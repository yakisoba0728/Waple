import Foundation

// WE(2.8.42) 재생목록 **스케줄링 층**의 조립기.
//
// 왜 따로 있는가
// -------------
// `PlaylistTransition.swift` 는 조각을 전부 갖고 있었지만 **아무도 그 조각들을 엮지
// 않았다** — 경과시간 축(§6.1)·모드 디스패치(§6.2/§6.3)·순서 디스패치(§6.4/§6.5)·
// 동영상 종료(§6.6)가 각자 옳은 답을 내는데, "지금 이 화면이 다음에 무엇을 걸어야
// 하는가" 를 묻는 자리가 없었다. 그래서 순수층 참조가 `Tests/` 48건 · `Sources/` 0건이
// 됐다. 이 파일이 그 자리다.
//
// **여기까지가 GPU 없이 판정되는 범위다.** 전환 *효과*(27종 셰이더)는 이 층에 없다 —
// `PlaylistTransitionKind`/`TransitionTimeline`/`PlaylistRandomDraw` 는 "어떻게 보이는가"
// 이고 그건 Metal 파이프라인과 실기 눈이 있어야 판정된다. 이 파일은 "언제 · 무엇을" 만
// 답한다. 전환 렌더러가 생기면 그때 `settings.transition` 을 여기 결정에 붙이면 된다.
//
// 이 파일은 `import Foundation` 하나만 쓴다 — `scripts/dev/linux-core-tests.sh` 에서 돈다.

// MARK: - 시계

/// 시각 기반 모드가 보는 "지금". **주입**한다 — `Date()` 를 안에서 읽으면 daytime/dayofweek
/// 를 결정적으로 테스트할 방법이 사라진다(WE 는 `localtime`/`GetLocalTime` 을 직접 부른다).
public struct PlaylistClockReading: Equatable, Sendable {
    /// 0…23.
    public var hour: Int
    /// 0…59. **초는 안 본다** — WE 도 분 해상도다(§6.2).
    public var minute: Int
    /// `SYSTEMTIME.wDayOfWeek` 규약 — **일요일 = 0**.
    public var weekday: Int
    /// `LOCALE_IFIRSTDAYOFWEEK` 규약 — **월요일 = 0 … 일요일 = 6**.
    public var firstDayOfWeek: Int

    public init(hour: Int, minute: Int, weekday: Int, firstDayOfWeek: Int) {
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.firstDayOfWeek = firstDayOfWeek
    }

    /// `Calendar` 에서 읽는다. 두 열거의 **원점이 셋 다 다르다**:
    ///   · `Calendar.component(.weekday)` 는 1 = 일요일 → WE 는 0 = 일요일이라 `-1`.
    ///   · `Calendar.firstWeekday` 도 1 = 일요일 → WE 는 0 = 월요일이라 `(x + 5) % 7`
    ///     (일요일 시작 `1` → 6, 월요일 시작 `2` → 0).
    /// 원점을 한 자리에서만 옮기려고 이 이니셜라이저를 둔다.
    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
        weekday = (parts.weekday ?? 1) - 1
        firstDayOfWeek = (calendar.firstWeekday + 5) % 7
    }
}

// MARK: - 화면 한 장

/// 화면 하나의 재생목록 진행 상태. WE 의 모니터 노드 `+0x50`(셔플백) · `+0x78`(sorted 커서) ·
/// `+0x7c`(경과시간) · `+0xe2`(인트로 래치)에 대응한다.
///
/// **화면마다 하나씩 갖는 것이 요점이다.** WE 는 이 넷을 전부 모니터 노드 안에 두고
/// 매 프레임 모니터 리스트를 순회한다(§6.1) — 전역 카운터가 아니다. 그래서
/// `playliststatetime.bin` 도 모니터 이름을 키로 경과시간을 나른다(§7).
///
/// `Sendable` 이 아니다: `ShuffleBag` 이 `SplitMix64` 때문에 조건부 적합을 못 세운다.
/// 값 타입이므로 액터/큐 하나 안에서 쓴다.
public struct PlaylistScreenScheduler {

    /// WE `+0x7c`(float 초). 전진할 때 0 으로 지워진다(0x1400684ea).
    public private(set) var elapsedSeconds: Float = 0
    /// 지금 이 화면에 걸린 항목의 인덱스. 아직 아무것도 안 걸었으면 `nil`.
    public private(set) var currentIndex: Int?
    /// WE `+0xe2` — "지금 걸린 것이 인트로 벽지". `beginfirst` 경로만 1 을 심는다.
    public private(set) var introShowing = false

