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
