import Foundation
import WapleCore
import WaplePolicy

// MARK: - 두 정지 경로의 합류 (stage 2c)
//
// [2026-08-26] Waple 에는 렌더 정지를 요구하는 경로가 **둘**이고, 둘은 모양이 다르다.
//
//   · `PauseGate` — 사유 집합(가림·수동·시스템 슬립·디스플레이 슬립)을 합성해
//     **전 렌더러 일괄** pause/resume 을 낸다. 모니터 구분이 없다.
//   · 재생정책 — `PlaybackVerdict` 로 **모니터별 `pauseMask`** + `muted`(전역) +
//     `stop`(렌더러 해제) 세 차원을 낸다.
//
// 셋 중 하나를 골라야 했다: ① 정책을 `PauseGate` 의 다섯째 사유로 접어 넣기(가장 작지만
// 모니터별 정지를 버린다 — WE 충실도 손실) ② `PauseGate` 를 모니터별로 확장(정확하지만
// 기존 네 사유의 의미를 전부 건드린다) ③ **두 층을 분리한 채 "둘 중 하나라도 멈추라면
// 멈춘다" 로 합치기.**
//
// ③ 을 택했다. 기존 네 사유의 의미가 그대로 남고, 모니터별 정지도 살고, 합성 규칙 자체가
// 순수 함수라 테스트된다. 대가는 정지 상태가 두 곳에 산다는 것이고, 그래서 **합류를 이
// 한 파일에 가둔다** — `AppDelegate` 는 여기가 낸 결정을 적용만 한다.

enum RenderPauseComposition {
    /// 렌더러 하나에 대한 결정.
    struct Decision: Equatable {
        /// 이 렌더러를 멈춰야 하는가. 전역 사유와 정책 중 **하나라도** 요구하면 true.
        let paused: Bool
        /// 정책이 `stop`(렌더러 해제)을 요구했는가.
        ///
        /// **의도적으로 정지로 축소한다 — 이것은 미결이 아니라 결론이다.** 근거는 아래
        /// `stopIsReducedToPause` 에 적었다. 이름을 남기는 것은 그 축소를 세는 자리가
        /// 있어야 하기 때문이다.
        let policyWantsStop: Bool
        /// 정책이 `muted` 를 요구했는가. WE 에서 음소거는 모니터별이 아니라 **전역**이라
        /// (판정 타입 주석) 이 값이 화면마다 갈리면 `wantsGlobalMute(_:)` 가 하나로 접는다.
        ///
        /// [2026-08-27 stage 3①] **이제 실제로 적용된다.** `WallpaperRenderer.setPolicyMuted(_:)`
        /// 가 생겼고 `AppDelegate.applyPlaybackPolicy` 가 전 렌더러에 같은 값을 먹인다.
        let policyWantsMute: Bool
    }

