import AppKit
import SwiftUI

/// 로컬 파일 미리보기 썸네일 — 그리드 타일·디스플레이 다이어그램·레일이 공유한다.
///
/// ## 왜 하나로 합치나
///
/// 2026-08-17 실측: 같은 F500 패턴이 `StillPreviewView`(그리드)와 `DisplaysThumbView`(디스플레이)
/// 두 벌로 복제돼 있었다. 복제는 갈라진다 — 실제로 플레이스홀더 채움이 한쪽 0.3, 다른 쪽 0.25 로
/// 어긋나 있었고, 그건 의도된 위계가 아니라 각자 정한 흔적이었다(근거는 `ColorRole.placeholderFill`).
/// 개편 후 이 썸네일을 쓰는 표면이 넷으로 늘어나므로, 지금 합치지 않으면 네 벌이 된다.
///
/// 종전 `DisplaysThumbView` 주석의 "PreviewImageCache 는 file-private" 라는 서술은 이미
/// 스테일했다(실제로는 internal — 단위 테스트 대상). 합치면서 그 오해의 여지도 함께 없앤다.
///
/// ## init 에서 캐시를 조회하는 이유 (F500)
///
/// `@State` 초기값에 캐시 히트를 넣어 두면 **첫 body 평가에 이미 이미지가 있다**. `task` 로만
/// 채우면 히트여도 한 프레임은 플레이스홀더가 그려져 스크롤 중 깜빡인다. 조회는 `NSCache`
/// 접근뿐이라 디스크를 읽지 않으므로 메인 스레드에서 안전하다 — 종전 구현이 하던 body 평가 중
/// 동기 `NSImage(contentsOf:)` 와는 다르다.
///
/// ## url 이 nil 이어도 호출부는 분기하지 않는다
///
/// 미리보기가 없는 항목은 흔하다(가져온 동영상·손상된 패키지). 종전에는 호출부마다
/// `if let url` 로 갈라 **플레이스홀더 ZStack 을 네 번 다시 적었고**, 그래서 값이 갈라졌다.
/// nil 을 이 뷰가 받아 같은 플레이스홀더를 그린다.
///
/// ## 접근성 — 통째로 감춘다
///
/// 썸네일은 장식이다. 항목의 이름은 타일이 `tileAccessibility(label:)` 로 이미 읽는다.
/// 여기에 라벨 없는 이미지를 하나 더 노출하면 `children: .combine` 이 그걸 흡수해 SF Symbol
/// 이름이 항목 이름에 섞여 읽힌다. 보조기술에 더할 정보가 없는 요소는 감추는 게 맞다.
struct PreviewThumbnail: View {
    let url: URL?
    var placeholderFont: Font

    @State private var image: NSImage?

    /// - Parameters:
    ///   - url: 로컬 미리보기 파일. nil 이면 플레이스홀더만 그린다.
    ///   - placeholderFont: 플레이스홀더 글리프 크기. 썸네일 크기에 맞춰 고른다 —
    ///     실측 3종은 레일 74×46 이 캡션급, 그리드 타일 200×125 가 본문급,
    ///     디스플레이 모니터 박스가 타이틀급이다. 글자가 아니라 글리프라 고정 크기 금지
    ///     규약(`Typography`)의 예외이고, 시스템 텍스트 스타일로 주므로 큰 글씨 설정도 따라온다.
    init(url: URL?, placeholderFont: Font = .body) {
        self.url = url
        self.placeholderFont = placeholderFont
        _image = State(initialValue: url.flatMap { PreviewImageCache.cached($0) })
    }

    var body: some View {
        content
            .accessibilityHidden(true)
            .task(id: url) { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(ColorRole.placeholderFill)
                Image(systemName: "photo").font(placeholderFont).foregroundStyle(.tertiary)
            }
        }
    }

    private func loadIfNeeded() async {
        guard image == nil, let url else { return }
        image = await PreviewImageCache.load(url)
    }
}
