"""wallpaper64.exe 가 링크한 서드파티 라이브러리를 **전수** 잰다.

## 왜 필요한가

WE 는 빌드 시 소스 경로 문자열을 바이너리에 남긴다(어서션 매크로의 `__FILE__`).
그 경로가 어느 라이브러리를 벤더링했는지 그대로 말해 준다. 그런데 그 문자열들은 **UTF-16LE** 라
ASCII 로 grep 하면 **0건**이 나온다 — 2026-08-19 스윕 전까지 이 사실이 정본에서 여러 번
거꾸로 기록됐다:

  · 분석 리포가 `D:\\dev\\we\\...` 경로·RapidJSON·FFTS 를 통틀어 "fabricated" 로 단정했다.
  · "no FFT/spectrum library strings" — FFTS 가 링크돼 있다.
  · "jsoncpp (NOT RapidJSON)" — 둘이 같은 `src/json/` 트리에 **병존**한다. 그 판단의 근거로
    인용된 파서 에러 문자열들은 실은 RapidJSON 자신의 `GetParseError_En()` 표였다.
  · **GLM 은 어느 문서에도 없었다** — Waple·분석 리포 양쪽 `grep -rniE "\\bglm\\b"` = 0건.

부재를 주장하려면 **어떤 인코딩으로 어떤 명령을 돌렸는지**를 함께 적어야 한다. 이 문서가
그 근거를 재생성 가능한 형태로 고정한다 — 하드코딩 목록이 아니라 **전수 스캔**이다.

## 왜 행렬 규약이 걸리는가

`spec/engine/mul-convention.json` 과 `Sources/WapleRender/Scene3DMath.swift` 의 전치 논증은
"WE 가 행벡터·행우선(DirectXMath/HLSL) 규약을 쓴다" 는 전제 위에 있다. 그 전제 자체는
`XMMatrixPerspectiveFov*` 어서션으로 뒷받침된다. 그런데 **GLM(열벡터·열우선, OpenGL 규약)도
동시에 링크돼 있다.** 틀렸다는 게 아니라 — 어느 행렬 경로가 어느 규약을 따르는지가
**미판정**이라는 뜻이다.

## [2026-08-21] 세 번째 사각지대 — 문자열이 **아예 없는** 라이브러리

2026-08-20 스윕이 "UTF-16LE 만 봐서 C 라이브러리를 못 봤다" 를 고쳤다(→ `linkedLibs.asciiOnly`).
그런데 그 수정도 여전히 **문자열 스캔**이었고, 문자열 스캔은 세 번째 부류를 원리적으로 못 본다:

    로그도 어서션도 없는 헤더/소스 몇 개짜리 C++ 라이브러리.

실측으로 확인된 것이 셋이다. **msdfgen 은 wallpaper64.exe 안에 자기 이름을 단 한 글자도
남기지 않는다**(`grep -i msdfgen` = ASCII·UTF-16LE 양쪽 0건). Sebastien Rombauts 의
Perlin Simplex Noise 도 마찬가지고, LZ4 는 WE 자신이 찍는 `"LZ4 error."` 한 줄뿐이라
라이브러리 이름이 아니다. 셋 다 종전 정본에 없었다.

그래서 이 문서는 이번에 **문자열이 아닌 지문**을 추가한다:

  · `DATA_FINGERPRINTS` — .rdata 에 구워진 **고유 상수·표**를 바이트열로 찾는다.
    예: msdfgen `solveCubicNormed` 의 `1/9`·`1/54`, `edgeColoringSimple` 의 `2.875`·`1.4375`,
        Ken Perlin 순열표 512바이트(`151,160,137,91,…`).
  · `CODE_SITES` — 위 상수를 쓰는 **함수 VA** 를 선두 바이트로 대조한다. VA 만 적으면
    다음 빌드에서 조용히 어긋나므로, 그 자리에 그 명령이 실제로 있는지 매 실행 확인한다.

VA 는 imagebase `0x140000000` 기준이다. `.rdata` 는 rawptr `0x424e00` / rva `0x426000` 이라
**파일 오프셋 + 0x1200 = RVA** 인데, 이 리포의 주석이 두 규약을 같은 표기로 섞어 쓴 전례가
있어서(→ `scripts/spec/check_address_ranges.py`) 여기서는 **VA 를 명시 표기**한다.

## WE 자신의 귀속 페이지를 대조군으로 쓴다

설치본에는 WE 가 직접 만든 서드파티 고지 페이지가 있다:

    bin/licenses/licenses_main.html          — 라이브러리 이름 + 라이선스 전문
    ui/dist/scripts/scripts.js               — REV 별 변경 이력(빌드 로그)

이건 "정답지" 가 아니다 — 제품 **전체**(에디터·UI·플러그인 DLL 포함)의 목록이라
wallpaper64.exe 에 안 들어 있는 것이 절반 이상이다. 그래서 그대로 베끼지 않고 **대조군**으로
쓴다: 페이지의 이름 하나하나에 "이 바이너리에서 어떻게 판정됐나" 를 붙이고, 페이지에
**우리가 모르는 이름이 새로 생기면 실패**시킨다. 하드코딩 목록의 구조적 한계를
(완전히는 못 닫아도) 한 단계 좁히는 자리다.

버전 문자열은 바이너리에 거의 없다 — 유일한 배너가 zlib `inflate 1.3.1` 이다. 나머지 버전은
저 변경 이력이 유일한 근거라 함께 뜬다("Updated JSONcpp to 1.9.6" 등).

## 재실행

    WE_BINARY=/path/to/wallpaper64.exe \
    WE_ROOT=/path/to/wallpaper_engine \
    python3 scripts/spec/measure_linked_libraries.py

원본인지는 sha256 `40e2ce02…`(5,360,112 B)로 대조할 것. 주입본(+208B)을 넣으면 오프셋이
전부 +0xD0 밀린다(`spec/engine/decompilation-provenance.json`).
`WE_ROOT` 는 설치본 루트(= `wallpaper64.exe` 와 `bin/` 이 있는 디렉터리)다 —
`measure_we_install_tree.py` 와 같은 규약이다.
"""
import collections
import hashlib
import html
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

BIN = os.environ.get("WE_BINARY",
                     r"Z:\SteamLibrary\steamapps\common\wallpaper_engine\wallpaper64.exe")
WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# **UTF-16LE**. 이 한 줄이 이 문서의 존재 이유다 — ASCII 로 찾으면 전부 0건이다.
ENCODING = "utf-16-le"
# 길이 6 이상의 인쇄 가능 ASCII 를 UTF-16LE 로 담은 구간.
UTF16_RUN = re.compile((r"(?:[\x20-\x7e]\x00){6,}").encode("latin1"))
# 빌드 시각 소스 경로로 볼 것: WE 자체 트리 또는 Windows SDK.
SOURCE_PATH = re.compile(r"^(D:\\dev\\we\\|C:\\Program Files \(x86\)\\Windows Kits\\)")

# 라이브러리별 대표 어서션. 경로만으로는 "링크됐다"까지고, 어서션은 **코드가 실제로 있다**를 보인다.
ASSERTIONS = {
    "glm": ["(i) >= 0 && (i) < (this->length())",
            "index >= 0 && index < m.length()",
            "index >= 0 && index < m[0].length()"],
    "DirectXMath": ["NearZ > 0.f && FarZ > 0.f",
                    "!XMScalarNearEqual(FarZ, NearZ, 0.00001f)",
                    "!XMScalarNearEqual(FovAngleY, 0.0f, 0.00001f * 2.0f)",
                    "!XMScalarNearEqual(AspectRatio, 0.0f, 0.00001f)"],
    "json": ["IsBool()", "IsArray()", "IsObject()"],
    "ffts": ["N == 32"],
}

