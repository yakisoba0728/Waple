#!/usr/bin/env python3
"""`Sources/WaplePolicy/PlaybackPolicy.swift` 가 재생 정책 정본과 같은 값을 담는지 본다.

## 왜 있나

이 부류는 **옮겨 적기 쉬워서 틀리기 쉽다.** 액션 다섯 개, 축 여섯 개, 문턱 넷 — 전부 한
줄짜리 상수라 "보고 옮기면 되는" 것처럼 보인다. 실제로 이 모델을 처음 쓸 때 축별 허용
열거에서 한 자리가 틀렸다(UI 빌더의 첫 인자가 축마다 `t` 와 리터럴 `!1` 로 갈리는데 전부
`t` 인 줄 알았다). 테스트가 잡아서 다행이었지, 잡을 테스트가 없었으면 사용자에게 없는
선택지를 보여주고 있었을 것이다.

정본(`spec/engine/playback-policy.json`)은 바이너리와 UI 번들에서 **다시 읽어** 만든다
(`scripts/spec/measure_playback_policy.py`). 그런데 정본과 구현이 갈리면 아무도 안 운다 —
정본은 자기 근거만 보고, Swift 는 자기 테스트만 본다. 이 검사가 그 사이를 잇는다.

WE 설치본도 바이너리도 필요 없다. 리포 안의 두 파일(정본 JSON · Swift 소스)만 읽으므로
리눅스 spec 레인에서 매 푸시 돈다 — Swift 컴파일러조차 필요 없다.

## 무엇을 대조하나

  1. 액션 열거의 정수값과 설정 문자열                (playbackPolicy.action.enum)
  2. 축의 설정 키와 기본값                            (playbackPolicy.axes)
  3. `pausevram` 의 기본값                            (playbackPolicy.pauseVRAM.setting)
  4. 축별 허용 열거(단일/다중 모니터)                 (playbackPolicy.allowedActions)
  5. `layout` 정의역                                  (playbackPolicy.monitorLayout)
  6. VRAM 문턱 넷과 게이트 셋                         (playbackPolicy.vram.*)
  7. 우선순위·마스크 규약의 구조 핀                   (playbackPolicy.priority · .pauseMask)

## 무엇을 못 잡나

값 표만 본다. 평가기의 **순서**(축 사이에 낀 플래그 override 둘)는 구조 핀으로 존재만
확인하고 의미는 `Tests/WaplePolicyTests/PlaybackPolicyTests.swift` 가 잡는다. 텍스트
검사로 실행 순서를 판정하려 들면 검사기 쪽이 먼저 틀린다.

## 음성 대조

`--selftest` 는 정본 값을 흔든 사본이 **실제로 실패하는지** 본다. 인자 없이 돌려도 본
검사 전에 먼저 돈다 — 그물이 뚫린 채 초록을 내는 것이 이 리포가 반복해서 당한 사고다.
"""
import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANON = ROOT / "spec" / "engine" / "playback-policy.json"
SWIFT = ROOT / "Sources" / "WaplePolicy" / "PlaybackPolicy.swift"

# 대조 건수 하한. 패턴이 안 맞게 되면 0건 대조로 조용히 통과하는 것이 이 리포의 상습 실패다.
MIN_COMPARED = 60

# Swift 열거 case ↔ 정본의 설정 키. Swift 쪽 이름은 `weConfigKey` 에서 읽으므로
# 여기 적는 것은 **Swift case 이름 목록**뿐이다.
SWIFT_TRIGGERS = ("focus", "maximized", "fullscreen", "audio", "displaySleep", "battery")

# `MonitorLayout` 의 Swift case ↔ 정본 `W.layouts` 의 라벨 꼬리.
# 이름이 다르다: UI 라벨은 "fit"/"clone_wallpaper", Swift 는 의미를 살린 stretch/clone 이다.
LAYOUT_ALIAS = {"perMonitor": "per_monitor", "stretch": "fit", "clone": "clone_wallpaper"}

