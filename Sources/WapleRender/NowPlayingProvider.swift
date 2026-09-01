import AppKit

/// 지금 재생 중 정보(미디어 연동 — 웹 wallpaperRegisterMedia* 리스너용).
/// Sendable: 전 필드가 값 타입(String/Double/Int enum) — MediaPoller 가 백그라운드 fetch 결과를
/// 메인 큐로 넘기므로 필수다(public 타입은 Sendable 이 자동 추론되지 않는다).
public struct NowPlayingInfo: Equatable, Sendable {
    public enum State: Int, Sendable { case stopped = 0, playing = 1, paused = 2 }
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

    /// 스크립트 출력 파싱(순수). Spotify 는 duration 이 ms 라 초로 환산한다.
    ///
    /// **[정정 r3-O15] "1000 초과 &" 조건은 코드에도 이력에도 없다.** 종전 이 줄은
    /// "1000 초과 & Spotify 는 초로 환산" 이라고 적었는데, 아래 분기는 `app == "Spotify"` 만
    /// 보는 **무조건** 환산이다. `git log -p --follow` 로 이 파일 전 이력을 훑어도 `1000` 이
    /// 등장하는 줄은 그 나눗셈 한 줄뿐이라, 그런 가드가 존재했다가 지워진 것도 아니다.
    /// 조건을 코드에 넣지 않고 주석만 고치는 이유: Spotify AppleScript 의 `duration` 은
    /// 단위가 ms 로 **고정**이라 값 크기로 단위를 추측하는 것이 오히려 틀린다(1초 미만
    /// 트랙이면 1000 이하가 나오고, 그때 환산을 건너뛰면 1000배 틀린 값이 된다).
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

    /// osascript 실행 → stdout(성공 시). 실패/비정상 종료/타임아웃 → nil.
    static func runOSAScript(_ source: String, timeout: TimeInterval = 2) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return nil
        }
        // F840: 파이프 배수를 종료 대기와 **동시에** 돌린다. 종전에는 waitUntilExit 뒤에야 읽었기 때문에
        // 출력이 파이프 버퍼(64KB)를 넘으면 자식이 write 에서 블록 → 종료하지 않고, 대기 스레드가
        // 그대로 붙잡혔다(타임아웃 terminate 가 있어도 그동안 유틸리티 스레드 하나가 통째로 정지).
        // stderr 도 같은 이유로 배수 대상이다(종전엔 아무도 읽지 않는 Pipe 였다).
        let outBox = SemaphoreResultBox(Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            outBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            p.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // F840-sweep: SIGTERM 만 보내고 끝내면 무시하는 자식이 좀비로 남고 대기 스레드·FD 가
            // 함께 샌다. 형제 3곳(ZipImporter:69 · SteamCmdDownloader:203 · FFmpegConverter:206)은
            // 전부 에스컬레이션을 하는데 여기만 없었다.
            // 주의: "osascript 가 SIGTERM 을 무시한다" 는 **미입증**이다 — 이건 그 전제가 아니라
            // 형제와 같은 방어를 갖추는 것이다. 정상 종료하면 아래 kill 은 실행되지 않는다.
            p.terminate()   // SIGTERM
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()   // SIGKILL 수거 확정(좀비 방지)
            }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        // 자식이 끝났으면 쓰기단이 닫혀 배수도 곧 EOF 다. 그래도 상한을 두고, 미완이면 박스를
        // 읽지 않는다(락 없는 박스 — 늦게 도착할 쓰기와 경합).
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        return String(data: outBox.value, encoding: .utf8)
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

    /// F554: 아트워크 임시 경로(호출마다 고유) — 종전 PID 고정 경로는 멀티모니터 다중 폴섹이 같은 파일에
    /// interleave write/read/defer 삭제로 절단/혼합 JPEG 를 만들었다. UUID 로 경합 제거.
    static func artworkTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_artwork_\(UUID().uuidString).dat")
    }

    /// F564: 아트워크 URL 검증 — https 만 허용(평문 http·file 등 차단).
    static func isValidArtworkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    public func fetchArtwork() -> Data? {
        guard let app = Self.currentRunningPlayer() else { return nil }
        if app == "Music" {
            let tmp = Self.artworkTempURL()
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let out = Self.runOSAScript(Self.musicArtworkScript(destPath: tmp.path)),
                  out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
                  let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
            return data
        }
        // Spotify: artwork url → 동기 다운로드(유틸리티 큐에서 호출됨 — 10초 상한).
        // F564: 평문 http 차단 — https 만 허용(종전 hasPrefix("http") 는 평문 http 통과).
        guard let out = Self.runOSAScript(Self.spotifyArtworkURLScript),
              let url = URL(string: out.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.isValidArtworkURL(url) else { return nil }
        // 지역 var 를 완료 클로저에서 변형하던 코드를 리포 관용(SemaphoreResultBox — SceneVideoLayer.swift:58,
        // 이 파일 위쪽 runOSAScript 도 사용)으로 교체한다. 표기만의 문제가 아니었다: `_ = sem.wait(timeout:)`
        // 는 **타임아웃이어도 그대로 진행**하므로, 10초를 넘긴 다운로드의 완료 콜백이 쓰는 동안 return 이
        // 같은 변수를 읽는 실경합이 있었다(happens-before 는 signal→wait 성공 경로에만 성립).
        // 박스 규약대로 타임아웃이면 값을 읽지 않고 nil 로 간다(SceneVideoLayer 의 같은 판단·같은 이유).
        let box = SemaphoreResultBox<Data?>(nil)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { box.value = data }
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 10) == .success else { return nil }
        return box.value
    }
}
