import XCTest
@testable import WapleCore

/// `docs/re/package-format.md` §7 의 갭 5건이 **실제로 닫혔는지**, 그리고 닫지 **않기로 한**
/// 이탈이 우연이 아니라 의도인지 못 박는다.
///
/// 왜 별도 파일인가: `ScenePackageTests` 는 컨테이너 파싱의 형식 계약을 재고,
/// 여기는 **WE 로더와의 동치/이탈**을 잰다. 두 축이 섞이면 "WE 는 이렇게 한다" 주장이
/// 형식 회귀 테스트 사이에 묻힌다. 각 테스트 주석에 근거 VA 와 동봉 도달 수치를 적는다.
///
/// 이 파일은 리포에 **파일을 남기지 않는다** — `.pkg` 는 메모리에서 합성하고, 디스크가 필요한
/// 마운트 결정 테스트만 `NSTemporaryDirectory()` 아래에 짓고 곧바로 지운다
/// (`check_stray_artifacts.py` 규약).
final class ScenePackageWEParityTests: XCTestCase {

    // MARK: - 스캐폴

    private func makeTemp() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-pkg-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 프로젝트 폴더 하나를 짓는다. `files` 의 값이 빈 문자열이면 0바이트 파일이 된다.
    @discardableResult
    private func writeFolder(_ root: URL, _ name: String, files: [String: String]) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (n, body) in files {
            try Data(body.utf8).write(to: folder.appendingPathComponent(n))
        }
        return folder
    }

    // MARK: - §7.1 마운트 대상은 `file` 이 정한다 (심각도 고)

    /// WE §6 표 1행. `file` 이 디스크에 있으면 그것이 **단독 결정자**다 — 확장자가 `.pkg` 가
    /// 아니면 폴더 마운트(`0x14010e1d1`–`0x14010e20c`).
    func testDeclaredJSONMountsDirectory() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "plain", files: ["scene.json": "{}"])
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "scene.json"),
                       .directory)
    }

    /// WE §6 표 2행 — **이 리포의 회귀였다.** 잔존 `scene.pkg` 가 있어도 선언된 `scene.json` 이
    /// 실재하면 WE 는 게이트 ③(`is_regular_file`, `0x14011e34d`)에서 빠져 폴더를 마운트한다.
    /// 종전 Waple 은 `pkgURL(in:)` 이 파일 존재만 보고 pkg 를 열어 **다른 씬을 그렸다**.
    func testStalePackageDoesNotOverrideExistingDeclaredFile() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "stale", files: ["scene.json": "{}"])
        try ScenePackageTests.makePkg([("scene.json", Data("{}".utf8))])
            .write(to: folder.appendingPathComponent("scene.pkg"))
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "scene.json"),
                       .directory,
                       "선언된 file 이 실재하면 .pkg 를 찾아보지도 않는다(0x14011e34d)")
    }

    /// WE §6 표 3행 + §7.1 2행 — **적용 실패였던 자리.** `file` 이 없으면 stem 을 `.pkg` 로 바꿔
    /// 본다(`replace_extension("pkg")` `0x14011e368`, 존재 검사 `0x14011e3ae`). 이름이 `scene.*`
    /// 일 필요가 없다는 게 요점이다 — 설치본에 `techno.json` `ricepod.json` `audiophile.json`
    /// `fantasticcar.json` `gifscene.json` 5건이 실재한다.
    func testMissingDeclaredFileFallsBackToSameStemPackage() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "techno", files: [:])
        let pkg = folder.appendingPathComponent("techno.pkg")
        try ScenePackageTests.makePkg([("techno.json", Data("{}".utf8))]).write(to: pkg)

        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "techno.json"),
                       .package(pkg))
        // 종전 선택자는 이 자리에서 nil 이었다 — 그래서 폴더 마운트로 떨어져 `.noScene` 이 났다.
        XCTAssertNil(ScenePackage.legacyPackageURL(in: folder),
                     "이름이 scene.pkg/gifscene.pkg 가 아니면 종전 선택자는 못 찾는다")
    }

    /// `file` 이 명시적으로 `.pkg` 면 그대로 연다 — WE 는 `.json` 을 **찾아보지도 않는다**
    /// (마운트 디스패처 2번 분기 `0x14010e14d`–`0x14010e18a`).
    ///
    /// 이름을 `scene.pkg` 가 아니라 `techno.pkg` 로 두는 이유: `scene.pkg` 면 하위호환 폴백이
    /// 어차피 같은 답을 내서 **이 테스트가 물지 않는다**(종전 선택자로 되돌려도 통과한다).
    func testDeclaredPackageIsOpenedDirectly() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "declared-pkg", files: ["techno.json": "{}"])
        let pkg = folder.appendingPathComponent("techno.pkg")
        try ScenePackageTests.makePkg([("techno.json", Data("{}".utf8))]).write(to: pkg)
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "techno.pkg"),
                       .package(pkg),
                       "선언된 .pkg 는 같은 stem 의 .json 이 옆에 있어도 그대로 열린다")
    }

    /// 확장자 판정은 **바이트별 ASCII 소문자화**다(`0x140053f80` → `0x140054262`–`0x140054276`).
    /// `TECHNO.PKG` 도 패키지로 잡혀야 한다(위와 같은 이유로 `scene.*` 이름을 피한다).
    func testDeclaredPackageExtensionIsASCIICaseInsensitive() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "upper-pkg", files: [:])
        let pkg = folder.appendingPathComponent("TECHNO.PKG")
        try ScenePackageTests.makePkg([("techno.json", Data("{}".utf8))]).write(to: pkg)
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "TECHNO.PKG"),
                       .package(pkg))
    }

    /// 게이트 ②(`0x14011e880`: json 에 **string** `dependency` 가 있으면 `.pkg` 재작성을 막는다).
    /// 관측 가능하려면 pkg 이름이 `scene.pkg`/`gifscene.pkg` 가 **아니어야** 한다 — 그 두 이름은
    /// 아래 하위호환 폴백이 어차피 집어내기 때문이다(그 관대함은 의도다, 다음 테스트 참조).
    func testDependencyBlocksPackageRewrite() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "dep", files: [:])
        try ScenePackageTests.makePkg([("techno.json", Data("{}".utf8))])
            .write(to: folder.appendingPathComponent("techno.pkg"))
        XCTAssertEqual(
            ScenePackage.resolveMountSource(folderURL: folder, fileName: "techno.json", hasDependency: true),
            .directory,
            "dependency 가 있으면 WE 는 replace_extension 경로에 들어가지 않는다(0x14011e341)")
    }

    /// **의도적 이탈 ①** — WE 는 `file:"scene.pkg"` 가 없으면 `scene.json` 이 있어도 실패한다
    /// (④가 같은 `scene.pkg` 를 다시 보고 끝난다). Waple 은 폴더를 마운트해 살려낸다.
    /// 더 관대한 쪽이라 무해하고, 종전 동작과도 같다.
    func testMissingDeclaredPackageStillMountsFolder() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "lenient", files: ["scene.json": "{}"])
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "scene.pkg"),
                       .directory)
    }

    /// **의도적 이탈 ②** — `file` 이 없거나 경로 검사에 걸려 결정 근거가 사라졌을 때만 도는
    /// 하위호환 폴백. WE 에는 없다. 종전 Waple 의 유일한 선택자였으므로, 여기서 살려 두는 것이
    /// 무회귀의 핵심이다(선언된 `file` 이 실재하는 경로는 위 `testStalePackage…` 가 이미 막았다).
    func testLegacyProbeStillCoversProjectsWithoutFileKey() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "nofile", files: [:])
        let pkg = folder.appendingPathComponent("gifscene.pkg")
        try ScenePackageTests.makePkg([("gifscene.json", Data("{}".utf8))]).write(to: pkg)
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: nil),
                       .package(pkg))
        // 경로 탈출 시도는 `WallpaperPathSecurity` 가 nil 로 만든다 → 같은 폴백으로 떨어진다.
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "../../etc/passwd"),
                       .package(pkg))
    }

    /// 아무것도 없으면 폴더다(호출자가 `fromDirectory` 로 마운트하고, 거기서 다시 실패한다).
    func testEmptyFolderResolvesToDirectory() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "empty", files: [:])
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "scene.json"),
                       .directory)
    }

    // MARK: - §7.2 확장자 → 타입 유도표

    /// WE 1번 표 `0x140483850` 은 `.json` `.pkg` `.gif` **셋 다** 1 = Scene 이다(`0x14011e7a5`).
    /// `pkg`/`gif` 가 빠져 있어서 `type` 없는 프로젝트가 `.preset` 으로 남았다 — 그러면
    /// RendererFactory 가 렌더러를 못 만들어 "적용해도 아무것도 안 뜬다".
    func testPackageAndGifExtensionsInferScene() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        for name in ["scene.pkg", "SCENE.PKG", "anim.gif", "techno.pkg"] {
            let p = ProjectJSONParser.parse(json: ["file": name], folderURL: folder)
            XCTAssertEqual(p.type, .scene, "\(name)")
        }
    }

    /// 유도는 **`type` 이 없고 `preset`/`dependency` 도 없을 때만** 돈다 — 진짜 프리셋 폴더를
    /// 씬으로 오분류하지 않기 위한 기존 가드다. 확장자 두 개를 더해도 그 가드는 그대로다.
    func testPresetGuardsStillWinOverExtensionInference() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(ProjectJSONParser.parse(json: ["file": "scene.pkg", "preset": ["a": 1]],
                                               folderURL: folder).type, .preset)
        XCTAssertEqual(ProjectJSONParser.parse(json: ["file": "scene.pkg", "dependency": "base"],
                                               folderURL: folder).type, .preset)
        // 선언된 `type` 은 여전히 이긴다 — WE 는 `type` 을 아예 안 읽지만(§5.1) 그 이탈은
        // 워크샵 코퍼스 분류가 통째로 바뀌므로 별도 판단으로 남겼다. `[미해결]`
        XCTAssertEqual(ProjectJSONParser.parse(json: ["type": "web", "file": "scene.pkg"],
                                               folderURL: folder).type, .web)
    }

    // MARK: - §7.3 조회 키 정규화는 ASCII 폴딩이다

    /// WE 는 `'A'..'Z'` 만 접는다(CRT `tolower` 빠른 경로 `0x1402bfb34`–`0x1402bfb3c`).
    /// Swift `.lowercased()` 는 유니코드 전체 매핑이라 더 넓게 접는다.
    func testASCIILowercasingDoesNotFoldNonASCII() {
        XCTAssertEqual(ScenePackage.asciiLowercased("Models/Foo.JSON"), "models/foo.json")
        // 라틴 확장·키릴·그리스: Swift 는 접고 WE 는 안 접는다.
        XCTAssertEqual(ScenePackage.asciiLowercased("\u{00C0}\u{00C9}"), "\u{00C0}\u{00C9}")
        XCTAssertEqual("\u{00C0}\u{00C9}".lowercased(), "\u{00E0}\u{00E9}")
        XCTAssertEqual(ScenePackage.asciiLowercased("\u{0418}"), "\u{0418}")       // Cyrillic И
        XCTAssertEqual(ScenePackage.asciiLowercased("\u{03A3}"), "\u{03A3}")       // Greek Σ
        // 터키어 İ 은 `.lowercased()` 에서 **스칼라가 늘어난다**(i + combining dot).
        XCTAssertEqual(ScenePackage.asciiLowercased("\u{0130}"), "\u{0130}")
        XCTAssertEqual("\u{0130}".lowercased().unicodeScalars.count, 2)
        // UTF-8 연속 바이트가 대문자 범위(0x41~0x5A)와 겹치지 않음도 함께 본다 — 바이트 단위로
        // 접는 구현이므로 멀티바이트 문자가 깨지면 여기서 드러난다.
        XCTAssertEqual(ScenePackage.asciiLowercased("\u{D55C}\u{AE00}A"), "\u{D55C}\u{AE00}a")
    }

    /// 정규화 색인이 **충돌하지 않는지**를 실제 조회로 잰다. 대소문자만 다른 키릴 두 엔트리를
    /// 소문자 먼저 넣는다 — 유니코드 폴딩이면 둘이 같은 키가 되어 먼저 온 것이 이기고
    /// (`ScenePackage.init` 의 `normalizedIndex`), ASCII 폴딩이면 갈린 채로 남는다.
    func testUnicodeCaseCollisionDoesNotHijackNormalizedIndex() throws {
        let lower = Data("LOWER".utf8)
        let upper = Data("UPPER".utf8)
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([
            ("\u{0438}.json", lower),   // и (소문자) — 먼저
            ("\u{0418}.json", upper),   // И (대문자)
        ]))
        // 정확 일치는 당연히 각자를 준다.
        XCTAssertEqual(p.data(for: "\u{0438}.json"), lower)
        XCTAssertEqual(p.data(for: "\u{0418}.json"), upper)
        // 정규화 색인으로만 닿는 질의(`.JSON` 이 exact miss 를 만든다).
        XCTAssertEqual(p.data(for: "\u{0418}.JSON"), upper,
                       "유니코드 폴딩이면 먼저 온 и 엔트리(LOWER)가 가로챈다")
        XCTAssertEqual(p.data(for: "\u{0438}.JSON"), lower)
    }

    /// 역슬래시→슬래시 치환은 WE 에 **없지만** 그대로 둔다 — 정확 일치가 먼저 이긴 뒤의 폴백
    /// 색인이라 히트만 늘리고 뺏지 않는다(§7.3). 이 관대함이 사라지지 않았음을 못 박는다.
    func testBackslashFallbackSurvivesASCIIFolding() throws {
        let model = Data(#"{"material":"materials/Foo.json"}"#.utf8)
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([("Models\\Foo.JSON", model)]))
        XCTAssertEqual(p.data(for: "Models\\Foo.JSON"), model)
        XCTAssertEqual(p.data(for: "models/foo.json"), model)
        XCTAssertEqual(p.data(for: "models\\foo.json"), model)
    }

    // MARK: - §7.4 매직·버전 게이트는 WE 와 **의도적으로** 반대다

    /// WE 는 접두를 **안 본다**(`PKGV` ASCII 리터럴이 바이너리 전역 0건). Waple 은 강제한다 —
    /// 실물 표본이 0개라 "접두가 다른 pkg" 가 가설일 뿐이고, 엄격한 쪽이 신뢰 경계 정책에 맞다.
    /// 되돌리려면 이 테스트를 먼저 지워야 한다.
    func testMagicPrefixIsEnforcedUnlikeWE() {
        for magic in ["XXXX0023", "PKGX0001", "pkgv0001"] {
            XCTAssertThrowsError(try ScenePackage.parse(ScenePackageTests.makePkg([], version: magic)),
                                 magic) { e in
                XCTAssertEqual(e as? ScenePackageError, .malformed)
            }
        }
        // 길이 4 이하면 WE 는 버전 검사조차 건너뛰고 통과시킨다(`0x140276946` `jbe`).
        XCTAssertThrowsError(try ScenePackage.parse(ScenePackageTests.makePkg([], version: "PKGV")))
    }

    /// 반대 방향: WE 는 `atoi(magic+4) > 24` 를 거부하지만(`0x140276964`) Waple 은 받는다.
    /// 프레이밍이 버전 불변이라 상한을 걸면 **파싱 가능한 미래 파일만 잃는다**.
    func testNoVersionCeilingUnlikeWE() {
        for magic in ["PKGV0024", "PKGV0025", "PKGV0100", "PKGV9999"] {
            XCTAssertNoThrow(try ScenePackage.parse(ScenePackageTests.makePkg([], version: magic)), magic)
        }
    }

    // MARK: - §7.5 `size == 0` 엔트리는 "없음"이다

    /// VFS 조회는 해시 히트 뒤에도 `cmp dword [rbx+0x34], 0` / `jle`(`0x14027412a`)로 크기를
    /// 한 번 더 보고 0 이하면 **디스크 폴백**으로 간다. 빈 `Data` 를 성공으로 돌려주면
    /// `probeAssetData` 가 공유 자산 폴백을 건너뛴다.
    func testZeroSizeBlobEntryReadsAsMissing() throws {
        let real = Data("REAL".utf8)
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([
            ("materials/empty.json", Data()),
            ("materials/real.json", real),
        ]))
        // 엔트리 자체는 표에 남는다(파스는 WE 와 같이 진행된다) — 조회에서만 탈락한다.
        XCTAssertEqual(p.entries.map(\.name), ["materials/empty.json", "materials/real.json"])
        XCTAssertEqual(p.entries.first?.size, 0)
        XCTAssertNil(p.data(for: "materials/empty.json"))
        XCTAssertNil(p.data(for: "materials/EMPTY.json"), "정규화 색인 경로도 같아야 한다")
        XCTAssertEqual(p.data(for: "materials/real.json"), real)
    }

    /// **폴더 마운트에는 적용하지 않는다.** WE 의 디렉터리 마운트(`0x1402764d0`)는 엔트리 표를
    /// 만들지 않고 파일을 바로 열므로, 디스크의 진짜 0바이트 파일은 0바이트로 열린다.
    func testZeroByteFileInMountedFolderStillReadsEmpty() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "dir", files: ["scene.json": "{}", "empty.txt": ""])
        let p = try XCTUnwrap(ScenePackage.fromDirectory(folder))
        XCTAssertEqual(p.data(for: "empty.txt"), Data(),
                       "폴더 백엔드는 크기 게이트를 타지 않는다(엔트리 표가 없는 WE 경로와 동형)")
        XCTAssertEqual(p.data(for: "scene.json"), Data("{}".utf8))
    }
}
