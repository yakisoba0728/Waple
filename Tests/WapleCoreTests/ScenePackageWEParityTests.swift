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
        // **경계 네 개를 값으로 못 박는다** — CRT 의 빠른 경로가 `lea eax,[rcx-0x41] ; cmp eax,0x19 ; ja`
        // 라 접히는 구간은 `0x41..0x5A`(`'A'..'Z'`) **닫힌 구간**이다. 바깥 이웃 `@`(0x40) ·
        // `[`(0x5B) 는 그대로여야 한다.
        // [2026-08-21 신설] 돌연변이 검증에서 상한을 `0x5A`→`0x59` 로 바꿔도 **아무 테스트도 안
        // 깨졌다**(39건 중 0건 실패). 무효한 돌연변이가 아니라 `'Z'` 를 쓰는 케이스가 없었던 것 —
        // 즉 테스트가 약했다. 그래서 네 경계를 여기 박는다.
        XCTAssertEqual(ScenePackage.asciiLowercased("A"), "a", "하한 0x41")
        XCTAssertEqual(ScenePackage.asciiLowercased("Z"), "z", "상한 0x5A")
        XCTAssertEqual(ScenePackage.asciiLowercased("@"), "@", "0x40 은 접히지 않는다")
        XCTAssertEqual(ScenePackage.asciiLowercased("["), "[", "0x5B 은 접히지 않는다")
        XCTAssertEqual(ScenePackage.asciiLowercased("ABCXYZ[@"), "abcxyz[@")
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

    // MARK: - §2.1 프레이밍 — 종단 조건과 오프셋 기준을 **값으로** 잠근다
    //
    // 아래 넷은 2026-08-21 에 로더(`0x140276700`)를 `.pdata` 함수 시작에서 **선형으로** 다시 떠서
    // 확정한 사실이다. 문서 §2.1·§2.3 이 산문으로만 적고 있던 것을 테스트로 옮긴다.

    /// **오프셋 기준은 파일 선두가 아니라 데이터 섹션 선두다.** 로더는 TOC 를 다 읽은 뒤
    /// `0x140276b4d call 0x14004a840`(tellg) 로 현재 위치를 재고,
    /// `0x140276b63 add dword [rax+0x30], edx` 로 **전 엔트리의 offset 에 그 값을 더한다**.
    ///
    /// 손으로 바이트를 짓는 이유: `ScenePackageTests.makePkg` 는 오프셋을 스스로 계산하므로
    /// 기준이 바뀌어도 자기 자신과는 늘 맞는다. 여기서는 TOC 길이를 **손으로 세어** 못 박는다.
    func testEntryOffsetsAreRelativeToDataSectionStart() throws {
        let ver = Array("PKGV0023".utf8)
        let n0 = Array("a.txt".utf8), n1 = Array("b.txt".utf8)
        let d0 = Data("AAAA".utf8), d1 = Data("BB".utf8)
        var out = i32(ver.count) + ver + i32(2)
        out += i32(n0.count) + n0 + i32(0) + i32(d0.count)
        out += i32(n1.count) + n1 + i32(d0.count) + i32(d1.count)
        // 헤더 4+8+4 = 16, 엔트리 둘 (4+5+4+4) × 2 = 34 → 데이터 섹션은 파일 오프셋 50 에서 시작한다.
        XCTAssertEqual(out.count, 50, "TOC 길이 계산이 바뀌었다 — 아래 단언의 전제가 무너진다")
        out += [UInt8](d0) + [UInt8](d1)

        let p = try ScenePackage.parse(Data(out))
        // 표에 적힌 offset 은 **가공하지 않은 원문**이다(데이터 섹션 상대).
        XCTAssertEqual(p.entries.map(\.offset), [0, 4])
        // 그런데 실제로 잘라 오는 바이트는 파일 오프셋 50·54 다.
        XCTAssertEqual(p.data(for: "a.txt"), d0)
        XCTAssertEqual(p.data(for: "b.txt"), d1)
        // 기준이 파일 선두였다면 `a.txt`(offset 0, size 4)는 파일 첫 4바이트(= 매직 길이 i32)를
        // 돌려줬을 것이다. 그렇지 않음을 함께 못 박는다.
        XCTAssertNotEqual(p.data(for: "a.txt"), Data(out.prefix(4)))
    }

    /// `entryCount == 0` 은 **빈 패키지로 성공**이다 — `0x140276992 cmp dword [rbp+0x77], r15d` /
    /// `0x140276996 jle 0x140276b46` 가 엔트리 표를 통째로 건너뛰고 그대로 dataBase 계산으로 간다
    /// (반환값 레지스터 `esi` 는 `0x140276b6e mov esi, r15d` 로 0 = 성공).
    func testZeroEntryCountParsesAsEmptyPackage() throws {
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([]))
        XCTAssertTrue(p.entries.isEmpty)
        XCTAssertNil(p.data(for: "scene.json"))
    }

    /// **의도적 이탈.** 같은 `jle` 가 **음수** entryCount 도 "빈 패키지 성공" 으로 보낸다(부호 있는
    /// 비교다). Waple 의 `i32` 는 부호 없이 읽어 `0xFFFFFFFF` 를 4,294,967,295 로 만들고
    /// `count <= maxEntries` 에서 거부한다. 어느 쪽이든 엔트리는 0개고, Waple 은 **에러로 끊는다**.
    /// 실물 표본에서 음수 count 는 관측되지 않았다(워크샵 161 pkg 파스 오류 0건).
    func testNegativeEntryCountIsRejectedUnlikeWE() {
        let ver = Array("PKGV0023".utf8)
        let out = i32(ver.count) + ver + [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try ScenePackage.parse(Data(out))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    /// **의도적 이탈 — 종단 조건.** WE 의 엔트리 루프는 `r12d` 를 0 부터 세어 `entryCount` 까지 도는
    /// **고정 횟수 루프**다(`0x1402769a0 mov r12d, r15d` … `0x140276b33 inc r12d` /
    /// `0x140276b3c cmp r12d, dword [rbp+0x77]` / `0x140276b40 jl 0x1402769a3`). "빈 이름이면 끝" 같은
    /// 센티널이 **없고**, 루프 어디에도 스트림 상태 검사가 없다 — 잘린 파일이면 읽기가 실패한 채로
    /// 남은 스택 값을 그대로 엔트리로 쌓고 **0(성공)** 을 돌려준다.
    /// Waple 은 경계를 넘는 순간 `malformed` 로 끊는다. 이 쪽이 엄격하다.
    func testTruncatedEntryTableIsRejectedUnlikeWE() {
        let ver = Array("PKGV0023".utf8)
        let nm = Array("a.txt".utf8)
        // count=2 라고 선언하고 엔트리 하나 분량만 준다.
        var out = i32(ver.count) + ver + i32(2)
        out += i32(nm.count) + nm + i32(0) + i32(1)
        out += [0x41]
        XCTAssertThrowsError(try ScenePackage.parse(Data(out))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    /// **의도적 이탈 — 상한 위반의 처리.** WE 의 길이 접두 문자열 리더(`0x140060720`)는
    /// `0x140060752 cmp eax, ebx` / `0x140060754 jbe` 가 **무부호** 비교이고, 초과하면
    /// `0x140060756`–`0x14006076c` 가 문자열을 **빈 것으로 만들고 그대로 반환**한다 —
    /// 스트림에서 **한 바이트도 먹지 않는다**. 엔트리 이름의 상한 `0x800`(`0x1402769bb`)도 같은
    /// 리더가 아니라 호출부에서 같은 모양으로 처리한다(`0x1402769c2`–`0x1402769d6` 가 이름을 빈
    /// 문자열로 만들고 `0x1402769d6 jmp 0x140276a63` 로 **이름 바이트를 안 먹은 채** offset/size
    /// 읽기로 간다). 곧 WE 는 그 뒤 파스가 통째로 밀린 채 계속 간다(방어라기보다 버그다).
    /// Waple 에는 `0x800` 상한 자체가 없고, 선언 길이가 버퍼를 넘는 순간 `malformed` 로 끊는다 —
    /// 결과적으로 더 엄격하다.
    func testOversizeEntryNameLengthIsRejectedUnlikeWE() {
        let ver = Array("PKGV0023".utf8)
        var out = i32(ver.count) + ver + i32(1)
        out += i32(0x801) + Array(repeating: UInt8(0x61), count: 8) + i32(0) + i32(0)
        XCTAssertThrowsError(try ScenePackage.parse(Data(out))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    // MARK: - §10 쓰는 쪽(`bin/wallpaperui.exe`)에서 확정한 것
    //
    // 아래 셋은 2026-08-21(2차)에 **패커**를 뜯어 확정한 사실을 잠근다. VA 는 전부
    // `bin/wallpaperui.exe` 다 — `wallpaper64.exe` 와 imagebase 가 같으므로 기계 대조는
    // `va_citations.py --also "$WE_ROOT/bin/wallpaperui.exe"` 로 재야 한다(§10 머리말).

    /// **의도적 이탈 — 음수 size.** 패커에 들어가는 레코드의 크기는 파일 상태 조회
    /// (`bin/wallpaperui.exe 0x1408e72b0`)가 준 u64 를 **i32 로 자른** 값이고
    /// (CLI `0x1401333aa` · UI `0x14020a3e5`), 조회가 실패하면 두 호출부 모두 `-1` 을 들고 나온다
    /// (CLI `0x14000ee71` · UI `0x14020a3cf`). 패커의 삭제 조건은 `== 0`(`0x14020a7d1`)이라
    /// `-1` 은 살아남아 `0xFFFFFFFF` 로 기록된다 — 곧 **쓰는 쪽이 실제로 만들 수 있는 값**이다.
    ///
    /// WE 읽는 쪽은 그 엔트리 **하나만** "없음" 으로 본다(`wallpaper64.exe 0x14027412a` 의 `jle`
    /// 가 0 과 음수를 같이 잡는다). Waple 은 **컨테이너 전체를 `malformed`** 로 끊는다 —
    /// `i32` 를 부호 없이 읽으므로 `0xFFFFFFFF` 는 4,294,967,295 이고 잘린 파일과 구별되지 않기
    /// 때문이다(`testNegativeEntryCountIsRejectedUnlikeWE` 와 같은 이유의 같은 선택).
    /// 도달 미관측: 워크샵 161 pkg · 19,777 엔트리 파스 오류 0건, 최대 단일 pkg 0.66 GiB.
    func testNegativeEntrySizeIsRejectedUnlikeWE() {
        let ver = Array("PKGV0023".utf8)
        let nm = Array("a.txt".utf8)
        var out = i32(ver.count) + ver + i32(1)
        out += i32(nm.count) + nm + i32(0) + i32(-1)    // size = 0xFFFFFFFF
        out += [0x41, 0x42]                              // 데이터 섹션은 멀쩡히 있다
        XCTAssertThrowsError(try ScenePackage.parse(Data(out)),
                             "WE 는 이 엔트리만 버리고 계속 간다 — Waple 은 의도적으로 더 엄격하다") { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
        // 대조군: 같은 바이트에서 size 만 정상이면 통과한다(거부 사유가 size 라는 것을 못 박는다).
        var ok = i32(ver.count) + ver + i32(1)
        ok += i32(nm.count) + nm + i32(0) + i32(2)
        ok += [0x41, 0x42]
        XCTAssertEqual(try ScenePackage.parse(Data(ok)).data(for: "a.txt"), Data([0x41, 0x42]))
    }

    /// **`assemble` 의 오프셋 규약은 WE 패커와 같다** — 0 에서 시작하는 크기 누적합이고
    /// 간극·정렬·패딩이 없다(`bin/wallpaperui.exe 0x14020a85d` 초기화 · `0x14020ab4b` 누적).
    /// 그래서 `parse(assemble(...))` 왕복이 바이트를 그대로 돌려준다.
    func testAssembleOffsetsAreCumulativeLikeWEPacker() throws {
        let a = Data("AAAA".utf8), b = Data("BB".utf8), c = Data("CCCCCCC".utf8)
        let pkg = ScenePackage.assemble([("a.txt", a), ("b.txt", b), ("c.txt", c)])
        XCTAssertEqual(pkg.entries.map(\.offset), [0, 4, 6], "누적합이 아니면 실패해야 한다")
        XCTAssertEqual(pkg.entries.map(\.size), [4, 2, 7])
        // 오프셋 = 앞선 크기의 합 — 간극이 있으면 이 항등식이 깨진다.
        var running = 0
        for e in pkg.entries {
            XCTAssertEqual(e.offset, running)
            running += e.size
        }
        XCTAssertEqual(pkg.data(for: "b.txt"), b)
        XCTAssertEqual(pkg.data(for: "c.txt"), c)
    }

    /// **`assemble` 은 0바이트 엔트리를 일부러 남긴다 — WE 패커와 다르다.**
    /// 패커는 쓰기 직전 `size == 0` 레코드를 벡터에서 지우고(`bin/wallpaperui.exe 0x14020a7d1`
    /// 비교, 압축 루프 `0x14020a7db` - `0x14020a824`) 남은 게 없으면 실패한다(`0x14020a83e`).
    /// 곧 WE 가 만든 pkg 에 0바이트 엔트리는 **구조적으로 없다.** 그런데 `assemble` 은 파리티
    /// 도구가 아니라 **테스트 스캐폴**이라 그것을 흉내 내면 안 된다 — 흉내 내는 순간
    /// `testZeroSizeBlobEntryReadsAsMissing` 이 잴 것을 잃는다. 이 테스트가 그 선택을 못 박는다.
    func testAssembleKeepsZeroSizeEntriesUnlikeWEPacker() {
        let pkg = ScenePackage.assemble([("empty.json", Data()), ("real.json", Data("R".utf8))])
        XCTAssertEqual(pkg.entries.map(\.name), ["empty.json", "real.json"],
                       "0바이트 엔트리를 버리면 §7.5 잠금이 무의미해진다")
        XCTAssertEqual(pkg.entries.first?.size, 0)
        XCTAssertNil(pkg.data(for: "empty.json"), "표에는 남지만 조회에서는 탈락한다(§7.5)")
        // 빈 목록도 그대로 빈 패키지다 — 패커라면 "Pkg file list empty" 로 실패할 자리다.
        XCTAssertTrue(ScenePackage.assemble([]).entries.isEmpty)
    }
}
