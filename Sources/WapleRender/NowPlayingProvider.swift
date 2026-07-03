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
    /// 트랙 없음/정지는 "0" 한 필드만.
    static func script(for app: String) -> String {
        """
        tell application "\(app)"
            if player state is stopped then
                return "0"
            end if
            set st to 1
            if player state is paused then set st to 2
            set t to name of current track
            set ar to artist of current track
            set al to album of current track
            set pos to player position
            set dur to duration of current track
            return (st as text) & tab & t & tab & ar & tab & al & tab & (pos as text) & tab & (dur as text)
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
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        guard let app = Self.runningPlayer(bundleIds: running) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", Self.script(for: app)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0,
              let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        return Self.parse(out, app: app)
    }
}
