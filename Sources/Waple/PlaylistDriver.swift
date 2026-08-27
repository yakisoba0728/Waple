import Foundation
import WapleCore
import WapleLibrary

/// `PlaylistStore`(우리 스키마) → `PlaylistSettings`(WE 스키마) 번역.
///
/// **한 자리에만 둔다.** 두 스키마가 여러 곳에서 각자 매핑되기 시작하면 어느 쪽이 정본인지
/// 알 수 없게 된다. 지금 대응은 이렇다:
///
/// | Waple | WE | 근거 |
/// | --- | --- | --- |
/// | `enabled == false` | `mode = never` | `never` 는 파서가 `delay` 를 0 으로 덮어(0x140075d41) 타이머가 0.01분 가드에 걸려 멎는다 — "자동 전환 끔" 과 정확히 같은 동작이다 |
/// | `enabled == true` | `mode = timer` | 기본값 1 = timer |
/// | `shuffle` | `order = random` / `sorted` | 셔플 켜짐이 곧 WE 의 소진형 셔플백이다 |
/// | `intervalMinutes` | `delay`(분) | WE 는 실수 분(하한 0.01)이고 우리는 정수 분(하한 1)이라 **우리가 더 좁다** |
///
/// 아직 대응이 없는 WE 키(`videosequence`·`beginfirst`·`playintro`·`updateonpause`·
/// `transition*`)는 **전부 끈 값**으로 둔다. 순수층은 그 키들을 전부 모델링하고 있고
/// (`Tests/WapleCoreTests/PlaylistRuntimeTests.swift` 가 잠근다) 여기서 켜지지 않는 이유는
/// 하나뿐이다 — **저장 스키마와 UI 가 아직 없다.** 켜는 것은 그 둘이 생기는 라운드의 일이다.
enum PlaylistSettingsBridge {

    static func settings(enabled: Bool, intervalMinutes: Int, shuffle: Bool) -> PlaylistSettings {
        PlaylistSettings(
            delayMinutes: Float(max(intervalMinutes, 1)),
            order: shuffle ? .random : .sorted,
            mode: enabled ? .timer : .never,
            // 동영상 종료 전진은 아직 통지 경로가 없다(§8.2 갭 #6) — 켜면 타이머가 동영상에서
            // 보류만 하고 아무도 받지 않아 **동영상 배경이 영원히 안 넘어간다**. 끈 채로 둔다.
            videoSequence: false,
            // 종전 `PlaylistScheduling.shouldAdvanceNow(isPaused:)` 와 같은 값 — 정지 중엔 멈춘다.
            updateOnPause: false,
            beginFirst: false,
            playIntro: false,
            // 전환 **렌더러가 없다.** `-1`(= 전환 안 함)이 지금 화면에서 실제로 일어나는 일이다.
            // 여기에 다른 값을 적으면 코드가 렌더링을 약속하는 것처럼 읽힌다.
            transitionConfigValue: PlaylistTransitionKind.noTransition.weConfigValue
        )
    }
}

/// 재생목록 스케줄러의 **앱 측 소비자**. `AppDelegate` 가 붙잡는 것은 이 객체 하나다.
///
/// 왜 `AppDelegate` 밖인가
/// ----------------------
/// `AppDelegate.swift` 는 리눅스 타입체크 제외 파일이라(`APP_EXCLUDED`) 거기 쓴 코드는
/// macOS CI 가 처음 본다. 이 파일은 제외가 아니므로 `linux-render-typecheck.sh --app` 이
/// 매번 타입체크하고, `WapleAppTests` 가 `AppDelegate` 없이 직접 인스턴스화해 판정한다.
/// 그래서 배선의 **판단**은 전부 여기 있고 `AppDelegate` 에는 호출과 마운트만 남는다.
///
/// 시간의 소유자
/// ------------
/// WE 는 프레임 델타를 누적한다(§6.1). 우리는 1초 틱이라 `Date()` 차분을 쓰는데, 그 차분은
/// 절전·시계 조정으로 튈 수 있다 — 그래서 `PlaylistSettings.clampedTickDelta` 의 5초 상한을
/// **순수층이** 걸어 준다. 이 클래스는 마지막 틱 시각만 들고 있는다.
@MainActor
final class PlaylistDriver {

    /// 경과시간을 파일에 되쓰는 최소 간격. 매 틱 쓰면 1초마다 디스크가 돌고, 안 쓰면 강제 종료에
    /// 전부 잃는다. 60초면 최악의 손실이 1분치다.
    static let persistIntervalSeconds: TimeInterval = 60

    private var runtime: PlaylistRuntime
    private let stateTime: PlaylistStateTimeStore
    private let calendar: Calendar
    /// 재생목록 순서대로의 라이브러리 엔트리 id. `runtime.items` 의 인덱스와 1:1 이다.
    private var entryIds: [String] = []
    private var lastTick: Date?
    private var lastPersist: Date?
    /// 마지막으로 본 전역 선택. 우리가 건 것도 다음 sync 에서 여기 들어오므로, 값이 어긋난
    /// 한 틱 동안만 adopt 가 한 번 더 돌고(이미 0 인 시계를 0 으로 되돌린다) 그 뒤로 조용하다.
    private var lastGlobalEntryId: String?
    private var hasSynced = false

    init(stateTime: PlaylistStateTimeStore, calendar: Calendar = .current) {
        self.stateTime = stateTime
        self.calendar = calendar
        self.runtime = PlaylistRuntime()
        // 재부팅 너머로 나른 경과시간 — 없으면 전부 0 에서 시작한다(첫 실행과 같다).
        runtime.restoreElapsed(stateTime.elapsedByScreen)
    }

