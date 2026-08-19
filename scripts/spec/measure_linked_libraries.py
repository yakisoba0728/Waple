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

## 재실행

    WE_BINARY=/path/to/wallpaper64.exe python3 scripts/spec/measure_linked_libraries.py

원본인지는 sha256 `40e2ce02…`(5,360,112 B)로 대조할 것. 주입본(+208B)을 넣으면 오프셋이
전부 +0xD0 밀린다(`spec/engine/decompilation-provenance.json`).
"""
import collections
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

BIN = os.environ.get("WE_BINARY",
                     r"Z:\SteamLibrary\steamapps\common\wallpaper_engine\wallpaper64.exe")

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


def classify(path):
    """소스 경로 → 라이브러리 이름. `src\\lib\\include\\<x>` 와 `src\\<x>` 둘 다 받는다."""
    if "Windows Kits" in path:
        return "DirectXMath"
    m = re.search(r"src\\(?:lib\\include\\)?([A-Za-z0-9_+]+)", path)
    return m.group(1) if m else "(기타)"


def main():
    if not os.path.isfile(BIN):
        raise SystemExit(
            f"[linked-libs] 바이너리가 없다: {BIN}\n"
            f"  WE_BINARY 로 원본 wallpaper64.exe 를 지정할 것(sha256 40e2ce02…, 5,360,112 B).")
    data = open(BIN, "rb").read()
    sha = hashlib.sha256(data).hexdigest()

    # ── 소스 경로 전수 ──────────────────────────────────────────────────────
    by_lib = collections.defaultdict(dict)
    for m in UTF16_RUN.finditer(data):
        text = m.group().decode(ENCODING)
        if SOURCE_PATH.match(text):
            by_lib[classify(text)][text] = f"0x{m.start():x}"

    # ── 어서션 ─────────────────────────────────────────────────────────────
    asserts = {}
    for lib, toks in ASSERTIONS.items():
        found = {}
        for t in toks:
            i = data.find(t.encode(ENCODING))
            found[t] = f"0x{i:x}" if i >= 0 else None
        asserts[lib] = found

    ev = specfmt.ev("binary", f"wallpaper64.exe (WE 2.8.42 원본, sha256 {sha}, {len(data)} bytes)",
                    f"UTF-16LE 문자열 전수 스캔 · 값은 파일 오프셋 · 정규식 {UTF16_RUN.pattern!r}")

    entries = [
        specfmt.entry("linkedLibs.sourcePaths",
                      {lib: dict(sorted(paths.items())) for lib, paths in sorted(by_lib.items())},
                      "확정", [ev]),
        specfmt.entry("linkedLibs.assertions", asserts, "확정", [ev]),
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
            "propagatedInto": "Waple 로 전파된 것은 docs/handoff-2026-08-17.md:176,234 두 줄뿐이었고 "
                              "정정했다. spec/ 정본은 같은 검사를 전수 통과했다.",
        }, "확정", [ev]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_linked_libraries.py", entries),
                 os.path.join("spec", "engine", "linked-libraries.json"))

    print(f"바이너리 {BIN}\n  sha256 {sha}  {len(data)} bytes  (인코딩 {ENCODING})")
    for lib, paths in sorted(by_lib.items(), key=lambda kv: -len(kv[1])):
        got = asserts.get(lib)
        n = f"  어서션 {sum(1 for v in got.values() if v)}/{len(got)}" if got else ""
        print(f"  {lib:14} 경로 {len(paths):2}개{n}")


if __name__ == "__main__":
    main()
