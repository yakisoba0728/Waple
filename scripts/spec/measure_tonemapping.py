"""톤 곡선·감마·디더의 **부재**와 블룸 두 경로의 갈림 → spec/engine/tonemapping.json.

왜 별도 문서인가
----------------
인접 정본이 각자 한 축씩만 담고 있어서 "최종 픽셀에 어떤 곡선이 걸리는가" 가 어디에도 없었다:

  · `spec/engine/shaders.json`     — 셰이더 **문면**(식). 어느 것이 런타임에 로드되는지는 안 담는다.
  · `spec/engine/render-pass.json` — 패스 **목록·순서·슬롯**. 색 공간·정밀도는 안 담는다.
  · `spec/engine/hdr-bloom.json`   — HDR **피라미드**만. LDR 3패스는 안 담는다.
  · `spec/engine/uniform-feed.json`— 유니폼 **급전**. 부재 증명은 안 담는다.

이 문서가 담는 것(겹치는 사실은 `crossRef` 로 가리키고 다시 쓰지 않는다 — 정본 자기모순 방지):

  1. 톤 곡선·노출·화이트포인트·디더의 **부재**를, 식별자 전수 + **상수 적재 자리 수**로.
  2. sRGB 전이함수가 **어디에**, **어느 방향으로** 걸리고 그중 무엇이 **런타임에 도달**하는가.
  3. 체인이 도는 **색 공간과 정밀도** — 렌더타깃 포맷 enum 선택 지점.
  4. LDR ↔ HDR 두 경로가 **어느 명령에서** 갈리는가.

부정 결론의 표본 설계
---------------------
"톤매핑이 없다" 는 부정 결론이다. 표본이 그것을 **보여줄 수 있는지** 먼저 밝힌다.

  · 최종 합성은 `Composite::frame`(`0x14017fa70`–`0x1401816cc`) 안에서 끝나고, 그 패스가 쓰는
    셰이더는 WE 가 **평문으로 배포**한다(동봉 137파일 = 설치본 `assets/shaders` 와 전건 동일).
  · 따라서 곡선이 있다면 (a) 그 평문에 있거나 (b) 엔진이 CPU 에서 상수를 실어야 한다.
  · (a) 는 식별자 전수로, (b) 는 **f32 비트패턴 이미지 전수 스캔**으로 잰다(방법론 함정 4:
    호출 사이트가 아니라 **적재 자리 수**를 센다 — 인라인 사본까지 포함하는 상한이라 0 이 강하다).
  · 재지 **않은** 것도 적는다(`notScanned`).

재현
----
    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_tonemapping.py

`WE_ROOT` 아래 `wallpaper64.exe` 와 씬 코퍼스가 둘 다 있어야 돈다. 하나라도 없으면
**부분 산출을 만들지 않고** exit(1) 한다(0 건을 확정으로 찍는 것보다 낫다 —
`scripts/spec/check_spec_shrink_guard.py` 머리말).

돌린 뒤 `git status` 가 비어 있어야 정상이다(재생성 고정점).
"""
import collections
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WEASSETS = os.path.join(REPO, "Sources", "WapleRender", "Resources", "WEAssets")
SHADERS = os.path.join(WEASSETS, "shaders")
MATS = os.path.join(WEASSETS, "materials", "util")
OUT = os.path.join(REPO, "spec", "engine", "tonemapping.json")
LDR_MATH = os.path.join(REPO, "Sources", "WapleCore", "LDRBloomMath.swift")
HDR_MATH = os.path.join(REPO, "Sources", "WapleCore", "HDRBloomMath.swift")
LDR_PASS = os.path.join(REPO, "Sources", "WapleRender", "LDRBloomPass.swift")
HDR_POST = os.path.join(REPO, "Sources", "WapleRender", "HDRPostPass.swift")

WE_ROOT = os.environ.get("WE_ROOT", "")
BINARY = os.path.join(WE_ROOT, "wallpaper64.exe") if WE_ROOT else ""
IMAGEBASE = 0x140000000

# 톤 곡선·노출·적응·디더를 **이름으로** 가진 것 전부. 대소문자 무시로 센다.
TONE_TOKENS = ("ACES", "Reinhard", "Uncharted", "filmic", "Hable", "tonemap", "whitepoint",
               "exposure", "luminance", "histogram", "adapt", "dither", "bayer")

# 바이너리 문자열 전수. ASCII 와 UTF-16LE 를 **둘 다** 본다(방법론 함정 8).
# `sRGB`/`srgb` 를 대문자 `SRGB` 와 **따로** 세는 이유: 대문자만 재면 0 이 나와
# "sRGB 문자열이 아예 없다" 는 과장된 결론을 만든다. 실제로는 둘 다 1 건씩 있고
# 그 정체가 이 문서의 결론을 바꾸지 않는다는 것을 아래 `binaryStringHits` 가 적는다.
BIN_TOKENS = ("gamma", "Gamma", "GAMMA", "tonemap", "ToneMap", "Tonemap", "TONEMAP",
              "exposure", "Exposure", "dither", "Dither", "bayer", "Bayer",
              "whitepoint", "luminance", "histogram", "ACES", "Reinhard",
              "SRGB", "sRGB", "srgb")

# f32 적재 자리 수를 셀 상수. 셋으로 나뉜다:
#  · transfer — sRGB/감마 전이함수. 있으면 엔진이 CPU 에서 색을 변환한다는 뜻이다.
#  · operator — 유명 톤 연산자의 계수. 있으면 그 연산자가 이식돼 있다는 뜻이다.
#  · luma     — 셰이더가 쓰는 밝기 가중치. 셰이더 평문에만 있는지 확인하는 대조군이다.
#
# 세 번째 원소는 **판별력**이다. 둥근 십진수(0.10 · 0.20 · 0.02 · 0.30 · 0.50 …)는 어느
# 프로그램에나 나오므로 그 자리 수가 0 이 아니어도 아무 것도 뜻하지 않는다. 실제로
# `Hable.C=0.10` 은 4자리가 잡히는데 그중 셋은 `Scene::Scene` 의 `bloomhdrfeather` 기본값
# 0.1(`0x1401870d8` 의 즉치)과 그 형제들이다. 판별력 없는 상수를 근거로 세면 그 순간
# 부재 결론이 거짓이 되므로, **판정은 판별력 있는 상수에만 건다**(재지 않은 것을 숨기지 않으려고
# 판별력 없는 것도 같이 실어 두되 라벨을 붙인다).
TRANSFER_CONSTS = (("2.4", 2.4, True), ("1.055", 1.055, True), ("12.92", 12.92, True),
                   ("0.04045", 0.04045, True), ("0.055", 0.055, True),
                   ("0.0031308", 0.0031308, True), ("1/2.4", 0.416666667, True),
                   ("2.2", 2.2, True), ("1/2.2", 1.0 / 2.2, True))
OPERATOR_CONSTS = (("ACES.a=2.51", 2.51, True), ("ACES.c=2.43", 2.43, True),
                   ("ACES.d=0.59", 0.59, True), ("ACES.e=0.14", 0.14, True),
                   ("Uncharted2.W=11.2", 11.2, True), ("Hable.A=0.15", 0.15, False),
                   ("Hable.B=0.50", 0.50, False), ("Hable.C=0.10", 0.10, False),
                   ("Hable.D=0.20", 0.20, False), ("Hable.E=0.02", 0.02, False),
                   ("Hable.F=0.30", 0.30, False))
LUMA_CONSTS = (("Rec601.0.299", 0.299, True), ("Rec601.0.587", 0.587, True),
               ("Rec601.0.114", 0.114, True), ("Rec601.0.2989", 0.2989, True),
               ("Rec601.0.5870", 0.5870, True), ("Rec601.0.1140", 0.1140, True),
               ("Rec709.0.2126", 0.2126, True), ("Rec709.0.7152", 0.7152, True),
               ("Rec709.0.0722", 0.0722, True))

