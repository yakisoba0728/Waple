import XCTest
@testable import Waple

/// 감사 V06 회귀: 타임아웃 시 SIGTERM(proc.terminate())만 본내고 waitUntilExit() 가 무한 대기 —
/// steamcmd 가 SIGTERM 을 무시하면 다운로드 스레드가 영구 정지하고 WorkshopViewModel 은
/// .downloading 에 고착됐다. 유예 시간 내 미종료 시 SIGKILL 로 에스컬레이션해 run 이 반드시
/// 반환되어야(completion 경로 보장) 한다. 실제 steamcmd 없이 /bin/sh 로 검증한다.
final class SteamCmdTerminateTests: XCTestCase {

    /// SIGTERM 을 무시하는 프로세스가 타임아웃 + 유예 후에도 run 에서 빠져나와야 한다.
    /// 종전(SIGTERM 만)에는 프로세스가 죽지 않아 run 이 영원히 반환되지 않아 이 테스트는
    /// wait 타임아웃으로 실패한다.
    func testTermIgnoringProcessIsKilledAfterGrace() {
        let done = expectation(description: "run returns")
        var result: (sawSuccess: Bool, path: String?)?
        DispatchQueue.global().async {
            // trap 으로 TERM 을 무시하고 자식 sleep 은 1초짜리라 sh 가 죽으면 곧 정리된다.
            result = SteamCmdDownloader.run(
                exe: URL(fileURLWithPath: "/bin/sh"),
                args: ["-c", "trap '' TERM; while true; do sleep 1; done"],
                timeout: 0.3,
                progress: { _ in })
            done.fulfill()
        }
        // 타임아웃(0.3) + 유예(기본 수 초) + 스폰 오버헤드를 흡수할 상한.
        wait(for: [done], timeout: 15)
        XCTAssertEqual(result?.sawSuccess, false)
    }

    /// 정상 종료 프로세스는 타임아웃과 무관하게 즉시 반환한다(에스컬레이션 오발 없음).
    func testNormalExitReturnsPromptly() {
        let start = Date()
        let result = SteamCmdDownloader.run(
            exe: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "exit 0"],
            timeout: 60,
            progress: { _ in })
        XCTAssertFalse(result.sawSuccess)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "정상 종료는 즉시 반환돼야 한다")
    }

    /// 성공 라인 파싱 경로 — 에스컬레이션 추가 후에도 기존 결과 해석이 유지되는지.
    func testSuccessLineIsParsed() {
        let result = SteamCmdDownloader.run(
            exe: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", #"echo 'Success. Downloaded item 1 to "/tmp/x"'"#],
            timeout: 60,
            progress: { _ in })
        XCTAssertTrue(result.sawSuccess)
        XCTAssertEqual(result.path, "/tmp/x")
    }
}
