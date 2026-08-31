import ast
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_prose_cross_ref_with_glob_target_is_not_a_dangling_id(self):
        """산문 crossRef 는 문장 전체가 후보 id 가 되면 안 된다 — 2026-08-30 이전 유일한 경고.

        `material.util.*` 는 글로브라 ID_IN_PROSE 가 못 뽑는다. 종전 폴백은 마침표만 있으면
        90자 문장을 통째로 후보로 넣어 절대 해석 못 하는 경고를 영구히 냈다. 영구 오탐 하나가
        채널을 죽인다(그 뒤에 들어오는 진짜 끊긴 링크와 구별이 안 된다).
        """
        docs = {
            "spec/a.json": self._doc("g1", [self._e("misc.x", value={
                "crossRef": "materials/util 상세 카탈로그는 spec/assets/material-schema.json 의 "
                            "material.util.* 가 정본이다. 여기서는 대조용으로만 같이 센다"})]),
            "spec/b.json": self._doc("g2", [self._e("material.util.catalog")]),
        }
        self.assertEqual(validate.cross_document_checks(docs), [])

    def test_single_dot_bare_id_is_still_checked(self):
        """폴백을 좁혔어도 맨몸 단일점 id 는 계속 봐야 한다 — 정본에 147종이 있고
        ID_IN_PROSE 는 점 2개 이상을 요구하므로 이 폴백만이 그것들을 검사한다."""
        docs = {"spec/a.json": self._doc("g1", [
            self._e("x.y", value={"crossRef": "assets.nonexistent"})])}
        warns = validate.cross_document_checks(docs)
        self.assertTrue(any("assets.nonexistent" in w for w in warns), warns)

    def test_single_dot_bare_id_that_exists_is_clean(self):
        docs = {
            "spec/a.json": self._doc("g1", [self._e("x.y", value={"crossRef": "assets.fileCount"})]),
            "spec/b.json": self._doc("g2", [self._e("assets.fileCount")]),
        }
        self.assertEqual(validate.cross_document_checks(docs), [])


