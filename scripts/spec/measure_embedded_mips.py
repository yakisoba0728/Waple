"""임베디드(PNG/JPEG/GIF) 텍스처의 저장 mip 체인 전수 측정 — spec/formats/tex-embedded-mips.json.

왜 이 측정이 필요했나. `TexImage.swift` 주석이 "PNG/JPEG/임베디드(단일 인코딩 이미지라
저장 mip 자체가 없음)" 라고 단언하고, 그 전제로 `.embeddedImage` 분기에서 파스한 mipChain 을
버리고 있었다. 감사가 이걸 거짓 전제로 지목했고, 같은 파일의 다른 실측 주석은 "코퍼스 임베디드
35개" 라고 적혀 있었다. 35 와 감사의 2,391 은 같은 모집단일 수 없다 — 그것부터 갈랐다.

결과: 35 는 **설치 assets 한정** 수치였고(워크샵 scene.pkg 미포함), 전수는 796 이다.
그리고 "저장 mip 이 없다" 는 거짓이다 — 701개가 mipCount>1 이고 level>0 페이로드는
전부 실물 축소 이미지다.

spec/README.md 규칙 5(부정 결론은 표본 설계를 먼저 검사한다)에 따라 **양성 대조**를 내장한다:
임베디드 텍스처를 하나도 못 찾으면 필터가 깨진 것이지 코퍼스가 비어 있는 게 아니다.

usage:
    python scripts/spec/measure_embedded_mips.py
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_tex_deep as T
import specfmt

OUT = os.path.join("spec", "formats", "tex-embedded-mips.json")

# FreeImage enum(TEXB v3+ imageFormat). -1 = raw(texFormat 사용).
ENCODED = {2: "JPEG", 13: "PNG", 25: "GIF", 35: "MP4"}


def png_dims(p):
    """IHDR 은 시그니처 직후 고정 위치(8 길이 + 4 'IHDR' + w,h)."""
    if len(p) < 24 or p[:8] != b"\x89PNG\r\n\x1a\n" or p[12:16] != b"IHDR":
        return None
    return struct.unpack_from(">2I", p, 16)


def jpeg_dims(p):
    """SOF0/1/2/3/5/6/7/9/10/11/13/14/15 세그먼트의 (h, w) → (w, h)."""
    if len(p) < 4 or p[0] != 0xFF or p[1] != 0xD8:
        return None
    i = 2
    while i + 4 <= len(p):
        if p[i] != 0xFF:
            i += 1
            continue
        m = p[i + 1]
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:      # 길이 없는 마커
            i += 2
            continue
        ln = struct.unpack_from(">H", p, i + 2)[0]
        if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            if i + 9 > len(p):
                return None
            h, w = struct.unpack_from(">2H", p, i + 5)
            return (w, h)
        if m == 0xDA:                                    # 스캔 시작 — SOF 는 이미 지났어야 한다
            return None
        i += 2 + ln
    return None


def gif_dims(p):
    if len(p) < 10 or p[:3] != b"GIF":
        return None
    return struct.unpack_from("<2H", p, 6)


DIMS = {2: jpeg_dims, 13: png_dims, 25: gif_dims}


def scan():
    r = {
        "total": 0, "parseFail": 0, "encodedTotal": 0,
        "perFormat": collections.Counter(),
        "crosstab": collections.Counter(),          # (버킷, mip>1) → 수
        "chainLen": collections.Counter(),
        "levelOK": 0, "levelBadSig": 0, "levelLZ4Fail": 0,
        "halvingOK": 0, "halvingBad": 0,
        "mip0DimsOK": 0, "mip0DimsBad": 0,
        "lz4Compressed": 0,
        "multiImageEncoded": 0,
        "encodedPkgs": set(), "rawPkgs": set(),
        "mismatchSamples": [],
    }
    for src, _name, b in T.iter_tex():
        r["total"] += 1
        try:
            d = T.parse_tex(b)
        except Exception:
            r["parseFail"] += 1
            continue
        fmt = d["imageFormat"]
        enc = fmt in ENCODED
        if enc:
            r["encodedTotal"] += 1
            r["perFormat"][ENCODED[fmt]] += 1
            if d["imageCount"] > 1:
                r["multiImageEncoded"] += 1
        if not d["mips"] or not d["mips"][0]:
            continue
        mc = len(d["mips"][0])
        bucket = ENCODED.get(fmt, "raw/BC" if fmt in (None, -1) else f"fmt{fmt}")
        r["crosstab"][(bucket, mc > 1)] += 1
        if mc <= 1:
            continue
        (r["encodedPkgs"] if enc else r["rawPkgs"]).add(src)
        if not enc or fmt not in DIMS:
            continue
        r["chainLen"][mc] += 1
        if d["mips"][0][0]["lz4"]:
            r["lz4Compressed"] += 1
        # mip0: 디코드 치수가 헤더 imgW/imgH 와 같아야 makeMipmappedTexture 의 레벨 진행 검증을 통과한다.
        try:
            got0 = DIMS[fmt](T.mip_bytes(b, d, level=0))
        except Exception:
            got0 = None
        if got0 == (d["imgW"], d["imgH"]):
            r["mip0DimsOK"] += 1
        else:
            r["mip0DimsBad"] += 1
        # level>0: 실제로 꺼내 시그니처와 치수를 본다. 여기가 "저장 mip 이 없다" 를 가르는 지점.
        for lv in range(1, mc):
            try:
                pay = T.mip_bytes(b, d, level=lv)
            except Exception:
                r["levelLZ4Fail"] += 1
                continue
            got = DIMS[fmt](pay)
            if got is None:
                r["levelBadSig"] += 1
                continue
            r["levelOK"] += 1
            want = (max(1, d["imgW"] >> lv), max(1, d["imgH"] >> lv))
            if got == want:
                r["halvingOK"] += 1
            else:
                r["halvingBad"] += 1
                if len(r["mismatchSamples"]) < 8:
                    r["mismatchSamples"].append(
                        {"tex": os.path.basename(src) + ":" + _name, "level": lv,
                         "got": list(got), "want": list(want)})
    return r


def build(r):
    ws = sorted(p for p in r["encodedPkgs"] if "workshop" in p.replace("\\", "/"))
    loose = sorted(p for p in r["encodedPkgs"] if "workshop" not in p.replace("\\", "/"))
    scan_ev = specfmt.ev("corpus", f"{r['total']}개 .tex 전수(워크샵 scene.pkg + 설치 assets)",
                         "scripts/spec/measure_embedded_mips.py")
    code_ev = specfmt.ev("file", "Sources/WapleCore/TexImage.swift",
                         "종전 .embeddedImage 분기가 파스한 mipChain 을 버렸다")

    enc_multi = sum(v for k, v in r["crosstab"].items()
                    if k[0] in ("PNG", "JPEG", "GIF") and k[1])

    return [
        specfmt.entry("format.tex.embedded.hasStoredMips", {
            "claimRefuted": "임베디드(PNG/JPEG) 텍스처는 단일 인코딩 이미지라 저장 mip 이 없다",
            "truth": "WE 는 레벨마다 **독립 인코딩 파일**을 TEXB 레벨 레코드에 넣는다",
            "encodedTextures": r["encodedTotal"],
            "perFormat": dict(r["perFormat"]),
            "withMultipleMips": enc_multi,
            "chainLengthDistribution": dict(sorted(r["chainLen"].items())),
            "levelPayloads": {
                "decodable": r["levelOK"],
                "badSignature": r["levelBadSig"],
                "lz4Failure": r["levelLZ4Fail"],
            },
            "positiveControl": "임베디드 텍스처를 0개 찾으면 필터가 깨진 것이다 — "
                               f"실제 {r['encodedTotal']}개 관측(대조 성립)",
        }, "확정", [scan_ev, code_ev]),

        specfmt.entry("format.tex.embedded.levelDims", {
            "rule": "레벨 L 의 디코드 치수 = (max(1, imgW>>L), max(1, imgH>>L))",
            "exactMatches": r["halvingOK"],
            "mismatches": r["halvingBad"],
            "mismatchSamples": r["mismatchSamples"],
            "mip0EqualsHeader": {"ok": r["mip0DimsOK"], "bad": r["mip0DimsBad"]},
            "whyItMatters": "SceneRendererResources.makeMipmappedTexture 가 "
                            "lv.width == max(1, first.width >> i) 를 검증한다. "
                            "치수가 어긋나면 체인을 통째로 거부하고 단일 레벨로 폴백한다.",
            "noCropNeeded": "인코딩 이미지는 BC 블록 패딩이 없어 alloc==orig — "
                            "raw/DXT 경로의 레벨별 크롭 규약이 필요 없다.",
        }, "확정", [scan_ev]),

        specfmt.entry("format.tex.embedded.compression", {
            "lz4CompressedAmongMultiMip": r["lz4Compressed"],
            "note": "임베디드 인코딩 이미지는 이미 압축 포맷이라 WE 가 LZ4 를 다시 걸지 않는다. "
                    "다만 코드 경로는 mipBytes 를 거치므로 압축본이 와도 동작한다.",
        }, "확정", [scan_ev]),

        specfmt.entry("format.tex.embedded.singleImage", {
            "encodedWithImageCountGreaterThan1": r["multiImageEncoded"],
            "consequence": "TexDecoder.swift 의 '임베디드 이미지 페이지는 단일' 가정이 "
                           "코퍼스에서 반례 0건으로 성립한다. rgbaLevels 의 "
                           "imageCount<=1 가드가 임베디드를 걸러내지 않는다.",
        }, "확정", [scan_ev]),

        specfmt.entry("format.tex.embedded.reach", {
            "workshopScenes": len(ws),
            "installedAssets": len(loose),
            "installedAssetSamples": [p.replace("\\", "/").split("wallpaper_engine/")[-1]
                                      for p in loose[:8]],
            "workshopIdSamples": [os.path.basename(os.path.dirname(p)) for p in ws[:12]],
            "rawBCPackagesAlreadyWorking": len(r["rawPkgs"]),
            "symptom": "축소 렌더 시 mip 없이 mip0 를 샘플 → 지글거림(에일리어싱). "
                       "QuadShaders/GLSLTranslator 는 이미 mip_filter::linear 라 "
                       "체인만 올리면 즉시 샘플된다.",
        }, "확정", [scan_ev,
                    specfmt.ev("file", "Sources/WapleRender/QuadShaders.swift",
                               "constexpr sampler s(filter::linear, mip_filter::linear, …)")]),

        specfmt.entry("format.tex.embedded.staleCommentOrigin", {
            "what": "TexImage.swift 의 '코퍼스 임베디드 35개' 는 **설치 assets 한정** 수치였다",
            "assetsOnly": 35,
            "corpusWide": r["encodedTotal"],
            "why": "그 측정(2026-07-09)은 assets 의 splash_*/lut/* 서브레이아웃을 보는 게 "
                   "목적이라 워크샵 scene.pkg 를 돌지 않았다. 수치는 맞았고 "
                   "'코퍼스' 라는 말이 틀렸다.",
            "lesson": "측정값을 주석에 적을 때 **표본 범위**를 함께 적어야 한다. "
                      "범위 없는 숫자는 나중에 전수 수치로 오독된다.",
        }, "확정", [scan_ev, code_ev]),
    ]


def main():
    r = scan()
    print(f"전체 .tex {r['total']}개 (파스 실패 {r['parseFail']})")
    print()
    print("=== 양성 대조 ===")
    print(f"  임베디드 텍스처: {r['encodedTotal']}개 {dict(r['perFormat'])}")
    if r["encodedTotal"] == 0:
        print("  !! 0 — 필터가 깨졌다. 부정 결론을 내면 안 된다.")
        return 1
    print()
    print("=== 교차표 ===")
    print(f"  {'버킷':<10} {'mip==1':>8} {'mip>1':>8}")
    for bk in sorted({k[0] for k in r["crosstab"]}):
        print(f"  {bk:<10} {r['crosstab'][(bk, False)]:>8} {r['crosstab'][(bk, True)]:>8}")
    print()
    print("=== level>0 실검증(임베디드) ===")
    print(f"  디코드 가능 {r['levelOK']} · 시그니처 불일치 {r['levelBadSig']} · LZ4 실패 {r['levelLZ4Fail']}")
    print(f"  치수 == 1/2^L: {r['halvingOK']} · 불일치 {r['halvingBad']}")
    print(f"  mip0 치수 == 헤더: {r['mip0DimsOK']} · 불일치 {r['mip0DimsBad']}")
    ws = [p for p in r["encodedPkgs"] if "workshop" in p.replace("\\", "/")]
    print(f"  영향 범위: 워크샵 씬 {len(ws)}종 + 설치 assets {len(r['encodedPkgs']) - len(ws)}개")

    specfmt.dump(specfmt.doc("scripts/spec/measure_embedded_mips.py", build(r)), OUT)
    print(f"\n기록: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
