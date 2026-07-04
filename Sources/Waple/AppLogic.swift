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

/// 마운트 트랜잭션: 전부 성공해야 교체, 하나라도 실패하면 부분 정리 후 롤백(이전 렌더러 유지).
enum RendererSwap {
    /// `screens` 를 순서대로 mount 시도.
    /// - 전부 성공 → `existing` 을 teardown 하고 새 렌더러 세트를 `.success` 로 반환.
    /// - mount 가 throw → 지금까지 만든 새 렌더러만 teardown, `existing` 은 건드리지 않고 에러를 `.failure` 로 전파.
    /// - `makeAndMount` 가 nil 반환(지원 안 하는 화면) → **스킵**(continue). throw 와 구분한다.
    static func apply<S, R>(
        screens: [S],
        existing: [R],
        makeAndMount: (S) throws -> R?,
        teardown: (R) -> Void
    ) -> Result<[R], Error> {
        var made: [R] = []
        for s in screens {
            do {
                guard let r = try makeAndMount(s) else { continue }  // 지원 안 함 → 스킵
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

    /// 다음에 적용할 엔트리 id. `next` 로 순환 후보를 구하고, 실제 존재하는 엔트리일 때만 반환.
    static func nextApplicableId(
        after selected: String?,
        next: (String?) -> String?,
        entryExists: (String) -> Bool
    ) -> String? {
        guard let id = next(selected), entryExists(id) else { return nil }
        return id
    }
}
