import CryptoKit
import Foundation
import WapleCore

/// 로컬 ffmpeg 로 AVFoundation 미지원 컨테이너(mkv/avi/webm)를 mp4(H.264/AAC)로 변환해 네이티브 재생을
/// 가능케 한다. 변환 결과는 ~/Library/Application Support/Waple/converted/<원본경로 sha256>.mp4 로 캐시(재사용).
/// ffmpeg 부재 시 nil 반환 + 로그(호출부가 기존 WKWebView 폴백 유지).
public enum FFmpegConverter {
    /// 변환 필요(AVFoundation 미지원) 확장자 — VideoRenderer.unsupportedExtensions 단일 출처.
    public static var convertExtensions: Set<String> { VideoRenderer.unsupportedExtensions }
    public static func needsConversion(_ url: URL) -> Bool {
        convertExtensions.contains(url.pathExtension.lowercased())
    }

    /// ffmpeg 실행파일 경로(최초 1회 탐지, 캐시). 고정 경로 우선 → PATH 폴백.
    public static let executableURL: URL? = detectExecutable()
    public static var isAvailable: Bool { executableURL != nil }

    private static func detectExecutable() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffmpeg" }
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// 변환 캐시 디렉터리(~/Library/Application Support/Waple/converted).
    public static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/converted", isDirectory: true)
    }

    /// 원본 경로 → 캐시 mp4 경로(절대경로 sha256 — 서로 다른 원본 충돌 방지, 같은 원본 재사용).
    public static func cachedURL(for source: URL) -> URL {
        let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir().appendingPathComponent("\(hash).mp4")
    }

    /// ffmpeg 인자 조립(순수 — 테스트 대상). videotoolbox 우선, 폴백은 libx264. 오디오는 aac.
    static func arguments(input: URL, output: URL, useVideotoolbox: Bool) -> [String] {
        ["-y", "-loglevel", "error", "-i", input.path,
         "-c:v", useVideotoolbox ? "h264_videotoolbox" : "libx264",
         "-c:a", "aac", output.path]
    }

    /// 비동기 변환. 완료 콜백은 메인 큐에서 호출(성공=mp4 URL, 실패/부재/타임아웃=nil + 로그).
    /// 캐시 히트 시 즉시 콜백. 메인스레드를 블록하지 않는다.
    public static func convert(_ source: URL, timeout: TimeInterval = 300,
                              completion: @escaping (URL?) -> Void) {
        let out = cachedURL(for: source)
        if FileManager.default.fileExists(atPath: out.path) { completion(out); return }
        guard let ff = executableURL else {
            WapleLog.warn("[Waple] ffmpeg not found — 'brew install ffmpeg' to play \(source.lastPathComponent)")
            completion(nil); return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = run(ff: ff, source: source, output: out, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 실제 변환(백그라운드). videotoolbox 실패 시 libx264 재시도. 부분 파일이 캐시로 남지 않도록
    /// 임시 파일에 쓰고 exit 0 에만 캐시 경로로 원자적 이동.
    private static func run(ff: URL, source: URL, output: URL, timeout: TimeInterval) -> URL? {
        try? FileManager.default.createDirectory(at: cacheDir(), withIntermediateDirectories: true)
        let tmp = cacheDir().appendingPathComponent("\(UUID().uuidString).part.mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        for useVT in [true, false] {
            guard runOnce(ff: ff, args: arguments(input: source, output: tmp, useVideotoolbox: useVT), timeout: timeout),
                  FileManager.default.fileExists(atPath: tmp.path) else {
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
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        proc.waitUntilExit()
        killer.cancel()
        return proc.terminationStatus == 0
    }
}
