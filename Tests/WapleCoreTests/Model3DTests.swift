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

    private func makeModelU16(_ meshes: [SynthMesh], magic: String = "MDLV0023") -> Data {
        var d = Data(magic.utf8)
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
        // 미목격 버전은 거부(추측 파스 금지) — 0023 과 같은 바이트라도 매직만 0018 이면 nil.
        let v18 = makeModelU16([SynthMesh(material: "materials/x.json", min: .zero, max: .zero, skinned: false,
                                          verts: [SynthVert(pos: .zero, nrm: SIMD3(0, 0, 1), tan: SIMD4(1, 0, 0, 1), uv: .zero)],
                                          indices: [0, 0, 0])], magic: "MDLV0018")
        XCTAssertNil(Model3D.parse(v18))
    }

    /// V0017/V0019: 메시·스켈레톤 레코드가 V0023 과 동일(실측 WLOP/3189665546 전수) — 매직 수용 +
    /// MDLS0002 스켈레톤 + MDLA0005 애니(레이아웃 동일, 숫자만 다름)까지 한 파일로 검증.
    func testParsesV0017AndV0019WithMDLS0002AndOldAnimMagic() throws {
        let vSkin = SynthVert(pos: SIMD3(1, 2, 0), nrm: SIMD3(0, 1, 0), tan: SIMD4(0, 0, 1, -1), uv: SIMD2(0.5, 0.5),
                              bones: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
        let mesh = SynthMesh(material: "materials/1.json", min: .zero, max: .zero,
                             skinned: true, verts: [vSkin, vSkin, vSkin], indices: [0, 1, 2])
        for (magic, animMagic) in [("MDLV0017", "MDLA0004"), ("MDLV0019", "MDLA0005")] {
            var d = makeModelU16([mesh], magic: magic)
            // MDLS0002: 레코드는 0004 와 동일(name|flags|parent|64|mat4|props) + 뒤에 13+80×본수 꼬리.
            d.append(Data("MDLS0002".utf8)); d.append(0)
            u(0, into: &d); u(1, into: &d)
            d.append(0)                                       // bone0 name "" (빈 cstring)
            u(1, into: &d)
            var pr: Int32 = -1; withUnsafeBytes(of: &pr) { d.append(contentsOf: $0) }
            u(64, into: &d)
            let mat: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, -3, 0, 1]
            for x in mat { f(x, into: &d) }
            d.append(0)                                       // props ""
            d.append(Data(repeating: 0, count: 11)); d.append(1)          // 꼬리 헤더(실측 11×0 + u8 1)
            d.append(Data(repeating: 0xAB, count: 80))                    // 본당 80B 미상 블록
            // 구버전 애니 매직 + 애니 1개(레이아웃은 MDLA0006 과 동일)
            d.append(Data(animMagic.utf8)); d.append(0)
            u(0, into: &d); u(1, into: &d); u(134, into: &d); u(0, into: &d)
            d.append(Data("Animación 1".utf8)); d.append(0)
            d.append(Data("loop".utf8)); d.append(0)
            f(30, into: &d); u(1, into: &d); u(0, into: &d); u(1, into: &d); u(0, into: &d)
            u(72, into: &d)                                   // 본0 트랙 2키 × 36B
            for _ in 0..<2 { for x: Float in [0, 0, 0, 0, 0, 0.5, 1, 1, 1] { f(x, into: &d) } }
            u(0, into: &d)                                    // blob2
            let m = try XCTUnwrap(Model3D.parse(d), "\(magic) 파스 실패")
            XCTAssertEqual(m.meshes.count, 1)
            XCTAssertTrue(m.meshes[0].skinned)
            XCTAssertEqual(m.bones.count, 1, "\(magic): MDLS0002 본")
            XCTAssertEqual(m.bones[0].bind.columns.3.x, 5)
            XCTAssertEqual(m.animations.count, 1, "\(magic): \(animMagic) 애니")
            XCTAssertEqual(m.animations[0].tracks[0].count, 2)
            XCTAssertEqual(m.animations[0].tracks[0][1].angles.z, 0.5, accuracy: 1e-6)
            XCTAssertNotNil(PuppetModel.parse(d), "\(magic): 퍼펫 라우팅")
        }
    }

    /// V0016(2885492021 전수 실측): AABB 부재 + 정점 플래그 0x01800009(normal/tangent 없는 stride 52
    /// = pos|bones4|weights4|uv — V0013 정점 레이아웃) + MDLS0002 + MDLA0003.
    func testParsesV0016NoAABBStride52() throws {
        var d = Data("MDLV0016".utf8)
        d.append(0); u(0x01800009, into: &d); u(1, into: &d); u(1, into: &d)   // hdr flag, const, meshCount
        d.append(Data("materials/图层 5.json".utf8)); d.append(0)
        u(0, into: &d)                                        // z — AABB 없음(바로 fmtflag)
        u(0x01800009, into: &d)                               // per-mesh flag: skin, normal/tangent 없음
        let verts: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>, SIMD2<Float>)] = [
            (SIMD3(22.02, -10.35, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0.9685, 0.7465)),
            (SIMD3(21.22, -11.39, 0), SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0.5, 0.5)),
            (SIMD3(0, 1, 0), SIMD4(0, 0, 0, 0), SIMD4(0.6, 0.4, 0, 0), SIMD2(0, 1)),
        ]
        u(UInt32(verts.count * 52), into: &d)
        for v in verts {
            f(v.0.x, into: &d); f(v.0.y, into: &d); f(v.0.z, into: &d)
            u(v.1.x, into: &d); u(v.1.y, into: &d); u(v.1.z, into: &d); u(v.1.w, into: &d)
            f(v.2.x, into: &d); f(v.2.y, into: &d); f(v.2.z, into: &d); f(v.2.w, into: &d)
            f(v.3.x, into: &d); f(v.3.y, into: &d)
        }
        u(6, into: &d)
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        // MDLS0002 + 1본 + 꼬리, MDLA0003 + 1애니
        d.append(Data("MDLS0002".utf8)); d.append(0)
        u(0, into: &d); u(1, into: &d)
        d.append(0); u(1, into: &d)
        var pr: Int32 = -1; withUnsafeBytes(of: &pr) { d.append(contentsOf: $0) }
        u(64, into: &d)
        for x: [Float] in [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [-37.03, 105.14, 0, 1]] { for v in x { f(v, into: &d) } }
        d.append(0)
        d.append(Data(repeating: 0, count: 11)); d.append(1)
        d.append(Data(repeating: 0xCD, count: 80))
        d.append(Data("MDLA0003".utf8)); d.append(0)
        u(0, into: &d); u(1, into: &d); u(0, into: &d); u(0, into: &d)
        d.append(Data("动画 1".utf8)); d.append(0)
        d.append(Data("loop".utf8)); d.append(0)
        f(30, into: &d); u(150, into: &d); u(0, into: &d); u(1, into: &d); u(0, into: &d)
        u(36, into: &d)
        for x: Float in [1, 2, 0, 0, 0, 0, 1, 1, 1] { f(x, into: &d) }
        u(0, into: &d)

        let m = try XCTUnwrap(Model3D.parse(d), "MDLV0016 파스 실패")
        let mm = m.meshes[0]
        XCTAssertTrue(mm.skinned)
        XCTAssertEqual(mm.vertices.count, 3)
        XCTAssertEqual(mm.vertices[0].position.x, 22.02, accuracy: 1e-4)
        XCTAssertEqual(mm.vertices[0].uv, SIMD2(0.9685, 0.7465))
        XCTAssertEqual(mm.vertices[2].weights.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(mm.vertices[0].normal, SIMD3(0, 0, 1), "normal 부재 → 기본값")
        XCTAssertEqual(mm.vertices[0].tangent, SIMD4(1, 0, 0, 1), "tangent 부재 → 기본값")
        XCTAssertEqual(m.bones.count, 1)
        XCTAssertEqual(m.bones[0].bind.columns.3.x, -37.03, accuracy: 1e-4)
        XCTAssertEqual(m.animations.count, 1, "MDLA0003 애니")
        XCTAssertEqual(m.animations[0].name, "动画 1")
        XCTAssertEqual(m.animations[0].lengthFrames, 150)
        // 퍼펫 라우팅(렌더 경로): pos/bones/weights/uv 가 그대로 이식
        let pm = try XCTUnwrap(PuppetModel.parse(d), "V0016 퍼펫 라우팅 실패")
        XCTAssertEqual(pm.vertices.count, 3)
        XCTAssertEqual(pm.vertices[0].uv, SIMD2(0.9685, 0.7465))
        XCTAssertEqual(pm.bones.count, 1)
        XCTAssertEqual(pm.animations.count, 1)
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

    /// 이슈7: MDLV0021(코퍼스 7개 pkg 에 17개 실존)이 0023 과 동일 레이아웃임을 실물 전수로 검증 —
    /// 파스 성공 + 인덱스/트라이앵글/머티리얼 정합. 실패 시 0021 은 별도 레이아웃이므로 수용 철회 신호.
    /// (3189665546 은 MDLV0019 도 섞여 있어 0021 매직 모델만 대상 — 0019 는 미지원.)
    func testParsesMDLV0021Models() throws {
        let ids = ["3189665546", "3367988661", "3384019940", "3404976219", "3400879974", "3417957645", "3409595232"]
        var total = 0
        for id in ids {
            let pkg: ScenePackage
            do { pkg = try loadPkg(id) } catch { continue }   // 없으면 스킵
            for e in pkg.entries where e.name.hasSuffix(".mdl") {
                guard let raw = pkg.data(for: e.name),
                      String(bytes: raw.prefix(8), encoding: .utf8) == "MDLV0021" else { continue }
                total += 1
                guard let m = Model3D.parse(raw) else { XCTFail("\(id)/\(e.name): MDLV0021 파스 실패"); continue }
                for mesh in m.meshes {
                    XCTAssertEqual(mesh.indices.count % 3, 0, "\(id)/\(e.name): 트라이앵글 리스트")
                    if let mx = mesh.indices.max() {
                        XCTAssertLessThan(Int(mx), mesh.vertices.count, "\(id)/\(e.name): 인덱스 범위")
                    }
                    XCTAssertTrue(mesh.material.hasPrefix("materials/"), "\(id)/\(e.name): 머티리얼 규약 \(mesh.material)")
                }
            }
        }
        print("[Model3D] MDLV0021 전수: \(total)개 파스·정합 OK")
        if total == 0 { throw XCTSkip("코퍼스에 MDLV0021 부재") }
    }

    /// 구버전 퍼펫(MDLV0016/0017/0019) 실물 전수: 파스 + 인덱스/본/애니 정합 + 퍼펫 라우팅(렌더 경로 입구).
    /// 실패 시 해당 버전 레이아웃 가정이 무너진 것 — 수용 철회 신호.
    func testParsesOldVersionPuppetModels() throws {
        let expected = ["2885492021": "MDLV0016", "3113287126": "MDLV0017", "3189665546": "MDLV0019"]
        var total = 0
        for (id, wantMagic) in expected {
            let pkg: ScenePackage
            do { pkg = try loadPkg(id) } catch { continue }   // 없으면 스킵
            for e in pkg.entries where e.name.hasSuffix(".mdl") {
                guard let raw = pkg.data(for: e.name),
                      String(bytes: raw.prefix(8), encoding: .utf8) == wantMagic else { continue }
                total += 1
                guard let m = Model3D.parse(raw) else { XCTFail("\(id)/\(e.name): \(wantMagic) 파스 실패"); continue }
                for mesh in m.meshes {
                    XCTAssertEqual(mesh.indices.count % 3, 0, "\(id)/\(e.name): 트라이앵글 리스트")
                    if let mx = mesh.indices.max() {
                        XCTAssertLessThan(Int(mx), mesh.vertices.count, "\(id)/\(e.name): 인덱스 범위")
                    }
                }
                XCTAssertFalse(m.bones.isEmpty, "\(id)/\(e.name): MDLS0002 본")
                XCTAssertFalse(m.animations.isEmpty, "\(id)/\(e.name): 구버전 MDLA 애니")
                for a in m.animations {
                    XCTAssertEqual(a.tracks.count, m.bones.count, "\(id)/\(e.name)/\(a.name): 트랙수==본수")
                }
                XCTAssertNotNil(PuppetModel.parse(raw), "\(id)/\(e.name): 퍼펫 라우팅(렌더 경로)")
            }
        }
        print("[Model3D] 구버전 퍼펫 전수: \(total)개 OK")
        if total == 0 { throw XCTSkip("코퍼스에 구버전 퍼펫 부재") }
    }
}
