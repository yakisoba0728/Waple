"""`.tex` 파이프라인 심층 정본 생성기 — spec/formats/tex-deep.json.

세 갈래 측정을 한 스크립트에 담는다(외부 의존 없음, 순수 표준 라이브러리):

 1. corpus  — 워크샵 scene.pkg 162개 + 설치 `assets/`·`projects/` 의 .tex 전수(5,120개) 헤더 파스.
              파스가 전건 성공한다는 것 자체가 TEXI/TEXB 레이아웃의 검증이다.
 2. cli     — resourcecompiler64.exe 를 실제로 돌려 인자/포맷 enum/flags 비트를 차분 측정.
              (.tex-json 사이드카 키를 하나씩 켜고 헤더 바이트가 어떻게 바뀌는지 본다)
 3. oracle  — `-transcode` 가 BC(DXT) → RGBA8888 디코더임을 이용해 WE 자신의 디코드 결과와
              Waple DXT5Decoder 의 파이썬 미러를 픽셀 단위로 대조한다.

usage:
    python scripts/spec/measure_tex_deep.py            # 전부 측정 후 spec 갱신
    python scripts/spec/measure_tex_deep.py --no-cli   # WE 실행 없이 코퍼스만
    python scripts/spec/measure_tex_deep.py --oracle-limit 3
"""
import argparse
import collections
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
RC = os.path.join(WE, "bin", "resourcecompiler64.exe")
OUT = os.path.join("spec", "formats", "tex-deep.json")


# ---------------------------------------------------------------- pkg / tex 파스

def parse_pkg(data):
    """i32 vlen | magic | i32 count | count x (i32 nlen | name | i32 off | i32 size) | blob."""
    p = 0

    def i32():
        nonlocal p
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    entries = []
    for _ in range(i32()):
        nlen = i32()
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return magic, entries, p


def parse_tex(b):
    """TEXV0005 컨테이너 전 필드. 레이아웃 근거는 wallpaper64.exe FUN_14015c760(TEXI 리더):

        i32 format | i32 flags | i32 texW | i32 texH | i32 imgW | i32 imgH
        | i32 texDepth      (flags & 0x40 일 때만)
        | i32 previewColor  (TEXI 버전 > 0 일 때만 — TEXI0001 은 항상)

    Waple TexImage.parse 는 6필드만 읽고 "TEXB" 를 스캔해 넘어가므로 depth/color 를 모른다.
    실패 시 예외 — 전건 성공이 곧 규약의 검증이라 방어적으로 삼키지 않는다.
    """
    d = {"magic": b[0:8].decode("ascii", "replace")}
    assert b[8] == 0 and b[17] == 0, "헤더 NUL 구분자 없음"
    d["container"] = b[9:17].decode("ascii", "replace")
    texi_ver = int(d["container"][4:])
    (d["format"], d["flags"], d["texW"], d["texH"],
     d["imgW"], d["imgH"]) = struct.unpack_from("<6i", b, 18)
    p = 42
    d["depth"] = None
    if d["flags"] & 0x40:
        d["depth"] = struct.unpack_from("<i", b, p)[0]
        p += 4
    d["previewColor"] = None
    if texi_ver > 0:
        d["previewColor"] = struct.unpack_from("<I", b, p)[0]
        p += 4
    d["texb"] = b[p:p + 8].decode("ascii", "replace")
    assert b[p + 8] == 0, "TEXB 가 헤더 직후에 없다"
    ver = int(b[p + 4:p + 8])
    d["texbVer"] = ver
    p += 9
    d["imageCount"] = struct.unpack_from("<i", b, p)[0]
    p += 4
    d["imageFormat"] = None
    d["variantCount"] = None
    if ver >= 3:
        d["imageFormat"] = struct.unpack_from("<i", b, p)[0]
        p += 4
        if ver >= 4:
            d["variantCount"] = struct.unpack_from("<i", b, p)[0]
            p += 4
    # v4 조건 변형 블록: variantCount 개 × (i32 ×3 + NUL 종단 JSON)
    d["variants"] = []
    for _ in range(d["variantCount"] or 0):
        x, y, z = struct.unpack_from("<3i", b, p)
        p += 12
        e = b.index(b"\0", p)
        d["variants"].append((x, y, z, b[p:e].decode("utf-8", "replace")))
        p = e + 1
    mips = []
    for _ in range(d["imageCount"]):
        mc = struct.unpack_from("<i", b, p)[0]
        p += 4
        if not (0 < mc < 64):
            d["parseNote"] = f"mipCount={mc}"
            break
        lv = []
        for _ in range(mc):
            w, h = struct.unpack_from("<2i", b, p)
            p += 8
            # 3D 슬라이스 텍스처는 mip 레코드에도 depth 가 하나 더 들어간다(실측 LUT 28개).
            # Waple 이 "lut/* 는 mip 에 여분 int 가 있어 parseMip 실패" 라고 적어 둔 그 필드다.
            mdepth = None
            if d["flags"] & 0x40:
                mdepth = struct.unpack_from("<i", b, p)[0]
                p += 4
            lz4, dec = 1, 0
            if ver >= 2:
                lz4, dec = struct.unpack_from("<2i", b, p)
                p += 8
            comp = struct.unpack_from("<i", b, p)[0]
            p += 4
            if not (0 < comp <= len(b) - p):
                d["parseNote"] = f"comp={comp}"
                break
            lv.append(dict(w=w, h=h, depth=mdepth, lz4=lz4, dec=dec, comp=comp, off=p))
            p += comp
        mips.append(lv)
    d["mips"] = mips
    d["texbEnd"] = p
    # TEXS 는 TEXB 섹션 **직후**에 온다(엔진 FUN_14015e580 의 섹션 루프). 뒤에서 스캔하지 않고
    # 정확한 위치에서 읽어야 레이아웃을 검증할 수 있다 — 파스 끝이 EOF 와 정확히 맞으면 규약이 맞은 것.
    d["texs"] = None
    if b[p:p + 4] == b"TEXS":
        d["texs"] = b[p:p + 8].decode("ascii", "replace")
        sver = int(b[p + 4:p + 8])
        d["texsVer"] = sver
        p += 9
        n = struct.unpack_from("<i", b, p)[0]
        p += 4
        d["texsCount"] = n
        if sver >= 3:                       # v3 은 gifWidth/gifHeight 를 명시한다
            d["gifW"], d["gifH"] = struct.unpack_from("<2i", b, p)
            p += 8
        else:                               # v1/v2 는 헤더 imgW/imgH 로 대체한다(엔진 기본값)
            d["gifW"], d["gifH"] = d["imgW"], d["imgH"]
        # 레코드 = i32 imageId | f32 frametime | 지오메트리 6개(v1 은 i32, v2+ 는 f32) = 32B 고정
        g = "<6i" if sver == 1 else "<6f"
        frames = []
        for _ in range(n):
            iid = struct.unpack_from("<i", b, p)[0]
            ft = struct.unpack_from("<f", b, p + 4)[0]
            geom = struct.unpack_from(g, b, p + 8)
            frames.append((iid, ft) + tuple(float(x) for x in geom))
            p += 32
        d["frames"] = frames
        d["texsEndsAtEOF"] = (p == len(b))
    return d


