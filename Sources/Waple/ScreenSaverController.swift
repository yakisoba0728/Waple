import AppKit
import WapleCore

// 화면보호기 연동(feat/screensaver).
// 순수 결정 로직(ScreenSaverLogic — moduleDict 조립/설치 경로/대상 동영상)과
// 부수효과(ScreenSaverController — 설치/선택/해제/설정 열기)를 분리해 로직을 WapleAppTests 에서 검증한다.
// 상태는 전부 CFPreferences 에 있으므로 둘 다 인스턴스 없는 enum 이다.

/// 순수 결정 로직 — 파일시스템/CFPreferences 접근 없음(단위테스트 대상).
enum ScreenSaverLogic {
    static let saverName = "Waple"
    /// 화면보호기(AVFoundation)가 확실히 재생하는 컨테이너 — WapleSaverView.m 의 목록과 일치해야 한다.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// com.apple.screensaver 도메인의 moduleDict 값(어떤 화면보호기를 쓸지 시스템에 지정).
    static func moduleDict(installedPath: String) -> [String: Any] {
        ["moduleName": saverName, "path": installedPath, "type": 0]
    }

    /// 설치 목적지: <Screen Savers 디렉터리>/Waple.saver
    static func installDestination(screenSaversDirectory: URL) -> URL {
        screenSaversDirectory.appendingPathComponent("\(saverName).saver")
    }

    /// 화면보호기가 재생할 동영상의 절대 경로. 동영상 타입 + 지원 확장자일 때만 반환.
    static func videoPath(for project: WallpaperProject?) -> String? {
        guard let project, project.type == .video, let fileName = project.fileName else { return nil }
        let url = project.folderURL.appendingPathComponent(fileName)
        guard videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url.path
    }

    /// enable 시 현재 시스템 선택(moduleDict)을 백업해 둘지 판정.
    /// 사용자의 실제 화면보호기일 때만 true — disable 이 이 백업을 원복한다.
    /// 이미 Waple(재활성)이면 첫 enable 때 만든 원본 백업을 덮어쓰지 않도록 false,
    /// 선택 없음(nil)이면 복원=제거가 원상("없음")복구이므로 백업 불필요 → false.
    static func shouldBackup(current: [String: Any]?) -> Bool {
        guard let current else { return false }
        return (current["moduleName"] as? String) != saverName
    }

    /// F489: enable 시 옛 백업을 폐기해야 하는가 — 현재 선택이 '없음'(nil)일 때만.
    /// Waple 활성 중 사용자가 시스템 설정에서 직접 선택을 해제한 뒤 재활성한 경우로, 최초 enable 때의
    /// 옛 백업은 스테일이다(그대로 두면 disable 이 '없음'이 아니라 옛 saver 를 복원한다). Waple 자신이
    /// 선택돼 있으면(재활성) 기존 백업 유지 → false, 다른 saver 면 shouldBackup 이 새로 덮어씀 → false.
    static func shouldDiscardBackup(current: [String: Any]?) -> Bool {
        current == nil
    }

    /// F489: disable 시 백업 원복 가능 여부 — 현재 시스템 선택이 Waple 일 때만 true. enable→disable
    /// 사이 사용자가 시스템 설정에서 직접 다른 saver/'없음'으로 바꿨다면 그 최신 선택을 존중해
    /// 옛 백업으로 덮어쓰지 않는다.
    static func shouldRestoreBackup(current: [String: Any]?) -> Bool {
        (current?["moduleName"] as? String) == saverName
    }
}

/// 설치/선택/해제 부수효과. 메뉴 토글과 AppDelegate.apply 훅에서 호출한다.
enum ScreenSaverController {
    /// saver 가 읽는 앱→saver 공유 도메인(~/Library/Preferences/kr.yaki.waple.saver.plist).
    private static let saverDomain = "kr.yaki.waple.saver" as CFString
    /// 시스템 화면보호기 선택 도메인(ByHost).
    private static let systemDomain = "com.apple.screensaver" as CFString
    private static let moduleDictKey = "moduleDict" as CFString
    /// enable 이 덮어쓰기 전에 사용자의 원래 화면보호기 선택을 보관하는 키(앱 소유 도메인).
    private static let backupKey = "backupModuleDict" as CFString

