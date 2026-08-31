import Foundation
import WebKit
import UniformTypeIdentifiers
import WapleCore

public final class WallpaperSchemeHandler: NSObject, @MainActor WKURLSchemeHandler {
    nonisolated public static let scheme = "waple-asset"
    nonisolated public static let host = "wallpaper"

    private let root: URL
    /// WebKit 태스크는 Sendable 이 아니므로 MainActor 밖으로 보내지 않는다.
    /// 백그라운드 작업은 값 타입인 request 스냅샷만 받고, 응답 이벤트를
    /// MainActor 클로저로 되돌린다. stop 은 여기서 태스크와 I/O job을 같이 취소한다.
    @MainActor private var activeTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
    @MainActor private var ioJobs: [ObjectIdentifier: Task<Void, Never>] = [:]
    nonisolated private static let chunkSize = 64 * 1024

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
    nonisolated static let contentSecurityPolicy: String = {
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

    /// 백그라운드 I/O 결과는 Sendable 값으로만 메인 액터에 복귀한다.
    /// HTTPURLResponse 와 WKURLSchemeTask 호출은 `deliver`에서만 이루어진다.
    private enum ResponseEvent: Sendable {
        case response(url: URL, status: Int, headers: [String: String])
        case data(Data)
        case finish
    }

    @MainActor
    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        activeTasks[id] = task
        let requestURL = task.request.url
        let rangeHeader = task.request.value(forHTTPHeaderField: "Range")
        guard let url = requestURL,
              url.scheme == WallpaperSchemeHandler.scheme,
              url.host == WallpaperSchemeHandler.host,
              let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root) else {
            deliverNotFound(id: id, requestURL: requestURL)
            return
        }

