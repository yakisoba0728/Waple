import Foundation
import WapleCore

/// Saved playback settings; runtime clocks and cursors remain owned by PlaylistDriver.
public struct PlaylistConfiguration: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var delayMinutes: Double
    public var mode: PlaylistMode
    public var ids: [String]
    public var shuffle: Bool
    public var videoSequence: Bool
    public var updateOnPause: Bool
    public var beginFirst: Bool
    public var playIntro: Bool
    public var daytimeEnds: [String: Float]
    public var transitionConfigValue: Int
    public var transitionTimeMillis: Int
    public var transitionPool: [Int]

    public init(id: String = "default", name: String = "Default", enabled: Bool = false,
                delayMinutes: Double = 30, mode: PlaylistMode = .timer, ids: [String] = [],
                shuffle: Bool = false, videoSequence: Bool = false, updateOnPause: Bool = false,
                beginFirst: Bool = false, playIntro: Bool = false, daytimeEnds: [String: Float] = [:],
                transitionConfigValue: Int = -1, transitionTimeMillis: Int = 1500,
                transitionPool: [Int] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.delayMinutes = delayMinutes
        self.mode = mode
        self.ids = ids
        self.shuffle = shuffle
        self.videoSequence = videoSequence
        self.updateOnPause = updateOnPause
        self.beginFirst = beginFirst
        self.playIntro = playIntro
        self.daytimeEnds = daytimeEnds
        self.transitionConfigValue = transitionConfigValue
        self.transitionTimeMillis = transitionTimeMillis
        self.transitionPool = transitionPool
        self = normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, delayMinutes, mode, ids, shuffle, videoSequence, updateOnPause
        case beginFirst, playIntro, daytimeEnds, transitionConfigValue, transitionTimeMillis, transitionPool
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id) ?? "default",
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Default",
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  delayMinutes: try c.decodeIfPresent(Double.self, forKey: .delayMinutes) ?? 30,
                  mode: PlaylistMode(rawValue: try c.decodeIfPresent(Int.self, forKey: .mode) ?? 1) ?? .timer,
                  ids: try c.decodeIfPresent([String].self, forKey: .ids) ?? [],
                  shuffle: try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false,
                  videoSequence: try c.decodeIfPresent(Bool.self, forKey: .videoSequence) ?? false,
                  updateOnPause: try c.decodeIfPresent(Bool.self, forKey: .updateOnPause) ?? false,
                  beginFirst: try c.decodeIfPresent(Bool.self, forKey: .beginFirst) ?? false,
                  playIntro: try c.decodeIfPresent(Bool.self, forKey: .playIntro) ?? false,
                  daytimeEnds: try c.decodeIfPresent([String: Float].self, forKey: .daytimeEnds) ?? [:],
                  transitionConfigValue: try c.decodeIfPresent(Int.self, forKey: .transitionConfigValue) ?? -1,
                  transitionTimeMillis: try c.decodeIfPresent(Int.self, forKey: .transitionTimeMillis) ?? 1500,
                  transitionPool: try c.decodeIfPresent([Int].self, forKey: .transitionPool) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(delayMinutes, forKey: .delayMinutes)
        try c.encode(mode.rawValue, forKey: .mode)
        try c.encode(ids, forKey: .ids)
        try c.encode(shuffle, forKey: .shuffle)
        try c.encode(videoSequence, forKey: .videoSequence)
        try c.encode(updateOnPause, forKey: .updateOnPause)
        try c.encode(beginFirst, forKey: .beginFirst)
        try c.encode(playIntro, forKey: .playIntro)
        try c.encode(daytimeEnds, forKey: .daytimeEnds)
        try c.encode(transitionConfigValue, forKey: .transitionConfigValue)
        try c.encode(transitionTimeMillis, forKey: .transitionTimeMillis)
        try c.encode(transitionPool, forKey: .transitionPool)
    }

    fileprivate func normalized() -> Self {
        var result = self
        result.delayMinutes = delayMinutes.isFinite ? min(525600, max(0.01, delayMinutes)) : 30
        result.transitionTimeMillis = max(0, transitionTimeMillis)
        let membership = Set(ids)
        result.daytimeEnds = daytimeEnds.reduce(into: [:]) { output, item in
            guard membership.contains(item.key), item.value.isFinite else { return }
            output[item.key] = min(1, max(0, item.value))
        }
        return result
    }
}

/// 배경 재생목록: 참여 엔트리 id 순환 + 간격(분). 영속(playlist.json).
public final class PlaylistStore {
    private struct Model: Codable, Equatable {
        var configurations = [PlaylistConfiguration()]
        var selectedPlaylistId = "default"
        var assignments: [String: String] = [:]
        var currentByScreen: [String: String] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case configurations, selectedPlaylistId, assignments, currentByScreen
            case enabled, intervalMinutes, ids, shuffle
        }

