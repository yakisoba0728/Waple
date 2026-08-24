import AppKit

/// [2026-08-25] `@MainActor` — 이 파일 27줄이 **전부 AppKit 창 조작**이다(`NSScreen.screens`,
/// `DesktopWindow(screen:)`, `orderFrontRegardless`, `contentView`, `orderOut`). 종전에는 표기가
/// 없어 멤버가 비격리로 잡혔고, `-strict-concurrency=complete` 진단 5건이 전부 그 자리였다.
///
/// 안전한 근거는 **유일한 사용처가 이미 `@MainActor`** 라는 것이다 — `AppDelegate`(`:38` 보유,
/// `:211`·`:243`·`:534`·`:662`·`:964` 호출)뿐이고 `Tests/` 사용처는 0건이다.
///
/// ⚠️ 우리가 직접 붙인 `@MainActor` 는 SDK 의 `@preconcurrency` 강등을 받지 못한다. 그래서
/// 앞으로 **비격리 동기 호출부가 생기면 경고가 아니라 에러**다. 그게 의도다 — 이 타입을
/// 백그라운드에서 만지는 코드는 애초에 틀린 코드이고, 조용히 넘어가는 것보다 컴파일이 막는 게 낫다.
@MainActor
public final class DesktopWindowController {
    private var windows: [DesktopWindow] = []

    public init() {}

    /// 모든 화면에 대해 데스크탑 창을 다시 만든다.
    public func rebuild() {
        teardown()
        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    /// 화면 키와 함께(모니터별 배경).
    public var screenViews: [(screenKey: String, view: NSView)] {
        windows.compactMap { w in w.contentView.map { (w.screenKey, $0) } }
    }

    public func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
