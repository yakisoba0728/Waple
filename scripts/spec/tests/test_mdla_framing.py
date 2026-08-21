"""`measure_mdl_deep.parse_mdla` 의 **양성 대조** — 합성 픽스처.

왜 합성인가
-----------
이 컨테이너에 붙어 있는 `.mdl` 은 설치본 **28개뿐**이고 그 전부에 `MDLS`/`MDLA` 섹션이
**0건**이다(2026-08-21 실측: 매직 `MDLV0014` 15 · `MDLV0004` 8 · `MDLV0023` 4 · `MDLV0017` 1,
`MDLS`/`MDLA`/`MDAT`/`MDLE`/`MDMP` 전부 0). 즉 새 검사를 **실물로는 양성 발화시킬 수 없다**.
표본 0 에서 조용히 통과하는 검사는 "동작하는 척하는 도구" 이므로, 위반하는 바이트열을
직접 만들어 검사가 실제로 잡는지 여기서 못박는다.

무엇을 잠그나
-------------
엔진이 `int 0x29`(__fastfail) 로 강제하는 두 불변식(wallpaper64.exe 0x140263c61–0x140263c95):

    trackBytes % 36 == 0
    trackBytes / 36 == frameCount + 1

Waple(`Sources/WapleCore/Model3D.swift` parseAnimations)은 **앞의 하나만** 본다 —
뒤의 관계는 어디에서도 검사하지 않는다. 그 격차가 이 측정의 존재 이유다.
"""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import measure_mdl_deep as M


KEY = 36                                  # pos 3f | 오일러각 3f | 스케일 3f


def skeleton(bone_count, magic=b"MDLS0004"):
    """`"MDLS000N" | u8 0 | u32 nextOff | u32 boneCount`."""
    return magic + b"\0" + struct.pack("<II", 0, bone_count)


def clip(name, frames, bones, mode="loop", fps=30.0, track_bytes=None, trailer=34):
    """한 클립의 바이트. `track_bytes` 를 주면 **일부러 어긋난** 값을 넣는다."""
    tb = track_bytes if track_bytes is not None else [KEY * (frames + 1)] * bones
    b = bytearray(name.encode("utf-8") + b"\0" + mode.encode("utf-8") + b"\0")
    b += struct.pack("<fIIII", fps, frames, 0, bones, 0)
    for n in tb:
        b += struct.pack("<I", n) + b"\0" * n      # 트랙 블롭
        b += struct.pack("<I", 0)                  # blob2 크기 0
    b += b"\0" * trailer                           # 가변 트레일러(리싱크 대상)
    return bytes(b)


def section(clips, magic=b"MDLA0006", base_id=100):
    """`"MDLA000N" | u8 0 | u32 nextOff | u32 animCount | u32 baseId | u32 0` + 클립들."""
    b = bytearray(magic + b"\0" + struct.pack("<IIII", 0, len(clips), base_id, 0))
    for c in clips:
        b += c
    return bytes(b)


def model(bone_count, clips, prefix=b"MDLV0023\0" + b"\0" * 12):
    return prefix + skeleton(bone_count) + section(clips)


