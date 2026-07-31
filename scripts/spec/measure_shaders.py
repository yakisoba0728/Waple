"""WE 2.8.42 번들 셰이더(WEAssets/shaders) 전수 판독 → spec/engine/shaders.json.

셰이더 원문은 리포에 동봉돼 있다(Sources/WapleRender/Resources/WEAssets/shaders,
2.8.42 base-assets 추출본, .vert 54 + .frag 54 + .h 12 + .geom 3 = 123 + 서브디렉터리 13).
그래서 셰이더 사실 부분은 WE 설치본 없이 재현된다.

두 군데만 외부를 본다:
  - `#require LightingV1` 의 의미: wallpaper64.exe (WE_ROOT)
  - 헤더/함수 사용 census: 워크샵 코퍼스 (WE_WORKSHOP)
둘 다 없으면 그 항목이 빠져 산출이 달라지므로 **경로가 없으면 실패시킨다**(부분 산출 금지).

정본에 원문을 복사하지 않는다(spec/README.md §3). 담는 것은 파생 사실이다:
파일별 해시·인클루드·#require·COMBO·uniform 기본값·텍스처 슬롯·수식의 상수 표.

재현: python scripts/spec/measure_shaders.py   (git status 가 비어야 정상)
"""
import hashlib
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHADERS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets", "shaders")
OUT = os.path.join(REPO, "spec", "engine", "shaders.json")
UNIFORMS_JSON = os.path.join(REPO, "spec", "engine", "uniforms.json")
RT_JSON = os.path.join(REPO, "spec", "engine", "render-targets.json")

WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
WE_WORKSHOP = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WALLPAPER64 = os.path.join(WE_ROOT, "wallpaper64.exe")

BLEND_MSL = os.path.join(REPO, "Sources", "WapleRender", "BlendMSL.swift")
BUILTIN_INC = os.path.join(REPO, "Sources", "WapleCore", "BuiltinShaderIncludes.swift")

SRC_EXT = (".vert", ".frag", ".geom", ".h")

# ---------------------------------------------------------------- 정규식

RE_COMBO = re.compile(r"//\s*\[COMBO\]\s*(\{.*?\})\s*$", re.M)
RE_INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)
RE_REQUIRE = re.compile(r"^\s*#require\s+(\S+)", re.M)
RE_DEFINE = re.compile(r"^\s*#define\s+([A-Za-z_]\w*)", re.M)
RE_UNIFORM = re.compile(
    r"^\s*uniform\s+(?:(?:lowp|mediump|highp)\s+)?"
    r"([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*;"
    r"[ \t]*(?://\s*(\{.*\}))?",
    re.M,
)
RE_ATTRIB = re.compile(r"^\s*attribute\s+(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)", re.M)
RE_VARYING = re.compile(r"^\s*varying\s+(?:(?:lowp|mediump|highp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)", re.M)
RE_GREF = re.compile(r"\bg_[A-Za-z]\w*")
RE_COND = re.compile(r"^\s*#\s*(if|elif|ifdef|ifndef)\s+(.*)$", re.M)
RE_IDENT = re.compile(r"[A-Za-z_]\w*")
RE_TEXSLOT = re.compile(r"\bg_Texture(\d+)\b")
RE_FN = re.compile(r"^([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(([^;{]*)\)\s*\{", re.M)
RE_VEC3LIT = re.compile(
    r"vec3\(\s*(-?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)\s*,"
    r"\s*(-?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)\s*,"
    r"\s*(-?\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)\s*\)"
)

COND_NOISE = {"defined", "and", "or", "not"}


def rel_repo(path):
    return os.path.relpath(path, REPO).replace("\\", "/")


def rel_sh(path):
    """셰이더 루트 기준 경로. 정본 키가 길어지지 않게 이걸 쓴다."""
    return os.path.relpath(path, SHADERS).replace("\\", "/")


def sha16(data):
    return hashlib.sha256(data).hexdigest()[:16]


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def jparse(raw):
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"_unparsed": raw}


