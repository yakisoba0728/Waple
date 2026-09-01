import XCTest
import simd
@testable import WapleCore

/// MDLS0001 / MDLA0001 섹션 프레이밍과 본 변환 규약을 **값으로** 잠근다.
///
/// 근거는 전부 `wallpaper64.exe` 2.8.42 의 MDL 디코더(`0x140261880`–`0x140265a43`, `.pdata`
/// 단편 6개 병합)를 **함수 시작에서 선형으로** 뜬 것이다. 설치본 `.mdl` 28개에는 MDLS·MDLA·
/// MDAT·MDMP·MDLE 섹션이 **한 건도 없어서**(2026-08-21 전수 재확인) 실물 대조가 불가능하다 —
/// 그래서 여기서는 엔진이 읽는 바이트 순서 그대로 합성해 파서를 잠근다.
/// 서술은 `docs/re/skeleton-animation.md` §6.
final class PuppetMDLAFramingTests: XCTestCase {

    // MARK: - 합성 바이트 빌더 (엔진 프레이밍 그대로)

    private struct Clip {
        var id: UInt64
        var name: String
        var mode: String
        var fps: Float
        var frameCount: UInt32
        var flags: UInt32 = 0
        /// 본별 (trackFlags, 키 배열). 키는 9 float = pos3 + euler3 + scale3.
        var tracks: [(UInt32, [[Float]])]
        var events: [AnimationMarker] = []
        var eventCountField: UInt32? = nil
        /// `flags & 1` 이 켠 **클립 꼬리 0xC0(192)바이트 레코드**. 본 트랙 뒤·이벤트 블록 앞에 온다
        /// (`0x140264fc9 test byte [rbp+0xc0],1` → `0x140264fdb call 0x14028af20`; 기본값에
        ///  -1(`0x140264ff7`)과 1.0f 가 깔린다 — docs/re/skeleton-animation.md §6.2).
        /// `flags` 와 **독립으로** 지정한다 — 비트만 서고 레코드가 없는 입력(종전에 통과하던 모양)을
        /// 그대로 합성할 수 있어야 보수 게이트를 검증할 수 있기 때문이다.
        var flagBit0TailRecord: [UInt8]? = nil
    }

