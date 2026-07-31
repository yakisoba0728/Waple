# 정본 기반 구축 A — `spec/` 정본화와 에셋 동봉 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WE 2.8.42 실설치본에서 확보한 정본을 리포 안에 기계 판독·재현 가능한 형태로 착지시키고, 공유 에셋을 동봉해 씬이 WE 설치 없이 돌 수 있게 한다.

**Architecture:** `spec/` 에 JSON 정본 데이터를 두고, `scripts/spec/` 에 stdlib Python 도구를 둔다. 도구는 두 종류다 — **재측정기**(WE 설치본에서 정본을 다시 뽑아 드리프트를 검출)와 **검증기**(정본의 스키마·근거 필드·내부 정합성을 검사). 모든 정본 항목은 근거를 달고, 직접 측정한 것만 `확정` 이며 `확정` 만 테스트를 생성한다. 에셋은 `Sources/WapleRender/Resources/WEAssets/` 에 원문 그대로 동봉하고 해시 매니페스트로 드리프트를 감지한다.

**Tech Stack:** Python 3.12 (**stdlib 전용** — 리포의 "외부 의존 0" 원칙을 도구에도 적용), JSON, git.

## Global Constraints

- **외부 패키지 의존은 0이다** (`AGENTS.md`). Python 도구도 stdlib 만 쓴다 — `jsonschema`/`pefile` 금지. PE 파싱이 필요하면 `struct` 로 직접 읽는다.
- **Swift 코드를 이 계획에서 건드리지 않는다.** 이 머신에 Swift 툴체인이 없어 빌드·테스트 검증이 불가능하다. Swift 변경은 계획 B(Mac 확보 후).
- **`Package.swift` 를 이 계획에서 수정하지 않는다.** 리소스 선언은 빌드 검증이 필요하므로 계획 B.
- 커밋 메시지는 **한국어 서술형**, `feat:` 류 접두사 없음. 근거는 괄호에 담는다.
- 성격이 다른 변경은 **커밋을 나눈다**.
- WE 설치 경로: `Z:\SteamLibrary\steamapps\common\wallpaper_engine`
- 코퍼스 경로: `Z:\SteamLibrary\steamapps\workshop\content\431960`
- WE 버전 **2.8.42** — 모든 정본과 에셋 매니페스트에 이 값을 기록한다.
- 상태 어휘 3종: **`확정`**(직접 측정 + 재현 스크립트 존재) · **`보고`**(정찰 에이전트 보고, 미재현) · **`추정`**(근거 불충분). **`확정` 만 테스트를 생성한다.**

---

## File Structure

```
spec/
  README.md                     규약 — 상태 어휘, 근거 필수, 재현 방법
  schema.json                   항목 스키마(자체 정의, stdlib 로 검사)
  binaries.json                 WE 바이너리 PE 조사 결과
  corpus/inventory.json         코퍼스 446종 실측 도수
  formats/pkg.json              PKGV 컨테이너 레이아웃
  formats/tex.json              TEXV/TEXI/TEXB/TEXS 관측
  formats/mdl.json              MDLV 버전 분포 + MDLV0004 레이아웃
  engine/uniforms.json          g_* 유니폼 143종
  engine/render-targets.json    _rt_* 21종
  assets/inventory.json         WE assets/ 구성
  assets/manifest.json          동봉본 파일 해시(드리프트 감지)

scripts/spec/
  specfmt.py                    공통 — 로드/저장/상태 어휘 (다른 스크립트가 임포트)
  validate.py                   정본 검증기(스키마·근거·정합성)
  measure_binaries.py           WE 바이너리 재측정
  measure_corpus.py             코퍼스 재측정
  measure_assets.py             assets/ 재측정 + 해시 매니페스트 생성
  verify_rosetta.py             .obj ↔ .mdl 로제타석 검증
  tests/test_validate.py        검증기 자체 테스트
  tests/test_rosetta.py         로제타석 검증기 테스트

Sources/WapleRender/Resources/WEAssets/    동봉 에셋 2,940파일 / 76MB
.gitattributes                             바이너리 규칙 추가
NOTICE                                     WE 에셋 동봉 고지 추가
```

**책임 분리:** `specfmt.py` 는 포맷만 안다(읽기·쓰기·상태 어휘). `measure_*.py` 는 WE 설치본을 읽어 정본을 **생성**한다. `validate.py` 는 생성물을 **검사**한다. 생성과 검사를 나눠야 "생성기가 틀렸는데 검사도 같이 틀리는" 상황을 피한다.

---

### Task 1: `spec/` 규약과 검증기

정본의 형식을 먼저 못박고, 그것을 강제하는 검증기를 만든다. 데이터보다 규약이 먼저다 — 규약 없이 데이터를 넣으면 나중에 전부 다시 손봐야 한다.

**Files:**
- Create: `spec/README.md`
- Create: `spec/schema.json`
- Create: `scripts/spec/specfmt.py`
- Create: `scripts/spec/validate.py`
- Test: `scripts/spec/tests/test_validate.py`

**Interfaces:**
- Produces:
  - `specfmt.STATUSES = ("확정", "보고", "추정")`
  - `specfmt.load(path: str) -> dict`
  - `specfmt.dump(obj: dict, path: str) -> None` (UTF-8, `ensure_ascii=False`, indent=1, 끝에 개행)
  - `specfmt.entry(id: str, value, status: str, evidence: list[dict]) -> dict`
  - `validate.validate_doc(doc: dict, path: str) -> list[str]` (오류 문자열 목록. 빈 목록 = 통과)
  - `validate.main(argv: list[str]) -> int` (0 = 통과)
- Consumes: 없음(첫 태스크)

- [ ] **Step 1: 검증기 테스트를 먼저 쓴다**

`scripts/spec/tests/test_validate.py`:

```python
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import specfmt
import validate


def doc(**over):
    base = {
        "weVersion": "2.8.42",
        "generatedBy": "scripts/spec/measure_x.py",
        "entries": [
            {
                "id": "x.y",
                "value": 1,
                "status": "확정",
                "evidence": [{"kind": "corpus", "ref": "162 pkg 전수"}],
            }
        ],
    }
    base.update(over)
    return base


class TestValidateDoc(unittest.TestCase):
    def test_valid_doc_passes(self):
        self.assertEqual(validate.validate_doc(doc(), "t.json"), [])

    def test_missing_we_version_fails(self):
        d = doc()
        del d["weVersion"]
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("weVersion" in e for e in errs))

    def test_wrong_we_version_fails(self):
        errs = validate.validate_doc(doc(weVersion="2.9.0"), "t.json")
        self.assertTrue(any("2.8.42" in e for e in errs))

    def test_unknown_status_fails(self):
        d = doc()
        d["entries"][0]["status"] = "확실"
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("status" in e for e in errs))

    def test_entry_without_evidence_fails(self):
        d = doc()
        d["entries"][0]["evidence"] = []
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("evidence" in e for e in errs))

    def test_confirmed_entry_requires_reproducible_evidence(self):
        # 확정은 재현 스크립트 근거를 하나 이상 가져야 한다.
        d = doc()
        d["entries"][0]["evidence"] = [{"kind": "hearsay", "ref": "누가 그랬다"}]
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("확정" in e for e in errs))

    def test_report_status_allows_any_evidence_kind(self):
        d = doc()
        d["entries"][0]["status"] = "보고"
        d["entries"][0]["evidence"] = [{"kind": "recon", "ref": "정찰 에이전트"}]
        self.assertEqual(validate.validate_doc(d, "t.json"), [])

    def test_duplicate_ids_fail(self):
        d = doc()
        d["entries"].append(dict(d["entries"][0]))
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("중복" in e for e in errs))

    def test_evidence_entry_needs_kind_and_ref(self):
        d = doc()
        d["entries"][0]["evidence"] = [{"kind": "corpus"}]
        errs = validate.validate_doc(d, "t.json")
        self.assertTrue(any("ref" in e for e in errs))


class TestSpecfmt(unittest.TestCase):
    def test_entry_builds_expected_shape(self):
        e = specfmt.entry("a.b", 3, "확정", [{"kind": "corpus", "ref": "r"}])
        self.assertEqual(e["id"], "a.b")
        self.assertEqual(e["value"], 3)
        self.assertEqual(e["status"], "확정")

    def test_entry_rejects_unknown_status(self):
        with self.assertRaises(ValueError):
            specfmt.entry("a.b", 3, "확실", [{"kind": "corpus", "ref": "r"}])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```
