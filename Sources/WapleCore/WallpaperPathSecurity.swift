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

    /// 루트 안으로 봉쇄된 파일 URL. 어휘적 봉쇄(`..`·절대경로·스킴 거부)는
    /// `normalizedRelativePath` 가, **심링크 탈출**은 여기서 막는다.
    ///
    /// [2026-08-21] 심링크 대조를 **존재하는 가장 깊은 조상**까지 내리도록 고쳤다.
    ///
    /// 종전에는 `FileManager.fileExists(atPath: candidate.path)` 가 참일 때만 realpath 를 떠서
    /// 대조했다. `fileExists` 는 심링크를 따라가므로 "루트 안의 심링크 → 바깥 디렉터리" 자체는
    /// 잡혔지만(`link` · `link/secret.txt` → nil), **그 심링크 아래의 아직 없는 이름**은
    /// 검사가 통째로 생략됐다. 실측(2026-08-21, 리눅스 단독 프로브):
    ///
    /// ```
    /// root/link -> /outside          (디렉터리 심링크)
    /// containedFileURL("link/secret.txt")  -> nil          (막힘)
    /// containedFileURL("link")             -> nil          (막힘)
    /// containedFileURL("link/missing.txt") -> root/link/missing.txt   ← 루트 밖으로 해석된다
    /// ```
    ///
    /// 지금은 읽기 전용 소비자뿐이라 그 URL 로 실제 유출이 나지는 않았지만(열면 ENOENT),
    /// **경계 함수가 "밖을 가리키는 경로" 를 돌려주면 안 된다** — 나중에 생성/쓰기 소비자가
    /// 하나만 붙어도 곧바로 탈출이 된다. 그래서 후보가 없으면 조상을 한 단계씩 올려
    /// **존재하는 첫 경로**의 realpath 를 루트의 realpath 와 대조한다.
    ///
    /// 무회귀 논증: 심링크가 없는 정상 트리에서는 조상 탐색이 루트(또는 실재하는 중간
    /// 디렉터리)에서 멈추고 그 realpath 는 realRoot 아래이므로 판정이 종전과 같다. 새로
    /// 거부되는 것은 조상 중 하나가 루트 밖을 가리키는 심링크인 경우뿐이다.
    ///
    /// 한계(정직하게): 검사와 실제 `open()` 사이의 TOCTOU 는 남는다. 여기서 막는 것은
    /// "패키지에 심링크를 심어 두는" 정적 공격이지 능동 레이스가 아니다.
    public static func containedFileURL(_ relativePath: String?, root: URL) -> URL? {
        guard let path = normalizedRelativePath(relativePath) else { return nil }
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard contains(candidate, in: rootURL) else { return nil }

        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default
        // 존재하는 가장 깊은 조상까지 내려간다(후보 자체가 존재하면 그게 곧 probe).
        var probe = candidate
        while probe.path != rootURL.path, !fileManager.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            if parent.path == probe.path { break }   // 루트("/")까지 올라가면 더 못 간다
            probe = parent
        }
        let realProbe = probe.resolvingSymlinksInPath().standardizedFileURL
        guard contains(realProbe, in: realRoot) else { return nil }
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
