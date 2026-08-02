import SwiftUI
import AppKit

// MARK: - 원격 프리뷰(URLSession 비동기 로드 + NSCache — 셀 재활용 시 재다운로드 방지)
// 레거시 WorkshopView 에서 이동, 디스커버·창작마당 공용이라 internal 로 승격.

enum WorkshopPreviewCache {
    static let cache = NSCache<NSURL, NSImage>()
}

struct WorkshopPreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                Image(systemName: "photo").foregroundStyle(.tertiary)
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

// MARK: - 원격 타일(디스커버 레일·창작마당 그리드 공용)
// 설치됨 타일(WallpaperGridView.tile)과 같은 문법: 라운드 썸네일 + 제목 아래 + 호버 리프트.
// 폭은 소비자가 정한다 — 그리드는 셀에 맞춰 늘어나고, 레일은 .frame(width: Metrics.tileWidth) 고정.

struct RemoteTileView: View {
    let item: WorkshopItem
    let download: WorkshopViewModel.DownloadUIState?
    let steamcmdAvailable: Bool
    var onDownload: () -> Void
    var onApply: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb
            Text(item.title)
                .font(.caption)
                .foregroundStyle(hovered ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
            HStack(spacing: 4) {
                if let subs = item.subscriptions {
                    Label(subs.formatted(), systemImage: "person.2")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(String(format: NSLocalizedString("구독 %@", comment: "워크샵 구독 수"), subs.formatted()))
                }
                Spacer(minLength: 4)
                control
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.45 : 0), radius: 9, y: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
    }

    private var thumb: some View {
        WorkshopPreview(url: item.previewURL)
            .frame(height: Metrics.tileThumbHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .stroke(hovered ? Color.secondary.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if let score = item.voteScore { ratingBadge(score) }
            }
    }

    /// 스팀 투표 점수(0~1)를 별 5점 환산 표시 — 표시만, 투표 액션 없음(스펙 기능 매핑).
    private func ratingBadge(_ score: Double) -> some View {
        Label(String(format: "%.1f", score * 5), systemImage: "star.fill")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.yellow)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
            .help(String(format: "평점 %.1f/5", score * 5))
    }

    @ViewBuilder
    private var control: some View {
        switch download?.phase {
        case nil:
            Button("다운로드", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!steamcmdAvailable)
                .help(steamcmdAvailable ? "steamcmd 로 다운로드해 라이브러리에 추가"
                                        : "steamcmd 가 필요합니다: brew install steamcmd")
        case .downloading(let v):
            if let v {
                ProgressView(value: v, total: 100)
                    .frame(width: Metrics.downloadBarWidth)
                    .help(String(format: NSLocalizedString("다운로드 중 %lld%%", comment: "다운로드 진행률"), Int(v)))
            } else {
                stage("다운로드 중")
            }
        case .verifying: stage("검증 중")
        case .committing: stage("설치 중")
        case .importing: stage("가져오는 중")
        case .done:
            Button("적용", action: onApply)
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Button("다시 시도", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func stage(_ label: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
