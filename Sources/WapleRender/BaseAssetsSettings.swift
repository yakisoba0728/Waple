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
    public static func isValidBaseAssetsPack(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("shaders/common.h").path) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.appendingPathComponent("materials").path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// 앱 번들에 동봉된 WE 2.8.42 공유 에셋. 해석 순서상 **마지막 폴백**이다.
    /// 사용자가 최신·수정된 WE 설치본을 갖고 있으면 그쪽이 이긴다.
    ///
    /// **`Bundle.module` 을 쓰지 않는다.** SwiftPM 이 생성하는 접근자는 못 찾으면 경고가 아니라
    /// **fatalError** 이고, 탐색 후보가 빌드 시스템에 따라 다르다(swiftbuild = Contents/Resources,
    /// native = 앱 루트 + 빌드 디렉터리 절대경로). 그래서 CI(native)로 만든 배포본이 실행 즉시
    /// 죽었다(v0.1.0-beta.3 — `could not load resource bundle`). 앱 루트에는 codesign 이
    /// 파일을 못 두게 하므로("unsealed contents present in the bundle root") 그 후보를 만족시킬
    /// 방법도 없다. 그래서 **우리가 직접 찾는다** — 못 찾으면 nil(사용자 지정 경로로 폴백).
    private final class BundleMarker {}

    public static var bundledAssetsDirectory: URL? {
        let fm = FileManager.default
        func directory(_ u: URL) -> URL? {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return u
        }
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }   // 패키징된 .app/Contents/Resources
        let own = Bundle(for: BundleMarker.self)
        if let r = own.resourceURL { roots.append(r) }           // 테스트 번들 리소스
        roots.append(own.bundleURL.deletingLastPathComponent())  // .build/<config>/ (개발·테스트)
        roots.append(Bundle.main.bundleURL)                      // CLI: 실행 파일 옆
        for r in roots {
            // ① 폴더를 그대로 동봉한 경우 — package-app.sh 산출물.
            if let u = directory(r.appendingPathComponent("WEAssets", isDirectory: true)) { return u }
            // ② SwiftPM 리소스 번들 안 — 개발 실행·테스트.
            let b = r.appendingPathComponent("Waple_WapleRender.bundle", isDirectory: true)
            for inner in ["Contents/Resources/WEAssets", "WEAssets"] {
                if let u = directory(b.appendingPathComponent(inner, isDirectory: true)) { return u }
            }
        }
        return nil
    }

    /// 공유 에셋 검색 루트 — **우선순위 순**.
    /// 1) 사용자 지정 / 자동 탐지 (기존 `baseAssetsDirectory`)
    /// 2) 앱 동봉본
    ///
    /// 동봉본을 마지막에 두는 이유: 사용자 설치본이 더 새롭거나 수정돼 있을 수 있고,
    /// 그 의도를 앱이 덮어쓰면 안 된다. 동봉본은 "없을 때의 바닥"이다.
    public static var searchRoots: [URL] {
        var roots: [URL] = []
        if let user = baseAssetsDirectory { roots.append(user) }
        if let bundled = bundledAssetsDirectory,
           !roots.contains(where: { $0.standardizedFileURL == bundled.standardizedFileURL }) {
            roots.append(bundled)
        }
        return roots
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
