import Foundation
import WapleCore

// AppDelegate 의 결정 로직을 순수 함수로 추출(테스트 가능). UI/부수효과 없음 —
// 화면·스토어·파서·렌더러는 전부 클로저로 주입한다. AppDelegate 가 이 헬퍼들을 실제로 호출하므로
// 테스트가 실사용 경로를 검증한다(병렬 사본 아님).

/// 멀티모니터 배경 매핑: 화면별로 마운트할 프로젝트를 결정한다.
enum MonitorMapping {
    /// 화면에 할당된 배경 폴더. 할당이 없거나 그 엔트리 폴더가 해석되지 않으면 nil(= 전역 선택 사용).
    static func assignedFolder(
        screenKey: String,
        assignment: (String) -> String?,
        folderForEntry: (String) -> URL?
    ) -> URL? {
        guard let id = assignment(screenKey), let folder = folderForEntry(id) else { return nil }
        return folder
    }

    /// 화면 순서대로 마운트할 프로젝트. 할당 폴더는 `parse` 로 **폴더당 1회만** 파싱(캐시).
    /// 할당 없음 / parse 실패 → 전역 프로젝트로 폴백(AppDelegate.apply 규약과 동일).
    static func resolveProjects(
        screenKeys: [String],
        global: WallpaperProject,
        assignedFolder: (String) -> URL?,
        parse: (URL) -> WallpaperProject?
    ) -> [WallpaperProject] {
        resolveProjectSlots(
            screenKeys: screenKeys,
            global: global,
            assignedFolder: assignedFolder,
            parse: parse
        ).map { $0 ?? global }
    }

    /// 화면 순서대로 마운트할 프로젝트 슬롯. `global == nil` 이면 미할당 화면은 의도적으로 비운다.
    /// 할당 폴더는 `parse` 로 **폴더당 1회만** 파싱한다.
    static func resolveProjectSlots(
        screenKeys: [String],
        global: WallpaperProject?,
        assignedFolder: (String) -> URL?,
        parse: (URL) -> WallpaperProject?
    ) -> [WallpaperProject?] {
        var cache: [URL: WallpaperProject] = [:]
        return screenKeys.map { key in
            guard let folder = assignedFolder(key) else { return global }
            if let cached = cache[folder] { return cached }
            guard let parsed = parse(folder) else { return global }
            cache[folder] = parsed
            return parsed
        }
    }
}

enum PresetResolver {
    static func resolve(
        project: WallpaperProject,
        originalFolder: URL,
        dependencyFolder: (String) -> URL?,
        parse: (URL) -> WallpaperProject?
    ) -> WallpaperProject? {
        guard project.type == .preset else { return project }
        guard let dependency = project.dependency, !dependency.isEmpty else { return nil }
        guard let safeDependency = WallpaperPathSecurity.normalizedPathComponent(dependency) else { return nil }

        var candidates: [URL] = []
        if let fromLibrary = dependencyFolder(safeDependency) { candidates.append(fromLibrary) }
        candidates.append(originalFolder.deletingLastPathComponent().appendingPathComponent(safeDependency, isDirectory: true))

        var seen = Set<String>()
        for folder in candidates {
            let key = folder.standardizedFileURL.path
            guard seen.insert(key).inserted, let target = parse(folder), target.type != .preset else { continue }
            return WallpaperProject(
                id: project.id,
                type: target.type,
                fileName: target.fileName,
                previewName: project.previewName ?? target.previewName,
                title: project.title,
                tags: project.tags,
                contentRating: project.contentRating ?? target.contentRating,
                workshopId: project.workshopId ?? target.workshopId,
                dependency: safeDependency,
                folderURL: target.folderURL,
                presetOverrides: project.presetOverrides,
                presetFolderURL: project.folderURL
            )
        }
        return nil
    }
}

enum VideoSettingsTarget {
    static func projectIds(currentProjectId: String?, activeVideoProjectIds: [String]) -> [String] {
        let active = unique(activeVideoProjectIds)
        if !active.isEmpty { return active }
        return unique(currentProjectId.map { [$0] } ?? [])
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}

/// 마운트 트랜잭션: 전부 성공해야 교체, 하나라도 실패하면 부분 정리 후 롤백(이전 렌더러 유지).
enum RendererSwap {
    enum SwapError: Error {
        case unsupportedRenderer
    }