class MDLATrackFraming(unittest.TestCase):
    def parse(self, data):
        i = data.find(b"MDLA000")
        self.assertGreaterEqual(i, 0, "픽스처에 MDLA 매직이 없다")
        bc = M.skeleton_bone_count(data)
        self.assertIsNotNone(bc, "픽스처의 MDLS 본 수를 못 읽었다")
        return M.parse_mdla(data, i, bc)

    # ── 기준(음성): 규약대로면 통과해야 한다 ────────────────────────────────
    def test_valid_single_clip(self):
        data = model(3, [clip("idle", frames=10, bones=3)])
        clips, bad = self.parse(data)
        self.assertEqual(bad, [], "정상 클립이 위반으로 잡혔다")
        self.assertEqual(len(clips), 1)
        self.assertEqual(clips[0]["frames"], 10)
        self.assertEqual(clips[0]["bones"], 3)
        self.assertEqual(clips[0]["keysPerTrack"], 11, "키 수는 frameCount + 1 이다")

    def test_multiple_clips_via_resync(self):
        """가변 트레일러(32~39B)를 리싱크로 건너뛰고 다음 클립을 찾는다."""
        data = model(2, [clip("a", 4, 2, trailer=32),
                         clip("b", 7, 2, trailer=39, mode="clamp"),
                         clip("c", 1, 2, trailer=34, mode="single")])
        clips, bad = self.parse(data)
        self.assertEqual(bad, [])
        self.assertEqual([c["name"] for c in clips], ["a", "b", "c"])
        self.assertEqual([c["keysPerTrack"] for c in clips], [5, 8, 2])

    def test_empty_mode_directory_record_is_read(self):
        """모드가 빈 문자열인 디렉토리 레코드도 트랙 프레이밍은 같다(Model3D.swift:741)."""
        data = model(2, [clip("Glance", 3, 2, mode="")])
        clips, bad = self.parse(data)
        self.assertEqual(bad, [])
        self.assertEqual(clips[0]["mode"], "")

    # ── 양성 대조: 불변식을 어긴 바이트열을 실제로 잡는가 ──────────────────
    def test_track_bytes_not_multiple_of_36(self):
        data = model(2, [clip("bad36", frames=5, bones=2,
                              track_bytes=[KEY * 6, KEY * 6 + 1])])
        clips, bad = self.parse(data)
        self.assertEqual(len(bad), 1, "36 배수 위반을 못 잡았다: %r" % bad)
        self.assertEqual(bad[0]["bone"], 1)
        self.assertEqual(bad[0]["trackBytes"], KEY * 6 + 1)
        self.assertIn("36 의 배수가 아니다", bad[0]["why"])

    def test_key_count_is_not_frame_count_plus_one(self):
        """36 의 배수이기만 하면 Waple 은 통과시킨다 — 엔진은 여기서 fastfail 한다."""
        data = model(2, [clip("badkeys", frames=5, bones=2,
                              track_bytes=[KEY * 6, KEY * 5])])
        clips, bad = self.parse(data)
        self.assertEqual(len(bad), 1, "frameCount+1 위반을 못 잡았다: %r" % bad)
        self.assertEqual(bad[0]["bone"], 1)
        self.assertIn("frameCount+1 = 6", bad[0]["why"])

    def test_off_by_one_in_both_directions(self):
        """키가 하나 모자라도, 하나 더 많아도 둘 다 잡는다(경계 양쪽)."""
        for keys in (KEY * 5, KEY * 7):
            data = model(1, [clip("edge", frames=5, bones=1, track_bytes=[keys])])
            _, bad = self.parse(data)
            self.assertEqual(len(bad), 1, "키 %d바이트를 못 잡았다" % keys)

    def test_truncated_track_is_reported(self):
        """트랙 크기가 파일 밖을 가리키면 조용히 넘기지 않는다."""
        data = model(1, [clip("trunc", frames=2, bones=1)])
        i = data.find(b"MDLA000")
        # 첫 트랙의 u32 크기를 파일 길이보다 크게 덮어쓴다.
        off = data.index(struct.pack("<I", KEY * 3), i)
        data = data[:off] + struct.pack("<I", len(data) + 4096) + data[off + 4:]
        _, bad = self.parse(data)
        self.assertTrue(any("잘렸다" in b["why"] for b in bad), bad)

    # ── 표본 0 안전성 ───────────────────────────────────────────────────────
    def test_zero_samples_is_quiet(self):
        """MDLA 가 없는 입력에서 폭발하지도, 위반을 지어내지도 않는다."""
        self.assertEqual(M.parse_mdla(b"", 0, 3), ([], []))
        self.assertEqual(M.parse_mdla(b"MDLA0006\0" + b"\0" * 16, 0, 3), ([], []))

    def test_skeleton_bone_count_rejects_garbage(self):
        """블롭 한복판의 가짜 MDLS 매직에 착지하면 터무니없는 본 수가 나온다 — 상한으로 거른다."""
        self.assertIsNone(M.skeleton_bone_count(b"nope"))
        self.assertIsNone(M.skeleton_bone_count(skeleton(0)))
        self.assertIsNone(M.skeleton_bone_count(skeleton(100000)))
        self.assertEqual(M.skeleton_bone_count(skeleton(M.MAX_BONES)), M.MAX_BONES)

    def test_local_install_really_has_no_mdla(self):
        """이 컨테이너에서 양성 발화가 불가능하다는 전제 자체를 검사한다.

        설치본이 없으면 건너뛴다(CI). 있으면 `.mdl` 전건에 MDLA 가 0건이어야 한다 —
        만약 하나라도 생기면 이 파일의 '합성으로만 검증 가능' 이라는 전제가 낡은 것이다.
        """
        we = os.environ.get("WE_ROOT")
        if not we or not os.path.isdir(we):
            self.skipTest("WE_ROOT 미지정 — 설치본 없음")
        found, total = [], 0
        for dp, _, fn in os.walk(we):
            for f in fn:
                if not f.lower().endswith(".mdl"):
                    continue
                total += 1
                with open(os.path.join(dp, f), "rb") as fh:
                    if fh.read().find(b"MDLA000") >= 0:
                        found.append(f)
        self.assertGreater(total, 0, "설치본에 .mdl 이 하나도 없다 — 경로가 틀렸다")
        self.assertEqual(found, [], "설치본에 MDLA 가 생겼다 — 실물 대조로 승급할 수 있다")


class InvariantMatchesDisassembly(unittest.TestCase):
    """0x140263c61–0x140263c95 의 산술을 그대로 재현해 분류가 일치하는지 본다.

        movabs rax, 0xe38e38e38e38e38f ; mul r8 ; shr rdx,5      → rdx = trackBytes / 36
        lea rax,[rdx+rdx*8] ; shl rax,2 ; sub r8,rax             → r8  = trackBytes % 36
        inc ecx ; cmp rdx,rcx ; jne  → int 0x29                  → 몫 != frameCount+1 이면 죽음
        test r8,r8 ; jne  → int 0x29                             → 나머지 != 0 이면 죽음
    """
    MAGIC = 0xE38E38E38E38E38F

    def engine_div36(self, x):
        return ((x * self.MAGIC) >> 64) >> 5

    def test_magic_constant_really_divides_by_36(self):
        for x in list(range(0, 4000)) + [36 * 1000, 36 * 65535, 0xFFFFFF]:
            self.assertEqual(self.engine_div36(x), x // 36, "x=%d 에서 매직 나눗셈이 어긋난다" % x)

    def test_fastfail_predicate_matches_parser(self):
        frames = 7
        for tb in range(0, 36 * 12 + 5):
            q, r = self.engine_div36(tb), tb - self.engine_div36(tb) * 36
            engine_dies = (q != frames + 1) or (r != 0)
            data = model(1, [clip("x", frames=frames, bones=1, track_bytes=[tb])])
            _, bad = self.parse_one(data)
            self.assertEqual(bool(bad), engine_dies,
                             "trackBytes=%d: 엔진사망=%s 인데 파서 위반=%r" % (tb, engine_dies, bad))

    def parse_one(self, data):
        i = data.find(b"MDLA000")
        return M.parse_mdla(data, i, M.skeleton_bone_count(data))


if __name__ == "__main__":
    unittest.main()
