import Foundation

// F232: `info` 케이스가 있었으나 analyzer 전체에서 이 값으로 이슈를 생성하는 곳이 한 군데도 없어(죽은
// 코드) 제거 — 실제 사용은 .warning/.error 뿐. sortRank 확장도 함께 정리.
public enum WallpaperCompatibilitySeverity: String, Codable, Equatable {
    case warning
    case error
}

// F235: 22종 중 8종이 한 번도 생성되지 않는 죽은 코드였다. 재조사 결과:
// - presetOverridesNotApplied/fractionalPropertyOrder/localizedProperties/directoryFetchAll 4종은
//   애초에 "위험해 보이지만 실제로 지원됨"으로 판명난 시나리오의 예약 코드였다(테스트 픽스처가 정확히
//   이 트리거 조건들 — 프리셋 오버라이드·소수 order·localization 블록·directory fetchall — 을 재현해
//   "이슈 없음"을 단언하는 음성 회귀 가드로 이미 존재: WallpaperProperties.localizationTable 이 실제로
//   지역화를 지원하고, WebRenderer:326 이 fetchall 모드를 실제로 처리하며, order 는 단순 Double 정렬키라
//   소수여도 문제없다 — 리터럴로 확정된 갭이 아니므로 제거). 실제 재조사 근거 없이 남겨두면 향후 세션이
//   "구현 예정 기능"으로 오인할 위험이 있어 퇴출한다.
// - webServiceWorker/webAudioListener/webMediaIntegration/remoteNetworkReference 4종은 반대로 이미
//   analyzeWebFeatures 가 실제로 탐지(features.insert)까지 하고서도 issue 로 승격하지 않던 것 — 아래
//   analyzeWebFeatures 에서 .warning 으로 배선한다(호환 위험 신호는 있으나 렌더 실패로 확정되지는
//   않으므로 .error 아닌 .warning).
public enum WallpaperCompatibilityIssueCode: String, Codable, Equatable, CaseIterable {
    case invalidProjectJSON
    case unsupportedApplicationType
    case unknownProjectType
    case unsafeWallpaperFilePath
    case missingWallpaperFile
    case unicodeNormalizedFileMatch
    case unsafePreviewPath
    case missingPreviewFile
    case missingScenePackage
    case missingPresetDependency
    case unsupportedPropertyType
    case propertyDisplayCondition
    case nonNativeVideoContainer
    case webServiceWorker
    case webRandomFileBridge
    case webAudioListener
    case webMediaIntegration
    case remoteNetworkReference
}

public struct WallpaperCompatibilityIssue: Codable, Equatable {
    public let severity: WallpaperCompatibilitySeverity
    public let code: WallpaperCompatibilityIssueCode
    public let message: String
    public let projectID: String
    public let relativePath: String?
    public let propertyKey: String?

    public init(severity: WallpaperCompatibilitySeverity,
                code: WallpaperCompatibilityIssueCode,
                message: String,
                projectID: String,
                relativePath: String? = nil,
                propertyKey: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.projectID = projectID
        self.relativePath = relativePath
        self.propertyKey = propertyKey
    }
}

public struct WallpaperCompatibilityProjectReport: Codable, Equatable {
    public let id: String
    public let title: String
    public let type: String
    public let folderPath: String
    public let fileName: String?
    public let previewName: String?
    public let dependency: String?
    public let propertyTypes: [String: Int]
    public let detectedFeatures: [String]
    public let issues: [WallpaperCompatibilityIssue]

    public var isBlocked: Bool {
        issues.contains { $0.severity == .error }
    }
}

public struct WallpaperCompatibilitySummary: Codable, Equatable {
    public let totalProjects: Int
    public let typeCounts: [String: Int]
    public let renderableProjects: Int
    public let blockedProjects: Int
    public let issueCounts: [String: Int]
    public let severityCounts: [String: Int]
}

public struct WallpaperCompatibilityReport: Codable, Equatable {
    public let scannedRootPath: String
    public let projectContainerPath: String
    public let projects: [WallpaperCompatibilityProjectReport]
    public let summary: WallpaperCompatibilitySummary