# ── [2026-08-20] 이 측정의 **구조적 사각지대** ────────────────────────────────
# 위 스캔은 UTF-16LE 전용이다. 그건 근거가 MSVC 어서션의 `__FILE__` 이기 때문인데,
# 그 경로가 wide 인 이유는 `_wassert` 를 쓰는 **C++ 라이브러리**여서다.
#
# 즉 이 방법은 **C 라이브러리를 원리적으로 못 본다.** 그쪽은 `assert`/자기 로그가
# narrow 문자열이라 UTF-16LE 스캔에 한 건도 안 걸린다. 실제로 넷을 통째로 놓치고 있었다.
#
# 함정 ⑨("ASCII-only 검색이 거짓 부재를 만든다")를 이 문서가 세워 놓고, 정작 자신은
# **반대 방향으로 같은 실수**를 하고 있었다 — UTF-16-only 검색도 똑같이 거짓 부재를 만든다.
ASCII_MARKERS = {
    "harfbuzz": ["harfbuzz ", "buffer verify error: clusters are not monotone.",
                 "struct hb_shape_plan_t *__cdecl hb_shape_plan_create2",
                 # HB_SHAPER_LIST 에 directwrite 가 들어 있다 = DWrite 셰이퍼 빌드.
                 # PE 임포트에 DWrite.dll 이 있는 이유가 이것이다.
                 "HB_SHAPER_LIST", "directwrite"],
    "freetype": ["FREETYPE_PROPERTIES", "resource.frk/", ".AppleDouble/",
                 # ot-svg 모듈은 FreeType 2.12.0 에서 들어왔다 → 버전 하한.
                 "ot-svg", "truetype", "psnames"],
    "zlib": [" inflate 1.3.1 Copyright 1995-2024 Mark Adler "],
    "wuffs": ["wuffs_aux::DecodeJson: no match", "#png: internal error: zlib decoder"
              " did not exhaust its input", "#gzip: bad encoding flags"],
    # [2026-08-21] 신규. 라이브러리 이름 문자열은 없고 WE 가 찍는 실패 메시지 한 줄뿐이라
    # 문자열만으로는 동정이 안 된다 — 아래 CODE_SITES 의 `LZ4_decompress_safe` 가 본체다.
    "lz4": ["LZ4 error."],
}
# FreeType 이 등록하는 모듈 이름. `cff`/`sdf` 처럼 짧아서 부분 문자열로 찾으면 오탐이 나므로
# **널 구분자로 감싸** 찾는다. 종전 정본이 "모듈 19종" 이라고 적었는데 그 수를 재는 코드가
# 어디에도 없었다 — 여기서 실제로 센다.
# Wuffs 상태 문자열의 코덱 접두사. `#png: bad header` 처럼 생겼다.
WUFFS_STATUS = re.compile(rb"[#@$]([a-z0-9_]{2,12}): [a-z]")

FREETYPE_MODULES = ("truetype", "type1", "type42", "t1cid", "cff", "sfnt", "pfr", "winfonts",
                    "pcf", "bdf", "psaux", "psnames", "pshinter", "autofitter", "smooth",
                    "raster", "sdf", "bsdf", "ot-svg", "gzip", "lzw", "bzip2")

ASCII_ROLE = {
    "harfbuzz": "텍스트 셰이핑. 정적 링크(코드 대역이 .text 후반 상당 부분). "
                "셰이퍼 목록에 `directwrite` 가 있고 PE 임포트에 DWrite.dll 이 있다.",
    "freetype": "폰트 래스터. 등록 모듈은 아래 `modules` 에서 실제로 센다(종전 정본의 "
                "'19종' 은 그 수를 재는 코드가 없는 숫자였다). `ot-svg` 는 2.12.0 "
                "도입이라 **버전 하한 2.12**.",
    "zlib": "inflate 전용(1.3.1). deflate 없음 — FreeType ftgzip.c 동봉분으로 보인다[추정]. "
            "FreeType 이 번들 zlib 을 1.3.1 로 올린 것이 2.13.3 이라, 맞다면 FreeType 도 "
            "2.13.3 이상이다[추정]. 아래 freetype.modules 에 `gzip` 이 없는 것과 모순되지 "
            "않는다 — ftgzip.c 는 **등록 모듈이 아니라** 스트림 함수(FT_Gzip_Uncompress)라 "
            "모듈 이름 표에 안 나온다.",
    "wuffs": "이미지·JSON 코덱(google/wuffs). `#png:`/`#json:`/`#gzip:` 상태 문자열이 고유 규약. "
             "라이브러리 이름 문자열 자체는 없어 동정은 **강한 추정**이다. "
             "어느 코덱이 컴파일됐는지는 아래 `statusPrefixes` 에서 실제로 센다 — "
             "GIF 디코드도 여기다(CGif 가 아니다).",
    "lz4": ".pkg/.tex 압축 해제. 문자열은 WE 자신의 실패 메시지뿐이고 라이브러리 이름은 없다.",
}

# ── [2026-08-21] 문자열이 없는 라이브러리 — 데이터 지문 ────────────────────────
#
# 값은 (설명, 바이트열, 기대 히트수). 기대 히트수가 어긋나면 **실패**시킨다 —
# "찾았다/못 찾았다" 만 보고하면 다른 빌드에서 조용히 다른 것을 가리키게 된다.
def _f64(v):
    return struct.pack("<d", v)


def _f32(v):
    return struct.pack("<f", v)


# Ken Perlin 의 참조 순열표 256개(= Gustavson 의 simplexnoise1234.c `perm[]` 앞 절반).
PERLIN_PERM_256 = bytes([
    151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30,
    69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94,
    252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171,
    168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60,
    211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1,
    216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86,
    164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118,
    126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170,
    213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39,
    253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
    242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49,
    192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254,
    138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180])
# "Simplex noise demystified"(Gustavson) 계열이 함께 굽는 `permMod12[]`.
PERLIN_PERM_MOD12_256 = bytes(p % 12 for p in PERLIN_PERM_256)