# VRAM 상수의 Swift 이름 ↔ 정본 키. 이름을 일부러 같게 뒀다.
VRAM_FLOATS = ("enterFraction", "releaseFraction", "immediateReleaseFraction", "sustainSeconds")
VRAM_INTS = {
    "minimumSampleCount": "최소 표본 수",
    "minimumTotalMegabytes": "총량 하한(MB)",
    "maximumTotalMegabytes": "총량 상한(MB)",
}

# 값 표로 못 잡는 계약. 문자열이 사라지면 그 계약이 코드에서 빠진 것이다.
STRUCTURE_PINS = [
    ("if stop || conditions.externalStopRequest || conditions.vramPressure",
     "정지 승격 — 정본 playbackPolicy.priority 의 `test ecx, 0x408`(bit3|bit10)"),
    ("return PlaybackVerdict(stop: true, muted: false, pauseMask: 0)",
     "정지가 pause·mute 를 가린다 — 0x14006d453 의 조기 이탈"),
    ("policy.displaySleep == .pause || policy.displaySleep == .stop",
     "절전 래치는 액션이 pause 나 stop 일 때만 선다 — 0x14006ed9a"),
    ("return PlaybackVerdict(stop: false, muted: false, pauseMask: .max)",
     "절전 래치는 전 모니터 일시정지 — 적용기 0x140073a4f 의 `test bpl, 0x21`"),
    ("1 << (monitorIndex & 31)",
     "마스크 접힘 — 정본 playbackPolicy.pauseMask 의 x86 `bt`/`shl` 규약"),
    ("if multiMonitor && honorsMultiMonitor",
     "pauseall 은 창 상태 세 축만 제시한다 — UI 빌더 첫 인자가 축마다 다르다"),
    ("if conditions.unpauseAero { pauseMask = 0 }",
     "플래그 bit1 override — 0x14006d274"),
    ("if conditions.forcePauseAll { pauseMask = .max }",
     "플래그 bit22 override — 0x14006d281"),
]


