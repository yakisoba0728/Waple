"""HDR 블룸 파이프라인을 WE **평문 셰이더**와 대조한다 — spec/engine/hdr-bloom.json.

WE 는 블룸 셰이더를 GLSL 평문으로 배포한다. 그래서 **구조**는 대조만으로 나온다.

    hdr_downsample.json         콤보 없음         → 4탭 박스 다운샘플 (×0.25)
    hdr_downsample_bloom.json   BLOOM:1          → 같은 4탭 + 임계(소프트 니) 추출
    hdr_upsample.json           UPSAMPLE:1       → 같은 4탭 × 0.25 × scatter, blending:"additive"
    hdr_upsample_cubic.json     UPSAMPLE+BICUBIC → 같은 것에 탭마다 textureBicubic
    combine_hdr_upsample.json   combine_hdr      → 블룸 4탭 평균 후 가산

즉 **셰이더 하나**를 콤보로 세 역할(+BICUBIC 변형)에 쓰는 듀얼-필터 피라미드이고,
가우시안 블러 패스가 **없다**.

**[2026-08-21] "디스어셈 불필요" 는 틀렸다.** 셰이더가 쓰는 탭 오프셋 `g_RenderVar0` 은
셰이더가 계산하지 않고 **엔진이 싣는다**. 그래서 탭 반경·레벨 수·BICUBIC 선택은 셰이더
문면에 없고 드로우 루프(`Composite::drawBloomChain` 0x140183610–0x140183a61)와 파라미터
피드(`Composite::allocateTargets` 0x14017f1b0–0x14017fa6f)를 읽어야 나온다. BICUBIC 분기의
`texSize = 0.5 / g_RenderVar0.xy` 를 전 패스로 일반화한 종전 서술이 구현에 반경 절반 결함을
낳았다(§structure.renderVar0Meaning · filterShapeDeviations.preSwap.W1).

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
# [2026-08-21] 순수 탭 산술 본체가 WapleCore 로 갔다(리눅스 테스트를 붙이려고).
# 아래 탐침 중 산술 쪽은 **이 파일**을 읽어야 한다 — WSRC 에 남은 것은 얇은 위임뿐이라
# 종전 정규식이 "탐침 불일치"/false 를 조용히 내놓는다(b19db5b 때 실제로 당한 고아화).
MSRC = os.path.join("Sources", "WapleCore", "HDRBloomMath.swift")


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
    # hdr_upsample_cubic 을 빼먹으면 안 된다 — 엔진이 가장 깊은 두 업샘플 단에서 그 슬롯
    # (`0x31a8`)을 고르고(`0x140183810`–`0x140183822`), BICUBIC 콤보가 걸린 곳이 여기뿐이라
    # `texSize = 0.5 / g_RenderVar0.xy` 항등식의 성립 범위도 이 머티리얼이 정한다.
    for name in ("hdr_downsample", "hdr_downsample_bloom", "hdr_upsample", "hdr_upsample_cubic",
                 "combine_hdr_upsample"):
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

    이력 두 단계를 그대로 반영한다.
      · 2026-08-02 — 탭을 공용 헬퍼로 모으고 가우시안 패스를 없앴다. 다만 그 헬퍼가
        소스 텍스처 크기에서 `0.5 / 크기` 로 오프셋을 **되짚어** 세 계열에 같은 반경을 줬다.
      · 2026-08-21(`b19db5b`) — 되짚기를 없애고 헬퍼 이름이 `weBox4(src, uv, t)` 가 됐다.
        `t` 는 호스트가 `tapOffsetUV(scale:baseWidth:baseHeight)` 로 계산해 유니폼으로 싣고,
        가장 깊은 두 업샘플 단은 `hdrBloomUpsampleCubic` 을 쓴다.
      · 2026-08-21(W-25) — 순수 산술이 `WapleCore/HDRBloomMath.swift`(MSRC)로 이동했다.
        MSL 과 인코드 루프는 그대로 WSRC 에 있으므로 **탐침이 두 파일로 갈린다**.

    **탐침이 소스를 놓치면 값이 조용히 0/false 로 무너진다.** 실제로 `b19db5b` 가
    `weDownsample4` → `weBox4` 로 이름을 바꾼 뒤 이 함수 전체가 헛돌아, 재생성이
    `helperTapCount 4 → 0` 으로 축소 가드에 막히는 상태였다(정본이 고아가 됐다).
    그래서 헬퍼 이름을 **한 자리**(HELPER)에 두고 아래가 전부 그걸 참조한다.
    """
    s = read(WSRC)     # MSL + 인코드 루프
    ms = read(MSRC)    # 순수 산술(탭 배율·BICUBIC 선택·강도 정규화)
    f = {}
    HELPER = "weBox4"
    m = re.search(r"float3 " + HELPER + r"\(.*?\n    \}", s, re.S)
    helper = m.group(0) if m else ""
    f["sharedTapHelper"] = bool(m)
    # 되짚기(`0.5 / 텍스처크기`)가 남아 있으면 그걸 적고, 없으면 호스트 급전을 적는다.
    # "미확인" 같은 헤지 낱말을 쓰지 않는다 — 확정 항목 안에 들어가면 validate.py 가 신고한다.
    f["helperTapScale"] = ("0.5 / 텍스처크기" if "0.5 / float2(src.get_width()" in helper
                           else ("호스트가 싣는 유니폼 t" if re.search(r"float2 t\)", helper)
                                 else "탐침 불일치"))
    f["helperTapCount"] = len(re.findall(r"\.sample\(", helper))
    # 주석에 'blur13' 이라는 낱말이 남아 있어도 잡히면 안 된다(교체 이력을 주석에 적어 뒀다) —
    # 실제 함수/프래그먼트 정의만 본다.
    f["hasBlur13"] = bool(re.search(r"float3 blur13\(|fragment float4 hdrBloomBlur", s))
    for name in ("hdrBloomExtract", "hdrBloomDownsample", "hdrBloomUpsample",
                 "hdrBloomUpsampleCubic", "hdrBloomCombine"):
        m = re.search(r"fragment float4 " + name + r"\(.*?\n    \}", s, re.S)
        body = m.group(0) if m else ""
        f[name + "UsesHelper"] = HELPER + "(" in body
        f[name + "DirectSamples"] = len(re.findall(r"\.sample\(", body))
    f["topLevelUpsampleFlipped"] = bool(
        re.search(r"e\.setFragmentTexture\(top, index: 0\)", s))
    f["uniformUpsampleRule"] = bool(
        re.search(r"for i in stride\(from: n - 2, through: 0, by: -1\)", s))
    f["levelZeroScale"] = ("1/2" if ">> (1 + i)" in s else ("1/4" if ">> (2 + i)" in s else "탐침 불일치"))
    # 셰이더 문면은 `albedo(4탭 합) *= 0.25 * g_BloomScatter` 다. `weBox4` 가 이미 x0.25 를
    # 먹었으므로 그 위에 곱하는 것은 **생 scatter** 여야 한다. 종전 캘리브(`* 0.25` 를 한 번 더)
    # 였는지 문면대로인지를 가른다.
    f["upsampleWeight"] = ("0.25 x scatter" if "parameters.scatter * 0.25" in s
                           else ("0.25(4탭 평균) x 생 scatter"
                                 if re.search(r"weBox4\(add, in\.uv, u\.tapOffset\) \* u\.scatter", s)
                                 else "탐침 불일치"))
    # --- b19db5b 이후 새로 측정하는 것들 -------------------------------------
    f["tapOffsetFedByHost"] = bool(
        re.search(r"static func tapOffsetUV\(scale: Int, baseWidth: Int, baseHeight: Int\)", ms))
    m = re.search(r"static func downsampleTapScale\(level: Int\) -> Int \{ ([^}]+) \}", ms)
    f["downsampleTapScaleRule"] = m.group(1).strip() if m else "탐침 불일치"
    m = re.search(r"static func upsampleTapScale\(sourceLevel: Int\) -> Int \{ ([^}]+) \}", ms)
    f["upsampleTapScaleRule"] = m.group(1).strip() if m else "탐침 불일치"
    f["hasBicubicUpsample"] = bool(re.search(r"fragment float4 hdrBloomUpsampleCubic\(", s))
    m = re.search(r"static func upsampleUsesBicubic\(sourceLevel: Int, levelCount: Int\) -> Bool \{\n\s*([^\n]+)\n", ms)
    f["bicubicSelectionRule"] = m.group(1).strip() if m else "탐침 불일치"
    f["strengthNormalization"] = bool(
        re.search(r"return strength / \(powf\(scatter, exponent\) \+ 1\)", ms))
    # [2026-08-21 신설] 레벨 수 산식. `sourceWidth`/`sourceHeight` 중 **min** 을 잡는지 본다 —
    # W-25 가 정확히 이 한 줄이었다(종전 `w > 1 || h > 1` 은 max 기준).
    f["levelCountBasis"] = (
        "min(W,H)" if re.search(r"var d = min\(max\(1, sourceWidth\), max\(1, sourceHeight\)\)", ms)
        else ("max(W,H)" if re.search(r"while w > 1 \|\| h > 1", ms + s) else "탐침 불일치"))
    f["levelCountCap"] = (8 if re.search(r"while count < 8 \{", ms) else 0)
    # WSRC 에 위임만 남았는지 — 산술이 두 곳에 복제되면 정본이 어느 쪽을 재는지 알 수 없다.
    f["renderSideIsDelegationOnly"] = bool(
        re.search(r"HDRBloomMath\.levelCount\(\n?\s*requested: requested", s))
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
                           "WE 가 평문 배포하는 블룸 피라미드 셰이더 — 콤보로 3역할(+BICUBIC 변형)")
    mat_ev = specfmt.ev("asset",
                        "assets/materials/util/hdr_{downsample,downsample_bloom,upsample,upsample_cubic}.json",
                        "콤보/블렌딩 규약 — BICUBIC 콤보는 hdr_upsample_cubic 에만 붙는다")
    code_ev = specfmt.ev("file", WSRC.replace(os.sep, "/"))
    chain_ev = specfmt.ev("binary", "wallpaper64.exe Composite::drawBloomChain 0x140183610–0x140183a61",
                          "g_RenderVar0 기저·패스별 정수 배율·BICUBIC 슬롯 선택")

    return [
        specfmt.entry("engine.bloom.hdr.structure", {
            "source": "WE 셰이더 평문 — 구조는 RE 불필요. 다만 **탭 반경은 셰이더만 봐서는 안 나온다**"
                      "(오프셋을 엔진이 유니폼으로 싣는다) — 아래 tapRadiusBySlot 은 드로우 루프 실측이다.",
            "pipeline": "hdr_downsample 셰이더 **하나**를 콤보로 3역할(+BICUBIC 변형)에 쓰는 듀얼-필터 피라미드",
            "roles": we["materials"],
            "downsampleTapCount": we["downsampleTaps"],
            "downsampleTapSwizzles": we["downsampleTapSwizzles"],
            # **[2026-08-21] 종전 서술이 틀렸다.** 여기 "즉 4탭이 ±0.5 텍셀 코너에 놓인다" 라고
            # 적어 두고 그걸 전 패스로 일반화했는데, 그 항등식은 BICUBIC 이 걸린
            # hdr_upsample_cubic 에서만 성립한다. 실물은 추출·다운샘플이 ±1.0 소스 텍셀이다.
            # 이 한 줄이 `b19db5b` 이전 구현의 반경 절반 결함(W-1)의 발원지였다.
            "renderVar0Meaning": f"BICUBIC 분기의 `texSize = {we['renderVar0Scale']} / g_RenderVar0.xy`(:22) 는 "
                                 "**BICUBIC 콤보가 걸린 자리에서만** 성립하는 항등식이고, 그 콤보는 "
                                 "hdr_upsample_cubic 하나에만 붙어 있다. 전 패스로 일반화하면 안 된다 — "
                                 "엔진은 셰이더가 크기에서 되짚게 두지 않고 오프셋을 **직접 싣는다**.",
            "tapRadiusBySlot": {
                "base": "g_RenderVar0 기저 = (1/W, 1/H, −1/W, −1/H), W·H 는 그 패스의 소스가 아니라 "
                        "**풀 프레임버퍼**(obj+0x84 · obj+0x88) — 0x14018367c–0x1401836ba, 저장 0x1401836a0–0x1401836ba",
                "extract": "배율 없이 기저 그대로(0x1401836a0), 소스=_rt_FullFrameBuffer(폭 W) → **±1.0 소스 텍셀**(4×4 박스)",
                "downsample": "`mov eax,1 ; shl eax,cl`(cl=i) = 1<<i 배(0x14018374a–0x14018375c), "
                              "소스=level[i−1](폭 W>>i) → **±1.0 소스 텍셀**(4×4 박스)",
                "upsample": "`mov eax,2 ; shl eax,cl`(cl=i−1) = 2<<(i−1) 배(0x140183856–0x14018386b), "
                            "소스=level[i](폭 W>>(i+1)) → **±0.5 소스 텍셀**(2×2 박스)",
                "whyDifferent": "배율 수는 둘 다 2^i 로 같다. 반경이 갈리는 원인은 **소스 레벨이 한 단 다른 것**이다.",
                "bicubicSlots": "업샘플 소스레벨 ebp 가 N−2 이상이면 0x31a8(hdr_upsample_cubic), 아니면 "
                                "0x31a0(hdr_upsample) — 0x140183810–0x140183822 `cmp ebp,eax ; cmovl rcx,r15`. "
                                "즉 가장 깊은 두 단만 큐빅이다.",
            },
            "noGaussianPass": not we["hasGaussianBlurPass"],
            "upsample": "같은 4탭 x 0.25 x g_BloomScatter, 머티리얼이 blending:additive",
            "combineTaps": we["combineBloomTaps"],
            "combineNote": "combine_hdr.frag 가 블룸 텍스처를 ±g_TexelSize 4탭으로 평균한 뒤 가산한다",
            "crossRef": "engine.uniformFeed.g_RenderVar0.hdrBloomPyramid",
        }, "확정", [shader_ev, mat_ev, chain_ev]),

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
            "status": "**2026-08-02 한 단위로 교체 완료** — 아래 preSwap 5건이 전부 해소됐다. "
                      "**[2026-08-21] 그 교체가 W1 을 반대로 진단했던 것이 `b19db5b` 에서 드러나 다시 뒤집혔다** "
                      "— 아래 W1 · postSwapCorrection 참조.",
            "preSwap": {
                # **[2026-08-21] 이 줄의 괄호가 틀렸었다.** "WE ±0.5" 라고 적었는데 WE 의 추출·다운샘플은
                # ±1.0 소스 텍셀이다(0x1401836a0 · 0x14018374a–0x14018375c, structure.tapRadiusBySlot).
                # 즉 교체 전 Waple 의 ±1.0 이 **맞았고** 2026-08-02 교체가 그걸 ±0.5 로 망가뜨렸다.
                # `b19db5b` 가 ±1.0 으로 되돌렸다. 오진의 뿌리는 renderVar0Meaning 의 과잉 일반화다.
                "W1": "추출 4탭이 ±1.0 소스 텍셀 — 당시 이것을 이탈로 적었으나 **오진이었다**"
                      "(WE 도 ±1.0 이다). 2026-08-02 교체가 ±0.5 로 바꿔 실제 이탈을 만들었고 "
                      "`b19db5b` 가 ±1.0 으로 되돌렸다.",
                "W2": "레벨마다 blur13(13탭 가우시안) h/v 패스 — WE 엔 그런 패스가 없다",
                "N1": "업샘플이 단일 탭(WE 는 4탭)",
                "N2": "합성이 블룸을 단일 탭으로 읽음(WE 는 ±텍셀 4탭 평균)",
                "S1": "최상위 업샘플만 가중이 뒤집혀 추출 레벨이 감쇠",
                "levelZero": "피라미드가 1/4 에서 시작(WE 는 매 단계 절반이라 1/2)",
            },
            "postSwapMeasured": wp,
            "postSwapCorrection": {
                "commit": "b19db5b (2026-08-21)",
                "what": "① 공용 헬퍼의 `0.5 / 텍스처크기` 되짚기를 없애고 탭 오프셋을 호스트가 싣게 했다"
                        "(`weDownsample4` → `weBox4(src, uv, t)`). ② 가장 깊은 두 업샘플 단의 BICUBIC 을 이식했다.",
                "why": "되짚기가 성립하는 곳은 BICUBIC 이 걸린 업샘플뿐인데 헬퍼가 세 계열 공용이라, "
                       "추출·다운샘플까지 업샘플 규칙을 받아 반경이 정확히 절반이 됐다.",
                "canonWasStale": "이 커밋은 구현만 고치고 정본·생성기·문서를 그대로 뒀다. 그래서 "
                                 "생성기의 `weDownsample4` 탐침이 전부 헛돌아 재생성이 "
                                 "`helperTapCount 4 → 0` 축소로 막히는 상태였다(정본이 고아). "
                                 "2026-08-21 이 갱신이 그 자리를 메운다.",
                "w25Move": "**[2026-08-21] 같은 함정을 한 번 더 밟을 뻔했다.** W-25(레벨 수 산식)를 "
                           "고치면서 순수 산술을 `WapleCore/HDRBloomMath.swift` 로 옮겼는데, "
                           "위 탐침 중 다섯이 `HDRBloomPyramidPass.swift` 만 읽고 있었다. 그대로 뒀으면 "
                           "`downsampleTapScaleRule`·`upsampleTapScaleRule` 이 '탐침 불일치', "
                           "`bicubicSelectionRule` 이 위임 한 줄, `strengthNormalization` 이 false 로 "
                           "무너진다(음성 대조로 실제 확인했다). 산술 탐침을 MSRC 로 옮기고 "
                           "`levelCountBasis`·`levelCountCap`·`renderSideIsDelegationOnly` 를 새로 잰다.",
            },
            "orderingConstraint": "W1·W2 는 결과를 넓히고 N1·N2 는 좁힌다. 일부만 고치면 더 나빠지므로 "
                                  "한 번에 갈아야 했다 — 실제로 그렇게 했다.",
            "abResult": {
                "baseline": "spec/golden/snapshot/baseline-f3a17da (교체 직전). **[2026-08-28] 이 라벨은 HEAD 에 없다** — 삭제 사고가 아니라 정책이다(`spec/golden/snapshot/README.md`: 낡은 기준선은 커밋 이력에만 남긴다). 여기서는 **당시 A/B 의 대조군**이라 현행 기준선으로 바꿔 적으면 거짓이 된다 — 라벨은 그대로 두고 '지금 트리에 없다' 는 사실만 붙인다. 현행 판정 기준선은 `baseline-6f0bcf0` 이고(`GoldenBaseline.currentLabel`), 아래 수치는 그것과 무관하다.",
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
                          "engineFeed": "0x14017f807 `movss xmm6,[rbx+0x3d0]`(저작값 적재) → 중간 변형 없이 `setMaterialParam(mat,\"scatter\",xmm6,1)` 2회. **[2026-08-21 재측정으로 VA 정정]** 첫 번째는 `mov rcx,[rsi+0x31a0]`(0x14017f944) → `call 0x14017e920`(0x14017f967), 두 번째는 `mov rcx,[rsi+0x31a8]`(0x14017f96c) → `jmp 0x14017f98f` 로 **공용 꼬리 `call 0x14017fa40`** 에 합류한다 — 0x14017f988 은 \"scatter\" 문자열의 `lea rdx` 이지 call 이 아니다(종전 서술이 그 자리를 call 로 적었다). 대상 [rsi+0x31a0] · [rsi+0x31a8] = hdr_upsample · hdr_upsample_cubic. 0x14017f854 `movaps xmm0,xmm6` 는 정규화의 powf 입력이고 xmm6 는 Win64 비휘발성이라 두 call 을 건너 살아남는다.",
                          "whyNoDivergence": "추출 강도를 `bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)` 로 나누는 정규화(0x14017f85e powf → 0x14017f86b +1.0 → 0x14017f88f divss)와 **한 쌍**이라 scatter^k 누적이 상쇄된다. 종전 백화(3589454154 meanLuma 0.0913 → 0.4198)는 가중만 옮기고 이 나눗셈을 안 옮겨서 난 것이지 가중이 틀려서가 아니었다.",
                          "crossCheck": "spec/engine/uniform-feed.json — engine.uniformFeed.hdrBloom.materialParams(확정)",
                          "supersedes": "engine.bloom.hdr.upsampleWeightUnknown",
                      },
                      "확정", [shader_ev, mat_ev, code_ev]),

        # [2026-08-21 신설 → 같은 날 해소] upsampleWeight 를 검증하다 N(레벨 수) 산식에서 이탈을
        # 하나 더 찾았다. 정규화 분모가 `scatter^(max(N,2)-2)+1` 이라 N 이 틀리면 **강도가 통째로
        # 틀린다** — 탭 모양보다 눈에 띄는 축이다. 풀스크린에서는 양쪽 다 캡(8)에 걸려 같은 값이
        # 나오지만 **이 리포의 골든 썸네일(256×144)은 갈린다** — 도달을 실제로 재고 반영했다.
        specfmt.entry("engine.bloom.hdr.levelCountRule",
                      {
                          "we": "생성 가능 단수 = **min(W,H)** 를 2로 계속 나눠 0 이 되기 전까지의 횟수, "
                                "루프 상한 8. `cmovg r14d,r12d`(0x14017f363)로 min 을 잡고 "
                                "`sar eax,1`(0x14017f376) → `jle`(0x14017f37d) 로 끊으며 "
                                "`inc [rsi+0x310c]`(0x14017f383) 로 센다. 루프는 `cmp ebx,8`(0x14017f541). "
                                "루프 진입 전에 두 변이 `max(·,2)` 로 클램프된다"
                                "(`cmovg r15d,edx` 0x14017f1ec · `cmovg r12d,r8d` 0x14017f200).",
                          "effectiveN": "N = max(1, min(bloomhdriterations, 생성단수)) — 0x14017f7f7–0x14017f84c, "
                                        "결과는 obj+0x3108. 이 N 이 그대로 정규화 지수 `max(N,2)-2` 로 간다. "
                                        "저작값은 obj+0x3d4(bloomhdriterations)에서 온다(0x14017f7ff).",
                          "waple": "[2026-08-21 이전 서술] HDRBloomPyramidPass.levelCount 는 `w > 1 || h > 1` 로 "
                                   "도는 **max 기준**이었다 — WE 의 floor(log2(min(W,H))) 와 달랐다. "
                                   "종전 서술은 그 값을 ceil(log2(max(W,H))) 라고 적었는데 실제로는 "
                                   "max(1, **floor**(log2(max(W,H)))) 다(재검산으로 정정).",
                          "reachability": "min(W,H) ≥ 256 이면 WE 쪽 단수가 이미 8 이라 캡에 걸려 양쪽이 같다. "
                                          "갈리는 것은 **짧은 변이 256 미만이고 두 변의 2-거듭제곱 구간이 다른** "
                                          "소스뿐이다(정사각 2의 거듭제곱은 min=max 라 안 갈린다). "
                                          "실사용 풀스크린은 전부 캡에 걸려 화면 차이 0 이지만, "
                                          "**이 리포의 골든 썸네일 파이프라인은 256×144**"
                                          "(SnapshotPipeline.thumbW/thumbH)라 8 → 7 로 갈린다 — "
                                          "정규화 분모가 19.01 → 12.12 로 내려가 블룸이 약 1.57배 밝아진다. "
                                          "64×32 렌더 테스트는 6 → 5. 코퍼스 bloomhdriterations 는 "
                                          "8 이 149건(157건 중)이라 요청 쪽이 먼저 캡을 만들지 않는다.",
                          "status": "**해소(2026-08-21)** — levelCount 를 min 기준으로 다시 썼다. 본체는 "
                                    "WapleCore/HDRBloomMath.swift `levelCount` 이고 "
                                    "HDRBloomPyramidPass 는 위임만 한다. 커밋된 기대치 "
                                    "Tests/WapleRenderTests/HDRBloomTests.swift 의 64×32 두 곳도 "
                                    "6 → 5 로 같이 고쳤다(나머지 넷은 불변).",
                          "crossRef": "engine.uniformFeed.hdrBloom.materialParams",
                          "해소": "산술을 WapleCore 로 옮긴 것이 이 항목의 실질 변화다 — 종전에는 "
                                 "WapleRender 의 static 이라 **리눅스에서 한 줄도 실행되지 않았다**. "
                                 "Tests/WapleCoreTests/HDRBloomMathTests.swift 17건이 WE 루프를 독립 "
                                 "재구현한 오라클과 전수 대조(폭 612종 × 높이 27종 × 요청 13종)하고, "
                                 "돌연변이 7건을 심어 7건 검출했다. **골든 스냅샷 재기준선이 필요하다** — "
                                 "256×144 에서 N 이 바뀌므로 HDR 블룸 씬의 썸네일 해시가 이동한다.",
                      },
                      "확정", [chain_ev,
                               specfmt.ev("binary",
                                          "wallpaper64.exe Composite::allocateTargets 0x14017f1b0–0x14017fa6f",
                                          "레벨 생성 루프와 N 산출"),
                               specfmt.ev("file", "Sources/WapleCore/HDRBloomMath.swift"),
                               specfmt.ev("file", "Tests/WapleCoreTests/HDRBloomMathTests.swift"),
                               code_ev]),
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
