import Foundation

/// zip 배경 가져오기(작업 4)의 해제(주입 가능)·배경 루트 탐색(순수).
/// import 오케스트레이션(관리 위치 이동 + 북마크)은 `LibraryStore.importZip`.
public enum ZipImporter {
    /// 디렉터리 트리에서 project.json 을 담은 배경 루트들을 찾는다. 루트 발견 시 그 아래로는
    /// 내려가지 않는다(배경 폴더 내부 하위 자산 폴더를 별개 배경으로 오인하지 않도록).
    /// zip 이 wrapper/Wallpaper/project.json 처럼 감싸여 있어도 재귀로 찾아낸다
    /// (importParent 는 1단계만 훑어 이런 중첩을 놓친다 — 그래서 별도 탐색이 필요).
    public static func findProjectRoots(in root: URL, fileManager: FileManager = .default) -> [URL] {
        var roots: [URL] = []
        func walk(_ dir: URL) {
            if fileManager.fileExists(atPath: dir.appendingPathComponent("project.json").path) {
                roots.append(dir)
                return  // 배경 루트 발견 → 하위 탐색 중단
            }
            let subs = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
            for sub in subs {
                // 심링크 미추종(fileExists 는 링크를 따라간다) — 악성 zip 의 절대링크(evil→/)로
                // 전체 디스크를 걷거나, 외부 경로의 project.json 을 배경 루트로 오인해
                // importZip 이 외부 원본 폴더를 imported/ 로 이동(파괴)하는 것 방지.
                let rv = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rv?.isSymbolicLink != true, rv?.isDirectory == true else { continue }
                walk(sub)
            }
        }
        walk(root)
        return roots
    }

    /// ditto 해제 실패 원인(감사 V06 — 해제 프로세스 타임아웃 / r2-H19 — 디스크 고갈).
    public enum ZipImportError: Error, Equatable {
        /// 해제가 상한(extractionTimeout)을 넘겨 강제 종료(SIGTERM→SIGKILL)됨.
        case extractionTimedOut
        /// 해제 중 목적지 볼륨 여유공간이 `minimumFreeBytes` 아래로 떨어져 중단됨(압축폭탄 방어).
        case insufficientDiskSpace
    }

    /// ditto 해제 시간 상한(감사 V06). 거대 zip 도 수 분이면 충분하고, 행 걸린 프로세스가
    /// 직렬 importQueue 를 이 시간 이상 점유하지 못하게 하는 안전장치다.
    static let extractionTimeout: TimeInterval = 300

    /// **[r2-H19] 시간 상한은 용량 방어를 대신하지 못한다.** 압축률이 높은 zip(압축폭탄)은
    /// `extractionTimeout` 300초 **안에** 디스크를 가득 채운다 — ditto 는 순차 쓰기라 초당
    /// 수백 MB 를 낸다. 그래서 해제 **도중** 목적지 볼륨의 여유공간을 폴링해 하한 아래로
    /// 떨어지면 프로세스를 회수하고 `insufficientDiskSpace` 를 던진다.
    ///
    /// 하한 512 MiB 는 "정상 배경 하나를 마저 풀 여유" 가 아니라 **시스템이 숨 쉴 여유**다 —
    /// 정상 import 는 여기까지 내려가지 않고, 이미 512 MiB 밖에 없는 디스크에서는 어차피
    /// 큰 배경을 받을 수 없다. 값을 키우면 여유 적은 디스크의 정상 import 를 막게 된다.
    static let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    /// 여유공간 폴링 간격. 해제 프로세스를 기다리는 슬라이스 길이이기도 하다.
    /// **`abortIf` 를 주지 않으면 폴링을 아예 하지 않는다**(종전 단일 `wait` 경로 그대로).
    static let extractionPollInterval: TimeInterval = 0.5

