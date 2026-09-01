import Foundation

/// Sendable: 저장 프로퍼티가 전부 값 타입(String/URL/배열/딕셔너리 + 아래 두 enum)이다.
/// 명시가 필요한 이유는 **public 타입은 Sendable 이 자동 추론되지 않기 때문**이고, 이게 없으면
/// 프로젝트를 백그라운드로 넘기는 모든 지점(VideoRenderer 의 ffmpeg 변환 완료 콜백,
/// DeepScan.concurrentPerform 의 병렬 스캔)이 "non-Sendable 캡처" 진단을 낸다.
///
/// ~~그리고 모두 `let` 이다.~~ → **정정 [2026-08-26]: `public private(set) var` 로 바꿨다.**
/// 이유는 아래 `with(...)` 주석에 있다(재구성 시 필드를 재나열하지 않기 위해서다).
/// **Sendable 판정은 그대로다** — 값 타입인 구조체는 저장 프로퍼티가 전부 Sendable 이면
/// 충분하고 가변성은 조건이 아니다. 모듈 밖에서 보이는 표면도 그대로 읽기 전용이다
/// (`private(set)` 의 세터는 이 파일 안에서만 보이고, 실제로 쓰는 곳은 `with(...)` 하나뿐이다).
public struct WallpaperProject: Equatable, Sendable {
    public private(set) var id: String          // 폴더명 (워크샵 ID)
    public private(set) var type: WallpaperType
    public private(set) var fileName: String?   // project.json "file"
    public private(set) var previewName: String?// project.json "preview"
    public private(set) var title: String
    public private(set) var tags: [String]
    public private(set) var contentRating: String?
    public private(set) var workshopId: String?
    public private(set) var dependency: String? // 프리셋 전용
    public private(set) var folderURL: URL
    public private(set) var presetOverrides: [String: PropertyValue]
    public private(set) var presetFolderURL: URL?
    /// project.json `general.supportsaudioprocessing`(bool). WE 의 `CProject::SupportsAudioProcessing`
    /// (0x14010d100–0x14010d161) 과 같은 뜻이다 — **벽지가 오디오 반응을 지원한다고 선언**했는가.
    ///
    /// 원본에서 이 한 비트가 오디오 파이프라인 전체의 마스터 게이트다. 세 자리가 이 값만 본다:
    ///  - 0x14010c70c: true 일 때만 `audioprocessing` **유저 프로퍼티를 합성 주입**한다
    ///    (`type`=bool, 기본 `value`=true(0x14010c6c1 `mov r12d,1`), `icon`="fa-microphone",
    ///     `text`="ui_browse_properties_audio_recording", `order`=-1).
    ///  - 0x140114d21: 벽지 런타임 플래그 `[obj+0x1b8]` bit3(0x8) 의 **초기값**을 이 값으로 세운다.
    ///    직후 0x140114e4f 가 유저 프로퍼티 `audioprocessing.value` 로 덮어쓰는데, 그 덮어쓰기도
    ///    이 값이 true 일 때만 일어난다 — 즉 false 면 유저가 무슨 값을 넣어도 bit3 은 항상 0.
    ///  - 0x14006e11a·0x14006e352: 살아 있는 모든 벽지에 대해
    ///    `SupportsAudioProcessing() && wproperties.audioprocessing.value` 를 OR 로 접고,
    ///    그 결과가 바뀔 때만 WASAPI 루프백 캡처를 켜고/끈다(시작 0x1400cf120 —
    ///    "WASAPI processor requires 32 bit per sample." @0x140486660).
    ///
    /// bit3 이 0 이면 프레임 틱(0x140111654 `test byte [r15+0x1b8],8`)이 스펙트럼 취득 블록을
    /// 통째로 건너뛰고, 0→전이 시 0x140115403 이 밴드 버퍼 3개(0x300·0x180·0xc0 =
    /// 64·32·16밴드 × 3채널 × 4바이트)를 0 으로 민다.
    ///
    /// 기본값은 **false** 다 — WE 도 키가 없으면 `general` 이 object(jsoncpp 태그 7)가 아니거나
    /// 값이 bool(태그 5)이 아닌 순간 전부 false 로 떨어뜨린다(0x14010d11b·0x14010d141).
    ///
    /// ## [2026-08-26] 위 VA 세 자리는 **WE 실물의** 소비처다 — Waple 에는 소비처가 아직 없다
    ///
    /// 셈법을 적어 둔다(`7de1021` 기준). `Sources/**` 에서 이 파일과 `ProjectJSONParser.swift`
    /// 를 뺀 뒤 `grep -o "\.<필드>\b"` 로 센 것이다. **일부러 과다 계상하는 셈**이다 —
    /// 다른 타입의 동명 멤버(`.id`·`.type` 은 도처에 있다)까지 세므로 상한이고, 그래서
    /// 결과가 0 이면 더 강한 증거다:
    ///
    /// `id` 272 · `type` 99 · `title` 56 · `fileName` 37 · `folderURL` 19 · `tags` 20 ·
    /// `contentRating` 9 · `previewName` 8 · `dependency` 8 · `presetOverrides` 5 ·
    /// `presetFolderURL` 4 · `workshopId` 3 ·
    /// **`supportsAudioProcessing` 0** · **`playbackProperties` 0**.
    ///
    /// 같은 커밋의 `Tests/**` 참조는 `supportsAudioProcessing` 9건 · `playbackProperties` 0건이고,
    /// 그 9건은 전부 파서(`ProjectJSONParserTests`·`ProjectJSONInstallCorpusTests`)를 겨눈다.
    ///
    /// 그래서 **Waple 은 WE 가 선언한 이 마스터 게이트를 존중하지 않는다**(아래 「처분」 —
    /// 미완이 아니라 결정이다). 실제 오디오 기동은 `SceneRenderer.hasAudio` 가 쥐고 있고,
    /// 그 값은 **씬 내용 검사에서 유도**된다 —
    /// 스크립트가 오디오를 참조하면 승격(`SceneRenderer.scriptWantsAudio(_:)`), 오디오 레이어·
    /// 이미터가 있으면 승격(`SceneRendererResources.swift` 의 `hasAudio = true` 세 자리).
    /// 프로젝트의 선언은 어느 경로에서도 읽지 않는다. 즉 `supportsaudioprocessing: false` 인
    /// 벽지도 스크립트가 오디오를 만지면 Waple 에서는 캡처가 돈다(원본이라면 안 돈다 —
    /// 위 0x140114d21 이 bit3 을 0 으로 고정한다).
    ///
    /// ## 처분 [2026-08-27] — **파싱은 유지, 소비는 하지 않는다(의도적)**
    ///
    /// 위 "소비처 0" 은 이제 미완이 아니라 **결정**이다. 근거 셋(WE 게이트가 두 항인데 Waple 은
    /// `audioprocessing` 유저 프로퍼티가 없어 한 항밖에 못 준다 · 조용해질 벽지 수를 잴 교차표가
    /// 없다 · 헤드리스 골든은 그 회귀를 구조적으로 못 본다)과 뒤집을 조건은
    /// `ProjectJSONParser.parseSupportsAudioProcessing` 의 「처분」 문단에 적혀 있다 —
    /// 여기서 되풀이하지 않는다(한 곳에서만 갱신되게).
    ///
    /// 계약을 지키는 오라클: `Tests/WapleRenderTests/AudioProcessingDeclarationTests.swift`.
    public private(set) var supportsAudioProcessing: Bool

