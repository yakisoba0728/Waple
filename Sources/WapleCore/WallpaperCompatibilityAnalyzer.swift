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
    // **[3차 웨이브 AB] 실물 대조로 찾은 거짓 음성.** `bin/webwallpaper64.exe` 의 웹 브리지 표면을
    // 전수로 뜨면(ASCII `wallpaper[A-Za-z0-9_]{2,60}`) 13종이고 그중 하나가 `wallpaperPluginListener`
    // (2회)다 — iCUE/Chroma LED 플러그인 채널. Waple 의 `WallpaperBridgeJS.swift` 는 이 이름을
    // **한 번도 정의하지 않는다**(`grep -rn "PluginListener" Sources/` = 0건). 즉 벽지가 등록해도
    // 콜백이 영영 안 오고 LED 연동이 조용히 죽는다.
    // 도달: 설치본 web 프로젝트 **2/2 전건**(`corsair_o_tron/js/main.js` ·
    // `corsair_collection/main.*.js`) — 이 코퍼스의 웹 벽지가 전부 iCUE 연동물이다. 종전에는
    // 이 2건에 대해 분석기가 아무 말도 하지 않았다.
    // 렌더 자체는 되므로 `.error` 가 아니라 `.warning`(형제 `webAudioListener` 와 같은 등급).
    case webPluginBridge
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

/// **웹 벽지가 건드리는 Wallpaper Engine 브리지 신호 — 탐지 문자열의 단일 소스.**
///
/// [2026-08-21 클러스터 BE] 종전에는 같은 마커 문자열이 두 스캐너에 각각 리터럴로 박혀 있었고
/// 그래서 **개수가 갈렸다**: `WallpaperCompatibilityAnalyzer.analyzeWebFeatures` 는 9종 +
/// `remoteNetwork`, `DeepScan.scanWeb` 은 `randomFile`·`serviceWorker` **2종뿐**. 즉 같은 웹
/// 벽지를 두 스캐너에 물리면 서로 다른 얘기를 했고, 어느 쪽이 정본인지 코드에 안 적혀 있었다.
/// 문자열을 여기 한 벌만 둬서 **개수가 갈릴 자리 자체를 없앤다.**
///
/// `rawValue` 는 `WallpaperCompatibilityProjectReport.detectedFeatures` 에 그대로 실리는 값이라
/// **바꾸면 리포트 스키마가 바뀐다**(하위호환 유지 — 종전 문자열 그대로다).
///
/// 근거: `bin/webwallpaper64.exe` 의 웹 브리지 표면을 ASCII `wallpaper[A-Za-z0-9_]{2,60}` 로
/// 전수하면 13종이다(3차 웨이브 AB 실측). `serviceWorker`/`webGL`/`fileURL` 은 그 13종이 아니라
/// 브라우저 API 쪽 신호다.
///
/// **크롤 범위는 이 타입이 정하지 않는다.** 분석기는 엔트리에서 시작해 최대 64파일/2MB 를 따라가고
/// (`webFeatureSources`), `DeepScan.scanWeb` 은 엔트리 파일 하나만 읽는다. 그 차이는 남아 있다 —
/// 여기서 합친 것은 **무엇을 신호로 보는가**이지 **어디를 읽는가**가 아니다.
public enum WebBridgeSignal: String, CaseIterable, Sendable {
    case propertyListener
    case webLifecycle
    case serviceWorker
    case randomFile
    case pluginBridge
    case audioListener
    case mediaIntegration
    case webGL
    case fileURL