def scan_file(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8", "replace")
    body = strip_comments(text)

    uniforms = []
    for utype, uname, arr, meta in RE_UNIFORM.findall(text):
        u = {"name": uname, "type": utype}
        if arr:
            u["array"] = arr.strip("[]")
        m = jparse(meta)
        if m is not None:
            u["meta"] = m
        uniforms.append(u)

    cond_macros = set()
    for _, expr in RE_COND.findall(body):
        for ident in RE_IDENT.findall(expr):
            if ident in COND_NOISE or ident.isdigit():
                continue
            cond_macros.add(ident)

    return {
        "path": rel_sh(path),
        "ext": os.path.splitext(path)[1],
        "topLevel": os.path.dirname(rel_sh(path)) == "",
        "bytes": len(raw),
        "sha256_16": sha16(raw),
        "includes": sorted(set(RE_INCLUDE.findall(text))),
        "requires": sorted(set(RE_REQUIRE.findall(text))),
        "defines": sorted(set(RE_DEFINE.findall(text))),
        "combos": [jparse(m) for m in RE_COMBO.findall(text)],
        "uniforms": uniforms,
        "attributes": sorted({n for _, n in RE_ATTRIB.findall(text)}),
        "varyings": sorted({n for _, n in RE_VARYING.findall(text)}),
        "functions": [f"{r} {n}" for r, n, _ in RE_FN.findall(body)],
        "gRefs": sorted(set(RE_GREF.findall(body))),
        "textureSlots": sorted({int(n) for n in RE_TEXSLOT.findall(body)}),
        "condMacros": sorted(cond_macros),
        "vec3Literals": [tuple(g) for g in RE_VEC3LIT.findall(body)],
    }


# ------------------------------------------------------- 블러 커널 파생 계산


def unpair(offset, weight, lo):
    """바이리니어 1탭(offset, weight)을 정수 탭 lo, lo+1 로 되돌린다.

    lo*w_lo + (lo+1)*w_hi = offset*weight, w_lo + w_hi = weight.
    """
    w_hi = offset * weight - lo * weight
    return weight - w_hi, w_hi


def gaussian_sigma(w0, w1):
    """이웃 두 탭 비로 σ 역산: w1/w0 = exp(-1/(2σ²))."""
    if w0 <= 0 or w1 <= 0:
        return None
    r = math.log(w1 / w0)
    return None if r >= 0 else round(math.sqrt(-1.0 / (2.0 * r)), 4)


def blur_kernels():
    b13_center = 0.1976406528809576
    b13_pairs = [(1.4091998770852122, 0.2959855056006557, 1),
                 (3.2979348079914822, 0.0935333619980593, 3),
                 (5.2062900776825969, 0.0116608059608062, 5)]
    t13 = {0: b13_center}
    for off, w, lo in b13_pairs:
        a, b = unpair(off, w, lo)
        t13[lo], t13[lo + 1] = round(a, 6), round(b, 6)

    a0, a1 = unpair(0.469433779698372, 0.4044856614512112, 0)
    a2, a3 = unpair(2.3515644035337887, 0.2028175528299753, 2)
    n1, n2 = unpair(1.4091998770852121, 0.3213933537319605, 1)
    t7 = {0: round(a0, 6), 1: round(a1, 6), 2: round(a2, 6), 3: round(a3, 6),
          -1: round(n1, 6), -2: round(n2, 6), -3: 0.071303}

    bloom = [0.171834, 0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299]

    return {
        "common_blur.h::blur13 / blur13a": {
            "taps": 7, "form": "bilinear(13탭 근사)", "sampler": "g_Texture0 고정",
            "centerWeight": b13_center,
            "offsets±": [p[0] for p in b13_pairs],
            "sideWeights": [p[1] for p in b13_pairs],
            "weightSum": round(b13_center + 2 * sum(p[1] for p in b13_pairs), 12),
            "derived_integerTaps": {str(k): t13[k] for k in sorted(t13)},
            "derived_gaussianSigma": gaussian_sigma(t13[0], t13[1]),
        },
        "common_blur.h::blur7 / blur7a": {
            "taps": 4, "form": "bilinear-비대칭(7탭 근사)", "sampler": "g_Texture0 고정",
            "offsets": [2.3515644035337887, 0.469433779698372, -1.4091998770852121, -3.0],
            "weights": [0.2028175528299753, 0.4044856614512112,
                        0.3213933537319605, 0.0713034319868530],
            "weightSum": 1.0,
            "note": "부호가 비대칭이다 — +o1,+o2 는 더하고 o3,o4 는 빼며 o4 는 정확히 3.0",
            "derived_integerTaps": {str(k): t7[k] for k in sorted(t7)},
            "derived_gaussianSigma": gaussian_sigma(t7[0], t7[1]),
        },
        "common_blur.h::blur3 / blur3a": {
            "taps": 3, "form": "integer", "sampler": "g_Texture0 고정",
            "offsets": [-1.0, 0.0, 1.0], "weights": [0.25, 0.5, 0.25], "weightSum": 1.0,
        },
        "common_blur.h::blurRadial13a/7a/3a": {
            "form": "회전 샘플링", "sampler": "g_Texture0 고정",
            "amountScale": 0.025,
            "note": "amt *= 0.025 후 blur13/7/3 과 같은 offsets 를 라디안 회전각으로 쓴다. "
                    "blurRadial3a 는 회전각 amt 하나(0.5/0.25/0.25). "
                    "blurRadial7a 는 o3,o4 를 음수 회전으로 준다",
            "rotate": "blurRotateVec2(v,r) = (v.x·cos r − v.y·sin r, v.x·sin r + v.y·cos r)",
        },
        "blur_h_bloom.frag / downsample_eighth_blur_v.frag": {
            "taps": 13, "form": "integer(별도 커널 — common_blur.h 와 다르다)",
            "sampler": "g_Texture0",
            "strideExpr": "localTexel = g_TexelSize.<axis> * 8.0",
            "offsets": list(range(-6, 7)),
            "weights": bloom[:0:-1] + bloom,
            "weightSum": round(bloom[0] + 2 * sum(bloom[1:]), 12),
            "derived_gaussianSigma": gaussian_sigma(bloom[0], bloom[1]),
            "axisNote": "blur_h_bloom.vert 은 g_TexelSize.y 로 **Y(세로)** 를 이동하고, "
                        "downsample_eighth_blur_v.vert 은 g_TexelSize.x 로 **X(가로)** 를 이동한다 "
                        "— 파일명의 h/v 가 실제 이동축과 반대다. 파이프라인 순서는 "
                        "quarter --X--> eighth --Y--> bloom",
        },
        "_nameCollisionWarning":
            "common_blur.h::blur13 과 블룸 13탭은 **다른 커널**이다. "
            "전자는 7 바이리니어 탭(σ≈2.02), 후자는 13 정수탭(σ≈2.33). "
            "이름만 보고 옮기면 조용히 다른 글로우가 나온다",
        "_callingConvention": {
            "d 인자": "blur*(u, d) 의 d 는 UV 공간 스텝 벡터다. 한 축만 채우고 반대 축은 0 — "
                     "분리형 2패스로 쓴다",
            "stock blur_precise(WE 기본 효과)":
                "vert 이 `#if VERTICAL` 로 d = (0, g_Scale.y/g_Texture0Resolution.w) 또는 "
                "(g_Scale.x/g_Texture0Resolution.z, 0) 를 만든다. "
                "frag 은 KERNEL 콤보로 blur13a/blur7a/blur3a 를 고른다",
            "KERNEL 콤보": {"material": "ui_editor_properties_kernel_size", "type": "options",
                          "default": 0, "options": {"13x13": 0, "7x7": 1, "3x3": 2}},
            "blur_k3(번들)": "d = 1.0/g_Texture0Resolution.xy, VERTICAL 여부로 축 선택",
        },
    }


# ------------------------------------------------- 손-판독 표(원문 대조로 확정)

# common_blending.h:106-146 매크로 + 148-170 함수 + 172-271 ApplyBlending 디스패치.
# formula 는 스칼라 f-변형 기준(vec3 변형은 성분별 적용). opacity: mix=mix(A,r,o), none=그대로 반환.
BLEND_MODES = {
    0: ["Normal", "B", "mix", "BlendNormal — #if 어디에도 안 걸리는 기본 반환문"],
    1: ["Darken", "min(A, B)", "mix", "BlendDarkenf = min(blend, base)"],
    2: ["Multiply", "A * B", "mix", ""],
    3: ["ColorBurn", "B == 0 ? B : max(1 - (1-A)/B, 0)", "mix", "동등 비교가 원문 그대로"],
    4: ["Subtract", "max(A + B - 1, 0)", "mix", "BlendSubstract — 실제로는 linear burn"],
    5: ["Min", "min(A, B)", "none", "opacity 무시하고 즉시 반환"],
    6: ["Lighten", "max(A, B)", "mix", "BlendLightenf = max(blend, base)"],
    7: ["Screen", "1 - (1-A)*(1-B)", "mix", ""],
    8: ["ColorDodge", "B == 1 ? B : min(A/(1-B), 1)", "mix", ""],
    9: ["Add", "min(A + B, 1)", "mix", "BlendAdd 는 클램프 있다"],
    10: ["Max", "max(A, B)", "none", "opacity 무시하고 즉시 반환"],
    11: ["Overlay", "A < 0.5 ? 2AB : 1 - 2(1-A)(1-B)", "mix", "분기 기준은 base"],
    12: ["SoftLight", "B < 0.5 ? 2AB + A²(1-2B) : sqrt(A)(2B-1) + 2A(1-B)", "mix", "분기 기준은 blend"],
    13: ["HardLight", "Overlay(B, A)", "mix", "인자 뒤집은 Overlay"],
    14: ["VividLight", "B < 0.5 ? ColorBurn(A, 2B) : ColorDodge(A, 2(B-0.5))", "mix", ""],
    15: ["LinearLight", "B < 0.5 ? max(A+2B-1, 0) : A + 2(B-0.5)", "mix", "두 번째 가지는 클램프 없음"],
    16: ["PinLight", "B < 0.5 ? min(A, 2B) : max(A, 2(B-0.5))", "mix", ""],
    17: ["HardMix", "VividLight(A,B) < 0.5 ? 0 : 1", "mix", ""],
    18: ["Difference", "abs(A - B)", "mix", ""],
    19: ["Exclusion", "A + B - 2AB", "mix", ""],
    20: ["Substract", "max(A + B - 1, 0)", "mix", "모드 4 와 완전 동일식"],
    21: ["Reflect", "B == 1 ? B : min(A²/(1-B), 1)", "mix", ""],
    22: ["Glow", "Reflect(B, A)", "mix", "인자 뒤집은 Reflect"],
    23: ["Phoenix", "min(A,B) - max(A,B) + 1", "mix", ""],
    24: ["Average", "(A + B) / 2", "mix", ""],
    25: ["Negation", "1 - abs(1 - A - B)", "mix", ""],
    26: ["Hue", "HSL(hue=B, sat=A, lum=A)", "mix", "RGBToHSL/HSLToRGB 왕복"],
    27: ["Saturation", "HSL(hue=A, sat=B, lum=A)", "mix", ""],
    28: ["Color", "HSL(hue=B, sat=B, lum=A)", "mix", ""],
    29: ["Luminosity", "HSL(hue=A, sat=A, lum=B)", "mix", ""],
    30: ["Tint", "max(A.x, A.y, A.z) * B", "mix", "BlendTint"],
    31: ["AddScaled", "A + B*opacity", "none", "mix 를 안 쓰고 직접 opacity 곱"],
    32: ["SelfModulate", "mix(A, A + A*B, opacity)", "mix", ""],
}

# common_blending.h 에 정의만 있고 ApplyBlending 디스패치에서 안 쓰이는 매크로
BLEND_UNUSED = [
    "BlendLinearDodgef(base,blend) = base + blend (클램프 없음)",
    "BlendLinearDodge(base,blend) = min(base+blend, 1)",
    "BlendLinearBurnf/BlendLinearBurn = max(base+blend-1, 0)",
    "BlendOpacity(base,blend,F,O) = mix(base, F(base,blend), O)",
    "BlendReflectf 는 21/22 에서만, BlendPhoenix 는 23 에서만 쓰인다",
]


def composite_table():
    return {
        "uniforms": {
            "g_CompositeAlpha": {"material": "compositealpha", "default": 1, "range": [0.0, 2.0]},
            "g_CompositeOffset": {"material": "compositeoffset", "default": "0 0",
                                  "linked": True, "range": [-10.0, 10.0]},
            "g_CompositeColor": {"material": "compositecolor", "default": "1 1 1", "type": "color"},
        },
        "ApplyCompositeOffset": "COMPOSITE != 0 이면 texCoords + g_CompositeOffset/textureResolution, "
                               "아니면 texCoords 그대로",
        "COMPOSITEMONO==1": "effect.rgb = CAST3(greyscale(effect.rgb)) — **common.h 의 뒤집힌 "
                            "가중치 (0.11,0.59,0.3) 를 쓴다**. 그 다음 항상 effect.rgb *= g_CompositeColor",
        "COMPOSITE": {
            "0": "effect 만 반환(원본 무시). g_CompositeAlpha/Offset 미적용",
            "1": "effect.rgb = ApplyBlending(BLENDMODE, original.rgb, effect.rgb, "
                 "effect.a * g_CompositeAlpha); effect.a = max(effect.a*saturate(g_CompositeAlpha), original.a)",
            "2": "effect.a *= saturate(g_CompositeAlpha); effect = mix(effect, original, original.a) "
                 "— 효과를 원본 아래로",
            "3": "effect.a *= saturate(g_CompositeAlpha); effect.a *= 1 - original.a "
                 "— 원본이 투명한 곳만 남긴다",
        },
        "note": "COMPOSITE 는 #if 라 컴파일타임 상수다. BLENDMODE 도 마찬가지 — "
                "ApplyBlending 의 첫 인자 blendMode 는 선언만 있고 본문에서 안 쓰인다",
    }


def fog_table():
    return {
        "uniforms": {"FOG_DIST": ["g_FogDistanceColor(vec3)", "g_FogDistanceParams(vec4)"],
                     "FOG_HEIGHT": ["g_FogHeightColor(vec3)", "g_FogHeightParams(vec4)"]},
        "CalculateFogPixelState": "x = (viewDirLength - P.x)/P.y  [FOG_DIST], "
                                  "y = (worldPosHeight - P.x)/P.y  [FOG_HEIGHT], 없으면 0",
        "ApplyFog": "HEIGHT 를 **먼저**, DIST 를 나중에 적용한다. "
                    "각 단계: color = mix(color, fogColor, P.z + P.w · saturate(t)²)",
        "ApplyFogAlpha": "fogFactor = saturate(max(distTerm, heightTerm)); "
                         "return alpha * (1 - fogFactor²)  — 항이 한 번 더 제곱된다",
        "paramLayout": "params = (start, span, baseDensity, deltaDensity)",
    }


def pbr_table():
    return {
        "FresnelSchlick": "F0 + (1-F0)·pow(max(1-cosθ, 0.001), 5)",
        "Distribution_GGX": "a=r²; a2=a²; NH=max(dot(N,H),0); "
                            "denom=(NH²(a2-1)+1); return a2/(π·denom²)",
        "Schlick_GGX": "k=(r+1)²/8; return NV/(NV(1-k)+k)   — 직접광 k",
        "GeoSmith": "Schlick_GGX(max(dot(N,V),0.001), r) · Schlick_GGX(max(dot(N,L),0.001), r)",
        "PointSegmentDelta": "v=dot(d,d); v==0 이면 A-pos, 아니면 "
                             "A + saturate(dot(pos-A, B-A)/v)·(B-A) - pos",
        "specularDenominator": "4·max(dot(N,V),0)·NL, max(·, 0.001) 로 하한",
        "diffuse": "(1-metallic)·(1-F);  최종 = (diffuse·albedo/π + specular[·specularTint])·radiance·NL",
        "common_pbr.h::ComputePBRLight": {
            "radiance": "lightColor / distance²  (역제곱, 반경/지수 없음)",
            "rimStepThreshold": 0.01,
            "hasShadow": False, "hasSpecularTint": False,
        },
        "common_pbr_2.h::ComputePBRLightShadow": {
            "falloff": "saturate(1 - distance/radius)",
            "radiance_HLSL": "lightColor · pow(falloff + 1.17549435e-38, exponent)",
            "radiance_GLSL": "lightColor · mix(0, pow(falloff + 6.103515625e-5, exponent), "
                             "step(0, falloff - 6.103515625e-5))",
            "NDF": "shadowFactor · Distribution_GGX(...)   — 섀도우가 NDF 에 곱해진다",
            "NL": "max(dNL · shadowFactor, 0);  GRADIENT_SAMPLER 경로는 "
                  "max(min(shadowFactor, dNL)·0.5 + 0.5, 0)",
            "rimStepThreshold": 0.001,
            "hasShadow": True, "hasSpecularTint": True,
        },
        "common_pbr_2.h::ComputePBRLightShadowInfinite": {
            "radiance": "lightColor 그대로(감쇠 없음) — directional",
            "note": "L 을 정규화하지 않는다(호출부가 정규화된 방향을 준다)",
        },
        "RIMLIGHTING": "rim = pow(1-max(dot(N,V),0), RIM_LIGHTING_EXPONENT) · RIM_LIGHTING_AMOUNT "
                       "· NL · step(threshold, ΣlightColor);  NL=max(NL,rim); metallic -= saturate(rim). "
                       "pbr.h threshold=0.01, pbr_2.h=0.001. "
                       "매크로 실체: RIM_LIGHTING_AMOUNT=g_RimAmount(기본 2.0, [0,5]), "
                       "RIM_LIGHTING_EXPONENT=g_RimExponent(기본 4.0, [0.01,10])",
        "GRADIENT_SAMPLER": "SHADINGGRADIENT 시 g_Texture4 = gradient/gradient_toon_smooth. "
                            "NL 을 (NL·0.5+0.5) 로 매핑해 1D 그라디언트 LUT 를 x 로 샘플. "
                            "TEX4FORMAT 이 R8/RG88 이면 .rrr, 아니면 .rgb",
        "CombineLighting": "HDR: len=length(light); over=(saturate(len-2)·0.5)/max(0.01,len); "
                           "saturate(ambient+light) + light·over. 비HDR: ambient+light. "
                           "3인자 변형(pbr_2.h)은 max(baseAmbient, ·)",
        "PerformShadowMapping": {
            "QUALITY==1": "1탭 texSample2DCompare",
            "else": "9탭 / 9.0. roundOffset = SHADOW_ATLAS_TEXEL.xy·0.81616, "
                    "offsets = SHADOW_ATLAS_TEXEL.xy·1.02323",
            "SHADOW_ATLAS_ANTIALIAS": "헤더에서 0 으로 하드코딩(#define SHADOW_ATLAS_ANTIALIAS 0) — "
                                      "random() 지터 경로는 죽어 있다",
        },
        "CalculateProjectedCoords": "proj/=w; xy = xy·(0.5,-0.5)+0.5; y = mix(y, 2.0, step(w,0)) "
                                    "— 뒤쪽 투영을 UV 밖으로 밀어낸다",
        "CalculateProjectedCoordsCascades": "REVERSEDEPTH 여부로 범위 밖 판정식이 갈린다. "
                                            "xy = xy·0.5+0.5; y = 1-y",
        "CalculateProjectedCoordsPoint": {
            "viewportScale": [0.5, 0.3333],
            "compensation_Q1_Q2": [0.47, -0.47],
            "compensation_Q3": [0.48, -0.48],
            "compensation_else": [0.49, -0.49],
            "note": "큐브 6면을 3×2 아틀라스 타일로. 축별 뷰행렬 6종이 하드코딩돼 있다",
        },
    }


def common_h_table():
    return {
        "constants": {"M_PI": 3.14159265359, "M_PI_HALF": 1.57079632679,
                      "M_PI_2": 6.28318530718, "SQRT_2": 1.41421356237, "SQRT_3": 1.73205080756},
        "hsv2rgb": "K=(1, 2/3, 1/3, 3); p=abs(frac(c.xxx+K.xyz)*6 - K.www); "
                   "return c.z·mix(K.xxx, clamp(p-K.xxx,0,1), c.y)",
        "rgb2hsv": "분기형 min/max 방식, 1e-10 안전항 2회",
        "rotateVec2": "(v.x·cos r − v.y·sin r, v.x·sin r + v.y·cos r)  — 반시계",
        "greyscale": {
            "weights": [0.11, 0.59, 0.3],
            "expr": "dot(color, vec3(0.11, 0.59, 0.3))",
            "anomaly": "R 에 0.11, B 에 0.3 이 걸린다 — NTSC (0.3,0.59,0.11) 의 **역순**. "
                       "같은 리포의 common_blending.h::Desaturate 는 (0.3,0.59,0.11) 로 올바르다. "
                       "WE 원문 그대로이므로 '버그를 그대로 이식' 해야 픽셀이 맞는다",
        },
    }


def luma_table():
    return {
        "(0.11, 0.59, 0.3)": {
            "where": ["common.h:36 greyscale()"],
            "consumers": ["common_composite.h:21 ApplyComposite (COMPOSITEMONO==1)",
                          "워크샵 이펙트가 greyscale() 직접 호출"],
            "note": "R/B 가 뒤집힌 NTSC. WE 안에서 유일하게 뒤집힌 벡터다",
        },
        "(0.3, 0.59, 0.11)": {
            "where": ["common_blending.h:4 Desaturate() grayXfer",
                      "brushinvert.frag:12 lightness"],
            "note": "정상 NTSC/Rec.601 근사(0.299/0.587/0.114 의 반올림)",
        },
        "(0.2125, 0.7154, 0.0721)": {
            "where": ["common_blending.h:96 ContrastSaturationBrightness() LumCoeff"],
            "note": "Rec.709. 같은 파일 안에서 Desaturate 와 다른 벡터를 쓴다",
        },
        "(0.299, 0.587, 0.114)": {
            "where": ["chroma4.frag:159 tint pigmentation",
                      "combine_hdr.frag:31 DISPLAYHDR 밝기 판정"],
            "note": "정확한 Rec.601",
        },
        "(0.2989, 0.5870, 0.1140)": {
            "where": ["downsample_quarter_bloom.frag:21 블룸 추출 채도 부스트"],
            "note": "Rec.601 을 4자리로 쓴 또 다른 표기 — 위와 값이 미세하게 다르다(0.2989 vs 0.299)",
        },
        "_summary": "WE 안에 luma **가중치 벡터**가 5종 공존한다. 그중 1종(common.h::greyscale)은 "
                    "성분 순서가 뒤집혀 있고, 2종(0.299… / 0.2989…)은 같은 Rec.601 의 다른 반올림이다",
        "_nonVectorLuminanceProxies":
            "WE 는 벡터가 아닌 밝기 대용치도 쓴다. 이걸 위 5종 중 하나로 바꿔치면 안 된다: "
            "(1) 최대성분 max(r,g,b) — hdr_downsample.frag brightness, "
            "downsample_quarter_bloom.frag scale, BlendTint(common_blending.h:146); "
            "(2) HSL lightness (fmax+fmin)/2 — RGBToHSL, 블렌드 모드 26-29; "
            "(3) length(light) — CombineLighting 의 overbright 판정; "
            "(4) ContrastSaturationBrightness 는 AvgLumin=(0.5,0.5,0.5) 상수를 대비 기준점으로 쓴다",
    }


def require_table(binary_hits):
    return {
        "directive": "#require <name> — WE 셰이더 전처리기 지시자. "
                     "wallpaper64.exe 의 지시자 정규식 `^\\s*#\\s*([a-z]+)\\b\\s*(.*)` 가 파싱하고 "
                     "키워드 목록에 'require' 가 있다",
        "knownValues": ["LightingV1"],
        "LightingV1": {
            "usedBy": ["chroma4.frag", "foliage4.frag", "fur4.frag", "generic4.frag",
                       "genericimage4.frag", "genericparticle.frag", "genericropeparticle.frag"],
            "injects": {
                "function": "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, "
                            "vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, "
                            "float metallic)",
                "uniformArrays": [
                    "uniform vec4 g_LPoint_Origin[]", "uniform vec4 g_LPoint_Color[]",
                    "uniform vec4 g_LSpot_Origin[]", "uniform vec4 g_LSpot_Color[]",
                    "uniform vec4 g_LSpot_Direction[]", "uniform vec4 g_LSpot_Exponent[]",
                    "uniform vec4 g_LTube_OriginA[]", "uniform vec4 g_LTube_OriginB[]",
                    "uniform vec4 g_LTube_Color[]",
                    "uniform vec4 g_LDirectional_Direction[]", "uniform vec4 g_LDirectional_Color[]",
                    "uniform vec4 g_LFeature_ShadowProjectionTransform[]",
                    "uniform mat4 g_LFeature_ShadowProjection[]",
                    "uniform vec4 g_LFeature_ShadowPointProjection[]",
                    "uniform vec4 g_LFeature_ShadowPointProjectionTransform[]",
                ],
                "calls": ["ComputePBRLightShadow", "ComputePBRLightShadowInfinite",
                          "PerformShadowMapping", "PerformPointShadowMapping",
                          "PointSegmentDelta", "CalculateProjectedCoords",
                          "CalculateProjectedCoordsCascades", "CalculateProjectedCoordsPoint"],
                "spot": "spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz); "
                        "spotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie)",
                "cookie": "colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb "
                          "→ g_LSpot_Color[i].rgb 에 곱",
                "cascades": "p1/p2/p3 3단 CSM. projectedCoords1.xyz 를 w 로 mix 하고 "
                            "uvTransforms 도 같은 w 로 mix. "
                            "shadowFactor = max(projectedCoords3.w, PerformShadowMapping(...))",
                "argOrder": "ComputePBRLightShadow(N, L, V, albedo, lightColor, **radius**, "
                            "**exponent**, specularTint, baseReflectance(=f0), roughness, metallic, "
                            "shadowFactor) — 헤더 시그니처(common_pbr_2.h:256-257)의 "
                            "6번째가 radius, 7번째가 exponent 다",
                "lightVec4Packing": {
                    "point": "g_LPoint_Color = (r,g,b, **radius**), "
                             "g_LPoint_Origin = (x,y,z, **exponent**)",
                    "spot": "g_LSpot_Color = (r,g,b, **radius**), "
                            "g_LSpot_Exponent.x = **exponent**, "
                            "g_LSpot_Origin = (x,y,z, cone smoothstep edge1), "
                            "g_LSpot_Direction = (x,y,z, cone smoothstep edge0)",
                    "tube": "g_LTube_Color = (r,g,b, **radius**), "
                            "g_LTube_OriginA = (x,y,z, **exponent**), g_LTube_OriginB = (x,y,z, ·)",
                    "directional": "ComputePBRLightShadowInfinite 를 쓴다 — radius/exponent 인자 자체가 없다",
                    "howDerived": "spot 호출(파일오프셋 0x48b2e1)의 7번째 인자가 리터럴로 "
                                  "g_LSpot_Exponent[i].x 다 → 7=exponent 확정 → 6=radius. "
                                  "같은 자리 규칙을 point(0x48b151)/tube(0x48b7e1) 호출에 대입했다. "
                                  "ComputePBRLightShadow 오버로드가 하나뿐이라 강제된다",
                },
            },
            "binaryHits": binary_hits,
        },
        "predecessor": "generic3.frag / genericimage3.frag 는 #require 없이 같은 일을 "
                       "셰이더 안에서 직접 한다(PerformLighting_Deprecated + "
                       "#if LIGHTS_POINT/SPOT/TUBE/DIRECTIONAL 로 uniform 배열 자체 선언). "
                       "`#if SHADERVERSION < 62` 로 구/신 경로가 갈린다",
    }


# ---------------------------------------------------------- 외부 소스 스캔


def scan_binary():
    if not os.path.exists(WALLPAPER64):
        sys.exit(f"wallpaper64.exe 가 없다: {WALLPAPER64}  (WE_ROOT 를 설정해라)")
    with open(WALLPAPER64, "rb") as fh:
        data = fh.read()
    out = {}
    for pat in (b"LightingV1", b"PerformLighting_V1", b"require",
                b"vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, "
                b"vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)",
                b"uniform vec4 g_LPoint_Origin[", b"uniform mat4 g_LFeature_ShadowProjection[",
                b"#define GS_ENABLED 1", b"SHADERVERSION"):
        offs = [m.start() for m in re.finditer(re.escape(pat), data)]
        key = pat.decode()[:60]
        out[key] = {"count": len(offs), "firstFileOffset": hex(offs[0]) if offs else None}
    return out


CORPUS_PATTERNS = {
    'include "common.h"': b'#include "common.h"',
    'include "common_blending.h"': b'#include "common_blending.h"',
    'include "common_blur.h"': b'#include "common_blur.h"',
    'include "common_composite.h"': b'#include "common_composite.h"',
    'include "common_fog.h"': b'#include "common_fog.h"',
    'include "common_foliage.h"': b'#include "common_foliage.h"',
    'include "common_fragment.h"': b'#include "common_fragment.h"',
    'include "common_particles.h"': b'#include "common_particles.h"',
    'include "common_pbr.h"': b'#include "common_pbr.h"',
    'include "common_pbr_2.h"': b'#include "common_pbr_2.h"',
    'include "common_perspective.h"': b'#include "common_perspective.h"',
    'include "common_vertex.h"': b'#include "common_vertex.h"',
    "call blur13a(": b"blur13a(",
    "call blur13(": b"blur13(",
    "call blur7a(": b"blur7a(",
    "call blur7(": b"blur7(",
    "call blur3a(": b"blur3a(",
    "call blur3(": b"blur3(",
    "call blurRadial": b"blurRadial",
    "call greyscale(": b"greyscale(",
    "call ApplyComposite(": b"ApplyComposite(",
    "call ApplyBlending(": b"ApplyBlending(",
    "call ContrastSaturationBrightness(": b"ContrastSaturationBrightness(",
    "call Desaturate(": b"Desaturate(",
    "call squareToQuad(": b"squareToQuad(",
    "macro COMPOSITEMONO": b"COMPOSITEMONO",
    "macro COMPOSITE(+MONO 포함)": b"COMPOSITE",
    "macro BLENDMODE": b"BLENDMODE",
    "directive #require": b"#require",
    # 헤더 '정의'가 pkg 안에 들어 있는지 — 0 이면 #include 는 기본 에셋 팩에서만 해소된다
    "DEF vec3 blur13(vec2 u, vec2 d)": b"vec3 blur13(vec2 u, vec2 d)",
    "DEF float greyscale(vec3 color)": b"float greyscale(vec3 color)",
    "DEF vec4 ApplyComposite(vec4 original, vec4 effect)":
        b"vec4 ApplyComposite(vec4 original, vec4 effect)",
    "DEF vec3 ApplyBlending(const int blendMode":
        b"vec3 ApplyBlending(const int blendMode",
    "DEF mat3 squareToQuad(vec2 p0": b"mat3 squareToQuad(vec2 p0",
}
CORPUS_EXT = (".pkg", ".json", ".frag", ".vert", ".h", ".geom")


def scan_corpus():
    if not os.path.isdir(WE_WORKSHOP):
        sys.exit(f"워크샵 코퍼스가 없다: {WE_WORKSHOP}  (WE_WORKSHOP 을 설정해라)")
    occ = {k: 0 for k in CORPUS_PATTERNS}
    projects = {k: set() for k in CORPUS_PATTERNS}
    scanned = 0
    all_projects = set()
    for dirpath, dirnames, filenames in os.walk(WE_WORKSHOP):
        dirnames.sort()
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1].lower() not in CORPUS_EXT:
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            scanned += 1
            proj = os.path.relpath(path, WE_WORKSHOP).replace("\\", "/").split("/")[0]
            all_projects.add(proj)
            for key, pat in CORPUS_PATTERNS.items():
                c = data.count(pat)
                if c:
                    occ[key] += c
                    projects[key].add(proj)
    usage = {k: {"occurrences": occ[k], "projects": len(projects[k])}
             for k in sorted(CORPUS_PATTERNS)}
    # COMPOSITEMONO 는 COMPOSITE 를 정확히 1회 포함한다 → 차가 순수 COMPOSITE 출현 수다.
    usage["macro COMPOSITE(MONO 제외, 파생)"] = {
        "occurrences": occ["macro COMPOSITE(+MONO 포함)"] - occ["macro COMPOSITEMONO"],
        "projects": None,
        "note": "부분문자열 겹침 보정. 프로젝트 수는 이 방식으로 분리되지 않아 null",
    }
    return {
        "scannedFiles": scanned,
        "scannedExtensions": list(CORPUS_EXT),
        "projectsWithScannedFiles": len(all_projects),
        "usage": dict(sorted(usage.items())),
        "caveat": ".pkg 안의 셰이더 텍스트를 평문 바이트 검색한 결과다. "
                  "압축·인코딩된 엔트리가 있으면 하한값이다. "
                  "부분문자열 겹침은 COMPOSITE⊃COMPOSITEMONO 하나뿐이며 위에서 보정했다 "
                  "(blur13a/blur3a/blurRadial3a, ApplyComposite/ApplyCompositeOffset 은 "
                  "여는 괄호까지 포함해 서로 겹치지 않는다)",
        "headerShippedInPkg": "워크샵 pkg 는 WE 공통 헤더의 **정의**를 담지 않는다 — "
                              "`vec3 blur13(vec2 u, vec2 d)` / `float greyscale(vec3 color)` / "
                              "`vec4 ApplyComposite(vec4 original, vec4 effect)` 원문 정의 출현 0회. "
                              "즉 #include 는 엔진 기본 에셋 팩에서만 해소된다",
    }


