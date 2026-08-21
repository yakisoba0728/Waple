"""정본의 **부재 주장**을 바이너리 전수·양 인코딩으로 재검증한다.

## 왜 필요한가

"X 가 없다" 는 "X 가 있다" 보다 틀리기 쉽다. 찾는 방법이 틀리면 그냥 안 보이기 때문이다.
2026-08-19 스윕에서 그 사고가 **9건** 나왔다 — 전부 분석 리포의 산문 보고서였고, 원인은 하나다:

    wallpaper64.exe 의 MSVC 어서션·`__FILE__` 문자열은 **UTF-16LE** 인데 ASCII 로만 grep 했다.

그중에는 실존하는 소스 경로 21개를 "fabricated" 로 단정한 것, "RapidJSON 아님" 의 근거로
RapidJSON 자신의 `GetParseError_En()` 표를 인용한 것이 있다. GLM 은 아예 어느 문서에도 없었다.

**그래서 `spec/` 정본도 같은 병에 걸렸는지 확인해야 했다.** 이 스크립트가 그 감사다.
결과는 음성이었다(2026-08-19: 반증 0건) — 하지만 그 음성 결과 자체가 자산이다.
다음 사람이 같은 의심을 품었을 때 890건을 다시 추출하지 않아도 된다.

## 왜 오염되지 않았나 — 문자열 종류가 다르다

이 리포의 부재 주장은 대부분 **저작 스키마 키**(`.tex-json` 키, 셰이더 유니폼 이름)에 관한
것이고, 그것들은 런타임이 JSON/셰이더 텍스트에서 파싱하므로 바이너리에 **narrow(ASCII)** 로
박혀 있다. UTF-16 인 것은 MSVC 가 넣는 어서션·소스경로다. 즉 "전부 UTF-16" 이 아니라
**"진단 문자열은 wide, 데이터 스키마는 narrow"** 다. 이 구분을 모르면 양쪽으로 다 틀린다.

## 무엇을 재는가

정본이 "없다" 고 말하는 토큰을 설치본 바이너리 **전수**(42종)에 대해 ASCII·UTF-16LE 두
인코딩으로 센다. 부분문자열 오탐은 앞뒤 문자 검사로 막는다(`spritesheet` 가
`spritesheetsequences` 에 걸리지 않도록) — 원 측정(`measure_tex_deep.py:735-751`)과 같은 규약이고,
UTF-16LE 쪽은 2바이트 단위로 같은 논리를 적용한다.

## 재실행

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_absence_claims.py

`WE_ROOT` 는 설치본 루트(= `wallpaper64.exe` 와 `bin/` 이 있는 디렉터리)다.
CI 에서는 돌지 않는다 — 바이너리를 커밋하지 않기 때문이다(독점 소프트웨어).
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# 정본이 부재를 주장하는 토큰. **각 주장은 범위(`absentIn`)를 반드시 명시한다.**
#
# 범위 없는 부재 주장은 판정할 수 없다 — `halfmip` 은 런타임(wallpaper64.exe)에는 없지만
# 컴파일러(resourcecompiler64.exe)에는 있다. "없다" 만 적으면 둘 중 어느 쪽인지 알 수 없고,
# 이 스크립트의 첫 판에서 실제로 그 이유로 거짓 반증이 났다.
#
# `absentIn` 값:
#   "runtime"     — wallpaper64.exe
#   "we"          — WE 가 만든 바이너리 전부(서드파티 런타임 제외)
#   "all"         — 설치본 42종 전부
#   [이름, …]     — 명시한 파일들
THIRD_PARTY = ("d3dcompiler", "dxcompiler", "dxil", "assimp", "libEGL", "libGLES",
               "vk_swiftshader", "vulkan-1", "chrome_elf", "steam_api", "CUESDK",
               "FreeImage", "steammdmp")

CLAIMS = {
    "anisotropic": {
        "absentIn": "we",
        "claim": "engine/texture-filtering.json:textureFiltering.authoring.noFilterKnob "
                 "runtimeStrings.anisotropic=false — 저작에 mip 필터 노브가 없다는 부정 결론의 일부",
    },
    "ANISOTROPIC": {
        "absentIn": "we",
        "claim": "같은 항목 runtimeStrings.ANISOTROPIC=false. d3dcompiler_47.dll 의 히트는 "
                 "마이크로소프트 HLSL 컴파일러라 WE 코드가 아니다(HLSL 필터 enum 이름)",
    },
    "mipfilter": {"absentIn": "we", "claim": "같은 항목 runtimeStrings.mipfilter=false"},
    "halfmip": {
        "absentIn": "runtime",
        "claim": "같은 항목 runtimeStrings.halfmip=false. **런타임 기준이다** — "
                 "formats/tex-deep.json 의 binaryTokenCounts 는 resourcecompiler64=1 을 함께 기록한다",
    },
    "srgb": {
        "absentIn": ["wallpaper64.exe", "wallpaperui.exe", "resourcecompiler64.exe"],
        "claim": "formats/tex-deep.json:format.tex.texJson.keys deadKeys.srgb "
                 "— '세 바이너리 어디에도 독립 토큰이 없다'",
    },
    "nonpoweroftwo": {
        "absentIn": ["wallpaper64.exe", "resourcecompiler64.exe"],
        "claim": "같은 deadKeys — 'resourcecompiler64/wallpaper64 문자열 표에 없다. "
                 "wallpaperui.exe(에디터) 템플릿에만 있다'",
    },
    "PKGV": {
        "absentIn": "all",
        # **[2026-08-21 정정]** 이 주장을 "패키지 매직이 아예 없다" 로 읽으면 **틀린다.**
        # 이 스캐너는 앞뒤가 인쇄가능 문자면 **부분문자열로 보고 버린다**(`standalone_count`).
        # 그런데 실물 매직은 `PKGV` 뒤에 버전 4자리가 붙는 `PKGV0024` 형태라 그 규칙에 걸린다 —
        # `bin/wallpaperui.exe` 에 raw 로 2건 있고(`0xab2876` 은
        # `checkWallpaperPKGVersions` 의 부분문자열, `0xad0898` 이 진짜 `PKGV0024`),
        # 이 항목만 보면 "42종 어디에도 없음" 이라 반대로 읽힌다.
        # 그래서 아래 `PKGV0024` 주장을 따로 세워 **버전 붙은 형태를 직접** 잰다.
        # 종전 claim 은 `ScenePackage.swift:50-64` 라는 **줄 번호**를 인용했는데 그 줄은 이미 밀렸다.
        "claim": "맨 `PKGV` 4글자 토큰(뒤에 아무것도 안 붙는 형태)은 42종 어디에도 없다 — "
                 "'PKGV 4자리 = per-file serial' 이라는 종전 문서 서술의 근거가 되지 못한다. "
                 "버전이 붙은 실물 매직은 아래 PKGV0024 항목이 따로 잰다",
    },
    # 실물 `.pkg` 매직. **런타임(wallpaper64)과 컴파일러에는 없고 에디터에만 있다** 는 것이
    # 이 항목이 잠그는 사실이다 — `.pkg` 를 **굽는** 쪽은 에디터다.
    "PKGV0024": {
        "absentIn": ["wallpaper64.exe", "resourcecompiler64.exe"],
        "claim": "실물 패키지 매직(버전 붙은 형태). 굽는 쪽인 bin/wallpaperui.exe 에만 있고 "
                 "런타임·리소스컴파일러에는 없다 — 런타임은 매직을 즉치로 비교한다",
    },
    "WEMath": {"absentIn": "all", "claim": "엔진 수학 라이브러리 이름 후보 — 부재 확인용"},
    "g_Gravity": {
        "absentIn": "we",
        "claim": "BACKLOG wind/gravity 보류 근거 — WE 셰이더에 이 유니폼이 없다",
    },
    "g_Wind": {"absentIn": "we", "claim": "같은 근거"},
}
# 대조군(양성). 이 토큰들이 안 잡히면 스캐너가 고장 난 것이다 — 부정 결론은 양성 대조 없이 못 믿는다.
POSITIVE_CONTROLS = {
    "nointerpolation": "wallpaper64.exe 에 있어야 한다(.tex flags 0x1 저작 키)",
    "clampuvs":        "wallpaper64.exe 에 있어야 한다(.tex flags 0x2)",
    "nomip":           "resourcecompiler64.exe·wallpaperui.exe 에는 있고 wallpaper64.exe 에는 없다",
    "nonpoweroftwo":   "wallpaperui.exe(에디터)에만 있다",
}


def in_scope(binary_name, scope):
    """이 바이너리가 그 부재 주장의 범위 안인가."""
    if isinstance(scope, list):
        return binary_name in scope
    if scope == "all":
        return True
    if scope == "runtime":
        return binary_name == "wallpaper64.exe"
    if scope == "we":
        return not binary_name.startswith(THIRD_PARTY)
    raise SystemExit(f"[absence-audit] 알 수 없는 absentIn 값: {scope!r}")


def standalone_count(data, token, encoding):
    """앞뒤가 인쇄가능 문자가 아닌 **독립 토큰**만 센다(부분문자열 오탐 차단)."""
    needle = token.encode(encoding)
    hits = 0
    for m in re.finditer(re.escape(needle), data):
        s, e = m.start(), m.end()
        if encoding == "ascii":
            pre = data[s - 1] if s else 0
            post = data[e] if e < len(data) else 0
            adjacent = (0x20 <= pre <= 0x7E) or (0x20 <= post <= 0x7E)
        else:  # utf-16-le — 2바이트 단위로 같은 논리
            pre = s >= 2 and 0x20 <= data[s - 2] <= 0x7E and data[s - 1] == 0
            post = e + 1 < len(data) and 0x20 <= data[e] <= 0x7E and data[e + 1] == 0
            adjacent = pre or post
        if not adjacent:
            hits += 1
    return hits


def main():
    root = WE_ROOT
    if not os.path.isdir(root):
        raise SystemExit(f"[absence-audit] WE_ROOT 가 디렉터리가 아니다: {root}")
    paths = [os.path.join(root, "wallpaper64.exe")]
    paths += sorted(glob.glob(os.path.join(root, "bin", "*.dll")) +
                    glob.glob(os.path.join(root, "bin", "*.exe")))
    paths = [p for p in paths if os.path.isfile(p)]
    if not paths:
        raise SystemExit(f"[absence-audit] 바이너리를 하나도 못 찾았다: {root}")

    tokens = list(CLAIMS) + list(POSITIVE_CONTROLS)
    where = {t: {} for t in tokens}
    for p in paths:
        data = open(p, "rb").read()
        name = os.path.basename(p)
        for t in tokens:
            a = standalone_count(data, t, "ascii")
            u = standalone_count(data, t, "utf-16-le")
            if a or u:
                where[t][name] = {"ascii": a, "utf16le": u}

    refuted = {}
    for t, spec_ in CLAIMS.items():
        offenders = {n: v for n, v in where[t].items() if in_scope(n, spec_["absentIn"])}
        if offenders:
            refuted[t] = offenders

    controls_ok = {t: bool(where[t]) for t in POSITIVE_CONTROLS}

    ev = specfmt.ev("binary", f"WE 2.8.42 설치본 바이너리 {len(paths)}종 ({root})",
                    "독립 토큰 검사 · ASCII 와 UTF-16LE 양쪽 · 앞뒤 인쇄가능 문자 배제")

    specfmt.dump(specfmt.doc("scripts/spec/measure_absence_claims.py", [
        specfmt.entry("absence.audit.result", {
            "binariesScanned": len(paths),
            "claimsTested": len(CLAIMS),
            "refutedClaims": sorted(refuted),
            "verdict": "정본의 부재 주장 중 반증된 것 없음" if not refuted
                       else "반증된 주장이 있다 — refutedClaims 참조",
        }, "확정", [ev]),
        specfmt.entry("absence.audit.claims", CLAIMS, "확정", [ev]),
        specfmt.entry("absence.audit.occurrences", {t: where[t] for t in tokens if where[t]},
                      "확정", [ev]),
        specfmt.entry("absence.audit.positiveControls", {
            "why": "부정 결론은 양성 대조 없이 못 믿는다 — 스캐너가 아무것도 못 찾는 상태여도 "
                   "'전부 없다' 는 결과가 나오기 때문이다.",
            "expectations": POSITIVE_CONTROLS,
            "found": controls_ok,
        }, "확정", [ev]),
        specfmt.entry("absence.audit.encodingRule", {
            "rule": "이 바이너리들은 문자열 종류에 따라 인코딩이 다르다 — '전부 UTF-16' 도 "
                    "'전부 ASCII' 도 아니다.",
            "wide": "MSVC 가 넣는 어서션·`__FILE__` 소스 경로는 UTF-16LE "
                    "(예: `D:\\dev\\we\\...`, `!XMScalarNearEqual(...)`).",
            "narrow": "저작 스키마 키(.tex-json 키, 셰이더 유니폼 이름)는 ASCII — 런타임이 "
                      "JSON·셰이더 텍스트에서 파싱하는 값이기 때문이다.",
            "consequence": "부재를 주장하려면 **어느 종류의 문자열인지** 먼저 정하고, "
                           "어떤 인코딩으로 어떤 명령을 돌렸는지 함께 적을 것.",
        }, "확정", [ev]),
    ]), os.path.join("spec", "engine", "absence-audit.json"))

    print(f"바이너리 {len(paths)}종 · 부재 주장 {len(CLAIMS)}개 · 양성 대조 {len(POSITIVE_CONTROLS)}개")
    for t in CLAIMS:
        hits = where[t]
        inscope = [n for n in hits if in_scope(n, CLAIMS[t]["absentIn"])]
        mark = "✗" if inscope else ("●" if hits else "○")
        print(f"  {mark} {t:16} " +
              (", ".join(f"{n}(a={v['ascii']},u={v['utf16le']})" for n, v in list(hits.items())[:3])
               if hits else "42종 어디에도 없음") +
              ("" if not hits else f"   [범위 {CLAIMS[t]['absentIn']} 안: {inscope or '없음'}]"))
    print("양성 대조:", ", ".join(f"{t}={'OK' if ok else '**실패**'}" for t, ok in controls_ok.items()))
    print("반증된 주장:", ", ".join(sorted(refuted)) if refuted else "없음")


if __name__ == "__main__":
    main()