# 포맷 enum → DXGI 점프 테이블. 디스패처 `sub_1400d2a20` 이 `cmp ecx,0x1b` + `ja default` 로
# 상한을 잡고 `[표 + rax*4]` 의 RVA 로 점프한다. 그 28엔트리 표를 **바이너리에서 읽는다**
# (하드코딩 아님). 표 자체는 `.text` 안의 데이터다 — 코드가 아니므로 명령 경계가 아니다.
FORMAT_TABLE_VA = 0x1400D2AA4      # [VA-데이터표]
FORMAT_TABLE_N = 28
# `_SRGB` 로 끝나는 DXGI_FORMAT 값 전부. 하나라도 arm 에 있으면 하드웨어 sRGB 뷰가 가능하다.
DXGI_SRGB_VALUES = (29, 72, 75, 78, 91, 93, 99)
DXGI_NAMES = {0: "UNKNOWN", 10: "R16G16B16A16_FLOAT", 11: "R16G16B16A16_UNORM",
              13: "R16G16B16A16_SNORM", 24: "R10G10B10A2_UNORM", 28: "R8G8B8A8_UNORM",
              34: "R16G16_FLOAT", 39: "R32_TYPELESS", 40: "D32_FLOAT", 41: "R32_FLOAT",
              49: "R8G8_UNORM", 54: "R16_FLOAT", 55: "D16_UNORM", 61: "R8_UNORM",
              71: "BC1_UNORM", 74: "BC2_UNORM", 77: "BC3_UNORM", 98: "BC7_UNORM"}


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def shader_files():
    out = []
    for root, _dirs, files in os.walk(SHADERS):
        for name in files:
            out.append(os.path.join(root, name))
    return sorted(out)


def rel(path):
    return os.path.relpath(path, SHADERS).replace("\\", "/")


# ---------------------------------------------------------------- 셰이더 전수

def identifier_census(files):
    """식별자별 히트 파일 수와 히트 줄. 0 이 결론이므로 0 을 그대로 적는다."""
    census = {}
    for token in TONE_TOKENS:
        pat = re.compile(re.escape(token), re.I)
        hits = []
        for p in files:
            for i, line in enumerate(read(p).splitlines(), 1):
                if pat.search(line):
                    hits.append(f"{rel(p)}:{i}")
        census[token] = {"files": len(set(h.rsplit(":", 1)[0] for h in hits)), "sites": hits}
    return census


def transfer_sites(files):
    """전이함수를 담은 파일과 **방향**. 방향은 함수 이름이 아니라 상수로 판정한다.

    `combine_hdr_editor.frag` 의 함수 이름은 `srgb()` 지만 본문은 지수 2.4 · 무릎 0.04045 라
    **디코드**다. 이름으로 방향을 정하면 뒤집힌다(방법론 함정 27 의 색 공간판).
    """
    out = {}
    for p in sorted(files):
        src = read(p)
        if "pow" not in src:
            continue
        decode = "0.04045" in src
        enc_srgb = "0.416666667" in src
        enc_22 = bool(re.search(r"pow\(\s*albedo\s*,\s*1\s*/\s*2\.2\s*\)", src))
        if not (decode or enc_srgb or enc_22):
            continue
        # 적용 지점 = 선언이 아니라 **호출**. `downsample_quarter_linear` 는 헬퍼를 만들지 않고
        # `pow(albedo, 1/2.2)` 를 본문에 바로 쓴다 — 이름으로만 찾으면 0건이 된다.
        apply_sites = []
        for i, line in enumerate(src.splitlines(), 1):
            s = line.strip()
            if s.startswith("//") or s.startswith("vec3 "):
                continue
            if re.search(r"\b(lin|srgb|_srgb)\s*\(", line) or "pow(albedo, 1/2.2)" in line:
                apply_sites.append(f"{rel(p)}:{i}")
        out[rel(p)] = {
            "declaredFunctions": re.findall(r"vec3 (\w+)\(vec3 v\)", src),
            "direction": ("sRGB→linear (디코드 · EOTF)" if decode else
                          "linear→sRGB (인코드 · OETF)" if enc_srgb else
                          "linear→감마2.2 (인코드)"),
            "knee": "0.04045" if decode else ("0.0031308" if "0.0031308" in src else "없음"),
            "exponent": "2.4" if decode else ("0.416666667 (= 1/2.4)" if enc_srgb else "1/2.2"),
            "applySites": apply_sites,
        }
    return out


def material_shader_map():
    out = {}
    for name in sorted(os.listdir(MATS)):
        if not name.endswith(".json"):
            continue
        try:
            doc = json.loads(read(os.path.join(MATS, name)))
        except ValueError:
            continue
        passes = doc.get("passes") or []
        if not passes:
            continue
        p = passes[0]
        out[name[:-5]] = {"shader": p.get("shader"), "combos": p.get("combos"),
                          "textures": p.get("textures")}
    return out


def blur13_weights():
    """13탭 가중을 셰이더 평문에서 **읽어** 온다(하드코딩 아님)."""
    out = {}
    for name in ("downsample_eighth_blur_v.frag", "blur_h_bloom.frag"):
        src = read(os.path.join(SHADERS, name))
        out[name] = [float(x) for x in re.findall(r"\.rgb \* (0\.\d+)", src)]
    return out


def blur_stride():
    out = {}
    for name in ("downsample_eighth_blur_v.vert", "blur_h_bloom.vert"):
        src = read(os.path.join(SHADERS, name))
        m = re.search(r"float localTexel = g_TexelSize\.([xy]) \* ([0-9.]+);", src)
        out[name] = {"axis": m.group(1), "fullResTexels": float(m.group(2))} if m else None
    return out


# ---------------------------------------------------------------- 바이너리 전수

def pe_sections(data):
    e = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, e + 6)[0]
    optsz = struct.unpack_from("<H", data, e + 20)[0]
    base = e + 24 + optsz
    out = []
    for i in range(nsec):
        o = base + 40 * i
        name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
        vsz, va, rawsz, rawoff = struct.unpack_from("<IIII", data, o + 8)
        out.append((name, va, vsz, rawoff, rawsz))
    return out


def off_to_va(sections, off):
    for _name, va, _vsz, rawoff, rawsz in sections:
        if rawoff <= off < rawoff + rawsz:
            return IMAGEBASE + va + (off - rawoff)
    return None


def va_to_off(sections, va):
    r = va - IMAGEBASE
    for _name, sva, vsz, rawoff, rawsz in sections:
        if sva <= r < sva + max(vsz, rawsz):
            d = r - sva
            if d < rawsz:
                return rawoff + d
    return None


def section_of(sections, off):
    for name, _va, _vsz, rawoff, rawsz in sections:
        if rawoff <= off < rawoff + rawsz:
            return name
    return "?"


def binary_string_census(data):
    """ASCII · UTF-16LE 를 둘 다 센다(방법론 함정 8)."""
    return {t: {"ascii": data.count(t.encode()),
                "utf16le": data.count(t.encode("utf-16-le"))} for t in BIN_TOKENS}