    public func markdown() -> String {
        var lines: [String] = []
        lines.append("# Wallpaper Compatibility Report")
        lines.append("")
        lines.append("- scanned root: `\(scannedRootPath)`")
        lines.append("- project container: `\(projectContainerPath)`")
        lines.append("- projects: \(summary.totalProjects)")
        lines.append("- renderable without blocking issues: \(summary.renderableProjects)")
        lines.append("- blocked: \(summary.blockedProjects)")
        lines.append("")
        lines.append("## Types")
        for key in summary.typeCounts.keys.sorted() {
            lines.append("- \(key): \(summary.typeCounts[key] ?? 0)")
        }
        lines.append("")
        lines.append("## Issues")
        if summary.issueCounts.isEmpty {
            lines.append("- none")
        } else {
            for key in summary.issueCounts.keys.sorted() {
                lines.append("- \(key): \(summary.issueCounts[key] ?? 0)")
            }
        }
        lines.append("")
        lines.append("## Projects With Issues")
        let projectsWithIssues = projects.filter { !$0.issues.isEmpty }
        if projectsWithIssues.isEmpty {
            lines.append("- none")
        } else {
            for project in projectsWithIssues {
                lines.append("- \(project.id) [\(project.type)] \(project.title)")
                for issue in project.issues {
                    let property = issue.propertyKey.map { " property=\($0)" } ?? ""
                    let path = issue.relativePath.map { " path=\($0)" } ?? ""
                    lines.append("  - \(issue.severity.rawValue) \(issue.code.rawValue)\(property)\(path): \(issue.message)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum WallpaperCompatibilityAnalyzer {
    /// 지원 속성 타입 단일 소스 — DeepScan 의 known 목록도 이걸 참조(스캐너 간 불일치 방지).
    /// F229: "boo4"/"uwu" 는 AppLogicTests 의 PropertyControl.kind(forType:) 미지 타입 폴백 검증용
    /// 더미 문자열이었다(be10dad 에서 테스트와 동시에 잘못 유입) — 실제 WE 속성 타입이 아니므로 제거.
    public static let currentPropertyTypes: Set<String> = [
        "bool", "checkbox", "slider", "combo", "color", "textinput", "text",
        "file", "directory", "scenetexture", "texture", "usershortcut", "group", "label",
    ]

    /// F230: VideoRenderer.nativeVideoExtensions 와 값이 같아야 하는 사본을 따로 두지 않는다 —
    /// WapleCore.VideoFormats 가 단일 소스(위 currentPropertyTypes 와 동일 원칙).
    private static let nativeVideoExtensions: Set<String> = VideoFormats.nativeExtensions

    public static func scan(rootURL: URL) throws -> WallpaperCompatibilityReport {
        let root = rootURL.standardizedFileURL
        let projectContainer = projectContainerURL(for: root)
        let folders = try projectFolders(in: projectContainer)
        let knownProjectIDs = Set(folders.map(\.lastPathComponent))
        let reports = folders.map { analyzeProject(folderURL: $0, knownProjectIDs: knownProjectIDs) }
            .sorted { $0.id < $1.id }

        return WallpaperCompatibilityReport(
            scannedRootPath: root.path,
            projectContainerPath: projectContainer.path,
            projects: reports,
            summary: makeSummary(reports)
        )
    }

    private static func projectContainerURL(for root: URL) -> URL {
        let backgrounds = root.appendingPathComponent("backgrounds", isDirectory: true)
        if FileManager.default.fileExists(atPath: backgrounds.appendingPathComponent("project.json").path) {
            return root
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: backgrounds.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return backgrounds.standardizedFileURL
        }
        return root
    }

    private static func projectFolders(in container: URL) throws -> [URL] {
        if FileManager.default.fileExists(atPath: container.appendingPathComponent("project.json").path) {
            return [container]
        }
        return try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func analyzeProject(folderURL: URL, knownProjectIDs: Set<String>) -> WallpaperCompatibilityProjectReport {
        let id = folderURL.lastPathComponent
        let raw = rawProjectJSON(folderURL: folderURL)
        var issues: [WallpaperCompatibilityIssue] = []

        guard let raw else {
            let issue = WallpaperCompatibilityIssue(
                severity: .error,
                code: .invalidProjectJSON,
                message: "project.json is missing or not a JSON object.",
                projectID: id
            )
            return WallpaperCompatibilityProjectReport(
                id: id,
                title: id,
                type: "invalid",
                folderPath: folderURL.path,
                fileName: nil,
                previewName: nil,
                dependency: nil,
                propertyTypes: [:],
                detectedFeatures: [],
                issues: [issue]
            )
        }

        // F231: `raw` 는 이미 이 폴더의 project.json 을 성공적으로 읽어 JSON 파싱한 결과다 — 같은 파일을
        // 다시 Data(contentsOf:) 로 읽고 다시 JSONSerialization 하는 대신 그 결과를 그대로 넘긴다
        // (ProjectJSONParser.parse(json:folderURL:) 는 non-throwing — 실패 가능성은 위 guard 가 이미
        // 소진했다). 부수 이득: 두 번 읽던 사이의 TOCTOU 창(파일이 그 사이 바뀌는 경우)도 사라진다.
        let project = ProjectJSONParser.parse(json: raw, folderURL: folderURL)

        analyzeTypeAndFiles(project, raw: raw, folderURL: folderURL, knownProjectIDs: knownProjectIDs, issues: &issues)
        let propertyTypes = analyzeProperties(raw: raw, projectID: project.id, issues: &issues)
        var features = Set(analyzeWebFeatures(project: project, folderURL: folderURL, issues: &issues))
        features.formUnion(analyzeSceneFeatures(project: project, folderURL: folderURL, issues: &issues))

        return WallpaperCompatibilityProjectReport(
            id: project.id,
            title: project.title,
            type: project.type.storageString,
            folderPath: folderURL.path,
            fileName: project.fileName,
            previewName: project.previewName,
            dependency: project.dependency,
            propertyTypes: propertyTypes,
            detectedFeatures: Array(features).sorted(),
            issues: issues.sorted(by: issueSort)
        )
    }

    private static func analyzeTypeAndFiles(_ project: WallpaperProject,
                                            raw: [String: Any],
                                            folderURL: URL,
                                            knownProjectIDs: Set<String>,
                                            issues: inout [WallpaperCompatibilityIssue]) {
        switch project.type {
        case .application:
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .unsupportedApplicationType,
                message: "Application wallpapers are recognized by project.json but Waple does not have an application renderer.",
                projectID: project.id,
                relativePath: project.fileName
            ))
            checkMainFile(project: project, raw: raw, folderURL: folderURL, issues: &issues)
        case .unknown(let rawType):
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .unknownProjectType,
                message: "Unknown Wallpaper Engine project type: \(rawType).",
                projectID: project.id
            ))
        case .web:
            checkMainFile(project: project, raw: raw, folderURL: folderURL, issues: &issues)
        case .video:
            checkMainFile(project: project, raw: raw, folderURL: folderURL, issues: &issues)
            if let file = project.fileName {
                let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
                if !nativeVideoExtensions.contains(ext) {
                    issues.append(WallpaperCompatibilityIssue(
                        severity: .warning,
                        code: .nonNativeVideoContainer,
                        message: "Video container is not currently handled by the native AVFoundation path and may need conversion or Web fallback.",
                        projectID: project.id,
                        relativePath: file
                    ))
                }
            }
        case .scene:
            if raw["file"] is String, project.fileName == nil {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .error,
                    code: .unsafeWallpaperFilePath,
                    message: "Main file path is absolute, escapes the project folder, or uses a URL scheme.",
                    projectID: project.id
                ))
            }
            let hasScenePackage = FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("scene.pkg").path)
                || FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("gifscene.pkg").path)
            if !hasScenePackage, !existingMainFile(project: project, folderURL: folderURL, issues: &issues) {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .error,
                    code: .missingScenePackage,
                    message: "Scene wallpaper has no scene.pkg, gifscene.pkg, or valid project file entry.",
                    projectID: project.id,
                    relativePath: project.fileName
                ))
            }
        case .preset:
            if let dependency = project.dependency, !dependency.isEmpty {
                if !knownProjectIDs.contains(dependency) {
                    issues.append(WallpaperCompatibilityIssue(
                        severity: .error,
                        code: .missingPresetDependency,
                        message: "Preset dependency \(dependency) is not present in the scanned corpus.",
                        projectID: project.id
                    ))
                }
            } else {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .error,
                    code: .missingPresetDependency,
                    message: "Preset has no dependency field.",
                    projectID: project.id
                ))
            }
        }

        checkPreview(project: project, raw: raw, folderURL: folderURL, issues: &issues)
    }

    @discardableResult
    private static func existingMainFile(project: WallpaperProject,
                                         folderURL: URL,
                                         issues: inout [WallpaperCompatibilityIssue]) -> Bool {
        guard rawHasStringFile(project.fileName) else { return false }
        guard let url = WallpaperPathSecurity.containedFileURL(project.fileName, root: folderURL) else {
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .unsafeWallpaperFilePath,
                message: "Main file path is absolute, escapes the project folder, or uses a URL scheme.",
                projectID: project.id,
                relativePath: project.fileName
            ))
            return false
        }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        if let equivalent = unicodeEquivalentURL(for: project.fileName ?? "", root: folderURL) {
            issues.append(WallpaperCompatibilityIssue(
                severity: .warning,
                code: .unicodeNormalizedFileMatch,
                message: "Declared file does not exist byte-for-byte, but a Unicode-normalized filename exists.",
                projectID: project.id,
                relativePath: relativePath(of: equivalent, root: folderURL)
            ))
            return true
        }
        return false
    }

    private static func checkMainFile(project: WallpaperProject,
                                      raw: [String: Any],
                                      folderURL: URL,
                                      issues: inout [WallpaperCompatibilityIssue]) {
        if raw["file"] is String, project.fileName == nil {
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .unsafeWallpaperFilePath,
                message: "Main file path is absolute, escapes the project folder, or uses a URL scheme.",
                projectID: project.id
            ))
            return
        }
        guard rawHasStringFile(project.fileName) else {
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .missingWallpaperFile,
                message: "Project type \(project.type.storageString) requires a file entry.",
                projectID: project.id
            ))
            return
        }
        if existingMainFile(project: project, folderURL: folderURL, issues: &issues) { return }
        issues.append(WallpaperCompatibilityIssue(
            severity: .error,
            code: .missingWallpaperFile,
            message: "Main wallpaper file is missing from the project folder.",
            projectID: project.id,
            relativePath: project.fileName
        ))
    }

    private static func checkPreview(project: WallpaperProject,
                                     raw: [String: Any],
                                     folderURL: URL,
                                     issues: inout [WallpaperCompatibilityIssue]) {
        guard raw["preview"] != nil else { return }
        guard let preview = project.previewName else {
            issues.append(WallpaperCompatibilityIssue(
                severity: .warning,
                code: .unsafePreviewPath,
                message: "Preview path is absolute, escapes the project folder, or uses a URL scheme.",
                projectID: project.id
            ))
            return
        }
        guard let previewURL = WallpaperPathSecurity.containedFileURL(preview, root: folderURL),
              FileManager.default.fileExists(atPath: previewURL.path) else {
            issues.append(WallpaperCompatibilityIssue(
                severity: .warning,
                code: .missingPreviewFile,
                message: "Preview file is missing from the project folder.",
                projectID: project.id,
                relativePath: preview
            ))
            return
        }
    }

    private static func analyzeProperties(raw: [String: Any],
                                          projectID: String,
                                          issues: inout [WallpaperCompatibilityIssue]) -> [String: Int] {
        guard let general = raw["general"] as? [String: Any] else { return [:] }
        guard let properties = general["properties"] as? [String: Any] else { return [:] }
        var counts: [String: Int] = [:]
        for key in properties.keys.sorted() {
            guard let property = properties[key] as? [String: Any] else { continue }
            let type = ((property["type"] as? String) ?? "").lowercased()
            if !type.isEmpty { counts[type, default: 0] += 1 }
            if !type.isEmpty, !currentPropertyTypes.contains(type) {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .warning,
                    code: .unsupportedPropertyType,
                    message: "Property type \(type) is not editable by Waple's current property panel.",
                    projectID: projectID,
                    propertyKey: key
                ))
            }
            if let condition = property["condition"] as? String,
               !PropertyConditionEvaluator.canEvaluate(condition) {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .warning,
                    code: .propertyDisplayCondition,
                    message: "Display condition is present but not supported by Waple's property condition evaluator.",
                    projectID: projectID,
                    propertyKey: key
                ))
            }
        }
        return counts
    }

    private static func analyzeWebFeatures(project: WallpaperProject,
                                           folderURL: URL,
                                           issues: inout [WallpaperCompatibilityIssue]) -> [String] {
        guard project.type == .web,
              let fileName = project.fileName else { return [] }

        var features: Set<String> = []
        func add(_ feature: String,
                 _ code: WallpaperCompatibilityIssueCode,
                 _ severity: WallpaperCompatibilitySeverity,
                 _ message: String) {
            guard features.insert(feature).inserted else { return }
            issues.append(WallpaperCompatibilityIssue(
                severity: severity,
                code: code,
                message: message,
                projectID: project.id,
                relativePath: fileName
            ))
        }

        for source in webFeatureSources(entryPath: fileName, folderURL: folderURL) {
            let text = source.text
            if text.contains("wallpaperPropertyListener") {
                features.insert("propertyListener")
            }
            if text.contains("wallpaperWillGoBackground") || text.contains("wallpaperWillGoForeground") {
                features.insert("webLifecycle")
            }
            // F235: 아래 4건은 종전엔 features.insert 만 하고 issue 로 승격하지 않아 markdown/JSON 요약·
            // --strict 게이트 어디에도 반영되지 않았다(detectedFeatures 에만 남아 사람이 안 읽는 한
            // 소실). add(...) 로 최소 .warning 승격 — feature 키 자체는 하위호환을 위해 그대로 둔다.
            if text.range(of: "serviceWorker", options: .caseInsensitive) != nil {
                add("serviceWorker", .webServiceWorker, .warning, "Web wallpaper touches the serviceWorker API; Waple's offline WKWebView may not offer full parity for background sync/fetch interception.")
            }
            if text.contains("wallpaperRequestRandomFileForProperty") {
                add("randomFile", .webRandomFileBridge, .warning, "Web wallpaper requests random files; returned paths and directory modes need Wallpaper Engine parity.")
            }
            if text.contains("wallpaperRegisterAudioListener") {
                add("audioListener", .webAudioListener, .warning, "Web wallpaper registers a Wallpaper Engine audio listener; verify Waple's audio bridge coverage for this project.")
            }
            if text.contains("wallpaperRegisterMedia") || text.contains("wallpaperMedia") {
                add("mediaIntegration", .webMediaIntegration, .warning, "Web wallpaper uses Wallpaper Engine media integration bridges; coverage may be partial.")
            }
            if text.range(of: #"\bwebgl\b|OES_"#, options: [.regularExpression, .caseInsensitive]) != nil {
                features.insert("webGL")
            }
            if text.range(of: #"file:///"#, options: [.caseInsensitive]) != nil {
                features.insert("fileURL")
            }
            if text.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
                add("remoteNetwork", .remoteNetworkReference, .warning, "Web wallpaper references a remote (non-local) URL; Waple's offline WKWebView may block or fail this request.")
            }
        }
        return Array(features)
    }

    private static func analyzeSceneFeatures(project: WallpaperProject,
                                             folderURL: URL,
                                             issues: inout [WallpaperCompatibilityIssue]) -> [String] {
        guard project.type == .scene,
              let packageURL = scenePackageURL(in: folderURL) else { return [] }
        let package: ScenePackage
        do {
            package = try ScenePackage.parse(Data(contentsOf: packageURL))
        } catch {
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .missingScenePackage,
                message: "Scene package exists but could not be parsed by Waple: \(error)",
                projectID: project.id,
                relativePath: packageURL.lastPathComponent
            ))
            return []
        }
        var features: Set<String> = ["scenePackage"]

        if package.entries.contains(where: { $0.name.hasPrefix("effects/") && $0.name.hasSuffix("effect.json") }) {
            features.insert("sceneEffect")
        }
        if package.entries.contains(where: { $0.name.hasSuffix(".mdl") }) {
            features.insert("scene3DModel")
        }
        if package.entries.contains(where: { $0.name.hasPrefix("sounds/") }) {
            features.insert("sceneSound")
        }

        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              let scene = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            return Array(features)
        }
        let sceneText = String(data: sceneData, encoding: .utf8) ?? ""
        if sceneText.contains(#""script""#) { features.insert("sceneScript") }

        for case let object as [String: Any] in scene["objects"] as? [Any] ?? [] {
            if object["image"] != nil { features.insert("sceneLayer") }
            if object["particle"] != nil { features.insert("sceneParticle") }
            if object["text"] != nil { features.insert("sceneText") }
            if object["sound"] != nil { features.insert("sceneSound") }
            if object["model"] != nil { features.insert("scene3DModel") }
            if object["light"] != nil { features.insert("sceneLight") }
            if object["effects"] != nil { features.insert("sceneEffect") }
        }

        return Array(features)
    }

    private static func scenePackageURL(in folderURL: URL) -> URL? {
        for name in ["scene.pkg", "gifscene.pkg"] {
            let url = folderURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private struct WebFeatureSource {
        let text: String
    }

    private static func webFeatureSources(entryPath: String, folderURL: URL) -> [WebFeatureSource] {
        let maxFiles = 64
        let maxBytes = 2_000_000
        var queue = [entryPath]
        var seen: Set<String> = []
        var totalBytes = 0
        var processed = 0
        var sources: [WebFeatureSource] = []

        while !queue.isEmpty, sources.count < maxFiles, processed < maxFiles * 4 {
            let relativePath = queue.removeFirst()
            guard let normalized = WallpaperPathSecurity.normalizedRelativePath(relativePath),
                  !seen.contains(normalized),
                  let url = WallpaperPathSecurity.containedFileURL(normalized, root: folderURL) else { continue }
            seen.insert(normalized)
            processed += 1
            guard isWebFeatureTextPath(normalized) else { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            guard data.count <= maxBytes,
                  totalBytes + data.count <= maxBytes,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            totalBytes += data.count
            sources.append(WebFeatureSource(text: text))

            for reference in localWebReferences(in: text, basePath: normalized) {
                guard !seen.contains(reference), queue.count + sources.count < maxFiles else { continue }
                queue.append(reference)
            }
        }

        return sources
    }

    private static func isWebFeatureTextPath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext.isEmpty || ["html", "htm", "js", "mjs", "css", "json", "txt", "svg", "xml"].contains(ext)
    }

    private static func localWebReferences(in text: String, basePath: String) -> [String] {
        let patterns = [
            #"(?:src|href)\s*=\s*["']([^"']+)["']"#,
            #"(?:new\s+Worker|importScripts|import)\s*\(\s*["']([^"']+)["']"#,
            #"\bimport\s+(?:[^"']+\s+from\s+)?["']([^"']+)["']"#,
        ]
        var out: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let refRange = Range(match.range(at: 1), in: text),
                      let resolved = resolveLocalWebReference(String(text[refRange]), basePath: basePath) else { continue }
                out.append(resolved)
            }
        }
        return out
    }

    private static func resolveLocalWebReference(_ raw: String, basePath: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#,
                            options: .regularExpression) == nil,
              !trimmed.hasPrefix("//") else { return nil }
        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutFragment
        guard !withoutQuery.isEmpty else { return nil }

        var parts: [String]
        if withoutQuery.hasPrefix("/") {
            parts = []
        } else {
            parts = basePath.split(separator: "/").dropLast().map(String.init)
        }

        for component in withoutQuery.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(component)
            }
        }

        guard !parts.isEmpty else { return nil }
        return WallpaperPathSecurity.normalizedRelativePath(parts.joined(separator: "/"))
    }

    private static func rawProjectJSON(folderURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folderURL.appendingPathComponent("project.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func makeSummary(_ projects: [WallpaperCompatibilityProjectReport]) -> WallpaperCompatibilitySummary {
        var typeCounts: [String: Int] = [:]
        var issueCounts: [String: Int] = [:]
        var severityCounts: [String: Int] = [:]
        var blocked = 0

        for project in projects {
            typeCounts[project.type, default: 0] += 1
            if project.isBlocked { blocked += 1 }
            for issue in project.issues {
                issueCounts[issue.code.rawValue, default: 0] += 1
                severityCounts[issue.severity.rawValue, default: 0] += 1
            }
        }

        return WallpaperCompatibilitySummary(
            totalProjects: projects.count,
            typeCounts: typeCounts,
            renderableProjects: projects.count - blocked,
            blockedProjects: blocked,
            issueCounts: issueCounts,
            severityCounts: severityCounts
        )
    }

    private static func issueSort(_ lhs: WallpaperCompatibilityIssue, _ rhs: WallpaperCompatibilityIssue) -> Bool {
        if lhs.severity.sortRank != rhs.severity.sortRank { return lhs.severity.sortRank > rhs.severity.sortRank }
        if lhs.code.rawValue != rhs.code.rawValue { return lhs.code.rawValue < rhs.code.rawValue }
        return (lhs.propertyKey ?? "") < (rhs.propertyKey ?? "")
    }

    private static func rawHasStringFile(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return !fileName.isEmpty
    }

    private static func unicodeEquivalentURL(for relativePath: String, root: URL) -> URL? {
        guard let normalized = WallpaperPathSecurity.normalizedRelativePath(relativePath) else { return nil }
        var current = root
        for component in normalized.split(separator: "/").map(String.init) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) else {
                return nil
            }
            let wantedPrecomposed = component.precomposedStringWithCanonicalMapping
            let wantedDecomposed = component.decomposedStringWithCanonicalMapping
            guard let match = entries.first(where: {
                let name = $0.lastPathComponent
                return name.precomposedStringWithCanonicalMapping == wantedPrecomposed
                    || name.decomposedStringWithCanonicalMapping == wantedDecomposed
            }) else {
                return nil
            }
            current = match
        }
        return current
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

private extension WallpaperCompatibilitySeverity {
    var sortRank: Int {
        switch self {
        case .error: return 3
        case .warning: return 2
        }
    }
}
