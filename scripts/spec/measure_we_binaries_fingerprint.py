"""spec 정본이 인용하는 WE 바이너리 8종의 지문을 남긴다.

## 왜 필요한가

`spec/` 정본은 WE 바이너리를 **341회** 인용한다(실측 · 아래 세는 법). 그런데 지문(sha256)이
남아 있던 것은 `wallpaper64.exe` 하나뿐이었다(`spec/engine/decompilation-provenance.json`).

    wallpaper64.exe        246회      scenescript64.dll       31회
    mediaextensions64.dll   18회      wallpaperui.exe         18회
    resourcecompiler64.exe  12회      webwallpaper64.exe       6회
    resourceutil64.dll       6회      cloneextensions64.dll    4회

## 세는 법 (2026-08-28 이전엔 없었다)

**[2026-08-28] 종전 이 도수는 `CITATIONS = {...}` 하드코딩 파이썬 리터럴이었다.** 그래서
`statusRules.확정` 이 요구하는 "generatedBy 스크립트로 재현된다" 를 만족하지 못했고, 실제로
8종 중 4종이 낡아 있었다(`wallpaper64` 189 · `mediaextensions` 14 · `wallpaperui` 13 ·
`resourceutil` 4 — 전부 그 뒤 늘어난 인용을 못 따라갔다). **지금은 매 실행 실제로 센다.**

모집단과 단위를 못 박는다 — 이 리포가 반복해서 당한 병이 "수치만 있고 세는 법이 없다" 다:

  · **모집단**: `spec/**/*.json` 중 정본인 것(= `validate.py` 의 `is_canon_path` 와 같은 규칙 —
    캡처 산출물 `golden/snapshot/` 과 형식 문서 `schema.json` 을 뺀다). 이 문서 자신도 포함된다.
  · **단위**: `evidence` **객체** 1개. 한 객체가 두 바이너리를 언급하면 양쪽에 각 1 로 센다
    (그래서 종별 합 341 ≥ 걸린 객체 수).
  · **일치**: `ref` 와 `note` 를 이어붙인 문자열에 파일명이 **낱말 경계로** 나타나면 1.
    경계가 필요한 이유는 `webwallpaper64.exe` 가 `wallpaper64.exe` 를 **부분문자열로 포함**하기
    때문이다 — 경계 없이 세면 `wallpaper64.exe` 가 4 과다 계수된다(실측 246 → 251).

이 바이너리들은 분석 리포(`Waple-wallpaper-source`)의 `wallpaper_engine/` 아래에만 있고,
그 리포는 삭제 예정이다. 삭제되면 **확정 등급인데 근거를 대조할 수단이 없는 항목**이 남는다.

`validate.py` 의 근거 실재 검사는 리포 **밖** 경로를 검사 대상에서 빼므로(머신마다 다르니
정당한 설계다) 이 부류를 영원히 못 잡는다. 그래서 사람이 명시적으로 박제해야 한다.

바이너리 자체는 커밋하지 않는다 — 독점 소프트웨어다. 지문만 남긴다.

## 재실행

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/spec/measure_we_binaries_fingerprint.py

`WE_ROOT` 는 WE 설치본 루트(= `wallpaper64.exe` 와 `bin/` 이 있는 디렉터리)다.
"""
import glob
import hashlib
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE_ROOT = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

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

def is_canon_json(path):
    """`validate.py` 의 `is_canon_path` 와 같은 규칙 — 캡처 산출물과 형식 문서를 뺀다.

    같은 판정을 두 곳에 적는 것은 좋지 않지만, 이 스크립트는 `validate.py` 를 import 하지
    않는다(정본을 **만드는** 쪽이 **검사하는** 쪽에 의존하면 같은 버그가 양쪽을 통과한다 —
    `validate.py` 머리말이 적어 둔 분리 원칙이다). 규칙이 갈리면 도수가 바뀌므로,
    바꿀 때는 양쪽을 같이 봐야 한다.
    """
    parts = path.replace("\\", "/").split("/")
    if parts[-1] == "schema.json":
        return False
    return not any(parts[i] == "golden" and parts[i + 1] == "snapshot"
                   for i in range(len(parts) - 1))


