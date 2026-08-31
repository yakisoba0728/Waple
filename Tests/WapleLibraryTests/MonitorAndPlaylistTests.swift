import XCTest
@testable import WapleLibrary

final class MonitorAssignmentStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)   // tearDown 에서 정리($TMPDIR 리터 방지)
        return d
    }

    func testAssignPersistAndReload() {
        let dir = tempDir()
        let s = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertNil(s.assignment(for: "display-1"))
        s.setAssignment("wallpaper-A", for: "display-1")
        s.setAssignment("wallpaper-B", for: "display-2")
        XCTAssertEqual(s.assignment(for: "display-1"), "wallpaper-A")
        // 재로드(영속성)
        let s2 = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertEqual(s2.assignment(for: "display-1"), "wallpaper-A")
        XCTAssertEqual(s2.assignment(for: "display-2"), "wallpaper-B")
        // 해제
        s2.setAssignment(nil, for: "display-1")
        XCTAssertNil(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "display-1"))
    }

    func testCorruptFileFallsBackEmpty() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("monitors.json"))
        let s = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertNil(s.assignment(for: "x"))
        s.setAssignment("a", for: "x")  // 저장 가능해야
        XCTAssertEqual(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "x"), "a")
    }

    func testCorruptFileBackedUpNotClobbered() throws {
        // 종전: 손상 monitors.json 을 try? 로 무시하고 첫 저장이 기본값으로 덮어써 사용자 할당 영구 손실.
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        MonitorAssignmentStore(baseDirectory: dir).setAssignment("a", for: "x")  // 저장 트리거
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("monitors.json.corrupt") }
        XCTAssertEqual(backups.count, 1, "손상 원본이 백업 없이 파괴됨(회귀)")
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage, "손상 원본 바이트 보존")
        XCTAssertEqual(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "x"), "a", "새 데이터는 정상 저장")
    }

    /// P2: 일시적 읽기오류(권한·잠금 등)는 디코드 실패(corrupt)가 아니다 — 원본이 멀쩡할 수 있으므로
    /// corrupt-백업 경로를 타면 안 되고, 다음 save() 가 그 원본을 덮어써서도 안 된다.
    /// ENOENT 가 아닌 읽기오류를 결정적으로 재현하기 위해 파일 자리에 디렉터리를 둔다
    /// (Data(contentsOf:) 가 "Is a directory" 로 실패 — CocoaError.fileReadNoSuchFile 이 아님).
    func testTransientReadErrorDoesNotClobberOrBackup() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let s = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertNil(s.assignment(for: "x"), "읽기실패 시 빈 상태로 시작")
        s.setAssignment("a", for: "x")  // 저장 트리거 — 원본을 덮어쓰면 안 된다

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "원본(디렉터리) 자리가 유지돼야 함")
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        XCTAssertTrue(isDir.boolValue, "일시적 읽기오류로 원본이 덮어써짐(회귀) — 디렉터리 그대로여야 함")

        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("monitors.json.corrupt") }
        XCTAssertTrue(backups.isEmpty, "일시적 읽기오류는 corrupt 오판이 아니므로 백업이 생기면 안 됨")
    }

    /// F252: backupCorruptStoreFile 의 백업 move 가 실패하면 corrupt 플래그는 true 로 남아야 한다.
    /// 종전엔 move 시도 전에 미리 플래그를 내려, move 가 실패해도(원본이 백업되지 않았는데도)
    /// 호출부 save() 가 그대로 덮어쓰고 다음 save() 의 재시도 기회까지 막았다.
    /// moveItem(rename) 실패를 결정적으로 재현하기 위해 디렉터리 쓰기 권한을 제거한다.
    func testBackupFailureLeavesCorruptFlagSetForRetry() throws {
        // root(UID 0)는 권한 비트 검사를 우회해 0o555 디렉터리에도 rename 이 성공한다 — 재현 불가라 skip.
        try XCTSkipIf(getuid() == 0, "root 실행 시 권한 0o555 기반 move 실패 재현 불가")
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        try Data("{ not json".utf8).write(to: url)

        var corrupt = true
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let succeeded = backupCorruptStoreFile(url, &corrupt)

        XCTAssertFalse(succeeded, "move 실패를 호출자에게 알려 save 중단을 가능하게 해야 한다")
        XCTAssertTrue(corrupt, "move 실패 시 플래그가 true 로 남아 다음 save() 가 재시도할 수 있어야 한다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "실패한 백업 시도가 원본을 건드리면 안 된다")
        let backups = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("monitors.json.corrupt") } ?? []
        XCTAssertTrue(backups.isEmpty, "move 가 실패했으므로 백업 파일이 생기면 안 된다")
    }

    /// F252: move 가 성공하면(정상 경로) 플래그는 그대로 false 로 내려가야 한다 — 회귀 방지용 대조.
    func testBackupSuccessClearsCorruptFlag() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        try Data("{ not json".utf8).write(to: url)

        var corrupt = true
        let succeeded = backupCorruptStoreFile(url, &corrupt)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(corrupt, "정상적으로 백업됐으면 플래그를 내려야 한다")
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("monitors.json.corrupt") }
        XCTAssertEqual(backups.count, 1)
    }

    /// 백업 대상 이름이 이미 있어 rename 만 실패하는 조건에서는 atomic write 자체는 가능하다.
    /// 이때 호출자가 백업 실패를 무시하면 손상 원본이 새 JSON 으로 덮여 복구 바이트가 사라진다.
    func testBackupFailureDoesNotAllowCallerToOverwriteCorruptFile() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        let garbage = Data("{ recoverable but invalid json".utf8)
        try garbage.write(to: url)
        let store = MonitorAssignmentStore(baseDirectory: dir, backupCorruptFile: { _, corrupt in
            XCTAssertTrue(corrupt, "손상 파일 로드 뒤 백업 경계를 타야 한다")
            return false
        })

        store.setAssignment("new-value", for: "display")

        XCTAssertEqual(try Data(contentsOf: url), garbage,
                       "백업 실패 시 save 를 중단해 복구 가능한 손상 원본을 보존해야 한다")
        XCTAssertNil(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "display"),
                     "백업되지 않은 원본 위에 새 JSON 을 기록하면 안 된다")
    }
}

