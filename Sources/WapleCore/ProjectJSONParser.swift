import Foundation

public enum ProjectParseError: Error, Equatable {
    case fileNotFound
    case invalidJSON
}

public enum ProjectJSONParser {
    public static func parse(folderURL: URL) throws -> WallpaperProject {
        let projectURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL) else {
            throw ProjectParseError.fileNotFound
        }
        return try parse(data: data, folderURL: folderURL)
    }

    public static func parse(data: Data, folderURL: URL) throws -> WallpaperProject {
        guard let obj = AssetJSON.dictionary(data) else {
            throw ProjectParseError.invalidJSON
        }
        return parse(json: obj, folderURL: folderURL)
    }

    /// F231: project.json 을 호출자가 이미 별도 목적(예: WallpaperCompatibilityAnalyzer 의 raw 필드
    /// 검사)으로 파싱해 `[String: Any]` 를 들고 있을 때 파일을 다시 읽고 다시 JSON 파싱하지 않도록 하는
    /// 진입점. `obj` 는 이미 유효한 JSON 오브젝트임이 보장되므로(호출자가 그 자체로 얻었음) throws 가
    /// 필요 없다 — 파싱 실패 가능성은 위 `parse(data:folderURL:)` 의 guard 에서만 발생한다.
    public static func parse(json obj: [String: Any], folderURL: URL) -> WallpaperProject {
        // F194: 폴더 basename 은 관리 위치 이동·zip 재래핑(임포트 관례상 `Wallpaper/` 등 비유일 래퍼명)에
        // 안정적이지 않다. project.json 이 워크샵 id 를 선언하면(전역 유일) identity 로 우선 채택하고,
        // 없을 때만 종전대로 폴더명에 폴백한다 — steamcmd 코퍼스는 폴더명 자체가 워크샵 id 라 무변화.
        let workshopId = parseStringOrNumber(obj["workshopid"])
        let id = workshopId ?? folderURL.lastPathComponent
        var type = WallpaperType.from(obj["type"] as? String)
        // G-E3-03: `type` 은 **선택** 키다. WE 2.8.42 설치본 실측: project.json 21개 중 5개가 type 을
        // 생략한다 — `sheep`(sheep.exe, application) `techno`/`audiophile`(*.json, scene)
        // `templates/gif`(gifscene.json) `templates/flag`(scene.json). 워크샵 코퍼스에도 1건 있다.
        // `WallpaperType.from(nil)` 이 `.preset` 을 내는 것 자체는 옳다(진짜 프리셋 폴더는 type 이
        // 비는 게 관례) — 문제는 그 뒤 RendererFactory 가 `.preset` 에서 렌더러를 만들지 못해
        // "라이브러리엔 보이는데 적용하면 아무것도 안 뜨는" 상태가 된다는 것이다. `preset`/
        // `dependency` 가 없으면 진짜 프리셋이 아니므로 확장자로 추론한다. 두 키 가드가 프리셋
        // 오분류를 막는다(무회귀).
        //
        // [2026-08-21 — docs/re/package-format.md §5.3·§7.2] 실물 분류기 `0x14011e520` 은 확장자를
        // 소문자로 뽑아(`0x140053f80` + 바이트별 ASCII `tolower` `0x140054262`–`0x140054276`)
        // `.rdata` 의 표들과 순서대로 `memcmp` 한다. 1번 표 `0x140483850` 이 **`.json` `.pkg` `.gif`
        // 세 개**를 담고 셋 다 **1 = Scene** 으로 간다(`0x14011e673` 색인, `0x14011e7a5` 매치).
        // 종전 표에는 `pkg`/`gif` 가 없어서 `type` 을 생략한 채 `file:"scene.pkg"` 를 쓰는 프로젝트가
        // `.preset` 으로 남았고 — 그건 위 문단이 말한 바로 그 "라이브러리엔 보이는데 적용하면
        // 아무것도 안 뜨는" 상태다. 두 확장자를 1번 표대로 채운다.
        //
        // **의도적으로 안 맞춘 것 4건**(전부 설치본+동봉 361건 도달 0건 — `file` 확장자는
        // `.json` 358 · `.html` 2 · `.exe` 1 이 전부다):
        //   · 4번 표 `0x140483810` 은 `.mp4 .wmv .avi .m4v .mov .webm .mkv` 7개인데 여기는
        //     `VideoFormats.nativeExtensions`(= `mp4 m4v mov`) 3개다. 넓히면 **분류 축과 재생 축이
        //     섞인다** — AVFoundation 이 못 여는 `wmv`/`mkv` 를 `.video` 로 분류해 VideoRenderer 로
        //     보내는 셈이고, 실패 지점만 뒤로 밀린다. 분류용 집합을 따로 두는 게 옳은 수선이나
        //     `VideoFormats` 는 이 과제 소유가 아니다. `[미해결]`
        //   · 6번 표 `0x1404837e0`(`.png .bmp .jpeg .jpg .jfif`)은 enum 값 5 로 가는데, WE 자신도
        //     5 를 캐논 문자열로 옮기지 못해 `Unknown` 으로 출력한다(`0x14011e864`→`0x14011e2e9`).
        //     `.preset` 으로 남기는 현행과 실질 차이가 없다.
        //   · 5번(문자열이 `http://`·`https://` 로 시작 → Web, `0x140018980`)은
        //     `WallpaperPathSecurity` 가 URL 스킴을 애초에 거부하므로 `fileName` 이 nil 이 된다.
        //   · `.htm` 은 WE 표에 **없다**(1번~4번 어디에도). Waple 이 더 관대한 쪽이라 그대로 둔다.
        //
        // **`type` 을 먼저 읽는 것 자체가 WE 와 다르다**(§5.1: WE 는 `type` 을 입력으로 쓰지 않고
        // 유도 결과로 **덮어쓴다** — `0x14011e300`). 곧 WE 는 `{"type":"video","file":"scene.json"}`
        // 을 Scene 으로 본다. 여기를 맞추면 `type` 에 의존해 분류돼 있는 워크샵 코퍼스 전체의
        // 분류가 바뀌므로 **별도 판단으로 남긴다**. `[미해결]`
        if type == .preset, obj["preset"] == nil, obj["dependency"] == nil,
           let file = obj["file"] as? String {
            switch (file as NSString).pathExtension.lowercased() {
            case "json", "pkg", "gif": type = .scene
            case "html", "htm": type = .web
            case "exe": type = .application
            case let ext where VideoFormats.nativeExtensions.contains(ext): type = .video
            default: break
            }
        }
        let rawTitle = obj["title"] as? String
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : id
        let tags = (obj["tags"] as? [String]) ?? []
        let presetOverrides = parsePresetOverrides(obj["preset"])
        return WallpaperProject(
            id: id,
            type: type,
            fileName: WallpaperPathSecurity.normalizedRelativePath(obj["file"] as? String),
            previewName: WallpaperPathSecurity.normalizedRelativePath(obj["preview"] as? String),
            title: title,
            tags: tags,
            contentRating: obj["contentrating"] as? String,
            workshopId: workshopId,
            dependency: WallpaperPathSecurity.normalizedPathComponent(obj["dependency"] as? String),
            folderURL: folderURL,
            presetOverrides: presetOverrides,
            presetFolderURL: type == .preset ? folderURL : nil,
            supportsAudioProcessing: parseSupportsAudioProcessing(obj)
        )
    }

    /// `general.supportsaudioprocessing` — 오디오 반응 지원 선언(bool).
    ///
    /// 원본은 `CProject::SupportsAudioProcessing`(0x14010d100–0x14010d161) 한 함수로 읽고,
    /// 그 결과가 오디오 파이프라인 전체의 마스터 게이트다(WallpaperProject.supportsAudioProcessing
    /// 주석에 소비처 VA 를 적어 뒀다). 원본 절차를 그대로 옮긴다:
    ///
    ///     0x14010d104  add rcx, 0x10            ; project.json 루트
    ///     0x14010d116  call ...                 ; root["general"]
    ///     0x14010d11b  cmp byte [rax+8], 7      ; jsoncpp objectValue 가 아니면 → false
    ///     0x14010d132  call Json::Value::find   ; general["supportsaudioprocessing"]
    ///     0x14010d141  cmp byte [rax+8], 5      ; jsoncpp booleanValue 가 아니면 → false
    ///     0x14010d14a  call ...asBool           ; 그제야 값을 쓴다
    ///
    /// **타입 엄격성이 요점이다.** 0x14010d141 은 태그 5(booleanValue)만 통과시킨다 — jsoncpp 는
    /// `1`/`"true"` 를 각각 태그 1/4 로 들고 있으므로 원본에선 둘 다 false 다. Foundation 의
    /// `JSONSerialization` 은 숫자와 불리언을 똑같이 `NSNumber` 로 주고 `1 as? Bool` 이 true 로
    /// 성공하므로, 맨 `as? Bool` 로 받으면 `{"supportsaudioprocessing": 1}` 이 원본과 반대로
    /// 갈린다. `EffectManifest.isJSONBool` 이 이미 이 구분을 하고 있어 그대로 재사용한다.
    ///
    /// `general` 이 object 가 아니거나(0x14010d11b) 키가 없으면 false — WE 의 기본값이 false 다.
    private static func parseSupportsAudioProcessing(_ obj: [String: Any]) -> Bool {
        guard let general = obj["general"] as? [String: Any] else { return false }
        let raw = general["supportsaudioprocessing"]
        guard EffectManifest.isJSONBool(raw) else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    private static func parsePresetOverrides(_ value: Any?) -> [String: PropertyValue] {
        guard let raw = value as? [String: Any] else { return [:] }
        var out: [String: PropertyValue] = [:]
        for (key, value) in raw {
            if value is NSNull { continue }
            // parseNumber는 CFBoolean을 배제하므로 숫자 검사를 먼저 — NSNumber(0/1)의 as? Bool 둔갑 방지
            if let number = parseNumber(value) {
                out[key] = .number(number)
            } else if let bool = value as? Bool {
                out[key] = .bool(bool)
            } else if let string = value as? String {
                out[key] = .string(string)
            }
        }
        return out
    }

    private static func parseNumber(_ value: Any) -> Double? {
        // CFBoolean 선배제 — 아래 as Double/Int 브리징이 CFBoolean도 1.0/0.0 으로 통과시키므로
        // NSNumber 케이스의 where 만으론 불충분(JSON true 가 number 로 둔갑).
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }

    private static func parseStringOrNumber(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }
}
