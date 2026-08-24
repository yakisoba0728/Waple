import XCTest

/// UI 규약 오라클 — 소스 텍스트 스캔.
///
/// ## 왜 이런 테스트가 필요한가
///
/// `WapleAppTests` 292개 중 **`import SwiftUI` 하는 파일이 하나도 없다**(2026-08-17 실측).
/// SwiftUI 뷰를 인스턴스화하는 테스트가 0개라, 레이아웃·색·모션·접근성을 **어떻게 바꾸든
/// 292개가 전부 초록으로 남는다.** 이 스위트가 실제로 잡는 UI 회귀는 카피(문구) 변경뿐이다.
///
/// 뷰 스냅샷 테스트를 도입하자는 게 아니다 — 무거운 데다 이 저장소의 골든 정책과도 어긋난다.
/// 대신 `LocalizationCoverageTests` 가 이미 쓰는 방식(소스 전문 정규식 스캔)으로,
/// **규약 위반을 기계가 판정할 수 있는 만큼만** 잡는다.
///
/// ## 허용 목록은 줄어들기만 한다
///
/// 각 규약에는 현재 위반 파일의 허용 목록이 붙어 있다. 2026-08-17 UI 개편에서 그 파일을
/// 담당하는 단위가 **자기 파일을 목록에서 지우면서** 마이그레이션한다.
/// 목록에 있는데 더는 위반하지 않는 파일이 남아 있으면 그것도 실패다 — 목록이 조용히
/// 썩어서 새 위반을 덮어주는 걸 막는다. **목록에 파일을 추가하지 마라.**
///
/// 규약 본문: `docs/ui-redesign-2026-08-17.md` §4(접근성) · 부록 A(토큰 적용 지도).
final class UIConventionTests: XCTestCase {

