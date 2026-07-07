import AppKit

/// 지금 재생 중 정보(미디어 연동 — 웹 wallpaperRegisterMedia* 리스너용).
public struct NowPlayingInfo: Equatable {
    public enum State: Int { case stopped = 0, playing = 1, paused = 2 }
    public var state: State
    public var title: String
    public var artist: String
    public var album: String
    public var position: Double   // 초
    public var duration: Double   // 초

    public init(state: State, title: String = "", artist: String = "", album: String = "",
                position: Double = 0, duration: Double = 0) {
        self.state = state; self.title = title; self.artist = artist; self.album = album
        self.position = position; self.duration = duration
    }
}

public protocol NowPlayingProvider {
    func fetch() -> NowPlayingInfo?
}

/// 앨범아트 공급(선택 채택 — MediaPoller 가 트랙 변경 시에만 호출). 원본 인코딩 바이트(JPEG/PNG).
/// 실패/아트워크 없음 → nil(썸네일 이벤트 생략 — graceful).
public protocol ArtworkProviding {
    func fetchArtwork() -> Data?
}

/// AppleScript 로 Music/Spotify 를 폴링(사설 API 불사용). **실행 중인 플레이어만** 질의해
/// 앱을 실수로 띄우지 않는다. 최초 AppleEvent 전송 시 macOS 가 자동화(TCC) 프롬프트를 1회 표시.
public final class AppleScriptNowPlayingProvider: NowPlayingProvider {
    public init() {}

    /// 실행 중인 지원 플레이어 앱 이름(AppleScript 타깃). 둘 다 있으면 재생 중일 확률이 높은 Spotify 우선.
    static func runningPlayer(bundleIds: [String]) -> String? {
        let mapping: [(String, String)] = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
        for (bid, name) in mapping where bundleIds.contains(bid) { return name }
        return nil
    }

    /// osascript 소스: 탭 구분 6필드(state, title, artist, album, position, duration).
    /// 트랙 없음/정지는 "0" 한 필드만. 변수명 `st` 는 금지 — AppleScript 가 예약 용어로 파싱해
    /// 문법 오류(-2741, 실측 2026-07-04: `set st to 1` 단독으로도 실패) → stateNum.
    static func script(for app: String) -> String {
        """
        tell application "\(app)"
            if player state is stopped then
                return "0"
            end if
            set stateNum to 1
            if player state is paused then set stateNum to 2
            set t to name of current track
            set ar to artist of current track
            set al to album of current track
            set pos to player position
            set dur to duration of current track
            return (stateNum as text) & tab & t & tab & ar & tab & al & tab & (pos as text) & tab & (dur as text)
        end tell
        """
    }

    /// 스크립트 출력 파싱(순수). Spotify 는 duration 이 ms — 1000 초과 & Spotify 는 초로 환산.
    static func parse(_ output: String, app: String) -> NowPlayingInfo? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let f = line.components(separatedBy: "\t")
        guard let stRaw = Int(f[0]), let state = NowPlayingInfo.State(rawValue: stRaw) else { return nil }
        guard f.count >= 6 else { return NowPlayingInfo(state: .stopped) }
        var dur = Double(f[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        if app == "Spotify" { dur /= 1000 }  // Spotify AppleScript 는 ms
        return NowPlayingInfo(state: state, title: f[1], artist: f[2], album: f[3],
                              position: Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0,
                              duration: dur)
    }

    public func fetch() -> NowPlayingInfo? {
        guard let app = Self.currentRunningPlayer() else { return nil }
        guard let out = Self.runOSAScript(Self.script(for: app)) else { return nil }
        return Self.parse(out, app: app)
    }

    static func currentRunningPlayer() -> String? {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        return runningPlayer(bundleIds: running)
    }

    /// osascript 실행 → stdout(성공 시). 실패/비정상 종료 → nil.
    static func runOSAScript(_ source: String, timeout: TimeInterval = 2) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            _ = finished.wait(timeout: .now() + 0.5)
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// 앨범아트: Music 은 `raw data of artwork 1`(원본 JPEG/PNG 바이트)을 AppleScript 가 임시 파일로 쓰고
/// 읽는다(osascript stdout 은 바이너리 부적합). Spotify 는 `artwork url` → HTTPS 다운로드.
/// TCC 규약은 fetch() 와 동일: 대상 앱이 실행 중일 때만 AppleEvent 를 보내고, 최초 1회 macOS
/// 자동화 프롬프트가 뜬다(추가 권한 불요 — 같은 앱 대상이라 기존 승인 재사용).
extension AppleScriptNowPlayingProvider: ArtworkProviding {
    /// Music 아트워크 추출 스크립트: raw data 를 destPath 에 기록, 성공 시 "ok".
    static func musicArtworkScript(destPath: String) -> String {
        """
        tell application "Music"
            if player state is stopped then return ""
            if (count of artworks of current track) is 0 then return ""
            set d to raw data of artwork 1 of current track
        end tell
        set f to open for access POSIX file "\(destPath)" with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
    }

    static let spotifyArtworkURLScript = """
    tell application "Spotify"
        if player state is stopped then return ""
        return artwork url of current track
    end tell
    """

    public func fetchArtwork() -> Data? {
        guard let app = Self.currentRunningPlayer() else { return nil }
        if app == "Music" {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("waple_artwork_\(ProcessInfo.processInfo.processIdentifier).dat")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let out = Self.runOSAScript(Self.musicArtworkScript(destPath: tmp.path)),
                  out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
                  let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
            return data
        }
        // Spotify: artwork url → 동기 다운로드(유틸리티 큐에서 호출됨 — 10초 상한).
        guard let out = Self.runOSAScript(Self.spotifyArtworkURLScript),
              let url = URL(string: out.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else { return nil }
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return result
    }
}
