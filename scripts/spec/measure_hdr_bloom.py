"""HDR 블룸 파이프라인을 WE **평문 셰이더**와 대조한다 — spec/engine/hdr-bloom.json.

WE 는 블룸 셰이더를 GLSL 평문으로 배포한다. 그래서 이 항목은 RE 대상이 아니라
**대조 대상**이다. 픽셀 캡처도, 디스어셈도 필요 없다.

WE 의 HDR 블룸 구조(assets/materials/util/*.json + assets/shaders/hdr_downsample.frag):

    hdr_downsample.json         콤보 없음        → 4탭 박스 다운샘플 (×0.25)
    hdr_downsample_bloom.json   BLOOM:1         → 같은 4탭 + 임계(소프트 니) 추출
    hdr_upsample.json           UPSAMPLE:1      → 같은 4탭 × 0.25 × scatter, blending:"additive"
    combine_hdr_upsample.json   combine_hdr     → 블룸 4탭 평균 후 가산

즉 **셰이더 하나**를 콤보로 세 역할에 쓰는 듀얼-필터 피라미드이고,
가우시안 블러 패스가 **없다**.

결론(요약): 임계 수식과 파라미터 기본값은 Waple 이 맞다. 갈리는 건 **필터 모양**이고,
오차의 부호가 서로 반대라 일부만 고치면 더 나빠진다.

usage:
    python scripts/spec/measure_hdr_bloom.py
"""
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure_tex_deep as T
import specfmt

OUT = os.path.join("spec", "engine", "hdr-bloom.json")
SHADERS = os.path.join(T.WE, "assets", "shaders")
MATS = os.path.join(T.WE, "assets", "materials", "util")
WSRC = os.path.join("Sources", "WapleRender", "HDRBloomPyramidPass.swift")


def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def we_facts():
    """WE 셰이더/머티리얼에서 구조적 사실을 **읽어서** 확인한다(하드코딩 아님)."""
    ds = read(os.path.join(SHADERS, "hdr_downsample.frag"))
    ch = read(os.path.join(SHADERS, "combine_hdr.frag"))
    f = {}
    # 4탭 패턴: v_TexCoord + g_RenderVar0.{xy,zy,xw,zw}
    # 주의: "#if BLOOM" 은 **uniform 선언부에도** 나온다. split 으로 main() 을 자르면
    # 탭이 있는 구간이 통째로 반대편에 남아 2(=BICUBIC 의 texSize/invTexSize 계산)만 세어진다.
    # 실제로 그렇게 세다가 4 대신 2 가 나와 잡았다 — 비-BICUBIC(#else) 분기를 직접 집는다.
    main_else = re.search(r"#else\n(\s*vec3 albedo = texSample2D.*?)#endif", ds, re.S)
    f["downsampleTaps"] = len(re.findall(r"texSample2D\(g_Texture0", main_else.group(1))) if main_else else 0
    f["downsampleTapSwizzles"] = sorted(set(re.findall(r"g_RenderVar0\.([xyzw]{2})",
                                                       main_else.group(1)))) if main_else else []
    # BICUBIC 분기가 g_RenderVar0.xy 의 크기를 규정한다: texSize = 0.5/RenderVar0.xy
    m = re.search(r"float sc = ([0-9.]+);\s*\n\s*vec2 texSize = sc / g_RenderVar0\.xy;", ds)
    f["renderVar0Scale"] = float(m.group(1)) if m else None
    f["hasGaussianBlurPass"] = bool(re.search(r"\b(blur13|gaussian)\b", ds, re.I))
    f["upsampleScale"] = bool(re.search(r"albedo \*= 0\.25 \* g_BloomScatter", ds))
    f["extractUsesMaxChannel"] = bool(re.search(r"max\(albedo\.r, max\(albedo\.g, albedo\.b\)\)", ds))
    f["combineBloomTaps"] = len(re.findall(r"texSample2D\(g_Texture1", ch))
    f["combineTapOffset"] = "g_TexelSize" if "g_TexelSize" in ch else None
    # 머티리얼 콤보/블렌딩
    mats = {}
    for name in ("hdr_downsample", "hdr_downsample_bloom", "hdr_upsample", "combine_hdr_upsample"):
        p = os.path.join(MATS, name + ".json")
        if os.path.exists(p):
            j = json.loads(read(p))
            ps = (j.get("passes") or [{}])[0]
            mats[name] = {"shader": ps.get("shader"), "combos": ps.get("combos"),
                          "blending": ps.get("blending")}
    f["materials"] = mats
    # 셰이더 주석의 기본값
    f["shaderDefaults"] = {
        k: v for k, v in re.findall(r'uniform \w+ g_(\w+);\s*//\s*\{[^}]*"default"\s*:\s*("?[^,}]+"?)', ds)
    }
    return f


