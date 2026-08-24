// @preconcurrency: 컴파일러 자체 fix-it(`:1:1 add '@preconcurrency' … from module 'AVFAudio'`).
// AVAudioPlayer 는 Sendable 이 아닌데 delegate 콜백이 메인으로 홉하면서 플레이어 인스턴스를 넘긴다 —
// 동시성 감사 이전 API 라서 나는 진단이고, 실제 직렬화는 아래 Playlist 주석의 "메인 전용" 규약이 한다.
@preconcurrency import AVFoundation
import WapleCore

/// 씬 sound 레이어 재생기. pkg 에서 mp3/wav 데이터를 추출해 AVAudioPlayer 로 재생한다.
///
/// 실측 의미(코퍼스 460종 / sound 오브젝트 382개 scene.json 직접 열람으로 확정, 2026-07-09):
/// - `sound[]` 다중 엔트리(33개, 2~18곡)는 전부 상이한 곡의 **플레이리스트** — 동시 재생이 아니라
///   한 번에 한 곡. loop=순차 순환, single=순차 1회 후 종료, random=곡 종료마다 무작위 재선곡.
///   (랜덤 오브젝트 9개 전부가 다중 엔트리 음악/SFX 목록 — 셔플 재생 의도가 명백.)
/// - `startsilent=true`(224/382)는 "씬 시작 시 자동재생 안 함" — WE 에선 트리거/SceneScript 로 기동
///   (single 148/224 + parent 보유 121/224 로 트리거성 SFX·보이스에 집중; false 157 은 비-parent
///   loop 140 의 배경음악). Waple 은 사운드 트리거 미지원 → 스킵. 시작 시점 무음이라는 점에서 WE 와
///   동일하고, 이후 트리거 재생만 미지원(한계).
/// - 음량은 (오서 볼륨 × VideoSettings 배경별 설정)으로 합성 — 동영상 설정 메뉴의 음소거/음량이 그대로
///   씬 오디오에도 적용된다(메뉴 변경 시 AppDelegate 가 배경을 재-mount → start 가 최신 설정을 재독). 기본
///   VideoSettings.volume 은 0(음소거)이라 사용자가 명시적으로 올리기 전엔 소리 나지 않는다.
/// - ogg(Vorbis)는 AVAudioPlayer 미디코드 → 순수 Swift 디코더(OggVorbisDecoder)로 PCM 화 후 재생(play(at:)).
///   mp3/wav/flac 은 Core Audio 네이티브. 코퍼스 참조 오디오 전 포맷 재생 가능.
/// - mintime/maxtime: random 모드 곡 종료 후 [mintime,maxtime]초 무작위 대기 후 다음 곡(gapSeconds). loop/single 은 즉시.
///
/// 헤드리스(캡처/테스트)에선 SceneRenderer 가 이 객체를 아예 생성하지 않는다(창 없는 mount → 스킵, 결정성).
/// 이 클래스 자체는 항상 재생 가능 — 통합테스트가 직접 구동한다.
public final class SceneAudioPlayer {
    /// 재생 불가로 미리 걸러낼 확장자. 코퍼스 전 포맷(mp3/wav/flac 네이티브 + ogg 자체 디코드) 지원 → 비어 있음.
    /// (미지원 확장자는 이 집합에 넣으면 playableEntries 가 사전 제외 — 폴백 로직과 별개의 안전장치.)
    static let unsupportedExtensions: Set<String> = []

    private var playlists: [Playlist] = []
    /// 이름 주소(name-addressable) 트리거 레지스트리: 씬 스크립트의 `getLayer(name).play()/stop()/isPlaying()/.volume`
    /// 대상. 이름 있는 사운드만 등록(playlists 배열의 같은 객체 참조 — pause/resume/teardown 이 함께 커버).
    private var named: [String: Playlist] = [:]

    public init() {}

