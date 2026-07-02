import Foundation

/// 동영상 배경별 재생 설정(UserDefaults 영속, 배경 id 키).
/// 음량 기본 0(음소거) — 바탕화면이 예고 없이 소리 내지 않도록 보수적 기본(설계 2026-07-02).
public enum VideoSettings {
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
    public static func setRate(_ r: Float, id: String) {
        UserDefaults.standard.set(max(0.25, min(4, r)), forKey: rateKey(id))
    }
    public static func reset(id: String) {
        UserDefaults.standard.removeObject(forKey: volumeKey(id))
        UserDefaults.standard.removeObject(forKey: rateKey(id))
    }
}
