import XCTest
import simd
@testable import WapleCore

/// `.mdl` 파서를 **WE 2.8.42 설치본 전수**에 돌려 컨테이너 인구조사를 못박는다.
///
/// 왜 있는가
/// ---------
/// 종전 실물 회귀 핀(`Model3DMeshFramingTests.testAllBundledMDLFilesStillParse`)이 보는 것은
/// 리포에 동봉된 `Sources/WapleRender/Resources/WEAssets` 의 **2파일**뿐이다(v0017 camera,
/// v0023 sphere). 설치본 트리는 `WAPLE_WE_ASSETS` 를 그쪽으로 지정한 하니스에서는 절대 안 걸린다.
/// 그래서 v0004(8) · v0014(15) 라는 **설치본의 대다수 23파일**이 어떤 테스트에도 안 잡혔다 —
/// 매직 화이트리스트에서 통째로 떨어져 기본 3D 프로젝트 8개가 모델 0개로 그려졌던 그 회귀
/// (G-C3-02)를 잡을 그물이 없었다는 뜻이다.
///
/// 여기서는 **분포를 고정한다.** 프레이밍 규칙을 건드리면 이 숫자가 움직이고, 움직인 만큼이
/// 도달 건수다. CI(ubuntu)에는 이 트리가 없으므로 조용히 스킵된다 —
/// `WallpaperCompatibilityCorpusAuditTests` 가 같은 이유로 같은 스킵을 한다.
///
/// 코퍼스: `WE_ROOT`(기본 `/home/user/Waple-wallpaper-source/wallpaper_engine`) 아래 `.mdl` 전부.
/// 2026-08-21 실측 **28파일 45메시**, 전부 고유 파일이고 `MDLS`/`MDLA`/`MDAT`/`MDLE`/`MDMP`
/// 섹션은 **0건**이다(= 이 코퍼스로는 스켈레톤/애니 경로를 실물로 밟을 수 없다. 워크샵 코퍼스 없음).
final class Model3DInstalledCorpusTests: XCTestCase {

