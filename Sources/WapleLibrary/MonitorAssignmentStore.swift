import Foundation

/// 손상된 스토어 JSON 을 덮어쓰기 전 1회 백업(rename). 복구 가능한 사용자 설정의 무음 파괴를 막는다.
/// Library/Playlist/Monitor 스토어가 공유한다.
func backupCorruptStoreFile(_ url: URL, _ corrupt: inout Bool) {
    guard corrupt else { return }
    corrupt = false
    // ms 해상도: 같은 초 내 재손상 시 백업 파일명 충돌 → moveItem 실패 → 원본 유실 방지.
    let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970 * 1000))")
    do {
        try FileManager.default.moveItem(at: url, to: backup)
        NSLog("%@", "[Waple] backed up corrupt \(url.lastPathComponent) to \(backup.path)")
    } catch {
        NSLog("%@", "[Waple] failed to back up corrupt \(url.lastPathComponent): \(error)")
    }
}

/// 스토어 파일 load 3분기 공통 규약: 파일없음=정상(최초 실행) / 읽기실패=corrupt / 성공=Data.
/// 디코드 실패(=corrupt) 분기는 타입이 제각각이라 호출자 몫. 읽기실패 시 corrupt 표시 —
/// 다음 save() 가 backupCorruptStoreFile 로 원본을 보존한 뒤 덮어쓴다.
func readStoreFile(_ url: URL, what: String, note: String, corrupt: inout Bool) -> Data? {
    do { return try Data(contentsOf: url) }
    catch CocoaError.fileReadNoSuchFile { return nil }  // 최초 실행: 파일 없음(정상)
    catch {
        NSLog("%@", "[Waple] \(what) unreadable — preserving, \(note): \(error)")
        corrupt = true
        return nil
    }
}

/// 모니터별 배경 할당(화면 키 → 라이브러리 엔트리 id). 미할당 화면은 전역 선택을 따른다.
/// 화면 키는 CGDirectDisplayID 문자열(앱 쪽에서 생성) — 디스플레이 재연결에도 안정적.
public final class MonitorAssignmentStore {
    private let fileURL: URL
    private var map: [String: String] = [:]
    /// 로드 시 손상(파일은 있으나 디코드 실패) 발견 → 다음 save() 가 덮어쓰기 전에 백업(데이터 손실 방지).
    private var corrupt = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("monitors.json")
        guard let data = readStoreFile(fileURL, what: "monitors.json", note: "starting empty", corrupt: &corrupt) else { return }
        do { map = try JSONDecoder().decode([String: String].self, from: data) }
        catch { NSLog("%@", "[Waple] monitors.json corrupt — preserving, starting empty: \(error)"); corrupt = true }
    }

    public func assignment(for screenKey: String) -> String? { map[screenKey] }

    public func setAssignment(_ entryId: String?, for screenKey: String) {
        map[screenKey] = entryId
        save()
    }

    /// 현재 할당 전체(설정 UI 표시용).
    public var all: [String: String] { map }

    /// 라이브러리 제거 연동: 이 엔트리를 가리키는 화면 할당 전부 해제(orphan 정리).
    public func removeAssignments(entryId: String) {
        let keys = map.filter { $0.value == entryId }.map(\.key)
        guard !keys.isEmpty else { return }
        for k in keys { map.removeValue(forKey: k) }
        save()
    }

    private func save() {
        backupCorruptStoreFile(fileURL, &corrupt)  // 손상 원본을 덮어쓰기 전 1회 백업
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "[Waple] monitor assignments save failed: \(error)")
        }
    }
}