    /// `screens` 를 순서대로 mount 시도.
    /// - 전부 성공 → `existing` 을 teardown 하고 새 렌더러 세트를 `.success` 로 반환.
    /// - mount 가 throw → 지금까지 만든 새 렌더러만 teardown, `existing` 은 건드리지 않고 에러를 `.failure` 로 전파.
    /// - `makeAndMount` 가 nil 반환(지원 안 하는 화면) → `.failure`; 기존 렌더러는 유지한다.
    static func apply<S, R>(
        screens: [S],
        existing: [R],
        makeAndMount: (S) throws -> R?,
        teardown: (R) -> Void
    ) -> Result<[R], Error> {
        var made: [R] = []
        for s in screens {
            do {
                guard let r = try makeAndMount(s) else {
                    made.forEach(teardown)
                    return .failure(SwapError.unsupportedRenderer)
                }
                made.append(r)
            } catch {
                made.forEach(teardown)   // 부분 정리(이 실행에서 만든 것만)
                return .failure(error)   // existing 은 그대로 유지
            }
        }
        existing.forEach(teardown)       // 전부 성공한 뒤에만 이전 렌더러 정리
        return .success(made)
    }
}

/// 재생목록 자동전환 스케줄링 결정.
enum PlaylistScheduling {
    /// 타이머를 돌려야 하는가 — 자동전환이 켜져 있고 목록이 비어있지 않을 때만.
    static func shouldRun(enabled: Bool, ids: [String]) -> Bool {
        enabled && !ids.isEmpty
    }

    /// 타이머 간격(초). 분 단위 → 초, 최소 1분 하한.
    static func intervalSeconds(minutes: Int) -> TimeInterval {
        TimeInterval(max(1, minutes) * 60)
    }

    /// 셔플(무작위 순서, w5d-playback) 다음 id. ids 가 2개 이상이면 직전(current)을 제외한 후보에서
    /// 뽑아 연속 반복을 피한다(음악 셔플 관례 — SceneAudioPlayer.nextIndex(mode:"random") 과 달리
    /// "직전 곡 회피"를 우선한다). 후보가 1개뿐이면 회피 불가능하므로 그대로 반환. 빈 목록 → nil.
    /// random 은 주입(기본 Int.random) — 결정적 테스트 가능.
    static func shuffleNext(current: String?, ids: [String],
                            random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String? {
        guard !ids.isEmpty else { return nil }
        let candidates = ids.count > 1 ? ids.filter { $0 != current } : ids
        guard !candidates.isEmpty else { return ids.first }   // 방어: current 가 목록과 불일치 등
        return candidates[random(candidates.count)]
    }

    /// "다음 배경" 액션(트레이·하단 바 공용, w5d-tray)을 활성화할지 — 순환 가능한 후보가 2개 이상일
    /// 때만. 하나뿐이면 순환해도 자기 자신으로 돌아와 무의미하다.
    static func canAdvance(count: Int) -> Bool { count >= 2 }

    /// 타이머 콜백이 실제로 전진해야 하는가(F041) — 일시정지(가림·수동·슬립 사유 무관) 중엔 보류한다.
    /// "정지=화면 고정" 기대와 달리, 종전엔 재생목록 타이머만 PauseGate 밖에 있어 정지 중에도 배경이
    /// 계속 바뀌었다(새로 마운트된 렌더러 자체는 즉시 pause() 되어 결과 프레임은 정지 상태였지만,
    /// 그 정지 프레임이 계속 바뀌는 것 자체가 문제). 수동 "다음으로" 버튼(advancePlaylist 직접 호출)은
    /// 이 가드를 거치지 않아 정지 중에도 그대로 동작한다 — 사용자의 명시적 요청이라 의도적으로 예외.
    static func shouldAdvanceNow(isPaused: Bool) -> Bool { !isPaused }

    /// 재생목록 전진: `selected` 다음 후보부터 순환하며 `apply` 가 성공하는 첫 id 를 적용하고 그 id 를 반환.
    /// `apply` 실패 후보(라이브러리에서 삭제됐거나 폴더 해석/마운트 실패)는 건너뛴다 — 한 바퀴(count) 한도.
    /// 종전 nextApplicableId 는 첫 후보 하나만 보고 실패 시 nil 을 반환해, 그 지점에서 재생목록이 영구
    /// 정지했다(외장 드라이브 분리·폴더 이동·엔트리 삭제 등). 모두 실패 → nil(기존 배경 유지).
    static func advance(
        from selected: String?,
        count: Int,
        next: (String?) -> String?,
        apply: (String) -> Bool
    ) -> String? {
        var anchor = selected
        for _ in 0..<Swift.max(count, 0) {
            guard let id = next(anchor) else { return nil }
            anchor = id
            if apply(id) { return id }
        }
        return nil
    }
}

/// 정적 배경 동기화(작업 1): 실제 macOS 바탕화면을 현재 배경 스틸로 덮어쓸 때의 순수 결정 로직.
enum StillDesktopSync {
    /// 이 화면의 현재 바탕화면을 '원본'으로 백업할지.
    /// - 이미 백업이 있으면 유지(false) — 최초 덮어쓰기 직전 값만 원본으로 본다.
    /// - 현재 경로가 우리 still 디렉터리 내부면 자기 오염이므로 백업 안 함(false):
    ///   앱이 스틸을 깐 채 재실행됐을 때(예: 크래시 후) 우리 스틸을 '원본'으로 저장해
    ///   복원을 영구 무의미화하는 것을 막는 핵심 가드.
    static func shouldBackupOriginal(currentPath: String?, stillDirPath: String, hasBackup: Bool) -> Bool {
        guard !hasBackup, let currentPath, !currentPath.isEmpty else { return false }
        return !isUnder(currentPath, dir: stillDirPath)
    }

