import SwiftUI
import AppKit

enum PreviewMedia {
    static func isAnimated(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gif" }
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
        v.image = NSImage(contentsOf: url)
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
            v.image = NSImage(contentsOf: url)
        }
        v.animates = animating
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator { var url: URL; init(url: URL) { self.url = url } }
}
