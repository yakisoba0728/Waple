import XCTest
import simd
@testable import WapleCore

/// `.mdl` 은 `.pkg` 안에서 온다 = **파일이 시키는 값**이다. 거짓 본 수·거짓 프레임 수·순환 부모·
/// 범위 밖 인덱스에서 Waple 이 트랩하지 않고 degrade 하는지 고정한다.
///
/// 대조 기준(wallpaper64.exe 2.8.42): WE 는 같은 자리에서 **즉사**한다 — 트랙 블롭 크기를 36 으로
/// 나눠(`0xE38E38E38E38E38F` / `shr rdx,5` @0x140263c61) 몫이 `frameCount+1` 이 아니거나 나머지가
/// 0 이 아니면 `int 0x29`(__fastfail) 다(0x140263c8c / 0x140263c95). Waple 은 그 자리에서 죽는 대신
/// 그 애니만 버리고 정지 메시를 살린다 — 배경화면 프로세스가 사라지는 것보다 낫다는 판단.
final class PuppetHostileInputTests: XCTestCase {

    // MARK: - 합성 MDLV0013 빌더

    private struct Anim {
        var name = "a"
        var mode = "loop"
        var fps: Float = 10
        var length: UInt32 = 1
        var boneCountField: UInt32? = nil        // nil = tracks.count
        var tracks: [(size: UInt32?, keys: [[Float]], blob2: UInt32)] = []
    }

    private func le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le(_ v: Float) -> [UInt8] { le(v.bitPattern) }

