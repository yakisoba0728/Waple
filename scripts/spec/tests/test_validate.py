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
        hits = validate.hedge_triage([e], "t.json")
        self.assertEqual(len(hits), 1)
        self.assertIn("미확인", hits[0])

    def test_hedge_in_report_status_is_not_flagged(self):
        e = {"id": "a.b", "value": {"note": "의미는 미확인"}, "status": "보고",
             "evidence": [{"kind": "recon", "ref": "r"}]}
        self.assertEqual(validate.hedge_triage([e], "t.json"), [])

    def test_clean_confirmed_value_is_not_flagged(self):
        e = {"id": "a.b", "value": {"count": 162}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}
        self.assertEqual(validate.hedge_triage([e], "t.json"), [])


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