DATA_FINGERPRINTS = {
    "msdfgen": [
        # core/equation-solver.cpp :: solveCubicNormed
        #     double q = 1/9.*(a2-3*b);  double r = 1/54.*(a*(2*a2-9*b)+27*c);
        ("solveCubicNormed 1/9", _f64(1 / 9.), 1),
        ("solveCubicNormed 1/54", _f64(1 / 54.), 1),
        ("solveCubicNormed 2*M_PI", _f64(6.283185307179586), 1),
        # core/edge-coloring.cpp :: symmetricalTrichotomy
        #     return int(3+2.875*position/(n-1)-1.4375+.5)-3;
        ("symmetricalTrichotomy 2.875", _f64(2.875), 1),
        ("symmetricalTrichotomy 1.4375", _f64(1.4375), 1),
        # core/Shape.cpp :: normalize() 의 `< MSDFGEN_CORNER_DOT_EPSILON-1`
        #     MSDFGEN_CORNER_DOT_EPSILON = .000001 → -0.999999
        ("Shape::normalize CORNER_DOT_EPSILON-1", _f64(-0.999999), 1),
        # core/msdf-error-correction.h
        #     MSDFGEN_DEFAULT_MIN_DEVIATION_RATIO / MIN_IMPROVE_RATIO = 1.11111111111111111
        ("ErrorCorrectionConfig 1.11111111111111111", _f64(1.11111111111111111), 5),
    ],
    "perlin-simplex-noise": [
        # SimplexNoise.cpp :: static const uint8_t perm[256]
        # (Rombauts 판은 512가 아니라 **256**이고 `perm[(uint8_t)i]` 로 감는다)
        # 히트 3건 중 **0x140484f40 만** 이 라이브러리 것이다. 나머지 둘은 아래
        # gustavson-perm-sse 의 512바이트 표(0x1404833a0)와 그 후반부(0x1404834a0) 겹침이다.
        ("perm[256] (이 중 0x140484f40 이 Rombauts 판)", PERLIN_PERM_256, 3),
        ("noise(x) 0.395f", _f32(0.395), 1),
        ("noise(x,y) 45.23065f", _f32(45.23065), 1),
        ("noise(x,y) 2*G2 = 0.4226497f", _f32(2 * (3 - 3 ** 0.5) / 6), 1),
    ],
    "gustavson-perm-sse": [
        # 같은 순열표의 **두 번째 사본**. 이쪽은 512바이트(256 반복)에 permMod12 가 앞에 붙는
        # "Simplex noise demystified" 배치다. 라이선스 페이지에 별도 항목이 없고 변경 이력이
        # "New 2D simplex SSE noise generator"(REV 4135) 라고 적어서, 서드파티가 아니라
        # **WE 자신의 SSE 이식**으로 본다 — 표만 Gustavson/Perlin 공용 것이다.
        ("permMod12[512]", PERLIN_PERM_MOD12_256 + PERLIN_PERM_MOD12_256, 1),
        ("perm[512]", PERLIN_PERM_256 + PERLIN_PERM_256, 1),
    ],
}

# ── 코드 지문. VA 와 선두 바이트를 함께 못 박는다 ─────────────────────────────
#
# VA 만 적으면 다음 빌드에서 조용히 다른 함수를 가리킨다. 선두 바이트를 함께 대조하면
# 어긋난 순간 실패한다 — 근거가 틀린 곳을 가리키는 것이 없는 것보다 나쁘다는 이 리포의
# 반복된 교훈(`validate.py` 의 줄 번호 검사와 같은 취지)을 코드 지문에도 적용한다.
CODE_SITES = {
    "msdfgen": {
        "edgeColoringSimple": (0x140283500, "4c8944241848894c24085553",
                               "2.875 @VA 0x1404927c0 · 1.4375 @VA 0x140492798 를 쓴다"),
        "solveCubic#1": (0x140286990, "488bc4488950105341544157",
                         "1e6 임계 @VA 0x140492870 · 1/9 · 1/54 · 27.0"),
        "solveCubic#2": (0x140288460, "488bc4f20f11582053565741",
                         "같은 상수 조합의 두 번째 인스턴스(다른 번역 단위)"),
        "WE 폰트 MSDF 아틀라스 빌더": (0x1401ae080, "4c894c24204c894424184889",
                                      "0x1401af40e 에서 angleThreshold 3.0 을 싣고 "
                                      "0x1401af41a 에서 edgeColoringSimple 을 부른다. "
                                      "0x1401af111 이 -0.999999(=CORNER_DOT_EPSILON-1)"),
    },
    "perlin-simplex-noise": {
        "noise(float x)": (0x14027b090, "4883ec18f30f101d547f2100",
                           "perm[256] @VA 0x140484f40 · grad = 1.0f+(h&7) · 0.395f"),
        "noise(float x, float y)": (0x14027b170, "488bc44881eca80000000f28",
                                    "F2 @VA 0x1404926a4 · G2 @VA 0x140492680 · 45.23065f"),
        "fractal(octaves, x)": (0x14027b4b0, "488bc44881ec980000000f29",
                                "옥타브 루프(lacunarity·persistence) — 라이브러리 상위 API"),
    },
    "gustavson-perm-sse": {
        "simplex3D SoA #1": (0x1400fc220, "488bc4488950104889480853",
                             "F3 @VA 0x1404835e0 · G3 @VA 0x140483600 · 0.6f @VA 0x140483620 · "
                             "&255 @VA 0x140483630 · perm/permMod12 를 [reg+base+0x4833a0] 로 색인"),
        "simplex3D SoA #2": (0x1400fd010, "488bc4488958184889501048", "같은 상수 조합"),
    },
    "lz4": {
        "LZ4_decompress_safe": (0x14014c160, "488954241048894c24085648",
                                "src==NULL||dstCapacity<0 → -1, srcSize==1&&*src==0 → 0 "
                                "가드가 LZ4 1.9.x 원문 그대로. 호출부 0x1400ce7bc 가 "
                                "실패 시 'LZ4 error.' @VA 0x1404863f8 를 찍는다"),
    },
}

# 문자열이 없다는 주장 자체도 **측정**해서 남긴다. "msdfgen 은 이름을 한 글자도 안 남긴다" 는
# 이 문서의 핵심 논거인데, 그걸 산문으로만 적으면 다음 사람이 확인할 방법이 없다.
NAME_SEARCHES = {
    "msdfgen": ["msdfgen", "Chlumsky", "Chlumský", "MSDFgen", "multi-channel signed distance"],
    "perlin-simplex-noise": ["SimplexNoise", "Rombauts", "simplexnoise1234", "Gustavson"],
    "gustavson-perm-sse": ["permMod12", "simplex"],
    "lz4": ["LZ4_decompress", "lz4.c", "Yann Collet", "LZ4"],
}

# ── 부재 주장 — **어떤 패턴으로 찾았는지**를 함께 남긴다 ──────────────────────
#
# 이 문서의 규칙("부재를 주장하려면 어떤 인코딩으로 어떤 명령을 돌렸는지 적어라")을
# 이번엔 처음부터 지킨다. 각 항목은 ASCII·UTF-16LE **양쪽**으로 대소문자 무시 검색한다.
ABSENT_PROBES = {
    "libpng": ["libpng", "png_create_read_struct", "png_sig_cmp"],
    "libjpeg-turbo": ["libjpeg", "jpeg_start_decompress", "jpeg_read_header"],
    "libwebp": ["libwebp", "WebPDecode", "VP8L"],
    "Ogg/Vorbis": ["OggS", "vorbis", "Xiph.Org"],
    "Opus": ["libopus", "opus_decode"],
    "FLAC": ["fLaC", "FLAC__stream"],
    "mpg123/minimp3/libmad": ["mpg123", "minimp3", "mad_synth"],
    "OpenSSL/BoringSSL": ["OpenSSL", "BoringSSL", "SSL_CTX_new"],
    "curl": ["libcurl", "curl_easy_perform"],
    "SQLite": ["SQLite", "sqlite3_open"],
    "Lua": ["lua_State", "lua_pcall"],
    "AngelScript": ["AngelScript", "asIScriptEngine"],
    "Bullet": ["btRigidBody", "btCollisionShape", "BulletCollision"],
    "Box2D": ["b2World", "b2Fixture", "Box2D"],
    "Assimp": ["assimp", "aiScene"],
    "Chromium/CEF": ["chromium", "cef_", "CefBrowser"],
    "V8": ["v8::", "V8 version"],
    "SDL": ["SDL_Init", "libSDL", "SDL2"],
    "brotli": ["brotli", "BrotliDecoderDecompress"],
    "zstd": ["zstd", "ZSTD_decompress"],
    "xxhash": ["xxhash", "XXH3_", "XXH64"],
    "nlohmann/json": ["nlohmann", "json.hpp"],
    "fmt/spdlog": ["fmt::", "spdlog"],
    "Steamworks SDK": ["SteamAPI_Init", "ISteamUser", "steam_api64"],
    "Detours": ["DetourAttach", "DetourTransactionBegin"],
    "DirectXTex": ["DirectXTex", "ScratchImage"],
    "libsamplerate/r8brain/soxr": ["libsamplerate", "r8brain", "soxr"],
    "FreeImage": ["FreeImage_", "FIBITMAP"],
    "LodePNG": ["lodepng", "unexisting error"],
    "Poly2Tri": ["poly2tri", "EdgeEvent", "collinear points"],
    "CGif": ["cgif_", "CGIF_"],
    "FastNoise 2": ["FastNoise", "OpenSimplex2", "DomainWarp"],
    "OpenCV": ["opencv", "cv::Mat"],
    "AMD Compressonator": ["Compressonator", "CMP_ConvertTexture"],
    "SFML": ["SFML", "sf::Render"],
    "triangleraster": ["triangleraster", "Josh A. Beam"],
    "jc_voronoi": ["jcv_diagram", "jc_voronoi"],
}

