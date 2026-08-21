import Foundation
// @preconcurrency: 컴파일러 자체 fix-it(`:2:1 add '@preconcurrency' … from module 'WebKit'`).
// `any WKURLSchemeTask` 는 Sendable 이 아닌데 io 큐 클로저가 태스크를 잡는다 — 이건 WebKit 이
// 동시성 감사를 받기 전 API 라서 나는 진단이고, 실제 직렬화는 우리 쪽 activeTasks/NSLock 이 한다
// (stop 이후 호출 금지 계약을 isTaskLive/withLiveTask 가 지킨다 — F575→F590 이력 참조).
@preconcurrency import WebKit
import UniformTypeIdentifiers
import WapleCore

public final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    // nonisolated: WKURLSchemeHandler 가 @MainActor 프로토콜이라 이 클래스는 멤버 전체가 메인 액터로
    // **추론**되지만, 이 타입의 실제 설계는 그 반대다 — 요청 처리는 ioQueue(동시 큐)에서 돌고 상태는
    // NSLock 으로 지킨다(아래 activeTasks). 그래서 io 큐에서 읽는 순수 상수·순수 함수는 격리에서
    // 명시적으로 빼낸다. 이게 없으면 "메인 액터 프로퍼티를 Sendable 클로저에서 참조" 진단이 뜨는데,
    // 그건 여기선 실제 위험이 아니라 추론이 틀렸다는 신호다(값은 불변, 함수는 인스턴스 상태 무접근).
    nonisolated public static let scheme = "waple-asset"
    nonisolated public static let host = "wallpaper"

    private let root: URL
    private let ioQueue = DispatchQueue(label: "waple.scheme.io", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()  // 시작됐고 아직 stop 안 된 태스크(use-after-stop 방지)
    private let chunkSize = 64 * 1024

    /// WE `assets/zcompat/web/<워크샵ID>.json` 전표(없으면 빈 값). 규칙·주소 근거는
    /// `WapleCore/WebCompatPatch.swift` 헤더 참조.
    private let compatPatches: WebCompatPatch.PatchSet
    /// 전표가 언급하는 파일들(정규화된 상대 경로). 요청마다 액션 배열을 훑지 않기 위한 게이트.
    private let compatFiles: Set<String>

    /// 호환성 패치를 위해 통째로 메모리에 올릴 파일의 상한. 동봉 5건의 대상은 전부 번들된
    /// JS(수백 KB)다 — 상한을 넘으면 패치를 포기하고 원본을 그대로 스트리밍한다(무회귀).
    /// 스트리밍 경로가 64KB 청크인 이유와 같은 이유로, 여기서만 예외적으로 전체를 읽는다:
    /// 치환은 파일 전역을 봐야 하고 청크 경계에 needle 이 걸치면 매치를 놓친다.
    nonisolated private static let maxCompatPatchBytes: Int64 = 32 * 1024 * 1024

    public convenience init(rootURL: URL) {
        // WE 는 `index.html` 의 상위 폴더명을 워크샵 ID 로 쓴다(0x14000c29e). Waple 의 프로젝트
        // 루트 폴더명이 같은 값이다(`WallpaperProject.id` = 폴더명 = 워크샵 ID).
        let id = rootURL.standardizedFileURL.lastPathComponent
        self.init(rootURL: rootURL,
                  compatPatches: WebCompatPatch.load(projectID: id, in: BaseAssetsSettings.searchRoots))
    }

    /// 지정 이니셜라이저 — 전표를 직접 주입한다(테스트/상위 계층이 다른 경로에서 찾은 경우).
    public init(rootURL: URL, compatPatches: WebCompatPatch.PatchSet) {
        self.root = rootURL.standardizedFileURL
        self.compatPatches = compatPatches
        self.compatFiles = compatPatches.referencedFiles
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
    /// nonisolated: io 큐에서 호출되는 순수 함수(인스턴스 상태 무접근) — 위 scheme/host 주석 참조.
    nonisolated public static func fileURL(forRequestPath path: String, root: URL) -> URL? {
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
                self.respondFile(task, id: id, requestURL: requestURL, rangeHeader: rangeHeader,
                                 fileURL: fileURL, requestPath: url.path)
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

    /// zcompat 대상이면 패치된 전체 바이트를, 아니면 nil(= 기존 스트리밍 경로 그대로).
    ///
    /// WE 는 이 치환을 **사용자의 워크샵 파일에 직접 덮어쓴다**(0x14000cee4 에서 출력 스트림을
    /// 열고 0x14000cf3b 로 쓴다 — 실패하면 `"Failed writing compat fix at %S\n"`). Waple 은
    /// 서빙 시점에 메모리에서만 바꾼다: 결과 바이트는 같고 남의 파일을 건드리지 않는다.
    /// (그래서 WE 가 필요로 한 "패치 후에는 needle 이 사라지므로 재실행이 안전하다" 는 멱등성
    ///  논증에 기대지 않아도 된다 — 매 요청이 원본에서 출발한다.)
    private func compatPatchedData(fileURL: URL, requestPath: String, size: Int64) -> Data? {
        guard !compatFiles.isEmpty else { return nil }
        guard size > 0, size <= WallpaperSchemeHandler.maxCompatPatchBytes else { return nil }
        let actions = compatPatches.actions(forRelativePath: requestPath)
        guard !actions.isEmpty else { return nil }
        guard let raw = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return nil }
        let patched = WebCompatPatch.applied(raw, actions: actions)
        return patched == raw ? nil : patched   // 바뀐 게 없으면 스트리밍 경로가 더 싸다
    }

    private func respondFile(_ task: WKURLSchemeTask, id: ObjectIdentifier, requestURL: URL?,
                             rangeHeader: String?, fileURL: URL, requestPath: String) {
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

        // zcompat: 패치 대상이면 Range 를 무시하고 **패치된 전체**를 200 으로 낸다.
        // Range 를 못 지키는 이유는 단순하다 — 치환이 길이를 바꾸므로 원본 오프셋 기준 범위가
        // 결과와 대응하지 않는다. WebKit 이 스크립트/문서에 Range 를 보내지 않으므로 실제
        // 도달이 없고(도달하더라도 200 전체 응답은 RFC 7233 상 허용되는 축소), 그래서
        // `Accept-Ranges: none` 으로 명시해 재요청을 유도하지 않는다.
        if let patched = compatPatchedData(fileURL: fileURL, requestPath: requestPath, size: total) {
            let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
            let response = HTTPURLResponse(
                url: target, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": WallpaperSchemeHandler.mimeType(for: fileURL),
                    "Accept-Ranges": "none",
                    "Content-Length": String(patched.count),
                    "Access-Control-Allow-Origin": "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)",
                    "Content-Security-Policy": WallpaperSchemeHandler.contentSecurityPolicy,
                ]
            )!
            guard withLiveTask(id, { task.didReceive(response) }) else { return }
            guard withLiveTask(id, { task.didReceive(patched) }) else { return }
            DispatchQueue.main.async {
                guard self.isTaskLive(id) else { return }
                task.didFinish()
                self.finishTask(id)
            }
            return
        }

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
