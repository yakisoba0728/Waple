import XCTest
import simd
@testable import WapleCore

/// D2/D3(2026-07-28): 메시 트레일러 게이트 구조 + MDLS 꼬리(T1..T7) 정식 파스 테스트.
/// 근거: WE 2.8.42 MDL 디코더 **`FUN_140261880`(RVA 0x261880)** + wallpaper64.exe 어셈블리 대조
/// + 실물 418파일 전수 착지 검증. 픽스처 값은 실물 관측치(Kirby gateB 16B, 眼睛_puppet 모프
/// 레코드, cat11_puppet T4a/T4b)를 축약 사용.
///
/// **[정정 2026-08-30] 이 파일의 디컴파일 인용 이름을 참 VA 로 옮긴다.** 종전 머리말은
/// > `근거: WE 2.8.42 디컴파일 FUN_140261950(:1214-1457 트레일러, :235-1059 MDLS)`
/// 였다. `FUN_140261950` 은 rich header 주입본 시절 이름이고 재생성 코퍼스에 **없다** —
/// 짝 저장소 `analysis/decompiled/manifest.json` 의 7,748 함수 어디에도 그 주소가 함수 시작으로
/// 없고, `−0xD0` 한 `0x140261880` 이 함수 시작으로 실재한다(`FUN_140261880`, 3,299줄).
/// `Sources/WapleCore/Model3D.swift` 의 같은 취지 정정 블록과 `spec/README.md` 가 이 개명을 적어
/// 뒀는데 정작 인용 지점인 이 파일은 안 따라왔다.
///
/// **줄 번호는 옮기지 않고 버린다.** 폐기된 변위 코퍼스 기준의 `:1214-1457`·`:235-1059` 같은
/// 범위는 재생성본에서 맞지 않는다(실측: `:1214` 는 트레일러가 아니라 float 선택 루프,
/// `:235-1059` 는 MDLS `strncmp` 를 품기는 하나 825줄 폭이라 앵커로 쓸모가 없다).
/// Model3D.swift 의 지침대로 **줄 번호 대신 VA·조건식**으로 적는다:
///   · 트레일러 게이트(v≥21) — `if (0x14 < iVar11)`, 그 블록 첫 호출 지점 VA `0x140261b70`
///   · v≥23 모프 리드     — `if (0x16 < iVar11)`, 첫 리드 VA `0x140261bea`
///   · MDLS 태그          — `strncmp(pcVar20,"MDLS0004",4)`
///   · MDLS 본 상한       — `if (0x80 < uVar14) { swi(0x29); }`(__fastfail), 주변 VA `0x140262501`
/// 세 VA 전부 `FUN_140261880` 범위 안임을 manifest 로 확인했다(+0x2f0 / +0x36a / +0xc81).
final class Model3DTrailerSkeletonTailTests: XCTestCase {
    // MARK: synthetic byte builders

