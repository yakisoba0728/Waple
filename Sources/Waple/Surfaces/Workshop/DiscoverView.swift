import SwiftUI
import AppKit

/// 둘러보기 표면 — 정렬 4종 가로 레일. 키 게이트·다운로드 상태는 워크샵 VM 을 공유한다
/// (다운로드가 어느 표면에서 시작됐든 같은 진행 상태가 보인다).
struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject var workshopVM: WorkshopViewModel

    var body: some View {
        Group {
            if workshopVM.hasAPIKey { browser } else { APIKeyGateView(vm: workshopVM) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorRole.well)
        .task(id: workshopVM.hasAPIKey) {
            if workshopVM.hasAPIKey { await vm.loadIfNeeded() }
        }
    }

    /// 유틸리티 바가 여기에도 있는 이유는 그 파일 주석 참조 — 레일에서 다운로드를 시작한
    /// 사용자에게 계정 입력 자리가 없어 안내가 막다른 길이었다.
    private var browser: some View {
        VStack(spacing: 0) {
            WorkshopUtilityBar(vm: workshopVM)
            rails
        }
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.gridRowSpacing) {
                // 이미 번역된 문구다(§5.0) — 워크샵 VM 이 만들 때 감싼다.
                if let message = workshopVM.statusMessage {
                    Text(message).font(Typography.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.contentInset)
                }
                ForEach(vm.rows) { row in section(row) }
            }
            .padding(.vertical, Space.contentInset)
        }
    }

    @ViewBuilder
    private func section(_ row: DiscoverViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.controlGap) {
            // 굵은 글씨는 눈에만 제목이다 — SectionHeader 가 붙이는 헤더 트레잇이 있어야
            // 로터의 제목 탐색으로 레일 사이를 건너뛸 수 있다. 레일이 넷이라 이게 실질이다.
            SectionHeader(title: Text(row.title))
                .padding(.horizontal, Space.contentInset)
            switch row.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Metrics.tileThumbHeight)
                    .accessibilityLabel("불러오는 중")
            case .failed(let message):
                HStack(spacing: Space.controlGap) {
                    // message 는 이미 번역돼 있다(DiscoverViewModel.RowState.failed).
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption).foregroundStyle(ColorRole.warning)
                    Button("다시 시도") { Task { await vm.reload(row.sort) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, Space.contentInset)
            case .loaded(let items):
                if items.isEmpty {
                    // 네이티브 빈 상태(w5d-polish) — WorkshopTabView 와 동일한 문법.
                    ContentUnavailableView("항목이 없습니다", systemImage: "square.grid.2x2",
                                           description: Text("나중에 다시 확인해보세요."))
                        .frame(maxWidth: .infinity, minHeight: Metrics.tileThumbHeight)
                } else {
                    rail(items)
                }
            }
        }
    }

    /// 가로 레일. 타일이 포커스 가능해졌으므로 탭 이동만으로 레일 안을 훑을 수 있고, 화면 밖
    /// 타일로 포커스가 가면 스크롤뷰가 알아서 따라온다 — 커스텀 포커스 관리를 두지 않는 이유다.
    private func rail(_ items: [WorkshopItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                ForEach(items) { item in
                    RemoteTileView(item: item,
                                   download: workshopVM.downloads[item.id],
                                   steamcmdAvailable: workshopVM.steamcmdAvailable,
                                   onDownload: { workshopVM.download(item) },
                                   onApply: { workshopVM.apply(item) })
                        .frame(width: Metrics.tileWidth)   // 레일은 고정폭 타일
                }
            }
            .padding(.horizontal, Space.contentInset)
            .padding(.vertical, Space.controlGap)   // 호버 리프트 그림자 클리핑 여유
        }
    }
}
