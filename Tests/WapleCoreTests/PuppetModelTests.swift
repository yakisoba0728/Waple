import XCTest
@testable import WapleCore

final class PuppetModelTests: XCTestCase {
    /// 실측 MDLV0013 레이아웃대로 합성 바이트 구성(설계 문서 참조).
    private func makeMDL(material: String, verts: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>, SIMD2<Float>)],
                         indices: [UInt16],
                         bones: [(String, Int32, [Float])] = [("", -1, [0, 0])],
                         anim: SynthAnim? = nil) -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))  // 13B 헤더
        d.append(Data(material.utf8)); d.append(0)
        var zero = UInt32(0); withUnsafeBytes(of: &zero) { d.append(contentsOf: $0) }   // 용도 미상 u32(0)
        var vsize = UInt32(verts.count * 52); withUnsafeBytes(of: &vsize) { d.append(contentsOf: $0) }
        for (pos, bi, w, uv) in verts {
            var p = pos; withUnsafeBytes(of: &p) { d.append(contentsOf: $0.prefix(12)) }
            var b = bi; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
            var ww = w; withUnsafeBytes(of: &ww) { d.append(contentsOf: $0) }
            var u = uv; withUnsafeBytes(of: &u) { d.append(contentsOf: $0.prefix(8)) }
        }
        var isize = UInt32(indices.count * 2); withUnsafeBytes(of: &isize) { d.append(contentsOf: $0) }
        for i in indices { var v = i; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        // 스켈레톤(실측 확정 레이아웃): magic | u8 0 | u32 nextOff | u32 count |
        // per bone: cstring | u32 flags | i32 parent | u32 64 | 16f | u8 0
        d.append(Data("MDLS0001".utf8))
        d.append(0)
        let boneRecords: [(String, Int32, [Float])] = bones
        var body = Data()
        for (name, parent, tx) in boneRecords {
            body.append(Data(name.utf8)); body.append(0)
            var f = UInt32(1); withUnsafeBytes(of: &f) { body.append(contentsOf: $0) }
            var pr = parent; withUnsafeBytes(of: &pr) { body.append(contentsOf: $0) }
            var msz = UInt32(64); withUnsafeBytes(of: &msz) { body.append(contentsOf: $0) }
            var mat: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, tx[0],tx[1],0,1]
            mat.withUnsafeBytes { body.append(contentsOf: $0) }
            body.append(0)
        }
        var nextOff = UInt32(d.count + 4 + 4 + body.count + 8)  // 대략적 MDLA 위치(파서는 count 기반이라 무관)
        d.append(0)  // wait — 위에서 이미 magic 뒤 0 추가함
        d.removeLast()
        withUnsafeBytes(of: &nextOff) { d.append(contentsOf: $0) }
        var bc = UInt32(boneRecords.count); withUnsafeBytes(of: &bc) { d.append(contentsOf: $0) }
        d.append(body)
        d.append(Data("MDLA0001".utf8))
        // 애니(실측): u8 0 | u32 nextOff | u32 count | u32 id | u32 0 |
        // cstring 이름 | cstring 모드 | f32 fps | u32 길이 | u32 0 | u32 본수 | u32 0 |
        // 본별: u32 트랙크기 | 키×36B(pos3f rot3f scale3f) | u32 블롭2크기(0)
        if let anim = anim {
            var a = Data([0])
            func u(_ v: UInt32) { var x = v; withUnsafeBytes(of: &x) { a.append(contentsOf: $0) } }
            func f(_ v: Float) { var x = v; withUnsafeBytes(of: &x) { a.append(contentsOf: $0) } }
            u(0); u(1); u(355); u(0)
            a.append(Data(anim.name.utf8)); a.append(0)
            a.append(Data(anim.mode.utf8)); a.append(0)
            f(anim.fps); u(UInt32(anim.length)); u(0); u(UInt32(anim.tracks.count)); u(0)
            for keys in anim.tracks {
                u(UInt32(keys.count * 36))
                for k in keys { for v in k { f(v) } }
                u(0)
            }
            d.append(a)
        }
        return d
    }

    struct SynthAnim {
        let name: String; let mode: String; let fps: Float; let length: Int
        let tracks: [[[Float]]]  // 본별 키 배열, 키 = 9f
    }

    func testParsesSyntheticMesh() throws {
        let mdl = makeMDL(material: "materials/body.json",
                          verts: [
                            (SIMD3(-1, -1, 0), SIMD4(8, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 1)),
                            (SIMD3(1, -1, 0), SIMD4(8, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(1, 1)),
                            (SIMD3(0, 1, 0), SIMD4(2, 3, 0, 0), SIMD4(0.5, 0.5, 0, 0), SIMD2(0.5, 0)),
                          ],
                          indices: [0, 1, 2])
        let m = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(m.material, "materials/body.json")
        XCTAssertEqual(m.vertices.count, 3)
        XCTAssertEqual(m.indices, [0, 1, 2])
        XCTAssertEqual(m.vertices[0].position, SIMD3(-1, -1, 0))
        XCTAssertEqual(m.vertices[2].boneIndices, SIMD4<UInt32>(2, 3, 0, 0))
        XCTAssertEqual(m.vertices[2].weights, SIMD4<Float>(0.5, 0.5, 0, 0))
        XCTAssertEqual(m.vertices[2].uv, SIMD2<Float>(0.5, 0))
    }

    func testParsesSkeleton() throws {
        let mdl = makeMDL(material: "materials/b.json",
                          verts: [(SIMD3(0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 0))],
                          indices: [0, 0, 0],
                          bones: [("root", -1, [10, 20]), ("arm", 0, [-5, 3])])
        let m = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(m.bones.count, 2)
        XCTAssertEqual(m.bones[0].name, "root")
        XCTAssertEqual(m.bones[0].parent, -1)
        XCTAssertEqual(m.bones[0].bind.columns.3.x, 10)
        XCTAssertEqual(m.bones[0].bind.columns.3.y, 20)
        XCTAssertEqual(m.bones[1].parent, 0)
        XCTAssertEqual(m.bones[1].name, "arm")
    }

    func testParsesAnimation() throws {
        let key0: [Float] = [10, 20, 0, 0, 0, 0, 1, 1, 1]
        let key1: [Float] = [15, 25, 0, 0, 0, 0.5, 1, 1, 1]
        let mdl = makeMDL(material: "materials/b.json",
                          verts: [(SIMD3(0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 0))],
                          indices: [0, 0, 0],
                          bones: [("", -1, [10, 20])],
                          anim: SynthAnim(name: "arm", mode: "mirror", fps: 20, length: 1, tracks: [[key0, key1]]))
        let m = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(m.animations.count, 1)
        let a = m.animations[0]
        XCTAssertEqual(a.name, "arm")
        XCTAssertEqual(a.mode, "mirror")
        XCTAssertGreaterThan(a.fps, 0)
        XCTAssertEqual(a.lengthFrames, 1)
        XCTAssertEqual(a.tracks.count, 1)
        XCTAssertEqual(a.tracks[0].count, 2)
        XCTAssertEqual(a.tracks[0][0].position, SIMD3<Float>(10, 20, 0))
        XCTAssertEqual(a.tracks[0][1].angles.z, 0.5)
        XCTAssertEqual(a.tracks[0][1].scale, SIMD3<Float>(1, 1, 1))
    }

    func testRejectsGarbage() {
        XCTAssertNil(PuppetModel.parse(Data("NOPE".utf8)))
        XCTAssertNil(PuppetModel.parse(Data("MDLV0013".utf8)))  // 트렁케이트
    }

    /// 실물 머티리얼/본 경로는 UTF-8 CJK("materials/太空球/…")를 포함 — 종전 바이트누적
    /// Latin-1 디코드는 mojibake 를 만들어 pkg 조회가 실패했다(감사 §1 medium). UTF-8 라운드트립 검증.
    func testDecodesCJKStringsAsUTF8() throws {
        let mat = "materials/太空球/body.json"
        let mdl = makeMDL(material: mat,
                          verts: [(SIMD3(0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 0))],
                          indices: [0, 0, 0],
                          bones: [("骨_root", -1, [0, 0])])
        let m = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(m.material, mat)            // spot 1: 머티리얼 cstring
        XCTAssertEqual(m.bones.first?.name, "骨_root")  // spot 2: 본 이름 cstring
    }

    /// MDLV0023(3D 스키닝 모델로 저장된 2D 퍼펫 — Hollow Knight) → PuppetModel 로 라우팅·변환.
    /// pos/boneIdx/wt/uv 만 이식하고 정적 바인드 포즈로 렌더 가능해야(애니 미해독).
    func testRoutesMDLV0023SkinnedToPuppet() {
        func f(_ v: Float, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u(_ v: UInt32, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        var d = Data("MDLV0023".utf8); d.append(0)
        u(0x0000000f, &d); u(1, &d); u(1, &d)                 // formatFlag, const 1, meshCount 1
        d.append(Data("materials/knight.json".utf8)); d.append(0)
        u(0, &d)
        for _ in 0..<6 { f(0, &d) }                            // AABB min/max
        u(0x0180000f, &d)                                     // 스키닝 메시(stride 80)
        let verts: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>, SIMD2<Float>)] = [
            (SIMD3(-10, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 1)),
            (SIMD3(10, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(1, 1)),
            (SIMD3(0, 20, 0), SIMD4(0, 0, 0, 0), SIMD4(0.5, 0.5, 0, 0), SIMD2(0.5, 0)),
        ]
        u(UInt32(verts.count * 80), &d)
        for (pos, bi, w, uv) in verts {
            f(pos.x, &d); f(pos.y, &d); f(pos.z, &d)
            f(0, &d); f(0, &d); f(1, &d)                      // normal
            f(1, &d); f(0, &d); f(0, &d); f(1, &d)            // tangent
            u(bi.x, &d); u(bi.y, &d); u(bi.z, &d); u(bi.w, &d)
            f(w.x, &d); f(w.y, &d); f(w.z, &d); f(w.w, &d)
            f(uv.x, &d); f(uv.y, &d)
        }
        let indices: [UInt16] = [0, 1, 2]
        u(UInt32(indices.count * 2), &d)
        for i in indices { var v = i; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }

        let pm = PuppetModel.parse(d)
        XCTAssertNotNil(pm)
        XCTAssertEqual(pm?.material, "materials/knight.json")
        XCTAssertEqual(pm?.vertices.count, 3)
        XCTAssertEqual(pm?.indices, [0, 1, 2])
        XCTAssertEqual(pm?.vertices[0].position, SIMD3(-10, 0, 0))   // 좌표계 이식(레이어-로컬 픽셀)
        XCTAssertEqual(pm?.vertices[1].boneIndices, SIMD4<UInt32>(1, 0, 0, 0))
        XCTAssertEqual(pm?.vertices[2].uv, SIMD2<Float>(0.5, 0))
        XCTAssertTrue(pm?.animations.isEmpty ?? false)              // 정적 바인드 포즈
    }

    /// MDLV0023 퍼펫은 Model3D 가 이미 MDLA0006 애니를 파싱하므로, PuppetModel 변환도 트랙을 보존해야 한다.
    func testRoutesMDLV0023AnimationsToPuppet() throws {
        func f(_ v: Float, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u(_ v: UInt32, _ d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func appendKey(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ s: SIMD3<Float>, to d: inout Data) {
            f(p.x, &d); f(p.y, &d); f(p.z, &d)
            f(a.x, &d); f(a.y, &d); f(a.z, &d)
            f(s.x, &d); f(s.y, &d); f(s.z, &d)
        }

        var d = Data("MDLV0023".utf8); d.append(0)
        u(0x0180000f, &d); u(1, &d); u(1, &d)
        d.append(Data("materials/knight.json".utf8)); d.append(0)
        u(0, &d)
        for _ in 0..<6 { f(0, &d) }
        u(0x0180000f, &d)
        u(UInt32(3 * 80), &d)
        for i in 0..<3 {
            f(Float(i), &d); f(0, &d); f(0, &d)
            f(0, &d); f(0, &d); f(1, &d)
            f(1, &d); f(0, &d); f(0, &d); f(1, &d)
            u(UInt32(min(i, 1)), &d); u(0, &d); u(0, &d); u(0, &d)
            f(1, &d); f(0, &d); f(0, &d); f(0, &d)
            f(Float(i) / 2, &d); f(0, &d)
        }
        u(6, &d)
        for i: UInt16 in [0, 1, 2] { var v = i; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }

        d.append(Data("MDLS0004".utf8)); d.append(0)
        u(0, &d); u(2, &d)
        func appendBone(_ name: String, _ parent: Int32, _ tx: Float) {
            d.append(Data(name.utf8)); d.append(0)
            u(1, &d)
            var pr = parent; withUnsafeBytes(of: &pr) { d.append(contentsOf: $0) }
            u(64, &d)
            let mat: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, tx,0,0,1]
            for x in mat { f(x, &d) }
            d.append(0)
        }
        appendBone("Root", -1, 0)
        appendBone("Arm", 0, 3)

        d.append(Data("MDLA0006".utf8)); d.append(0)
        u(0, &d); u(1, &d); u(100, &d); u(0, &d)
        d.append(Data("knight|idle_bone".utf8)); d.append(0)
        d.append(Data("loop".utf8)); d.append(0)
        f(24, &d); u(1, &d); u(0, &d); u(2, &d); u(0, &d)
        u(72, &d)
        appendKey(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1), to: &d)
        appendKey(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1), to: &d)
        u(0, &d)
        u(72, &d)
        appendKey(SIMD3(3, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1), to: &d)
        appendKey(SIMD3(3, 0, 0), SIMD3(0, 0, 0.75), SIMD3(1, 1, 1), to: &d)
        u(0, &d)

        let pm = try XCTUnwrap(PuppetModel.parse(d))
        XCTAssertEqual(pm.bones.count, 2)
        XCTAssertEqual(pm.animations.count, 1)
        XCTAssertEqual(pm.animations[0].name, "knight|idle_bone")
        XCTAssertEqual(pm.animations[0].mode, "loop")
        XCTAssertEqual(pm.animations[0].fps, 24)
        XCTAssertEqual(pm.animations[0].tracks.count, 2)
        XCTAssertEqual(pm.animations[0].tracks[1][1].angles.z, 0.75, accuracy: 1e-6)
    }
}