    // MARK: - `stop` 을 정지로 접는다 — 왜 그것이 옳은가 (stage 3②)
    //
    // [2026-08-27] stage 2 는 이 축소를 "표면이 없어서 못 한다" 로 적었다. stage 3 에서
    // **적극적인 선택으로 승격한다.** 셋을 놓고 골랐다:
    //
    //   (a) 축소를 유지하고 이유를 분명히 한다        ← **택했다**
    //   (b) `teardown()` + 재마운트로 진짜 해제한다
    //   (c) 중간 형태 — 마운트를 잃지 않는 범위에서 자원을 부분 반납한다
    //
    // **(b) 를 버린 결정타는 `stop` 의 지배적 발동원이 무엇인지 세어 본 것이다.**
    // WE 기본값은 `playbacksleep = stop` 이고(`PlaybackTrigger.displaySleep.weDefault`),
    // 평가기는 그 축이 `stop` 일 때 절전 래치에서 실제로 `stop: true` 를 낸다
    // (`PlaybackEvaluator.evaluate` 의 ⑨ — `sleepLatched && policy.displaySleep == .stop`).
    // 즉 (b) 를 넣으면 **디스플레이가 절전에 들 때마다 전 화면 벽지가 해제되고 깨어날 때마다
    // 재마운트된다.** 하루에 수십 번 도는 경로다. 그 경로에서:
    //   · `mount(in:project:)` 는 `throws` 다. 깨어나는 순간 한 번 실패하면 사용자는
    //     **검은 바탕화면**을 얻고, 되돌릴 방법은 라이브러리에서 다시 적용하는 것뿐이다.
    //     `RendererSwap` 의 롤백은 교체 실패를 막지 나중에 실패한 재마운트를 막지 못한다.
    //   · 셰이더 재컴파일·씬 상태 소실이 매 절전마다 반복되는데 그 비용을 **잰 적이 없다**.
    // 이 컨테이너에도 CI 에도 데스크탑이 없어 둘 다 검증할 수 없다. 검증할 수 없는 변경을
    // 하루 수십 번 도는 경로에 넣는 것은, 게다가 실패 양식이 "벽지가 사라진 채 안 돌아옴"
    // 인 것은, 충실도로 정당화되지 않는다.
    //
    // **(c) 를 버린 이유는 다르다 — 안전해 보이는데 확인할 수 없다.** 실제로 반납할 만한 것은
    // `SceneRenderer` 의 GPU 텍스처 풀(`releasePooledGPUTextures()`, 4K rgba16Float 항목당 ≈88MB)
    // 인데, 그 풀은 프레임 간 지속 FBO(모션블러 누적)의 재사용을 **순서로** 보장하도록
    // 설계돼 있고(`beginFramePool()` 주석), 살아 있는 렌더러에서 비웠을 때 무엇이 달라지는지는
    // 프레임을 한 장도 못 그리는 여기서 판정할 수 없다. 반납량은 추정이고 위험은 GPU 경로다 —
    // 근거 없이 이득을 가정하는 쪽에 서지 않는다.
    //
    // **축소가 실제로 무엇을 잃는가:** 사용자가 보는 것은 같다(양쪽 다 화면이 멈춘다).
    // 다른 것은 **메모리를 놓지 않는다**는 것 하나뿐이고, 지배적 발동원인 절전 구간에서는
    // 어차피 화면이 꺼져 있다. 그래서 이 축소는 "WE 보다 약하다" 가 맞지만 **사용자가 보는
    // 화면에서는 구분되지 않는다.** 그 사실이 (b) 의 위험을 감수할 이유를 더 없앤다.
    //
    // 설정 UI(stage 3④)는 이 축소를 **화면에서 말한다** — `stop` 을 고를 수 있게 두되
    // (WE 값 호환을 위해 저장 값은 그대로 `"stop"` 이다) 지금 일시정지로 동작한다고 적는다.
    // 조용히 다르게 동작하는 것이 이 리포가 막으려는 실패다.
    //
    // 되돌리려는 사람에게: (b) 로 가려면 **먼저 실기에서** ① 절전→깨어남 왕복 100회에
    // 재마운트가 한 번도 실패하지 않는지 ② 재마운트 비용이 절전 복귀 체감을 해치지 않는지를
    // 재라. 그 두 수치 없이 이 축소를 걷는 것은 이 주석을 읽지 않은 것과 같다.

    /// `stop` 이 정지로 접힌다는 사실 자체. 상수로 두는 이유는 이 축소가 **결론**이라는 것을
    /// 코드에서 읽을 수 있게 하려는 것이고, 오라클이 이 값을 근거로 단언할 수 있게 하려는 것이다.
    static let stopIsReducedToPause = true

    /// 합류 규칙. **전역 사유가 서 있으면 정책을 보지 않고 멈춘다** — 그쪽이 더 강한 요구다.
    ///
    /// `stop` 은 `PlaybackVerdict` 안에서 이미 다른 둘을 가리므로(그 타입 주석),
    /// 여기서는 "정지" 로만 접는다. 그 축소의 근거는 위 `stopIsReducedToPause` 블록에 있다.
    static func decide(globallyPaused: Bool,
                       verdict: PlaybackVerdict,
                       monitorIndex: Int) -> Decision {
        let policyPauses = verdict.stop || verdict.isPaused(monitorIndex: monitorIndex)
        return Decision(paused: globallyPaused || policyPauses,
                        policyWantsStop: verdict.stop,
                        policyWantsMute: verdict.muted)
    }