# ── Swift 텍스트 파싱 ────────────────────────────────────────────────────────
def balanced_body(text, start):
    """`start` 위치의 `{` 부터 짝이 맞는 `}` 까지를 돌려준다."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    raise ValueError("중괄호 짝이 안 맞는다")


def member_body(text, header_pattern):
    """`header_pattern` 이 매치하는 선언의 본문을 돌려준다. 없으면 None."""
    m = re.search(header_pattern, text)
    if not m:
        return None
    brace = text.index("{", m.end() - 1)
    return balanced_body(text, brace)


CASE_ARM = re.compile(r"case\s+((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*return\s+([^\n]+)")


def case_map(body):
    """`case .a, .b: return X` 를 {case: "X"} 로 편다."""
    out = {}
    for labels, value in CASE_ARM.findall(body):
        value = value.strip().rstrip(",")
        for label in re.findall(r"\.(\w+)", labels):
            out[label] = value
    return out


def parse(text):
    """검사에 필요한 표를 전부 뽑는다. 못 뽑으면 예외를 던진다(조용한 0건 대조 방지)."""
    got = {}

    enum_body = member_body(text, r"public enum PlaybackAction\s*:[^\n{]*")
    if enum_body is None:
        raise ValueError("PlaybackAction 열거를 못 찾았다")
    got["actionValues"] = {n: int(v) for n, v in
                           re.findall(r"case\s+(\w+)\s*=\s*(\d+)", enum_body)}

    body = member_body(text, r"public var weConfigValue\s*:\s*String\s*")
    if body is None:
        raise ValueError("weConfigValue 를 못 찾았다")
    got["actionStrings"] = {k: v.strip('"') for k, v in case_map(body).items()}

    body = member_body(text, r"public var weConfigKey\s*:\s*String\s*")
    if body is None:
        raise ValueError("weConfigKey 를 못 찾았다")
    got["triggerKeys"] = {k: v.strip('"') for k, v in case_map(body).items()}

    body = member_body(text, r"public var weDefault\s*:\s*PlaybackAction\s*")
    if body is None:
        raise ValueError("PlaybackTrigger.weDefault 를 못 찾았다")
    got["triggerDefaults"] = {k: v.lstrip(".") for k, v in case_map(body).items()}

    for prop in ("honorsMultiMonitor", "allowsMute", "allowsStop"):
        body = member_body(text, rf"private var {prop}\s*:\s*Bool\s*")
        if body is None:
            raise ValueError(f"{prop} 를 못 찾았다")
        got[prop] = {k: v == "true" for k, v in case_map(body).items()}

    m = re.search(r"public static let weDefault\s*=\s*PlaybackPolicy\(([^)]*)\)", text, re.S)
    if not m:
        raise ValueError("PlaybackPolicy.weDefault 리터럴을 못 찾았다")
    got["policyDefault"] = {k: v.lstrip(".")
                            for k, v in re.findall(r"(\w+)\s*:\s*(\.?\w+)", m.group(1))}

    layout_body = member_body(text, r"public enum MonitorLayout\s*:[^\n{]*")
    if layout_body is None:
        raise ValueError("MonitorLayout 열거를 못 찾았다")
    got["layouts"] = {n: int(v) for n, v in
                      re.findall(r"case\s+(\w+)\s*=\s*(\d+)", layout_body)}

    vram_body = member_body(text, r"public struct VRAMHysteresis\s*:[^\n{]*")
    if vram_body is None:
        raise ValueError("VRAMHysteresis 를 못 찾았다")
    got["vramFloats"] = {n: float(v) for n, v in re.findall(
        r"public static let (\w+)\s*:\s*Float\s*=\s*([0-9.]+)", vram_body)}
    got["vramInts"] = {n: int(v) for n, v in re.findall(
        r"public static let (\w+)\s*:\s*(?:Int|UInt32)\s*=\s*(\d+)", vram_body)}
    return got


def allowed_from(got, trigger, multi_monitor):
    """Swift 의 세 술어에서 UI 옵션 목록을 재구성한다 — 구현과 같은 조립 순서다.

    술어가 축을 아예 안 덮으면 `.get(..., False)` 로 떨어뜨린다. 그 상태는 위쪽
    `술어 커버리지` 대조가 별도로 잡으므로 여기서 예외를 던질 이유가 없다 —
    검사기가 예외로 죽으면 무엇이 틀렸는지 대신 스택트레이스가 나온다.
    """
    out = ["run"]
    if got["allowsMute"].get(trigger, False):
        out.append("mute")
    out.append("pause")
    if multi_monitor and got["honorsMultiMonitor"].get(trigger, False):
        out.append("pauseall")
    if got["allowsStop"].get(trigger, False):
        out.append("stop")
    return out


# ── 대조 ─────────────────────────────────────────────────────────────────────
def compare(canon, text):
    """(문제 목록, 대조 건수)."""
    bad, n = [], 0
    value = {e["id"]: e["value"] for e in canon["entries"]}
    try:
        got = parse(text)
    except ValueError as exc:
        return [f"Swift 파스 실패: {exc}"], 0

    def eq(label, mine, theirs):
        nonlocal n
        n += 1
        if mine != theirs:
            bad.append(f"{label}: Swift {mine!r} / 정본 {theirs!r}")

    # 1. 액션 열거
    canon_actions = value["playbackPolicy.action.enum"]["값"]
    for name, num in canon_actions.items():
        swift_name = "pauseAll" if name == "pauseall" else name
        eq(f"PlaybackAction.{swift_name} rawValue", got["actionValues"].get(swift_name), num)
        eq(f"PlaybackAction.{swift_name}.weConfigValue",
           got["actionStrings"].get(swift_name), name)
    eq("액션 개수", len(got["actionValues"]), len(canon_actions))

    # 2. 축 키와 기본값
    axes = value["playbackPolicy.axes"]
    for trigger in SWIFT_TRIGGERS:
        key = got["triggerKeys"].get(trigger)
        eq(f"{trigger}.weConfigKey 가 정본에 있는가", key in axes["기본값"], True)
        if key in axes["기본값"]:
            default = axes["기본값"][key]
            swift_default = "pauseAll" if default == "pauseall" else default
            eq(f"{key} 기본값", got["triggerDefaults"].get(trigger), swift_default)
            eq(f"{key} PlaybackPolicy.weDefault", got["policyDefault"].get(trigger), swift_default)

    # 3. pausevram
    eq("pauseVRAM 기본값", got["policyDefault"].get("pauseVRAM"),
       "true" if value["playbackPolicy.pauseVRAM.setting"]["기본값"] else "false")

    # 4. 축별 허용 열거
    #    술어 셋이 여섯 축을 **전부** 덮는지 먼저 본다. Swift 는 열거 switch 를 강제하지만
    #    이 검사기는 텍스트를 읽으므로, 한 팔에서 축이 빠진 형태를 스스로 확인해야 한다.
    for prop in ("honorsMultiMonitor", "allowsMute", "allowsStop"):
        eq(f"{prop} 술어 커버리지", sorted(got[prop]), sorted(SWIFT_TRIGGERS))
    allowed = value["playbackPolicy.allowedActions"]["축별"]
    for trigger in SWIFT_TRIGGERS:
        key = got["triggerKeys"].get(trigger)
        if key not in allowed:
            bad.append(f"{trigger}: 정본 allowedActions 에 {key!r} 가 없다")
            continue
        eq(f"{key} 허용(다중)", allowed_from(got, trigger, True), allowed[key]["multiMonitor"])
        eq(f"{key} 허용(단일)", allowed_from(got, trigger, False), allowed[key]["singleMonitor"])

    # 5. layout 정의역
    layouts = value["playbackPolicy.monitorLayout"]["값"]
    eq("MonitorLayout 개수", len(got["layouts"]), len(layouts))
    for swift_name, canon_name in LAYOUT_ALIAS.items():
        eq(f"MonitorLayout.{swift_name}", got["layouts"].get(swift_name), layouts.get(canon_name))

    # 6. VRAM 문턱과 게이트
    thresholds = value["playbackPolicy.vram.thresholds"]
    for name in VRAM_FLOATS:
        mine, theirs = got["vramFloats"].get(name), thresholds.get(name)
        n += 1
        # 정본은 바이너리의 f32 를 그대로 담아 0.800000011920929 처럼 적힌다.
        # Swift 의 `0.8` 은 같은 f32 이므로 **f32 로 환산해** 비교한다.
        if mine is None or theirs is None or f32(mine) != f32(theirs):
            bad.append(f"VRAMHysteresis.{name}: Swift {mine!r} / 정본 {theirs!r}")
    sampling = value["playbackPolicy.vram.sampling"]
    for name, canon_key in VRAM_INTS.items():
        eq(f"VRAMHysteresis.{name}", got["vramInts"].get(name), sampling.get(canon_key))

    # 7. 구조 핀
    for needle, why in STRUCTURE_PINS:
        n += 1
        if needle not in text:
            bad.append(f"구조 핀이 사라졌다 — {needle!r}\n      이유: {why}")

    return bad, n


def f32(x):
    """float 을 단정도로 접는다. 정본은 f32 원본을, Swift 는 십진 축약을 담는다."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


