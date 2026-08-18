import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// fix-g3 감사 수정(F530–F544) 회귀 테스트. Metal 디바이스가 필요한 항목만 skip 가드를 둔다.
///
/// 테스트가 비현실적인 수정(사유 기록): F531(F-5, Metal 할당 실패 주입 불가), F532(F-6, 효과 파이프라인+
/// 인코더 실패 주입 불가), F536/F544(F-51/F-115, SCStream 은 화면 기록 권한 필요 — 공유 코어는 private),
/// F538(F-69, 라이브 창 + 사운드 패키지 마운트 통합 경로), F540(F-72, destination 포맷 가드가 동일 텍스처를
/// 먼저 거부해 관측 가능한 동작 델타 없음 — 미래 리팩터 대비 가드), F541(F-73, 스킨 파이프라인 선택적 실패 연출 불가).
final class SceneRenderFixRegressionTests: XCTestCase {

    // MARK: - F530(F-2/F-70): 유한 거대 float 의 Int() 변환 트랩 방어

    /// ParticleSystem.sheetFrameIndex(:50) 의 Int.max 가드와 동형 — 클램프 전 트랩이 없어야 한다.
    func testSafeFloatToInt_hugeFinite_clampsToIntMaxInsteadOfTrap() {
        XCTAssertEqual(SceneRenderer.safeFloatToInt(3e38, floor: 1), Int.max, "F530: 3e38 은 Int.max 로(종전 트랩)")
        XCTAssertEqual(SceneRenderer.safeFloatToInt(Float(Int.max), floor: 1), Int.max,
                       "F530: Float(Int.max)=2^63 경계값도 Int.max(F-70 의 projectionWidth 극단과 동일 클래스)")
    }

    func testSafeFloatToInt_nonFiniteAndNonPositive_returnsFloor() {
        XCTAssertEqual(SceneRenderer.safeFloatToInt(.nan, floor: 1), 1)
        XCTAssertEqual(SceneRenderer.safeFloatToInt(.infinity, floor: 0), 0)
        XCTAssertEqual(SceneRenderer.safeFloatToInt(-5, floor: 1), 1)
        XCTAssertEqual(SceneRenderer.safeFloatToInt(0, floor: 0), 0)
    }

    func testSafeFloatToInt_normalValues_matchLegacyRoundedClamp() {
        XCTAssertEqual(SceneRenderer.safeFloatToInt(100.4, floor: 1), 100)
        XCTAssertEqual(SceneRenderer.safeFloatToInt(100.5, floor: 1), 101)   // .rounded() = schoolbook
        XCTAssertEqual(SceneRenderer.safeFloatToInt(0.4, floor: 1), 1, "0.4 → rounded 0 → floor 1(종전 max(1,…)와 동일)")
    }

    /// 조작된 TEXS(거대 atlas 좌표/크기)도 트랩 없이 아틀라스 경계 내 서브렉트로 귀결(F-2 ①).
    func testSpriteSubrect_hugeTexFrameCoords_noTrapAndClamped() {
        let fr = TexImage.TexFrame(imageId: 0, time: 1, x: 3e38, y: 3e38, width: 3e38, height: 3e38)
        let r = SceneRenderer.spriteSubrect(atlasW: 256, atlasH: 128, frame: fr)
        XCTAssertEqual(r.x, 255); XCTAssertEqual(r.y, 127, "거대 좌표는 아틀라스 끝으로 클램프")
        XCTAssertEqual(r.w, 1); XCTAssertEqual(r.h, 1, "클램프된 좌표에서 크기는 최소 1")

        let fr2 = TexImage.TexFrame(imageId: 0, time: 1, x: 10, y: 10, width: 3e38, height: 3e38)
        let r2 = SceneRenderer.spriteSubrect(atlasW: 256, atlasH: 128, frame: fr2)
        XCTAssertEqual(r2.x, 10); XCTAssertEqual(r2.y, 10)
        XCTAssertEqual(r2.w, 246, "Int.max 크기는 aw - sx 로 클램프"); XCTAssertEqual(r2.h, 118)
    }