final class PlaylistStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)   // tearDown 에서 정리($TMPDIR 리터 방지)
        return d
    }

    func testDefaultsAndPersistence() {
        let dir = tempDir()
        let p = PlaylistStore(baseDirectory: dir)
        XCTAssertFalse(p.enabled)
        XCTAssertEqual(p.intervalMinutes, 30, "기본 30분")
        XCTAssertEqual(p.ids, [])
        XCTAssertFalse(p.shuffle, "기본 순차(무회귀)")
        p.enabled = true
        p.intervalMinutes = 5
        p.ids = ["a", "b", "c"]
        p.shuffle = true
        let p2 = PlaylistStore(baseDirectory: dir)
        XCTAssertTrue(p2.enabled)
        XCTAssertEqual(p2.intervalMinutes, 5)
        XCTAssertEqual(p2.ids, ["a", "b", "c"])
        XCTAssertTrue(p2.shuffle, "셔플 설정도 영속")
    }

    /// w5d-playback: shuffle 필드가 없는 구버전 JSON(intervalMinutes 누락 케이스와 동일 하위호환
    /// 패턴) → throw 없이 기본값(false) 폴백 디코드, corrupt 오판 없음.
    func testOldShapeJSONMissingShuffleDecodesWithDefault() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("playlist.json")
        try Data(#"{"enabled":true,"intervalMinutes":15,"ids":["a","b"]}"#.utf8).write(to: url)

        let p = PlaylistStore(baseDirectory: dir)
        XCTAssertFalse(p.shuffle, "누락 필드는 기본값 폴백(throw 금지)")

        p.ids = ["a", "b", "c"]  // 저장 트리거 — corrupt 오판이었다면 백업 파일이 생겼을 것
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playlist.json.corrupt") }
        XCTAssertTrue(backups.isEmpty, "누락 필드=corrupt 오판이면 안 됨")
    }

    func testNextRotatesAndWraps() {
        let p = PlaylistStore(baseDirectory: tempDir())
        p.ids = ["a", "b", "c"]
        XCTAssertEqual(p.next(after: "a"), "b")
        XCTAssertEqual(p.next(after: "c"), "a", "래핑")
        XCTAssertEqual(p.next(after: "zz"), "a", "목록 밖 → 처음부터")
        XCTAssertEqual(p.next(after: nil), "a")
    }

    func testNextEmptyListIsNil() {
        let p = PlaylistStore(baseDirectory: tempDir())
        XCTAssertNil(p.next(after: nil))
    }

    func testToggleMembership() {
        let p = PlaylistStore(baseDirectory: tempDir())
        p.toggle("a"); p.toggle("b")
        XCTAssertEqual(p.ids, ["a", "b"])
        p.toggle("a")
        XCTAssertEqual(p.ids, ["b"], "재토글 = 제거")
    }

    func testCorruptFileBackedUpNotClobbered() throws {
        // 종전: 손상 playlist.json 을 try? 로 무시하고 첫 저장이 기본값으로 덮어써 재생목록 구성 영구 손실.
        let dir = tempDir()
        let url = dir.appendingPathComponent("playlist.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let p = PlaylistStore(baseDirectory: dir)
        p.enabled = true  // 저장 트리거
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playlist.json.corrupt") }
        XCTAssertEqual(backups.count, 1, "손상 원본이 백업 없이 파괴됨(회귀)")
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage, "손상 원본 바이트 보존")
        XCTAssertTrue(PlaylistStore(baseDirectory: dir).enabled, "새 데이터는 정상 저장")
    }

    /// P1: 합성 init(from:) 는 누락 키에서 throw 하므로, 향후 필드가 추가되면 구버전 JSON 전부가
    /// corrupt 로 오판돼 초기화된다. intervalMinutes 필드가 없는 구버전 모양 JSON 을 기본값으로
    /// 폴백 디코드해야 하며(성공, corrupt 아님), 나머지 필드는 정상 로드돼야 한다.
    func testOldShapeJSONMissingFieldDecodesWithDefault() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("playlist.json")
        try Data(#"{"enabled":true,"ids":["a","b"]}"#.utf8).write(to: url)

        let p = PlaylistStore(baseDirectory: dir)
        XCTAssertTrue(p.enabled, "존재하는 필드는 정상 로드")
        XCTAssertEqual(p.ids, ["a", "b"], "존재하는 필드는 정상 로드")
        XCTAssertEqual(p.intervalMinutes, 30, "누락 필드는 기본값 폴백(throw 금지)")

        p.ids = ["a", "b", "c"]  // 저장 트리거 — corrupt 오판이었다면 백업 파일이 생겼을 것
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playlist.json.corrupt") }
        XCTAssertTrue(backups.isEmpty, "누락 필드=corrupt 오판이면 안 됨")
    }
}
