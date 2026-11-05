import AppKit
import Observation

/// 시스템 접근성 설정 조회 창구.
///
/// **왜 한 곳에 모으나.** 2026-08-17 실측: `Sources/Waple` 전체에서 `reduceMotion` ·
/// `accessibilityReduceTransparency` · `differentiateWithoutColor` 참조가 **전부 0건**이다.
/// 애니메이션 진입점 6개가 설정과 무관하게 무조건 실행되고, 시스템 재질 5곳에 폴백이 없다.
/// 화면마다 각자 읽게 하면 새 자리가 생길 때마다 빠뜨린다 — 토큰(`Motion`·`ColorRole`·
/// `Surface`)이 여기를 읽고, 화면은 토큰만 쓴다.
///
/// **왜 SwiftUI 환경값이 아닌가.** 이 앱은 `NSHostingController` 로 붙는 AppKit 앱이고,
/// 애니메이션·문구 결정 지점이 뷰 바깥(`StatusBannerModel`, `AppDelegate` 콜백)에도 있다.
/// 환경값은 뷰 안에서만 읽히므로 그 자리들이 분기에서 빠진다. Observable 스냅샷을
/// 토큰에서 읽으면 기존 SwiftUI 소비자도 접근성 변경 알림 직후 다시 평가된다.
enum SystemPreference {
    /// "동작 줄이기". 이동·확대를 페이드로 대체해야 한다 → `Motion` 이 소비한다.
    static var reduceMotion: Bool {
        MainActor.assumeIsolated { AccessibilityDisplayPreferences.shared.snapshot.reduceMotion }
    }

    /// "투명도 줄이기". 시스템 `Material` 은 대체로 스스로 반응하지만, 재질 **위에** 얹은
    /// 반투명 오버레이(그라디언트 스크림 등)는 반응하지 않는다 — 그쪽은 직접 불투명하게 한다.
    static var reduceTransparency: Bool {
        MainActor.assumeIsolated { AccessibilityDisplayPreferences.shared.snapshot.reduceTransparency }
    }

    /// "색상 없이 구분". 색만으로 전달하던 상태에 모양·글자를 덧붙여야 한다는 신호다.
    /// 다만 규약상 **이 값이 false 여도 색 단독 전달은 금지**다(§4.5) — 이건 색맹 사용자가
    /// 설정을 켜지 않았을 때도 지켜야 하는 하한이라, 이 프로퍼티는 추가 보강용이다.
    static var differentiateWithoutColor: Bool {
        MainActor.assumeIsolated { AccessibilityDisplayPreferences.shared.snapshot.differentiateWithoutColor }
    }

    /// "대비 증가". 시맨틱 컬러를 쓰면 시스템이 알아서 처리하므로 보통 읽을 일이 없다.
    /// 커스텀 반투명 위에 글자를 얹는 자리에서만 참고한다.
    static var increaseContrast: Bool {
        MainActor.assumeIsolated { AccessibilityDisplayPreferences.shared.snapshot.increaseContrast }
    }
}


/// The workspace posts accessibility display changes on its own notification center.
/// Injectable snapshots keep the notification→observation seam testable without changing OS settings.
@MainActor @Observable
final class AccessibilityDisplayPreferences {
    struct Snapshot: Equatable {
        var reduceMotion: Bool
        var reduceTransparency: Bool
        var differentiateWithoutColor: Bool
        var increaseContrast: Bool

        static func current() -> Snapshot {
            let workspace = NSWorkspace.shared
            return Snapshot(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
                            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        }
    }

    static let shared = AccessibilityDisplayPreferences()
    private(set) var snapshot: Snapshot
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let read: () -> Snapshot
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         read: @escaping () -> Snapshot = Snapshot.current) {
        self.center = center
        self.read = read
        snapshot = read()
        observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = self.read()
                if next != self.snapshot { self.snapshot = next }
            }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }
}
