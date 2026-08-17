import SwiftUI
import AppKit

/// 검색(디스커버) 탭 — 정렬 4종 가로 레일. 키 게이트·다운로드 상태는 워크샵 VM 을 공유한다
/// (다운로드가 어느 탭에서 시작됐든 같은 진행 상태가 보인다).
struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject var workshopVM: WorkshopViewModel

    var body: some View {
        Group {
            if workshopVM.hasAPIKey { browser } else { APIKeyGateView(vm: workshopVM) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
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
            LazyVStack(alignment: .leading, spacing: Metrics.gridSpacing + 6) {
                // 이미 번역된 문구다(§5.0) — 워크샵 VM 이 만들 때 감싼다.
                if let message = workshopVM.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                ForEach(vm.rows) { row in section(row) }
            }
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private func section(_ row: DiscoverViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
            switch row.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Metrics.tileThumbHeight)
            case .failed(let message):
                HStack(spacing: Metrics.gap) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button("다시 시도") { Task { await vm.reload(row.sort) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 20)
            case .loaded(let items):
                if items.isEmpty {
                    // 네이티브 빈 상태(w5d-polish) — WorkshopTabView:33 과 동일한 ContentUnavailableView 문법.
                    ContentUnavailableView("항목이 없습니다", systemImage: "square.grid.2x2",
                                           description: Text("나중에 다시 확인해보세요."))
                        .frame(maxWidth: .infinity, minHeight: Metrics.tileThumbHeight)
                } else {
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
                        .padding(.horizontal, 20)
                        .padding(.vertical, Metrics.gap)   // 호버 리프트 그림자 클리핑 여유
                    }
                }
            }
        }
    }
}
