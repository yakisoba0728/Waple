#!/usr/bin/env python3
"""WE 의 **대표색 추출**과 `schemecolor` 의 산출·소비 → spec/engine/dominant-color.json.

담는 것
-------
1. `bin/resourceutil64.dll` 의 `GetDominantColor` **산식 전문**을 상수 적재 자리까지.
   양자화 축(hue 360빈) · 가중치(`(int)(S·V·100)`) · 무채색 판정 임계 · 출력 팩 순서.
   그리고 "채도 하한" 의 정확한 성격 — 별도의 하한 상수는 **없고**, 가중치의 `cvttss2si`
   **절단**이 `S·V < 0.01` 인 픽셀을 기여 0 으로 만든다(빈의 count/satSum/valSum 에는 그대로 든다).
2. `wallpaper64.exe` 가 **네이티브에서** 그 함수를 불러 `general.properties.schemecolor.value`
   를 짓는 자리. 종전 `docs/re/scheme-color.md` §2 는 이 경로를 에디터 JS
   (`getDominantColorFromFile`)로만 인용했다 — 네이티브 쪽 VA 가 없었다.
3. 미디어 썸네일 이벤트의 다섯 색(`primaryColor` … `highContrastColor`)이
   `wallpaper64.exe` 안에서 **생산되지 않는다**는 부정 결론과 그 표본 설계.

부정 결론의 표본 설계 (3)
-------------------------
"이 이미지에 생산자가 없다" 는 부정 결론이다. 재는 방법을 먼저 밝힌다.

  · 다섯 색은 한 객체의 `+0x150 · +0x154 · +0x158 · +0x15c · +0x160` 연속 dword 다
    (이벤트 빌더 `0x14011be40`–`0x14011c90c` 가 그 순서로 읽는다).
  · `.pdata` 의 **모든 함수를 선형 디스어셈**해서 그 다섯 변위로 가는 **스택이 아닌**
    dword 스토어를 전수로 센다(방법론 함정 4 — 호출 사이트가 아니라 적재/저장 자리를 센다).
  · 남는 것이 (a) 생성자의 0 초기화 (b) 복사 생성자 (c) 무관한 4×4 행렬 복사뿐이면
    **이 이미지에는 계산 자리가 없다**.
  · 교차 근거: `wallpaper64.exe` 에는 WinRT 미디어 세션 문자열이 **0건**이고
    (`Windows.Media.Control` · `GlobalSystemMediaTransportControlsSessionManager`,
    ASCII/UTF-16 양쪽), 그 문자열은 `bin/winrtutil64.exe` 에만 있다. 즉 다섯 색은
    다른 프로세스에서 건너온다(방법론 함정 13 — 바이너리 하나 ≠ WE).

재현
----
    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_dominant_color.py

`WE_ROOT/wallpaper64.exe` 와 `WE_ROOT/bin/resourceutil64.dll` · `WE_ROOT/bin/winrtutil64.exe`
가 있어야 돈다. 하나라도 없으면 **부분 산출을 만들지 않고** exit(1) 한다.
`capstone` 이 필요하다(전수 디스어셈) — 없으면 exit(1).
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
OUT = os.path.join(REPO, "spec", "engine", "dominant-color.json")

WE_ROOT = os.environ.get("WE_ROOT", "")
ENGINE = os.path.join(WE_ROOT, "wallpaper64.exe") if WE_ROOT else ""
RESUTIL = os.path.join(WE_ROOT, "bin", "resourceutil64.dll") if WE_ROOT else ""
WINRT = os.path.join(WE_ROOT, "bin", "winrtutil64.exe") if WE_ROOT else ""

# ── resourceutil64.dll (imagebase 0x180000000) ────────────────────────────────
# export 둘 다 같은 본체로 접힌다(ICF). 5바이트 `jmp rel32`.
RESUTIL_THUNKS = {"GetDominantColor": 0x180001A90, "GetDominantColorFromImage": 0x1800014C0}
RESUTIL_BODY = 0x18000A6D0          # 로더 래퍼
RESUTIL_CORE = 0x180009E30          # 히스토그램 본체

# (VA, 폭, 기대값, 무엇) — 부동소수 상수 적재 대상.
RESUTIL_FCONST = (
    (0x18011A3DC, 4, 255.0, "채널 정규화 제수 (0x180009efb movss xmm15)"),
    (0x18011A3D4, 4, 6.0, "hue 섹터 제수 (0x180009f14 movss xmm13)"),
    (0x18011A39C, 4, 1.0, "hue<0 보정 가산 (0x180009f1d movss xmm12)"),
    (0x18011A3E0, 4, 360.0, "빈 수 = hue·360 (0x180009f26 movss xmm9)"),
    (0x18011A3D8, 4, 100.0, "가중치 배율 (0x180009f48 movss xmm10)"),
    (0x18011A398, 4, 9.999999747378752e-06, "무채색 임계 delta<1e-5 (0x180009f5a movss xmm11)"),
    (0x18011A3B0, 8, 2.0, "hue 섹터 오프셋 +2 (0x180009f07 movsd xmm14)"),
    (0x18011A3B8, 8, 4.0, "hue 섹터 오프셋 +4 (0x180009f37 movsd xmm7)"),
    (0x18011A3C0, 8, 6.0, "HSV→RGB fmod 제수 (0x18000a508 movsd xmm1)"),
)

# (VA, 기대 바이트, 무엇) — 산식을 고정하는 명령.
RESUTIL_SITES = (
    (0x180009E97, "41b8400b0000", "weight/count 배열 memset 크기 0xb40 = 360 × int64"),
    (0x180009EDC, "41b8a0050000", "satSum/valSum 배열 memset 크기 0x5a0 = 360 × float"),
    (0x180009F85, "8b0c06", "픽셀 dword 적재 — byte0 = R"),
    (0x180009FD4, "440f2fde", "comiss xmm11(1e-5), xmm6(delta) — delta<1e-5 면 무채색"),
    (0x180009FDA, "410f2fe0", "comiss xmm4(fmax), xmm8(0) — fmax<=0 이면 무채색"),
    (0x180009FE6, "f30f5ed4", "divss xmm2 = delta / fmax = HSV **S**"),
    (0x18000A035, "f30f2cc9", "cvttss2si ecx = trunc(hue·360) — 빈 번호"),
    (0x18000A039, "81f967010000", "cmp ecx, 0x167 — 359 상한"),
    (0x18000A051, "0f48c8", "cmovs ecx, 0 — 음수 하한"),
    (0x18000A048, "33c9", "무채색 갈래: 빈 0"),
    (0x18000A04A, "0f57d2", "무채색 갈래: xorps xmm2 → S=0 (**V=fmax 는 그대로 누적된다**)"),
    (0x18000A05A, "f30f59c4", "mulss xmm0 = S · V"),
    (0x18000A078, "f3410f59c2", "mulss xmm0 *= 100.0"),
    (0x18000A08C, "f30f2cc0", "cvttss2si eax — **절단**. S·V<0.01 이면 가중치 기여 0"),
    (0x18000A093, "48018cd5600a0000", "weight[bin] += (int64)eax"),
    (0x18000A070, "48ff84d5a0150000", "count[bin] += 1"),
    (0x18000A0FB, "4c3bc8", "cmp r9(weight[bin]), rax — 최대 빈 선택"),
    (0x18000A105, "418bd1", "mov edx, r9d — 러닝 최대를 **int32 로 좁힌다**(대형 이미지 오버플로 결함)"),
    (0x18000A116, "f3410f5ec1", "divss xmm0 = bin / 360 = H"),
    (0x18000A14C, "f30f5ef1", "divss xmm6 = satSum[bin] / count[bin] = S"),
    (0x18000A150, "f30f5ef9", "divss xmm7 = valSum[bin] / count[bin] = V"),
    (0x18000A515, "f30f59f7", "mulss xmm6 = S·V = C(chroma)"),
    (0x18000A544, "f30f5cfe", "subss xmm7 = V − C = m"),
    (0x18000A6A2, "81ca000000ff", "or edx, 0xff000000 — 출력 = 0xFF000000|B<<16|G<<8|R"),
)

# ── wallpaper64.exe (imagebase 0x140000000) ───────────────────────────────────
SCHEMEGEN = (0x140110060, 0x1401105A5)      # merged 범위
SCHEMEGEN_SITES = (
    (0x140110209, "488d15f06d3700", '.gif 확장자 게이트 — lea rdx, ".gif"(0x140487000)'),
    (0x14011023F, "488d0d2a7f3600", 'lea rcx, L"resourceutil64.dll"(0x140478170) → LoadLibraryExW'),
    (0x14011027B, "488d15168f3700", 'lea rdx, "GetDominantColorFromImage"(0x140489198) → GetProcAddress'),
    (0x1401102A4, "ffd0", "call rax — 반환 eax = 0xFF000000|B<<16|G<<8|R"),
    (0x1401102C1, "4c8d05108e3700", 'lea r8, "%.5f %.5f %.5f"(0x1404890d8)'),
    (0x1401103CB, "488d158e413600", 'lea rdx, "schemecolor"(0x140474560)'),
    (0x1401103EA, "488d1517413600", 'lea rdx, "value"(0x140474508)'),
)

# 미디어 썸네일 이벤트의 다섯 색 — 오프셋과 읽는 자리(빌더 0x14011be40–0x14011c90c).
MEDIA_COLOR_FIELDS = (
    ("primaryColor", "0x150", "0x14011c4f1"),
    ("secondaryColor", "0x154", "0x14011c558"),
    ("tertiaryColor", "0x158", "0x14011c5ab"),
    ("textColor", "0x15c", "0x14011c5fe"),
    ("highContrastColor", "0x160", "0x14011c651"),
)
MEDIA_COLOR_OFFSETS = ("0x150]", "0x154]", "0x158]", "0x15c]", "0x160]")
WINRT_STRINGS = ("Windows.Media.Control", "GlobalSystemMediaTransportControlsSessionManager")


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
        self.funcs = []
        for name, sva, vsz, rawoff, _rawsz in self.sec:
            if name != ".pdata":
                continue
            for i in range(vsz // 12):
                b, e2, _u = struct.unpack_from("<III", d, rawoff + i * 12)
                if b:
                    self.funcs.append((self.base + b, self.base + e2))
        self.funcs.sort()

    def off(self, va):
        r = va - self.base
        for _n, sva, vsz, rawoff, rawsz in self.sec:
            if sva <= r < sva + max(vsz, rawsz):
                delta = r - sva
                return rawoff + delta if delta < rawsz else None
        return None

    def read(self, va, n):
        o = self.off(va)
        return self.d[o:o + n] if o is not None else b""


def check_bytes(pe, sites, what):
    """명령 바이트를 전수 대조한다. 하나라도 어긋나면 exit(1) — 낡은 인용을 정본에 안 남긴다."""
    out = {}
    for va, hexs, note in sites:
        want = bytes.fromhex(hexs)
        have = pe.read(va, len(want))
        if have != want:
            raise SystemExit("%s: %#x 의 바이트가 %s 가 아니다 (%s): %s"
                             % (what, va, hexs, note, have.hex()))
        out[hex(va)] = note
    return out


def check_floats(pe):
    out = {}
    for va, width, want, note in RESUTIL_FCONST:
        raw = pe.read(va, width)
        got = struct.unpack("<f" if width == 4 else "<d", raw)[0]
        if got != want:
            raise SystemExit("resourceutil64: %#x 상수가 %r 이 아니다: %r" % (va, want, got))
        out[hex(va)] = {"값": want, "폭": width, "쓰는 자리": note}
    return out


def check_thunks(pe):
    out = {}
    for name, va in RESUTIL_THUNKS.items():
        b = pe.read(va, 5)
        if not b or b[0] != 0xE9:
            raise SystemExit("%s @%#x 가 jmp rel32 가 아니다" % (name, va))
        tgt = va + 5 + struct.unpack_from("<i", b, 1)[0]
        if tgt != RESUTIL_BODY:
            raise SystemExit("%s 가 %#x 로 가지 않는다: %#x" % (name, RESUTIL_BODY, tgt))
        out[name] = {"export": hex(va), "jmp": hex(tgt)}
    return out


def color_field_stores(pe):
    """다섯 색 변위로 가는 **스택 아닌** dword 스토어 전수(생산자 부재 증명의 그물)."""
    try:
        import capstone
    except ImportError:
        raise SystemExit("capstone 이 필요하다 — 전수 디스어셈으로 생산자 부재를 재기 때문이다")
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    md.detail = False
    seen = set()
    total = 0
    per_func = collections.defaultdict(lambda: collections.defaultdict(list))
    for b, e in pe.funcs:
        if (b, e) in seen:
            continue
        seen.add((b, e))
        o = pe.off(b)
        if o is None:
            continue
        for ins in md.disasm(pe.d[o:o + (e - b)], b):
            op = ins.op_str
            if ins.mnemonic not in ("mov", "movss"):
                continue
            if not op.startswith("dword ptr ["):
                continue                       # 목적지가 메모리인 것만
            if "rsp" in op or "rbp" in op:
                continue                       # 스택 지역변수는 이 구조체가 아니다
            hit = [k for k in MEDIA_COLOR_OFFSETS if k in op]
            if not hit:
                continue
            total += 1
            per_func[hex(b)][hit[0]].append(
                {"va": hex(ins.address), "insn": "%s %s" % (ins.mnemonic, op)})
    # 다섯 필드는 **연속 dword** 다. 계산 자리라면 한 함수가 그중 넷 이상을 쓴다.
    candidates = {f: {k: v for k, v in offs.items()}
                  for f, offs in per_func.items() if len(offs) >= 4}
    return {"그물 크기(전수 스토어)": total,
            "닿은 함수 수": len(per_func),
            "5필드 중 4개 이상을 쓰는 함수": candidates}


def strings_present(path, names):
    with open(path, "rb") as fh:
        d = fh.read()
    return {n: {"ascii": d.count(n.encode()), "utf16": d.count(n.encode("utf-16-le"))}
            for n in names}


def schemecolor_corpus(root, label):
    total, declared, zero, nonzero = 0, 0, 0, []
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if f.lower() != "project.json":
                continue
            total += 1
            try:
                raw = open(os.path.join(dp, f), "rb").read()
                if raw[:3] == b"\xef\xbb\xbf":
                    raw = raw[3:]
                doc = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue
            props = (doc.get("general") or {}).get("properties") or {}
            sc = props.get("schemecolor")
            if not isinstance(sc, dict):
                continue
            declared += 1
            v = str(sc.get("value", ""))
            if re.fullmatch(r"\s*0(\.0+)?(\s+0(\.0+)?){2}\s*", v):
                zero += 1
            else:
                nonzero.append(v)
    return {"모집단": label, "project.json": total, "schemecolor 선언": declared,
            "값이 0 0 0": zero, "비영값": len(nonzero),
            "비영값 표본": sorted(nonzero)[:4]}


def build(engine, resutil):
    resutil_ev = specfmt.ev("binary", "bin/resourceutil64.dll 0x180009e30–0x18000a6af",
                            "imagebase 0x180000000. GetDominantColor 본체")
    engine_ev = specfmt.ev("binary", "wallpaper64.exe 0x140110060–0x1401105a5",
                           "imagebase 0x140000000. schemecolor 네이티브 자동생성")
    media_ev = specfmt.ev("binary", "wallpaper64.exe 0x14011be40–0x14011c90c",
                          "미디어 썸네일 이벤트 빌더")
    scr_ev = specfmt.ev("script", "scripts/spec/measure_dominant_color.py")
    src_ev = specfmt.ev("file", "Sources/WapleRender/ArtworkColors.swift")

    stores = color_field_stores(engine)
    winrt_in_engine = strings_present(ENGINE, WINRT_STRINGS)
    winrt_in_helper = strings_present(WINRT, WINRT_STRINGS)

    return [
        specfmt.entry("dominantColor.entryPoints", {
            "export": check_thunks(resutil),
            "폴딩": "두 export 가 같은 5바이트 `jmp rel32` 로 0x18000a6d0 에 접힌다(ICF)",
            "래퍼": "0x18000a6d0 — 이미지 로드(sub_180009c40) 후 "
                   "sub_180009e30(rcx=RGBA8, edx=width, r8d=height) 호출(0x18000a71a)",
            "본체": hex(RESUTIL_CORE),
            "호출자": "에디터 JS `getDominantColorFromFile`(ui/dist/scripts/scripts.js) 와 "
                    "wallpaper64.exe 0x140110060(아래 항목)",
        }, "확정", [resutil_ev, scr_ev]),

        specfmt.entry("dominantColor.algorithm", {
            "1. 색공간": "RGBA8 전 픽셀 → HSV. 픽셀 dword 의 byte0 = R (0x180009f85)",
            "2. 양자화": "hue 를 **1° 단위 360빈**. bin = clamp(trunc(H·360), 0, 359)",
            "3. 무채색": "delta < 1e-5 **또는** fmax <= 0 이면 bin 0 · S=0. "
                       "V(=fmax) 는 그대로 valSum 에 든다 — S 만 0 이다",
            "4. 빈 누적": ["weight[bin] += (int)(S·V·100)", "count[bin] += 1",
                        "satSum[bin] += S", "valSum[bin] += V"],
            "5. 선택": "weight 최대 빈 하나. H = bin/360 · S = satSum/count · V = valSum/count",
            "6. 역변환": "표준 HSV→RGB (C = S·V, X = C·(1−|fmod(H·6,2)−1|), m = V−C), "
                       "각 채널 ×255 후 [0,255] 클램프",
            "7. 출력": "0xFF000000 | B<<16 | G<<8 | R (바이트 순서 R,G,B,A)",
            "채도 하한": "**별도의 하한 상수는 없다.** 하한 노릇을 하는 것은 가중치의 "
                      "`cvttss2si` **절단**이다(0x18000a08c) — S·V < 0.01 인 픽셀은 "
                      "weight 기여가 0 이 된다. 그래도 그 빈의 count/satSum/valSum 에는 "
                      "그대로 들어가므로 **선택된 빈의 평균색은 끌어내린다**",
            "알파": "읽지 않는다 — 픽셀 dword 에서 byte3 을 쓰는 자리가 본체에 없다",
            "표본": "전 픽셀(서브샘플·리사이즈 없음)",
            "결함": "최대 빈 비교가 러닝 최대를 int32 로 좁힌다(0x18000a105 `mov edx, r9d`). "
                   "픽셀수 × 100 이 2^31 을 넘으면(≈2148만 픽셀 이상, 전 픽셀이 S·V=1일 때) "
                   "비교가 뒤집힐 수 있다. 실행 관측은 못 했다",
            "상수 적재 자리": check_floats(resutil),
            "명령 자리": check_bytes(resutil, RESUTIL_SITES, "resourceutil64"),
        }, "확정", [resutil_ev, scr_ev]),

        specfmt.entry("dominantColor.schemecolorGeneration", {
            "무엇": "wallpaper64.exe 가 **네이티브에서** `general.properties.schemecolor.value` 를 짓는다",
            "게이트": "대상 파일 확장자가 `.gif` 일 때만(0x140110209). 그 밖은 0x1401104ab 로 빠진다",
            "적재": "LoadLibraryExW(L\"resourceutil64.dll\") → GetProcAddress(\"GetDominantColorFromImage\")",
            "포맷": '"%.5f %.5f %.5f" — R, G, B 순서로 각 채널/255 (버퍼 196바이트)',
            "채널 추출": "R = eax & 0xff · G = (eax>>8)&0xff · B = (eax>>16)&0xff "
                      "(0x1401102f8 / 0x1401102da / 0x1401102cd)",
            "주입": "`schemecolor` → `value` 두 단계 Json::Value::operator[](0x140086de0) — "
                    "키 lea 는 0x1401103cb / 0x1401103ea, 그 직후 call 이 0x1401103db / 0x1401103f1",
            "명령 자리": check_bytes(engine, SCHEMEGEN_SITES, "wallpaper64"),
            "종전 문면과의 관계": "docs/re/scheme-color.md §2 는 이 경로를 에디터 JS "
                              "`getDominantColorFromFile` 로만 인용했다. 네이티브에도 있다",
        }, "확정", [engine_ev, scr_ev]),

        specfmt.entry("dominantColor.mediaThumbnailColors", {
            "필드": [{"이름": n, "오프셋": o, "읽는 자리": va} for n, o, va in MEDIA_COLOR_FIELDS],
            "게이트": "이벤트 빌더가 `test byte [r14], 2` (0x14011c4e7) 로 색 블록을 켠다",
            "wallpaper64.exe 안의 자리 전수": stores,
            "그물 설계": "`.pdata` 전 함수 선형 디스어셈 → 다섯 변위로 가는 **스택 아닌** "
                      "dword 스토어(mov/movss)를 전수로 세고, 한 함수가 다섯 중 **넷 이상**을 "
                      "쓰는 경우만 후보로 남긴다(연속 dword 다섯을 채우는 계산 자리라면 반드시 걸린다)",
            "판정": "후보 다섯 함수 중 넷(0x140058c15 · 0x1401dd630 · 0x1401de962 · 0x1401df620)은 "
                   "전건 `movss` 로 **float** 다섯 개를 쓴다 — uint32 색이 아니다. 남은 하나 "
                   "0x1400d834f 는 `[rdi + r9 + 0x150]` 처럼 **런타임 베이스**를 더한 4×4 행렬 "
                   "복사이고 같은 함수가 +0x108…+0x17c 를 0x10 간격으로 채운다. "
                   "미디어 구조체 자신을 만지는 자리는 생성자의 0 초기화(0x1400c1402 qword · "
                   "0x1400c1409 qword · 0x1400c1413 dword)와 복사 생성자(0x1400c2422–0x1400c2454) "
                   "뿐이다 — **이 이미지에는 다섯 색을 계산하는 자리가 없다**",
            "생성자 기본값": "다섯 색 전부 0, `+0x174`(enabled) 만 1 (0x1400c1428)",
            "교차 근거": {"wallpaper64.exe": winrt_in_engine, "bin/winrtutil64.exe": winrt_in_helper},
            "그래서 어디에 있나": "WinRT 미디어 세션 문자열이 `bin/winrtutil64.exe` 에만 있다"
                            "(그 실행 파일은 OpenCV·FreeImage 를 링크한다). 다섯 색은 그 프로세스에서 "
                            "만들어져 IPC 로 건너온다 — **[미해결]** 정확한 산식은 아직 안 떴다",
            "GetDominantColor 로 채울 수 없다": "그 함수는 색을 **하나만** 낸다. "
                                          "secondary/tertiary/text/highContrast 대응물이 없다",
        }, "확정", [media_ev, scr_ev, src_ev]),

        specfmt.entry("dominantColor.schemecolorCorpus", {
            "동봉": schemecolor_corpus(WEASSETS, "동봉 Sources/WapleRender/Resources/WEAssets"),
            "설치본": schemecolor_corpus(WE_ROOT, "설치본 wallpaper_engine"),
            "형식": '"r g b" 0–1 부동소수 3성분, 스페이스 구분, 감마 변환 없음',
            "Waple 처리": "제네릭 사용자 속성으로 원문 보존 — 배선하지 않는다"
                       "(docs/re/scheme-color.md §7)",
        }, "확정", [specfmt.ev("asset", "Sources/WapleRender/Resources/WEAssets/**/project.json"),
                   specfmt.ev("asset", "WE_ROOT/**/project.json"), scr_ev]),
    ]


def main():
    for p, why in ((ENGINE, "WE_ROOT/wallpaper64.exe"),
                   (RESUTIL, "WE_ROOT/bin/resourceutil64.dll"),
                   (WINRT, "WE_ROOT/bin/winrtutil64.exe")):
        if not p or not os.path.exists(p):
            raise SystemExit(
                "%s 를 찾지 못했다: %r\n"
                "상수 적재 자리와 부재 증명은 이미지 전수 스캔이라 부분 산출을 만들지 않는다 — "
                "WE_ROOT 를 주고 다시 돌려라." % (why, p or "<WE_ROOT 미설정>"))
    engine, resutil = PE(ENGINE), PE(RESUTIL)
    entries = build(engine, resutil)
    specfmt.dump(specfmt.doc("scripts/spec/measure_dominant_color.py", entries), OUT)
    print("%s: %d 항목" % (OUT, len(entries)))


if __name__ == "__main__":
    main()
