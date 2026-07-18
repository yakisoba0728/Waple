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
    static let transitionAnimation: Animation = .easeInOut(duration: 0.2)

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
            Label(msg, systemImage: "info.circle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .padding(.top, 10)
                .task(id: model.generation) { await model.autoDismissAfterDelay() }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