    private var cursor = PlaylistSortedCursor()
    private var bag: ShuffleBag<Int>
    /// 백을 만들 때의 항목 수·`playintro`. 둘 중 하나라도 바뀌면 백을 새로 만든다
    /// (WE 도 설정 재적용 때 백을 새로 만든다 — `ShuffleBag.source`/`playIntro` 는 `let`).
    private var bagItemCount: Int
    private var bagPlayIntro: Bool
    private let seed: UInt64

    /// - Parameter seed: 화면마다 다른 값을 주면 두 화면이 같은 수열을 걷지 않는다.
    public init(seed: UInt64) {
        self.seed = seed
        self.bagItemCount = 0
        self.bagPlayIntro = false
        self.bag = ShuffleBag(items: [], seed: seed, playIntro: false)
    }

    private mutating func syncBag(itemCount: Int, playIntro: Bool) {
        guard itemCount != bagItemCount || playIntro != bagPlayIntro else { return }
        bagItemCount = itemCount
        bagPlayIntro = playIntro
        bag = ShuffleBag(items: Array(0..<max(itemCount, 0)), seed: seed, playIntro: playIntro)
    }

    /// 순서(order) 디스패치. `random` 은 소진형 셔플백, `sorted` 는 커서다.
    /// 백/커서를 **실제로 소모한다** — 후보가 마운트에 실패해도 그 소모는 되돌리지 않는다
    /// (WE 도 뽑은 항목을 백에서 지운 뒤에 건다).
    private mutating func drawByOrder(settings: PlaylistSettings, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        syncBag(itemCount: itemCount, playIntro: settings.playIntro)
        switch settings.order {
        case .random:
            return bag.next(current: currentIndex)
        case .sorted:
            return cursor.next(count: itemCount, playIntro: settings.playIntro)
        }
    }

    /// 다음에 걸 후보. **아직 확정하지 않는다** — 마운트가 실패할 수 있으므로
    /// 성공했을 때 호출부가 `commit(index:)` 를 부른다.
    ///
    /// 모드 디스패치가 여기 있다:
    ///   · `daytime`   → `PlaylistDaytime.index(items:normalizedNow:)`
    ///   · `dayofweek` → `PlaylistDayOfWeek.index(weekday:firstDayOfWeek:)`
    ///   · 그 밖       → 순서(order) 디스패치
    public mutating func nextCandidate(settings: PlaylistSettings,
                                       items: [PlaylistItem],
                                       now: PlaylistClockReading) -> Int? {
        guard !items.isEmpty else { return nil }
        switch settings.mode {
        case .daytime:
            let normalized = PlaylistDaytime.normalizedTimeOfDay(hour: now.hour, minute: now.minute)
            return PlaylistDaytime.index(items: items, normalizedNow: normalized)
        case .dayOfWeek:
            let slot = PlaylistDayOfWeek.index(weekday: now.weekday, firstDayOfWeek: now.firstDayOfWeek)
            // UI 가 7개를 넘기지 못하게 막지만(§6.3) 목록이 그보다 짧을 수는 있다 —
            // 그 슬롯에 항목이 없으면 걸 것이 없다(전진 안 함).
            return slot < items.count ? slot : nil
        case .logon, .timer, .never:
            return drawByOrder(settings: settings, itemCount: items.count)
        }
    }

    /// 후보가 실제로 걸렸다. 경과시간을 0 으로 지우고 인트로 래치를 내린다
    /// (0x1400684ea `mov [r14+0x7c], 0` · 0x140067ff2 `mov byte [rax+0xe2], 0`).
    public mutating func commit(index: Int) {
        currentIndex = index
        elapsedSeconds = 0
        introShowing = false
    }

    /// 사용자가 이 화면의 벽지를 직접 바꿨다 — 전진이 아니므로 경과시간만 되돌린다.
    public mutating func adopt(index: Int?) {
        currentIndex = index
        elapsedSeconds = 0
        introShowing = false
    }

    /// `beginfirst` 첫 걸기(0x140067ebe–0x140067edc). 커서를 0 으로 되돌리고 첫 항목을 걸며,
    /// `playintro` 값을 인트로 래치에 그대로 심는다.
    ///
    /// - Returns: 첫 항목을 실제로 걸었는가. `beginfirst` 가 꺼져 있거나 목록이 비었으면 `false`.
    @discardableResult
    public mutating func begin(settings: PlaylistSettings, items: [PlaylistItem]) -> Bool {
        guard settings.beginFirst, !items.isEmpty else { return false }
        cursor.reset()
        currentIndex = 0
        elapsedSeconds = 0
        introShowing = settings.playIntro
        return true
    }

