import AVFoundation
import CryptoKit
import Foundation
import WapleCore

/// 로컬 ffmpeg 로 AVFoundation 미지원 컨테이너를 mp4(H.264/AAC)로 변환해 네이티브 재생을
/// 가능케 한다. 변환 결과는 ~/Library/Application Support/Waple/converted/<원본경로 sha256>.mp4 로 캐시(재사용).
/// ffmpeg 부재 시 nil 반환 + 로그(호출부가 기존 WKWebView 폴백 유지).
public enum FFmpegConverter {
    /// 변환 필요(AVFoundation 미지원) 확장자 — VideoRenderer.unsupportedExtensions 단일 출처.
    public static var convertExtensions: Set<String> { VideoRenderer.unsupportedExtensions }
    public static func needsConversion(_ url: URL) -> Bool {
        convertExtensions.contains(url.pathExtension.lowercased())
    }

    /// ffmpeg 실행파일 경로(최초 1회 탐지, 캐시). 명시 opt-in → 고정 경로 → opt-in PATH 순.
    public static let executableURL: URL? = detectExecutable()
    public static var isAvailable: Bool { executableURL != nil }

    static let explicitExecutableEnv = "WAPLE_FFMPEG_PATH"
    static let trustPathEnv = "WAPLE_FFMPEG_TRUST_PATH"
    static let fixedExecutablePaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    static func detectExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        knownExecutablePaths: [String] = fixedExecutablePaths,
        isExecutable: (String) -> Bool = defaultExecutableCheck
    ) -> URL? {
        if let explicit = environment[explicitExecutableEnv],
           isAbsoluteExecutablePath(explicit),
           isExecutable(explicit) {
            return URL(fileURLWithPath: explicit)
        }

        if let known = knownExecutablePaths.first(where: isExecutable) {
            return URL(fileURLWithPath: known)
        }

        guard environment[trustPathEnv] == "1",
              let path = environment["PATH"] else { return nil }
        for entry in path.split(separator: ":") {
            let dir = String(entry)
            guard dir.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("ffmpeg").path
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static func defaultExecutableCheck(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func isAbsoluteExecutablePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && path.hasPrefix("/")
    }

    /// F840: isReusableConvertedOutput 의 동기 대기 상한(초).
    static let assetProbeTimeoutSeconds: Double = 5

    /// 캐시할 변환 결과 mp4 최대 개수. 초과 시 마지막 접근(mtime)이 오래된 것부터 evict.
    /// F840: 종전엔 상한이 전혀 없어 webm/mkv 를 여러 개 시도할 때마다 수백 MB 결과물이
    /// ~/Library/Application Support/Waple/converted 에 무한 축적됐다(사용자가 존재도 모르는 경로).
    /// 정책·구현은 VideoTextureExtractor(maxCachedVideos=8, evictOldest)와 동일하게 맞춘다.
    public static let maxCachedConversions = 8

    /// 캐시 적중 파일의 mtime 을 now 로 갱신 — evictOldest 의 LRU 순서용
    /// (VideoTextureExtractor.touch 와 동형. 그쪽은 private 이라 여기 같은 구현을 둔다).
    private static func touchCacheHit(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 변환 캐시 디렉터리(~/Library/Application Support/Waple/converted).
    public static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/converted", isDirectory: true)
    }

    /// 원본 경로+파일 상태 → 캐시 mp4 경로. 같은 경로의 원본이 교체되면 stale 변환물을 재사용하지 않는다.
    public static func cachedURL(for source: URL) -> URL {
        let hash = SHA256.hash(data: cacheKeyData(for: source))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir().appendingPathComponent("\(hash).mp4")
    }

    private static func cacheKeyData(for source: URL) -> Data {
        var parts = [source.standardizedFileURL.path]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: source.path) {
            if let size = attrs[.size] { parts.append("size:\(size)") }
            if let mtime = attrs[.modificationDate] as? Date {
                parts.append(String(format: "mtime:%.9f", mtime.timeIntervalSince1970))
            }
        }
        return Data(parts.joined(separator: "\u{0}").utf8)
    }

    /// ffmpeg 인자 조립(순수 — 테스트 대상). videotoolbox 우선, 폴백은 libx264. 오디오는 aac.
    static func arguments(input: URL, output: URL, useVideotoolbox: Bool) -> [String] {
        ["-y", "-loglevel", "error", "-i", input.path,
         "-c:v", useVideotoolbox ? "h264_videotoolbox" : "libx264",
         "-c:a", "aac", output.path]
    }

    /// F557: 변환 작업 직렬 큐 — 동일 소스 동시 convert(복구 경로와 사용자 재마운트, 멀티모니터)가
    /// 각자 ffmpeg 를 돌린 뒤 한쪽이 removeItem(output) 후 moveItem 실패하면 유효 출력이 삭제되고 nil
    /// 반환되던 경주를 차단한다(캐시 remove+move 비원자 구간). 변환은 무거운 ffmpeg 실행이라 직렬화 비용 무해.
    private static let workQueue = DispatchQueue(label: "waple.ffmpeg.convert", qos: .utility)

    /// 비동기 변환. 완료 콜백은 메인 큐에서 호출(성공=mp4 URL, 실패/부재/타임아웃=nil + 로그).
    /// 캐시 히트 검사(AVURLAsset.isPlayable 동기 로드)까지 백그라운드 — 메인스레드를 블록하지 않는다.
    ///
    /// [2026-08-25] `completion` 이 `@Sendable` 이다. 이 콜백은 **호출 큐를 두 번 건넌다** —
    /// 호출자 → `workQueue`(백그라운드) → `DispatchQueue.main`. 그 사실은 종전에도 참이었고
    /// 위 주석이 이미 적고 있었지만 **타입이 그것을 말하지 않아** 컴파일러가 검사할 수 없었다.
    /// 진단이 나던 자리는 `completion` **캡처 지점**(아래 `workQueue.async` 클로저와
    /// `completeOnMain` 호출)이지 이 선언 줄이 아니다 — 원인과 증상이 다른 줄에 있다는 뜻이라,
    /// 고칠 때 헷갈리지 않게 여기 적어 둔다. (자기참조 줄 번호는 다음 커밋에 썩는다.)
    public static func convert(_ source: URL, timeout: TimeInterval = 300,
                              completion: @escaping @Sendable (URL?) -> Void) {
        workQueue.async {
            let out = cachedURL(for: source)
            if FileManager.default.fileExists(atPath: out.path) {
                if isReusableConvertedOutput(out) {
                    touchCacheHit(out)   // LRU 갱신 — 최근 쓴 변환물이 evict 대상이 되지 않게
                    completeOnMain(completion, out)
                    return
                }
                WapleLog.warn("[Waple] ignoring invalid ffmpeg cache output: \(out.path)")
                try? FileManager.default.removeItem(at: out)
            }
            guard let ff = executableURL else {
                WapleLog.warn("[Waple] ffmpeg not found — 'brew install ffmpeg' to play \(source.lastPathComponent)")
                completeOnMain(completion, nil)
                return
            }
            let result = run(ff: ff, source: source, output: out, timeout: timeout)
            completeOnMain(completion, result)
        }
    }

    private static func completeOnMain(_ completion: @escaping @Sendable (URL?) -> Void, _ result: URL?) {
        DispatchQueue.main.async { completion(result) }
    }

    static func isReusableConvertedOutput(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 0 else { return false }
        // load(.isPlayable) 비동기 — 호출부(convert/run)가 백그라운드 큐라 세마포어 동기 대기로 충분.
        // (박스 패턴 근거는 SceneVideoLayer.swift 의 SemaphoreResultBox 주석 참조 — Swift 5.10 캡처 var 에러 대응)
        let sem = DispatchSemaphore(value: 0)
        let playable = SemaphoreResultBox(false)
        Task {
            playable.value = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            sem.signal()
        }
        // F840: 무한 대기 금지. 여기는 **직렬** workQueue 위라, Task 가 완료되지 않으면(협조 스레드풀
        // 고갈·응답 없는 볼륨) 그 큐가 영구히 막혀 이후 모든 변환 요청이 조용히 사라진다.
        // 타임아웃 시 박스를 읽지 않는다(락이 없어 늦게 도착한 쓰기와 경합) — 재사용 불가로 처리.
        //
        // ⚠️ r3-O13: "재사용 불가" 의 **실제 결과는 삭제**다. 이 false 를 받는 `convert(_:timeout:)`
        // 의 캐시 히트 분기가 `ignoring invalid ffmpeg cache output` 로그와 함께 `removeItem` 으로
        // 캐시 파일을 지운다. 즉 프로브가 5초(`assetProbeTimeoutSeconds`) 안에 안 끝나면 **파일이
        // 실제로 유효해도** 삭제되고 전체 재변환이 걸린다. 종전 이 주석은 삭제를 적지 않아
        // "이번 재생만 캐시를 안 쓴다" 로 읽혔다. 타임아웃(느린 볼륨·협조 스레드풀 포화)과
        // 손상(진짜 무효)을 구분하려면 반환 타입을 3값으로 넓혀야 한다 — 이번 라운드 범위 밖.
        guard sem.wait(timeout: .now() + assetProbeTimeoutSeconds) == .success else {
            WapleLog.warn("[Waple] ffmpeg cache probe timed out: \(url.lastPathComponent)")
            return false
        }
        return playable.value
    }

    /// 실제 변환(백그라운드). videotoolbox 실패 시 libx264 재시도. 부분 파일이 캐시로 남지 않도록
    /// 임시 파일에 쓰고 exit 0 에만 캐시 경로로 원자적 이동.
    ///
    /// **벽시계 상한은 `timeout` 이 아니라 `2·(timeout + 5)` 다**(r3-M15). 아래 `for useVT in
    /// [true, false]` 가 `runOnce` 를 **최대 2회** 부르고, 각 회의 상한은 `runOnce` 의
    /// `timeout` 후 `terminate()` + **5초 유예** 뒤 `SIGKILL` 이다. 기본 `timeout: 300`(convert 의
    /// 기본 인자)이면 **최대 약 610초**. 선행 감사 문서(`docs/audit-r2-lanes/lane08-app.md`)가
    /// "최대 300초" 라고 적은 것은 재시도와 유예를 빠뜨린 값이라 실제의 절반이다.
    private static func run(ff: URL, source: URL, output: URL, timeout: TimeInterval) -> URL? {
        try? FileManager.default.createDirectory(at: cacheDir(), withIntermediateDirectories: true)
        let tmp = cacheDir().appendingPathComponent("\(UUID().uuidString).part.mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        for useVT in [true, false] {
            guard runOnce(ff: ff, args: arguments(input: source, output: tmp, useVideotoolbox: useVT), timeout: timeout),
                  isReusableConvertedOutput(tmp) else {
                try? FileManager.default.removeItem(at: tmp)   // 다음 시도 위해 정리
                continue
            }
            do {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: tmp, to: output)
                // 새 결과물 기록 후 상한 초과분 정리(방금 만든 output 은 mtime 최신이라 대상 아님).
                VideoTextureExtractor.evictOldest(in: cacheDir(), keep: maxCachedConversions)
                return output
            } catch {
                WapleLog.warn("[Waple] ffmpeg cache move failed: \(error)")
                return nil
            }
        }
        WapleLog.warn("[Waple] ffmpeg conversion failed for \(source.lastPathComponent)")
        return nil
    }

    /// Process 1회 실행. 타임아웃 시 terminate. exit 0 = 성공.
    private static func runOnce(ff: URL, args: [String], timeout: TimeInterval) -> Bool {
        let proc = Process()
        proc.executableURL = ff
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            WapleLog.warn("[Waple] ffmpeg launch failed: \(error)"); return false
        }
        let killer = DispatchWorkItem { [proc] in
            guard proc.isRunning else { return }
            proc.terminate()
            // F558: SIGTERM 을 무시하는 ffmpeg 가 waitUntilExit 를 영구 블록(스레드 리크)하지 않도록
            // 유예 후 SIGKILL 에스컬레이션.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [proc] in
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        proc.waitUntilExit()
        killer.cancel()
        return proc.terminationStatus == 0
    }
}
