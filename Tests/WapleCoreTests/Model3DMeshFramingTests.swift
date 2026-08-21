import XCTest
import simd
@testable import WapleCore

/// T11 D3/D4(2026-08-21) 회귀 핀 — 메시 헤더 여분 u32 는 **탐색이 아니라 gateWord bit1 이 결정**하고,
/// MDLS 본 개수 상한은 100,000 이 아니라 **128** 이다.
///
/// 근거는 wallpaper64.exe(imagebase 0x140000000) 모델 로더 `0x140261880` 어셈블리 직접 대조:
///   0x140261992 `test al, 2` / 0x140261994 `je 0x1402619a6` / 0x14026199b `call 0x14009c560`
///     → gateWord bit1 이 설 때만 u32 **한 번** 더. 루프가 아니라 분기라 2개는 발생 불가.
///   0x140262501 `cmp eax, 0x80` / 0x140262506 `jbe 0x14026250c` / 0x14026250a `int 0x29`
///     → 본 개수 128 초과는 __fastfail(프로세스 즉사).
/// 상세 인용은 `Model3DFormat.extraMeshHeaderWords` / `Model3DFormat.maxBoneCount` 주석에 있다.
final class Model3DMeshFramingTests: XCTestCase {
    // MARK: - 바이트 빌더 (Model3DTrailerSkeletonTailTests 와 동일 규약)