# ── WE 자신의 귀속 페이지에 대한 판정 ─────────────────────────────────────────
#
# 페이지에 있는 이름 하나하나가 wallpaper64.exe 에서 어떻게 판정됐는지. 페이지에
# **모르는 이름이 새로 생기면 실패**한다 — 그게 이 표의 존재 이유다(하드코딩 목록이
# 조용히 낡는 것을 WE 자신의 문서로 감시한다).
LICENSE_PAGE_VERDICT = {
    "LodePNG": "미도달 — `lodepng`/`unexisting error` 0건. PNG 디코드는 Wuffs 다.",
    "JsonCpp": "정적 링크 — src\\json\\src\\json_*.cpp 경로 3건.",
    "GLM": "정적 링크 — 경로 7건 + 어서션 3건.",
    "CEF": "미도달 — 별도 프로세스/DLL(WPEDesktopCEFWindow 창 클래스만 있다).",
    "FFTS": "정적 링크 — ffts_static.c + 어서션 `N == 32`.",
    "AMD Compressonator SDK": "미도달 — `Compressonator`/`CMP_ConvertTexture` 0건.",
    "Assimp": "미도달 — `assimp`/`aiScene` 0건(모델은 .mdl 자체 포맷).",
    "FreeImage": "플러그인 DLL — resourceutil64.dll 의 GetProcAddress 이름 "
                 "`FreeImageBits` @VA 0x1404781a8 · `SaveRGBAToJPEG` @VA 0x140478198 만 있다.",
    "LZ4 - Fast LZ compression algorithm": "정적 링크 — LZ4_decompress_safe @VA 0x14014c160.",
    "Perlin Simplex Noise": "정적 링크 — perm[256] @VA 0x140484f40, 0.395f/45.23065f.",
    "FastNoise 2": "미도달 — `FastNoise`/`OpenSimplex2`/`DomainWarp` 0건.",
    "SFML 2": "미도달 — `SFML`/`sf::Render` 0건.",
    "Monaco Editor": "에디터 UI(JS) — 바이너리 밖.",
    "FreeType2": "정적 링크 — FREETYPE_PROPERTIES + 등록 모듈"
                 "(수는 asciiOnly.libraries.freetype.moduleCount 에서 실측).",
    "HarfBuzz": "정적 링크 — `harfbuzz ` 배너 + HB_SHAPER_LIST.",
    "OpenCV": "미도달 — `opencv`/`cv::Mat` 0건.",
    "V8": "플러그인 DLL — scenescript64.dll @VA 0x1404864d8.",
    "Bodymovin": "에디터 UI(JS) — 바이너리 밖.",
    "RapidJSON": "정적 링크 — 경로 7건 + 어서션 3건(JsonCpp 와 **병존**).",
    "Wuffs": "정적 링크 — wuffs_aux + 상태 접두사"
             "(수는 asciiOnly.libraries.wuffs.statusPrefixCount 에서 실측).",
    "triangleraster": "미도달 — `triangleraster`/`Josh A. Beam` 0건.",
    "nQuant.cs": "에디터(C#) — 바이너리 밖.",
    "nQuant.cs/nQuant.Master/BitmapUtilities.cs": "에디터(C#) — 바이너리 밖.",
    "nQuant.cs/nQuant.Master/BlueNoise.cs": "에디터(C#) — 바이너리 밖.",
    "nQuant.cs/nQuant.Master/GilbertCurve.cs": "에디터(C#) — 바이너리 밖.",
    "nQuant.cs/nQuant.Master/PnnQuantizer.cs": "에디터(C#) — 바이너리 밖.",
    "CGif": "미도달 — `cgif_`/`CGIF_` 0건. GIF **디코드**는 Wuffs, 인코드는 에디터 쪽이다.",
    "WebGL-Fluid-Simulation": "셰이더·자산 — 바이너리 밖.",
    "Poly2Tri": "미도달 — `poly2tri`/`EdgeEvent`/`collinear points` 0건.",
    "Photoshop Blend Functions": "셰이더·자산 — 바이너리 밖.",
    "GLSL hash": "셰이더·자산 — 바이너리 밖.",
    "GLSL noise": "셰이더·자산 — 바이너리 밖(Ashima/Gustavson GLSL, CPU 쪽과 별개다).",
    "Voronoi JCash": "플러그인 DLL — cloneextensions64.dll 의 `CreateVoronoiFacets` "
                     "@VA 0x140477b68.",
    "glsl-rotate": "셰이더·자산 — 바이너리 밖.",
    "SDF CPU Computation": "미판정 — 고유 문자열도 고유 상수도 못 찾았다. FreeType 의 "
                           "`sdf`/`bsdf` 모듈이 별도로 있어 구분이 안 된다.",
    "msdfgen": "정적 링크 — solveCubicNormed 1/9·1/54, symmetricalTrichotomy 2.875·1.4375.",
    # 라이선스 제목이 이름 자리에 오는 항목(원본 HTML 의 div 중첩이 그렇다).
    "The MIT License (MIT)": "(라이선스 제목 행 — 라이브러리 이름이 아니다)",
    "MIT License": "(라이선스 제목 행 — 라이브러리 이름이 아니다)",
}

# 변경 이력에서 뽑을 것. 바이너리에 버전 문자열이 없는 라이브러리의 **유일한 버전 근거**다.
CHANGELOG_PROBE = re.compile(
    r"(?i)(msdfgen|Updated (?:JSONcpp|GLM|LZ4|V8|fontawesome)|Updated LZ4"
    r"|simplex SSE|SSE noise|SSE utilities|Updated V8)")


def classify(path):
    """소스 경로 → 라이브러리 이름. `src\\lib\\include\\<x>` 와 `src\\<x>` 둘 다 받는다."""
    if "Windows Kits" in path:
        return "DirectXMath"
    m = re.search(r"src\\(?:lib\\include\\)?([A-Za-z0-9_+]+)", path)
    return m.group(1) if m else "(기타)"