def float_load_sites(data, sections, consts):
    """**적재 자리 수** — 그 f32 비트패턴이 이미지에 몇 번 박혀 있는가(방법론 함정 4).

    호출 사이트를 세면 인라인 사본을 놓친다. 이미지 전수 바이트 스캔이 상한이자 하한이다.
    5.36MB 이미지에서 임의의 4바이트 패턴이 우연히 맞을 기대값은 0.00125 회라 **0 은 강하다**.

    `where` 가 주는 주소는 **명령 주소가 아니라 그 4바이트가 놓인 위치**다. `.rdata` 면 상수
    그 자체이고, `.text` 면 `mov [r+d], imm32` 같은 명령의 **즉치 필드 한복판**이다. 그래서
    줄마다 `[VA-스캐너위치]` 마커를 붙인다 — `scripts/re/va_citations.py` 가 그 뜻으로 읽고
    경계 검사에서 뺀다(정본 JSON 은 줄에 주석을 달 수 없으므로 값 안에 넣는다).
    """
    census = {}
    for label, value, discriminating in consts:
        bits = struct.pack("<f", value)
        sites, start = [], 0
        while True:
            i = data.find(bits, start)
            if i < 0:
                break
            va = off_to_va(sections, i)
            sites.append("%s [VA-스캐너위치] %s" % ("%#x" % va if va else "?",
                                                  section_of(sections, i)))
            start = i + 1
        census[label] = {"loadSites": len(sites), "discriminating": discriminating,
                         "where": sites[:4]}
    return census


def discriminating_total(*censuses):
    """판별력 있는 상수의 적재 자리 수 합. 부재 결론이 걸리는 **단 하나의 수**다."""
    return sum(row["loadSites"] for c in censuses for row in c.values() if row["discriminating"])


def positive_control(consts):
    """**양성 대조** — 같은 스캐너로 다른 이미지를 재서 "0 은 스캐너가 고장난 것이 아니다" 를 보인다.

    부재 결론의 최대 약점은 "재는 방법이 틀려서 0 이 나온 것" 이다. 그래서 같은 f32 비트패턴
    스캔을 `bin/FreeImage64.dll`(이미지 코덱 — sRGB 전이함수를 **정당하게** 가진다)과
    `bin/d3dcompiler_47.dll`(셰이더 컴파일러 — 색 변환을 하지 않는다)에 그대로 돌린다.
    앞이 0 이 아니고 뒤가 0 이면 스캐너가 살아 있고 결과가 이미지별로 갈린다는 뜻이다.

    파일이 없으면 그 항목을 빼고 나머지만 적는다(없는 값을 지어내지 않는다).
    """
    out = {}
    for name in ("FreeImage64.dll", "d3dcompiler_47.dll", "webwallpaper64.exe", "scenescript64.dll"):
        path = os.path.join(WE_ROOT, "bin", name)
        if not os.path.exists(path):
            continue
        with open(path, "rb") as fh:
            blob = fh.read()
        out[name] = {label: blob.count(struct.pack("<f", value))
                     for label, value, _d in consts}
    return out


def format_enum_table(data, sections):
    """`sub_1400d2a20` 의 포맷 enum → DXGI 표를 **바이너리에서 읽는다**.

    `cmp ecx,0x1b` 로 상한을 잡고 `[표 + rax*4]` 의 RVA 로 점프하는 arm 하나하나가
    `mov eax, imm32 ; ret` 이다. 표 자체는 `.text` 안의 데이터다(`[VA-데이터표]`).
    """
    off = va_to_off(sections, FORMAT_TABLE_VA)
    out = {}
    for i in range(FORMAT_TABLE_N):
        rva = struct.unpack_from("<I", data, off + 4 * i)[0]
        aoff = va_to_off(sections, IMAGEBASE + rva)
        b = data[aoff:aoff + 5]
        if b[0] == 0xB8:                       # mov eax, imm32
            dxgi = struct.unpack_from("<I", data, aoff + 1)[0]
        elif b[0] == 0x33:                     # xor eax, eax
            dxgi = 0
        else:
            dxgi = None
        out["%#04x" % i] = {"dxgi": dxgi, "name": DXGI_NAMES.get(dxgi, "?")}
    return out


def material_runtime_reach(data, mats):
    """머티리얼이 **런타임에 열릴 수 있는가** — 두 증거를 따로 센다.

    처음엔 전체 경로(`materials/util/<name>.json`)만 셌는데 그건 **과잉 주장**이었다.
    엔진은 짧은 이름으로도 연다: `solidlayer`(`0x140490ba0`)·`passthrough`(`0x140490b90`)는
    전체 경로가 없는데 **맨몸 이름**이 이미지에 있다. 전체 경로만 보고 "미로드" 라고 하면
    그 부류를 통째로 오판한다.

    그래서 둘을 나눠 싣고, **둘 다 없을 때만** `unreachable` 로 판정한다:
      · `pathString` — `materials/util/<name>.json` 이 이미지에 있는가
      · `bareName`   — `<name>` 이 이미지에 있는가(다른 문자열의 부분일 수 있으므로 그 자체로는
        약한 증거다. 실제로 `combine.json` 히트는 `volumetrics_combine.json` 의 일부였다)
    """
    out = {}
    for name in sorted(mats):
        path = ("materials/util/%s.json" % name).encode()
        bare = name.encode()
        has_path = data.count(path) > 0
        has_bare = data.count(bare) > 0
        out[name] = {"pathString": has_path, "bareName": has_bare,
                     "verdict": "loadable" if has_path else
                                ("nameOnly" if has_bare else "unreachable")}
    return out


# ---------------------------------------------------------------- 씬 코퍼스

def corpus_reach():
    """**설치본 단일 모집단** 씬 전수의 `general.hdr` × `general.bloom` 분포.

    모집단: `WE_ROOT` 아래 이름 글롭 `{scene,gifscene}.json` = **186 씬**
    (설치본 `assets/` + `projects/`).

    **[2026-08-28] 종전엔 동봉 `WEAssets/` 와 설치본 `WE_ROOT/` 를 둘 다 훑어 358 을 냈다.
    그것은 이중계수다** — 동봉 트리는 설치본 `assets/` 를 그대로 복사한 것이라(이 파일이
    셰이더에 대해 이미 "동봉 137파일 = 설치본 assets/shaders 와 전건 동일" 이라고 적고 있다)
    172 씬을 두 번 셌다. 358 = 172(동봉) + 186(설치본). 도수를 두 배 가까이 부풀리면서
    `hdrScenes` 에는 `previewthunderbolt` 가 동봉·설치 두 경로로 실려 고유 HDR 씬이 3인데
    4로 보였다.

    고쳐서 **설치본 하나만** 훑는다. 도수를 적을 때는 반드시 이 모집단 이름을 붙인다.
    참고: 같은 트리를 **구조 기준**(`objects` + `general|camera` 키를 가진 json)으로 세면
    190 이고 분포는 {180, 7, 3, 0} 이다 — 기준이 다르면 수가 다르다는 사실 자체를
    `spec/engine/scene-objects.json` 의 `scene.corpus.objectIDCensus` 가 담는다.
    """
    # (루트, 상대경로 기준, 결과에 붙일 접두). 접두를 남기는 이유는 머신마다 다른 절대
    # 경로를 정본에 넣지 않으면서 어느 트리의 씬인지는 남기기 위해서다.
    roots = ((WE_ROOT, WE_ROOT, "WE_ROOT/"),)
    files = []
    for r, base, prefix in roots:
        for dp, _dn, fn in os.walk(r):
            for f in fn:
                if f in ("scene.json", "gifscene.json"):
                    files.append((os.path.join(dp, f), base, prefix))
    combo = collections.Counter()
    hdr_scenes = []
    for p, base, prefix in sorted(files):
        try:
            with open(p, encoding="utf-8-sig") as fh:
                d = json.load(fh)
        except (ValueError, OSError):
            continue
        g = d.get("general") or {}
        h, b = bool(g.get("hdr", False)), bool(g.get("bloom", False))
        combo[(h, b)] += 1
        if h:
            hdr_scenes.append(prefix + os.path.relpath(p, base).replace("\\", "/"))
    return len(files), combo, sorted(hdr_scenes)


# ---------------------------------------------------------------- Waple 탐침

