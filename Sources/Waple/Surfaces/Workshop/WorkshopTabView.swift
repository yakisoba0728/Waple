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
        .background(ColorRole.well)
        .task(id: vm.hasAPIKey) { await vm.searchIfNeeded() }  // 키 게이트에서 저장 직후에도 자동 로드(디스커버와 동일 규약)
        .onChange(of: vm.sort) { _, _ in Task { await vm.search() } }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            WorkshopUtilityBar(vm: vm)
            // vm.statusMessage 는 생산 지점에서 이미 번역돼 있다 — 여기 붙는 오버로드는
            // 번역을 하지 않으므로(§5.0) 뷰가 뒤늦게 감쌀 수 있는 것이 아니다.
            if let message = vm.statusMessage {
                Text(message).font(Typography.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.contentInset)
                    .padding(.top, Space.controlGap)
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
            LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
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
            .padding(Space.contentInset)
            if vm.isLoadingMore {
                // 무한 스크롤은 보조기술에 조용하다 — 마지막 타일에 닿으면 onAppear 로 다음
                // 페이지가 붙지만, 라벨 없는 스피너는 "무엇이 진행 중인지" 를 말하지 않는다.
                // 글자를 띄우면 그리드 아래 레이아웃이 흔들리므로 이름만 붙인다.
                ProgressView().controlSize(.small)
                    .padding(.bottom, Space.lg)
                    .accessibilityLabel("더 불러오는 중")
            }
        }
    }
}
