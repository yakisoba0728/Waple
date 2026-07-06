import XCTest
import simd
@testable import WapleCore

final class Model3DTests: XCTestCase {
    // MARK: synthetic byte builders (실측 MDLV0023 레이아웃)

    private func f(_ v: Float, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u(_ v: UInt32, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

    private struct SynthVert {
        var pos: SIMD3<Float>; var nrm: SIMD3<Float>; var tan: SIMD4<Float>; var uv: SIMD2<Float>
        var bones: SIMD4<UInt32> = .zero; var weights: SIMD4<Float> = .zero
    }
    private struct SynthMesh {
        var material: String; var min: SIMD3<Float>; var max: SIMD3<Float>
        var skinned: Bool; var verts: [SynthVert]; var indices: [UInt16]
    }

    private func encodeVertex(_ v: SynthVert, skinned: Bool, into d: inout Data) {
        f(v.pos.x, into: &d); f(v.pos.y, into: &d); f(v.pos.z, into: &d)
        f(v.nrm.x, into: &d); f(v.nrm.y, into: &d); f(v.nrm.z, into: &d)
        f(v.tan.x, into: &d); f(v.tan.y, into: &d); f(v.tan.z, into: &d); f(v.tan.w, into: &d)
        if skinned {
            u(v.bones.x, into: &d); u(v.bones.y, into: &d); u(v.bones.z, into: &d); u(v.bones.w, into: &d)
            f(v.weights.x, into: &d); f(v.weights.y, into: &d); f(v.weights.z, into: &d); f(v.weights.w, into: &d)
        }
        f(v.uv.x, into: &d); f(v.uv.y, into: &d)
    }

    private func makeModelU16(_ meshes: [SynthMesh]) -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0); u(0x0000000f, into: &d); u(1, into: &d); u(UInt32(meshes.count), into: &d)
        for (mi, m) in meshes.enumerated() {
            d.append(Data(m.material.utf8)); d.append(0)
            u(0, into: &d)
            f(m.min.x, into: &d); f(m.min.y, into: &d); f(m.min.z, into: &d)
            f(m.max.x, into: &d); f(m.max.y, into: &d); f(m.max.z, into: &d)
            u(m.skinned ? 0x0180000f : 0x0000000f, into: &d)
            let stride = m.skinned ? 80 : 48
            u(UInt32(m.verts.count * stride), into: &d)
            for v in m.verts { encodeVertex(v, skinned: m.skinned, into: &d) }
            u(UInt32(m.indices.count * 2), into: &d)
            for i in m.indices { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
            if mi < meshes.count - 1 { d.append(Data(repeating: 0, count: 6)) }
        }
        return d
    }

    // MARK: tests

    func testParsesStaticSingleMesh() throws {
        let verts = [
            SynthVert(pos: SIMD3(-1, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(0, 1)),
            SynthVert(pos: SIMD3(1, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(1, 1)),
            SynthVert(pos: SIMD3(0, 2, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(0.5, 0)),
        ]
        let mesh = SynthMesh(material: "materials/models/lock/Mod.json",
                             min: SIMD3(-1, 0, 0), max: SIMD3(1, 2, 0), skinned: false,
                             verts: verts, indices: [0, 1, 2])
        let m = try XCTUnwrap(Model3D.parse(makeModelU16([mesh])))
        XCTAssertEqual(m.meshes.count, 1)
        let mm = m.meshes[0]
        XCTAssertEqual(mm.material, "materials/models/lock/Mod.json")
        XCTAssertFalse(mm.skinned)
        XCTAssertEqual(mm.vertices.count, 3)
        XCTAssertEqual(mm.indices, [0, 1, 2])
        XCTAssertEqual(mm.vertices[0].position, SIMD3(-1, 0, 0))
        XCTAssertEqual(mm.vertices[0].normal, SIMD3(0, 0, 1))
        XCTAssertEqual(mm.vertices[0].tangent, SIMD4(1, 0, 0, -1))
        XCTAssertEqual(mm.vertices[2].uv, SIMD2(0.5, 0))
        XCTAssertEqual(mm.vertices[0].boneIndices, SIMD4<UInt32>(0, 0, 0, 0))  // 정적: 스키닝 없음
        XCTAssertEqual(mm.boundsMin, SIMD3(-1, 0, 0))
        XCTAssertEqual(mm.boundsMax, SIMD3(1, 2, 0))
        XCTAssertTrue(m.bones.isEmpty)
    }

    func testRejectsMeshWithVertexIndexOutOfRange() {
        let verts = [
            SynthVert(pos: SIMD3(-1, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(0, 1)),
            SynthVert(pos: SIMD3(1, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(1, 1)),
            SynthVert(pos: SIMD3(0, 2, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, -1), uv: SIMD2(0.5, 0)),
        ]
        let mesh = SynthMesh(material: "materials/models/lock/Mod.json",
                             min: SIMD3(-1, 0, 0), max: SIMD3(1, 2, 0), skinned: false,
                             verts: verts, indices: [0, 1, 3])

        XCTAssertNil(Model3D.parse(makeModelU16([mesh])))
    }

    /// 머티리얼 경로 cstring 은 UTF-8 — 실물 태양계 모델이 CJK 경로("太空球")를 쓴다(Latin-1 해석 시
    /// mojibake 로 pkg 엔트리 조회 실패 → 흰 텍스처 사고).
    func testUTF8MaterialPath() throws {
        let vert = SynthVert(pos: SIMD3(0, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, 1), uv: SIMD2(0, 0))
        let mesh = SynthMesh(material: "materials/models/太空球/DefaultMaterial.json",
                             min: .zero, max: .zero, skinned: false,
                             verts: [vert, vert, vert], indices: [0, 1, 2])
        let m = try XCTUnwrap(Model3D.parse(makeModelU16([mesh])))
        XCTAssertEqual(m.meshes[0].material, "materials/models/太空球/DefaultMaterial.json")
    }

    /// 변종 스트라이드(실물 3577990983 sl_puppet.mdl = 84 = 80+미상4B, 플래그 0x181000e):
    /// 표 스트라이드로 안 나눠지면 인덱스 maxIndex+1 로 자기기술 추론, 필드는 꼬리 고정
    /// (bones@-40, weights@-24, uv@-8). 미상 4B 는 tangent 뒤에 위치(실측 중간 영역).
    func testParsesVariantStride84() throws {
        var d = Data("MDLV0023".utf8)
        d.append(0); u(0x0181000e, into: &d); u(1, into: &d); u(1, into: &d)
        d.append(Data("materials/sl.json".utf8)); d.append(0)
        u(0x100c, into: &d)                       // 실물: 0 이 아닌 미상값 — 관용 스킵 확인
        for _ in 0..<6 { f(0, into: &d) }         // AABB 전부 0(실물 그대로)
        u(0x0181000e, into: &d)                   // per-mesh flags
        let verts: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>, SIMD2<Float>)] = [
            (SIMD3(172.5, 488.0, 0), SIMD4(52, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0.531, 0.110)),
            (SIMD3(178.9, 480.7, 0), SIMD4(52, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0.533, 0.113)),
            (SIMD3(175.5, 486.0, 0), SIMD4(7, 3, 0, 0), SIMD4(0.6, 0.4, 0, 0), SIMD2(0.532, 0.111)),
        ]
        u(UInt32(verts.count * 84), into: &d)     // vSize = 84 스트라이드 (80 표값으로 나눠지지 않음)
        for v in verts {
            f(v.0.x, into: &d); f(v.0.y, into: &d); f(v.0.z, into: &d)   // pos
            f(0, into: &d); f(0, into: &d); f(0, into: &d)               // normal(실물 0)
            f(1, into: &d); f(1, into: &d); f(0, into: &d); f(0, into: &d) // tangent
            f(1, into: &d)                                                // 미상 +4B
            u(v.1.x, into: &d); u(v.1.y, into: &d); u(v.1.z, into: &d); u(v.1.w, into: &d)  // bones @-40
            f(v.2.x, into: &d); f(v.2.y, into: &d); f(v.2.z, into: &d); f(v.2.w, into: &d)  // weights @-24
            f(v.3.x, into: &d); f(v.3.y, into: &d)                                          // uv @-8
        }
        u(6, into: &d)                            // iSize = 3 인덱스 × 2B
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        let m = try XCTUnwrap(Model3D.parse(d), "변종 84 스트라이드 파스 실패")
        XCTAssertEqual(m.meshes.count, 1)
        let mm = m.meshes[0]
        XCTAssertTrue(mm.skinned)
        XCTAssertEqual(mm.vertices.count, 3)
        XCTAssertEqual(mm.vertices[0].position.x, 172.5, accuracy: 1e-4)
        XCTAssertEqual(mm.vertices[0].boneIndices, SIMD4<UInt32>(52, 0, 0, 0))
        XCTAssertEqual(mm.vertices[2].weights.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(mm.vertices[0].uv.x, 0.531, accuracy: 1e-5)
        XCTAssertEqual(mm.indices, [0, 1, 2])
    }

    func testParsesSkinnedVertexFields() throws {
        let verts = [
            SynthVert(pos: SIMD3(5, 6, 7), nrm: SIMD3(0, 1, 0), tan: SIMD4(1, 0, 0, 1), uv: SIMD2(0.25, 0.75),
                      bones: SIMD4(3, 4, 0, 0), weights: SIMD4(0.7, 0.3, 0, 0)),
        ]
        let mesh = SynthMesh(material: "materials/models/mario/body.json",
                             min: SIMD3(5, 6, 7), max: SIMD3(5, 6, 7), skinned: true,
                             verts: verts, indices: [0, 0, 0])
        let m = try XCTUnwrap(Model3D.parse(makeModelU16([mesh])))
        let v = m.meshes[0].vertices[0]
        XCTAssertTrue(m.meshes[0].skinned)
        XCTAssertEqual(v.position, SIMD3(5, 6, 7))
        XCTAssertEqual(v.boneIndices, SIMD4<UInt32>(3, 4, 0, 0))
        XCTAssertEqual(v.weights, SIMD4<Float>(0.7, 0.3, 0, 0))
        XCTAssertEqual(v.uv, SIMD2<Float>(0.25, 0.75))
        XCTAssertEqual(v.weights.x + v.weights.y + v.weights.z + v.weights.w, 1.0, accuracy: 1e-6)
    }

    func testParsesMultiMeshAndSkeleton() throws {
        let vStatic = SynthVert(pos: SIMD3(0, 0, 0), nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, 1), uv: SIMD2(0, 0))
        let vSkin = SynthVert(pos: SIMD3(1, 1, 1), nrm: SIMD3(0, 1, 0), tan: SIMD4(0, 0, 1, -1), uv: SIMD2(1, 1),
                              bones: SIMD4(1, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
        let m0 = SynthMesh(material: "materials/a.json", min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 1),
                           skinned: false, verts: [vStatic, vStatic, vStatic], indices: [0, 1, 2])
        let m1 = SynthMesh(material: "materials/b.json", min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 1),
                           skinned: true, verts: [vSkin, vSkin, vSkin], indices: [0, 1, 2])
        // 멀티메시 + 스켈레톤(MDLS0004) + 애니 마커(MDLA0006) 를 실측 레이아웃대로 부착.
        var d = makeModelU16([m0, m1])
        // 스켈레톤 부착(MDLS0004): magic|0|u32 nextOff|u32 본수| per bone: name|flags|parent|64|16f|props
        d.append(Data("MDLS0004".utf8)); d.append(0)
        u(0, into: &d); u(2, into: &d)
        func appendBone(_ name: String, _ parent: Int32, _ tx: Float, _ props: String) {
            d.append(Data(name.utf8)); d.append(0)
            u(1, into: &d)
            var pr = parent; withUnsafeBytes(of: &pr) { d.append(contentsOf: $0) }
            u(64, into: &d)
            let mat: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, tx,0,0,1]
            for x in mat { f(x, into: &d) }
            d.append(Data(props.utf8)); d.append(0)
        }
        appendBone("RootNode", -1, 0, "")
        appendBone("Center", 0, 3, "{\"ik\":true}")
        d.append(Data("MDAT0001".utf8)); d.append(0)
        d.append(Data("MDLA0006".utf8)); d.append(0)

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.meshes.count, 2)
        XCTAssertFalse(m.meshes[0].skinned)
        XCTAssertTrue(m.meshes[1].skinned)
        XCTAssertEqual(m.meshes[1].vertices[0].boneIndices, SIMD4<UInt32>(1, 0, 0, 0))
        XCTAssertEqual(m.bones.count, 2)
        XCTAssertEqual(m.bones[0].name, "RootNode")
        XCTAssertEqual(m.bones[0].parent, -1)
        XCTAssertEqual(m.bones[1].name, "Center")
        XCTAssertEqual(m.bones[1].parent, 0)
        XCTAssertEqual(m.bones[1].properties, "{\"ik\":true}")
        XCTAssertEqual(m.bones[1].bind.columns.3.x, 3)
        XCTAssertTrue(m.hasAnimation)
        // 스킨 인덱스 ↔ 스켈레톤 교차검증
        for v in m.meshes[1].vertices {
            XCTAssertLessThan(Int(v.boneIndices.max()), m.bones.count)
        }
    }

    /// MDLA0006 애니 파스: 헤더 + 2 애니(리싱크 트레일러 경유) + 본별 키 트랙. 실측 레이아웃.
    func testParsesMDLA0006Animations() throws {
        let vSkin = SynthVert(pos: SIMD3(1, 1, 1), nrm: SIMD3(0, 1, 0), tan: SIMD4(0, 0, 1, -1), uv: SIMD2(1, 1),
                              bones: SIMD4(1, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
        let m0 = SynthMesh(material: "materials/a.json", min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 1),
                           skinned: true, verts: [vSkin, vSkin, vSkin], indices: [0, 1, 2])
        var d = makeModelU16([m0])
        // 스켈레톤(MDLS0004): 2 본
        d.append(Data("MDLS0004".utf8)); d.append(0)
        u(0, into: &d); u(2, into: &d)
        func appendBone(_ name: String, _ parent: Int32, _ tx: Float) {
            d.append(Data(name.utf8)); d.append(0)
            u(1, into: &d)
            var pr = parent; withUnsafeBytes(of: &pr) { d.append(contentsOf: $0) }
            u(64, into: &d)
            let mat: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, 0, 0, 1]
            for x in mat { f(x, into: &d) }
            d.append(0)  // props(빈)
        }
        appendBone("RootNode", -1, 0)
        appendBone("Center", 0, 3)
        // 애니(MDLA0006): 헤더 + anim0(리싱크 트레일러) + anim1
        d.append(Data("MDLA0006".utf8)); d.append(0)
        u(0, into: &d); u(9, into: &d); u(100, into: &d); u(0, into: &d)  // nextOff, animCount(불신값 9), baseId, 0
        func appendKey(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ s: SIMD3<Float>) {
            f(p.x, into: &d); f(p.y, into: &d); f(p.z, into: &d)
            f(a.x, into: &d); f(a.y, into: &d); f(a.z, into: &d)
            f(s.x, into: &d); f(s.y, into: &d); f(s.z, into: &d)
        }
        func appendAnim(_ name: String, _ mode: String, _ fps: Float, _ length: Int, tracks: [[(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]]) {
            d.append(Data(name.utf8)); d.append(0)
            d.append(Data(mode.utf8)); d.append(0)
            f(fps, into: &d); u(UInt32(length), into: &d); u(0, into: &d); u(UInt32(tracks.count), into: &d); u(0, into: &d)
            for keys in tracks {
                u(UInt32(keys.count * 36), into: &d)
                for k in keys { appendKey(k.0, k.1, k.2) }
                u(0, into: &d)  // blob2
            }
        }
        // anim0: idle, 2 키(length 1), 본0 정지 / 본1 z회전
        appendAnim("test|idle_bone", "loop", 30, 1, tracks: [
            [(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)), (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))],
            [(SIMD3(3, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)), (SIMD3(3, 0, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 1))],
        ])
        // 트레일러(가변 32B): u16 0 | AABB 6f | u32 0 | u16 0
        var z16: UInt16 = 0; withUnsafeBytes(of: &z16) { d.append(contentsOf: $0) }
        for _ in 0..<6 { f(0, into: &d) }
        u(0, into: &d); withUnsafeBytes(of: &z16) { d.append(contentsOf: $0) }
        // anim1: glance, 1 키(length 0)
        appendAnim("test|glance_bone", "single", 24, 0, tracks: [
            [(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))],
            [(SIMD3(3, 0, 0), SIMD3(0, 0, 0), SIMD3(2, 2, 2))],
        ])

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertTrue(m.hasAnimation)
        XCTAssertEqual(m.animations.count, 2, "리싱크로 트레일러 넘어 2 애니 파스")
        let a0 = m.animations[0]
        XCTAssertEqual(a0.name, "test|idle_bone")
        XCTAssertEqual(a0.mode, "loop")
        XCTAssertEqual(a0.fps, 30)
        XCTAssertEqual(a0.lengthFrames, 1)
        XCTAssertEqual(a0.tracks.count, 2)
        XCTAssertEqual(a0.tracks[0].count, 2)
        XCTAssertEqual(a0.tracks[1][1].angles.z, 1, accuracy: 1e-6)
        XCTAssertEqual(m.animations[1].name, "test|glance_bone")
        XCTAssertEqual(m.animations[1].mode, "single")
        XCTAssertEqual(m.animations[1].tracks[1][0].scale, SIMD3(2, 2, 2))
        // 애니 선택 & 스킨 행렬
        XCTAssertEqual(Model3DPose.resolveAnimation(model: m, layerName: "Idle"), 0)
        XCTAssertEqual(Model3DPose.resolveAnimation(model: m, layerName: "Glance"), 1)
        let mats = Model3DPose.skinMatrices(model: m, animation: 0, time: 0)
        XCTAssertEqual(mats.count, 2)
    }

