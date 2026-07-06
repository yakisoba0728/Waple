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

enum ScreenChangeLifecycle {
    static func detachRenderersBeforeRebuild<R>(
        existing: inout [R],
        teardown: (R) -> Void
    ) {
        let old = existing
        existing.removeAll()
        old.forEach(teardown)
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

/// 속성 편집 UI 결정(순수).
enum PropertyControl {
    /// 슬라이더 범위. min>max·min==max·음수 상한 등 비정상 경계에서도 항상 유효한 오름차순 범위를 만든다.
    /// ClosedRange 는 lower<=upper 를 요구하므로(위반 시 트랩=앱 크래시), 제3자 콘텐츠의 뒤집힌/축퇴
    /// 경계를 하한 기준으로 클램프한다. 상한 부재 시 하한+1.
    static func sliderRange(min: Double?, max: Double?) -> ClosedRange<Double> {
        let lo = min ?? 0
        let hi = Swift.max(lo + 0.0001, max ?? (lo + 1))
        return lo...hi
    }
}
