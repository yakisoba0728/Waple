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
    public static func convert(_ source: URL, timeout: TimeInterval = 300,
                              completion: @escaping (URL?) -> Void) {
        workQueue.async {
            let out = cachedURL(for: source)
            if FileManager.default.fileExists(atPath: out.path) {
                if isReusableConvertedOutput(out) {
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

    private static func completeOnMain(_ completion: @escaping (URL?) -> Void, _ result: URL?) {
        DispatchQueue.main.async { completion(result) }
    }

    static func isReusableConvertedOutput(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 0 else { return false }
        // load(.isPlayable) 비동기 — 호출부(convert/run)가 백그라운드 큐라 세마포어 동기 대기로 충분.
        let sem = DispatchSemaphore(value: 0)
        var playable = false
        Task {
            playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            sem.signal()
        }
        sem.wait()
        return playable
    }

    /// 실제 변환(백그라운드). videotoolbox 실패 시 libx264 재시도. 부분 파일이 캐시로 남지 않도록
    /// 임시 파일에 쓰고 exit 0 에만 캐시 경로로 원자적 이동.
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