    /// 타이머 틱 한 번. **누적과 판정을 순수층 두 함수에 그대로 위임한다** —
    /// 여기서 규칙을 다시 적지 않는다.
    ///
    /// `daytime`/`dayofweek` 는 경과시간 축을 안 쓴다(§6.1-3). WE 는 그 자리에서 틱 함수의
    /// 세 번째 인자(bool)를 보는데 **누가 무엇을 넘기는지가 미해결**이라 그대로 옮길 수 없다.
    /// 그래서 재구현 판단으로 **"지금 시각이 고르는 항목이 걸린 것과 다르면 전진"** 을 쓴다 —
    /// 관찰되는 동작(시간대가 바뀌면 그 시간대 벽지로 넘어간다)이 같고, 같은 슬롯 안에서는
    /// 아무 일도 일어나지 않는다. **이건 WE 주장이 아니다.**
    ///
    /// **후보를 뽑지 않는다.** "넘어가야 하는가" 까지만 답하고, 무엇으로 넘어갈지는 호출부가
    /// `nextCandidate` 로 따로 묻는다. 둘을 한 함수로 합치면 마운트가 실패했을 때 이미 소모된
    /// 셔플백을 되돌릴 방법이 없고, 호출부는 "후보를 하나 더 달라" 고 할 수도 없다.
    ///
    /// - Returns: 이 틱에서 전진해야 하는가.
    public mutating func tick(deltaSeconds: Float,
                              isPaused: Bool,
                              currentIsVideo: Bool,
                              settings: PlaylistSettings,
                              items: [PlaylistItem],
                              now: PlaylistClockReading) -> Bool {
        guard !items.isEmpty else { return false }

        if settings.accumulatesElapsed(isPaused: isPaused) {
            elapsedSeconds += PlaylistSettings.clampedTickDelta(deltaSeconds)
        }

        if !settings.mode.usesTimerTick {
            // 시각 기반 모드 — 위 독스트링의 재구현 판단. `nextCandidate` 는 이 두 모드에서
            // 백/커서를 건드리지 않으므로(시각이 인덱스를 직접 고른다) 여기서 불러도 소모가 없다.
            if isPaused && !settings.updateOnPause { return false }
            guard let wanted = nextCandidate(settings: settings, items: items, now: now) else { return false }
            return wanted != currentIndex
        }

        return settings.shouldTimerAdvance(elapsedSeconds: elapsedSeconds,
                                           isPaused: isPaused,
                                           currentIsVideo: currentIsVideo,
                                           introShowing: introShowing)
    }

    /// 동영상이 끝났다(§6.6). 관문은 `shouldAdvanceOnVideoEnd(introShowing:)` 하나다.
    /// `tick` 과 같은 이유로 후보는 뽑지 않는다.
    public func shouldAdvanceOnVideoEnd(settings: PlaylistSettings, items: [PlaylistItem]) -> Bool {
        guard !items.isEmpty else { return false }
        return settings.shouldAdvanceOnVideoEnd(introShowing: introShowing)
    }

    /// 재부팅 너머로 나른 경과시간을 되살린다(`playliststatetime.bin`, §7).
    /// 음수·NaN 은 0 으로 내린다 — 파일은 신뢰 경계 밖이다.
    public mutating func restore(elapsedSeconds seconds: Float) {
        elapsedSeconds = seconds.isFinite ? max(seconds, 0) : 0
    }
}

// MARK: - 화면 전체

/// 화면별 스케줄러의 모음. 설정·항목은 전 화면이 공유하고 **진행 상태만 화면별**이다.
///
/// WE 도 같은 모양이다 — 재생목록 설정은 모니터 노드에 복사돼 들어가지만(§6.1) 값은
/// 같은 원본에서 온 것이고, 갈리는 것은 백/커서/경과시간이다.
public struct PlaylistRuntime {

    /// 파서 상호 의존을 적용한 뒤의 설정(`normalized()`). 직접 대입하지 말고 `apply` 를 써라.
    public private(set) var settings: PlaylistSettings
    public private(set) var items: [PlaylistItem]
    /// 지금 붙어 있는 화면. 순서는 호출부가 준 순서 그대로다(첫 원소 = 주 화면).
    public private(set) var activeScreens: [String] = []

    private var screens: [String: PlaylistScreenScheduler] = [:]
    private let seedBase: UInt64

    public init(settings: PlaylistSettings = PlaylistSettings(),
                items: [PlaylistItem] = [],
                seed: UInt64 = 0x5DEECE66D) {
        self.settings = settings.normalized()
        self.items = items
        self.seedBase = seed
    }

    /// 설정·항목 갱신. **정규화를 여기서 한 번만 한다** — 호출부가 잊으면 `beginfirst`/
    /// `playintro` 상호 의존이 조용히 어긋난다.
    public mutating func apply(settings newSettings: PlaylistSettings, items newItems: [PlaylistItem]) {
        settings = newSettings.normalized()
        items = newItems
    }