    /// 복원 패스(P-D1): 연결된 화면 키만 복원 시도하고, 소비한 키를 제거한 백업 dict 를 반환.
    /// - 파일 부재 → 복원 불가 확정이므로 제거(보존해도 영원히 못 쓴다).
    /// - restore 성공 → 제거. 실패 → 보존(다음 복원 경로에서 재시도).
    /// - 연결 안 된 화면 키는 건드리지 않는다 — 종전 전체 소거(= [:])가 분리 모니터 백업을 유실했다.
    static func restorePass(
        originals: [String: String],
        connectedKeys: [String],
        fileExists: (String) -> Bool,
        restore: (String, String) -> Bool
    ) -> [String: String] {
        var remaining = originals
        for key in connectedKeys {
            guard let path = remaining[key] else { continue }
            if !fileExists(path) || restore(key, path) {
                remaining.removeValue(forKey: key)
            }
        }
        return remaining
    }

    /// path 가 dir 내부(또는 동일)인가 — 표준화 후 경로 프리픽스 비교.
    static func isUnder(_ path: String, dir: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let d = (dir as NSString).standardizingPath
        if p == d { return true }
        return p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }
}

/// 수동 "정지 배경으로 설정" 통지 문구 결정(F044/F045, 순수). 종전엔 화면별 NSWorkspace 호출 성공
/// 여부를 전혀 세지 않고(try? 로 폐기) 무조건 성공 알림을 띄웠다 — 일부·전체 실패해도 사용자는
/// 거짓 성공을 통지받았다. 실제 성공 화면 수를 반영해 성공/부분성공/전체실패를 구분한다.
enum StillWallpaperNotice {
    static func message(successCount: Int, totalScreens: Int) -> String {
        switch successCount {
        case 0: return "정지 배경 설정에 실패했습니다"
        case totalScreens: return "정지 배경으로 설정했습니다"
        default: return "일부 화면만 정지 배경으로 설정했습니다(\(successCount)/\(totalScreens))"
        }
    }
}

/// 최근 배경 목록(작업 6): 적용 성공 id 를 선두 삽입·중복 제거·상한 유지(순수).
enum RecentWallpapers {
    static func push(_ id: String, into list: [String], max: Int = 10) -> [String] {
        var out = list.filter { $0 != id }   // 중복 제거
        out.insert(id, at: 0)                // 선두 삽입(최신)
        if out.count > max { out.removeLast(out.count - max) }
        return out
    }
}

/// 가림 일시정지 모드(작업 3): 라디오 선택값 ↔ (사용 여부, 커버 임계값).
enum OcclusionMode {
    /// represented 값(-1=사용안함, 0=기존 즉시, 0.3/0.5/0.8=커버 비율)을 (enabled, threshold) 로.
    static func decode(_ mode: Double) -> (enabled: Bool, threshold: Double) {
        mode < 0 ? (false, 0) : (true, mode)
    }