def scan_waple_parity():
    """Waple 쪽 두 파일에서 기계적으로 확인 가능한 것만 뽑는다(의미 판정은 사람이)."""
    out = {}
    with open(BLEND_MSL, encoding="utf-8") as fh:
        msl = fh.read()
    with open(BUILTIN_INC, encoding="utf-8") as fh:
        inc = fh.read()
    # 해시는 일부러 담지 않는다 — Swift 파일을 고칠 때마다 정본이 더러워지면
    # README 의 "재측정 후 git status 가 비어야 한다" 신호가 오염된다.
    out["BlendMSL.swift"] = {
        "modes": sorted(int(m) for m in re.findall(r"case\s+(\d+):", msl)),
        "hasDefault": "default:" in msl,
        "epsilons": sorted(set(re.findall(r"1e-\d+", msl))),
    }
    out["BuiltinShaderIncludes.swift"] = {
        "modes": sorted(int(m) for m in re.findall(r"mode\s*==\s*(\d+)", inc)),
        "headersProvided": sorted(set(re.findall(r'case\s+"([^"]+\.h)"', inc))),
    }
    out["expectedModes"] = sorted(k for k in BLEND_MODES if k != 0)
    out["modeCoverageOK"] = (out["BlendMSL.swift"]["modes"] == out["expectedModes"]
                             and out["BuiltinShaderIncludes.swift"]["modes"] == out["expectedModes"])
    return out