    /// 재생 시작. 각 sound 오브젝트 → 플레이리스트 1개(한 번에 한 곡).
    /// - settingVolume: VideoSettings.volume(id:) (0…1). 오서 볼륨과 곱해 최종 음량.
    /// - volumeEngine: sound.volumeScript 가 있는 오브젝트마다 호출되는 엔진 팩토리(씬 공유 JSContext
    ///   생성은 SceneAudioPlayer 책임 밖 — 호출자(SceneRenderer.makeScriptEngine)가 주입). nil 반환 시
    ///   해당 사운드는 정적 볼륨 유지(무회귀).
    /// 이름 있는 사운드는 startsilent 여도 트리거 레지스트리에 등록(재생은 play(name:) 트리거 대기).
    /// 자동재생은 비-startsilent 만(startsilent 은 기존 정책대로 시작 무음 — 클래스 주석 참조).
    public func start(sounds: [SceneSound], package: ScenePackage, settingVolume: Float,
                      volumeEngine: (SceneSound) -> TextScriptEngine? = { _ in nil }) {
        for snd in sounds {
            let entries = Self.playableEntries(snd)
            guard !entries.isEmpty else {
                WapleLog.warn("[Waple] scene sound: no playable entry in \(snd.sounds)")
                continue
            }
            let triggerable = !snd.name.isEmpty
            // startsilent 이고 이름도 없으면 재생 경로 전무(자동재생X·트리거X) → 스킵(기존 no-op 계약 유지).
            if snd.startSilent && !triggerable { continue }
            let engine = snd.volumeScript != nil ? volumeEngine(snd) : nil
            let pl = Playlist(entries: entries, mode: snd.playbackMode, package: package,
                              authorVolume: snd.volume, settingVolume: settingVolume,
                              minTime: snd.minTime, maxTime: snd.maxTime, volumeEngine: engine)
            // F561(주석 정정): 자동재생 실패(전 후보 디코드 불가)면 named 여도 미등록 — pkg 데이터는 정적이라
            // 트리거 시 재시도해도 같은 디코드 실패(결정적)라 등록이 무의미하다(실질 영향 없음). startsilent 은 애초에 자동재생 안 함.
            if !snd.startSilent {
                guard pl.startFirstPlayable() else { continue }
            }
            playlists.append(pl)
            if triggerable { named[snd.name] = pl }
        }
    }

    /// volume 프로퍼티 스크립트 per-frame 재평가(F214) — 오디오/페이드 구동 볼륨(실측 12건, 예 2911866381).
    /// 스크립트 없는 재생목록은 매칭되는 엔진이 없어 안전 no-op(정적 볼륨 유지).
    public func tick(time: Float) { playlists.forEach { $0.tick(time: time) } }

    // ── 이름 주소 트랜스포트(씬 스크립트 브리지 __wapleSound 배후) ─────────────────
    /// 트리거 재생(재트리거 시 처음부터 재시작 — 클릭 SFX 규약). 미등록 이름은 안전 no-op.
    public func play(name: String) { named[name]?.trigger() }
    public func stop(name: String) { named[name]?.stop() }
    /// 일시정지(현재 플레이어). 재생 재개는 play(name:) 트리거(처음부터) — 3596485909 getChildren 경로 한정 사용.
    public func pause(name: String) { named[name]?.pause() }
    /// 실재생 상태(주크박스 폴링용) — 곡 자연종료 시 false 로 떨어진다.
    public func isPlaying(name: String) -> Bool { named[name]?.isPlaying ?? false }
    /// 스크립트 관점 볼륨(오서 볼륨, 0…1). 실제 출력은 VideoSettings 배수와 곱해진다.
    public func volume(name: String) -> Float { named[name]?.scriptVolume ?? 0 }
    public func setVolume(name: String, _ v: Float) { named[name]?.setVolume(v) }

    public func pause() { playlists.forEach { $0.pause() } }
    public func resume() { playlists.forEach { $0.resume() } }
    public func teardown() { playlists.forEach { $0.stop() }; playlists.removeAll(); named.removeAll() }

    /// 하나라도 재생 중인지(통합테스트 검증용).
    public var isPlaying: Bool { playlists.contains { $0.isPlaying } }
    /// 활성 플레이어 수(테스트용). 다중 엔트리도 오브젝트당 1(동시 재생 아님).
    var playerCount: Int { playlists.filter { $0.hasPlayer }.count }
    /// F812 테스트용: 정지(paused) 상태 플레이리스트 수 — 가림 게이트의 sceneAudio pause/resume 대칭 검증.
    var pausedPlaylistCountForTesting: Int { playlists.filter { $0.pausedForTesting }.count }

