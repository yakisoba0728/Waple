"""신뢰 경계 밖 값의 정수 좁힘이 가드를 건너뛰지 못하게 막는다.

## 무엇을 막는가

Swift 의 `Int(Float)` / `Int32(Int)` 는 범위를 넘으면 **클램프가 아니라 트랩**이다.
`.pkg` 안의 숫자는 파일이 시키는 값이라 얼마든지 크게 올 수 있으므로, 가드 없는 좁힘
한 줄이면 워크샵 배경화면이 프로세스를 죽인다. 폴백도 로그도 없이 앱이 사라진다.

2026-08-19 스윕에서 이 클래스가 **12곳** 나왔다(high 2 + medium 2 + 나머지). 흥미로운 건
가드가 없어서가 아니었다는 점이다 — `safeInt` · `safeFloatToInt` · `sheetFrameIndex` ·
`EffectManifest.safeInt` 네 개가 이미 있었고, `AudioResponse.swift:21`(감사 V05/V06)이나
`ParticleSimulator.valueNoise3` 처럼 **주석까지 달아 가드한 자리도 많았다.** 실패 방식은
"가드가 없다" 가 아니라 **"가드가 넷인데 새 자리가 아무도 안 거친다"** 였다.

그래서 이 스크립트는 "좋은 코드를 가르치는" 린터가 아니라 **증식 감시기**다.

## 네 가지 검사

  R1  `as? Double` / `as? Float` 와 맨 `Int…(` 가 같은 줄        — 오탐 없음, 즉시 오류
  R2  `(… as? Double).map { Int…($0) }`                          — R1 의 우회 형태
  R3  **가드 라우팅 핀** — 스윕이 고친 자리가 되돌아가면 오류
  R4  **인구조사** — 가드 없는 좁힘의 총수가 기준선을 넘으면 오류

R4 가 핵심이다. R1~R3 는 아는 형태만 잡지만 R4 는 **모르는 새 자리**를 잡는다.
새로 하나 늘면 CI 가 막고, 개발자는 둘 중 하나를 해야 한다 —
가드를 태우거나, 기준선을 올리면서 **왜 안전한지 여기에 적거나**.
후자를 귀찮게 만드는 게 목적이다. 침묵이 기본값이면 안 된다.

## 재실행

    python3 scripts/spec/check_int_narrowing.py            # 검사
    python3 scripts/spec/check_int_narrowing.py --census   # 현재 수치만 출력(기준선 갱신용)
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "Sources")

# 좁힘/변환 이니셜라이저. `Int(` 는 확대(UInt32→Int)도 포함하지만 R4 는 총수만 보므로 무방하다.
CONV = re.compile(r"\bU?Int(?:8|16|32|64)?\(")
# 이 라벨/헬퍼를 거치면 트랩하지 않는다. `.rounded()` 는 가드가 아니다(범위를 좁히지 않는다).
GUARDS = ("clamping:", "truncatingIfNeeded:", "exactly:", "bitPattern:",
          "littleEndian:", "bigEndian:", "ascii:", "safeInt(", "safeFloatToInt(",
          "sheetFrameIndex(", "blendModeVal(")
# **[2026-08-20] R1 이 방향에 묶여 있었다** — `as? Double` 이 `Int(` **앞에** 올 때만 잡았다.
# 가장 흔한 형태 `Int(v as? Double ?? 0)` 는 순서가 반대라 R1 을 통과하고 R4(총수)에만 걸렸다.
# 두 방향을 다 본다.
R1 = re.compile(r"as\?\s+(?:Double|Float)\b.*\bU?Int(?:8|16|32|64)?\(|"
                r"\bU?Int(?:8|16|32|64)?\([^)]*\bas\?\s+(?:Double|Float)\b")
R2 = re.compile(r"as\?\s+(?:Double|Float)\)?\s*\.(?:map|flatMap)\s*\{\s*U?Int(?:8|16|32|64)?\(")

# ── R3: 스윕이 고친 자리의 가드가 살아 있는지 ────────────────────────────────
# "이 파일에 이 문자열이 최소 N번" 형태다. 행 번호로 고정하면 리팩터링마다 깨지므로 쓰지 않는다.
PINS = [
    ("Sources/WapleCore/JSONNumerics.swift", "public func safeInt(", 1,
     "모듈 밖 12곳이 이 정본 가드를 부른다 — 다시 internal 로 닫으면 그 자리들이 맨 Int() 로 돌아간다"),
    ("Sources/WapleCore/SceneDocument.swift", "blendModeVal(", 3,
     "colorBlendMode 파스 정규화(레이어·텍스트 두 소비처를 한 자리에서 덮는다)"),
    ("Sources/WapleRender/SceneRendererFrameEncoder.swift", "Int32(clamping:", 2,
     "colorBlendMode 좁힘 — 이미지(:1450)·텍스트(:1629)"),
    ("Sources/WapleRender/SceneRendererFrameEncoder.swift", "safeInt(Double(", 2,
     "particleSheetFrameIndex 의 sequence·frametime 두 경로(매 프레임 실행)"),
    ("Sources/WapleRender/SceneRenderer3D.swift", "safeInt(", 8,
     "3D combos 7곳 + 파티클 frametime 폴터 1곳"),
    ("Sources/WapleRender/SceneRendererResources.swift", "safeInt(", 1, "머티리얼 combos"),
    ("Sources/WapleRender/EffectShaders.swift", "safeInt(", 1, "tint 이펙트 blendmode 상수"),
    ("Sources/WapleCompatCore/DeepScan.swift", "safeInt(", 1,
     "머티리얼 combos(스캐너 사본). 2026-08-19 에 WapleCompat → WapleCompatCore 로 옮겼다 —\n"
     "     실행파일 타깃이라 테스트가 의존할 수 없었던 것을 라이브러리로 분리했다"),
]

# ── R4: 가드 없는 좁힘 총수 기준선 ───────────────────────────────────────────
# [실측 2026-08-19, HEAD e4e0fce + F530-sweep] 아래 수치는 **줄이는 방향으로만** 갱신할 것.
# 올려야 한다면 왜 그 자리가 안전한지(값 도메인이 이미 제한됨)를 커밋 메시지에 남긴다.
#
# [2026-08-20] 342 → 343. 늘어난 한 자리는 `Model3DFormat.materialCount` 의 `Int(skinCount)` 다.
# ① 바로 윗줄이 `guard skinCount <= 256` 이라 값 도메인이 코드에 적혀 있고,
# ② UInt32 → Int 는 64비트에서 **확대 변환**이라 원리적으로 트랩하지 않는다.
# safeInt 를 태우지 않은 이유: 그 함수는 `Any?` 를 받는 JSON 경계용이고 여기는 이미 UInt32 다 —
# 태우면 Optional 을 한 겹 더 벗기는 잡음만 는다.
#
# [2026-08-20] 343 → 344. 늘어난 한 자리는 `GLSLTranslator.formatComboSlots` 의 `Int(digits)` 로,
# 바로 옆 `samplerCombos` 가 같은 자리에서 쓰는 것과 **글자 그대로 같은 변환**이다(그쪽은 이미
# 기준선에 들어 있다). ① `digits` 는 `prefix(while: { $0.isNumber })` 결과라 숫자만이고,
# ② `Int(String)` 은 실패 가능 이니셜라이저라 넘치면 트랩이 아니라 nil 이며 `if let` 으로 받는다.
# 즉 좁힘이 아니라 파싱이다 — 센서스 패턴이 구분하지 못할 뿐이다.
#
# [2026-08-21] 344 → 345. 늘어난 한 자리는 `SimplexNoise.fastFloor` 의 `Int(x)`(Float→Int)다.
# 실물은 `cvttss2si` 라 범위를 넘어도 안 죽지만 Swift 는 트랩하므로, 같은 파일의 `fold(_:)` 가
# **호출 전에** 정의역을 ±10⁶ 로 접는다(NaN/Inf 포함). 그 위에서는 트랩이 불가능하다.
# `safeFloatToInt` 를 태우지 않은 이유: 이 자리는 파티클 루프 안에서 파티클×옥타브만큼 돌아
# Optional 언랩 한 겹이 그대로 비용이고, 가드가 이미 함수 경계에 있어 이중이 된다.
# 나머지 새 좁힘 20건은 전부 `Int(UInt8)`(확대라 트랩 불가)이라 `clamping:` 라벨을 달아 뺐다.
# [2026-08-26] 345 → 347. **두 커밋이 5자리를 늘렸는데 앞 커밋은 여유로 흡수돼 조용히 지나갔다.**
# 실측: `edff0ab` 342 → S2a(전역 재생정책면) 345 → S2b(관측자) 348. 기준선이 345 라
# S2a 는 `census > BASELINE` 을 아슬아슬하게 통과했고 — 여유가 정확히 0 이 됐다 — S2b 가
# 넘겼다. 이 블록은 **다섯 자리 전부**를 적는다(앞 셋이 문서 없이 들어간 것을 여기서 갚는다).
#
# S2a — `PlaybackPolicyRuntime.PlaybackMasks` 의 비트 시프트 3자리(`1 << UInt32(i)` ×2 ·
# `1 << UInt32(n)`). 셋 다 **같은 줄에 상한 가드가 있다**: 앞 둘은 `i < 32` 로 걸러진 뒤에만
# 시프트하고, 셋째는 `n = max(0, min(count, 32))` 로 접힌 값이다. 마스크가 `UInt32` 라 32 가
# 상한인 것이 타입에서 오고, 33번째 화면을 무시한다는 계약은 `PlaybackObserversTests` 의
# `testScreensBeyondBitWidthDoNotOverflow` 가 지킨다. `clamping:` 을 달지 않은 이유는
# 그 라벨이 **값을 자르는** 의미인데 여기서는 자르는 게 아니라 **넣지 않는** 것이기 때문이다.
#
# S2b — `PlaybackObservers.defaultOutputDeviceIsRunning()` 의 `UInt32(MemoryLayout<…>.size)`
# 2자리. CoreAudio 의 `ioDataSize` 가 `UInt32` 라서 필요한 변환이고, 인자는 **컴파일 타임
# 상수 4**다(`AudioDeviceID` = `UInt32`). 런타임 입력이 아니므로 좁힘이라기보다 상수 표기다.
# 같은 커밋에서 `UInt32(0)`·`AudioDeviceID(0)` 두 자리는 타입 표기(`var x: UInt32 = 0`)로
# 바꿔 아예 없앴다 — 게이트를 피하려는 것이 아니라 그쪽이 실제로 더 나은 스위프트다.
CENSUS_BASELINE = 347


def swift_files():
    for root, _dirs, files in os.walk(SRC):
        for f in sorted(files):
            if f.endswith(".swift"):
                yield os.path.join(root, f)


def strip_trailing_comment(line):
    """줄 끝 `//` 주석을 잘라낸다. 문자열 리터럴 안의 `//`(예: URL)는 건드리지 않는다.

    **[2026-08-20] 이게 없어서 가드 판정이 주석으로 뚫렸다.** `GUARDS` 를 **줄 전체**에서
    찾으므로, 같은 줄 주석에 가드 이름이 들어 있기만 하면 R1 과 인구조사에서 그 줄이 통째로
    빠졌다:

        let n = Int(obj["x"] as? Double ?? 0)  // clamping: 을 쓸 수 없는 자리다
        → `[int-narrowing] 통과 — 가드 없는 좁힘 343건` (그 줄은 세지도 않는다)

    같은 원인으로 한 줄에 가드된 좁힘과 가드 없는 좁힘이 섞이면 줄 전체가 면제됐다.
    """
    out, i, in_str, n = [], 0, False, len(line)
    while i < n:
        c = line[i]
        if in_str:
            if c == "\\":
                out.append(line[i:i + 2]); i += 2; continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(c); i += 1
    return "".join(out)


def code_lines(path):
    """주석·문자열 리터럴만인 줄은 뺀다(완전한 파싱은 아니다 — 총수 안정성이 목적).

    줄 끝 주석도 잘라낸다 — 가드 판정이 주석으로 뚫리던 자리다(`strip_trailing_comment`).
    """
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            code = strip_trailing_comment(line)
            if code.strip():
                yield i, code


def main():
    census, errors = 0, []
    for path in swift_files():
        rel = os.path.relpath(path, REPO)
        for lineno, line in code_lines(path):
            if not CONV.search(line):
                continue
            if R1.search(line) and not any(g in line for g in GUARDS):
                errors.append(f"{rel}:{lineno}  [R1] JSON Double/Float 을 가드 없이 정수로 좁힌다\n"
                              f"    {line.strip()}\n"
                              f"    → safeInt(_:) 를 경유할 것(WapleCore/JSONNumerics.swift)")
            if R2.search(line):
                errors.append(f"{rel}:{lineno}  [R2] map/flatMap 안에서 가드 없이 좁힌다\n"
                              f"    {line.strip()}\n"
                              f"    → .flatMap {{ safeInt($0) }} 로 바꿀 것")
            if not any(g in line for g in GUARDS):
                census += len(CONV.findall(line))

    for rel, needle, least, why in PINS:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            errors.append(f"{rel}  [R3] 핀이 가리키는 파일이 없다 — 옮겼으면 PINS 를 갱신할 것")
            continue
        got = open(path, encoding="utf-8").read().count(needle)
        if got < least:
            errors.append(f"{rel}  [R3] `{needle}` 가 {least}개여야 하는데 {got}개다 — 가드가 풀렸다\n"
                          f"    이유: {why}")

    if "--census" in sys.argv:
        print(f"가드 없는 정수 좁힘 총수: {census}  (기준선 {CENSUS_BASELINE})")
        return

    if census > CENSUS_BASELINE:
        errors.append(
            f"[R4] 가드 없는 정수 좁힘이 {CENSUS_BASELINE} → {census} 로 늘었다(+{census - CENSUS_BASELINE}).\n"
            f"    새로 추가한 좁힘이 신뢰 경계 밖 값을 받는다면 safeInt(_:) 를 태울 것.\n"
            f"    값 도메인이 이미 제한돼 안전하다면(AudioResponse.swift:21 · ParticleSimulator.valueNoise3\n"
            f"    처럼 **가드를 코드에 적어 두고**) CENSUS_BASELINE 을 올리면서 이유를 커밋에 남길 것.")

    if errors:
        print("[int-narrowing] 정수 좁힘 가드 검사 실패\n")
        for e in errors:
            print("  " + e.replace("\n", "\n  ") + "\n")
        raise SystemExit(1)

    print(f"[int-narrowing] 통과 — 가드 없는 좁힘 {census}건(기준선 {CENSUS_BASELINE}), "
          f"라우팅 핀 {len(PINS)}개 유지")


if __name__ == "__main__":
    main()
