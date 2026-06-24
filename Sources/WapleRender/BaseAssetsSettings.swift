import Foundation

/// WE 기본(공유) 에셋 팩 경로 설정(UserDefaults 영속).
/// WE 월페이퍼는 패키지에 없는 공유 `.tex`(예: `materials/particle/halo.tex`, `materials/util/white.tex`)를
/// 참조한다. 이 경로가 설정되면 패키지에 없는 텍스처를 여기서 폴백 로드한다.
/// 기본 nil — 앱이 기본 에셋 팩을 번들하지 않으므로(공개 배포 + 저작권), 사용자가 지정해야 한다.
public enum BaseAssetsSettings {
    private static let key = "waple.baseAssetsPath"

    public static var baseAssetsDirectory: URL? {
        get {
            guard let p = UserDefaults.standard.string(forKey: key), !p.isEmpty else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: key) }
    }
}
