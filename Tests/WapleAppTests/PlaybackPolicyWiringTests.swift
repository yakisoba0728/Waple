import XCTest

/// stage 3①·③ — `AppDelegate` 가 판정을 **실제로** 렌더러에 먹이는가.
///
/// ## 왜 소스 스캔인가
///
/// `AppDelegate` 는 이 스위트에서 **한 번도 인스턴스화되지 않는다**(`grep 'AppDelegate()' Tests/`
/// = 0건). 인스턴스화하려면 `NSApplication`·상태바·데스크탑 창이 필요하고 CI 러너에는 그게
/// 없다. 그래서 `UIConventionTests.testNotifyMirrorsIntoSettingsWindow…` 가 쓰는 것과 같은 방식
/// (함수 본문을 떼어 주석을 걷고 텍스트로 판정)을 쓴다.
///
/// ## 이 파일이 막는 것
///
/// 순수층 오라클은 **판정 규칙**을 지키지만 "그 판정이 올바른 렌더러에 도달하는가" 는 아무
/// 게이트도 보지 않았다(stage 2 인계 문서 §3). 배선은 한 줄만 지워도 조용히 사라지는 종류이고,
/// 여기 넷은 특히 그렇다:
///
///   ① `audioPlaying:` 이 다시 리터럴 `false` 가 되면 오디오 축이 통째로 죽는다(stage 2 상태).
///   ② 음소거 적용이 빠지면 `policyWantsMute` 가 다시 아무 일도 안 하는 이름이 된다.
///   ③ 렌더러 세트 교체 시 음소거 엣지 추적을 리셋하지 않으면, 배경을 바꾸는 순간
///      정책 음소거가 조용히 풀린다(새 렌더러는 `policyMuted == false` 로 태어난다).
///   ④ [2026-08-30 추가] `monitorIndex` 가 마스크와 다른 배열 기준에서 오면, 판정이 맞는데도
///      **엉뚱한 화면**에 간다. 아래 「못 잡는 것」 의 정정이 그 전말이다.
///
/// ## 못 잡는 것
///
/// > ~~**실제로 소리가 꺼지는지, 판정이 맞는 화면에 가는지는 여전히 실기 몫이다.**~~
///
/// **[정정 2026-08-30] 둘 중 뒤쪽("판정이 맞는 화면에 가는지")을 이 파일이 실제로 놓쳤고,
/// 그 자리에 결함이 배송됐다.** `applyPlaybackPolicy` 는 `rendererProjects` 의 **배열 위치**를
/// `monitorIndex` 로 먹였는데, 그 배열은 `applyResolved` 의 `compactMap` 이 빈 슬롯을 떨어뜨려
/// 재인덱싱한 것이고 대조되는 `pauseMask` 는 `NSScreen.screens` 위치로 만들어진다 — 즉 첫 빈
/// 슬롯 이후 모든 화면이 남의 pause 결정을 받았다(`global == nil` 인 화면별 할당 전용 모드에
/// 한정. 전역 벽지가 걸리면 슬롯이 다 채워져 두 인덱스가 일치했다).
///
/// 순수층 오라클(`PlaybackPolicyCompositionTests` 의
/// `testPerProjectDecideAllUsesRealMonitorIndexNotArrayPosition` 외 2건)이 판정 쪽을 못 박았고,
/// **배선 쪽은 아래 ④** 가 본다 — 두 인덱스가 같은 `NSScreen.screens` 배열에서 나오는지.
/// 여전히 실기 몫인 것은 **소리가 실제로 꺼지는지**와, 그 `screens` 배열이 창 순서와 일치하는지다.
/// 이 파일은 "호출부가 존재한다" 까지만 본다 — 그 경계를 흐리지 않으려고 여기 적어 둔다.
final class PlaybackPolicyWiringTests: XCTestCase {

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

