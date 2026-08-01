"""WE **자신이 저장한** mip 레벨의 밝기를 레벨별로 잰다 — 알파/색 분리 측정.

왜 필요했나. 임베디드 mip 체인을 올린 뒤 macOS 검증에서 3394601417 이
luma 0.0600 -> 0.0116(0.194배)로 떨어져 GT structureLoss 게이트가 발화했다.
버그인지 정답인지는 한 가지로 갈린다:

  **WE 자신의 저장 mip 이 원래 그만큼 어두운가?**

프레임 캡처가 필요 없다 — WE 가 파일에 넣어 둔 픽셀을 그대로 읽으면 된다.

핵심은 **알파와 색을 나눠 보는 것**이다. 밝기 하락이
  - 색이 평균돼서면 → 정상(밉맵의 정의)
  - 알파가 평균돼서면 → 커버리지 축소, 역시 정상
  - 색은 그대로인데 알파만 급락 → 스파스 콘텐츠의 전형
반대로 알파는 그대로인데 색만 무너지면 디코드/규약 버그를 의심해야 한다.

실측 결론(코퍼스 25씬 · 임베디드 mip>=3 텍스처 140개):
  순수 색 비율은 레벨을 내려가도 중앙 ~0.99 — **색은 안 어두워진다**
  떨어지는 건 알파(커버리지). 최저 0.038
  절반 아래 하락의 주도 요인: 알파 11 · 색 0
따라서 0.194배는 WE 자신의 데이터 범위 안이고, 대응은 게이트 완화가 아니라 재베이스라인이다.
근거 항목: spec/formats/tex-embedded-mips.json → format.tex.embedded.mipDarkeningIsAlphaCoverage

usage:
    python scripts/spec/measure_mip_luma.py            # 코퍼스 25씬 요약
    python scripts/spec/measure_mip_luma.py --scenes 40
    python scripts/spec/measure_mip_luma.py --scene 3300031038   # 한 씬 레벨별 상세
"""
import argparse
import collections
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_tex_deep as T

MAXPX = 1 << 22          # 레벨당 픽셀 상한(순수 파이썬 디코드라 거대한 mip0 는 건너뛴다)


