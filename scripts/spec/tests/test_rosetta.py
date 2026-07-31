"""verify_rosetta.py 단위 테스트.

[2026-08-01 복구] 이 파일은 14/17 이 죽어 있었다. mdl-deep 조사가
verify_rosetta.py 를 다시 쓰면서 API 가 셋 바뀌었는데 테스트가 따라오지
않았다:
  - parse_mdl_v4 -> parse_mdl (다버전 파서로 일반화)
  - 반환 형태가 평면 {positions,uvs} -> {meshes:[{...}]} (다메시 지원)
  - uv_v_flipped 반환이 True/False/None -> (라벨, 오류여부) 튜플
게다가 새 파서는 정점 블롭 뒤 u32 indexBytes 를 **요구**한다 —
픽스처 생성기가 그걸 안 써서 파싱 자체가 불가능했다.

단언은 약화시키지 않았다. 검사 대상이 사라진 것은 하나뿐이고
(test_rejects_unconfirmed_version 이 겨냥하던 MDLV0023 은 이제
정식 지원 버전이다) 그건 실제로 미확정인 버전으로 겨냥을 옮겼다.
"""
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


def make_mdl_v4(positions, uvs, materials=(b"materials/x.json",), indices=None,
                magic=b"MDLV0004"):
    """MDLV0004 형태의 최소 바이트열(파서 테스트용).

    v0004 메시 = cstring material × skinCount | u32 gateWord | u32 vertexBytes
                 | vertices | u32 indexBytes | indices
    (spec/formats/mdl-deep.json format.mdl.meshLayout)

    indices=None 이면 인덱스 버퍼를 비운다 — compare 의 삼각형 수 검사가
    obj["f"] == [] 인 픽스처와 정합한다(양쪽 다 0).
    """
    out = magic + b"\0"
    out += struct.pack("<III", 0x09, len(materials), 1)   # formatFlag, skinCount, meshCount
    for m in materials:
        out += m + b"\0"
    out += struct.pack("<I", 0)                            # gateWord (bit1 미설정)
    blob = b"".join(struct.pack("<3f2f", *p, *u) for p, u in zip(positions, uvs))
    out += struct.pack("<I", len(blob)) + blob
    if indices:
        # 폭 규칙은 파서와 같아야 한다: 정점 수 > 0xFFFF 면 u32.
        wide = len(positions) > 0xFFFF
        packed = struct.pack(f"<{len(indices)}{'I' if wide else 'H'}", *indices)
    else:
        packed = b""
    out += struct.pack("<I", len(packed)) + packed
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