    /// 현재 상태가 이 라디오 값과 일치하는가(체크 표시용).
    static func isSelected(_ mode: Double, enabled: Bool, threshold: Double) -> Bool {
        if mode < 0 { return !enabled }
        return enabled && abs(threshold - mode) < 0.001
    }
}

/// 렌더 일시정지 사유 합성(순수). 가림·수동·슬립은 독립으로 겹칠 수 있고, 렌더러는 사유가
/// 하나도 없을 때만 재생한다. 사유 하나가 바뀔 때 실제 pause/resume 호출이 필요한지(엣지)를 이
/// 한 곳에서만 판정 — AppDelegate 가 반환 액션대로 renderers 에 적용한다(병렬 사본 아님). 사유마다
/// pause/resume 를 손으로 가드하지 않으므로 한 사유가 다른 사유를 덮어쓰는 실수가 원천 차단된다.
struct PauseGate {
    enum Reason { case occlusion, manual, sleep }
    enum Action { case pause, resume, none }

    private(set) var reasons: Set<Reason> = []

    /// 사유 on/off 반영. none→some 첫 진입 = .pause, some→none 마지막 해제 = .resume, 그 외 = .none.
    mutating func set(_ reason: Reason, active: Bool) -> Action {
        let wasPaused = isPaused
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        if wasPaused == isPaused { return .none }   // 경계를 안 넘으면 렌더 무동작
        return isPaused ? .pause : .resume
    }

    /// 사유 토글(수동 일시정지 메뉴/하단 바). 반환: 토글 후 활성 여부 + 렌더 액션.
    mutating func toggle(_ reason: Reason) -> (active: Bool, action: Action) {
        let next = !reasons.contains(reason)
        return (next, set(reason, active: next))
    }

    var isPaused: Bool { !reasons.isEmpty }
    func isActive(_ reason: Reason) -> Bool { reasons.contains(reason) }
}

/// 잠금화면 스틸(작업 2): `dscl . -read /Users/<user> GeneratedUID` 출력 파싱(순수).
enum GeneratedUID {
    /// dscl 출력에서 UID 추출. 형식은 "GeneratedUID: <uuid>"(같은 줄) 또는 값이 다음 줄일 수 있어
    /// 라벨 이후의 첫 공백 구분 토큰을 UID 로 본다. 라벨 부재/값 없음 → nil.
    static func parse(dsclOutput: String) -> String? {
        guard let range = dsclOutput.range(of: "GeneratedUID:") else { return nil }
        let after = dsclOutput[range.upperBound...]
        guard let uid = after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              !uid.isEmpty else { return nil }
        return uid
    }
}

/// 속성 편집 UI 결정(순수).
enum PropertyControl {
    enum Kind: Equatable {
        case toggle
        case slider
        case picker
        case color
        case textInput
        case file
        case directory
        case displayOnly
    }

    static func kind(forType type: String) -> Kind {
        switch type.lowercased() {
        case "bool", "checkbox":
            return .toggle
        case "slider":
            return .slider
        case "combo":
            return .picker
        case "color":
            return .color
        case "textinput":
            return .textInput
        case "file", "scenetexture":
            return .file
        case "directory":
            return .directory
        default:
            return .displayOnly
        }
    }

