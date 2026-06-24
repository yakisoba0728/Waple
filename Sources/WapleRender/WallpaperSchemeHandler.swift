import Foundation
import WebKit
import UniformTypeIdentifiers

public final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "waple-asset"
    public static let host = "wallpaper"

    private let root: URL
    private let ioQueue = DispatchQueue(label: "waple.scheme.io", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()  // 시작됐고 아직 stop 안 된 태스크(use-after-stop 방지)

    public init(rootURL: URL) {
        self.root = rootURL.standardizedFileURL
        super.init()
    }

    /// 요청 경로를 루트 하위 파일 URL 로 안전하게 변환. 루트를 벗어나면 nil.
    public static func fileURL(forRequestPath path: String, root: URL) -> URL? {
        let root = root.standardizedFileURL
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(rel).standardizedFileURL
        // `standardizedFileURL` 는 `.`/`..` 만 정규화하고 심볼릭 링크는 따라가지 않는다.
        // 악성 배경이 패키지 안에 `leak -> /Users/<user>/.ssh/id_rsa` 같은 심링크를 넣으면
        // candidate.path 는 여전히 루트 하위로 보여 검사를 통과하지만 Data(contentsOf:) 가
        // 링크를 따라 루트 밖 파일을 읽는다. 심링크를 해석한 경로로 격리(containment)를 검사한다.
        let realRoot = root.resolvingSymlinksInPath().path
        let realCandidate = candidate.resolvingSymlinksInPath().path
        guard realCandidate == realRoot || realCandidate.hasPrefix(realRoot + "/") else { return nil }
        return candidate
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); activeTasks.insert(id); lock.unlock()
        let requestURL = task.request.url
        let root = self.root
        // 파일 읽기는 메인 스레드를 막지 않도록 백그라운드에서(큰 비디오 등). 응답은 메인에서 stop 여부 확인 후.
        ioQueue.async { [weak self] in
            guard let self else { return }
            var status = 404, mime = "text/plain", data = Data()
            if let url = requestURL,
               let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root),
               let d = try? Data(contentsOf: fileURL) {
                status = 200; mime = self.mimeType(for: fileURL); data = d
            }
            DispatchQueue.main.async {
                // stop 이후엔 WKURLSchemeTask 호출 금지(크래시). 메인 직렬화로 stop/respond 인터리브 없음.
                self.lock.lock(); let live = self.activeTasks.contains(id); self.lock.unlock()
                guard live else { return }
                self.respond(task, url: requestURL, status: status, mime: mime, data: data)
                self.lock.lock(); self.activeTasks.remove(id); self.lock.unlock()
            }
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); activeTasks.remove(ObjectIdentifier(task)); lock.unlock()
    }

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
