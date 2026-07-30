import XCTest
import AppKit
import AVFoundation
import Metal
@testable import WapleCore
@testable import WapleRender

/// 감사 V06 SceneRenderer 코어 수정 회귀 테스트(소유: SceneRenderer.swift / SceneRenderer3D.swift /
/// SceneRendererFrameEncoder.swift / SceneVideoLayer.swift).
///  (1) teardown 리소스 해제 누락 4종(blendPipeline/composePipeline/effectVertexBuffer/effectQuadInterleaved)
///  (2) prepare3DSkinBuffers — ortho 하이브리드 다중 mesh3D 런에서 프레임당 2+회 적재(3슬롯 링 경합)
///  (3) startLive 실패 레이어의 라이브 draw 매 프레임 동기 디코드
///  (4) 가림 게이트가 오디오만 정지하고 AVPlayer 는 실시간 진행(클록 동결과 desync)
///  (5) ortho 하이브리드 build3D 의 빌보드/3D텍스트 이중 빌드(직후 폐기 + 2D 경로 재로드)
final class SceneRendererAuditV06RegressionTests: XCTestCase {

    // MARK: 공용 스캐폴드(SceneRendererSceneFixRegressionTests 와 동형)

    private func mount(scene: String, files: [(String, Data)], tag: String) throws -> (SceneRenderer, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_v06_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg([("scene.json", Data(scene.utf8))] + files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "v06_\(tag)_\(UUID().uuidString)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        return (renderer, root)
    }

    /// 유효 MDLV0023(비스키닝, ±1 XY 평면 4정점 — SceneRendererSceneFixRegressionTests.planeModel 과 동일 바이트).
    private func planeModel() -> Data {
        var data = Data("MDLV0023".utf8)
        data.append(0)
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func f32(_ value: Float) {
            var little = value
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        u32(0x0000000f); u32(1); u32(1)
        data.append(Data("materials/plane.json".utf8)); data.append(0)
        u32(0)
        f32(-1); f32(-1); f32(0); f32(1); f32(1); f32(0)
        u32(0x0000000f)
        let vertices: [(Float, Float, Float, Float)] = [
            (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
        ]
        u32(UInt32(vertices.count * 48))
        for (x, y, u, v) in vertices {
            [x, y, 0, 0, 0, 1, 1, 0, 0, -1, u, v].forEach(f32)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        u32(UInt32(indices.count * MemoryLayout<UInt16>.stride))
        for index in indices {
            var little = index.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// video 페이로드를 담는 최소 .tex(TEXB0001 — VideoBackedSceneCaptureTests.makeTex 와 동형).
    private func makeVideoTex(w: Int, h: Int, payload: Data) -> Data {
        var b: [UInt8] = []
        b += bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(0), i32b(0), i32b(w), i32b(h), i32b(w), i32b(h))
        b += bytes(tag("TEXB0001"), Array(payload))
        return Data(b)
    }

    /// 비디오 레이어(디코드 가능한 실 mp4) + 솔리드 형제 레이어 씬 마운트.
    private func mountVideoScene(tag: String) throws -> (SceneRenderer, URL) {
        let mp4URL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v06_\(tag)_\(UUID().uuidString).mp4")
        try makeTinyMP4(at: mp4URL)
        defer { try? FileManager.default.removeItem(at: mp4URL) }
        let mp4 = try Data(contentsOf: mp4URL)
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/vid.json","origin":"32 32 0","size":"64 64","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}},
           {"id":2,"image":"models/sib.json","origin":"32 32 0","size":"40 40","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}
         ]}
        """
        return try mount(scene: scene, files: [
            ("models/vid.json", Data(#"{"material":"materials/vidmat.json"}"#.utf8)),
            ("materials/vidmat.json", Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)),
            ("materials/v.tex", makeVideoTex(w: 64, h: 64, payload: mp4)),
            ("models/sib.json", Data(#"{"material":"materials/sibmat.json"}"#.utf8)),
            ("materials/sibmat.json", Data(#"{"passes":[{"shader":"flat"}]}"#.utf8)),
        ], tag: tag)
    }

    // MARK: (1) teardown 리소스 해제

    /// 수정 전: teardown 이 blendPipeline/composePipeline/effectVertexBuffer/effectQuadInterleaved 4종을
    /// 해제하지 않아 마운트 반복 시 GPU 리소스가 누적됐다 → 마운트 후 non-nil(전제), teardown 후 nil 이어야.
    func testTeardown_releasesBlendComposePipelinesAndEffectBuffers() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"32 32 0","size":"64 64"}]}
        """
        let (r, root) = try mount(scene: scene, files: [
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ], tag: "teardown")
        defer { try? FileManager.default.removeItem(at: root) }
        // 전제: 마운트가 4종을 빌드한다(무조건 생성 경로 — mount :1023/:1034/:1197/:1206).
        XCTAssertNotNil(r.blendPipeline); XCTAssertNotNil(r.composePipeline)
        XCTAssertNotNil(r.effectVertexBuffer); XCTAssertNotNil(r.effectQuadInterleaved)
        r.teardown()
        XCTAssertNil(r.blendPipeline, "teardown 리소스 해제 누락(blendPipeline)")
        XCTAssertNil(r.composePipeline, "teardown 리소스 해제 누락(composePipeline)")
        XCTAssertNil(r.effectVertexBuffer, "teardown 리소스 해제 누락(effectVertexBuffer)")
        XCTAssertNil(r.effectQuadInterleaved, "teardown 리소스 해제 누락(effectQuadInterleaved)")
    }

    // MARK: (2) prepare3DSkinBuffers 프레임당 1회 적재

    /// 수정 전: 같은 time 의 재호출(ortho 하이브리드 다중 mesh3D 런)마다 boneRing 3슬롯을 전진시켜
    /// 프레임 내에서 링이 감기면 GPU in-flight 슬롯을 CPU 가 덮어쓴다. 같은 time 은 같은 버퍼
    /// 인스턴스를 반환해야 하고(메모이), 새 time 은 다음 슬롯에 적재해야 한다.
    func testPrepare3DSkinBuffers_sameTimeReusesBuffer_newTimeAdvancesRing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let r = SceneRenderer()
        defer { r.teardown() }
        var model = Model3D(meshes: [])
        model.bones = [Model3D.Bone(name: "root", parent: -1, bind: matrix_identity_float4x4, properties: "")]
        r.meshRenderables = [SceneRenderer.MeshRenderable(
            id: 1, meshes: [], order: 0, name: "m", model: model, animIndex: -1, animRate: 1,
            boneRing: DynamicVertexBuffer(), castShadow: false)]

        let first = r.prepare3DSkinBuffers(time: 1.0, device: device)
        let buf1 = try XCTUnwrap(first[0], "스키닝 모델의 본 버퍼 적재")
        let second = r.prepare3DSkinBuffers(time: 1.0, device: device)
        XCTAssertTrue(second[0] === buf1,
                      "같은 프레임(time) 재호출은 링을 전진하지 않고 직전 버퍼를 재사용해야 한다(수정 전: 호출마다 다음 슬롯)")
        let third = r.prepare3DSkinBuffers(time: 1.033, device: device)
        XCTAssertNotNil(third[0])
        XCTAssertFalse(third[0] === buf1, "새 프레임(time 변경)은 다음 슬롯에 적재해야 한다")
    }

    // MARK: (2) teardown 스킨 버퍼 메모 리셋

    /// 스킨 버퍼 프레임 메모는 마운트 상태라 teardown 에서 함께 해제돼야 한다(마운트 재사용 시 이전
    /// 마운트의 본 버퍼 참조 잔류 방지).
    func testTeardown_clearsSkinBuffersFrameMemo() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let r = SceneRenderer()
        var model = Model3D(meshes: [])
        model.bones = [Model3D.Bone(name: "root", parent: -1, bind: matrix_identity_float4x4, properties: "")]
        r.meshRenderables = [SceneRenderer.MeshRenderable(
            id: 1, meshes: [], order: 0, name: "m", model: model, animIndex: -1, animRate: 1,
            boneRing: DynamicVertexBuffer(), castShadow: false)]
        _ = r.prepare3DSkinBuffers(time: 1.0, device: device)
        XCTAssertNotNil(r.skinBuffersFrameMemo, "적재 시 메모 세팅 전제")
        r.teardown()
        XCTAssertNil(r.skinBuffersFrameMemo, "teardown 은 스킨 버퍼 메모도 해제해야 한다")
    }

