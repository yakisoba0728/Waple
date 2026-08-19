import AppKit
import SwiftUI

/// 미리보기 이미지 디코드 캐시(URL→NSImage). body 재평가마다의 반복 디스크 I/O 제거.
/// F500: 최초 로드도 body 평가 중 메인 동기 읽기 대신 백그라운드 디코드로(느린 디스크에서의 스크롤
/// 히치 방지) — cached() 는 조회만, load() 가 디코드+캐시를 담당한다. internal: 단위 테스트 대상.
///
/// 2026-08-17 개편에서 WallpaperGridView 로부터 이 파일로 옮겼다. 소비자가 그리드 하나가 아니라
/// 아래 `PreviewThumbnail` 하나가 되므로 그 옆이 제자리다. **타입 이름과 API 는 옮기면서도
/// 그대로 뒀다** — `AppUIFixRegressionTests` 가 이름으로 참조하는 동결 파일이라, 이름을 바꾸면
/// 그건 리팩토링이 아니라 회귀 테스트 수정이 된다.
enum PreviewImageCache {
    /// `nonisolated(unsafe)` 근거: `NSCache` 는 **자체 락으로 스레드 안전**이라고 Apple 이 문서로
    /// 보증한다 — 아래 `load` 가 오프메인(`Task.detached`)에서 넣고 메인에서 꺼내는 것이 바로 그
    /// 보증에 기대는 사용이다. 컴파일러는 그 락을 볼 수 없어 "비-Sendable 타입의 전역 가변 상태"
    /// 로 표시할 뿐이고, 참조 자체는 `let` 이라 재대입도 없다.
    nonisolated(unsafe) private static let cache = NSCache<NSURL, NSImage>()

    /// 캐시 히트만 동기 반환(디스크 읽기 없음 — body 평가 중 호출 안전).
    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// 백그라운드 디코드 + 캐시. 히트면 즉시 반환, 실패(읽기 불가 등) → nil.
    static func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        return await Task.detached(priority: .userInitiated) {
            guard let img = NSImage(contentsOf: url) else { return nil }
            cache.setObject(img, forKey: url as NSURL)
            return img
        }.value
    }
}

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
/// ## url 이 nil 이어도 같은 플레이스홀더가 나온다
///
/// 미리보기가 없는 항목은 흔하다(가져온 동영상·손상된 패키지). 종전에는 호출부마다
/// `if let url` 로 갈라 **플레이스홀더 ZStack 을 네 번 다시 적었고**, 그래서 값이 갈라졌다.
/// nil 을 이 뷰가 받으므로 호출부는 더 이상 플레이스홀더를 그리지 않는다.
///
/// 호출부에 아직 `if let url` 분기가 남아 있는 것은 추출 커밋에서 뷰 식별자를 바꾸지 않으려고
/// 구조를 그대로 둔 흔적이다. 아래 `reloadIfNeeded()` 가 url 변경을 스스로 처리하므로
/// **이제 합쳐도 된다** — 합치는 것은 그 화면을 맡는 단위가 자기 커밋에서 한다.
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
    /// `image` 가 어느 url 의 것인가. 재사용된 뷰에서 살아남은 `@State` 와 새로 들어온 `url` 을
    /// 구별하는 유일한 수단이다 — 아래 `reloadIfNeeded()` 참조.
    @State private var loadedURL: URL?

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
        _loadedURL = State(initialValue: url)
    }

    var body: some View {
        content
            .accessibilityHidden(true)
            .task(id: url) { await reloadIfNeeded() }
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

    /// ## 왜 `image == nil` 만으로는 부족한가
    ///
    /// SwiftUI 는 같은 자리·같은 갈래의 뷰를 **재사용**한다. 재사용되면 `init` 은 다시 불려도
    /// `State(initialValue:)` 는 버려지므로 이전 그림이 그대로 남는다. 종전 두 구현은 여기서
    /// `image == nil` 만 보고 일찍 반환해, url 이 바뀌어도 **이전 배경의 썸네일을 계속 보여줬다**
    /// (디스플레이 다이어그램에서 모니터를 다른 배경으로 다시 할당하면 재현된다).
    /// 그래서 "채워졌는가" 가 아니라 **"지금 url 의 것으로 채워졌는가"** 를 본다.
    ///
    /// 첫 마운트에서는 `loadedURL == url` 이라 판정이 종전과 완전히 같다 —
    /// 캐시 히트면 그대로 두고, 미스면 백그라운드 디코드로 간다.
    ///
    /// ## 취소된 task 의 늦은 완료
    ///
    /// url 이 바뀌면 `task(id:)` 가 이전 task 를 취소하지만, 취소는 협조적이고
    /// `PreviewImageCache.load` 는 던지지 않는 `Task.detached` 의 값을 기다리므로 **중간에
    /// 끊기지 않는다.** 느린 디스크의 이전 로드가 나중에 끝나면 이미 새 그림으로 채워진 자리에
    /// 옛 그림을 덮어쓴다 — 이 함수가 없애려던 상태 그대로다. 그래서 대입 직전에 자기가 아직
    /// 유효한 로드인지 다시 본다. 이전 task 는 `url` 이 옛 값이고 `loadedURL` 은 이미 새 값이라
    /// 스스로 자기를 알아보고 물러난다.
    private func reloadIfNeeded() async {
        guard loadedURL != url || image == nil else { return }
        loadedURL = url
        guard let url else { image = nil; return }
        if let hit = PreviewImageCache.cached(url) { image = hit; return }
        // 다른 파일로 바뀌었는데 디코드가 걸리는 동안 이전 그림을 남겨 두면 그게 그 항목의
        // 미리보기인 줄 읽힌다. 플레이스홀더를 잠깐 보여주는 편이 틀린 그림보다 낫다.
        image = nil
        let loaded = await PreviewImageCache.load(url)
        guard loadedURL == url else { return }
        image = loaded
    }
}
