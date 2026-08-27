import XCTest

/// `AppDelegate` 가 재생목록 판정을 **실제로** 태우는가 — 소스 스캔.
///
/// ## 왜 소스 스캔인가
///
/// `AppDelegate` 는 이 스위트에서 한 번도 인스턴스화되지 않는다(상태바·데스크탑 창이 필요하고
/// CI 러너에 없다). 게다가 이 파일은 **리눅스 타입체크 제외**라(`APP_EXCLUDED`) 여기 쓴 코드는
/// macOS CI 가 처음 본다. `PlaybackPolicyWiringTests` 가 쓰는 것과 같은 방식으로 본문을 떼어
/// 주석을 걷고 텍스트로 판정한다.
///
/// ## 이 파일이 막는 것
///
/// 순수층(`PlaylistRuntime`)과 소비자(`PlaylistDriver`)는 각자 테스트가 있지만, "그 판정이
/// 실제 마운트에 도달하는가" 는 아무 게이트도 보지 않는다. 이 서브시스템은 **849줄이 검증까지
/// 끝난 채로 프로덕션 참조 0** 이던 곳이라 그 침묵이 특히 비싸다. 여기 넷을 본다:
///
///   ① 틱이 1초다 — 간격 타이머로 되돌아가면 정지 중 정지·5초 상한·경과시간 영속이 전부 죽는다.
///   ② 전진 결정이 드라이버에서 온다 — `AppDelegate` 가 다시 자기 산수를 하면 순수층이 또 고립된다.
///   ③ 종료 시 경과시간을 쓴다 — 안 쓰면 영속이 60초 주기 저장에만 걸려 마지막 회차를 잃는다.
///   ④ 화면 해석이 유효 할당(사용자 고정 → 재생목록 순)을 본다 — 아니면 모니터별 재생목록이
///      화면에 도달하지 못한다.
///
/// ## 못 잡는 것
///
/// **실제로 배경이 바뀌는지·어느 화면에 걸리는지는 여전히 실기 몫이다.** 여기는 "호출부가
/// 존재한다" 까지만 본다.
final class PlaylistWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appDelegateSource() throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/Waple/AppDelegate.swift"),
                   encoding: .utf8)
    }

    /// 선언 뒤 중괄호를 세어 **함수 본문만** 떼어낸다(고정 길이로 자르면 뒤 함수가 딸려 온다).
    private func body(of declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration),
                                  "선언을 못 찾았다: \(declaration) — 시그니처가 바뀌었으면 이 오라클도 같이 고쳐라")
        var depth = 1
        var out = ""
        for ch in source[start.upperBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 { break } }
            out.append(ch)
        }
        XCTAssertGreaterThan(out.count, 80, "본문 추출이 실패했다 — 이 오라클이 아무것도 안 본다")
        return out
    }

    /// **주석을 걷고 본다.** 안 걷으면 "이렇게 하지 마라" 라고 적어 둔 설명 자체가 위반으로 세어진다.
    private func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slash = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slash.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: - ① 1초 틱

    func testPlaylistTimerTicksEverySecondInsteadOfSleepingForTheWholeInterval() throws {
        let code = stripComments(try body(of: "private func schedulePlaylistTimer() {",
                                          in: try appDelegateSource()))
        XCTAssertTrue(code.contains("Timer(timeInterval: 1,"),
                      "간격만큼 한 번 깨는 타이머로 되돌아갔다 — 정지 중 정지·5초 상한·경과시간 영속이 전부 죽는다")
        XCTAssertFalse(code.contains("PlaylistScheduling.intervalSeconds"),
                       "간격을 타이머 주기로 쓰면 시계의 소유자가 다시 운영체제가 된다")
        XCTAssertTrue(code.contains("tickPlaylist()"), "틱이 재생목록 판정으로 이어져야 한다")
        XCTAssertTrue(code.contains("forMode: .common"),
                      "F840 — .default 만 등록하면 메뉴를 열어 둔 동안 회차가 통째로 밀린다")
    }

    // MARK: - ② 판정은 드라이버에서 온다

    func testTickDelegatesTheDecisionInsteadOfRedoingTheArithmetic() throws {
        let code = stripComments(try body(of: "private func tickPlaylist() {", in: try appDelegateSource()))
        XCTAssertTrue(code.contains("playlistDriver.tick("),
                      "전진 판정이 사라졌다 — 순수층이 다시 고립된다")
        XCTAssertTrue(code.contains("playlistDriver.advance("),
                      "후보 선택·실패 건너뛰기는 드라이버 안이다 — 여기서 다시 정하지 마라")
        XCTAssertTrue(code.contains("isPaused: pauseGate.isPaused"),
                      "정지 축이 상수로 굳으면 updateonpause 관문이 죽는다")
        XCTAssertFalse(code.contains("PlaylistScheduling.shuffleNext"),
                       "직전 1개만 회피하던 종전 셔플로 되돌아갔다 — 소진형 셔플백이 그 자리다")
    }

    func testManualNextUsesTheSameBagAsTheTimer() throws {
        let code = stripComments(try body(of: "private func advancePlaylist() {", in: try appDelegateSource()))
        XCTAssertTrue(code.contains("playlistDriver.advance("),
                      "수동 '다음 배경' 이 다른 경로를 타면 손으로 넘긴 것과 저절로 넘어간 것이 다른 순서를 걷는다")
        XCTAssertTrue(code.contains("libraryVM.apply("),
                      "수동 전진은 전역 선택을 옮겨야 한다 — 라이브러리 강조·하단 바가 그 값을 본다")
    }

    // MARK: - ③ 종료 시 경과시간 영속

    func testTerminateWritesTheElapsedClockBeforeAnyEarlyReturn() throws {
        let source = try appDelegateSource()
        let code = stripComments(try body(of: "public func applicationWillTerminate(_ notification: Notification) {",
                                          in: source))
        let persist = try XCTUnwrap(code.range(of: "playlistDriver.persist()"),
                                    "종료 시 경과시간 저장이 사라졌다 — 마지막 회차를 통째로 잃는다")
        let guardLine = try XCTUnwrap(code.range(of: "guard StillDesktopSync.shouldRestoreOnTerminate"),
                                      "정적 배경 복원 가드를 못 찾았다 — 이 오라클의 전제가 바뀌었나?")
        XCTAssertTrue(persist.lowerBound < guardLine.lowerBound,
                      "저장이 조기 return 가드 뒤에 있다 — 정적 배경 동기화가 꺼져 있으면 저장이 통째로 건너뛰어진다")
    }

    // MARK: - ④ 유효 할당이 화면 해석에 도달한다

    func testScreenResolutionGoesThroughTheEffectiveAssignment() throws {
        let code = stripComments(try appDelegateSource())
        let closures = code.split(separator: "\n").filter { $0.contains("assignment: {") }
        XCTAssertEqual(closures.count, 2,
                       "MonitorMapping.assignedFolder 주입 지점이 둘이 아니다 — 이 오라클의 전제가 바뀌었다")
        for line in closures {
            XCTAssertTrue(line.contains("effectiveAssignment(for:"),
                          "화면 해석이 재생목록 오버라이드를 못 본다 — 모니터별 재생목록이 화면에 도달하지 않는다: \(line)")
        }
    }

    /// **재생목록은 사용자가 못박은 화면을 건드리지 않는다.** 이 필터가 사라지면 `monitors.json`
    /// 설정이 매 회차 무시되는 것처럼 보인다(값은 남아 있는데 화면이 계속 바뀐다).
    func testPlaylistLeavesPinnedScreensAlone() throws {
        let code = stripComments(try body(of: "private func playlistScreenKeys(includingAssigned: Bool = false) -> [String] {",
                                          in: try appDelegateSource()))
        XCTAssertTrue(code.contains("monitorStore.assignment(for: $0) == nil"),
                      "고정 화면 제외 규칙이 사라졌다 — 사용자가 지정한 배경을 재생목록이 덮는다")
    }
}
