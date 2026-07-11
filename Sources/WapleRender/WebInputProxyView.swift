import AppKit
import WebKit

/// 웹 월페이퍼 조작 창의 콘텐츠 뷰: 데스크탑 WKWebView 를 미러링(주기 스냅샷)하면서
/// 이 뷰가 받는 실입력(마우스/드래그/휠/키)을 대상 웹뷰에 합성 DOM 이벤트로 재게시한다.
/// 인스턴스는 데스크탑 1개뿐이므로 창에서의 조작이 곧 바탕화면에 실시간 반영된다.
final class WebInputProxyView: NSView {
    private weak var target: WKWebView?
    private var timer: Timer?
    private var lastImage: NSImage?
    private var dragging = false
    private var lastMoveForward: CFAbsoluteTime = 0

    init(target: WKWebView) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func start() {
        guard timer == nil else { return }
        // ~12fps 미러 — takeSnapshot 은 메인큐 콜백(WKWebView 규약). 조작 창이 열려있는 동안만.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self, let web = self.target, self.window?.isVisible == true else { return }
            let cfg = WKSnapshotConfiguration()
            web.takeSnapshot(with: cfg) { [weak self] image, _ in
                guard let self, let image else { return }
                self.lastImage = image
                self.needsDisplay = true
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let img = lastImage else {
            let s = "월페이퍼 미리보기 로딩 중…"
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white]
            (s as NSString).draw(at: NSPoint(x: 20, y: bounds.midY), withAttributes: attrs)
            return
        }
        // 종횡비 유지 fit — 입력 좌표 변환(viewToWeb)과 동일한 사각형을 써야 클릭이 정확히 맞는다.
        img.draw(in: fitRect(for: img.size), from: .zero, operation: .copy, fraction: 1.0)
    }

    private func fitRect(for imageSize: NSSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// 뷰 좌표(하단 원점) → 웹 CSS 좌표(상단 원점). fit 사각형 밖이면 nil.
    /// clampToFit: 밖이어도 경계 안쪽으로 클램프해 항상 반환 — 드래그 릴리즈(mouseup) 소실 방지(감사 W-B3).
    func webPoint(from viewPoint: NSPoint, clampToFit: Bool = false) -> (x: Int, y: Int)? {
        guard let web = target else { return nil }
        let webSize = web.bounds.size
        let r = fitRect(for: lastImage?.size ?? webSize)
        guard r.width > 0, r.height > 0 else { return nil }
        if !clampToFit, !r.contains(viewPoint) { return nil }
        let nx = min(max((viewPoint.x - r.minX) / r.width, 0), 1)
        let ny = min(max((viewPoint.y - r.minY) / r.height, 0), 1)
        // 클램프된 nx==1 이 뷰포트 밖(x==width)으로 매핑되지 않게 상한은 width-1.
        return (min(Int(nx * webSize.width), max(Int(webSize.width) - 1, 0)),
                min(Int((1 - ny) * webSize.height), max(Int(webSize.height) - 1, 0)))
    }

    private func send(_ kind: String, _ p: (x: Int, y: Int), a: String = "0", b: String = "0") {
        target?.evaluateJavaScript("window.__wapleEvent('\(kind)', \(p.x), \(p.y), \(a), \(b));")
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = webPoint(from: convert(event.locationInWindow, from: nil)) else { return }
        dragging = true
        send("mousedown", p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = webPoint(from: convert(event.locationInWindow, from: nil)) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMoveForward > 1.0 / 60.0 else { return }
        lastMoveForward = now
        send("mousemove", p, a: "1")
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        dragging = false
        // 드래그 릴리즈는 fit 밖이어도 클램프 좌표로 반드시 전달 — 미전송 시 웹이 buttons=1(드래그 중)로
        // 고착된다(감사 W-B3). 드래그가 아니었으면 종전대로 fit 안에서만.
        guard let p = webPoint(from: convert(event.locationInWindow, from: nil), clampToFit: wasDragging) else { return }
        send("mouseup", p)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let p = webPoint(from: convert(event.locationInWindow, from: nil)) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMoveForward > 1.0 / 30.0 else { return }
        lastMoveForward = now
        send("mousemove", p)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = webPoint(from: convert(event.locationInWindow, from: nil)) else { return }
        send("wheel", p, a: "\(Int(event.scrollingDeltaX))", b: "\(Int(-event.scrollingDeltaY))")
    }

    override func keyDown(with event: NSEvent) {
        forwardKey("keydown", event)
    }

    override func keyUp(with event: NSEvent) {
        forwardKey("keyup", event)
    }

    private func forwardKey(_ kind: String, _ event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let key = jsKey(chars, keyCode: event.keyCode)
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        target?.evaluateJavaScript("window.__wapleEvent('\(kind)', 0, 0, '\(escaped)', '\(escaped)');")
    }

    private func jsKey(_ chars: String, keyCode: UInt16) -> String {
        switch keyCode {
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 36: return "Enter"
        case 49: return " "
        case 53: return "Escape"
        default: return chars
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // mouseMoved 수신을 위한 트래킹 영역.
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        window?.makeFirstResponder(self)
    }
}
