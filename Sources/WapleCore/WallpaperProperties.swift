import Foundation

public enum PropertyValue: Equatable, Hashable, Sendable {   // 페이로드 String/Bool/Double — 값 타입
    case string(String)
    case bool(Bool)
    case number(Double)
    case none
}

public struct WallpaperProperty: Equatable {
    public struct Option: Equatable {
        public let label: String
        public let value: PropertyValue
        public init(label: String, value: PropertyValue) { self.label = label; self.value = value }
    }

    public let key: String
    public let type: String
    public var value: PropertyValue
    public let order: Double?
    public let condition: String?
    // 편집 UI 메타(project.json 원문): 라벨/슬라이더 범위/콤보 옵션.
    public var text: String? = nil
    public var min: Double? = nil
    public var max: Double? = nil
    public var step: Double? = nil
    public var options: [Option]? = nil
    public var index: Int? = nil
    public var mode: String? = nil
    public var fileType: String? = nil

    public init(key: String, type: String, value: PropertyValue, order: Double?, condition: String?,
                text: String? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                options: [Option]? = nil, index: Int? = nil, mode: String? = nil, fileType: String? = nil) {
        self.key = key
        self.type = type
        self.value = value
        self.order = order
        self.condition = condition
        self.text = text
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.index = index
        self.mode = mode
        self.fileType = fileType
    }
}