    private func f(_ v: Float, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u(_ v: UInt32, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func cstr(_ s: String, into d: inout Data) { d.append(Data(s.utf8)); d.append(0) }

    /// V0016 단일 메시 모델. AABB 없음 + per-mesh formatFlag 있음 + 트레일러 없음이라
    /// 메시 헤더가 `material | gate | [여분] | flag | vSize` 로 최단이다 — 프레이밍 핀에 최적.
    /// 정점은 flag 0x09(stride 20 = pos 3f + uv 2f) 3개, 인덱스는 u16 [0,1,2].
    private func makeV16(gateWord: UInt32, extraWord: UInt32?) -> Data {
        var d = Data("MDLV0016".utf8)
        d.append(0)
        u(0x09, into: &d)                 // 헤더 formatFlag
        u(1, into: &d)                    // skinCount
        u(1, into: &d)                    // meshCount
        cstr("materials/a.json", into: &d)
        u(gateWord, into: &d)
        if let e = extraWord { u(e, into: &d) }
        u(0x09, into: &d)                 // per-mesh formatFlag → stride 20
        u(3 * 20, into: &d)               // vSize
        for i in 0..<3 {
            f(Float(i), into: &d); f(1, into: &d); f(2, into: &d)   // pos (v0 의 x 는 0)
            f(0.25, into: &d); f(0.5, into: &d)                     // uv
        }
        u(6, into: &d)                    // iSize
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }

    private func appendBones(_ d: inout Data, count: Int, declared: UInt32? = nil) {
        d.append(Data("MDLS0004".utf8)); d.append(0)
        u(0, into: &d)                                  // nextOffset(더미)
        u(declared ?? UInt32(count), into: &d)          // 본수
        for i in 0..<count {
            cstr("bone\(i)", into: &d)
            u(0, into: &d)                              // flags
            var parent = Int32(i == 0 ? -1 : i - 1); withUnsafeBytes(of: &parent) { d.append(contentsOf: $0) }
            u(64, into: &d)                             // 행렬 크기
            for col in 0..<4 {
                for row in 0..<4 { f(col == row ? 1 : 0, into: &d) }
            }
            d.append(0)                                 // props ""
        }
    }

    // MARK: - D3: gateWord bit1 이 여분 u32 를 결정한다

    func testExtraMeshHeaderWordsIsDecidedByGateBit1() {
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 0), 0)
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 1), 0, "bit0 은 인덱스 폭 — 여분과 무관")
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 2), 1, "Kirby_puppet mesh1 실물값")
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 3), 1)
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 0xFFFF_FFFD), 0, "bit1 만 본다")
        XCTAssertEqual(Model3DFormat.extraMeshHeaderWords(gateWord: 0xFFFF_FFFF), 1)
    }

    /// bit1=1 이면 여분 u32 를 정확히 1개 소비하고 그 뒤부터 정상 프레이밍이다.
    func testGateBit1SetConsumesExactlyOneExtraWord() throws {
        let m = try XCTUnwrap(Model3D.parse(makeV16(gateWord: 2, extraWord: 0xDEAD_BEEF)),
                              "bit1=1 + 여분 u32 1개는 정상 프레이밍")
        XCTAssertEqual(m.meshes.count, 1)
        XCTAssertEqual(m.meshes[0].vertices.count, 3)
        XCTAssertEqual(m.meshes[0].material, "materials/a.json")
        XCTAssertEqual(m.meshes[0].indices, [0, 1, 2])
        XCTAssertEqual(m.meshes[0].vertices[2].position, SIMD3(2, 1, 2))
    }

    /// bit1=0 인데 여분 u32 가 끼어 있으면 **거부**다. 종전 `probe: for extra in 0...2` 는
    /// extra=1 프레이밍이 정합하니 조용히 성공했다 — 규칙(0x140261992 `test al,2`)을 무시한 오탐이다.
    func testGateBit1ClearRejectsStrayExtraWord() {
        XCTAssertNil(Model3D.parse(makeV16(gateWord: 0, extraWord: 0xDEAD_BEEF)),
                     "bit1=0 이면 여분 u32 를 읽지 않는다 — 탐색으로 주워 담으면 안 된다")
    }

    /// 역방향: bit1=1 인데 여분 u32 가 없으면 역시 거부다(종전 탐색은 extra=0 으로 통과).
    func testGateBit1SetWithoutExtraWordRejected() {
        XCTAssertNil(Model3D.parse(makeV16(gateWord: 2, extraWord: nil)),
                     "bit1=1 이면 여분 u32 를 반드시 읽는다")
    }

    // MARK: - D4: 본 개수 상한 128

    func testBoneCountAtEngineCapParses() throws {
        var d = makeV16(gateWord: 0, extraWord: nil)
        appendBones(&d, count: Model3DFormat.maxBoneCount)
        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertEqual(m.bones.count, 128, "0x140262506 `jbe` — 128 은 **통과**(이하)")
        XCTAssertEqual(m.meshes.count, 1)
    }

    /// 129 본은 엔진이 `int 0x29`(0x14026250a)로 즉사하는 입력이다 — 실물로 존재할 수 없다.
    /// Waple 은 죽지 않고 스켈레톤만 버린다(정적 메시로 렌더 가능).
    func testBoneCountAboveEngineCapDropsSkeletonButKeepsMeshes() throws {
        var d = makeV16(gateWord: 0, extraWord: nil)
        appendBones(&d, count: 1, declared: 129)
        let m = try XCTUnwrap(Model3D.parse(d), "본 거부가 모델 전체를 버려선 안 된다")
        XCTAssertTrue(m.bones.isEmpty, "128 초과 → 스켈레톤 드롭")
        XCTAssertEqual(m.meshes.count, 1)
        XCTAssertEqual(m.meshes[0].vertices.count, 3)
    }

    /// 폭주 카운트(매직 스캔 오탐이 블롭 한복판에 착지했을 때의 전형)도 같은 문에서 잘린다.
    /// 종전 `< 100_000` 은 이 값을 통과시키고 본 레코드 루프를 돌았다.
    func testRunawayBoneCountRejected() throws {
        var d = makeV16(gateWord: 0, extraWord: nil)
        appendBones(&d, count: 1, declared: 99_999)
        let m = try XCTUnwrap(Model3D.parse(d))
        XCTAssertTrue(m.bones.isEmpty)
    }

    // MARK: - 실물 회귀: 동봉 .mdl 전건 파스

    /// 동봉 `Sources/WapleRender/Resources/WEAssets` 아래 `.mdl` 전건이 결정론적 프레이밍으로
    /// 여전히 파스되는지 본다. `WAPLE_WE_ASSETS` 로 추가 루트(예: WE 설치본)를 붙일 수 있다.
    func testAllBundledMDLFilesStillParse() throws {
        let roots = Self.mdlSearchRoots()
        var files: [URL] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where u.pathExtension.lowercased() == "mdl" { files.append(u) }
        }
        guard !files.isEmpty else { throw XCTSkip("동봉 .mdl 을 못 찾았다(루트: \(roots.map(\.path)))") }

        // 동봉 WEAssets 만으로도 2개(camera/sphere)다 — 0·1 이면 탐색 경로가 깨진 것이니 조용히
        // 통과시키지 않는다. 실측(2026-08-21): 동봉 2 + WE 2.8.42 설치본 28 = 30파일 47메시 전건 파스,
        // gateWord 는 47메시 전부 0(= 여분 u32 0개) — 종전 탐색과 바이트 동일한 프레이밍이다.
        XCTAssertGreaterThanOrEqual(files.count, 2, "탐색 루트: \(roots.map(\.path))")
        var failures: [String] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let raw = try? Data(contentsOf: url) else { failures.append("\(url.lastPathComponent): 읽기 실패"); continue }
            guard let m = Model3D.parse(raw) else { failures.append("\(url.path): 파스 nil"); continue }
            XCTAssertFalse(m.meshes.isEmpty, "\(url.lastPathComponent): 메시 0")
            for mesh in m.meshes {
                XCTAssertFalse(mesh.vertices.isEmpty, "\(url.lastPathComponent): 정점 0")
                XCTAssertFalse(mesh.material.isEmpty, "\(url.lastPathComponent): 머티리얼 빈 문자열")
                XCTAssertEqual(mesh.indices.count % 3, 0, "\(url.lastPathComponent): 트라이앵글 리스트")
                if let mx = mesh.indices.max() {
                    XCTAssertLessThan(Int(mx), mesh.vertices.count, "\(url.lastPathComponent): 인덱스 범위")
                }
            }
            // D4 실물 확인: 엔진이 fastfail 하는 129본 이상은 실물에 존재할 수 없다.
            XCTAssertLessThanOrEqual(m.bones.count, Model3DFormat.maxBoneCount,
                                     "\(url.lastPathComponent): 본 \(m.bones.count) — 엔진 상한 초과")
        }
        XCTAssertTrue(failures.isEmpty, "동봉 .mdl 파스 실패 \(failures.count)건: \(failures)")
    }

    /// `.mdl` 을 찾을 루트들. 리눅스 시임 하니스는 테스트 소스를 심링크로 끌어가므로
    /// `#filePath` 를 한 번 풀고 나서 리포 루트를 위로 올라가며 찾는다.
    private static func mdlSearchRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        let here = (try? fm.destinationOfSymbolicLink(atPath: #filePath)) ?? #filePath
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
            if fm.fileExists(atPath: cand.path) { roots.append(cand); break }
            dir = dir.deletingLastPathComponent()
        }
        if let extra = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !extra.isEmpty,
           fm.fileExists(atPath: extra) {
            roots.append(URL(fileURLWithPath: extra))
        }
        return roots
    }
}
