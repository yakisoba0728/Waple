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

    def test_rejects_unconfirmed_version(self):
        # v17+ 는 메시마다 AABB 가 붙어 이 레이아웃이 통하지 않는다.
        # 억지로 읽어 '통과' 를 만들지 않도록 명시적으로 거부한다.
        data = bytearray(make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)]))
        data[:8] = b"MDLV0023"
        with self.assertRaises(ValueError) as cm:
            R.parse_mdl_v4(bytes(data))
        self.assertIn("미확정", str(cm.exception))


class TestCompare(unittest.TestCase):
    """비교는 순서 무관이어야 한다 — MDL 은 면 전개 순서로 정점을 굽고 복제한다."""

    def test_matching_geometry_has_no_errors(self):
        pos = [(-3.285059, -3.285059, -0.554853)]
        uv = [(0.0, 0.0)]
        obj = {"v": pos, "vt": uv, "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4(pos, uv))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_reordered_vertices_pass(self):
        # 같은 집합을 순서만 바꿔 구운 것은 통과해야 한다(실측 동작).
        a, b = (-1.0, -1.0, 0.0), (1.0, 1.0, 0.0)
        obj = {"v": [a, b], "vt": [(0.0, 0.0), (1.0, 1.0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([b, a], [(1.0, 1.0), (0.0, 0.0)]))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_duplicated_vertices_pass(self):
        # 면마다 UV 가 다르면 정점이 복제된다 — 늘어나는 것은 정상이다.
        a = (0.0, 0.0, 0.0)
        b = (1.0, 0.0, 0.0)
        obj = {"v": [a, b], "vt": [(0.0, 0.0), (1.0, 0.0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([a, b, a], [(0, 0), (1, 0), (0, 1)]))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_foreign_position_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0)], "vt": [(0.0, 0.0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([(9.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("obj 에 없는 위치" in e for e in errs))

    def test_fewer_mdl_vertices_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0)], "vt": [(0, 0), (0, 0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("정점 수" in e for e in errs))

    def test_empty_mdl_is_reported_as_parse_failure(self):
        obj = {"v": [(0.0, 0.0, 0.0)], "vt": [], "f": []}
        mdl = {"positions": [], "uvs": []}
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("파싱 실패" in e for e in errs))


class TestUvFlip(unittest.TestCase):
    def test_detects_v_flip(self):
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.0), (1.0, 0.0)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4(pos, [(0.0, 1.0), (1.0, 1.0)]))
        self.assertIs(R.uv_v_flipped(obj, mdl), True)

    def test_detects_direct_uv(self):
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.25), (1.0, 0.25)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4(pos, [(0.0, 0.25), (1.0, 0.25)]))
        self.assertIs(R.uv_v_flipped(obj, mdl), False)

    def test_ambiguous_returns_none(self):
        # v=0.5 는 뒤집어도 그대로라 판정할 수 없다.
        pos = [(0.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.5)], "f": []}
        mdl = R.parse_mdl_v4(make_mdl_v4(pos, [(0.0, 0.5)]))
        self.assertIsNone(R.uv_v_flipped(obj, mdl))


if __name__ == "__main__":
    unittest.main()
