import SwiftUI
import AppKit

// MARK: - 원격 프리뷰(URLSession 비동기 로드 + NSCache — 셀 재활용 시 재다운로드 방지)
// 레거시 WorkshopView 에서 이동, 디스커버·창작마당 공용이라 internal 로 승격.
//
// 공유 컴포넌트 PreviewThumbnail 로 합치지 **않았다**. 저쪽은 로컬 파일을 NSImage(contentsOf:)
// 로 여는 F500 패턴이고 이쪽은 스팀 CDN 에서 URLSession 으로 받는다 — 캐시 키만 같아 보일 뿐
// 실패 모드(디스크 읽기 실패 vs 네트워크 오류)와 재시도 정책이 다르다. 억지로 합치면 한쪽의
// 사정이 다른 쪽 코드에 조건으로 남는다. 청사진 §3.2 가 PreviewThumbnail 의 대체 대상으로
// 지목한 것도 그리드·디스플레이의 로컬 썸네일 두 벌이지 이것이 아니다.

enum WorkshopPreviewCache {
    /// `nonisolated(unsafe)` 근거: `NSCache` 는 자체 락으로 스레드 안전(Apple 문서 보증)이고
    /// 참조는 `let` 이라 재대입이 없다. 컴파일러가 그 락을 볼 수 없을 뿐이다
    /// (`PreviewImageCache`·`AnimatedImageCache` 와 같은 근거).
    nonisolated(unsafe) static let cache = NSCache<NSURL, NSImage>()
}

struct WorkshopPreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(ColorRole.placeholderFill)
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        // 썸네일은 장식이다 — 항목 이름은 타일이 읽는다. 라벨 없는 이미지를 남겨 두면
        // children: .combine 이 그걸 흡수해 SF Symbol 이름이 항목 이름에 섞인다.
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        // F840: 원격이 준 문자열에서 만든 URL 이다. URLSession 은 file:// 도 그대로 처리하므로
        // 스킴 검증 없이 넘기면 원격이 지목한 로컬 파일을 앱이 읽어 타일에 그린다(로컬 파일 노출).
        // 파서(WorkshopResponseParser)에서 이미 https 만 통과시키지만, 여기서도 한 번 더 확인한다 —
        // 이 뷰는 임의의 URL 을 받을 수 있는 공개 소비자다(NowPlayingProvider.isValidArtworkURL, F564 와 동일 정책).
        guard let url, url.scheme?.lowercased() == "https" else { return }
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
//
// ## 2026-08-17 개편 — 복제를 공유 컴포넌트로 넘긴다
//
// 호버 리프트(확대 + 그림자 + 스프링)가 설치됨 타일과 **바이트 단위로 같은 코드**였고, 링을
// 그리는 삼항과 썸네일 클립 3연타도 각자 적혀 있었다. 값이 우연히 같아서 한쪽만 바뀌어도
// 아무도 모르는 상태였다 — Surface.tileLift / TileRing / tileThumbnailClip 이 그걸 받는다.
// 여기 있던 생 스프링 곡선은 동작 줄이기 설정을 통째로 무시하던 자리이기도 하다. 토큰 안에
// 그 분기가 들어 있으므로 리프트를 넘기는 것만으로 함께 낫는다.
//
// ⚠️ 이 파일의 주석에 규약 API 이름을 원문 그대로 적지 마라. 규약 오라클은 소스 전문을
// 텍스트로 훑기 때문에 주석 속 이름도 코드로 센다 — 양방향으로 거짓말을 만든다.
//
// ## 수치 두 개를 썸네일 위로 올렸다
//
// 종전에는 구독 수만 제목 아래 캡션 줄에 있고 평점만 썸네일 위에 있었다. 둘 다 같은 급의
// 메타데이터인데 위치가 갈려 있었고, 캡션 줄에 수치와 액션 버튼이 섞여 무엇이 정보이고
// 무엇이 조작인지 흐렸다. 수치는 배지로 썸네일 위에, 캡션 아래 줄은 조작 하나만 둔다.
// MetricBadge 의 재질 캡슐도 아래 이미지가 비쳐야 뜻이 사는 형태라 그 자리가 맞다.

