"""spec 정본이 인용하는 WE 바이너리 8종의 지문을 남긴다.

## 왜 필요한가

`spec/` 정본은 WE 바이너리를 **273회** 인용한다. 그런데 지문(sha256)이 남아 있던 것은
`wallpaper64.exe` 하나뿐이었다(`spec/engine/decompilation-provenance.json`).

    wallpaper64.exe        189회      scenescript64.dll       31회
    mediaextensions64.dll   14회      wallpaperui.exe         13회
    resourcecompiler64.exe  12회      webwallpaper64.exe       6회
    resourceutil64.dll       4회      cloneextensions64.dll    4회

이 바이너리들은 분석 리포(`Waple-wallpaper-source`)의 `wallpaper_engine/` 아래에만 있고,
그 리포는 삭제 예정이다. 삭제되면 **확정 등급인데 근거를 대조할 수단이 없는 항목**이 남는다.

`validate.py` 의 근거 실재 검사는 리포 **밖** 경로를 검사 대상에서 빼므로(머신마다 다르니
정당한 설계다) 이 부류를 영원히 못 잡는다. 그래서 사람이 명시적으로 박제해야 한다.

바이너리 자체는 커밋하지 않는다 — 독점 소프트웨어다. 지문만 남긴다.

## 재실행

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_we_binaries_fingerprint.py

`WE_ROOT` 는 WE 설치본 루트(= `wallpaper64.exe` 와 `bin/` 이 있는 디렉터리)다.
"""
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# spec 정본이 실제로 인용하는 것만. 인용 횟수는 아래 doc 항목에 함께 기록한다.
TARGETS = [
    "wallpaper64.exe",
    "bin/scenescript64.dll",
    "bin/mediaextensions64.dll",
    "bin/wallpaperui.exe",
    "bin/resourcecompiler64.exe",
    "bin/webwallpaper64.exe",
    "bin/resourceutil64.dll",
    "bin/cloneextensions64.dll",
]

CITATIONS = {
    "wallpaper64.exe": 189, "scenescript64.dll": 31, "mediaextensions64.dll": 14,
    "wallpaperui.exe": 13, "resourcecompiler64.exe": 12, "webwallpaper64.exe": 6,
    "resourceutil64.dll": 4, "cloneextensions64.dll": 4,
}


def pe_facts(data):
    """PE 헤더에서 재현 검증에 쓸 값만. 형식이 아니면 None(지문은 그래도 남긴다)."""
    off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[off:off + 4] != b"PE\0\0":
        return None
    timestamp = struct.unpack_from("<I", data, off + 8)[0]
    optsz = struct.unpack_from("<H", data, off + 20)[0]
    image_base = struct.unpack_from("<Q", data, off + 24 + 24)[0]
    _pdata_rva, pdata_size = struct.unpack_from("<II", data, off + 24 + 112 + 3 * 8)
    return {
        "eLfanew": off,
        "timeDateStamp": timestamp,
        "imageBase": f"0x{image_base:x}",
        # .pdata RUNTIME_FUNCTION 수 — 같은 빌드인지 빠르게 가리는 두 번째 지표.
        # 주의: unwind 정보 없는 리프 함수는 여기 없다(전체 함수 수가 아니다).
        "pdataFunctions": pdata_size // 12,
    }


def main():
    rows, missing = {}, []
    for rel in TARGETS:
        path = os.path.join(WE_ROOT, rel)
        if not os.path.isfile(path):
            missing.append(rel)
            continue
        data = open(path, "rb").read()
        info = {"sha256": hashlib.sha256(data).hexdigest(), "fileBytes": len(data)}
        facts = pe_facts(data)
        if facts:
            info.update(facts)
        rows[os.path.basename(rel)] = info

    if not rows:
        raise SystemExit(
            f"[we-binaries] WE_ROOT 아래에서 대상 바이너리를 하나도 못 찾았다: {WE_ROOT}\n"
            f"  WE_ROOT 는 wallpaper64.exe 와 bin/ 이 있는 설치본 루트여야 한다.")

    ev = specfmt.ev("binary", "WE 2.8.42 설치본(wallpaper64.exe + bin/)",
                    "sha256 · fileBytes · PE TimeDateStamp · .pdata 함수 수")

    entries = [
        specfmt.entry("binary.fingerprints", rows, "확정", [ev]),
        specfmt.entry("binary.fingerprints.why", {
            "reason": "spec 정본이 WE 바이너리를 273회 인용하는데 지문은 wallpaper64.exe 하나뿐이었다. "
                      "근거가 사는 분석 리포가 삭제되면 나머지 7종은 확정 등급인데 대조 수단이 사라진다.",
            "citations": CITATIONS,
            "validatorBlindSpot": "validate.py 의 근거 실재 검사는 리포 밖 경로를 제외한다"
                                  "(머신마다 다르므로 정당한 설계) — 그래서 이 부류를 자동으로는 못 잡는다.",
            "notCommitted": "바이너리 자체는 커밋하지 않는다(독점 소프트웨어). 지문만 남긴다.",
        }, "확정", [ev]),
    ]
    if missing:
        entries.append(specfmt.entry("binary.fingerprints.missing", sorted(missing), "확정", [ev]))

    specfmt.dump(specfmt.doc("scripts/spec/measure_we_binaries_fingerprint.py", entries),
                 os.path.join("spec", "binaries-fingerprint.json"))

    for name, info in rows.items():
        print(f"{name:26} {info['fileBytes']:>9}  {info['sha256'][:16]}…  "
              f"pdata={info.get('pdataFunctions', '-')}")
    if missing:
        print("못 찾음:", ", ".join(missing))


if __name__ == "__main__":
    main()