python scripts/spec/tests/test_validate.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'specfmt'`

- [ ] **Step 3: `specfmt.py` 구현**

`scripts/spec/specfmt.py`:

```python
"""spec/ 정본 문서의 공통 포맷.

정본은 사람이 읽고 기계가 검사한다. 그래서 (a) UTF-8 그대로 두고
(b) 들여쓰기를 얕게 해서 diff 가 읽히게 하고 (c) 항목마다 근거를 강제한다.
"""
import json
import os

WE_VERSION = "2.8.42"

# 확정 = 직접 측정했고 재현 스크립트가 있다
# 보고 = 정찰 에이전트가 보고했고 아직 재현하지 않았다
# 추정 = 근거가 불충분하다
STATUSES = ("확정", "보고", "추정")

# 확정 항목이 반드시 하나 이상 가져야 하는 근거 종류 — 재현 가능한 것들
REPRODUCIBLE_KINDS = ("corpus", "binary", "asset", "shader", "script", "file")


def entry(id, value, status, evidence):
    if status not in STATUSES:
        raise ValueError(f"알 수 없는 status: {status!r} (가능: {STATUSES})")
    if not evidence:
        raise ValueError(f"{id}: evidence 가 비어 있다")
    return {"id": id, "value": value, "status": status, "evidence": list(evidence)}


def ev(kind, ref, note=None):
    e = {"kind": kind, "ref": ref}
    if note:
        e["note"] = note
    return e


def doc(generated_by, entries, extra=None):
    d = {"weVersion": WE_VERSION, "generatedBy": generated_by}
    if extra:
        d.update(extra)
    d["entries"] = entries
    return d


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def dump(obj, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, indent=1, ensure_ascii=False, sort_keys=False)
        fh.write("\n")