        /// Missing new keys migrate the legacy Bool/int/list schema, never corrupt it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let saved = try c.decodeIfPresent([PlaylistConfiguration].self, forKey: .configurations), !saved.isEmpty {
                configurations = saved
            } else {
                // [2026-09-01 r4-28] Legacy decode retains the setter's >=1 minute guard.
                let minutes = max(1, try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30)
                configurations = [PlaylistConfiguration(
                    enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                    delayMinutes: Double(minutes),
                    ids: try c.decodeIfPresent([String].self, forKey: .ids) ?? [],
                    shuffle: try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false)]
            }
            // Preserve duplicate-id records under distinct identities instead of dropping user data.
            var seen = Set<String>()
            for index in configurations.indices {
                let base = configurations[index].id.isEmpty ? "default" : configurations[index].id
                var identifier = base
                var suffix = 2
                while seen.contains(identifier) { identifier = "\(base)-\(suffix)"; suffix += 1 }
                configurations[index].id = identifier
                seen.insert(identifier)
            }
            let selected = try c.decodeIfPresent(String.self, forKey: .selectedPlaylistId)
            selectedPlaylistId = selected.flatMap { seen.contains($0) ? $0 : nil } ?? configurations[0].id
            assignments = (try c.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:])
                .filter { seen.contains($0.value) }
            currentByScreen = try c.decodeIfPresent([String: String].self, forKey: .currentByScreen) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(configurations, forKey: .configurations)
            try c.encode(selectedPlaylistId, forKey: .selectedPlaylistId)
            try c.encode(assignments, forKey: .assignments)
            try c.encode(currentByScreen, forKey: .currentByScreen)
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

    public var savedPlaylists: [PlaylistConfiguration] { model.configurations }
    public var selectedPlaylistId: String { model.selectedPlaylistId }

    public var configuration: PlaylistConfiguration {
        get { model.configurations.first { $0.id == model.selectedPlaylistId } ?? model.configurations[0] }
        set {
            guard let index = model.configurations.firstIndex(where: { $0.id == model.selectedPlaylistId }) else { return }
            var value = newValue.normalized()
            value.id = model.selectedPlaylistId
            model.configurations[index] = value
        }
    }

    public func configuration(for screenKey: String? = nil) -> PlaylistConfiguration {
        guard let screenKey, let assigned = model.assignments[screenKey],
              let configuration = model.configurations.first(where: { $0.id == assigned }) else { return self.configuration }
        return configuration
    }

    public var currentByScreen: [String: String] {
        get { model.currentByScreen }
        set { if model.currentByScreen != newValue { model.currentByScreen = newValue } }
    }

    public var enabled: Bool {
        get { configuration.enabled }
        set { var value = configuration; value.enabled = newValue; configuration = value }
    }

    /// Legacy UI keeps integral minutes, while the richer configuration stores fractional minutes.
    public var intervalMinutes: Int {
        get { max(1, safeInt(configuration.delayMinutes) ?? 30) }
        set { var value = configuration; value.delayMinutes = Double(max(1, newValue)); configuration = value }
    }

    public var ids: [String] {
        get { configuration.ids }
        set { var value = configuration; value.ids = newValue; configuration = value }
    }

    /// 무작위 순서(w5d-playback) — true 면 PlaylistScheduling.shuffleNext 가 순환 대신 무작위 선곡.
    public var shuffle: Bool {
        get { configuration.shuffle }
        set { var value = configuration; value.shuffle = newValue; configuration = value }
    }

    @discardableResult
    public func createPlaylist(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return selectedPlaylistId }
        let value = PlaylistConfiguration(id: UUID().uuidString, name: name)
        var next = model
        next.configurations.append(value)
        next.selectedPlaylistId = value.id
        model = next
        return value.id
    }

    @discardableResult
    public func selectPlaylist(id: String) -> Bool {
        guard model.configurations.contains(where: { $0.id == id }) else { return false }
        if model.selectedPlaylistId != id { model.selectedPlaylistId = id }
        return true
    }

    public func renamePlaylist(id: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = model.configurations.firstIndex(where: { $0.id == id }) else { return }
        model.configurations[index].name = name
    }

    public func removePlaylist(id: String) {
        guard model.configurations.count > 1, model.configurations.contains(where: { $0.id == id }) else { return }
        var next = model
        next.configurations.removeAll { $0.id == id }
        next.assignments = next.assignments.filter { $0.value != id }
        if next.selectedPlaylistId == id { next.selectedPlaylistId = next.configurations[0].id }
        model = next
    }

    public func assignPlaylist(_ id: String?, toScreen screenKey: String) {
        guard !screenKey.isEmpty else { return }
        if let id, !model.configurations.contains(where: { $0.id == id }) { return }
        if model.assignments[screenKey] != id { model.assignments[screenKey] = id }
    }

    public func assignedPlaylistId(forScreen screenKey: String) -> String? { model.assignments[screenKey] }

    /// 순환: current 다음 항목. current 가 목록에 없거나 nil → 첫 항목. 빈 목록 → nil.
    public func next(after current: String?) -> String? {
        let ids = configuration.ids
        guard !ids.isEmpty else { return nil }
        guard let cur = current, let i = ids.firstIndex(of: cur) else { return ids.first }
        return ids[(i + 1) % ids.count]
    }

    /// 참여 토글(있으면 제거, 없으면 끝에 추가).
    public func toggle(_ id: String) {
        var value = configuration
        if let index = value.ids.firstIndex(of: id) { value.ids.remove(at: index) }
        else { value.ids.append(id) }
        configuration = value
    }

    /// 라이브러리 제거 연동: 모든 저장된 목록·시간대·화면 선택의 orphan 정리.
    public func remove(_ id: String) {
        var next = model
        for index in next.configurations.indices {
            next.configurations[index].ids.removeAll { $0 == id }
            next.configurations[index].daytimeEnds.removeValue(forKey: id)
        }
        next.currentByScreen = next.currentByScreen.filter { $0.value != id }
        if next != model { model = next }
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