struct RemoteTileView: View {
    let item: WorkshopItem
    let download: WorkshopViewModel.DownloadUIState?
    let steamcmdAvailable: Bool
    var onDownload: () -> Void
    var onApply: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            thumb
            Text(item.title)
                .font(Typography.caption)
                .foregroundStyle(hovered ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, Space.captionInset)
            HStack(spacing: Space.xxs) {
                Spacer(minLength: Space.xxs)
                control
            }
            .padding(.horizontal, Space.captionInset)
        }
        .tileLift(hovered)
        .onHover { hovered = $0 }
        .tileAccessibility(label: accessibilityTitle,
                           value: statusValue,
                           onActivate: primaryAction)
        // [2026-08-25] 실패 사유는 **툴팁으로만** 보여준다.
        //
        // `statusValue` 에 실으면 VoiceOver 가 타일마다 100자 넘는 문장을 전부 읽는다 —
        // 목록을 훑는 것이 불가능해진다. 그래서 접근성 값은 종전 "다운로드 실패" 를 유지하고,
        // 전문은 마우스로 가져가면 나오는 `.help()` 에 둔다. 화면 전역 캡션(`statusMessage`)에도
        // 같은 문장이 있지만, 여러 개를 동시에 받다 실패하면 **어느 타일의 사유인지** 그쪽으로는
        // 알 수 없다 — 그게 타일에 붙이는 이유다.
        .help(download?.failureReason ?? "")
        .focused($focused)
        // tileAccessibility 는 Return 키만 배선한다. 보조기술의 '활성화'(VO-Space)는 키 이벤트가
        // 아니라 기본 액션이라, 그 자리를 따로 채우지 않으면 아래 버튼이 combine 에 흡수된 뒤
        // 눌러 볼 방법이 사라진다.
        .accessibilityAction { primaryAction?() }
    }

    /// ## 폭을 이미지가 아니라 컨테이너가 정하게 한다 (2026-08-17 캡처로 발견)
    ///
    /// 종전에는 프리뷰 자체에 `frame(maxWidth: .infinity)` 를 걸었다. 그리드에서는 셀이 확정
    /// 폭을 내려주므로 맞게 잘렸지만, **가로 레일에서는 제안 폭이 없어** 그 프레임이 이미지의
    /// 고유 폭(꽉 채우기 종횡비 × 썸네일 높이 ≈ 222pt)으로 확정됐다. 타일에 걸린 200pt 는
    /// 배치만 200 으로 만들 뿐 이미 222 로 잘린 그림을 줄이지 못해, 양옆으로 11pt 씩 삐져나와
    /// **타일 사이 간격 14pt 를 통째로 덮었다** — 레일 타일이 서로 맞붙어 보이던 원인이다.
    ///
    /// 고유 크기가 없는 면을 먼저 깔고 그림을 그 위에 얹으면, 폭은 항상 위에서 내려온 제안이
    /// 정한다. 그리드는 셀 폭, 레일은 타일 폭 — 두 소비자 모두 자기가 아는 값으로 자른다.
    private var thumb: some View {
        Color.clear
            .frame(height: Metrics.tileThumbHeight)
            .frame(maxWidth: .infinity)
            .overlay { WorkshopPreview(url: item.previewURL) }
            .tileThumbnailClip(corner: Surface.tileCorner)
            // selected 가 늘 false 인 것은 의도다 — 원격 타일에는 '적용 중' 이라는 상태가 없다.
            // 다운로드가 끝난 항목은 라이브러리 타일이 그 사실을 말한다. 여기서 .done 을 선택으로
            // 칠하면 두 화면이 서로 다른 뜻으로 같은 링을 쓰게 된다.
            .tileRing(TileRing.tile(selected: false, focused: hovered || focused))
            .overlay(alignment: .topLeading) { subscriptionsBadge }
            .overlay(alignment: .topTrailing) { ratingBadge }
    }

    /// 스팀 투표 점수(0~1)를 별 5점 환산 표시 — 표시만, 투표 액션 없음(스펙 기능 매핑).
    @ViewBuilder
    private var ratingBadge: some View {
        if let score = item.voteScore {
            MetricBadge(symbol: "star.fill",
                        value: Text(String(format: "%.1f", score * 5)),
                        label: Text("평점"))
                .foregroundStyle(ColorRole.rating)
                .help(Self.ratingText(score))
        }
    }

    @ViewBuilder
    private var subscriptionsBadge: some View {
        if let subs = item.subscriptions {
            MetricBadge(symbol: "person.2",
                        value: Text(subs.formatted()),
                        label: Text("구독"))
                .help(Self.subscriptionsText(subs))
        }
    }

    /// 평점 툴팁·접근성 문구. 종전 `String(format: "평점 %.1f/5", …)` 는 `NSLocalizedString`
    /// 밖이라 어떤 스캔 패턴에도 걸리지 않았고, 그래서 번역이 없는 줄 아무도 몰랐다.
    static func ratingText(_ score: Double) -> String {
        String(format: NSLocalizedString("평점 %.1f/5", comment: "스팀 투표 점수를 별 5점으로 환산"),
               score * 5)
    }

    static func subscriptionsText(_ subscriptions: Int) -> String {
        String(format: NSLocalizedString("구독 %@", comment: "워크샵 구독 수"), subscriptions.formatted())
    }

    static func progressText(_ percent: Double) -> String {
        String(format: NSLocalizedString("다운로드 중 %lld%%", comment: "다운로드 진행률"), Int(percent))
    }

    // MARK: - 접근성
    //
    // 타일은 children: .combine 로 요소 하나가 되고 그 위에 label 을 **명시**하므로, 배지가
    // 자기 몫으로 붙인 이름·값은 덮여서 읽히지 않는다. MetricBadge 가 label 과 value 를 나눠
    // 받는 것은 배지 단독으로 쓰일 때의 규약이고, 타일 안에서는 타일이 다시 엮어야 한다.
    // 평점·구독 수는 바뀌지 않는 그 항목의 속성이라 value 가 아니라 label 쪽이다 —
    // value 에 넣으면 다운로드가 진행될 때마다 수치까지 다시 읽힌다(§4.2).

    private var accessibilityTitle: Text {
        var text = Text(item.title)
        if let score = item.voteScore {
            text = text + Text(", ") + Text(Self.ratingText(score))
        }
        if let subs = item.subscriptions {
            text = text + Text(", ") + Text(Self.subscriptionsText(subs))
        }
        return text
    }

    /// 지금 어떤 상태인가. 아직 손대지 않은 항목은 nil — 빈 값을 넣으면 빈 칸이 읽힌다.
    private var statusValue: Text? {
        switch download?.phase {
        case nil: return nil
        case .downloading(let v): return v.map { Text(Self.progressText($0)) } ?? Text("다운로드 중")
        case .verifying: return Text("검증 중")
        case .committing: return Text("설치 중")
        case .importing: return Text("가져오는 중")
        case .done: return Text("라이브러리에 추가됨")
        case .failed: return Text("다운로드 실패")
        }
    }

    /// Return 키·기본 액션이 실행할 동작. 단계마다 하나뿐이고 서로 배타적이라 목록이 아니라
    /// 하나로 충분하다 — 이 타일에는 우클릭 메뉴가 없으므로 §4.3 의 1:1 규약이 요구하는 것도 없다.
    /// 진행 중에는 nil 이라 포커스도 받지 않는다(누를 것이 없는 자리에 탭이 멈추지 않게).
    private var primaryAction: (() -> Void)? {
        switch download?.phase {
        case nil, .failed: return steamcmdAvailable ? onDownload : nil
        case .done: return onApply
        default: return nil
        }
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

    /// 파라미터가 `String` 이 아니라 `Text` 인 이유: `Text(someString)` 는 비현지화 오버로드라
    /// 호출부의 한국어 리터럴이 조용히 번역을 잃는다. `Text` 로 받으면 리터럴이 호출부에 남아
    /// `LocalizedStringKey` 로 해석되고 커버리지 스캐너에도 잡힌다(공유 컴포넌트와 같은 규약).
    private func stage(_ label: Text) -> some View {
        HStack(spacing: Space.xxs) {
            ProgressView().controlSize(.small)
            label.font(Typography.badge).foregroundStyle(.secondary)
        }
    }
}