def waple_probes():
    """구현이 같은 사실을 담고 있는지 — 정본이 고아가 되지 않게 실제 파일을 읽는다.

    탐침이 소스를 놓치면 값이 조용히 `false`/`탐침 불일치` 로 무너지고, 재생성이 축소 가드에
    막힌다. `measure_hdr_bloom.py` 가 `weDownsample4` → `weBox4` 개명으로 실제로 당한 사고다.
    """
    lm, hm = read(LDR_MATH), read(HDR_MATH)
    lp, hp = read(LDR_PASS), read(HDR_POST)
    return {
        "ldr.defaultStrength": float(re.search(r"defaultStrength: Float = ([0-9.]+)", lm).group(1)),
        "ldr.defaultThreshold": float(re.search(r"defaultThreshold: Float = ([0-9.]+)", lm).group(1)),
        "ldr.blur13HalfWeights": [
            float(x) for x in re.search(r"blur13HalfWeights: \[Float\] = \[\s*([^\]]+)\]", lm)
            .group(1).replace("\n", " ").split(",") if x.strip()],
        "ldr.extractTapIsFullResTexel": bool(re.search(
            r"extractTapOffsetUV\(sourceWidth: Int, sourceHeight: Int\) -> SIMD2<Float> \{\s*"
            r"fullFrameTexelUV", lm)),
        "ldr.horizontalStepIsTwoQuarterTexels": bool(re.search(
            r"horizontalStepUV\(quarterWidth: Int\) -> SIMD2<Float> \{\s*SIMD2\(2 /", lm)),
        "ldr.verticalStepIsOneEighthTexel": bool(re.search(
            r"verticalStepUV\(eighthHeight: Int\) -> SIMD2<Float> \{\s*SIMD2\(0, 1 /", lm)),
        "ldr.gateIsSaturateOfExcess": "min(max(scale - threshold, 0), 1)" in lm,
        "ldr.saturationBoostFoldsToTwoCMinusGray": "2 * gated - SIMD3(repeating: gray)" in lm,
        "ldr.compositeIsPlainAddition": bool(re.search(
            r"composite\(scene: SIMD3<Float>, glow: SIMD3<Float>\) -> SIMD3<Float> \{\s*"
            r"scene \+ glow", lm)),
        "ldr.noStrengthNormalization": "normalizedStrength" not in lm and "normalizedStrength" not in lp,
        "hdr.hasStrengthNormalization": bool(re.search(
            r"return strength / \(powf\(scatter, exponent\) \+ 1\)", hm)),
        "hdr.blendParamsKneeIsThresholdTimesFeather": "max(threshold * feather, 0)" in hm,
        "post.finalIsSaturateOnly": "saturate(c.rgb * exposure)" in hp,
        "post.noTransferFunction": not any(t in hp for t in ("0.04045", "1.055", "12.92", "0.416666667")),
    }


# ---------------------------------------------------------------- 조립