class TestSupersededIDs(unittest.TestCase):
    """묘비 집합에는 **id** 가 담겨야 한다 — hedge_triage 가 `e['id'] in tombstones` 로 본다."""

    def _docs(self, sup):
        return {"spec/a.json": {"weVersion": "2.8.42", "generatedBy": "g", "entries": [
            {"id": "x.y", "value": {"supersedes": sup}, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "r"}]}]}}

    def test_bare_id_is_collected(self):
        self.assertEqual(validate.superseded_ids(self._docs("engine.bloom.hdr.upsampleWeightUnknown")),
                         {"engine.bloom.hdr.upsampleWeightUnknown"})

    def test_id_is_extracted_from_prose(self):
        """산문 묘비에서 id 를 뽑는다. 종전엔 문장을 통째로 담아 어떤 항목도 못 맞췄다."""
        prose = ("spec/formats/tex.json format.tex.transcodeDecodes — 그 5표본은 "
                 "재측정으로 대체됐다")
        self.assertEqual(validate.superseded_ids(self._docs(prose)),
                         {"format.tex.transcodeDecodes"})

    def test_list_form_is_collected(self):
        self.assertEqual(
            validate.superseded_ids(self._docs(["a.b.c", "산문 안의 d.e.f 를 대체한다"])),
            {"a.b.c", "d.e.f"})


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
        # 경로로 해석할 수 없는 코퍼스 산문과 임의 외부 경로는 검사 대상이 아니다.
        # WE 설치 트리의 정형 경로는 아래 TestSiblingWERefs 가 별도로 검사한다.
        for ref in (r"Z:\SteamLibrary\steamapps\common\wallpaper_engine\assets",
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


class TestSiblingWERefs(unittest.TestCase):
    """짝 저장소의 wallpaper_engine/ 근거도 경로로 해석해 존재를 검사한다.

    종전 repo_ref_path 는 이 부류를 전부 None 으로 버렸다. 현재 정본에서
    wallpaper64.exe 하나만 236회 인용되므로, 짝 저장소가 있는 개발 머신에서도
    근거를 지워 보고 오류 0 이 나던 구멍이다.
    """

    def test_known_install_tree_forms_are_normalized(self):
        cases = {
            "wallpaper64.exe FUN_140099980 @ 0x140099980": "wallpaper64.exe",
            "bin/scenescript64.dll 0x180012340": "bin/scenescript64.dll",
            "shaders/common_blending.h:18-25": "assets/shaders/common_blending.h",
            "wallpaper_engine/ui/dist/scripts/scripts.js": "ui/dist/scripts/scripts.js",
        }
        for ref, want in cases.items():
            with self.subTest(ref=ref):
                self.assertEqual(validate.we_ref_path(ref), want)

    def test_existing_and_missing_sibling_refs_are_distinguished(self):
        with tempfile.TemporaryDirectory() as td:
            os.makedirs(os.path.join(td, "bin"))
            open(os.path.join(td, "wallpaper64.exe"), "wb").close()
            with mock.patch.object(validate, "WE_ROOT", td):
                self.assertEqual(
                    validate.validate_doc(ref_doc("wallpaper64.exe FUN_1400"), "t.json"), [])
                errs = validate.validate_doc(ref_doc("bin/scenescript64.dll FUN_1800"), "t.json")
        self.assertTrue(any("WE 설치/짝 저장소에 없다" in e for e in errs), errs)

    def test_missing_default_sibling_does_not_break_portable_validation(self):
        with tempfile.TemporaryDirectory() as td:
            missing = os.path.join(td, "not-cloned", "wallpaper_engine")
            with mock.patch.object(validate, "WE_ROOT", missing):
                self.assertEqual(
                    validate.validate_doc(ref_doc("wallpaper64.exe FUN_1400"), "t.json"), [])

    def test_current_canon_maps_at_least_the_audited_sibling_population(self):
        mapped = 0
        spec_root = os.path.join(validate.REPO_ROOT, "spec")
        for dirpath, _dirs, files in os.walk(spec_root):
            for filename in files:
                path = os.path.join(dirpath, filename)
                if not filename.endswith(".json") or not validate.is_canon_path(path):
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        canon = json.load(fh)
                except (OSError, json.JSONDecodeError):
                    continue
                for entry in canon.get("entries", []):
                    for evidence in entry.get("evidence", []) if isinstance(entry, dict) else []:
                        if isinstance(evidence, dict) and validate.we_ref_path(evidence.get("ref")) is not None:
                            mapped += 1
        self.assertGreaterEqual(mapped, 349,
                                "감사에서 실재 확인한 짝 저장소 ref 349건보다 매핑 그물이 작아졌다")

    def test_evidence_census_keeps_unstructured_refs_visible(self):
        d = doc(entries=[
            {"id": "a.repo", "value": 1, "status": "확정",
             "evidence": [{"kind": "file", "ref": "scripts/spec/validate.py"}]},
            {"id": "a.we", "value": 1, "status": "확정",
             "evidence": [{"kind": "binary", "ref": "wallpaper64.exe FUN_1400"}]},
            {"id": "a.prose", "value": 1, "status": "확정",
             "evidence": [{"kind": "corpus", "ref": "워크샵 전수"}]},
        ])
        self.assertEqual(validate.evidence_ref_census({"t.json": d}),
                         {"total": 3, "repo": 1, "we": 1, "unstructured": 1})

    def test_known_deleted_a4_document_is_not_cited_by_canon_or_generator(self):
        needle = "A4-headers-blending-fog.md"
        for relative in ("spec/engine/mul-convention.json",
                         "scripts/spec/measure_mul_convention.py"):
            with self.subTest(relative=relative):
                with open(os.path.join(validate.REPO_ROOT, relative), encoding="utf-8") as fh:
                    self.assertNotIn(needle, fh.read())


class TestAuditCanonRegressions(unittest.TestCase):
    """2026-08-31 감사에서 실제로 재현된 정본/생성기 드리프트를 고정한다."""

    @staticmethod
    def _entry(path, eid):
        with open(os.path.join(validate.REPO_ROOT, path), encoding="utf-8") as fh:
            doc = json.load(fh)
        return next(e for e in doc["entries"] if e["id"] == eid)

    @staticmethod
    def _generator_file_refs(source, eid):
        tree = ast.parse(source)
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "entry" and len(node.args) >= 4
                    and isinstance(node.args[0], ast.Constant) and node.args[0].value == eid):
                continue
            refs = []
            for child in ast.walk(node.args[3]):
                if (isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute)
                        and child.func.attr == "ev" and len(child.args) >= 2):
                    try:
                        kind = ast.literal_eval(child.args[0])
                        ref = ast.literal_eval(child.args[1])
                    except (ValueError, TypeError):
                        continue
                    if kind == "file":
                        refs.append(ref)
            return refs
        raise AssertionError(f"생성기에서 {eid} 엔트리를 못 찾았다")

    def test_material_gap_file_evidence_uses_stable_symbol_anchors(self):
        expected = {
            "waple.gap.fboFormatDropped":
                "Sources/WapleRender/SceneRendererResources.swift `static func metalFormat(_ f: EffectManifest.FBO.Format?, hdr: Bool)`",
            "waple.gap.fboClearAndUnique":
                "Sources/WapleRender/SceneRendererFrameEncoder.swift `uniqueStore.pendingClear` 순회 — `let c = fboSpecs[i].clearColor ?? SIMD4<Float>(0, 0, 0, 0)`",
            "waple.gap.strictJSON": "Sources/WapleCore/EffectManifest.swift",
            "waple.gap.bindPrevAlias":
                "Sources/WapleRender/SceneRendererResources.swift `buildPassBindings` — `if let idx = fboIndex[b.name]` … `binds.append((b.index, -1))`",
            "waple.gap.cullmodeInMaterialPass":
                "Sources/WapleCore/SceneDocument.swift `parseMaterialPassProperties` — cullmode 미참조",
            "waple.gap.comboCaseFolding":
                "Sources/WapleCore/SceneDocument.swift `result.materialCombos[k] = i` (원문 대소문자 보존)",
        }
        with open(os.path.join(validate.REPO_ROOT, "scripts/spec/measure_material_schema.py"),
                  encoding="utf-8") as fh:
            generator = fh.read()
        for eid, want in expected.items():
            with self.subTest(eid=eid):
                refs = [ev["ref"] for ev in self._entry("spec/assets/material-schema.json", eid)["evidence"]
                        if ev["kind"] == "file"]
                self.assertEqual(refs, [want])
                self.assertEqual(self._generator_file_refs(generator, eid), [want],
                                 "정본만 고치면 다음 코퍼스 재측정이 stale 줄 번호를 되살린다")

        tree = ast.parse(generator)
        line_refs = []
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "ev" and len(node.args) >= 2):
                continue
            try:
                kind, ref = ast.literal_eval(node.args[0]), ast.literal_eval(node.args[1])
            except (ValueError, TypeError):
                continue
            if kind == "file" and validate.ref_max_line(ref) is not None:
                line_refs.append(ref)
        self.assertEqual(line_refs, [], "줄번호 금지 선언과 generator evidence가 다시 모순된다")

    def test_version_gate_pigeonhole_minima_include_missing_versions(self):
        import measure_scene_schema

        versions = {"5": 63, "1": 33, "4": 32, "3": 31, "None": 3}
        key_counts = {"hdr": 159, "bloomtint": 142,
                      "perspectiveoverridefov": 130, "windenabled": 109}
        got = measure_scene_schema.version_gate_counterexample_minima(versions, key_counts)
        self.assertEqual(got, {"hdr": 30, "bloomtint": 13,
                               "perspectiveoverridefov": 1, "windenabled": 11})

        impact = self._entry("spec/corpus/scene-schema.json", "waple.gapImpact")["value"]
        why = next(x["why"] for x in impact["notGaps"] if x["what"].startswith("scene.version"))
        self.assertIn("최소 30씬", why)
        self.assertIn("최소 11씬", why)
        self.assertNotIn("최소 33씬", why)
        self.assertNotIn("최소 14씬", why)

    def test_uniform_scanner_prefers_exact_nul_terminated_name(self):
        import measure_engine_symbols

        data = b"g_Array[\0padding\0g_Array\0g_Texture([\\d]+)\0"
        secs = [(".rdata", 0, len(data), 0x140000000)]
        got = measure_engine_symbols.collect_symbols(data, secs, measure_engine_symbols.UNIFORM)
        self.assertEqual(got["g_Array"]["va"], hex(0x140000000 + data.index(b"g_Array\0")))
        self.assertNotIn("coordinateKind", got["g_Array"])
        self.assertEqual(got["g_Texture"]["coordinateKind"], "embeddedToken")

        texture = self._entry("spec/engine/uniforms.json", "engine.uniforms")["value"]["g_Texture"]
        self.assertEqual(texture["coordinateKind"], "embeddedToken")


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
