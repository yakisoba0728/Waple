import AVFoundation
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
    /// 이름 있는 사운드는 startsilent 여도 트리거 레지스트리에 등록(재생은 play(name:) 트리거 대기).
    /// 자동재생은 비-startsilent 만(startsilent 은 기존 정책대로 시작 무음 — 클래스 주석 참조).
    public func start(sounds: [SceneSound], package: ScenePackage, settingVolume: Float) {
        for snd in sounds {
            let entries = Self.playableEntries(snd)
            guard !entries.isEmpty else {
                WapleLog.warn("[Waple] scene sound: no playable entry in \(snd.sounds)")
                continue
            }
            let triggerable = !snd.name.isEmpty
            // startsilent 이고 이름도 없으면 재생 경로 전무(자동재생X·트리거X) → 스킵(기존 no-op 계약 유지).
            if snd.startSilent && !triggerable { continue }
            let pl = Playlist(entries: entries, mode: snd.playbackMode, package: package,
                              authorVolume: snd.volume, settingVolume: settingVolume,
                              minTime: snd.minTime, maxTime: snd.maxTime)
            // 자동재생 실패(전 후보 디코드 불가)면 미등록 — 단, 트리거 가능 사운드는 나중에 pkg 데이터가
            // 없을 리 없으니 그대로 등록(트리거 시 재시도). startsilent 은 애초에 자동재생 안 함.
            if !snd.startSilent {
                guard pl.startFirstPlayable() else { continue }
            }
            playlists.append(pl)
            if triggerable { named[snd.name] = pl }
        }
    }

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
/// AVAudioPlayer delegate 콜백은 메인 스레드 — mount/teardown 도 메인이라 락 불요(stopped 플래그만).
private final class Playlist: NSObject, AVAudioPlayerDelegate {
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

    init(entries: [String], mode: String, package: ScenePackage,
         authorVolume: Float, settingVolume: Float, minTime: Float, maxTime: Float) {
        self.entries = entries; self.mode = mode; self.package = package
        self.authorVolume = authorVolume; self.settingVolume = settingVolume
        self.minTime = minTime; self.maxTime = maxTime
    }

    /// 최종 출력 볼륨(오서 × 설정, 클램프). play(at:) 마다 적용 → 다음 곡에도 스크립트가 세팅한 볼륨이 지속.
    private var effectiveVolume: Float { SceneAudioPlayer.effectiveVolume(author: authorVolume, setting: settingVolume) }
    /// 스크립트가 읽어가는 볼륨(오서 관점). 세팅 배수는 감춘다(주크박스 페이드 로직이 세팅한 값을 그대로 회수).
    var scriptVolume: Float { authorVolume }
    func setVolume(_ v: Float) { authorVolume = v; player?.volume = effectiveVolume }

    /// 트리거 재생: 정지/일시정지 플래그 리셋 후 처음부터 재시작(재트리거 = 재시작).
    func trigger() {
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

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard !stopped,
              let next = SceneAudioPlayer.nextIndex(mode: mode, current: index, count: entries.count) else { return }
        // random 모드는 곡 사이 [mintime,maxtime]초 대기 후 다음 곡(WE 셔플 간격). 그 외 gap=0(즉시).
        // 다음 곡 실패 시 이 플레이리스트만 종료(코퍼스는 참조 파일 전부 존재 — 실사용에선 발생 안 함).
        let gap = SceneAudioPlayer.gapSeconds(mode: mode, minTime: minTime, maxTime: maxTime)
        guard gap > 0 else { _ = play(at: next); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            guard let self, !self.stopped else { return }
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
    func stop() { stopped = true; pendingNext = nil; player?.stop(); player = nil }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var hasPlayer: Bool { player != nil }
}