    func testRejectsWrongMagic() {
        XCTAssertNil(Model3D.parse(Data("MDLV0013".utf8)))  // 2D 퍼펫은 거부
        XCTAssertNil(Model3D.parse(Data("NOPE".utf8)))
        XCTAssertNil(Model3D.parse(Data("MDLV0023".utf8)))  // 트렁케이트
    }
}

/// 실물 스모크(env-guarded): OoT/Sonic/태양계 pkg 의 .mdl 전수 파스.
final class Model3DRealFileTests: XCTestCase {
    private func realBase() -> String {
        ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
    }

    private func loadPkg(_ id: String) throws -> ScenePackage {
        let url = URL(fileURLWithPath: realBase()).appendingPathComponent("\(id)/scene.pkg")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no real pkg \(id)") }
        return try ScenePackage.parse(data)
    }

    func testParsesAllOoTModels() throws {
        let pkg = try loadPkg("3737268876")
        let mdls = pkg.entries.filter { $0.name.hasSuffix(".mdl") }
        XCTAssertEqual(mdls.count, 100, "OoT pkg 는 .mdl 100개")
        var ok = 0, skinned = 0, totalMeshes = 0, animModels = 0
        var failures: [String] = []
        for e in mdls {
            guard let raw = pkg.data(for: e.name), let m = Model3D.parse(raw) else {
                failures.append(e.name); continue
            }
            ok += 1
            totalMeshes += m.meshes.count
            if m.meshes.contains(where: { $0.skinned }) { skinned += 1 }
            // 무결성: 트라이앵글 리스트 + 인덱스 범위 + 머티리얼 규약
            for mesh in m.meshes {
                XCTAssertEqual(mesh.indices.count % 3, 0, "\(e.name): 트라이앵글 리스트")
                if let mx = mesh.indices.max() {
                    XCTAssertLessThan(Int(mx), mesh.vertices.count, "\(e.name): 인덱스 범위")
                }
                XCTAssertTrue(mesh.material.hasPrefix("materials/"), "\(e.name): 머티리얼 규약 \(mesh.material)")
            }
            // 스킨 정점 본 인덱스 ↔ 스켈레톤 교차검증
            if !m.bones.isEmpty {
                for mesh in m.meshes where mesh.skinned {
                    for v in mesh.vertices {
                        XCTAssertLessThan(Int(v.boneIndices.max()), m.bones.count, "\(e.name): 본 인덱스 범위")
                    }
                }
            }
            // 애니(MDLA0006) 존재 시 파스 성공 + 본별 트랙수 == 본수 + 키 포맷 무결.
            if m.hasAnimation {
                animModels += 1
                XCTAssertFalse(m.animations.isEmpty, "\(e.name): MDLA0006 있으나 애니 0 (리싱크 실패)")
                for a in m.animations {
                    XCTAssertEqual(a.tracks.count, m.bones.count, "\(e.name)/\(a.name): 트랙수==본수")
                    XCTAssertGreaterThan(a.fps, 0)
                    XCTAssertTrue(["loop", "single", "mirror", "clamp"].contains(a.mode), "\(e.name): 모드 \(a.mode)")
                }
            }
        }
        print("[Model3D] OoT parse \(ok)/\(mdls.count) OK, skinned=\(skinned), animModels=\(animModels), totalMeshes=\(totalMeshes), fails=\(failures)")
        XCTAssertEqual(ok, 100, "전수 파스 성공: 실패=\(failures)")
        XCTAssertEqual(skinned, 29, "스키닝(MDLS0004) 모델 29개")
        XCTAssertGreaterThan(animModels, 0, "MDLA0006 애니 모델 존재")
    }

