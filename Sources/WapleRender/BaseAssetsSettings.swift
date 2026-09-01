import Foundation

/// WE 기본(공유) 에셋 팩 경로 설정(UserDefaults 영속).
/// WE 월페이퍼는 패키지에 없는 공유 `.tex`(예: `materials/particle/halo.tex`, `materials/util/white.tex`)를
/// 참조한다. 이 경로가 설정되면 패키지에 없는 텍스처를 여기서 폴백 로드한다.
///
/// **[r4-22 정정] 앱은 기본 에셋 팩을 동봉한다.** 종전 헤더는 "앱이 기본 에셋 팩을 번들하지
/// 않으므로(공개 배포 + 저작권), 사용자가 지정해야 한다" 고 적었지만 같은 파일의
/// `bundledAssetsDirectory` 가 "앱 번들에 동봉된 WE 2.8.42 공유 에셋 — 해석 순서상 마지막 폴백"
/// 을 구현한다. 사후 드리프트다(헤더는 동봉 이전 커밋 `4600bd44`, 동봉은 이후 `4e882a9d`).
/// 현재 규약은 `searchRoots` 가 정본이다: ① 사용자 지정/자동 탐지 → ② 앱 동봉본.
/// 이 프로퍼티(`baseAssetsDirectory`)의 기본이 nil 인 것은 여전히 맞지만, 그렇다고 공유 에셋이
/// 없는 것은 아니다 — 동봉본이 바닥을 받친다.
public enum BaseAssetsSettings {
    private static let key = "waple.baseAssetsPath"

    /// 영속 저장소. 프로덕션은 `.standard`, **테스트가 갈아끼우는 유일한 주입점**이다.
    ///
    /// [r3-M36] 형제 `SceneRenderSettings.defaults` · `SystemAudioSpectrumProvider` 와 같은 시임을
    /// 여기에도 둔다. 종전엔 이 타입만 `UserDefaults.standard` 를 직접 써서, 이 키를 만지는
    /// save/restore 5자리(`SnapshotPipeline.pinRenderSettings` + 테스트 4파일)가 **사용자 단위**
    /// 도메인을 그대로 밟았다. `SceneRenderSettings.defaults` 주석이 적듯 `.standard` 는 프로세스가
    /// 아니라 사용자 단위라, SwiftPM `--parallel` 워커 여럿이 같은 키를 공유해 경합한다
    /// (`lane12-tests.md` 의 "클래스별 프로세스라 경합 아님" 근거는 `setenv` 에는 맞지만
    ///  `UserDefaults` 에는 적용되지 않는다).
    ///
    /// `nonisolated(unsafe)`: 프로덕션에서는 앱 기동 후 바뀌지 않고(테스트만 갈아끼운다)
    /// `UserDefaults` 자체가 스레드 안전하다 — `SceneRenderSettings.defaults` 와 같은 표기 규율.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    public static var fingerprint: String {
        guard let path = defaults.string(forKey: key), !path.isEmpty else {
            return "<automatic>"
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// 사용자 지정 경로. **미설정이면 관례 위치 자동 탐지 결과를 돌려준다(영속화하지 않는다).**
    ///
    /// ⚠️ [r3-O20] 게터와 세터가 비대칭이다 — 게터는 "미설정" 을 자동 탐지 값으로 메우는데
    /// 세터는 받은 값을 그대로 `UserDefaults` 에 굽는다. 그래서 흔한 save/restore 관용구
    ///   `let old = ...baseAssetsDirectory;  defer { ...baseAssetsDirectory = old }`
    /// 는 **자동 탐지를 명시 핀으로 승격**시킨다: 복원 시점에 `old`(자동 탐지 경로)가 키에
    /// 기록되므로, 그 뒤로는 팩이 다른 위치로 옮겨가도 게터가 자동 탐지를 다시 하지 않는다.
    /// 이 관용구는 지금 5자리에 있다(`SnapshotPipeline.pinRenderSettings` +
    /// `RealPackagesGroundTruthTests` · `ForwardLightingGateProbeTests` · `SingleSceneProbeTests` ·
    /// `ThreeDV3CaptureTests`). 재현: `grep -rn 'baseAssetsDirectory' Sources Tests | grep oldBase`.
    ///
    /// 지금은 **동작을 바꾸지 않는다** — 대칭으로 고치려면(예: 자동 탐지 값을 게터가 감추거나,
    /// 세터가 자동 탐지와 같은 값이면 키를 지우거나) 위 5자리의 복원 의미가 함께 바뀌고
    /// 골든 캡처 경로(`pinRenderSettings`)가 그 안에 있다. 저장·복원이 필요하면 원시 키를 직접
    /// 다루는 별도 API 가 옳다 — 그 설계까지가 이 결함의 해소 조건이다.
    public static var baseAssetsDirectory: URL? {
        get {
            if let p = defaults.string(forKey: key), !p.isEmpty {
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
        set { defaults.set(newValue?.path, forKey: key) }
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
    ///
    /// [2026-08-19] 락을 씌운다(엄격 동시성 진단이 가리킨 곳). searchRoots 는 마운트 경로에서 불리고
    /// (SceneRenderer.mount), 다중 모니터 동시 마운트처럼 호출 스레드가 갈릴 수 있다 — Set 은 값
    /// 타입이라 동시 변형은 중복 로그가 아니라 **자료구조 손상/크래시**가 될 수 있다. 프로세스당
    /// 사실상 1회 도는 경로라 락 비용은 무의미하고, "1회 로그" 라는 원래 의도도 이제 정확해진다.
    /// (nonisolated(unsafe) 로 표기만 하고 넘어가지 않은 이유 — 여기엔 실제 경합 여지가 있다.)
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var loggedAutoDetectedPaths: Set<String> = []
    private static func logAutoDetectedOnce(_ url: URL) {
        let path = url.path
        logLock.lock()
        let inserted = loggedAutoDetectedPaths.insert(path).inserted
        logLock.unlock()
        guard inserted else { return }
        NSLog("%@", "[Waple] base assets auto-detected: \(path) (설정 메뉴 지정이 항상 우선)")
    }
}
