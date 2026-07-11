import AppKit

public final class ParallaxController {
    public var onOffset: ((CGPoint) -> Void)?
    /// 정규화 기준 화면(렌더러 뷰가 속한 화면). 미설정/nil 반환 시 NSScreen.main 폴백 —
    /// 보조 모니터 씬이 주모니터 기준으로 ±1 포화 고착되는 문제 방지. 매 emit 시 평가(창 이동 추종).
    public var screenProvider: (() -> NSScreen?)?
    private var monitor: Any?

    public init() {}

    // teardown() 없이 해제돼도 전역 모니터가 프로세스 수명 동안 남지 않도록 하는 안전망.
    deinit { stop() }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.emit()
        }
        emit()
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func emit() {
        let screen = screenProvider.flatMap { $0() } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        onOffset?(ParallaxController.normalizedOffset(mouse: NSEvent.mouseLocation, screenFrame: frame))
    }

    /// 화면 중심=0, 가장자리=±1, 밖은 클램프. (순수)
    public static func normalizedOffset(mouse: CGPoint, screenFrame: CGRect) -> CGPoint {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let nx = (mouse.x - screenFrame.midX) / (screenFrame.width / 2)
        let ny = (mouse.y - screenFrame.midY) / (screenFrame.height / 2)
        return CGPoint(x: min(max(nx, -1), 1), y: min(max(ny, -1), 1))
    }

    /// 카메라 시차 지수 스무딩 한 스텝(프레임 dt 기반). WE `cameraparallaxdelay` 재현.
    /// delay = 시상수(초). delay<=0 또는 dt<=0 → 즉시 target 반환(기존 즉시 반영 = 무회귀).
    /// 그 외 alpha = 1 - exp(-dt/delay) 로 target 쪽 지수 수렴 — framerate 독립(dt 배분과 무관하게 동일 곡선).
    /// (순수 — 유닛 테스트 대상. 상태는 호출자 renderer 가 프레임마다 current 를 갱신.)
    public static func smoothed(current: SIMD2<Float>, target: SIMD2<Float>,
                                dt: Float, delay: Float) -> SIMD2<Float> {
        guard delay > 0, dt > 0 else { return target }
        let alpha = 1 - exp(-dt / delay)
        return current + (target - current) * alpha
    }
}
