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
    """Waple 현재 구현(HDRBloomPyramidPass.swift)의 필터 구조를 소스에서 읽는다.

    2026-08-02 WE 구조 교체 후: 탭은 공용 헬퍼 weDownsample4 로 모였고(±0.5 소스 텍셀),
    가우시안 패스는 없어졌으며, 업샘플/합성이 4탭을 쓴다. 교체 전 값은 아래 PRE_SWAP 상수.
    """
    s = read(WSRC)
    f = {}
    m = re.search(r"float3 weDownsample4\(.*?\n    \}", s, re.S)
    helper = m.group(0) if m else ""
    f["sharedTapHelper"] = bool(m)
    f["helperTapScale"] = "0.5 / 텍스처크기" if "0.5 / float2(src.get_width()" in helper else "미확인"
    f["helperTapCount"] = len(re.findall(r"\.sample\(", helper))
    # 주석에 'blur13' 이라는 낱말이 남아 있어도 잡히면 안 된다(교체 이력을 주석에 적어 뒀다) —
    # 실제 함수/프래그먼트 정의만 본다.
    f["hasBlur13"] = bool(re.search(r"float3 blur13\(|fragment float4 hdrBloomBlur", s))
    for name in ("hdrBloomExtract", "hdrBloomDownsample", "hdrBloomUpsample", "hdrBloomCombine"):
        m = re.search(r"fragment float4 " + name + r".*?\n    \}", s, re.S)
        body = m.group(0) if m else ""
        f[name + "UsesHelper"] = "weDownsample4" in body
        f[name + "DirectSamples"] = len(re.findall(r"\.sample\(", body))
    f["topLevelUpsampleFlipped"] = bool(
        re.search(r"e\.setFragmentTexture\(top, index: 0\)", s))
    f["uniformUpsampleRule"] = bool(
        re.search(r"for i in stride\(from: n - 2, through: 0, by: -1\)", s))
    f["levelZeroScale"] = ("1/2" if ">> (1 + i)" in s else ("1/4" if ">> (2 + i)" in s else "미확인"))
    f["upsampleWeight"] = ("0.25 x scatter" if "parameters.scatter * 0.25" in s else "scatter")
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


