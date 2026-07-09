import XCTest
@testable import Waple

/// steamcmd 다운로더의 순수 로직(실행파일 탐지 / 인자 / stdout 파싱 / 결과 경로 후보) 검증.
/// steamcmd 실호출은 없다.
final class SteamCmdDownloaderTests: XCTestCase {

    // MARK: - 실행파일 탐지 (env → 고정 경로 → nil, PATH 불신)

    func testDetectExecutableIgnoresPath() {
        let found = SteamCmdDownloader.detectExecutable(
            environment: ["PATH": "/tmp/attacker"],
            knownExecutablePaths: [],
            isExecutable: { $0 == "/tmp/attacker/steamcmd" })
        XCTAssertNil(found, "PATH 는 신뢰하지 않는다")
    }

    func testDetectExecutableUsesFixedPath() {
        let found = SteamCmdDownloader.detectExecutable(
            environment: [:],
            knownExecutablePaths: ["/opt/homebrew/bin/steamcmd"],
            isExecutable: { $0 == "/opt/homebrew/bin/steamcmd" })
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/steamcmd")
    }

    func testDetectExecutableUsesExplicitEnv() {
        let found = SteamCmdDownloader.detectExecutable(
            environment: [SteamCmdDownloader.explicitExecutableEnv: "/custom/steamcmd"],
            knownExecutablePaths: ["/opt/homebrew/bin/steamcmd"],
            isExecutable: { $0 == "/custom/steamcmd" || $0 == "/opt/homebrew/bin/steamcmd" })
        XCTAssertEqual(found?.path, "/custom/steamcmd", "명시 env 가 고정 경로보다 우선")
    }

    // MARK: - 인자 조립 (비밀번호 없음)

    func testArguments() {
        let args = SteamCmdDownloader.arguments(username: "alice", itemId: "12345")
        XCTAssertEqual(args, ["+login", "alice", "+workshop_download_item", "431960", "12345", "validate", "+quit"])
        XCTAssertFalse(args.contains { $0.lowercased().contains("password") }, "비밀번호는 인자에 없어야 한다")
    }

    // MARK: - stdout 파싱

    func testParseStateCodes() {
        XCTAssertEqual(SteamCmdDownloader.parse(line: "Update state (0x61) downloading, progress: 10.00 (1 / 10)"),
                       .downloading(10.0))
        XCTAssertEqual(SteamCmdDownloader.parse(line: "Update state (0x5) verifying install"),
                       .verifying)
        XCTAssertEqual(SteamCmdDownloader.parse(line: "Update state (0x101) committing"),
                       .committing)
        XCTAssertEqual(SteamCmdDownloader.parse(line: "Success. Downloaded item 12345 to \"/x/y\""),
                       .success)
        XCTAssertEqual(SteamCmdDownloader.parse(line: "ERROR! Download item 12345 failed (Failure)."),
                       .failed)
        XCTAssertNil(SteamCmdDownloader.parse(line: "Loading Steam API...OK"))
    }

    func testParseProgressValue() {
        XCTAssertEqual(SteamCmdDownloader.progressValue("progress: 42.35 (100 / 236)"), 42.35)
        XCTAssertEqual(SteamCmdDownloader.progressValue("... progress:7 ..."), 7)
        XCTAssertNil(SteamCmdDownloader.progressValue("no progress here"))
    }

    func testParseDownloadingWithoutProgressIsNil() {
        XCTAssertEqual(SteamCmdDownloader.parse(line: "Update state (0x61) downloading"),
                       .downloading(nil))
    }

    // MARK: - 결과 경로 후보

    func testResultPathCandidatesOrderAndShape() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let exe = URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd")
        let candidates = SteamCmdDownloader.resultPathCandidates(itemId: "999", executableURL: exe, homeDirectory: home)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].path,
                       "/Users/tester/Library/Application Support/Steam/steamapps/workshop/content/431960/999",
                       "1순위: macOS 기본 Steam 데이터 홈")
        XCTAssertEqual(candidates[1].path,
                       "/opt/homebrew/bin/steamapps/workshop/content/431960/999",
                       "2순위: steamcmd 실행파일 디렉터리")
    }

    func testResultPathCandidatesWithoutExecutable() {
        let candidates = SteamCmdDownloader.resultPathCandidates(
            itemId: "1", executableURL: nil, homeDirectory: URL(fileURLWithPath: "/home/u"))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].path.hasSuffix("steamapps/workshop/content/431960/1"))
    }
}
