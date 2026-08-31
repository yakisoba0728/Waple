import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// H1 검증: 커스텀 머티리얼 셰이더가 실제로 렌더에 적용되는지(픽셀 출력으로 확인).
final class SceneCustomShaderRenderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h1v","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        return try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
    }

    private func capture(_ files: [(String, Data)], id: String, size: Int = 200) throws -> NSBitmapImageRep {
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)),
                           project: try project(files: files, id: id))
        defer { renderer.teardown() }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_h1v_out_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: size, height: size, times: [0.1],
                                                       toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func inkBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.redComponent > 0.5 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func redBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y),
                      c.redComponent > 0.5, c.greenComponent < 0.3, c.blueComponent < 0.3 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// `perspective` 카메라 래퍼(`0x1401e8aa0`의 bit7 분기)는 material/custom 분기보다
    /// 바깥에서 virtual draw 전체를 감싼다. 따라서 같은 pass-through 재질은 stock 쿼드와
    /// origin.z·x/y 회전·FOV·near 평면 클립까지 같은 픽셀 외곽을 만들어야 한다.
    func testCustomShaderUsesLayerPerspectiveMVPAndGPUClip() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """

        func files(custom: Bool, originZ: Float, angleX: Float, angleY: Float) -> [(String, Data)] {
            let scene = """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"image":"models/x.json","origin":"100 100 \(originZ)","size":"80 60",
                         "scale":"1 1 1","angles":"\(angleX) \(angleY) 0.18","perspective":true,
                         "alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
            """
            let pass = custom
                ? #"{"passes":[{"shader":"pass","textures":["pic"]}]}"#
                : #"{"passes":[{"textures":["pic"]}]}"#
            var result: [(String, Data)] = [
                ("scene.json", Data(scene.utf8)),
                ("models/x.json", Data(#"{"width":80,"height":60,"material":"materials/m.json"}"#.utf8)),
                ("materials/m.json", Data(pass.utf8)),
                ("materials/pic.tex", solidTex(255, 255, 255)),
            ]
            if custom {
                result.append(("shaders/pass.vert", Data(vert.utf8)))
                result.append(("shaders/pass.frag", Data(frag.utf8)))
            }
            return result
        }

        func assertParity(originZ: Float, angleX: Float, angleY: Float, tag: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
            let stock = try capture(files(custom: false, originZ: originZ, angleX: angleX, angleY: angleY),
                                    id: "perspective_stock_\(tag)")
            let custom = try capture(files(custom: true, originZ: originZ, angleX: angleX, angleY: angleY),
                                     id: "perspective_custom_\(tag)")
            let a = try XCTUnwrap(inkBounds(stock), file: file, line: line)
            let b = try XCTUnwrap(inkBounds(custom), file: file, line: line)
            XCTAssertEqual(b.minX, a.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(b.maxX, a.maxX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(b.minY, a.minY, accuracy: 1, file: file, line: line)
            XCTAssertEqual(b.maxY, a.maxY, accuracy: 1, file: file, line: line)
        }

        try assertParity(originZ: 20, angleX: 0.55, angleY: -0.35, tag: "inside")
        let d = SceneCameraMath.layerPerspectiveDistance(orthoHeight: 200, fovDegrees: 60)
        try assertParity(originZ: d - 12, angleX: 0.8, angleY: 0.25, tag: "near_crossing")

        // stock 쿼드는 카메라 뒤라 CPU vertexCount=0이지만, custom vertex가 local z를 -20
        // 이동하면 다시 near/far 안으로 들어온다. custom 실행 전에 stock count로 잘라선 안 된다.
        let movedScene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200},
                    "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"100 100 \(d + 10)","size":"40 40",
                     "scale":"1 1 1","angles":"0 0 0","perspective":true,"visible":true}]}
        """
        let movingVert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            vec3 p = a_Position; p.z -= 20.0;
            gl_Position = mul(vec4(p, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord;
        }
        """
        let moved = try capture([
            ("scene.json", Data(movedScene.utf8)),
            ("models/x.json", Data(#"{"width":40,"height":40,"material":"materials/m.json"}"#.utf8)),
            ("materials/m.json", Data(#"{"passes":[{"shader":"move","textures":["pic"]}]}"#.utf8)),
            ("materials/pic.tex", solidTex(255, 255, 255)),
            ("shaders/move.vert", Data(movingVert.utf8)),
            ("shaders/move.frag", Data(frag.utf8)),
        ], id: "perspective_custom_moves_inside")
        XCTAssertNotNil(inkBounds(moved), "custom vertex가 카메라 안으로 옮긴 쿼드는 그려져야")
    }

    /// custom vertex가 만든 local z에는 scale.z가 적용되고, 이미지 스크립트/read-back의
    /// origin.z·scale.z·angles.x/y도 정적 def 대신 그 프레임의 유효 MVP로 전달돼야 한다.
    func testCustomPerspectiveShaderConsumesDynamicThreeDimensionalTransform() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            vec3 p = a_Position;
            p.z = a_Position.y * 20.0;
            gl_Position = mul(vec4(p, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """

        func files(originZ: Float, scaleZ: Float, angleX: Float, angleY: Float,
                   dynamic: Bool) -> [(String, Data)] {
            let origin = dynamic ? "100 100 0" : "100 100 \(originZ)"
            let scale = dynamic ? "1 1 1" : "1 1 \(scaleZ)"
            let angles = dynamic ? "0 0 0" : "\(angleX) \(angleY) 0"
            let angleXDegrees = angleX * 180 / Float.pi
            let angleYDegrees = angleY * 180 / Float.pi
            let alpha = dynamic
                ? #"{"value":1,"script":"thisLayer.origin = new Vec3(100,100,\#(originZ)); thisLayer.scale = new Vec3(1,1,\#(scaleZ)); thisLayer.angles = new Vec3(\#(angleXDegrees),\#(angleYDegrees),0); export function update(value){ return value; }"}"#
                : "1"
            let scene = """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"image":"models/x.json","origin":"\(origin)","size":"80 60",
                         "scale":"\(scale)","angles":"\(angles)","perspective":true,
                         "alpha":\(alpha)}]}
            """
            return [
                ("scene.json", Data(scene.utf8)),
                ("models/x.json", Data(#"{"width":80,"height":60,"material":"materials/m.json"}"#.utf8)),
                ("materials/m.json", Data(#"{"passes":[{"shader":"depth","textures":["pic"]}]}"#.utf8)),
                ("materials/pic.tex", solidTex(255, 255, 255)),
                ("shaders/depth.vert", Data(vert.utf8)),
                ("shaders/depth.frag", Data(frag.utf8)),
            ]
        }

        let angleX: Float = 0.55, angleY: Float = -0.35
        let authoredUnitZ = try capture(files(originZ: 20, scaleZ: 1, angleX: angleX, angleY: angleY,
                                              dynamic: false), id: "custom_3d_authored_z1")
        let authoredScaledZ = try capture(files(originZ: 20, scaleZ: 2, angleX: angleX, angleY: angleY,
                                                dynamic: false), id: "custom_3d_authored_z2")
        let scriptedScaledZ = try capture(files(originZ: 20, scaleZ: 2, angleX: angleX, angleY: angleY,
                                                dynamic: true), id: "custom_3d_scripted_z2")
        let unitBounds = try XCTUnwrap(inkBounds(authoredUnitZ))
        let authoredBounds = try XCTUnwrap(inkBounds(authoredScaledZ))
        let scriptedBounds = try XCTUnwrap(inkBounds(scriptedScaledZ))

        XCTAssertNotEqual(authoredBounds, unitBounds, "custom vertex의 local z에 scale.z가 적용돼야")
        XCTAssertEqual(scriptedBounds.minX, authoredBounds.minX, accuracy: 1)
        XCTAssertEqual(scriptedBounds.maxX, authoredBounds.maxX, accuracy: 1)
        XCTAssertEqual(scriptedBounds.minY, authoredBounds.minY, accuracy: 1)
        XCTAssertEqual(scriptedBounds.maxY, authoredBounds.maxY, accuracy: 1)
    }

    /// stock CPU 쿼드도 custom MVP처럼 clip-space w를 보존해야 UV가 perspective-correct로
    /// 보간된다. Rx=60° 평면의 화면 중심은 실제 local v=0.5지만, w=1로 평면화하면
    /// 투영된 상·하단 사이를 affine 보간해 v≈0.65를 읽는다.
    func testStockPerspectiveGradientMatchesCustomShaderInsideQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        func files(custom: Bool) -> [(String, Data)] {
            let scene = """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"image":"models/x.json","origin":"100 100 0","size":"120 120",
                         "scale":"1 1 1","angles":"1.04719755 0 0","perspective":true}]}
            """
            let material = custom
                ? #"{"passes":[{"shader":"pass","textures":["pic"]}]}"#
                : #"{"passes":[{"textures":["pic"]}]}"#
            var result: [(String, Data)] = [
                ("scene.json", Data(scene.utf8)),
                ("models/x.json", Data(#"{"width":120,"height":120,"material":"materials/m.json"}"#.utf8)),
                ("materials/m.json", Data(material.utf8)),
                ("materials/pic.tex", verticalGradientTex(top: (255, 0, 0), bottom: (0, 0, 255),
                                                           w: 32, h: 256)),
            ]
            if custom {
                result.append(("shaders/pass.vert", Data(vert.utf8)))
                result.append(("shaders/pass.frag", Data(frag.utf8)))
            }
            return result
        }

        let stock = try capture(files(custom: false), id: "perspective_gradient_stock")
        let custom = try capture(files(custom: true), id: "perspective_gradient_custom")
        let stockCenter = try XCTUnwrap(stock.colorAt(x: 100, y: 100))
        let customCenter = try XCTUnwrap(custom.colorAt(x: 100, y: 100))

        XCTAssertEqual(customCenter.redComponent, customCenter.blueComponent, accuracy: 0.06,
                       "custom MVP 중심은 그라디언트 v=0.5를 읽어야")
        XCTAssertEqual(stockCenter.redComponent, customCenter.redComponent, accuracy: 0.04)
        XCTAssertEqual(stockCenter.blueComponent, customCenter.blueComponent, accuracy: 0.04)
    }

    /// REFRACT는 별도 스냅샷 패스를 쓰지만, 그 레이어의 프로퍼티 update는 일반 stock 이미지와
    /// 같은 프레임 상태 평가를 거쳐야 한다. 종전 runRefractLayer는 정적 vertexBuffer를 곧바로
    /// 그려 Rx=60° 스크립트가 있어도 평면 높이 그대로였다.
    func testRefractPerspectiveLayerConsumesDynamicAngleTransform() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func files(angleXDegrees: Int) -> [(String, Data)] {
            let scene = """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[
               {"image":"models/bg.json","origin":"100 100 0","size":"200 200"},
               {"image":"models/fx.json","origin":"100 100 0","size":"80 60",
                "perspective":true,
                "angles":{"value":"0 0 0","script":"export function update(value){ return new Vec3(\(angleXDegrees), 0, 0); }"}}
             ]}
            """
            return [
                ("scene.json", Data(scene.utf8)),
                ("models/bg.json", Data(#"{"material":"materials/bg.json"}"#.utf8)),
                ("materials/bg.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255)),
                ("models/fx.json", Data(#"{"material":"materials/fx.json"}"#.utf8)),
                ("materials/fx.json", Data(#"{"passes":[{"textures":["red","normal"],"combos":{"REFRACT":1},"constantshadervalues":{"ui_editor_properties_refract_amount":0}}]}"#.utf8)),
                ("materials/red.tex", solidTex(255, 0, 0)),
                ("materials/normal.tex", solidTex(128, 128, 255)),
            ]
        }

        let flat = try capture(files(angleXDegrees: 0), id: "refract_dynamic_flat")
        let tilted = try capture(files(angleXDegrees: 60), id: "refract_dynamic_tilted")
        let flatBounds = try XCTUnwrap(redBounds(flat))
        let tiltedBounds = try XCTUnwrap(redBounds(tilted))

        XCTAssertGreaterThan(flatBounds.height, 50)
        XCTAssertLessThan(tiltedBounds.height, flatBounds.height * 0.8,
                          "REFRACT도 일반 이미지와 같은 dynamic Rx 정점을 소비해야")
    }

    /// geometry뿐 아니라 tint/alpha/visible과 완전 클립의 vertexCount=0도 stock 이미지와 같은
    /// 프레임 평가 결과를 써야 한다. stale vertexBuffer가 남아 있더라도 count=0이면 그리면 안 된다.
    func testRefractLayerSharesDynamicAppearanceVisibilityAndClipState() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func files(extra: String, albedo: (UInt8, UInt8, UInt8)) -> [(String, Data)] {
            let scene = """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[
               {"image":"models/bg.json","origin":"100 100 0","size":"200 200"},
               {"image":"models/fx.json","origin":"100 100 0","size":"80 60",
                "perspective":true\(extra)}
             ]}
            """
            return [
                ("scene.json", Data(scene.utf8)),
                ("models/bg.json", Data(#"{"material":"materials/bg.json"}"#.utf8)),
                ("materials/bg.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255)),
                ("models/fx.json", Data(#"{"material":"materials/fx.json"}"#.utf8)),
                ("materials/fx.json", Data(#"{"passes":[{"textures":["albedo","normal"],"combos":{"REFRACT":1},"constantshadervalues":{"ui_editor_properties_refract_amount":0}}]}"#.utf8)),
                ("materials/albedo.tex", solidTex(albedo.0, albedo.1, albedo.2)),
                ("materials/normal.tex", solidTex(128, 128, 255)),
            ]
        }

        let appearance = try capture(files(
            extra: #", "color":{"value":"1 1 1","script":"export function update(value){ return new Vec3(0, 1, 0); }"}, "alpha":{"value":1,"script":"export function update(value){ return 0.5; }"}"#,
            albedo: (255, 255, 255)), id: "refract_dynamic_appearance")
        let appearanceCenter = try XCTUnwrap(appearance.colorAt(x: 100, y: 100))
        XCTAssertEqual(appearanceCenter.greenComponent, 1, accuracy: 0.08)
        XCTAssertEqual(appearanceCenter.redComponent, 0.5, accuracy: 0.08)
        XCTAssertEqual(appearanceCenter.blueComponent, 0.5, accuracy: 0.08)

        let hidden = try capture(files(
            extra: #", "visible":{"value":true,"script":"export function update(value){ return false; }"}"#,
            albedo: (255, 0, 0)), id: "refract_dynamic_hidden")
        let hiddenCenter = try XCTUnwrap(hidden.colorAt(x: 100, y: 100))
        XCTAssertGreaterThan(hiddenCenter.greenComponent, 0.9,
                             "visible=false REFRACT 뒤의 흰 배경이 보여야")

        let clipped = try capture(files(
            extra: #", "alpha":{"value":1,"script":"thisLayer.origin = new Vec3(100, 100, 1000); export function update(value){ return value; }"}"#,
            albedo: (255, 0, 0)), id: "refract_dynamic_clipped")
        let clippedCenter = try XCTUnwrap(clipped.colorAt(x: 100, y: 100))
        XCTAssertGreaterThan(clippedCenter.greenComponent, 0.9,
                             "dynamic origin.z가 카메라 뒤면 stale quad를 그리지 않아야")
    }

    /// 커스텀 셰이더(빨간 반전)가 적용되면 출력이 빨간색이 아닌 반전색이어야 한다.
    /// 폴터(QuadShaders)면 원본 빨간 텍스처가 그대로 나온다.
    func testCustomShaderAppliesToRender() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"32 32","size":"64 64","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":64,"height":64,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"invert","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - c.r, 1.0 - c.g, 1.0 - c.b, c.a);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),  // 빨간 텍스처
            ("shaders/invert.vert", vert.data(using: .utf8)!),
            ("shaders/invert.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "invert"))
        defer { r.teardown() }
        // 커스텀 셰이더가 빌드됐는지 확인.
        XCTAssertNotNil(r.layers[0].customShader)
        // 캡처로 실제 픽셀 확인.
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 64, times: [0.1], toDir: outDir)
        guard let url = urls.first,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("capture failed"); return
        }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("context failed"); return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // 중앙 픽셀 확인 — 반전 셰이더면 빨강(255,0,0)이 아닌 시안(0,255,255)에 가까워야 한다.
        let center = (32 * 64 + 32) * 4
        let rVal = px[center], gVal = px[center + 1], bVal = px[center + 2]
        // 반전이면 r < 50, g > 200, b > 200. 폴터면 r > 200, g < 50, b < 50.
        XCTAssertTrue(rVal < 100 && gVal > 150 && bVal > 150,
                      "custom invert shader not applied (r=\(rVal), g=\(gVal), b=\(bVal))")
    }

    /// 회전 레이어의 커스텀 셰이더 변환: 번역 셰이더는 mul(v, eng.mvp)=v·M 계약이라 M·v 규약의
    /// layerTransformMatrix 를 전치해 바인딩해야 한다(무전치면 Dᵀ 회전 — 90° 회전 64×16 쿼드가
    /// 세로 스트립 대신 가로 스트립으로 그려진다). 무회전 레이어는 D=Dᵀ 이라 기존 테스트에서 잠복.
    func testCustomShaderRotatedLayerTransform() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"32 32","size":"64 16","scale":"1 1",
                     "angles":"0 0 1.5707963","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":64,"height":16,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"invert","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - c.r, 1.0 - c.g, 1.0 - c.b, c.a);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),
            ("shaders/invert.vert", vert.data(using: .utf8)!),
            ("shaders/invert.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "invert_rot"))
        defer { r.teardown() }
        _ = try XCTUnwrap(r.layers.first?.customShader)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_out_rot", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 64, times: [0.1], toDir: outDir)
        guard let url = urls.first,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("capture failed"); return
        }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("context failed"); return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // 64×16 쿼드 90° 회전 → 중심 (32,32) 의 세로 스트립(x∈[24,40], y∈[0,64]) 덮개.
        func isCyan(_ x: Int, _ y: Int) -> Bool {
            let o = (y * 64 + x) * 4
            return px[o] < 100 && px[o + 1] > 150 && px[o + 2] > 150
        }
        XCTAssertTrue(isCyan(32, 4), "세로 스트립 날린 위치(32,4)가 커버돼야 함(무전치면 가로 스트립이라 미커버)")
        XCTAssertFalse(isCyan(4, 32), "스트립 밖(4,32)은 배경(검정)이어야 함(무전치면 가로 스트립이라 칠해짐)")
    }

    /// F1(flip①): 커스텀 셰이더 2D 레이어가 effectQuadInterleaved(ev_main 전용, uv 반전)를 그대로 재사용하면
    /// 텍스처가 상하 반전된다. 세로 그라디언트(위=빨강/아래=파랑) 텍스처로 방향을 직접 단언 —
    /// 셰이더는 UV 를 손대지 않는 패스스루(실물 workshop tint.vert 근사)라 규약 위반이 그대로 드러난다.
    func testCustomShaderPreservesVerticalOrientation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"32 32","size":"64 64","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":64,"height":64,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"pass","textures":["pic"]}]}"#
        // 패스스루(UV 미변형) — 실물 workshop tint.vert 와 동일하게 v_TexCoord = a_TexCoord 만 한다.
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            // 위(top)=빨강, 아래(bottom)=파랑 세로 그라디언트.
            ("materials/pic.tex", verticalGradientTex(top: (255, 0, 0), bottom: (0, 0, 255))),
            ("shaders/pass.vert", vert.data(using: .utf8)!),
            ("shaders/pass.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "gradient"))
        defer { r.teardown() }
        XCTAssertNotNil(r.layers[0].customShader)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_out_grad", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 64, times: [0.1], toDir: outDir)
        guard let url = urls.first,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("capture failed"); return
        }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("context failed"); return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // 캡처 PNG 는 row0=이미지 상단(다른 스위트 전역 규약과 동일) — 화면 위쪽(y=4)은 빨강, 아래쪽(y=60)은 파랑이어야 한다.
        func sample(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (y * 64 + x) * 4
            return (px[o], px[o + 1], px[o + 2])
        }
        let top = sample(32, 4)
        let bottom = sample(32, 60)
        XCTAssertTrue(top.0 > 150 && top.2 < 100,
                      "화면 위쪽이 빨강이어야 함(텍스처 top) — 반전되면 파랑(r=\(top.0),b=\(top.2))")
        XCTAssertTrue(bottom.2 > 150 && bottom.0 < 100,
                      "화면 아래쪽이 파랑이어야 함(텍스처 bottom) — 반전되면 빨강(r=\(bottom.0),b=\(bottom.2))")
    }
}