    /// `bones` = (이름, 부모, tx, ty). `boneCountField` 로 헤더의 본 수만 거짓말시킬 수 있다.
    private func makeMDL(vertices: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>)],
                         indices: [UInt16],
                         bones: [(String, Int32, Float, Float)]? = nil,
                         boneCountField: UInt32? = nil,
                         anims: [Anim]? = nil,
                         animCountField: UInt32? = nil) -> Data {
        var d = [UInt8]("MDLV0013".utf8)
        d += [UInt8](repeating: 0, count: 13)
        d += [UInt8]("materials/x.json".utf8) + [0]
        d += le(UInt32(0))                                   // 용도 미상 u32 — 탐색이 건너뛴다
        d += le(UInt32(vertices.count * 52))
        for (p, bi, w) in vertices {
            d += le(p.x) + le(p.y) + le(p.z)
            d += le(bi.x) + le(bi.y) + le(bi.z) + le(bi.w)
            d += le(w.x) + le(w.y) + le(w.z) + le(w.w)
            d += le(Float(0)) + le(Float(0))                 // uv
        }
        d += le(UInt32(indices.count * 2))
        for i in indices { d += [UInt8(i & 0xFF), UInt8(i >> 8)] }

        if let bones {
            d += [UInt8]("MDLS0001".utf8) + [0]
            d += le(UInt32(0))                               // nextOff (파서 미사용)
            d += le(boneCountField ?? UInt32(bones.count))
            for (name, parent, tx, ty) in bones {
                d += [UInt8](name.utf8) + [0]
                d += le(UInt32(1))                           // flags
                d += le(UInt32(bitPattern: parent))
                d += le(UInt32(64))
                let m: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]
                for f in m { d += le(f) }
                d += [0]
            }
        }
        if let anims {
            d += [UInt8]("MDLA0001".utf8) + [0]
            d += le(UInt32(0))                               // nextOff
            d += le(animCountField ?? UInt32(anims.count))
            d += le(UInt32(7))                               // id
            d += le(UInt32(0))
            for a in anims {
                d += [UInt8](a.name.utf8) + [0]
                d += [UInt8](a.mode.utf8) + [0]
                d += le(a.fps)
                d += le(a.length)
                d += le(UInt32(0))
                d += le(a.boneCountField ?? UInt32(a.tracks.count))
                d += le(UInt32(0))
                for t in a.tracks {
                    d += le(t.size ?? UInt32(t.keys.count * 36))
                    for k in t.keys { for f in k { d += le(f) } }
                    d += le(t.blob2)
                }
            }
        }
        return Data(d)
    }

    private func oneVertex() -> [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>)] {
        [(SIMD3(0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0))]
    }
    private static let restKey: [Float] = [0, 0, 0, 0, 0, 0, 1, 1, 1]

    // MARK: - 거짓 본 수

    /// MDLS0001 이 본 40억 개라고 주장해도 루프 상한으로 삼지 않는다 — 상한(100k) 초과는
    /// **본 없이** 반환하고 정지 메시는 산다.
    func testAbsurdBoneCountYieldsBonelessModelNotHang() throws {
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0)], boneCountField: 0xFFFF_FFFF)
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.bones.count, 0, "거짓 본 수는 본 전량 포기")
        XCTAssertEqual(m.vertices.count, 1, "메시는 살아 있어야 한다")
    }

    /// 상한 **아래**의 거짓말(레코드가 없는데 9만 본이라고 함)도 레코드 파스 실패로 빠져나온다.
    /// 이 테스트가 도는 것 자체가 "루프가 유한하다" 는 단언이다.
    func testUnderCapBoneCountWithNoRecordsTerminates() throws {
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [], boneCountField: 99_999)
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.bones.count, 0)
        XCTAssertEqual(m.vertices.count, 1)
    }

    // MARK: - 순환 / 범위 밖 부모

    /// 순환 부모(0→1, 1→0)에서 무한재귀·범위밖 인덱싱이 없어야 한다. 규약은 `p < i` 게이트 —
    /// 자기 이후를 가리키는 부모는 루트로 떨어진다.
    func testCyclicBoneParentsAreBrokenNotRecursed() {
        var m = PuppetModel(material: "m", vertices: [], indices: [])
        let t = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 1))
        m.bones = [.init(name: "a", parent: 1, bind: t), .init(name: "b", parent: 0, bind: t)]
        let w = PuppetPose.worldMatrices(model: m,
                                         layers: [(anim: 0, additive: false, weight: 1, rate: 1)], time: 0)
        XCTAssertEqual(w.count, 2)
        for mat in w {
            for c in 0..<4 { for r in 0..<4 { XCTAssertTrue(mat[c][r].isFinite) } }
        }
        XCTAssertEqual(w[0].columns.3.x, 1, accuracy: 1e-5, "부모 1 은 자기 이후 → 루트 취급")
        XCTAssertEqual(w[1].columns.3.x, 2, accuracy: 1e-5, "부모 0 은 유효 → 누적")
    }

    /// 부모 필드가 큰 u32 로 오면 `Int32(bitPattern:)` 이 음수를 만든다 → 루트.
    /// (`Int32(parentRaw)` 였다면 이 파일에서 트랩이다.)
    func testHugeUnsignedParentBecomesRoot() throws {
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", Int32(bitPattern: 0xFFFF_FFF0), 3, 0)])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.bones.count, 1)
        XCTAssertEqual(m.bones[0].parent, -16)
        let w = PuppetPose.bindWorlds(m)
        XCTAssertEqual(w[0].columns.3.x, 3, accuracy: 1e-5)
    }

    // MARK: - 거짓 프레임 수 / 트랙 크기

    /// 헤더가 1000 프레임이라 주장하고 키는 2개뿐인 트랙. WE 는 여기서 __fastfail 이지만
    /// (0x140263c88 `cmp rdx, rcx` → `int 0x29`), Waple 은 트랙 길이로 클램프해 마지막 키를 문다.
    func testFalseFrameCountClampsToLastKeyInsteadOfTrapping() throws {
        let k1: [Float] = [0, 0, 0, 0, 0, 0, 1, 1, 1]
        let k2: [Float] = [50, 0, 0, 0, 0, 0, 1, 1, 1]
        var a = Anim(); a.length = 1000; a.mode = "single"
        a.tracks = [(size: nil, keys: [k1, k2], blob2: 0)]
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0)], anims: [a])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.animations.count, 1)
        XCTAssertEqual(m.animations[0].lengthFrames, 1000, "헤더 값은 그대로 보존")
        XCTAssertEqual(m.animations[0].tracks[0].count, 2, "실제 키는 2개")
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 99)
        let p = PuppetPose.skinnedPositions(model: m, matrices: mats)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].x, 50, accuracy: 1e-3, "범위 밖 프레임은 마지막 키로 물린다")
        XCTAssertTrue(p[0].x.isFinite && p[0].y.isFinite && p[0].z.isFinite)
    }

    /// 트랙 크기가 36의 배수가 아니면 그 애니를 버리고 메시는 산다(WE 는 0x140263c95 에서 즉사).
    ///
    /// 크기 4 를 쓰는 이유: 파일에는 온전한 키 1개(36B)+blob2 가 이어지므로 `%36` 가드가 없으면
    /// 파서가 **키를 하나 읽고 오프셋만 4 전진해** 그럴듯한 애니를 만들어 낸다(돌연변이 검증에서
    /// 실제로 그랬다 — 37 을 쓰면 EOF 가드에 먼저 걸려 이 가드를 못 고정한다).
    func testTrackSizeNotMultipleOf36DropsAnimationKeepsMesh() throws {
        var a = Anim()
        a.tracks = [(size: 4, keys: [Self.restKey], blob2: 0)]
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0)], anims: [a])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.animations.count, 0, "손상 트랙은 애니 드롭")
        XCTAssertEqual(m.bones.count, 1, "본은 유지")
        XCTAssertEqual(m.vertices.count, 1, "메시는 유지")
    }

    /// 트랙 크기가 파일 잔여를 넘으면(4GB 주장) 애니만 버린다 — 할당 폭주도, 트랩도 없다.
    func testTrackSizeBeyondEOFDropsAnimation() throws {
        var a = Anim()
        // 0xFFFF_FFFC = 36 × 119_304_647 — 36 의 배수이면서 파일보다 크다(크기 게이트만 남긴다).
        XCTAssertEqual(UInt32(0xFFFF_FFFC) % 36, 0, "테스트 전제")
        a.tracks = [(size: 0xFFFF_FFFC, keys: [Self.restKey], blob2: 0)]
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0)], anims: [a])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.animations.count, 0)
        XCTAssertEqual(m.vertices.count, 1)
    }

    /// 트랙 꼬리 blob2 크기가 4GB 여도 오프셋이 64비트라 감싸지 않고, 다음 읽기가 nil 로 끝난다.
    func testHugeTrailingBlobSizeDoesNotWrapOffset() throws {
        var a = Anim()
        a.tracks = [(size: nil, keys: [Self.restKey], blob2: 0xFFFF_FFFF),
                    (size: nil, keys: [Self.restKey], blob2: 0)]
        a.boneCountField = 2
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0), ("arm", 0, 0, 0)], anims: [a])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.animations.count, 0, "부분 트랙 애니는 드롭")
        XCTAssertEqual(m.bones.count, 2)
    }

    /// 헤더 animCount 가 40억이어도 파일이 끝나면 루프가 끝난다(누적분 유지).
    func testAbsurdAnimCountTerminatesKeepingParsedAnimations() throws {
        var a = Anim(); a.name = "real"
        a.tracks = [(size: nil, keys: [Self.restKey, Self.restKey], blob2: 0)]
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 0],
                        bones: [("root", -1, 0, 0)], anims: [a], animCountField: 0xFFFF_FFFF)
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.animations.count, 1, "완료된 1개는 유지, 나머지는 EOF 로 종료")
        XCTAssertEqual(m.animations[0].name, "real")
    }

    // MARK: - 범위 밖 인덱스

    /// 정점의 본 인덱스가 본 수를 넘으면 스킨 행렬 배열 밖이다 — 마지막 행렬로 클램프한다
    /// (WE 는 셰이더가 `g_Bones[blendIndices.x]` 를 그대로 인덱싱해 정의되지 않은 값을 읽는다).
    func testOutOfRangeVertexBoneIndexIsClamped() throws {
        let d = makeMDL(vertices: [(SIMD3(1, 2, 3), SIMD4(0xFFFF_FFFF, 0, 0, 0), SIMD4(1, 0, 0, 0))],
                        indices: [0, 0, 0], bones: [("root", -1, 0, 0)])
        let m = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(m.vertices[0].boneIndices.x, 0xFFFF_FFFF)
        let p = PuppetPose.skinnedPositions(
            model: m, matrices: PuppetPose.skinMatrices(model: m, animation: 0, time: 0))
        XCTAssertTrue(p[0].x.isFinite && p[0].y.isFinite && p[0].z.isFinite)
    }

    /// 인덱스 블롭이 정점 수를 넘게 가리키면 **모델 자체를 거부**한다(메시가 붕괴하므로
    /// 폴터 쿼드가 낫다 — PuppetModel.swift 의 F441 정책).
    func testIndexBeyondVertexCountRejectsModel() {
        let d = makeMDL(vertices: oneVertex(), indices: [0, 0, 9])
        XCTAssertNil(PuppetModel.parse(d))
    }

    // MARK: - 재생 시계의 퇴화 입력

    /// fps ≤ 0 / length ≤ 0 은 WE 라면 클립 초기화가 실패(false 반환)하는 자리다
    /// (0x1401a8c21 `comiss` → 0x1401a8cc4, 0x1401a8c43 → 같은 곳). 여기선 프레임 0 으로 떨어진다.
    func testNonPositiveFpsOrLengthYieldsFrameZero() {
        XCTAssertEqual(PuppetPose.frame(time: 5, fps: 0, length: 10, mode: "loop"), 0)
        XCTAssertEqual(PuppetPose.frame(time: 5, fps: -1, length: 10, mode: "loop"), 0)
        XCTAssertEqual(PuppetPose.frame(time: 5, fps: 10, length: 0, mode: "loop"), 0)
        XCTAssertEqual(PuppetPose.frame(time: 5, fps: 10, length: -3, mode: "loop"), 0)
    }

    /// `Playback::sample` 0x140170580–0x1401705f6 의 인덱스/보간계수 규약 고정점:
    /// `i = clamp(trunc(T/fd), 0, frameCount-1)`, `j = min(i+1, frameCount)`, `t = fmod(T,fd)/fd`.
    /// 키 수가 `frameCount+1` 이므로 `j` 는 마지막 키까지 닿는다.
    func testSampleIndexAndFractionFollowPlaybackSample() {
        let keys = (0...3).map {
            PuppetModel.Key(position: SIMD3(Float($0) * 10, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))
        }
        // frameCount = 3, 키 4개.
        for (f, want) in [(Float(0), Float(0)), (0.5, 5), (1.25, 12.5), (2.75, 27.5), (3, 30)] {
            guard let s = PuppetPose.sampledTRS(keys, frame: f) else { return XCTFail("샘플 실패") }
            XCTAssertEqual(s.position.x, want, accuracy: 1e-4, "frame \(f)")
        }
        // 음수/초과는 양 끝으로 물린다(엔진의 clamp 와 같은 방향).
        XCTAssertEqual(PuppetPose.sampledTRS(keys, frame: -5)?.position.x ?? .nan, 0, accuracy: 1e-4)
        XCTAssertEqual(PuppetPose.sampledTRS(keys, frame: 99)?.position.x ?? .nan, 30, accuracy: 1e-4)
    }
}