    /// 정상 TEXS 입력은 종전과 동일(무회귀).
    func testSpriteSubrect_normalFrame_unchanged() {
        let fr = TexImage.TexFrame(imageId: 0, time: 1, x: 4, y: 8, width: 32, height: 16)
        let r = SceneRenderer.spriteSubrect(atlasW: 256, atlasH: 128, frame: fr)
        XCTAssertEqual(r.x, 4); XCTAssertEqual(r.y, 8); XCTAssertEqual(r.w, 32); XCTAssertEqual(r.h, 16)
    }

    // MARK: - F533(F-7): 침러라 up 퇴화(영/평행/비유한) NaN 방어

    private func assertFinite(_ m: simd_float4x4, _ msg: String) {
        for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            XCTAssertTrue(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite, msg)
        }
    }

    func testLookAt_upParallelToForward_returnsFiniteMatrix() {
        // 탑다운/궤도 침러라 극점 통과 1프레임 — 종전 simd_normalize(영벡터)=NaN 이 viewProj 전체로 전파.
        let m = Scene3DMath.lookAt(eye: SIMD3<Float>(0, 0, 5), center: .zero, up: SIMD3<Float>(0, 0, 1))
        assertFinite(m, "F533: 전방과 평행한 up 은 기준축 폴백로 유한 행렬")
    }

    func testLookAt_zeroUp_returnsFiniteMatrix() {
        let m = Scene3DMath.lookAt(eye: SIMD3<Float>(0, 0, 5), center: .zero, up: .zero)
        assertFinite(m, "F533: 영벡터 up 도 유한 행렬")
    }

    func testLookAt_nonFiniteUp_returnsFiniteMatrix() {
        let m = Scene3DMath.lookAt(eye: SIMD3<Float>(0, 0, 5), center: .zero, up: SIMD3<Float>(.nan, 0, 0))
        assertFinite(m, "F533: 비유한 up 도 유한 행렬")
    }

    func testLookAt_eyeEqualsCenter_returnsFiniteMatrix() {
        // 베이스 침러라 자체 퇴화(parseCamera 미검증) — 호출부 폴백 밖에서도 total 함수 보장.
        let m = Scene3DMath.lookAt(eye: .zero, center: .zero, up: SIMD3<Float>(0, 1, 0))
        assertFinite(m, "F533: eye==center 도 -Z 폴백로 유한 행렬")
    }

    /// 정상 입력은 종전과 비트 동일(무회귀) — eye=(0,0,5), center=원점, up=+Y 표준 배치.
    func testLookAt_normalCase_unchanged() {
        let m = Scene3DMath.lookAt(eye: SIMD3<Float>(0, 0, 5), center: .zero, up: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(m.columns.0, SIMD4<Float>(1, 0, 0, 0))    // right
        XCTAssertEqual(m.columns.1, SIMD4<Float>(0, 1, 0, 0))    // up
        XCTAssertEqual(m.columns.2, SIMD4<Float>(0, 0, 1, 0))    // -f
        XCTAssertEqual(m.columns.3, SIMD4<Float>(0, 0, -5, 1))   // eye → 원점 사상
    }

    func testUpReference_degenerateOrValid_selectionRule() {
        // 평행/영 → 전방과 덜 정렬된 기준축, 유효 → 그대로.
        XCTAssertEqual(Scene3DMath.upReference(forward: SIMD3<Float>(0, 0, -1), up: SIMD3<Float>(0, 0, 2)),
                       SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(Scene3DMath.upReference(forward: SIMD3<Float>(0, 0, -1), up: .zero), SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(Scene3DMath.upReference(forward: SIMD3<Float>(0, 1, 0), up: SIMD3<Float>(0, -3, 0)),
                       SIMD3<Float>(1, 0, 0), "전방이 Y 축 정렬이면 X 축 폴백")
        XCTAssertEqual(Scene3DMath.upReference(forward: SIMD3<Float>(0, 0, -1), up: SIMD3<Float>(0, 1, 0)),
                       SIMD3<Float>(0, 1, 0), "유효 up 은 그대로(무회귀)")
    }

    // MARK: - F534(F-8): 명시 정지 중 가림 전이 무시(이중 보정/캡처 재기동 방지)

    func testOcclusionGate_duringPause_isFullyIgnored() {
        let r = SceneRenderer()
        r.startTime = 100
        r.scenePausedAt = 50   // 50초 시점에 명시 정지 중(pause() 가 오디오 정지·시각 소유 완료)
        var stopCount = 0, startCount = 0

        r.handleOcclusionGate(occluded: true, now: 60,
                              stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        XCTAssertNil(r.drawGateOccludedSince, "F534: 정지 중엔 가림 추적을 시작하지 않는다")

        r.handleOcclusionGate(occluded: false, now: 70,
                              stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        XCTAssertEqual(r.startTime, 100, accuracy: 1e-9,
                       "F534: 정지 중 가림 해제가 startTime 을 보정하지 않는다(resume() 단일 보정과의 이중 계산=시간 역행 방지)")
        XCTAssertEqual(stopCount, 0, "정지 중 재정지 호출 없음(pause() 가 이미 정지)")
        XCTAssertEqual(startCount, 0, "F534: 정지 중 오디오 캡처 재기동 없음")
    }

    // MARK: - F535(F-50): 씬 사운드 프라이머리 화면 게이트

    func testIsPrimaryScreenWindow_nilWindow_isFalse() {
        // 헤드리스(캡처/테스트)는 창이 없으므로 false — 종전 container.window == nil 스킵(결정성) 계약 보존.
        XCTAssertFalse(SceneRenderer.isPrimaryScreenWindow(nil))
    }

    /// 창이 실제 올라간 화면과의 일관성(단일 모니터 CI 에선 그 화면이 곧 프라이머리).
    func testIsPrimaryScreenWindow_realWindow_matchesWindowScreen() throws {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                           styleMask: [], backing: .buffered, defer: false)
        guard let screen = win.screen, let primary = NSScreen.screens.first else { throw XCTSkip("no screen (headless)") }
        XCTAssertEqual(SceneRenderer.isPrimaryScreenWindow(win), screen == primary,
                       "F535: 프라이머리 판정은 window.screen == NSScreen.screens.first 와 일치해야 한다")
    }

    // MARK: - F537(F-68): sceneScriptLayers 텍스트 initialVisible 존중

    func testSceneScriptLayers_textInitialVisibleFalse_isRespected() throws {
        var doc = SceneDocument(projectionWidth: 1920, projectionHeight: 1080,
                                clearColor: Vec3(x: 0, y: 0, z: 0),
                                parallaxEnabled: false, parallaxAmount: 0,
                                parallaxMouseInfluence: 0, parallaxDelay: 0,
                                layers: [], particles: [])
        var text = SceneTextLayer(text: "hello", script: nil, font: "Arial", pointSize: 12,
                                  color: Vec3(x: 1, y: 1, z: 1), alpha: 1,
                                  horizontalAlign: "left", verticalAlign: "top",
                                  origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1))
        text.name = "clock"
        text.initialVisible = false   // visible 스크립트 바인딩된 정적 비가시(SceneDocument:167-170 규약)
        doc.texts = [text]

        let layers = SceneRenderer.sceneScriptLayers(from: doc)
        let desc = try XCTUnwrap(layers.first { $0.name == "clock" })
        XCTAssertFalse(desc.visible, "F537: 텍스트도 initialVisible 존중(종전 true 하드코딩 — 최초 스크립트 판독 부정확)")
    }

    func testSceneScriptLayers_textDefaultVisibleTrue_unchanged() {
        var doc = SceneDocument(projectionWidth: 1920, projectionHeight: 1080,
                                clearColor: Vec3(x: 0, y: 0, z: 0),
                                parallaxEnabled: false, parallaxAmount: 0,
                                parallaxMouseInfluence: 0, parallaxDelay: 0,
                                layers: [], particles: [])
        var text = SceneTextLayer(text: "hello", script: nil, font: "Arial", pointSize: 12,
                                  color: Vec3(x: 1, y: 1, z: 1), alpha: 1,
                                  horizontalAlign: "left", verticalAlign: "top",
                                  origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1))
        text.name = "clock"
        doc.texts = [text]
        XCTAssertTrue(SceneRenderer.sceneScriptLayers(from: doc).first?.visible ?? false,
                      "기본(initialVisible=true)은 종전과 동일(무회귀)")
    }

    // MARK: - F542(F-74): colordodge/colorburn 경계 등호 — GLSL 내장본 정합

    func testBlendMSL_colorburnDodgeBoundary_matchesGLSLBuiltinStep() {
        // BuiltinShaderIncludes.commonBlending: colorburn = step(s,0)(s≤0), colordodge = step(1,s)(s≥1).
        XCTAssertTrue(BlendMSL.source.contains("s <= 0.0"),
                      "F542: colorburn 상수 선택은 s≤0(GLSL step(s,0)과 정합 — 음수 틴트 발산 해소)")
        XCTAssertTrue(BlendMSL.source.contains("s >= 1.0"),
                      "F542: colordodge 상수 선택은 s≥1(GLSL step(1,s)과 정합 — HDR 슈퍼브라이트 발산 해소)")
        XCTAssertFalse(BlendMSL.source.contains("s == 0.0"), "종전 등호(s==0) 제거 확인")
        XCTAssertFalse(BlendMSL.source.contains("s == 1.0"), "종전 등호(s==1) 제거 확인")
    }

    // MARK: - F543(F-75): QuadShaders.finiteLightFalloff radius<=0 가드

    func testQuadShaders_finiteLightFalloff_hasNonPositiveRadiusGuard() {
        XCTAssertTrue(QuadShaders.source.contains("if (radius <= 0.0) return 0.0;"),
                      "F543: QuadShaders 사본도 Mesh3DShaders:142 와 같은 radius<=0 가드(방어 일관성)")
    }

    // MARK: - F539(F-71): HDRPostPass 인코드 결과 반환(실패 전파 계약)

    /// 정상 인코드는 true — 새 Bool 계약의 성공 측(실패 측은 인코더 생성 실패 연출이 사실상 불가).
    func testHDRPostPass_encodeValidTextures_returnsTrue() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))

        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        let src = try XCTUnwrap(device.makeTexture(descriptor: sd))
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]
        let dst = try XCTUnwrap(device.makeTexture(descriptor: dd))

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(post.encode(cb: cb, src: src, dst: dst), "F539: 정상 인코드는 true 반환")
        cb.commit(); cb.waitUntilCompleted()
    }

    // MARK: - E1(⑦): mount() 오디오 스펙트럼 캡처 헤드리스 결정성 가드 (F286)

    /// mount()의 SCStream 오디오 스펙트럼 캡처가 형제 sceneAudio 블록(:1333, isPrimaryScreenWindow 가드)과
    /// 동일하게 container.window==nil(헤드리스)에서는 기동을 건너뛰어야 한다 — 종전엔 이 블록만 가드가
    /// 없어 테스트/캡처 경로에서도 화면 기록 권한을 요구하는 실 SCStream 캡처가 무조건 떴다.
    func testMountHeadlessSkipsAudioSpectrumCapture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_e1_audio_headless", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/x.json","origin":"10 10 0"}]}
        """
        // audioprocessingmode!=0 이미터 — buildParticles 가 hasAudio=true 로 승격(SceneRendererResources.swift:1169).
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":1,"audioprocessingmode":3}],
         "renderer":[{"name":"sprite"}],"maxcount":10,"material":"materials/x.json"}
        """
        let material = #"{"passes":[{"textures":["x"]}]}"#
        let pkgData = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("particles/x.json", particle.data(using: .utf8)!),
            ("materials/x.json", material.data(using: .utf8)!),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
        try pkgData.write(to: dir.appendingPathComponent("scene.pkg"))

        let project = WallpaperProject(
            id: "e1audio", type: .scene, fileName: "scene.pkg", previewName: nil, title: "e1audio",
            tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))  // 창에 미부착 — window == nil
        XCTAssertNil(container.window)
        let renderer = SceneRenderer()
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        XCTAssertTrue(renderer.hasAudio, "오디오반응 이미터가 있으면 hasAudio 는 계속 true 여야(무회귀)")
        XCTAssertNil(renderer.audioProvider, "헤드리스(window==nil)에서는 SCStream 캡처 프로바이더가 기동되면 안 됨")
    }

    // MARK: - F833: 보조 모니터 SceneRenderer 도 오디오 스펙트럼 프로바이더를 얻어야 한다

    /// 종전엔 audioProvider 게이트가 sceneAudio(재생)와 동일하게 isPrimaryScreenWindow 를 재사용해서,
    /// 보조 모니터(비-프라이머리 화면)에 뜬 SceneRenderer 인스턴스는 currentSpectrum 이 init 값 .silent 에서
    /// 영원히 안 바뀌었다(오디오-반응 씬이 보조 모니터에만 배정되면 프로세스 전체에서 provider 가 단 하나도
    /// 안 뜨는 최악의 경우까지 있었다). 실제 보조 모니터 없이도 window.screen == nil(화면 밖으로 멀리 옮긴
    /// 창)이면 isPrimaryScreenWindow 가 false 를 내므로 "비-프라이머리인데 헤드리스는 아님" 조건을
    /// 재현할 수 있다 — 창 자체(container.window)는 non-nil 이라 새 게이트(window != nil)는 통과해야 한다.
    func testMountNonPrimaryScreenWindowStillStartsAudioSpectrumCapture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_f833_audio_secondary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/x.json","origin":"10 10 0"}]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":1,"audioprocessingmode":3}],
         "renderer":[{"name":"sprite"}],"maxcount":10,"material":"materials/x.json"}
        """
        let material = #"{"passes":[{"textures":["x"]}]}"#
        let pkgData = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("particles/x.json", particle.data(using: .utf8)!),
            ("materials/x.json", material.data(using: .utf8)!),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
        try pkgData.write(to: dir.appendingPathComponent("scene.pkg"))

        let project = WallpaperProject(
            id: "f833audio", type: .scene, fileName: "scene.pkg", previewName: nil, title: "f833audio",
            tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)

        // 화면 경계 밖 좌표(1_000_000)에 얹은 창 — NSWindow.screen 은 창 프레임이 어느 화면과도 겹치지
        // 않으면 nil 을 반환(경험적 확인). 실제 다중 모니터 없이 "비-프라이머리" 를 흉내내는 가장 단순한 경로.
        let win = NSWindow(contentRect: NSRect(x: 1_000_000, y: 1_000_000, width: 100, height: 100),
                           styleMask: [], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        win.contentView = container
        XCTAssertNotNil(container.window, "창에 부착됐으므로 헤드리스가 아니다")
        XCTAssertNil(win.screen, "화면 경계 밖 창은 screen 이 nil(전제 확인)")
        XCTAssertFalse(SceneRenderer.isPrimaryScreenWindow(container.window),
                       "screen==nil 이면 isPrimaryScreenWindow 는 false — 종전 게이트라면 이 인스턴스는 provider 를 못 얻었다")

        let renderer = SceneRenderer()
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        XCTAssertTrue(renderer.hasAudio, "오디오반응 이미터가 있으면 hasAudio 는 true(무회귀)")
        XCTAssertNotNil(renderer.audioProvider,
                        "F833: 헤드리스가 아니면 비-프라이머리 화면이어도 스펙트럼 프로바이더가 기동돼야 한다")
    }

    // MARK: - E1(⑥): buildLayers projW/projH 클램프 통일(projection 0 씬 NaN 방지)

    /// scene.json 이 orthogonalprojection width/height 를 명시적 0 으로 주면 파서가 그대로 통과시킨다
    /// (SceneDocument.swift:735 `intVal(proj["width"]) ?? 1920`) — 종전 buildLayers 는 이 값을
    /// 무클램프로 quadVertices 에 넘겨 pxToNDC 의 `x / projW` 가 0-나눗셈으로 NaN/Inf 정점을 냈다
    /// (encodeLayer 의 per-frame 재계산 경로는 이미 max(1,…) 클램프된 projW/projH 를 써서 비대칭이었다).
    func testBuildLayersClampsZeroProjectionDimensionsAvoidingNaNVertices() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":0,"height":0}},
         "objects":[{"id":1,"image":"models/x.json","origin":"0 0 0","size":"10 10"}]}
        """
        let p = ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.projectionWidth, 0, "파서는 명시적 0 을 그대로 통과(무회귀 확인 — 클램프는 렌더러 책임)")
        XCTAssertEqual(doc.projectionHeight, 0)

        let renderer = SceneRenderer()
        let built = renderer.buildLayers(doc: doc, package: p, device: device, sceneID: "e1-projzero")
        XCTAssertEqual(built.count, 1)
        let verts = built[0].vertexBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4)
        for i in 0..<4 {
            XCTAssertTrue(verts[i].x.isFinite, "projection 0 이어도 정점 x 는 유한해야(0-나눗셈 NaN 방지)")
            XCTAssertTrue(verts[i].y.isFinite, "projection 0 이어도 정점 y 는 유한해야(0-나눗셈 NaN 방지)")
        }
    }

    /// E1(⑥): 텍스처 바이트는 찾았지만 디코드(TexImage.parse/makeImageTexture, 대체 bitmapRGBAFile 모두)에
    /// 실패하면 종전엔 레이어가 아무 로그 없이 통째로 드롭됐다(buildLayers:255 `else { continue }`).
    func testBuildLayersWarnsOnTextureDecodeFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        var captured: [String] = []
        let saved = WapleLog.warnHandler
        defer { WapleLog.warnHandler = saved }
        WapleLog.warnHandler = { captured.append($0) }

        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"0 0 0","size":"10 10"}]}
        """
        let p = ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", Data("not-a-real-tex".utf8)),  // 바이트는 존재하지만 디코드 실패
        ])
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        let built = renderer.buildLayers(doc: doc, package: p, device: device, sceneID: "e1-decodefail")
        XCTAssertEqual(built.count, 0, "디코드 실패 레이어는 계속 드롭돼야(무회귀)")
        XCTAssertTrue(captured.contains { $0.contains("texture decode failed") },
                      "디코드 실패가 경고 로그로 남아야 함(종전엔 무로그)")
    }

    /// 미해결 텍스처의 **조용한 백색 폴백**. 폴백 자체는 유지(미바인드 방지)하되 로그가 남아야 한다 —
    /// 흰색은 곱셈 항등원이라 노이즈/마스크/그라디언트 슬롯에서 결과가 "정상"처럼 보여 상류 원인을 가린다
    /// (실측: `util/clouds_N` 이 조용히 백색이 됐다). 이름이 nil 인 슬롯(설계상 placeholder)은 무로그.
    func testUnresolvedTextureFallbackIsLogged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        var captured: [String] = []
        let saved = WapleLog.warnHandler
        defer { WapleLog.warnHandler = saved }
        WapleLog.warnHandler = { captured.append($0) }

        let renderer = SceneRenderer()
        let p = ScenePackage.assemble([("scene.json", Data("{}".utf8))])

        let missing = renderer.resolveTexture("util/definitely_not_here_N", package: p, device: device)
        XCTAssertNotNil(missing, "폴백은 유지 — 미바인드로 두지 않는다")
        XCTAssertEqual(missing?.width, 1)
        XCTAssertTrue(captured.contains { $0.contains("texture unresolved") && $0.contains("definitely_not_here_N") },
                      "미해결 텍스처의 백색 폴백은 경고로 남아야 한다: \(captured)")

        captured.removeAll()
        let placeholder = renderer.resolveTexture(nil, package: p, device: device)
        XCTAssertNotNil(placeholder, "이름 없는 슬롯도 placeholder 를 받는다(무회귀)")
        XCTAssertTrue(captured.isEmpty, "이름이 없으면 '미해결'이 아니다 — 로그 스팸 금지: \(captured)")
    }
}
