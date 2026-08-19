import Foundation
import WapleCore

// steamcmd 로 워크샵 아이템을 내려받는다. 실행파일 탐지·인자 조립·stdout 파싱·결과 경로 후보는
// 순수 함수로 분리해 실호출 없이 단위 테스트한다(FFmpegConverter 패턴).
//
// 비밀번호는 앱이 저장·전달하지 않는다. steamcmd 는 최초 로그인 후 세션을 캐시하므로,
// 사용자에게 "터미널에서 `steamcmd +login <계정>` 으로 1회 로그인해 세션을 캐시하라"고 안내한다
// (ponytail: 최소·안전 UX). username 만 UserDefaults 에 저장한다.
enum SteamCmdDownloader {
    static let appid = "431960"  // Wallpaper Engine 고정
    static let explicitExecutableEnv = "WAPLE_STEAMCMD_PATH"
    static let fixedExecutablePaths = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]

    static let executableURL: URL? = detectExecutable()
    static var isAvailable: Bool { executableURL != nil }

    // MARK: - username(UserDefaults — 비밀 아님)

    static let usernameDefaultsKey = "waple.steam.username"
    static var username: String {
        get { UserDefaults.standard.string(forKey: usernameDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameDefaultsKey) }
    }

    // MARK: - 순수 로직(테스트 대상)

    /// 실행파일 경로: 명시 opt-in(env) → 고정 경로 → nil. PATH 는 신뢰하지 않는다(FFmpegConverter 와 동일 정책).
    static func detectExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        knownExecutablePaths: [String] = fixedExecutablePaths,
        isExecutable: (String) -> Bool = defaultExecutableCheck
    ) -> URL? {
        if let explicit = environment[explicitExecutableEnv],
           explicit.hasPrefix("/"), !explicit.contains("\0"), isExecutable(explicit) {
            return URL(fileURLWithPath: explicit)
        }
        if let known = knownExecutablePaths.first(where: isExecutable) {
            return URL(fileURLWithPath: known)
        }
        return nil
    }

    private static func defaultExecutableCheck(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// steamcmd 인자. 비밀번호 없음 — 세션 캐시 전제(사용자가 1회 로그인해 둠).
    static func arguments(username: String, itemId: String) -> [String] {
        ["+login", username, "+workshop_download_item", appid, itemId, "validate", "+quit"]
    }

    enum Progress: Equatable {
        case downloading(Double?)  // progress 값(0~100, Steam 이 퍼센트로 출력). 미검출 시 nil.
        case verifying
        case committing
        case success
        case failed
    }

    /// stdout 한 줄 → 진행 상태. 우선순위: 완료/실패 먼저, 그다음 상태 코드.
    /// 실측: Update state (0x61)=downloading, (0x5)=verifying, (0x101)=committing;
    /// "Success. Downloaded item"=완료, "ERROR!"=실패; 진행률 `progress: NN.NN`.
    static func parse(line: String) -> Progress? {
        if line.contains("Success. Downloaded item") { return .success }
        if line.contains("ERROR!") { return .failed }
        if line.contains("(0x61)") { return .downloading(progressValue(line)) }
        if line.contains("(0x5)") { return .verifying }
        if line.contains("(0x101)") { return .committing }
        return nil
    }

    /// `progress:\s*([\d.]+)` 첫 매치를 Double 로. 없으면 nil.
    static func progressValue(_ line: String) -> Double? {
        guard let range = line.range(of: #"progress:\s*([\d.]+)"#, options: .regularExpression) else { return nil }
        let matched = line[range].drop { !$0.isNumber && $0 != "." }
        return Double(matched)
    }

    /// 성공 라인의 목적지 경로 추출 — steamcmd 는 `Success. Downloaded item <id> to "<path>" :` 형태로
    /// 실제로 쓴 위치를 출력한다(실측). F499: 후보 스캔이 Steam 홈을 항상 우선해 양쪽 공존 시 이번
    /// 다운로드와 무관한 stale 콘텐츠를 임포트할 수 있어, 성공 라인이 알려준 경로를 우선한다.
    static func successPath(_ line: String) -> String? {
        guard line.contains("Success. Downloaded item"),
              let open = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let path = String(rest[..<close])
        return path.isEmpty ? nil : path
    }

    /// 결과 폴더 후보(실존 확인은 호출부). steamcmd 홈이 실행파일 위치와 무관할 수 있어 두 후보를 순서대로 낸다:
    /// 1) macOS 기본 Steam 데이터 홈(~/Library/Application Support/Steam)
    /// 2) steamcmd 실행파일 디렉터리(자체 디렉터리에 저장하는 배포)
    static func resultPathCandidates(itemId: String, executableURL: URL?, homeDirectory: URL) -> [URL] {
        let relative = "steamapps/workshop/content/\(appid)/\(itemId)"
        var bases: [URL] = [
            homeDirectory.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        ]
        if let exe = executableURL {
            bases.append(exe.deletingLastPathComponent())
        }
        return bases.map { $0.appendingPathComponent(relative, isDirectory: true) }
    }

    // MARK: - 실행(백그라운드 Process + 타임아웃). 진행/완료 콜백은 메인 큐.

    /// itemId 를 내려받아 결과 폴더 URL 을 completion 으로 돌려준다(실패/부재/미로그인 → nil).
    /// 완료는 반드시 stdout 의 "Success. Downloaded item" 라인 확인 후에만 결과 폴더를 스캔한다 —
    /// steamcmd 는 실패해도 exit 0 을 낼 수 있고 content/<id> 폴더가 이전 부분 다운로드로 미리 있을 수 있어,
    /// 존재만으로 임포트하면 stale 콘텐츠를 조용히 가져오게 된다.
    ///
    /// `progress`/`completion` 이 `@Sendable` 인 것은 표기가 아니라 **사실의 기술**이다 — 둘 다
    /// 이 함수가 만든 백그라운드 큐(`.utility`)를 거쳐 `DispatchQueue.main` 으로 다시 넘어가므로,
    /// 큐 경계를 최소 두 번 넘는다. 종전에는 그 사실이 타입에 없어 호출부가 무엇을 캡처해도
    /// 컴파일러가 아무 말도 하지 않았다.
    static func download(itemId: String, username: String, timeout: TimeInterval = 900,
                         progress: @escaping @Sendable (Progress) -> Void,
                         completion: @escaping @Sendable (URL?) -> Void) {
        // F840: itemId 는 원격(Steam Web API) 문자열이다. 셸도 문자열 보간도 없지만
        //  (1) steamcmd 는 `+` 로 시작하는 argv 를 **새 명령**으로 읽는다 — id 가 `+runscript` 면
        //      arguments() 가 만든 argv 에 명령이 하나 끼어든다.
        //  (2) 같은 문자열이 resultPathCandidates 의 `content/<appid>/<id>` 경로 조각으로도 들어가
        //      `../` 탈출이 된다.
        // 그래서 계에 들어오는 이 지점에서 숫자로 확정한다(LibraryStore 의 F580 과 같은 규율).
        guard WorkshopQuery.isValidPublishedFileID(itemId) else {
            WapleLog.warn("[Waple] refusing steamcmd download for non-numeric workshop id: \(itemId)")
            completeOnMain(completion, nil)
            return
        }
        guard let exe = executableURL else {
            WapleLog.warn("[Waple] steamcmd not found — 'brew install steamcmd' to download workshop items")
            completeOnMain(completion, nil)
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            WapleLog.warn("[Waple] steamcmd username not set — cannot download")
            completeOnMain(completion, nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = run(exe: exe, args: arguments(username: username, itemId: itemId),
                             timeout: timeout, progress: progress)
            guard result.sawSuccess else {
                WapleLog.warn("[Waple] steamcmd download did not report success for item \(itemId)")
                completeOnMain(completion, nil)
                return
            }
            // F499: 성공 라인이 경로를 알려주면 그 경로만 신뢰한다 — 다른 후보는 이번 실행이 쓴 곳이
            // 아니므로(양쪽 공존 시 stale) 폴백 스캔으로 돌아가지 않는다. 경로 미출력(구형 포맷)일 때만
            // 기존 후보 스캔을 쓴다.
            let found: URL?
            if let reported = result.path {
                let url = URL(fileURLWithPath: reported)
                found = isDirectory(url) ? url : nil
            } else {
                found = resultPathCandidates(
                    itemId: itemId, executableURL: exe,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ).first { isDirectory($0) }
            }
            if found == nil {
                WapleLog.warn("[Waple] steamcmd reported success but no content folder found for item \(itemId)")
            }
            completeOnMain(completion, found)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func completeOnMain(_ completion: @escaping @Sendable (URL?) -> Void, _ result: URL?) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Process 1회 실행. stdout 을 라인 단위로 파싱해 progress 를 메인 큐로 전달.
    /// 타임아웃 시 SIGTERM(terminate) → 유예(terminateGrace) 내 미종료 시 SIGKILL 로 에스컬레이션한다
    /// (감사 V06: steamcmd 가 SIGTERM 을 무시하면 availableData/waitUntilExit 가 영구 블록돼
    /// 다운로드 스레드 정지 + WorkshopViewModel .downloading 고착 — 어떤 경로든 반환을 보장).
    /// 반환값 = ("완료" 라인을 봤는가, 성공 라인이 알려준 목적지 경로 — F499. 경로 미출력 포맷이면 nil).
    /// `progress` 는 이 함수가 `DispatchQueue.main.async` 로 넘기므로 `@Sendable` 이다(download 와 동일 근거).
    static func run(exe: URL, args: [String], timeout: TimeInterval,
                    terminateGrace: TimeInterval = 5,
                    progress: @escaping @Sendable (Progress) -> Void) -> (sawSuccess: Bool, path: String?) {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            WapleLog.warn("[Waple] steamcmd launch failed: \(error)")
            return (false, nil)
        }
        // 감사 V06: SIGTERM 을 무시하는 프로세스 대비 — 유예 후 SIGKILL 에스컬레이션.
        // 프로세스 사망 시 파이프가 닫혀 위 읽기 루프(availableData)와 waitUntilExit 가 풀린다.
        let escalator = DispatchWorkItem {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        let killer = DispatchWorkItem {
            if proc.isRunning {
                proc.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + terminateGrace, execute: escalator)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        var sawSuccess = false
        var reportedPath: String?
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // EOF(또는 terminate 로 파이프 닫힘)
            buffer.append(chunk)
            // steamcmd 는 진행률을 \r 로 제자리 갱신하기도 해 \n·\r 둘 다 줄 끝으로 취급.
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8), let p = parse(line: line) else { continue }
                if p == .success { sawSuccess = true; reportedPath = successPath(line) ?? reportedPath }
                DispatchQueue.main.async { progress(p) }
            }
        }
        // 마지막 줄이 개행 없이 EOF 로 끝날 수 있다 — 남은 버퍼도 파싱(성공 신호를 놓치지 않게).
        if let line = String(data: buffer, encoding: .utf8), let p = parse(line: line) {
            if p == .success { sawSuccess = true; reportedPath = successPath(line) ?? reportedPath }
            DispatchQueue.main.async { progress(p) }
        }
        proc.waitUntilExit()
        killer.cancel()
        escalator.cancel()
        return (sawSuccess, reportedPath)
    }
}