def iter_tex():
    """(출처, 이름, 바이트) — pkg 내부 + 설치 `assets/`·`projects/` 의 loose .tex."""
    # 코퍼스가 없으면 조용히 건너뛰지 않는다. 건너뛰면 `corpusTexFiles` 가 0 이 되고
    # 산문 근거("코퍼스 5120 중 bit3 켜진 파일 0개")가 "코퍼스 0 중 0개" 로 바뀌어
    # **같은 문장이 반대 의미가 된다** — 0/0 은 아무 것도 증명하지 않는데 문장은 그대로
    # 확정으로 남는다. exit 0 으로 통과하는 것이 이 구멍의 핵심이다.
    if not os.path.isdir(WS):
        raise SystemExit(
            f"[measure_tex_deep] 코퍼스가 없다: {WS}\n"
            f"  WE_WORKSHOP 으로 워크샵 코퍼스 루트를 지정하라.\n"
            f"  (코퍼스 도수가 이 문서 근거의 대부분이다 — 없이 재생성하면 근거만 지워진다.)")
    if os.path.isdir(WS):
        for wid in sorted(os.listdir(WS)):
            d = os.path.join(WS, wid)
            if not os.path.isdir(d):
                continue
            for fn in ("scene.pkg", "gifscene.pkg"):
                path = os.path.join(d, fn)
                if not os.path.exists(path):
                    continue
                data = open(path, "rb").read()
                try:
                    _, entries, base = parse_pkg(data)
                except Exception:
                    continue
                for name, off, size in entries:
                    if name.lower().endswith(".tex"):
                        yield (path, name, data[base + off:base + off + size])
    # [2026-08-21] `projects/` 추가(없는 루트는 walk 가 빈 이터레이터) — 근거 docs/re/tex-format.md §2.4.
    for root in (os.path.join(WE, "assets"), os.path.join(WE, "projects")):
        for dp, _, fn in os.walk(root):
            for f in fn:
                if f.endswith(".tex"):
                    p = os.path.join(dp, f)
                    yield (p, f, open(p, "rb").read())


# ---------------------------------------------------------------- PNG / LZ4 (무의존)

def write_png(path, w, h, rgba):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * w * 4:(y + 1) * w * 4]

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def lz4_raw(src, expected):
    """LZ4 block(raw) 해제 — Apple COMPRESSION_LZ4_RAW 와 동일 규약(Waple 이 쓰는 것)."""
    out = bytearray()
    i, n = 0, len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                v = src[i]
                i += 1
                lit += v
                if v != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        ml = tok & 0xF
        if ml == 15:
            while True:
                v = src[i]
                i += 1
                ml += v
                if v != 255:
                    break
        ml += 4
        s = len(out) - off
        for k in range(ml):
            out.append(out[s + k])
    if expected is not None and len(out) != expected:
        raise ValueError(f"lz4 {len(out)} != {expected}")
    return bytes(out)


def mip_bytes(b, d, level=0, image=0):
    m = d["mips"][image][level]
    p = b[m["off"]:m["off"] + m["comp"]]
    return lz4_raw(p, m["dec"]) if m["lz4"] else p


# ---------------------------------------------------------------- BC 디코더(WE 규약)

def _c565(c):
    """WE 실측: 5/6bit → 8bit 는 **비트 복제**. Waple 은 c*255/31 을 써서 채널당 최대 ±1 어긋난다."""
    r, g, b = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


LERP_ROUND = False   # 컬러 보간 반올림 여부 — 아래 오라클이 floor 가 정답임을 실측으로 가른다


def _lerp3(x, y, t):
    return (x * (3 - t) + y * t + (1 if LERP_ROUND else 0)) // 3


