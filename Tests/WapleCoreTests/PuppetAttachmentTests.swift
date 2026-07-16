import XCTest
import simd
@testable import WapleCore

/// P1 attachment(이름 본-슬롯 부착): MDAT 파스 + 부착점 프레임 산출.
/// 실측 규약(코퍼스 28씬/47 mdl): "MDAT0001"|u8 0|u32 nextOff|u16 count|
/// count×(u16 본인덱스|cstring 이름|64B float4x4 로컬).
final class PuppetAttachmentTests: XCTestCase {
    // MARK: MDAT 바이너리 파스

    private func mdatBytes(entries: [(bone: UInt16, name: String, tx: Float, ty: Float)]) -> [UInt8] {
        var b: [UInt8] = Array("MDAT0001".utf8)
        b.append(0)                                   // lead u8
        b += withUnsafeBytes(of: UInt32(0).littleEndian, Array.init)   // nextOff(미사용)
        b += withUnsafeBytes(of: UInt16(entries.count).littleEndian, Array.init)
        for e in entries {
            b += withUnsafeBytes(of: e.bone.littleEndian, Array.init)
            b += Array(e.name.utf8) + [0]
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(e.tx, e.ty, 0, 1)
            for c in 0..<4 {
                for r in 0..<4 {
                    b += withUnsafeBytes(of: m[c][r].bitPattern.littleEndian, Array.init)
                }
            }
        }
        return b
    }

    func testParseMDATEntries() {
        let bytes = mdatBytes(entries: [(9, "头", 40.9, -104.2), (5, "手臂", 249.3, -13.3)])
        let atts = Model3D.parseAttachments(bytes: bytes, at: 0, boneCount: 12)
        XCTAssertEqual(atts.count, 2)
        XCTAssertEqual(atts[0].name, "头")
        XCTAssertEqual(atts[0].bone, 9)
        XCTAssertEqual(atts[0].local.columns.3.x, 40.9, accuracy: 1e-4)
        XCTAssertEqual(atts[1].name, "手臂")
        XCTAssertEqual(atts[1].bone, 5)
        XCTAssertEqual(atts[1].local.columns.3.y, -13.3, accuracy: 1e-4)
    }

    func testParseMDATRejectsBoneIndexOutOfRange() {
        // 본 인덱스가 스켈레톤 범위 밖 → 전체 무부착(추측 부착 금지·무크래시).
        let bytes = mdatBytes(entries: [(9, "头", 0, 0)])
        XCTAssertEqual(Model3D.parseAttachments(bytes: bytes, at: 0, boneCount: 3).count, 0)
    }

    func testParseMDATTruncatedReturnsEmpty() {
        var bytes = mdatBytes(entries: [(0, "a", 1, 2)])
        bytes.removeLast(40)   // 행렬 중간 절단
        XCTAssertEqual(Model3D.parseAttachments(bytes: bytes, at: 0, boneCount: 3).count, 0)
    }

    // MARK: 부착점 프레임(본 월드 추종)