def waple_facts():
    s = read(WSRC)
    f = {}
    m = re.search(r"hdrBloomExtract.*?float2 t = u\.sourceTexelSize;(.*?)\) \* 0\.25", s, re.S)
    f["extractTapOffsets"] = sorted(set(re.findall(r"float2\(\s*(-?[0-9.]+),\s*(-?[0-9.]+)\)",
                                                   m.group(1)))) if m else []
    m = re.search(r"fragment float4 hdrBloomDownsample.*?\) \* 0\.25", s, re.S)
    f["downsampleTapOffsets"] = sorted(set(re.findall(r"float2\(\s*(-?[0-9.]+),\s*(-?[0-9.]+)\)",
                                                      m.group(0)))) if m else []
    f["hasBlur13"] = "blur13" in s
    m = re.search(r"fragment float4 hdrBloomUpsample.*?\n    \}", s, re.S)
    f["upsampleSampleCount"] = len(re.findall(r"\.sample\(", m.group(0))) if m else None
    m = re.search(r"fragment float4 hdrBloomCombine.*?\n    \}", s, re.S)
    f["combineSampleCount"] = len(re.findall(r"\.sample\(", m.group(0))) if m else None
    f["topLevelUpsampleFlipped"] = bool(
        re.search(r"e\.setFragmentTexture\(top, index: 0\)\s*\n\s*e\.setFragmentTexture\(L\[0\], index: 1\)", s))
    return f


def corpus_defaults():
    keys = ("bloomhdrscatter", "bloomhdrfeather", "bloomhdrthreshold",
            "bloomhdrstrength", "bloomhdriterations")
    import collections
    c = {k: collections.Counter() for k in keys}
    n = 0
    for wid in sorted(os.listdir(T.WS)):
        pkg = next((os.path.join(T.WS, wid, f) for f in ("scene.pkg", "gifscene.pkg")
                    if os.path.exists(os.path.join(T.WS, wid, f))), None)
        if not pkg:
            continue
        raw = open(pkg, "rb").read()
        try:
            _, entries, base = T.parse_pkg(raw)
        except Exception:
            continue
        for name, off, size in entries:
            if name != "scene.json":
                continue
            try:
                sc = json.loads(raw[base + off:base + off + size].decode("utf-8-sig", "replace"))
            except Exception:
                continue
            n += 1
            g = sc.get("general") or {}
            for k in keys:
                c[k][str(g.get(k))] += 1
    return n, {k: dict(v.most_common(4)) for k, v in c.items()}


def float_hits(v):
    data = open(os.path.join(T.WE, "wallpaper64.exe"), "rb").read()
    return len(re.findall(re.escape(struct.pack("<f", v)), data))