    /// WE 재생정책 속성(project.json `general.properties.<키>.value`)의 **원문 문자열**.
    ///
    /// 키는 여섯 개다 — `playbackfocus`·`playbackmaximized`·`playbackfullscreen`·
    /// `playbackaudio`·`playbacksleep`·`playbackonbattery`
    /// (analysis/strings/json-keys.txt:409-414 · spec/engine/playback-policy.json 의
    /// `playbackPolicy.axes`). 값은 UI 콤보의 문자열 그대로("run"/"mute"/"pause"/
    /// "pauseall"/"stop")이며, 액션으로의 접기는 앱 계층의 WaplePolicy 매퍼 포트가 한다
    /// (PlaybackAction.init(weConfigValue:) — mapper 0x140141880, 미인식 → run).
    ///
    /// **여기 `[String: String]` 이상을 담지 않는 것은 의도다.** 이 모듈(WapleCore)은 리눅스
    /// spec 레인 보호를 위해 WaplePolicy 에 의존할 수 없다(Package.swift 의 WaplePolicy 경고 —
    /// 실측 `AudioResponse.swift:2 error: no such module 'simd'`). 부재 키는 딕셔너리에
    /// **안 들어간다.** WE 는 월페이퍼별 속성을 "" 기본값으로 주입해 "전역 설정 따름"을 뜻하게
    /// 하는데(FUN_140046ff0 → FUN_140086eb0(param_1,"playbackfocus","")), 빈 문자열도 부재와
    /// 같게 취급해 소비자에게 넘기지 않는다.
    ///
    /// **[2026-08-26] 그 소비자가 이제 실재한다** — 이 주석이 쓰일 때는 예고였다.
    ///
    /// **[2026-08-27 정정] 위 두 문단의 근거가 뒤집혔고 결론만 살아남았다.** 종전엔 "소비자
    /// (PlaybackPolicyGate)가 '부재 = run' 을 판정한다" · "Waple 에는 아직 전역 정책면이 없으므로"
    /// 라고 적혀 있었는데 둘 다 이제 거짓이다. 전역면은 `Sources/Waple/PlaybackPolicyRuntime.swift`
    /// 에 실재하고, 판정자는 `PlaybackPolicyResolver` 다(`PlaybackPolicyGate.verdict` 는 걷어냈다 —
    /// `AppLogic.swift` 의 [2026-08-26 승계] 툼스톤). 부재 축은 `run` 이 아니라 **전역값**을 받는다.
    ///
    /// **빈 문자열을 버리는 것은 그래서 오히려 더 옳아졌다.** 전역면이 없을 때는 `""` 를 버리는
    /// 것이 "표현할 수 없으니 근사" 였지만, 지금은 `""` = "전역 따름" 이 정확히 표현된다 —
    /// 키를 안 넣으면 `effective(global:declaring:)` 가 전역값을 그대로 남긴다. 근거가 바뀌었을 뿐
    /// 동작은 손댈 것이 없다. (`PlaybackPolicyRuntime.swift:27-29` 에 같은 판단이 적혀 있다.)
    ///
    /// 플랫폼 관측자도 이제 6축이 실재한다(`Sources/Waple/PlaybackObservers.swift`).
    /// 아직 안 채우는 축은 `vramPressure` 와 `external*Request` 둘뿐이고 이유는 `:128` 에 있다.
    public private(set) var playbackProperties: [String: String]

