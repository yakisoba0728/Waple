import Foundation

/// 배경 재생목록: 참여 엔트리 id 순환 + 간격(분). 영속(playlist.json).
public final class PlaylistStore {
    private struct Model: Codable {
        var enabled = false
        var intervalMinutes = 30
        var ids: [String] = []
        /// 무작위 순서(w5d-playback) — false(기본)는 기존 순차 순환과 동일(무회귀).
        var shuffle = false

        init() {}

        /// 합성 init(from:) 는 누락 키에서 throw 한다(= default 는 memberwise init 전용, decode 는 미적용) —
        /// 향후 필드 추가 시 구버전 JSON 전부가 corrupt 오판으로 초기화되는 걸 막기 위해 누락 키는
        /// 각 필드의 기본값으로 폴백한다. 기본값은 위 프로퍼티 선언과 동일하게 유지할 것.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            // **[2026-09-01 r4-28]** 세터(`intervalMinutes` 의 `max(1, newValue)`)와 **같은 하한**을
            // 디코드에도 건다. 종전에는 세터에만 있어서, 손으로 고친 playlist.json(또는 구버전이
            // 쓴 값)의 `0`·음수가 그대로 살아 스케줄러에 들어갔다 — 0 은 즉시 재발화, 음수는
            // 과거 시각이라 전환이 폭주한다. 부재 기본 30 은 그대로다.
            intervalMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30)
            ids = try c.decodeIfPresent([String].self, forKey: .ids) ?? []
            shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        }
    }

    private let fileURL: URL
    private var model = Model() { didSet { save() } }
    /// 로드 시 손상(파일은 있으나 디코드 실패) 발견 → 다음 save() 가 덮어쓰기 전에 백업(데이터 손실 방지).
    private var corrupt = false
    /// 로드 시 읽기 자체가 실패(권한·잠금 등 일시적) → 원본이 멀쩡할 수 있어 save() 를 건너뛴다.
    private var loadFailed = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("playlist.json")
        guard let data = readStoreFile(fileURL, what: "playlist.json", note: "starting default", loadFailed: &loadFailed) else { return }
        // init 내 직접 대입이라 didSet(save) 미발동 — 로드가 파일을 되쓰지 않는다.
        do { model = try JSONDecoder().decode(Model.self, from: data) }
        catch { NSLog("%@", "[Waple] playlist.json corrupt — preserving, starting default: \(error)"); corrupt = true }
    }

    public var enabled: Bool {
        get { model.enabled }
        set { model.enabled = newValue }
    }

    public var intervalMinutes: Int {
        get { model.intervalMinutes }
        set { model.intervalMinutes = max(1, newValue) }
    }

    public var ids: [String] {
        get { model.ids }
        set { model.ids = newValue }
    }

    /// 무작위 순서(w5d-playback) — true 면 PlaylistScheduling.shuffleNext 가 순환 대신 무작위 선곡.
    public var shuffle: Bool {
        get { model.shuffle }
        set { model.shuffle = newValue }
    }

    /// 순환: current 다음 항목. current 가 목록에 없거나 nil → 첫 항목. 빈 목록 → nil.
    public func next(after current: String?) -> String? {
        guard !model.ids.isEmpty else { return nil }
        guard let cur = current, let i = model.ids.firstIndex(of: cur) else { return model.ids.first }
        return model.ids[(i + 1) % model.ids.count]
    }

    /// 참여 토글(있으면 제거, 없으면 끝에 추가).
    public func toggle(_ id: String) {
        if let i = model.ids.firstIndex(of: id) {
            model.ids.remove(at: i)
        } else {
            model.ids.append(id)
        }
    }

    /// 라이브러리 제거 연동: 해당 id 전부 제거(orphan 정리).
    public func remove(_ id: String) {
        guard model.ids.contains(id) else { return }
        model.ids.removeAll { $0 == id }
    }

    private func save() {
        guard !loadFailed else {
            NSLog("%@", "[Waple] playlist.json save skipped — earlier read failed transiently, avoiding clobber")
            return
        }
        guard backupCorruptStoreFile(fileURL, &corrupt) else {
            NSLog("%@", "[Waple] playlist save skipped — corrupt original backup failed, avoiding clobber")
            return
        }
        do {
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "[Waple] playlist save failed: \(error)")
        }
    }
}