def float_hits(x):
    """wallpaper64.exe 안에 float32 리터럴 x 가 몇 번 등장하는지.

    exe 는 윈도우 설치본에만 있다(맥 작업 환경에는 없다). 없으면 None 을 돌려주고
    호출부가 "이번 실행에서는 재측정 안 함" 으로 적는다 — 없는 값을 지어내지 않는다.
    """
    p = os.path.join(T.WE, "wallpaper64.exe")
    if not os.path.exists(p):
        return None
    data = open(p, "rb").read()
    return data.count(struct.pack("<f", x))


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
                "scatterIsWEDefault": (
                    f"1.619 가 wallpaper64.exe 에 float 로 {float_hits(1.619)}회 등장하고 "
                    "코퍼스 140/161 이 그 값을 저작한다 — 에디터가 쓰는 기본값이다."
                    if float_hits(1.619) is not None else
                    "1.619 는 윈도우 측정에서 wallpaper64.exe 에 float 로 1회 등장했다"
                    "(이번 실행 환경엔 exe 가 없어 재측정하지 않음). "
                    "코퍼스 140/161 이 그 값을 저작한다 — 에디터가 쓰는 기본값이다."),
            },
        }, "확정", [shader_ev, code_ev,
                    specfmt.ev("corpus", f"{n}개 씬 general.bloomhdr* 분포"),
                    specfmt.ev("binary", "wallpaper64.exe float 1.619")]),

        specfmt.entry("engine.bloom.hdr.filterShapeDeviations", {
            "summary": "임계 수식과 파라미터는 처음부터 맞았고 **필터 모양**이 갈렸다. "
                       "오차 부호가 서로 반대라 일부만 고치면 더 나빠지는 구조였다.",
            "status": "**2026-08-02 한 단위로 교체 완료** — 아래 preSwap 5건이 전부 해소됐다.",
            "preSwap": {
                "W1": "추출 4탭이 ±1.0 소스 텍셀(WE ±0.5)",
                "W2": "레벨마다 blur13(13탭 가우시안) h/v 패스 — WE 엔 그런 패스가 없다",
                "N1": "업샘플이 단일 탭(WE 는 4탭)",
                "N2": "합성이 블룸을 단일 탭으로 읽음(WE 는 ±텍셀 4탭 평균)",
                "S1": "최상위 업샘플만 가중이 뒤집혀 추출 레벨이 감쇠",
                "levelZero": "피라미드가 1/4 에서 시작(WE 는 매 단계 절반이라 1/2)",
            },
            "postSwapMeasured": wp,
            "orderingConstraint": "W1·W2 는 결과를 넓히고 N1·N2 는 좁힌다. 일부만 고치면 더 나빠지므로 "
                                  "한 번에 갈아야 했다 — 실제로 그렇게 했다.",
            "abResult": {
                "baseline": "spec/golden/snapshot/baseline-f3a17da (교체 직전)",
                "changedScenes": 9,
                "lumaRatioRange": "0.95 ~ 1.10",
                "maxMeanAbsDiff": 2.84,
                "reading": "에너지는 보존되고 헤일로 모양만 바뀌었다 — 필터 교체의 기대 형상.",
            },
        }, "확정", [shader_ev, mat_ev, code_ev]),

        # [2026-08-20] 이 두 항목은 **한 쌍**이다.
        # `...Unknown`(추정)은 "저작 scatter 가 셰이더로 그대로 가는지 미확인" 을 미해결로 들고 있었는데,
        # ① 동봉 셰이더 원문의 어노테이션이 material 이름을 직접 적고 ② 같은 정본 uniform-feed.json 이
        # 확정 등급으로 답을 갖고 ③ 출하 코드가 이미 확정 쪽을 따랐다 — **정본만 낡아 모순을 배포**했다.
        #
        # 지우지 않고 묘비로 남기는 이유: 근거 축소 가드가 항목·키 소멸을 잡는데 이 하나를 통과시키려면
        # allow_shrink 를 켜야 하고, 그러면 이 파일의 가드가 영구히 꺼진다(= 원격 스위치). 그리고
        # HDRBloomPyramidPass.swift · parity-sweep 문서가 이 id 를 인용한다. 원문 키도 그대로 보존한다.
        specfmt.entry("engine.bloom.hdr.upsampleWeightUnknown",
                      {
                          "question": "WE 셰이더 문면대로면 업샘플 가중이 **평균 x g_BloomScatter** 인데, 저작값 scatter=1.619 를 그대로 넣으면 레벨마다 곱해져 발산한다.",
                          "measured": "그대로 구현해 전 코퍼스를 뜨니 3589454154 의 meanLuma 가 0.0913 → 0.4198(4.6배)로 화면이 백화됐다. 9씬 중 5씬이 2배 이상 밝아졌다.",
                          "whatWeDo": "탭 모양만 WE 로 맞추고 **가중은 종전 캘리브(0.25 x scatter)를 유지**한다. 이 값은 발산하지 않고 A/B 에서 에너지 보존이 확인된다.",
                          "openQuestion": "저작 bloomhdrscatter(1.619)가 셰이더 g_BloomScatter 로 그대로 가는지, 엔진이 레벨 수로 정규화하는지 미확인. 셰이더 주석의 material 기본값은 1 이다.",
                          "howToClose": "wallpaper64.exe 에서 scatter 머티리얼 프로퍼티를 셰이더 상수로 넘기는 지점을 찾거나(정적 분석), 윈도우에서 같은 씬을 캡처해 헤일로 감쇠율을 재면 된다.",
                          "closed": "**[2026-08-20] 이 미해결은 닫혔다** → engine.bloom.hdr.upsampleWeight 참조. 위 question/openQuestion/howToClose 는 당시 서술을 지우지 않고 남긴 것이다.",
                          "whyItWasWrong": "미확인이 아니었다. ① 동봉 셰이더 원문의 어노테이션이 material 이름을 직접 적고 있었다(함정 ⑦: x86 전에 GLSL 을 먼저 봤어야 했다). ② 같은 정본 uniform-feed.json 이 **확정** 등급으로 답을 갖고 있었다. ③ 출하 코드는 이미 확정 쪽을 따랐다. 정본만 낡아 모순을 배포하고 있었다.",
                          "whyKeptAsTombstone": "id 를 지우지 않는 이유 둘. ① 근거 축소 가드가 항목·키 소멸을 잡는데 이 하나를 통과시키려면 allow_shrink 를 켜야 하고 그러면 이 파일의 가드가 영구히 꺼진다 — 이 리포가 반복해서 잡아낸 '원격 스위치' 부류다. ② Sources/WapleRender/HDRBloomPyramidPass.swift 와 docs/history/parity-sweep-2026-08-19.md 가 이 id 를 인용한다.",
                      },
                      "확정", [shader_ev, mat_ev, code_ev]),

        specfmt.entry("engine.bloom.hdr.upsampleWeight",
                      {
                          "resolved": "업샘플 머티리얼의 `scatter` 파라미터에는 저작 `bloomhdrscatter` 가 **변형 없이** 실린다. 셰이더의 `0.25` 는 4탭 평균이지 가중이 아니다 — 둘은 애초에 경쟁 후보가 아니었다.",
                          "shaderText": "assets/shaders/hdr_downsample.frag:61 `uniform float g_BloomScatter; // {\"material\":\"scatter\",\"default\":1}` · 본문 `albedo *= 0.25 * g_BloomScatter` (albedo 는 4탭 **합**)",
                          "engineFeed": "0x14017f807 `movss xmm6,[rbx+0x3d0]`(저작값 적재) → 중간 변형 없이 `setMaterialParam(mat,\"scatter\",xmm6,1)` 2회: 0x14017f967 · 0x14017f988. 대상 [rsi+0x31a0] · [rsi+0x31a8] = hdr_upsample 계열 2개. 0x14017f854 `movaps xmm0,xmm6` 는 정규화의 powf 입력이라 xmm6 를 바꾸지 않는다.",
                          "whyNoDivergence": "추출 강도를 `bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)` 로 나누는 정규화(0x14017f85e powf → 0x14017f86b +1.0 → 0x14017f88f divss)와 **한 쌍**이라 scatter^k 누적이 상쇄된다. 종전 백화(3589454154 meanLuma 0.0913 → 0.4198)는 가중만 옮기고 이 나눗셈을 안 옮겨서 난 것이지 가중이 틀려서가 아니었다.",
                          "crossCheck": "spec/engine/uniform-feed.json — engine.uniformFeed.hdrBloom.materialParams(확정)",
                          "supersedes": "engine.bloom.hdr.upsampleWeightUnknown",
                      },
                      "확정", [shader_ev, mat_ev, code_ev]),
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
    print(f"  Waple 현재 구조(소스 실측): {v['engine.bloom.hdr.filterShapeDeviations']['postSwapMeasured']}")
    print()
    print("교체 전 차이(해소됨):")
    for k, d in v["engine.bloom.hdr.filterShapeDeviations"]["preSwap"].items():
        print(f"  [{k}] {d}")
    print()
    ab = v["engine.bloom.hdr.filterShapeDeviations"]["abResult"]
    print(f"  A/B: {ab['changedScenes']}씬 변화 · luma {ab['lumaRatioRange']} · maxMeanΔ {ab['maxMeanAbsDiff']}")
    print(f"  업샘플 가중(확정): {v['engine.bloom.hdr.upsampleWeight']['resolved']}")
    print(f"\n기록: {OUT}")


if __name__ == "__main__":
    main()