/// `project.json` 의 `general.properties` 파서.
///
/// # 타입 전수 (2026-08-21 클러스터 AF — 실물 두 소스로 교차 확정)
///
/// **브라우저가 그릴 줄 아는 타입 12 + 컨테이너 `group`.** 템플릿
/// `views/includes/browseruserproperties.html`(scripts.js char@750151–757383)의
/// `ng-if="property.type==='…'"` 분기를 전수로 읽으면 이 열둘이다:
/// `color` · `bool` · `textinput` · `slider` · `volume` · `combo` · `combolutfilters` ·
/// `directory` · `file` · `scenetexture` · `usershortcut` · `divider`.
/// `group` 은 템플릿 밖 — 목록 빌더가 `"group"===l.type` 일 때 **새 그룹 컨테이너를 열고**
/// 그 프로퍼티 자신은 `browseruserpropertiesgroup.html`(제목 + 접기)로 그린다(char@88480).
///
/// **에디터가 저작하게 해 주는 타입 10**(`EditorUserPropertyDetailsModalCtrl` 의 `typeOptions`,
/// char@617200–618900) — 프로젝트 종류로 갈린다:
/// ```
/// scene   프로젝트: color slider bool combo textinput scenetexture usershortcut group
/// 그 외   프로젝트: color slider bool combo textinput directory    file         group
/// ```
/// 합집합 10. 브라우저의 12 중 **`volume` · `combolutfilters` · `divider` 는 저작 불가**다 —
/// 셋 다 **엔진이 주입**한다(`wallpaper64.exe` 0x140104b60: `volume`/`rate` 슬라이더,
/// `wcc_v` = `combolutfilters`; `divider` 는 0x14010c650 이 키 `_d0` 로 심는다 — 같은 함수가
/// `audioprocessing`(bool)과 `schemecolor`(color, 기본 `"0.5 0.5 0.5"`)도 심는다). 즉 워크샵 `project.json` 에서
/// 나올 수 있는 타입은 위 10 이 상한이다.
/// 로케일이 그대로 확증한다(`locale/ui_en-us.json`): `ui_editor_user_properties_type_color` =
/// "Color" · `_slider` = "Slider" · `_bool` = **"Checkbox"** · `_combo` = "Combo" ·
/// `_textinput` = **"Text"** · `_directory` = "Directory" · `_file` = "File" ·
/// `_scenetexture` = **"Texture"** · `_usershortcut` = "User shortcut" · `_group` = "Group".
/// `volume`/`combolutfilters`/`divider` 라벨은 **없다**.
///
/// # 타입별 키와 **기본값 규칙**
///
/// 저작 시 타입을 바꾸면 에디터가 이 함수를 돌린다(char@616842, 원문 그대로):
/// ```js
/// delete min, max, mode, options, step, precision, fraction;
/// switch (type) {
///   default:          value = "";                                            // textinput/file/scenetexture/usershortcut
///   case "directory": value = "", mode = "ondemand";
///   case "color":     value = "1 0 0";
///   case "slider":    value = 1, min = 0, max = 1, fraction = true, precision = 1;
///   case "bool":      value = true;
///   case "combo":     options = [], value = undefined;
/// }
/// ```
/// 저장(`ok()`, char@619685) 규칙:
/// - `precision` 은 **로드 시 −1, 저장 시 +1** 된다 → **파일의 `precision` 은 UI 의 "Decimal
///   Places"(`ui_editor_user_properties_precision`)보다 1 크다.**
/// - `slider` + `fraction` 이면 `precision` 을 1..4 로 클램프하고
///   `step = (precision == 1) ? 1 : 0.1^(precision-1)` 을 **파생**한다.
///   `fraction` 이 거짓이면 `step`·`precision` 을 **지운다**(정수 슬라이더).
/// - 슬라이더가 아니면 `step`·`precision`·`fraction` 셋 다 지운다.
/// - `combo` 는 `options` 가 비면 저장 자체가 막히고(`isOkDisabled`), `value` 가 어느 옵션과도
///   맞지 않으면 **`options[0].value` 로 강제**된다.
/// - `key` 는 `toLowerCase().replace(/\W+/g,"")` 로 정규화되고, 숫자로 시작하면 `_` 를 붙이며,
///   비면 `"newproperty"` 가 된다.
/// - `file`/`directory` 는 `fileType` ∈ {`image`,`video`}, `directory` 는 추가로
///   `mode` ∈ {`ondemand`,`fetchall`}.
///
/// 브라우저 렌더 기본값(위와 별개 — 파일에 없을 때 UI 가 쓰는 값):
/// rzslider 가 `step: property.step||1` · `precision: property.precision||1` 로 폴백하고
/// (char@751619) `floor/ceil` 은 `min`/`max` 를 그대로 쓴다.
///
/// `value` 의 이름이 **"Default Value"** 라는 것도 로케일이 못박는다
/// (`ui_editor_user_properties_value`) — 즉 `project.json` 의 `value` 는 **기본값**이고
/// 유저 오버라이드는 다른 곳에 산다(`applying(overrides:to:)` 가 그 합성이다).
///
/// # 설치본 코퍼스 도달 (WE 설치본 `project.json` 191개 · JSON 2,143개 전수 워크)
/// ```
/// general.properties 를 가진 파일 180 / 프로퍼티 241개
///   color   203   키: type·text·value 203/203 · order 182 · condition 4 · index 3 · shadername 2
///   slider   17   키: type·text·value·order·min·max 17/17 · precision 9 · step 9 · fraction 6
///                      · condition 4 · editable 3 · index 2
///   combo    14   키: type·text·value·options 14/14 · order 13 · condition 7 · index 1
///   bool      7   키: type·text·value·order 7/7 · condition 2
///   value 의 JSON 타입: color 전건 문자열 · combo 전건 문자열 · bool {bool 6, 문자열 1}
///                        · slider {int 15, float 1, 문자열 1}
///   options 원소 키는 {label, value} 둘뿐(53쌍)
/// ```
/// **`textinput`·`file`·`directory`·`scenetexture`·`usershortcut`·`group`·`divider`·`volume`·
/// `combolutfilters` 는 설치본 도달 0 이다.** 동봉 트리(`Sources/WapleRender/Resources/WEAssets`)는
/// 프로퍼티 161개가 **전부 `color`** 다. `general.properties` 가 아닌 다른 `properties` 맵에서
/// 나오는 프로퍼티도 **0건**이다(2,143 JSON 전수 워크에서 241/241 이 `/general/properties` 밑).
///
/// **이 파서가 아직 안 읽는 키**(전부 편집 UI 메타, 런타임 값과 무관):
/// `precision`(9) · `fraction`(6) · `editable`(3) · `shadername`(2) · `icon`(0) ·
/// `disabledcondition`(0). 소비처(`PropertyEditorView`)가 생기기 전에는 담을 이유가 없어
/// 두었다 — 담게 되면 위 "저장 규칙" 의 `precision` ±1 규약을 같이 옮겨야 한다.
///
/// **정렬은 실물과 다르다(의도적).** 브라우저는 `i.sort((e,t) => e.order - t.order)` 하나뿐이라
/// (char@88420) `order` 가 없는 프로퍼티는 비교값이 `NaN` 이 되어 V8 TimSort 의 삽입 순서로
/// 흘러간다. 여기서는 `order` 부재를 **맨 뒤 + key 오름차순**으로 결정화한다. 설치본에서
/// `order` 부재는 color 21 · combo 1 = 22건이다. 한편 에디터의 프로퍼티 목록은 현대 판에서
/// **`order` 를 지우고 `index` 를 0부터 다시 매긴다**(char@503002
/// `delete e.order, e.index = t, ++t`) — 그런데 **브라우저는 `index` 를 정렬에 쓰지 않는다.**
/// 두 키가 어떻게 화해하는지는 [미해결]이다.
public enum WallpaperProperties {
    public static func parse(generalProperties: [String: Any]) -> [WallpaperProperty] {
        parse(generalProperties: generalProperties, localization: nil)
    }

