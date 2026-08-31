import AppKit
import Metal
import XCTest
@testable import WapleCore
@testable import WapleRender

/// Wallpaper Engine camera-parallax의 두 출력(셰이더 위치·오브젝트 이동)을 실제 렌더 경계에서 잠근다.
final class CameraParallaxRenderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_camera_parallax_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"camera-parallax","file":"scene.pkg"}"#.utf8)
            .write(to: dir.appendingPathComponent("project.json"))
        return try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func capture(_ files: [(String, Data)], id: String, width: Int, height: Int,
                         pointer: SIMD2<Float> = SIMD2<Float>(0.5, 0.5), time: Float = 0) throws
        -> NSBitmapImageRep {
        let renderer = SceneRenderer()
        renderer.capturePointerUV = pointer
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: width, height: height)),
                           project: try project(files: files, id: id))
        defer { renderer.teardown() }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_camera_parallax_\(id)_out", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: width, height: height, times: [time], toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func isRed(_ c: NSColor) -> Bool {
        c.redComponent > 0.55 && c.greenComponent < 0.25 && c.blueComponent < 0.25
    }

    private func isGreen(_ c: NSColor) -> Bool {
        c.greenComponent > 0.55 && c.redComponent < 0.25 && c.blueComponent < 0.25
    }

    private func redMask(_ bitmap: NSBitmapImageRep) -> Set<Int> {
        var out: Set<Int> = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), isRed(c) {
                    out.insert(y * bitmap.pixelsWide + x)
                }
            }
        }
        return out
    }

    private func brightMask(_ bitmap: NSBitmapImageRep) -> Set<Int> {
        var out: Set<Int> = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 0.75 {
                    out.insert(y * bitmap.pixelsWide + x)
                }
            }
        }
        return out
    }

    /// delay 보간은 최종 이동량과 독립적으로 focus/uniform을 수렴시켜야 한다. amount=0을
    /// 조기 종료 조건으로 쓰면 첫 프레임 뒤 needsDisplay가 끊겨 g_ParallaxPosition이 중간값에 멈춘다.
    func testDelaySettlingSignalDoesNotDependOnMovementAmount() {
        let renderer = SceneRenderer()
        renderer.projW = 200
        renderer.projH = 100
        renderer.parallaxEnabled = true
        renderer.parallaxAmount = 0
        renderer.parallaxMouseInfluence = 0
        renderer.parallaxDelay = 0.1
        renderer.parallaxFocus = .zero

        XCTAssertTrue(renderer.advanceCameraParallax(dt: 1.0 / 60.0, eye: .zero))
        XCTAssertGreaterThan(renderer.parallaxFocus.x, 0)
        XCTAssertLessThan(renderer.parallaxFocus.x, 100)
        XCTAssertGreaterThan(renderer.parallaxFocus.y, 0)
        XCTAssertLessThan(renderer.parallaxFocus.y, 50)
    }

    func testCaptureSubstepsResampleRuntimeEyeAtEachStep() {
        let renderer = SceneRenderer()
        renderer.projW = 100
        renderer.projH = 100
        renderer.parallaxEnabled = true
        renderer.parallaxMouseInfluence = 0
        renderer.parallaxDelay = 1
        renderer.parallaxFocus = .zero
        var clock: Float = 0

        renderer.advanceCaptureCameraParallax(to: 0.1, clock: &clock, step: 0.05) { time in
            SIMD2<Float>(10 * time, 0)
        }

        XCTAssertEqual(clock, 0.1, accuracy: 1e-6)
        XCTAssertEqual(renderer.parallaxFocus.x, 28.222222, accuracy: 1e-5,
                       "각 substep 끝 시각의 eye를 다시 샘플해야 한다")
        XCTAssertEqual(renderer.parallaxFocus.y, 27.777778, accuracy: 1e-5)
    }

    func testPerspectiveFallbackUpdatesUniformButNeverTranslatesObjectsOrHits() {
        let renderer = SceneRenderer()
        renderer.projW = 200
        renderer.projH = 100
        renderer.orthographicScene = false
        renderer.parallaxEnabled = true
        renderer.parallaxAmount = 0.5
        renderer.parallaxMouseInfluence = 0
        renderer.parallaxDelay = 0
        renderer.cameraParallaxRootByOrder[7] = SceneObjectParallaxDescriptor(
            order: 7, id: 7, parent: nil,
            origin: Vec2(x: 150, y: 50), depth: Vec2(x: 1, y: 1))

        _ = renderer.advanceCameraParallax(dt: 0, eye: SIMD2<Float>(20, -10))

        XCTAssertEqual(renderer.parallaxPosition.x, 0.6, accuracy: 1e-6,
                       "g_ParallaxPosition은 투영 종류와 무관하게 갱신")
        XCTAssertEqual(renderer.parallaxPosition.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(renderer.renderCameraParallaxOffsetPixels(order: 7), .zero,
                       "원근 씬은 2D 렌더 폴백이어도 root 평행이동 금지")
        XCTAssertEqual(renderer.hitCameraParallaxShift(origin: Vec2(x: 150, y: 50),
                                                       depth: Vec2(x: 1, y: 1)), .zero,
                       "interaction도 저작 투영 플래그를 따라야")
    }

    /// 원본은 pointer=(.25,.75)를 Y 반전해 focus/uniform=(.25,.25)로 내보낸다.
    /// g_PointerPosition과 g_ParallaxPosition이 같은 EngineU 슬롯이면 green이 .75가 되어 실패한다.
    func testParallaxPositionIsIndependentFromPointerPosition() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":1,"cameraparallaxdelay":0},
         "objects":[{"image":"models/x.json","origin":"32 32 0","size":"64 64",
                     "scale":"1 1 1","angles":"0 0 0","parallaxDepth":"0 0",
                     "alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
        """
        let model = #"{"width":64,"height":64,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"probe","textures":["white"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform vec2 g_PointerPosition;
        uniform vec2 g_ParallaxPosition;
        void main() { gl_FragColor = vec4(g_ParallaxPosition.x, g_ParallaxPosition.y, g_PointerPosition.y, 1.0); }
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(model.utf8)),
            ("materials/m.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255)),
            ("shaders/probe.vert", Data(vert.utf8)),
            ("shaders/probe.frag", Data(frag.utf8)),
        ]
        let renderer = SceneRenderer()
        renderer.capturePointerUV = SIMD2<Float>(0.25, 0.75)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                           project: try project(files: files, id: "uniform"))
        defer { renderer.teardown() }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_camera_parallax_uniform_out", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: out).first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try pixel(bitmap, 32, 32)
        // PNG/NSColor 경계의 색공간 변환 때문에 원시 0.25/0.75 수치 대신 채널 관계를 잠근다.
        // R/G는 같은 parallax (.25,.25), B만 pointer.y=.75라 확실히 더 밝아야 한다.
        XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.03,
                       "g_ParallaxPosition.y는 포인터 y=.75가 아니라 X와 같은 Y-flip focus=.25")
        XCTAssertGreaterThan(c.blueComponent - c.greenComponent, 0.3,
                             "g_PointerPosition.y=.75는 별도 슬롯에 남아야 한다")
    }

    /// influence=0은 이동 gain 0이 아니라 focus를 캔버스 중앙에 고정한다. 따라서 두 루트는
    /// origin-focus 부호에 따라 서로 반대 방향으로 25px 이동해야 한다.
    func testMouseInfluenceZeroStillMovesRootsAroundCenteredFocus() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":1,"image":"models/red.json","origin":"50 50 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,"visible":true},
          {"id":2,"image":"models/red.json","origin":"150 50 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
            ("materials/red.json", Data(material.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
        ], id: "centered_focus", width: 200, height: 100)
        XCTAssertTrue(isRed(try pixel(bitmap, 25, 50)), "root A center 50→25")
        XCTAssertTrue(isRed(try pixel(bitmap, 175, 50)), "root B center 150→175")
        XCTAssertFalse(isRed(try pixel(bitmap, 50, 50)), "이전 A 위치는 비어야")
        XCTAssertFalse(isRed(try pixel(bitmap, 150, 50)), "이전 B 위치는 비어야")
    }

    /// root의 origin 키프레임은 같은 프레임의 시차 기준점이어야 한다. mount 시점 x=40을 계속
    /// 쓰면 t=1의 동적 중심 80에 -30px을 더해 x=50에 그려지고, 현재값을 쓰면 -10px이라 x=70이다.
    func testAnimatedRootOriginDrivesSameFrameParallax() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":1,"image":"models/red.json","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "origin":{"animation":{"c0":[{"frame":0,"value":40},{"frame":30,"value":80}],
                                    "options":{"fps":30,"length":30,"mode":"single"}},
                     "value":"40 50 0"},
           "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
            ("materials/red.json", Data(material.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
        ], id: "animated_root", width: 200, height: 100, time: 1)
        XCTAssertTrue(isRed(try pixel(bitmap, 70, 50)), "동적 root 중심 80 + 현재 root shift -10")
        XCTAssertFalse(isRed(try pixel(bitmap, 50, 50)), "mount root shift -30을 재사용하면 안 된다")
    }

    /// parent는 JSON 배열에서 child보다 뒤에 올 수 있다. draw 순서를 parent-first로 바꾸면 z-order가
    /// 깨지므로, 부작용 없는 root origin keyframe만 같은 프레임 값으로 먼저 확정한다.
    func testChildDeclaredBeforeAnimatedRootUsesSameFrameRootOrigin() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":11,"parent":10,"image":"models/red.json","origin":"30 0 0","size":"10 10",
           "scale":"1 1 1","angles":"0 0 0","parallaxDepth":"0 0",
           "alpha":1,"color":"1 1 1","brightness":1,"visible":true},
          {"id":10,"image":"models/red.json","size":"10 10",
           "origin":{"animation":{"c0":[{"frame":0,"value":40},{"frame":30,"value":80}],
                                    "options":{"fps":30,"length":30,"mode":"single"}},
                     "value":"40 50 0"},
           "scale":"1 1 1","angles":"0 0 0","parallaxDepth":"1 1",
           "alpha":0,"color":"1 1 1","brightness":1,"visible":true}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
            ("materials/red.json", Data(material.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
        ], id: "child_before_animated_root", width: 200, height: 100, time: 1)
        XCTAssertTrue(isRed(try pixel(bitmap, 60, 50)),
                      "child는 나중에 선언된 root의 현재 x=80에서 계산한 -10px shift를 써야 한다")
        XCTAssertFalse(isRed(try pixel(bitmap, 40, 50)),
                       "mount 시 root x=40에서 계산한 -30px shift로 남으면 안 된다")
    }

    /// interaction도 표시된 프레임의 동적 쿼드와 현재 leaf origin을 써야 한다. draw는 root,
    /// hit은 leaf를 쓰는 비대칭 자체는 유지하되 둘 다 mount 스냅샷에 고정되면 안 된다.
    func testAnimatedLeafUpdatesPresentedInteractionGeometry() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let hook = "export function cursorClick(e) {}\nexport function update(v) { return v; }"
        let escapedHook = hook.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":1,"image":"models/red.json","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "origin":{"animation":{"c0":[{"frame":0,"value":40},{"frame":30,"value":80}],
                                    "options":{"fps":30,"length":30,"mode":"single"}},
                     "value":"40 50 0"},
           "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,
           "visible":{"value":true,"script":"\(escapedHook)"}}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                           project: try project(files: [
                            ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
                            ("materials/red.json", Data(material.utf8)),
                            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
                           ], id: "animated_leaf_hit"))
        defer { renderer.teardown() }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_camera_parallax_animated_leaf_hit_out", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertEqual(renderer.captureFrames(width: 200, height: 100, times: [1], toDir: out).count, 1)
        renderer.parallaxFocus = SIMD2<Float>(100, 50)

        let center = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        XCTAssertEqual(center.x, 70, accuracy: 0.001, "동적 leaf quad 80 + 현재 leaf shift -10")
        XCTAssertEqual(center.y, 50, accuracy: 0.001)
    }

    /// perspective 쿼드의 시차는 projection 뒤 상수 NDC가 아니라 object origin에 먼저 합성돼야 한다.
    /// yaw로 각 꼭짓점의 w가 달라도 "시차 -25px"과 "저작 origin -25px"은 같은 픽셀 집합이다.
    func testPerspectiveLayerParallaxMatchesAuthoredObjectTranslation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(originX: Float, parallax: Bool) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                        "cameraparallax":\(parallax),"cameraparallaxamount":0.5,
                        "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
             "objects":[
              {"id":1,"image":"models/red.json","origin":"\(originX) 50 25","size":"40 40",
               "scale":"1 1 1","angles":"0 0.7 0","perspective":true,
               "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
            """
        }
        let model = #"{"width":40,"height":40,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        func bitmap(_ scene: String, id: String) throws -> NSBitmapImageRep {
            try capture([
                ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
                ("materials/red.json", Data(material.utf8)),
                ("materials/red.tex", solidTex(255, 0, 0, w: 40, h: 40)),
            ], id: id, width: 200, height: 100)
        }

        let shiftedByParallax = try bitmap(scene(originX: 50, parallax: true), id: "perspective_parallax")
        let shiftedInObject = try bitmap(scene(originX: 25, parallax: false), id: "perspective_authored")
        XCTAssertEqual(redMask(shiftedByParallax), redMask(shiftedInObject),
                       "시차 translation은 perspective divide 전에 object origin에 더해야 한다")
    }

    func testPerspectiveCustomShaderParallaxMatchesAuthoredObjectTranslation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(originX: Float, parallax: Bool) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                        "cameraparallax":\(parallax),"cameraparallaxamount":0.5,
                        "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
             "objects":[{"id":1,"image":"models/red.json","origin":"\(originX) 50 25","size":"40 40",
                          "scale":"1 1 1","angles":"0 0.7 0","perspective":true,
                          "parallaxDepth":"1 1","alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
            """
        }
        let model = #"{"width":40,"height":40,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"shader":"parallaxprobe","textures":["red"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = "varying vec2 v_TexCoord; void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }"
        func bitmap(_ scene: String, id: String) throws -> NSBitmapImageRep {
            try capture([
                ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
                ("materials/red.json", Data(material.utf8)),
                ("materials/red.tex", solidTex(255, 0, 0, w: 40, h: 40)),
                ("shaders/parallaxprobe.vert", Data(vert.utf8)),
                ("shaders/parallaxprobe.frag", Data(frag.utf8)),
            ], id: id, width: 200, height: 100)
        }
        let a = try bitmap(scene(originX: 50, parallax: true), id: "perspective_custom_parallax")
        let b = try bitmap(scene(originX: 25, parallax: false), id: "perspective_custom_authored")
        XCTAssertEqual(redMask(a), redMask(b),
                       "custom MVP도 parallax를 perspective projection 전에 합성해야 한다")
    }

    func testPerspectiveTextParallaxMatchesAuthoredObjectTranslation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(originX: Float, parallax: Bool) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                        "cameraparallax":\(parallax),"cameraparallaxamount":0.5,
                        "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
             "objects":[{"id":1,"text":"MMMM","font":"systemfont_arial","pointsize":24,
                          "origin":"\(originX) 50 25","scale":"1 1 1","angles":"0 0.7 0",
                          "perspective":true,"parallaxDepth":"1 1",
                          "horizontalalign":"center","verticalalign":"center"}]}
            """
        }
        let a = try capture([("scene.json", Data(scene(originX: 50, parallax: true).utf8))],
                            id: "perspective_text_parallax", width: 200, height: 100)
        let b = try capture([("scene.json", Data(scene(originX: 25, parallax: false).utf8))],
                            id: "perspective_text_authored", width: 200, height: 100)
        XCTAssertEqual(brightMask(a), brightMask(b),
                       "text quad도 parallax를 perspective projection 전에 합성해야 한다")
    }

    /// 텍스트 content 스크립트가 재래스터한 폭도 mount 때 만든 pointer quad에 갇히면 안 된다.
    /// encodeText가 실제 표시 프레임의 raster/transform을 승격하는지 event-owner 경계로 검증한다.
    func testScriptedTextRasterUpdatesPresentedHitWidth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let script = """
        export function update(value) { return engine.runtime >= 1 ? 'AAAAAAAA' : 'x'; }
        export function cursorClick(e) {}
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":{"value":"x","script":"\(escaped)"},
                     "font":"systemfont_arial","pointsize":24,"origin":"100 50 0",
                     "scale":"1 1 1","horizontalalign":"center","verticalalign":"center"}]}
        """
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                           project: try project(files: [("scene.json", Data(scene.utf8))],
                                                id: "dynamic_text_hit"))
        defer { renderer.teardown() }
        guard case .object(let initialQuad) = try XCTUnwrap(renderer.pointerTargets.first).scope else {
            return XCTFail("초기 text pointer quad가 필요")
        }

        renderer.refreshScriptedTexts(device: device, time: 1)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_camera_parallax_dynamic_text_hit_out", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertEqual(renderer.captureFrames(width: 200, height: 100, times: [1], toDir: out).count, 1)
        guard case .object(let presentedQuad) = try XCTUnwrap(renderer.pointerTargets.first).scope else {
            return XCTFail("표시된 text pointer quad가 필요")
        }
        let initialWidth = sqrt(initialQuad.axisX.x * initialQuad.axisX.x
                                + initialQuad.axisX.y * initialQuad.axisX.y)
        let presentedWidth = sqrt(presentedQuad.axisX.x * presentedQuad.axisX.x
                                  + presentedQuad.axisX.y * presentedQuad.axisX.y)
        XCTAssertGreaterThan(presentedWidth, initialWidth * 3,
                             "긴 문자열의 새 raster 폭이 pointer geometry로 승격돼야")
    }

    /// 렌더 경로는 leaf가 아니라 parent를 끝까지 따라간 최상위 root의 origin/depth를 쓴다.
    /// A는 root depth=0이라 leaf depth=1이어도 고정, B는 leaf depth=0이어도 root depth=1로 이동한다.
    func testChildRenderingUsesTopmostRootOriginAndDepth() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":10,"image":"models/red.json","origin":"40 50 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"0 0","alpha":0,"visible":true},
          {"id":11,"parent":10,"image":"models/red.json","origin":"30 0 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"1 1","alpha":1,"visible":true},
          {"id":20,"image":"models/green.json","origin":"160 50 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"1 1","alpha":0,"visible":true},
          {"id":21,"parent":20,"image":"models/green.json","origin":"-30 0 0","size":"10 10","scale":"1 1 1","angles":"0 0 0",
           "parallaxDepth":"0 0","alpha":1,"visible":true}]}
        """
        let redModel = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let greenModel = #"{"width":10,"height":10,"material":"materials/green.json"}"#
        let redMaterial = #"{"passes":[{"textures":["red"]}]}"#
        let greenMaterial = #"{"passes":[{"textures":["green"]}]}"#
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)),
            ("models/red.json", Data(redModel.utf8)), ("models/green.json", Data(greenModel.utf8)),
            ("materials/red.json", Data(redMaterial.utf8)), ("materials/green.json", Data(greenMaterial.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
            ("materials/green.tex", solidTex(0, 255, 0, w: 10, h: 10)),
        ], id: "root_ancestry", width: 200, height: 100)
        XCTAssertTrue(isRed(try pixel(bitmap, 70, 50)), "root depth=0이면 child authored depth를 무시하고 고정")
        XCTAssertTrue(isGreen(try pixel(bitmap, 160, 50)), "root origin=160/depth=1의 +30px 이동을 child도 공유")
        XCTAssertFalse(isGreen(try pixel(bitmap, 130, 50)), "leaf depth=0을 쓰면 남는 이전 위치는 비어야")
    }

    /// 바이너리의 의도적 비대칭: draw는 root를 쓰지만 image/text interaction은 현재 leaf의
    /// raw local origin/depth를 쓴다. 이 장면의 child는 화면 (70,50)에 그려져도 hit 중심은 (35,25)다.
    func testInteractionParallaxUsesLeafInsteadOfRenderRoot() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let hook = "export function cursorClick(e) {}\nexport function update(v) { return v; }"
        let escapedHook = hook.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":10,"origin":"40 50 0","parallaxDepth":"0 0"},
          {"id":11,"parent":10,"image":"models/red.json","origin":"30 0 0","size":"10 10",
           "scale":"1 1 1","angles":"0 0 0","parallaxDepth":"1 1","alpha":1,"color":"1 1 1",
           "brightness":1,"visible":{"value":true,"script":"\(escapedHook)"}}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        let renderer = SceneRenderer()
        renderer.capturePointerUV = SIMD2<Float>(0.5, 0.5)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                           project: try project(files: [
                            ("scene.json", Data(scene.utf8)), ("models/red.json", Data(model.utf8)),
                            ("materials/red.json", Data(material.utf8)),
                            ("materials/red.tex", solidTex(255, 0, 0, w: 10, h: 10)),
                           ], id: "leaf_hit"))
        defer { renderer.teardown() }
        renderer.parallaxFocus = SIMD2<Float>(100, 50)

        let center = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        XCTAssertEqual(center.x, 35, accuracy: 0.001)
        XCTAssertEqual(center.y, 25, accuracy: 0.001)
    }

    /// 정사영 draw list의 model도 image/text/particle과 같은 root 이동 분기를 탄다.
    /// 원근 3D 씬만 translation 제외 대상이며, ortho-hybrid mesh를 빼면 원래 x=50에 남는다.
    func testOrthographicMeshUsesPerObjectRootParallax() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[
          {"id":1,"model":"models/plane.mdl","origin":"50 50 0","scale":"10 10 10",
           "parallaxDepth":"1 1","visible":true}]}
        """
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"textures":["red"],"combos":{"LIGHTING":0}}]}"#.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 2, h: 2)),
        ], id: "ortho_mesh", width: 200, height: 100)
        XCTAssertTrue(isRed(try pixel(bitmap, 25, 50)), "ortho mesh root center 50→25")
        XCTAssertFalse(isRed(try pixel(bitmap, 50, 50)), "시차 전 mesh 중심은 비어야")
    }

    /// ortho-hybrid projection의 aspect 보정은 2D 셰이더처럼 원점 중심에서 적용돼야 한다.
    /// 100×100 씬을 200×100 fit으로 잡으면 중앙 x=50은 출력 x=100이며, x=50으로 밀리면
    /// projection translation에 aspect를 적용하지 않은 것이다.
    func testOrthographicMeshFitKeepsProjectionCenterAlignedWith2D() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldFit = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = .fit
        defer { SceneRenderSettings.fitMode = oldFit }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"model":"models/plane.mdl","origin":"50 50 0","scale":"10 10 10"}]}
        """
        let bitmap = try capture([
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"textures":["red"],"combos":{"LIGHTING":0}}]}"#.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0, w: 2, h: 2)),
        ], id: "ortho_mesh_fit", width: 200, height: 100)
        XCTAssertTrue(isRed(try pixel(bitmap, 100, 50)), "fit 중앙은 출력 중앙에 있어야")
        XCTAssertFalse(isRed(try pixel(bitmap, 50, 50)), "잘못된 translation=-1 위치는 비어야")
    }
}