```

- [ ] **Step 4: `validate.py` 구현**

`scripts/spec/validate.py`:

```python
"""spec/ 정본 검증기 — 스키마, 근거 필드, 내부 정합성.

생성기(measure_*.py)와 분리해 둔다. 같은 코드가 만들고 검사하면
생성기의 버그를 검사기가 그대로 통과시킨다.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt


def validate_doc(d, path):
    errs = []
    p = os.path.basename(path)

    if "weVersion" not in d:
        errs.append(f"{p}: weVersion 필드가 없다")
    elif d["weVersion"] != specfmt.WE_VERSION:
        errs.append(f"{p}: weVersion 이 {d['weVersion']!r} — {specfmt.WE_VERSION!r} 이어야 한다")

    if not d.get("generatedBy"):
        errs.append(f"{p}: generatedBy 가 없다 — 재현 방법을 알 수 없다")

    entries = d.get("entries")
    if not isinstance(entries, list):
        errs.append(f"{p}: entries 가 배열이 아니다")
        return errs

    seen = set()
    for i, e in enumerate(entries):
        where = f"{p}[{i}]"
        eid = e.get("id")
        if not eid:
            errs.append(f"{where}: id 가 없다")
        elif eid in seen:
            errs.append(f"{where}: id 중복 — {eid!r}")
        else:
            seen.add(eid)
            where = f"{p}:{eid}"

        if "value" not in e:
            errs.append(f"{where}: value 가 없다")

        status = e.get("status")
        if status not in specfmt.STATUSES:
            errs.append(f"{where}: status 가 {status!r} — {specfmt.STATUSES} 중 하나여야 한다")

        evs = e.get("evidence")
        if not isinstance(evs, list) or not evs:
            errs.append(f"{where}: evidence 가 비어 있다 — 근거 없는 정본은 허용하지 않는다")
            continue

        kinds = []
        for j, x in enumerate(evs):
            if not isinstance(x, dict):
                errs.append(f"{where}: evidence[{j}] 가 객체가 아니다")
                continue
            if not x.get("kind"):
                errs.append(f"{where}: evidence[{j}] 에 kind 가 없다")
            if not x.get("ref"):
                errs.append(f"{where}: evidence[{j}] 에 ref 가 없다")
            kinds.append(x.get("kind"))

        if status == "확정" and not any(k in specfmt.REPRODUCIBLE_KINDS for k in kinds):
            errs.append(
                f"{where}: status 가 '확정' 인데 재현 가능한 근거가 없다 "
                f"(필요: {specfmt.REPRODUCIBLE_KINDS} 중 하나, 현재: {kinds})"
            )

    return errs


def main(argv):
    root = argv[1] if len(argv) > 1 else "spec"
    paths = sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
    paths = [p for p in paths if os.path.basename(p) != "schema.json"]
    if not paths:
        print(f"검사 대상 없음: {root}")
        return 1

    total_err = 0
    stats = {s: 0 for s in specfmt.STATUSES}
    for p in paths:
        try:
            d = specfmt.load(p)
        except json.JSONDecodeError as e:
            print(f"FAIL {p}: JSON 파싱 실패 — {e}")
            total_err += 1
            continue
        errs = validate_doc(d, p)
        for e in d.get("entries", []):
            if e.get("status") in stats:
                stats[e["status"]] += 1
        if errs:
            print(f"FAIL {p}")
            for e in errs:
                print(f"   {e}")
            total_err += len(errs)
        else:
            print(f"ok   {p}  ({len(d.get('entries', []))} 항목)")

    print()
    print(f"상태 분포: " + " / ".join(f"{k} {v}" for k, v in stats.items()))
    print(f"오류 {total_err} 건")
    return 0 if total_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 5: 테스트 통과 확인**

```
python scripts/spec/tests/test_validate.py -v
```
Expected: PASS — 11 tests

- [ ] **Step 6: `spec/README.md` 와 `spec/schema.json` 작성**

`spec/schema.json` (자체 정의 — `jsonschema` 패키지를 쓰지 않으므로 문서 겸용):

```json
{
 "$comment": "spec/ 정본 문서의 형식. 검사는 scripts/spec/validate.py 가 stdlib 로 수행한다(외부 의존 0 원칙).",
 "document": {
  "weVersion": "문자열. 반드시 '2.8.42' — 정본이 어느 WE 빌드에서 나왔는지 고정한다",
  "generatedBy": "문자열. 이 문서를 만든 스크립트 경로. 재현 방법이다",
  "entries": "항목 배열"
 },
 "entry": {
  "id": "점으로 구분된 고유 식별자. 문서 안에서 중복 불가",
  "value": "정본 값. 형태는 항목마다 다르다",
  "status": "확정 | 보고 | 추정",
  "evidence": "근거 배열. 비면 안 된다"
 },
 "evidence": {
  "kind": "corpus | binary | asset | shader | script | file | recon | doc",
  "ref": "구체적 참조 — 경로, 주소, 수치, 명령",
  "note": "선택. 부연"
 },
 "statusRules": {
  "확정": "직접 측정했고 generatedBy 스크립트로 재현된다. evidence 에 corpus/binary/asset/shader/script/file 중 하나가 반드시 있어야 한다. 이 항목만 테스트를 생성한다",
  "보고": "정찰 에이전트가 보고했으나 재현하지 않았다. 테스트를 생성하지 않는다",
  "추정": "근거가 불충분하다. 테스트를 생성하지 않으며, 구현이 이 값에 의존하면 주석에 명시해야 한다"
 }
}
```

`spec/README.md`:

```markdown
# spec/ — WE 2.8.42 정본

이 디렉터리는 Wallpaper Engine 2.8.42 실설치본에서 확보한 **정본(canon)** 이다.
구현이 무엇을 향해 쓰이는지의 기준이고, 여기서 테스트가 생성된다.

## 왜 코드 주석이 아니라 여기인가

이전에 역공학 산출물(`analysis/`)이 통째로 사라졌고 근거가 코드 주석에만 남았다.
지금 코드가 인용하는 `analysis/decompiled/all/FUN_140261950.c`,
`corpus_scan/mdl-format.md` 는 리포에 존재하지 않는다. 같은 사고를 구조적으로 막는다.

## 규약

1. **모든 항목에 근거(`evidence`)가 필수다.** 없으면 검증기가 거부한다.
2. **상태는 셋뿐이다.**
   - `확정` — 직접 측정했고 `generatedBy` 스크립트로 재현된다. **이 항목만 테스트를 생성한다.**
   - `보고` — 정찰이 보고했으나 재현하지 않았다.
   - `추정` — 근거 불충분. 구현이 이 값에 의존하면 코드 주석에 명시할 것.
3. **원문이 아니라 파생 사실을 담는다.** 값·표·필드 정의. WE 셰이더 원문 전사나
   전체 디컴파일 덤프는 넣지 않는다 — **저작권 때문이 아니라**(에셋은
   `Sources/WapleRender/Resources/WEAssets/` 에 원문 그대로 동봉된다) 원문 사본으로는
   테스트를 생성할 수 없고 diff 도 의미가 없기 때문이다.
4. **`weVersion` 은 항상 `2.8.42`.** WE 가 올라가면 재측정하고 이 값을 바꾼다.

## 검증

```bash
python scripts/spec/validate.py          # 전체 검사
python scripts/spec/tests/test_validate.py -v   # 검증기 자체 테스트
```

## 재측정 (WE 설치본 필요 — Windows)

```bash
python scripts/spec/measure_binaries.py   # spec/binaries.json
python scripts/spec/measure_corpus.py     # spec/corpus/inventory.json, spec/formats/*.json
python scripts/spec/measure_assets.py     # spec/assets/inventory.json, spec/assets/manifest.json
python scripts/spec/verify_rosetta.py     # .obj ↔ .mdl 대조
```

경로는 환경변수로 바꾼다: `WE_ROOT`, `WE_WORKSHOP`.

## 문서

프로그램 차터: [../docs/superpowers/specs/2026-07-31-we-engine-port-charter.md](../docs/superpowers/specs/2026-07-31-we-engine-port-charter.md)
```

- [ ] **Step 7: 검증기를 빈 `spec/` 에 돌려 동작 확인**

```
python scripts/spec/validate.py
```
Expected: `검사 대상 없음: spec` 후 exit 1 (아직 정본 데이터가 없으므로 정상)

- [ ] **Step 8: 커밋**

```bash
git add spec/README.md spec/schema.json scripts/spec/specfmt.py scripts/spec/validate.py scripts/spec/tests/test_validate.py
git commit -m "spec/ 정본 규약과 검증기 신설(근거 필수·상태 3종·stdlib 전용)"
```

---

### Task 2: WE 바이너리 조사 정본

PE 구조를 재측정 스크립트로 다시 뽑아 `spec/binaries.json` 에 착지시킨다. `pefile` 을 쓰지 않고 `struct` 로 직접 읽는다 — 외부 의존 0 원칙을 도구에도 적용한다.

**Files:**
- Create: `scripts/spec/measure_binaries.py`
- Create: `spec/binaries.json` (스크립트가 생성)

**Interfaces:**
- Consumes: `specfmt.entry`, `specfmt.ev`, `specfmt.doc`, `specfmt.dump`
- Produces: `spec/binaries.json` — 항목 id 는 `binary.<파일명>.<속성>` 형태
  (예: `binary.wallpaper64.exe.codeBytes`, `binary.wallpaper64.exe.importedDLLs`)

- [ ] **Step 1: 재측정 스크립트 작성**

`scripts/spec/measure_binaries.py`:

```python
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
    machine, nsec, _, _, _, opt_size, _ = struct.unpack_from("<HHIIIHH", data, coff)
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    pe32plus = magic == 0x20B
    image_base = struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus else \
        struct.unpack_from("<I", data, opt + 28)[0]
    # 데이터 디렉터리: PE32+ 는 opt+112, PE32 는 opt+96
    dd = opt + (112 if pe32plus else 96)
    import_rva, _ = struct.unpack_from("<II", data, dd + 8)

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
                end = data.index(b"\0", no)
                dlls.append(data[no:end].decode("ascii", "ignore"))
                off += 20

    code = sum(s["vsize"] for s in sections if s["name"] in (".text", "CODE"))
    return {"machine": machine, "imageBase": image_base, "sections": sections,
            "codeBytes": code, "importedDLLs": sorted(dlls), "fileBytes": len(data)}


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
```

- [ ] **Step 2: 실행해서 정본 생성**

```
python scripts/spec/measure_binaries.py
```
Expected: 8개 바이너리 출력. `wallpaper64.exe` 의 `code` 가 약 4,242 KB, imports 13개.

- [ ] **Step 3: 검증기 통과 확인**

```
python scripts/spec/validate.py
```
Expected: `ok   spec\binaries.json  (N 항목)`, 오류 0건

- [ ] **Step 4: 알려진 값과 대조**

`spec/binaries.json` 을 열어 다음이 맞는지 눈으로 확인한다(이전 세션 실측치):
- `binary.wallpaper64.exe.importedDLLs` 에 `d3d11.dll`, `DWrite.dll`, `MFReadWrite.dll`, `dwmapi.dll` 이 있다
- `binary.wallpaper64.exe.codeBytes` 가 4,300,000 안팎이다
- `binary.resourcecompiler64.exe.importedDLLs` 에 `assimp-vc143-mt64.dll`, `FreeImage64.dll` 이 있다

어긋나면 스크립트를 고친다(정본을 손으로 고치지 않는다 — 재현 가능해야 한다).

- [ ] **Step 5: 커밋**

```bash
git add scripts/spec/measure_binaries.py spec/binaries.json
git commit -m "WE 바이너리 PE 구조 정본화(stdlib 직접 파싱, 재측정 스크립트 동반)"
```

---

### Task 3: 코퍼스 실측 정본과 포맷 정본

446종 코퍼스를 전수 파싱해 버전·포맷 도수를 정본으로 만든다. 이 파싱이 성공한다는 사실 자체가 `ScenePackage` 컨테이너 이해의 검증이다.

**Files:**
- Create: `scripts/spec/measure_corpus.py`
- Create: `spec/corpus/inventory.json` (스크립트가 생성)
- Create: `spec/formats/pkg.json` (스크립트가 생성)
- Create: `spec/formats/tex.json` (스크립트가 생성)
- Create: `spec/formats/mdl.json` (스크립트가 생성)

**Interfaces:**
- Consumes: `specfmt.entry`, `specfmt.ev`, `specfmt.doc`, `specfmt.dump`
- Produces:
  - `spec/corpus/inventory.json` — `corpus.typeDistribution`, `corpus.pkgParseResult`, `corpus.entryExtensions`
  - `spec/formats/pkg.json` — `format.pkg.layout`, `format.pkg.magicDistribution`
  - `spec/formats/tex.json` — `format.tex.magicDistribution`, `format.tex.containerDistribution`, `format.tex.paddedVsImageDims`
  - `spec/formats/mdl.json` — `format.mdl.corpusVersions`, `format.mdl.bundledVersions`, `format.mdl.v0004Layout`

- [ ] **Step 1: 측정 스크립트 작성**

`scripts/spec/measure_corpus.py`:

```python
"""워크샵 코퍼스를 전수 파싱해 포맷 도수 정본을 만든다.

