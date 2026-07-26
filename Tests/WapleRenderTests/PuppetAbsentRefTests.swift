import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// H3 회귀: 퍼펫 ref(model json "puppet" 키)가 **pkg 에 부재**할 때의 처리.
/// 실측(capture.log 78회): WE 기본 모델 `models/1x1.json` 이 `"puppet":"models/1x1_puppet.mdl"`
/// 를 참조하나 해당 .mdl 이 pkg 에 미베이크(코퍼스 2955378002: 그런 레이어 50개). 종전 buildLayers 는
/// 이를 로깅 assetData 로 로드 시도 → "asset missing" + "puppet mdl load failed" 스팸.
/// WE 규약(changelog: "Only load puppet ref if file exists on global file system")은 부재를 조용히 건너뛴다.
/// 저장된 실물 퍼펫은 파싱 정상(코퍼스 226개 전수 parse nil=0) — 파서 결함 아님.
final class PuppetAbsentRefTests: XCTestCase {
    /// 유효 MDLV0023(비스키닝 3정점) — PuppetModel.parse 가 Model3D 경유로 로드(실측 레이아웃).
    private func validPuppetMDLV0023() -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0)
        func u(_ v: UInt32) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f(_ v: Float) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u(0x0000000f); u(1); u(1)                       // formatFlag, const(1), meshCount=1
        d.append(Data("materials/p.json".utf8)); d.append(0)  // material cstring
        u(0)                                            // 미상 u32(0)
        f(-1); f(0); f(0); f(1); f(2); f(0)             // aabb min/max
        u(0x0000000f)                                   // vertex format(비스키닝)
        u(UInt32(3 * 48))                               // 정점 블롭(3 × stride48)
        for (px, py): (Float, Float) in [(-1, 0), (1, 0), (0, 2)] {
            f(px); f(py); f(0); f(0); f(0); f(1); f(1); f(0); f(0); f(-1); f(0); f(0)  // pos3 nrm3 tan4 uv2
        }
        u(UInt32(3 * 2))                                // 인덱스 블롭
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }

    func testAbsentPuppetRefIsSilent_presentUnparseableStillLogs_validLoads() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/absent.json","origin":"32 32 0","size":"8 8"},
           {"id":2,"image":"models/garbage.json","origin":"32 32 0","size":"8 8"},
           {"id":3,"image":"models/valid.json","origin":"32 32 0","size":"8 8"}
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("materials/m.json", Data(#"{"passes":[{}]}"#.utf8)),   // 무텍스처 → solid 레이어(.tex 불요, 퍼펫 경로 도달)
            ("models/absent.json",  Data(#"{"material":"materials/m.json","puppet":"models/absent_puppet.mdl"}"#.utf8)),
            ("models/garbage.json", Data(#"{"material":"materials/m.json","puppet":"models/garbage_puppet.mdl"}"#.utf8)),
            ("models/valid.json",   Data(#"{"material":"materials/m.json","puppet":"models/valid_puppet.mdl"}"#.utf8)),
            // absent_puppet.mdl 은 일부러 미저장 — 실측 1x1_puppet.mdl 댕글링 ref 재현
            ("models/garbage_puppet.mdl", Data("NOPEBYTES".utf8)),  // 존재하나 파싱 불가
            ("models/valid_puppet.mdl", validPuppetMDLV0023()),
        ]
        let package = ScenePackage.assemble(files)
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        let (layers, log) = captureStderr {
            renderer.buildLayers(doc: doc, package: package, device: device, sceneID: "test")
        }

        // 퍼펫 유무와 무관하게 세 이미지 레이어 모두 쿼드로 남아야(부재는 스킵이 아니라 정적 쿼드)
        XCTAssertEqual(layers.count, 3, "이미지 레이어는 퍼펫 부재여도 드롭되면 안 됨")
        // 저장된 유효 MDLV0023 퍼펫만 로드(present-path 무회귀 가드)
        XCTAssertEqual(layers.filter { $0.puppet != nil }.count, 1, "유효 퍼펫 1개만 로드돼야")

        // === 근본원인 red→green: 부재 ref 는 실패로 로그되면 안 됨(WE: 존재 시만 로드) ===
        XCTAssertFalse(log.contains("puppet mdl load failed (static quad fallback): models/absent_puppet.mdl"),
                       "부재 퍼펫 ref 를 로드 실패로 로깅하면 안 됨(수정 전 실패 지점)")
        XCTAssertFalse(log.contains("asset missing (pkg+shared): models/absent_puppet.mdl"),
                       "부재 퍼펫은 quietAssetData 경유라 asset-missing 로그도 없어야")
        // === 과침묵 방지: 존재하나 파싱 불가한 퍼펫은 여전히 결함으로 로그(실진단 보존) ===
        XCTAssertTrue(log.contains("puppet mdl load failed (static quad fallback): models/garbage_puppet.mdl"),
                      "존재+파싱실패 퍼펫은 여전히 로그로 남아야")
    }

    // MARK: animationlayers 스크립트 per-frame 재적용(캐스케이드 소비자 배선) — 픽셀 red→green

    /// 스키닝 MDLV0013 합성: 1본(항등 바인드), 화면을 덮는 ±5000 쿼드(전정점 본0 가중 1),
    /// 클립 2개 — "clipA" 키 (0,0,0)=항등 / "clipB" 키 (+100000,0,0)=화면 밖 평행이동. 각 1키(시불변 포즈).
    private func twoClipPuppetMDL() -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))
        func u(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f(_ v: Float) { u(v.bitPattern) }
        d.append(Data("materials/m.json".utf8)); d.append(0)
        u(0)                                    // 미상 u32(0)
        let quad: [(Float, Float)] = [(-5000, -5000), (5000, -5000), (-5000, 5000), (5000, 5000)]
        u(UInt32(quad.count * 52))
        for (px, py) in quad {
            f(px); f(py); f(0)                  // pos
            u(0); u(0); u(0); u(0)              // boneIndices
            f(1); f(0); f(0); f(0)              // weights → 본0 전량
            f(0); f(0)                          // uv
        }
        u(6 * 2)
        for i: UInt16 in [0, 1, 2, 2, 1, 3] { var x = i.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("MDLS0001".utf8)); d.append(0)
        u(0); u(1)                              // nextOff(파서 미검증), 본수
        d.append(Data("root".utf8)); d.append(0)
        u(1); u(UInt32(bitPattern: -1)); u(64)  // flags, parent=-1, 행렬크기
        for v: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] { f(v) }
        d.append(0)                             // pad
        d.append(Data("MDLA0001".utf8)); d.append(0)
        u(0); u(2); u(0); u(0)                  // nextOff, 애니수, id, 0
        for (name, dx) in [("clipA", Float(0)), ("clipB", Float(100_000))] {
            d.append(Data(name.utf8)); d.append(0)
            d.append(Data("loop".utf8)); d.append(0)
            f(1); u(1); u(0); u(1); u(0)        // fps, length, 0, 트랙본수, 0
            u(36)                               // 1키(36B)
            f(dx); f(0); f(0); f(0); f(0); f(0); f(1); f(1); f(1)  // pos/angles/scale
            u(0)                                // blob2
        }
        return d
    }

    /// 스키닝 MDLV0013 합성(단일 클립): 1본(항등 바인드), ±5000 쿼드, 클립 "clipA" 1개(항등 포즈,
    /// 시불변) — attachment·animationlayers 캐스케이드 모두 미사용, C② 테스트 전용(단층 skinMatrices
    /// 경로가 항등 클립을 반환하므로 메시 화면상 위치는 오직 layer origin 애니에 의해서만 움직여야 한다).
    private func singleClipPuppetMDL() -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))
        func u(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f(_ v: Float) { u(v.bitPattern) }
        d.append(Data("materials/m.json".utf8)); d.append(0)
        u(0)                                    // 미상 u32(0)
        let quad: [(Float, Float)] = [(-5000, -5000), (5000, -5000), (-5000, 5000), (5000, 5000)]
        u(UInt32(quad.count * 52))
        for (px, py) in quad {
            f(px); f(py); f(0)                  // pos
            u(0); u(0); u(0); u(0)              // boneIndices
            f(1); f(0); f(0); f(0)              // weights → 본0 전량
            f(0); f(0)                          // uv
        }
        u(6 * 2)
        for i: UInt16 in [0, 1, 2, 2, 1, 3] { var x = i.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("MDLS0001".utf8)); d.append(0)
        u(0); u(1)                              // nextOff(파서 미검증), 본수
        d.append(Data("root".utf8)); d.append(0)
        u(1); u(UInt32(bitPattern: -1)); u(64)  // flags, parent=-1, 행렬크기
        for v: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] { f(v) }
        d.append(0)                             // pad
        d.append(Data("MDLA0001".utf8)); d.append(0)
        u(0); u(1); u(0); u(0)                  // nextOff, 애니수=1, id, 0
        d.append(Data("clipA".utf8)); d.append(0)
        d.append(Data("loop".utf8)); d.append(0)
        f(1); u(1); u(0); u(1); u(0)            // fps, length, 0, 트랙본수, 0
        u(36)                                   // 1키(36B)
        f(0); f(0); f(0); f(0); f(0); f(0); f(1); f(1); f(1)  // pos/angles/scale(항등)
        u(0)                                    // blob2
        return d
    }

    /// C②: attachment 없는 퍼펫 레이어가 origin 프로퍼티 키프레임 애니를 스킨 메시 배치에 반영해야 한다.
    /// 항등 클립(단층, animationlayers 미사용) 고정 — 유일한 변수는 layer origin 애니. 수정 전에는
    /// def 정적 origin(="32 18 0", 화면 중앙)만 써서 t=1.0(단일모드 클램프, origin.x=100032=화면 밖)
    /// 에도 메시가 여전히 화면을 덮어 밝다(red). 수정 후에는 애니가 반영돼 화면 밖 → 어둡다(green).
    func testPuppetOriginAnimationMovesSkinMesh() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":36},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/p.json","size":"64 36","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true,
           "origin":{"animation":{"c0":[{"frame":0,"value":32},{"frame":30,"value":100032}],
                                   "options":{"fps":30,"length":30,"mode":"single"}},
                     "value":"32 18 0"}}]}
        """
        let pkgData = encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/p.json", Data(#"{"material":"materials/m.json","puppet":"models/p.mdl"}"#.utf8)),
            ("materials/m.json", Data(#"{"passes":[{}]}"#.utf8)),   // 무텍스처 → solid 흰 퍼펫 메시
            ("models/p.mdl", singleClipPuppetMDL()),
        ])
        let (r, urls) = try mountAndCapture(pkgData, id: "originanim", times: [0.0, 1.0])
        let pm = try XCTUnwrap(r.layers.first?.puppet, "합성 퍼펫이 로드돼야(픽스처 새너티)")
        XCTAssertEqual(pm.animations.map(\.name), ["clipA"], "단일 클립 파스(픽스처 새너티)")
        XCTAssertEqual(urls.count, 2)
        let b0 = try brightness(urls[0]), b1 = try brightness(urls[1])
        XCTAssertGreaterThan(b0, 0.9, "t=0: origin=(32,18) 화면 중앙 → 메시가 화면을 덮어 밝아야")
        XCTAssertLessThan(b1, 0.05, "t=1.0(단일모드 클램프, origin.x=100032) → 메시가 화면 밖으로 이동해 어두워야 "
            + "(수정 전에는 def 정적 origin 을 써서 계속 밝음)")
    }

    private func mountAndCapture(_ pkg: Data, id: String, times: [Float]) throws -> (SceneRenderer, [URL]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_alscript_\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        addTeardownBlock { r.teardown() }
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: times, toDir: out)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (r, urls)
    }

    /// 화면 평균 밝기(0=흑, 1=백).
    private func brightness(_ url: URL) throws -> Double {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var sum = 0.0, n = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3; n += 1
            }
        }
        return n > 0 ? sum / n : -1
    }

    /// animationlayers visible 스크립트의 per-frame 재적용 → 캐스케이드 블렌드 소비자까지 관통(픽셀 검증).
    /// 정적 파스: L1 visible=false → 단일 클립 경로(clipA=항등) → 흰 퍼펫이 화면을 덮는다.
    /// 스크립트는 매 프레임 true → 재적용되면 2층 캐스케이드(clipB 절대 w=1 오버라이드, +100000px
    /// 평행이동) → 메시 화면 밖 → 흑화면. base 는 파스된 정적값만 소비해 흰 화면 유지(red).
    func testAnimationLayerVisibleScriptDrivesCascadePerFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":36},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/p.json","origin":"32 18 0","size":"64 36","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true,
           "animationlayers":[
             {"name":"clipA","additive":false,"blend":1.0,"rate":1.0,"visible":true},
             {"name":"clipB","additive":false,"blend":1.0,"rate":1.0,
              "visible":{"value":false,"script":"export function update(v) { return true; }"}}
           ]}]}
        """
        let pkgData = encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/p.json", Data(#"{"material":"materials/m.json","puppet":"models/p.mdl"}"#.utf8)),
            ("materials/m.json", Data(#"{"passes":[{}]}"#.utf8)),   // 무텍스처 → solid 퍼펫 메시
            ("models/p.mdl", twoClipPuppetMDL()),
        ])
        let (r, urls) = try mountAndCapture(pkgData, id: "cascade", times: [0.25, 0.75])
        // 픽스처 새너티: 퍼펫+2클립 로드(실패 시 정적 쿼드 폴백도 흰 화면이라 red 원인이 오염된다).
        let pm = try XCTUnwrap(r.layers.first?.puppet, "합성 퍼펫이 로드돼야(픽스처 새너티)")
        XCTAssertEqual(pm.animations.map(\.name), ["clipA", "clipB"], "클립 2개 파스(픽스처 새너티)")
        XCTAssertEqual(urls.count, 2)
        for u in urls {
            let b = try brightness(u)
            XCTAssertLessThan(b, 0.05, "visible 스크립트 재적용 → clipB 오버라이드로 메시 화면 밖(흑)이어야. "
                + "base: 정적 visible=false 단일 clipA(흰 화면) 유지 — \(u.lastPathComponent) brightness=\(b)")
        }
    }

    /// stderr 캡처(NSLog → stderr; GT 하네스도 동일 가정). XCTest 직렬 실행 전제, 출력 소량(무-deadlock).
    private func captureStderr<T>(_ body: () -> T) -> (T, String) {
        let pipe = Pipe()
        fflush(stderr)
        let saved = dup(2)
        dup2(pipe.fileHandleForWriting.fileDescriptor, 2)
        let result = body()
        fflush(stderr)
        dup2(saved, 2); close(saved)
        pipe.fileHandleForWriting.closeFile()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return (result, String(decoding: out, as: UTF8.self))
    }
}
