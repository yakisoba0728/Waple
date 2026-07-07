import Foundation

public enum WallpaperPathSecurity {
    public static func normalizedRelativePath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.contains("\0") else { return nil }

        let decoded = fullyPercentDecoded(raw)
        guard !decoded.contains("\0"),
              !decoded.hasPrefix("/"),
              !decoded.hasPrefix("\\"),
              !looksLikeURLScheme(decoded) else { return nil }

        let path = decoded.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    public static func normalizedPathComponent(_ raw: String?) -> String? {
        guard let path = normalizedRelativePath(raw),
              !path.contains("/") else { return nil }
        return path
    }

    public static func containedFileURL(_ relativePath: String?, root: URL) -> URL? {
        guard let path = normalizedRelativePath(relativePath) else { return nil }
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard contains(candidate, in: rootURL) else { return nil }

        if FileManager.default.fileExists(atPath: candidate.path) {
            let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let realCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard contains(realCandidate, in: realRoot) else { return nil }
        }
        return candidate
    }

    public static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func fullyPercentDecoded(_ raw: String) -> String {
        var current = raw
        for _ in 0..<4 {
            guard let next = current.removingPercentEncoding, next != current else { break }
            current = next
        }
        return current
    }

    private static func looksLikeURLScheme(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        let firstSeparator = path.firstIndex { $0 == "/" || $0 == "\\" }
        guard firstSeparator == nil || colon < firstSeparator! else { return false }
        let scheme = path[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