def build(data, sections, files):
    ident = identifier_census(files)
    bstr = binary_string_census(data)
    transfer = float_load_sites(data, sections, TRANSFER_CONSTS)
    operator = float_load_sites(data, sections, OPERATOR_CONSTS)
    luma = float_load_sites(data, sections, LUMA_CONSTS)
    control = positive_control(TRANSFER_CONSTS)
    tsites = transfer_sites(files)
    mats = material_shader_map()
    reach = material_runtime_reach(data, mats)
    fmt = format_enum_table(data, sections)
    weights = blur13_weights()
    strides = blur_stride()
    probes = waple_probes()
    n_scenes, combo, hdr_scenes = corpus_reach()

    srgb_arms = sorted({v["dxgi"] for v in fmt.values()} & set(DXGI_SRGB_VALUES))

    shader_ev = specfmt.ev("shader", "Sources/WapleRender/Resources/WEAssets/shaders",
                           "WE 2.8.42 동봉 원본 — 설치본 assets/shaders 와 파일 목록·내용 전건 동일")
    mat_ev = specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/materials/util")
    bin_ev = specfmt.ev("binary",
                        "wallpaper64.exe (imagebase 0x140000000) — 이미지 전수 바이트 스캔"
                        "(f32 비트패턴 · ASCII/UTF-16LE 문자열 · 점프표)")
    # [2026-08-28] 종전 ref 는 "동봉 172 + 설치본 186 = 358" 이었다 — 두 트리가 같은 집합이라
    # 그 덧셈 자체가 이중계수다. 모집단을 설치본 하나로 못 박는다.
    corpus_ev = specfmt.ev("corpus", "설치본 assets/ + projects/ 186 씬(이름 글롭 "
                                     "{scene,gifscene}.json)의 general.hdr / general.bloom",
                           "단일 모집단이다. 동봉 WEAssets/ 는 설치본 assets/ 의 사본이라 "
                           "같이 세면 172 씬이 두 번 들어간다",
                           "설치본 assets/ + projects/ — 이름 글롭 {scene,gifscene}.json 186씬")
    script_ev = specfmt.ev("script", "scripts/spec/measure_tonemapping.py")
    ldr_math_ev = specfmt.ev("file", "Sources/WapleCore/LDRBloomMath.swift")
    hdr_math_ev = specfmt.ev("file", "Sources/WapleCore/HDRBloomMath.swift")

    return [

        specfmt.entry("engine.tonemap.operatorAbsence", {
            "verdict": "톤매핑 연산자·노출·자동노출·화이트포인트가 **없다**. 최종 픽셀 연산은 "
                       "가산과 `saturate` 클램프뿐이고 `saturate` 는 곡선이 아니다 — 어깨도 발끝도 없다.",
            "samplingDesign": "최종 합성은 Composite::frame(0x14017fa70–0x1401816cc) 안에서 끝나고 "
                              "그 패스의 셰이더는 WE 가 평문 배포한다. 곡선이 있다면 (a) 평문에 있거나 "
                              "(b) 엔진이 상수를 실어야 한다. (a)=identifierCensus, "
                              "(b)=binaryOperatorConstants 로 각각 쟀고 둘 다 0 이다.",
            "shaderPopulation": len(files),
            "identifierCensus": ident,
            "identifierCensusNote": "유일한 히트는 `ACES` 1건이고 그것은 **오타 주석**이다 — "
                                    "HLSL/dx11playlisttransition.vert 의 \"Move pieaces up and down\" "
                                    "안의 `ace`. 코드 식별자는 0건이다.",
            "binaryStringCensus": bstr,
            "binaryStringHits": {
                "sRGB": "ASCII 1건. **문자열이 아니다** — `0x1400b8817 cmp ecx, 0x42475273` 의 "
                        "즉치 필드다. 같은 함수가 `\"#png: bad chunk\"`(0x140479a38)를 참조하므로 "
                        "**PNG 청크 타입 판별**이고 렌더 파이프라인과 무관하다.",
                "srgb": "ASCII 1건. `materials/util/combine_srgb.json` 경로 문자열의 일부다"
                        "(transferFunctionSites 참조).",
                "그 밖": "gamma · tonemap · exposure · dither · bayer · whitepoint · luminance · "
                        "histogram · ACES · Reinhard 는 ASCII·UTF-16LE 양쪽 0건이다.",
            },
            "binaryOperatorConstants": operator,
            "binaryTransferConstants": transfer,
            "binaryLumaConstants": luma,
            "transferConstantPositiveControl": control,
            "transferConstantPositiveControlNote": "부재 결론의 최대 약점은 **재는 방법이 틀려서 "
                                                   "0 이 나왔을 가능성**이다. 같은 f32 스캐너를 설치본의 "
                                                   "다른 이미지에 그대로 돌려 그 가능성을 닫는다. "
                                                   "`bin/FreeImage64.dll`(이미지 코덱)은 sRGB 전이함수를 "
                                                   "정당하게 갖고 있어 **0 이 아닌 값**이 나오고, "
                                                   "`bin/d3dcompiler_47.dll`·`bin/webwallpaper64.exe`·"
                                                   "`bin/scenescript64.dll` 은 0 이다. 곧 스캐너는 살아 "
                                                   "있고 `wallpaper64.exe` 의 0 은 실제 부재다.",
            "discriminatingLoadSiteTotal": discriminating_total(operator, transfer),
            "discriminatingNote": "부재 결론이 걸리는 수는 `discriminatingLoadSiteTotal` **하나**다 — "
                                  "판별력 있는 톤 연산자 계수와 전이함수 상수의 적재 자리 수 합. "
                                  "`discriminating:false` 로 표시된 둥근 십진수(0.15 · 0.5 · 0.1 · "
                                  "0.2 · 0.02 · 0.3)는 어느 프로그램에나 나오므로 **근거가 아니다**. "
                                  "실측이 그것을 보여 준다: `Hable.C=0.10` 4자리 중 셋은 "
                                  "`Scene::Scene` 의 `bloomhdrfeather` 기본값 0.1(`0x1401870d8` 의 "
                                  "즉치)과 그 형제 필드다. 숨기지 않고 싣되 판정에서 뺀다.",
            "lumaConstantHits": "Rec.709 삼중(0.2126 · 0.7152 · 0.0722)만 각 1건이고 셋 다 `.rdata` "
                                "상수다. 소비처는 세 함수이고 전부 8비트 정수 색을 255.0 으로 나눠 "
                                "0.6333 과 비교하는 자리다(`0x14003d877` `mulss` … `0x14003d8a4` "
                                "`divss 255.0` → `0x14003d8ac` `subss 0.6333`; 같은 함수가 "
                                "`DwmIsCompositionEnabled` 를 GetProcAddress 로 찾는다) — "
                                "**데스크톱 강조색 대비 판정**이지 씬 톤매핑이 아니다. "
                                "셰이더가 쓰는 Rec.601 삼중(0.299/0.587/0.114 · 0.2989/0.5870/0.1140)은 "
                                "**적재 자리 0** 이라 평문에만 있다 — 곧 그 dot 은 GPU 에서만 돈다.",
            "howToRead": "`loadSites` 는 호출 사이트가 아니라 **그 f32 비트패턴이 이미지에 박힌 "
                         "횟수**다(방법론 함정 4). 5.36MB 에서 임의 4바이트가 우연히 맞을 기대값은 "
                         "0.00125 회라 0 은 강하다 — 0 이면 그 상수를 쓰는 코드가 이 이미지에 없다.",
            "notScanned": [
                "다른 실행 파일/DLL 의 **결론**(bin/webwallpaper64.exe · bin/scenescript64.dll · "
                "bin/wallpaperui.exe · bin/mediaextensions64.dll) — 최종 합성을 소유하지 않으므로 "
                "이 문서의 범위 밖이다. 다만 전이함수 상수만은 위 positiveControl 에서 같이 쟀다",
                "워크샵 저작 셰이더 — 씬이 자기 이펙트에 곡선을 넣는 것은 엔진 규약이 아니다",
                "bin/ 의 서드파티 DLL(FreeImage64.dll · d3dcompiler_47.dll 등)의 **내부 동작** — "
                "전이함수 상수를 정당하게 가질 수 있고, 실제로 FreeImage 가 갖고 있다(positiveControl)",
            ],
            # **`probes` 전체를 여기 다시 싣지 않는다.** 같은 dict 를 두 항목에 복제하면 한쪽만
            # 고쳐질 때 정본이 자기 자신과 모순된다(방법론 함정 20). 부재와 직접 얽힌 두 탐침만
            # 싣고 나머지는 engine.bloom.ldr.arithmetic.wapleProbes 가 소유한다.
            # (실증: 복제해 뒀을 때 한쪽 사본을 돌연변이시켰더니 어떤 테스트도 잡지 못했다.)
            "wapleParity": {
                "post.finalIsSaturateOnly": probes["post.finalIsSaturateOnly"],
                "post.noTransferFunction": probes["post.noTransferFunction"],
                "note": "HDRPostPass.hdrpost_f 가 `saturate(c.rgb * exposure)` 뿐이고 전이함수 "
                        "상수를 하나도 갖지 않는다 — WE 와 일치. 나머지 탐침은 "
                        "engine.bloom.ldr.arithmetic.wapleProbes 가 소유한다.",
            },
            "crossRef": "spec/engine/shaders.json shaders.bloom (셰이더 문면) · "
                        "spec/engine/render-pass.json engine.renderPass.order (패스 순서)",
        }, "확정", [shader_ev, bin_ev, script_ev]),

        specfmt.entry("engine.tonemap.transferFunctionSites", {
            "howDirectionIsDecided": "**함수 이름이 아니라 상수로 판정한다.** 지수 2.4 + 무릎 0.04045 "
                                     "= 디코드(sRGB→linear), 지수 0.416666667(=1/2.4) 또는 1/2.2 = "
                                     "인코드. `combine_hdr_editor.frag` 의 함수 이름은 `srgb()` 지만 "
                                     "본문은 `passthroughsrgb.frag` 의 `lin()` 과 같은 디코드다 — "
                                     "이름으로 방향을 정하면 뒤집힌다.",
            "sites": tsites,
            "materialToShader": mats,
            "runtimeReachable": reach,
            "runtimeReachableNote": "세 등급이다. `loadable` = `materials/util/<name>.json` 전체 경로가 "
                                    "이미지에 있다(엔진이 그 경로로 연다). `nameOnly` = 전체 경로는 "
                                    "없지만 **맨몸 이름**이 있다 — 다른 방식으로 열릴 수 있으므로 "
                                    "미로드로 단정하지 않는다(실사례: `solidlayer` `0x140490ba0` · "
                                    "`passthrough` `0x140490b90`). `unreachable` = **둘 다 없다** — "
                                    "그때만 런타임이 열 방법이 없다고 말한다. "
                                    "**[정정] 종전 초안은 전체 경로만 보고 판정했는데 그건 과잉 주장이었다** "
                                    "— `nameOnly` 부류를 통째로 미로드로 오판한다. "
                                    "`unreachable` 도 만능은 아니다: 엔진이 이름을 **이어붙여** 만드는 "
                                    "자리가 있으므로(HDR 피라미드 RT 이름이 `\"_rt_\"` + 숫자 + "
                                    "`\"FrameBuffer\"` 로 만들어진다 — `0x14017f3ae`–`0x14017f3d3`) "
                                    "`solidlayer_depthtest` 처럼 기존 문자열의 이어붙임으로 만들 수 있는 "
                                    "이름은 이 표만으로 미로드를 단정하면 안 된다. 아래 "
                                    "`unreachableTransferPaths` 셋은 그 예외에 걸리지 않는 것만 골랐다.",
            "unreachableTransferPaths": {
                "combine_hdr_editor": "전체 경로도 맨몸 이름도 **없다** → 런타임 미로드. `srgb()` 라는 "
                                      "오해를 부르는 이름이 화면에 닿지 않는다는 뜻이다.",
                "combine_hdr_upsample_linear": "전체 경로도 맨몸 이름도 **없다**. 이 머티리얼만 "
                                               "`combine_hdr` 의 `LINEAR=1` 콤보를 건다 — 즉 `lin()` 을 "
                                               "건너뛰는 분기(combine_hdr.frag `#if LINEAR == 1`)는 "
                                               "**도달 불가**다.",
                "combine_hdr_upsample_dbg": "전체 경로도 맨몸 이름도 **없다**. `COMBINEDBG=1` 분기도 "
                                            "도달 불가.",
                "howVerified": "위 셋의 맨몸 이름은 `combine_hdr_editor` · "
                               "`combine_hdr_upsample_linear` · `combine_hdr_upsample_dbg` 로 충분히 "
                               "길어 다른 문자열의 부분이 될 수 없다(짧은 이름 `combine` 은 "
                               "`volumetrics_combine.json` 의 부분으로 잡히므로 그런 이름에는 이 논법을 "
                               "쓰지 않는다).",
            },
            "loadSelection": "combine 슬롯 `[composite+0x3150]` 은 `0x14017fb45`–`0x14017fb6f` 에서 "
                             "셋 중 하나로 정해진다: bit13&&bit14 → combine_dhdr_upsample"
                             "(`0x14017fb49`), bit13 → combine_hdr_upsample, 아니면 combine_ldr"
                             "(`0x14017fb5c` `lea rdx` · `0x14017fb63` `cmovne rdx,rax`). "
                             "블룸이 꺼진 HDR 용 슬롯 `[+0x3158]` 은 `0x14017fb88`–`0x14017fb9f` 에서 "
                             "bit16 이면 combine_video_hdr, 아니면 combine_srgb 다.",
            "ldrHasNoTransferFunction": True,
            "ldrHasNoTransferFunctionWhy": "LDR 이 쓰는 combine_ldr → combine.frag 에는 `pow` 가 "
                                           "한 번도 나오지 않는다. 감마 논쟁이 화면에 닿는 표본은 "
                                           "`hdr:true` 씬뿐이다(finalPixelExpression.corpusReach).",
            "crossRef": "spec/engine/shaders.json shaders.bloom · "
                        "spec/engine/render-pass.json engine.renderPass.materialInputs",
        }, "확정", [shader_ev, mat_ev, bin_ev, script_ev]),

        specfmt.entry("engine.tonemap.finalPixelExpression", {
            "byPath": {
                "LDR + bloom": "scene + bloom — combine.frag:10-15. 곡선 없음, 클램프는 UNORM 타깃이 한다.",
                "LDR + bloom off": "최종 패스 자체가 없다 — 씬이 이미 타깃에 그려져 있다"
                                   "(`0x140180b97` `test r13b,r13b` 의 `je` 가 combine 을 통째로 건너뛴다).",
                "HDR + bloom (SDR)": "saturate(lin(scene + 4탭bloom)) * g_RenderVar0.x — combine_hdr.frag:43",
                "HDR + bloom (HDR10)": "lin(max(0, saturate(scene) + bloom)) * "
                                       "(g_RenderVar0.y * smoothstep(1,5,dot((0.299,0.587,0.114),c)) "
                                       "+ g_RenderVar0.x) — combine_hdr.frag:27-32",
                "HDR + bloom off": "lin(scene) — passthroughsrgb.frag:15",
                "비디오 HDR(bit16)": "saturate(rgb / (2*g_HDRParams.y)) * (2*g_HDRParams.y) — "
                                    "combine_video_hdr.frag:10-13. 순수 클리핑이다.",
            },
            "saturateIsClampNotCurve": "[0,1] 구간은 **항등**이고 >1 은 1.0 이다. 어깨도 발끝도 없으므로 "
                                       "ACES/Reinhard 로 바꾸면 저역까지 곡선변형돼 이탈한다.",
            "hdrBoostRampIsNotAToneCurve": "combine_hdr.frag:31 의 smoothstep(1,5,luma) 는 톤 곡선이 "
                                           "아니라 **HDR10 헤드룸 배수 램프**다. DISPLAYHDR 콤보 안에만 "
                                           "있고 SDR 경로에는 실리지 않는다.",
            "corpusPopulation": "**설치본 assets/ + projects/**, 이름 글롭 `{scene,gifscene}.json`. "
                                "[2026-08-28] 종전 358 은 이중계수였다 — 동봉 "
                                "`Sources/WapleRender/Resources/WEAssets/` 는 설치본 `assets/` 의 "
                                "사본이라 172 씬을 두 번 셌다(358 = 172 + 186). 단일 모집단으로 "
                                "다시 세면 **186** 이고 분포도 그만큼 줄어든다"
                                "({348,6,4,0} → {178,5,3,0}; 산술 확인 348 = 178+170 · 6 = 5+1 · "
                                "4 = 3+1). 같은 트리를 **구조 기준**(`objects` + `general|camera`)으로 "
                                "세면 190 / {180,7,3,0} 이다 — 기준이 다르면 수가 다르다.",
            "corpusScenes": n_scenes,
            "corpusReach": {
                "LDR + bloom off": combo[(False, False)],
                "LDR + bloom on": combo[(False, True)],
                "HDR + bloom on": combo[(True, True)],
                "HDR + bloom off": combo[(True, False)],
            },
            "hdrScenes": hdr_scenes,
            "hdrScenesNote": "고유 HDR 씬은 **3개**다. 종전 4개는 `previewthunderbolt` 를 동봉 경로와 "
                             "설치 경로로 두 번 실은 것이다 — 이중계수의 같은 뿌리.",
            "reachReading": "감마 논쟁(`lin()` 이식 여부)이 화면에 닿는 표본은 **설치본 186 씬** 중 "
                            "`hdr:true` 쪽 3건뿐이고, `hdr:true && !bloom` 은 코퍼스에 **0건**이라 "
                            "`passthroughsrgb` 경로는 설치본 어느 씬으로도 재현되지 않는다.",
            "crossRef": "spec/engine/shaders.json shaders.composite · "
                        "spec/engine/render-pass.json engine.renderPass.order",
        }, "확정", [shader_ev, corpus_ev, script_ev]),

        specfmt.entry("engine.tonemap.chainColorSpace", {
            "question": "톤매핑·블룸·감마가 **어느 색 공간과 정밀도에서** 도는가.",
            "renderTargetFormatSelect": "컴포지트가 만드는 **모든** 컬러 타깃의 포맷은 한 자리에서 "
                                        "정해진다: `0x14017f317 mov edi,1`(LDR 기본) · "
                                        "`0x14017f323 mov ecx,0xf`(HDR) · `0x14017f328 shr r14d,0xd` + "
                                        "`0x14017f32c and r14b,1`(= flags bit13) · "
                                        "`0x14017f33d cmovne edi,ecx` · `0x14017f340 mov [rbp+0x130],edi`. "
                                        "그 값이 `_rt_FullFrameBuffer`(`0x14017f5a3`), 피라미드 레벨"
                                        "(`0x14017f47d`), LDR 3버퍼(`0x14017f5a3` 뒤 `0x14017f5ea`)에 "
                                        "**같이** 실린다.",
            "formatEnumToDXGI": fmt,
            "formatEnumToDXGINote": "`sub_1400d2a20` 의 28엔트리 점프표를 이미지에서 읽은 것이다"
                                    "(표 `0x1400d2aa4` — `.text` 안의 데이터). "
                                    "enum 1 → 28 `R8G8B8A8_UNORM`, enum 0xf → 10 "
                                    "`R16G16B16A16_FLOAT`, enum 0x1b → 0 `UNKNOWN`(= 없음).",
            "srgbArmsPresent": srgb_arms,
            "noHardwareSRGB": "28 arm 중 `_SRGB` DXGI 값(29·72·75·78·91·93·99)이 **0건**이다 — "
                              "엔진은 sRGB 텍스처 뷰를 만들 수단 자체가 없다. 스왑체인도 "
                              "`0x140008146 mov dword [rbp-0x40], 0x1c`(=28 UNORM)로 채워 "
                              "`0x140008172 call [rax+0x50]`(CreateSwapChain)에 넘긴다. "
                              "곧 셰이더의 `lin()` 을 상쇄할 하드웨어 인코드는 존재하지 않는다.",
            "precisionByPath": {
                "LDR": "체인 전체가 **8비트 UNORM**이다. `_rt_FullFrameBuffer`(`0x14017f5ac`) · "
                       "`_rt_4FrameBuffer`(`0x14017f5c6` 이름 → `0x14017f618` 슬롯) · "
                       "`_rt_8FrameBuffer`(`0x14017f62a` → `0x14017f65c`) · "
                       "`_rt_Bloom`(`0x14017f66e` → `0x14017f686`) 넷 다 같은 포맷 인자를 받는다. "
                       "곧 추출·블러 결과가 **매 패스 [0,1] 로 잘린다** — 임계를 넘긴 밝기가 "
                       "1.0 이상으로 살아남지 못한다.",
                "HDR": "`_rt_FullFrameBuffer` 와 피라미드 레벨 전부가 **fp16**(enum 0xf → DXGI 10)이다. "
                       "1.0 초과가 보존되므로 소프트-니 임계(`bloomhdrthreshold` 기본 1.0)가 의미를 갖는다.",
            },
            "depthOnBloomTargets": "블룸 타깃 넷은 깊이 인자가 전부 enum `0x1b`(= DXGI 0 UNKNOWN = "
                                   "깊이 버퍼 없음)다. `_rt_FullFrameBuffer` 만 `0x14017f591 "
                                   "lea eax,[rax*4+0x16]` 로 flags bit0 에 따라 0x16(D16_UNORM) 또는 "
                                   "0x1a 를 받는다.",
            "whereGammaSitsInOrder": "감마 디코드는 **블룸 합성과 같은 셰이더 안**에서, 블룸을 더한 "
                                     "뒤에 걸린다(combine_hdr.frag:43 `saturate(lin(albedo))`). 곧 "
                                     "블룸은 **감마 인코드된 값 위에서** 더해지고 그 합에 디코드가 걸린다. "
                                     "그 뒤 그레이딩(ccsimple `[+0x3188]`, `0x140180bd2`)과 "
                                     "페이드(`[+0x3180]`, `0x140180c96`)가 온다 — **감마가 그레이딩보다 앞**이다.",
            "noDitherBeforeEightBit": "8비트 백버퍼로 내려가기 전에 밴딩을 깨는 단계가 없다 — "
                                      "engine.postprocess.ditherAbsence 참조.",
            "crossRef": "spec/engine/render-state.json · spec/engine/render-targets.json · "
                        "spec/engine/render-pass.json engine.renderPass.frameObjectFields",
        }, "확정", [bin_ev, script_ev]),

        specfmt.entry("engine.postprocess.ditherAbsence", {
            "verdict": "디더링 패스가 **없다**. fp16 또는 8비트 타깃에서 8비트 백버퍼로 내려가면서 "
                       "밴딩을 깨는 단계가 WE 에 존재하지 않는다.",
            "shaderFilesWithDitherToken": ident["dither"]["files"] + ident["bayer"]["files"],
            "binaryAscii": (bstr["dither"]["ascii"] + bstr["Dither"]["ascii"]
                            + bstr["bayer"]["ascii"] + bstr["Bayer"]["ascii"]),
            "binaryUtf16le": (bstr["dither"]["utf16le"] + bstr["Dither"]["utf16le"]
                              + bstr["bayer"]["utf16le"] + bstr["Bayer"]["utf16le"]),
            "noBayerTexture": "`assets/materials/util/` 의 동봉 텍스처(black · white · noise · "
                              "clouds_256 · perlin_256 · uniform_256 · flatnormal · fur · noflow)에 "
                              "베이어/블루노이즈 행렬이 없다. 디더 커널을 실을 자산이 없다.",
            "whyItMatters": "Waple 도 디더를 넣지 않는 것이 **정확**하다. 넣으면 WE 보다 부드러워져 "
                            "골든이 어긋난다 — '개선' 으로 오인하기 쉬운 자리다.",
            "crossRef": "engine.tonemap.chainColorSpace",
        }, "확정", [shader_ev, mat_ev, bin_ev, script_ev]),

        specfmt.entry("engine.bloom.ldr.arithmetic", {
            "note": "패스 목록·머티리얼·렌더타깃은 spec/engine/render-pass.json "
                    "engine.renderPass.bloomChain.ldr 이, 셰이더 문면은 spec/engine/shaders.json "
                    "shaders.bloom 이 이미 담는다. 여기 담는 것은 **탭 기하와 그 판정 근거**다.",
            "passCount": 3,
            "passCountEvidence": "`Composite::drawBloomChain` LDR 분기 `0x140183949`–`0x140183a5d` 는 "
                                 "머티리얼 세 개만 그린다: `[+0x3160]`(`0x140183966` 바인드 · "
                                 "`0x140183983` 드로우) · `[+0x3170]`(`0x1401839b5` · `0x1401839d2`) · "
                                 "`[+0x3178]`(`0x140183a04` · `0x140183a21`). 레벨 루프도 업샘플도 없다.",
            "tapUniformIsNotWrittenPerPass": "LDR 분기 전체에 `[composite+0xb8..0xc4]`(g_RenderVar0) "
                                             "스토어가 **0건**이다 — HDR 분기가 `0x1401836a0`–"
                                             "`0x1401836ba` 에서 매 패스 다시 쓰는 것과 대조된다. "
                                             "곧 LDR 의 탭 오프셋은 엔진 공통 유니폼 바인더가 채우는 "
                                             "`g_TexelSize` 하나뿐이다.",
            "blur13Weights": weights,
            "blur13Stride": strides,
            "axisNamingTrap": "`downsample_eighth_blur_v` 는 이름이 `_v` 인데 `g_TexelSize.x` 로 "
                              "**X축**이고, `blur_h_bloom` 은 `_h` 인데 `g_TexelSize.y` 로 **Y축**이다. "
                              "이름 보고 포팅하면 두 패스가 바뀐다.",
            "notCommonBlurH": "`common_blur.h` 의 `blur13`(7탭 bilinear 근사, σ≈2.02)과는 **다른 "
                              "커널**이다(13 정수탭, σ≈2.33). 이름이 같아 섞이기 쉽다.",
            "hardThresholdNotSoftKnee": "추출은 `saturate(max(rgb) − g_BloomThreshold)` 를 **곱한다** — "
                                        "비율이 아니라 초과분 자체가 감쇠 계수인 하드 임계다. "
                                        "HDR 의 소프트-니(`g_BloomBlendParams`)와 형태가 다르다.",
            "strengthIsRaw": "LDR 경로에는 **강도 정규화가 없다**. 저작값이 그대로 추출 머티리얼 "
                             "`[+0x3160]` 한 곳에만 실린다(`0x14017f994`–`0x14017fa40`: "
                             "`bloomstrength` `0x14017f9d4` · `bloomthreshold` `0x14017fa07` · "
                             "`bloomtint` `0x14017fa40`). 블러 두 패스에는 어떤 상수도 실리지 않는다.",
            "authoringDefaults": {
                "bloomstrength": "2.0 — Scene::Scene 즉시값 `0x1401870ac` (0x40000000)",
                "bloomthreshold": "0.6499999761581421 — `0x1401870b7` (0x3f266666)",
                "bloomtint": "(1,1,1) — **설치본 186 씬**(이름 글롭 {scene,gifscene}.json) 중 "
                             "저작 **77건**이 전건 \"1.00000 1.00000 1.00000\". "
                             "[2026-08-28] 종전 \"358 중 154\" 는 이중계수였다 — 동봉 77 + 설치 77 을 "
                             "더한 것이고 두 트리는 같은 집합이다.",
            },
            "wapleProbes": probes,
            "crossRef": "spec/engine/uniform-feed.json engine.uniformFeed.g_TexelSize.convention "
                        "(그쪽은 셰이더 5종 교차대조로 status 보고) · "
                        "spec/engine/shaders.json shaders.blurKernels",
        }, "확정", [shader_ev, mat_ev, bin_ev, ldr_math_ev, script_ev]),

        specfmt.entry("engine.bloom.pathDivergence", {
            "gate": "렌더러 플래그 `[composite+0x128]` **비트13(0x2000)** 하나가 두 경로를 가른다. "
                    "소비 지점은 셋이고 전부 같은 비트를 본다: "
                    "① 타깃 생성·포맷 선택 `0x14017f328`(shr) + `0x14017f33d`(cmovne) + "
                    "`0x14017f346`(test) — LDR 이면 `0x14017f55e` 로 뛰어 피라미드를 만들지 않는다. "
                    "② 파라미터 급전 `0x14017f7cb` `test dword [rsi+0x128], 0x2000` → "
                    "`0x14017f7d5 je 0x14017f994`(LDR 피드). "
                    "③ 드로우 루프 `0x140183618` 같은 test → `0x140183625 je 0x140183949`(LDR 체인).",
            "gatesBefore": "체인 자체는 비트13 **앞에** 세 게이트를 더 지난다: "
                           "`0x140180a41 test byte [rsi+0x128], 0x40`(bit6 블룸 설정) · "
                           "씬 플래그 `[scene+0xe0]` 비트1 · 씬 오브젝트 리스트 비어있지 않음"
                           "(`0x140180a68 cmp [rcx+0x158], rax`). 하나라도 false 면 "
                           "`0x140180a48 je 0x140180b69` 로 블룸 없는 분기로 간다.",
            "rows": {
                "렌더타깃 포맷": {"LDR": "enum 1 → DXGI 28 R8G8B8A8_UNORM (매 패스 [0,1] 클램프)",
                                "HDR": "enum 0xf → DXGI 10 R16G16B16A16_FLOAT",
                                "where": "0x14017f33d"},
                "추출 임계": {"LDR": "하드 — `saturate(max(rgb) − T)` 를 곱한다",
                             "HDR": "소프트-니 — `g_BloomBlendParams` = (T, T−K, 2K, 0.25/(K+1e-5)), "
                                    "K = T×feather (0x14017f8bc–0x14017f900)"},
                "임계 파라미터": {"LDR": "bloomthreshold (기본 0.65)",
                                "HDR": "bloomhdrthreshold (기본 1.0) × bloomhdrfeather (기본 0.1)"},
                "강도 파라미터": {"LDR": "bloomstrength (기본 2.0) — **생값**",
                                "HDR": "bloomhdrstrength (기본 2.0) ÷ (scatter^(max(N,2)−2) + 1) "
                                       "(0x14017f85e powf → 0x14017f86b +1.0 → 0x14017f88f divss)"},
                "채도 부스트": {"LDR": "있다 — `2c − gray`(셰이더 리터럴 sat=1.0)", "HDR": "없다"},
                "필터": {"LDR": "1/4 박스 → 13탭 가우시안 X → 13탭 가우시안 Y (고정 3패스)",
                        "HDR": "듀얼필터 피라미드 — 전 단계 4탭 박스, 가우시안 패스 없음"},
                "레벨 수": {"LDR": "고정 3 (1/4, 1/8, 1/8)",
                          "HDR": "N = max(1, min(bloomhdriterations, min(8, floor(log2(min(W,H)))))) "
                                 "(0x14017f363 min → 0x14017f541 상한 8)"},
                "탭 오프셋 유니폼": {"LDR": "g_TexelSize — 드로우 루프가 LDR 분기에서 "
                                          "[composite+0xb8..0xc4] 를 한 번도 쓰지 않는다",
                                   "HDR": "g_RenderVar0 — 드로우 루프가 패스마다 다시 쓴다 "
                                          "(0x1401836a0–0x1401836ba)"},
                "업샘플": {"LDR": "없다", "HDR": "4탭 ×0.25×scatter, 머티리얼 blending:additive"},
                "합성 머티리얼": {"LDR": "combine_ldr → combine.frag (블룸 단일 탭 가산)",
                                "HDR": "combine_hdr_upsample / combine_dhdr_upsample → combine_hdr.frag "
                                       "(블룸 ±g_TexelSize 4탭 평균 가산)"},
                "전이함수": {"LDR": "없다", "HDR": "lin() 디코드 1지점 (combine_hdr.frag:43)"},
                "블룸 off 일 때": {"LDR": "최종 패스 자체가 없다",
                                 "HDR": "combine_srgb(passthroughsrgb) 또는 bit16 이면 combine_video_hdr"},
                "틴트": {"LDR": "bloomtint (추출에 곱)", "HDR": "bloomtint (추출에 곱) — 같다"},
            },
            "sharedFacts": ["4탭 박스의 ×0.25", "bloomtint 기본 (1,1,1)",
                            "추출이 max 채널을 밝기로 쓴다(벡터 luma 가 아니다)",
                            "최종 클램프는 saturate 또는 UNORM 타깃"],
            "openQuestion": "비트13 을 **세우는** 자리는 이번 조사에서 특정하지 못했다. "
                            "`[composite+0x128]` 은 `0x140115b5d`–`0x140115b67` 의 범용 "
                            "`flags = (set | flags) & ~clear` 헬퍼로만 갱신되고, 이미지 전체에 "
                            "즉치 0x2000 을 그 필드에 or/and 하는 자리는 없다(전수 스캔 0건 — "
                            "0x2000 과 0x128 이 같은 명령에 있는 자리는 위 세 `test` 뿐이다). "
                            "즉 이 문서가 확정한 것은 비트13 의 **소비**이고, "
                            "`general.hdr` → 비트13 의 **주입**은 아직 열려 있다(방법론 함정 3).",
            "crossRef": "engine.bloom.hdr.structure · engine.bloom.hdr.levelCountRule · "
                        "spec/engine/render-pass.json engine.renderPass.conditions",
        }, "확정", [shader_ev, mat_ev, bin_ev, ldr_math_ev, hdr_math_ev, script_ev]),
    ]


