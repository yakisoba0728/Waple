import XCTest
import simd
@testable import WapleCore

/// MDLA0003..0006 (3D 컨테이너 MDLV00xx) 애니 섹션 프레이밍을 **값으로** 잠근다.
///
/// 근거는 전부 `wallpaper64.exe` 2.8.42 의 MDL 디코더(`.pdata` 조각 6개 병합
/// `0x140261880`–`0x140265a43`)를 **함수 조각 시작에서 선형으로** 뜬 것이다. 설치본 `.mdl`
/// 28개에는 MDLS·MDLA·MDAT·MDMP·MDLE 섹션이 **한 건도 없고**(2026-08-21 이 레인에서 설치본
/// 트리 6138파일을 파일 전체 바이트로 재스캔해 확인했다 — `.pak` 446개는 전부 CEF 리소스
/// 팩이라 `.mdl` 을 담지 않는다), 워크샵 코퍼스는 이 컨테이너에 없다. 그래서 여기서는 엔진이
/// 읽는 바이트 순서 그대로 합성해 파서를 잠근다. 서술은 `docs/re/skeleton-animation.md` §6 과
/// `Sources/WapleCore/Model3D.swift` 머리 주석.
final class Model3DMDLAFramingTests: XCTestCase {

    // MARK: - 합성 바이트 빌더 (엔진 프레이밍 그대로)

