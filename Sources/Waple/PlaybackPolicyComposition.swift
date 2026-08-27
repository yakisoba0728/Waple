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
        /// **아직 적용하지 않는다.** `WallpaperRenderer` 에는 `teardown()` 뿐이고 그것은
        /// 되돌리려면 재마운트(셰이더 재컴파일·씬 상태 소실)를 뜻한다 — 실기 검증 없이
        /// 넣을 변경이 아니다. 지금은 `paused` 로 떨어지므로 **WE 보다 약하게** 동작한다
        /// (멈추긴 하되 메모리를 놓지 않는다). 이름을 남기는 것은 그 격차를 세는 자리가
        /// 있어야 하기 때문이다.
        let policyWantsStop: Bool
        /// 정책이 `muted` 를 요구했는가. WE 에서 음소거는 모니터별이 아니라 **전역**이다.
        ///
        /// 역시 아직 적용하지 않는다 — 프로토콜에 음량 표면이 없다. 배선하려면
        /// `WallpaperRenderer` 에 음소거를 더해야 하고 그건 별개의 변경이다.
        let policyWantsMute: Bool
    }

    /// 합류 규칙. **전역 사유가 서 있으면 정책을 보지 않고 멈춘다** — 그쪽이 더 강한 요구다.
    ///
    /// `stop` 은 `PlaybackVerdict` 안에서 이미 다른 둘을 가리므로(그 타입 주석),
    /// 여기서는 "정지" 로만 접는다. 그 축소가 위 `policyWantsStop` 이 세는 격차다.
    static func decide(globallyPaused: Bool,
                       verdict: PlaybackVerdict,
                       monitorIndex: Int) -> Decision {
        let policyPauses = verdict.stop || verdict.isPaused(monitorIndex: monitorIndex)
        return Decision(paused: globallyPaused || policyPauses,
                        policyWantsStop: verdict.stop,
                        policyWantsMute: verdict.muted)
    }

    /// 렌더러 배열 전체분(판정 하나를 공유). 인덱스가 곧 모니터 인덱스다 —
    /// `AppDelegate.renderers` 가 `desktopController.screenViews` 와 같은 순서로 만들어지기
    /// 때문이고, 그 불변식이 깨지면 여기 결정이 엉뚱한 화면에 간다.
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
    static func decideAll(globallyPaused: Bool,
                          projects: [WallpaperProject],
                          conditions: PlaybackConditions,
                          global: PlaybackPolicy) -> [Decision] {
        projects.enumerated().map { index, project in
            let verdict = PlaybackPolicyResolver.verdict(for: project, conditions: conditions, global: global)
            return decide(globallyPaused: globallyPaused, verdict: verdict, monitorIndex: index)
        }
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