    /// 붙어 있는 화면 목록을 맞춘다. **사라진 화면의 상태는 지우지 않는다** —
    /// 모니터를 뺐다 끼우면 경과시간·커서가 이어져야 한다(WE 도 모니터 **이름**을 키로
    /// 경과시간을 파일에 남긴다, §7). 화면 키는 `CGDirectDisplayID` 기반이라 안정적이다.
    public mutating func setActiveScreens(_ keys: [String]) {
        activeScreens = keys
        for key in keys where screens[key] == nil {
            screens[key] = PlaylistScreenScheduler(seed: seed(for: key))
        }
    }

    /// 화면 키 → 시드. **`String.hashValue` 를 쓰지 않는다** — 스위프트의 문자열 해시는
    /// 프로세스마다 시드가 달라서 같은 모니터가 실행마다 다른 수열을 걷고, 테스트로 잠글
    /// 수도 없다. FNV-1a 64 는 어디서 돌려도 같은 값이다.
    private func seed(for key: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(truncatingIfNeeded: byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return seedBase &+ hash
    }

    public func scheduler(for key: String) -> PlaylistScreenScheduler? { screens[key] }

    /// 화면별 경과시간(초). `playliststatetime.bin` 에 그대로 실린다.
    public var elapsedByScreen: [String: Float] {
        screens.mapValues { $0.elapsedSeconds }
    }

    /// 파일에서 되살린다. 모르는 키는 무시하지 않고 **자리를 만들어 담는다** —
    /// 아직 안 붙은 모니터(다음 부팅에 다시 붙을)의 값을 잃지 않기 위해서다.
    public mutating func restoreElapsed(_ map: [String: Float]) {
        for (key, seconds) in map {
            var s = screens[key] ?? PlaylistScreenScheduler(seed: seed(for: key))
            s.restore(elapsedSeconds: seconds)
            screens[key] = s
        }
    }

    /// 한 화면의 다음 후보. 확정은 `commit` 이다.
    public mutating func nextCandidate(screenKey: String, now: PlaylistClockReading) -> Int? {
        guard var s = screens[screenKey] else { return nil }
        let index = s.nextCandidate(settings: settings, items: items, now: now)
        screens[screenKey] = s
        return index
    }

    public mutating func commit(index: Int, screenKey: String) {
        guard var s = screens[screenKey] else { return }
        s.commit(index: index)
        screens[screenKey] = s
    }

    public mutating func adopt(index: Int?, screenKey: String) {
        guard var s = screens[screenKey] else { return }
        s.adopt(index: index)
        screens[screenKey] = s
    }

    /// 전 화면의 타이머 틱. 전진할 화면만 돌려준다(순서는 `activeScreens` 순서).
    ///
    /// - Parameter isVideo: 그 화면에 지금 걸린 것이 동영상인가 — WE 는 벽지 객체에
    ///   타입을 묻는다(0x140076d79 `call [rax+0x20]` → `cmp eax, 4`).
    /// - Returns: 이 틱에서 **전진해야 하는 화면 키**(`activeScreens` 순서). 무엇으로 넘어갈지는
    ///   호출부가 `nextCandidate` 로 따로 묻는다 — 마운트 실패 시 다음 후보를 요구할 수 있어야 한다.
    public mutating func tick(deltaSeconds: Float,
                              isPaused: Bool,
                              now: PlaylistClockReading,
                              isVideo: (String) -> Bool = { _ in false }) -> [String] {
        var out: [String] = []
        for key in activeScreens {
            guard var s = screens[key] else { continue }
            let wants = s.tick(deltaSeconds: deltaSeconds,
                               isPaused: isPaused,
                               currentIsVideo: isVideo(key),
                               settings: settings,
                               items: items,
                               now: now)
            screens[key] = s
            if wants { out.append(key) }
        }
        return out
    }

    /// 한 화면의 동영상이 끝났다 — 전진해야 하는가.
    public func shouldAdvanceOnVideoEnd(screenKey: String) -> Bool {
        screens[screenKey]?.shouldAdvanceOnVideoEnd(settings: settings, items: items) ?? false
    }

    /// `beginfirst` — 앱이 뜨자마자 첫 항목을 건다. 확정까지 여기서 한다(후보가 언제나 0 이라
    /// 고를 것이 없다).
    ///
    /// - Returns: 첫 항목을 건 화면 키.
    public mutating func begin() -> [String] {
        var out: [String] = []
        for key in activeScreens {
            guard var s = screens[key] else { continue }
            if s.begin(settings: settings, items: items) { out.append(key) }
            screens[key] = s
        }
        return out
    }

    /// 그 화면에 지금 걸린 항목의 인덱스.
    public func currentIndex(for key: String) -> Int? { screens[key]?.currentIndex }
}
