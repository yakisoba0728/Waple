import Foundation

/// 배경 재생목록: 참여 엔트리 id 순환 + 간격(분). 영속(playlist.json).
public final class PlaylistStore {
    private struct Model: Codable {
        var enabled = false
        var intervalMinutes = 30
        var ids: [String] = []
    }

    private let fileURL: URL
    private var model = Model() { didSet { save() } }

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("playlist.json")
        if let data = try? Data(contentsOf: fileURL),
           let m = try? JSONDecoder().decode(Model.self, from: data) {
            model = m
        }
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

    private func save() {
        do {
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("%@", "[Waple] playlist save failed: \(error)")
        }
    }
}
