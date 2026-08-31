"""wallpaper64.exe 에서 엔진 심볼(g_* 유니폼, _rt_* 렌더타깃)을 뽑는다.

PE 파일을 직접 스캔한다. Ghidra 를 거치지 않는 이유는 재현성이다 —
이 스크립트는 WE 설치본만 있으면 어디서든 돈다.

VA(가상주소)를 함께 남기는 이유: 나중에 Ghidra 에서 "이 심볼을 어느 함수가
참조하는가" 로 확장할 때의 진입점이 된다.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.path.join(WE, "wallpaper64.exe")

UNIFORM = re.compile(rb"g_[A-Z][A-Za-z0-9_]{2,40}")
RT = re.compile(rb"(?:_rt_|_alias_)[A-Za-z0-9_]{2,40}")

# 유니폼 **테이블**의 원소 수는 문자열 스캔으로 알 수 없다 — 스캔은 자산 쪽 이름까지 쓸어온다.
# 등록 함수 꼬리가 배열 전체를 소멸시키는 호출에서 원소 수와 stride 를 직접 못박는다:
#
#     0x1400042f8  ba 28 00 00 00        mov edx, 0x28        ; stride = 40 B
#     0x1400042fd  41 b8 8c 00 00 00     mov r8d, 0x8c        ; 원소 수 = 140
#     0x140004303  48 8d 4d 10           lea rcx, [rbp+0x10]  ; 배열 베이스
#     0x140004307  e8 ..                 call __ehvec_dtor
#
# 함정 ④("호출 지점이 아니라 `mov r9d, imm` 을 세라")가 정확히 이 자리다.
# 주소를 고정하되 **앞 7바이트를 대조**해 바이너리가 바뀌면 조용히 틀린 수를 내지 않고 죽는다.
TABLE_DTOR_VA = 0x1400042F8
TABLE_DTOR_PREFIX = bytes.fromhex("ba28000000" "41b8")   # mov edx,0x28 ; mov r8d,imm32
TABLE_STRIDE = 0x28


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
        secs.append((name, rawptr, rawptr + rawsize, base + vaddr))
    return secs


def va_of(off, secs):
    for name, s, e, va in secs:
        if s <= off < e:
            return va + (off - s), name
    return None, None


def off_of(va, secs):
    for _name, s, e, base in secs:
        if base <= va < base + (e - s):
            return s + (va - base)
    return None


def table_count(data, secs):
    """등록 함수 꼬리의 `mov r8d, imm32` 에서 유니폼 테이블 원소 수를 **직접** 읽는다."""
    off = off_of(TABLE_DTOR_VA, secs)
    if off is None:
        raise SystemExit(f"유니폼 테이블 소멸 호출 VA {TABLE_DTOR_VA:#x} 를 파일에서 못 찾았다")
    got = data[off:off + len(TABLE_DTOR_PREFIX)]
    if got != TABLE_DTOR_PREFIX:
        raise SystemExit(
            f"{TABLE_DTOR_VA:#x} 의 바이트가 기대와 다르다 — 바이너리가 바뀌었다.\n"
            f"  기대 {TABLE_DTOR_PREFIX.hex()} / 실제 {got.hex()}\n"
            f"  이 자리는 `mov edx,0x28; mov r8d,<원소수>` 여야 한다. 재확인 없이 수치를 쓰지 마라.")
    return struct.unpack_from("<I", data, off + len(TABLE_DTOR_PREFIX))[0]


def collect_symbols(data, secs, rx):
    """문자열 심볼과 VA를 모으되 NUL 종료 **맨 이름** 좌표를 우선한다.

    같은 이름이 셰이더 선언 조각(`g_Bones[`)과 엔진 등록 테이블의 C 문자열
    (`g_Bones\0`) 양쪽에 존재한다. 종전의 "첫 등장" 규칙은 배열 유니폼 16종을 전부
    선언 조각으로 보냈다. 맨 이름이 없는 `g_Texture([\\d]+)` 한 건만 embeddedToken 으로
    명시해, 좌표 의미가 나머지 143종과 다른 사실을 숨기지 않는다.
    """
    chosen = {}
    for match in rx.finditer(data):
        name = match.group().decode("ascii")
        exact = data[match.end():match.end() + 1] == b"\0"
        previous = chosen.get(name)
        if previous is not None and (previous[0] or not exact):
            continue
        va, section = va_of(match.start(), secs)
        chosen[name] = (exact, va, section)

    out = {}
    for name, (exact, va, section) in chosen.items():
        row = {"va": hex(va) if va else None, "section": section}
        if not exact:
            row["coordinateKind"] = "embeddedToken"
        out[name] = row
    return out


def main():
    specfmt.require_inputs("measure_engine_symbols",
                           ("file", BIN, "WE_ROOT", "wallpaper64.exe"))
    with open(BIN, "rb") as fh:
        data = fh.read()
    secs = section_map(data)

    uniforms = collect_symbols(data, secs, UNIFORM)
    rts = collect_symbols(data, secs, RT)
    n_table = table_count(data, secs)

    src = specfmt.ev("binary", "wallpaper64.exe 문자열 전수 스캔 (PE 섹션 매핑 포함)")
    src_tbl = specfmt.ev("binary", f"wallpaper64.exe {TABLE_DTOR_VA:#x}",
                         "등록 함수 꼬리의 `mov edx,0x28`(stride) + `mov r8d,imm32`(원소 수). "
                         "앞 7바이트 대조로 자기검증한다")

    # 자산 쪽 이름 — 엔진 유니폼 테이블에 없고 셰이더 자산이 자기 이름으로 선언한 것들.
    # 문자열 스캔은 이것들을 구분할 수 없다(그게 스캔의 한계다).
    asset_side = sorted(n for n in uniforms
                        if n in ("g_Texture", "g_Texture0MipMapped", "g_Texture1Noise",
                                 "g_Texture2Clouds"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.uniforms.count", n_table, "확정", [src_tbl]),
        specfmt.entry("engine.uniforms.stringScan", {
            "count": len(uniforms),
            "무엇을 재는가": "바이너리 어디든 나타나는 `g_[A-Z]…` 문자열의 고유 개수. "
                            "**엔진 유니폼 테이블의 원소 수가 아니다** — 자산(셰이더)이 선언한 "
                            "이름까지 쓸어온다.",
            "테이블과의 차": len(uniforms) - n_table,
            "VA 좌표 규약": "같은 이름의 후보가 여럿이면 NUL 종료 맨 이름 문자열을 우선한다. "
                         "맨 이름이 바이너리에 없는 g_Texture 한 건만 정규식 소스 조각 좌표이며 "
                         "coordinateKind=embeddedToken 으로 표시한다.",
            "자산 쪽으로 확인된 이름": asset_side,
            "확인 근거": "g_Texture0MipMapped / g_Texture1Noise / g_Texture2Clouds 는 "
                        "assets/shaders/HLSL/dx11playlisttransition.frag:18-20 의 "
                        "`Texture2D … :register(tN)` 선언이다(재생목록 전환 셰이더). "
                        "g_Texture 는 샘플러 어노테이션 정규식 "
                        "`^uniform[\\s]+(sampler[\\w]*)[\\s]+g_Texture([\\d]+)` 의 접두사로, "
                        "동봉 셰이더 68파일에 등장한다.",
            "[2026-08-20 정정]": "종전 `engine.uniforms.count` 가 이 스캔 결과(=%d)를 "
                                 "테이블 원소 수로 기록하고 있었다. 근거란도 '문자열 전수 스캔' "
                                 "이라고 정직하게 적혀 있었는데, id 가 count 라 그 구분이 "
                                 "읽는 쪽에 전달되지 않았다." % len(uniforms),
        }, "확정", [src, src_tbl]),
        specfmt.entry("engine.uniforms", dict(sorted(uniforms.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "uniforms.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.renderTargets.count", len(rts), "확정", [src]),
        specfmt.entry("engine.renderTargets", dict(sorted(rts.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "render-targets.json"))

    print(f"유니폼 테이블 {n_table}종 · g_* 문자열 스캔 {len(uniforms)}종"
          f"(차 {len(uniforms) - n_table}: {asset_side}) · 렌더타깃 {len(rts)}종")
    for k in sorted(rts):
        print(f"  {k}")


if __name__ == "__main__":
    main()
