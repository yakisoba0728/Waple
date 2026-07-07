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
        let root = self.root
        // 파일 읽기는 메인 스레드를 막지 않도록 백그라운드에서(큰 비디오 등). 응답은 메인에서 stop 여부 확인 후.
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let url = requestURL,
               url.scheme == WallpaperSchemeHandler.scheme,
               url.host == WallpaperSchemeHandler.host,
               let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root) {
                self.respondFile(task, id: id, requestURL: requestURL, fileURL: fileURL)
            } else {
                DispatchQueue.main.async {
                    guard self.isTaskLive(id) else { return }
                    self.respond(task, url: requestURL, status: 404, mime: "text/plain", data: Data())
                    self.finishTask(id)
                }
            }
        }
    }

    private func respondFile(_ task: WKURLSchemeTask, id: ObjectIdentifier, requestURL: URL?, fileURL: URL) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            DispatchQueue.main.async {
                guard self.isTaskLive(id) else { return }
                self.respond(task, url: requestURL, status: 404, mime: "text/plain", data: Data())
                self.finishTask(id)
            }
            return
        }
        defer { try? handle.close() }

        let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
        let mime = mimeType(for: fileURL)
        DispatchQueue.main.sync {
            guard self.isTaskLive(id) else { return }
            let response = HTTPURLResponse(
                url: target, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)"]
            )!
            task.didReceive(response)
        }
        while isTaskLive(id) {
            let data = autoreleasepool {
                (try? handle.read(upToCount: chunkSize)) ?? Data()
            }
            if data.isEmpty { break }
            DispatchQueue.main.sync {
                guard self.isTaskLive(id) else { return }
                task.didReceive(data)
            }
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

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