class TestParseMdl(unittest.TestCase):
    def setUp(self):
        self.pos = [(-3.285059, -3.285059, -0.554853), (3.285059, -3.285059, -0.554853)]
        self.uv = [(0.0, 0.0), (1.0, 0.0)]
        self.data = make_mdl_v4(self.pos, self.uv)

    def test_header(self):
        m = R.parse_mdl(self.data)
        self.assertEqual(m["magic"], "MDLV0004")
        self.assertEqual(m["version"], 4)
        self.assertEqual(m["headerFlag"], 0x09)
        self.assertEqual(m["meshCount"], 1)
        self.assertEqual(m["skinCount"], 1)
        self.assertEqual(m["meshes"][0]["materials"], ["materials/x.json"])

    def test_stride_is_20_bytes_for_flag_09(self):
        m = R.parse_mdl(self.data)
        self.assertEqual(m["meshes"][0]["stride"], 20)
        self.assertEqual(m["meshes"][0]["vertexBytes"], 2 * 20)
        self.assertEqual(len(m["meshes"][0]["positions"]), 2)

    def test_positions_roundtrip(self):
        m = R.parse_mdl(self.data)
        self.assertAlmostEqual(m["meshes"][0]["positions"][0][0], -3.285059, places=5)

    def test_lands_at_eof(self):
        # 프레이밍이 맞으면 메시 섹션 끝이 정확히 파일 끝이어야 한다.
        m = R.parse_mdl(self.data)
        self.assertEqual(m["end"], len(self.data))
        self.assertEqual(R.landing(self.data, m["end"]), "EOF")

    def test_rejects_wrong_magic(self):
        with self.assertRaises(ValueError):
            R.parse_mdl(b"NOTMDL00" + b"\0" * 32)

    def test_rejects_unconfirmed_version(self):
        # 실물 미목격 버전(FRAMING 에 없음)은 억지로 읽어 '통과' 를 만들지 않는다.
        # MDLV0023 은 이제 정식 지원이라 겨냥이 될 수 없다 — 0015/0018/0020/0022 로 옮긴다.
        for ver in (b"MDLV0015", b"MDLV0018", b"MDLV0020", b"MDLV0022"):
            self.assertNotIn(int(ver[4:]), R.FRAMING, f"{ver!r} 가 지원 목록에 들어왔다면 이 테스트를 갱신해라")
            data = make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)], magic=ver)
            with self.assertRaises(ValueError) as cm:
                R.parse_mdl(data)
            self.assertIn("미확정", str(cm.exception))

    def test_material_cstring_is_per_skin(self):
        # 문자열 루프는 메시 루프 **안**이고 메시당 skinCount 개다.
        # 1개 고정으로 읽으면 skinCount=2 에서 스트림이 어긋난다(실물 audiophile grid.mdl).
        data = make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)],
                           materials=(b"materials/grid/grid.json", b"materials/grid/grid2.json"))
        m = R.parse_mdl(data)
        self.assertEqual(m["skinCount"], 2)
        self.assertEqual(m["meshes"][0]["materials"],
                         ["materials/grid/grid.json", "materials/grid/grid2.json"])
        self.assertEqual(m["end"], len(data))     # 어긋났으면 착지가 깨진다

    def test_index_width_follows_vertex_count(self):
        """정점 수 > 65535 면 인덱스는 u32 다(코퍼스 986/986).

        u16 로 읽으면 상위 워드 0 이 섞여 maxIndex 가 정확히 0xFFFF 로 찍힌다 —
        Waple Model3D.swift 의 현행 결함이 정확히 이것이고, maxIndex 검사는
        65535 < vertexCount 라 절대 발화하지 못한다.
        """
        n = 0x10000 + 3                            # 65539 정점
        pos = [(float(i), 0.0, 0.0) for i in range(n)]
        uv = [(0.0, 0.0)] * n
        idx = (0, 0xFFFF, n - 1)                   # maxIndex == n-1 을 만든다
        data = make_mdl_v4(pos, uv, indices=idx)
        mesh = R.parse_mdl(data)["meshes"][0]
        self.assertEqual(mesh["count"], n)
        self.assertEqual(mesh["indices"], idx)
        self.assertEqual(max(mesh["indices"]), mesh["count"] - 1)

        # 같은 바이트를 u16 로 읽으면(= Waple Model3D.swift 현행) 상위 워드 0 이 섞여
        # maxIndex 가 정확히 0xFFFF 로 붕괴한다. 그리고 0xFFFF < n 이므로
        # `maxIndex >= vertexCount` 방어선은 절대 발화하지 못한다 — 거부가 아니라
        # 깨진 지오메트리로 **통과**한다는 것이 이 결함의 핵심이다.
        raw = data[-len(idx) * 4:]
        as_u16 = struct.unpack(f"<{len(raw) // 2}H", raw)
        self.assertEqual(max(as_u16), 0xFFFF)
        self.assertLess(max(as_u16), n)            # 방어선이 못 잡는다


