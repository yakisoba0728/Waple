import Foundation

/// WE 기본(공유) 에셋 팩 경로 설정(UserDefaults 영속).
/// WE 월페이퍼는 패키지에 없는 공유 `.tex`(예: `materials/particle/halo.tex`, `materials/util/white.tex`)를
/// 참조한다. 이 경로가 설정되면 패키지에 없는 텍스처를 여기서 폴백 로드한다.
/// 기본 nil — 앱이 기본 에셋 팩을 번들하지 않으므로(공개 배포 + 저작권), 사용자가 지정해야 한다.
public enum BaseAssetsSettings {
    private static let key = "waple.baseAssetsPath"

    public static var fingerprint: String {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return "<automatic>"
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

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
                if isValidBaseAssetsPack(cand) {
                    logAutoDetectedOnce(cand)
                    return cand
                }
            }
            return nil
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: key) }
    }

    /// 자동 탐지 후보의 WE 기본 에셋 팩 정합성(F471) — shaders/common.h 와 materials/ 디렉터리 모두
    /// 존재해야 한다. common.h 단독 검사는 우연히 같은 이름을 가진 무관 폴터(범용명 ~/Downloads/assets)를
    /// 기본 에셋 팩으로 오채택할 수 있다.
    static func isValidBaseAssetsPack(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("shaders/common.h").path) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.appendingPathComponent("materials").path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// 자동 탐지 채택 1회 로그(F471) — 무관 폴터 채택 시 사용자가 원인을 추적할 수 있게.
    private static var loggedAutoDetectedPaths: Set<String> = []
    private static func logAutoDetectedOnce(_ url: URL) {
        let path = url.path
        guard !loggedAutoDetectedPaths.contains(path) else { return }
        loggedAutoDetectedPaths.insert(path)
        NSLog("%@", "[Waple] base assets auto-detected: \(path) (설정 메뉴 지정이 항상 우선)")
    }
}
