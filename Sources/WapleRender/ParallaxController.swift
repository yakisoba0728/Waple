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

    /// 카메라 시차 스무딩 한 스텝(프레임 dt 기반). WE `cameraparallaxdelay` 재현.
    ///
    /// **[정정 2026-08-21] `delay` 는 시상수가 아니라 수렴률의 역파라미터다.**
    /// 종전 구현은 `alpha = 1 − exp(−dt/delay)`(시상수 = delay 초)였는데 실물은 다르다
    /// (`0x140189c0d`–`0x140189c75`, 근거 전문은 `docs/re/camera-motion.md` §2):
    ///
    ///     0x140189c0d  movss  xmm0, [rbx+0x338]   ; delay
    ///     0x140189c15  comiss xmm0, xmm5 / jbe    ; delay <= 0 → 즉시 반영(스무딩 건너뜀)
    ///     0x140189c2e  divss  xmm0, xmm11         ; xmm11 = 3.0 (0x1401899b1 ← 0x140492830)
    ///     0x140189c37  subss  xmm4, xmm0          ; 1 − delay/3      (xmm15 = 1.0)
    ///     0x140189c3b  mulss  xmm4, [0x140492868] ; × 10.0
    ///     0x140189c43  mulss  xmm4, xmm6          ; × dt
    ///     0x140189c47  comiss xmm15, xmm4 / ja    ; alpha = min(1, ·)   ← **상한만 있다**
    ///     0x140189c61  subss / mulss / addss      ; prev + (target − prev) * alpha
    ///
    /// 즉 `alpha = min(1, 10 · (1 − delay/3) · dt)` 다. 기본값 0.1 에서는 실효 시상수가
    /// 0.1034s 라 종전 식(0.100s)과 3.4% 밖에 안 갈려 **우연히 맞아 보였다**. 코퍼스에 하나
    /// 있는 `delay: 1` 에서는 스텝당 진행이 0.1111 vs 0.0165 로 **6.7배** 어긋난다.
    ///
    /// **하한 클램프를 넣지 않는다.** 실물은 `ja` 로 상한 1 만 건다. 그래서 `delay == 3` 이면
    /// alpha 가 정확히 0 이라 **영구 정지**하고, `delay > 3` 이면 음수가 되어 target 반대쪽으로
    /// **발산**한다. 클램프를 넣으면 그 지점에서 실물과 갈리므로 넣지 않는다(`snoise3` 동점
    /// 결함과 같은 판단). 동봉·설치본 도달은 `0.1` 이 176건 · `1` 이 1건뿐이고 **3 이상은 0건**이라
    /// 이 발산 구간에 닿는 자산은 없다.
    ///
    /// `dt <= 0` 도 실물과 같게 뒀다 — 실물엔 dt 가드가 없고 alpha 가 0 이 되어 **current 를
    /// 그대로 돌려준다**(종전 구현은 target 을 즉시 반환해 시간이 안 흘렀는데 순간이동했다).
    ///
    /// (순수 — 유닛 테스트 대상. 상태는 호출자 renderer 가 프레임마다 current 를 갱신.)
    public static func smoothed(current: SIMD2<Float>, target: SIMD2<Float>,
                                dt: Float, delay: Float) -> SIMD2<Float> {
        guard delay > 0 else { return target }
        let alpha = min(1, 10 * (1 - delay / 3) * dt)
        return current + (target - current) * alpha
    }
}