    /// 스토어와 화면 목록을 다시 읽는다. 매 틱 불러도 되도록 싸게 만들어 뒀다(문자열 배열 비교).
    ///
    /// - Parameter screenKeys: **재생목록이 굴리는 화면만** 넘긴다. 사용자가 `monitors.json` 으로
    ///   고정한 화면은 여기 들어오면 안 된다 — 그 화면은 사용자가 그 배경을 못박은 것이다.
    /// - Parameter currentEntryId: 지금 주 화면에 걸린 전역 선택. **이 값이 우리가 마지막으로 건
    ///   것과 다르면 사용자가 직접 바꾼 것**이므로 그 화면의 시계를 되돌린다. 안 그러면 방금 고른
    ///   배경이 몇 초 만에 넘어간다 — 경과시간이 재부팅 너머로 이어지는 지금은 특히 그렇다
    ///   (앱이 뜨자마자 전 회차의 59분이 살아 있을 수 있다).
    func sync(enabled: Bool,
              intervalMinutes: Int,
              shuffle: Bool,
              ids: [String],
              screenKeys: [String],
              currentEntryId: String?) {
        entryIds = ids
        runtime.apply(settings: PlaylistSettingsBridge.settings(enabled: enabled,
                                                               intervalMinutes: intervalMinutes,
                                                               shuffle: shuffle),
                      items: ids.map { PlaylistItem(file: $0) })
        if runtime.activeScreens != screenKeys { runtime.setActiveScreens(screenKeys) }
        // **첫 sync 는 기준선만 잡는다.** 여기서 adopt 하면 앱이 뜨자마자 파일에서 되살린
        // 경과시간이 0 으로 지워져 영속이 통째로 무의미해진다(복원 → 즉시 리셋).
        if hasSynced, currentEntryId != lastGlobalEntryId, let primary = screenKeys.first {
            adopt(entryId: currentEntryId, screenKey: primary)
        }
        lastGlobalEntryId = currentEntryId
        hasSynced = true
    }

    /// 틱 한 번. **아직 아무것도 걸지 않는다** — 전진하고 싶은 화면 키만 돌려준다.
    ///
    /// - Parameter isVideo: 그 화면에 지금 걸린 것이 동영상인가. 기본값 `false` 가 안전한 이유는
    ///   이 값이 판정에 들어가는 두 관문(0x140076d81·0x140076d87)이 **둘 다 `videosequence`
    ///   또는 인트로 래치가 참일 때만** 살아 있는데, 위 `PlaylistSettingsBridge` 가 그 둘을 모두
    ///   끄기 때문이다. 그 키에 UI 가 생기면 여기에 실제 타입을 넘겨야 한다.
    func tick(now: Date, isPaused: Bool, isVideo: (String) -> Bool = { _ in false }) -> [String] {
        let previous = lastTick ?? now
        lastTick = now
        let delta = Float(now.timeIntervalSince(previous))
        let wants = runtime.tick(deltaSeconds: delta,
                                 isPaused: isPaused,
                                 now: PlaylistClockReading(date: now, calendar: calendar),
                                 isVideo: isVideo)
        persistIfDue(now: now)
        return wants
    }

    /// 한 화면을 실제로 전진시킨다. 후보를 **순서대로 시도해** `apply` 가 성공하는 첫 것으로 확정한다.
    ///
    /// 실패 후보를 건너뛰는 것이 요점이다 — 라이브러리에서 지워졌거나 폴더가 사라진 항목 하나가
    /// 재생목록을 그 자리에 영구 정지시킨 이력이 있다(`PlaylistScheduling.advance` 독스트링).
    /// 한 바퀴(항목 수)까지만 돈다.
    ///
    /// - Returns: 실제로 걸린 엔트리 id. 전부 실패하면 `nil`(기존 배경 유지).
    @discardableResult
    func advance(screenKey: String, now: Date, apply: (String) -> Bool) -> String? {
        let reading = PlaylistClockReading(date: now, calendar: calendar)
        for _ in 0..<entryIds.count {
            guard let index = runtime.nextCandidate(screenKey: screenKey, now: reading) else { return nil }
            guard entryIds.indices.contains(index) else { continue }
            let id = entryIds[index]
            if apply(id) {
                runtime.commit(index: index, screenKey: screenKey)
                persist(now: now)   // 경과시간이 0 이 됐다 — 이 상태를 잃으면 되살릴 근거가 없다
                return id
            }
        }
        return nil
    }

    /// 사용자가 그 화면의 배경을 직접 바꿨다. 전진이 아니므로 시계만 되돌린다.
    func adopt(entryId: String?, screenKey: String) {
        runtime.adopt(index: entryId.flatMap { entryIds.firstIndex(of: $0) }, screenKey: screenKey)
    }

    /// 화면별 경과시간(초) — 진단·테스트용.
    var elapsedByScreen: [String: Float] { runtime.elapsedByScreen }

    /// 지금 상태를 파일에 쓴다. 종료 직전에 부른다.
    func persist(now: Date = Date()) {
        lastPersist = now
        stateTime.save(runtime.elapsedByScreen, now: now)
    }

    private func persistIfDue(now: Date) {
        guard let last = lastPersist else { lastPersist = now; return }
        guard now.timeIntervalSince(last) >= Self.persistIntervalSeconds else { return }
        persist(now: now)
    }
}
