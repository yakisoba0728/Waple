import SwiftUI

/// notify() 메시지의 창 내 표시 모델. 메인 스레드 전용(AppDelegate·뷰에서만 접근).
final class StatusBannerModel: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var generation = 0

    func show(_ message: String) {
        self.message = message
        generation += 1
    }

    func dismiss() { message = nil }
}

/// WE식 상단 배너 — 어두운 패널 + 파랑 보더, 4초 후 자동 소멸.
struct WEStatusBanner: View {
    @ObservedObject var model: StatusBannerModel

    var body: some View {
        if let msg = model.message {
            Text(msg)
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textPrimary)
                .padding(.horizontal, WETheme.Metrics.hPad * 2)
                .padding(.vertical, 8)
                .background(WETheme.Colors.panel)
                .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                    .stroke(WETheme.Colors.accent, lineWidth: 1))
                .cornerRadius(WETheme.Metrics.corner)
                .padding(.top, WETheme.Metrics.titlebarH + 8)
                .task(id: model.generation) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    model.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