    /// 리포 루트 — 테스트 바이너리는 .build 안이라 소스 파일 위치에서 거슬러 올라간다.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 화면 코드 전부. `DesignSystem/` 은 제외한다 — 토큰을 **정의**하는 곳이라
    /// 원시 애니메이션·색이 있는 게 정상이고, 문서 주석의 예제 코드도 들어 있다.
    private static func uiSources() throws -> [(name: String, text: String)] {
        let root = repoRoot.appendingPathComponent("Sources/Waple")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(name: String, text: String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relative.hasPrefix("DesignSystem/") else { continue }
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// 위반 판정 + 허용 목록 정합을 한 번에. `pending` 이 줄어드는 방향으로만 바뀐다.
    private func assertConvention(violates: (String) -> Bool,
                                  pending: Set<String>,
                                  rule: String,
                                  fix: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let sources = try Self.uiSources()
        XCTAssertGreaterThan(sources.count, 20, "소스 수집이 실패했다 — 경로 규약이 바뀌었나?",
                             file: file, line: line)
        let violators = Set(sources.filter { violates($0.text) }.map(\.name))
        let unexpected = violators.subtracting(pending).sorted()
        XCTAssertTrue(unexpected.isEmpty,
                      "\(rule)\n새 위반 \(unexpected.count)건:\n"
                        + unexpected.map { "  \($0)" }.joined(separator: "\n")
                        + "\n\(fix)",
                      file: file, line: line)
        let stale = pending.subtracting(violators).sorted()
        XCTAssertTrue(stale.isEmpty,
                      "\(rule)\n허용 목록이 스테일하다 — 아래 파일은 더 이상 위반하지 않는다.\n"
                        + "목록에서 지워라(안 지우면 그 파일의 다음 위반을 조용히 덮어준다):\n"
                        + stale.map { "  \($0)" }.joined(separator: "\n"),
                      file: file, line: line)
    }

    // MARK: - 모션

    /// 화면 코드는 애니메이션 곡선을 직접 만들지 않는다.
    ///
    /// `Motion` 토큰이 `reduceMotion` 분기를 안에 가두고 있으므로, 화면이 `.spring(...)` 을
    /// 직접 쓰는 순간 그 자리만 "동작 줄이기" 설정을 무시한다. 실측(2026-08-17): 소스 전체에
    /// `reduceMotion`·`accessibilityReduceTransparency`·`differentiateWithoutColor` 참조가
    /// **0건**이고 애니메이션 진입점 6개가 무조건 실행된다.
    func testAnimationsComeFromMotionTokens() throws {
        // 2026-08-17 기준 위반 4파일이 **전부** 마이그레이션을 끝냈다 —
        // MainWindowView·StatusBanner(Unit A, 셸 개편) · WallpaperGridView(Unit B,
        // 라이브러리 개편) · RemoteTile(Unit C, 창작마당 개편)이 각자 호버 리프트
        // 모디파이어와 Motion 토큰으로 옮기며 지웠다.
        //
        // 목록이 비었다고 이 테스트를 지우지 마라 — 이제부터는 **새 위반을 막는**
        // 역할이다. 생 `.animation(.spring(…))` 을 새로 쓰면 여기서 빨개진다.
        let pending: Set<String> = [
        ]
        try assertConvention(
            violates: { text in
                text.contains(".spring(") || text.contains(".easeInOut(")
                    || text.contains(".linear(") || text.contains("withAnimation(.")
            },
            pending: pending,
            rule: "모션은 Motion 토큰으로만 만든다(reduceMotion 분기가 토큰 안에 있다).",
            fix: "→ Motion.hoverLift / Motion.reveal / Motion.fade / Motion.revealTransition(edge:) "
                + "또는 View.tileLift(_:) 를 쓰고, 이 테스트의 pending 에서 자기 파일을 지워라."
        )
    }

    // MARK: - 접근성

    /// 우클릭 메뉴에만 있는 기능은 보조기술로 도달할 수 없다.
    ///
    /// `contextMenu` 는 마우스 우클릭 전용이다. VoiceOver 사용자와 키보드 전용 사용자에게
    /// 그 안의 항목은 존재하지 않는 것과 같다. 실측(2026-08-17): 라이브러리 타일의 우클릭
    /// 메뉴 11개 중 5개(선택(속성 보기)·적용 + 조작 창 열기·폴더로 이동·Finder에서 보기·
    /// 폴더 삭제)는 다른 어떤 경로로도 도달할 수 없다.
    func testContextMenusHaveAccessibilityCounterpart() throws {
        // 2026-08-17 기준 위반 1파일이었고, Unit B 가 라이브러리 개편에서 지웠다 — 목록은 비었다.
        let pending: Set<String> = []
        try assertConvention(
            violates: { text in
                text.contains(".contextMenu") && !text.contains(".accessibilityAction(")
            },
            pending: pending,
            rule: "contextMenu 항목은 accessibilityAction 으로 1:1 대응돼야 한다.",
            fix: "→ 메뉴 항목마다 .accessibilityAction(named: Text(\"…\")) { … } 를 붙여라. 규약은 §4.3."
        )
    }

    /// 탭으로 동작하는 커스텀 뷰는 자기가 무엇인지 보조기술에 알려야 한다.
    ///
    /// `VStack { 썸네일; 제목 }` + `.onTapGesture` 는 화면에서만 버튼이다 — 보조기술에는
    /// 이미지와 텍스트가 따로 읽히고, 누를 수 있다는 것도 선택 상태도 전달되지 않는다.
    /// 실측(2026-08-17): `Sources/Waple` 전체에서 `.accessibilityLabel`/`Value`/`Hint`/
    /// `Element`/`AddTraits`·`.focusable` 참조가 **전부 0건**이다.
    func testTapDrivenViewsDeclareAccessibility() throws {
        // 2026-08-17 기준 위반 2파일이 **둘 다** 마이그레이션을 끝냈다 —
        // WallpaperGridView(Unit B, 타일)와 DisplaysView(Unit D, railTile·monitorBox)가
        // 각자 tileAccessibility 로 옮기며 지웠다.
        //
        // 목록이 비었다고 이 테스트를 지우지 마라 — 이제부터는 **새 위반을 막는**
        // 역할이다. 접근성 표현 없는 onTapGesture 뷰를 새로 만들면 여기서 빨개진다.
        let pending: Set<String> = [
        ]
        try assertConvention(
            violates: { text in
                text.contains("onTapGesture")
                    && !text.contains("tileAccessibility")
                    && !text.contains(".accessibilityElement(")
            },
            pending: pending,
            rule: "onTapGesture 로 동작하는 커스텀 뷰에는 접근성 표현이 있어야 한다.",
            fix: "→ .tileAccessibility(label:value:isSelected:onActivate:) 를 붙여라. 표준 형태는 §4.1."
        )
    }

    // MARK: - notify 미러 (2026-08-25)

    /// **`notify` 가 설정 창에도 흐르는가, 그리고 굽기 스피너를 건드리지 않는가.**
    ///
    /// `AppDelegate` 는 이 스위트에서 **한 번도 인스턴스화되지 않는다**(`grep 'AppDelegate()' Tests/` = 0건).
    /// 즉 `notify` 의 런타임 동작을 부를 방법이 없다. 이 파일 머리말이 적은 그 상황 그대로라,
    /// 같은 방식(소스 전문 스캔)으로 **기계가 판정할 수 있는 만큼만** 잡는다.
    ///
    /// 잠그는 것 둘:
    /// ① 미러가 존재한다 — 없으면 트레이에서 설정 창만 열고 누른 동작의 성패가 화면 어디에도 안 뜬다.
    /// ② 미러가 `isBakingStill` 을 건드리지 않는다 — 이 미러는 **모든** notify 를 받으므로,
    ///    굽는 도중 도착한 무관한 알림이 스피너를 먼저 끄면 안 된다. (굽기는 한 번에 두 번
    ///    알림이 올 수 있다 — `writeLockscreenStill`.)
    ///
    /// 못 잡는 것: 실제로 화면에 뜨는지. 그건 실기 확인 몫이다.
    func testNotifyMirrorsIntoSettingsWindowWithoutTouchingTheBakingSpinner() throws {
        let files = try Self.uiSources()
        let appDelegate = try XCTUnwrap(files.first { $0.name == "AppDelegate.swift" }?.text,
                                        "AppDelegate.swift 를 못 찾았다 — 스캔 루트가 바뀌었나?")
        // `notify(_:)` 본문만 떼어 본다. 다음 함수 선언 전까지.
        guard let start = appDelegate.range(of: "private func notify(_ message: String) -> Bool {") else {
            return XCTFail("notify(_:) 선언을 못 찾았다 — 시그니처가 바뀌었으면 이 오라클도 같이 고쳐라")
        }
        // 중괄호를 세어 **함수 본문만** 떼어낸다. 고정 길이로 자르면 뒤따르는 다른 함수가
        // 딸려 들어와 오탐이 난다 — 처음에 1600자로 잘랐다가 실제로 그 오탐을 봤다.
        var depth = 1
        var body = ""
        for ch in appDelegate[start.upperBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 { break } }
            body.append(ch)
        }
        XCTAssertGreaterThan(body.count, 200, "본문 추출이 실패했다 — 이 오라클이 아무것도 안 본다")

        // **주석을 걷어내고 본다.** 처음엔 안 걷었다가 "isBakingStill 을 건드리지 마라" 라고
        // 적어 둔 **설명 주석 자체**를 위반으로 셌다 — 규약을 적는 행위가 규약 위반이 되는 오탐이다.
        let code = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slash = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slash.lowerBound])
            }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("settingsWindow?.isVisible == true"),
                      "설정 창 가시성 게이트가 없다 — settingsVM 은 lazy 라 먼저 건드리면 조기 생성된다")
        XCTAssertTrue(code.contains("settingsVM.statusMessage = message"),
                      "설정 창 미러가 없다 — 트레이→설정 경로에서 성패가 화면에 안 뜬다")
        XCTAssertFalse(code.contains("isBakingStill"),
                       "notify 미러는 굽기 스피너를 건드리면 안 된다 — 무관한 알림이 스피너를 먼저 끈다")
    }
}
