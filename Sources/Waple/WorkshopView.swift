import SwiftUI
import AppKit
import WapleLibrary

// MARK: - 창

struct WorkshopView: View {
    @StateObject private var vm: WorkshopViewModel

    init(library: LibraryViewModel, client: WorkshopClient = .live()) {
        _vm = StateObject(wrappedValue: WorkshopViewModel(client: client, library: library))
    }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        Group {
            if vm.hasAPIKey { browser } else { apiKeySetup }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    // 검색 + 그리드
    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("워크샵 검색", text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.search() } }
                Picker("정렬", selection: $vm.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("검색") { Task { await vm.search() } }
                    .disabled(vm.isSearching)
                Button("API 키 변경") { vm.clearAPIKey() }
            }
            .padding()

            if !vm.steamcmdAvailable {
                banner("steamcmd 가 설치되어 있지 않습니다 — 터미널에서 `brew install steamcmd` 후 앱을 다시 실행하세요.")
            }
            HStack {
                Text("steamcmd 계정").foregroundColor(.secondary).font(.caption)
                TextField("username", text: $vm.usernameInput)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Text("최초 1회 터미널에서 `steamcmd +login <계정>` 로 로그인해 세션을 캐시하세요(비밀번호는 앱이 저장하지 않습니다).")
                    .foregroundColor(.secondary).font(.caption)
                Spacer()
            }
            .padding(.horizontal)

            if let message = vm.statusMessage {
                Text(message).foregroundColor(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 4)
            }

            if vm.isSearching {
                Spacer(); ProgressView("검색 중…"); Spacer()
            } else if vm.results.isEmpty {
                Spacer()
                Text("검색어를 입력하고 검색하세요.").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(vm.results) { tile(for: $0) }
                    }
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for item: WorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkshopPreview(url: item.previewURL)
                .frame(height: 120).frame(maxWidth: .infinity).clipped().cornerRadius(8)
            Text(item.title).font(.caption).lineLimit(1)
            if let subs = item.subscriptions {
                Text("구독 \(subs)").font(.caption2).foregroundColor(.secondary)
            }
            downloadControl(for: item)
        }
    }

    @ViewBuilder
    private func downloadControl(for item: WorkshopItem) -> some View {
        switch vm.downloads[item.id]?.phase {
        case nil:
            Button("다운로드") { vm.download(item) }
                .disabled(!vm.steamcmdAvailable)
        case .downloading(let v):
            if let v { ProgressView(value: v, total: 100) { Text("다운로드 중 \(Int(v))%").font(.caption2) } }
            else { ProgressView { Text("다운로드 중…").font(.caption2) } }
        case .verifying:
            ProgressView { Text("검증 중…").font(.caption2) }
        case .committing:
            ProgressView { Text("설치 중…").font(.caption2) }
        case .importing:
            ProgressView { Text("가져오는 중…").font(.caption2) }
        case .done:
            Button("적용") { vm.apply(item) }
        case .failed:
            Button("다시 시도") { vm.download(item) }
        }
    }

    // API 키 미설정 안내
    private var apiKeySetup: some View {
        VStack(spacing: 12) {
            Text("Steam Web API 키가 필요합니다").font(.headline)
            Text("워크샵을 검색하려면 본인 발급 API 키가 필요합니다. 아래에서 발급 후 붙여넣으세요. 키는 Keychain 에만 저장됩니다.")
                .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Link("API 키 발급: steamcommunity.com/dev/apikey",
                 destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
            SecureField("API 키 붙여넣기", text: $vm.apiKeyInput)
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { vm.saveAPIKey() }
            Button("저장") { vm.saveAPIKey() }
                .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = vm.statusMessage {
                Text(message).foregroundColor(.red).font(.caption)
            }
        }
        .padding()
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(Color.orange.opacity(0.12)).padding(.horizontal)
    }
}
