import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import specfmt
import validate


def doc(**over):
    base = {
        "weVersion": "2.8.42",
        # 실재 경로여야 한다 — validate 가 generatedBy 가 가리키는 스크립트의 존재를 검사한다.
        "generatedBy": "scripts/spec/validate.py",
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


class TestCanonPathFilter(unittest.TestCase):
    """spec/ 아래에 정본이 아닌 것도 산다 — 캡처 산출물을 정본으로 검사하면 안 된다."""

    def test_golden_artifacts_are_not_canon(self):
        self.assertFalse(validate.is_canon_path(os.path.join("spec", "golden", "snapshot",
                                                             "baseline-x", "manifest.json")))

    def test_golden_artifacts_are_not_canon_posix(self):
        self.assertFalse(validate.is_canon_path("spec/golden/snapshot/baseline-x/manifest.json"))

    def test_canon_docs_are_canon(self):
        for p in ("spec/binaries.json", "spec/formats/tex.json",
                  "spec/engine/uniforms.json", "spec/assets/manifest.json"):
            self.assertTrue(validate.is_canon_path(p), p)

    def test_schema_is_not_canon(self):
        self.assertFalse(validate.is_canon_path("spec/schema.json"))

    def test_golden_analysis_docs_are_canon(self):
        """golden/ 을 통째로 빼면 이 문서들이 조용히 검사에서 빠진다(2026-08-01 실제 사고)."""
        self.assertTrue(validate.is_canon_path("spec/golden/gate-analysis.json"))
        self.assertTrue(validate.is_canon_path("spec/golden/nondeterminism.json"))


class TestCrossDocChecks(unittest.TestCase):
    """검증기가 문서 하나만 보면 영역 간 모순을 못 잡는다 — 실제로 4건이 오류 0 을 통과했다."""

    def _doc(self, gen, entries):
        return {"weVersion": "2.8.42", "generatedBy": gen, "entries": entries}

    def _e(self, eid, value="v", status="확정", ev=None):
        return {"id": eid, "value": value, "status": status,
                "evidence": ev or [{"kind": "corpus", "ref": "r"}]}

    def test_same_id_in_two_files_is_reported(self):
        docs = {
            "spec/a.json": self._doc("g1", [self._e("format.tex.layout")]),
            "spec/b.json": self._doc("g2", [self._e("format.tex.layout")]),
        }
        warns = validate.cross_document_checks(docs)
        self.assertTrue(any("format.tex.layout" in w for w in warns),
                        f"같은 id 가 두 파일에 있는데 안 잡혔다: {warns}")

    def test_distinct_ids_are_clean(self):
        docs = {
            "spec/a.json": self._doc("g1", [self._e("format.tex.layout")]),
            "spec/b.json": self._doc("g2", [self._e("format.mdl.layout")]),
        }
        self.assertEqual(validate.cross_document_checks(docs), [])

    def test_dangling_cross_ref_is_reported(self):
        docs = {
            "spec/a.json": self._doc("g1", [
                self._e("x.y", value={"crossRef": "format.tex.nonexistent"})]),
        }
        warns = validate.cross_document_checks(docs)
        self.assertTrue(any("nonexistent" in w for w in warns), warns)

    def test_resolvable_cross_ref_is_clean(self):
        docs = {
            "spec/a.json": self._doc("g1", [
                self._e("x.y", value={"crossRef": "format.tex.layout"})]),
            "spec/b.json": self._doc("g2", [self._e("format.tex.layout")]),
        }
        self.assertEqual(validate.cross_document_checks(docs), [])

    def test_supersedes_target_must_exist(self):
        docs = {
            "spec/a.json": self._doc("g1", [
                self._e("x.y", value={"supersedes": "format.tex.gone"})]),
        }
        warns = validate.cross_document_checks(docs)
        self.assertTrue(any("gone" in w for w in warns), warns)


class TestHedgeTriage(unittest.TestCase):
    """확정 항목 안에 '미확인/추정' 이 섞이면 보고한다. 실패는 아니고 검토 대상이다."""

    def test_hedge_in_confirmed_value_is_flagged(self):
        e = {"id": "a.b", "value": {"note": "의미는 미확인"}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}
        hits, exempt = validate.hedge_triage([e], "t.json")
        self.assertEqual(len(hits), 1)
        self.assertIn("미확인", hits[0])
        self.assertEqual(exempt, 0)

    def test_hedge_in_report_status_is_not_flagged(self):
        e = {"id": "a.b", "value": {"note": "의미는 미확인"}, "status": "보고",
             "evidence": [{"kind": "recon", "ref": "r"}]}
        self.assertEqual(validate.hedge_triage([e], "t.json"), ([], 0))

    def test_clean_confirmed_value_is_not_flagged(self):
        e = {"id": "a.b", "value": {"count": 162}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}
        self.assertEqual(validate.hedge_triage([e], "t.json"), ([], 0))

    # ── 묘비 면제 ────────────────────────────────────────────────────────────
    # 답이 나온 뒤에도 당시 서술을 남기는 항목(`supersedes` 로 대체된 id)은 헤지가
    # 정당하다. 다만 **면제는 개수로 보고**되고, 대체 항목 없이는 절대 면제되지 않는다.

    def test_tombstone_hedge_is_exempted_and_counted(self):
        e = {"id": "a.old", "value": {"note": "의미는 미확인"}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}
        hits, exempt = validate.hedge_triage([e], "t.json", {"a.old"})
        self.assertEqual(hits, [])
        self.assertEqual(exempt, 1, "면제는 조용히 사라지면 안 되고 개수로 남아야 한다")

    def test_tombstone_set_comes_only_from_supersedes(self):
        docs = {
            "a.json": doc(entries=[
                {"id": "a.old", "value": {"note": "미확인"}, "status": "확정",
                 "evidence": [{"kind": "corpus", "ref": "r"}]},
                {"id": "a.new", "value": {"supersedes": "a.old"}, "status": "확정",
                 "evidence": [{"kind": "corpus", "ref": "r"}]}]),
        }
        self.assertEqual(validate.superseded_ids(docs), {"a.old"})

    def test_without_superseding_entry_the_hedge_still_fires(self):
        """면제가 스위치가 아니라는 증명 — 대체 항목을 지우면 헤지가 되살아난다."""
        docs = {"a.json": doc(entries=[
            {"id": "a.old", "value": {"note": "미확인"}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}])}
        tombs = validate.superseded_ids(docs)
        self.assertEqual(tombs, set())
        hits, exempt = validate.hedge_triage(docs["a.json"]["entries"], "a.json", tombs)
        self.assertEqual(len(hits), 1)
        self.assertEqual(exempt, 0)

    def test_supersedes_may_be_a_list(self):
        docs = {"a.json": doc(entries=[
            {"id": "a.new", "value": {"supersedes": ["a.old1", "a.old2"]}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}])}
        self.assertEqual(validate.superseded_ids(docs), {"a.old1", "a.old2"})

    def test_non_dict_value_does_not_crash_superseded_scan(self):
        docs = {"a.json": doc(entries=[
            {"id": "a.x", "value": 162, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}])}
        self.assertEqual(validate.superseded_ids(docs), set())


def ref_doc(ref):
    return doc(entries=[{"id": "x.y", "value": 1, "status": "확정",
                         "evidence": [{"kind": "file", "ref": ref}]}])


class TestDanglingRepoRefs(unittest.TestCase):
    """리포 안을 가리키는 근거는 실제로 있어야 한다.

    이 검사가 없어서 gate-analysis.json 이 재베이스라인으로 지워진
    baseline-618d16f/manifest.json 을 근거로 인용한 채 오류 0 으로 통과했다.
    """

    def test_existing_repo_path_passes(self):
        self.assertEqual(validate.validate_doc(ref_doc("scripts/spec/validate.py"), "t.json"), [])

    def test_existing_repo_path_with_line_citation_passes(self):
        for ref in ("scripts/spec/validate.py:10",
                    "scripts/spec/validate.py:10-20",
                    "scripts/spec/validate.py:10,11,12",
                    "scripts/spec/validate.py:10-20,"):
            with self.subTest(ref=ref):
                self.assertEqual(validate.validate_doc(ref_doc(ref), "t.json"), [])

    def test_missing_repo_path_fails(self):
        errs = validate.validate_doc(ref_doc("spec/golden/snapshot/baseline-deadbee/manifest.json"),
                                     "t.json")
        self.assertTrue(any("리포에 없다" in e for e in errs), errs)

    def test_outside_repo_ref_is_not_checked(self):
        # 설치본·코퍼스·바이너리는 머신마다 다르다 — 검사 대상이 아니다.
        for ref in (r"Z:\SteamLibrary\steamapps\common\wallpaper_engine\assets",
                    "wallpaper64.exe FUN_140099980 @ 0x140099980",
                    "162 pkg 전수"):
            with self.subTest(ref=ref):
                self.assertEqual(validate.validate_doc(ref_doc(ref), "t.json"), [])

    def test_glob_ref_checks_only_the_prefix_directory(self):
        # 존재하는 디렉터리 아래의 글로브는 통과해야 한다(오탐 방지).
        self.assertEqual(validate.validate_doc(ref_doc("scripts/spec/*.py"), "t.json"), [])
        self.assertEqual(validate.validate_doc(ref_doc("scripts/spec/tests/**/*.py"), "t.json"), [])
        # 없는 디렉터리 아래의 글로브는 잡혀야 한다.
        errs = validate.validate_doc(ref_doc("Sources/NoSuchTarget/**/*.swift"), "t.json")
        self.assertTrue(any("리포에 없다" in e for e in errs), errs)

    def test_prose_after_path_is_ignored(self):
        self.assertEqual(
            validate.validate_doc(ref_doc("scripts/spec/validate.py 의 죽은 참조 검사"), "t.json"), [])


class TestGeneratedByExists(unittest.TestCase):
    """`generatedBy` 가 가리키는 스크립트가 실재하는지.

    종전 검사는 "비어있지 않음" 만 봤다 — `evidence[].ref` 는 `os.path.exists` 로 검사하면서
    generatedBy 는 안 보는 강도 비대칭이었다. 스크립트 이름이 바뀌거나 지워지면 그 문서는
    재생성 방법을 잃는데 아무도 울지 않았다.
    """

    def test_missing_script_is_error(self):
        errs = validate.validate_doc(doc(generatedBy="scripts/spec/nope.py"), "t.json")
        self.assertTrue(any("generatedBy 가 가리키는 스크립트가 없다" in e for e in errs), errs)

    def test_existing_script_passes(self):
        self.assertEqual(validate.validate_doc(doc(generatedBy="scripts/spec/validate.py"), "t.json"), [])

    def test_non_path_description_is_allowed(self):
        """손 작성 문서는 경로가 아닌 설명을 싣는 것이 이 리포의 관례다
        (`spec/engine/deviations.json` = "손 작성 — …"). `.py` 로 끝나는 것만 검사한다."""
        self.assertEqual(validate.validate_doc(doc(generatedBy="손 작성 — 2026-08-19 수기 정리"), "t.json"), [])

    def test_empty_is_still_an_error(self):
        errs = validate.validate_doc(doc(generatedBy=""), "t.json")
        self.assertTrue(any("generatedBy 가 없다" in e for e in errs), errs)


class TestRefLineNumbers(unittest.TestCase):
    """근거 ref 의 줄 인용이 그 파일에 실재하는가.

    2026-08-20 에 실제로 터진 부류다 — `measure_oracle_gate.py` 가 줄 번호는
    `Snapshot.swift`(209줄)에서 뽑고 파일명은 `SnapshotCompare.swift`(153줄)를 붙여,
    **확정 등급 항목 셋이 없는 줄을 가리켰다**. 종전 검사기는 `:숫자` 를 잘라내고 파일
    존재만 봤기 때문에 오류 0 으로 통과했다.
    """

    def test_extracts_max_line_from_every_citation_form(self):
        self.assertEqual(validate.ref_max_line("Sources/a.swift:12"), 12)
        self.assertEqual(validate.ref_max_line("Sources/a.swift:12-34"), 34)
        self.assertEqual(validate.ref_max_line("Sources/a.h:114,115,119"), 119)
        self.assertEqual(validate.ref_max_line("Sources/a.swift:1254-1257,"), 1257)
        self.assertIsNone(validate.ref_max_line("Sources/a.swift"))
        self.assertIsNone(validate.ref_max_line(None))

    def test_line_past_end_of_file_is_an_error(self):
        # validate.py 자신을 대상으로 삼는다 — 파일 길이를 계산해 확실히 넘는 줄을 만든다.
        rel = "scripts/spec/validate.py"
        with open(os.path.join(validate.REPO_ROOT, rel), "rb") as fh:
            total = sum(1 for _ in fh)
        bad = doc()
        bad["entries"][0]["evidence"] = [{"kind": "file", "ref": f"{rel}:{total + 1}"}]
        errs = validate.validate_doc(bad, "t.json")
        self.assertTrue(any("없는 줄을 가리킨다" in e for e in errs), errs)

        good = doc()
        good["entries"][0]["evidence"] = [{"kind": "file", "ref": f"{rel}:{total}"}]
        self.assertEqual(
            [e for e in validate.validate_doc(good, "t.json") if "없는 줄" in e], [])


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
