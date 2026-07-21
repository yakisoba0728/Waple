import XCTest
import simd
@testable import WapleCore

/// 감사 수정 회귀(F430-F443) — WapleCore 씬 문서/파티클/모델 그룹. 전부 결정적(시드 고정·파일 IO 無).
final class SceneParticleModelFixRegressionTests: XCTestCase {

    // MARK: 헬퍼

    private func scenePkg(_ sceneJSON: String, _ extra: [(String, String)] = []) -> ScenePackage {
        var files: [(name: String, data: Data)] = [("scene.json", Data(sceneJSON.utf8))]
        for (n, c) in extra { files.append((name: n, data: Data(c.utf8))) }
        return ScenePackage.assemble(files)
    }

    /// 결정적 파티클 def(박스 이미터, distanceMax 0 → 정확히 origin).
    private func def0(initializers: [Initializer] = [.lifetimeRandom(min: 100, max: 100)],
                      operators ops: [ParticleOperator] = [],
                      rate: Float = 1000, burst: Int = 0,
                      startTime: Float = 0, maxCount: Int = 10,
                      children: [ChildLink] = []) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: rate, burst: burst)],
            initializers: initializers,
            operators: ops,
            renderer: .sprite, maxCount: maxCount, startTime: startTime, material: nil,
            children: children)
    }

    /// 실측 MDLV0013 레이아웃의 최소 합성 바이트(스켈레톤/애니 섹션 없음).
    private func mdlV0013(vertCount: Int, indices: [UInt16]) -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))  // 13B 헤더
        d.append(Data("m".utf8)); d.append(0)
        func u32(_ v: UInt32) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(0)                                  // 용도 미상(파서 프로브가 건륶뜀)
        u32(UInt32(vertCount * 52))             // 정점 블롭
        for _ in 0..<vertCount {
            var rec = [Float](repeating: 0, count: 13)   // 52B 전부 0 비트 = 유효 정점
            rec.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        u32(UInt32(indices.count * 2))
        for i in indices { var v = i; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return d
    }

    // MARK: F430 — 파티클 def 공유에셋 폴터(SceneDocument.parseParticleDef)

    func testF430_ParticleDefFallsBackToSharedAssets() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"particle": "particles/fx.json", "id": 7, "origin": "0 0"}]}
        """
        let defJSON = """
        {"emitter": [{"name": "boxrandom", "rate": 10}], "maxcount": 10}
        """
        // pkg 에는 scene.json 만 — 파티클 json 은 base-assets 에만 존재하는 씬.
        let doc = try SceneDocument.parse(package: scenePkg(scene),
                                          assets: { $0 == "particles/fx.json" ? Data(defJSON.utf8) : nil })
        XCTAssertEqual(doc.particles.count, 1, "공유에셋 폴터로 파티클 def 를 로드해야 한다(종전 통째 드롭)")
        XCTAssertEqual(doc.particles.first?.def.emitters.count, 1)
    }

    // MARK: F431 — angularvelocityrandom 초기 각속도 적분(오퍼레이터 부재)

    func testF431_InitialAngularVelocityIntegratesWithoutOperator() {
        let def = def0(initializers: [.lifetimeRandom(min: 100, max: 100),
                                      .angularVelocityRandom(min: Vec3(x: 0, y: 0, z: 2),
                                                             max: Vec3(x: 0, y: 0, z: 2))],
                       operators: [], maxCount: 1)   // angularmovement 부재
        var sim = ParticleSimulator(def: def, seed: 1)
        let s = sim.step(0.1)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].rotation.z, 0.2, accuracy: 1e-4,
                       "오퍼레이터 없이도 초기 각속도(2 rad/s) × dt(0.1) 만큼 회전해야 한다")
    }

    // MARK: F432 — 원샷 자식의 startTime 게이트

    func testF432_OneShotChildWaitsForStartTime() {
        let child = def0(initializers: [.lifetimeRandom(min: 10, max: 10)],
                         rate: 0, burst: 3, startTime: 0.05)
        let parent = def0(initializers: [.lifetimeRandom(min: 100, max: 100)], rate: 0, burst: 1,
                          children: [ChildLink(def: child, trigger: .spawnBurst, maxInstances: 4,
                                               probability: 1, origin: Vec3(x: 0, y: 0, z: 0))])
        var sim = ParticleSimulator(def: parent, seed: 42)
        var maxChild = 0
        for _ in 0..<6 { _ = sim.step(1.0 / 60); maxChild = max(maxChild, sim.childDisplay(0).count) }
        XCTAssertEqual(maxChild, 3,
                       "자식 startTime(0.05) 도달 스텝에서 버스트 3개가 발화돼야 한다(종전 첫 스텝 후 영구 정지)")
    }

    // MARK: F433 — raw RGBA 페이로드가 TEXV 헤더를 포함하지 않음

    func testF433_RawRGBAPayloadSkipsTEXVHeader() {
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(0) + i32(0) + i32(2) + i32(2) + i32(2) + i32(2)   // format=0, flags, texW/H, imgW/H
        b += Array(repeating: UInt8(0xAB), count: 16)              // 2×2 RGBA 픽셀(TEXB 컨테이너 없음)
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .rawRGBA8888)
        XCTAssertEqual(t?.payloadRange, 42..<58,
                       "픽셀은 42B TEXV 헤더 뒤에서 시작해야 한다(종전 헤더가 픽셀로 디코드)")
    }

    // MARK: F434 — 사운드 startsilent/playbackmode 바인딩 언랩

    func testF434_SoundBindingsAreUnwrapped() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"sound": ["a.mp3"],
                      "startsilent": {"user": "silent", "value": true},
                      "playbackmode": {"user": "mode", "value": "multi"}}]}
        """
        let doc = try SceneDocument.parse(package: scenePkg(scene))
        XCTAssertEqual(doc.sounds.count, 1)
        XCTAssertTrue(doc.sounds[0].startSilent, "{user,value} 바인딩을 언랩해야 한다(종전 무조건 false)")
        XCTAssertEqual(doc.sounds[0].playbackMode, "multi")
    }

    // MARK: F435 — 스크립트-only blend 정적 기본값 0

    func testF435_ScriptOnlyBlendDefaultsToZero() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"model": "m.mdl",
                      "animationlayers": [{"name": "A", "blend": {"script": "return 1;"}},
                                          {"name": "B"}]}]}
        """
        let doc = try SceneDocument.parse(package: scenePkg(scene))
        let als = doc.objects3D.first?.animationLayers ?? []
        XCTAssertEqual(als.count, 2)
        XCTAssertEqual(als[0].blend, 0,
                       "스크립트-only blend 는 시작 0(형제 선택 경로 parseAnimationLayers 와 대칭)")
        XCTAssertEqual(als[1].blend, 1, "blend 키 부재는 종전 기본 1 유지(무회귀)")
    }

    // MARK: F436 — parent 있지만 id 없는 레이어도 부모 합성

    func testF436_LayerWithParentButNoIDIsComposed() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 1, "origin": "100 50 0"},
                     {"image": "a.json", "parent": 1, "origin": "10 5 0"}]}
        """
        let model = #"{"material": "mat.json"}"#
        let material = #"{"passes": [{"textures": ["tex"]}]}"#
        let doc = try SceneDocument.parse(package: scenePkg(scene, [("a.json", model), ("mat.json", material)]))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].origin.x, 110, accuracy: 0.001)
        XCTAssertEqual(doc.layers[0].origin.y, 55, accuracy: 0.001)
    }

    // MARK: F437 — 레이어/노드 id 중복 시 레이어 우선

    func testF437_LayerWinsOnLayerNodeIDCollision() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"image": "a.json", "id": 5, "parent": 2, "origin": "10 0 0"},
                     {"id": 2, "origin": "100 0 0"},
                     {"id": 5, "origin": "999 0 0"}]}
        """
        let model = #"{"material": "mat.json"}"#
        let material = #"{"passes": [{"textures": ["tex"]}]}"#
        let doc = try SceneDocument.parse(package: scenePkg(scene, [("a.json", model), ("mat.json", material)]))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].origin.x, 110, accuracy: 0.001,
                       "노드(id 5)가 레이어의 localT 를 덮어쓰면 1099 가 된다 — 레이어 우선이어야 한다")
    }

    // MARK: F438 — 실행 이력이 있는 sim 의 step(0) 은 재방출하지 않는다(스냅샷 경로 상태 불변)

    func testF438_StepZeroDoesNotReEmitAfterRealSteps() {
        // 수명 0.15 버스트 — 발화(step 1)→전멸(step 2) 이력(time>0) 후 step(0) 은 재버스트하지 않는다.
        // rate: 0 명시 — F621 부터 burst+rate 병행이라 def0 기본 rate(1000)가 남으면 연속 방출이
        // maxCount 까지 채워져 버스트 의도 측정이 불가능해진다.
        var sim = ParticleSimulator(def: def0(initializers: [.lifetimeRandom(min: 0.15, max: 0.15)],
                                              rate: 0, burst: 5), seed: 7)
        _ = sim.step(0.1)                       // 버스트 발화(5, age 0.1 < 0.15)
        _ = sim.step(0.2)                       // 수명 초과 → 전멸
        XCTAssertEqual(sim.liveCount, 0)
        XCTAssertEqual(sim.step(0).count, 0, "실행 이력이 있는 sim 의 step(0) 은 재버스트하지 않는다")
        XCTAssertEqual(sim.liveCount, 0)
        XCTAssertEqual(sim.step(0.1).count, 5, "다음 실스텝에서는 재버스트(ponytail 루프)가 정상 동작")
    }

    func testF438_FreshSimStepZeroStillFiresInitialBurst() {
        var sim = ParticleSimulator(def: def0(burst: 5), seed: 7)
        XCTAssertEqual(sim.step(0).count, 5,
                       "무이력 sim 의 초기 버스트는 종전대로 발화(기존 ParticleSystemTests 호환)")
    }

    // MARK: F439 — angularmovement 다수여도 rotation 적분은 스텝당 1회

    func testF439_MultipleAngularMovementsIntegrateOnce() {
        let def = def0(operators: [.angularMovement(force: Vec3(x: 0, y: 0, z: 1), drag: 0),
                                   .angularMovement(force: Vec3(x: 0, y: 0, z: 1), drag: 0)],
                       maxCount: 1)
        var sim = ParticleSimulator(def: def, seed: 1)
        let s = sim.step(0.1)
        // 누적 ω = (1+1)·0.1 = 0.2, rotation = ω·dt = 0.02 (종전 루프 내 적분: 0.01+0.02 = 0.03)
        XCTAssertEqual(s[0].rotation.z, 0.02, accuracy: 1e-5,
                       "선형 movement 와 대칭으로 적분은 스텝당 1회여야 한다")
    }

    // MARK: F440 — remapValue(velocity) 가 같은 스텝의 힘 오퍼레이터를 덮어쓰지 않음

    func testF440_RemapVelocityDoesNotWipeForces() {
        let def = def0(operators: [
            .remapValue(output: .velocity(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                        fbm: false, inputScale: 1),
            .controlPointAttract(scale: 1000, threshold: 0, target: Vec3(x: 100, y: 0, z: 0)),
        ], maxCount: 1)
        var sim = ParticleSimulator(def: def, seed: 1)
        let s = sim.step(0.1)
        XCTAssertEqual(s.count, 1)
        XCTAssertGreaterThan(s[0].pos.x, 0,
                             "remap(0) 덮어쓰기 후 attract 가속이 같은 스텝에 반영돼야 한다(종전 전량 덮어씀)")
    }

    // MARK: F441 — MDLV0013 인덱스 상한 검증

    func testF441_V0013RejectsOutOfRangeIndices() {
        XCTAssertNotNil(PuppetModel.parse(mdlV0013(vertCount: 3, indices: [0, 1, 2])))
        XCTAssertNil(PuppetModel.parse(mdlV0013(vertCount: 3, indices: [0, 1, 5])),
                     "maxIndex ≥ vCount 인 손상 인덱스 블롭은 파스 실패(→ 폴터 쿼드)여야 한다(Model3D:255 와 대칭)")
    }

    // MARK: F442 — 퇴화(영스케일) 행렬 역행렬의 NaN 전파 차단

    func testF442_DegenerateBindDoesNotPropagateNaN() {
        var model = PuppetModel(material: "", vertices: [], indices: [])
        model.bones = [PuppetModel.Bone(name: "b", parent: -1,
                                        bind: simd_float4x4(diagonal: SIMD4<Float>(0, 1, 1, 1)))]
        model.animations = [PuppetModel.Animation(
            name: "a", mode: "loop", fps: 30, lengthFrames: 1,
            tracks: [[PuppetModel.Key(position: SIMD3<Float>(1, 2, 0), angles: .zero,
                                      scale: SIMD3<Float>(1, 1, 1))]])]
        let skins = PuppetPose.skinMatrices(model: model, animation: 0, time: 0)
        XCTAssertEqual(skins.count, 1)
        for c in 0..<4 { for r in 0..<4 {
            XCTAssertTrue(skins[0][c][r].isFinite, "영스케일 바인드의 역행렬은 항등 폴터(NaN 전파 금지)")
        } }
    }

    func testF442_AdditiveDegenerateReferenceDoesNotPropagateNaN() {
        var model = PuppetModel(material: "", vertices: [], indices: [])
        model.bones = [PuppetModel.Bone(name: "b", parent: -1, bind: matrix_identity_float4x4)]
        model.animations = [PuppetModel.Animation(
            name: "a", mode: "loop", fps: 30, lengthFrames: 1,
            tracks: [[PuppetModel.Key(position: .zero, angles: .zero, scale: SIMD3<Float>(0, 1, 1))]])]
        let skins = PuppetPose.blendedSkinMatrices(
            model: model, layers: [(anim: 0, additive: true, weight: 1, rate: 1)], time: 0)
        XCTAssertEqual(skins.count, 1)
        for c in 0..<4 { for r in 0..<4 {
            XCTAssertTrue(skins[0][c][r].isFinite, "가산 델타 기준(프레임0) 퇴화 시에도 NaN 전파 금지")
        } }
    }

    // MARK: F443 — 빈 클립명은 이름 매칭 후보에서 제외

    func testF443_EmptyClipNameIsNotMatched() {
        var model = PuppetModel(material: "", vertices: [], indices: [])
        model.animations = [
            PuppetModel.Animation(name: "", mode: "loop", fps: 30, lengthFrames: 1, tracks: []),
            PuppetModel.Animation(name: "walk", mode: "loop", fps: 30, lengthFrames: 1, tracks: []),
        ]
        XCTAssertEqual(PuppetPose.clipIndex(model: model, name: "walk", fallback: 0), 1,
                       "빈 클립명은 contains 가 항상 참이라 매칭 후보에서 제외해야 한다")
    }
}