    /// 슬라이더 범위. min>max·min==max·음수 상한 등 비정상 경계에서도 항상 유효한 오름차순 범위를 만든다.
    /// ClosedRange 는 lower<=upper 를 요구하므로(위반 시 트랩=앱 크래시), 제3자 콘텐츠의 뒤집힌/축퇴
    /// 경계를 하한 기준으로 클램프한다. 상한 부재 시 하한+1.
    static func sliderRange(min: Double?, max: Double?) -> ClosedRange<Double> {
        let lo = min ?? 0
        let hi = Swift.max(lo + 0.0001, max ?? (lo + 1))
        return lo...hi
    }
}

// MARK: - 설정 창 표시 카탈로그 (SP5′)

/// 설정 창의 스텝 목록·상태 라벨 — 순수. 값은 기존 트레이 메뉴와 동일해야 저장값이 호환된다.
enum SettingsPresentation {
    static let volumeSteps: [(label: String, value: Float)] = [
        ("음소거", 0), ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1),
    ]
    static let rateSteps: [(label: String, value: Float)] = [
        ("0.5×", 0.5), ("1×", 1), ("1.5×", 1.5), ("2×", 2),
    ]
    static let playlistIntervalMinutes = [5, 15, 30, 60]

    /// 가림 정지 옵션(raw: -1=사용 안 함, 0=창 뜨면 즉시, 0.3/0.5/0.8=커버 비율) — 트레이 서브메뉴에서 이관.
    static let occlusionOptions: [(label: String, raw: Double)] = [
        ("사용 안 함", -1),
        ("창이 뜨면 즉시", 0),
        ("30% 이상 가려지면", 0.30),
        ("50% 이상 가려지면", 0.50),
        ("80% 이상 가려지면", 0.80),
    ]

    /// 영속 상태(enabled+threshold) → Picker 선택 raw 역산. 미일치는 방어 폴백(-1).
    static func currentOcclusionRaw(enabled: Bool, threshold: Double) -> Double {
        occlusionOptions.first {
            OcclusionMode.isSelected($0.raw, enabled: enabled, threshold: threshold)
        }?.raw ?? -1
    }

    /// 화면보호기 행 상태. bundled = 앱 번들에 Waple.saver 존재(패키징 앱에서만 true).
    static func saverStatus(bundled: Bool, selected: Bool) -> (label: String, canToggle: Bool) {
        guard bundled else {
            return ("패키징된 앱에서만 사용 가능 — scripts/package-app.sh", false)
        }
        return (selected ? "화면보호기로 사용 중" : "사용 안 함", true)
    }

    static func ffmpegStatus(available: Bool, path: String?) -> String {
        available ? "사용 가능 — \(path ?? "")"
                  : "미설치 — mkv/webm 동영상 변환에 필요합니다 (brew install ffmpeg)"
    }
}

/// 상태바 아이콘 글리프·툴팁 결정(w5d-tray, 순수). 상주 앱은 메뉴바 아이콘으로 상태를 한눈에
/// 알린다(미디어=재생/정지, VPN=연결) — Waple 은 종전엔 아이콘이 고정이라 정지·적용 실패가 메뉴를
/// 열기 전엔 안 보였다.
enum StatusIconState {
    /// 우선순위: 오류 > 정지 > 정상(재생 중). 오류는 다음 적용 성공까지 지속 표시(호출부가 플래그를 든다).
    static func symbolName(isPaused: Bool, hasError: Bool) -> String {
        if hasError { return "exclamationmark.triangle.fill" }
        return isPaused ? "pause.circle.fill" : "water.waves"
    }

    /// 툴팁: 적용된 배경 제목(없으면 앱 이름) + 상태 문구(정상 재생 중이면 덧붙이지 않음).
    static func tooltip(appliedTitle: String?, isPaused: Bool, hasError: Bool) -> String {
        var parts = [appliedTitle ?? "Waple"]
        if hasError { parts.append("적용 실패") }
        else if isPaused { parts.append("일시정지됨") }
        return parts.joined(separator: " · ")
    }
}

/// 최초 실행 온보딩 게이트(앱셸 스코프 B, 순수). 준비 항목 상태·시트 표시는 UI(부수효과)가 담당하고,
/// 여기서는 "완료 플래그가 없으면 1회 표시" 결정만 한다(플래그 영속은 호출자 — UserDefaults).
enum Onboarding {
    static func shouldPresent(completed: Bool) -> Bool { !completed }
}