class Image:
    """오프셋↔VA 만 필요하다. 섹션표를 읽어서 계산한다 — `+0x1200` 을 상수로 박지 않는다."""

    def __init__(self, data):
        self.data = data
        e = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e:e + 4] != b"PE\0\0":
            raise SystemExit("[linked-libs] PE 헤더가 아니다")
        nsec = struct.unpack_from("<H", data, e + 6)[0]
        optsz = struct.unpack_from("<H", data, e + 20)[0]
        magic = struct.unpack_from("<H", data, e + 24)[0]
        self.imagebase = (struct.unpack_from("<Q", data, e + 48)[0] if magic == 0x20B
                          else struct.unpack_from("<I", data, e + 52)[0])
        so = e + 24 + optsz
        self.sections = []
        for i in range(nsec):
            o = so + 40 * i
            name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            vsz, rva, rawsz, rawptr = struct.unpack_from("<IIII", data, o + 8)
            self.sections.append((name, rva, vsz, rawptr, rawsz))

    def off2va(self, off):
        for _, rva, _vsz, rawptr, rawsz in self.sections:
            if rawsz and rawptr <= off < rawptr + rawsz:
                return self.imagebase + rva + (off - rawptr)
        return None

    def va2off(self, va):
        r = va - self.imagebase
        for _, rva, vsz, rawptr, rawsz in self.sections:
            if rva <= r < rva + max(vsz, rawsz):
                d = r - rva
                if d < rawsz:
                    return rawptr + d
        return None

    def where(self, off):
        """정본에 적을 표기. 오프셋과 VA 를 **둘 다** 적는다(둘이 섞여 쓰인 전례가 있다)."""
        va = self.off2va(off)
        return f"0x{off:x}" if va is None else f"0x{off:x} (VA 0x{va:x})"

    def find_all(self, pat):
        out, i = [], 0
        while True:
            j = self.data.find(pat, i)
            if j < 0:
                return out
            out.append(j)
            i = j + 1


def scan_source_paths(img):
    by_lib = collections.defaultdict(dict)
    for m in UTF16_RUN.finditer(img.data):
        text = m.group().decode(ENCODING)
        if SOURCE_PATH.match(text):
            by_lib[classify(text)][text] = img.where(m.start())
    return by_lib


def scan_ascii_markers(img):
    out = {}
    for lib, toks in ASCII_MARKERS.items():
        found = {}
        for t in toks:
            i = img.data.find(t.encode("ascii"))
            j = img.data.find(t.encode(ENCODING))
            found[t] = {"ascii": img.where(i) if i >= 0 else None,
                        "utf16le": img.where(j) if j >= 0 else None}
        out[lib] = {"role": ASCII_ROLE[lib], "markers": found,
                    "utf16leHits": sum(1 for v in found.values() if v["utf16le"])}
    # FreeType 모듈은 널 구분자로 감싸 찾는다 — `cff`/`sdf` 는 부분 문자열 오탐이 난다.
    mods = {}
    for name in FREETYPE_MODULES:
        i = img.data.find(b"\0" + name.encode("ascii") + b"\0")
        mods[name] = img.where(i + 1) if i >= 0 else None
    out["freetype"]["modules"] = mods
    out["freetype"]["moduleCount"] = sum(1 for v in mods.values() if v)
    # Wuffs 는 `#<코덱>: <사유>` / `@<코덱>: …` / `$<코덱>: …` 꼴로만 상태를 낸다.
    # 어느 코덱이 컴파일돼 들어왔는지가 그대로 드러난다.
    pref = collections.Counter()
    first = {}
    for m in WUFFS_STATUS.finditer(img.data):
        name = m.group(1).decode("ascii")
        pref[name] += 1
        first.setdefault(name, img.where(m.start()))
    out["wuffs"]["statusPrefixes"] = {k: {"count": pref[k], "firstAt": first[k]}
                                      for k in sorted(pref)}
    out["wuffs"]["statusPrefixCount"] = len(pref)
    return out


def scan_data_fingerprints(img):
    """고유 상수·표를 찾는다. 기대 히트수와 다르면 실패시킨다."""
    out, bad = {}, []
    for lib, probes in DATA_FINGERPRINTS.items():
        rows = {}
        for label, pat, want in probes:
            offs = img.find_all(pat)
            rows[label] = {"bytes": pat[:16].hex() + ("…" if len(pat) > 16 else ""),
                           "len": len(pat),
                           "va": [f"0x{img.off2va(o):x}" for o in offs if img.off2va(o)],
                           "hits": len(offs), "expected": want}
            if len(offs) != want:
                bad.append(f"{lib}/{label}: 히트 {len(offs)} — 기대 {want}")
        out[lib] = rows
    return out, bad


