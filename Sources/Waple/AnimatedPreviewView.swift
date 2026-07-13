import SwiftUI
import AppKit

enum PreviewMedia {
    static func isAnimated(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gif" }
}

/// gif 디코드 캐시(URL→NSImage) — 타일 재사용 시 재디코드 방지. WallpaperGridView 의 PreviewImageCache 와
/// 같은 패턴(그쪽은 private 라 공유 불가). NSCache 는 스레드 안전 — 오프메인 디코드에서 채운다.
private enum AnimatedImageCache {
    private static let cache = NSCache<NSURL, NSImage>()
    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    static func load(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// preview.gif 네이티브 재생(NSImageView.animates) — SwiftUI Image는 GIF 애니를 지원하지 않는다.
/// animating=false 면 첫 프레임 정지(그리드 성능: 호버 중에만 재생).
struct AnimatedPreviewView: NSViewRepresentable {
    let url: URL
    var animating: Bool

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = animating
        setImage(url, on: v, coordinator: context.coordinator)
        // 고유 크기(원본 픽셀)가 SwiftUI 프레임을 밀어내지 않게 — LazyVGrid 셀 폭이
        // gif 원본 폭으로 부풀어 타일 폭이 불균일해지는 오버플로 방지(SP1′ 판정 캡처 실측).
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        // URL 변경(그리드 셀 재사용) 시에만 재로드 — animates 토글은 매 업데이트 반영.
        if context.coordinator.url != url {
            context.coordinator.url = url
            setImage(url, on: v, coordinator: context.coordinator)
        }
        v.animates = animating
    }

    /// 캐시 히트는 메인에서 즉시(디스크 I/O 없음), 미스는 오프메인 디코드 후 메인에서 반영.
    /// 셀 재사용으로 url 이 바뀌면 늦게 온 디코드는 폐기(coordinator.url 대조)해 엉뚱한 타일 덮어쓰기 방지.
    private func setImage(_ url: URL, on v: NSImageView, coordinator: Coordinator) {
        if let hit = AnimatedImageCache.cached(url) { v.image = hit; return }
        coordinator.url = url
        DispatchQueue.global(qos: .userInitiated).async {
            let img = AnimatedImageCache.load(url)
            DispatchQueue.main.async {
                guard coordinator.url == url else { return }   // 그 사이 셀이 다른 url 로 재사용됨 → 폐기
                v.image = img
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator { var url: URL; init(url: URL) { self.url = url } }
}