    /// 렌더러 배열 전체분(판정 하나를 공유). 여기서는 **배열 위치를 그대로 모니터 인덱스로 쓴다** —
    /// 판정이 하나뿐이라 호출자가 "0..<n 번 모니터에 대해 이 판정을 풀어라" 를 요구한 것으로 읽는다.
    ///
    /// > ~~인덱스가 곧 모니터 인덱스다 — `AppDelegate.renderers` 가 `desktopController.screenViews`
    /// > 와 같은 순서로 만들어지기 때문이고, 그 불변식이 깨지면 여기 결정이 엉뚱한 화면에 간다.~~
    ///
    /// **[정정 2026-08-30] 위 문장이 근거로 든 사실이 틀렸고, 그래서 예고한 실패가 실제로 났다.**
    /// `renderers` 는 `screenViews` 순서가 아니라 **`screenViews` 를 nil 슬롯에서 떨어뜨린
    /// `screenProjects` 순서**로 만들어졌다(`AppDelegate.applyResolved` 의 `compactMap`).
    /// 즉 빈 슬롯이 하나라도 앞에 있으면 renderers 인덱스는 모니터 인덱스보다 작아지고,
    /// 마스크 쪽은 `NSScreen.screens` 위치로 만들어지므로(`AppDelegate` 의
    /// `screenFrames: screens.map(\.frame)`) 첫 빈 슬롯 이후 모든 화면이 **다른 화면의 pause
    /// 결정**을 받았다. 주석이 예고한 "엉뚱한 화면에 간다" 가 곧 당시의 실동작이었다.
    ///
    /// **전제조건(좁다 — 넓게 적으면 그것이 다음 세션의 거짓이 된다):** 스큐는 `global == nil`,
    /// 즉 **전역 선택 없이 화면별 할당만으로 적용하는 모드**에서만 났다. `MonitorMapping.
    /// resolveProjectSlots` 는 global 이 nil 일 때만 nil 슬롯을 낸다(다른 실패 경로는 전부
    /// `return global`). 전역 벽지가 걸려 있으면 슬롯이 전부 채워져 compactMap 이 아무것도
    /// 떨어뜨리지 않고 두 인덱스가 일치했다. 그 모드는 `AppDelegate.applyCurrentSelection` 이
    /// `applyResolved(global: nil, folderURL: nil)` 로 도달하는 **공식 지원 경로**다(F029).
    ///
    /// **이제는 관례가 아니라 타입이 강제한다.** 프로덕션이 부르는 것은 아래
    /// `decideAll(globallyPaused:projects:conditions:global:)` 하나뿐이고(이 오버로드의
    /// 프로덕션 호출부는 0건 — 테스트 전용이다), 그 오버로드는 배열 위치를 쓰지 않고
    /// **호출자가 실제 모니터 인덱스를 함께 넘기게** 시그니처로 요구한다. 실측 오라클은
    /// `PlaybackPolicyCompositionTests.testPerProjectDecideAllUsesRealMonitorIndexNotArrayPosition`
    /// (빈 슬롯 레이아웃 — 화면 2개 중 1번만 마운트, `fullscreenMask: 0b10` → 그 렌더러가 정지).
    static func decideAll(globallyPaused: Bool,
                          verdict: PlaybackVerdict,
                          rendererCount: Int) -> [Decision] {
        (0..<max(0, rendererCount)).map {
            decide(globallyPaused: globallyPaused, verdict: verdict, monitorIndex: $0)
        }
    }

    /// **화면마다 벽지가 다를 수 있다.** `AppDelegate` 는 `screenProjects` 로 화면별 프로젝트를
    /// 받아 렌더러를 만든다 — 그래서 정책도 렌더러마다 다르게 나온다(벽지별 선언이 다르므로).
    /// 판정 하나를 전 화면에 쓰면 A 화면 벽지의 선언이 B 화면을 멈추는 오적용이 된다.
    ///
    /// 전역 정책은 하나이고(사용자 설정), 조건도 하나다(시스템 상태). 갈리는 것은
    /// **벽지가 선언한 덮어쓰기**뿐이라 여기서 프로젝트별로 접는다.
    ///
    /// **[2026-08-30] `monitorIndex` 를 호출자가 명시한다 — 배열 위치를 쓰지 않는다.**
    /// 종전에는 `projects.enumerated()` 의 오프셋을 그대로 `monitorIndex` 로 먹였는데,
    /// 그 전제("렌더러 배열 위치 == 모니터 인덱스")가 빈 슬롯 레이아웃에서 깨져 있었다
    /// (위 오버로드의 [정정 2026-08-30] 에 전말과 전제조건을 적었다). 위치를 못 쓰게
    /// **시그니처로 막는다** — 마스크가 `NSScreen.screens` 위치로 만들어지므로 여기 인덱스도
    /// 같은 기준이어야 하고, 그 기준을 아는 것은 렌더러를 만든 쪽(`AppDelegate`)뿐이다.
    /// 반환 배열의 순서·길이는 `projects` 그대로다 — 적용부(`PerRendererPauseState`)가
    /// 렌더러 배열 위치로 짝짓기 때문이다(그쪽은 양변이 같은 배열이라 자기정합적이다).
    static func decideAll(globallyPaused: Bool,
                          projects: [(monitorIndex: Int, project: WallpaperProject)],
                          conditions: PlaybackConditions,
                          global: PlaybackPolicy) -> [Decision] {
        projects.map { entry in
            let verdict = PlaybackPolicyResolver.verdict(for: entry.project, conditions: conditions, global: global)
            return decide(globallyPaused: globallyPaused, verdict: verdict, monitorIndex: entry.monitorIndex)
        }
    }