    /// 본 2개(root→child(+10x)), child 본에 부착점(+5x 로컬). 애니: root 가 끝프레임 +100x.
    private func model() -> PuppetModel {
        var m = PuppetModel(material: "m", vertices: [], indices: [])
        m.bones = [
            .init(name: "", parent: -1, bind: matrix_identity_float4x4),
            .init(name: "", parent: 0,
                  bind: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(10, 0, 0, 1))),
        ]
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4(5, 0, 0, 1)
        m.attachments = [.init(name: "att", bone: 1, local: local)]
        let k0 = PuppetModel.Key(position: SIMD3(0, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))
        let k1 = PuppetModel.Key(position: SIMD3(100, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))
        m.animations = [.init(name: "a", mode: "loop", fps: 10, lengthFrames: 2,
                              tracks: [[k0, PuppetModel.Key(position: SIMD3(50, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1)), k1], []])]
        return m
    }

    func testAttachmentFrameAtBindEqualsBindWorldTimesLocal() {
        // t=0(트랙 첫 키 = 바인드): frame = bindWorld_1 × local = +10x ∘ +5x = +15x.
        let f = PuppetPose.attachmentFrame(model: model(), name: "att", layers: [], time: 0)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.columns.3.x, 15, accuracy: 1e-4)
        XCTAssertEqual(f!.columns.3.y, 0, accuracy: 1e-4)
    }

    func testAttachmentFrameFollowsBoneAnimation() {
        // t=0.1s = 프레임 1: root +50x 전파 → frame = +50 ∘ +10 ∘ +5 = +65x.
        let f = PuppetPose.attachmentFrame(model: model(), name: "att", layers: [], time: 0.1)
        XCTAssertEqual(f!.columns.3.x, 65, accuracy: 1e-3)
    }

    func testAttachmentFrameEmptyLayersMatchesClipZeroClock() {
        // 빈 layers 폴백(클립 0) ≡ 명시적 단일 절대 weight=1 캐스케이드 — 부모 퍼펫 단일 경로와 클록 일치.
        let m = model()
        let a = PuppetPose.attachmentFrame(model: m, name: "att", layers: [], time: 0.13)!
        let b = PuppetPose.attachmentFrame(model: m, name: "att",
                                           layers: [(anim: 0, additive: false, weight: 1, rate: 1)], time: 0.13)!
        XCTAssertEqual(a.columns.3.x, b.columns.3.x, accuracy: 1e-4)
    }

    func testAttachmentFrameUnknownNameNil() {
        // 부착점 이름 미존재 → nil(무부착 폴백 — 크래시·소실 금지).
        XCTAssertNil(PuppetPose.attachmentFrame(model: model(), name: "없는이름", layers: [], time: 0))
    }

    func testAttachmentFrameNoAnimationsUsesBindPose() {
        // 애니 없는 퍼펫: 바인드 월드 그대로(정적 부착 위치 보정만) — 크래시 없음.
        var m = model()
        m.animations = []
        let f = PuppetPose.attachmentFrame(model: m, name: "att", layers: [], time: 1.0)
        XCTAssertEqual(f!.columns.3.x, 15, accuracy: 1e-4)
    }

    // MARK: 실물 코퍼스(존재 시만 — PuppetBlendRealSceneTests 게이트 컨벤션)

    func testRealCorpusMDATAttachments() throws {
        // 3538758087 身体_puppet.mdl(MDLV0023): MDAT 실측 — 头→본9, 手臂→본5, 로컬 평행이동.
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let pkgPath = base + "/3538758087/scene.pkg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pkgPath), "실코퍼스 부재 — 스킵")
        let pkg = try ScenePackage.parse(Data(contentsOf: URL(fileURLWithPath: pkgPath)))
        let mdl = try XCTUnwrap(pkg.data(for: "models/身体_puppet.mdl"))
        let pm = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(pm.attachments.count, 2)
        let head = try XCTUnwrap(pm.attachments.first(where: { $0.name == "头" }))
        XCTAssertEqual(head.bone, 9)
        XCTAssertEqual(head.local.columns.3.x, 40.906, accuracy: 0.01)
        XCTAssertEqual(head.local.columns.3.y, -104.2, accuracy: 0.01)
        let arm = try XCTUnwrap(pm.attachments.first(where: { $0.name == "手臂" }))
        XCTAssertEqual(arm.bone, 5)
        // 부착점 프레임: 바인드에서도 유한값(본 월드 × 로컬), 이름 미존재는 nil.
        XCTAssertNotNil(PuppetPose.attachmentFrame(model: pm, name: "头", layers: [], time: 0))
        XCTAssertNil(PuppetPose.attachmentFrame(model: pm, name: "absent", layers: [], time: 0))
    }

    // MARK: scene.json 파스 캡처

    func testSceneLayerCapturesAttachmentName() throws {
        // 실물 스키마(3538758087): 오브젝트 최상위 "attachment": "<부착점 이름>" + 숫자 parent 병존.
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":2027,"image":"models/x.json","origin":"960 540 0","size":"100 100","visible":true},
           {"id":2225,"attachment":"头","parent":2027,"image":"models/x.json",
            "origin":"-69.8 23.3 0","size":"50 50","visible":true}]}
        """
        let model = #"{"width":100,"height":100,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(model.utf8)),
            ("materials/m.json", Data(material.utf8)),
        ]))
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertNil(doc.layers[0].attachment)
        XCTAssertEqual(doc.layers[1].attachment, "头")
        XCTAssertEqual(doc.layers[1].parent, 2027)   // 숫자 parent 병행 캡처(계층 무회귀)
    }
}