    static var screenSaversDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers")
    }

    /// 현재 시스템에 선택된 화면보호기가 Waple 인가(메뉴 체크 상태).
    static var isSelected: Bool {
        guard let dict = CFPreferencesCopyValue(moduleDictKey, systemDomain,
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesCurrentHost) as? [String: Any] else { return false }
        return dict["moduleName"] as? String == ScreenSaverLogic.saverName
    }

    /// 켜기: ① 번들 saver 를 ~/Library/Screen Savers 로 설치(덮어쓰기)
    ///       ② moduleDict 로 시스템 선택 ③ 현재 배경이 동영상이면 경로 기록.
    static func enable(currentProject: WallpaperProject?) throws {
        guard let bundled = Bundle.main.url(forResource: ScreenSaverLogic.saverName,
                                            withExtension: "saver") else {
            // F840: 이 문자열은 AppDelegate.toggleScreenSaverCore 의 알림에 `error.localizedDescription`
            // 으로 그대로 실려 사용자에게 보인다 — 생 리터럴이면 영어 UI 에서 사유만 한국어로 남는다
            // (그 호출부 주석이 "이 파일은 동결이라 손대지 않았다(보고)"로 남겨 둔 자리다).
            throw NSError(domain: "Waple", code: 1, userInfo: [NSLocalizedDescriptionKey:
                NSLocalizedString("앱 번들에 Waple.saver 가 없습니다 — scripts/package-app.sh 로 패키징한 앱에서 실행하세요.",
                                  comment: "화면보호기 설치 실패 — 앱 번들에 .saver 부재")])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: screenSaversDirectory, withIntermediateDirectories: true)
        let dest = ScreenSaverLogic.installDestination(screenSaversDirectory: screenSaversDirectory)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }  // 버전 갱신 시 덮어쓰기
        try fm.copyItem(at: bundled, to: dest)

        // 덮어쓰기 전에 사용자의 원래 선택을 백업(disable 이 원복). 이미 Waple 이면 원본 백업 보존.
        let current = CFPreferencesCopyValue(moduleDictKey, systemDomain,
                                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [String: Any]
        if ScreenSaverLogic.shouldBackup(current: current) {
            CFPreferencesSetValue(backupKey, current as CFDictionary?, saverDomain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(saverDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        } else if ScreenSaverLogic.shouldDiscardBackup(current: current) {
            // F489: 사용자가 Waple 활성 중 시스템 설정에서 직접 '없음'으로 해제한 뒤 재활성 —
            // 최초 enable 때의 옛 백업은 스테일이므로 폐기한다(그대로 두면 disable 이 '없음'이
            // 아니라 옛 saver 를 복원해 사용자의 최신 선택을 덮어썼다).
            CFPreferencesSetValue(backupKey, nil, saverDomain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(saverDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }

        CFPreferencesSetValue(moduleDictKey,
                              ScreenSaverLogic.moduleDict(installedPath: dest.path) as CFDictionary,
                              systemDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(systemDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        syncVideoPath(for: currentProject)
    }

    /// 끄기: 백업된 사용자 화면보호기가 있으면 원복(백업 소거), 없으면 선택 제거.
    /// 설치 파일은 남긴다(재활성 대비, 무해). enable 이 사용자 원본을 backupKey 에 보관해 둔다.
    /// F489: enable→disable 사이 사용자가 시스템 설정에서 직접 다른 saver/'없음'으로 바꿨다면
    /// 현재 선택이 Waple 이 아니므로 옛 백업으로 덮어쓰지 않고 그대로 존중한다(백업만 폐기).
    static func disable() {
        let backup = CFPreferencesCopyValue(backupKey, saverDomain,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        let current = CFPreferencesCopyValue(moduleDictKey, systemDomain,
                                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? [String: Any]
        if ScreenSaverLogic.shouldRestoreBackup(current: current) {
            CFPreferencesSetValue(moduleDictKey, backup as CFDictionary?, systemDomain,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(systemDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        if backup != nil {  // 원복했든 사용자 직접 변경으로 무효화됐든 백업 소거(다음 사이클 오염 방지)
            CFPreferencesSetValue(backupKey, nil, saverDomain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(saverDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    /// 현재 배경이 동영상이면 그 경로를 saver 도메인에 기록. 아니면 기존 값 유지
    /// (마지막 동영상을 계속 재생 — 검은 화면보다 낫다). AppDelegate.apply 성공 경로에서 호출.
    static func syncVideoPath(for project: WallpaperProject?) {
        guard let path = ScreenSaverLogic.videoPath(for: project) else { return }
        CFPreferencesSetValue("videoPath" as CFString, path as CFString, saverDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(saverDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// 시스템 설정의 잠금 화면 패널 열기(화면보호기 확인/시작 대기시간 조정용).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
