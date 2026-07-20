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
        return .partial(start..<min(end + 1, fileSize))
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
        // 전달한다. isTaskLive 는 NSLock 보호이고, 이 함수는 태스크당 직렬로 진행돼 전달 순서는 유지된다.
        guard isTaskLive(id) else { return }
        let response = HTTPURLResponse(
            url: target, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        task.didReceive(response)
        if body.lowerBound > 0 { try? handle.seek(toOffset: UInt64(body.lowerBound)) }
        var remaining = Int(body.upperBound - body.lowerBound)
        while remaining > 0, isTaskLive(id) {
            let data = autoreleasepool {
                (try? handle.read(upToCount: Swift.min(chunkSize, remaining))) ?? Data()
            }
            if data.isEmpty { break }
            remaining -= data.count
            guard isTaskLive(id) else { break }
            task.didReceive(data)
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
            headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)"]
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