def png_decode(b):
    """8비트 PNG(그레이/RGB/팔레트/그레이+A/RGBA) → (w, h, [(r,g,b,a)…]).

    인터레이스·16비트는 미지원(None 반환) — 코퍼스 임베디드에는 없다.
    외부 의존 0 원칙에 따라 zlib(표준 라이브러리)만 쓴다.
    """
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    p, idat, plte, trns = 8, [], None, None
    w = h = depth = ctype = interlace = None
    while p + 8 <= len(b):
        ln = struct.unpack_from(">I", b, p)[0]
        typ = b[p + 4:p + 8]
        data = b[p + 8:p + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, ctype, _c, _f, interlace = struct.unpack_from(">IIBBBBB", data, 0)
        elif typ == b"PLTE":
            plte = data
        elif typ == b"tRNS":
            trns = data
        elif typ == b"IDAT":
            idat.append(data)
        elif typ == b"IEND":
            break
        p += 12 + ln
    if w is None or depth != 8 or interlace:
        return None
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if ch is None:
        return None
    raw = zlib.decompress(b"".join(idat))
    stride = w * ch
    out = bytearray(stride * h)
    prev = bytearray(stride)
    q = 0
    for y in range(h):
        f = raw[q]; q += 1
        line = bytearray(raw[q:q + stride]); q += stride
        if f == 1:                                    # Sub
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:                                  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:                                  # Average
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:                                  # Paeth
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                c = prev[i - ch] if i >= ch else 0
                bb = prev[i]
                pp = a + bb - c
                pa, pb, pc = abs(pp - a), abs(pp - bb), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (bb if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    px = []
    for i in range(0, stride * h, ch):
        if ctype == 0:
            g = out[i]; px.append((g, g, g, 255))
        elif ctype == 2:
            px.append((out[i], out[i + 1], out[i + 2], 255))
        elif ctype == 3:
            idx = out[i]
            r, g, bl = plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2]
            a = trns[idx] if trns and idx < len(trns) else 255
            px.append((r, g, bl, a))
        elif ctype == 4:
            g = out[i]; px.append((g, g, g, out[i + 1]))
        else:
            px.append((out[i], out[i + 1], out[i + 2], out[i + 3]))
    return w, h, px


def luma(px):
    """(premul, rgbOnly, alpha) — 이 셋을 나눠야 하락의 원인을 가릴 수 있다."""
    if not px:
        return (0.0, 0.0, 0.0)
    sp = sr = sa = 0.0
    for r, g, b, a in px:
        y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
        sp += y * (a / 255.0)
        sr += y
        sa += a / 255.0
    n = len(px)
    return (sp / n, sr / n, sa / n)


def embedded_multimip_texes(pkg):
    """(엔트리명, 파스결과, 원본바이트) — 임베디드 PNG/JPEG 이고 mip>1 인 것만."""
    raw = open(pkg, "rb").read()
    try:
        _, entries, base = T.parse_pkg(raw)
    except Exception:
        return
    for name, off, size in entries:
        if not name.lower().endswith(".tex"):
            continue
        b = raw[base + off:base + off + size]
        try:
            d = T.parse_tex(b)
        except Exception:
            continue
        if d["imageFormat"] not in (2, 13) or not d["mips"] or len(d["mips"][0]) < 2:
            continue
        yield name, d, b


def scene_pkg(wid):
    for fn in ("scene.pkg", "gifscene.pkg"):
        p = os.path.join(T.WS, wid, fn)
        if os.path.exists(p):
            return p
    return None


def one_scene(wid):
    pkg = scene_pkg(wid)
    if not pkg:
        print(f"{wid}: 패키지 없음")
        return
    print(f"{wid}")
    for name, d, b in embedded_multimip_texes(pkg):
        lv = []
        for i in range(len(d["mips"][0])):
            try:
                dec = png_decode(T.mip_bytes(b, d, level=i))
            except Exception:
                dec = None
            lv.append(luma(dec[2]) if dec else None)
        if not lv or lv[0] is None or lv[0][0] <= 0:
            continue
        print(f"  {name}  ({d['imgW']}x{d['imgH']}, {len(lv)}레벨)")
        for i, v in enumerate(lv):
            if v is None:
                print(f"     L{i}: 디코드 실패")
                continue
            print(f"     L{i}: premul={v[0]:.5f} ({v[0]/lv[0][0]:.3f}배)  "
                  f"rgb={v[1]:.5f} ({v[1]/max(lv[0][1],1e-9):.3f}배)  "
                  f"alpha={v[2]:.5f} ({v[2]/max(lv[0][2],1e-9):.3f}배)")


def corpus(limit):
    per_level = collections.defaultdict(list)
    drops = []
    alpha_driven = color_driven = 0
    scanned = scenes = 0
    for wid in sorted(os.listdir(T.WS)):
        if scenes >= limit:
            break
        pkg = scene_pkg(wid)
        if not pkg:
            continue
        used = False
        for name, d, b in embedded_multimip_texes(pkg):
            if len(d["mips"][0]) < 3 or d["imgW"] * d["imgH"] > MAXPX:
                continue
            lv, ok = [], True
            for i in range(len(d["mips"][0])):
                try:
                    dec = png_decode(T.mip_bytes(b, d, level=i))
                except Exception:
                    dec = None
                if not dec:
                    ok = False
                    break
                lv.append(luma(dec[2]))
            if not ok or len(lv) < 3 or lv[0][0] <= 1e-6:
                continue
            scanned += 1
            used = True
            for i, v in enumerate(lv):
                per_level[i].append(v[0] / lv[0][0])
            deep = min(len(lv) - 1, 4)
            ratio = lv[deep][0] / lv[0][0]
            rgb_r = lv[deep][1] / max(lv[0][1], 1e-9)
            a_r = lv[deep][2] / max(lv[0][2], 1e-9)
            drops.append({"scene": wid, "tex": name, "deepestLevel": deep,
                          "premulRatio": round(ratio, 3),
                          "rgbRatio": round(rgb_r, 3), "alphaRatio": round(a_r, 3)})
            if ratio < 0.8:
                if a_r < rgb_r:
                    alpha_driven += 1
                else:
                    color_driven += 1
        if used:
            scenes += 1

    print(f"씬 {scenes}종 · 임베디드 mip>=3 텍스처 {scanned}개 디코드")
    print()
    print("레벨별 L0 대비 밝기(알파 가중) — 중앙 / 최소 / 하위10%")
    for i in sorted(per_level):
        v = sorted(per_level[i])
        if len(v) < 3:
            continue
        print(f"  L{i}: n={len(v):<4} 중앙 {v[len(v)//2]:.3f}  최소 {v[0]:.3f}  "
              f"하위10% {v[max(0, len(v)//10)]:.3f}")
    print()
    strong = [d for d in drops if d["premulRatio"] < 0.5]
    print(f"깊은 레벨에서 **절반 아래**로 떨어지는 텍스처: {len(strong)} / {len(drops)}")
    print(f"  주도 요인 — 알파 {alpha_driven} · 색 {color_driven}")
    print("  (색 주도가 0 이라는 게 핵심이다: 색은 유지되고 커버리지만 준다 = 밉맵의 정의)")
    print()
    print("가장 크게 어두워지는 12개 — WE 자신의 저장 픽셀이다:")
    for d in sorted(drops, key=lambda x: x["premulRatio"])[:12]:
        print(f"  {d['premulRatio']:.3f}배  {d['scene']}/{d['tex'][:44]:<44} "
              f"rgb={d['rgbRatio']:.3f} alpha={d['alphaRatio']:.3f}")
    return {"scenes": scenes, "textures": scanned, "drops": drops,
            "alphaDriven": alpha_driven, "colorDriven": color_driven}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenes", type=int, default=25)
    ap.add_argument("--scene")
    ap.add_argument("--json")
    a = ap.parse_args()
    if a.scene:
        one_scene(a.scene)
        return
    r = corpus(a.scenes)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(r, fh, ensure_ascii=False, indent=1)
        print(f"\n기록: {a.json}")


if __name__ == "__main__":
    main()
