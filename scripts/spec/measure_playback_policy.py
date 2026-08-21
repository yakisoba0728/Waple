#!/usr/bin/env python3
"""WE 2.8.42 의 재생 정책(playbackfocus/…/pausevram)을 wallpaper64.exe 와 UI 번들에서 뽑는다.

## 왜 바이트에서 뽑는가

이 영역의 사실은 **문서로 옮겨 적기 쉬운 부류**다 — 액션 다섯 개, 축 일곱 개, 문턱 넷.
그래서 틀리기도 쉽다. 실제로 이 작업의 선행 정찰 보고에도 두 군데가 어긋나 있었다
(전역 저장 순서, `pauseall` 을 제시하는 축의 범위). 옮겨 적는 대신 **바이트에서 다시 읽고**
읽은 자리의 바이트를 함께 대조한다. 바이너리가 바뀌면 조용히 틀린 수를 내지 않고 죽는다.

## 무엇을 어디서 재는가

  · 액션 열거      매퍼 0x140141880–0x14014191b 의 비교 리터럴과 반환 상수를 직접 디코드
  · 축 키 문자열   0x140476df0 계열의 C 문자열
  · 기본값         설치자 0x140046f20–0x1400483be 에서 각 키 창 안의 액션 문자열 참조
  · 전역 슬롯      로더 0x14006c280–0x14006ce9b 의 `call 매퍼` → `mov [rip+d], eax`
  · 우선순위       판정 적용부 0x14006d407 의 `test ecx, imm32`
  · 마스크 규약    0x140074d40 · 0x140073a5a 의 `movzx ecx, byte ptr [rax+0x51]`
  · VRAM 문턱      0x1404926e4 · 0x1404926d4 · 0x1404926a0 · 0x140492888 의 f32
  · VRAM 게이트    0x14006d31a(표본수) · 0x14006d32d·0x14006d334(총량 범위)
  · VRAM 표본      PDH 카운터 경로 0x14048b180(UTF-16) + 폴 간격 0x1401414c7
  · 축별 허용 열거 ui/dist/scripts/scripts.js 의 옵션 빌더 `function k(e,t,a)` 와 그 호출 여섯 줄
  · layout 정의역  같은 번들의 `W.layouts=[…]`

## 재실행

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_playback_policy.py
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.path.join(WE, "wallpaper64.exe")
UI_JS = os.path.join(WE, "ui", "dist", "scripts", "scripts.js")
OUT = os.path.join("spec", "engine", "playback-policy.json")

# ── 고정 주소 ────────────────────────────────────────────────────────────────
MAPPER = (0x140141880, 0x14014191B)
DEFAULT_INSTALLER = (0x140046F20, 0x1400483BE)
CONFIG_LOADER = (0x14006C280, 0x14006CE9B)

AXIS_KEY_VA = {
    "playbackfocus": 0x140476DF0,
    "playbackmaximized": 0x140476E00,
    "playbackfullscreen": 0x140476E18,
    "playbackonbattery": 0x140476E30,
    "playbacksleep": 0x140476E48,
    "playbackaudio": 0x140476E58,
}
PAUSEVRAM_KEY_VA = 0x140477038

# 매퍼 디코드 지점. (VA, 기대 바이트, 설명) — 바이트가 다르면 즉시 죽는다.
#
# 매퍼는 길이로 먼저 가른다. 길이 4 가 두 번 나오는데(=stop 과 mute) 그 둘의 반환 방식이
# 서로 다르다: stop 은 `mov eax, r8d`(r8 = 길이 4)라 **상수가 코드에 안 보이고**,
# mute 는 `mov eax,0 / sete al` 이라 1 이 상수로도 안 보인다. 여기를 눈으로 옮겨 적으면
# 그 둘을 놓친다 — 그래서 반환 경로까지 바이트로 못박는다.
# 필드: (이름, 길이비교 VA, 길이비교 접두, 그 길이, 리터럴비교 VA, 리터럴비교 접두,
#        리터럴 바이트 수, 반환 VA, 반환 접두)
# "pause" 만 길이(5)와 리터럴 바이트 수(4)가 다르다 — 5번째 글자를 따로 비교한다.
MAPPER_SITES = [
    ("stop", 0x140141894, "4983f8", 4, 0x14014189A, "8138", 4, 0x1401418A2, "418bc0"),
    ("pauseall", 0x1401418B2, "4983f8", 8, 0x1401418B8, "48ba", 8, 0x1401418C7, "b803000000"),
    ("pause", 0x1401418D9, "4983f8", 5, 0x1401418E1, "81ea", 4, 0x1401418F4, "b802000000"),
    ("mute", 0x140141903, "4983f8", 4, 0x140141909, "8139", 4, 0x14014190F, "b8000000000f94c0"),
]
MAPPER_FALLTHROUGH = (0x140141918, "33c0c3")

# `pausevram` 은 열거가 아니라 불이다. 설치자가 태그 5(booleanValue)로 확인하고
# `xor r15d,r15d` 로 0 이 된 r15b 를 그대로 심는다 = false.
PAUSEVRAM_TAGCHECK = (0x140047D52, "80780805")
PAUSEVRAM_STORE = (0x140047D71, "44887db7")

# 판정 적용부. `test ecx, imm32` 의 imm 이 곧 "정지로 승격되는 비트 집합" 이다.
STOP_MASK_SITE = (0x14006D407, "f7c1")
# 절전 래치를 보는 자리: `shr eax,5` → `test r14b, al` → jne.
SLEEP_LATCH_SITE = (0x14006D45B, "8bc1c1e805")
# 모니터 인덱스 필드. 만드는 쪽과 읽는 쪽이 같은 오프셋을 써야 마스크가 성립한다.
MASK_BUILD_SITE = (0x140074D40, "0fb648")
MASK_READ_SITE = (0x140073A5A, "0fb648")

VRAM_FLOAT_VA = {
    "enterFraction": 0x1404926E4,
    "releaseFraction": 0x1404926D4,
    "immediateReleaseFraction": 0x1404926A0,
    "sustainSeconds": 0x140492888,
}
VRAM_SAMPLE_GATE = (0x14006D31A, "4883f8")          # cmp rax, imm8
VRAM_TOTAL_LOW = (0x14006D32D, "418d80")            # lea eax, [r8 + disp32]
VRAM_TOTAL_SPAN = (0x14006D334, "3d")               # cmp eax, imm32
VRAM_COUNTER_PATH_VA = 0x14048B180
VRAM_POLL_SITE = (0x1401414C7, "ba")                # mov edx, imm32 (PdhCollectQueryDataEx 초)

# UI 옵션 빌더의 호출 여섯 줄. JS 이름 → 설정 키.
UI_AXIS = {
    "Focus": "playbackfocus",
    "Maximized": "playbackmaximized",
    "Fullscreen": "playbackfullscreen",
    "Audio": "playbackaudio",
    "Sleep": "playbacksleep",
    "Battery": "playbackonbattery",
}


# ── PE ───────────────────────────────────────────────────────────────────────
def section_map(data):
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    pe32plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    base = (struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus
            else struct.unpack_from("<I", data, opt + 28)[0])
    secs = []
    for i in range(nsec):
        b = opt + opt_size + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append((name, rawptr, rawptr + rawsize, base + vaddr, max(vsize, rawsize)))
    return secs


def off_of(va, secs):
    for _name, start, end, base, span in secs:
        if base <= va < base + span:
            delta = va - base
            if delta < end - start:
                return start + delta
    return None


def need(data, secs, va, prefix_hex, what):
    """VA 의 바이트가 기대 접두와 같은지 확인하고 그 오프셋을 돌려준다."""
    off = off_of(va, secs)
    if off is None:
        raise SystemExit(f"{what}: VA {va:#x} 가 파일 안에 없다")
    want = bytes.fromhex(prefix_hex)
    got = data[off:off + len(want)]
    if got != want:
        raise SystemExit(
            f"{what}: {va:#x} 의 바이트가 기대와 다르다 — 바이너리가 바뀌었다.\n"
            f"  기대 {want.hex()} / 실제 {got.hex()}\n"
            f"  재확인 없이 수치를 쓰지 마라.")
    return off


def cstring(data, secs, va, limit=64):
    off = off_of(va, secs)
    if off is None:
        return None
    raw = data[off:off + limit].split(b"\0")[0]
    try:
        return raw.decode("ascii")
    except UnicodeDecodeError:
        return None


def utf16_string(data, secs, va, limit=256):
    off = off_of(va, secs)
    if off is None:
        return None
    raw = data[off:off + limit]
    end = raw.find(b"\0\0")
    if end % 2:
        end += 1
    return raw[:end].decode("utf-16-le", "replace")


def va_of(off, secs):
    for _name, start, end, base, _span in secs:
        if start <= off < end:
            return base + (off - start)
    return None


# ── 액션 열거 ────────────────────────────────────────────────────────────────
def decode_mapper(data, secs):
    """매퍼 0x140141880–0x14014191b 를 디코드해 문자열 → 정수 표를 만든다."""
    values = {}
    for (name, len_va, len_pfx, gate_len, cmp_va, cmp_pfx, lit_len,
         ret_va, ret_pfx) in MAPPER_SITES:
        len_off = need(data, secs, len_va, len_pfx, f"매퍼 {name} 길이 비교")
        got_len = data[len_off + len(bytes.fromhex(len_pfx))]
        if got_len != gate_len:
            raise SystemExit(f"매퍼 {name}: 길이 비교가 {got_len} 인데 {gate_len} 이어야 한다")
        if got_len != len(name):
            raise SystemExit(f"매퍼 {name}: 길이 게이트 {got_len} 가 이름 길이와 다르다")
        cmp_off = need(data, secs, cmp_va, cmp_pfx, f"매퍼 {name} 리터럴 비교")
        lit_start = cmp_off + len(bytes.fromhex(cmp_pfx))
        literal = data[lit_start:lit_start + lit_len]
        ret_off = need(data, secs, ret_va, ret_pfx, f"매퍼 {name} 반환")
        if name == "stop":
            # `mov eax, r8d` — r8 은 방금 비교한 길이 그 자체다. 상수가 코드에 안 보인다.
            value = gate_len
        elif name == "mute":
            # `mov eax,0 / sete al` — 같으면 1.
            value = 1
        else:
            value = struct.unpack_from("<I", data, ret_off + 1)[0]
        text = literal.decode("ascii", "replace")
        if name == "pause":
            # 5글자는 앞 4바이트(`sub edx, "paus"`) + 뒤 1바이트(`sub edx, 'e'`)로 갈려 있다.
            tail_off = need(data, secs, 0x1401418E9, "0fb65004" "83ea",
                            "매퍼 pause 꼬리 글자")
            text += chr(data[tail_off + 6])
        if text != name:
            raise SystemExit(f"매퍼: 리터럴이 {text!r} 인데 {name!r} 이어야 한다")
        values[name] = value
    need(data, secs, *MAPPER_FALLTHROUGH, "매퍼 미인식 폴백")
    values["run"] = 0
    return values


# ── 기본값 · 전역 슬롯 ───────────────────────────────────────────────────────
LEA_RDX = re.compile(rb"\x48\x8d\x15(.{4})", re.S)
LEA_RCX = re.compile(rb"\x48\x8d\x0d(.{4})", re.S)
MOV_EAX_RIP = re.compile(rb"\x8b\x05(.{4})", re.S)
MOV_RIP_EAX = re.compile(rb"\x89\x05(.{4})", re.S)
CALL_REL = re.compile(rb"\xe8(.{4})", re.S)


def _windows(data, secs, fn, keys):
    """함수 안의 `lea rdx, [rip+d]` 위치를 훑어 키마다 [시작, 다음 lea) 창을 만든다."""
    lo, hi = fn
    lo_off, hi_off = off_of(lo, secs), off_of(hi, secs)
    body = data[lo_off:hi_off]
    marks = []
    for m in LEA_RDX.finditer(body):
        disp = struct.unpack("<i", m.group(1))[0]
        target = va_of(lo_off + m.end(), secs) + disp
        marks.append((m.start(), target))
    out = {}
    for i, (pos, target) in enumerate(marks):
        name = cstring(data, secs, target)
        if name in keys:
            end = marks[i + 1][0] if i + 1 < len(marks) else len(body)
            out[name] = (lo_off + pos, lo_off + end)
    missing = [k for k in keys if k not in out]
    if missing:
        raise SystemExit(f"{fn[0]:#x}: 키 참조를 못 찾았다 — {missing}")
    return out


def measure_defaults(data, secs, actions):
    """설치자 창 안에서 액션 문자열을 가리키는 참조를 찾아 기본값으로 삼는다."""
    windows = _windows(data, secs, DEFAULT_INSTALLER, set(AXIS_KEY_VA))
    out = {}
    for key, (start, end) in sorted(windows.items()):
        body = data[start:end]
        hits = set()
        for rx in (LEA_RCX, MOV_EAX_RIP):
            for m in rx.finditer(body):
                disp = struct.unpack("<i", m.group(1))[0]
                target = va_of(start + m.end(), secs) + disp
                text = cstring(data, secs, target)
                if text in actions:
                    hits.add(text)
        if len(hits) != 1:
            raise SystemExit(f"{key}: 기본값 후보가 {sorted(hits)} — 정확히 하나여야 한다")
        out[key] = hits.pop()
    return out


def measure_globals(data, secs):
    """로더 창 안에서 `call 매퍼` 직후의 `mov [rip+d], eax` 를 찾아 전역 슬롯을 얻는다."""
    windows = _windows(data, secs, CONFIG_LOADER, set(AXIS_KEY_VA))
    out = {}
    for key, (start, end) in sorted(windows.items()):
        body = data[start:end]
        call_end = None
        for m in CALL_REL.finditer(body):
            rel = struct.unpack("<i", m.group(1))[0]
            if va_of(start + m.end(), secs) + rel == MAPPER[0]:
                call_end = m.end()
                break
        if call_end is None:
            raise SystemExit(f"{key}: 로더에서 매퍼 호출을 못 찾았다")
        m = MOV_RIP_EAX.search(body, call_end)
        if m is None:
            raise SystemExit(f"{key}: 매퍼 호출 뒤에 전역 저장이 없다")
        disp = struct.unpack("<i", m.group(1))[0]
        out[key] = hex(va_of(start + m.end(), secs) + disp)
    return out


# ── UI 옵션 빌더 ─────────────────────────────────────────────────────────────
BUILDER = re.compile(
    r"function k\(e,t,a\)\{var i=\[\{label:\"ui_settings_playback_keep_running\",value:\"run\"\}\];"
    r"return t&&i\.push\(\{label:\"ui_settings_playback_mute\",value:\"mute\"\}\),"
    r"e\?\(i\.push\(\{label:\"ui_settings_playback_pause_per_monitor\",value:\"pause\"\}\),"
    r"i\.push\(\{label:\"ui_settings_playback_pause_all\",value:\"pauseall\"\}\)\):"
    r"i\.push\(\{label:\"ui_settings_playback_pause\",value:\"pause\"\}\),"
    r"a&&i\.push\(\{label:\"ui_settings_playback_stop\",value:\"stop\"\}\),i\}")
CALL_SITE = re.compile(r"playbackOptions(Focus|Maximized|Fullscreen|Audio|Sleep|Battery)"
                       r"=k\((t|!0|!1),(!0|!1),(!0|!1)\)")
LAYOUTS = re.compile(r"W\.layouts=\[(.*?)\]", re.S)
LAYOUT_ITEM = re.compile(r"\{label:\"(ui_browse_monitors_layout_[a-z_]+)\",value:(\d+)\}")


def measure_ui(js):
    """빌더 본문을 글자 그대로 대조한 뒤 호출 여섯 줄의 인자를 읽는다."""
    if not BUILDER.search(js):
        raise SystemExit(
            "UI 옵션 빌더 `function k(e,t,a)` 가 기대한 형태가 아니다 — WE UI 가 바뀌었다.\n"
            "  이 정본의 축별 허용 열거는 그 함수 본문이 근거다. 손으로 고치지 말고 다시 읽어라.")
    calls = {m.group(1): (m.group(2), m.group(3), m.group(4))
             for m in CALL_SITE.finditer(js)}
    missing = [k for k in UI_AXIS if k not in calls]
    if missing:
        raise SystemExit(f"UI 호출 지점을 못 찾았다 — {missing}")

    allowed = {}
    for js_name, key in sorted(UI_AXIS.items(), key=lambda kv: kv[1]):
        multi_arg, mute_arg, stop_arg = calls[js_name]
        options = ["run"]
        if mute_arg == "!0":
            options.append("mute")
        options.append("pause")
        if multi_arg == "t":                       # runtime.multimonitor 를 그대로 받는 축
            options.append("pauseall")
        elif multi_arg != "!1":
            raise SystemExit(f"{js_name}: 빌더 첫 인자가 {multi_arg!r} 라 해석할 수 없다")
        if stop_arg == "!0":
            options.append("stop")
        allowed[key] = {
            "multiMonitor": options,
            "singleMonitor": [o for o in options if o != "pauseall"],
            "builderArgs": f"k({multi_arg},{mute_arg},{stop_arg})",
        }

    m = LAYOUTS.search(js)
    if not m:
        raise SystemExit("UI 번들에서 `W.layouts=[…]` 를 못 찾았다")
    layouts = {label.replace("ui_browse_monitors_layout_", ""): int(value)
               for label, value in LAYOUT_ITEM.findall(m.group(1))}
    if not layouts:
        raise SystemExit("`W.layouts` 를 해석하지 못했다")
    return allowed, layouts


# ── 본체 ─────────────────────────────────────────────────────────────────────
def main():
    if not os.path.isfile(BIN):
        raise SystemExit(f"wallpaper64.exe 가 없다: {BIN}\n  WE_ROOT 를 설정하라.")
    if not os.path.isfile(UI_JS):
        raise SystemExit(f"UI 번들이 없다: {UI_JS}\n  WE_ROOT 를 설정하라.")
    with open(BIN, "rb") as fh:
        data = fh.read()
    secs = section_map(data)
    js = open(UI_JS, encoding="utf-8", errors="replace").read()

    actions = decode_mapper(data, secs)
    keys = {name: hex(va) for name, va in sorted(AXIS_KEY_VA.items())}
    for name, va in AXIS_KEY_VA.items():
        got = cstring(data, secs, va)
        if got != name:
            raise SystemExit(f"{va:#x} 의 문자열이 {got!r} 인데 {name!r} 이어야 한다")
    if cstring(data, secs, PAUSEVRAM_KEY_VA) != "pausevram":
        raise SystemExit(f"{PAUSEVRAM_KEY_VA:#x} 가 'pausevram' 이 아니다")

    defaults = measure_defaults(data, secs, set(actions))
    globals_ = measure_globals(data, secs)
    need(data, secs, *PAUSEVRAM_TAGCHECK, "pausevram 태그 검사")
    need(data, secs, *PAUSEVRAM_STORE, "pausevram 기본값 저장")

    stop_off = need(data, secs, *STOP_MASK_SITE, "정지 승격 비트 마스크")
    stop_mask = struct.unpack_from("<I", data, stop_off + 2)[0]
    need(data, secs, *SLEEP_LATCH_SITE, "절전 래치 비트")
    build_off = need(data, secs, *MASK_BUILD_SITE, "마스크 생성부 모니터 인덱스 필드")
    read_off = need(data, secs, *MASK_READ_SITE, "마스크 소비부 모니터 인덱스 필드")
    build_field, read_field = data[build_off + 3], data[read_off + 3]
    if build_field != read_field:
        raise SystemExit(f"모니터 인덱스 필드가 갈린다 — 생성 +{build_field:#x} / "
                         f"소비 +{read_field:#x}")

    floats = {}
    for name, va in VRAM_FLOAT_VA.items():
        off = off_of(va, secs)
        if off is None:
            raise SystemExit(f"VRAM 상수 {name}: VA {va:#x} 가 파일 안에 없다")
        floats[name] = struct.unpack_from("<f", data, off)[0]

    gate_off = need(data, secs, *VRAM_SAMPLE_GATE, "VRAM 표본수 게이트")
    min_samples = data[gate_off + 3]
    low_off = need(data, secs, *VRAM_TOTAL_LOW, "VRAM 총량 하한")
    total_low = -struct.unpack_from("<i", data, low_off + 3)[0]
    span_off = need(data, secs, *VRAM_TOTAL_SPAN, "VRAM 총량 범위 폭")
    total_span = struct.unpack_from("<I", data, span_off + 1)[0]
    poll_off = need(data, secs, *VRAM_POLL_SITE, "VRAM 폴 간격")
    poll_seconds = struct.unpack_from("<I", data, poll_off + 1)[0]
    counter_path = utf16_string(data, secs, VRAM_COUNTER_PATH_VA)

    allowed, layouts = measure_ui(js)

    binary_ev = specfmt.ev("binary", f"wallpaper64.exe {MAPPER[0]:#x}–{MAPPER[1]:#x}",
                           "매퍼 본문 디코드. 비교 리터럴·길이 게이트·반환 상수를 "
                           "바이트 대조로 자기검증한다")
    installer_ev = specfmt.ev(
        "binary",
        f"wallpaper64.exe {DEFAULT_INSTALLER[0]:#x}–{DEFAULT_INSTALLER[1]:#x}",
        "기본값 설치자. 키마다 [해당 `lea rdx` , 다음 `lea rdx`) 창 안에서 "
        "액션 문자열을 가리키는 참조가 정확히 하나인지 확인한다")
    loader_ev = specfmt.ev(
        "binary", f"wallpaper64.exe {CONFIG_LOADER[0]:#x}–{CONFIG_LOADER[1]:#x}",
        "설정 로더. `call 매퍼` 직후의 `mov [rip+d], eax` 로 전역 슬롯을 얻는다")
    eval_ev = specfmt.ev("binary", "wallpaper64.exe 0x14006cea0–0x14006e0bc",
                         "평가기. 축 디스패치 0x14006d0e0–0x14006d2b4 · "
                         "VRAM 0x14006d2e5–0x14006d403 · 판정 적용 0x14006d403–0x14006d4a6")
    ui_ev = specfmt.ev("file", "wallpaper_engine/ui/dist/scripts/scripts.js",
                       "옵션 빌더 `function k(e,t,a)` 본문을 글자 그대로 대조한 뒤 "
                       "호출 여섯 줄의 인자를 읽는다")
    script_ev = specfmt.ev("script", "scripts/spec/measure_playback_policy.py")
    swift_ev = specfmt.ev("file", "Sources/WaplePolicy/PlaybackPolicy.swift",
                          "이 정본을 그대로 옮긴 순수 모델. "
                          "scripts/spec/check_playback_policy.py 가 둘을 대조한다")

    entries = [
        specfmt.entry("playbackPolicy.action.enum", {
            "매퍼": f"{MAPPER[0]:#x}–{MAPPER[1]:#x}",
            "값": dict(sorted(actions.items(), key=lambda kv: kv[1])),
            "미인식": "run",
            "미인식 근거": f"{MAPPER_FALLTHROUGH[0]:#x} 의 `xor eax, eax; ret` — "
                           "던지지도 실패하지도 않고 0 을 돌려준다",
            "표기": "설정 파일에는 **문자열**로 저장된다. 정수는 로더가 접은 결과이고 "
                    "전역/디스패치에서만 보인다",
        }, "확정", [binary_ev, script_ev]),

        specfmt.entry("playbackPolicy.axes", {
            "키 문자열 VA": keys,
            "기본값": dict(sorted(defaults.items())),
            "전역 슬롯": globals_,
            "저장 순서 주의": "전역은 focus·maximized·fullscreen 다음에 **sleep → onbattery** "
                              "순이다. 문자열 VA 순서(onbattery 가 sleep 보다 앞)와 다르므로 "
                              "주소로 축을 유추하면 틀린다",
        }, "확정", [installer_ev, loader_ev, script_ev]),

        specfmt.entry("playbackPolicy.pauseVRAM.setting", {
            "키": "pausevram",
            "키 VA": hex(PAUSEVRAM_KEY_VA),
            "형": "bool",
            "jsoncpp 태그": 5,
            "기본값": False,
            "근거": f"{PAUSEVRAM_TAGCHECK[0]:#x} 의 `cmp byte ptr [rax+8], 5`(booleanValue) 와 "
                    f"{PAUSEVRAM_STORE[0]:#x} 의 `mov byte ptr [rbp-0x49], r15b` — "
                    "r15 는 0x140046f53 의 `xor r15d, r15d` 로 0 이다",
        }, "확정", [installer_ev, script_ev]),

        specfmt.entry("playbackPolicy.allowedActions", {
            "축별": allowed,
            "빌더": "function k(e,t,a) — e=multimonitor, t=mute 허용, a=stop 허용",
            "엔진과의 대응": "목록에 없는 액션은 엔진 디스패치에 분기가 없어 무동작(=run)이 된다. "
                             "단 pauseall 은 UI 가 단일 모니터에서 숨길 뿐 엔진은 처리한다 — "
                             "모니터가 하나면 pause 와 관측상 같다",
            "빌더 첫 인자 주의": "audio·sleep·battery 는 리터럴 `!1` 이라 모니터 수와 무관하게 "
                                 "pauseall 을 제시하지 않는다. 셋 다 엔진에도 액션 3 분기가 없다",
        }, "확정", [ui_ev, eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.dispatch", {
            "fullscreen": {"범위": "0x14006d111–0x14006d176", "처리": ["mute", "pause", "pauseall", "stop"]},
            "maximized": {"범위": "0x14006d176–0x14006d1e4", "처리": ["mute", "pause", "pauseall", "stop"]},
            "focus": {"범위": "0x14006d1e4–0x14006d21f", "처리": ["mute", "pause", "pauseall"]},
            "audio": {"범위": "0x14006d21f–0x14006d26c", "처리": ["mute", "pause"]},
            "onbattery": {"범위": "0x14006d28c–0x14006d2b4", "처리": ["pause", "stop"]},
            "sleep": {"범위": "0x14006ed90–0x14006edc8", "처리": ["pause", "stop"],
                      "note": "평가기 안이 아니라 전원 이벤트 핸들러다. 액션이 pause 나 stop 일 "
                              "때만 플래그 bit5 를 세우고, 그 밖에는 `ret` 으로 빠진다"},
            "run": "어느 축에도 분기가 없다 — 아무것도 하지 않는 것이 run 이다",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.priority", {
            "순서": ["stop", "displaySleep", "pauseMask · mute"],
            "정지 승격 비트": hex(stop_mask),
            "정지 승격 근거": f"{STOP_MASK_SITE[0]:#x} 의 `test ecx, {stop_mask:#x}` + "
                              "0x14006d423 `cmovne ebx, 1` — bit3(외부 정지 요청)와 "
                              "bit10(VRAM 압박)이 축 판정과 무관하게 정지를 세운다",
            "조기 이탈": f"0x14006d453 `test bl, bl / jne`(정지면 pause·mute 갱신 안 함) 와 "
                         f"{SLEEP_LATCH_SITE[0]:#x} `shr eax, 5 / test / jne`(절전 래치도 같음)",
            "절전의 결과": "적용기 0x140073a4f 의 `test bpl, 0x21`(bit0|bit5)가 인스턴스마다 "
                           "참을 먹이므로 절전 래치는 곧 **전 모니터 일시정지**다",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.pauseMask", {
            "폭": 32,
            "비트": "1 << monitorIndex",
            "전체": "0xffffffff",
            "모니터 인덱스 필드": hex(build_field),
            "생성": f"{MASK_BUILD_SITE[0]:#x} `movzx ecx, byte ptr [rax+{build_field:#x}]` → "
                    "`shl r8d, cl` → `or r9d, r8d` (전역 0x1404e52ec 에 전 모니터 비트합)",
            "소비": f"{MASK_READ_SITE[0]:#x} `movzx ecx, byte ptr [rax+{read_field:#x}]` → "
                    "`bt eax, ecx` (전역 0x1404e52e8 의 래치를 인스턴스마다 조회)",
            "접힘": "x86 의 `shl`/`bt` 가 오프셋을 32로 접으므로 인덱스 32 는 0 과 같은 비트다",
            "음소거는 마스크가 아니다": "0x140073a7b 의 `test bpl, 0xc0` — 음소거는 전역 비트 "
                                        "둘(bit6 외부 요청 · bit7 축 판정)이고 모니터별이 아니다",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.monitorLayout", {
            "설정 키": "general/wallpaperconfig/layout",
            "전역": "0x1404e52e0",
            "값": layouts,
            "사용처": "0x14006d103 `test r9d, r9d`(최대화 마스크가 전체화면 마스크를 흡수) · "
                      "0x14006d150·0x14006d1b3 의 `sub/cmp` 사다리(pause 가 전부 가려졌을 때만) · "
                      "0x14006d208(focus 의 pause 는 마스크가 비지 않기만 하면 전체)",
            "정의역 주의": "엔진이 쓰는 두 술어(`!= 0` 과 `∈ {1,2}`)는 정의역 {0,1,2} 에서만 같다",
        }, "확정", [ui_ev, eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.vram.thresholds", {
            "enterFraction": floats["enterFraction"],
            "releaseFraction": floats["releaseFraction"],
            "immediateReleaseFraction": floats["immediateReleaseFraction"],
            "sustainSeconds": floats["sustainSeconds"],
            "상수 VA": {k: hex(v) for k, v in sorted(VRAM_FLOAT_VA.items())},
            "진입": "used >= total * enterFraction 이면 래치를 세우고 타이머를 0 으로 되돌린다",
            "복귀": "타이머 > sustainSeconds **이고** total * releaseFraction > used 이거나, "
                    "total * immediateReleaseFraction > used 이면 시간과 무관하게 즉시",
            "타이머": "0x1404e6428 의 f32. 진입선 아래인 틱에서만 누적된다"
                      "(0x14006d3b8 의 QueryPerformanceCounter 차분)",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.vram.sampling", {
            "카운터": counter_path,
            "폴 간격(초)": poll_seconds,
            "표본 스레드": "0x140141460–0x1401417dc",
            "최소 표본 수": min_samples,
            "총량 하한(MB)": total_low,
            "총량 상한(MB)": total_low + total_span,
            "사용량": "표본[0] ÷ 1_000_000 (매직 0x431bde82d7b634db, `sar rdx, 0x12`) → MB",
            "총량": "표본[마지막] 의 하위 32비트를 MB 로 읽는다. 같은 카운터의 다른 인스턴스 "
                    "값이므로 단위가 사용량과 어긋난다 — 바이트가 그렇게 되어 있다",
            "게이트": f"표본이 {min_samples}개 미만이거나 총량이 범위 밖이면 "
                      "0x14006d403 으로 바로 뛰어 래치를 **그대로 둔다**(지우지 않는다)",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.vram.escalation", {
            "결과": "stop",
            "근거": f"래치는 플래그 bit10 인데 {STOP_MASK_SITE[0]:#x} 의 "
                    f"`test ecx, {stop_mask:#x}` 가 bit3 와 **같은 자리에서** 보고 "
                    "0x14006d423 `cmovne ebx, 1` 로 정지를 세운다",
            "이름 주의": "설정 키가 `pausevram` 이라 일시정지로 읽히지만 실물은 렌더러를 내린다",
        }, "확정", [eval_ev, script_ev]),

        specfmt.entry("playbackPolicy.model", {
            "구현": "Sources/WaplePolicy/PlaybackPolicy.swift",
            "의존": "Foundation 하나. simd·CoreGraphics·AppKit 를 쓰지 않는다",
            "검사기": "scripts/spec/check_playback_policy.py",
            "타깃": "WaplePolicy · WaplePolicyTests (Package.swift, 다른 타깃에 의존하지 않는다)",
        }, "확정", [swift_ev, script_ev]),
    ]

    specfmt.dump(specfmt.doc("scripts/spec/measure_playback_policy.py", entries,
                             extra={"scope": "wallpaper64.exe 재생 정책(6축 + pausevram)"}), OUT)

    print(f"액션 {len(actions)}종: " + " · ".join(
        f"{k}={v}" for k, v in sorted(actions.items(), key=lambda kv: kv[1])))
    for key in sorted(AXIS_KEY_VA):
        print(f"  {key:<20} 기본 {defaults[key]:<9} 전역 {globals_[key]:<12} "
              f"허용 {','.join(allowed[key]['multiMonitor'])}")
    print(f"  pausevram            기본 false     bool 태그 5")
    print(f"VRAM 진입 {floats['enterFraction']} · 복귀 {floats['releaseFraction']}"
          f"+{floats['sustainSeconds']}s · 즉시 {floats['immediateReleaseFraction']} · "
          f"표본≥{min_samples} · 총량 {total_low}–{total_low + total_span}MB · "
          f"폴 {poll_seconds}s")
    print(f"정지 승격 비트 {stop_mask:#x} · 모니터 인덱스 필드 +{build_field:#x} · "
          f"layout {layouts}")


if __name__ == "__main__":
    main()