# ── 음성 대조 ────────────────────────────────────────────────────────────────
# (설명, 원본 조각, 바꿀 조각). 셋 다 실제 소스에 있어야 하고, 바꾸면 반드시 잡혀야 한다.
MUTATIONS = [
    ("액션 정수", "case stop = 4", "case stop = 5"),
    ("액션 문자열", 'case .pauseAll: return "pauseall"', 'case .pauseAll: return "pause_all"'),
    ("설정 키", 'case .displaySleep: return "playbacksleep"',
     'case .displaySleep: return "playbacksleeep"'),
    ("축 기본값", "case .displaySleep: return .stop", "case .displaySleep: return .pause"),
    ("정책 기본값", "displaySleep: .stop,\n        battery: .run,\n        pauseVRAM: false",
     "displaySleep: .pause,\n        battery: .run,\n        pauseVRAM: false"),
    ("허용 열거(mute)", "case .focus, .maximized, .fullscreen, .audio: return true",
     "case .focus, .maximized, .fullscreen: return true"),
    ("허용 열거(pauseall)", "case .focus, .maximized, .fullscreen: return true\n"
                            "        case .audio, .displaySleep, .battery: return false",
     "case .focus, .maximized, .fullscreen, .audio: return true\n"
     "        case .displaySleep, .battery: return false"),
    ("layout 값", "case clone = 2", "case clone = 3"),
    ("VRAM 복귀 문턱", "releaseFraction: Float = 0.75", "releaseFraction: Float = 0.8"),
    ("VRAM 유지 시간", "sustainSeconds: Float = 15.0", "sustainSeconds: Float = 10.0"),
    ("VRAM 총량 하한", "minimumTotalMegabytes: UInt32 = 2049",
     "minimumTotalMegabytes: UInt32 = 1024"),
    ("VRAM 표본수 게이트", "minimumSampleCount: Int = 2", "minimumSampleCount: Int = 1"),
    ("정지 승격 구조 핀", "if stop || conditions.externalStopRequest || conditions.vramPressure",
     "if stop || conditions.externalStopRequest"),
]


