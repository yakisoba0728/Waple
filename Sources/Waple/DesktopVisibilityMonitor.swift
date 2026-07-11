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

    /// 커버 비율 임계값 판정(작업 3). `threshold<=0` 이면 기존 동작(차단 창 1개라도 있으면 가림).
    /// `threshold>0` 이면 차단 창 합집합 커버 비율이 임계값 미만일 때만 데스크탑이 보인다고 본다
    /// (WaifuX 30–100% 관행 — 살짝 가린 정도로는 일시정지하지 않음).
    static func isDesktopVisible(
        windows: [WindowSnapshot],
        currentProcessId: Int,
        screenFrames: [CGRect],
        threshold: Double
    ) -> Bool {
        guard threshold > 0 else {
            return isDesktopVisible(windows: windows, currentProcessId: currentProcessId, screenFrames: screenFrames)
        }
        let blocking = windows
            .filter { isBlocking($0, currentProcessId: currentProcessId, screenFrames: screenFrames) }
            .map(\.bounds)
        return coverageRatio(blocking: blocking, screenFrames: screenFrames) < threshold
    }

    /// 차단 창들의 합집합 면적(화면에 클리핑) / 전체 화면 면적. 0…1. 화면 면적 0 → 0.
    /// 화면은 서로 겹치지 않으므로(타일링) 화면별 클리핑 후 합산이 곧 전역 커버 면적이다.
    static func coverageRatio(blocking: [CGRect], screenFrames: [CGRect]) -> Double {
        let screenArea = screenFrames.reduce(0.0) { $0 + area($1) }
        guard screenArea > 0 else { return 0 }
        var covered = 0.0
        for screen in screenFrames {
            let clipped = blocking.map { $0.intersection(screen) }.filter { !$0.isNull && !$0.isEmpty }
            covered += unionArea(clipped)
        }
        return min(1.0, covered / screenArea)
    }

    /// 사각형 합집합 면적(좌표 압축 — 정확, 겹침 중복 없음).
    /// ponytail: x-슬랩마다 y-구간 합집합을 재는 O(n²) 스윕. 창 수 n 이 작아 충분.
    static func unionArea(_ rects: [CGRect]) -> Double {
        let xs = Set(rects.flatMap { [Double($0.minX), Double($0.maxX)] }).sorted()
        guard xs.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(xs.count - 1) {
            let x0 = xs[i], x1 = xs[i + 1]
            let width = x1 - x0
            guard width > 0 else { continue }
            let midX = (x0 + x1) / 2
            let intervals = rects
                .filter { Double($0.minX) <= midX && midX <= Double($0.maxX) }
                .map { (Double($0.minY), Double($0.maxY)) }
            total += width * unionLength(intervals)
        }
        return total
    }

    /// 1D 구간 합집합 길이.
    static func unionLength(_ intervals: [(Double, Double)]) -> Double {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = sorted.first else { return 0 }
        var total = 0.0
        var curLo = first.0, curHi = first.1
        for (lo, hi) in sorted.dropFirst() {
            if lo > curHi {
                total += curHi - curLo
                curLo = lo; curHi = hi
            } else {
                curHi = Swift.max(curHi, hi)
            }
        }
        return total + (curHi - curLo)
    }

    /// CG 창 bounds(주화면 좌상단 원점·y 아래) → Cocoa(주화면 좌하단 원점·y 위) 플립.
    /// CGWindowList 는 CG 좌표, NSScreen.frame 은 Cocoa 좌표 — 무플립 교차는 주화면 위에 놓인
    /// 수직·혼합높이 멀티모니터에서 커버리지를 오산한다(P-B1). mainScreenHeight 는 '주화면' 높이
    /// (= NSScreen.screens.first frame.maxY = CGDisplayBounds(CGMainDisplayID()).height 규약).
    static func cocoaFlipped(_ bounds: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.origin.x, y: mainScreenHeight - bounds.origin.y - bounds.height,
               width: bounds.width, height: bounds.height)
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

    /// 현재 화면 상태로 데스크탑 가림 여부를 판정. `threshold` 기본 0 = 기존 동작(무회귀).
    func isDesktopVisible(threshold: Double = 0) -> Bool {
        Self.isDesktopVisible(
            windows: currentSnapshots(),
            currentProcessId: Int(ProcessInfo.processInfo.processIdentifier),
            screenFrames: NSScreen.screens.map(\.frame),
            threshold: threshold
        )
    }

    /// 온스크린 창 목록(데스크탑 요소 제외)을 스냅샷으로. bounds 는 Cocoa 로 플립해 담는다 —
    /// screenFrames(NSScreen.frame)와 같은 좌표계여야 교차·커버리지가 맞는다. threshold==0 경로는
    /// 면적/변 길이만 보므로 플립 무영향(무회귀).
    private func currentSnapshots() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let mainH = NSScreen.screens.first?.frame.maxY ?? 0
        return list.map(WindowSnapshot.init).map {
            WindowSnapshot(ownerName: $0.ownerName, processId: $0.processId, layer: $0.layer,
                           alpha: $0.alpha, bounds: Self.cocoaFlipped($0.bounds, mainScreenHeight: mainH))
        }
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