pkg 컨테이너 규약(Waple 의 ScenePackage.swift 와 동일):
  i32 vlen | vlen bytes magic("PKGV####") | i32 count
  count x { i32 nlen | nlen bytes name | i32 offset | i32 size }
  blobBase = 현재 위치
파싱이 전건 성공한다는 것 자체가 그 규약의 검증이다.
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")


def parse_pkg(data):
    n = len(data)
    p = 0

    def i32():
        nonlocal p
        if p + 4 > n:
            raise ValueError("eof")
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    if vlen < 0 or p + vlen > n:
        raise ValueError("bad vlen")
    magic = data[p:p + vlen].decode("ascii", "ignore")
    p += vlen
    count = i32()
    if count < 0 or count > 65536:
        raise ValueError("bad count")
    entries = []
    for _ in range(count):
        nlen = i32()
        if nlen < 0 or p + nlen > n:
            raise ValueError("bad nlen")
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return magic, entries, p


def main():
    types = collections.Counter()
    types_raw = collections.Counter()
    pkg_magic = collections.Counter()
    ext = collections.Counter()
    mdl_ver = collections.Counter()
    tex_magic = collections.Counter()
    tex_cont = collections.Counter()
    errors = collections.Counter()
    pkgs = 0

    for wid in sorted(os.listdir(WS)):
        d = os.path.join(WS, wid)
        if not os.path.isdir(d):
            continue
        pj = os.path.join(d, "project.json")
        if os.path.exists(pj):
            try:
                with open(pj, encoding="utf-8-sig") as fh:
                    t = (json.load(fh).get("type") or "").strip()
                types_raw[t or "(없음)"] += 1
                types[t.lower() or "(없음)"] += 1
            except Exception as e:
                errors[f"project.json:{type(e).__name__}"] += 1

        for fn in ("scene.pkg", "gifscene.pkg"):
            path = os.path.join(d, fn)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                data = fh.read()
            try:
                magic, entries, base = parse_pkg(data)
            except Exception as e:
                errors[f"pkg:{e}"] += 1
                continue
            pkgs += 1
            pkg_magic[magic] += 1
            for name, off, size in entries:
                e = os.path.splitext(name)[1].lower() or "(없음)"
                ext[e] += 1
                s = base + off
                if s < 0 or s + 16 > len(data):
                    continue
                head = data[s:s + 16]
                if e == ".mdl":
                    mdl_ver[head[:8].decode("ascii", "ignore")] += 1
                elif e == ".tex":
                    tex_magic[head[:8].decode("ascii", "ignore")] += 1
                    sub = data[s:s + min(size, 64)]
                    for tag in (b"TEXI", b"TEXB", b"TEXS"):
                        i = sub.find(tag)
                        if i >= 0:
                            tex_cont[sub[i:i + 8].decode("ascii", "ignore")] += 1

    # WE 자체 번들 .mdl (코퍼스와 다르다 — Waple 미지원 버전이 여기 있다)
    bundled = collections.Counter()
    for root, _, files in os.walk(WE):
        for f in files:
            if f.endswith(".mdl"):
                with open(os.path.join(root, f), "rb") as fh:
                    bundled[fh.read(8).decode("ascii", "ignore")] += 1

    corpus_ev = specfmt.ev("corpus", f"{WS} 전수 스캔 (scene.pkg {pkgs}개)")

    # --- corpus/inventory.json ---
    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("corpus.typeDistribution", dict(types.most_common()), "확정", [corpus_ev]),
        specfmt.entry("corpus.typeDistributionRaw", dict(types_raw.most_common()), "확정",
                      [specfmt.ev("corpus", "project.json type 원문(대소문자 보존)",
                                  "대소문자 혼용이라 정확 비교는 일부를 놓친다")]),
        specfmt.entry("corpus.pkgParsed", pkgs, "확정", [corpus_ev]),
        specfmt.entry("corpus.pkgParseErrors", dict(errors), "확정", [corpus_ev]),
        specfmt.entry("corpus.entryExtensions", dict(ext.most_common()), "확정", [corpus_ev]),
    ]), os.path.join("spec", "corpus", "inventory.json"))

    # --- formats/pkg.json ---
    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.pkg.layout", {
            "header": "i32 vlen | vlen bytes magic | i32 entryCount",
            "entry": "i32 nameLen | nameLen bytes name | i32 offset | i32 size",
            "blobBase": "엔트리 표 직후",
            "compression": "없음 — 무압축 TOC 아카이브",
        }, "확정", [specfmt.ev("corpus", f"{pkgs}/{pkgs} 파싱 성공, 오류 {sum(errors.values())}건",
                              "전건 성공이 곧 규약의 검증이다")]),
        specfmt.entry("format.pkg.magicDistribution", dict(pkg_magic.most_common()), "확정", [corpus_ev]),
    ]), os.path.join("spec", "formats", "pkg.json"))

    # --- formats/tex.json ---
    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.tex.magicDistribution", dict(tex_magic.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.tex.containerDistribution", dict(tex_cont.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.tex.transcodeIsNotDecoder", {
            "claim": "resourcecompiler64.exe -transcode 는 RGBA8888 디코더가 아니다",
            "observed": "5표본 중 3 무변화(패스스루), 2 재압축. 출력이 여전히 TEXV0005/TEXI0001",
            "deterministic": True,
        }, "확정", [specfmt.ev("binary", "bin/resourcecompiler64.exe -transcode -i <in> -o <out>",
                              "5표본 215B~2.8MB, 2회 실행 SHA 동일")]),
    ]), os.path.join("spec", "formats", "tex.json"))

    # --- formats/mdl.json ---
    specfmt.dump(specfmt.doc("scripts/spec/measure_corpus.py", [
        specfmt.entry("format.mdl.corpusVersions", dict(mdl_ver.most_common()), "확정", [corpus_ev]),
        specfmt.entry("format.mdl.bundledVersions", dict(bundled.most_common()), "확정",
                      [specfmt.ev("asset", f"{WE} 하위 .mdl 전수",
                                  "WE 자체 번들. 코퍼스와 버전 분포가 다르다")]),
        specfmt.entry("format.mdl.v0004Layout", {
            "header": 'magic "MDLV0004" | u8 0 | u32 formatFlag | u32 const1 | u32 meshCount',
            "mesh": "cstring materialPath | u32 0 | u32 vertexBlobBytes | vertices | ...",
            "formatFlag0x09": "pos(3f) + uv(2f) = stride 20B, 법선/탄젠트 없음",
            "hasAABB": "version >= 17 에서만 존재. 0004 는 없음",
        }, "확정", [specfmt.ev("file",
                              "projects/defaultprojects/audiophile/models/audiophile/glow.mdl (156B)",
                              "짝 glow.obj 와 대조: 정점4·UV4·법선없음, 첫 정점 x=-3.285059 = float 68 3E 52 C0")]),
    ]), os.path.join("spec", "formats", "mdl.json"))

    print(f"pkg {pkgs}개 파싱, 오류 {sum(errors.values())}건")
    print(f"  type(소문자) {dict(types.most_common())}")
    print(f"  PKGV {dict(pkg_magic.most_common(5))}")
    print(f"  MDLV 코퍼스 {dict(mdl_ver.most_common())}")
    print(f"  MDLV 번들   {dict(bundled.most_common())}")
    print(f"  TEX {dict(tex_magic.most_common())} / {dict(tex_cont.most_common())}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 실행**

```
python scripts/spec/measure_corpus.py
```
Expected: `pkg 162개 파싱, 오류 0건`. PKGV0023 이 최빈. MDLV 코퍼스는 0023 최다, 번들에는 0004/0014 존재.

- [ ] **Step 3: 검증기 통과 확인**

```
python scripts/spec/validate.py
```
Expected: 5개 파일 전부 `ok`, 오류 0건

- [ ] **Step 4: 대소문자 혼용을 눈으로 확인**

`spec/corpus/inventory.json` 의 `corpus.typeDistributionRaw` 를 연다.
`Video`/`Scene`/`Web` 같은 대문자 시작 값이 실제로 있는지 본다.
있다면 이 사실이 정본에 남는다 — 나중에 `type == "video"` 정확 비교를 쓰는 코드를 잡는 근거가 된다.

- [ ] **Step 5: 커밋**

```bash
git add scripts/spec/measure_corpus.py spec/corpus/ spec/formats/
git commit -m "코퍼스 전수 실측과 pkg/tex/mdl 포맷 정본화(162/162 파싱, transcode 반증 포함)"
```

---

### Task 4: `.obj` ↔ `.mdl` 로제타석 검증기

`.mdl` 은 정본 생성 수단이 없다(`-mdl` 무한 스핀, 역변환 부재). 대신 WE 기본 프로젝트에 소스 `.obj` 와 컴파일 결과 `.mdl` 이 같은 이름으로 공존한다. 이걸로 파서를 바이트 단위 검증한다.

**Files:**
- Create: `scripts/spec/verify_rosetta.py`
- Test: `scripts/spec/tests/test_rosetta.py`

**Interfaces:**
- Consumes: 없음(독립)
- Produces:
  - `verify_rosetta.parse_obj(text: str) -> dict` — `{"v": [(x,y,z)], "vt": [(u,v)], "f": [[(vi,ti)]]}`
  - `verify_rosetta.parse_mdl_v4(data: bytes) -> dict` — `{"version": str, "formatFlag": int, "meshCount": int, "material": str, "vertexBytes": int, "positions": [(x,y,z)], "uvs": [(u,v)]}`
  - `verify_rosetta.compare(obj: dict, mdl: dict, tol: float) -> list[str]`

- [ ] **Step 1: 테스트를 먼저 쓴다**

`scripts/spec/tests/test_rosetta.py`:

```python
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import verify_rosetta as R


OBJ_TEXT = """# comment
mtllib glow.mtl
v -3.285059 -3.285059 -0.554853
v 3.285059 -3.285059 -0.554853
v -3.285059 3.285059 -0.554853
v 3.285059 3.285059 -0.554853
vt 0.000000 0.000000
vt 1.000000 0.000000
vt 0.000000 1.000000
vt 1.000000 1.000000
usemtl phongE1SG
f 1/1 2/2 4/4 3/3
"""


def make_mdl_v4(positions, uvs, material=b"materials/x.json"):
    """MDLV0004 형태의 최소 바이트열을 만든다(파서 테스트용)."""
    out = b"MDLV0004" + b"\0"
    out += struct.pack("<III", 0x09, 1, 1)          # formatFlag, const1, meshCount
    out += material + b"\0"
    out += struct.pack("<I", 0)                      # u32 0
    blob = b"".join(struct.pack("<3f2f", *p, *u) for p, u in zip(positions, uvs))
    out += struct.pack("<I", len(blob)) + blob
    return out


class TestParseObj(unittest.TestCase):
    def test_counts(self):
        o = R.parse_obj(OBJ_TEXT)
        self.assertEqual(len(o["v"]), 4)
        self.assertEqual(len(o["vt"]), 4)
        self.assertEqual(len(o["f"]), 1)

    def test_first_vertex(self):
        o = R.parse_obj(OBJ_TEXT)
        self.assertAlmostEqual(o["v"][0][0], -3.285059, places=6)

    def test_ignores_comments_and_directives(self):
        o = R.parse_obj("# x\nmtllib a\nusemtl b\nv 1 2 3\n")
        self.assertEqual(o["v"], [(1.0, 2.0, 3.0)])


class TestParseMdlV4(unittest.TestCase):
    def setUp(self):
        self.pos = [(-3.285059, -3.285059, -0.554853), (3.285059, -3.285059, -0.554853)]
        self.uv = [(0.0, 0.0), (1.0, 0.0)]
        self.data = make_mdl_v4(self.pos, self.uv)

    def test_header(self):
        m = R.parse_mdl_v4(self.data)
        self.assertEqual(m["version"], "MDLV0004")
        self.assertEqual(m["formatFlag"], 0x09)
        self.assertEqual(m["meshCount"], 1)
        self.assertEqual(m["material"], "materials/x.json")

    def test_stride_is_20_bytes_for_flag_09(self):
        m = R.parse_mdl_v4(self.data)
        self.assertEqual(m["vertexBytes"], 2 * 20)
        self.assertEqual(len(m["positions"]), 2)

    def test_positions_roundtrip(self):
        m = R.parse_mdl_v4(self.data)
        self.assertAlmostEqual(m["positions"][0][0], -3.285059, places=5)

    def test_rejects_wrong_magic(self):
        with self.assertRaises(ValueError):
            R.parse_mdl_v4(b"NOTMDL00" + b"\0" * 32)


class TestCompare(unittest.TestCase):
    def test_matching_geometry_has_no_errors(self):
        pos = [(-3.285059, -3.285059, -0.554853)]
        uv = [(0.0, 0.0)]
        obj = {"v": pos, "vt": uv, "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4(pos, uv))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_position_mismatch_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0)], "vt": [(0.0, 0.0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([(9.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("위치" in e for e in errs))

    def test_vertex_count_mismatch_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0)], "vt": [(0, 0), (0, 0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("정점 수" in e for e in errs))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 테스트 실패 확인**

```
python scripts/spec/tests/test_rosetta.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'verify_rosetta'`

- [ ] **Step 3: 구현**

`scripts/spec/verify_rosetta.py`:

```python
"""로제타석 검증 — WE 기본 프로젝트의 .obj(소스)와 .mdl(컴파일 결과) 대조.

.mdl 은 정본 생성 수단이 없다(resourcecompiler 의 -mdl 은 무한 스핀,
.mdl -> obj 역변환 부재). 대신 projects/defaultprojects/*/models/ 에
같은 이름의 .obj 와 .mdl 이 공존한다. OBJ 는 정점이 평문이므로
이것으로 .mdl 파서를 바이트 단위 검증할 수 있다.
"""
import os
import struct
import sys

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# formatFlag 하위 바이트 -> 정점 stride(바이트)
STRIDE_BY_FLAG = {0x09: 20}   # pos(12) + uv(8). 관측된 것만 등록한다.


def parse_obj(text):
    v, vt, f = [], [], []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        tag = parts[0]
        if tag == "v" and len(parts) >= 4:
            v.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "vt" and len(parts) >= 3:
            vt.append(tuple(float(x) for x in parts[1:3]))
        elif tag == "f":
            face = []
            for p in parts[1:]:
                bits = p.split("/")
                vi = int(bits[0]) - 1
                ti = int(bits[1]) - 1 if len(bits) > 1 and bits[1] else None
                face.append((vi, ti))
            f.append(face)
    return {"v": v, "vt": vt, "f": f}


def parse_mdl_v4(data):
    if data[:4] != b"MDLV":
        raise ValueError(f"MDLV 매직이 아니다: {data[:8]!r}")
    version = data[:8].decode("ascii", "ignore")
    p = 8
    if data[p:p + 1] != b"\0":
        raise ValueError("매직 뒤 NUL 종단자가 없다")
    p += 1
    format_flag, const1, mesh_count = struct.unpack_from("<III", data, p)
    p += 12
    end = data.index(b"\0", p)
    material = data[p:end].decode("utf-8", "ignore")
    p = end + 1
    p += 4                                   # u32 0
    vertex_bytes = struct.unpack_from("<I", data, p)[0]
    p += 4

    stride = STRIDE_BY_FLAG.get(format_flag & 0xFF)
    positions, uvs = [], []
    if stride and vertex_bytes % stride == 0:
        for i in range(vertex_bytes // stride):
            o = p + i * stride
            x, y, z, u, vv = struct.unpack_from("<3f2f", data, o)
            positions.append((x, y, z))
            uvs.append((u, vv))

    return {"version": version, "formatFlag": format_flag, "const1": const1,
            "meshCount": mesh_count, "material": material,
            "vertexBytes": vertex_bytes, "stride": stride,
            "positions": positions, "uvs": uvs}


def compare(obj, mdl, tol=1e-4):
    errs = []
    if len(obj["v"]) != len(mdl["positions"]):
        errs.append(f"정점 수 불일치: obj {len(obj['v'])} vs mdl {len(mdl['positions'])}")
        return errs
    for i, (a, b) in enumerate(zip(obj["v"], mdl["positions"])):
        for k in range(3):
            if abs(a[k] - b[k]) > tol:
                errs.append(f"정점[{i}] 위치 불일치 축{k}: obj {a[k]} vs mdl {b[k]}")
    if obj["vt"] and len(obj["vt"]) == len(mdl["uvs"]):
        for i, (a, b) in enumerate(zip(obj["vt"], mdl["uvs"])):
            for k in range(2):
                if abs(a[k] - b[k]) > tol:
                    errs.append(f"정점[{i}] UV 불일치 축{k}: obj {a[k]} vs mdl {b[k]}")
    return errs


def find_pairs(root=None):
    root = root or os.path.join(WE, "projects", "defaultprojects")
    pairs = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".obj"):
                continue
            mdl = os.path.join(dirpath, f[:-4] + ".mdl")
            if os.path.exists(mdl):
                pairs.append((os.path.join(dirpath, f), mdl))
    return sorted(pairs)


def main():
    pairs = find_pairs()
    print(f"로제타석 {len(pairs)} 쌍 발견\n")
    checked = skipped = failed = 0
    for objp, mdlp in pairs:
        rel = os.path.relpath(objp, WE)
        with open(mdlp, "rb") as fh:
            data = fh.read()
        try:
            mdl = parse_mdl_v4(data)
        except ValueError as e:
            print(f"  SKIP {rel}: {e}")
            skipped += 1
            continue
        if mdl["stride"] is None:
            print(f"  SKIP {rel}: 미등록 formatFlag 0x{mdl['formatFlag']:x} ({mdl['version']})")
            skipped += 1
            continue
        with open(objp, encoding="utf-8", errors="replace") as fh:
            obj = parse_obj(fh.read())
        errs = compare(obj, mdl)
        if errs:
            print(f"  FAIL {rel} ({mdl['version']}, {len(mdl['positions'])} 정점)")
            for e in errs[:5]:
                print(f"        {e}")
            failed += 1
        else:
            print(f"  ok   {rel} ({mdl['version']}, {len(mdl['positions'])} 정점)")
            checked += 1

    print(f"\n대조 {checked} / 스킵 {skipped} / 불일치 {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 테스트 통과 확인**

```
python scripts/spec/tests/test_rosetta.py -v
```
Expected: PASS — 10 tests

- [ ] **Step 5: 실물 로제타석에 돌린다**

```
python scripts/spec/verify_rosetta.py
```
Expected: 16쌍 발견. `glow` 는 `ok`(4 정점). 다른 버전(`MDLV0014` 등)은 `SKIP — 미등록 formatFlag`.
**불일치(FAIL)가 0이어야 한다.** FAIL 이 나오면 파서가 틀린 것이므로 고친다.

- [ ] **Step 6: 커밋**

```bash
git add scripts/spec/verify_rosetta.py scripts/spec/tests/test_rosetta.py
git commit -m "obj↔mdl 로제타석 검증기 신설(.mdl 오라클 부재를 소스 대조로 대체)"
```

---

### Task 5: 엔진 심볼 정본 — 유니폼과 렌더타깃

`wallpaper64.exe` 문자열에서 `g_*` 유니폼과 `_rt_*` 렌더타깃을 뽑는다. 이건 셰이더 번역기가 무엇을 알아야 하는지의 목록이다.

**Files:**
- Create: `scripts/spec/measure_engine_symbols.py`
- Create: `spec/engine/uniforms.json` (스크립트가 생성)
- Create: `spec/engine/render-targets.json` (스크립트가 생성)

**Interfaces:**
- Consumes: `specfmt.*`
- Produces: `spec/engine/uniforms.json` (`engine.uniforms`), `spec/engine/render-targets.json` (`engine.renderTargets`)

- [ ] **Step 1: 스크립트 작성**

`scripts/spec/measure_engine_symbols.py`:

```python
"""wallpaper64.exe 에서 엔진 심볼(g_* 유니폼, _rt_* 렌더타깃)을 뽑는다.

PE 파일을 직접 스캔한다. Ghidra 를 거치지 않는 이유는 재현성이다 —
이 스크립트는 WE 설치본만 있으면 어디서든 돈다.
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


def section_map(data):
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    pe32plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    base = struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus else \
        struct.unpack_from("<I", data, opt + 28)[0]
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


def main():
    with open(BIN, "rb") as fh:
        data = fh.read()
    secs = section_map(data)

    def collect(rx):
        out = {}
        for m in rx.finditer(data):
            s = m.group().decode("ascii")
            if s in out:
                continue
            va, sec = va_of(m.start(), secs)
            out[s] = {"va": hex(va) if va else None, "section": sec}
        return out

    uniforms = collect(UNIFORM)
    rts = collect(RT)

    src = specfmt.ev("binary", "wallpaper64.exe 문자열 전수 스캔 (PE 섹션 매핑 포함)")

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.uniforms.count", len(uniforms), "확정", [src]),
        specfmt.entry("engine.uniforms", dict(sorted(uniforms.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "uniforms.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.renderTargets.count", len(rts), "확정", [src]),
        specfmt.entry("engine.renderTargets", dict(sorted(rts.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "render-targets.json"))

    print(f"유니폼 {len(uniforms)}종, 렌더타깃 {len(rts)}종")
    for k in sorted(rts):
        print(f"  {k}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: 실행**

```
python scripts/spec/measure_engine_symbols.py
```
Expected: 유니폼 140종 안팎, 렌더타깃 21종 안팎. `_rt_FullFrameBuffer`, `_rt_shadowAtlas`, `_alias_lightCookie` 가 목록에 있어야 한다.

- [ ] **Step 3: 검증기 통과 확인**

```
python scripts/spec/validate.py
```
Expected: 전 파일 `ok`, 오류 0건

- [ ] **Step 4: 커밋**

```bash
git add scripts/spec/measure_engine_symbols.py spec/engine/
git commit -m "엔진 심볼 정본화(g_* 유니폼·_rt_* 렌더타깃, PE 직접 스캔)"
```

---

### Task 6: `assets/` 동봉과 해시 매니페스트

공유 에셋을 리포에 넣는다. 씬의 대부분이 공유 헤더·텍스처에 의존하는데 패키지가 그걸 동봉하지 않으므로, 이게 없으면 WE 설치가 필수다.

**Files:**
- Create: `scripts/spec/measure_assets.py`
- Create: `spec/assets/inventory.json` (스크립트가 생성)
- Create: `spec/assets/manifest.json` (스크립트가 생성)
- Create: `Sources/WapleRender/Resources/WEAssets/**` (복사)
- Modify: `.gitattributes`
- Modify: `NOTICE`

**Interfaces:**
- Consumes: `specfmt.*`
- Produces: `spec/assets/inventory.json` (`assets.dirBreakdown`, `assets.extensionBreakdown`), `spec/assets/manifest.json` (`assets.fileHashes` — 상대경로 → sha256[:16])

- [ ] **Step 1: `.gitattributes` 에 바이너리 규칙 추가**

현재 `.gitattributes` 는 `* text=auto` 한 줄뿐이다. 76MB 의 `.tex`/`.png`/`.ttf` 가 들어오므로 줄바꿈 정규화가 손대지 않도록 명시한다. 반대로 셰이더는 텍스트로 유지한다.

`.gitattributes` 를 다음으로 만든다:

```
# Auto detect text files and perform LF normalization
* text=auto

# 동봉된 WE 에셋: 바이너리는 정규화 금지(내용이 깨진다)
Sources/WapleRender/Resources/WEAssets/**/*.tex binary
Sources/WapleRender/Resources/WEAssets/**/*.png binary
Sources/WapleRender/Resources/WEAssets/**/*.jpg binary
Sources/WapleRender/Resources/WEAssets/**/*.gif binary
Sources/WapleRender/Resources/WEAssets/**/*.tga binary
Sources/WapleRender/Resources/WEAssets/**/*.ttf binary
Sources/WapleRender/Resources/WEAssets/**/*.otf binary
Sources/WapleRender/Resources/WEAssets/**/*.ttc binary
Sources/WapleRender/Resources/WEAssets/**/*.mdl binary
Sources/WapleRender/Resources/WEAssets/**/*.gxs binary

# 셰이더·JSON 은 텍스트. 단 원문 보존을 위해 정규화하지 않는다
Sources/WapleRender/Resources/WEAssets/**/*.vert -text
Sources/WapleRender/Resources/WEAssets/**/*.frag -text
Sources/WapleRender/Resources/WEAssets/**/*.geom -text
Sources/WapleRender/Resources/WEAssets/**/*.h    -text
Sources/WapleRender/Resources/WEAssets/**/*.json -text
```

셰이더에 `-text` 를 주는 이유: WE 원문은 CRLF 인데 `ShaderPreprocessor` 가 CRLF 를 정규화해서 읽는다. 리포가 임의로 LF 로 바꾸면 원문과 바이트가 달라져 해시 매니페스트가 매번 어긋난다.

- [ ] **Step 2: 측정·복사 스크립트 작성**

`scripts/spec/measure_assets.py`:

```python
"""WE assets/ 를 리포에 동봉하고 인벤토리·해시 매니페스트를 만든다.

해시 매니페스트의 목적은 드리프트 감지다. WE 가 업데이트되면 동봉본이
조용히 낡는데, 매니페스트가 있으면 재측정으로 즉시 알 수 있다.
"""
import collections
import hashlib
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
SRC = os.path.join(WE, "assets")
DST = os.path.join("Sources", "WapleRender", "Resources", "WEAssets")


def sha16(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def walk(root):
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            yield p, os.path.relpath(p, root).replace(os.sep, "/")


def main():
    copy = "--no-copy" not in sys.argv

    if copy:
        if os.path.isdir(DST):
            shutil.rmtree(DST)
        print(f"복사: {SRC} -> {DST}")
        shutil.copytree(SRC, DST)

    by_dir = collections.Counter()
    by_dir_bytes = collections.Counter()
    by_ext = collections.Counter()
    by_ext_bytes = collections.Counter()
    hashes = {}
    total = 0

    for path, rel in walk(DST if copy else SRC):
        size = os.path.getsize(path)
        total += size
        top = rel.split("/")[0]
        by_dir[top] += 1
        by_dir_bytes[top] += size
        ext = os.path.splitext(rel)[1].lower() or "(없음)"
        by_ext[ext] += 1
        by_ext_bytes[ext] += size
        hashes[rel] = sha16(path)

    src_ev = specfmt.ev("asset", f"{SRC} (WE 2.8.42)")

    specfmt.dump(specfmt.doc("scripts/spec/measure_assets.py", [
        specfmt.entry("assets.fileCount", len(hashes), "확정", [src_ev]),
        specfmt.entry("assets.totalBytes", total, "확정", [src_ev]),
        specfmt.entry("assets.dirBreakdown",
                      {k: {"files": by_dir[k], "bytes": by_dir_bytes[k]}
                       for k in sorted(by_dir)}, "확정", [src_ev]),
        specfmt.entry("assets.extensionBreakdown",
                      {k: {"files": by_ext[k], "bytes": by_ext_bytes[k]}
                       for k, _ in by_ext.most_common()}, "확정", [src_ev]),
        specfmt.entry("assets.bundledAt", DST.replace(os.sep, "/"), "확정",
                      [specfmt.ev("file", DST.replace(os.sep, "/"),
                                  "앱 번들 동봉 위치. 해석 순서상 마지막 폴백")]),
    ]), os.path.join("spec", "assets", "inventory.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_assets.py", [
        specfmt.entry("assets.fileHashes", hashes, "확정",
                      [specfmt.ev("asset", "sha256 앞 16자리",
                                  "WE 업데이트 시 드리프트 감지용")]),
    ]), os.path.join("spec", "assets", "manifest.json"))

    print(f"파일 {len(hashes)}개, {total / 1024 / 1024:.1f} MB")
    for k in sorted(by_dir):
        print(f"  {k:12} {by_dir[k]:5}개  {by_dir_bytes[k] / 1024 / 1024:8.2f} MB")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: 실행 — 복사 + 매니페스트**

```
python scripts/spec/measure_assets.py
```
Expected: `파일 2940개, 75.8 MB`. 디렉터리별로 `materials` 586 / `effects` 1041 / `presets` 880 / `fonts` 19 / `shaders` 137 이 나온다.

- [ ] **Step 4: 동봉본 무결성 확인**

```
python -c "import os; d=r'Sources/WapleRender/Resources/WEAssets'; print('common.h:', os.path.exists(d+'/shaders/common.h')); print('files:', sum(len(f) for _,_,f in os.walk(d)))"
```
Expected: `common.h: True`, `files: 2940`

- [ ] **Step 5: 검증기 통과 확인**

```
python scripts/spec/validate.py
```
Expected: 전 파일 `ok`, 오류 0건

- [ ] **Step 6: `NOTICE` 에 동봉 고지 추가**

`NOTICE` 의 `## 1. RePKG — MIT` **앞에** 다음 절을 삽입한다:

```markdown
## 0. Wallpaper Engine 공유 에셋 — 동봉

Waple 은 Wallpaper Engine **2.8.42** 의 공유 에셋(`assets/`)을
`Sources/WapleRender/Resources/WEAssets/` 에 원문 그대로 동봉한다.

동봉하는 이유는 기술적이다. 워크샵 배경 패키지는 공유 셰이더 헤더
(`shaders/common.h` 등)와 공유 파티클 텍스처를 **동봉하지 않는다**(코퍼스 162개
전수 확인, 0건). 그래서 이 에셋이 없으면 대부분의 씬 배경이 불완전하게 그려진다.

- 출처: Wallpaper Engine 2.8.42 설치본의 `assets/` 디렉터리
- 파일 목록과 해시: [spec/assets/manifest.json](spec/assets/manifest.json)
- 구성 통계: [spec/assets/inventory.json](spec/assets/inventory.json)

동봉본에 포함된 서드파티 폰트는 원 라이선스 파일을 함께 유지한다
(`assets/fonts/SIL Open Font License.txt`, `assets/fonts/RobotoMono-Regular License.txt`).

Wallpaper Engine 은 해당 권리자의 저작물이며 Waple 은 비공식 프로젝트다.
```

- [ ] **Step 7: 커밋을 두 번으로 나눈다**

성격이 다르므로 나눈다(리포 관례).

```bash
git add .gitattributes scripts/spec/measure_assets.py spec/assets/
git commit -m "에셋 인벤토리·해시 매니페스트와 바이너리 정규화 규칙 추가"

git add Sources/WapleRender/Resources/WEAssets NOTICE
git commit -m "WE 2.8.42 공유 에셋 동봉(패키지가 공유 헤더·텍스처를 담지 않아 씬이 불완전했다)"
```

---

### Task 7: 문서 연결과 재현 확인

정본이 문서 체계에 연결되지 않으면 다음 사람이 못 찾는다. 그리고 전체를 한 번 재현해 드리프트가 없는지 본다.

**Files:**
- Modify: `docs/README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: Task 1~6 의 산출물 전부
- Produces: 없음(문서)

- [ ] **Step 1: 전체 재현 — 정본이 재생성돼도 같은지 확인**

```
git status --short
python scripts/spec/measure_binaries.py
python scripts/spec/measure_corpus.py
python scripts/spec/measure_engine_symbols.py
python scripts/spec/measure_assets.py --no-copy
git status --short
```
Expected: 마지막 `git status` 가 **비어 있어야 한다**. 재실행으로 파일이 바뀌면
측정에 비결정성이 있다는 뜻이므로 원인(정렬 누락, 딕셔너리 순서 등)을 찾아 고친다.

- [ ] **Step 2: 전체 테스트**

```
python scripts/spec/tests/test_validate.py
python scripts/spec/tests/test_rosetta.py
python scripts/spec/validate.py
python scripts/spec/verify_rosetta.py
```
Expected: 전부 통과, `verify_rosetta` 의 불일치 0건

- [ ] **Step 3: `docs/README.md` 색인에 추가**

`## 현행 문서` 표에 다음 행을 추가한다:

```markdown
| [../spec/README.md](../spec/README.md) | WE 2.8.42 정본 — 바이너리·코퍼스·포맷·엔진 심볼·에셋. 근거 필수, 재측정 스크립트 동반 |
```

`## 먼저 볼 것` 표 아래에 다음 문단을 추가한다:

```markdown
엔진 이식 프로그램의 차터와 스펙은
[superpowers/specs/](superpowers/specs/) 에 있다. 정본 데이터는 리포 루트
[../spec/](../spec/) 이다.
```

- [ ] **Step 4: `AGENTS.md` 에 정본 규약 안내 추가**

`## 관례` 절 **앞에** 다음을 삽입한다:

```markdown
## 정본(spec/)

WE 동작에 대한 사실은 코드 주석이 아니라 [spec/](spec/) 에 둔다. 이전에
역공학 산출물(`analysis/`)이 통째로 사라져 근거가 주석에만 남은 적이 있다 —
지금 코드가 인용하는 `analysis/decompiled/all/...` 은 리포에 없다.

- 모든 항목에 **근거가 필수**다. 없으면 `scripts/spec/validate.py` 가 거부한다.
- 상태는 `확정`(직접 측정 + 재현 스크립트) / `보고`(정찰, 미재현) / `추정` 셋뿐이고,
  **`확정` 만 테스트를 생성한다.**
- WE 설치본이 있으면 `python scripts/spec/measure_*.py` 로 전부 재생성된다.
  재생성 후 `git status` 가 비어야 정상이다.
- 공유 에셋은 `Sources/WapleRender/Resources/WEAssets/` 에 동봉돼 있다.
  WE 가 업데이트되면 `spec/assets/manifest.json` 의 해시가 어긋나 드리프트가 드러난다.
```

- [ ] **Step 5: 커밋**

```bash
git add docs/README.md AGENTS.md
git commit -m "문서 색인에 spec/ 정본 연결(사람·AI 진입점에서 찾을 수 있게)"
```

---

## Self-Review

**1. 스펙 커버리지** — 스펙 0(`docs/superpowers/specs/2026-07-31-spec-00-canon-foundation.md`) 대비:

| 스펙 항목 | 이 계획 | 비고 |
| --- | --- | --- |
| §3 `spec/` 개설 + 규약 | Task 1 | ✅ |
| §3-1 항목 스키마 | Task 1 | ✅ |
| §3-2 evidence 정책 | Task 1 (README) | ✅ |
| §4 `assets/` 동봉 | Task 6 | ✅ |
| §4-3 4단 폴백 | **미포함** | Swift 변경 — 계획 B |
| §4-4 결손 0건 확인 | **미포함** | Mac 필요 — 계획 B |
| §5 텍스처 오라클 | Task 3 (반증 사실만 정본화) | 스펙이 이미 범위 밖으로 뺐다 |
| §6 이탈 3건 교정 | **미포함** | Swift 변경 — 계획 B |
| §7 BACKLOG 정리 | **미포함** | 계획 B (코드 변경과 함께) |
| §8-2 L3 골든 | **미포함** | Mac 진행 중 |
| §10 순서 3·4단계 | Task 1~7 | ✅ |

**의도적 제외**를 계획 서두에 명시했다. 이 계획은 스펙 0의 Windows 실행 가능분만 다루고, 나머지는 계획 B 다.

**2. 플레이스홀더 스캔** — "TBD"/"적절히"/"에러 처리 추가" 류 없음. 모든 코드 단계에 실제 코드 블록이 있다.

**3. 타입 정합성**
- `specfmt.entry(id, value, status, evidence)` — Task 1 정의, Task 2·3·5·6 에서 동일 시그니처로 호출 ✅
- `specfmt.ev(kind, ref, note=None)` — Task 1 정의, 이후 동일 ✅
- `specfmt.doc(generated_by, entries, extra=None)` — Task 1 정의, Task 2 가 `extra=` 사용 ✅
- `validate.validate_doc(d, path)` — Task 1 테스트와 구현 시그니처 일치 ✅
- `verify_rosetta.parse_mdl_v4` 반환 키(`version`/`formatFlag`/`meshCount`/`material`/`vertexBytes`/`stride`/`positions`/`uvs`) — 테스트·구현·`main()` 에서 동일 ✅
- `STRIDE_BY_FLAG` 는 `formatFlag & 0xFF` 로 조회 — 테스트가 `0x09` 를 그대로 넣으므로 일치 ✅

---

## 실행 후 다음

계획 A 가 끝나면 **계획 B**(Swift 변경, Mac 필요)를 쓴다. 내용:
- `BaseAssetsSettings` 4단 폴백(동봉본을 마지막 폴백으로)
- 에셋 결손 0건 확인
- `g_TexelSize` 이원 규약 제거, `texRes` 4성분 실전달, `g_LightAmbientColor` 배선
- 이탈 3건(GGX 바닥값·`nl>0`·블렌드 엡실론) 유지/제거 결정 반영
- 하드 오라클 강화(검정 프레임 거부)
- `AGENTS.md` 테스트 기준값 갱신, BACKLOG 정리

계획 B 는 Mac 골든 기준선이 확보된 뒤에 시작한다 — 그게 없으면 변경의 영향을 판정할 수 없다.