    /// 전역 음소거 — 화면마다 벽지가 다르면 판정도 갈리는데 **WE 의 음소거는 전역**이라
    /// (`PlaybackVerdict.muted` 주석: 적용기가 인스턴스마다 같은 값을 먹인다) 하나로 접어야 한다.
    ///
    /// OR 로 접는 이유: 어느 화면의 벽지든 "지금은 조용히 하라" 를 요구했으면 그 요구를 무시할
    /// 근거가 없다. AND 로 접으면 화면 하나가 `run` 이라는 이유로 나머지 전부의 음소거가 사라진다.
    ///
    /// 정지와 달리 **틀렸을 때의 대가가 작다** — 소리가 잠깐 덜 나는 것과, 멈춰야 할 화면이 도는
    /// 것은 무게가 다르다. 그래서 여기서는 강한 쪽(OR)으로 접는다.
    static func wantsGlobalMute(_ decisions: [Decision]) -> Bool {
        decisions.contains { $0.policyWantsMute }
    }
}

// MARK: - 엣지 추적
//
// `PauseGate` 가 "경계를 안 넘으면 렌더 무동작" 을 지키는 것과 같은 이유다. 조건 폴링은
// 1초마다 돌므로, 매번 `pause()` 를 부르면 렌더러가 초당 한 번씩 같은 요청을 받는다.

/// 렌더러별 마지막 적용 상태를 들고, **바뀐 것만** 돌려준다.
struct PerRendererPauseState: Equatable {
    private var applied: [Bool] = []

    init() {}

    /// 새 결정을 받아 실제로 호출해야 하는 (인덱스, 정지여부) 만 낸다.
    ///
    /// 렌더러 수가 바뀌면(모니터 착탈·재적용) **전부 새로 적용한다** — 이전 배열과 인덱스가
    /// 같은 화면을 가리킨다는 보장이 없기 때문이다. 착각하고 diff 하면 엉뚱한 화면이 멈춘 채
    /// 남는다.
    mutating func changes(_ next: [Bool]) -> [(index: Int, paused: Bool)] {
        defer { applied = next }
        guard applied.count == next.count else {
            return next.enumerated().map { ($0.offset, $0.element) }
        }
        return next.enumerated().compactMap { i, want in
            applied[i] == want ? nil : (i, want)
        }
    }

    /// 렌더러 세트가 교체됐다 — 다음 `changes` 가 전부를 다시 적용하게 만든다.
    mutating func reset() { applied = [] }

    var appliedCount: Int { applied.count }
}

/// 전역 1비트 상태(음소거)의 엣지 추적. `PerRendererPauseState` 와 같은 이유다 —
/// 조건 폴링이 1초마다 도는데 매번 밀면 웹 렌더러에 초당 한 번씩 JS 주입이 들어간다.
///
/// 초기값이 `nil` 인 것이 계약이다: **처음 한 번은 무조건 적용한다.** `false` 로 시작하면
/// "이미 음소거가 아니다" 라고 기억한 채로 새 렌더러에 아무것도 안 밀어서, 렌더러가 갈릴 때
/// 정책 음소거가 조용히 사라진다(`reset()` 이 이 상태로 되돌리는 것도 같은 이유다).
struct AppliedFlag: Equatable {
    private var applied: Bool?

    init() {}

    /// 바뀌었으면 새 값을, 아니면 nil. 반환이 옵셔널인 것이 "부를 필요 없음" 을 표현한다.
    mutating func change(to next: Bool) -> Bool? {
        guard applied != next else { return nil }
        applied = next
        return next
    }

    /// 적용 대상이 갈렸다 — 다음 `change(to:)` 가 무조건 적용하게 만든다.
    mutating func reset() { applied = nil }

    var appliedValue: Bool? { applied }
}
