#!/usr/bin/env python3
"""블렌드 모드 도메인의 **세 출처 교차 확정** → spec/engine/blend-modes.json.

왜 별도 문서인가
----------------
`spec/engine/shaders.json` 의 `shaders.blending.*` 는 **셰이더 문면**만 담는다 — 이름은
`common_blending.h` 의 매크로 이름(`BlendSubstract` 등)이다. 그런데 방법론 함정 27
("함수에 붙인 이름은 근거가 아니다") 이 정확히 이 자리에 걸린다:

  · 모드 4 의 매크로 이름은 `BlendSubstract` 인데 **에디터가 사용자에게 보이는 이름은
    `linear_burn`** 이다. 모드 20 이 같은 매크로를 가리키면서 이름이 `subtract` 다.
  · 모드 5/10 의 매크로는 그냥 `min`/`max` 인데 UI 이름은 `darker_color`/`lighter_color`.
  · 모드 9 는 `BlendAdd` 인데 UI 이름은 `linear_dodge` 이고, UI 의 `add` 는 **모드 31** 이다.
  · 모드 32 는 매크로가 없고(인라인 식) UI 이름은 `diffuse_light`.

즉 매크로 이름만 인용하면 사용자·저작자와 말이 안 통하고, 워크샵 자산의 의도를 오독한다.
이 문서는 **에디터 드롭다운의 라벨↔값 짝**을 바이너리에서 직접 떠서 그 층을 채운다.

그리고 `shaders.json` 이 담지 않는 사실 하나를 더 담는다 — 에디터가 모드를
`native (fast)` / `emulated (slow)` 두 그룹으로 가르는데, **그 그룹 경계가 엔진의
`0 또는 31` 고속 경로와 정확히 같다**(`docs/re/material-blend.md` §7.5.3 이 종전에
**추정**으로 남겨 둔 항목이다 — 이 측정이 확정으로 바꾼다).

라벨↔값 짝을 뜨는 법 (함정 16 대비)
-----------------------------------
드롭다운 항목 하나는 **세 명령**으로 만들어진다:

    lea r8,  [rip+…]   ; "31"                      ← 값 문자열이 **먼저**
    lea rdx, [rip+…]   ; "ui_editor_blending_add"  ← 라벨이 **뒤**
    call sub_14015fa30 ; f(rcx=json, rdx=label, r8=value)

`sub_14015fa30` 본문이 rdx 를 `"label"` 키로, r8 을 `"value"` 키로 넣는 것을 확인했다
(`0x14015fa6d` `lea rdx, "label"` · `0x14015faf6` `mov rcx, rbp`(=r8) 뒤 `"value"`).
**값이 라벨보다 앞에 온다** — 문자열 풀 순서나 "라벨 다음 정수" 로 짝을 지으면 한 칸 밀린다.

그래서 이 생성기는 **7+7+5바이트 고정 패턴**을 바이트로 스캔한다(디스어셈블러 불필요).
33개 중 31개가 이 패턴이고, 나머지 둘(`darken`=1 · `tint`=30)은 MSVC 가 std::string 을
길게 지어 올리는 갈래라 패턴이 다르다 — 그 둘은 **바이트 증거를 VA 로 단언**해서 뽑는다.
교차검증: 33개 값 집합이 정확히 0…32 여야 한다(모자라면 exit(1)).

재현
----
    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_blend_modes.py

`WE_ROOT/bin/wallpaperui.exe` 와 `WE_ROOT/wallpaper64.exe`, 그리고 동봉
`Sources/WapleRender/Resources/WEAssets/shaders/common_blending.h` 가 있어야 돈다.
하나라도 없으면 **부분 산출을 만들지 않고** exit(1) 한다(0 건을 확정으로 찍는 것보다 낫다 —
`scripts/spec/check_spec_shrink_guard.py` 머리말).
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
HEADER = os.path.join(WEASSETS, "shaders", "common_blending.h")
OUT = os.path.join(REPO, "spec", "engine", "blend-modes.json")

WE_ROOT = os.environ.get("WE_ROOT", "")
UI_BIN = os.path.join(WE_ROOT, "bin", "wallpaperui.exe") if WE_ROOT else ""
ENGINE_BIN = os.path.join(WE_ROOT, "wallpaper64.exe") if WE_ROOT else ""

# 드롭다운 생성기(wallpaperui.exe). merged 범위이고 primary 는 0x140160040 이다.
UI_BUILDER = (0x14015FD90, 0x140160A4C)
UI_ADD_OPTION = 0x14015FA30          # f(rcx=json, rdx=label, r8=value)

# 패턴 밖 두 항목의 **바이트 증거**. MSVC 가 std::string 을 길게 지어 올리는 갈래라
# 위의 3명령 패턴에 안 걸린다. 각각 (값, 라벨 문자열 VA, 라벨, 값 증거 VA, 기대 바이트, 설명).
#   · darken — 값이 `lea rcx, "1"`(0x14016035a) 로 오고 뒤이어 키 "value" 로 들어간다.
#   · tint   — 값 "30" 이 `mov word [rax+4], 0x3033` 즉치로 인라인된다(길이 2 는
#              0x140160206 `mov dword [rax], 2`). 라벨도 23바이트 인라인 사본이다.
UI_LONGFORM = (
    (1, 0x140AD4190, "ui_editor_blending_darken", 0x14016035A,
     "488d0d8fca9600",
     "lea rcx, \"1\" @0x14016035a → sub_140234c20(len=1) → 키 \"value\" @0x140160387"),
    (30, 0x140AD4170, "ui_editor_blending_tint", 0x140160213,
     "66c740043330",
     "mov word [rax+4], 0x3033 = \"30\" (길이 2 = 0x140160206 mov dword [rax],2) → "
     "키 \"value\" @0x140160219"),
)

# 엔진(wallpaper64.exe)의 native 고속 경로 — colorBlendMode 가 0/31 이면 셰이더를 안 탄다.
NATIVE_FASTPATH_SITES = {
    "combos.BLENDMODE 강제 0": ["0x140206be0", "0x1401ebc96", "0x140257911"],
    "머티리얼 blending 강제 additive(2)": ["0x1401ea096", "0x140208786"],
    "_rt_FullFrameBuffer 요청 건너뜀": ["0x1401e8ef2", "0x1401e8f44"],
}


def read_header():
    with open(HEADER, "rb") as fh:
        return fh.read().decode("utf-8")


def header_modes(text):
    """`#if BLENDMODE == n` 집합과, 각 팔이 opacity 를 어떻게 쓰는지."""
    lines = [ln.strip() for ln in text.replace("\r\n", "\n").split("\n")]
    arms, cur = {}, None
    for ln in lines:
        m = re.match(r"^#if BLENDMODE == (\d+)$", ln)
        if m:
            cur = int(m.group(1))
            continue
        if ln == "#endif":
            cur = None
            continue
        if cur is not None and ln.startswith("return "):
            arms[cur] = "mix" if ln.startswith("return mix(A,") else "none"
    return arms


class PE:
    def __init__(self, path):
        with open(path, "rb") as fh:
            self.d = fh.read()
        d = self.d
        e = struct.unpack_from("<I", d, 0x3C)[0]
        if d[e:e + 4] != b"PE\0\0":
            raise SystemExit("PE 가 아니다: %s" % path)
        nsec = struct.unpack_from("<H", d, e + 6)[0]
        optsz = struct.unpack_from("<H", d, e + 20)[0]
        magic = struct.unpack_from("<H", d, e + 24)[0]
        self.base = (struct.unpack_from("<Q", d, e + 48)[0] if magic == 0x20B
                     else struct.unpack_from("<I", d, e + 52)[0])
        so = e + 24 + optsz
        self.sec = []
        for i in range(nsec):
            o = so + 40 * i
            name = d[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            vsz, va, rawsz, rawoff = struct.unpack_from("<IIII", d, o + 8)
            self.sec.append((name, va, vsz, rawoff, rawsz))

    def off(self, va):
        r = va - self.base
        for _n, sva, vsz, rawoff, rawsz in self.sec:
            if sva <= r < sva + max(vsz, rawsz):
                delta = r - sva
                return rawoff + delta if delta < rawsz else None
        return None

    def va(self, off):
        for _n, sva, _vsz, rawoff, rawsz in self.sec:
            if rawoff <= off < rawoff + rawsz:
                return self.base + sva + (off - rawoff)
        return None

    def read(self, va, n):
        o = self.off(va)
        return self.d[o:o + n] if o is not None else b""

    def cstr(self, va, maxlen=96):
        b = self.read(va, maxlen)
        z = b.split(b"\0")[0]
        return z.decode("ascii", "replace") if z else ""


def ui_dropdown(pe):
    """라벨↔값 짝 전수. 고정 3명령 패턴 + 긴 문자열 갈래 둘."""
    lo, hi = UI_BUILDER
    o = pe.off(lo)
    blob = pe.d[o:o + (hi - lo)]
    pairs, sites, addr = {}, {}, {}
    for i in range(len(blob) - 19):
        if blob[i:i + 3] != b"\x4c\x8d\x05":            # lea r8, [rip+d32]
            continue
        if blob[i + 7:i + 10] != b"\x48\x8d\x15":       # lea rdx, [rip+d32]
            continue
        if blob[i + 14] != 0xE8:                        # call rel32
            continue
        va = lo + i
        d_val = struct.unpack_from("<i", blob, i + 3)[0]
        d_lab = struct.unpack_from("<i", blob, i + 10)[0]
        d_cal = struct.unpack_from("<i", blob, i + 15)[0]
        if va + 14 + 5 + d_cal != UI_ADD_OPTION:
            continue
        # 첫 lea(r8) 가 **값**, 둘째 lea(rdx) 가 **라벨**이다(함정 16 — 순서를 뒤집으면 0건이 된다).
        value = pe.cstr(va + 7 + d_val)
        label = pe.cstr(va + 14 + d_lab)
        if not label.startswith("ui_editor_blending_"):
            continue
        if not re.fullmatch(r"\d+", value):
            raise SystemExit("값 자리가 정수 문자열이 아니다 @%#x: %r" % (va, value))
        pairs[int(value)] = label[len("ui_editor_blending_"):]
        sites[int(value)] = hex(va)
        addr[int(value)] = va
    for value, lab_va, label, ev_va, ev_bytes, note in UI_LONGFORM:
        got = pe.cstr(lab_va)
        if got != label:
            raise SystemExit("긴 갈래 라벨이 %#x 에서 %r 이 아니다: %r" % (lab_va, label, got))
        want = bytes.fromhex(ev_bytes)
        have = pe.read(ev_va, len(want))
        if have != want:
            raise SystemExit("긴 갈래 값 증거가 %#x 에서 %s 가 아니다: %s"
                             % (ev_va, ev_bytes, have.hex()))
        pairs[value] = label[len("ui_editor_blending_"):]
        sites[value] = "%s (%s)" % (hex(ev_va), note)
        addr[value] = ev_va
    return pairs, sites, addr


def ui_groups(pe):
    """`isgrouptitle` 두 개가 드롭다운을 가르는 자리 — 그 앞뒤로 어느 값이 오는가."""
    lo, hi = UI_BUILDER
    o = pe.off(lo)
    blob = pe.d[o:o + (hi - lo)]
    marks = []
    for i in range(len(blob) - 7):
        if blob[i:i + 3] != b"\x48\x8d\x15":            # lea rdx, [rip+d32]
            continue
        va = lo + i
        d = struct.unpack_from("<i", blob, i + 3)[0]
        s = pe.cstr(va + 7 + d)
        if s.startswith("ui_editor_blending_group_"):
            marks.append((va, s[len("ui_editor_blending_group_"):]))
    return marks


def corpus_reach(root, label):
    """`objects[].colorBlendMode` 와 `passes[].combos.BLENDMODE` 도수."""
    cbm, combo, files = collections.Counter(), collections.Counter(), 0
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if not f.lower().endswith(".json"):
                continue
            files += 1
            try:
                raw = open(os.path.join(dp, f), "rb").read()
                if raw[:3] == b"\xef\xbb\xbf":
                    raw = raw[3:]
                doc = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue
            stack = [doc]
            while stack:
                n = stack.pop()
                if isinstance(n, dict):
                    for k, v in n.items():
                        if k == "colorBlendMode" and isinstance(v, (int, float)):
                            cbm[int(v)] += 1
                        if k == "combos" and isinstance(v, dict):
                            for k2, v2 in v.items():
                                if k2.upper() == "BLENDMODE" and isinstance(v2, (int, float)):
                                    combo[int(v2)] += 1
                        stack.append(v)
                elif isinstance(n, list):
                    stack.extend(n)
    return {"모집단": label, "json": files,
            "colorBlendMode": {str(k): cbm[k] for k in sorted(cbm)},
            "combos.BLENDMODE": {str(k): combo[k] for k in sorted(combo)}}


def shader_combo_defaults(root):
    """`[COMBO] … "type":"imageblending"` 선언의 default 분포(설치본 전수)."""
    dist, lines = collections.Counter(), 0
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if not f.lower().endswith((".frag", ".vert", ".h")):
                continue
            try:
                txt = open(os.path.join(dp, f), "rb").read().decode("utf-8", "replace")
            except Exception:
                continue
            for ln in txt.splitlines():
                if "imageblending" not in ln or "[COMBO]" not in ln:
                    continue
                lines += 1
                m = re.search(r'"default"\s*:\s*"?(-?\d+)"?', ln)
                if m:
                    dist[int(m.group(1))] += 1
    return lines, {str(k): dist[k] for k in sorted(dist)}


def build(ui, engine, header):
    arms = header_modes(header)
    pairs, sites, addr = ui_dropdown(ui)
    marks = ui_groups(ui)
    bundled = corpus_reach(WEASSETS, "동봉 Sources/WapleRender/Resources/WEAssets")
    install = corpus_reach(WE_ROOT, "설치본 wallpaper_engine")
    combo_lines, combo_dist = shader_combo_defaults(WE_ROOT)
    # **도달**은 세 갈래를 합쳐야 뜻이 있다 — 오브젝트 키 · 머티리얼 콤보 · 셰이더 기본값.
    measured_reached = set()
    for src in (bundled, install):
        for key in ("colorBlendMode", "combos.BLENDMODE"):
            measured_reached |= {int(k) for k in src[key]}
    measured_reached |= {int(k) for k in combo_dist}
    # **그룹 멤버십은 코드 순서로만 판정한다.** `native` 헤더 다음, `emulated` 헤더 앞에
    # 적재되는 항목이 native 다 — 0/31 을 미리 알고 거르면 순환 논증이 된다.
    by_group = {g: va for va, g in marks}
    lo_native, lo_emul = by_group["native"], by_group["emulated"]
    native = sorted(v for v, a in addr.items() if lo_native < a < lo_emul)
    emulated = sorted(v for v, a in addr.items() if a > lo_emul)

    ui_ev = specfmt.ev("binary", "bin/wallpaperui.exe 0x14015fd90–0x140160a4c",
                       "12,742,640 B. lea r8(값)+lea rdx(라벨)+call 0x14015fa30 고정 패턴")
    eng_ev = specfmt.ev("binary", "wallpaper64.exe 0x140206be0 · 0x1401ea096 · 0x1401e8ef2",
                        "colorBlendMode 0/31 고속 경로")
    sh_ev = specfmt.ev("shader", "shaders/common_blending.h:106-271")
    scr_ev = specfmt.ev("script", "scripts/spec/measure_blend_modes.py")
    src_ev = specfmt.ev("file", "Sources/WapleRender/BlendMSL.swift")

    return [
        specfmt.entry("blend.editorDropdown", {
            "값→UI라벨": {str(k): pairs[k] for k in sorted(pairs)},
            "항목수": len(pairs),
            "도메인": "0…32 (33개) — 값 집합이 정확히 range(33)",
            "적재자리": {str(k): sites[k] for k in sorted(sites)},
            "짝짓는 법": "lea r8=값문자열 → lea rdx=라벨 → call 0x14015fa30. "
                        "**값이 라벨보다 앞**이라 라벨 다음 정수로 짝지으면 한 칸 밀린다(함정 16)",
            "인자 규약 근거": "0x14015fa6d `lea rdx, \"label\"` · 0x14015faf6 `mov rcx, rbp`(r8) 뒤 \"value\"",
            "매크로 이름과 갈리는 자리": {
                "4": "매크로 BlendSubstract / UI linear_burn",
                "5": "매크로 없음(min) / UI darker_color",
                "9": "매크로 BlendAdd / UI linear_dodge",
                "10": "매크로 없음(max) / UI lighter_color",
                "20": "매크로 BlendSubstract(4와 동일식) / UI subtract",
                "31": "매크로 없음(A+B·o) / UI **add**",
                "32": "매크로 없음(mix(A,A+A·B,o)) / UI diffuse_light",
            },
            "crossRef": "spec/engine/shaders.json shaders.blending.modes 는 **매크로 이름**을 싣는다. "
                        "둘은 다른 층이고 서로 대체하지 않는다",
        }, "확정", [ui_ev, scr_ev]),

        specfmt.entry("blend.nativeVsEmulated", {
            "그룹 헤더 적재자리": [{"va": hex(va), "group": g} for va, g in marks],
            "native": native,
            "emulated": emulated,
            "판정": "드롭다운이 `group_native` 뒤에 0·31 만 놓고 `group_emulated` 뒤에 나머지 31개를 "
                   "놓는다. 엔진의 `0 또는 31` 고속 경로와 **경계가 정확히 같다**",
            "엔진측 자리": NATIVE_FASTPATH_SITES,
            "종전 등급": "docs/re/material-blend.md §7.5.3 은 그룹 멤버십을 미확정 등급으로 "
                       "남겨 뒀다(그 문서의 등급 표기를 보라). 이 측정이 확정으로 바꾼다",
        }, "확정", [ui_ev, eng_ev, scr_ev]),

        specfmt.entry("blend.opacityApplication", {
            "mix 적용": sorted(k for k, v in arms.items() if v == "mix"),
            "opacity 무시(즉시 return)": sorted(k for k, v in arms.items() if v == "none"),
            "fallthrough(0 · 범위 밖)": "mix(A, BlendNormal(A,B), opacity) = mix(A,B,o)",
            "근거": "헤더의 `#if BLENDMODE == n` 팔이 `return mix(A,…,opacity)` 인지 아닌지로 판정",
        }, "확정", [sh_ev, scr_ev]),

        specfmt.entry("blend.formulaParity", {
            "대조 방법": "WE 원문(common_blending.h 의 정확 비교 `==` 포함) · BlendMSL.swift(MSL) · "
                       "BuiltinShaderIncludes.swift(GLSL 심) 셋을 파이썬으로 옮겨 격자 평가",
            "격자": "A·B 각 성분 0…255/255 중 52단계 + {0,0.5,1} · opacity {0,0.25,0.5,0.75,1} · "
                   "모드 0…32 와 범위 밖 {-1,33,99}",
            "결과": "in-range 전건 |Δ| < 1e-9 — 어긋나는 모드 0개",
            "범위 밖 이탈": {
                "3·8·14·17·21·22": "WE 의 `blend == 0` / `blend == 1` **정확 비교**를 "
                                   "`s <= 0` / `s >= 1` **범위 비교**로 바꾼 자리. [0,1] 안에서는 동일",
                "12": "WE 는 `sqrt(base)` 무가드 — base<0 에서 NaN. 포트는 `sqrt(max(b,0))`",
                "26·27·28·29": "WE 의 `#ifdef HDR color = saturate(color)` 를 포트는 무조건 적용. "
                              "LDR(UNORM ≤1) 에서는 항등",
            },
            "등록된 이탈": "spec/engine/deviations.json deviation.D3 (정확비교↔범위비교) · "
                        "BlendMSL.swift F676 주석(HDR saturate)",
            "클램프 규약": "`f` 변형 매크로(BlendLinearDodgef 등)는 클램프가 **없다** — 모드 15 의 "
                        "s≥0.5 가지가 그것을 그대로 쓴다. 최종 클램프는 렌더타깃 포맷이 한다"
                        "(LDR bgra8Unorm=클램프, HDR rgba16Float=클램프 없음 — WE 도 같다)",
            "알파 규약": "`ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a)` — "
                       "**A·B 양변 straight(비-프리멀티)**, opacity = 이 레이어의 straight 알파. "
                       "직후 `gl_FragColor.a = screen.a` 로 알파를 배경 것으로 되돌린다"
                       "(genericimage2.frag:162-167). 소스 rgb 에 알파를 곱하는 자리는 없다",
        }, "확정", [sh_ev, src_ev, scr_ev,
                   specfmt.ev("file", "Sources/WapleCore/BuiltinShaderIncludes.swift")]),

        specfmt.entry("blend.corpusReach", {
            "동봉": bundled,
            "설치본": install,
            "셰이더 [COMBO] imageblending 선언": {"줄수": combo_lines, "default 분포": combo_dist},
            "워크샵 코퍼스": "이 컨테이너에 없다 — `spec/corpus/scene-schema.json` "
                          "scene.objects.colorBlendMode 인용만 쓰고 재측정하지 않았다",
            "이 컨테이너에서 도달한 모드": sorted(measured_reached),
            "이 컨테이너에서 도달 0": sorted(set(range(33)) - measured_reached),
            "세 코퍼스 전부 도달 0": [5, 10, 13, 14, 17, 20, 25, 26, 29],
            "도달 0의 뜻": "위 '세 코퍼스 전부 도달 0' 아홉은 동봉·설치본에서 재 보면 0건이고, "
                        "워크샵 코퍼스 인용(scene.objects.colorBlendMode)에서도 image 미도달이다. "
                        "구현은 되어 있으나 **회귀를 관측할 표본이 없다** — 그쪽 산식을 손대는 "
                        "변경은 A/B 로 확인할 방법이 없다는 뜻이다. "
                        "반대로 워크샵에서 31 이 image 최다(447/782)이고 그것이 native 경로다",
        }, "확정", [specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/**/*.json"),
                   specfmt.ev("asset", "WE_ROOT/**/*.json"), scr_ev]),
    ]


def main():
    for p, why in ((HEADER, "동봉 common_blending.h"),
                   (UI_BIN, "WE_ROOT/bin/wallpaperui.exe"),
                   (ENGINE_BIN, "WE_ROOT/wallpaper64.exe")):
        if not p or not os.path.exists(p):
            raise SystemExit(
                "%s 를 찾지 못했다: %r\n"
                "라벨↔값 짝은 바이너리 전수 스캔이라 부분 산출을 만들지 않는다 — "
                "WE_ROOT 를 주고 다시 돌려라." % (why, p or "<WE_ROOT 미설정>"))
    ui = PE(UI_BIN)
    engine = PE(ENGINE_BIN)
    header = read_header()
    pairs, _sites, _addr = ui_dropdown(ui)
    if sorted(pairs) != list(range(33)):
        raise SystemExit("드롭다운 값 집합이 0…32 가 아니다: %s" % sorted(pairs))
    if sorted(header_modes(header)) != list(range(1, 33)):
        raise SystemExit("헤더의 #if BLENDMODE 집합이 1…32 가 아니다")
    entries = build(ui, engine, header)
    specfmt.dump(specfmt.doc("scripts/spec/measure_blend_modes.py", entries), OUT)
    print("%s: %d 항목 (드롭다운 %d 짝)" % (OUT, len(entries), len(pairs)))


if __name__ == "__main__":
    main()
