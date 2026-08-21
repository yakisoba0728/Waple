import Foundation

/// 동영상 배경별 재생 설정(UserDefaults 영속, 배경 id 키).
/// 음량 기본 0(음소거) — 바탕화면이 예고 없이 소리 내지 않도록 보수적 기본(설계 2026-07-02).
/// **WE 기본은 50(퍼센트)** 이다(`getSharedDefaultProperties`). 이 차이는 정합 대상이 아니라
/// 의도적 정책 이탈이다 — `docs/re/media-playback.md` §9.2 G4.
public enum VideoSettings {
    /// 배속 하한. **엔진이 실제로 거는 유일한 클램프**다 —
    /// 0x140114d84 `movss xmm1, [0x140492654](=0.1f)` → 0x140114d90 `comiss/ja/movaps`.
    /// 저작값은 퍼센트라 0x140114d58 의 `100.0f`(0x1404928f8)로 나눈 뒤 이 하한을 먹는다.
    public static let minRate: Float = 0.1
    /// 배속 상한. **엔진에는 상한 클램프가 없다** — 이 값은 프로퍼티 스키마의 슬라이더
    /// `max`(0x1401052bf `mov qword [rbp+0x228], 0xc8` = 200%)에서 온다.
    /// 짝인 `min`(0x14010525f, `0xa` = 10%)은 위 엔진 하한과 같은 0.1 이다.
    /// 두 상수가 붙어 있는 프로퍼티는 `ui_browse_properties_playback_rate`(0x140488b70).
    public static let maxRate: Float = 2.0

    private static func volumeKey(_ id: String) -> String { "waple.video.volume.\(id)" }
    private static func rateKey(_ id: String) -> String { "waple.video.rate.\(id)" }

    public static func volume(id: String) -> Float {
        let d = UserDefaults.standard
        return d.object(forKey: volumeKey(id)) == nil ? 0 : d.float(forKey: volumeKey(id))
    }
    public static func setVolume(_ v: Float, id: String) {
        UserDefaults.standard.set(max(0, min(1, v)), forKey: volumeKey(id))
    }
    public static func rate(id: String) -> Float {
        let d = UserDefaults.standard
        let r = d.object(forKey: rateKey(id)) == nil ? 1 : d.float(forKey: rateKey(id))
        return r <= 0 ? 1 : r
    }
    /// 종전 클램프는 `[0.25, 4]` 였다 — 어느 쪽도 실측 근거가 없었다. WE 로 맞춘다:
    /// 하한은 엔진 클램프(0.1), 상한은 저작 슬라이더 최대(2.0). UI(`SettingsPresentation.rateSteps`)
    /// 가 제시하는 값은 0.5/1/1.5/2 라 이 변경으로 도달 불가가 되는 사용자 선택지는 없다.
    public static func setRate(_ r: Float, id: String) {
        UserDefaults.standard.set(max(minRate, min(maxRate, r)), forKey: rateKey(id))
    }
    public static func reset(id: String) {
        UserDefaults.standard.removeObject(forKey: volumeKey(id))
        UserDefaults.standard.removeObject(forKey: rateKey(id))
    }
}