    public init(id: String, type: WallpaperType, fileName: String?, previewName: String?,
                title: String, tags: [String], contentRating: String?, workshopId: String?,
                dependency: String?, folderURL: URL, presetOverrides: [String: PropertyValue] = [:],
                presetFolderURL: URL? = nil, supportsAudioProcessing: Bool = false,
                playbackProperties: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.previewName = previewName
        self.title = title
        self.tags = tags
        self.contentRating = contentRating
        self.workshopId = workshopId
        self.dependency = dependency
        self.folderURL = folderURL
        self.presetOverrides = presetOverrides
        self.presetFolderURL = presetFolderURL
        self.supportsAudioProcessing = supportsAudioProcessing
        self.playbackProperties = playbackProperties
    }

    /// 일부 필드만 바꾼 사본. **재구성할 때 필드를 다시 나열하지 않기 위해서 있다.**
    ///
    /// ## 무엇이 잘못됐었나 [2026-08-26]
    ///
    /// `Sources/Waple/AppLogic.swift` 의 `PresetResolver.resolve` 가 프로젝트를 **필드 재나열**로
    /// 재구성하면서 뒤쪽 두 필드(`supportsAudioProcessing`·`playbackProperties`)를 통째로
    /// 흘리고 있었다. 위 `init` 에서 그 둘이 기본값을 갖고 있어 **빼먹어도 컴파일이 통과**하고,
    /// 그 자리에 `false` 와 `[:]` 가 조용히 들어간다 — 프리셋 경유 마운트마다 100% 재현되는
    /// 무증상 데이터 소실이다. 선행 감사는 둘 중 `playbackProperties` 하나만 잡았다(다른 하나를
    /// 놓친 것 자체가 "눈으로 재나열을 대조하는" 방식의 신뢰도를 말해 준다).
    ///
    /// ## 근본 원인은 그 호출부가 아니라 "재나열로 재구성" 이라는 방식이다
    ///
    /// 모델에 필드가 하나 늘 때마다 같은 사고가 재발하고, 컴파일러는 아무 말도 하지 않는다.
    /// 그래서 **재나열하는 자리를 없앤다.** `with(...)` 는 `var copy = self` 로 시작하므로
    /// 바꾸라고 지시받지 않은 필드는 **앞으로 추가될 것까지 포함해** 전부 그대로 실린다 —
    /// 흘릴 필드가 애초에 존재하지 않는다. 필드를 새로 추가하는 사람이 이 함수를 고치지 않아도
    /// 데이터는 보존된다(그 필드를 *바꾸고* 싶어질 때만 파라미터를 하나 더 연다. 파라미터 없이
    /// 바꾸려 들면 "extra argument" 컴파일 에러라 조용히 새지 않는다).
    ///
    /// 저장 프로퍼티를 `let` 에서 `public private(set) var` 로 바꾼 것이 그 대가다.
    /// 모듈 밖 표면은 그대로 읽기 전용이고(세터가 이 파일 안에서만 보인다), 세터를 쓰는 곳은
    /// 이 함수 하나뿐이다.
    ///
    /// **기각한 대안: `init` 의 기본값 두 개를 지워 모든 호출부에 명시를 강제하는 것.**
    /// 컴파일 에러로 막아 준다는 점에서 더 강하지만, 생성 지점이 **소스 3 · 테스트 100** 이다
    /// (`7de1021` 실측 — `grep -rn "WallpaperProject(" Sources/ Tests/`). 그중 91건이
    /// `Tests/WapleRenderTests/**`, 소스 3 중 둘은 여기(`ProjectJSONParser.swift:84`)와
    /// `Sources/WapleRender/VideoRenderer.swift:296` 로 이 수선의 소유 밖이다.
    /// 게다가 그쪽은 **재나열을 강제**하므로 "필드가 늘면 100군데를 고친다"가 영구 비용으로 남는다.
    /// 여기서 고치는 병이 바로 그 재나열이다.
    ///
    /// ## 인자 규약 — 옵셔널 필드는 **이중 옵셔널**이다
    ///
    /// 인자를 생략하면 "안 바꿈" 이다. 옵셔널 필드(`fileName` 등)는 "nil 로 바꿈" 과
    /// "안 바꿈" 을 구분해야 하므로 파라미터가 `String??` 다:
    ///
    /// - `with(fileName: other.fileName)` — `String?` 이 옵셔널 승격으로 `.some(…)` 이 되어
    ///   **nil 이어도 그 nil 로 덮어쓴다**(재나열과 같은 결과. 이게 흔한 쓰임이다).
    /// - `with(fileName: nil)` — 리터럴 `nil` 은 `.none` 이므로 **안 바꿈**.
    ///
    /// ⚠️ **그래서 `??` 를 인자 자리에 직접 쓰면 안 된다.** `with(previewName: a ?? b)` 에서
    /// 좌변 `a`(`String?`)가 `String??` 로 승격되며 `.some(a)` 가 되어 **항상 non-nil** 이 되고,
    /// 우변 `b` 는 죽는다. 컴파일러가 경고는 준다 —
    /// `left side of nil coalescing operator '??' has non-optional type 'String?',
    /// so the right side is never used` — 그러나 **경고일 뿐이라 빌드는 선다.**
    /// [2026-08-26] `PresetResolver.resolve` 에서 이 함정을 실제로 밟았고(세 필드), 앱 계층
    /// 타입체크 경고로 잡았다. 타입을 명시한 지역 상수로 먼저 접은 뒤 넘겨라:
    ///
    /// ```swift
    /// let previewName: String? = preset.previewName ?? target.previewName
    /// return preset.with(previewName: previewName)
    /// ```
    public func with(
        id: String? = nil,
        type: WallpaperType? = nil,
        fileName: String?? = nil,
        previewName: String?? = nil,
        title: String? = nil,
        tags: [String]? = nil,
        contentRating: String?? = nil,
        workshopId: String?? = nil,
        dependency: String?? = nil,
        folderURL: URL? = nil,
        presetOverrides: [String: PropertyValue]? = nil,
        presetFolderURL: URL?? = nil,
        supportsAudioProcessing: Bool? = nil,
        playbackProperties: [String: String]? = nil
    ) -> WallpaperProject {
        var copy = self
        if let id { copy.id = id }
        if let type { copy.type = type }
        if let fileName { copy.fileName = fileName }
        if let previewName { copy.previewName = previewName }
        if let title { copy.title = title }
        if let tags { copy.tags = tags }
        if let contentRating { copy.contentRating = contentRating }
        if let workshopId { copy.workshopId = workshopId }
        if let dependency { copy.dependency = dependency }
        if let folderURL { copy.folderURL = folderURL }
        if let presetOverrides { copy.presetOverrides = presetOverrides }
        if let presetFolderURL { copy.presetFolderURL = presetFolderURL }
        if let supportsAudioProcessing { copy.supportsAudioProcessing = supportsAudioProcessing }
        if let playbackProperties { copy.playbackProperties = playbackProperties }
        return copy
    }
}
