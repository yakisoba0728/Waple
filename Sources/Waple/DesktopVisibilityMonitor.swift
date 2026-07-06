import AppKit
import CoreGraphics

/// 데스크탑이 다른 창에 가려졌는지 판정한다(자동 일시정지용).
///
/// 실판정은 CGWindowList 스냅샷을 `WindowSnapshot` 배열로 만들어 순수 static 함수에 넘긴다 —
/// AppDelegate 가 실제로 이 경로를 호출하므로 테스트가 실사용 로직을 검증한다(병렬 사본 아님).
struct DesktopVisibilityMonitor {
    /// 판정에 필요한 창 정보만 뽑은 스냅샷(CGWindowList dict → 순수 값).
    struct WindowSnapshot: Equatable {
        let ownerName: String
        let processId: Int?
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    // MARK: - 순수 판정 (테스트 대상)

    /// 데스크탑이 보이는가 — 데스크탑을 가리는 '차단 창'이 하나도 없으면 true.
    static func isDesktopVisible(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect]
    ) -> Bool {
        !windows.contains { isBlocking($0, currentProcessId: currentProcessId, screenFrames: screenFrames) }
    }

    /// 창 하나가 데스크탑을 가리는가.
    static func isBlocking(
        _ w: WindowSnapshot,
        currentProcessId: Int,
        screenFrames: [CGRect]
    ) -> Bool {
        // 레이어0(일반 앱 창)·거의 불투명·충분히 큰 창만 후보. 나머지는 데스크탑을 가리지 않는다.
        guard w.layer == 0, w.alpha > 0.05, area(w.bounds) > 12_000 else { return false }
        if w.processId == currentProcessId { return false }          // 자기 자신(월페이퍼 창)
        if ignoredOwners.contains(w.ownerName) { return false }       // 시스템 UI(Dock/제어센터 등)
        if isFinderDesktopHost(w, screenFrames: screenFrames) { return false }  // 아이콘 호스트만 예외
        // ponytail: 소형 오버레이는 위치 무관 최대변<=240 으로 예외(엣지 근접 검사 생략 — 좌표계 변환 회피).
        if max(w.bounds.width, w.bounds.height) <= 240 { return false }
        return true
    }

    /// Finder '데스크탑 호스트'(디스플레이 전체를 덮는 배경 호스트 창)만 예외.
    /// 대형 Finder 브라우저 창은 예외가 **아니다** — 그런 창은 데스크탑을 실제로 가린다.
    private static func isFinderDesktopHost(_ w: WindowSnapshot, screenFrames: [CGRect]) -> Bool {
        guard w.ownerName == "Finder" else { return false }
        return screenFrames.contains { area(w.bounds) >= area($0) * 0.95 }
    }

    private static func area(_ r: CGRect) -> Double { Double(r.width * r.height) }

    // MARK: - 라이브 스냅샷 (통합 지점)

    /// 현재 화면 상태로 데스크탑 가림 여부를 판정.
    func isDesktopVisible() -> Bool {
        Self.isDesktopVisible(
            windows: currentSnapshots(),
            currentProcessId: Int(ProcessInfo.processInfo.processIdentifier),
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    /// 온스크린 창 목록(데스크탑 요소 제외)을 스냅샷으로.
    private func currentSnapshots() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.map(WindowSnapshot.init)
    }
}

extension DesktopVisibilityMonitor.WindowSnapshot {
    /// CGWindowList dict → 스냅샷. 값 부재는 '가리지 않음' 쪽으로 안전 기본값(layer=max, alpha=1).
    init(_ dict: [String: Any]) {
        ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""
        processId = dict[kCGWindowOwnerPID as String] as? Int
        layer = dict[kCGWindowLayer as String] as? Int ?? Int.max
        alpha = dict[kCGWindowAlpha as String] as? Double ?? 1
        let b = dict[kCGWindowBounds as String] as? [String: Any]
        bounds = CGRect(
            x: b?["X"] as? Double ?? 0,
            y: b?["Y"] as? Double ?? 0,
            width: b?["Width"] as? Double ?? 0,
            height: b?["Height"] as? Double ?? 0
        )
    }
}

/// 데스크탑을 가리지 않는 시스템 UI 소유자(레이어0 이라도 예외).
private let ignoredOwners: Set<String> = [
    "Window Server", "Dock", "Control Center", "ControlCenter",
    "WindowManager", "Notification Center", "SystemUIServer",
    "AirPlayUIAgent", "Continuity", "ContinuityCaptureAgent"
]