    func testRepresentativeModelStats() throws {
        let pkg = try loadPkg("3737268876")
        func model(_ path: String) throws -> Model3D {
            try XCTUnwrap(Model3D.parse(try XCTUnwrap(pkg.data(for: path))), "parse fail: \(path)")
        }
        // lock: 단일 정적 메시, 100 정점 / 64 트라이앵글, maxIndex == vertexCount-1
        let lock = try model("models/lock/lock.mdl")
        XCTAssertEqual(lock.meshes.count, 1)
        XCTAssertFalse(lock.meshes[0].skinned)
        XCTAssertEqual(lock.meshes[0].vertices.count, 100)
        XCTAssertEqual(lock.meshes[0].indices.count, 64 * 3)
        XCTAssertEqual(Int(lock.meshes[0].indices.max() ?? 0), 99)
        XCTAssertTrue(lock.bones.isEmpty)
        XCTAssertFalse(lock.hasAnimation)

        // sky: 594 정점 / 510 트라이앵글
        let sky = try model("models/sky/sky.mdl")
        XCTAssertEqual(sky.meshes[0].vertices.count, 594)
        XCTAssertEqual(sky.meshes[0].indices.count, 510 * 3)

        // mario: 4 서브메시, 스키닝, 27본, 애니 1개(pc01_walk)
        let mario = try model("models/mario/mario.mdl")
        XCTAssertEqual(mario.meshes.count, 4)
        XCTAssertTrue(mario.meshes.allSatisfy { $0.skinned })
        XCTAssertEqual(mario.meshes.reduce(0) { $0 + $1.vertices.count }, 2335)
        XCTAssertEqual(mario.bones.count, 27)
        XCTAssertEqual(mario.bones[0].parent, -1, "루트")
        XCTAssertTrue(mario.hasAnimation, "MDLA0006 존재")
        XCTAssertEqual(mario.animations.count, 1, "mario 애니 1개")
        XCTAssertEqual(mario.animations[0].name, "body with fists_skeleton|pc01_walk")
        XCTAssertEqual(mario.animations[0].fps, 24)
        XCTAssertEqual(mario.animations[0].tracks.count, 27, "본별 트랙 == 본수")
        // 각 트랙 키수 == length+1(프레임당 1키, 0..length 포함)
        for t in mario.animations[0].tracks {
            XCTAssertEqual(t.count, mario.animations[0].lengthFrames + 1)
        }

        // link_adult: MDLA0006 4 애니(glance/idle/play/surprise) — 헤더 animCount=8 이나 리싱크로 4개 확정.
        let link = try model("models/link_adult/link_adult.mdl")
        XCTAssertEqual(link.bones.count, 31)
        XCTAssertEqual(link.animations.count, 4, "link_adult 4 애니(헤더 count 불신, 리싱크)")
        XCTAssertTrue(link.animations.contains { $0.name.lowercased().contains("idle") }, "idle 존재")
        XCTAssertEqual(Model3DPose.resolveAnimation(model: link, layerName: "Idle"),
                       link.animations.firstIndex { $0.name.lowercased().contains("idle") })
        // 스킨 행렬: 바인드 포즈(애니=-1) 항등, 애니 t>0 은 비항등(모션).
        let bindMats = Model3DPose.skinMatrices(model: link, animation: -1, time: 0)
        XCTAssertEqual(bindMats.count, 31)
        XCTAssertTrue(bindMats.allSatisfy { $0 == matrix_identity_float4x4 }, "애니 없음 → 스킨 항등(바인드)")
        // 정점 필드 sanity: 법선 단위길이 ≈ 1
        let n0 = mario.meshes[0].vertices[0].normal
        XCTAssertEqual(simd_length(n0), 1.0, accuracy: 1e-3)

        // treasure_chest: 2 서브메시, 스키닝, 5본
        let chest = try model("models/treasure_chest/treasure_chest.mdl")
        XCTAssertEqual(chest.meshes.count, 2)
        XCTAssertEqual(chest.bones.count, 5)
    }

    func testParsesSonicAndSolarModels() throws {
        for id in ["3706286085", "3662790108"] {
            let pkg: ScenePackage
            do { pkg = try loadPkg(id) } catch { continue }  // 없으면 스킵
            let mdls = pkg.entries.filter { $0.name.hasSuffix(".mdl") }
            var ok = 0
            for e in mdls {
                guard let m = pkg.data(for: e.name).flatMap(Model3D.parse) else { continue }
                ok += 1
                for mesh in m.meshes {
                    XCTAssertEqual(mesh.indices.count % 3, 0, "\(id)/\(e.name): 트라이앵글 리스트")
                    XCTAssertTrue(mesh.material.hasPrefix("materials/"), "\(id)/\(e.name): 머티리얼 규약 \(mesh.material)")
                }
            }
            print("[Model3D] pkg \(id): \(ok)/\(mdls.count) OK")
            XCTAssertEqual(ok, mdls.count, "pkg \(id) 전수 파스")
        }
    }
}