    /// **이 방어가 덮지 않는 것**: 엔트리 수 상한·압축률 상한·경로 순회(`../`)다.
    /// 앞의 둘은 zip 중앙 디렉터리를 직접 읽어야 하고(현재는 해제를 `/usr/bin/ditto` 에 위임한다),
    /// 마지막은 `ditto -x -k` 가 자체적으로 목적지 밖 쓰기를 막는다.
    /// 여유공간 하한은 그 셋과 무관하게 **결과(디스크 고갈)** 를 막는 자리라 먼저 둔다.
    static func freeCapacityGuard(_ destination: URL) -> ZipImportError? {
        guard let values = try? destination.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil   // 볼륨 속성을 못 읽으면 방어를 걸지 않는다(fail-open — 무회귀 우선)
        }
        return available < minimumFreeBytes ? .insufficientDiskSpace : nil
    }

    /// `/usr/bin/ditto -x -k <zip> <dest>`. 종료코드 0 = 성공.
    /// 감사 V06: waitUntilExit 무한 대기 금지 — extractionTimeout 초과 시 SIGTERM → 미종료 시
    /// SIGKILL 로 회수하고 ZipImportError.extractionTimedOut 을 던진다(행 걸린 ditto 가
    /// 직렬 importQueue 를 영구 정지시키는 회귀 방지). 기본 구현 — 테스트는 대체 클로저를 주입한다.
    public static func dittoExtract(_ zipURL: URL, _ dest: URL) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zipURL.path, dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        // r2-H19: 시간 상한 + **여유공간 하한**. 후자가 없으면 압축폭탄이 300초 안에 디스크를 채운다.
        try waitForExitOrKill(p, timeout: extractionTimeout,
                              abortIf: { freeCapacityGuard(dest) })
        return p.terminationStatus == 0
    }

    /// 프로세스 종료를 timeout 까지만 기다린다. 초과 시 SIGTERM, terminateGrace 내 미종료 시
    /// SIGKILL 로 회수하고 extractionTimedOut 을 던진다(테스트는 단축 상한을 주입).
    ///
    /// `abortIf` 는 **주어졌을 때만** `extractionPollInterval` 마다 호출된다. 에러를 돌려주면
    /// 같은 회수 절차(SIGTERM → SIGKILL)를 밟고 그 에러를 던진다. nil 을 주면(기본) 종전과
    /// 똑같이 `timeout` 한 번을 통째로 기다린다 — 기존 호출부·테스트와 무회귀다.
    static func waitForExitOrKill(_ p: Process, timeout: TimeInterval, terminateGrace: TimeInterval = 5,
                                  abortIf: (() -> ZipImportError?)? = nil) throws {
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        // **[r4-27] 레이스를 닫는다.** `terminationHandler` 는 `run()` **뒤에** 설치되므로 그 사이에
        // 프로세스가 이미 끝났으면 핸들러가 영영 불리지 않고, 그러면 이미 죽은 프로세스를 상대로
        // timeout(기본 300초)을 꼬박 기다린 뒤 타임아웃을 **오탐**한다. 설치 직후 실행 여부를
        // 다시 보고 이미 끝났으면 직접 신호한다(둘 다 발화해 세마포어가 2 가 돼도 무해 —
        // 대기는 한 번뿐이고 값이 초기치 아래로 내려가지 않는다).
        if !p.isRunning { exited.signal() }

        let deadline = Date().addingTimeInterval(timeout)
        var abortReason: ZipImportError? = nil
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            // abortIf 가 없으면 슬라이스를 쪼개지 않는다 — 종전 단일 wait 과 동일.
            let slice = abortIf == nil ? remaining : min(extractionPollInterval, remaining)
            if exited.wait(timeout: .now() + slice) != .timedOut {
                p.terminationHandler = nil
                return
            }
            if let reason = abortIf?() { abortReason = reason; break }
        }
        p.terminate()   // SIGTERM
        if exited.wait(timeout: .now() + terminateGrace) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()   // SIGKILL 수거 확정
        }
        if let abortReason {
            NSLog("%@", "[Waple] zip extraction aborted (\(abortReason)) — killed extraction process")
            throw abortReason
        }
        NSLog("%@", "[Waple] zip extraction timed out after \(Int(timeout))s — killed hung process")
        throw ZipImportError.extractionTimedOut
    }
}