    // ── 순수 로직(테스트 대상) ─────────────────────────────────────────────

    /// 최종 음량 = 오서 볼륨 × 설정 볼륨, 0…1 클램프.
    static func effectiveVolume(author: Float, setting: Float) -> Float {
        max(0, min(1, author * setting))
    }

    /// 재생 가능(확장자 지원) 엔트리만, 순서 보존 — loop/single 은 이 순서로 재생.
    static func playableEntries(_ snd: SceneSound) -> [String] {
        snd.sounds.filter { !unsupportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// 시작 인덱스: random 은 무작위 선곡, 그 외 첫 곡. count<=0 → nil.
    static func firstIndex(mode: String, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return mode == "random" ? Int.random(in: 0..<count) : 0
    }

    /// 곡 종료 후 다음 인덱스. nil = 플레이리스트 종료.
    /// loop=순환, random=무작위 재선곡(연속), 그 외(single)=순차 1회(마지막이면 종료).
    static func nextIndex(mode: String, current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch mode {
        case "loop": return (current + 1) % count
        case "random": return Int.random(in: 0..<count)
        default: return current + 1 < count ? current + 1 : nil
        }
    }

    /// random 모드 곡 간 무작위 대기(초). WE: random 재생목록은 곡 종료 후 [mintime,maxtime]초 쉬고 다음 곡.
    /// 그 외 모드(loop/single)는 0(즉시 다음 곡). 경계: min>max 스왑, 음수 클램프, 둘 다 0/미지정 → 0.
    static func gapSeconds(mode: String, minTime: Float, maxTime: Float) -> Double {
        guard mode == "random" else { return 0 }
        let lo = max(0, min(minTime, maxTime))
        let hi = max(0, max(minTime, maxTime))
        guard hi > 0 else { return 0 }
        return Double(Float.random(in: lo...hi))
    }
}

/// sound 오브젝트 1개 = 플레이리스트 1개. 곡 종료 delegate 로 다음 곡을 건다(트랙별 라이브 루프).
/// AVAudioPlayer delegate 콜백 스레드는 문서상 미보장 — didFinishPlaying 은 메인으로 홉해
/// 상태(player/index/paused)를 메인 전용으로 직렬화(mount/teardown 도 메인 — 락 불요).
/// internal 인 이유: F552 stale 콜백 회귀 테스트가 직접 구동한다.
/// @unchecked Sendable 의 근거는 바로 위 문단이다 — 상태(player/index/paused/generation 등)는
/// **메인 전용**이고, 유일한 비메인 진입인 delegate 콜백은 첫 줄에서 메인으로 홉한다(락 불요).
/// 표기를 붙이는 이유는 그 메인 홉 클로저가 self 를 캡처하기 때문이다(엄격 동시성 진단 :237/:252).
/// [2026-08-25] `nonisolated` — `AVAudioPlayerDelegate` 적합성 때문에 멤버 전체가 메인 액터로
/// **추론**되고 있었다. 그런데 이 타입의 실제 설계는 바로 위 문단이 적은 그대로다: 상태는
/// 메인 전용이고 유일한 비메인 진입(delegate 콜백)이 첫 줄에서 메인으로 홉한다. 즉 추론된 격리는
/// 실제와 다르고, 그 어긋남이 `-strict-concurrency=complete` 진단 **17건**(`:57`–`:95` 의 비격리
/// 파사드가 Playlist 멤버를 부르는 자리)으로 나타났다.
///
/// 표기를 실제 설계에 맞춘다. `@unchecked Sendable` 이 이미 같은 주장을 하고 있었으므로 새 약속이
/// 아니라 **같은 약속을 한 번 더 명시**하는 것이다. 판례: `WallpaperSchemeHandler.swift:11-15`.
nonisolated final class Playlist: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let entries: [String]
    private let mode: String
    private let package: ScenePackage
    /// 오서(스크립트) 볼륨 0…1 — 스크립트가 `.volume` 로 덮어쓰면 갱신. 실제 출력은 settingVolume 배수와 곱.
    private var authorVolume: Float
    private let settingVolume: Float
    private let minTime: Float
    private let maxTime: Float
    private var index = 0
    private var player: AVAudioPlayer?
    private var stopped = false
    private var paused = false
    /// 곡 간 대기(random gap) 중 일시정지되면 여기 다음 인덱스를 보관 → resume 이 재개(정지 중 재생 방지).
    private var pendingNext: Int?
    /// F410: gap 콜백 stale 가드용 세대 — trigger/stop 마다 증가. 곡 종료로 예약된 asyncAfter 가 만기되기
    /// 전 trigger/stop 으로 새 세대가 시작됐으면 캡처 세대와 불일치 → 폐기(트리거된 새 곡을 중간에 끊지 않음).
    private var generation = 0
    /// F214: volume 프로퍼티 스크립트 엔진(sound.volumeScript 있을 때만 비-nil). tick(time:) 이 매 프레임
    /// update(authorVolume) → 새 authorVolume 으로 재평가.
    private let volumeEngine: TextScriptEngine?

    init(entries: [String], mode: String, package: ScenePackage,
         authorVolume: Float, settingVolume: Float, minTime: Float, maxTime: Float,
         volumeEngine: TextScriptEngine? = nil) {
        self.entries = entries; self.mode = mode; self.package = package
        self.authorVolume = authorVolume; self.settingVolume = settingVolume
        self.minTime = minTime; self.maxTime = maxTime
        self.volumeEngine = volumeEngine
    }

    /// 최종 출력 볼륨(오서 × 설정, 클램프). play(at:) 마다 적용 → 다음 곡에도 스크립트가 세팅한 볼륨이 지속.
    private var effectiveVolume: Float { SceneAudioPlayer.effectiveVolume(author: authorVolume, setting: settingVolume) }

    /// volume 스크립트 재평가(오디오/페이드 구동 — 실측 12건). update() 가 스칼라를 반환하지 않거나
    /// 예외면 authorVolume 유지(현상 유지 — 다른 프로퍼티 스크립트 소비처와 동일 규약).
    func tick(time: Float) {
        guard let volumeEngine else { return }
        volumeEngine.setRuntime(Double(time))
        if let v = volumeEngine.evaluateVec(current: [authorVolume])?.first {
            setVolume(v)
        }
    }
    /// 스크립트가 읽어가는 볼륨(오서 관점). 세팅 배수는 감춘다(주크박스 페이드 로직이 세팅한 값을 그대로 회수).
    var scriptVolume: Float { authorVolume }
    func setVolume(_ v: Float) { authorVolume = v; player?.volume = effectiveVolume }

    /// 트리거 재생: 정지/일시정지 플래그 리셋 후 처음부터 재시작(재트리거 = 재시작).
    func trigger() {
        generation += 1   // F410: 진행 중이던 gap 콜백 무효화(새 곡 절단 방지)
        stopped = false; paused = false; pendingNext = nil
        player?.stop()
        _ = startFirstPlayable()
    }

    /// 시작 곡부터 재생 시도, 실패(pkg 누락/디코드) 시 다음 후보로 폴백. 전부 실패 = false.
    func startFirstPlayable() -> Bool {
        guard let first = SceneAudioPlayer.firstIndex(mode: mode, count: entries.count) else { return false }
        for probe in 0..<entries.count where play(at: (first + probe) % entries.count) { return true }
        return false
    }

    private func play(at i: Int) -> Bool {
        let name = entries[i]
        guard let raw = package.data(for: name) else {
            WapleLog.warn("[Waple] scene sound: pkg entry missing: \(name)")
            return false
        }
        // ogg(Vorbis)는 AVAudioPlayer 미디코드 → 순수 Swift 디코더로 PCM WAV 화. 그 외는 원본 그대로.
        // ponytail: mount 스레드에서 동기 디코드. 대형 곡(수 MB)이 히치되면 백그라운드 디코드로 승격.
        let data: Data
        if (name as NSString).pathExtension.lowercased() == "ogg" {
            guard let decoded = try? OggVorbisDecoder.decode(raw), decoded.frameCount > 0 else {
                WapleLog.warn("[Waple] scene sound: ogg decode failed/empty: \(name)")
                return false
            }
            data = decoded.pcm16WAV()
        } else {
            data = raw
        }
        do {
            let p = try AVAudioPlayer(data: data)
            // 단곡 loop 는 네이티브 무한루프(심리스, delegate 불요). 그 외는 delegate 로 다음 곡 결정.
            if mode == "loop" && entries.count == 1 { p.numberOfLoops = -1 } else { p.delegate = self }
            p.volume = effectiveVolume
            p.prepareToPlay()
            p.play()
            player = p
            index = i
            return true
        } catch {
            WapleLog.warn("[Waple] scene sound decode failed: \(name): \(error)")
            return false
        }
    }

    /// AVAudioPlayerDelegate 의 이 요구사항은 **optional @objc** 라 런타임 respondsToSelector: 로 조회된다.
    /// 셀렉터를 명시로 고정하는 이유는 WebRenderer.swift 의 didFinish 주석에 적힌 사고와 같다 — 엄격
    /// 동시성/언어 모드 전환으로 witness 매칭이 깨지면 암묵 @objc 노출이 사라지고, 곡이 끝나도 다음 곡이
    /// 시작되지 않는 **무음 실패**가 된다(에러도 로그도 없다). 유닛 테스트는 이 메서드를 직접 호출하므로
    /// 후킹 여부를 잡지 못한다 — 그래서 코드로 고정한다.
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        // 콜백 스레드 미보장(Apple 문서) — 상태 갱신은 메인으로 홉(비메인이면 pause/teardown 과 경합).
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.audioPlayerDidFinishPlaying(p, successfully: flag) }
            return
        }
        // F552: stale 콜백 가드 — trigger/stop 으로 현재 플레이어가 교체/해제된 뒤 도착한 이전 곡의 종료
        // 통지는 폐기한다. F410 세대 가드는 gap asyncAfter 경로만 보호하고 이 홉 경로(gap=0 즉시 play(at:))는
        // 물방비였다 — 트리거 직전 자연종료 곡의 통지가 새 곡을 절단하는 것을 차단.
        guard p === player, !stopped,
              let next = SceneAudioPlayer.nextIndex(mode: mode, current: index, count: entries.count) else { return }
        // random 모드는 곡 사이 [mintime,maxtime]초 대기 후 다음 곡(WE 셔플 간격). 그 외 gap=0(즉시).
        // 다음 곡 실패 시 이 플레이리스트만 종료(코퍼스는 참조 파일 전부 존재 — 실사용에선 발생 안 함).
        let gap = SceneAudioPlayer.gapSeconds(mode: mode, minTime: minTime, maxTime: maxTime)
        guard gap > 0 else { _ = play(at: next); return }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            // F410: 만기 전 trigger/stop 으로 세대가 바뀌었으면 stale — 폐기(새 곡 절단 방지).
            guard let self, !self.stopped, self.generation == gen else { return }
            if self.paused { self.pendingNext = next }   // 정지 중이면 보류 → resume 이 재개
            else { _ = self.play(at: next) }
        }
    }

    func pause() { paused = true; player?.pause() }
    func resume() {
        paused = false
        if let next = pendingNext { pendingNext = nil; _ = play(at: next); return }  // gap 중 정지됐던 다음 곡
        if let p = player, !p.isPlaying { p.play() }
    }
    func stop() { generation += 1; stopped = true; pendingNext = nil; player?.stop(); player = nil }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var hasPlayer: Bool { player != nil }
    /// F552 회귀 테스트용 읽기 전용 접근자(stale 콜백이 현재 플레이어를 교체했는지 검증).
    var playerForTesting: AVAudioPlayer? { player }
    var indexForTesting: Int { index }
    /// F812 테스트용: 정지(paused) 플래그 — 가림 게이트의 sceneAudio pause/resume 대칭 검증.
    var pausedForTesting: Bool { paused }
}