    private static func installRoot() -> URL? {
        let path = ProcessInfo.processInfo.environment["WE_ROOT"]
            ?? "/home/user/Waple-wallpaper-source/wallpaper_engine"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func mdlFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en where url.pathExtension.lowercased() == "mdl" {
            out.append(url.standardizedFileURL)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `project.json` 을 가진 최근접 조상 = 프로젝트 루트. 없으면 `assets/`(엔진 자산 트리).
    private static func projectRoot(of mdl: URL, installRoot: URL) -> URL {
        var dir = mdl.deletingLastPathComponent()
        while dir.path.count > installRoot.path.count {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return installRoot.appendingPathComponent("assets", isDirectory: true)
    }

    // MARK: - 인구조사

    /// 28파일 45메시 전건 파스 + 버전/플래그/스킨 분포 고정.
    ///
    /// 버전 분기는 셋 다 엔진 게이트가 정본이다(`Model3DFormat`): AABB v≥17(`0x1402619a6 cmp edi,0x11`),
    /// per-mesh formatFlag v≥15(`0x140261a19 cmp edi,0x0f`), 메시 트레일러 v≥21(`0x140261b61 cmp edi,0x15`),
    /// 섹션 루프 v≥13(`0x140262382 cmp edi,0x0d`). 설치본 4개 버전(0004/0014/0017/0023)은 그 게이트의
    /// 네 조합을 정확히 밟는다: 0004·0014 = 셋 다 없음(0004 는 섹션 루프도 없어 말미 NUL 이 없다),
    /// 0017 = AABB+flag, 0023 = 전부 + 모프.
    func testInstalledCorpusCensus() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE_ROOT 트리 없음 — CI(ubuntu)에는 설치본이 없다") }
        let files = Self.mdlFiles(under: root)
        guard !files.isEmpty else { throw XCTSkip("WE_ROOT 아래 .mdl 0건") }

        // 실측(WE 2.8.42): 28파일. 늘거나 줄면 코퍼스가 바뀐 것이니 조용히 통과시키지 않는다.
        XCTAssertEqual(files.count, 28, "설치본 .mdl 개수")

        var versions: [Int: Int] = [:]
        var meshTotal = 0
        var skinCountHistogram: [Int: Int] = [:]
        var failures: [String] = []

        for url in files {
            let name = url.lastPathComponent
            guard let raw = try? Data(contentsOf: url) else { failures.append("\(name): 읽기 실패"); continue }
            let magic = String(decoding: raw.prefix(8), as: UTF8.self)
            guard let version = Model3DFormat.version(ofMagic: magic) else {
                failures.append("\(name): 매직 \(magic) 거부"); continue
            }
            versions[version, default: 0] += 1
            guard let model = Model3D.parse(raw) else { failures.append("\(url.path): 파스 nil"); continue }

            // 이 코퍼스에는 스켈레톤/애니 섹션이 0건이다 — 매직 스캔이 블롭 한복판을 물면 여기서 걸린다.
            XCTAssertTrue(model.bones.isEmpty, "\(name): MDLS 섹션은 설치본에 없다")
            XCTAssertFalse(model.hasAnimation, "\(name): MDLA 섹션은 설치본에 없다")
            XCTAssertTrue(model.attachments.isEmpty, "\(name): MDAT 섹션은 설치본에 없다")

            meshTotal += model.meshes.count
            for mesh in model.meshes {
                skinCountHistogram[mesh.materials.count, default: 0] += 1
                XCTAssertFalse(mesh.vertices.isEmpty, "\(name): 정점 0")
                XCTAssertEqual(mesh.indices.count % 3, 0, "\(name): 트라이앵글 리스트")
                XCTAssertFalse(mesh.skinned, "\(name): 설치본에 스키닝 메시는 없다")
                // 서브메시가 인덱스 범위를 나눠 갖는 구조가 아니라 메시마다 자기 블롭을 통째로 싣는
                // 다는 증거 — 인덱스가 자기 정점 배열을 빈틈없이 덮는다.
                XCTAssertEqual(Int(mesh.indices.max() ?? 0), mesh.vertices.count - 1,
                               "\(name): maxIndex == vCount-1")
                XCTAssertFalse(mesh.material.isEmpty, "\(name): 머티리얼 빈 문자열")
                XCTAssertTrue(mesh.material.hasPrefix("materials/"), "\(name): \(mesh.material)")
                XCTAssertTrue(mesh.material.hasSuffix(".json"), "\(name): \(mesh.material)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "설치본 .mdl 실패 \(failures.count)건: \(failures)")

        // 버전 분포(실측): 0004 8 · 0014 15 · 0017 1 · 0023 4.
        XCTAssertEqual(versions, [4: 8, 14: 15, 17: 1, 23: 4], "버전 분포")
        XCTAssertEqual(meshTotal, 45, "총 메시 수")
        // 스킨(= 메시당 머티리얼 경로) 분포: 44메시가 1개, audiophile grid.mdl 만 2개.
        XCTAssertEqual(skinCountHistogram, [1: 44, 2: 1], "메시당 머티리얼(스킨) 개수 분포")
    }

    /// 정점 채널 인구조사 — 설치본 45메시가 밟는 formatFlag 는 정확히 4종이고, 각각이
    /// `vertexLayoutTable` 로 산출되는 스트라이드로 정확히 나눠떨어진다.
    ///
    /// | flag | stride | 채널 | 메시 |
    /// |---|---|---|---|
    /// | 0x09 | 20 | pos + TEXCOORD0 f2 | 19 |
    /// | 0x0b | 32 | pos + normal + TEXCOORD0 f2 | 10 |
    /// | 0x0f | 48 | pos + normal + tangent4 + TEXCOORD0 f2 | 10 |
    /// | 0x27 | 56 | pos + normal + tangent4 + **TEXCOORD0 f4**(uv0=.xy, uv1=.zw) | 6 |
    ///
    /// 0x27 은 arsenal `pistols.mdl` 전용이고 모델 옵션 `models/pistols/pistols.json` 이
    /// `"seconduvchannel": true`, 재질이 `"lightmap": 1` 콤보를 켠다 — `.zw` 가 라이트맵 UV 라는
    /// 근거가 자산에 그대로 적혀 있다(`assets/shaders/generic.frag` 의
    /// `texSample2D(g_LightmapMapSampler, v_TexCoord.zw)`).
    func testInstalledCorpusVertexChannelCensus() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE_ROOT 트리 없음") }
        let files = Self.mdlFiles(under: root)
        guard !files.isEmpty else { throw XCTSkip("WE_ROOT 아래 .mdl 0건") }

        var flagHistogram: [UInt32: Int] = [:]
        var normalMeshes = 0, tangentMeshes = 0, uv1Meshes = 0
        var uv1Lo = Float.greatestFiniteMagnitude, uv1Hi = -Float.greatestFiniteMagnitude

        for url in files {
            let name = url.lastPathComponent
            guard let raw = try? Data(contentsOf: url), let model = Model3D.parse(raw) else { continue }
            // 헤더 오프셋 9 의 formatFlag. v≥15 는 메시마다 다시 싣지만 설치본 5파일은 전부 헤더와
            // 같은 값이라(45메시 실측) 이 값을 메시 플래그로 써도 된다 — 아래 채널 단언이 그 전제를
            // 함께 검증한다(채널이 없는데 있다고 보면 값 검사가 깨진다).
            let bytes = [UInt8](raw)
            guard bytes.count > 13 else { continue }
            let flag = UInt32(bytes[9]) | UInt32(bytes[10]) << 8 | UInt32(bytes[11]) << 16 | UInt32(bytes[12]) << 24

            for mesh in model.meshes {
                flagHistogram[flag, default: 0] += 1
                if flag & 0x2 != 0 {                    // a_Normal float3
                    normalMeshes += 1
                    for v in mesh.vertices {
                        // 파일에 그대로 실린 float3 다 — 정규화 포맷이 아니므로 길이 1 은 데이터 규약이다.
                        XCTAssertEqual(simd_length(v.normal), 1, accuracy: 2e-3, "\(name): 법선 단위길이")
                    }
                }
                if flag & 0x4 != 0 {                    // a_Tangent4 float4(w = handedness)
                    tangentMeshes += 1
                    for v in mesh.vertices {
                        XCTAssertEqual(abs(v.tangent.w), 1, accuracy: 1e-3, "\(name): tangent.w = ±1")
                    }
                }
                if flag & 0x20 != 0 {                   // a_TexCoordVec4 → uv1 = .zw
                    uv1Meshes += 1
                    for v in mesh.vertices {
                        uv1Lo = min(uv1Lo, v.uv1.x, v.uv1.y)
                        uv1Hi = max(uv1Hi, v.uv1.x, v.uv1.y)
                    }
                } else {
                    // 채널이 없으면 uv1 은 반드시 (0,0) — 다른 채널을 uv1 로 오독하면 여기서 걸린다.
                    XCTAssertFalse(mesh.vertices.contains { $0.uv1 != .zero }, "\(name): uv1 채널 없음")
                }
            }
        }

        // 실측 분포: 0x09(pos+uv, stride 20) 19메시 · 0x0b(+normal, 32) 10 · 0x0f(+tangent, 48) 10 ·
        // 0x27(TEXCOORD0 을 float4 로, 56) 6 — 넷 다 vertexLayoutTable 로 산출된다.
        XCTAssertEqual(flagHistogram, [0x09: 19, 0x0b: 10, 0x0f: 10, 0x27: 6], "정점 포맷 플래그 분포")
        XCTAssertEqual(normalMeshes, 26)
        XCTAssertEqual(tangentMeshes, 16)
        XCTAssertEqual(uv1Meshes, 6, "uv1(라이트맵) 채널 보유 메시 = pistols 6")
        // 라이트맵 UV 는 아틀라스라 [0,1] 안에 든다(실측 [0.0019, 0.9982]) — 반면 uv0 은 타일링이라
        // 같은 파일에서 [-3.70, 4.71] 까지 나간다. 두 세트를 바꿔 읽으면 이 단언이 먼저 깨진다.
        XCTAssertGreaterThanOrEqual(uv1Lo, 0, "라이트맵 UV 하한")
        XCTAssertLessThanOrEqual(uv1Hi, 1, "라이트맵 UV 상한")
    }

    /// 머티리얼 바인딩 규칙: 메시가 지목하는 것은 **인덱스가 아니라 프로젝트 루트 상대 경로**다.
    /// 설치본 46경로(45메시 + grid.mdl 의 2번째 스킨) 중 45개가 디스크에 실재한다.
    /// 유일한 미스는 배포에서 빠진 에디터 기즈모 재질
    /// (`assets/models/editor/camera/camera.mdl` → `materials/models/editorcamera/editorcamera.json`)
    /// 이고, 그 폴더 자체가 설치본에 없다 — 규칙이 틀린 게 아니라 자산이 없는 것이다.
    func testMaterialPathsResolveAgainstProjectRoot() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE_ROOT 트리 없음") }
        let files = Self.mdlFiles(under: root)
        guard !files.isEmpty else { throw XCTSkip("WE_ROOT 아래 .mdl 0건") }

        var total = 0, resolved = 0
        var misses: [String] = []
        for url in files {
            guard let raw = try? Data(contentsOf: url), let model = Model3D.parse(raw) else { continue }
            let base = Self.projectRoot(of: url, installRoot: root)
            for mesh in model.meshes {
                for path in mesh.materials {
                    total += 1
                    if FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path) {
                        resolved += 1
                    } else {
                        misses.append("\(url.lastPathComponent) → \(path)")
                    }
                }
            }
        }
        XCTAssertEqual(total, 46, "머티리얼 경로 총수(45메시 + grid.mdl 2번째 스킨)")
        XCTAssertEqual(resolved, 45, "프로젝트 루트 상대 경로로 실재하는 재질 수")
        XCTAssertEqual(misses, ["camera.mdl → materials/models/editorcamera/editorcamera.json"],
                       "유일한 미스는 배포에서 빠진 에디터 기즈모 재질이어야 한다")
    }

    /// 섹션 루프 v≥13 게이트의 실물 대응 = **파일 말미 1바이트의 소속이 버전마다 다르다.**
    /// v≥13 은 마지막 바이트가 섹션 루프를 끝내는 빈 cstring 의 NUL 이라 메시 페이로드 밖이고,
    /// v0004 는 섹션 루프 자체가 없어 마지막 인덱스 바이트가 곧 EOF 다
    /// (엔진 근거: `Model3DFormat.hasSections` 주석의 `0x140262382` / `0x1402623ec`).
    ///
    /// 말미 바이트 **값**으로는 못 가른다 — v0004 의 마지막 인덱스 상위바이트도 대개 0 이다.
    /// 대신 **끝 1바이트를 잘라 보면** 갈린다: v≥13 은 잘라도 그대로 파스되고(그 바이트를 아무도
    /// 안 읽는다), v0004 는 인덱스 블롭이 잘려 nil 이 된다.
    func testLastByteBelongsToSectionLoopOnlyForVersion13AndUp() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE_ROOT 트리 없음") }
        let files = Self.mdlFiles(under: root)
        guard !files.isEmpty else { throw XCTSkip("WE_ROOT 아래 .mdl 0건") }

        var withSections = 0, withoutSections = 0
        for url in files {
            let name = url.lastPathComponent
            guard let raw = try? Data(contentsOf: url), raw.count > 1 else { continue }
            let magic = String(decoding: raw.prefix(8), as: UTF8.self)
            guard let version = Model3DFormat.version(ofMagic: magic) else { continue }
            let trimmed = raw.dropLast()
            if Model3DFormat.hasSections(version: version) {
                XCTAssertEqual(raw.last, 0, "\(name)(v\(version)): 섹션 루프 종단 NUL")
                XCTAssertNotNil(Model3D.parse(Data(trimmed)),
                                "\(name)(v\(version)): 말미 NUL 은 메시 페이로드 밖 — 잘라도 파스돼야 한다")
                withSections += 1
            } else {
                // `XCTAssertNil` 은 실패 시 Model3D 전체를 문자열로 덤프한다(11MB 로그를 실제로 봤다).
                // 불리언으로 좁혀서 실패 메시지를 파일명만 남긴다.
                XCTAssertTrue(Model3D.parse(Data(trimmed)) == nil,
                              "\(name)(v\(version)): 마지막 바이트는 인덱스 블롭의 일부 — 자르면 nil 이어야 한다")
                withoutSections += 1
            }
        }
        XCTAssertEqual(withSections, 20, "v≥13 파일 수(0014 15 + 0017 1 + 0023 4)")
        XCTAssertEqual(withoutSections, 8, "v0004 파일 수")
    }
}
