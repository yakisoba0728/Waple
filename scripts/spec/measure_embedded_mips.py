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
            "installedAssetPaths": [p.replace("\\", "/").split("wallpaper_engine/")[-1] for p in loose],
            # 표본이 아니라 **전량**이다 — 골든 대조가 "예상한 씬만 바뀌었는가" 를 물으려면
            # 기대 집합이 완전해야 한다. 이 목록 밖의 씬이 바뀌면 그건 조사 대상이다.
            "workshopIds": sorted({os.path.basename(os.path.dirname(p)) for p in ws}),
            "rawBCPackagesAlreadyWorking": len(r["rawPkgs"]),
            "symptom": "축소 렌더 시 mip 없이 mip0 를 샘플 → 지글거림(에일리어싱). "
                       "QuadShaders/GLSLTranslator 는 이미 mip_filter::linear 라 "
                       "체인만 올리면 즉시 샘플된다.",
        }, "확정", [scan_ev,
                    specfmt.ev("file", "Sources/WapleRender/QuadShaders.swift",
                               "constexpr sampler s(filter::linear, mip_filter::linear, …)")]),

        specfmt.entry("format.tex.embedded.mipDarkeningIsAlphaCoverage", {
            "observation": "mip 체인을 올리자 일부 씬의 평균 밝기가 크게 떨어졌다. "
                           "macOS 검증에서 3394601417 이 luma 0.0600 -> 0.0116(0.194배)로 "
                           "GT structureLoss 게이트를 발화시켰다.",
            "verdict": "버그가 아니다. **WE 자신이 저장한 픽셀**이 그렇다.",
            "measurement": "코퍼스 25씬 · 임베디드 mip>=3 텍스처 140개를 파이썬으로 직접 "
                           "디코드해 레벨별 밝기를 쟀다(알파 가중 / 순수 색 / 알파 분리).",
            "result": {
                "rgbOnlyRatio": "레벨을 내려가도 **색은 안 어두워진다**(중앙 ~0.99)",
                "alphaRatio": "떨어지는 건 알파(커버리지) 쪽 — 최저 0.038",
                "alphaDrivenVsColorDriven": "절반 아래로 떨어진 사례의 주도 요인: 알파 11 · 색 0",
                "extreme": "3300031038/materials/Paper Effect.tex 는 WE 자신의 L3 가 "
                           "L0 대비 0.038배(rgb 0.989 · alpha 0.038)",
            },
            "why": "투명 배경 위 가는 밝은 선/스파스 스프라이트를 축소하면 커버리지가 평균된다. "
                   "색은 유지되고 알파가 준다 — 밉맵의 정의 그대로다. "
                   "종전 Waple 은 mip0 만 샘플해 그 선들이 축소돼도 살아남았다(에일리어싱).",
            "consequenceForGate": "GT 의 structureLoss(기준선 대비 0.5배 미만 = 하드 실패)는 "
                                  "**알파 가중 밝기**를 본다. 올바른 밉맵 적용이 그 지표를 "
                                  "정당하게 절반 아래로 떨어뜨릴 수 있다. "
                                  "즉 이 발화는 오탐이 아니라 **의도된 변화의 정확한 검출**이고, "
                                  "대응은 게이트 완화가 아니라 **재베이스라인**이다.",
            "doNotWeakenGate": "이 사례를 이유로 structureLoss 문턱을 낮추지 마라. "
                               "게이트는 제 일을 했다 — 큰 변화를 세우고 사람이 판정했다. "
                               "문턱을 낮추면 '화면이 사라지는' 진짜 사고를 놓친다.",
        }, "확정", [specfmt.ev("corpus", "임베디드 mip>=3 텍스처 140개 레벨별 PNG 디코드",
                               "scripts/spec/measure_mip_luma.py — 알파/색 분리 측정"),
                    specfmt.ev("file", "Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift",
                               "structureLoss 판정부"),
                    specfmt.ev("file", "macOS 세션 2026-08-01 검증 — 3394601417 발화")]),

        specfmt.entry("format.tex.embedded.reachCorpusBasis", {
            "issue": "reach.workshopIds(146종)는 **윈도우 코퍼스 162씬** 기준이다. "
                     "macOS 검증 코퍼스는 170씬이라 7종이 목록에 없다.",
            "missingFromList": ["1412044563", "2593802559", "2809885105", "2881558311",
                                "2947302287", "3047405322", "3394601417"],
            "verified": "이 7종은 윈도우 워크샵 디렉터리에 **존재하지 않는다**(전수 확인). "
                        "코드 누수가 아니라 측정 표본 범위 차이다. "
                        "예: 3394601417 은 임베디드 mip>1 PNG 13개 보유(macOS 실측).",
            "consequence": "검증 스크립트의 '기대 집합 밖' 판정은 이 목록이 완전하다고 "
                           "가정한다. 목록이 부분집합이면 정당한 변화가 '조사 대상' 으로 "
                           "잘못 뜬다 — 실제로 8건 중 7건이 그랬다.",
            "fixApplied": "verify-embedded-mips.sh 가 이제 기대 집합을 **실행 시점에 코퍼스를 "
                          "직접 스캔해** 산출한다(정적 목록 미사용). 윈도우에서 대조 검증: "
                          "그 파서가 이 생성기와 동일한 146종을 낸다(차집합 0). "
                          "macOS 170씬 코퍼스에서는 153종이 나와 7종 오탐이 사라진다.",
            "guard": "코퍼스 산출이 0종이면 스크립트가 즉시 실패한다 — 파서가 깨진 채로 "
                     "'기대 밖 변화 0' 이라는 무의미한 통과를 내지 않도록.",
        }, "확정", [specfmt.ev("corpus", "윈도우 워크샵 431960 디렉터리 존재 여부 전수 대조"),
                    specfmt.ev("file", "macOS 세션 2026-08-01 — 기대 집합 밖 8종 분석")]),

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
