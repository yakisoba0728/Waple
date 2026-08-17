import SwiftUI

/// Steam Web API 키 미설정 안내 — 둘러보기·창작마당 공용 게이트. 키는 Keychain(SteamAPIKeyStore)에만 저장.
///
/// ## 여기가 "무엇을 해야 하는가" 를 말하는 유일한 자리다
///
/// 종전에는 툴바의 검색 필드가 `disabled` 로 같은 사실을 한 번 더 말하고 있었다. 셸이
/// 시스템 서치필드로 바뀌면서 그 이중 안내가 사라졌고(대응 수정자가 없다), 그래서 남는
/// 안내는 이 화면 하나다. 키가 없으면 콘텐츠 자리를 통째로 이 화면이 차지하므로 놓칠 수 없다.
///
/// ## 커스텀 빈 상태를 시스템 것으로 바꿨다
///
/// 글리프 + 제목 + 설명 + 액션이라는 배치를 직접 쌓고 있었는데, 그건 `ContentUnavailableView`
/// 가 하는 일 그대로다(청사진 §3.1 — 빈 상태에 커스텀 금지). 시스템 것을 쓰면 이 앱의 다른
/// 빈 상태 셋과 위계·간격·글리프 크기가 저절로 맞고, Dynamic Type 과 라이트 모드도 따라온다.
/// 종전 `.font(.system(size: 34))` 고정 글리프는 큰 글씨 설정에서 혼자 안 커지던 자리였다.
struct APIKeyGateView: View {
    @ObservedObject var vm: WorkshopViewModel

    var body: some View {
        ContentUnavailableView {
            Label("Steam Web API 키가 필요합니다", systemImage: "key.fill")
        } description: {
            Text("워크샵을 검색하려면 본인 발급 API 키가 필요합니다. 아래에서 발급 후 붙여넣으세요. 키는 Keychain 에만 저장됩니다.")
        } actions: {
            entry
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entry: some View {
        VStack(spacing: Space.stackGap) {
            Link("API 키 발급: steamcommunity.com/dev/apikey",
                 destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
            SecureField("API 키 붙여넣기", text: $vm.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: Metrics.keyGateFieldWidth)
                .onSubmit { vm.saveAPIKey() }
            Button("저장") { vm.saveAPIKey() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            // 저장 실패 사유. 이미 번역된 문구다(§5.0 — SteamAPIKeyStore.SaveFailure.message).
            // 색은 상태를 **거드는** 것이지 혼자 나르지 않는다 — 문구가 원인을 그대로 말한다.
            if let message = vm.statusMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(ColorRole.destructive)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Metrics.keyGateTextWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
