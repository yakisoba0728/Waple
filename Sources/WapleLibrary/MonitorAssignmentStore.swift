import Foundation

/// 모니터별 배경 할당(화면 키 → 라이브러리 엔트리 id). 미할당 화면은 전역 선택을 따른다.
/// 화면 키는 CGDirectDisplayID 문자열(앱 쪽에서 생성) — 디스플레이 재연결에도 안정적.
public final class MonitorAssignmentStore {
    private let fileURL: URL
    private var map: [String: String] = [:]

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("monitors.json")
        if let data = try? Data(contentsOf: fileURL),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            map = m
        }
    }

    public func assignment(for screenKey: String) -> String? { map[screenKey] }

    public func setAssignment(_ entryId: String?, for screenKey: String) {
        map[screenKey] = entryId
        save()
    }

    /// 현재 할당 전체(설정 UI 표시용).
    public var all: [String: String] { map }

    private func save() {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "[Waple] monitor assignments save failed: \(error)")
        }
    }
}