# ---------------------------------------------------------------- 본체


def main():
    files = []
    for dirpath, dirnames, filenames in os.walk(SHADERS):
        dirnames.sort()
        for fn in sorted(filenames):
            if os.path.splitext(fn)[1] in SRC_EXT:
                files.append(os.path.join(dirpath, fn))
    files.sort(key=rel_sh)
    scans = [scan_file(p) for p in files]

    counts_top, counts_all = {}, {}
    for s in scans:
        counts_all[s["ext"]] = counts_all.get(s["ext"], 0) + 1
        if s["topLevel"]:
            counts_top[s["ext"]] = counts_top.get(s["ext"], 0) + 1

    # --- COMBO 선언
    declared = {}
    for s in scans:
        for c in s["combos"]:
            name = c.get("combo")
            if not name:
                continue
            rec = declared.setdefault(name, {"declaredIn": set(), "defaults": []})
            rec["declaredIn"].add(s["path"])
            if "default" in c and c["default"] not in rec["defaults"]:
                rec["defaults"].append(c["default"])
            for k in ("options", "material", "require"):
                if c.get(k) and k not in rec:
                    rec[k] = c[k]
    for name, rec in declared.items():
        rec["declaredIn"] = sorted(rec["declaredIn"])
        rec["defaults"] = sorted(rec["defaults"], key=str)
        if not rec["defaults"]:
            rec["defaults"] = "선언에 default 없음 — 엔진이 값을 준다"
    declared = dict(sorted(declared.items()))

    # --- 텍스처 선언에서 유래하는 combo
    texture_combos = {}
    for s in scans:
        for u in s["uniforms"]:
            m = u.get("meta") or {}
            slot = RE_TEXSLOT.match(u["name"])
            if m.get("combo"):
                texture_combos.setdefault(m["combo"], set()).add(f'{s["path"]}:{u["name"]}')
            for comp in m.get("components") or []:
                if comp.get("combo"):
                    texture_combos.setdefault(comp["combo"], set()).add(
                        f'{s["path"]}:{u["name"]}.components')
            if m.get("formatcombo") and slot:
                texture_combos.setdefault(f"TEX{slot.group(1)}FORMAT", set()).add(
                    f'{s["path"]}:{u["name"]}(formatcombo)')
    texture_combos = {k: sorted(v) for k, v in sorted(texture_combos.items())}

    # --- 어디에도 선언되지 않은 #if 매크로 = 엔진 주입
    all_defines = set()
    for s in scans:
        all_defines |= set(s["defines"])
    engine_injected = {}
    for s in scans:
        for m in s["condMacros"]:
            if m in declared or m in texture_combos or m in all_defines:
                continue
            engine_injected.setdefault(m, set()).add(s["path"])
    engine_injected = {k: sorted(v) for k, v in sorted(engine_injected.items())}

    # --- 텍스처 슬롯
    tex = {}
    for s in scans:
        for u in s["uniforms"]:
            if not u["type"].startswith("sampler"):
                continue
            mo = RE_TEXSLOT.match(u["name"])
            r = tex.setdefault(u["name"], {"slot": int(mo.group(1)) if mo else None,
                                           "types": set(), "defaults": set(),
                                           "combos": set(), "declaredIn": set()})
            r["types"].add(u["type"])
            m = u.get("meta") or {}
            if m.get("default"):
                r["defaults"].add(m["default"])
            if m.get("combo"):
                r["combos"].add(m["combo"])
            for comp in m.get("components") or []:
                if comp.get("combo"):
                    r["combos"].add(comp["combo"])
            r["declaredIn"].add(s["path"])
    tex = {k: {"slot": v["slot"], "types": sorted(v["types"]),
               "defaults": sorted(v["defaults"]), "combos": sorted(v["combos"]),
               "declaredIn": sorted(v["declaredIn"])}
           for k, v in sorted(tex.items())}

    # --- 샘플러 별칭 매크로가 셰이더별로 어느 슬롯을 가리키나
    RE_ALIAS = re.compile(r"^\s*#define\s+(GRADIENT_SAMPLER|SHADOW_ATLAS_SAMPLER|COOKIE_SAMPLER"
                          r"|SHADOW_ATLAS_TEXEL)\s+(\S+)", re.M)
    sampler_alias = {}
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for macro, target in RE_ALIAS.findall(fh.read()):
                sampler_alias.setdefault(macro, {}).setdefault(target, set()).add(rel_sh(path))
    sampler_alias = {m: {t: sorted(v) for t, v in sorted(d.items())}
                     for m, d in sorted(sampler_alias.items())}

    # --- g_* 참조
    g_used = {}
    for s in scans:
        for g in s["gRefs"]:
            g_used.setdefault(g, set()).add(s["path"])
    g_used = {k: sorted(v) for k, v in sorted(g_used.items())}

    binset = set()
    d = specfmt.load(UNIFORMS_JSON)
    for e in d["entries"]:
        if e["id"] == "engine.uniforms":
            binset = set(e["value"].keys())
    cross = {
        "binaryUniformCount": len(binset),
        "shaderRefCount": len(g_used),
        "inBoth": len(binset & set(g_used)),
        "shaderOnly": sorted(set(g_used) - binset),
        "binaryOnly": sorted(binset - set(g_used)),
        "interpretation": "uniforms.json 은 wallpaper64.exe 가 이름으로 아는 **엔진 제공** "
                          "유니폼이고, shaderOnly 는 셰이더가 선언하는 **머티리얼 파라미터**다. "
                          "불일치가 아니라 두 계층의 구분이다",
    }

    rts = set()
    d = specfmt.load(RT_JSON)
    for e in d["entries"]:
        if e["id"] == "engine.renderTargets":
            rts = set(e["value"].keys())
    used_rt = {dv for v in tex.values() for dv in v["defaults"]
               if dv.startswith("_rt_") or dv.startswith("_alias_")}
    rt_cross = {"binaryCount": len(rts), "shaderDefaults": sorted(used_rt),
                "notInBinary": sorted(used_rt - rts)}

    # --- 헤더 함수 목록
    headers = {s["path"]: {"sha256_16": s["sha256_16"], "bytes": s["bytes"],
                           "includes": s["includes"], "functions": s["functions"],
                           "defines": s["defines"], "condMacros": s["condMacros"]}
               for s in scans if s["ext"] == ".h"}

    header_users = {}
    for s in scans:
        for inc in s["includes"]:
            header_users.setdefault(inc, set()).add(s["path"])
    header_users = {k: sorted(v) for k, v in sorted(header_users.items())}

    requires = {}
    for s in scans:
        for r in s["requires"]:
            requires.setdefault(r, set()).add(s["path"])
    requires = {k: sorted(v) for k, v in sorted(requires.items())}

    # --- 파일별 요약
    per_file = {}
    for s in scans:
        e = {"sha256_16": s["sha256_16"], "bytes": s["bytes"]}
        for k in ("includes", "requires", "attributes", "varyings", "textureSlots",
                  "functions", "condMacros", "gRefs"):
            if s[k]:
                e[k] = s[k]
        if s["combos"]:
            e["combos"] = [{"combo": c.get("combo"), "default": c.get("default")}
                           for c in s["combos"]]
        if s["uniforms"]:
            e["uniforms"] = [
                {kk: vv for kk, vv in (("name", u["name"]), ("type", u["type"]),
                                       ("array", u.get("array")),
                                       ("default", (u.get("meta") or {}).get("default")),
                                       ("range", (u.get("meta") or {}).get("range")),
                                       ("material", (u.get("meta") or {}).get("material")))
                 if vv is not None}
                for u in s["uniforms"]]
        per_file[s["path"]] = e

    # --- luma 후보(축 벡터 제외: 성분 하나라도 0 또는 1 이면 luma 가 아니다)
    luma_scan = {}
    for s in scans:
        for a, b, c in s["vec3Literals"]:
            vals = [float(a), float(b), float(c)]
            if not (0.9 <= sum(vals) <= 1.1):
                continue
            if any(v in (0.0, 1.0) for v in vals):
                continue
            luma_scan.setdefault(f"({a}, {b}, {c})", set()).add(s["path"])
    luma_scan = {k: sorted(v) for k, v in sorted(luma_scan.items())}

    binary_hits = scan_binary()
    corpus = scan_corpus()
    parity = scan_waple_parity()

    # ------------------------------------------------------------ 정본 항목
    A = specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/shaders (WE 2.8.42 base-assets 동봉본)")
    S = specfmt.ev("script", "scripts/spec/measure_shaders.py")
    E = specfmt.entry

    entries = [
        E("shaders.inventory", {"totalScanned": len(scans),
                                "topLevel": counts_top, "allIncludingSubdirs": counts_all,
                                "subdirs": ["HLSL", "base", "editor"],
                                "nonShaderFile": "declarations.json (임포터 프리셋 — 셰이더 아님)"},
          "확정", [A, S]),
        E("shaders.files", per_file, "확정", [A, S]),
        E("shaders.headers", headers, "확정",
          [A, S, specfmt.ev("doc", "12개 공통 헤더의 함수 시그니처 전수")]),
        E("shaders.headerUsers", header_users, "확정", [A, S]),

        E("shaders.common_h", common_h_table(), "확정",
          [specfmt.ev("shader", "shaders/common.h:1-37"), S]),
        E("shaders.blending.modes", BLEND_MODES, "확정",
          [specfmt.ev("shader", "shaders/common_blending.h:106-271"), S,
           specfmt.ev("doc", "value = [이름, 식, opacity적용방식, 비고]. "
                             "A=base(dst), B=blend(src), o=opacity")]),
        E("shaders.blending.dispatch",
          {"signature": "vec3 ApplyBlending(const int blendMode, in vec3 A, in vec3 B, in float opacity)",
           "mechanism": "본문이 `#if BLENDMODE == N` 프리프로세서 분기다. "
                        "인자 blendMode 는 **본문에서 한 번도 쓰이지 않는다** — "
                        "블렌드 모드는 런타임 값이 아니라 컴파일타임 특수화다",
           "fallthrough": "어느 #if 에도 안 걸리면 mix(A, B, opacity) (Normal)",
           "undefinedBLENDMODE": "GLSL 전처리기에서 미정의 매크로는 0 → Normal",
           "noOpacityModes": [5, 10, 31],
           "unusedMacros": BLEND_UNUSED,
           "hdrGuard": "RGBToHSL 은 `#ifdef HDR` 일 때만 입력을 saturate 한다 "
                       "— 모드 26-29 의 HDR 거동이 갈린다"},
          "확정", [specfmt.ev("shader", "shaders/common_blending.h:9-13,172-271"), S]),
        E("shaders.blending.wapleParity", parity, "확정",
          [specfmt.ev("file", "Sources/WapleRender/BlendMSL.swift"),
           specfmt.ev("file", "Sources/WapleCore/BuiltinShaderIncludes.swift"), S,
           specfmt.ev("doc", "모드 번호 커버리지만 기계 검사. 식 동등성은 사람이 대조했다")]),

        E("shaders.blurKernels", blur_kernels(), "확정",
          [specfmt.ev("shader", "shaders/common_blur.h, shaders/blur_h_bloom.frag, "
                                "shaders/downsample_eighth_blur_v.frag, shaders/blur_k3.frag"), S,
           specfmt.ev("doc", "offsets/weights 는 원문 리터럴(확정). derived_* 는 스크립트가 "
                             "역산한 파생값으로 원문에 없다")]),
        E("shaders.bloom",
          {"LDR": {"extract": "downsample_quarter_bloom.frag — 4탭(a_TexCoord ± g_TexelSize 대각) "
                              "×0.25 → scale=max(rgb) → rgb *= saturate(scale - g_BloomThreshold) "
                              "→ gray=dot((0.2989,0.5870,0.1140), rgb); sat=1.0; "
                              "rgb = -gray·sat + rgb·(1+sat)  (= 2·rgb - gray) "
                              "→ max(0, rgb·g_BloomStrength·g_BloomTint)",
                   "blur": "blur_h_bloom.frag + downsample_eighth_blur_v.frag, 13정수탭, "
                           "스트라이드 g_TexelSize·8.0",
                   "combine": "combine.frag — albedo + bloom (클램프 없음)",
                   "defaults": {"g_BloomStrength": {"default": 2, "range": [0, 4]},
                                "g_BloomThreshold": {"default": 0.65, "range": [0, 0.999]},
                                "g_BloomTint": {"default": "1 1 1"}}},
           "HDR": {"downsample": "hdr_downsample.frag — 4탭(v_TexCoord + g_RenderVar0.xy/.zy/.xw/.zw) "
                                 "×0.25, UPSAMPLE 이면 ×g_BloomScatter 추가",
                   "softKnee": "brightness=max(rgb); soft=clamp(brightness-P.y, 0, P.z); "
                               "soft=soft²·P.w; contribution=max(soft, brightness-P.x); "
                               "contribution /= max(brightness, 0.00001); "
                               "rgb *= contribution·g_BloomStrength·g_BloomTint",
                   "defaults": {"g_BloomStrength": {"default": 2},
                                "g_BloomBlendParams": {"default": "1 1 0 1",
                                                       "note": "P.z=0 이라 기본값에선 soft knee 가 죽는다"},
                                "g_BloomTint": {"default": "1 1 1"},
                                "g_BloomScatter": {"default": 1}},
                   "BICUBIC": "cubic(v) B-스플라인 4탭 + bilinear 4샘플 조합",
                   "combine": "combine_hdr.frag — bloom1 은 g_TexelSize 대각 4탭 ×0.25. "
                              "DISPLAYHDR==1: saturate(albedo)+bloom → "
                              "hdrFactors = g_RenderVar0.y·smoothstep(1,5, dot((0.299,0.587,0.114), albedo)) "
                              "+ g_RenderVar0.x → lin(max(0,albedo))·hdrFactors. "
                              "LINEAR==1: saturate(albedo). 그 외: saturate(lin(albedo))·g_RenderVar0.x",
                   "lin()": "c=step(0.04045,v); c·pow((v+0.055)/1.055, 2.4) + (1-c)·(v/12.92) "
                            "— 이름은 lin 이지만 sRGB→linear 식이고, combine_hdr_editor.frag 는 "
                            "**같은 식을 srgb() 라 부른다**"}},
          "확정", [specfmt.ev("shader", "shaders/downsample_quarter_bloom.frag, shaders/blur_h_bloom.*, "
                                       "shaders/downsample_eighth_blur_v.*, shaders/hdr_downsample.frag, "
                                       "shaders/combine.frag, shaders/combine_hdr.frag, "
                                       "shaders/combine_hdr_editor.frag"), S]),

        E("shaders.composite", composite_table(), "확정",
          [specfmt.ev("shader", "shaders/common_composite.h:1-50"), S]),
        E("shaders.fog", fog_table(), "확정",
          [specfmt.ev("shader", "shaders/common_fog.h:1-55"), S]),
        E("shaders.pbr", pbr_table(), "확정",
          [specfmt.ev("shader", "shaders/common_pbr.h, shaders/common_pbr_2.h"), S]),
        E("shaders.perspective",
          {"squareToQuad": "단위정사각 → 임의 사각형 호모그래피 3×3. "
                           "입력 순서를 p0,p1,p3,p2 로 **재배열해서** 쓴다(dx2=p3.x, dx3=p2.x). "
                           "det==0 이거나 sumx==sumy==0 이면 아핀 폴백",
           "coefficients": "g = (sumx·diffy2 - diffx2·sumy)/det, h = (diffx1·sumy - sumx·diffy1)/det; "
                           "m[0]=(dx1-dx0+g·dx1, dy1-dy0+g·dy1, g), "
                           "m[1]=(dx2-dx0+h·dx2, dy2-dy0+h·dy2, h), m[2]=(dx0, dy0, 1)",
           "inverse": "`#if HLSL` 일 때만 mat3 inverse 를 자체 정의한다(HLSL 에 내장이 없어서)"},
          "확정", [specfmt.ev("shader", "shaders/common_perspective.h:1-65"), S]),
        E("shaders.fragmentHelpers",
          {"formats": {"FORMAT_RGBA8888": 0, "FORMAT_RGB888": 1, "FORMAT_RGB565": 2,
                       "FORMAT_ETC1_RGB8": 3, "FORMAT_DXT5": 4, "FORMAT_ETC2_RGBA8": 5,
                       "FORMAT_DXT3": 6, "FORMAT_DXT1": 7, "FORMAT_RG88": 8, "FORMAT_R8": 9,
                       "FORMAT_RG1616F": 10, "FORMAT_R16F": 11, "FORMAT_BC7": 12},
           "DecompressNormal": "블록압축(3..7 또는 12): normal.yx = normal.yw·2 - (0.965, 1.0). "
                               "RG88: normal.xy = normal.rg·2 - 1. "
                               "그 외: normal.xy = normal.wy·2 - 1. "
                               "z = sqrt(saturate(1 - x² - y²)). "
                               "**0.965 비대칭 상수가 x 쪽에만 걸린다**",
           "DecompressNormalWithMask": "먼저 normal.xw = normal.wx 스왑 후 같은 식. "
                                       "RG88 은 normal.gr 순서",
           "ComputeMaterialSpecularPower": "(1.01 - roughness) · mix(400, 250, metallic)",
           "ComputeMaterialSpecularStrength": "(0.5 + metallic·0.5) · (1 - roughness·0.9)",
           "ComputeLight": "attn = saturate((radius - dist)/radius); "
                           "color · saturate(dot(L/dist, N)) · attn²",
           "ComputeLightSpecular": "spec = pow(max(0, dot(normalize(V+L), N)), specularPower) "
                                   "· specularStrength · attn · color (누산). "
                                   "halfLambertLight = dot·0.5+0.5; "
                                   "rim = metallicTerm·2; "
                                   "rim = pow((1-saturate(dot(N,V)))·pow(halfLambertLight, 0.25), 6-rim)·rim; "
                                   "return color·(saturate(lightDot)+rim)·attn²",
           "ConvertTexture0Format": "RG88/RG1616F → sample.rrrg (HLSL_SM30 은 .rrra), "
                                    "R8/R16F → (1,1,1,sample.r) (SM30 은 .a)",
           "ConvertSampleR8": "HLSL_SM30 이면 .a, 아니면 .r"},
          "확정", [specfmt.ev("shader", "shaders/common_fragment.h:1-132"), S]),
        E("shaders.vertexHelpers",
          {"BuildTangentSpace": "bitangent = cross(normal, tangent) · signedTangent.w; "
                                "mat3(tangent, bitangent, normal). "
                                "modelTransform 인자가 있으면 세 축 모두 mul(axis, modelTransform)",
           "overloads": 3},
          "확정", [specfmt.ev("shader", "shaders/common_vertex.h:1-23"), S]),
        E("shaders.particles",
          {"ComputeParticleTangents": "Z(roll)·X(pitch)·Y(yaw) 순으로 mat3 를 곱하고, "
                                      "마지막에 mat3(g_OrientationRight, g_OrientationUp, "
                                      "g_OrientationForward) 를 곱한다",
           "ComputeParticlePosition": "pos.xyz + (pos.w·right·(u-0.5) - pos.w·up·(v-0.5)·textureRatio) "
                                      "— **v 축에 마이너스**",
           "ComputeParticleTrailTangents": "right = normalize(cross(eyeDir, localVelocity)); "
                                           "up = v̂ · max(g_RenderVar0.z, "
                                           "min(len·g_RenderVar0.x, g_RenderVar0.y))",
           "ComputeSpriteFrame": "numFrames=g_RenderVar1.z, frameW=.x, frameH=.y. "
                                 "cur=floor(t·N), next=min(N-1, cur+1). "
                                 "uv.y=floor(cur·frameW)·frameH, uv.x=frac(cur·frameW). "
                                 "frameBlend = frac(t·N)",
           "SPRITESHEETBLENDNPOT": "unpaddedWidth = g_Texture0Resolution.z/.x 로 frameWidth 를 "
                                   "나눈 뒤 x 에 unpaddedWidth 를 되곱한다",
           "g_RefractAmount": {"default": 0.05, "range": [-1, 1], "guard": "#if REFRACT"}},
          "확정", [specfmt.ev("shader", "shaders/common_particles.h:1-114"), S]),
        E("shaders.foliage",
          {"CalcLeavesUVWeight": "LEAVESUVMODE 1=1-uv.y, 2=uv.y, 3=uv.x, 4=1-uv.x; "
                                 "saturate((t - bounds.x)·bounds.y), 0 이면 1.0",
           "fastSinesFreq": [1.71717171, -1.56161616, -1.9333, 1.041666666],
           "slowSinesFreq": [0.53333, -0.019841, -0.13888889, 0.0024801587],
           "worldPosSwizzle": {"fast": "worldPos.xzzy · scale · 3.333", "slow": "worldPos.xyyx · scale"},
           "cutoffBaseFactor": 0.6666,
           "leafMask": "strengthLeaves · smoothstep(-1.2, -0.3, "
                       "sin(dot(worldPos, forward) + speedBase·time))",
           "blend": "blendParams = mix((r², r), (r, r²), step(1, treeRadius)); "
                    "leafMask *= mix(smoothstep(bp.x, bp.y, leafDistance), baseMask, baseMask) "
                    "· CalcLeavesUVWeight",
           "output": "dot(mask, (fast.xy, slow.xy))·forward + dot(mask, (fast.zw, slow.zw))·up, "
                     "forward = (cos(dir), 0, sin(dir)), up = (0,1,0)"},
          "확정", [specfmt.ev("shader", "shaders/common_foliage.h:1-40"), S]),

        E("shaders.combos.declared", declared, "확정", [A, S]),
        E("shaders.combos.fromTextureDeclarations", texture_combos, "확정",
          [A, S, specfmt.ev("doc", "sampler 선언 JSON 의 combo/components[].combo/formatcombo 에서 온다. "
                                   "wallpaper64.exe 에 'formatcombo'/'components' 문자열이 있고 "
                                   "슬롯 파싱 정규식 `^uniform[\\s]+(sampler[\\w]*)[\\s]+g_Texture([\\d]+)` 가 있다")]),
        E("shaders.combos.engineInjected", engine_injected, "확정",
          [A, S, specfmt.ev("doc", "#if 로 참조되지만 [COMBO]·텍스처메타·#define 어디에도 선언이 없다. "
                                   "= 엔진/컴파일러가 정의해 줘야 하는 매크로")]),
        E("shaders.textureSlots", tex, "확정", [A, S]),
        E("shaders.samplerAliases", sampler_alias, "확정",
          [A, S, specfmt.ev("doc", "GRADIENT_SAMPLER / SHADOW_ATLAS_SAMPLER / COOKIE_SAMPLER "
                                   "는 셰이더마다 **다른 슬롯**에 매핑된다. "
                                   "슬롯 번호를 상수로 고정하면 파티클/볼류메트릭에서 어긋난다")]),
        E("shaders.requires", require_table(binary_hits), "확정",
          [A, specfmt.ev("binary", "wallpaper64.exe 문자열 — LightingV1 @0x48ac90(파일오프셋), "
                                   "PerformLighting_V1 @0x48ae75, 생성기 문자열 0x48ac50-0x48be47"), S]),
        E("shaders.requires.useSites", requires, "확정", [A, S]),

        E("shaders.gRefs", g_used, "확정", [A, S]),
        E("shaders.crossCheck.uniformsJson", cross, "확정",
          [S, specfmt.ev("file", "spec/engine/uniforms.json")]),
        E("shaders.crossCheck.renderTargetsJson", rt_cross, "확정",
          [S, specfmt.ev("file", "spec/engine/render-targets.json")]),

        E("shaders.lumaVectors", luma_table(), "확정",
          [specfmt.ev("shader", "shaders/common.h:36, common_blending.h:4,96, brushinvert.frag:12, "
                                "chroma4.frag:159, combine_hdr.frag:31, downsample_quarter_bloom.frag:21"), S]),
        E("shaders.lumaVectors.scan", luma_scan, "확정",
          [A, S, specfmt.ev("doc", "합이 [0.9,1.1] 이고 성분에 0/1 이 없는 vec3 리터럴 전수. "
                                   "축 벡터((0,1,0) 등)는 제외했다")]),

        E("shaders.textureResolutionUniforms.usage",
          {"g_TextureNResolution": [
              "blur_k3.vert:13  v_TexCoord.zw = 1.0 / g_Texture0Resolution.xy",
              "generic3.vert:70  morphMapIndex % CASTU(g_Texture5Resolution.x)  (픽셀 개수로 쓴다)",
              "common_particles.h:71  unpaddedWidth = g_Texture0Resolution.z / g_Texture0Resolution.x",
              "chroma4.frag:133  screenUV *= g_Screen.xy / g_Texture8Resolution.xy",
              "stock blur_precise .vert  d = g_Scale.x / g_Texture0Resolution.z"],
           "g_TextureNTexel": [
               "generic4.frag:23  #define SHADOW_ATLAS_TEXEL g_Texture6Texel",
               "common_pbr_2.h:50,61,99  offsets = SHADOW_ATLAS_TEXEL.xy  (UV 스텝)",
               "common_pbr_2.h:50  scaled = projectedCoords.xy * SHADOW_ATLAS_TEXEL.zw  (픽셀화)",
               "base/model_vertex_v1.h:43,48  px % CASTU(Texel.z), vec2(px,py)*Texel.xy"],
           "g_TexelSize": ["downsample_quarter_bloom.vert  a_TexCoord ± g_TexelSize",
                           "blur_h_bloom.vert  localTexel = g_TexelSize.y * 8.0",
                           "combine_hdr.frag  v_TexCoord ± g_TexelSize"]},
          "확정", [A, S]),
        E("shaders.textureResolutionUniforms.layout",
          {"g_TextureNResolution": "(x, y) = 할당(POT 패딩 포함) 픽셀 크기, "
                                   "(z, w) = 실제(unpadded) 픽셀 크기",
           "g_TextureNTexel": "(x, y) = 1/크기 (UV 스텝), (z, w) = 픽셀 크기",
           "basis": "common_particles.h:71 이 .z/.x 를 'unpaddedWidth' 라 이름 붙이고 "
                    "≤1 인 비율로 쓴다 → .z 가 unpadded, .x 가 padded. "
                    "Texel 쪽은 .xy 를 UV 스텝으로, .zw 를 정수 나머지 연산의 제수로 쓴다",
           "caveat": "실제 텍스처를 바인딩해 값을 읽어 확인한 것은 아니다 — "
                     "셰이더 사용례에서의 역산이다"},
          "보고", [specfmt.ev("shader", "shaders/common_particles.h:71, shaders/blur_k3.vert:13, "
                                       "shaders/common_pbr_2.h:50, shaders/base/model_vertex_v1.h:43-49")]),

        E("shaders.corpusUsage", corpus, "확정",
          [specfmt.ev("corpus", f"{WE_WORKSHOP} — .pkg/.json/.frag/.vert/.h/.geom 평문 바이트 검색"), S]),
        E("shaders.corpusUsage.blurEffect",
          {"stockEffect": "blur_precise (replacementkey), passes = "
                          "materials/effects/blur_precise_gaussian_{x,y}.json, "
                          "shaders/effects/blur_precise_gaussian.{vert,frag}",
           "sample": "workshop 2802243144/scene.pkg 안에 평문으로 들어 있다",
           "why": "common_blur.h 를 쓰는 코퍼스 90개 프로젝트의 대다수가 이 스톡 효과 사본이다. "
                  "그래서 blur13a/blur7a/blur3a 호출 수가 정확히 같게 나온다(각 137회/89프로젝트)",
           "unusedInCorpus": ["blur13(", "blur7(", "blur3("],
           "note": "워크샵은 vec4 변형(a 접미)만 쓴다. vec3 변형은 코퍼스에서 호출 0회"},
          "확정", [specfmt.ev("corpus",
                             r"Z:\SteamLibrary\steamapps\workshop\content\431960\2802243144\scene.pkg "
                             "— shaders/effects/blur_precise_gaussian.frag 평문"), S]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_shaders.py", entries), OUT)

    print(f"셰이더 {len(scans)}개(top-level {sum(counts_top.values())}: {counts_top}) → {rel_repo(OUT)}")
    print(f"  COMBO 선언 {len(declared)} / 텍스처유래 {len(texture_combos)} / 엔진주입 {len(engine_injected)}")
    print(f"  g_* {len(g_used)}종 (엔진제공 교집합 {cross['inBoth']}, 머티리얼 전용 {len(cross['shaderOnly'])})")
    print(f"  luma 후보: {list(luma_scan)}")
    print(f"  Waple 모드 커버리지 OK: {parity['modeCoverageOK']}")
    print("  코퍼스 헤더 사용:")
    for k, v in corpus["usage"].items():
        if v["occurrences"]:
            print(f"    {k:38s} occ={v['occurrences']:6d} projects={v['projects']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