    private func u8(_ v: UInt8, _ d: inout Data) { d.append(v) }
    private func u32(_ v: UInt32, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u64(_ v: UInt64, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func f32(_ v: Float, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func cstr(_ s: String, _ d: inout Data) { d.append(Data(s.utf8)); d.append(0) }

    /// MDLV0013 컨테이너 + 선택적 MDLS0001 + 선택적 MDLA0001.
    ///
    /// 본 레코드: `cstring 이름 | u32 flags | i32 부모 | u32 64 | 16f 행렬 | cstring 본제약config`
    ///  — 마지막 cstring 은 엔진이 `0x140262588`(readCString) → `0x140265c30`(제약 파서)로 넘기는
    ///    필드다. 종전 Waple 은 이걸 "u8 0 패드" 로 읽고 있었다.
    /// 클립 레코드: `u64 id | cstring 이름 | cstring 모드 | f32 fps | u32 frameCount | u32 flags | u32 본수`
    ///  — 본마다 `u32 trackFlags | u32 trackBytes | trackBytes`.
    private func makeMDL(bones: [(name: String, parent: Int32, matrix: [Float], config: String)],
                         clips: [Clip]) -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))
        cstr("materials/b.json", &d)
        u32(0, &d)                       // 용도 미상 u32
        u32(52, &d)                      // 정점 블롭 = 1정점
        f32(0, &d); f32(0, &d); f32(0, &d)                       // pos
        u32(0, &d); u32(0, &d); u32(0, &d); u32(0, &d)           // bone indices
        f32(1, &d); f32(0, &d); f32(0, &d); f32(0, &d)           // weights
        f32(0, &d); f32(0, &d)                                   // uv
        u32(6, &d)                       // 인덱스 블롭 = 3 × u16
        for _ in 0..<3 { d.append(0); d.append(0) }

        if !bones.isEmpty {
            d.append(Data("MDLS0001".utf8))
            u8(0, &d)
            var body = Data()
            for b in bones {
                cstr(b.name, &body)
                u32(1, &body)                                     // flags
                u32(UInt32(bitPattern: b.parent), &body)
                u32(64, &body)                                    // 행렬 블롭 크기(크기접두 리더 0x1400d3ef0)
                for v in b.matrix { f32(v, &body) }
                cstr(b.config, &body)                             // 본 제약 config
            }
            u32(0, &d)                                            // nextOff(파서 무관)
            u32(UInt32(bones.count), &d)
            d.append(body)
        }

        if !clips.isEmpty {
            d.append(Data("MDLA0001".utf8))
            u8(0, &d)
            u32(0, &d)                                            // nextOff
            u32(UInt32(clips.count), &d)                          // animCount
            for c in clips {
                u64(c.id, &d)
                cstr(c.name, &d)
                cstr(c.mode, &d)
                f32(c.fps, &d)
                u32(c.frameCount, &d)
                u32(c.flags, &d)
                u32(UInt32(c.tracks.count), &d)
                for (flags, keys) in c.tracks {
                    u32(flags, &d)
                    u32(UInt32(keys.count * 36), &d)
                    for k in keys { for v in k { f32(v, &d) } }
                }
                if let tail = c.flagBit0TailRecord { d.append(contentsOf: tail) }
                u32(c.eventCountField ?? UInt32(c.events.count), &d)
                for event in c.events {
                    f32(c.fps > 0 ? event.frame / c.fps : 0, &d)
                    cstr(#"{"frame":\#(event.frame),"name":"\#(event.name)"}"#, &d)
                }
            }
        }
        return d
    }

    private func key(x: Float, rz: Float = 0) -> [Float] { [x, 0, 0, 0, 0, rz, 1, 1, 1] }

    private let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    // MARK: - 1. 클립이 둘 이상이면 종전 프레이밍은 두 번째부터 전부 잃는다

    /// 엔진은 클립마다 선두 u64 id 를 읽고(`0x1402639de` → `0x1402616b0` readU64) 본 레코드를
    /// `u32 trackFlags | u32 trackBytes | 트랙` 으로 읽는다(`0x140263aa7` / `0x140263acb` /
    /// `0x140263afe`). 종전 Waple 은 그 id 를 섹션 헤더 필드로 오인해 클립 0 것만 소비하고,
    /// 본마다 트랙 뒤의 u32(= 다음 본의 trackFlags)를 "블롭2 크기" 로 읽어 그만큼 커서를 더 밀었다.
    /// 그 둘이 겹쳐 **두 번째 클립의 시작이 정확히 4바이트 어긋난다** — 클립 1 이 통째로 사라진다.
    func testMultiClipMDLA0001ParsesEveryClipNotJustTheFirst() throws {
        let clips = [
            Clip(id: 355, name: "idle", mode: "loop", fps: 20, frameCount: 1,
                 tracks: [(0, [key(x: 10), key(x: 20)])]),
            Clip(id: 356, name: "wave", mode: "single", fps: 30, frameCount: 1,
                 tracks: [(0, [key(x: 100), key(x: 200)])]),
            Clip(id: 357, name: "jump", mode: "mirror", fps: 12, frameCount: 1,
                 tracks: [(0, [key(x: -5), key(x: -9)])]),
        ]
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")], clips: clips)))
        XCTAssertEqual(m.animations.count, 3, "클립 3개가 전부 파스돼야 한다(종전 프레이밍은 1개만 남았다)")
        guard m.animations.count == 3 else { return }   // 아래 인덱싱이 크래시가 아니라 단언으로 끝나게
        XCTAssertEqual(m.animations.map(\.name), ["idle", "wave", "jump"])
        XCTAssertEqual(m.animations.map(\.mode), ["loop", "single", "mirror"])
        XCTAssertEqual(m.animations[1].fps, 30)
        XCTAssertEqual(m.animations[2].lengthFrames, 1)
        XCTAssertEqual(m.animations[1].tracks[0][1].position.x, 200, accuracy: 1e-5)
        XCTAssertEqual(m.animations[2].tracks[0][0].position.x, -5, accuracy: 1e-5)
    }

    /// 클립 선두 u64 가 `Animation.id` 다. 종전엔 네이티브 MDLA0001 의 id 를 항상 nil 로 뒀다.
    func testClipIdComesFromTheLeadingU64OfEachClip() throws {
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")],
            clips: [Clip(id: 4_294_967_400, name: "a", mode: "loop", fps: 10, frameCount: 0,
                         tracks: [(0, [key(x: 1)])]),
                    Clip(id: 7, name: "b", mode: "loop", fps: 10, frameCount: 0,
                         tracks: [(0, [key(x: 2)])])])))
        XCTAssertEqual(m.animations.count, 2)
        guard m.animations.count == 2 else { return }
        // 32비트를 넘는 id 도 그대로 살아야 한다(엔진 필드가 u64 다 — u32 로 자르면 104 가 된다).
        XCTAssertEqual(m.animations[0].id, 4_294_967_400)
        XCTAssertEqual(m.animations[1].id, 7)
        // clipIndex 가 이름 휴리스틱보다 id 를 먼저 본다.
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "a", fallback: 0, clipId: 7), 1)
    }

    /// 이벤트 블록은 MDLA 버전 게이트 밖이라 네이티브 MDLA0001에도 클립마다 존재한다.
    /// 첫 클립의 이벤트를 소비하지 않으면 그 count를 다음 클립 id로 오독해 두 번째 클립을 잃는다.
    func testNativeMDLAEventsAreParsedWithoutDesynchronizingTheNextClip() throws {
        let clips = [
            Clip(id: 10, name: "idle", mode: "loop", fps: 20, frameCount: 1,
                 tracks: [(0, [key(x: 0), key(x: 1)])],
                 events: [AnimationMarker(name: "blink", frame: 12)]),
            Clip(id: 11, name: "wave", mode: "single", fps: 20, frameCount: 1,
                 tracks: [(0, [key(x: 2), key(x: 3)])]),
        ]

        let model = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")], clips: clips)))
        XCTAssertEqual(model.animations.map(\.name), ["idle", "wave"])
        guard model.animations.count == 2 else { return }
        XCTAssertEqual(model.animations[0].events, [AnimationMarker(name: "blink", frame: 12)])
        XCTAssertTrue(model.animations[1].events.isEmpty)
    }

    func testNativeMDLAEventCountAboveSafetyLimitDropsClipBeforeAllocation() throws {
        var clip = Clip(id: 10, name: "hostile", mode: "loop", fps: 20, frameCount: 1,
                        tracks: [(0, [key(x: 0), key(x: 1)])])
        clip.eventCountField = 4_097

        let model = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")], clips: [clip])))
        XCTAssertTrue(model.animations.isEmpty,
                      "신뢰할 수 없는 eventCount를 Int로 좁히거나 reserveCapacity에 넘기면 안 됨")
    }

    // MARK: - 2. trackFlags 는 크기가 아니다

    /// 트랙 앞 u32 는 **플래그**이지 뒤따르는 블롭의 크기가 아니다. 종전 코드는 (다음 본의) 이 값을
    /// 바이트 수로 보고 커서를 밀었으므로 0 이 아닌 순간 이후 전부가 어긋났다.
    /// 엔진에서 이 워드의 비트0 은 클립 flags 에 0x80000000 을 세우는 데만 쓰이고(`0x140263c97`–
    /// `0x140263c9d`) 키 해석을 바꾸지 않는다.
    func testNonZeroTrackFlagsAreReadAsFlagsNotAsAByteCount() throws {
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, ""), ("arm", 0, identity, "")],
            clips: [Clip(id: 1, name: "a", mode: "loop", fps: 10, frameCount: 1,
                         tracks: [(0x0000_0003, [key(x: 1), key(x: 2)]),
                                  (0xDEAD_BEEF, [key(x: 3), key(x: 4)])])])))
        let a = try XCTUnwrap(m.animations.first)
        XCTAssertEqual(a.tracks.count, 2, "본 2개 트랙이 모두 살아야 한다")
        guard a.tracks.count == 2 else { return }
        XCTAssertEqual(a.tracks[0].map(\.position.x), [1, 2])
        XCTAssertEqual(a.tracks[1].map(\.position.x), [3, 4],
                       "두 번째 본 트랙이 어긋나면 첫 본의 trackFlags 를 크기로 오독한 것이다")
    }

    // MARK: - 3. 본 레코드 꼬리는 패딩이 아니라 제약 config cstring

    /// 엔진은 64B 행렬 블롭 직후 cstring 을 하나 더 읽는다(`0x140262588`). 실물은 그게 비어 있어
    /// 종전의 "u8 0 패드" 와 바이트가 같았을 뿐이다 — 비어 있지 않으면 이후 전 오프셋이 밀린다.
    func testBoneConstraintConfigStringIsConsumedNotTreatedAsOnePadByte() throws {
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "ik=1 ikd=2"), ("arm", 0, identity, "")],
            clips: [Clip(id: 9, name: "a", mode: "loop", fps: 10, frameCount: 0,
                         tracks: [(0, [key(x: 7)]), (0, [key(x: 8)])])])))
        XCTAssertEqual(m.bones.map(\.name), ["root", "arm"])
        XCTAssertEqual(m.bones[1].parent, 0)
        // config 문자열을 안 삼켰다면 MDLA 매직 위치가 밀려 애니 섹션 자체를 못 찾는다.
        XCTAssertEqual(m.animations.count, 1, "본 config 를 1바이트로만 넘기면 MDLA 매직을 놓친다")
        guard m.animations.first?.tracks.count == 2 else { return XCTFail("두 본 트랙이 있어야 한다") }
        XCTAssertEqual(m.animations[0].tracks[1][0].position.x, 8, accuracy: 1e-5)
    }

    // MARK: - 4. 본 행렬은 **열 우선**이다 (함정 14: 레이아웃이 아니라 값으로)

    /// 평행이동만 든 행렬로는 행/열 주도를 못 가른다(두 해석의 바이트가 같다). 회전을 넣으면 갈린다:
    /// `Rz(90°)` 의 열0 은 `(0, 1, 0)`, 행0 은 `(0, −1, 0)` 이다. 엔진이 같은 4×4 를 저장 순서대로
    /// 쓰는 자리(`setLocalBoneAngles` `0x14020fce0`: `+0x00 = cos(y)cos(z)`, `+0x04 = cos(y)sin(z)`,
    /// `+0x08 = −sin(y)`)를 보면 처음 세 float 이 **열0** 이다. 파일 바이트도 같은 규약이어야 한다.
    func testBoneMatrixBytesAreColumnMajorProvenByAKnownRotation() throws {
        // Rz(90°) 를 열 우선으로 나열: 열0 = (0,1,0,0), 열1 = (−1,0,0,0), 열2 = (0,0,1,0), 열3 = (0,0,0,1)
        let rz90: [Float] = [0, 1, 0, 0,
                             -1, 0, 0, 0,
                             0, 0, 1, 0,
                             0, 0, 0, 1]
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, rz90, "")], clips: [])))
        let b = try XCTUnwrap(m.bones.first).bind
        let mapped = b * SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual(mapped.x, 0, accuracy: 1e-5)
        XCTAssertEqual(mapped.y, 1, accuracy: 1e-5,
                       "x축이 +y 로 가야 한다 — −1 이 나오면 파일 바이트를 행 우선으로 읽은 것이다")
        // 엔진 저장 순서(첫 세 float = 열0)와의 직접 대조.
        XCTAssertEqual(b.columns.0, SIMD4<Float>(0, 1, 0, 0))
        XCTAssertNotEqual(b.columns.0, SIMD4<Float>(0, -1, 0, 0))
    }

    /// 공개 API 쪽에서도 같은 판별을 한 번 더 — `Rz(90°)` 오일러 키가 만드는 행렬의 열0 이 `(0,1,0)`.
    func testEulerKeyMatrixIsColumnMajorByTheSameDiscriminator() {
        let m = PuppetPose.localMatrix(position: .zero,
                                       angles: SIMD3<Float>(0, 0, .pi / 2),
                                       scale: SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(m.columns.0.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.y, 1, accuracy: 1e-6, "열0 = (cos z, sin z, 0) — 행 우선이면 −1")
        XCTAssertEqual(m.columns.1.x, -1, accuracy: 1e-6)
    }

    // MARK: - 5. 키 수 = frameCount + 1

    /// 엔진은 `trackBytes % 36 == 0` 과 `trackBytes / 36 == frameCount + 1` **둘 다** 어기면
    /// `int 0x29`(__fastfail)로 즉사한다(`0x140263c85`→`0x140263c8c`, `0x140263c8e`→`0x140263c95`).
    /// 이 불변식이 성립하면 `frame()` 의 상한 `length` 와 트랙 끝 인덱스 `keys.count-1` 이 같아져
    /// `sampledTRS` 의 클램프가 **무동작**이 된다 — 마지막 프레임이 잘리지 않는다는 뜻이다.
    func testKeyCountIsFrameCountPlusOneSoTheLastFrameIsNotClipped() throws {
        let frames: UInt32 = 4
        let keys = (0...Int(frames)).map { key(x: Float($0) * 10) }   // 5키 / frameCount 4
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")],
            clips: [Clip(id: 1, name: "a", mode: "single", fps: 4, frameCount: frames,
                         tracks: [(0, keys)])])))
        let a = try XCTUnwrap(m.animations.first)
        XCTAssertEqual(a.tracks[0].count, Int(frames) + 1)
        guard a.tracks.first?.count == Int(frames) + 1 else { return XCTFail("키 수가 frameCount+1 이 아니다") }
        // t = frameCount/fps = 1.0s → 프레임 4 = 마지막 키(x = 40).
        let f = PuppetPose.frame(time: 1.0, fps: a.fps, length: a.lengthFrames, mode: a.mode)
        XCTAssertEqual(f, Float(frames), accuracy: 1e-5)
        let trs = try XCTUnwrap(PuppetPose.sampledTRS(a.tracks[0], frame: f))
        XCTAssertEqual(trs.position.x, 40, accuracy: 1e-4, "마지막 키에 정확히 닿아야 한다")
    }

    // MARK: - 6. 음수 시간(역방향 rate)의 모드별 되돌림

    /// loop: 엔진은 `T < 0` 이면 `T += D` 한 뒤 `fmodf(T, D)` 한다(`0x1401aa05f`–`0x1401aa070`).
    /// 종전 Waple 은 `truncatingRemainder` 를 그대로 써서 **음수 프레임**을 냈고 소비처의 `max(0,…)`
    /// 가 그걸 프레임 0 으로 뭉갰다 — 역방향 재생이 클립 끝이 아니라 시작에 붙어 버린다.
    func testLoopModeWrapsNegativeTimeToTheEndOfTheClipNotToZero() {
        // fps 4, length 10 → D = 2.5s. t = −0.25s → T += D = 2.25s → 프레임 9.
        XCTAssertEqual(PuppetPose.frame(time: -0.25, fps: 4, length: 10, mode: "loop"),
                       9, accuracy: 1e-4)
        XCTAssertEqual(PuppetPose.frame(time: -2.25, fps: 4, length: 10, mode: "loop"),
                       1, accuracy: 1e-4)
        // 경계: 정확히 −D 는 0 으로 되돌아온다(주기 경계).
        XCTAssertEqual(PuppetPose.frame(time: -2.5, fps: 4, length: 10, mode: "loop"),
                       0, accuracy: 1e-4)
        // 양수 쪽 값은 종전과 동일해야 한다(무회귀).
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 4, length: 10, mode: "loop"),
                       1, accuracy: 1e-4)
        XCTAssertEqual(PuppetPose.frame(time: 3.0, fps: 4, length: 10, mode: "loop"),
                       2, accuracy: 1e-4)
    }

    /// mirror: 엔진은 0 을 지나면 `T = −fmodf(T, D)` 로 **반사**하고 역방향 비트를 지운다
    /// (`0x1401aa13b`–`0x1401aa147`). 즉 삼각파는 0 을 축으로 하는 우함수다.
    func testMirrorModeReflectsAtZeroSoItIsAnEvenFunction() {
        for t: Float in [0.1, 0.6, 1.3, 2.2, 3.9, 5.4] {
            XCTAssertEqual(PuppetPose.frame(time: -t, fps: 4, length: 10, mode: "mirror"),
                           PuppetPose.frame(time: t, fps: 4, length: 10, mode: "mirror"),
                           accuracy: 1e-4, "mirror(−t) == mirror(t) — 0 에서 반사한다")
        }
        XCTAssertEqual(PuppetPose.frame(time: -0.25, fps: 4, length: 10, mode: "mirror"),
                       1, accuracy: 1e-4)
    }

    /// single: 엔진에는 음수 쪽 분기가 아예 없다(`0x1401aa177` 은 `T ≥ D` 만 본다). T 는 음수인 채로
    /// 남고 `Playback::sample` 의 인덱스 클램프(`0x1401705c8`)가 0 으로 물린다 — Waple 도 같다.
    /// **의도적으로 고치지 않은 자리**이므로 회귀 핀으로 박아 둔다.
    func testSingleModeLeavesNegativeTimeToTheDownstreamIndexClamp() throws {
        let f = PuppetPose.frame(time: -0.5, fps: 4, length: 10, mode: "single")
        XCTAssertLessThan(f, 0, "single 은 음수를 되돌리지 않는다(엔진에 그 분기가 없다)")
        let keys = [PuppetModel.Key(position: SIMD3(1, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1)),
                    PuppetModel.Key(position: SIMD3(9, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))]
        let trs = try XCTUnwrap(PuppetPose.sampledTRS(keys, frame: f))
        XCTAssertEqual(trs.position.x, 1, accuracy: 1e-5, "소비처 클램프가 프레임 0 으로 물린다")
    }

    // MARK: - 클립 flags bit0 → 꼬리 0xC0 레코드 (r2-H2)

    /// 엔진 기본값을 흉내낸 192바이트 레코드 — 선두 u32 가 `-1`(0xFFFFFFFF) 이라 이벤트 수로는
    /// 성립하지 않는다(`0x140264ff7` 이 심는 값). 나머지는 1.0f 로 채운다.
    private func flagBit0Record() -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        while out.count < 0xC0 { out.append(contentsOf: [0x00, 0x00, 0x80, 0x3F]) }   // 1.0f
        return out
    }

    /// **회귀 핀(r2-H2).** 클립 헤더의 `u32 flags` bit0 이 서면 본 트랙 뒤·이벤트 블록 앞에
    /// 0xC0(192)바이트 레코드가 하나 더 붙는다. 종전 파서는 `flags` 를 아예 읽지 않고
    /// (`fps|frameCount|boneCount` 셋만 바인딩하고 `o += 16`) 그 레코드의 선두 u32 를
    /// 이벤트 수로 오독했다 — 그 클립과 **그 뒤의 모든 클립**이 사라진다.
    func testClipFlagsBit0SkipsThe192ByteTailRecordBeforeTheEventBlock() throws {
        let clips = [
            Clip(id: 11, name: "flagged", mode: "loop", fps: 24, frameCount: 1,
                 flags: 1, tracks: [(0, [key(x: 3), key(x: 4)])],
                 flagBit0TailRecord: flagBit0Record()),
            Clip(id: 12, name: "after", mode: "single", fps: 24, frameCount: 1,
                 tracks: [(0, [key(x: 5), key(x: 6)])]),
        ]
        let m = try XCTUnwrap(PuppetModel.parse(makeMDL(
            bones: [("root", -1, identity, "")], clips: clips)))
        XCTAssertEqual(m.animations.count, 2,
                       "flags bit0 레코드를 못 건너뛰면 이 클립부터 뒤가 전부 유실된다")
        guard m.animations.count == 2 else { return }
        XCTAssertEqual(m.animations.map(\.name), ["flagged", "after"])
        XCTAssertEqual(m.animations[0].tracks[0][1].position.x, 4, accuracy: 1e-5)
        XCTAssertEqual(m.animations[1].tracks[0][0].position.x, 5, accuracy: 1e-5,
                       "레코드를 건너뛴 뒤 커서가 다음 클립 선두에 정확히 서야 한다")
    }

    /// **보수 게이트의 반대편.** `flags` bit0 이 서 있어도 그 자리에서 이벤트 블록이 이미
    /// 성립하면 건너뛰지 않는다 — 이 결함의 도달 모집단(MDLA flags bit0 클립)이 이 머신의
    /// 어떤 코퍼스에도 없어서(설치 .mdl 28개에 MDLS/MDLA 매직 0건) 종전에 통과하던 입력의
    /// 거동을 바꾸지 않는 쪽을 택했다. flags 만 다른 두 입력이 같은 결과를 내야 한다.
    func testClipFlagsBit0WithoutTheTailRecordParsesLikeFlagsZero() throws {
        func parse(flags: UInt32) throws -> PuppetModel {
            try XCTUnwrap(PuppetModel.parse(makeMDL(
                bones: [("root", -1, identity, "")],
                clips: [Clip(id: 21, name: "c", mode: "loop", fps: 24, frameCount: 1,
                             flags: flags, tracks: [(0, [key(x: 7), key(x: 8)])])])))
        }
        let plain = try parse(flags: 0)
        let flagged = try parse(flags: 1)
        XCTAssertEqual(flagged.animations.count, 1)
        XCTAssertEqual(flagged.animations.map(\.name), plain.animations.map(\.name))
        XCTAssertEqual(flagged.animations[0].tracks[0][1].position.x,
                       plain.animations[0].tracks[0][1].position.x, accuracy: 1e-5)
    }
}
