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
        // 2026-08-17 기준 위반 4파일 중 셋(MainWindowView·StatusBanner = Unit A,
        // WallpaperGridView = Unit B)은 각자 개편에서 Motion 토큰으로 옮기며 지웠다.
        let pending: Set<String> = [
            "Surfaces/Workshop/RemoteTile.swift",  // Unit C
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
        // 2026-08-17 기준 위반 2파일 중 WallpaperGridView 는 Unit B 가 지웠다.
        let pending: Set<String> = [
            "Surfaces/Displays/DisplaysView.swift",   // Unit D (railTile·monitorBox)
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
}