        let patches = compatPatches
        let patchedFiles = compatFiles
        let deliver: @MainActor @Sendable (ResponseEvent) -> Bool = { [weak self] event in
            self?.deliver(event, id: id) ?? false
        }
        let job = Task.detached(priority: .userInitiated) {
            await WallpaperSchemeHandler.streamFile(
                requestURL: requestURL,
                rangeHeader: rangeHeader,
                fileURL: fileURL,
                requestPath: url.path,
                compatPatches: patches,
                compatFiles: patchedFiles,
                deliver: deliver
            )
        }
        ioJobs[id] = job
    }

    /// Range 헤더 해석 결과. WebKit 의 미디어 로더(<video>/<audio>)는 Range 요청(206)이
    /// 지원되지 않으면 소스 선택 자체가 실패하므로(networkState=NO_SOURCE) 단일 범위를 지원한다.
    enum ParsedRange: Equatable, Sendable {
        case full                    // Range 없음/해석 불가 → 200 전체 (기존 정적 에셋 경로 그대로)
        case partial(Range<Int64>)   // 206 + Content-Range
        case unsatisfiable           // 416 (시작이 파일 끝 이후)
    }

    /// RFC 7233 단일 바이트 레인지 파싱. 멀티 레인지/비 bytes 단위/문법 오류는 .full 로 무시(전체 200 폴백).
    nonisolated static func parseRangeHeader(_ header: String?, fileSize: Int64) -> ParsedRange {
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
    /// WE 는 이 치환을 **사용자의 워크샵 파일에 직접 덮어쓴다**(`bin/webwallpaper64.exe` 의
    /// 0x14000cee4 에서 출력 스트림을 열고 0x14000cf3b 로 쓴다 — 실패하면
    /// `"Failed writing compat fix at %S\n"`). **[2026-08-21] 어느 바이너리인지 적혀 있지
    /// 않았다** — zcompat 은 `wallpaper64.exe` 에 없고 CEF 서브프로세스 쪽이다
    /// (`docs/re/web-wallpaper-bridge.md`). 둘은 imagebase 가 같아서(0x140000000) 바이너리를
    /// 안 밝히면 다른 이미지에서 그 주소를 떠 보고 엉뚱한 명령을 읽는다. Waple 은
    /// 서빙 시점에 메모리에서만 바꾼다: 결과 바이트는 같고 남의 파일을 건드리지 않는다.
    /// (그래서 WE 가 필요로 한 "패치 후에는 needle 이 사라지므로 재실행이 안전하다" 는 멱등성
    ///  논증에 기대지 않아도 된다 — 매 요청이 원본에서 출발한다.)
    nonisolated private static func compatPatchedData(
        fileURL: URL,
        requestPath: String,
        size: Int64,
        compatPatches: WebCompatPatch.PatchSet,
        compatFiles: Set<String>
    ) -> Data? {
        guard !compatFiles.isEmpty else { return nil }
        guard size > 0, size <= WallpaperSchemeHandler.maxCompatPatchBytes else { return nil }
        let actions = compatPatches.actions(forRelativePath: requestPath)
        guard !actions.isEmpty else { return nil }
        guard let raw = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return nil }
        let patched = WebCompatPatch.applied(raw, actions: actions)
        return patched == raw ? nil : patched   // 바뀐 게 없으면 스트리밍 경로가 더 싸다
    }

    /// 파일 검증·Range 계산·읽기는 detached task에서 수행한다. `deliver`는
    /// MainActor에 격리된 Sendable 클로저라, 이 함수에는 WebKit 참조가 넘어오지 않는다.
    /// 청크마다 await 하므로 전달 순서·백프레셔를 유지하고, stop 이 태스크를 제거하면
    /// 다음 전달이 false를 돌려 I/O도 즉시 끝난다.
    nonisolated private static func streamFile(
        requestURL: URL?,
        rangeHeader: String?,
        fileURL: URL,
        requestPath: String,
        compatPatches: WebCompatPatch.PatchSet,
        compatFiles: Set<String>,
        deliver: @escaping @MainActor @Sendable (ResponseEvent) -> Bool
    ) async {
        guard !Task.isCancelled else { return }
        // [2026-08-28] `.isRegularFileKey` 게이트를 추가한다 — 종전엔 정규파일 검사가 없었다.
        //
        // WE 는 서빙 경로에서 같은 검사를 두 번 한다(`webwallpaper64.exe` 의 거부 문자열
        // `0x14011cebb "Deny request: '%s' is not a regular file.\n"`, 심링크 거부는
        // `0x14011ce4b`). 여기엔 크기 검사밖에 없어서 FIFO 같은 비정규 노드가 요청되면
        // `FileHandle(forReadingFrom:)` 이 열리고 읽기에서 블록한다.
        //
        // 형제 규약이 이미 둘 있다 — `WebRenderer.swift:657` 이 `.isRegularFileKey` 와
        // `.isSymbolicLinkKey` 를 **함께** 요청하고, `ZipImporter.swift:22-25` 가
        // "심링크 미추종(fileExists 는 링크를 따라간다)" 을 명시한다. 그 형태에 맞춘다.
        guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              rv.isRegularFile == true,
              let size = rv.fileSize,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
            guard await deliver(.response(
                url: target,
                status: 404,
                headers: standardHeaders(mime: "text/plain")
            )) else { return }
            guard await deliver(.data(Data())) else { return }
            _ = await deliver(.finish)
            return
        }
        defer { try? handle.close() }
        let total = Int64(size)

        // zcompat: 패치 대상이면 Range 를 무시하고 **패치된 전체**를 200 으로 낸다.
        // Range 를 못 지키는 이유는 단순하다 — 치환이 길이를 바꾸므로 원본 오프셋 기준 범위가
        // 결과와 대응하지 않는다. WebKit 이 스크립트/문서에 Range 를 보내지 않으므로 실제
        // 도달이 없고(도달하더라도 200 전체 응답은 RFC 7233 상 허용되는 축소), 그래서
        // `Accept-Ranges: none` 으로 명시해 재요청을 유도하지 않는다.
        if let patched = compatPatchedData(
            fileURL: fileURL,
            requestPath: requestPath,
            size: total,
            compatPatches: compatPatches,
            compatFiles: compatFiles
        ) {
            let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
            guard await deliver(.response(url: target, status: 200, headers: [
                "Content-Type": mimeType(for: fileURL),
                "Accept-Ranges": "none",
                "Content-Length": String(patched.count),
                "Access-Control-Allow-Origin": "\(scheme)://\(host)",
                "Content-Security-Policy": contentSecurityPolicy,
            ])) else { return }
            guard await deliver(.data(patched)) else { return }
            _ = await deliver(.finish)
            return
        }

        var headers = [
            "Content-Type": mimeType(for: fileURL),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "\(scheme)://\(host)",
            "Content-Security-Policy": contentSecurityPolicy,
        ]
        let status: Int
        let body: Range<Int64>
        switch parseRangeHeader(rangeHeader, fileSize: total) {
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
        guard await deliver(.response(url: target, status: status, headers: headers)) else { return }
        if body.lowerBound > 0 { try? handle.seek(toOffset: UInt64(body.lowerBound)) }
        var remaining = Int(body.upperBound - body.lowerBound)
        while remaining > 0, !Task.isCancelled {
            let data = autoreleasepool {
                (try? handle.read(upToCount: Swift.min(Self.chunkSize, remaining))) ?? Data()
            }
            if data.isEmpty { break }
            remaining -= data.count
            guard await deliver(.data(data)) else { return }
        }
        guard !Task.isCancelled else { return }
        _ = await deliver(.finish)
    }

    @MainActor
    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        activeTasks.removeValue(forKey: id)
        ioJobs.removeValue(forKey: id)?.cancel()
    }

    nonisolated private static func standardHeaders(mime: String) -> [String: String] {
        [
            "Content-Type": mime,
            "Access-Control-Allow-Origin": "\(scheme)://\(host)",
            "Content-Security-Policy": contentSecurityPolicy,
        ]
    }

    @MainActor
    private func deliverNotFound(id: ObjectIdentifier, requestURL: URL?) {
        let target = requestURL ?? URL(string: "waple-asset://wallpaper/")!
        guard deliver(.response(
            url: target,
            status: 404,
            headers: Self.standardHeaders(mime: "text/plain")
        ), id: id) else { return }
        guard deliver(.data(Data()), id: id) else { return }
        _ = deliver(.finish, id: id)
    }

    /// WKURLSchemeTask 콜백의 유일한 소비 지점. WebKit SDK의 MainActor 계약과
    /// stop 반환 후 콜백 금지를 같은 격리 영역에서 지킨다.
    @MainActor
    private func deliver(_ event: ResponseEvent, id: ObjectIdentifier) -> Bool {
        guard let task = activeTasks[id] else { return false }
        switch event {
        case .response(let url, let status, let headers):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else { return false }
            task.didReceive(response)
        case .data(let data):
            task.didReceive(data)
        case .finish:
            task.didFinish()
            activeTasks.removeValue(forKey: id)
            ioJobs.removeValue(forKey: id)
        }
        return true
    }

    /// 미디어 확장자 → MIME 명시 고정 테이블. UTType 은 LaunchServices(설치 앱의 UTI 등록)에
    /// 의존해 webm/ogv 등이 머신에 따라 미해결(→ octet-stream)될 수 있고, 그러면 <video> 소스
    /// 선택이 실패한다. 코퍼스 web <video> 는 전부 webm.
    nonisolated static let mediaMIMETypes: [String: String] = [
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

    nonisolated static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let mime = mediaMIMETypes[ext] { return mime }
        if let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
