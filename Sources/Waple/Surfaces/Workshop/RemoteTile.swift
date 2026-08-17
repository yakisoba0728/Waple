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
            .help(Self.ratingText(score))
    }

    /// 평점 툴팁·접근성 문구. 종전 `String(format: "평점 %.1f/5", …)` 는 `NSLocalizedString`
    /// 밖이라 어떤 스캔 패턴에도 걸리지 않았고, 그래서 번역이 없는 줄 아무도 몰랐다.
    static func ratingText(_ score: Double) -> String {
        String(format: NSLocalizedString("평점 %.1f/5", comment: "스팀 투표 점수를 별 5점으로 환산"),
               score * 5)
    }

    @ViewBuilder
    private var control: some View {
        switch download?.phase {
        case nil:
            Button("다운로드", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!steamcmdAvailable)
                // 삼항으로 **문자열 리터럴**을 고르면 `(` 바로 뒤가 `"` 가 아니라 스캐너가 둘 다
                // 놓친다(§5.3 사각지대). 생산 지점에서 감싸면 패턴 1 이 양쪽을 잡는다.
                .help(steamcmdAvailable
                      ? NSLocalizedString("steamcmd 로 다운로드해 라이브러리에 추가",
                                          comment: "다운로드 버튼 툴팁")
                      : NSLocalizedString("steamcmd 가 필요합니다: brew install steamcmd",
                                          comment: "다운로더 미설치로 버튼 비활성"))
        case .downloading(let v):
            if let v {
                ProgressView(value: v, total: 100)
                    .frame(width: Metrics.downloadBarWidth)
                    .help(Self.progressText(v))
            } else {
                stage(Text("다운로드 중"))
            }
        case .verifying: stage(Text("검증 중"))
        case .committing: stage(Text("설치 중"))
        case .importing: stage(Text("가져오는 중"))
        case .done:
            Button("적용", action: onApply)
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Button("다시 시도", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    static func progressText(_ percent: Double) -> String {
        String(format: NSLocalizedString("다운로드 중 %lld%%", comment: "다운로드 진행률"), Int(percent))
    }

    /// 파라미터가 `String` 이 아니라 `Text` 인 이유: `Text(someString)` 는 비현지화 오버로드라
    /// 호출부의 한국어 리터럴이 조용히 번역을 잃는다. `Text` 로 받으면 리터럴이 호출부에 남아
    /// `LocalizedStringKey` 로 해석되고 커버리지 스캐너에도 잡힌다(공유 컴포넌트와 같은 규약).
    private func stage(_ label: Text) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            label.font(.caption2).foregroundStyle(.secondary)
        }
    }
}