def scan_code_sites(img):
    """주장한 함수 VA 에 그 명령이 실제로 있는지 대조한다."""
    out, bad = {}, []
    for lib, sites in CODE_SITES.items():
        rows = {}
        for name, (va, head_hex, note) in sites.items():
            off = img.va2off(va)
            got = img.data[off:off + len(head_hex) // 2].hex() if off is not None else None
            ok = got == head_hex
            rows[name] = {"va": f"0x{va:x}", "head": head_hex, "verified": ok, "why": note}
            if not ok:
                bad.append(f"{lib}/{name}: VA 0x{va:x} 선두 바이트 {got} — 기대 {head_hex}")
        out[lib] = rows
    return out, bad


def scan_names(img):
    """라이브러리 **이름 자체**를 양쪽 인코딩으로 찾는다. 0건인 것이 이 항목의 요점이다."""
    out = {}
    for lib, toks in NAME_SEARCHES.items():
        rows = {}
        for t in toks:
            try:
                pa = re.escape(t.encode("utf-8"))
            except UnicodeError:                     # 방어적 — 실제로는 안 난다
                continue
            rx_a = re.compile(pa, re.I)
            rx_w = re.compile(re.escape(t.encode(ENCODING)), re.I)
            rows[t] = {"ascii": [img.where(m.start()) for m in rx_a.finditer(img.data)][:3],
                       "utf16le": [img.where(m.start()) for m in rx_w.finditer(img.data)][:3]}
        out[lib] = rows
    return out


def scan_absent(img):
    """부재 주장. ASCII·UTF-16LE 양쪽으로 대소문자 무시 검색하고 **토큰을 함께 남긴다**."""
    out = {}
    for lib, toks in ABSENT_PROBES.items():
        rows = {}
        for t in toks:
            rx_a = re.compile(re.escape(t.encode("ascii")), re.I)
            rx_w = re.compile(re.escape(t.encode(ENCODING)), re.I)
            rows[t] = {"ascii": [img.where(m.start()) for m in rx_a.finditer(img.data)][:3],
                       "utf16le": [img.where(m.start()) for m in rx_w.finditer(img.data)][:3]}
        out[lib] = rows
    return out


def read_vendor_attribution():
    """설치본의 귀속 페이지 + 변경 이력. 버전 근거가 여기밖에 없는 라이브러리가 여럿이다."""
    lic = os.path.join(WE_ROOT, "bin", "licenses", "licenses_main.html")
    log = os.path.join(WE_ROOT, "ui", "dist", "scripts", "scripts.js")
    for p in (lic, log):
        if not os.path.isfile(p):
            raise SystemExit(
                f"[linked-libs] 설치본 파일이 없다: {p}\n"
                f"  WE_ROOT 로 WE 설치본 루트를 지정할 것(현재 {WE_ROOT!r}).\n"
                f"  이 둘이 없으면 버전 근거(zlib 외 전부)와 귀속 대조군이 사라진다.")

    text = open(lic, encoding="utf-8", errors="replace").read()
    names = [html.unescape(m.group(1)).strip()
             for m in re.finditer(r"<div>\s*([^<>\n][^<>]{0,60}?)\s*</div>", text)]
    verdicts, unknown = {}, []
    for n in names:
        if n in LICENSE_PAGE_VERDICT:
            verdicts[n] = LICENSE_PAGE_VERDICT[n]
        else:
            unknown.append(n)
            verdicts[n] = "**미분류** — 이 이름은 이 스크립트가 모른다. 판정을 추가할 것."

    js = open(log, encoding="utf-8", errors="replace").read()
    revs = {}
    for m in re.finditer(r"REV (\d+)</div> <pre class=\"changelogBody\">(.*?)</pre>", js, re.S):
        body = html.unescape(re.sub("<[^>]+>", "", m.group(2)))
        for line in body.replace("\\n", "\n").splitlines():
            line = line.strip(" -\t")
            if line and CHANGELOG_PROBE.search(line):
                revs.setdefault(f"REV {m.group(1)}", []).append(line)
    return names, verdicts, unknown, revs


def main():
    if not os.path.isfile(BIN):
        raise SystemExit(
            f"[linked-libs] 바이너리가 없다: {BIN}\n"
            f"  WE_BINARY 로 원본 wallpaper64.exe 를 지정할 것(sha256 40e2ce02…, 5,360,112 B).")
    data = open(BIN, "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    img = Image(data)

    by_lib = scan_source_paths(img)
    ascii_libs = scan_ascii_markers(img)
    fps, fp_bad = scan_data_fingerprints(img)
    sites, site_bad = scan_code_sites(img)
    absent = scan_absent(img)
    name_hits = scan_names(img)
    names, verdicts, unknown, revs = read_vendor_attribution()

    # 지문이 어긋나면 **쓰지 않는다.** 틀린 곳을 가리키는 근거는 없는 근거보다 나쁘다.
    if fp_bad or site_bad:
        for b in fp_bad + site_bad:
            print(f"  지문 불일치: {b}", file=sys.stderr)
        raise SystemExit("[linked-libs] 지문이 이 바이너리와 맞지 않는다 — 정본을 쓰지 않았다.")

    asserts = {}
    for lib, toks in ASSERTIONS.items():
        found = {}
        for t in toks:
            i = data.find(t.encode(ENCODING))
            found[t] = img.where(i) if i >= 0 else None
        asserts[lib] = found

    ev = specfmt.ev("binary", f"wallpaper64.exe (WE 2.8.42 원본, sha256 {sha}, {len(data)} bytes)",
                    f"UTF-16LE 문자열 전수 스캔 · 값은 파일 오프셋과 VA · 정규식 {UTF16_RUN.pattern!r}")
    ev_fp = specfmt.ev("binary", f"wallpaper64.exe (sha256 {sha})",
                       "문자열이 아니라 .rdata 의 고유 상수·표 바이트열과 함수 선두 바이트로 "
                       "동정한다. VA 는 imagebase 0x140000000 기준.")
    ev_we = specfmt.ev("file", f"WE 2.8.42 설치본 ({WE_ROOT}) "
                               "bin/licenses/licenses_main.html · ui/dist/scripts/scripts.js",
                       "WE 자신의 서드파티 귀속 페이지와 REV 변경 이력. 제품 전체 목록이라 "
                       "wallpaper64.exe 밖의 항목이 절반 이상이다 — 대조군으로만 쓴다.")

    entries = [
        specfmt.entry("linkedLibs.sourcePaths",
                      {lib: dict(sorted(paths.items())) for lib, paths in sorted(by_lib.items())},
                      "확정", [ev]),
        specfmt.entry("linkedLibs.assertions", asserts, "확정", [ev]),
        specfmt.entry("linkedLibs.asciiOnly", {
            "왜 따로 재는가": "위 sourcePaths/assertions 는 UTF-16LE 전용이다. 그 근거가 MSVC "
                             "어서션의 __FILE__ 이고, 그게 wide 인 이유는 `_wassert` 를 쓰는 "
                             "**C++ 라이브러리**이기 때문이다. 즉 이 방법은 **C 라이브러리를 "
                             "원리적으로 못 본다** — 그쪽은 narrow 문자열만 남긴다.",
            "[2026-08-20 자기정정]": "이 문서가 함정 ⑨('ASCII-only 검색이 거짓 부재를 만든다')를 "
                                     "세워 놓고 **반대 방향으로 같은 실수**를 하고 있었다. "
                                     "아래 넷은 UTF-16LE 스캔에 한 건도 안 걸린다(utf16leHits 전부 0) — "
                                     "정본이 '서드파티 전수' 라고 적으면서 넷을 통째로 빠뜨렸다.",
            "[2026-08-21 두 번째 자기정정]": "그 수정도 여전히 **문자열 스캔**이었다. 문자열이 "
                                             "아예 없는 라이브러리(msdfgen·Perlin Simplex Noise)는 "
                                             "이 표에도 못 들어온다 — `linkedLibs.stringlessLibs` 가 "
                                             "그 부류를 맡는다. lz4 는 이번에 여기 추가됐지만 "
                                             "걸린 문자열이 WE 자신의 실패 메시지 한 줄이라 "
                                             "동정의 본체는 역시 코드 지문 쪽이다.",
            "libraries": ascii_libs,
            "총계": f"UTF-16LE 경로로 잡히는 {len(by_lib)}종(WE 자체 트리 `wallpaper` 포함, "
                    f"`json` 은 RapidJSON+JsonCpp 병존) + ASCII 로 잡히는 {len(ascii_libs)}종 + "
                    f"문자열 없이 코드 지문으로만 잡히는 {len(DATA_FINGERPRINTS)}종",
            "남은 한계": "이 목록도 **하드코딩 마커**다. 새 라이브러리가 들어오면 여전히 못 잡는다. "
                        "2026-08-21 에 그물을 하나 더 걸었다 — WE 자신의 귀속 페이지에 "
                        "**모르는 이름이 생기면 실패**한다(`linkedLibs.vendorAttribution`). "
                        "완전히 닫히지는 않는다: 귀속 페이지에 안 적힌 라이브러리는 여전히 안 보인다.",
        }, "확정", [ev]),
        specfmt.entry("linkedLibs.stringlessLibs", {
            "왜 이 항목이 있는가": "문자열 스캔이 원리적으로 못 보는 부류가 있다 — 로그도 어서션도 "
                                  "없는 헤더/소스 몇 개짜리 C++ 라이브러리. **msdfgen 은 "
                                  "wallpaper64.exe 에 자기 이름을 한 글자도 남기지 않는다**"
                                  "(`msdfgen` ASCII·UTF-16LE 양쪽 0건). 그래서 .rdata 에 구워진 "
                                  "고유 상수·표와 그것을 쓰는 함수 VA 로 동정한다.",
            "검증 방식": "데이터 지문은 **기대 히트수**와 다르면, 코드 지문은 그 VA 의 선두 바이트가 "
                        "다르면 스크립트가 정본을 쓰지 않고 죽는다. 근거가 엉뚱한 곳을 가리키는 것이 "
                        "근거가 없는 것보다 나쁘다는 이 리포의 반복된 교훈을 코드 지문에도 적용했다.",
            "이름 검색을 읽는 법":
                "아래 nameSearches 는 **라이브러리 이름 자체**를 양쪽 인코딩으로 찾은 결과다. "
                "msdfgen 은 다섯 토큰 전부 0건이다 — 이 문서가 코드 지문으로 가야 했던 이유가 "
                "이 줄에 있다. 나머지 셋의 히트는 라이브러리 이름이 아니다: "
                "`simplexnoise` @VA 0x140491f98 과 `fbmnoise` @VA 0x140491fa8 은 파티클 "
                "**remap 오퍼레이터 이름**이고(같은 표에 remap·multiply·triangle·average 가 "
                "나란히 있다), `LZ4` 는 WE 자신의 실패 메시지 `\"LZ4 error.\"` 다.",
            "nameSearches": name_hits,
            "dataFingerprints": fps,
            "codeSites": sites,
            "msdfgen": {
                "무엇": "Viktor Chlumsky 의 multi-channel signed distance field 생성기. "
                        "WE 는 이걸로 폰트 아틀라스를 **런타임에** 굽는다.",
                "왜 런타임인가": "동봉 폰트 자산이 전부 .ttf/.otf 아웃라인이고 미리 구운 MSDF "
                                "아틀라스가 하나도 없다(`Sources/WapleRender/Resources/WEAssets/fonts/`). "
                                "소비 쪽 셰이더는 있다 — `shaders/font.frag` 의 `median(r,g,b)` 와 "
                                "`ScreenPxRange()`, 그리고 `materials/fonts/basefont_msdf.json` 등 "
                                "MSDF 콤보 머티리얼 4종. 즉 **생성기는 바이너리 안에 있어야 한다.**",
                "버전": "정확한 릴리스 태그는 바이너리에 없다(버전 문자열 자체가 없다). "
                        "코드 지문으로 하한만 말할 수 있다 — `Shape::normalize()` 의 "
                        "`MSDFGEN_CORNER_DOT_EPSILON-1`(= -0.999999) 과 "
                        "`MSDFGEN_DEFAULT_MIN_DEVIATION_RATIO`(= 1.11111111111111111), "
                        "그리고 `solveCubic` 의 `1e6` 임계(옛 판은 `1e-14` 였다)가 모두 있다. "
                        "연도 근거는 설치본 라이선스 사본의 'Copyright (c) 2014 - 2025 "
                        "Viktor Chlumsky' 뿐이다.",
                "언제 들어왔나": "설치본 변경 이력 REV 4319 'Added msdfgen for advanced font "
                                "rendering.' (라이선스는 REV 4344 에 추가).",
            },
            "perlin-simplex-noise": {
                "무엇": "Sebastien Rombauts 의 SimplexNoise.cpp — Stefan Gustavson 의 "
                        "simplexnoise1234 를 C++ 로 옮긴 것. 라이선스 페이지의 이름이 "
                        "'Perlin Simplex Noise' 다.",
                "왜 Rombauts 판으로 보는가": "① 순열표가 512가 아니라 **256**이다(Gustavson 원본은 "
                                            "512를 굽고 `perm[i & 0xff]` 로 읽는다). "
                                            "② 1D 스케일이 `0.395f`, 2D 스케일이 `45.23065f` — "
                                            "Gustavson 원본의 `40.0f` 가 아니다. "
                                            "③ `fractal(octaves, …)` 옥타브 API 가 함께 있다. "
                                            "라이선스 사본의 'Copyright (c) 2012-2014 Sebastien "
                                            "Rombauts' 와 일치한다.",
                "버전": "미상 — 태그도 버전 문자열도 없다. 저작권 연도 2012-2014 만 남아 있다.",
                "어디에 쓰이나":
                    "perm[256] @VA 0x140484f40 바로 앞이 파티클 remap 오퍼레이터 이름 "
                    "문자열들을 가리키는 포인터 표이고(→ `remap` @VA 0x140491f6c), 그 표에 "
                    "`simplexnoise`·`fbmnoise` 가 들어 있다. 같은 번역 단위로 보이므로 "
                    "파티클 remap 의 노이즈 변환이 소비처다[추정]. 옥타브 API(fractal)가 "
                    "함께 링크된 것이 `fbmnoise` 와 맞아떨어진다.",
            },
            "gustavson-perm-sse": {
                "무엇": "같은 Perlin/Gustavson 순열표의 **두 번째 사본**. 이쪽은 512바이트이고 "
                        "앞에 `permMod12[512]` 가 붙는 'Simplex noise demystified' 배치다.",
                "누구 것인가": "라이선스 페이지에 대응 항목이 없고, 변경 이력이 "
                              "REV 4135 'New 2D simplex SSE noise generator.' / "
                              "REV 4136 'Moving SSE utilities into separate library.' 라고 적는다. "
                              "그래서 **서드파티가 아니라 WE 자신의 SSE 이식**으로 본다 — "
                              "공용인 것은 공개 도메인 순열표뿐이다[추정].",
                "실제 코드": "SoA(레인 4개) 3D simplex 두 벌. F3=1/3 · G3=1/6 · 감쇠 0.6f · "
                            "`&255` 마스크를 __m128 상수로 굽고, "
                            "`[reg + imagebase + 0x4833a0]`(perm) 과 `+0x4831a0`(permMod12) 로 "
                            "색인한다 — 변경 이력은 2D 라고 적지만 상수는 3D 것이다. "
                            "스칼라 경로(perlin-simplex-noise)와 **두 벌이 공존**한다.",
            },
            "lz4": {
                "무엇": "Yann Collet 의 LZ4. `.pkg`/`.tex` 압축 해제 경로.",
                "왜 문자열로 안 잡혔나": "바이너리에 `LZ4` 를 담은 문자열은 WE 자신이 찍는 "
                                        "`\"LZ4 error.\"` 한 줄뿐이다. 라이브러리 자체는 "
                                        "문자열을 안 남긴다.",
                "버전": "미상 — 변경 이력 REV 3981 'Updated LZ4.' 만 있고 번호가 없다.",
            },
        }, "확정", [ev_fp, ev_we]),
        specfmt.entry("linkedLibs.notLinked", {
            "규칙": "부재를 주장하려면 **어떤 인코딩으로 어떤 패턴을 돌렸는지**를 함께 적어야 한다. "
                   "이 항목은 그 규칙을 처음부터 지킨 것이다 — 아래는 전부 ASCII·UTF-16LE "
                   "양쪽으로 대소문자 무시 검색한 결과이고, 히트 목록이 비어 있는 것이 근거다.",
            "무엇을 뜻하지 않는가": "'WE 제품에 없다' 가 아니라 **'wallpaper64.exe 안에 없다'** 다. "
                                   "V8·CEF·FreeImage·jc_voronoi 는 플러그인 DLL 에 있고, "
                                   "OpenCV·Assimp·Compressonator·nQuant 는 에디터 쪽으로 보인다 — "
                                   "귀속 페이지에는 전부 적혀 있다.",
            "probes": absent,
        }, "확정", [ev]),
        specfmt.entry("linkedLibs.vendorAttribution", {
            "왜 대조군인가": "WE 가 직접 만든 서드파티 고지 페이지다. 우리 하드코딩 목록이 조용히 "
                            "낡는 것을 **WE 자신의 문서로** 감시한다 — 페이지에 이 스크립트가 "
                            "모르는 이름이 생기면 `unknownNames` 에 쌓이고 화면에 경고가 뜬다.",
            "왜 그대로 못 베끼는가": "제품 전체(에디터·UI·플러그인 DLL 포함) 목록이라 "
                                    "wallpaper64.exe 에 안 들어 있는 것이 절반 이상이다. "
                                    "그래서 이름마다 바이너리 판정을 붙여 둔다.",
            "names": names,
            "verdicts": verdicts,
            "unknownNames": unknown,
            "changelog": revs,
            "버전이 여기서만 나오는 것들": {
                "JsonCpp": "REV 4130 'Updated JSONcpp  to 1.9.6.'",
                "GLM": "REV 4090 'Updated GLM to 10.1.' (원문 표기 그대로. GLM 1.0.1 로 읽는 것이 "
                       "자연스럽지만 바이너리에 버전 문자열이 없어 **미판정**이다.)",
                "LZ4": "REV 3981 'Updated LZ4.' — 번호 없음.",
                "msdfgen": "REV 4319 'Added msdfgen for advanced font rendering.' — 번호 없음. "
                           "라이선스 사본 저작권 연도가 '2014 - 2025'.",
                "zlib": "여기가 아니라 **바이너리**에 있다 — `inflate 1.3.1 Copyright 1995-2024 "
                        "Mark Adler`. 이 문서에서 버전 문자열이 바이너리에 있는 유일한 항목이다.",
            },
        }, "확정", [ev_we]),
        specfmt.entry("linkedLibs.matrixConvention", {
            "fact": "DirectXMath(행벡터·행우선)와 GLM(열벡터·열우선)이 **동시에** 링크돼 있다.",
            "whyItMatters": "mul-convention.json 과 Scene3DMath 의 전치 논증은 행벡터 규약을 전제한다. "
                            "전제 자체는 XMMatrixPerspectiveFov* 어서션이 뒷받침하지만, GLM 병존은 "
                            "**어느 행렬 경로가 어느 규약을 따르는가**를 미판정으로 만든다.",
            "notAContradiction": "Scene3DMath.perspective 가 XMMatrixPerspectiveFovRH 와 성분 단위로 "
                                 "일치함은 별도로 확인됐다 — 이 항목은 '틀렸다'가 아니라 "
                                 "'근거가 하나 더 필요하다'는 기록이다.",
            "nextStep": "gtc\\quaternion.inl 링크는 3D 오브젝트 회전 오일러 순서(Scene3DMath 가 "
                        "'다축 혼합 회전 미판정' 으로 남긴 항목)를 정적으로 좁힐 출발점이다 — "
                        "쿼터니언 경유는 ZYX 내재 회전 관례를 함의한다.",
        }, "확정", [ev]),
        specfmt.entry("linkedLibs.correctedClaims", {
            "encoding": "이 문자열들은 전부 UTF-16LE 다. ASCII grep 은 0건을 낸다.",
            "corrected": [
                "'D:\\dev\\we\\... 경로·RapidJSON·FFTS 는 fabricated' → 20개 경로가 실존한다.",
                "'no FFT/spectrum library strings' → FFTS 가 링크돼 있다(ffts_static.c).",
                "'jsoncpp (NOT RapidJSON)' → 같은 src\\json\\ 트리에 병존한다. "
                "그 판단의 근거로 인용된 파서 에러 문자열은 RapidJSON 자신의 GetParseError_En() 표다.",
                "'GLM 언급 0건' → 링크돼 있다. 어느 정본도 몰랐다(양쪽 리포 grep 0건).",
            ],
            "rule": "바이너리 부재를 주장하려면 **어떤 인코딩으로 어떤 명령을 돌렸는지**를 함께 적을 것.",
            "[2026-08-20] 이 규칙을 이 문서가 스스로 어겼다":
                "위 규칙을 세워 놓고 정작 자기는 UTF-16LE 만 돌려서 harfbuzz·freetype·zlib·wuffs 를 "
                "통째로 놓쳤다(linkedLibs.asciiOnly 참조). 규칙은 대칭이다 — **어느 한쪽 인코딩만 "
                "돌린 결과로 부재를 주장하지 마라.**",
            "[2026-08-21] 두 번째로 어겼다 — 이번엔 '문자열' 자체가 그물이었다":
                "인코딩을 양쪽 다 돌려도 **문자열을 안 남기는 라이브러리**는 못 본다. msdfgen 은 "
                "자기 이름을 한 글자도 안 남기는데 폰트 렌더 경로의 중심이었고, "
                "Perlin Simplex Noise(Rombauts)·LZ4 도 같은 부류였다. 셋 다 정본에 없었다. "
                "규칙을 한 번 더 넓힌다 — **문자열 0건은 부재의 근거가 아니다.** "
                "고유 상수·구운 표·함수 지문까지 돌린 결과여야 한다(linkedLibs.stringlessLibs).",
            "propagatedInto": "Waple 로 전파된 것은 docs/handoff-2026-08-17.md:176,234 두 줄뿐이었고 "
                              "정정했다. spec/ 정본은 같은 검사를 전수 통과했다.",
        }, "확정", [ev, ev_fp]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_linked_libraries.py", entries),
                 os.path.join("spec", "engine", "linked-libraries.json"))

    print(f"바이너리 {BIN}\n  sha256 {sha}  {len(data)} bytes  (인코딩 {ENCODING})")
    for lib, paths in sorted(by_lib.items(), key=lambda kv: -len(kv[1])):
        got = asserts.get(lib)
        n = f"  어서션 {sum(1 for v in got.values() if v)}/{len(got)}" if got else ""
        print(f"  {lib:14} 경로 {len(paths):2}개{n}")
    for lib, rows in ascii_libs.items():
        hit = sum(1 for v in rows["markers"].values() if v["ascii"])
        extra = ""
        if lib == "freetype":
            extra = f" · 모듈 {rows['moduleCount']}/{len(FREETYPE_MODULES)}"
        elif lib == "wuffs":
            extra = f" · 상태 접두사 {rows['statusPrefixCount']}종 "\
                    f"({'·'.join(rows['statusPrefixes'])})"
        print(f"  {lib:14} ASCII 마커 {hit}/{len(rows['markers'])}{extra}")
    for lib in DATA_FINGERPRINTS:
        n_fp = len(fps[lib])
        n_site = len(sites.get(lib, {}))
        print(f"  {lib:22} 데이터 지문 {n_fp}종 · 코드 지문 {n_site}곳 (전부 대조 통과)")
    print(f"  lz4                    코드 지문 {len(sites['lz4'])}곳 (전부 대조 통과)")
    zero = [k for k, v in name_hits.items()
            if not any(r["ascii"] or r["utf16le"] for r in v.values())]
    print(f"  이름 문자열 0건 {len(zero)}/{len(name_hits)}종 {zero}")
    empty = [k for k, v in absent.items()
             if not any(r["ascii"] or r["utf16le"] for r in v.values())]
    print(f"  부재 확인 {len(empty)}/{len(absent)}종 (양쪽 인코딩 0건)")
    print(f"  귀속 페이지 이름 {len(names)}개 · 미분류 {len(unknown)}개"
          + (f" → {unknown}" if unknown else ""))
    if unknown:
        print("  ** 귀속 페이지에 모르는 이름이 있다. LICENSE_PAGE_VERDICT 에 판정을 추가할 것. **",
              file=sys.stderr)


if __name__ == "__main__":
    main()
