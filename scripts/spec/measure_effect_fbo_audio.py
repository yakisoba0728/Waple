"""effect.json FBO 규약과 오디오 스펙트럼 파이프라인을 wallpaper64.exe 에서 뽑는다.

왜 이 문서가 따로 있는가
------------------------
2026-08-20 라운드에서 Waple 의 두 축(멀티패스 이펙트의 렌더 타깃, 64밴드 오디오)을
원본 디스어셈블로 다시 확정했다. 그 과정에서 **리포의 기존 추정 셋이 뒤집혔다**:

  · effect.json `fbos[].format` 은 5종이 아니라 **21종**이다(해시맵 19 + strcmp 로 가로채는
    백버퍼 별칭 2).
  · `clear` 는 1/3/4 성분을 받는 게 아니라 **스페이스 구분 정확히 4성분**만 받고,
    **빈 문자열은 (0,0,0,0) 으로 클리어한다**(종전 구현은 정반대로 무시했다).
  · 씬 패스 오버라이드는 셰이더 패스 순번이 아니라 **원본 배열 인덱스**로 정렬된다.

그리고 오디오는 네 군데가 전부 달랐다(밴드 매핑·축약·틸트·게인).

재현 범위에 대한 정직한 선언
----------------------------
이 스크립트가 **바이트에서 직접 재현하는 것만 `확정`** 이다:

  · enum → DXGI 점프 테이블 28개 (`0x1400d2aa4`) — 각 arm 의 `mov eax, imm32` 를 읽는다
  · 포맷 문자열 21종의 `.rdata` 실재
  · AudioProcessor 생성자의 float 즉시값 4개 (지수·틸트상수·FFT계수·빈계수)
  · `maxss`(밴드 축약이 평균이 아님)·HDR 분기·enum 선택의 명령 바이트

**이름 → enum 값 대응(19쌍)은 `보고`** 다. 그 표는 `0x1401e53a0` 이 만드는 해시맵의
initializer_list 를 스택 스토어 에뮬레이션으로 복원해야 나오는데, 이 스크립트는 그걸 하지
않는다. 실제로 재현을 두 번 시도해 둘 다 실패했다 — 문자열이 `lea [rip+…]` 로도, 코드 안
즉시값으로도 안 나온다(MSVC `std::string` SSO 경로가 다른 형태로 채운다). 재현 못 한 것을
확정으로 적으면 이 리포가 계속 싸워 온 "검사하는 척하는 검사" 와 같은 종류의 거짓이 된다.

바이너리가 없으면 기존 산출물을 이어받는다 — 측정할 수 없다는 것이 근거가 틀렸다는 뜻은
아니다(`measure_mul_convention.carry_forward` 와 같은 규약).
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "spec", "engine", "effect-fbo-audio.json")

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
CANDIDATES = [
    os.path.join(WE, "wallpaper64.exe"),
    "/home/user/Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe",
    os.path.join(REPO, "..", "Waple-wallpaper-source", "wallpaper_engine", "wallpaper64.exe"),
]

# 원본 VA. Ghidra 코퍼스는 +0xD0 오프셋이지만 아래는 전부 **원본** 주소다
# (spec/engine/decompilation-provenance.json 의 규약과 같다).
VA_DXGI_JUMPTABLE = 0x1400D2AA4     # 28-way, enum → DXGI 상수
VA_DXGI_DISPATCH = 0x1400D2A20      # 그 테이블을 쓰는 함수
VA_FORMAT_MAP_FN = 0x1401E53A0      # 문자열 → enum 해시맵 생성 함수
VA_EFFECT_PARSER = 0x1401E7170      # effect.json 파서
VA_AUDIO_THREAD = 0x1400D02B0       # 캡처/FFT 스레드 본체
VA_AP_CTOR = 0x1400C0C80            # AudioProcessor 를 품는 객체의 생성자

AP_CONSTANTS = [
    (0x1400C0D59, "exponent", 0.25, "AudioProcessor+0xE4 — 밴드 매핑 지수"),
    (0x1400C0D63, "tiltC", 0.50099998712539673, "AudioProcessor+0xE8 — 스펙트럴 틸트 상수"),
    (0x1400C0D6D, "fftLengthFactor", 30.0, "AudioProcessor+0xEC — FFT 길이 계수"),
    (0x1400C0D77, "binCountFactor", 10.0, "AudioProcessor+0xF0 — 사용 빈 개수 계수"),
]

BYTE_CHECKS = [
    (0x1400D1D04, "f30f5fc8", "밴드 축약이 `maxss` — 평균이 아니라 최댓값"),
    (0x1401E7586, "81e100200000", "`and ecx, 0x2000` — 백버퍼 포맷의 HDR 비트 검사"),
    (0x1401E7590, "83e00e", "`and eax, 0xe` — HDR 이면 enum 14(rgba16161616f), 아니면 0"),
]

FORMAT_STRINGS = [
    "rgba8888", "rgb888", "rg88", "r8", "rgb565", "bc7", "dxt5", "dxt3", "dxt1",
    "rgba16161616f", "rgb161616f", "rg1616f", "r16f", "rgba16161616", "rgb161616",
    "rgba16161616S", "rgb161616S", "rgba8888s", "rgba1010102",
    "rgba_backbuffer", "rgb_backbuffer",
]

# `보고` 등급 — 아래 주석 참조. 이 스크립트는 이 대응을 재현하지 않는다.
REPORTED_NAME_TO_ENUM = {
    "rgba8888": 0, "rgb888": 1, "rg88": 8, "r8": 9, "rgb565": 2, "bc7": 12,
    "dxt5": 4, "dxt3": 6, "dxt1": 7, "rgba16161616f": 14, "rgb161616f": 15,
    "rg1616f": 10, "r16f": 11, "rgba16161616": 17, "rgb161616": 18,
    "rgba16161616S": 19, "rgb161616S": 20, "rgba8888s": 21, "rgba1010102": 13,
}

DXGI_NAMES = {
    10: "R16G16B16A16_FLOAT", 11: "R16G16B16A16_UNORM", 13: "R16G16B16A16_SNORM",
    24: "R10G10B10A2_UNORM", 28: "R8G8B8A8_UNORM", 34: "R16G16_FLOAT",
    39: "R32_TYPELESS", 40: "D32_FLOAT", 41: "R32_FLOAT", 49: "R8G8_UNORM",
    54: "R16_FLOAT", 55: "D16_UNORM", 61: "R8_UNORM", 71: "BC1_UNORM",
    74: "BC2_UNORM", 77: "BC3_UNORM", 98: "BC7_UNORM",
}


class PE:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        d = self.data
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        coff = pe + 4
        nsec = struct.unpack_from("<H", d, coff + 2)[0]
        opt_size = struct.unpack_from("<H", d, coff + 16)[0]
        opt = coff + 20
        pe32plus = struct.unpack_from("<H", d, opt)[0] == 0x20B
        self.base = (struct.unpack_from("<Q", d, opt + 24)[0] if pe32plus
                     else struct.unpack_from("<I", d, opt + 28)[0])
        self.secs = []
        for i in range(nsec):
            b = opt + opt_size + i * 40
            name = d[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
            vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", d, b + 8)
            self.secs.append((name, vaddr, vsize, rawptr, rawsize))

    def off(self, va):
        rva = va - self.base
        for _n, vaddr, vsize, rawptr, rawsize in self.secs:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        raise ValueError(f"VA {va:#x} 가 어느 섹션에도 없다")

    def section(self, name):
        for s in self.secs:
            if s[0] == name:
                return s
        raise ValueError(f"섹션 {name} 없음")

    def movimm_float(self, va):
        """`[REX] C7 /0 disp imm32` 의 imm32 를 float 로 읽는다."""
        i = self.off(va)
        if self.data[i] & 0xF0 == 0x40:
            i += 1                                    # REX 접두
        if self.data[i] != 0xC7:
            raise ValueError(f"VA {va:#x} 가 `mov r/m, imm32` 가 아니다 (opcode {self.data[i]:#x})")
        i += 1
        modrm = self.data[i]
        i += 1
        mod, rm = modrm >> 6, modrm & 7
        if rm == 4:
            i += 1                                    # SIB
        if mod == 1:
            i += 1
        elif mod == 2:
            i += 4
        return struct.unpack_from("<f", self.data, i)[0]


def find_binary():
    for p in CANDIDATES:
        if os.path.isfile(p):
            return p
    return None


def carry_forward():
    """바이너리가 없을 때 기존 산출물을 그대로 이어받는다(근거 보존)."""
    if not os.path.isfile(OUT):
        return None
    try:
        return json.load(open(OUT, encoding="utf-8"))
    except (OSError, ValueError):
        return None


def measure(pe):
    entries = []
    S = specfmt.ev("script", "scripts/spec/measure_effect_fbo_audio.py")

    # ── enum → DXGI 점프 테이블 (직접 재현) ─────────────────────────────────
    table = {}
    o = pe.off(VA_DXGI_JUMPTABLE)
    for i in range(28):
        arm_rva = struct.unpack_from("<i", pe.data, o + 4 * i)[0]
        arm = pe.base + arm_rva
        ao = pe.off(arm)
        if pe.data[ao] != 0xB8:                       # mov eax, imm32
            table[i] = None
            continue
        table[i] = struct.unpack_from("<I", pe.data, ao + 1)[0]
    entries.append(specfmt.entry(
        "effect.fbo.enumToDXGI",
        {str(k): {"dxgi": v, "name": DXGI_NAMES.get(v)} for k, v in table.items()},
        "확정",
        [specfmt.ev("binary",
                    f"wallpaper64.exe {VA_DXGI_DISPATCH:#x} 의 28-way 점프 테이블 {VA_DXGI_JUMPTABLE:#x} — "
                    f"각 arm 의 `mov eax, imm32` 를 직접 읽는다"),
         specfmt.ev("binary",
                    "sRGB 경로 부재의 근거이기도 하다 — 28개 arm 중 DXGI 29/72/75/78/99(_SRGB) 가 0건"),
         S]))

    # ── 포맷 문자열 실재 (직접 재현) ────────────────────────────────────────
    _n, rva, _vs, rawptr, rawsize = pe.section(".rdata")
    blob = pe.data[rawptr:rawptr + rawsize]
    present, missing = {}, []
    for s in FORMAT_STRINGS:
        idx = blob.find(s.encode() + b"\0")
        if idx < 0:
            missing.append(s)
        else:
            present[s] = hex(pe.base + rva + idx)
    if missing:
        raise SystemExit(f"[measure_effect_fbo_audio] 포맷 문자열이 .rdata 에 없다: {missing}\n"
                         f"  바이너리 버전이 다르거나 이 목록이 낡았다 — 확인 전엔 정본을 갱신하지 않는다.")
    entries.append(specfmt.entry(
        "effect.fbo.formatStrings", present, "확정",
        [specfmt.ev("binary", ".rdata 전수 스캔 — 21종 전건 실재(부재 0)"),
         specfmt.ev("asset",
                    "동봉 WEAssets 의 effect.json 128개에서 실제로 쓰이는 것은 5종뿐: "
                    "rgba8888 28 · rgba_backbuffer 13 · r16f 8 · rg1616f 4 · r8 2 (합 55 = fbo 선언 전건)"),
         S]))

    # ── 이름 → enum (재현 안 함: 보고) ──────────────────────────────────────
    entries.append(specfmt.entry(
        "effect.fbo.nameToEnum", dict(REPORTED_NAME_TO_ENUM), "보고",
        [specfmt.ev("binary",
                    f"{VA_FORMAT_MAP_FN:#x} 이 magic-static 으로 만드는 FNV-1a 해시맵. 엔트리 19개 근거는 "
                    f"소멸자 루프 `mov ebx, 0x13`(=19회)와 initializer_list 크기 760 = 19 × 40"),
         specfmt.ev("binary",
                    "미스 시 0(rgba8888) 폴백 — 알 수 없는 문자열은 에러가 아니다"),
         specfmt.ev("doc",
                    "**이 스크립트는 이 대응을 재현하지 않는다.** 스택 스토어 에뮬레이션이 필요하다. "
                    "재현을 두 번 시도해 둘 다 실패했다 — 문자열이 `lea [rip+…]` 로도 코드 내 즉시값으로도 "
                    "나오지 않는다(MSVC std::string SSO 경로). 그래서 확정이 아니라 보고다.")]))

    # ── 백버퍼 별칭 (직접 재현한 바이트 + 보고된 의미) ──────────────────────
    entries.append(specfmt.entry(
        "effect.fbo.backbufferAlias",
        {"rgba_backbuffer": "HDR 이면 enum 14(rgba16161616f), 아니면 enum 0(rgba8888)",
         "rgb_backbuffer": "HDR 이면 enum 15(rgb161616f), 아니면 enum 1(rgb888)",
         "note": "해시맵에 없다 — 파서가 조회 **전에** strcmp 로 가로챈다. 최종 DXGI 는 두 쌍이 각각 10 / 28 로 같다"},
        "확정",
        [specfmt.ev("binary", f"{0x1401E7562:#x} strcmp(\"rgba_backbuffer\") · {0x1401E759E:#x} strcmp(\"rgb_backbuffer\")"),
         specfmt.ev("binary", f"{0x1401E7586:#x} `and ecx, 0x2000`(HDR 비트) → {0x1401E7590:#x} `and eax, 0xe`"),
         S]))

    # ── 명령 바이트 검사 (직접 재현) ────────────────────────────────────────
    checks = {}
    for va, expect, why in BYTE_CHECKS:
        o = pe.off(va)
        got = pe.data[o:o + len(expect) // 2].hex()
        if got != expect:
            raise SystemExit(f"[measure_effect_fbo_audio] {va:#x} 의 바이트가 {got} 인데 {expect} 를 기대했다.\n"
                             f"  ({why})\n"
                             f"  바이너리가 다르거나 주소가 낡았다 — 조용히 다른 값을 확정으로 커밋하지 않으려고 멈춘다.")
        checks[hex(va)] = {"bytes": got, "meaning": why}
    entries.append(specfmt.entry(
        "engine.audio.instructionAnchors", checks, "확정",
        [specfmt.ev("binary", "각 VA 의 원시 바이트를 직접 대조 — 불일치 시 하드 실패"), S]))

    # ── 오디오 상수 (직접 재현) ─────────────────────────────────────────────
    consts = {}
    for va, key, expect, why in AP_CONSTANTS:
        got = pe.movimm_float(va)
        if abs(got - expect) > 1e-9 * max(1.0, abs(expect)):
            raise SystemExit(f"[measure_effect_fbo_audio] {key} 가 {got} 인데 {expect} 를 기대했다 ({va:#x}).")
        consts[key] = {"value": got, "site": hex(va), "why": why}
    entries.append(specfmt.entry(
        "engine.audio.processorConstants", consts, "확정",
        [specfmt.ev("binary", f"{VA_AP_CTOR:#x} 생성자의 `mov [reg+off], imm32` 즉시값을 float 로 읽는다"),
         specfmt.ev("binary",
                    "이 네 필드는 생성자 말고는 바이너리 어디에서도 기록되지 않는다 — 씬 프로퍼티 "
                    "`audioprocessingexponent` 는 프로젝트 JSON 기본값 작성기에만 나오고 이 경로에 도달하지 않는다"),
         S]))

    # ── 파이프라인 (수식은 보고, 상수는 위에서 확정) ────────────────────────
    entries.append(specfmt.entry(
        "engine.audio.pipeline",
        {"fftLength": "N = int(max(rate/44100, 1) × 64 × 30)  — 44.1kHz 에서 1920",
         "binCount": "B = int(64 × 10) = 640, 샘플레이트 무관 고정",
         "window": "N − int(N × 10/30), 오버랩 없음, 나머지는 제로패딩 — 1920 → 1280",
         "design": "N 을 레이트에 비례시키고 B 를 고정해 **빈 폭 ≈22.97 Hz · 상한 ≈14677 Hz** 를 고정한다",
         "timeWindow": "없음(사각창). 샘플별 곱셈은 상수 127 하나뿐",
         "bandMapping": "band(i) = min(int(powf((i−1)/(B−1), 0.25) × 64) % 64, prev+1), i = 1..B−1",
         "oneToOneBands": "하위 29밴드가 빈 1:1 — 별도 선형 구간이 아니라 prev+1 클램프의 결과",
         "tilt": "w = C − (1−C)·cos(π·t), t = (i−1)/(B−1) — **빈 인덱스**이지 밴드 인덱스가 아니다. 진폭에 sqrt(w)",
         "tiltRatio": "최저↔최고 감쇠비 sqrt(1.0)/sqrt(0.002) = 22.3608 — 원본은 저역을 깎는다",
         "reduction": "밴드 내 MAX(평균 아님)",
         "gain": "162.56 = 127 × 0.001 × 2 × 640, 1/N 정규화 진폭 기준. 축약 뒤 맨 마지막에 일괄",
         "smoothing": "생산 단계에 없음 — 매 프레임 밴드 배열을 0 으로 시작해 재계산"},
        "보고",
        [specfmt.ev("binary", f"{VA_AUDIO_THREAD:#x} 오디오 스레드 본체(7,783 B) 디스어셈블"),
         specfmt.ev("binary", f"밴드 매핑 {0x1400D1C7A:#x}-{0x1400D1CC7:#x} · 틸트 {0x1400D1CB0:#x}-{0x1400D1CEE:#x} · "
                              f"게인 {0x1400D1D2C:#x}-{0x1400D1D70:#x}"),
         specfmt.ev("doc",
                    "상수 넷과 `maxss` 는 위 두 항목에서 확정으로 재현했다. 수식 자체는 명령 흐름 해석이라 "
                    "이 스크립트가 재현하지 않으므로 보고로 둔다.")]))

    # ── 파서 규약 (보고) ────────────────────────────────────────────────────
    entries.append(specfmt.entry(
        "effect.parser.conventions",
        {"fboRequiredKeys": "`name` 과 `format` 이 **둘 다 문자열**이어야 한다 — 아니면 그 fbo 선언을 통째로 버린다",
         "fboFlags": "bit0 = unique(JSON boolean) · bit1 = clear(4성분 파스 성공) · bit2 = uvs == \"repeat\"",
         "clearFormat": "스페이스(0x20) 구분 **정확히 4성분**. 콤마·탭은 구분자가 아니다. "
                        "성분이 모자라면 clear 비트가 안 선다. **빈 문자열은 (0,0,0,0) 으로 클리어**",
         "clearTiming": "렌더 타깃 획득 경로에서 1회 — 매 프레임이 아니다(프레임 렌더 함수는 flags 를 읽지 않는다)",
         "uniqueSemantics": "캐시 키가 `<name>_<effectInstanceId>`(치수 접미사 없음) — 인스턴스 전용·프레임 간 지속. "
                            "비-unique 는 `<name>_<W>_<H>` 로 이펙트 간 공유(refcount)",
         "scenePassIndex": "씬의 `effects[].passes[]` 오버라이드는 매니페스트 `passes[]` 의 **원본 배열 인덱스**로 "
                           "정렬된다 — 명령 패스도 슬롯을 하나 소비하고, 범위 밖은 오류가 아니라 오버라이드 없음",
         "conditionsOps": "명명 연산자는 ge/gt/le/lt **4종뿐**이고 형태는 {COMBO:{op,value}}. "
                          "op 가 없거나 미지면 **등호 폴백**(false 고정이 아니다)",
         "conditionsAccum": "객체 내 키끼리 AND, 배열 원소끼리 AND. 빈 배열·비배열·키 부재는 전부 **true**(fail-open)",
         "conditionsLHS": "이펙트 **인스턴스** 레벨 `combos`(씬의 objects[].effects[i].combos). "
                          "동봉 자산에는 0건이라 실측상 전부 0 이다 — 패스 레벨 combos 와 다른 것이다",
         "conditionsFalse": "fbo → 생성 안 함(벡터 압축, 참조는 전부 이름 기반이라 안 어긋남) · "
                            "pass → 통째로 스킵(단 인덱스는 증가) · bind → 그 슬롯만 언바인드(패스는 실행)"},
        "보고",
        [specfmt.ev("binary", f"{VA_EFFECT_PARSER:#x} effect.json 파서(6,445 B) 디스어셈블"),
         specfmt.ev("binary", f"conditions 평가기 {0x1401E63B0:#x}(1,478 B) — 반환 TRUE 경로는 "
                              f"{0x1401E63D1:#x}(비배열)와 {0x1401E6412:#x}(빈 배열) 둘뿐"),
         specfmt.ev("asset",
                    "동봉 자산 대조: fbo 선언 55/55 가 format 보유 · clear 12건 전건이 동시에 unique · "
                    "conditions 는 fluidsimulation 2파일에만 8건")]))

    return entries


def main():
    path = find_binary()
    if path is None:
        prior = carry_forward()
        if prior is None:
            raise SystemExit(f"[measure_effect_fbo_audio] wallpaper64.exe 를 못 찾았고 "
                             f"이어받을 기존 산출물도 없다.\n  WE_ROOT 를 설정하거나 {CANDIDATES[1]} 에 두어라.")
        print("  ⚠️ wallpaper64.exe 없음 — 기존 산출물을 그대로 이어받는다(근거 보존)", file=sys.stderr)
        specfmt.dump(prior, OUT)
        print(f"이펙트 FBO · 오디오 → {os.path.relpath(OUT, REPO)} (이어받음)")
        return

    pe = PE(path)
    entries = measure(pe)
    specfmt.dump(specfmt.doc("scripts/spec/measure_effect_fbo_audio.py", entries), OUT)
    print(f"이펙트 FBO · 오디오 → {os.path.relpath(OUT, REPO)}")
    print(f"  바이너리 {path}")
    print(f"  항목 {len(entries)}개 (확정 {sum(1 for e in entries if e['status'] == '확정')} / "
          f"보고 {sum(1 for e in entries if e['status'] == '보고')})")


if __name__ == "__main__":
    main()
