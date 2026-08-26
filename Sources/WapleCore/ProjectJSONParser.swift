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
            supportsAudioProcessing: parseSupportsAudioProcessing(obj),
            playbackProperties: parsePlaybackProperties(obj)
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

    /// WE 재생정책 여섯 키(`general.properties.<키>.value`)의 문자열 값을 수집한다.
    ///
    /// 키 목록은 `analysis/strings/json-keys.txt:409-414`(playbackfocus/maximized/fullscreen/
    /// onbattery/sleep/audio)와 정본 spec/engine/playback-policy.json 의 `playbackPolicy.axes` 가
    /// 확정한다. WapleCore 는 WaplePolicy 를 import 할 수 없어(Package.swift 경고 — 리눅스
    /// `no such module 'simd'`) 이 모듈 안에서 리터럴로 두고, 양쪽의 일치는 앱 측 테스트가
    /// PlaybackTrigger.allCases 의 weConfigKey 와 대조해 감시한다.
    ///
    /// 수집 규칙:
    /// - **값이 비어 있거나(빈 문자열) 문자열이 아니면 부재로 본다.** WE 는 월페이퍼별 속성을 ""
    ///   기본값으로 주입해 "전역 설정 따름"을 뜻하게 한다(FUN_140046ff0 →
    ///   FUN_140086eb0(param_1,"playbackfocus","") — analysis/decompiled/all/0000000140046ff0).
    ///   Waple 에는 전역 정책면이 아직 없으므로 빈 값 ≡ 부재다. 숫자·불리언 value 도 WE 의
    ///   저장 형식(콤보 문자열)과 어긋나므로 받지 않는다 — 매퍼 포트가 기대하는 입력은
    ///   config.json `general/user` 와 같은 `[String: String]` 이다
    ///   (PlaybackPolicy.init(weConfig:) 서명).
    /// - **부재 키는 딕셔너리에 넣지 않는다** — 소비자(PlaybackPolicyGate)의 "부재 = run"
    ///   무회귀 계약이 판정의 단일 지점을 갖게 하기 위해서다.
    private static func parsePlaybackProperties(_ obj: [String: Any]) -> [String: String] {
        guard let properties = (obj["general"] as? [String: Any])?["properties"] as? [String: Any] else {
            return [:]
        }
        let playbackKeys = [
            "playbackfocus", "playbackmaximized", "playbackfullscreen",
            "playbackaudio", "playbacksleep", "playbackonbattery",
        ]
        var out: [String: String] = [:]
        for key in playbackKeys {
            guard let prop = properties[key] as? [String: Any],
                  let value = prop["value"] as? String,
                  !value.isEmpty else { continue }
            out[key] = value
        }
        return out
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

    /// `workshopid` 전용 — 문자열이면 그대로, 수면 문자열로. **공백뿐인 문자열은 부재로 본다.**
    ///
    /// 빈 문자열을 통과시키면 안 되는 이유는 두 겹이다.
    ///  1. 이 값이 곧 `WallpaperProject.id` 이고(`workshopId ?? folderURL.lastPathComponent`),
    ///     `title` 의 폴백도 그 id 다 — `{"workshopid":""}` 하나로 id 와 title 이 **둘 다 빈 문자열**이 된다.
    ///  2. 더 나쁜 것은 `LibraryStore.importExtractedZipCounting` 이
    ///     `let hasStableId = parsed?.workshopId != nil` 로 "전역 유일 식별자가 선언됐다 =
    ///     같은 배경의 재가져오기다" 를 판정하고, 참이면 **이미 있는 관리 폴더를 지우고 덮어쓴다**는
    ///     점이다. 빈 문자열이 non-nil 로 통과하면 서로 다른 배경 두 개가(WE export 관례상 래퍼
    ///     폴더명은 `Wallpaper/` 로 비유일이다) **무통지로 서로를 덮어쓴다** — F247·F581 이
    ///     막으려던 바로 그 손실이다. 관리 폴더명 쪽은 `normalizedPathComponent("")` 가 nil 을 내
    ///     이미 폴더명으로 폴백하지만, 그 폴백이 오히려 "빈 id + 비유일 폴더명" 조합을 만든다.
    ///
    /// 실물에서 이 키가 채워지는 경로는 `strtoull` 결과를 심는 것뿐이라(docs/re/package-format.md
    /// §5.4 — `0x14010aadf` strtoull → `0x14010ab27` `json["workshopid"] = <수>`) 빈 문자열이
    /// 나올 수 없다. 빈 값은 손편집·내보내기 도구에서만 온다. **설치본 191건 도달 0**
    /// (`workshopid` 키 자체가 0건 — `ProjectJSONInstallCorpusTests` 가 그 도수를 고정한다).
    ///
    /// 공백 제거는 **하지 않는다**. `" 123 "` 은 빈 값과 달리 유일·안정하므로 위 손실 경로가 없고,
    /// 원문을 말없이 바꾸는 쪽이 오히려 id 드리프트를 만든다.
    private static func parseStringOrNumber(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // `NSNumber.stringValue` 의 **형식**은 Foundation 구현마다 다를 수 있다(정수 태그는
        // 양쪽 다 자릿수 그대로지만, `{"workshopid":1108426854.0}` 처럼 실수 태그로 오면
        // swift-corelibs 는 `"1108426854.0"` 을 낸다 — Apple Foundation 값은 이 컨테이너에서
        // 실측할 수 없다). 실수 workshopid 는 설치본 도달 0이고 WE 도 정수로만 심으므로
        // 여기서 형식을 강제하지 않는다. 테스트는 **수치 동등성**만 단언한다. `[미해결]`
        return number.stringValue
    }
}