/// 실물 스모크(env-guarded): 2809885105 의 퍼펫 2개가 파스되고 실측 수치와 일치.
final class PuppetRealFileTests: XCTestCase {
    func testParsesRealPuppets() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"] ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let pkgURL = URL(fileURLWithPath: base).appendingPathComponent("2809885105/scene.pkg")
        guard let data = try? Data(contentsOf: pkgURL) else { throw XCTSkip("no real pkg") }
        let pkg = try ScenePackage.parse(data)
        let mdls = pkg.entries.filter { $0.name.hasSuffix("_puppet.mdl") }
        XCTAssertEqual(mdls.count, 2)
        var counts: [Int] = []
        for e in mdls {
            let m = try XCTUnwrap(PuppetModel.parse(try XCTUnwrap(pkg.data(for: e.name))), "parse fail: \(e.name)")
            XCTAssertTrue(m.material.hasPrefix("materials/"), m.material)
            XCTAssertGreaterThan(m.vertices.count, 100)
            XCTAssertGreaterThan(m.indices.count, 300)
            XCTAssertEqual(m.indices.count % 3, 0, "트라이앵글 리스트")
            let maxIdx = Int(m.indices.max() ?? 0)
            XCTAssertLessThan(maxIdx, m.vertices.count, "인덱스 범위")
            counts.append(m.vertices.count)
            XCTAssertEqual(m.bones.count, 10, "실측 10본: \(e.name)")
            XCTAssertEqual(m.bones[0].parent, -1, "루트")
            for (i, b) in m.bones.enumerated() where i > 0 {
                XCTAssertTrue(b.parent >= -1 && Int(b.parent) < i, "본 트리 유효성")
            }
        }
        XCTAssertTrue(counts.contains(1406), "실측 1406 정점 모델 포함: \(counts)")
    }

    func testRealAnimationTracks() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"] ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let pkgURL = URL(fileURLWithPath: base).appendingPathComponent("2809885105/scene.pkg")
        guard let data = try? Data(contentsOf: pkgURL) else { throw XCTSkip("no real pkg") }
        let pkg = try ScenePackage.parse(data)
        for e in pkg.entries where e.name.hasSuffix("_puppet.mdl") {
            let m = try XCTUnwrap(PuppetModel.parse(try XCTUnwrap(pkg.data(for: e.name))))
            XCTAssertEqual(m.animations.count, 1, e.name)
            let a = m.animations[0]
            XCTAssertGreaterThan(a.fps, 0)
            XCTAssertEqual(a.tracks.count, m.bones.count, "본당 트랙 1개")
            for (i, t) in a.tracks.enumerated() where !t.isEmpty {
                XCTAssertEqual(t.count, a.lengthFrames + 1, "프레임당 1키(0..길이 포함)")
                // 첫 키 위치는 바인드 평행이동과 정합(실측 특성)
                let bind = m.bones[i].bind.columns.3
                XCTAssertEqual(t[0].position.x, bind.x, accuracy: 500, "본\(i) 키 위치 자릿수 sanity")
            }
        }
    }
}
