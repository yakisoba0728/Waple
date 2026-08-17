import SwiftUI

/// notify() 메시지의 창 내 표시 모델. 메인 스레드 전용(AppDelegate·뷰에서만 접근).
final class StatusBannerModel: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var generation = 0

    func show(_ message: String) {
        withAnimation(Self.transitionAnimation) {
            self.message = message
            generation += 1
        }
    }

    func dismiss() {
        withAnimation(Self.transitionAnimation) { message = nil }
    }

    /// F093: 뷰의 `.transition(...)` 은 삽입/제거를 유발하는 상태변경이 애니메이션 트랜잭션 '안'에서
    /// 일어나야 발화한다(SwiftUI 규약). show/dismiss 가 일반 대입만 하던 종전 코드는 트랜지션 선언과
    /// 무관하게 매번 하드컷이었다 — AppDelegate.notify() 처럼 뷰 밖(임의 스레드 아닌 메인 스레드 컨텍스트)
    /// 에서 호출돼도 withAnimation 은 정상 동작한다(현재 실행 중인 트랜잭션에 애니메이션을 실어 보낼 뿐,
    /// View.body 내부일 필요는 없다).
    ///
    /// 2026-08-17: 곡선을 `Motion.fade` 로 옮겼다. 값은 같지만(0.2 이즈인아웃) 분기가 토큰
    /// 안으로 들어가 "동작 줄이기" 설정에서 짧은 페이드가 된다 — 여기서 직접 곡선을 만들면
    /// 그 설정이 이 자리만 무시된다. `let` 이 아니라 `var` 인 것은 설정이 실행 중에 바뀌기
    /// 때문이다(`let` 이면 앱 시작 시점의 값에 고정된다).
    static var transitionAnimation: Animation { Motion.fade }

    /// 배너 자동 소멸 타이머 본체(F092) — 뷰의 `.task(id: generation)` 가 세대마다 새로 호출한다.
    /// `sleep` 이 취소(CancellationError)로 던지면 dismiss 를 건너뛴다: 4초 내에 새 메시지가 연달아
    /// 뜨면(= generation 증가) SwiftUI 가 옛 태스크를 취소하는데, 종전엔 `try?` 로 이 취소를 삼키고
    /// 무조건 dismiss() 를 호출해 방금 표시된 새 메시지까지 함께 지워버렸다. sleep 을 주입해
    /// Task.sleep(4초) 없이도 정상 만료/취소 두 경로를 테스트할 수 있게 한다.
    func autoDismissAfterDelay(
        sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 4_000_000_000) }
    ) async {
        do {
            try await sleep()
            dismiss()
        } catch {
            // 취소됨(새 메시지로 대체) — dismiss 스킵. 새 태스크가 자기 몫의 4초를 새로 갖는다.
        }
    }
}

/// 네이티브 상태 배너 — 캡슐 재질, 4초 후 자동 소멸.
struct StatusBanner: View {
    @ObservedObject var model: StatusBannerModel

    var body: some View {
        if let msg = model.message {
            // ⚠️ msg 는 미현지화 String 이다 — AppDelegate.notify() 가 한국어 리터럴을 그대로
            // 넘기고, 이 오버로드는 번역하지 않는다. 생산 지점(notify 호출 40여 곳)을 감싸는
            // 것이 옳은 수정이고 그 파일은 Phase 3(Unit E) 소유라 여기서는 손대지 않는다.
            // 싱크 타입만 바꾸면 대입문이 되어 어떤 스캔 패턴에도 안 걸린다 — 런타임 버그
            // 하나를 고치면서 오라클 사각지대를 새로 파는 셈이라 그 길은 택하지 않는다.
            Label(msg, systemImage: "info.circle")
                .font(Typography.secondaryBody)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(Surface.overlay, in: Capsule())
                .overlay(Capsule().stroke(ColorRole.hairline, lineWidth: Surface.strokeHairline))
                .padding(.top, Space.md)
                .task(id: model.generation) { await model.autoDismissAfterDelay() }
                .transition(Motion.revealTransition(edge: .top))
        }
    }
}