    public static func parse(generalProperties: [String: Any],
                             localization: [String: Any]?,
                             localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.current.identifier) -> [WallpaperProperty] {
        let localized = localizationTable(localization, localeIdentifier: localeIdentifier)
        var result: [WallpaperProperty] = []
        for (key, raw) in generalProperties {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? ""
            var options: [WallpaperProperty.Option]? = nil
            if let opts = dict["options"] as? [[String: Any]] {
                options = opts.map { WallpaperProperty.Option(label: localizedString(($0["label"] as? String) ?? "", table: localized) ?? "",
                                                              value: parseValue($0["value"], type: type)) }
            }
            result.append(WallpaperProperty(
                key: key,
                type: type,
                value: parseValue(dict["value"], type: type),
                order: parseNumber(dict["order"]),
                condition: dict["condition"] as? String,
                text: localizedString(dict["text"] as? String, table: localized),
                min: parseNumber(dict["min"]), max: parseNumber(dict["max"]), step: parseNumber(dict["step"]),
                options: options,
                index: parseInt(dict["index"]),
                mode: dict["mode"] as? String,
                fileType: dict["fileType"] as? String
            ))
        }
        return result.sorted {
            ($0.order ?? Double.greatestFiniteMagnitude, $0.key) < ($1.order ?? Double.greatestFiniteMagnitude, $1.key)
        }
    }

    private static func parseValue(_ raw: Any?, type: String) -> PropertyValue {
        switch type.lowercased() {
        case "bool", "checkbox":
            // WE project.json 은 종종 bool 을 문자열로 싣는다("1"/"true") — 네이티브 Bool 경로(무회귀)
            // 다음에만 문자열을 관용 파스. 숫자 NSNumber(0/1)의 as? Bool 둔갑은 기존 동작 그대로 보존.
            if let b = raw as? Bool { return .bool(b) }
            if let s = raw as? String { return .bool(s == "true" || (lenientFloat(s) ?? 0) != 0) }
            return .bool(false)
        case "slider":
            // 마찬가지로 문자열 숫자("0.5") 관용 — parseNumber(무회귀, Double 정밀도 보존) 우선 시도 후
            // 실패(비숫자·String)할 때만 lenientFloat 폴백. lenientFloat(raw) 를 바로 쓰지 않는 이유:
            // NSNumber(bool) 이 Swift 에서 `as? Double` 로도 브리지되어(1.0/0.0) parseNumber 의 CFBoolean
            // 배제를 무력화한다 — 문자열로 이미 좁힌 값에만 적용해 그 함정을 피한다.
            if let n = parseNumber(raw) { return .number(n) }
            if let s = raw as? String, let f = lenientFloat(s) { return .number(Double(f)) }
            return .number(0)
        default:
            // JSONSerialization 의 NSNumber(0/1)은 `as? Bool`도 성공한다. parseNumber가
            // CFBoolean을 명시적으로 배제하므로 숫자를 먼저 가르면 원래 JSON 타입 태그가
            // 보존된다. 특히 combo 기본값/option tag가 .bool로 오타입되면 숫자 preset
            // override(.number)와 달라져 SwiftUI Picker가 무선택 상태가 된다.
            if let s = raw as? String { return .string(s) }
            if let n = parseNumber(raw) { return .number(n) }
            if let b = raw as? Bool { return .bool(b) }
            return .none
        }
    }