def selftest(canon, text):
    bad, n = compare(canon, text)
    if bad:
        print("selftest 실패: 손대지 않은 소스가 이미 정본과 어긋난다", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        raise SystemExit(2)
    if n < MIN_COMPARED:
        print(f"selftest 실패: 대조가 {n}건뿐이다(하한 {MIN_COMPARED}) — 그물이 작아졌다",
              file=sys.stderr)
        raise SystemExit(2)

    for label, before, after in MUTATIONS:
        if text.count(before) != 1:
            print(f"selftest 실패: 변이 지점 '{label}' 이 소스에서 "
                  f"{text.count(before)}번 나온다(1번이어야 한다)\n   {before!r}", file=sys.stderr)
            raise SystemExit(2)
        wrecked, _ = compare(canon, text.replace(before, after))
        if not wrecked:
            print(f"selftest 실패: '{label}' 을 흔들었는데 통과했다 — 그물이 뚫렸다",
                  file=sys.stderr)
            raise SystemExit(2)
    print(f"selftest: OK (대조 {n}건 · 변이 {len(MUTATIONS)}건 전부 차단)")


def main():
    if not CANON.is_file():
        print(f"[playback-policy] 정본이 없다: {CANON.relative_to(ROOT)}\n"
              f"  WE_ROOT=… python3 scripts/spec/measure_playback_policy.py 로 생성하라.",
              file=sys.stderr)
        return 1
    if not SWIFT.is_file():
        print(f"[playback-policy] 구현이 없다: {SWIFT.relative_to(ROOT)}", file=sys.stderr)
        return 1
    canon = json.loads(CANON.read_text(encoding="utf-8"))
    text = SWIFT.read_text(encoding="utf-8")

    selftest(canon, text)
    if "--selftest" in sys.argv:
        return 0

    bad, n = compare(canon, text)
    if bad:
        print(f"[playback-policy] 정본↔구현 불일치 {len(bad)}건 "
              f"(대조 {n}건)\n", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        print("\n  둘 중 하나다:\n"
              "   · WE 가 바뀌었다 → WE_ROOT=… python3 scripts/spec/measure_playback_policy.py\n"
              "   · 구현이 틀렸다  → Sources/WaplePolicy/PlaybackPolicy.swift 를 고쳐라",
              file=sys.stderr)
        return 1
    print(f"[playback-policy] 통과 — 정본 {len(canon['entries'])}항목과 "
          f"{SWIFT.relative_to(ROOT)} 를 {n}건 대조")
    return 0


if __name__ == "__main__":
    sys.exit(main())
