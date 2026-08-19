import Foundation
import WebKit
import UniformTypeIdentifiers
import WapleCore

public final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "waple-asset"
    public static let host = "wallpaper"

    private let root: URL
    private let ioQueue = DispatchQueue(label: "waple.scheme.io", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()  // 시작됐고 아직 stop 안 된 태스크(use-after-stop 방지)
    private let chunkSize = 64 * 1024

    public init(rootURL: URL) {
        self.root = rootURL.standardizedFileURL
        super.init()
    }

    /// F840: 응답에 붙이는 Content-Security-Policy.
    ///
    /// 배경 — 브리지가 시스템 오디오 스펙트럼(`__wapleAudio`)과 Now-Playing 메타데이터
    /// (제목/아티스트/앨범, `__wapleMedia`)를 페이지에 넘기는데, 내비게이션 게이트
    /// (`WebRenderer.decidePolicyFor`)는 **내비게이션만** 다룬다(F571). 그래서 fetch/XHR/WebSocket/
    /// 폼 전송이 무검증으로 열려 있었고, 캡처한 오디오·미디어 메타데이터를 그대로 반출할 수 있었다.
    ///
    /// F571 이 서브리소스를 열어 둔 이유(WE 자체가 네트워크를 허용 — 원격 이미지/스크립트를 쓰는
    /// 실물 월페이퍼가 실재)는 그대로 존중한다. 그래서 전면 차단이 아니라 **원격 반출 채널만** 닫는다:
    ///  - `connect-src` 에 **원격 스킴을 넣지 않는다** : fetch/XHR/WebSocket/EventSource/sendBeacon 이
    ///    원격 호스트로 나갈 수 없다(= 캡처한 오디오·미디어 메타데이터의 POST 반출 차단).
    ///  - `form-action` 도 같은 목록 : 폼 POST 반출 차단.
    ///  - img/media/font/style/script 는 https: 를 계속 허용 → 원격 리소스 월페이퍼 무회귀.
    ///  - default-src(= frame/worker/object/manifest 폴백)는 로컬만 — 원격 프레임은 어차피
    ///    내비게이션 게이트가 이미 막고 있어 새 제약이 아니다.
    ///
    /// **`'none'` 이 아니라 로컬 허용으로 좁힌 이유**: 실물 웹 월페이퍼는 자기 패키지의 JSON/텍스트를
    /// `fetch()`·XHR 로 읽는 것이 흔하다. `connect-src 'none'` 이면 그 로컬 읽기까지 죽는데, 그건
    /// 보안에 아무것도 더해 주지 않는다 — waple-asset: 은 이 스킴 핸들러가 처리하는 **로컬 파일**이고
    /// 반출 경로가 아니기 때문이다. 원격 스킴(http/https/ws/wss)이 목록에 없다는 사실이 차단의 전부다.
    ///
    /// 수용 한계(문서화): `<img src="https://…?d=…">` 같은 수동 비콘 반출은 여전히 가능하다.
    /// 그걸 막으려면 img-src 를 로컬로 좁혀야 하는데 그건 F571 이 지키려는 월페이퍼를 깨뜨린다.
    ///
    /// `'unsafe-inline'`/`'unsafe-eval'` 은 WE 웹 월페이퍼가 인라인 스크립트 덩어리라 필수이고,
    /// 브리지 주입(WKUserScript)이 CSP 에 걸리지 않게 하는 보험이기도 하다.
    static let contentSecurityPolicy: String = {
        let local = "'self' \(WallpaperSchemeHandler.scheme): blob: data:"
        return [
            "default-src \(local) 'unsafe-inline' 'unsafe-eval'",
            "script-src \(local) https: 'unsafe-inline' 'unsafe-eval'",
            "style-src \(local) https: 'unsafe-inline'",
            "img-src \(local) https:",
            "media-src \(local) https:",
            "font-src \(local) https:",
            "connect-src \(local)",
            "form-action \(local)",
        ].joined(separator: "; ")
    }()

    /// 요청 경로를 루트 하위 파일 URL 로 안전하게 변환. 루트를 벗어나면 nil.
    public static func fileURL(forRequestPath path: String, root: URL) -> URL? {
        let root = root.standardizedFileURL
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if rel.isEmpty { return root }
        return WallpaperPathSecurity.containedFileURL(rel, root: root)
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); activeTasks.insert(id); lock.unlock()
        let requestURL = task.request.url
        let rangeHeader = task.request.value(forHTTPHeaderField: "Range")
        let root = self.root
        // 파일 읽기는 메인 스레드를 막지 않도록 백그라운드에서(큰 비디오 등). 본문 응답도 이 큐에서
        // stop 여부 확인 후 직접 전달(감사 H — didReceive 는 백그라운드 큐 호출 가능).
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let url = requestURL,
               url.scheme == WallpaperSchemeHandler.scheme,
               url.host == WallpaperSchemeHandler.host,
               let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root) {
                self.respondFile(task, id: id, requestURL: requestURL, rangeHeader: rangeHeader, fileURL: fileURL)
            } else {
                DispatchQueue.main.async {
                    guard self.isTaskLive(id) else { return }
                    self.respond(task, url: requestURL, status: 404, mime: "text/plain", data: Data())
                    self.finishTask(id)
                }
            }
        }
    }

    /// Range 헤더 해석 결과. WebKit 의 미디어 로더(<video>/<audio>)는 Range 요청(206)이
    /// 지원되지 않으면 소스 선택 자체가 실패하므로(networkState=NO_SOURCE) 단일 범위를 지원한다.
    enum ParsedRange: Equatable {
        case full                    // Range 없음/해석 불가 → 200 전체 (기존 정적 에셋 경로 그대로)
        case partial(Range<Int64>)   // 206 + Content-Range
        case unsatisfiable           // 416 (시작이 파일 끝 이후)
    }

    /// RFC 7233 단일 바이트 레인지 파싱. 멀티 레인지/비 bytes 단위/문법 오류는 .full 로 무시(전체 200 폴백).
    static func parseRangeHeader(_ header: String?, fileSize: Int64) -> ParsedRange {
        guard let header else { return .full }
        let spec = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard spec.hasPrefix("bytes=") else { return .full }
        let ranges = spec.dropFirst("bytes=".count)
        // ponytail: 멀티 레인지(multipart/byteranges)는 WebKit 이 안 보냄 — 전체 200 폴백이 정확한 축소.
        guard !ranges.contains(",") else { return .full }
        let parts = ranges.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        if startStr.isEmpty {
            // suffix 형식 bytes=-N: 마지막 N 바이트.
            guard let n = Int64(endStr), n > 0 else { return .full }
            guard fileSize > 0 else { return .unsatisfiable }
            return .partial(max(0, fileSize - n)..<fileSize)
        }
        guard let start = Int64(startStr), start >= 0 else { return .full }
        guard start < fileSize else { return .unsatisfiable }
        if endStr.isEmpty { return .partial(start..<fileSize) }  // bytes=N-
        guard let end = Int64(endStr), end >= start else { return .full }
        // F570: end=Int64.max(페이지 JS 가 Range 헤더로 주입 가능)면 end+1 이 산술 오버플로
        // 트랩 — 클램프를 덧셈 없이 분기로 처리.
        let upperBound = end >= fileSize ? fileSize : end + 1
        return .partial(start..<upperBound)
    }

    private func respondFile(_ task: WKURLSchemeTask, id: ObjectIdentifier, requestURL: URL?, rangeHeader: String?, fileURL: URL) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL),
              let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            DispatchQueue.main.async {
                guard self.isTaskLive(id) else { return }
                self.respond(task, url: requestURL, status: 404, mime: "text/plain", data: Data())
                self.finishTask(id)
            }
            return
        }
        defer { try? handle.close() }
        let total = Int64(size)

        var headers = [
            "Content-Type": WallpaperSchemeHandler.mimeType(for: fileURL),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)",
            "Content-Security-Policy": WallpaperSchemeHandler.contentSecurityPolicy,
        ]
        let status: Int
        let body: Range<Int64>
        switch WallpaperSchemeHandler.parseRangeHeader(rangeHeader, fileSize: total) {
        case .full:
            status = 200
            body = 0..<total
            headers["Content-Length"] = String(total)
        case .partial(let range):
            status = 206
            body = range
            headers["Content-Length"] = String(range.upperBound - range.lowerBound)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
        case .unsatisfiable:
            status = 416
            body = 0..<0
            headers["Content-Length"] = "0"
            headers["Content-Range"] = "bytes */\(total)"
        }

        let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
        // 감사 H: main.sync 왕복이면 스트리밍 처리량이 메인 큐 응답성에 결합되므로 ioQueue 에서 직접
        // 전달한다. 이 함수는 태스크당 직렬로 진행돼 전달 순서는 유지된다.
        // F590: live 확인과 didReceive 호출을 한 락 구간에서 원자화한 F575 는 폐기 — WebKit 호출이
        // 락 안에서 블록되는 동안 메인의 isTaskLive(didFinish 경로)가 같은 락을 기다리는 교착이
        // 실재했다(RealWebGroundTruthTests 에서 샘플링으로 확인). stop 과 호출의 잔여 경합(F-28)은
        // 청크 루프의 isTaskLive 재확인으로 창을 좁히는 선에서 수용한다.
        let response = HTTPURLResponse(
            url: target, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        guard withLiveTask(id, { task.didReceive(response) }) else { return }
        if body.lowerBound > 0 { try? handle.seek(toOffset: UInt64(body.lowerBound)) }
        var remaining = Int(body.upperBound - body.lowerBound)
        while remaining > 0, isTaskLive(id) {
            let data = autoreleasepool {
                (try? handle.read(upToCount: Swift.min(chunkSize, remaining))) ?? Data()
            }
            if data.isEmpty { break }
            remaining -= data.count
            guard withLiveTask(id, { task.didReceive(data) }) else { break }
        }
        DispatchQueue.main.async {
            guard self.isTaskLive(id) else { return }
            task.didFinish()
            self.finishTask(id)
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); activeTasks.remove(ObjectIdentifier(task)); lock.unlock()
    }

    private func respond(_ task: WKURLSchemeTask, url: URL?, status: Int, mime: String, data: Data) {
        let target = url ?? URL(string: "waple-asset://wallpaper/")!
        let response = HTTPURLResponse(
            url: target, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Access-Control-Allow-Origin": "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)",
                "Content-Security-Policy": WallpaperSchemeHandler.contentSecurityPolicy,
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func isTaskLive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let live = activeTasks.contains(id)
        lock.unlock()
        return live
    }

    /// F590: live 확인과 태스크 메서드 호출은 락 밖에서 한다. 락을 쥔 채 WebKit 을 호출하면(F575)
    /// WebKit 남부 블록 중 메인 스레드가 isTaskLive 에서 같은 락을 기다려 교착된다. 확인-호출 사이에
    /// stop 이 끼는 창(F-28)은 마이크로초 단위라, 실재한 교착보다 이론적 경합을 택한다.
    private func withLiveTask(_ id: ObjectIdentifier, _ body: () -> Void) -> Bool {
        lock.lock()
        let live = activeTasks.contains(id)
        lock.unlock()
        guard live else { return false }
        body()
        return true
    }

    private func finishTask(_ id: ObjectIdentifier) {
        lock.lock()
        activeTasks.remove(id)
        lock.unlock()
    }

    /// 미디어 확장자 → MIME 명시 고정 테이블. UTType 은 LaunchServices(설치 앱의 UTI 등록)에
    /// 의존해 webm/ogv 등이 머신에 따라 미해결(→ octet-stream)될 수 있고, 그러면 <video> 소스
    /// 선택이 실패한다. 코퍼스 web <video> 는 전부 webm.
    static let mediaMIMETypes: [String: String] = [
        "webm": "video/webm",
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "mov": "video/quicktime",
        "ogv": "video/ogg",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "wav": "audio/wav",
        "flac": "audio/flac",
    ]

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let mime = mediaMIMETypes[ext] { return mime }
        if let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