    private static func parseNumber(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let n = raw as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.intValue
        }
        if let i = raw as? Int { return i }
        // F530-sweep: project.json 은 신뢰 경계 밖이다 — `{"value": 1e300}` 하나로
        // 맨 `Int(d)` 가 트랩했다. 이 자리는 스윕 6단계가 전부 놓쳤고
        // scripts/spec/check_int_narrowing.py 의 R1 이 잡아냈다.
        if let d = raw as? Double { return safeInt(d) }
        return nil
    }

    public static func parse(folderURL: URL) throws -> [WallpaperProperty] {
        let url = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { throw ProjectParseError.fileNotFound }
        guard let obj = AssetJSON.dictionary(data) else {
            throw ProjectParseError.invalidJSON
        }
        let generalObject = obj["general"] as? [String: Any]
        let general = generalObject?["properties"] as? [String: Any] ?? [:]
        let localization = generalObject?["localization"] as? [String: Any]
        return parse(generalProperties: general, localization: localization)
    }

    /// 유저 오버라이드를 기본값 위에 병합한 효과값 목록(순수).
    public static func applying(overrides: [String: PropertyValue], to props: [WallpaperProperty]) -> [WallpaperProperty] {
        props.map { p in
            guard let o = overrides[p.key] else { return p }
            var out = p
            out.value = o
            return out
        }
    }

    public static func weUserPropertiesJSON(_ props: [WallpaperProperty]) -> String {
        var dict: [String: Any] = [:]
        for p in props {
            var inner: [String: Any] = ["type": p.type]
            switch p.value {
            case .string(let s): inner["value"] = s
            case .bool(let b):   inner["value"] = b
            case .number(let n): inner["value"] = n
            case .none:          break
            }
            dict[p.key] = inner
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func localizationTable(_ localization: [String: Any]?,
                                          localeIdentifier: String) -> [String: String] {
        guard let localization else { return [:] }
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let language = normalized.split(separator: "-").first.map(String.init)
        let candidates = [
            normalized,
            language,
            "en-us",
            "en"
        ].compactMap { $0 }

        for candidate in candidates {
            if let table = exactLocalizationTable(localization, key: candidate) { return table }
            // r3-O7: `Dictionary.keys` 는 순서 비보장이라 같은 언어의 지역 표가 둘 이상이면
            // (예: `ko-kr` 과 `ko-kp`) 실행마다 다른 표가 뽑힐 수 있었다. 아래 최종 폴백이 이미
            // `keys.sorted()` 를 쓰므로 같은 규약으로 맞춘다 — 선택 자체는 여전히 임의지만
            // **결정적**이다(같은 입력 → 같은 표).
            if candidate.count == 2,
               let key = localization.keys.sorted().first(where: { $0.lowercased().hasPrefix(candidate + "-") }),
               let table = exactLocalizationTable(localization, key: key) {
                return table
            }
        }

        for key in localization.keys.sorted() {
            if let table = exactLocalizationTable(localization, key: key) { return table }
        }
        return [:]
    }

    private static func exactLocalizationTable(_ localization: [String: Any], key: String) -> [String: String]? {
        guard let raw = localization.first(where: { $0.key.lowercased() == key.lowercased() })?.value as? [String: Any] else {
            return nil
        }
        return raw.reduce(into: [String: String]()) { out, pair in
            if let value = pair.value as? String { out[pair.key] = value }
        }
    }

    private static func localizedString(_ raw: String?, table: [String: String]) -> String? {
        guard let raw else { return nil }
        return table[raw] ?? raw
    }
}