    private func f(_ v: Float, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u(_ v: UInt32, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u16(_ v: UInt16, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u64(_ v: UInt64, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func cstr(_ s: String, into d: inout Data) { d.append(Data(s.utf8)); d.append(0) }

    private func makeHeader(_ magic: String, _ meshCount: Int) -> Data {
        var d = Data(magic.utf8)
        d.append(0); u(0x0f, into: &d); u(1, into: &d); u(UInt32(meshCount), into: &d)
        return d
    }

    /// 정적/스킨 단일 서브메시 바이트(정점 3개, 인덱스 [0,1,2]). v23/v21 은 AABB 포함.
    private func appendMesh(_ d: inout Data, material: String, skinned: Bool = false, hasAABB: Bool = true) {
        d.append(Data(material.utf8)); d.append(0)
        u(0, into: &d)                                    // z(관측 0 — bit1 미설정이라 여분 u32 없음)
        if hasAABB { for _ in 0..<6 { f(0, into: &d) } }
        u(skinned ? 0x0180_000f : 0x0000_000f, into: &d)
        let stride = skinned ? 80 : 48
        u(UInt32(3 * stride), into: &d)
        for i in 0..<3 {
            f(Float(i), into: &d); f(1, into: &d); f(0, into: &d)            // pos
            f(0, into: &d); f(0, into: &d); f(1, into: &d)                   // normal
            f(1, into: &d); f(0, into: &d); f(0, into: &d); f(1, into: &d)   // tangent
            if skinned {
                u(0, into: &d); u(0, into: &d); u(0, into: &d); u(0, into: &d)          // boneIdx
                f(1, into: &d); f(0, into: &d); f(0, into: &d); f(0, into: &d)          // weights
            }
            f(0.5, into: &d); f(0.5, into: &d)                             // uv
        }
        u(6, into: &d)
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    }

    private func appendIdentityMat(_ d: inout Data, tx: Float = 0, ty: Float = 0, tz: Float = 0) {
        for x: [Float] in [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [tx, ty, tz, 1]] {
            for v in x { f(v, into: &d) }
        }
    }

    private func appendBone(_ d: inout Data, name: String, parent: Int32) {
        cstr(name, into: &d)
        u(0, into: &d)                                       // flags
        var p = parent; withUnsafeBytes(of: &p) { d.append(contentsOf: $0) }
        u(64, into: &d)                                      // matrix size
        appendIdentityMat(&d)
        d.append(0)                                          // props ""
    }

    private func appendMDLS(_ d: inout Data, magic: String = "MDLS0004", boneCount: Int) {
        d.append(Data(magic.utf8)); d.append(0)
        u(0, into: &d); u(UInt32(boneCount), into: &d)       // nextOff(더미), 본수
    }

    // MARK: - 작업 1: 메시 트레일러 게이트 구조

    /// gateA=1 트레일러: 종전 휴리스틱(u8 0 필수)은 nil → +6 폴리백으로 mesh1 프레이밍 붕괴
    /// (태스크의 ':313 폴터 +6 오프셋 불일치'). 정식 파스는 u32 word + u32 size + blob 를 소비하고 노출.
    func testGateATrailerParsesAndPreservesMultiMeshFraming() throws {
        var d = makeHeader("MDLV0023", 2)
        appendMesh(&d, material: "materials/a.json")
        // mesh0 트레일러: gateA=1 | u32 word=1 | u32 size=24 | 24B blob | gateB=0 | morphCount=0
        d.append(1); u(1, into: &d); u(24, into: &d)
        d.append(Data((1...24).map { UInt8($0) }))
        d.append(0); u(0, into: &d)
        appendMesh(&d, material: "materials/b.json")
        d.append(Data(repeating: 0, count: 6))            // mesh1 트레일러 전부 0
        d.append(0)                                       // 파일 종단 NUL(실물 418/418)

        let m = try XCTUnwrap(Model3D.parse(d), "gateA=1 멀티메시 프레이밍 붕괴 — 정식 파스 실패")
        XCTAssertEqual(m.meshes.count, 2)
        XCTAssertEqual(m.meshes[1].material, "materials/b.json")
        let gA = try XCTUnwrap(m.meshes[0].trailer?.gateA, "gateA 블롭 미노출")
        XCTAssertEqual(gA.word, 1)
        XCTAssertEqual(gA.data, Data((1...24).map { UInt8($0) }))
        XCTAssertNil(m.meshes[0].trailer?.gateB)
        XCTAssertEqual(m.meshes[0].trailer?.morphs ?? [], [])
        XCTAssertNil(m.meshes[1].trailer, "전부 0 트레일러는 nil(종전 '6바이트 구분자'와 동형)")
    }

    /// gateB=1 + 16B×2 레코드: Kirby 실물 패턴(12B 0 + u32). 종전 해석(u8 0|u8 1|u32 size|blob|u32 tail)과
    /// 우연히 바이트 동형이라 파스는 종전대로 성공 — 신규는 블롭 노출.
    func testGateBTrailerExposes16BRecordBlob() throws {
        var d = makeHeader("MDLV0023", 2)
        appendMesh(&d, material: "materials/a.json")
        // gateA=0 | gateB=1 | u32 32 | 16B×2 레코드(실물: 12B 0 + u32)
        d.append(0); d.append(1); u(32, into: &d)
        d.append(Data(repeating: 0, count: 12)); u(1824, into: &d)   // Kirby 레코드 1
        d.append(Data(repeating: 0, count: 12)); u(640, into: &d)    // 레코드 2
        u(0, into: &d)                                    // morphCount 0
        appendMesh(&d, material: "materials/b.json")
        d.append(Data(repeating: 0, count: 6)); d.append(0)

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.meshes[1].material, "materials/b.json")
        let gB = try XCTUnwrap(m.meshes[0].trailer?.gateB, "gateB 블롭 미노출")
        XCTAssertEqual(gB.count, 32)
        XCTAssertEqual(gB.count / 16, 2, "16B 레코드 2개(엔진: size>>4 = 레코드 수)")
    }

    /// v23 모프 레코드: u64 id | cstring name | u32 flags | u32 n1 + n1×u32 | u32 n2 + n2×u32.
    /// 값은 실물 眼睛_puppet/若叶睦 관측치. MDMP0001 디스패치(디컴파일 :1104-1108)와 연계되는 구조.
    func testMorphTargetRecordsV23() throws {
        var d = makeHeader("MDLV0023", 2)
        appendMesh(&d, material: "materials/a.json")
        d.append(0); d.append(1); u(16, into: &d)         // gateA=0, gateB=1 + 16B×1
        d.append(Data(repeating: 0, count: 16))
        u(2, into: &d)                                    // morphCount = 2
        u64(5661, into: &d); cstr("masks/clipping_mask_2766f6e9", into: &d)
        u(0, into: &d)                                    // flags
        u(1, into: &d); u(15, into: &d)                   // n1=1 → [15]
        u(4, into: &d); for x: UInt32 in [0, 1, 2, 3] { u(x, into: &d) }   // n2=4
        u64(276, into: &d); cstr("masks/clipping_mask_6cec714b", into: &d)
        u(1, into: &d)                                    // flags=1
        u(1, into: &d); u(12, into: &d)                   // n1=1 → [12]
        u(2, into: &d); u(0, into: &d); u(2, into: &d)    // n2=2 → [0, 2]
        appendMesh(&d, material: "materials/b.json")
        d.append(Data(repeating: 0, count: 6)); d.append(0)

        let m = try XCTUnwrap(Model3D.parse(d), "모프 레코드 멀티메시 프레이밍 실패")
        XCTAssertEqual(m.meshes[1].material, "materials/b.json")
        let morphs = try XCTUnwrap(m.meshes[0].trailer?.morphs)
        XCTAssertEqual(morphs.count, 2)
        XCTAssertEqual(morphs[0].id, 5661)
        XCTAssertEqual(morphs[0].name, "masks/clipping_mask_2766f6e9")
        XCTAssertEqual(morphs[0].flags, 0)
        XCTAssertEqual(morphs[0].indicesA, [15])
        XCTAssertEqual(morphs[0].indicesB, [0, 1, 2, 3])
        XCTAssertEqual(morphs[1].id, 276)
        XCTAssertEqual(morphs[1].flags, 1)
        XCTAssertEqual(morphs[1].indicesA, [12])
        XCTAssertEqual(morphs[1].indicesB, [0, 2])
    }

    /// v21 트레일러는 모프 카운트가 없다(엔진: v≥23 전용 — 어셈블리 `cmp edi,0x17`).
    /// 종전 휴리스틱은 u32 tail 을 무조건 소비해 실제보다 4B 과소비(조용한 프레이밍 부패) —
    /// 정식 파스는 gateB 블롭 직후 정확히 끝낸다.
    func testV21TrailerHasNoMorphCount() throws {
        var d = makeHeader("MDLV0021", 2)
        appendMesh(&d, material: "materials/a.json")
        d.append(0); d.append(1); u(16, into: &d)         // gateA=0, gateB=1 + 16B×1
        d.append(Data(repeating: 0, count: 16))           // ← v21 트레일러는 여기까지(22B)
        appendMesh(&d, material: "materials/b.json")
        d.append(0); d.append(0)                          // mesh1 트레일러(gates 0, 모프 없음 = 2B)
        d.append(0)

        let m = try XCTUnwrap(Model3D.parse(d), "v21 트레일러 프레이밍 실패")
        XCTAssertEqual(m.meshes.count, 2)
        XCTAssertEqual(m.meshes[1].material, "materials/b.json", "v21 은 모프카운트 부재 — 4B 과소비 금지")
        XCTAssertEqual(m.meshes[0].trailer?.gateB?.count, 16)
        XCTAssertEqual(m.meshes[0].trailer?.morphs ?? [], [])
        XCTAssertNil(m.meshes[1].trailer)
    }

    /// v<21 은 트레일러 자체가 없다(엔진 `FUN_140261880` 의 v≥21 게이트 `if (0x14 < iVar11)`
    /// — 그 블록 안에서만 트레일러를 읽는다. 첫 호출 지점 VA `0x140261b70`).
    /// **[정정 2026-08-30]** 종전 이 자리는 ~~`디컴파일 :1214 \`if (0x14 < iVar17)\``~~ 였다.
    /// 줄 번호도 변수명도 재생성본과 어긋난다 — 그 줄은 float 선택 루프이고 실제 게이트의 변수는
    /// `iVar11` 이다(887줄 차). 재생성마다 흔들리는 줄 번호 대신 조건식과 VA 로 적는다.
    /// 종전 코드는 메시 사이에 무조건 6B 를 건니뛰어 v16 다중메시를 붕괴시켰다(미수용 매직이라
    /// 실물 미관측이나 정본 정합). V0016: AABB 부재 + 정점 플래그 0x09(stride 20 = pos|uv).
    func testV16MultiMeshHasNoTrailer() throws {
        func appendV16Mesh(_ d: inout Data, material: String) {
            d.append(Data(material.utf8)); d.append(0)
            u(0, into: &d)                                // z — V0016 은 AABB 없음
            u(0x09, into: &d)                             // flag 0x09 → stride 20(pos 3f + uv 2f)
            u(3 * 20, into: &d)
            for i in 0..<3 {
                f(Float(i), into: &d); f(2, into: &d); f(0, into: &d)   // pos
                f(0.25, into: &d); f(0.75, into: &d)                    // uv
            }
            u(6, into: &d)
            for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        }
        var d = makeHeader("MDLV0016", 2)
        appendV16Mesh(&d, material: "materials/a.json")
        appendV16Mesh(&d, material: "materials/b.json")   // 메시 사이 트레일러 없음(정본)
        let m = try XCTUnwrap(Model3D.parse(d), "v16 다중메시: 트레일러 미소비가 정본 정합")
        XCTAssertEqual(m.meshes.count, 2)
        XCTAssertEqual(m.meshes[0].material, "materials/a.json")
        XCTAssertEqual(m.meshes[1].material, "materials/b.json")
        XCTAssertEqual(m.meshes[1].vertices.count, 3)
    }

    /// 마지막 메시 뒤 트레일러(실물 390/390 존재): 단일메시 + gateA 블롭 + MDLS — 트레일러를
    /// 정식 소비한 뒤 스켈레톤 스캔이 정상 착지해야 한다.
    func testLastMeshTrailerConsumedBeforeSkeleton() throws {
        var d = makeHeader("MDLV0023", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        d.append(1); u(1, into: &d); u(12, into: &d)      // gateA=1 word=1 + 12B(정점수×vec3 풍)
        d.append(Data(repeating: 0xAA, count: 12))
        d.append(0); u(0, into: &d)                       // gateB=0, morphCount=0
        appendMDLS(&d, boneCount: 1)
        appendBone(&d, name: "Root", parent: -1)
        // MDLS 꼬리 전부 0(MDLS0004: T1..T7 = 2+1+4+2+2+1+1+1 = 14B) + 종단 NUL
        d.append(Data(repeating: 0, count: 14)); d.append(0)

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.bones.count, 1, "마지막 메시 트레일러 소비 후 스켈레톤 착지")
        XCTAssertEqual(m.meshes[0].trailer?.gateA?.data.count, 12)
        XCTAssertNotNil(m.skeletonTail, "전부 0 꼬리도 파스 성공(착지=말미 NUL)")
    }

    // MARK: - 작업 2: MDLS 꼬리(T1..T7)

    /// MDLS0004 꼬리 전 구간 합성: T1 태그, T2 게이트 mat4, T3 제약(flags&2 분기 포함), T5, T6, T7.
    /// skeletonTail 노출은 착지 검증(여기선 MDLA 매직) 통과 시에만 — 내용 단언이 곧 프레이밍 단언.
    func testSkeletonTailAllBlocksParseAndLandOnAnimation() throws {
        var d = makeHeader("MDLV0023", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        d.append(Data(repeating: 0, count: 6))            // 메시 트레일러(전부 0)
        appendMDLS(&d, boneCount: 2)
        appendBone(&d, name: "Root", parent: -1)
        appendBone(&d, name: "Spine", parent: 0)
        // T1: C1=2 — ("gd", bone1, flags1, I) / ("ik", bone0, flags0, 이동 mat4)
        u16(2, into: &d)
        cstr("gd", into: &d); u(1, into: &d); u(1, into: &d); appendIdentityMat(&d)
        cstr("ik", into: &d); u(0, into: &d); u(0, into: &d); appendIdentityMat(&d, tx: 3, ty: -2, tz: 1)
        // T2: gate=1 — 본수×64B
        d.append(1); appendIdentityMat(&d); appendIdentityMat(&d, tx: 1)
        // T3: C2=2 — (bone1, 0.5, -0.25, flags0) / (bone0, 1.0, 2.0, flags3 → extra 2f)
        u(2, into: &d)
        u(1, into: &d); f(0.5, into: &d); f(-0.25, into: &d); u(0, into: &d)
        u(0, into: &d); f(1.0, into: &d); f(2.0, into: &d); u(3, into: &d); f(0.1, into: &d); f(0.2, into: &d)
        // T4a C3=0, T4b C4=0
        u16(0, into: &d); u16(0, into: &d)
        // T5: gate=1 — 본수×(3f+mat4)
        d.append(1)
        f(10, into: &d); f(20, into: &d); f(30, into: &d); appendIdentityMat(&d)
        f(-1, into: &d); f(-2, into: &d); f(-3, into: &d); appendIdentityMat(&d, tx: 5)
        // T6: gate=1 — 본수×u32 (본 인덱스 순열 풍)
        d.append(1); u(1, into: &d); u(0, into: &d)
        // T7: gate=1 — 본수×u32
        d.append(1); u(100, into: &d); u(200, into: &d)
        // 다음 섹션 MDLA0006(애니 0개) — 착지 검증용
        d.append(Data("MDLA0006".utf8)); d.append(0)
        u(0, into: &d); u(0, into: &d); u(0, into: &d); u(0, into: &d)

        let m = try XCTUnwrap(Model3D.parse(d))
        let t = try XCTUnwrap(m.skeletonTail, "MDLS 꼬리 미노출(착지 검증 실패?)")
        XCTAssertEqual(t.tags.count, 2)
        XCTAssertEqual(t.tags[0].tag, "gd"); XCTAssertEqual(t.tags[0].bone, 1); XCTAssertEqual(t.tags[0].flags, 1)
        XCTAssertEqual(t.tags[1].tag, "ik"); XCTAssertEqual(t.tags[1].matrix.columns.3.x, 3, accuracy: 1e-6)
        XCTAssertEqual(t.extraBinds.count, 2, "T2 게이트 — 본수×64B")
        XCTAssertEqual(t.extraBinds[1].columns.3.x, 1, accuracy: 1e-6)
        XCTAssertEqual(t.constraints.count, 2)
        XCTAssertEqual(t.constraints[0].bone, 1)
        XCTAssertEqual(t.constraints[0].a, 0.5, accuracy: 1e-6)
        XCTAssertEqual(t.constraints[0].b, -0.25, accuracy: 1e-6)
        XCTAssertEqual(t.constraints[0].flags, 0)
        XCTAssertNil(t.constraints[0].extra, "flags&2 아님 — 추가 2f 없음")
        XCTAssertEqual(t.constraints[1].flags, 3)
        XCTAssertEqual(try XCTUnwrap(t.constraints[1].extra).x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(t.constraints[1].extra).y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(t.boneTransforms.count, 2, "T5 게이트 — 본수×(3f+mat4)")
        XCTAssertEqual(t.boneTransforms[0].offset, SIMD3(10, 20, 30))
        XCTAssertEqual(t.boneTransforms[1].matrix.columns.3.x, 5, accuracy: 1e-6)
        XCTAssertEqual(t.boneIndices, [1, 0], "T6 게이트 — 본수×u32")
        XCTAssertEqual(t.boneParams, [100, 200], "T7 게이트(MDLS≥3) — 본수×u32")
        XCTAssertNil(t.groups); XCTAssertEqual(t.links, [])
        XCTAssertTrue(m.hasAnimation, "꼬리 착지 지점(MDLA)에서 애니 섹션 탐지")
    }

    /// T4a 중첩(u16 C3 | C3×u32 | C3 × (u16 D | D×16B)) + T4b 링크 레코드 — 디컴파일 결락분을
    /// 어셈블리(0x140262a34-0x140262bd0)로 복구한 구조. 값은 cat11_puppet 실측 축약.
    /// 착지는 말미 NUL(EOF-1) 경로로 검증.
    func testSkeletonTailNestedGroupsAndLinks() throws {
        var d = makeHeader("MDLV0023", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        d.append(Data(repeating: 0, count: 6))
        appendMDLS(&d, boneCount: 3)
        appendBone(&d, name: "Root", parent: -1)
        appendBone(&d, name: "A", parent: 0)
        appendBone(&d, name: "B", parent: 0)
        // T1: C1=1 — 빈 태그(실물 전부 빈 문자열), bone2
        u16(1, into: &d)
        cstr("", into: &d); u(2, into: &d); u(0, into: &d); appendIdentityMat(&d)
        d.append(0)                                       // T2 gate 0
        u(0, into: &d)                                    // T3 C2=0
        // T4a: C3=2 | values [1.0f, 2.0f] | group0: D=2 | group1: D=1
        u16(2, into: &d)
        u(0x3F800000, into: &d); u(0x40000000, into: &d)
        u16(2, into: &d)
        u(2, into: &d); f(0.99, into: &d); f(0.13, into: &d); u(0, into: &d)
        u(1, into: &d); f(-0.84, into: &d); f(-0.53, into: &d); u(0, into: &d)
        u16(1, into: &d)
        u(0, into: &d); f(0.5, into: &d); f(0.5, into: &d); u(7, into: &d)
        // T4b: C4=1 — bone2 | B=1 refs[0](T1 인덱스) | C=1: idx1 D=1: vec4(1,2,3,4) E=2 [5,6]
        u16(1, into: &d)
        u(2, into: &d); u(1, into: &d); u(0, into: &d)
        u16(1, into: &d)
        u(1, into: &d); u16(1, into: &d)
        f(1, into: &d); f(2, into: &d); f(3, into: &d); f(4, into: &d)
        u16(2, into: &d); u(5, into: &d); u(6, into: &d)
        d.append(0)                                       // T5 gate 0
        d.append(0)                                       // T6 gate 0
        d.append(0)                                       // T7 gate 0
        d.append(0)                                       // 파일 종단 NUL(EOF-1 착지)

        let m = try XCTUnwrap(Model3D.parse(d))
        let t = try XCTUnwrap(m.skeletonTail, "T4a/T4b 꼬리 미노출")
        let g = try XCTUnwrap(t.groups)
        XCTAssertEqual(g.values, [0x3F800000, 0x40000000], "T4a 선행 C3×u32(f32 비트로 보존)")
        XCTAssertEqual(g.groups.count, 2, "외측 루프 C3 회(어셈블리 `cmp r13d,ebx`)")
        XCTAssertEqual(g.groups[0].count, 2)
        XCTAssertEqual(g.groups[0][0].index, 2)
        XCTAssertEqual(g.groups[0][0].x, 0.99, accuracy: 1e-6)
        XCTAssertEqual(g.groups[0][0].y, 0.13, accuracy: 1e-6)
        XCTAssertEqual(g.groups[0][1].index, 1)
        XCTAssertEqual(g.groups[1].count, 1)
        XCTAssertEqual(g.groups[1][0].value, 7)
        XCTAssertEqual(t.links.count, 1)
        XCTAssertEqual(t.links[0].bone, 2)
        XCTAssertEqual(t.links[0].refs, [0], "T1 태그 레코드 인덱스(엔진 bound 검사 대상)")
        XCTAssertEqual(t.links[0].subs.count, 1)
        XCTAssertEqual(t.links[0].subs[0].index, 1)
        XCTAssertEqual(t.links[0].subs[0].elems.count, 1)
        XCTAssertEqual(t.links[0].subs[0].elems[0].vec, SIMD4(1, 2, 3, 4))
        XCTAssertEqual(t.links[0].subs[0].elems[0].indices, [5, 6])
    }

    /// MDLS0002(v=2): T3 제약 엔트리에 flags 워드가 없고(12B 고정 — 어셈블리 `cmp r15d,4`),
    /// T7 블록도 없다(디컴파일 :1006 `2 < ver`). 종전 '13+80×본수 꼬리' 기록의 정본 해석.
    func testSkeletonTailV2ConstraintHasNoFlagsWordAndNoT7() throws {
        var d = makeHeader("MDLV0019", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        // v19 는 트레일러 부재(v<21) — 메시 직후 MDLS
        appendMDLS(&d, magic: "MDLS0002", boneCount: 1)
        appendBone(&d, name: "Root", parent: -1)
        u16(0, into: &d)                                  // T1 C1=0
        d.append(0)                                       // T2 gate 0
        u(1, into: &d)                                    // T3 C2=1 — bone0, a, b (12B 만!)
        u(0, into: &d); f(0.75, into: &d); f(-0.5, into: &d)
        u16(0, into: &d)                                  // T4a C3=0
        u16(0, into: &d)                                  // T4b C4=0
        d.append(0)                                       // T5 gate 0
        d.append(0)                                       // T6 gate 0
        // (T7 없음 — MDLS v<3) 곧장 MDLA0005
        d.append(Data("MDLA0005".utf8)); d.append(0)
        u(0, into: &d); u(0, into: &d); u(0, into: &d); u(0, into: &d)

        let m = try XCTUnwrap(Model3D.parse(d), "MDLS0002 꼬리 프레이밍 실패")
        let t = try XCTUnwrap(m.skeletonTail)
        XCTAssertEqual(t.constraints.count, 1)
        XCTAssertEqual(t.constraints[0].a, 0.75, accuracy: 1e-6)
        XCTAssertEqual(t.constraints[0].b, -0.5, accuracy: 1e-6)
        XCTAssertEqual(t.constraints[0].flags, 0, "v<4 는 flags 워드 부재 → 0")
        XCTAssertNil(t.constraints[0].extra)
        XCTAssertEqual(t.boneParams, [], "MDLS0002 는 T7 없음")
        XCTAssertTrue(m.hasAnimation, "T7 부재 위치에서 MDLA0005 정확 착지")
    }

    /// 꼬리 난부 블롭 안의 가짜 MDLA 매직 오탐 제거: T5 블롭 안에 "MDLA0006" 바이트를 심고,
    /// 정식 착지(진짜 MDLA)까지만 스캔이 진행되는지 검증. 종전 매직 스캔은 가짜를 먼저 집었다.
    func testTailBlobMagicFalsePositiveEliminated() throws {
        var d = makeHeader("MDLV0023", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        d.append(Data(repeating: 0, count: 6))
        appendMDLS(&d, boneCount: 1)
        appendBone(&d, name: "Root", parent: -1)
        u16(0, into: &d)                                  // T1
        d.append(0)                                       // T2
        u(0, into: &d)                                    // T3
        u16(0, into: &d); u16(0, into: &d)                // T4a/T4b
        d.append(1)                                       // T5 gate=1 — 76B(3f + mat4) 안에 가짜 매직
        f(0, into: &d); f(0, into: &d); f(0, into: &d)
        var fake = Data(repeating: 0, count: 64)
        fake.replaceSubrange(8..<16, with: Data("MDLA0006".utf8))
        d.append(fake)
        d.append(0)                                       // T6 gate 0
        d.append(0)                                       // T7 gate 0
        // 진짜 MDLA0006 + 애니 1개("real")
        d.append(Data("MDLA0006".utf8)); d.append(0)
        u(0, into: &d); u(1, into: &d); u(9, into: &d); u(0, into: &d)
        cstr("real", into: &d); cstr("loop", into: &d)
        f(30, into: &d); u(1, into: &d); u(0, into: &d); u(1, into: &d); u(0, into: &d)
        u(36, into: &d)
        for x: Float in [0, 0, 0, 0, 0, 0, 1, 1, 1] { f(x, into: &d) }
        u(0, into: &d)

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertNotNil(m.skeletonTail, "T5 블롭 소비 후 정상 착지")
        XCTAssertEqual(m.animations.count, 1, "가짜 MDLA 가 아니라 진짜 MDLA 로 착지")
        XCTAssertEqual(m.animations.first?.name, "real")
    }

    /// 꼬리 파스가 비매직 지점에 착지하면(손상/미지 변종) 노출하지 않고 종전 스캔으로 폴리백 —
    /// 본·애니 파스는 그대로 유지(무회귀).
    func testSkeletonTailUnverifiedLandingFallsBackToScan() throws {
        var d = makeHeader("MDLV0023", 1)
        appendMesh(&d, material: "materials/a.json", skinned: true)
        d.append(Data(repeating: 0, count: 6))
        appendMDLS(&d, boneCount: 1)
        appendBone(&d, name: "Root", parent: -1)
        d.append(Data("GARBAGE-GARBAGE-!!".utf8))         // 꼬리 위치의 비구조 바이트
        d.append(Data("MDLA0006".utf8)); d.append(0)
        u(0, into: &d); u(0, into: &d); u(0, into: &d); u(0, into: &d)

        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.bones.count, 1)
        XCTAssertNil(m.skeletonTail, "착지 미검증 — 노출하지 않음")
        XCTAssertTrue(m.hasAnimation, "폴리백 스캔이 MDLA 를 그대로 탐지(무회귀)")
    }

    // MARK: - 작업 3: PuppetModel 방어

    /// fromModel3D 병합: 정점 >0xFFFF 가 되는 삼각형은 0 클램프(정점0 찌그러짐) 대신 통째로 드롭.
    /// 피팅하는 삼각형은 보존(드롭은 삼각형 단위라 %3 정합 유지).
    func testFromModel3DDropsOverflowTrianglesNotClamp() {
        let v = Model3D.Vertex(position: .zero, normal: SIMD3(0, 0, 1), tangent: SIMD4(1, 0, 0, 1), uv: .zero)
        let mesh0 = Model3D.Mesh(material: "m0", boundsMin: .zero, boundsMax: .zero,
                                 skinned: true, vertices: [Model3D.Vertex](repeating: v, count: 65533), indices: [])
        let mesh1 = Model3D.Mesh(material: "m1", boundsMin: .zero, boundsMax: .zero,
                                 skinned: true, vertices: [Model3D.Vertex](repeating: v, count: 5),
                                 indices: [0, 1, 2, 2, 3, 4])
        let pm = PuppetModel.fromModel3D(Model3D(meshes: [mesh0, mesh1]))
        XCTAssertEqual(pm.vertices.count, 65533 + 5)
        // tri0 = 65533+{0,1,2} = 65533/65534/65535 → 전부 피팅(보존);
        // tri1 = 65533+{2,3,4} → 65536 초과 → 통째로 드롭(종전은 65535,0,0 클램프로 손상).
        XCTAssertEqual(pm.indices, [65533, 65534, 65535])
    }

    /// V0013 vSize 프로브: z-flag 가 우연히 %52==0 이면 종전엔 그것을 vSize 로 오인해 모델 전체 드롭.
    /// 인덱스 블롭 검증으로 오탐 후보를 제외하고 진짜 vSize 를 찾는다.
    func testV0013ProbeSkipsFalsePositiveVSizeCandidate() throws {
        var d = Data("MDLV0013".utf8)
        d.append(Data(repeating: 0, count: 13))           // 13B 헤더
        cstr("materials/x.json", into: &d)
        u(52, into: &d)                                   // z 오탐 후보(%52==0, >0, 피팅)
        u(7, into: &d); u(3, into: &d)                    // 잡 필드(프로브 건니뜀)
        u(104, into: &d)                                  // 진짜 vSize = 정점 2개 × 52B
        for i in 0..<2 {
            f(Float(i), into: &d); f(0, into: &d); f(0, into: &d)         // pos
            u(0, into: &d); u(0, into: &d); u(0, into: &d); u(0, into: &d) // bones
            f(1, into: &d); f(0, into: &d); f(0, into: &d); f(0, into: &d) // weights
            f(0.5, into: &d); f(0.5, into: &d)                             // uv
        }
        u(6, into: &d)
        for i: UInt16 in [0, 1, 0] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        let pm = try XCTUnwrap(PuppetModel.parse(d), "z-flag 오탐 후보를 제외하고 진짜 vSize 착지")
        XCTAssertEqual(pm.vertices.count, 2)
        XCTAssertEqual(pm.indices, [0, 1, 0])
    }

    // MARK: - 무회귀: 기존 6바이트 트레일러

    /// 종전 '6바이트 구분자' 무회귀: 전부 0 인 트레일러는 정식 파스로도 정확히 6B(v23) 를 소비해
    /// 다중메시 프레이밍이 유지된다(디컴파일 게이트 구조와 바이트 동형 — 작업 1 의 성립 조건).
    func testAllZeroTrailerStillSixBytesRegression() throws {
        var d = makeHeader("MDLV0023", 3)
        for mat in ["materials/a.json", "materials/b.json", "materials/c.json"] {
            appendMesh(&d, material: mat)
            d.append(Data(repeating: 0, count: 6))        // 각 메시 뒤 6B(마지막 메시 포함)
        }
        d.append(0)
        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.meshes.map(\.material), ["materials/a.json", "materials/b.json", "materials/c.json"])
        XCTAssertTrue(m.meshes.allSatisfy { $0.trailer == nil }, "전부 0 트레일러는 노출하지 않음(nil)")
    }
}
