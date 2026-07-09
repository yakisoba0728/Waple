import SwiftUI
import AppKit
import WapleLibrary

// Steam 워크샵 브라우즈·다운로드·임포트 창. 순수 로직(WorkshopAPI/SteamCmdDownloader)을 얇게 배선한다.
// @MainActor — async 클라이언트/다운로더 콜백이 오프메인에서 재개되므로 @Published 변경을 전부 메인으로 모은다.

@MainActor
final class WorkshopViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var sort: WorkshopSort = .subscriptions
    @Published private(set) var results: [WorkshopItem] = []
    @Published private(set) var isSearching = false
    @Published var statusMessage: String?
    @Published private(set) var hasAPIKey: Bool
    @Published var apiKeyInput = ""
    @Published var usernameInput: String
    @Published private(set) var downloads: [String: DownloadUIState] = [:]

    let steamcmdAvailable = SteamCmdDownloader.isAvailable

    private let client: WorkshopClient
    private let library: LibraryViewModel

    struct DownloadUIState: Equatable {
        enum Phase: Equatable {
            case downloading(Double?), verifying, committing, importing, done, failed
        }
        var phase: Phase
        var entryId: String?   // 임포트된 라이브러리 엔트리 id(적용용)
    }

    init(client: WorkshopClient, library: LibraryViewModel) {
        self.client = client
        self.library = library
        self.hasAPIKey = SteamAPIKeyStore.load() != nil
        self.usernameInput = SteamCmdDownloader.username
    }

    // MARK: - API 키

    func saveAPIKey() {
        SteamAPIKeyStore.save(apiKeyInput)
        hasAPIKey = SteamAPIKeyStore.load() != nil
        if hasAPIKey {
            apiKeyInput = ""
            statusMessage = nil
        } else {
            statusMessage = "API 키를 저장하지 못했습니다."
        }
    }

    func clearAPIKey() {
        SteamAPIKeyStore.save("")
        hasAPIKey = false
        results = []
    }

    // MARK: - 검색

    func search() async {
        guard let key = SteamAPIKeyStore.load() else { hasAPIKey = false; return }
        isSearching = true
        statusMessage = nil
        defer { isSearching = false }
        do {
            results = try await client.search(apiKey: key, searchText: searchText, sort: sort)
            if results.isEmpty { statusMessage = "결과가 없습니다." }
        } catch {
            results = []
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "검색 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - 다운로드 → 임포트 → 적용

    func download(_ item: WorkshopItem) {
        guard steamcmdAvailable else {
            statusMessage = "steamcmd 가 필요합니다: brew install steamcmd"; return
        }
        let username = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            statusMessage = "steamcmd 로그인 계정(username)을 먼저 입력하세요."; return
        }
        SteamCmdDownloader.username = username
        downloads[item.id] = DownloadUIState(phase: .downloading(nil), entryId: nil)
        SteamCmdDownloader.download(
            itemId: item.id, username: username,
            progress: { [weak self] p in Task { @MainActor in self?.applyProgress(item.id, p) } },
            completion: { [weak self] url in Task { @MainActor in self?.finishDownload(item, url) } }
        )
    }

    private func applyProgress(_ id: String, _ p: SteamCmdDownloader.Progress) {
        guard var state = downloads[id], state.phase != .done else { return }
        switch p {
        case .downloading(let v): state.phase = .downloading(v)
        case .verifying: state.phase = .verifying
        case .committing: state.phase = .committing
        case .success: state.phase = .importing
        case .failed: state.phase = .failed
        }
        downloads[id] = state
    }

    private func finishDownload(_ item: WorkshopItem, _ url: URL?) {
        guard let url else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            statusMessage = "‘\(item.title)’ 다운로드 실패 — 터미널에서 `steamcmd +login \(usernameInput)` 로 1회 로그인해 세션을 캐시했는지 확인하세요."
            return
        }
        guard let entry = library.importDownloaded(url) else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            return
        }
        downloads[item.id] = DownloadUIState(phase: .done, entryId: entry.id)
    }

    func apply(_ item: WorkshopItem) {
        guard let entryId = downloads[item.id]?.entryId,
              let entry = library.entries.first(where: { $0.id == entryId }) else { return }
        _ = library.apply(entry)
    }
}

// MARK: - 프리뷰 이미지(URLSession 비동기 로드 + NSCache — LazyVGrid 셀 재활용 시 재다운로드 방지)

private enum WorkshopPreviewCache {
    static let cache = NSCache<NSURL, NSImage>()
}

private struct WorkshopPreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.25))
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = WorkshopPreviewCache.cache.object(forKey: url as NSURL) { image = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        WorkshopPreviewCache.cache.setObject(img, forKey: url as NSURL)
        image = img
    }
}

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