    /// 선언 뒤 중괄호를 세어 **함수 본문만** 떼어낸다. 고정 길이로 자르면 뒤따르는 다른 함수가
    /// 딸려 들어와 오탐이 난다(그 사고 이력은 `UIConventionTests` 의 같은 헬퍼에 적혀 있다).
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
        XCTAssertGreaterThan(out.count, 200, "본문 추출이 실패했다 — 이 오라클이 아무것도 안 본다")
        return out
    }

    /// **주석을 걷고 본다.** 안 걷으면 "이렇게 하지 마라" 라고 적어 둔 설명 주석 자체가
    /// 위반으로 세어진다(같은 오탐을 `UIConventionTests` 가 이미 겪었다).
    private func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slash = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slash.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: - ③ 오디오 축

    /// 오디오 축이 **뺄셈을 거쳐** 채워진다. stage 2 는 여기를 리터럴 `false` 로 두었고,
    /// 그 상태에서는 사용자가 `playbackaudio` 를 켜도 아무 일도 일어나지 않는다.
    func testAudioAxisIsFedThroughTheSelfSubtraction() throws {
        let code = stripComments(try body(of: "private func applyPlaybackPolicy() {",
                                          in: try appDelegateSource()))
        XCTAssertFalse(code.contains("audioPlaying: false"),
                       "오디오 축이 다시 리터럴 false 로 굳었다 — 축이 통째로 죽는다")
        XCTAssertTrue(code.contains("SystemAudioObserver.isOtherAppPlaying("),
                      "우리 소리를 빼는 순수 함수를 거쳐야 한다 — 안 거치면 되먹임이다")
        XCTAssertTrue(code.contains("weArePlayingAudio:"),
                      "뺄셈의 두 번째 인자가 사라지면 뺄셈이 아니다")
        XCTAssertTrue(code.contains("isPlayingAudio"),
                      "뺄셈 항은 렌더러가 답한다 — 상수로 굳히면 다시 stage 2 다")
    }

    // MARK: - ① 음소거 적용

    /// 음소거가 실제로 렌더러에 도달한다. 그리고 **전 렌더러에 같은 값**이다 —
    /// WE 에서 음소거는 모니터별이 아니라 전역이다(`PlaybackVerdict.muted`).
    func testGlobalMuteReachesEveryRenderer() throws {
        let code = stripComments(try body(of: "private func applyPlaybackPolicy() {",
                                          in: try appDelegateSource()))
        XCTAssertTrue(code.contains("RenderPauseComposition.wantsGlobalMute("),
                      "화면별 판정을 하나로 접는 규칙은 순수층에 있다 — 여기서 다시 정하지 마라")
        XCTAssertTrue(code.contains("setPolicyMuted("),
                      "음소거 적용이 사라졌다 — policyWantsMute 가 다시 아무 일도 안 하는 이름이 된다")
        XCTAssertTrue(code.contains("renderers.forEach { $0.setPolicyMuted("),
                      "인덱스로 갈라 먹이면 안 된다 — 음소거는 전역이다")
        XCTAssertFalse(code.contains("setPolicyMuted(true)"),
                       "상수를 먹이면 정책이 아니라 하드코딩이다")
    }

    /// **음소거를 정지로 바꿔치지 않는다.** 이 함수가 `pause()` 를 부르는 자리는 정지 결정
    /// 하나뿐이어야 한다 — 음소거 분기에서 렌더러를 멈추면 소리만 줄이려던 사용자의 벽지가
    /// 얼어붙는다(순수층 오라클 `testMuteAloneNeverPauses` 의 배선 쪽 짝).
    func testMuteBranchDoesNotPause() throws {
        let code = stripComments(try body(of: "private func applyPlaybackPolicy() {",
                                          in: try appDelegateSource()))
        let muteLines = code.split(separator: "\n").filter { $0.contains("setPolicyMuted") }
        XCTAssertFalse(muteLines.isEmpty, "음소거 적용을 못 찾았다")
        for line in muteLines {
            XCTAssertFalse(line.contains(".pause()"), "음소거 분기가 렌더러를 멈춘다: \(line)")
            XCTAssertFalse(line.contains(".teardown()"), "음소거 분기가 렌더러를 해제한다: \(line)")
        }
    }

    // MARK: - ① 엣지 추적 리셋

    /// **`renderers` 배열을 갈아끼우는 자리는 두 추적기를 함께 리셋한다.**
    ///
    /// 새 렌더러는 `policyMuted == false` 로 태어나는데 추적기는 "이미 음소거 중" 을 기억하고
    /// 있으므로, 리셋하지 않으면 배경 교체·모니터 착탈 한 번에 정책 음소거가 조용히 풀린다.
    /// 정지 쪽이 이미 같은 이유로 리셋하고 있으니, **대입 자리마다 둘 다** 있는지 본다.
    ///
    /// 개수만 세지 않는 이유: `applyPause` 도 정지 추적기를 리셋하지만 그건 렌더러 세트가
    /// 갈려서가 아니라 그 함수가 추적기를 **우회해** 전 렌더러를 직접 멈췄기 때문이다.
    /// 음소거는 거기서 건드리지 않으므로 총수는 원래 다르다 — 개수로 보면 그 차이가 오탐이 된다.
    func testEveryRendererSetChangeResetsBothEdgeTrackers() throws {
        let lines = stripComments(try appDelegateSource())
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 대입만 고른다. 선언(`private var renderers: [WallpaperRenderer] = []`)과
        // `let webRenderers = renderers.compactMap …`(대문자 R)은 이 패턴에 걸리지 않는다.
        let assignments = lines.indices.filter {
            lines[$0].contains("renderers = ") && !lines[$0].contains("rendererProjects")
        }
        XCTAssertFalse(assignments.isEmpty, "renderers 대입을 못 찾았다 — 스캔 전제가 바뀌었나?")
        for index in assignments {
            let window = lines[max(0, index - 6)...min(lines.count - 1, index + 20)]
                .joined(separator: "\n")
            XCTAssertTrue(window.contains("policyPauseState.reset()"),
                          "renderers 대입(:\(index + 1)) 근처에 정지 추적기 리셋이 없다")
            XCTAssertTrue(window.contains("policyMuteState.reset()"),
                          "renderers 대입(:\(index + 1)) 근처에 음소거 추적기 리셋이 없다 — "
                            + "새 렌더러는 policyMuted == false 로 태어나므로 음소거가 조용히 풀린다")
        }
    }

    // MARK: - ④ 모니터 인덱스 기준 (2026-08-30)

    /// **판정에 넘기는 `monitorIndex` 가 마스크와 같은 배열에서 나온다.**
    ///
    /// `pauseMask` 의 비트 자리는 `screenFrames:`/`visibleFrames:` 로 넘긴 `NSScreen.screens`
    /// 배열 위치가 정한다. 그래서 `decideAll(projects:)` 에 넘기는 인덱스도 **그 배열에서**
    /// 나와야 한다. `renderers`/`rendererProjects` 의 배열 위치는 그 기준이 아니다 —
    /// `applyResolved` 의 `compactMap` 이 빈 슬롯(= `global == nil` 인 화면별 할당 전용 모드에서
    /// 미할당 화면)을 떨어뜨려 0..<n 으로 재인덱싱한 값이다. 종전에 그 위치를 그대로 먹여
    /// 첫 빈 슬롯 이후 모든 화면이 남의 pause 결정을 받았다.
    ///
    /// **순수층 오라클로는 이 자리를 막을 수 없다.** `AppDelegate` 는 이 스위트에서 한 번도
    /// 인스턴스화되지 않으므로(파일 머리말), 배선을 되돌리는 회귀 — 예: `monitorIndex: 0` 으로
    /// 굳히기 — 는 실측으로 WapleAppTests 461개를 통째로 통과한다. 그래서 소스 스캔이다.
    func testMonitorIndexComesFromTheSameScreenArrayAsTheMasks() throws {
        let code = stripComments(try body(of: "private func applyPlaybackPolicy() {",
                                          in: try appDelegateSource()))
        XCTAssertTrue(code.contains("screenFrames: screens.map"),
                      "마스크의 비트 자리를 정하는 배열이 바뀌었다 — 이 오라클의 전제가 사라졌다")
        XCTAssertTrue(code.contains("DesktopWindow.screenKey(for:"),
                      "실제 모니터 인덱스는 안정 키로 되찾아야 한다 — 배열 위치는 안정 식별자가 아니다(F840)")
        XCTAssertTrue(code.contains("screens.enumerated()"),
                      "인덱스가 마스크와 같은 `screens` 배열에서 나오지 않는다 — 두 기준이 갈리면 스큐다")
        XCTAssertTrue(code.contains("monitorIndex: monitorIndexByKey["),
                      "판정에 넘기는 monitorIndex 가 키 조회를 거치지 않는다 — 배열 위치로 되돌아갔나?")

        // 배열 위치로 되돌아가는 두 가지 모양을 직접 막는다.
        XCTAssertFalse(code.contains("projects: rendererProjects,"),
                       "rendererProjects 를 그대로 넘기면 배열 위치가 다시 monitorIndex 가 된다")
        for forbidden in ["monitorIndex: 0", "monitorIndex: index", "monitorIndex: offset"] {
            XCTAssertFalse(code.contains(forbidden),
                           "monitorIndex 가 상수/배열 위치로 굳었다: \(forbidden)")
        }
    }
}