class TestCompare(unittest.TestCase):
    """비교는 순서 무관이어야 한다 — MDL 은 면 전개 순서로 정점을 굽고 복제한다."""

    def test_matching_geometry_has_no_errors(self):
        pos = [(-3.285059, -3.285059, -0.554853)]
        uv = [(0.0, 0.0)]
        obj = {"v": pos, "vt": uv, "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4(pos, uv))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_reordered_vertices_pass(self):
        # 같은 집합을 순서만 바꿔 구운 것은 통과해야 한다(실측 동작).
        a, b = (-1.0, -1.0, 0.0), (1.0, 1.0, 0.0)
        obj = {"v": [a, b], "vt": [(0.0, 0.0), (1.0, 1.0)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4([b, a], [(1.0, 1.0), (0.0, 0.0)]))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_duplicated_vertices_pass(self):
        # 면마다 UV 가 다르면 정점이 복제된다 — 늘어나는 것은 정상이다.
        a = (0.0, 0.0, 0.0)
        b = (1.0, 0.0, 0.0)
        obj = {"v": [a, b], "vt": [(0.0, 0.0), (1.0, 0.0)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4([a, b, a], [(0, 0), (1, 0), (0, 1)]))
        self.assertEqual(R.compare(obj, mdl, 1e-4), [])

    def test_foreign_position_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0)], "vt": [(0.0, 0.0)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4([(9.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("obj 에 없는 위치" in e for e in errs))

    def test_fewer_mdl_vertices_is_reported(self):
        obj = {"v": [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0)], "vt": [(0, 0), (0, 0)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4([(0.0, 0.0, 0.0)], [(0.0, 0.0)]))
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("정점 수" in e for e in errs))

    def test_empty_mdl_is_reported_as_parse_failure(self):
        obj = {"v": [(0.0, 0.0, 0.0)], "vt": [], "vn": [], "f": []}
        mdl = {"meshes": [{"positions": [], "uvs": [], "normals": [], "tangents": [],
                           "indices": (), "count": 0, "aabb": None}]}
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("파싱 실패" in e for e in errs))

    def test_triangle_count_mismatch_is_reported(self):
        # (d) 팬 삼각화: obj Σ(n-2) 와 mdl 인덱스/3 이 어긋나면 잡아야 한다.
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]
        uv = [(0.0, 0.0)] * 3
        obj = {"v": pos, "vt": uv, "vn": [], "f": [[(0, 0, None), (1, 1, None), (2, 2, None)]]}
        mdl = R.parse_mdl(make_mdl_v4(pos, uv))     # 인덱스 0개 = 삼각형 0개
        errs = R.compare(obj, mdl, 1e-4)
        self.assertTrue(any("삼각형 수" in e for e in errs))


class TestUvFlip(unittest.TestCase):
    """반환은 (라벨, 오류여부) 튜플이다."""

    def test_detects_v_flip(self):
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.0), (1.0, 0.0)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4(pos, [(0.0, 1.0), (1.0, 1.0)]))
        self.assertEqual(R.uv_v_flipped(obj, mdl), ("UV-V 뒤집힘", False))

    def test_detects_direct_uv(self):
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.25), (1.0, 0.25)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4(pos, [(0.0, 0.25), (1.0, 0.25)]))
        self.assertEqual(R.uv_v_flipped(obj, mdl), ("UV 직결", False))

    def test_ambiguous_is_reported_as_symmetric(self):
        # v=0.5 는 뒤집어도 그대로라 판정할 수 없다 — 오류가 아니라 '판정불가'다.
        pos = [(0.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.5)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4(pos, [(0.0, 0.5)]))
        self.assertEqual(R.uv_v_flipped(obj, mdl), ("UV-V 대칭(판정불가)", False))

    def test_foreign_uv_is_an_error(self):
        pos = [(0.0, 0.0, 0.0)]
        obj = {"v": pos, "vt": [(0.0, 0.25)], "vn": [], "f": []}
        mdl = R.parse_mdl(make_mdl_v4(pos, [(0.0, 0.9)]))
        label, bad = R.uv_v_flipped(obj, mdl)
        self.assertTrue(bad)
        self.assertIn("불일치", label)


if __name__ == "__main__":
    unittest.main()
