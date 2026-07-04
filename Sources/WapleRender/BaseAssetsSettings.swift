import Foundation

/// WE 기본(공유) 에셋 팩 경로 설정(UserDefaults 영속).
/// WE 월페이퍼는 패키지에 없는 공유 `.tex`(예: `materials/particle/halo.tex`, `materials/util/white.tex`)를
/// 참조한다. 이 경로가 설정되면 패키지에 없는 텍스처를 여기서 폴백 로드한다.
/// 기본 nil — 앱이 기본 에셋 팩을 번들하지 않으므로(공개 배포 + 저작권), 사용자가 지정해야 한다.
public enum BaseAssetsSettings {
    private static let key = "waple.baseAssetsPath"

    public static var baseAssetsDirectory: URL? {
        get {
            if let p = UserDefaults.standard.string(forKey: key), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            // 미설정 자동 탐지 — 번들ID 없는 SPM 실행파일은 외부 `defaults write` 도메인을 못 읽어
            // 실사용에서 에셋 실종("씬 개판" 2026-07-05 실증: common.h/util·particle tex 전부 미발견).
            // 관례 위치에 유효한 팩(shaders/common.h 존재)이 있으면 그걸 쓴다. 메뉴 설정이 항상 우선.
            let home = FileManager.default.homeDirectoryForCurrentUser
            for cand in [home.appendingPathComponent("Downloads/wallpaper_dev/assets"),
                         home.appendingPathComponent("Downloads/assets")] {
                if FileManager.default.fileExists(atPath: cand.appendingPathComponent("shaders/common.h").path) {
                    return cand
                }
            }
            return nil
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: key) }
    }
}