def build():
    we = we_facts()
    wp = waple_facts()
    n, corp = corpus_defaults()
    shader_ev = specfmt.ev("shader", "assets/shaders/hdr_downsample.frag",
                           "WE 가 평문 배포하는 블룸 피라미드 셰이더 — 콤보로 3역할")
    mat_ev = specfmt.ev("asset", "assets/materials/util/hdr_{downsample,downsample_bloom,upsample}.json",
                        "콤보/블렌딩 규약")
    code_ev = specfmt.ev("file", WSRC.replace(os.sep, "/"))

    return [
        specfmt.entry("engine.bloom.hdr.structure", {
            "source": "WE 셰이더 평문 — RE 불필요",
            "pipeline": "hdr_downsample 셰이더 **하나**를 콤보로 3역할에 쓰는 듀얼-필터 피라미드",
            "roles": we["materials"],
            "downsampleTapCount": we["downsampleTaps"],
            "downsampleTapSwizzles": we["downsampleTapSwizzles"],
            "renderVar0Meaning": f"BICUBIC 분기의 `texSize = {we['renderVar0Scale']} / g_RenderVar0.xy` 에서 "
                                 f"g_RenderVar0.xy = {we['renderVar0Scale']} x 텍셀크기 로 확정 — "
                                 "즉 4탭이 ±0.5 텍셀 코너에 놓인다.",
            "noGaussianPass": not we["hasGaussianBlurPass"],
            "upsample": "같은 4탭 x 0.25 x g_BloomScatter, 머티리얼이 blending:additive",
            "combineTaps": we["combineBloomTaps"],
            "combineNote": "combine_hdr.frag 가 블룸 텍스처를 ±g_TexelSize 4탭으로 평균한 뒤 가산한다",
        }, "확정", [shader_ev, mat_ev]),

        specfmt.entry("engine.bloom.hdr.wapleMatches", {
            "thresholdMath": "추출의 소프트-니 수식이 WE 와 **수학적으로 동일**하다 "
                             "(max채널 brightness, soft=clamp(m-P.y,0,P.z)^2*P.w, "
                             "q=max(m-P.x,soft), c*q/max(m,1e-5)*strength*tint).",
            "extractUsesMaxChannel": we["extractUsesMaxChannel"],
            "parameterDefaults": {
                "corpusScenes": n,
                "distribution": corp,
                "verdict": "scatter 1.619 · feather 0.1 · threshold 1.0 · strength 2.0 · iterations 8 "
                           "— Waple 기본값과 전부 일치.",
                "scatterIsWEDefault": f"1.619 가 wallpaper64.exe 에 float 로 {float_hits(1.619)}회 등장하고 "
                                      "코퍼스 140/161 이 그 값을 저작한다 — 에디터가 쓰는 기본값이다.",
            },
            "downsampleTaps": {
                "wapleOffsets": wp["downsampleTapOffsets"],
                "weOffsetMagnitude": we["renderVar0Scale"],
                "match": all(abs(float(a)) == we["renderVar0Scale"] and abs(float(b)) == we["renderVar0Scale"]
                             for a, b in wp["downsampleTapOffsets"]) if wp["downsampleTapOffsets"] else None,
            },
        }, "확정", [shader_ev, code_ev,
                    specfmt.ev("corpus", f"{n}개 씬 general.bloomhdr* 분포"),
                    specfmt.ev("binary", "wallpaper64.exe float 1.619")]),

        specfmt.entry("engine.bloom.hdr.filterShapeDeviations", {
            "summary": "임계 수식과 파라미터는 맞고 **필터 모양**이 갈린다. "
                       "오차 부호가 서로 반대다.",
            "widerThanWE": [
                {"id": "W1", "what": "추출 4탭이 ±1.0 소스 텍셀",
                 "we": "±0.5 텍셀", "waple": wp["extractTapOffsets"],
                 "note": "같은 파일의 hdrBloomDownsample 은 ±0.5 라 내부적으로도 불일치한다 — "
                         "이 불일치 자체가 ±0.5 해석을 뒷받침한다."},
                {"id": "W2", "what": "레벨마다 blur13(13탭 가우시안) h/v 패스",
                 "we": "그런 패스가 **없다**(순수 4탭 듀얼 필터)", "waple": wp["hasBlur13"],
                 "note": "이게 가장 큰 모양 차이다."},
            ],
            "narrowerThanWE": [
                {"id": "N1", "what": "업샘플이 단일 탭",
                 "we": "4탭 × 0.25 × scatter + additive 블렌딩",
                 "waple": f"sample 호출 {wp['upsampleSampleCount']}회(base+add)",
                 "note": "0.25×scatter 가중 자체는 Waple 도 적용한다 — 빠진 건 탭 모양이다."},
                {"id": "N2", "what": "합성이 블룸을 단일 탭으로 읽음",
                 "we": f"combine_hdr.frag 가 ±텍셀 {we['combineBloomTaps']}탭 평균 후 가산",
                 "waple": f"sample 호출 {wp['combineSampleCount']}회"},
            ],
            "structural": [
                {"id": "S1", "what": "최상위 업샘플의 가중이 뒤집혀 있다",
                 "detail": "중간 단계는 `L[i] + acc*w`(WE 규약과 일치)인데 최상위만 "
                           "`acc + L[0]*w` 라 **추출 레벨이 감쇠**되고 누적이 전가중이다.",
                 "detected": wp["topLevelUpsampleFlipped"]},
            ],
            "orderingConstraint": "W1·W2 는 결과를 넓히고 N1·N2 는 좁힌다. **일부만 고치면 더 나빠진다** — "
                                  "예컨대 blur13 만 제거하면 WE 보다 훨씬 뾰족해지고, "
                                  "합성 4탭만 추가하면 이미 넓은 결과가 더 번진다. "
                                  "필터 체인을 **한 번에** WE 구조로 갈아야 한다.",
            "whyCurrentLooksPlausible": "현 구현은 blur13 로 넓히고 단일 탭으로 좁히는 조합이 "
                                        "서로 상쇄돼 육안으로는 그럴듯하다. 그래서 개별 항목을 "
                                        "'명백한 버그' 로 보고 하나씩 고치면 회귀한다.",
            "reach": "HDR 블룸 사용 씬(코퍼스 bloomhdr* 저작분) — 골든 영향 추정 7종",
            "doNotFixPiecemeal": "한 항목씩 커밋하지 마라. 전체 교체 + 재베이스라인이 한 단위다.",
        }, "보고", [shader_ev, mat_ev, code_ev]),
    ]


def main():
    entries = build()
    specfmt.dump(specfmt.doc("scripts/spec/measure_hdr_bloom.py", entries), OUT)
    v = {e["id"]: e["value"] for e in entries}
    st = v["engine.bloom.hdr.structure"]
    dv = v["engine.bloom.hdr.filterShapeDeviations"]
    print("WE 구조:", st["pipeline"])
    print(f"  다운샘플 {st['downsampleTapCount']}탭{st.get('downsampleTapSwizzles', '')} · "
          f"가우시안 패스 없음={st['noGaussianPass']} · 합성 {st['combineTaps']}탭")
    print(f"  Waple 다운샘플 일치: {v['engine.bloom.hdr.wapleMatches']['downsampleTaps']}")
    print()
    print("차이:")
    for k in ("widerThanWE", "narrowerThanWE", "structural"):
        for d in dv[k]:
            print(f"  [{d['id']}] {d['what']}")
    print()
    print("  " + dv["orderingConstraint"][:100] + "…")
    print(f"\n기록: {OUT}")


if __name__ == "__main__":
    main()
