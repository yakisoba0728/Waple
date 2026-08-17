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
        .task(id: vm.hasAPIKey) { await vm.searchIfNeeded() }  // 키 게이트에서 저장 직후에도 자동 로드(디스커버와 동일 규약)
        .onChange(of: vm.sort) { _, _ in Task { await vm.search() } }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            WorkshopUtilityBar(vm: vm)
            // vm.statusMessage 는 생산 지점에서 이미 번역돼 있다 — 여기 붙는 오버로드는
            // 번역을 하지 않으므로(§5.0) 뷰가 뒤늦게 감쌀 수 있는 것이 아니다.
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
