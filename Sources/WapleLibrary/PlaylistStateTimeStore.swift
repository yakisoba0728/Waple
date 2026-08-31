import Foundation
import WapleCore

/// 화면별 재생목록 경과시간의 영속. **WE 와 같은 바이트 포맷**(`bin/playliststatetime.bin`)을 쓴다.
///
/// 왜 JSON 이 아닌가
/// ----------------
/// 이 저장소의 다른 스토어는 전부 JSON 이다. 여기만 다른 이유는 하나다 — 이 파일은
/// **WE 설치본과 주고받을 후보**다(§7 의 실측 파일이 근거이고, 포맷은 `PlaylistStateTimeFile`
/// 에 바이트 단위로 잠겨 있다). 지금 JSON 으로 쓰면 나중에 가져오기를 붙일 때 매핑표를 새로
/// 만들어야 하고, 그 매핑표가 곧 두 번째 정본이 된다.
///
/// 이름은 WE 와 같지만 **자리는 우리 것**이다(`~/Library/Application Support/Waple/`).
/// WE 의 `bin/` 을 건드리지 않는다.
public final class PlaylistStateTimeStore {

    /// WE 와 같은 파일명. 경로는 우리 베이스 디렉터리다.
    public static let fileName = "playliststatetime.bin"

    private let fileURL: URL
    private var elapsed: [String: Float] = [:]
    /// 로드 시 손상(파일은 있으나 디코드 실패) → 다음 save() 가 덮어쓰기 전에 1회 백업.
    private var corrupt = false
    /// 로드 시 읽기 자체가 실패(권한·잠금 등 일시적) → 원본이 멀쩡할 수 있어 save() 를 건너뛴다.
    private var loadFailed = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent(Self.fileName)
        guard let data = readStoreFile(fileURL, what: Self.fileName,
                                       note: "starting from zero", loadFailed: &loadFailed) else { return }
        guard let contents = PlaylistStateTimeFile.decode(data) else {
            NSLog("%@", "[Waple] \(Self.fileName) unreadable — preserving, starting from zero")
            corrupt = true
            return
        }
        elapsed = contents.elapsedByName
    }

    /// 화면 키 → 경과시간(초).
    public var elapsedByScreen: [String: Float] { elapsed }

    /// 덮어쓴다. 유닉스 시각은 파일 머리에 그대로 실린다(WE 도 기록 시각을 쓴다).
    public func save(_ map: [String: Float], now: Date = Date()) {
        elapsed = map
        guard !loadFailed else {
            NSLog("%@", "[Waple] \(Self.fileName) save skipped — earlier read failed transiently, avoiding clobber")
            return
        }
        guard backupCorruptStoreFile(fileURL, &corrupt) else {
            NSLog("%@", "[Waple] \(Self.fileName) save skipped — corrupt original backup failed, avoiding clobber")
            return
        }
        // 두 라벨(`exactly:`/`clamping:`)로만 좁힌다 — 시스템 시계가 어디에 있든 트랩하지 않는다.
        let seconds = UInt32(clamping: Int64(exactly: now.timeIntervalSince1970.rounded()) ?? 0)
        do {
            try PlaylistStateTimeFile.encode(elapsedByName: map, timestamp: seconds)
                .write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "[Waple] \(Self.fileName) save failed: \(error)")
        }
    }
}