    private func u8(_ v: UInt8, _ d: inout Data) { d.append(v) }
    private func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func i32(_ v: Int32, _ d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u64(_ v: UInt64, _ d: inout Data) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func f32(_ v: Float, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func cstr(_ s: String, _ d: inout Data) { d.append(Data(s.utf8)); d.append(0) }

    private struct Clip {
        var id: UInt64
        var name: String
        var mode: String
        var fps: Float = 30
        var frameCount: UInt32
        var flags: UInt32 = 0
        /// 본별 `(trackFlags, 키 배열)`. 키 하나 = 9 float = pos3 + 오일러3 + scale3.
        var tracks: [(UInt32, [[Float]])]
        /// 클립 꼬리 바이트. nil 이면 `minimumTail()`(게이트 전부 0 · 이벤트 0 = 35B).
        var tail: [UInt8]? = nil
    }

    /// `MDLA0006` 에서 **게이트가 전부 0 이고 이벤트가 없을 때**의 꼬리 = 35바이트.
    ///
    ///   `u32 v3count(0x14026468d)` 4 | `u8 v3gate(0x140264838)` 1 | `u8 v4gate(0x140264a1e)` 1
    ///   | `f32×6 v5(0x140264d23…)` 24 | `u8 v6gate(0x140264e27)` 1 | `u32 이벤트수(0x14026536d)` 4
    ///
    /// 이 35 가 이 레인이 확정한 수다. `docs/re/skeleton-animation.md` §6.3 이 27 이라고 적으며
    /// "Model3D 와 4바이트 어긋난다" 고 한 것은 **v≥3 의 `u32 count` 와 이벤트 블록의 `u32 수`
    /// 를 둘 다 빠뜨린 산술**이었다(4 + 4 = 8, 27 + 8 = 35).
    private func minimumTail() -> [UInt8] { [UInt8](repeating: 0, count: 35) }

    /// 이벤트가 있는 꼬리: 최소 꼬리의 마지막 `u32 이벤트수` 를 n 으로 바꾸고 원소를 잇는다.
    private func tailWithEvents(_ events: [(Float, String)]) -> [UInt8] {
        var d = Data()
        u32(0, &d)                                   // v≥3 ① count
        u8(0, &d)                                    // v≥3 ② gate
        u8(0, &d)                                    // v≥4 gate
        for _ in 0..<6 { f32(0, &d) }                // v≥5 f32 6개
        u8(0, &d)                                    // v≥6 gate
        u32(UInt32(events.count), &d)                // 이벤트 수
        for (t, name) in events {
            f32(t, &d)
            cstr("{\"frame\":\(Int((t * 30).rounded())),\"name\":\"\(name)\"}", &d)
        }
        return [UInt8](d)
    }

    /// MDLV0023(스키닝 단일 삼각형) + MDLS0004(본 N개) + MDLA0006(클립 목록).
    private func makeMDL(bones: [(name: String, parent: Int32)], clips: [Clip],
                         magic: String = "MDLA0006") -> Data {
        var d = Data("MDLV0023".utf8)
        u8(0, &d)
        u32(0x0000_000f, &d); u32(1, &d); u32(1, &d)        // formatFlag, skinCount, meshCount
        cstr("materials/a.json", &d)
        u32(0, &d)
        for _ in 0..<6 { f32(0, &d) }                        // AABB
        u32(0x0180_000f, &d)                                 // 스키닝 정점(stride 80)
        u32(3 * 80, &d)
        for _ in 0..<3 {
            f32(0, &d); f32(0, &d); f32(0, &d)               // pos
            f32(0, &d); f32(1, &d); f32(0, &d)               // normal
            f32(0, &d); f32(0, &d); f32(1, &d); f32(-1, &d)  // tangent
            for _ in 0..<4 { u32(0, &d) }                    // boneIndices
            f32(1, &d); f32(0, &d); f32(0, &d); f32(0, &d)   // weights
            f32(0, &d); f32(0, &d)                           // uv
        }
        u32(6, &d)
        for i: UInt16 in [0, 1, 2] { var x = i.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        d.append(Data("MDLS0004".utf8)); u8(0, &d)
        u32(0, &d); u32(UInt32(bones.count), &d)
        for b in bones {
            cstr(b.name, &d)
            u32(1, &d); i32(b.parent, &d); u32(64, &d)
            for v: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] { f32(v, &d) }
            u8(0, &d)                                        // props(빈 cstring)
        }

        guard !clips.isEmpty else { return d }
        d.append(Data(magic.utf8)); u8(0, &d)
        u32(0, &d)                                           // nextOff(스킵 한계 — 파서 무관)
        u32(UInt32(clips.count), &d)                         // animCount(파서는 불신)
        for c in clips {
            u64(c.id, &d)                                    // 클립 레코드 선두 u64 id
            cstr(c.name, &d)
            cstr(c.mode, &d)
            f32(c.fps, &d); u32(c.frameCount, &d); u32(c.flags, &d); u32(UInt32(c.tracks.count), &d)
            for (flags, keys) in c.tracks {
                u32(flags, &d)                               // trackFlags — 크기가 아니다
                u32(UInt32(keys.count * 36), &d)             // trackBytes
                for k in keys { for v in k { f32(v, &d) } }
            }
            // 마지막 클립 뒤에도 꼬리는 붙는다(엔진 루프가 클립마다 읽는다).
            d.append(contentsOf: c.tail ?? minimumTail())
        }
        return d
    }

    private func key(x: Float, rz: Float = 0) -> [Float] { [x, 0, 0, 0, 0, rz, 1, 1, 1] }

    // MARK: - 1. 본 레코드는 `u32 trackFlags | u32 trackBytes | 트랙` 이다

    /// 엔진은 본마다 첫 u32 를 **플래그**로(`0x140263aa7` `mov r15d, [rsi]`), 둘째 u32 를
    /// **트랙 바이트 수**로(`0x140263acb` `mov ecx, [rsi]`) 읽고 그만큼 커서를 민다
    /// (`0x140263afe` `add rsi, rdx`). 종전 Waple 은 클립 헤더가 `… | u32 본수 | u32 0` 이라고
    /// 보고(그 `u32 0` 이 실은 **본 0 의 trackFlags**), 본마다 트랙 뒤의 u32(= **다음 본의
    /// trackFlags**)를 "블롭2 크기" 로 읽어 그만큼 커서를 더 밀었다. 실물에서 그 값이 0 이라
    /// 우연히 맞았을 뿐이고, **0 이 아닌 순간 그 클립이 통째로 사라진다**.
    func testNonZeroTrackFlagsOnLaterBonesDoesNotDesyncTheClip() throws {
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1), ("Arm", 0)],
            clips: [Clip(id: 41, name: "a|idle_bone", mode: "loop", frameCount: 1,
                         tracks: [(0x0000_0003, [key(x: 1), key(x: 2)]),
                                  (0xDEAD_BEEF, [key(x: 3), key(x: 4)])])])))
        XCTAssertEqual(m.animations.count, 1, "trackFlags 를 크기로 읽으면 이 클립은 통째로 드롭된다")
        guard let a = m.animations.first, a.tracks.count == 2 else {
            return XCTFail("본 2개 트랙이 모두 살아야 한다")
        }
        XCTAssertEqual(a.tracks[0].map(\.position.x), [1, 2])
        XCTAssertEqual(a.tracks[1].map(\.position.x), [3, 4],
                       "두 번째 본 트랙이 어긋나면 첫 본 뒤의 u32 를 블롭 크기로 오독한 것이다")
    }

    /// 다중 클립 + 다중 본 + 0 이 아닌 trackFlags 를 섞어도 전부 살아야 한다.
    func testMultipleClipsWithMultipleBonesAllSurvive() throws {
        let clips = [
            Clip(id: 10, name: "idle", mode: "loop", fps: 20, frameCount: 1,
                 tracks: [(0, [key(x: 1), key(x: 2)]), (1, [key(x: 3), key(x: 4)])]),
            Clip(id: 11, name: "wave", mode: "single", fps: 30, frameCount: 1,
                 tracks: [(0x8000_0000, [key(x: 5), key(x: 6)]), (0, [key(x: 7), key(x: 8)])]),
            Clip(id: 12, name: "jump", mode: "mirror", fps: 12, frameCount: 1,
                 tracks: [(0, [key(x: 9), key(x: 10)]), (7, [key(x: 11), key(x: 12)])]),
        ]
        let m = try XCTUnwrap(Model3D.parse(makeMDL(bones: [("RootNode", -1), ("Arm", 0)], clips: clips)))
        XCTAssertEqual(m.animations.map(\.name), ["idle", "wave", "jump"])
        guard m.animations.count == 3 else {
            return XCTFail("클립 3개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        XCTAssertTrue(m.animations.allSatisfy { $0.tracks.count == 2 }, "본 2개 트랙이 다 살아야 한다")
        guard m.animations.allSatisfy({ $0.tracks.count == 2 && $0.tracks[1].count == 2 }) else { return }
        XCTAssertEqual(m.animations.map(\.mode), ["loop", "single", "mirror"])
        XCTAssertEqual(m.animations.map(\.fps), [20, 30, 12])
        XCTAssertEqual(m.animations.map { $0.tracks[1][1].position.x }, [4, 8, 12])
    }

    // MARK: - 2. 클립 id 는 **그 클립 레코드 선두의 u64** 다

    /// 엔진은 클립마다 선두에서 u64 를 읽어(`0x1402639de` → readU64 `0x1402616b0`) 클립 오브젝트
    /// `+0x00` 에 넣는다. 종전 Waple 은 그 자리를 섹션 헤더의 `u32 baseId | u32 0` 으로 오인하고,
    /// 클립 id 는 "꼬리 시작 +31 의 u16" 으로 집었다. **그 자리는 다음 클립의 u64 id 하위 16비트**다
    /// (게이트가 전부 0 이면 꼬리가 35B 이고 종전 커서는 마지막 트랙 끝 +4 였다 → +31 = +35).
    /// 즉 종전 구현은 클립 i 에 **클립 i+1 의 id** 를 붙이고 마지막 클립에는 클립 0 의 id 를 붙였다.
    func testClipIdIsThisClipsLeadingU64NotTheNextClips() throws {
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1)],
            clips: [Clip(id: 555, name: "clipA", mode: "loop", frameCount: 1,
                         tracks: [(0, [key(x: 1), key(x: 2)])]),
                    Clip(id: 777, name: "clipB", mode: "single", frameCount: 0,
                         tracks: [(0, [key(x: 3)])])])))
        XCTAssertEqual(m.animations.map(\.name), ["clipA", "clipB"])
        guard m.animations.count == 2 else {
            return XCTFail("클립 2개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        XCTAssertEqual(m.animations[0].id, 555,
                       "종전 구현은 여기서 777(다음 클립의 id)을 냈다 — 클립 하나만큼 밀려 있었다")
        XCTAssertEqual(m.animations[1].id, 777,
                       "마지막 클립도 자기 선두 u64 를 쓴다 — 종전의 헤더 baseId 폴백은 클립 0 의 id 였다")
    }

    /// id 는 u64 다. `u32` 로 자르면 4294967400 이 104 가 되고, `u16` 으로 자르면 104 가 된다.
    func testClipIdKeepsTheFullSixtyFourBitValue() throws {
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1)],
            clips: [Clip(id: 4_294_967_400, name: "clipA", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 1)])]),
                    Clip(id: 7, name: "clipB", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 2)])])])))
        guard m.animations.count == 2 else {
            return XCTFail("클립 2개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        XCTAssertEqual(m.animations[0].id, 4_294_967_400)
        XCTAssertEqual(m.animations[1].id, 7)
        // 소비처(씬 animationlayers[].animation) 가 id 로 클립을 고른다.
        XCTAssertEqual(Model3DPose.resolveAnimation(model: m, layerName: "없는이름", clipId: 7), 1)
    }

    /// 꼬리 길이가 바뀌어도 id 는 안 흔들린다 — 고정 오프셋을 안 읽기 때문이다.
    /// 이벤트 블록(`u32 수` | 수×(`f32 초` | JSON cstring))이 붙으면 종전의 "+31 u16" 이 읽던
    /// 자리는 다음 클립 id 가 아니라 **첫 이벤트의 f32 초** 하위 16비트다(1.0f → 0).
    func testClipIdIsStableWhenTheTailGrowsWithEventMarkers() throws {
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1)],
            clips: [Clip(id: 555, name: "clipA", mode: "loop", frameCount: 1,
                         tracks: [(0, [key(x: 1), key(x: 2)])],
                         tail: tailWithEvents([(1.0, "Look Left")])),
                    Clip(id: 777, name: "clipB", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 3)])])])))
        guard m.animations.count == 2 else {
            return XCTFail("클립 2개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        XCTAssertEqual(m.animations[0].id, 555, "종전 구현은 여기서 f32 1.0 의 하위 16비트(0)를 읽었다")
        XCTAssertEqual(m.animations[1].id, 777)
        XCTAssertEqual(m.animations[0].events, [AnimationMarker(name: "Look Left", frame: 30)],
                       "이벤트 블록은 꼬리의 맨 끝(다음 클립 u64 id 직전)에 온다")
        XCTAssertTrue(m.animations[1].events.isEmpty)
    }

    /// 꼬리가 0바이트여도(다음 클립의 u64 가 마지막 트랙 바로 뒤에 붙어도) id 는 정확하다 —
    /// 고정 오프셋이 아니라 **다음 헤더 −8** 을 보기 때문이다.
    func testClipIdIsExactEvenWithAZeroLengthTail() throws {
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1)],
            clips: [Clip(id: 555, name: "clipA", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 1)])], tail: []),
                    Clip(id: 777, name: "clipB", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 2)])])])))
        XCTAssertEqual(m.animations.map(\.name), ["clipA", "clipB"])
        XCTAssertEqual(m.animations.map(\.id), [555, 777])
    }

    /// 리싱크가 **8바이트도 안 남기고** 헤더를 찾으면 그 자리는 클립 경계일 수 없다(레코드 선두에
    /// u64 가 들어갈 자리가 없다 — 꼬리 안의 오탐이다). 그때는 그릇된 id 를 짓지 않고 nil 을 둔다:
    /// 트랙과 이름은 살리고 id 소비처는 이름 휴리스틱으로 폴백한다.
    func testClipIdIsNilWhenTheResyncLandsWithNoRoomForTheLeadingU64() throws {
        // clipA 의 꼬리가 **곧바로** 유효 헤더 모양으로 시작한다(오프셋 0 에서 리싱크가 물린다).
        var ghost = Data()
        cstr("ghost", &ghost); cstr("loop", &ghost)
        f32(30, &ghost); u32(0, &ghost); u32(0, &ghost); u32(1, &ghost)   // fps, frameCount, flags, boneCount
        u32(0, &ghost); u32(36, &ghost)                                    // trackFlags, trackBytes
        for v in key(x: 9) { f32(v, &ghost) }
        ghost.append(contentsOf: minimumTail())
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1)],
            clips: [Clip(id: 555, name: "clipA", mode: "loop", frameCount: 0,
                         tracks: [(0, [key(x: 1)])], tail: [UInt8](ghost))])))
        XCTAssertEqual(m.animations.map(\.name), ["clipA", "ghost"])
        guard m.animations.count == 2 else {
            return XCTFail("클립 2개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        XCTAssertEqual(m.animations[0].id, 555)
        XCTAssertNil(m.animations[1].id, "u64 자리가 없으면 id 를 짓지 않는다(그릇된 값 대신 nil)")
    }

    // MARK: - 3. 구버전 매직도 같은 코드 경로다

    /// 섹션 디스패치는 `strncmp(magic, "MDLA0006", **4**)`(`0x14026397d`)이고 버전은
    /// `atoi(magic+4)`(`0x14026399a` → `0x1402639a4` 저장)다 — 즉 레코드 구조는 버전과 무관하고
    /// 버전은 **꼬리 블록만** 가른다. MDLA0003 은 v≥4/5/6 블록이 없으므로 꼬리가 더 짧다.
    func testLegacyMDLA0003UsesTheSameRecordFramingWithAShorterTail() throws {
        // v=3 꼬리: u32 v3count | u8 v3gate | u32 이벤트수  = 9바이트
        var t = Data(); u32(0, &t); u8(0, &t); u32(0, &t)
        let m = try XCTUnwrap(Model3D.parse(makeMDL(
            bones: [("RootNode", -1), ("Arm", 0)],
            clips: [Clip(id: 3, name: "clipA", mode: "loop", frameCount: 1,
                         tracks: [(0, [key(x: 1), key(x: 2)]), (5, [key(x: 3), key(x: 4)])],
                         tail: [UInt8](t)),
                    Clip(id: 4, name: "clipB", mode: "loop", frameCount: 1,
                         tracks: [(0, [key(x: 5), key(x: 6)]), (0, [key(x: 7), key(x: 8)])],
                         tail: [UInt8](t))],
            magic: "MDLA0003")))
        XCTAssertEqual(m.animations.map(\.name), ["clipA", "clipB"])
        XCTAssertEqual(m.animations.map(\.id), [3, 4])
        guard m.animations.count == 2 else {
            return XCTFail("클립 2개가 파스돼야 한다 — 실제 \(m.animations.count)개")
        }
        guard m.animations[0].tracks.count == 2 else { return XCTFail("본 2개 트랙이 있어야 한다") }
        XCTAssertEqual(m.animations[0].tracks[1].map(\.position.x), [3, 4])
    }
}