    /// 이 신호가 이 텍스트에 있는가.
    public func matches(_ text: String) -> Bool {
        switch self {
        case .propertyListener:
            return text.contains("wallpaperPropertyListener")
        case .webLifecycle:
            // **[3차 웨이브 AB]** 이 두 이름은 WE 2.8.42 설치본 전 트리(exe·dll·ui·assets·projects)
            // ASCII·UTF-16LE 전수에서 **0건**이다 — 다른 버전/문서 기반이거나 다른 제품의 API 로
            // 보인다(추정). 피처 태그일 뿐 이슈를 만들지 않는다.
            return text.contains("wallpaperWillGoBackground") || text.contains("wallpaperWillGoForeground")
        case .serviceWorker:
            return text.range(of: "serviceWorker", options: .caseInsensitive) != nil
        case .randomFile:
            return text.contains("wallpaperRequestRandomFileForProperty")
        case .pluginBridge:
            return text.contains("wallpaperPluginListener")
        case .audioListener:
            return text.contains("wallpaperRegisterAudioListener")
        case .mediaIntegration:
            return text.contains("wallpaperRegisterMedia") || text.contains("wallpaperMedia")
        case .webGL:
            return text.range(of: #"\bwebgl\b|OES_"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .fileURL:
            return text.range(of: #"file:///"#, options: [.caseInsensitive]) != nil
        }
    }

    /// 이슈로 승격되는 신호면 그 코드, 태그로만 남는 신호면 nil.
    /// 승격 기준: **Waple 의 브리지가 그 이름을 정의하지 않거나 동작 파리티가 불확실할 때**만.
    /// `propertyListener`·`webLifecycle`·`webGL`·`fileURL` 은 지원하거나(브리지 실측) 위험 신호가
    /// 아니라 태그로만 남는다.
    public var issueCode: WallpaperCompatibilityIssueCode? {
        switch self {
        case .propertyListener, .webLifecycle, .webGL, .fileURL: return nil
        case .serviceWorker: return .webServiceWorker
        case .randomFile: return .webRandomFileBridge
        case .pluginBridge: return .webPluginBridge
        case .audioListener: return .webAudioListener
        case .mediaIntegration: return .webMediaIntegration
        }
    }

    /// 승격될 때 실리는 문구(태그 전용 신호는 빈 문자열).
    public var issueMessage: String {
        switch self {
        case .propertyListener, .webLifecycle, .webGL, .fileURL:
            return ""
        case .serviceWorker:
            return "Web wallpaper touches the serviceWorker API; Waple's offline WKWebView may not offer full parity for background sync/fetch interception."
        case .randomFile:
            return "Web wallpaper requests random files; returned paths and directory modes need Wallpaper Engine parity."
        case .pluginBridge:
            // [3차 웨이브 AB] WE 웹 브리지 13종 중 Waple 이 **정의하지 않는** 유일한 이름
            // (`webPluginBridge` 선언부 주석의 근거 참조). 설치본 web 2/2 도달.
            return "Web wallpaper registers a Wallpaper Engine plugin listener (iCUE/Chroma LED channel); Waple's WKWebView bridge does not define wallpaperPluginListener, so those callbacks never arrive."
        case .audioListener:
            return "Web wallpaper registers a Wallpaper Engine audio listener; verify Waple's audio bridge coverage for this project."
        case .mediaIntegration:
            return "Web wallpaper uses Wallpaper Engine media integration bridges; coverage may be partial."
        }
    }

    /// 텍스트 한 벌에서 켜지는 신호 전부.
    public static func signals(in text: String) -> Set<WebBridgeSignal> {
        Set(allCases.filter { $0.matches(text) })
    }
}

public enum WallpaperCompatibilityAnalyzer {
    /// 지원 속성 타입 단일 소스 — DeepScan 의 known 목록도 이걸 참조(스캐너 간 불일치 방지).
    /// F229: "boo4"/"uwu" 는 AppLogicTests 의 PropertyControl.kind(forType:) 미지 타입 폴백 검증용
    /// 더미 문자열이었다(be10dad 에서 테스트와 동시에 잘못 유입) — 실제 WE 속성 타입이 아니므로 제거.
    ///
    /// **[3차 웨이브 AB · 2026-08-21 실물 대조 — 이 집합은 WE 스키마도 Waple 패널도 아니다]**
    /// WE 가 아는 벽지 유저 프로퍼티 `type` 은 `ui/dist/scripts/scripts.js` 의
    /// `views/includes/browseruserproperties.html` 템플릿(byte @750151, 길이 7,272)이 분기하는
    /// **12종**: `bool color combo combolutfilters directory divider file scenetexture slider
    /// textinput usershortcut volume` + 형제 템플릿 `browseruserpropertiesgroup.html` 의 `group`.
    /// (형제 파일 `PropertyDecoration.swift:9` 가 같은 오프셋에서 같은 목록을 이미 인용한다.)
    ///
    /// **[2026-08-21 정정 · 클러스터 BE 가 설치본 `ui/` 를 독립적으로 다시 떴다]**
    /// 위 문단은 **12종 목록 자체는 맞지만** 오프셋 라벨과 `group` 의 귀속이 틀렸다. 실측:
    ///   · 오프셋은 **byte 가 아니라 char** 다. 템플릿 **본문**은 char `[750195, 757420)` =
    ///     byte `[750374, 757599)`, 길이 **7,225**(그 구간은 전부 ASCII 라 char=byte). 종전의
    ///     `@750151` 은 `e.put("views/includes/browseruserproperties.html"` 의 **이름 문자열**
    ///     char 오프셋이고 `길이 7,272` 는 어디서도 나오지 않는 수다(7,232 의 오타로 보인다).
    ///     `scripts.js` 는 char 1,186,896 / byte 1,187,134 로 둘이 238 만큼 어긋난다.
    ///   · `browseruserproperties.html` 안의 타입 분기는 **13자리 · 고유 12종**이다.
    ///     `color` 만 `property.type==='color'`(**삼중 등호**)이고 나머지 11종은 `==` 이며,
    ///     `volume` 만 두 자리다(`isVolumeEnabled(...)` 유/무로 갈린 두 `ng-if`).
    ///     `==` 만 찾는 순진한 grep 은 `color` 를 놓쳐 **11종**을 준다 — 그 11이라는 수가
    ///     이 코드베이스에서 실제로 나돌았다.
    ///   · **`group` 은 형제 템플릿에 없다.** `browseruserpropertiesgroup.html`(char
    ///     `[757479, 757963)`, byte `[757658, 758142)`, **484바이트**)에는 `type` 비교가
    ///     **0건**이고, 그룹 제목 + `#GroupFoldParent` 접힘 컨테이너만 그린다.
    ///     `group` 을 아는 것은 **JS 컨트롤러**다 — byte @88625 의
    ///     `"group"===l.type?t.push(n={properties:[],property:l}):n.properties.push(l)` 가
    ///     정렬된 프로퍼티 목록을 `group` 마다 잘라 구획을 만들고, 그 구획마다
    ///     `D.all([e("views/includes/browseruserproperties.html"),
    ///     e("views/includes/browseruserpropertiesgroup.html")])` 로 받아 둔 두 템플릿을
    ///     각각 인스턴스화한다. 즉 브라우저 패널이 아는 타입은 **템플릿 12 + JS 1 = 13종**이다.
    ///   · **`divider` 는 이름이 겹친다 — 어느 namespace 인지 반드시 밝힐 것.** `scripts.js`
    ///     에서 `divider` 를 *타입 값*으로 쓰는 자리는 넷이고 서로 무관하다:
    ///       ① byte @757526 `views/includes/browseruserproperties.html`
    ///          `property.type=='divider'` → `<hr class="fullWidth">` — **이 집합이 다루는 것**
    ///       ② byte @960811 `views/templates/droplist.html`
    ///          `ng-class="{divider:option.type=='divider',…}"` — 드롭리스트 항목 구분선
    ///       ③ byte @1022004 `views/templates/propertylist.html` `ng-switch-when="divider"`
    ///          (`ng-switch on="property.type"` byte @993662·@994748 아래) — 씬 에디터 인스펙터
    ///       ④ byte @444157 JS 컨텍스트 메뉴 빌더 `divider:function(){…push({type:"divider"})…}`
    ///          (소비 byte @440490 `case"divider":`) — 우클릭 메뉴 항목
    ///     ①만 벽지 유저 프로퍼티다. ②③④를 근거로 끌어 쓰면 틀린다.
    ///
    /// 아래 집합과의 차이는 **양방향**이고, 어느 쪽도 근거가 없다:
    ///   · **WE 에 있는데 여기 없음(3)**: `volume` `combolutfilters` `divider`
    ///     → 실물이 쓰면 "not editable" 경고가 나간다. 이건 우연히 맞다(`PropertyControl.kind`
    ///       가 셋 다 `.displayOnly`) — 근거가 아니라 우연이다.
    ///   · **여기 있는데 WE 스키마에 없음(4)**: `checkbox` `text` `texture` `label`
    ///     - `checkbox` 는 WE 에서 **템플릿 옵션·플러그인 설정**의 타입이지 벽지 프로퍼티 타입이
    ///       아니다(`option.type === 'checkbox'`). `WallpaperProperties.parseValue` 가 `bool` 과
    ///       함께 처리하므로 무해하다.
    ///     - `texture` 는 WE **씬 에디터 오브젝트 인스펙터**의 타입이다(byte @994481,
    ///       `ng-switch on="property.type"` — `readonly`/`readonlycolor` 등과 같은 namespace).
    ///       벽지 `general.properties` 에서는 근거가 없다.
    ///       [2026-08-21 정정] 그 인스펙터는 `views/templates/propertylist.html` 이고 실측
    ///       오프셋은 `ng-switch on="property.type"` byte @993662·@994748,
    ///       `property.type === 'texture'` byte @994719, `ng-switch-when="texture"` byte
    ///       @1007433 이다. 같은 인스펙터(byte 길이 37,577)가 `ng-switch-when` 으로
    ///       **59자리 · 고유 56종**을 분기한다(`checkbox` `checkboxbit3` `vec2` `vec3` `vec4`
    ///       `uvec2` `hue` `huesteps` `knob` `particle` `boneweights` `matrixselector` …) —
    ///       벽지 프로퍼티 12종과는 **집합 크기부터 다른 별개 namespace** 다.
    ///     - `text` `label` 은 `type==` 비교가 **0건**이다. `text`/`label` 은 프로퍼티의
    ///       **필드 이름**(라벨 문자열·옵션 라벨)이라 형제 키 혼동으로 보인다. [미해결]
    ///   · **이름이 뜻과 어긋난다**: 아래 이슈 문구는 "Waple 의 프로퍼티 패널이 편집 못 한다"인데
    ///     `usershortcut` `group` `text` `label` `texture` 는 이 집합에 있으면서
    ///     `PropertyControl.kind(forType:)`(`Sources/Waple/AppLogic.swift` 의
    ///     `static func kind(forType type: String) -> Kind`)가 `.displayOnly` 를
    ///     준다 — 즉 **경고가 나가야 하는데 안 나간다**.
    ///
    /// **집합을 지금 고치지 않는 이유**: 설치본 191 + 동봉 170 프로젝트에 등장하는 타입은
    /// `color·slider·combo·bool` 넷뿐이라 위 어떤 차이도 **도달 0건**이고(코퍼스 감사 테스트가
    /// 그 분포를 고정한다), 반대로 `group` 을 미지로 돌리면 워크샵 코퍼스(여기서 측정 불가)에서
    /// 대량 경고가 난다. 정정안은 보고서로 넘긴다.
    public static let currentPropertyTypes: Set<String> = [
        "bool", "checkbox", "slider", "combo", "color", "textinput", "text",
        "file", "directory", "scenetexture", "texture", "usershortcut", "group", "label",
    ]

    /// **WE 2.8.42 브라우저 벽지 프로퍼티 패널이 실제로 아는 `type` 전수(13종).** 위 정정 문단의
    /// 실측을 코드로 굳혀 둔다 — 문서만 고치면 다음 세션이 또 다른 수를 적는다.
    ///
    /// 출처는 설치본 `ui/dist/scripts/scripts.js` 한 파일이고 두 갈래다:
    ///   · 템플릿 `views/includes/browseruserproperties.html` 의 `ng-if` 12종
    ///     (`color` 만 `===`, 나머지는 `==`; `volume` 은 두 자리)
    ///   · JS 컨트롤러의 `"group"===l.type` 1종(구획 분할 — 템플릿에는 없다)
    ///
    /// **이 집합은 판정에 쓰이지 않는다**(경고를 내는 것은 `currentPropertyTypes` 다). 두 집합의
    /// 차이를 테스트가 못박기 위한 참조값이다 — 차이가 움직이면 그건 근거가 바뀐 것이므로
    /// 사람이 다시 봐야 한다. 설치본 191 + 동봉 170 프로젝트에 등장하는 타입은
    /// `color · slider · combo · bool` 넷뿐이라 아래 차이 전부가 **코퍼스 도달 0건**이다.
    public static let weBrowserPropertyTypes: Set<String> = [
        // browseruserproperties.html — ng-if 12종
        "bool", "color", "combo", "combolutfilters", "directory", "divider",
        "file", "scenetexture", "slider", "textinput", "usershortcut", "volume",
        // JS 컨트롤러 `"group"===l.type` — 템플릿 분기가 아니다
        "group",
    ]

    /// WE 스키마에는 있는데 `currentPropertyTypes` 에는 없는 타입 — 실물이 쓰면
    /// `unsupportedPropertyType` 경고가 나간다. 실측 3종(`volume` `combolutfilters` `divider`).
    public static var wePropertyTypesMissingFromWaple: Set<String> {
        weBrowserPropertyTypes.subtracting(currentPropertyTypes)
    }

    /// `currentPropertyTypes` 에는 있는데 WE 벽지 프로퍼티 스키마에는 없는 타입 — 경고가
    /// 나가야 할지 모르는데 안 나간다. 실측 4종(`checkbox` `text` `texture` `label`);
    /// 각각의 실제 출처는 위 선언 주석 참조(다른 namespace 이거나 근거 0건).
    public static var waplePropertyTypesNotInWESchema: Set<String> {
        currentPropertyTypes.subtracting(weBrowserPropertyTypes)
    }

    /// F230: VideoRenderer.nativeVideoExtensions 와 값이 같아야 하는 사본을 따로 두지 않는다 —
    /// WapleCore.VideoFormats 가 단일 소스(위 currentPropertyTypes 와 동일 원칙).
    private static let nativeVideoExtensions: Set<String> = VideoFormats.nativeExtensions

    public static func scan(rootURL: URL) throws -> WallpaperCompatibilityReport {
        let root = rootURL.standardizedFileURL
        let projectContainer = projectContainerURL(for: root)
        let folders = try projectFolders(in: projectContainer)
        let knownProjectIDs = knownProjectIDs(in: folders)
        let reports = folders.map { analyzeProject(folderURL: $0, knownProjectIDs: knownProjectIDs) }
            .sorted { $0.id < $1.id }

        return WallpaperCompatibilityReport(
            scannedRootPath: root.path,
            projectContainerPath: projectContainer.path,
            projects: reports,
            summary: makeSummary(reports)
        )
    }

    /// **코퍼스 열거의 단일 소스 ①** — 루트에서 "프로젝트 폴더들이 들어 있는 컨테이너" 를 고른다.
    ///
    /// [2026-08-21 클러스터 BE] 종전에는 이 규칙의 **사본이 셋**이었다:
    /// `WallpaperCompatibilityAnalyzer`(여기) · `DeepScan.projectContainer` ·
    /// `SnapshotPipeline.sceneContainer`. 앞의 둘은 글자만 다르고 뜻이 같았지만 셋째는
    /// **첫 분기(`backgrounds/project.json` 존재)를 통째로 빼먹은 채 주석에는
    /// "DeepScan.projectContainer 와 동일 규칙" 이라고 적혀 있었다.** 즉 그 자리는
    /// `backgrounds` 라는 이름의 프로젝트 폴더가 있는 루트에서 컨테이너를 한 칸 잘못 골랐다
    /// (설치본·동봉 도달 0건 — 두 트리에 그런 폴더가 없다. 그래서 아무도 못 봤다).
    /// 사본이 하나면 다시 갈릴 수 없다 — 세 소비처가 전부 이 함수를 부른다.
    ///
    /// 규칙(세 갈래, 순서가 중요하다):
    ///   ① `<root>/backgrounds/project.json` 이 있으면 `backgrounds` 자체가 **프로젝트 폴더**다
    ///      → 컨테이너는 `root`.
    ///   ② `<root>/backgrounds` 가 디렉터리면 WE 개발 루트 배치다 → 컨테이너는 그 디렉터리.
    ///   ③ 아니면 `root` 그대로(= `backgrounds` 를 직접 지정했거나 단일 프로젝트 폴더).
    public static func projectContainerURL(for root: URL) -> URL {
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

    /// **코퍼스 열거의 단일 소스 ②** — 컨테이너 아래에서 `project.json` 을 가진 폴더 전부(정렬).
    /// 컨테이너 자신이 `project.json` 을 가지면 `[container]` 하나를 준다(단일 프로젝트 모드).
    ///
    /// `throws` 인 이유: 디렉터리를 못 읽는 것(권한·경로 오타)은 **"프로젝트 0개" 와 다른 사건**이다.
    /// 조용히 `[]` 를 돌려주면 호출측이 "빈 코퍼스" 로 오인하고 성공 종료한다(F150/F151·F520 이
    /// 반복해서 막은 바로 그 류). 0 개를 `[]` 로 받고 싶은 호출측은 `try?` 로 명시적으로 삼켜라 —
    /// `DeepScan`/`SnapshotPipeline` 이 그렇게 한다(둘 다 자체 0건 가드를 따로 들고 있다).
    public static func projectFolders(in container: URL) throws -> [URL] {
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

    /// F411: preset dependency 매칭 기준을 런타임 PresetResolver(엔트리 id 매칭 + 형제 폴터명 매칭)와
    /// 동등 수준으로 — 종전엔 폴터명(lastPathComponent)만 모았는데, F194 이후 project id 는
    /// `workshopid ?? 폴터명` 이라 폴터명 ≠ workshopid 인 대상을 가리키는 preset 은 런타임엔 해소되는데
    /// analyzer 만 거짓 missingPresetDependency 를 냈다. id ∪ 폴터명 합집합으로 구성한다(id 규칙의
    /// 단일 소스는 ProjectJSONParser — F230 원칙상 여기서 workshopid 추출을 복제하지 않는다).
    private static func knownProjectIDs(in folders: [URL]) -> Set<String> {
        var ids = Set<String>()
        for folder in folders {
            ids.insert(folder.lastPathComponent)
            if let raw = rawProjectJSON(folderURL: folder) {
                ids.insert(ProjectJSONParser.parse(json: raw, folderURL: folder).id)
            }
        }
        return ids
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
            // 3차 웨이브 AB: **마운트 결정은 `ScenePackage.resolveMountSource` 하나다.** 종전 이 줄은
            // `scene.pkg`/`gifscene.pkg` **이름 두 개의 존재**만 봤는데, 렌더러는 2026-08-21 부터
            // `resolveMountSource`(SceneRenderer.swift:1454)를 쓴다 — `project.json` 의 `file` 이
            // 단독 결정자이고 `.pkg` 는 그 파일이 디스크에 **없을 때만** 도는 폴백이다. 이 스캐너의
            // 계약("이슈 없음 = 렌더 가능")은 두 결정이 같을 때만 참이므로 여기도 같은 함수를 부른다.
            // 종전과 갈리던 자리 3종(전부 렌더러 쪽이 맞다):
            //   ① `file:"techno.json"` 부재 + `techno.pkg` 존재 → 렌더러는 pkg 를 연다. 종전 스캐너는
            //      이름이 안 맞아 못 찾고 폴더 마운트로 떨어져 **거짓 missingScenePackage** 를 냈다.
            //   ② `Scene.pkg` 처럼 대소문자만 다른 표기 → `legacyPackageURL` 은 잡고 종전 스캐너는 놓쳤다.
            //   ③ `file:"scene.json"` 이 실재하는데 잔존 `scene.pkg` 도 있을 때 → 렌더러는 **폴더**를,
            //      종전 스캐너는 **pkg** 를 열어 서로 다른 씬을 검사했다.
            // **코퍼스 도달 0건**: 설치본 191 + 동봉 170 전건에 `.pkg` 가 0개고 `file` 이 전건 실재한다
            // (WallpaperCompatibilityCorpusAuditTests 가 그 분포를 고정한다). 즉 판정 수치는 안 움직인다.
            let hasScenePackage: Bool
            if case .package = sceneMountSource(project, folderURL: folderURL) { hasScenePackage = true }
            else { hasScenePackage = false }
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
        if let previewURL = WallpaperPathSecurity.containedFileURL(preview, root: folderURL),
           FileManager.default.fileExists(atPath: previewURL.path) {
            return
        }
        // F233/F234: existingMainFile 과 동일한 Unicode(NFC/NFD) 정규화 동치 폴백 — 바이트 단위로는
        // 안 맞지만 실존하는 프리뷰 파일(Steam Workshop/한글 파일명 환경에서 흔함)을 거짓
        // missingPreviewFile 로 잘못 잡지 않는다. main file 은 이미 이 폴백을 쓰는데 preview 만
        // 엄격했던 비대칭을 해소.
        if let equivalent = unicodeEquivalentURL(for: preview, root: folderURL) {
            issues.append(WallpaperCompatibilityIssue(
                severity: .warning,
                code: .unicodeNormalizedFileMatch,
                message: "Declared preview does not exist byte-for-byte, but a Unicode-normalized filename exists.",
                projectID: project.id,
                relativePath: relativePath(of: equivalent, root: folderURL)
            ))
            return
        }
        issues.append(WallpaperCompatibilityIssue(
            severity: .warning,
            code: .missingPreviewFile,
            message: "Preview file is missing from the project folder.",
            projectID: project.id,
            relativePath: preview
        ))
    }

    /// 표시 조건식(`condition`)이 Waple 에서 어디까지 되는지 — **두 스캐너의 단일 소스**.
    ///
    /// [2026-08-21 클러스터 BE] 종전에는 같은 사실을 두 갈래로 셌다:
    ///   · 분석기: `canEvaluate(c)` 하나 — 거짓이면 `propertyDisplayCondition` 경고.
    ///   · `DeepScan.scanProperties`: `canEvaluate(c) && evaluate(c, values:) != nil` —
    ///     리포트의 `conditions evaluable` 백분율.
    /// 두 술어가 **다른 것을 재는데 이름도 주석도 그 차이를 말하지 않았다.** 사다리로 못박는다:
    /// `none ⊂ unsupported | parsedOnly ⊂ evaluated`.
    ///
    /// **빈 조건은 `none` 이다 — WE 규약이다.** 브라우저 템플릿이
    /// `ng-if="!property.condition || evalCondition(property.condition)"` 라 빈 문자열은 JS 에서
    /// falsy → `evalCondition` 을 **부르지 않고** 항상 표시한다. Waple 의 평가기도 같은 결과를
    /// 낸다(`Tokenizer` 가 빈 토큰열이면 `(true, exact)`). 설치본 도달 **1건**
    /// (`projects/defaultprojects/dino_run` 의 `god_rays`, `type: bool`, `condition: ""`) —
    /// 종전에도 두 스캐너가 이 1건을 서로 다른 이유로 조용히 통과시켰다(분석기는 평가기가
    /// true 를 주기 때문에, DeepScan 은 `!c.isEmpty` 로 걸러내기 때문에). 이제 같은 이유다.
    public enum PropertyConditionSupport: String, Equatable, Sendable {
        /// 조건 자체가 없다(키 부재 또는 공백뿐) — WE 도 평가하지 않는다.
        /// (`none` 이 아니라 `absent` 인 이유: `Optional.none` 과 이름이 겹치면 `switch` 에서
        ///  어느 쪽인지 읽는 사람이 헷갈린다.)
        case absent
        /// 파서가 정확히 못 읽는다(미지원 문법, 또는 삼항 근사) → 분석기 경고 대상.
        case unsupported
        /// 파스는 정확한데 주어진 값 사전으로는 Bool 이 안 나온다(미정의 키 참조 등).
        case parsedOnly
        /// 파스 + 평가 둘 다 된다.
        case evaluated
    }

    public static func conditionSupport(_ condition: String?,
                                        values: [String: PropertyValue]) -> PropertyConditionSupport {
        guard let condition,
              !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        guard PropertyConditionEvaluator.canEvaluate(condition) else { return .unsupported }
        return PropertyConditionEvaluator.evaluate(condition, values: values) == nil ? .parsedOnly : .evaluated
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
            if conditionSupport(property["condition"] as? String, values: [:]) == .unsupported {
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
                 _ message: String,
                 path: String) {
            guard features.insert(feature).inserted else { return }
            issues.append(WallpaperCompatibilityIssue(
                severity: severity,
                code: code,
                message: message,
                projectID: project.id,
                relativePath: path
            ))
        }

        for source in webFeatureSources(entryPath: fileName, folderURL: folderURL) {
            let text = source.text
            // [2026-08-21 클러스터 BE] **탐지 문자열은 `WebBridgeSignal` 하나가 갖는다.**
            // 종전에는 같은 마커 문자열이 이 루프와 `DeepScan.scanWeb` 두 곳에 리터럴로 박혀
            // 있었고 그래서 개수가 갈렸다(여기 10종 · DeepScan 2종). 문구·등급만 여기서 붙인다.
            // `allCases` 순서 = 선언 순서라 이슈 생성 순서도 결정적이다.
            let signals = WebBridgeSignal.signals(in: text)
            for signal in WebBridgeSignal.allCases where signals.contains(signal) {
                guard let code = signal.issueCode else {
                    features.insert(signal.rawValue)
                    continue
                }
                // F235: 종전엔 features.insert 만 하고 issue 로 승격하지 않아 markdown/JSON 요약·
                // --strict 게이트 어디에도 반영되지 않았다(detectedFeatures 에만 남아 사람이 안 읽는 한
                // 소실). add(...) 로 최소 .warning 승격 — feature 키 자체는 하위호환을 위해 그대로 둔다.
                // F424: relativePath 는 엔트리 fileName 이 아니라 실제 탐지 파일(source.path) —
                // include 된 JS 에서 serviceWorker 등을 탐지한 경우에도 종전엔 경고가 항상
                // index.html 을 가리켰다.
                add(signal.rawValue, code, .warning, signal.issueMessage, path: source.path)
            }
            // **[3차 웨이브 AB] 종전 `https?://` 맨 부분일치는 설치본에서 2/2 전건 거짓 양성이었다.**
            // 잡힌 두 건은 요청이 아니라 (a) 미니파이 라이브러리의 라이선스 배너(`http://greensock.com`
            // — `corsair_o_tron/js/TweenMax.min.js`)와 (b) XML/SVG **네임스페이스 이름**·프레임워크
            // 문서 링크(`http://www.w3.org/2000/svg`, `https://angular.io/docs/...` —
            // `corsair_collection/main.*.js`)였다. 네임스페이스 URI 는 XML Namespaces 규약상
            // **가져오지 않는 식별자**이고, 배너·에러메시지 문자열도 마찬가지다. 두 프로젝트를
            // 실측하면 `corsair_o_tron` 은 `fetch`/`XMLHttpRequest`/`WebSocket`/`EventSource`/
            // `sendBeacon` 이 **한 건도 없다** — 경고 문구("this request")가 가리키는 요청 자체가 없다.
            //
            // 그래서 **요청을 만드는 자리**의 URL 만 본다(아래 `remoteRequestURL`). 도달 실측:
            // 설치본 191 + 동봉 170 프로젝트에서 2건 → **0건**(제거된 2건이 전부 거짓 양성이고
            // 참 양성은 0건이었다). 양성 대조는 픽스처의 `fetch('https://example.invalid/...')` 로
            // 계속 잡힌다(`WallpaperCompatibilityAnalyzerTests.testWebFeatureScanFollowsLocalScripts`).
            //
            // **알려진 한계(고치지 않음)**: URL 이 변수를 거치면(`var u = "https://…"; fetch(u)`)
            // 못 잡는다. 정적 문자열 스캔의 원리적 한계이고, 종전 규칙은 그 대신 모든 문자열을
            // 잡아 정밀도를 0 으로 만들었다.
            //
            // `WebBridgeSignal` 에 넣지 않은 이유: 이 신호만 **값**(찾은 URL)을 문구에 실어야 해서
            // Bool 술어로 환원되지 않는다.
            if let remote = remoteRequestURL(in: text) {
                add("remoteNetwork", .remoteNetworkReference, .warning, "Web wallpaper issues a request to a remote (non-local) URL (\(remote)); Waple's offline WKWebView may block or fail it.", path: source.path)
            }
        }
        return Array(features)
    }

    private static func analyzeSceneFeatures(project: WallpaperProject,
                                             folderURL: URL,
                                             issues: inout [WallpaperCompatibilityIssue]) -> [String] {
        guard project.type == .scene else { return [] }
        // G-E3-01/02 의 **잔여분** — 이 스캐너만 렌더러와 다른 규약을 쓰고 있었다. 이 스캐너의 계약은
        // "이슈 없음 = 렌더 가능" 이므로, 렌더러와 규약이 갈리는 순간 그 보장이 거짓이 된다.
        //
        // ① **마운트 형태.** 렌더러는 `.pkg` 가 없으면 폴더를 그대로 마운트한다(SceneRenderer.swift:1228
        //    `ScenePackage.fromDirectory`). 여기는 `.pkg` 가 없으면 `return []` 로 조용히 빠져나갔다 —
        //    즉 **언팩 씬 프로젝트를 한 건도 검사하지 못했다.** 실측(WE 2.8.42 설치본): 씬 프로젝트
        //    188개가 전부 언팩이고 `.pkg` 는 0개다. 이 스캐너의 씬 분석은 설치본 전건에 대해
        //    "피처 0개·이슈 0개" 를 냈다 — 이슈가 없으니 계약을 어긴 것처럼 안 보이지만, 실제로는
        //    **아무것도 안 본 것**이라 그 침묵에 아무 보장이 없다.
        //
        // ② **씬 문서 이름.** `project.json` 의 `"file"` 이 정한다(SceneDocument.swift:940 —
        //    렌더러가 `project.fileName` 을 그대로 넘긴다, SceneRenderer.swift:1246). 여기만
        //    `scene.json`/`gifscene.json` 을 하드코딩해, 이름이 다른 씬을 "SceneDocument 를 만들 수
        //    없다" 는 `.error` 로 단정할 수 있었다.
        //
        // 둘은 **묶여 있다**: ①만 고치면 이름이 다른 씬들이 비로소 이 경로에 도달해 ②의 거짓 치명
        // 이슈를 정통으로 맞는다. 설치본 실측으로 그 4건이 실재한다 — `ricepod.json`
        // `fantasticcar.json` `techno.json` `audiophile.json`(뒤 둘은 `type` 자체를 생략해서
        // `ProjectJSONParser` 의 확장자 추론으로 `.scene` 이 된다). 그래서 한 커밋에서 같이 고친다.
        //
        // ③ **[3차 웨이브 AB]** 마운트 **선택자**도 렌더러와 같아야 한다. 위 ①을 고칠 때는
        //    `scene.pkg`/`gifscene.pkg` 이름 존재로 골랐는데, 렌더러는 그 뒤(2026-08-21)
        //    `ScenePackage.resolveMountSource` 로 옮겼다. 갈리는 자리는 `analyzeTypeAndFiles` 의
        //    같은 주석에 3종으로 적었다. 여기서도 같은 함수를 부른다.
        let package: ScenePackage
        let sourcePath: String
        switch sceneMountSource(project, folderURL: folderURL) {
        case .package(let packageURL):
            sourcePath = packageURL.lastPathComponent
            do {
                package = try ScenePackage.parse(Data(contentsOf: packageURL))
            } catch {
                issues.append(WallpaperCompatibilityIssue(
                    severity: .error,
                    code: .missingScenePackage,
                    message: "Scene package exists but could not be parsed by Waple: \(error)",
                    projectID: project.id,
                    relativePath: sourcePath
                ))
                return []
            }
        case .directory:
            // 폴더 백엔드는 지연 읽기라 큰 프로젝트도 통째로 메모리에 올리지 않는다
            // (ScenePackage.fromDirectory 주석). 렌더러와 같은 진입점을 쓴다.
            guard let folderPackage = ScenePackage.fromDirectory(folderURL) else {
                // 렌더러도 이 경우 `assetMissing` 으로 실패한다(SceneRenderer.swift:1489) — 다만 폴더에
                // project.json 이라도 있으면 `fromDirectory` 는 nil 이 아니므로 여기 오는 것은 읽을 파일이
                // 하나도 없는 폴더뿐이다. 종전과 같이 조용히 통과시킨다(다른 게이트가 잡는 영역).
                return []
            }
            sourcePath = project.fileName ?? "scene.json"
            package = folderPackage
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

        // 후보 순서를 `SceneDocument.parse` 의 `sceneCandidates` 와 **글자 그대로 같게** 둔다.
        // 둘이 갈리는 순간 위 ②가 그대로 재발한다.
        let sceneCandidates: [String] = [project.fileName, "scene.json", "gifscene.json"].compactMap { $0 }
        guard let sceneData = sceneCandidates.compactMap({ package.data(for: $0) }).first,
              let scene = AssetJSON.dictionary(sceneData) else {
            let candidateList = sceneCandidates.joined(separator: ", ")
            // 같은 프로젝트에 대해 `analyzeTypeAndFiles` 가 이미 같은 코드의 치명 이슈를 냈다면 중복
            // 보고하지 않는다. 그쪽(:314)은 **선언된 메인 파일이 디스크에 있는가**를 보고, 여기는
            // **그 파일이 패키지 조회로 잡히고 유효한 JSON 인가**를 본다 — 파일이 아예 없는 경우에만
            // 두 판정이 겹친다(실측: 언팩 브랜치를 켜기 전에는 겹칠 일이 없어 안 드러났다).
            // 겹칠 때 남길 것은 먼저 나온 쪽이다(더 구체적인 relativePath 를 들고 있다).
            guard !issues.contains(where: { $0.projectID == project.id && $0.code == .missingScenePackage }) else {
                return Array(features)
            }
            // F236: 패키지 자체는 유효하게 파싱됐지만 scene.json/gifscene.json 이 없거나(또는 JSON으로
            // 해석 불가) 실려 있지 않은 경우 — 위 catch(패키지 파싱 자체 실패)와 대칭으로 이슈를 남긴다.
            // SceneDocument 를 구성할 방법이 없어 실제로는 렌더 불가할 개연성이 높은데, 종전엔 이슈
            // 없이 조용히 통과해 "이슈 없음=렌더 가능" 이라는 이 스캐너의 보장이 이 경로에서만 깨졌다.
            issues.append(WallpaperCompatibilityIssue(
                severity: .error,
                code: .missingScenePackage,
                message: "Scene package parsed but contains none of \(candidateList) (or it is not valid JSON) — Waple cannot build a SceneDocument from it.",
                projectID: project.id,
                relativePath: sourcePath
            ))
            return Array(features)
        }
        let sceneText = String(data: sceneData, encoding: .utf8) ?? ""
        if sceneText.contains(#""script""#) { features.insert("sceneScript") }

        features.formUnion(sceneObjectFeatures(from: scene["objects"] as? [Any] ?? []))

        return Array(features)
    }

    /// scene.json の objects 배열에서 키 존재 여부로 feature 태그를 수집(순수 계산).
    private static func sceneObjectFeatures(from objects: [Any]) -> Set<String> {
        var features: Set<String> = []
        for case let object as [String: Any] in objects {
            if object["image"] != nil { features.insert("sceneLayer") }
            if object["particle"] != nil { features.insert("sceneParticle") }
            if object["text"] != nil { features.insert("sceneText") }
            if object["sound"] != nil { features.insert("sceneSound") }
            if object["model"] != nil { features.insert("scene3DModel") }
            if object["light"] != nil { features.insert("sceneLight") }
            if object["effects"] != nil { features.insert("sceneEffect") }
        }
        return features
    }

    /// 씬 마운트 결정 — **렌더러와 같은 함수 하나**(`SceneRenderer.swift:1454` 와 동형 호출).
    /// 인자 셋을 여기서 한 번만 조립해, 두 소비처(`analyzeTypeAndFiles`·`analyzeSceneFeatures`)가
    /// 서로 다른 결정을 내리는 것을 구조적으로 막는다.
    private static func sceneMountSource(_ project: WallpaperProject, folderURL: URL) -> SceneMountSource {
        ScenePackage.resolveMountSource(folderURL: folderURL,
                                        fileName: project.fileName,
                                        hasDependency: project.dependency != nil)
    }

    private struct WebFeatureSource {
        let text: String
        let path: String   // 프로젝트 루트 기준 정규화 상대 경로 — F424: 경고의 relativePath 로 사용
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
            sources.append(WebFeatureSource(text: text, path: normalized))

            for reference in localWebReferences(in: text, basePath: normalized) {
                guard !seen.contains(reference), queue.count + sources.count < maxFiles else { continue }
                queue.append(reference)
            }
        }

        return sources
    }

    /// **요청을 만드는 자리**에 놓인 원격 URL 하나(없으면 nil).
    ///
    /// 각 패턴은 "브라우저가 실제로 네트워크 로드를 시작하는 문법"에 대응한다:
    ///   1. HTML 속성 / JS 프로퍼티 대입 — `<img src=…>` `<link href=…>` `el.src = "…"`
    ///   2. 요청 API 의 첫 인자 — `fetch(…)` `importScripts(…)` `new Worker(…)` `new WebSocket(…)`
    ///      `new EventSource(…)` `navigator.sendBeacon(…)` 동적 `import(…)` `require(…)`
    ///   3. `XMLHttpRequest.open(method, url)` — URL 이 **둘째** 인자다
    ///   4. ES 모듈 정적 import — `import x from "…"`
    ///   5. CSS `url(…)` / `@import "…"`
    /// 반환값은 경고 문구에 그대로 실어, 사람이 오탐 여부를 바로 판별할 수 있게 한다.
    private static let remoteRequestPatterns: [String] = [
        #"(?:src|href|srcset|poster|action)\s*=\s*["']?(https?://[^\s"'<>)]+)"#,
        #"\b(?:fetch|importScripts|Worker|SharedWorker|WebSocket|EventSource|sendBeacon|import|require)\s*\(\s*["'](https?://[^"']+)["']"#,
        #"\.open\s*\(\s*["'][A-Za-z]+["']\s*,\s*["'](https?://[^"']+)["']"#,
        #"\bfrom\s+["'](https?://[^"']+)["']"#,
        #"url\(\s*["']?(https?://[^)"']+)"#,
        #"@import\s+["'](https?://[^"']+)["']"#,
    ]

    static func remoteRequestURL(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in remoteRequestPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let hit = Range(match.range(at: 1), in: text) else { continue }
            return String(text[hit].prefix(120))
        }
        return nil
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
              let object = AssetJSON.dictionary(data) else {
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
        let rootURL = root.standardizedFileURL
        var current = rootURL
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
            current = match.standardizedFileURL
            // F237: containedFileURL 과 동일한 논리 재검증 — 컴포넌트를 하나씩 실제 디렉터리 목록에서
            // 골라 내려가므로 그 자체로는 탈출하지 않지만, 중간 디렉터리가 심볼릭 링크로 바뀌어 있으면
            // 다음 nameOfContentsOfDirectory 가 루트 밖을 나열할 수 있다 — 매 스텝 즉시 방어.
            guard WallpaperPathSecurity.contains(current, in: rootURL) else { return nil }
        }
        // 최종 결과도 containedFileURL 과 동일하게 realpath 기준 재검증(심링크 경유 탈출 차단).
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let realCurrent = current.resolvingSymlinksInPath().standardizedFileURL
        guard WallpaperPathSecurity.contains(realCurrent, in: realRoot) else { return nil }
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