    // MARK: (3) startLive 실패 레이어 정적 폴 백

    /// 정적 폴 백은 1회만 디코드해 고정한다(라이브 draw 의 매 프레임 동기 디코드 금지) — 재호출 시
    /// 같은 텍스처 인스턴스를 반환해야 한다.
    func testStaticFallbackTexture_decodesOnceAndCaches() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mp4 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v06_fallback_\(UUID().uuidString).mp4")
        try makeTinyMP4(at: mp4)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let sv = SceneVideoLayer(mp4URL: mp4)
        defer { sv.teardown() }
        let t1 = try XCTUnwrap(sv.staticFallbackTexture(device: device), "t=0 정적 프레임 디코드")
        let t2 = try XCTUnwrap(sv.staticFallbackTexture(device: device))
        XCTAssertTrue(t1 === t2, "정적 폴 백은 1회 디코드 후 고정(재호출 시 재디코드 금지)")
    }

    /// 수정 전: startLive 실패(player=nil → isLive=false 유지)핸도 draw() 가 videoLayersLive=true 로
    /// 마킹(:1369-1371)해, buildDisplayTextures 가 라이브 draw(메인 스레드)에서 매 프레임
    /// headlessTexture(동기 copyCGImage + 최초 duration 세마포어 블로킹)를 돌렸다.
    /// 실패 기록된 레이어는 시간이 달라도 같은 정적 프레임을 반환해야 한다(1회 디코드 + 고정, 재시도 없음).
    func testBuildDisplayTextures_liveStartFailed_reusesStaticFrameAcrossTimes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let (r, root) = try mountVideoScene(tag: "fallback")
        defer { r.teardown(); try? FileManager.default.removeItem(at: root) }
        let idx = try XCTUnwrap(r.layers.firstIndex { $0.video != nil })
        let sv = try XCTUnwrap(r.layers[idx].video)
        // startLive 실패 상태 재현(CVMetalTextureCacheCreate 실패는 환경 의존이라 직접 유발 불가 — 플래그로 대체).
        sv.liveStartFailed = true
        let device = try XCTUnwrap(r.device)
        let cb = try XCTUnwrap(r.queue?.makeCommandBuffer())
        let t1 = r.buildDisplayTextures(device: device, time: 0.05, cb: cb)
        let t2 = r.buildDisplayTextures(device: device, time: 0.25, cb: cb)
        XCTAssertTrue(t1[idx] === t2[idx],
                      "startLive 실패 레이어는 정적 폴 백 고정 — 시간이 달라도 같은 텍스처(수정 전: 프레임별 동기 재디코드)")
    }

    /// 대조(무회귀 잠금): 실패 아닌 헤드리스 경로는 프레임별 scene-time 디코드를 유지한다(캡처 결정성 경로).
    func testBuildDisplayTextures_headlessNotFailed_stillDecodesPerFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let (r, root) = try mountVideoScene(tag: "headless")
        defer { r.teardown(); try? FileManager.default.removeItem(at: root) }
        let idx = try XCTUnwrap(r.layers.firstIndex { $0.video != nil })
        let device = try XCTUnwrap(r.device)
        let cb = try XCTUnwrap(r.queue?.makeCommandBuffer())
        let t1 = r.buildDisplayTextures(device: device, time: 0.0, cb: cb)
        let t2 = r.buildDisplayTextures(device: device, time: 0.2, cb: cb)
        XCTAssertFalse(t1[idx] === t2[idx], "헤드리스(캡처) 경로는 프레임별 디코드 유지(변경 없음 잠금)")
    }

    // MARK: (4) 가림 게이트 비디오 pause/resume 대칭

    /// 수정 전: occlusionStopAudio/StartAudioIfNeeded(F812)가 오디오만 정지/재기동하고 AVPlayer 는 계속
    /// 재생 — 씬 클록은 가림 구간만큼 동결(F290)하는데 비디오만 실시간 진행해 해제 시 desync.
    /// 가림 진입 시 비디오도 pause, 해제 시 resume 돼야 한다(오디오와 대칭).
    func testOcclusionGate_pausesAndResumesLiveVideoLikeAudio() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let (r, root) = try mountVideoScene(tag: "occlusion")
        defer { r.teardown(); try? FileManager.default.removeItem(at: root) }
        let sv = try XCTUnwrap(r.layers.compactMap(\.video).first, "비디오 레이어 공급자 부착")
        sv.startLive(device: device)   // draw() 첫 프레임의 지연 기동(:1370)과 동일
        defer { sv.teardown() }
        XCTAssertTrue(sv.isLive, "라이브 기동 성공 전제(실패 시 이 테스트는 무효)")
        let player = try XCTUnwrap(sv.player)
        XCTAssertEqual(player.rate, 1, accuracy: 0.01, "라이브 기동 직후 재생 중")

        r.occlusionStopAudio()   // 가림 진입 — 오디오 정지와 대칭으로 비디오도 정지해야
        XCTAssertEqual(player.rate, 0, accuracy: 0.001,
                       "가림 시 비디오도 정지해야 한다(씬 클록 동결 F290 과 정합 — 수정 전엔 계속 재생)")
        r.occlusionStartAudioIfNeeded()   // 가림 해제 — 오디오 재기동과 대칭으로 비디오도 재개
        XCTAssertEqual(player.rate, 1, accuracy: 0.01, "가림 해제 시 비디오 재개")
    }

    // MARK: (5) ortho 하이브리드 build3D 이중 빌드 스킵

    /// 수정 전: ortho 씬에서 build3D 가 빌보드(텍스처/효과/스크립트)·3D 텍스트 컨트롤러를 전량 빌드한 뒤
    /// mount 가 폐기(billboards=[]/text3DControllers=[])하고, 2D buildLayers/buildTexts 가 같은 자산·
    /// 스크립트를 재로드했다. build3D 자체가 ortho 모드면 이들을 건너뛰어야 한다(직접 호출로 구조 고정).
    func testOrthoHybrid_build3D_skipsBillboardsAnd3DTextControllers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"ring","model":"models/plane.mdl","origin":"32 32 0","scale":"20 20 20"},
           {"id":2,"image":"models/solid.json","origin":"32 32 0","size":"8 8"},
           {"id":3,"text":{"value":"0","script":"export function update(value) { return value; }"}}
         ]}
        """
        let package = ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
            ("models/solid.json", Data(#"{"material":"materials/solid.json"}"#.utf8)),
            ("materials/solid.json", Data(#"{"passes":[{"shader":"flat"}]}"#.utf8)),
        ])
        let doc = try SceneDocument.parse(package: package)
        XCTAssertNil(doc.camera3D, "ortho 씬 전제(하이브리드 판정 키)")
        let r = SceneRenderer()
        r.sceneScript = SceneScriptContext()
        r.projW = Float(doc.projectionWidth); r.projH = Float(doc.projectionHeight)
        r.build3D(doc: doc, package: package, device: device)
        defer { r.teardown() }
        XCTAssertEqual(r.meshRenderables.count, 1, "메시 적재는 종전대로")
        XCTAssertTrue(r.billboards.isEmpty,
                      "ortho 모드의 build3D 는 빌보드를 빌드하지 않아야 한다(수정 전: 빌드 후 mount 가 폐기 — 이중 작업)")
        XCTAssertTrue(r.text3DControllers.isEmpty,
                      "ortho 모드의 build3D 는 3D 텍스트 컨트롤러를 빌드하지 않아야 한다(2D buildTexts 가 담당)")
    }

    /// 수정 전의 이중 빌드는 레이어 스크립트 top-level 사이드이펙트를 2회 실행했다(build3D 빌보드 엔진
    /// + 2D buildLayers 엔진). 하이브리드 마운트 후엔 1회만 실행돼야 한다.
    func testOrthoHybrid_layerScriptTopLevelSideEffectRunsOnce() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"ring","model":"models/plane.mdl","origin":"32 32 0","scale":"20 20 20"},
           {"id":2,"image":"models/w.json","origin":"32 32 0","size":"64 64",
            "alpha":{"value":1,"script":"shared.v06hybrid=(shared.v06hybrid||0)+1;"}}
         ]}
        """
        let (r, root) = try mount(scene: scene, files: [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ], tag: "hybrid")
        defer { r.teardown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(r.ortho3DHybrid, "하이브리드 진입 전제")
        XCTAssertEqual(r.meshRenderables.count, 1)
        let runs = r.sceneScript?.context.evaluateScript("shared.v06hybrid")?.toInt32() ?? -1
        XCTAssertEqual(runs, 1,
                       "레이어 스크립트 top-level 은 1회만 실행돼야 한다(수정 전: build3D 빌보드 엔진 + 2D 엔진 = 2회)")
    }
}
