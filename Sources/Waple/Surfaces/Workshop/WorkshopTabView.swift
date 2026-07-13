import SwiftUI
import AppKit

/// 창작마당 탭 — 네이티브 그리드 + 무한 스크롤. 검색 필드·정렬 메뉴는 셸 툴바가 담당한다(MainWindowView).
struct WorkshopTabView: View {
    @ObservedObject var vm: WorkshopViewModel

    private let columns = [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing)]

    var body: some View {
        Group {
            if vm.hasAPIKey { browser } else { APIKeyGateView(vm: vm) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { await vm.searchIfNeeded() }
        .onChange(of: vm.sort) { _, _ in Task { await vm.search() } }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            utilityStrip
            if let message = vm.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            if vm.isSearching && vm.results.isEmpty {
                Spacer()
                ProgressView("검색 중…")
                Spacer()
            } else if vm.results.isEmpty {
                ContentUnavailableView("결과 없음", systemImage: "magnifyingglass",
                                       description: Text("툴바 검색창에 검색어를 입력하거나 정렬을 바꿔보세요."))
            } else {
                grid
            }
        }
    }

    /// steamcmd 상태 + 다운로드 계정 — 다운로드 전제조건이라 탭 안에 상시 노출(캡션 크기로 절제).
    private var utilityStrip: some View {
        HStack(spacing: Metrics.gap) {
            if !vm.steamcmdAvailable {
                Label("steamcmd 미설치 — `brew install steamcmd` 후 다시 실행", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Text("steamcmd 계정").font(.caption).foregroundStyle(.secondary)
            TextField("username", text: $vm.usernameInput)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .frame(width: Metrics.usernameFieldWidth)
                .help("다운로드용 Steam 계정. 최초 1회 터미널에서 `steamcmd +login <계정>` 으로 로그인해 세션을 캐시하세요 — 비밀번호는 앱이 저장하지 않습니다.")
            Button("API 키 변경") { vm.clearAPIKey() }
                .controlSize(.small)
                .help("Keychain 의 Steam Web API 키를 지우고 다시 입력")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, Metrics.gap)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Metrics.gridSpacing + 6) {
                ForEach(vm.results) { item in
                    RemoteTileView(item: item,
                                   download: vm.downloads[item.id],
                                   steamcmdAvailable: vm.steamcmdAvailable,
                                   onDownload: { vm.download(item) },
                                   onApply: { vm.apply(item) })
                        .onAppear {
                            if item.id == vm.results.last?.id { Task { await vm.loadMore() } }
                        }
                }
            }
            .padding(20)
            if vm.isLoadingMore {
                ProgressView().controlSize(.small).padding(.bottom, 16)
            }
        }
    }
}