def count_citations(names):
    """정본이 각 바이너리를 인용하는 **evidence 객체** 수. 세는 법은 머리말 참조.

    낱말 경계가 필요한 이유: `webwallpaper64.exe` 가 `wallpaper64.exe` 를 부분문자열로
    포함한다. 경계 없이 세면 `wallpaper64.exe` 가 4 과다 계수된다(246 → 251).
    """
    pats = {n: re.compile(r"(?<![A-Za-z0-9_])" + re.escape(n)) for n in names}
    cnt = {n: 0 for n in names}
    for p in sorted(glob.glob(os.path.join(REPO, "spec", "**", "*.json"), recursive=True)):
        if not is_canon_json(p):
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (ValueError, OSError):
            continue
        if not isinstance(doc, dict):
            continue
        for e in doc.get("entries") or []:
            for ev in e.get("evidence") or []:
                if not isinstance(ev, dict):
                    continue
                text = " ".join(str(ev.get(k, "")) for k in ("ref", "note"))
                for n, rx in pats.items():
                    if rx.search(text):
                        cnt[n] += 1
    return cnt


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
    citations = count_citations([os.path.basename(t) for t in TARGETS])
    script_ev = specfmt.ev("script", "scripts/spec/measure_we_binaries_fingerprint.py",
                           "citations 는 이 스크립트가 spec/ 정본을 훑어 매 실행 다시 센다 — "
                           "종전의 하드코딩 리터럴이 아니다",
                           "spec/ 정본 전체(validate.py 의 is_canon_path 기준)의 evidence 객체 — "
                           "1,203개 중 바이너리명이 낱말 경계로 나타나는 것을 종별로 센다")

    entries = [
        specfmt.entry("binary.fingerprints", rows, "확정", [ev]),
        specfmt.entry("binary.fingerprints.why", {
            "reason": f"spec 정본이 WE 바이너리를 {sum(citations.values())}회 인용하는데 지문은 "
                      f"wallpaper64.exe 하나뿐이었다. 근거가 사는 분석 리포가 삭제되면 나머지 7종은 "
                      f"확정 등급인데 대조 수단이 사라진다.",
            "citations": citations,
            "citationsPopulation": "**spec/ 정본 전체**(= validate.py 의 is_canon_path — 캡처 산출물 "
                                   "golden/snapshot/ 과 형식 문서 schema.json 제외). 이 문서 자신도 "
                                   "포함된다(자기 evidence 2건이 wallpaper64.exe 를 언급한다).",
            "citationsUnit": "**evidence 객체 1개 = 1**. 한 객체가 두 바이너리를 언급하면 양쪽에 각 1 "
                             "이므로 종별 합(341)은 '걸린 객체 수'보다 크다. 일치는 `ref` + `note` 를 "
                             "이어붙인 문자열에 파일명이 **낱말 경계로** 나타나는지로 본다 — "
                             "`webwallpaper64.exe` 가 `wallpaper64.exe` 를 부분문자열로 포함하므로 "
                             "경계가 없으면 4 과다 계수된다(246 → 251).",
            "citationsWasHardcoded": "[2026-08-28] 종전 이 도수는 생성기 안의 `CITATIONS = {...}` "
                                     "하드코딩 리터럴이었다. statusRules.확정 이 요구하는 "
                                     "'generatedBy 스크립트로 재현된다' 를 만족하지 못했고 실제로 "
                                     "8종 중 4종이 낡아 있었다 — wallpaper64 189 · "
                                     "mediaextensions 14 · wallpaperui 13 · resourceutil 4. "
                                     "지금은 count_citations() 가 매 실행 실제로 센다.",
            "citationsIsAFunctionOfSpec": "**이 도수는 spec/ 전체의 함수다.** 정본 어디든 evidence 를 "
                                          "더하거나 빼면 여기 수치가 바뀐다 — 하드코딩을 걷어낸 대가이고, "
                                          "그게 옳다. 정본을 고친 커밋에서는 이 생성기를 같이 돌려라. "
                                          "실제로 이 감사 한 번에 339 → 341 로 움직였다"
                                          "(render-state 의 D3D11CreateDevice 호출부 근거 2건 추가).",
            "validatorBlindSpot": "validate.py 의 근거 실재 검사는 리포 밖 경로를 제외한다"
                                  "(머신마다 다르므로 정당한 설계) — 그래서 이 부류를 자동으로는 못 잡는다.",
            "notCommitted": "바이너리 자체는 커밋하지 않는다(독점 소프트웨어). 지문만 남긴다.",
        }, "확정", [ev, script_ev]),
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
