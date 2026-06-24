import Foundation
import WebKit
import UniformTypeIdentifiers

public final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "waple-asset"
    public static let host = "wallpaper"

    private let root: URL

    public init(rootURL: URL) {
        self.root = rootURL.standardizedFileURL
        super.init()
    }

    /// 요청 경로를 루트 하위 파일 URL 로 안전하게 변환. 루트를 벗어나면 nil.
    public static func fileURL(forRequestPath path: String, root: URL) -> URL? {
        let root = root.standardizedFileURL
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(rel).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root),
              let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: task.request.url, status: 404, mime: "text/plain", data: Data())
            return
        }
        respond(task, url: url, status: 200, mime: mimeType(for: fileURL), data: data)
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL?, status: Int, mime: String, data: Data) {
        let target = url ?? URL(string: "waple-asset://wallpaper/")!
        let response = HTTPURLResponse(
            url: target, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