def main():
    if not WE_ROOT or not os.path.exists(BINARY):
        raise SystemExit(
            "wallpaper64.exe 를 찾지 못했다: %r\n"
            "상수 적재 자리 수와 문자열 전수는 **이미지 전수 스캔**이라 부분 산출을 만들지 않는다 — "
            "WE_ROOT 를 주고 다시 돌려라." % (BINARY or "<WE_ROOT 미설정>"))
    files = shader_files()
    if len(files) < 130:
        raise SystemExit("동봉 셰이더가 %d개뿐이다 — WEAssets 가 온전하지 않다" % len(files))
    n_scenes, _combo, _hdr = corpus_reach()
    # [2026-08-28] 하한을 300 → 180 으로 내렸다. 종전 300 은 **이중계수된 358** 을 전제한
    # 값이라, 이중계수를 걷어내면 정상 실행이 이 관문에 막힌다. 단일 모집단(설치본 이름
    # 글롭)의 정상값은 186 이다.
    if n_scenes < 180:
        raise SystemExit(
            "씬 코퍼스가 %d개뿐이다 — 도달 수치를 확정으로 쓸 수 없다. "
            "WE_ROOT 가 설치본 루트(projects/ 포함)를 가리키는지 확인해라." % n_scenes)
    with open(BINARY, "rb") as fh:
        data = fh.read()
    sections = pe_sections(data)
    entries = build(data, sections, files)
    specfmt.dump(specfmt.doc("scripts/spec/measure_tonemapping.py", entries), OUT)
    print("%s: %d 항목 (셰이더 %d · 씬 %d)" % (OUT, len(entries), len(files), n_scenes))


if __name__ == "__main__":
    main()