def _bc_common(src, w, h, block, alpha_of, four_color_only):
    bx, by = (w + 3) // 4, (h + 3) // 4
    out = bytearray(w * h * 4)
    coff = 8 if block == 16 else 0
    for byi in range(by):
        for bxi in range(bx):
            o = (byi * bx + bxi) * block
            co = o + coff
            c0 = src[co] | (src[co + 1] << 8)
            c1 = src[co + 2] | (src[co + 3] << 8)
            p0, p1 = _c565(c0), _c565(c1)
            if four_color_only or c0 > c1:
                pal = [p0 + (255,), p1 + (255,),
                       tuple(_lerp3(p0[k], p1[k], 1) for k in range(3)) + (255,),
                       tuple(_lerp3(p0[k], p1[k], 2) for k in range(3)) + (255,)]
            else:
                pal = [p0 + (255,), p1 + (255,),
                       tuple((p0[k] + p1[k]) // 2 for k in range(3)) + (255,), (0, 0, 0, 0)]
            cb = struct.unpack_from("<I", src, co + 4)[0]
            av = alpha_of(src, o) if alpha_of else None
            for py in range(4):
                for px in range(4):
                    x, y = bxi * 4 + px, byi * 4 + py
                    if x >= w or y >= h:
                        continue
                    idx = py * 4 + px
                    r, g, b, a = pal[(cb >> (2 * idx)) & 3]
                    if av is not None:
                        a = av(idx)
                    d = (y * w + x) * 4
                    out[d:d + 4] = bytes((r, g, b, a))
    return bytes(out)


def _bc3_alpha(src, o):
    """BC4 알파 보간은 **반올림**(+3)/7, (+2)/5 — Waple 은 floor 라 ±1 어긋난다."""
    a0, a1 = src[o], src[o + 1]
    al = [a0, a1] + [0] * 6
    if a0 > a1:
        for i in range(1, 7):
            al[i + 1] = ((7 - i) * a0 + i * a1 + 3) // 7
    else:
        for i in range(1, 5):
            al[i + 1] = ((5 - i) * a0 + i * a1 + 2) // 5
        al[6], al[7] = 0, 255
    ab = int.from_bytes(src[o + 2:o + 8], "little")
    return lambda idx: al[(ab >> (3 * idx)) & 7]


def _bc2_alpha(src, o):
    ab = int.from_bytes(src[o:o + 8], "little")
    return lambda idx: ((ab >> (4 * idx)) & 0xF) * 17


def decode_bc(fmt, src, w, h):
    if fmt == 4:
        return _bc_common(src, w, h, 16, _bc3_alpha, True)
    if fmt == 6:
        return _bc_common(src, w, h, 16, _bc2_alpha, True)
    if fmt == 7:
        return _bc_common(src, w, h, 8, None, False)
    return None


def crop(pixels, dw, dh, iw, ih):
    """Waple TexDecoder.cropped(): 패딩 텍스처(decode dims)에서 image dims 를 top-left 로 자른다."""
    if (iw, ih) == (dw, dh) or not (0 < iw <= dw and 0 < ih <= dh):
        return pixels
    out = bytearray(iw * ih * 4)
    for y in range(ih):
        out[y * iw * 4:(y + 1) * iw * 4] = pixels[y * dw * 4:y * dw * 4 + iw * 4]
    return bytes(out)


# ---------------------------------------------------------------- 1) 코퍼스 측정

def measure_corpus():
    c = dict(fmt=collections.Counter(), flags=collections.Counter(),
             flagbits=collections.Counter(), texb=collections.Counter(),
             variantCount=collections.Counter(), imageFormat=collections.Counter(),
             imageCount=collections.Counter(), bpp=collections.Counter(),
             depth=collections.Counter(), mipCount=collections.Counter(),
             texs=collections.Counter(), texsEndsAtEOF=collections.Counter(),
             texbEndIsEOForTEXS=collections.Counter(), tailHasVariants=collections.Counter())
    total, errors = 0, collections.Counter()
    variant_model_mismatch = 0
    picks = {}          # 뒤 단계(CLI/오라클)가 쓸 표본 — 코퍼스를 두 번 훑지 않으려고 여기서 고른다
    for src, name, b in iter_tex():
        total += 1
        try:
            d = parse_tex(b)
        except Exception as e:
            errors[f"{type(e).__name__}: {e}"] += 1
            continue
        if len(b) <= 4 << 20:
            for k, cond in (("fmt8", d["format"] == 8), ("fmt9", d["format"] == 9),
                            ("depth>1", (d["depth"] or 0) > 1),
                            ("flags&0x20", bool(d["flags"] & 0x20)),
                            ("bcSample", d["format"] == 4 and d["imageFormat"] in (None, -1)
                             and d["texW"] * d["texH"] <= 256 * 256)):
                if cond and k not in picks:
                    picks[k] = (src, name, b)
        c["fmt"][d["format"]] += 1
        c["flags"][d["flags"]] += 1
        for i in range(32):
            if d["flags"] & (1 << i):
                c["flagbits"][i] += 1
        c["texb"][d["texb"]] += 1
        c["variantCount"][d["variantCount"]] += 1
        c["imageFormat"][d["imageFormat"]] += 1
        c["imageCount"][d["imageCount"]] += 1
        if d["depth"] is not None:
            c["depth"][d["depth"]] += 1
        if d["mips"] and d["mips"][0]:
            c["mipCount"][len(d["mips"][0])] += 1
            m = d["mips"][0][0]
            if d["imageFormat"] in (None, -1) and m["dec"] and m["w"] and m["h"]:
                c["bpp"][(d["format"], round(m["dec"] / (m["w"] * m["h"]), 4))] += 1
        c["texs"][d["texs"]] += 1
        if d["texs"]:
            c["texsEndsAtEOF"][d["texsEndsAtEOF"]] += 1
        else:
            c["texbEndIsEOForTEXS"][d["texbEnd"] == len(b)] += 1
            if d["texbEnd"] != len(b):
                # 남은 꼬리가 있는 파일 = 조건 변형 이미지 섹션을 가진 파일인가?
                c["tailHasVariants"][bool(d["variantCount"])] += 1
        if d["texbVer"] >= 4 and heuristic_variants(b, d) != d["variants"]:
            variant_model_mismatch += 1
    out = dict(total=total, errors=dict(errors), variantModelMismatch=variant_model_mismatch,
               **{k: {str(a): n for a, n in sorted(v.items(), key=lambda x: -x[1])}
                  for k, v in c.items()})
    out["_picks"] = picks
    return out


def heuristic_variants(b, d):
    """Waple TexImage.conditionVariantBlock 의 휴리스틱 재현 — 카운트 기반 정답과 대조용."""
    p = 42 + (4 if d["flags"] & 0x40 else 0) + 4
    q = p + 9 + 4 + 4 + 4          # TEXB000N\0 + imageCount + imageFormat + variantCount
    out = []
    while True:
        if q + 12 > len(b):
            break
        m1, idx, z = struct.unpack_from("<3i", b, q)
        if m1 != 1 or not (1 <= idx <= 64) or z != 0:
            break
        js = q + 12
        if js >= len(b) or b[js] not in (0x7B, 0x5B):
            break
        lim = min(len(b), js + 65536)
        e = js
        while e < lim and b[e] != 0:
            e += 1
        if e >= lim:
            break
        out.append((m1, idx, z, b[js:e].decode("utf-8", "replace")))
        q = e + 1
    return out


# ---------------------------------------------------------------- 2) CLI 차분 측정

def _rc(cwd, *args):
    """resourcecompiler64.exe 호출.

    ⚠️ **반드시 cwd + 상대경로**로 불러야 한다. 절대경로를 -i 로 주면 -tex 모드가 무한 루프에
    빠진다(실측: 22분 스핀, CPU 1353s, 출력 없음). 같은 파일을 cwd 상대경로로 주면 즉시 끝난다.
    timeout 은 그래도 남겨 둔다 — 다른 입력에서 같은 함정을 밟아도 스크립트가 멈추지 않게.
    """
    try:
        r = subprocess.run([RC] + list(args), capture_output=True, text=True,
                           cwd=cwd, timeout=120)
        return r.stdout
    except subprocess.TimeoutExpired:
        return "<timeout>"


def _hdr(path):
    b = open(path, "rb").read()
    d = parse_tex(b)
    return dict(format=d["format"], flags=d["flags"], texW=d["texW"], texH=d["texH"],
                imgW=d["imgW"], imgH=d["imgH"], depth=d["depth"],
                previewColor=None if d["previewColor"] is None else f"{d['previewColor']:#010x}",
                mipCount=len(d["mips"][0]) if d["mips"] else 0,
                mipDims=[(m["w"], m["h"]) for m in (d["mips"][0] if d["mips"] else [])])


def measure_cli(tmp, picks):
    """.tex-json 사이드카/CLI 인자를 하나씩 켜고 헤더 필드가 어떻게 바뀌는지 본다.

    파일명은 전부 tmp 기준 **상대경로**로 넘긴다(_rc 주석의 절대경로 무한루프 함정)."""
    px = bytearray()
    for y in range(64):
        for x in range(64):
            px += bytes([x * 4, y * 4, (x + y) * 2, 255])
    write_png(os.path.join(tmp, "grad.png"), 64, 64, bytes(px))
    px = bytearray()
    for y in range(32):
        for x in range(1024):
            px += bytes([x % 256, y * 8, (x // 32) * 8, 255])
    write_png(os.path.join(tmp, "lut.png"), 1024, 32, bytes(px))
    for name, rgba in (("red", (255, 0, 0, 255)), ("gray", (128, 128, 128, 255))):
        write_png(os.path.join(tmp, name + ".png"), 64, 64, bytes(rgba) * (64 * 64))
    grad, lut = "grad.png", "lut.png"
    solid = {"red": "red.png", "gray": "gray.png"}

    def compile_tex(src, tag, sidecar):
        shutil.copy(os.path.join(tmp, src), os.path.join(tmp, tag + ".png"))
        json.dump(sidecar, open(os.path.join(tmp, tag + ".tex-json"), "w"))
        log = _rc(tmp, "-tex", "-i", tag + ".png", "-o", tag + ".tex")
        out = os.path.join(tmp, tag + ".tex")
        return (_hdr(out) if os.path.exists(out) else None), log

    res = {}
    # (a) .tex-json format 문자열 → 헤더 format enum
    fmts = {}
    for n in ["rgba8888", "rgb888", "rgb565", "rg88", "r8", "dxt1", "dxt3", "dxt5", "bc7",
              "etc1", "etc2", "rgba8", "rgba1010102", "rgba16161616f", "rgb161616f",
              "dxt5n", "dxt1n", "dxt3n", "bc7n", "rg88n", "rgba8888n", "___bogus___"]:
        h, log = compile_tex(grad, "f_" + re.sub(r"\W", "_", n), {"format": n})
        fmts[n] = dict(headerFormat=h and h["format"],
                       mip0DecompressedBytes=h and h["mipCount"] and None,
                       normalmapSwizzle="Normalmap swizzling" in log,
                       compressLog=next((l.strip() for l in log.splitlines()
                                         if "Compressing as" in l), None))
    res["texJsonFormatToEnum"] = fmts

    # (b) .tex-json 불리언 키 → flags 비트
    base, _ = compile_tex(grad, "flags_base", {"format": "rgba8888"})
    bits = {}
    for k in ["nointerpolation", "clampuvs", "croptoaspectratio", "nomip", "halfmip",
              "bleedtransparentcolors", "forcerawcompression", "alphachannelpriority",
              "ignoresizefornativecompression", "cropandresize", "normalmapflipx",
              "normalmapflipy", "nonpoweroftwo", "srgb", "spritesheet"]:
        h, _ = compile_tex(grad, "flag_" + k, {"format": "rgba8888", k: True})
        if h and h["flags"] != base["flags"]:
            bits[k] = f'{h["flags"] ^ base["flags"]:#x}'
    h, _ = compile_tex(grad, "flag_ss", {"format": "rgba8888",
                                         "spritesheetsequences": [{"frames": 8, "duration": 1,
                                                                   "width": 32, "height": 32}]})
    if h:
        bits["spritesheetsequences"] = f'{h["flags"] ^ base["flags"]:#x}'
    h3, _ = compile_tex(lut, "flag_s3d", {"format": "rgba8888", "slice3d": True})
    if h3:
        bits["slice3d"] = f'{h3["flags"]:#x}'
        res["slice3dHeader"] = h3
    res["texJsonKeyToFlagBit"] = bits
    res["flagsBaseline"] = base

    # (c) TEXI preview color (헤더 마지막 u32)
    pc = {}
    for name, p in solid.items():
        h, _ = compile_tex(p, "pc_" + name, {"format": "rgba8888"})
        pc[name] = h and h["previewColor"]
    h, _ = compile_tex(grad, "pc_grad", {"format": "rgba8888"})
    pc["gradient(mean=126,126,126)"] = h and h["previewColor"]
    res["previewColor"] = pc

    # (d) -transcode 인자 매트릭스
    tr = {}
    src4 = None
    if "bcSample" in picks:
        src4 = os.path.join(tmp, "src_dxt5.tex")
        open(src4, "wb").write(picks["bcSample"][2])
    if src4:
        for tag, extra in (("default", []), ("f_RGBA8", ["-f", "RGBA8"]), ("f_ETC1", ["-f", "ETC1"]),
                           ("f_ETC2", ["-f", "ETC2"]), ("f_dxt5", ["-f", "dxt5"]),
                           ("f_rgba8888", ["-f", "rgba8888"]), ("c_force", ["-c", "force"]),
                           ("shrink2", ["-shrink", "2"]), ("maxmipmaps2", ["-maxmipmaps", "2"])):
            o = os.path.join(tmp, "tr_" + tag + ".tex")
            _rc(tmp, "-transcode", "-i", "src_dxt5.tex", "-o", "tr_" + tag + ".tex", *extra)
            tr[tag] = _hdr(o) if os.path.exists(o) else None
        res["transcodeMatrix"] = tr
        res["transcodeSourceHeader"] = _hdr(src4)

    # (e) 통과(passthrough) 조건: RG88/R8/3D LUT/비디오는 바이트 복사
    pt = {}
    for key in ("fmt8", "fmt9", "depth>1", "flags&0x20"):
        if key not in picks:
            continue
        b = picks[key][2]
        d = parse_tex(b)
        ip = os.path.join(tmp, "pt_in.tex")
        op = os.path.join(tmp, "pt_out.tex")
        open(ip, "wb").write(b)
        if os.path.exists(op):
            os.remove(op)
        _rc(tmp, "-transcode", "-i", "pt_in.tex", "-o", "pt_out.tex")
        same = os.path.exists(op) and open(op, "rb").read() == b
        pt[key] = dict(srcFormat=d["format"], srcFlags=d["flags"], depth=d["depth"],
                       byteIdentical=same)
    res["transcodePassthrough"] = pt

    # (f) 모드 목록 — 알 수 없는 인자는 "unsupported mode"
    res["modes"] = {"unknown-mode-stdout": _rc(tmp, "-help").strip().splitlines()[:1]}
    # (g) -pngExport: 인자는 파싱되지만 어떤 입력으로도 산출물을 못 봤다
    shutil.copy(os.path.join(tmp, "grad.tex") if os.path.exists(os.path.join(tmp, "grad.tex"))
                else os.path.join(tmp, "flags_base.tex"), os.path.join(tmp, "pe.tex"))
    os.makedirs(os.path.join(tmp, "peout"), exist_ok=True)
    _rc(tmp, "-pngExport", "-src", "pe.tex", "-out", "peout")
    res["pngExportProducedFiles"] = os.listdir(os.path.join(tmp, "peout"))
    return res


# ---------------------------------------------------------------- 3) 오라클 대조

def measure_oracle(tmp, limit=4):
    """`-transcode` 기본 출력(RGBA8888, image dims 크롭)을 정답으로 두고 BC 디코드를 대조."""
    got = collections.Counter()
    rows = []
    for _, name, b in iter_tex():
        try:
            d = parse_tex(b)
        except Exception:
            continue
        f = d["format"]
        if f not in (4, 6, 7) or got[f] >= limit:
            continue
        # 순수 파이썬 디코드라 큰 텍스처는 제외. fmt6(dxt3)은 코퍼스에 작은 표본이 없어 한도를 넓힌다.
        if d["imageFormat"] not in (None, -1):
            continue
        if d["texW"] * d["texH"] > (520 * 520 if f == 6 else 300 * 300):
            continue
        got[f] += 1
        ip, op = os.path.join(tmp, "o_in.tex"), os.path.join(tmp, "o_out.tex")
        open(ip, "wb").write(b)
        if os.path.exists(op):
            os.remove(op)
        _rc(tmp, "-transcode", "-i", "o_in.tex", "-o", "o_out.tex")
        if not os.path.exists(op):
            rows.append(dict(name=name, status="transcode-failed"))
            continue
        ob = open(op, "rb").read()
        dst = parse_tex(ob)
        m = d["mips"][0][0]
        ours = crop(decode_bc(f, mip_bytes(b, d), m["w"], m["h"]), m["w"], m["h"],
                    d["imgW"], d["imgH"])
        theirs = mip_bytes(ob, dst)
        row = dict(srcFormat=f, dstFormat=dst["format"],
                   srcDims=[d["texW"], d["texH"], d["imgW"], d["imgH"]],
                   dstDims=[dst["texW"], dst["texH"], dst["imgW"], dst["imgH"]],
                   bytes=[len(ours), len(theirs)])
        if len(ours) != len(theirs):
            row["status"] = "size-mismatch"
        else:
            delta = max((abs(ours[i] - theirs[i]) for i in range(len(ours))), default=0)
            row["maxChannelDelta"] = delta
            row["status"] = "exact" if delta == 0 else "differs"
            # 컬러 보간 반올림 변형도 같이 재서 floor 가 유일해인지 가른다(포맷별 첫 표본만)
            if got[f] == 1:
                global LERP_ROUND
                LERP_ROUND = True
                try:
                    alt = crop(decode_bc(f, mip_bytes(b, d), m["w"], m["h"]),
                               m["w"], m["h"], d["imgW"], d["imgH"])
                finally:
                    LERP_ROUND = False
                row["roundedColorLerpByteDiffs"] = sum(1 for i in range(len(alt))
                                                       if alt[i] != theirs[i])
            # Waple 현행 규약(565 = c*255/31, 알파 floor)과의 차이도 같은 표본에서 잰다
            if got[f] == 1:
                row["wapleRuleMaxChannelDelta"] = _waple_rule_delta(f, b, d, m, theirs)
        rows.append(row)
        if all(got[k] >= limit for k in (4, 6, 7)):
            break
    return rows


def _waple_rule_delta(f, b, d, m, theirs):
    """Waple TexImage/DXT5Decoder 현행 규약(c*255/31 + floor 알파)으로 디코드했을 때의 최대 오차."""
    global _c565, _bc3_alpha
    orig_c565, orig_alpha = _c565, _bc3_alpha

    def waple_c565(c):
        r, g, b_ = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
        return (r * 255 // 31, g * 255 // 63, b_ * 255 // 31)

    def waple_alpha(src, o):
        a0, a1 = src[o], src[o + 1]
        al = [a0, a1] + [0] * 6
        if a0 > a1:
            for i in range(1, 7):
                al[i + 1] = ((7 - i) * a0 + i * a1) // 7
        else:
            for i in range(1, 5):
                al[i + 1] = ((5 - i) * a0 + i * a1) // 5
            al[6], al[7] = 0, 255
        ab = int.from_bytes(src[o + 2:o + 8], "little")
        return lambda idx: al[(ab >> (3 * idx)) & 7]

    _c565, _bc3_alpha = waple_c565, waple_alpha
    try:
        alt = crop(decode_bc(f, mip_bytes(b, d), m["w"], m["h"]), m["w"], m["h"],
                   d["imgW"], d["imgH"])
    finally:
        _c565, _bc3_alpha = orig_c565, orig_alpha
    return max((abs(alt[i] - theirs[i]) for i in range(len(alt))), default=0)


# ---------------------------------------------------------------- 4) .tex-json 키 수확

def measure_texjson():
    keys = collections.Counter()
    vals = collections.defaultdict(collections.Counter)
    files = 0

    def walk(o, pre=""):
        if isinstance(o, dict):
            for k, v in o.items():
                keys[pre + k] += 1
                if isinstance(v, (str, int, float, bool)) or v is None:
                    vals[pre + k][repr(v)] += 1
                else:
                    walk(v, pre + k + ".")
        elif isinstance(o, list):
            for v in o:
                walk(v, pre + "[].")

    for root in (os.path.join(WE, "assets"), WS, os.path.join(WE, "projects")):
        if not os.path.isdir(root):
            continue
        for dp, _, fn in os.walk(root):
            for f in fn:
                if not f.endswith(".tex-json"):
                    continue
                files += 1
                try:
                    walk(json.load(open(os.path.join(dp, f), encoding="utf-8-sig")))
                except Exception:
                    pass
    return dict(files=files,
                keys={k: dict(count=n, values=dict(vals[k].most_common(6)))
                      for k, n in keys.most_common()})


def measure_compiler_key_strings():
    """resourcecompiler64.exe / wallpaperui.exe / wallpaper64.exe 에서 키 토큰 존재 여부."""
    out = {}
    bins = {"resourcecompiler64.exe": os.path.join(WE, "bin", "resourcecompiler64.exe"),
            "wallpaperui.exe": os.path.join(WE, "bin", "wallpaperui.exe"),
            "wallpaper64.exe": os.path.join(WE, "wallpaper64.exe")}
    keys = ["format", "nointerpolation", "clampuvs", "croptoaspectratio", "nomip", "halfmip",
            "bilateralfilterkernel", "bilateralfilterstrength", "wildcard", "frameduration",
            "imagesequence", "file", "duration", "spritesheetsequences",
            "bleedtransparentcolors", "forcerawcompression",
            "ignoresizefornativecompression", "cropandresize", "cropresizewidth",
            "cropresizeheight", "alphachannelpriority", "normalmapflipx", "normalmapflipy",
            "slice3d", "variants", "options", "blend", "variantcondition", "alphablend",
            "component", "width", "height", "frames", "force",
            "nonpoweroftwo", "srgb", "spritesheet"]
    for bn, path in bins.items():
        if not os.path.exists(path):
            continue
        d = open(path, "rb").read()
        hit = {}
        for k in keys:
            # 정확 토큰: 앞뒤가 인쇄가능 ASCII 가 아니어야 한다(부분문자열 오탐 차단)
            n = 0
            for m in re.finditer(re.escape(k.encode()), d):
                s, e = m.start(), m.end()
                pre = d[s - 1] if s else 0
                post = d[e] if e < len(d) else 0
                if not (0x20 <= pre <= 0x7E) and not (0x20 <= post <= 0x7E):
                    n += 1
            hit[k] = n
        out[bn] = hit
    return out


# ---------------------------------------------------------------- 정본 조립

def build(m):
    E = specfmt.entry
    ev = specfmt.ev
    S = "scripts/spec/measure_tex_deep.py"
    corpus = m["corpus"]
    cli = m.get("cli") or {}
    oracle = m.get("oracle") or []
    tj = m["texjson"]
    ks = m["keyStrings"]
    entries = []

    entries.append(E(
        "format.tex.texi.fieldLayout",
        {"order": ["i32 format", "i32 flags", "i32 texWidth", "i32 texHeight",
                   "i32 imageWidth", "i32 imageHeight",
                   "i32 texDepth  — flags & 0x40 일 때만 존재",
                   "u32 previewColor(RGBA 바이트 순) — TEXI 버전 > 0 일 때만"],
         "headerBytesWithoutDepth": 46, "headerBytesWithDepth": 50,
         "note": "TEXB 는 이 헤더 직후에 붙는다. Waple 은 6필드만 읽고 TEXB 를 스캔한다."},
        "확정",
        [ev("binary", "wallpaper64.exe FUN_14015c760 (TEXI 리더) 디컴파일",
            "슬롯 [0]fmt [1]flags(|=) [2]texW [3]texH [5]imgW [6]imgH, flags&0x40 이면 [4]depth, ver>0 이면 [7]"),
         ev("corpus", f"코퍼스 {corpus['total']}/{corpus['total']} 파스 성공, 오류 {len(corpus['errors'])}종",
            "종전 46B 고정 가정은 flags&0x40 인 28개(LUT)에서 전건 실패했다"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.flags.bits",
        {"0x1": "nointerpolation — 차분 측정 확정",
         "0x2": "clampuvs — 차분 측정 확정",
         "0x4": "스프라이트시트(gif) — spritesheetsequences 를 주면 켜지고 TEXS 섹션이 붙는다",
         "0x8": f"파일 입력이 **아니다** — 코퍼스 {corpus['total']}개 중 bit3 이 켜진 파일 0개. "
                f"엔진 로더가 프레임 수 < 2 일 때 스스로 세우고, -transcode 출력에도 그대로 찍혀 나온다"
                f"(입력 flags 2 → 출력 10 관측). 리더는 이 비트를 무시해야 한다",
         "0x10": f"설치 `projects/` 를 코퍼스에 넣고서야 나타난 비트(관측 "
                 f"{corpus['flagbits'].get('4', 0)}건). `.tex-json` 의 `srgb: true` 와 "
                 f"사이드카 짝 358쌍에서 10/10 · 348/348 로 붙는다. **이름과 런타임 소비 여부는 "
                 f"별도 항목 `format.tex.flags.srgbBit` 를 보라** — 그쪽은 확정이 아니다",
         "0x20": "비디오 텍스처(mp4 페이로드). 코퍼스 38개, 전부 TEXB0003",
         "0x40": "3D 슬라이스(volume). 헤더에 i32 texDepth 가 추가된다. slice3d:true 로 재현",
         "0x80000": "alphachannelpriority — 차분 측정 확정(코퍼스 82개)",
         "0x100000/0x200000/0x400000/0x800000": "미상 — 코퍼스 30개, 전부 *_mask_*.tex",
         "observedBitCounts": corpus["flagbits"],
         "observedValues": corpus["flags"]},
        "확정",
        [ev("binary", "resourcecompiler64.exe -tex 차분 컴파일(.tex-json 키 1개씩 토글)",
            json.dumps(cli.get("texJsonKeyToFlagBit", {}), ensure_ascii=False)),
         ev("binary", "wallpaper64.exe FUN_14015e580 — 프레임 수 < 2 이면 flags |= 8"),
         ev("corpus", f"{corpus['total']}개 전수 비트 도수"),
         ev("script", S)]))

    # 비트 0x10 은 **도수만 확정**이고 이름·소비는 아니다. `flags.bits` 는 확정 항목이라
    # 그 안에 헤지를 섞으면 항목 전체의 등급이 흐려진다 — 등급이 다른 주장은 항목을 나눈다.
    entries.append(E(
        "format.tex.flags.srgbBit",
        {"observed": f"코퍼스 {corpus['total']}개 중 비트 4(`0x10`)가 선 파일 "
                     f"{corpus['flagbits'].get('4', 0)}개 — 전부 설치 "
                     f"`projects/defaultprojects/razer_bedroom/materials/` 한 프로젝트다. "
                     f"`assets/`·워크샵 코퍼스에는 0건이라 `projects/` 를 넣기 전까지 안 보였다",
         "sidecarCorrespondence": "`.tex-json` 짝 358쌍(동봉 272 + 설치 projects 86)에서 "
                                  "`srgb: true` 10/10 이 비트를 세우고 `srgb` 부재 348/348 이 안 세운다. "
                                  "check_tex_format_map.py 의 J 게이트가 매 실행 다시 잰다",
         "nameIsNotConfirmed": "표본 10건이 전부 같은 프로젝트 = 같은 시점 같은 도구로 구운 한 묶음이라 "
                               "교란 가능하다. 그 10건에만 있는 다른 성질이 원인일 수도 있다. "
                               "게다가 현행 resourcecompiler64.exe 의 `.tex-json` 키 표 34개에 `srgb` 가 "
                               "없다(texJson.keys.deadKeys) — 지금 컴파일러는 이 비트를 만들지 못한다. "
                               "차분 컴파일로 재현하지 못한 유일한 비트다",
         "runtimeConsumption": "wallpaper64.exe `.text`(4,344,320B) 전수 바이트 스캔에서 "
                               "`test byte ptr [reg+4], 0x10`(f6 /0, disp8=4, imm8=0x10) 0건. "
                               "형제 인코딩은 0 이 아니다 — 같은 자리 다른 imm 36건 · 같은 imm 다른 "
                               "disp8 108건이라 판별력 있는 0 이다. 다만 (a) `mov eax,[reg+4]` 로 먼저 "
                               "적재한 뒤 `test al, imm` 하는 형태는 이 스캔이 못 잡고 (b) WE 는 "
                               "여러 바이너리로 나뉜다. 그러므로 **비소비는 정황**이다",
         "wapleImpact": "Waple 은 이 비트를 무시한다. 그것이 안전한 기본값이다 — 읽기 시작하면 그때부터 "
                        "WE 와 **다르게** 그리는 쪽이 되고, 지금은 렌더 결과가 이 비트와 무관하다",
         "doc": "docs/re/tex-format.md §3.1"},
        "추정",
        [ev("corpus", "설치 projects 129개 · 사이드카 짝 358쌍 대응 전수"),
         ev("binary", "wallpaper64.exe .text 전수 바이트 스캔 — test byte [reg+4], 0x10 0건"),
         ev("script", "scripts/spec/check_tex_format_map.py")]))

    entries.append(E(
        "format.tex.texs.fieldLayout",
        {"position": "TEXB 섹션 **바로 뒤**(엔진 섹션 루프는 앞에서부터 마법값을 읽는다). "
                     "Waple 은 파일 꼬리에서 역방향 스캔한다 — 결과는 같지만 위치는 계산 가능하다",
         "order": ["'TEXS000N' + NUL", "i32 frameCount",
                   "i32 gifWidth, i32 gifHeight — **버전 3 이상만**. "
                   "v1/v2 는 헤더 imageWidth/imageHeight 를 그대로 쓴다(엔진 기본값)",
                   "frameCount × 32B 레코드"],
         "record": ["i32 imageId (아틀라스 페이지 = mips 인덱스)", "f32 frametime",
                    "지오메트리 6개 = x, y, width, widthY, heightX, height "
                    "— **v1 은 i32, v2 이상은 f32**(레코드 크기는 모두 32B)"],
         "engineNormalizesUV": "엔진은 지오메트리를 저장할 때 그 imageId 의 **mip0 alloc(=패딩) 크기**로 "
                               "나눠 0..1 UV 로 만든다(x/w, y/h, width/w, widthY/h, heightX/w, height/h). "
                               "imgW/imgH 가 아니라 decode dims 가 분모다",
         "wapleNote": "Waple TexFrame 은 픽셀 좌표를 그대로 들고 주석에 '좌표는 imgW×imgH 이미지 픽셀 공간' "
                      "이라고 적어 뒀다. 엔진 기준 분모는 decode dims 라서 주석이 어긋난다. "
                      "다만 실제 소비처(keepFullAtlas 경로)가 decode dims 텍스처를 쓰므로 결과는 일치한다",
         "versionDistribution": corpus["texs"],
         "parseEndsExactlyAtEOF": corpus["texsEndsAtEOF"],
         "noTexsFilesEndAtTexbEnd": corpus["texbEndIsEOForTEXS"],
         "tailIsVariantSection": "TEXS 도 없고 꼬리가 남는 파일은 전부 조건 변형 텍스처다"
                                 f" — variantCount>0 여부 {corpus['tailHasVariants']}"},
        "확정",
        [ev("binary", "wallpaper64.exe FUN_14015e1d0(TEXS 리더) 디컴파일",
            "version==1 분기에서 (float)(int)로 캐스팅 — v1 지오메트리가 i32 라는 뜻"),
         ev("corpus", f"{corpus['total']}개 전수 — TEXS 를 TEXB 끝에서 이어 읽어 파스 끝이 EOF 와 일치하는지 검사"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.texs.halfScalePath",
        {"observation": "엔진은 TEXB 리더가 특정 코드(1)를 돌려주면 모든 TEXS 프레임 지오메트리 6개를 "
                        "0.5 배 한다",
         "constants": "곱하는 값은 .rdata 0x140492dd0 / 0x140492dd4 = 둘 다 정확히 0.5f",
         "unknown": "TEXB 리더가 그 코드를 언제 돌려주는지는 확인하지 못했다(절반 해상도 로드 경로로 추정). "
                    "코퍼스에서 재현 조건을 못 잡았다",
         "wapleImpact": "Waple 에는 대응 경로가 없다. 조건이 밝혀지기 전까지는 무시해도 무방하나, "
                        "스프라이트 UV 가 절반으로 어긋나는 케이스가 보고되면 여기부터 볼 것"},
        "보고",
        [ev("binary", "wallpaper64.exe FUN_14015e580 — iVar9==1 일 때 프레임 레코드 +8..+0x1f 을 0.5 배"),
         ev("binary", ".rdata 0x140492dd0/0x140492dd4 원시 바이트 00 00 00 3f = 0.5f")]))

    entries.append(E(
        "format.tex.flags.maskBits",
        {"bits": [20, 21, 22, 23], "counts": {k: v for k, v in corpus["flagbits"].items()
                                              if k in ("20", "21", "22", "23")},
         "observedCombinations": [k for k in corpus["flags"] if int(k) >> 20],
         "note": "연속한 4비트 니블이고 관측 파일이 전부 이펙트 마스크(*_mask_*.tex)다. "
                 "비트필드인지 작은 enum 인지 코퍼스만으로는 구분되지 않는다"},
        "추정",
        [ev("corpus", "코퍼스 관측 — 파일명 패턴 외 근거 없음")]))

    entries.append(E(
        "format.tex.format.enum",
        {"0": "rgba8888", "1": "rgb888", "2": "rgb565", "3": "ETC1", "4": "dxt5(BC3)",
         "5": "ETC2", "6": "dxt3(BC2)", "7": "dxt1(BC1)", "8": "rg88", "9": "r8",
         "10": "rg1616f", "11": "r16f", "12": "bc7", "13": "rgba1010102",
         "14": "rgba16161616f", "15": "rgb161616f", "16": "(미상 — 어느 표에도 없음)",
         "17": "rgba16161616", "18": "rgb161616", "19": "rgba16161616S", "20": "rgb161616S",
         "21": "rgba8888s",
         "notInThisMap": ["rgb_backbuffer", "rgba_backbuffer"],
         "corpusDistribution": corpus["fmt"],
         "corpusBytesPerPixel": corpus["bpp"]},
        "확정",
        [ev("binary", "wallpaper64.exe 0x1401e54bf — 이름→enum std::map 정적 초기화 19항목 직독",
            "rgba8888=0/rgb888=1 은 rsp 상대 저장이라 원시 바이트(48 c7 44 24 30 08 / c7 44 24 68 01)로 확인"),
         ev("binary", "resourcecompiler64.exe FUN_140063c70 — -f ETC2→5 / ETC1→3 / RGBA8→0"),
         ev("binary", "-tex 차분 컴파일: dxt5→4 dxt3→6 dxt1→7 rg88→8 r8→9 bc7→12 rgba8888→0"),
         ev("corpus", f"{corpus['total']}개 관측 포맷은 0/4/6/7/8/9 뿐"),
         ev("script", S)]))

    tm = cli.get("transcodeMatrix") or {}
    entries.append(E(
        "format.tex.transcode.isDecoder",
        {"claim": "-transcode 는 BC(DXT1/3/5) 입력을 RGBA8888(format 0)로 **디코드**한다",
         "default": "출력 format=0, 크기는 imageWidth×imageHeight(패딩 크롭 완료), LZ4 재압축",
         # [2026-08-01] 대체 대상이던 format.tex.transcodeIsNotDecoder 는 이미 제거되고
        # format.tex.transcodeDecodes 로 교체됐다. 링크가 끊겨 있던 것을 검증기가 잡았다.
        "supersedes": "spec/formats/tex.json format.tex.transcodeDecodes — "
                       "그 5표본은 전부 format 0/8/9(= 아래 통과 조건에 걸리는 포맷)였다. "
                       "관측 자체는 정확했고, 표본이 BC 포맷을 안 담았을 뿐이다",
         "witness": {"in": cli.get("transcodeSourceHeader"), "outDefault": tm.get("default")},
         "passthrough": cli.get("transcodePassthrough"),
         "passthroughRule": ["무조건 통과: format == 8(rg88) · format == 9(r8) · texDepth > 1 · flags & 0x20",
                             "조건부 통과: format == 1(rgb888) 은 (-c force 이면서 -f 가 ETC1/ETC2 로 "
                             "풀린) 경우가 **아닐 때만** 통과한다 — 원식 `fmt==1 && (!force || !etcSelected)`",
                             "그 외(0/4/6/7)는 변환한다. 코퍼스에 format 1 파일은 0개라 조건부 분기는 "
                             "디컴파일 근거뿐이고 실물로는 못 밟았다"]},
        "확정",
        [ev("binary", "resourcecompiler64.exe -transcode 실행 — DXT5 입력 format 4→0, mip0 dec 65536→262144"),
         ev("binary", "FUN_140063c70 통과 조건 디컴파일 — iStack_728∈{1,8,9} / 1<depth / flags&0x20"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.transcode.args",
        {"modes": {"-tex": "텍스처 인코더(1)", "-mdl": "모델 인코더(2)", "-pkg": "패키지 인코더(3)",
                   "-transcode": "텍스처 트랜스코더(4)", "-generateDepthMap": "깊이맵 생성(별도 경로)"},
         "-transcode": {"-i": "입력 .tex", "-o": "출력 .tex",
                        "-f": "ETC1|ETC2|RGBA8 **셋뿐**(대소문자 구분). 그 외/미지정은 RGBA8 취급",
                        "-c": "force 하나뿐. -f 없이 -c force 만 주면 기본이 ETC2 가 된다",
                        "-shrink N": "mip 체인을 N 배 축소한 레벨에서 시작(헤더 texW/H·imgW/H 는 갱신 안 됨)",
                        "-maxmipmaps N": "mip 체인을 N 레벨로 자른다"},
         "-tex": {"-i": "입력 이미지", "-o": "출력 .tex", "-nolz4": "LZ4 생략",
                  "note": "-f/-c/-shrink/-maxmipmaps 는 -tex 가 읽지 않는다(트랜스코더 전용)"},
         "-generateDepthMap": ["-src", "-dst", "-blurSize", "-outlineCompensationPercent",
                               "-autoContrast", "-invertDepth", "-quality"],
         "-pngExport": {"args": ["-src", "-out"],
                        "status": "인자 파싱은 확인했지만(main 디컴파일) .tex/.pkg/디렉터리 어느 "
                                  "입력으로도 산출물이 나오지 않았다",
                        "producedFiles": cli.get("pngExportProducedFiles")},
         "other": ["-dlc(-generateDepthMap 분기)"],
         "⚠️ 절대경로 함정": "-tex 에 **절대경로**를 -i 로 주면 무한 루프에 빠진다(실측 22분 스핀, "
                          "CPU 1353s, 출력 0). 같은 파일을 cwd 상대경로로 주면 즉시 끝난다. "
                          "자동화는 반드시 cwd + 상대경로 + timeout 으로 호출할 것",
         "measured": {k: {"format": v and v["format"], "mipDims": v and v["mipDims"][:3]}
                      for k, v in tm.items()},
         "goldenOracle": "임의의 BC .tex → `-transcode -i x.tex -o y.tex` → y 의 mip0 을 LZ4 해제하면 "
                         "WE 자신이 디코드한 straight-alpha RGBA8888(image dims)이다. "
                         "4,680개 텍스처 전부에 쓸 수 있는 골든 오라클"},
        "확정",
        [ev("binary", "resourcecompiler64.exe FUN_140064fa0(main) 디컴파일 — 모드 인덱스 1..4 분기와 인자 소비처"),
         ev("binary", "FUN_140063c70 — param_3 vs 'force', param_4 vs 'ETC2'/'ETC1'/'RGBA8'"),
         ev("binary", "실행 검증: -f ETC1→format 3, -f ETC2→format 5, -c force→format 5"),
         ev("script", S)]))

    ok = [r for r in oracle if r.get("status") == "exact"]
    entries.append(E(
        "format.tex.bcDecodeRounding",
        {"we": {"565to8": "비트 복제 — (r<<3)|(r>>2), (g<<2)|(g>>4), (b<<3)|(b>>2)",
                "colorLerp": "floor — (x*(3-t) + y*t) / 3",
                "bc3AlphaLerp8": "반올림 — ((7-i)*a0 + i*a1 + 3) / 7",
                "bc3AlphaLerp6": "반올림 — ((5-i)*a0 + i*a1 + 2) / 5"},
         "waple": {"565to8": "c*255/31 (·255/63)", "bc3AlphaLerp": "floor"},
         "result": f"위 규약으로 {len(ok)}/{len(oracle)} 표본이 WE 트랜스코더 출력과 **바이트 동일**",
         "wapleRuleMaxChannelDelta": sorted({r["wapleRuleMaxChannelDelta"] for r in oracle
                                             if "wapleRuleMaxChannelDelta" in r}),
         "colorLerpRounding": "포맷별 첫 표본을 반올림 lerp 로 다시 디코드했을 때의 불일치 바이트: "
                              + ", ".join(f'fmt{r["srcFormat"]}→{r["roundedColorLerpByteDiffs"]}B'
                                          for r in oracle
                                          if "roundedColorLerpByteDiffs" in r)
                              + ". 0B 인 표본은 그 이미지가 4색 보간 슬롯을 안 쓴 것뿐이고, "
                                "판별력이 있는 표본에서는 전부 floor 만 일치한다",
         "caveat": "이 오라클은 resourcecompiler64 의 **CPU** 디코더다. Waple 의 nativeBC 경로는 "
                   "BC 블록을 Metal 에 그대로 올려 **하드웨어**가 디코드한다. CPU 경로만 여기에 맞추면 "
                   "Waple 내부에서 CPU/GPU 결과가 서로 어긋나므로, 적용 전에 GPU 파리티 판단이 먼저다",
         "samples": oracle},
        "확정",
        [ev("binary", "resourcecompiler64.exe -transcode 출력 vs 파이썬 미러 픽셀 대조"),
         ev("corpus", "코퍼스 BC 텍스처 표본(format 4/6/7)"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.texb.variantCount",
        {"field": "TEXB0004 의 imageFormat 다음 i32 = **조건 변형 항목 수**(0 이면 없음)",
         "entry": "i32 ×3 + NUL 종단 JSON — 그 수만큼 연속한다",
         "corpusDistribution": corpus["variantCount"],
         "wapleModel": "isVideoMp4 불리언으로 보고 건너뛴 뒤 패턴 휴리스틱으로 블록을 스캔한다",
         "modelMismatchOnCorpus": corpus["variantModelMismatch"],
         "note": f"카운트 기반 정답과 Waple 휴리스틱이 코퍼스 TEXB0004 전건에서 동일한 결과를 낸다"
                 f"(불일치 {corpus['variantModelMismatch']}건) — 모델은 틀렸지만 출력은 같다"},
        "확정",
        [ev("binary", "wallpaper64.exe FUN_14015c8d0 — 이 i32 를 루프 횟수로 쓴다(0 이면 루프 없음)"),
         ev("corpus", f"TEXB0004 {corpus['texb'].get('TEXB0004')}개 두 방식 대조"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.container.versionDistribution",
        {"texb": corpus["texb"], "imageFormat": corpus["imageFormat"],
         "imageCount": corpus["imageCount"], "mip0ChainLength": corpus["mipCount"],
         "depthValues": corpus["depth"],
         "layout": {"TEXB0001": "imageCount 없음(1 고정), isLZ4/dec 없음",
                    "TEXB0002": "isLZ4 + decompressedSize 추가",
                    "TEXB0003": "imageFormat(i32) 추가",
                    "TEXB0004": "variantCount(i32) 추가"}},
        "확정",
        [ev("corpus", f"{corpus['total']}개 전수"),
         ev("binary", "wallpaper64.exe FUN_14015c8d0 버전 분기(<1 / <3 / <4)"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.texi.previewColor",
        {"field": "TEXI0001 헤더 마지막 u32 — 바이트 순 R,G,B,A",
         "measured": cli.get("previewColor"),
         "corpusMostCommon": "0xff000000(불투명 검정)이 최빈값",
         "notAverage": "그라디언트(산술 평균 126,126,126) 입력이 평균값을 내지 않았고 "
                       "무채색(128,128,128) 입력은 0 이 됐다 — 단순 평균이 아니다",
         "consumer": "렌더 경로 소비처를 찾지 못했다. 에디터/UI 힌트로 보이며 Waple 영향은 미상"},
        "보고",
        [ev("binary", "resourcecompiler64.exe -tex 단색 PNG 컴파일 — red→0xff0000ff, blue→0xffff0000"),
         ev("binary", "wallpaper64.exe FUN_14015c760 — TEXI ver>0 일 때만 읽는 필드")]))

    compiler_keys = [k for k, n in (ks.get("resourcecompiler64.exe") or {}).items() if n]
    entries.append(E(
        "format.tex.texJson.keys",
        {"files": tj["files"],
         "observedInCorpus": {k: v["count"] for k, v in tj["keys"].items()},
         "observedValues": {k: v["values"] for k, v in tj["keys"].items()},
         "acceptedByCompiler": compiler_keys,
         "measuredHeaderEffect": cli.get("texJsonKeyToFlagBit"),
         "deadKeys": {"nonpoweroftwo": "resourcecompiler64/wallpaper64 문자열 표에 없다. "
                                       "wallpaperui.exe(에디터) 템플릿에만 있다 — 컴파일 무영향",
                      "srgb": "세 바이너리 어디에도 독립 토큰이 없다",
                      "spritesheet": "독립 토큰 없음(spritesheetsequences / spritesheetrefreshsync 의 부분문자열일 뿐)"},
         "binaryTokenCounts": ks,
         "note": "format 값에 '+' 접미사(dxt5n+)가 코퍼스에 6건 있는데 컴파일러는 dxt5n 과 동일하게 처리한다"},
        "확정",
        [ev("file", f".tex-json {tj['files']}개 전수 수확(설치 assets/projects + 워크샵)"),
         ev("binary", "세 바이너리 문자열 표 토큰 존재 검사"),
         ev("binary", "-tex 차분 컴파일로 헤더 변화 측정"),
         ev("script", S)]))

    entries.append(E(
        "format.tex.slice3d",
        {"layout": "flags |= 0x40, texW/texH = 슬라이스 한 장 크기, imgW = texW × depth, "
                   "imgH = texH, 그리고 헤더에 i32 depth 가 추가된다",
         "mipRecordLayout": "mip 레코드에도 depth 가 하나 더 들어간다 — "
                            "i32 w | i32 h | **i32 depth** | i32 isLZ4 | i32 dec | i32 comp | payload. "
                            "Waple 이 'lut/* 는 mip 에 여분 int 가 있어 parseMip 실패' 라고 적어 둔 필드가 이것이다",
         "mipParseBefore": "여분 필드를 모르면 코퍼스 28개(LUT)의 mip 테이블이 전건 파스 실패한다",
         "measured": cli.get("slice3dHeader"),
         "corpus": "설치 assets/materials/lut/*.tex 28개 — 전부 32×32×32 LUT(imgW=1024, depth=32)",
         "transcodeRefuses": "depth > 1 이면 -transcode 가 바이트 그대로 복사한다",
         "wapleImpact": "Waple 은 이 텍스처를 1024×32 2D 로 읽는다(TEXB 스캔 덕에 파스는 성공). "
                        "3D LUT 로 샘플링해야 하는 소비처가 있으면 depth 를 알아야 한다"},
        "확정",
        [ev("binary", "-tex + .tex-json {\"slice3d\":true} 차분 컴파일 — flags 0x40, depth 32 삽입"),
         ev("asset", "assets/materials/lut/aliens_2.tex — flags 0x42, depth 32, TEXB@50"),
         ev("script", S)]))

    return specfmt.doc(S, entries, extra={"measuredAt": {"corpusTexFiles": corpus["total"],
                                                         "texJsonFiles": tj["files"]}})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-cli", action="store_true", help="WE 실행 없이 코퍼스/문자열만")
    ap.add_argument("--oracle-limit", type=int, default=4)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()

    m = {"corpus": measure_corpus()}
    picks = m["corpus"].pop("_picks")
    print(f"corpus: {m['corpus']['total']} tex, errors={m['corpus']['errors']}", flush=True)
    m["texjson"] = measure_texjson()
    m["keyStrings"] = measure_compiler_key_strings()
    print(f"tex-json: {m['texjson']['files']}", flush=True)
    if not a.no_cli and os.path.exists(RC):
        tmp = tempfile.mkdtemp(prefix="texdeep_")
        try:
            m["cli"] = measure_cli(tmp, picks)
            print("cli done", flush=True)
            m["oracle"] = measure_oracle(tmp, a.oracle_limit)
            print(f"oracle: {sum(1 for r in m['oracle'] if r.get('status') == 'exact')}"
                  f"/{len(m['oracle'])} exact", flush=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    specfmt.dump(build(m), a.out)
    print("wrote", a.out, flush=True)


if __name__ == "__main__":
    main()
