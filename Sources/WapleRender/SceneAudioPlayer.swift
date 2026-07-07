import AVFoundation
import WapleCore

/// 씬 sound 레이어 재생기. pkg 에서 mp3/wav 데이터를 추출해 AVAudioPlayer 로 재생한다.
///
/// - 음량은 (오서 볼륨 × VideoSettings 배경별 설정)으로 합성 — 동영상 설정 메뉴의 음소거/음량이 그대로
///   씬 오디오에도 적용된다(메뉴 변경 시 AppDelegate 가 배경을 재-mount → start 가 최신 설정을 재독). 기본
///   VideoSettings.volume 은 0(음소거)이라 사용자가 명시적으로 올리기 전엔 소리 나지 않는다.
/// - ogg 는 AVAudioPlayer 미지원(코퍼스 3개)이라 스킵+로그.
/// - loop 모드는 무한 반복, 그 외(single/random)는 1회. random 은 배열에서 무작위 1개 선택.
/// - mintime/maxtime 재트리거 스케줄링은 미구현(파스만) — 실측 근거 부족.
///
/// 헤드리스(캡처/테스트)에선 SceneRenderer 가 이 객체를 아예 생성하지 않는다(창 없는 mount → 스킵, 결정성).
/// 이 클래스 자체는 항상 재생 가능 — 통합테스트가 직접 구동한다.
public final class SceneAudioPlayer {
    /// AVAudioPlayer 가 디코드 못 하는 확장자(코퍼스: ogg 3개). 스킵 대상.
    static let unsupportedExtensions: Set<String> = ["ogg"]

    private var players: [AVAudioPlayer] = []

    public init() {}

    /// 재생 시작. 각 sound 오브젝트 → (배열에서 1개 선택) → AVAudioPlayer.
    /// - settingVolume: VideoSettings.volume(id:) (0…1). 오서 볼륨과 곱해 최종 음량.
    public func start(sounds: [SceneSound], package: ScenePackage, settingVolume: Float) {
        for snd in sounds {
            if snd.startSilent { continue }
            guard let (name, data) = Self.pick(snd, package: package) else { continue }
            do {
                let p = try AVAudioPlayer(data: data)
                p.numberOfLoops = snd.loop ? -1 : 0   // loop = 무한, 그 외 1회
                p.volume = Self.effectiveVolume(author: snd.volume, setting: settingVolume)
                p.prepareToPlay()
                p.play()
                players.append(p)
            } catch {
                WapleLog.warn("[Waple] scene sound decode failed: \(name): \(error)")
            }
        }
    }

    public func pause() { players.forEach { $0.pause() } }
    public func resume() { players.forEach { if !$0.isPlaying { $0.play() } } }
    public func teardown() { players.forEach { $0.stop() }; players.removeAll() }

    /// 하나라도 재생 중인지(통합테스트 검증용).
    public var isPlaying: Bool { players.contains { $0.isPlaying } }
    /// 장착된 플레이어 수(테스트용).
    var playerCount: Int { players.count }

    // ── 순수 로직(테스트 대상) ─────────────────────────────────────────────

    /// 최종 음량 = 오서 볼륨 × 설정 볼륨, 0…1 클램프.
    static func effectiveVolume(author: Float, setting: Float) -> Float {
        max(0, min(1, author * setting))
    }

    /// sound 배열에서 재생할 1개를 골라 pkg 데이터와 함께 반환. random 모드는 무작위, 그 외 첫 재생가능.
    /// ogg 등 미지원/누락은 건너뛴다. 반환 nil = 재생가능 엔트리 없음(로그).
    static func pick(_ snd: SceneSound, package: ScenePackage) -> (name: String, data: Data)? {
        let playable = snd.sounds.filter {
            !unsupportedExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        guard !playable.isEmpty else {
            WapleLog.warn("[Waple] scene sound: no playable entry in \(snd.sounds)")
            return nil
        }
        let name = snd.playbackMode == "random" ? (playable.randomElement() ?? playable[0]) : playable[0]
        guard let data = package.data(for: name) else {
            WapleLog.warn("[Waple] scene sound: pkg entry missing: \(name)")
            return nil
        }
        return (name, data)
    }
}
