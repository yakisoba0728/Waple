import Foundation
import WapleCore
import WaplePolicy

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
            // [2026-08-26] 종전엔 `WallpaperProject(...)` 로 **필드를 다시 나열**해 재구성했고,
            // 그 나열이 뒤쪽 두 필드를 통째로 흘렸다 — `supportsAudioProcessing`(false 로) ·
            // `playbackProperties`([:] 로). 생성자에서 둘 다 기본값을 갖고 있어 **빼먹어도
            // 컴파일이 통과**했기 때문이고, 그래서 프리셋 경유 마운트마다 100% 재현되는데도
            // 아무 증상이 없었다(읽는 코드가 아직 없다). 선행 감사는 둘 중 하나만 잡았다.
            //
            // 재나열을 없앤다. `with(...)` 는 `var copy = self` 로 시작하므로 **여기서 이름을
            // 대지 않은 필드는 앞으로 늘어날 것까지 그대로 실린다** — 흘릴 것이 없다.
            // 근거·기각한 대안은 `WallpaperProject.with(...)` 주석에.
            //
            // 기준은 `project`(프리셋)다. 이 함수가 돌려주는 것은 "해석된 그 프리셋" 이고,
            // 라이브러리 엔트리로서의 정체성(id·title·tags·presetOverrides)이 프리셋 쪽이다.
            // 내용 쪽 필드만 target 으로 다시 가리킨다.
            // ⚠️ `??` 를 `with(...)` 인자 자리에 **직접 쓰면 안 된다.** 옵셔널 필드의 파라미터가
            //    이중 옵셔널이라 좌변 `String?` 이 `.some(…)` 으로 승격돼 **항상 non-nil** 이 되고,
            //    우변(target 폴백)이 통째로 죽는다. 이 자리에서 실제로 그렇게 썼다가 실측으로
            //    잡았다 — `warning: left side of nil coalescing operator '??' has non-optional
            //    type 'String?', so the right side is never used`(AppLogic.swift:91–93).
            //    경고일 뿐이라 빌드는 서고, "프리셋이 비면 target 값" 규약만 조용히 사라진다.
            //    타입을 명시한 지역 상수로 **먼저 접은 뒤** 넘긴다.
            let previewName: String? = project.previewName ?? target.previewName
            let contentRating: String? = project.contentRating ?? target.contentRating
            let workshopId: String? = project.workshopId ?? target.workshopId
            return project.with(
                type: target.type,
                fileName: target.fileName,
                previewName: previewName,
                contentRating: contentRating,
                workshopId: workshopId,
                dependency: safeDependency,
                folderURL: target.folderURL,
                presetFolderURL: project.folderURL,
                // 아래 둘은 위 `??` 관례(프리셋이 있으면 프리셋, 없으면 target)를 타입이
                // 허락하는 만큼 그대로 옮긴 것이다.
                //  · Bool 은 "선언 안 함" 과 "false 로 선언함" 을 구분할 수 없으므로 OR 로 접는다 —
                //    어느 쪽도 잃지 않는 유일한 접기다. 실무상 프리셋 project.json 에는 `general`
                //    블록이 없어 거의 언제나 target 값이 그대로 남는다.
                //  · 딕셔너리는 키 단위로 같은 관례가 성립한다(프리셋이 선언한 축이 이긴다).
                // **프리셋과 target 이 같은 축을 서로 다르게 선언했을 때 WE 가 어느 쪽을 쓰는지는
                // 아직 측정하지 못했다** — 여기 우선순위는 이 파일의 기존 `??` 관례를 따른 것이지
                // 실물 근거가 아니다. `[미해결]`
                supportsAudioProcessing: project.supportsAudioProcessing || target.supportsAudioProcessing,
                playbackProperties: target.playbackProperties
                    .merging(project.playbackProperties) { _, presetValue in presetValue }
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

/// ffmpeg 선변환 집계. 같은 원본을 보는 모니터는 하나의 변환을 공유하고,
/// 고유 소스 전부가 성공해야만 마운트 트랜잭션을 열 수 있다.
struct VideoPreparationBatch {
    enum Update {
        case ignored
        case pending
        case ready([URL: URL])
        case failed(URL)
    }

    let sources: [URL]
    private var pending: Set<URL>
    private var outputs: [URL: URL] = [:]

    init(sources: [URL]) {
        var seen = Set<URL>()
        self.sources = sources.filter { seen.insert($0).inserted }
        self.pending = Set(self.sources)
    }

    mutating func record(source: URL, output: URL?) -> Update {
        guard pending.remove(source) != nil else { return .ignored }
        guard let output else { return .failed(source) }
        outputs[source] = output
        return pending.isEmpty ? .ready(outputs) : .pending
    }

    /// 같은 apply 세대가 화면 세트를 재해석해 추가 소스를 발견했을 때 앞 배치 결과를 보존한다.
    /// 새 결과가 같은 source를 포함하면 더 최신 변환 결과가 이긴다.
    static func accumulated(existing: [URL: URL], newlyPrepared: [URL: URL]) -> [URL: URL] {
        existing.merging(newlyPrepared) { _, newer in newer }
    }
}

/// 재생목록 자동전환 스케줄링 결정.
///
/// **[2026-08-27] 이 열거의 절반은 더 이상 프로덕션에서 불리지 않는다.** 전진 판정·순서·시계가
/// `WapleCore.PlaylistRuntime`(순수) → `PlaylistDriver`(소비자)로 옮겨 갔다:
///
/// | 여기 | 대체 |
/// | --- | --- |
/// | `shuffleNext` — 직전 1개만 회피 | `WapleCore.ShuffleBag` — 소진형이라 한 바퀴 안에 반복이 없다 |
/// | `advance(from:count:next:apply:)` | `PlaylistDriver.requestAdvance(screenKey:now:apply:)` — 비동기 실패까지 같은 "실패 후보 건너뛰기" 루프를 **화면별로** 돈다 |
/// | `shouldAdvanceNow(isPaused:)` | `PlaylistSettings.accumulatesElapsed(isPaused:)` — 정지 중엔 전진만 막는 게 아니라 **시계가 선다** |
/// | `intervalSeconds(minutes:)` | 없음 — 틱이 1초 고정이고 간격은 `delayMinutes` 로 판정에 들어간다 |
///
/// **지우지 않은 이유는 하나다**: 이 라운드에서 테스트를 줄일 수 없다(`ci.yml` 의 실행 하한은
/// 그린 CI 실측으로만 움직인다). 제거는 그 하한을 다시 잴 수 있는 라운드의 일이다.
/// `shouldRun` · `shouldScheduleTimer` · `canAdvance` 는 계속 쓰인다.
enum PlaylistScheduling {
    /// 타이머를 돌려야 하는가 — 자동전환이 켜져 있고 목록이 비어있지 않을 때만.
    static func shouldRun(enabled: Bool, ids: [String]) -> Bool {
        enabled && !ids.isEmpty
    }

    /// F483: 자동전환 타이머를 실제로 걸어야 하는가 — 켜짐 + 순환 가능한 후보 2개 이상.
    /// 목록이 정확히 1개면 next(after:) 가 (i+1)%1 로 자기 자신만 반환해, 타이머가 매 간격 같은
    /// 배경을 리마운트했다(동영상 t=0 재시작·웹 리로드·화면 깜빡임). 수동 "다음 배경" 버튼/트레이의
    /// canAdvance(count>=2) 가드와 대칭을 맞춘다. shouldRun 은 기존 호출·테스트 호환을 위해 유지.
    static func shouldScheduleTimer(enabled: Bool, ids: [String]) -> Bool {
        shouldRun(enabled: enabled, ids: ids) && canAdvance(count: ids.count)
    }

    /// 타이머 간격(초). 분 단위 → 초, 최소 1분 하한.
    /// F488: 상한(1년)도 클램프 — playlist.json 수동 편집 등으로 거대한 분 값이 들어오면
    /// `max(1, minutes) * 60` 의 Int 곱셈이 오버플로 트랩(크래시)을 일으켰다.
    static func intervalSeconds(minutes: Int) -> TimeInterval {
        let clamped = min(max(1, minutes), 525_600)   // 1년 = 525_600분
        return TimeInterval(clamped * 60)
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

    /// F481: 앱 종료 시 백업 원본을 복원해야 하는가 — 자동 동기화가 켜진 상태일 때만. 동기화 OFF 의
    /// 수동 "정지 배경으로 설정"까지 종료와 함께 되돌리면(종전) 사용자의 명시적 1회 액션을 앱이
    /// 묵시적으로 취소하는 모순이 된다(백업은 F042 오염 방지용으로 수동 경로도 남아 있다).
    static func shouldRestoreOnTerminate(syncEnabled: Bool) -> Bool { syncEnabled }
}

/// 수동 "정지 배경으로 설정" 통지 문구 결정(F044/F045, 순수). 종전엔 화면별 NSWorkspace 호출 성공
/// 여부를 전혀 세지 않고(try? 로 폐기) 무조건 성공 알림을 띄웠다 — 일부·전체 실패해도 사용자는
/// 거짓 성공을 통지받았다. 실제 성공 화면 수를 반영해 성공/부분성공/전체실패를 구분한다.
enum StillWallpaperNotice {
    /// 반환값은 **이미 현지화된** 문자열이다. 싱크(StatusBanner)가 미현지화 `String` 을 받는
    /// `Text` 오버로드라 뷰까지 나르면 조용히 번역이 사라진다 — 그래서 생산 지점에서 완성한다
    /// (청사진 §5.0 의 권장안 (a)). 리터럴이 `NSLocalizedString(` 안에 남아 오라클에도 걸린다.
    static func message(successCount: Int, totalScreens: Int) -> String {
        switch successCount {
        case 0: return NSLocalizedString("정지 배경 설정에 실패했습니다", comment: "정지 배경 전량 실패")
        case totalScreens: return NSLocalizedString("정지 배경으로 설정했습니다", comment: "정지 배경 성공")
        default:
            return String(format: NSLocalizedString("일부 화면만 정지 배경으로 설정했습니다(%lld/%lld)",
                                                    comment: "정지 배경 부분 성공"),
                          successCount, totalScreens)
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

    /// F480: 마운트된 폴더 경로로 '최근 배경'에 넣을 라이브러리 엔트리 id 를 고른다(순수).
    /// 파서 id(project.id)를 쓰면 F194 로 접미 유일화된 엔트리(x-2)와 불일치해 메뉴가 무접미 id 의
    /// 다른 배경을 집거나(원본 제거 시) 아예 못 찾는다 — 반드시 엔트리 id 기준으로 정합.
    /// entries 는 호출부가 (엔트리 id, 해석된 폴더 경로) 쌍으로 만든다. 못 찾으면 nil — 호출부는
    /// push 를 생략한다(파서 id 폴백을 섞으면 같은 불일치가 재발한다).
    static func entryId(matchingFolderPath path: String, entries: [(id: String, path: String)]) -> String? {
        entries.first(where: { $0.path == path })?.id
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
    /// F840: 시스템 슬립(.sleep)과 디스플레이 슬립(.displaySleep)은 **서로 다른 사유**다.
    /// 종전에는 넷(willSleep/screensDidSleep/didWake/screensDidWake)이 전부 .sleep 하나를
    /// 켜고 껐기 때문에, 둘 중 한쪽이 아직 자고 있어도 다른 쪽의 첫 웨이크가 정지를 풀었다.
    enum Reason { case occlusion, manual, sleep, displaySleep }
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

// MARK: - WE 재생 정책 게이트 (stage 1 — 순수 판정까지만)

/// 벽지가 `project.json` 에 **선언한** WE 재생정책(playbackfocus/maximized/fullscreen/
/// audio/sleep/onbattery)을 하나의 판정으로 접는다.
///
/// `WapleCore` 가 걷어 온 원문 문자열(`WallpaperProject.playbackProperties`)과 `WaplePolicy` 의
/// 평가기(`PlaybackEvaluator.evaluate`) 사이를 잇는 **유일한 자리**다. 두 모듈은 서로를 모른다 —
/// `WapleCore` 는 리눅스 spec 레인 보호 때문에 `WaplePolicy` 를 import 할 수 없다
/// (`Package.swift` 의 `WaplePolicy` 경고). 그래서 접합은 둘 다 볼 수 있는 앱 계층에서 한다.
///
/// ## 최상위 계약: **부재 = run**
///
/// 파서는 부재 키와 빈 문자열을 딕셔너리에 **넣지 않는다**(`ProjectJSONParser.parsePlaybackProperties`).
/// "그러면 어떻게 되는가" 를 정하는 자리가 여기 한 곳이라는 것이 그 설계의 요점이다.
///
/// **`PlaybackPolicy.init(weConfig:)` 를 쓰면 안 된다.** 그쪽은 부재 키를 `trigger.weDefault`
/// 로 채우는데(maximized `pause` · fullscreen `pause` · sleep `stop`), 그건 WE **전역 설정**의
/// 기본값이지 **벽지별 선언**의 기본값이 아니다. 그대로 쓰면 아무것도 선언하지 않은 벽지가
/// 남의 창 최대화만으로 멈춘다 — 무회귀 요구의 정반대다. 그래서 기준선을 전 축 `.run` 으로
/// 깔고 **선언된 축만** 덮어쓴다.
///
/// ## 무회귀 — **이 절이 설명하던 `verdict(...)` 는 걷어냈다** (아래 [2026-08-26 승계] 참조)
///
/// 종전: 한 축도 선언되지 않았으면 `declaredPolicy` 가 nil 이고 `verdict(...)` 가 평가기를
/// 부르지도 않고 `.running` 을 냈다 — 무회귀가 논증이 아니라 **구조**로 성립했다.
/// 그 단축은 전역 정책면이 없다는 전제 위에서만 옳았고, 전제가 깨지면서 함수와 함께 사라졌다.
/// 지금 선언이 없는 축은 `.running` 이 아니라 **전역 정책값**을 받는다
/// (`PlaybackPolicyResolver.effective`). 위 문단의 "기준선을 전 축 `.run` 으로 깔고" 는
/// `declaredPolicy` 에 대해서는 여전히 유효하다 — 그 함수는 "이 벽지가 스스로 무엇을
/// 선언했는가" 라는 별개의 질문에 답하므로 전 축 `.run` 기준선이 맞다.
///
/// 남아 있는 사실 하나: `PlaybackConditions` 의 `external*Request` · `vramPressure` ·
/// `forcePauseAll` 에 **값을 넣는 프로덕션 코드가 아직 하나도 없다**(`PlaybackObservers.swift:128`
/// 이 왜 안 넘기는지 적어 둔다). 수동·가림·슬립 정지는 이 파일의 `PauseGate` 가 따로 쥐고 있고,
/// 트레이/IPC 를 붙일 때 이 자리를 다시 판단해라.
enum PlaybackPolicyGate {
    /// 벽지가 **선언한 축만** 반영한 정책. 한 축도 선언하지 않았으면 nil.
    ///
    /// 빈 문자열을 여기서 한 번 더 거르는 것은 중복이 아니다. 파서가 이미 걸러 주지만
    /// ("전역 설정 따름" 을 뜻하는 WE 의 `""` 기본 주입 — `WallpaperProject.playbackProperties`
    /// 주석), **"부재 = run" 을 판정하는 단일 지점은 이 함수**라서 딕셔너리가 다른 경로로
    /// 들어와도 계약이 유지돼야 한다.
    ///
    /// 미인식 문자열은 `PlaybackAction(weConfigValue:)` 규약대로 조용히 `.run` 이다
    /// (매퍼 0x140141918). 즉 오타는 "정책 없음" 이지 실패가 아니다 — 실물이 그렇다.
    static func declaredPolicy(_ properties: [String: String]) -> PlaybackPolicy? {
        var policy = PlaybackPolicy(
            focus: .run, maximized: .run, fullscreen: .run,
            audio: .run, displaySleep: .run, battery: .run, pauseVRAM: false
        )
        var declaredAny = false
        for trigger in PlaybackTrigger.allCases {
            guard let raw = properties[trigger.weConfigKey], !raw.isEmpty else { continue }
            policy[trigger] = PlaybackAction(weConfigValue: raw)
            declaredAny = true
        }
        return declaredAny ? policy : nil
    }

    // [2026-08-26 승계] **여기 있던 `verdict(...)` 둘은 걷어냈다.**
    //
    // 그 둘은 벽지 선언만 보고 판정을 냈고, 선언이 없으면 평가기를 부르지 않고 `.running` 으로
    // 단축했다. 그 단축은 "전역 정책면이 없다" 는 전제 위에서만 옳았는데 **그 전제가 깨졌다** —
    // `PlaybackPolicyRuntime.swift` 가 전역면을 세웠다(근거: 코퍼스 191개 중 이 6키를 선언한
    // `project.json` 이 0개이고, 정책은 WE 의 `config.json` `general/user` 에 산다).
    //
    // 판정을 내는 자리는 이제 `PlaybackPolicyResolver` **하나**다. 두 경로를 남겨 두면 둘 중
    // 어느 쪽이 진짜인지가 호출부마다 갈린다.
    //
    // 이 층이 사라진 것은 아니다 — 위 `declaredPolicy` 는 여전히 "이 벽지가 **스스로** 무엇을
    // 선언했는가" 라는 별개의 질문에 답한다. 종전 `verdict` 의 의미(선언 없는 축 = run)는
    // 이제 `PlaybackPolicyResolver.effective(global: .allRun, declaring:)` 로 정확히 표현된다.
}

// MARK: - stage 2 — 축별 착지점, 그리고 아직 남은 둘
//
// [2026-08-27 정정] 이 블록은 stage 2 가 **끝난 뒤에도 "아직 없다" 를 현재형으로 말하고
// 있었다.** 부분 갱신 한 줄만 머리에 얹히고 본문이 그대로였다. 사실과 어긋난 문장 셋을
// 걷어내고 축별 착지점으로 바꾼다 — 재생정책 진입 설명을 맡은 자리라, 다음 사람이 이미
// 있는 관측자를 다시 만들 위험이 실질적이었다. (같은 서술이 실린
// `docs/handoff-2026-08-26b.md:116` 도 그 시점 기록이니 그대로 읽지 마라.)
//
// 걷어낸 문장: "관측자는 하나도 쓰지 않았다" · "`PlaybackPolicyGate` 를 부르는 프로덕션
// 호출부가 없다" · "판정을 렌더러에 먹이는 쪽도 아직 없다". 셋 다 뒤집혔다 —
// `PlaybackObservers.swift` 가 6축을 채우고 `AppDelegate.applyPlaybackPolicy`(1초 타이머)가
// 판정을 렌더러에 먹인다. `PlaybackPolicyGate.verdict` 자체는 삭제됐고 판정자는
// `PlaybackPolicyResolver` 다(아래 툼스톤 참조).
//
// 축별 착지점:
//
//  · `unfocusedMask`   → `PlaybackMasks.unfocused` (`PlaybackObservers.swift:115`).
//  · `maximizedMask`   → `PlaybackMasks.maximized` (`:119`), 비교 대상 `NSScreen.visibleFrame`.
//  · `fullscreenMask`  → `PlaybackMasks.fullscreen` (`:122`), 비교 대상 `NSScreen.frame`.
//                        셋 다 `DesktopVisibilityMonitor.WindowSnapshot` 배열의 파생으로 얹었다 —
//                        `CGWindowListCopyWindowInfo` → 순수 스냅샷 → static 판정 함수라는
//                        그 파일의 모양을 그대로 물려받는다. 예상대로 그게 맞는 자리였다.
//  · `audioPlaying`    → `SystemAudioObserver.defaultOutputDeviceIsRunning` (`:68`),
//                        `kAudioDevicePropertyDeviceIsRunningSomewhere`. WE 는 WASAPI 세션
//                        열거로 같은 것을 본다. 우리 자신의 재생을 빼는 것은 `:61`.
//  · `displayAsleep`   → `AppDelegate.displaySleepBegan/displaySleepEnded` 의 불리언을 그대로
//                        넘긴다(`NSWorkspace.screensDidSleepNotification`). 새 관측자가 필요
//                        없는 유일한 축이라던 예상이 맞았다.
//  · `onBattery`       → `PowerSourceObserver.isOnBattery` (`:48`), IOKit
//                        `IOPSGetProvidingPowerSourceType() == kIOPMBatteryPowerKey`.
//
// **아직 남은 둘** — `PlaybackConditionsBuilder.make` 가 왜 안 넘기는지를 그 자리
// (`PlaybackObservers.swift:128-131`)에 적어 두었다. 요약하면:
//
//  · `vramPressure`     `VRAMHysteresis`(WaplePolicy) 는 모델만 있고 표본을 먹이는 자리가
//                       없다. macOS 쪽 표본은 `MTLDevice.currentAllocatedSize` /
//                       `recommendedMaxWorkingSetSize` 이고, WE 의 PDH 표본수·총량 범위
//                       게이트는 그 모델이 이미 강제한다. 기본값 false 가 "압박 없음" 이라
//                       무회귀 쪽이다.
//  · `external*Request` 트레이/IPC. 겹치는 문제가 그대로 남아 있다 — 수동 정지는 이 파일의
//                       `PauseGate` 가 이미 쥐고 있고, 두 경로를 어떻게 합칠지가 설계 결정이다.
//                       **붙일 때 함께 볼 것**: 절전 래치가 `externalMuteRequest`(플래그 bit6)를
//                       삼킨다(`WaplePolicy/PlaybackPolicy.swift:546` 의 조기 이탈이 `muted:
//                       false` 를 못박는다). 적용기는 pause 와 다른 마스크로 bit6 을 보므로
//                       (`test bpl, 0xc0` vs `test bpl, 0x21`) 모델이 실물과 갈리는 자리다.
//                       호출부가 없어 오늘 도달이 0 이라 잠복해 있을 뿐이다 —
//                       `docs/swarm-audit-2026-08-26.md:296` 이 이미 지적했고 처분 기록이 없다.

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
/// ## 라벨은 여기서 이미 현지화해 내보낸다
///
/// 호출부가 `Text($0.label)` 로 받는데 그 오버로드는 `String` 이라 번역하지 않는다
/// (청사진 §5.0). 싱크 타입을 `LocalizedStringKey` 로 바꾸는 대안은 리터럴이 대입문이
/// 되어 어떤 스캔 패턴에도 안 걸리므로 택하지 않았다 — 런타임 버그 하나를 고치면서
/// 오라클 사각지대를 새로 파는 셈이다. 생산 지점에서 `NSLocalizedString` 으로 완성하면
/// 리터럴이 패턴 1 에 그대로 잡힌다.
///
/// `static let` 이 아니라 계산 프로퍼티인 것은 **언어가 프로세스 수명 중에 바뀔 수 있기**
/// 때문이다. `let` 이면 앱 시작 시점의 번역에 고정된다(`Motion.fade` 가 `var` 인 것과 같은 이유).
enum SettingsPresentation {
    static var volumeSteps: [(label: String, value: Float)] {
        [(NSLocalizedString("음소거", comment: "음량 0%"), 0),
         ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1)]
    }
    static let rateSteps: [(label: String, value: Float)] = [
        ("0.5×", 0.5), ("1×", 1), ("1.5×", 1.5), ("2×", 2),
    ]
    static let playlistIntervalMinutes = [5, 15, 30, 60]

    /// 가림 정지 옵션(raw: -1=사용 안 함, 0=창 뜨면 즉시, 0.3/0.5/0.8=커버 비율) — 트레이 서브메뉴에서 이관.
    static var occlusionOptions: [(label: String, raw: Double)] {
        [(NSLocalizedString("사용 안 함", comment: "옵션 끔 — 가림 정지·화면보호기 공용"), -1),
         (NSLocalizedString("창이 뜨면 즉시", comment: "가림 정지 임계값"), 0),
         (NSLocalizedString("30% 이상 가려지면", comment: "가림 정지 임계값"), 0.30),
         (NSLocalizedString("50% 이상 가려지면", comment: "가림 정지 임계값"), 0.50),
         (NSLocalizedString("80% 이상 가려지면", comment: "가림 정지 임계값"), 0.80)]
    }

    /// 영속 상태(enabled+threshold) → Picker 선택 raw 역산. 미일치는 방어 폴백(-1).
    static func currentOcclusionRaw(enabled: Bool, threshold: Double) -> Double {
        occlusionOptions.first {
            OcclusionMode.isSelected($0.raw, enabled: enabled, threshold: threshold)
        }?.raw ?? -1
    }

    /// 화면보호기 행 상태. bundled = 앱 번들에 Waple.saver 존재(패키징 앱에서만 true).
    /// "사용 안 함" 은 가림 정지 옵션과 이 자리가 **같은 키를 공유**한다. 영어 한 줄로
    /// 둘 다 성립하는 "Off" 를 골랐다 — 문맥별로 갈라 쓰려고 한국어 원문을 손보면
    /// 그건 영어를 위해 한국어 UI 를 바꾸는 것이라 하지 않는다.
    static func saverStatus(bundled: Bool, selected: Bool) -> (label: String, canToggle: Bool) {
        guard bundled else {
            return (NSLocalizedString("패키징된 앱에서만 사용 가능 — scripts/package-app.sh",
                                      comment: "화면보호기 — 개발 실행"), false)
        }
        return (selected ? NSLocalizedString("화면보호기로 사용 중", comment: "화면보호기 선택됨")
                         : NSLocalizedString("사용 안 함", comment: "옵션 끔 — 가림 정지·화면보호기 공용"),
                true)
    }

    /// 현재 값이 경로라 눈에 잘 띄지 않았을 뿐 같은 병이었다 — 보간이 끼므로 포맷 지정자를 명시한다.
    static func ffmpegStatus(available: Bool, path: String?) -> String {
        available
            ? String(format: NSLocalizedString("사용 가능 — %@", comment: "ffmpeg 경로"), path ?? "")
            : NSLocalizedString("미설치 — mkv/webm 동영상 변환에 필요합니다 (brew install ffmpeg)",
                                comment: "ffmpeg 미설치")
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
    /// 상태바 툴팁은 AppKit 경로(`NSStatusBarButton.toolTip`)라 자동 해석이 없다 —
    /// 배경 제목은 사용자 데이터라 그대로 두고 상태 문구만 감싼다.
    static func tooltip(appliedTitle: String?, isPaused: Bool, hasError: Bool) -> String {
        var parts = [appliedTitle ?? "Waple"]
        if hasError { parts.append(NSLocalizedString("적용 실패", comment: "상태바 툴팁 — 적용 실패")) }
        else if isPaused { parts.append(NSLocalizedString("일시정지됨", comment: "상태바 툴팁 — 정지")) }
        return parts.joined(separator: " · ")
    }
}

/// 최초 실행 온보딩 게이트(앱셸 스코프 B, 순수). 준비 항목 상태·시트 표시는 UI(부수효과)가 담당하고,
/// 여기서는 "완료 플래그가 없으면 1회 표시" 결정만 한다(플래그 영속은 호출자 — UserDefaults).
enum Onboarding {
    static func shouldPresent(completed: Bool) -> Bool { !completed }
}
