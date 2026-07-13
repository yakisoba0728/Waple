import SwiftUI

/// Steam Web API 키 미설정 안내 — 검색·창작마당 탭 공용 게이트. 키는 Keychain(SteamAPIKeyStore)에만 저장.
struct APIKeyGateView: View {
    @ObservedObject var vm: WorkshopViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Steam Web API 키가 필요합니다").font(.title3.weight(.semibold))
            Text("워크샵을 검색하려면 본인 발급 API 키가 필요합니다. 아래에서 발급 후 붙여넣으세요. 키는 Keychain 에만 저장됩니다.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.keyGateTextWidth)
            Link("API 키 발급: steamcommunity.com/dev/apikey",
                 destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
            SecureField("API 키 붙여넣기", text: $vm.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: Metrics.keyGateFieldWidth)
                .onSubmit { vm.saveAPIKey() }
            Button("저장") { vm.saveAPIKey() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = vm.statusMessage {
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
