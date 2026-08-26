import Foundation

/// Sendable: 저장 프로퍼티가 전부 값 타입(String/URL/배열/딕셔너리 + 아래 두 enum)이고 모두 let 이다.
/// 명시가 필요한 이유는 **public 타입은 Sendable 이 자동 추론되지 않기 때문**이고, 이게 없으면
/// 프로젝트를 백그라운드로 넘기는 모든 지점(VideoRenderer 의 ffmpeg 변환 완료 콜백,
/// DeepScan.concurrentPerform 의 병렬 스캔)이 "non-Sendable 캡처" 진단을 낸다.
public struct WallpaperProject: Equatable, Sendable {
    public let id: String          // 폴더명 (워크샵 ID)
    public let type: WallpaperType
    public let fileName: String?   // project.json "file"
    public let previewName: String?// project.json "preview"
    public let title: String
    public let tags: [String]
    public let contentRating: String?
    public let workshopId: String?
    public let dependency: String? // 프리셋 전용
    public let folderURL: URL
    public let presetOverrides: [String: PropertyValue]
    public let presetFolderURL: URL?
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
    public let supportsAudioProcessing: Bool

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
    /// **안 들어간다** — 소비자(PlaybackPolicyGate)가 "부재 = run" 을 판정한다. WE 는 월페이퍼별
    /// 속성을 "" 기본값으로 주입해 "전역 설정 따름"을 뜻하게 하는데(FUN_140046ff0 →
    /// FUN_140086eb0(param_1,"playbackfocus","")), Waple 에는 아직 전역 정책면이 없으므로
    /// 빈 문자열도 부재와 같게 취급해 소비자에게 넘기지 않는다.
    public let playbackProperties: [String: String]

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
}
