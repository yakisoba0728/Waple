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

    /// stop() 미호출 안전망 — 미호출 시 타이머가 nil self 로 계속 발화(감사 L1). stop() 은 멱등.
    ///
    /// [2026-08-25] `deinit` 은 액터 격리를 가질 수 없어서 메인 액터인 `stop()` 을 그냥 못 부른다.
    /// `AppDelegate:32-34` 가 세워 둔 규약을 따른다 — **실행되는 곳이 메인임을 아는 자리에서는
    /// `MainActor.assumeIsolated` 로 그 사실을 알린다. 검사를 끄는 게 아니라 런타임 단언이다.**
    ///
    /// ⚠️ **행동이 바뀐다.** 종전에는 오프메인 해제 시 `timer?.invalidate()` 가 설치 스레드가 아닌
    /// 곳에서 불려 **조용히 잘못 동작**했다(RunLoop 규약 위반이라 타이머가 안 죽을 수 있다).
    /// 이제는 같은 상황에서 **트랩된다**. 이 리포는 "조용히 틀리는 것보다 실패하는 쪽" 을 택해
    /// 왔고(규약 5), 어차피 그 경로에서 종전 동작도 옳지 않았다.
    ///
    /// 전제의 근거: 이 뷰는 `WebRenderer` 의 조작 창 `contentView` 로만 존재하고, 그 창은
    /// `isReleasedWhenClosed = false` 로 `interactionWindow` 가 강참조한다. 타이머 블록과
    /// `takeSnapshot` 완료 핸들러는 둘 다 `[weak self]` 라 오프메인 강참조를 만들지 않는다.
    /// 즉 마지막 참조는 메인에서 놓인다.
    deinit {
        MainActor.assumeIsolated { stop() }
    }

    override var acceptsFirstResponder: Bool { true }

    func start() {
        guard timer == nil else { return }
        // ~12fps 미러 — takeSnapshot 은 메인큐 콜백(WKWebView 규약). 조작 창이 열려있는 동안만.
        // `.common` 모드 — MediaPoller 와 같은 이유(AppDelegate:755 주석 참조). 이 타이머는
        // 조작 창 미러링이라 메뉴를 여는 동안 멈추면 그대로 눈에 보인다.
        // [2026-08-25] 블록 본문을 `MainActor.assumeIsolated` 로 감싼다. `Timer` 의 블록은 타입상
        // 비격리인데 이 타이머는 바로 아래에서 `RunLoop.main` 에 얹으므로 **실행되는 곳이 메인**이다.
        // `AppDelegate:32-34` 의 규약 그대로 — 검사를 끄는 게 아니라 그 사실을 런타임 단언으로 적는다.
        // (진단 5건: `target`/`window`/`isVisible` 참조 · `WKSnapshotConfiguration()` · `takeSnapshot`)
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let web = self.target, self.window?.isVisible == true else { return }
                let cfg = WKSnapshotConfiguration()
                web.takeSnapshot(with: cfg) { [weak self] image, _ in
                    // takeSnapshot 완료는 WKWebView 규약상 메인 큐 배달이다(파일 머리말 참조).
                    MainActor.assumeIsolated {
                        guard let self, let image else { return }
                        self.lastImage = image
                        self.needsDisplay = true
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        let escaped = jsEscape(key)
        target?.evaluateJavaScript("window.__wapleEvent('\(kind)', 0, 0, '\(escaped)', '\(escaped)');")
    }

    /// JS 문자열 리터럴 이스케이프 — 테스트 가능하게 분리(webPoint 와 동일 규약).
    /// 백슬래시·작은따옴표 외에 라인터미네이터(\r/\n/U+2028/U+2029)도 이스케이프한다 — raw 로
    /// 들어가면 JS 구문 오류로 evaluateJavaScript 가 무음 실패해 키가 유실된다(감사 항목 I).
    func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
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
