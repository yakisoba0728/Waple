import Foundation

/// Only a target explicitly selected by the user can become a script-openable binding.
public struct UserShortcutBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case application, web }
    public let targetURL: URL
    public let kind: Kind

    public init(targetURL: URL) throws {
        switch targetURL.scheme?.lowercased() {
        case "http", "https":
            guard let host = targetURL.host, !host.isEmpty,
                  targetURL.user == nil, targetURL.password == nil else { throw UserShortcutStore.BindingError.invalidTarget }
            self.targetURL = targetURL
            kind = .web
        case "file":
            guard targetURL.query == nil, targetURL.fragment == nil else { throw UserShortcutStore.BindingError.invalidTarget }
            let resolved = targetURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.pathExtension.lowercased() == "app",
                  (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  Bundle(url: resolved)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
            else { throw UserShortcutStore.BindingError.invalidTarget }
            self.targetURL = resolved
            kind = .application
        default:
            throw UserShortcutStore.BindingError.invalidTarget
        }
    }
}

/// Separate user bindings; imported project command/file fields are never trusted or auto-bound.
public final class UserShortcutStore {
    public enum BindingError: Error { case invalidTarget, invalidIdentity, persistenceUnavailable }
    private let fileURL: URL
    private var records: [String: [String: UserShortcutBinding]] = [:]
    private var corrupt = false
    private var loadFailed = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("user-shortcuts.json")
        guard let data = readStoreFile(fileURL, what: "user-shortcuts.json", note: "starting unbound", loadFailed: &loadFailed) else { return }
        do { records = try JSONDecoder().decode([String: [String: UserShortcutBinding]].self, from: data) }
        catch { NSLog("%@", "[Waple] user-shortcuts.json corrupt — preserving, starting unbound: \(error)"); corrupt = true }
    }

    /// Revalidate each lookup: removing/replacing an app must not leave a stale launch target.
    public func bindings(for entryID: String) -> [String: UserShortcutBinding] {
        (records[entryID] ?? [:]).reduce(into: [:]) { output, item in
            guard let validated = try? UserShortcutBinding(targetURL: item.value.targetURL) else { return }
            output[item.key] = validated
        }
    }

    public func set(_ targetURL: URL?, propertyKey: String, entryID: String) throws {
        guard !entryID.isEmpty, !propertyKey.isEmpty else { throw BindingError.invalidIdentity }
        var next = records
        if let targetURL {
            next[entryID, default: [:]][propertyKey] = try UserShortcutBinding(targetURL: targetURL)
        } else {
            next[entryID]?.removeValue(forKey: propertyKey)
            if next[entryID]?.isEmpty == true { next.removeValue(forKey: entryID) }
        }
        guard next != records else { return }
        try persist(next)
        records = next
    }

    public func remove(entryID: String) throws {
        guard records[entryID] != nil else { return }
        var next = records
        next.removeValue(forKey: entryID)
        try persist(next)
        records = next
    }

    private func persist(_ records: [String: [String: UserShortcutBinding]]) throws {
        guard !loadFailed, backupCorruptStoreFile(fileURL, &corrupt) else { throw BindingError.persistenceUnavailable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
