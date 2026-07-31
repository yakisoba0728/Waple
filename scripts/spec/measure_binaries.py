"""WE 바이너리의 PE 구조를 stdlib 로 직접 읽어 정본을 만든다.

pefile 을 쓰지 않는 이유: AGENTS.md 의 "외부 패키지 의존은 0" 원칙을
도구에도 적용한다. PE 임포트 테이블 파싱은 struct 로 충분하다.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

TARGETS = [
    ("wallpaper64.exe", "렌더러 본체"),
    ("bin/scenescript64.dll", "스크립트 엔진(V8 정적링크)"),
    ("bin/mediaextensions64.dll", "미디어 파이프라인"),
    ("bin/resourcecompiler64.exe", "에셋 컴파일러"),
    ("bin/resourceutil64.dll", "리소스 유틸"),
    ("bin/cloneextensions64.dll", "화면 클론"),
    ("bin/webwallpaper64.exe", "웹 배경 호스트"),
    ("bin/wallpaperui.exe", "UI — 엔진 무관, 분석 제외 대상"),
]


def read_pe(path):
    """섹션 표와 임포트 DLL 목록을 반환. 실패 시 None."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:2] != b"MZ":
        return None
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        return None
    coff = pe_off + 4
    machine = struct.unpack_from("<H", data, coff)[0]
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    pe32plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    image_base = (struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus
                  else struct.unpack_from("<I", data, opt + 28)[0])
    # 데이터 디렉터리: PE32+ 는 opt+112, PE32 는 opt+96. 두 번째 항목이 임포트.
    dd = opt + (112 if pe32plus else 96)
    import_rva = struct.unpack_from("<I", data, dd + 8)[0]

    sec_off = opt + opt_size
    sections = []
    for i in range(nsec):
        b = sec_off + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        sections.append({"name": name, "vsize": vsize, "vaddr": vaddr,
                         "rawsize": rawsize, "rawptr": rawptr})

    def rva_to_off(rva):
        for s in sections:
            if s["vaddr"] <= rva < s["vaddr"] + max(s["vsize"], s["rawsize"]):
                return s["rawptr"] + (rva - s["vaddr"])
        return None

    dlls = []
    if import_rva:
        off = rva_to_off(import_rva)
        if off is not None:
            while True:
                desc = data[off:off + 20]
                if len(desc) < 20 or desc == b"\0" * 20:
                    break
                name_rva = struct.unpack_from("<I", desc, 12)[0]
                no = rva_to_off(name_rva)
                if no is None:
                    break
                try:
                    end = data.index(b"\0", no)
                except ValueError:
                    break
                dlls.append(data[no:end].decode("ascii", "ignore"))
                off += 20

    code = sum(s["vsize"] for s in sections if s["name"] in (".text", "CODE"))
    return {"machine": machine, "imageBase": image_base, "sections": sections,
            "codeBytes": code, "importedDLLs": sorted(set(dlls)), "fileBytes": len(data)}


def main():
    entries = []
    for rel, note in TARGETS:
        path = os.path.join(WE, rel.replace("/", os.sep))
        if not os.path.exists(path):
            print(f"  건너뜀(없음): {rel}")
            continue
        pe = read_pe(path)
        if pe is None:
            print(f"  건너뜀(PE 아님): {rel}")
            continue
        base = f"binary.{os.path.basename(rel)}"
        src = specfmt.ev("binary", f"{rel} (WE 2.8.42 설치본)", note)
        entries.append(specfmt.entry(f"{base}.fileBytes", pe["fileBytes"], "확정", [src]))
        entries.append(specfmt.entry(f"{base}.codeBytes", pe["codeBytes"], "확정", [src]))
        entries.append(specfmt.entry(f"{base}.importedDLLs", pe["importedDLLs"], "확정", [src]))
        entries.append(specfmt.entry(
            f"{base}.sections",
            [{"name": s["name"], "vsize": s["vsize"]} for s in pe["sections"]],
            "확정", [src]))
        print(f"  {rel:34} code={pe['codeBytes'] // 1024:>7} KB  imports={len(pe['importedDLLs'])}")

    d = specfmt.doc("scripts/spec/measure_binaries.py", entries, extra={
        "note": "wallpaperui.exe 는 UI 라 엔진 분석 대상이 아니다. 크기 비교용으로만 기록한다.",
    })
    out = os.path.join("spec", "binaries.json")
    specfmt.dump(d, out)
    print(f"\n{out} — {len(entries)} 항목")


if __name__ == "__main__":
    main()
