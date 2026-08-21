import XCTest
@testable import WapleCore

/// WE 재생목록·전환 순수 모델의 계약 잠금.
///
/// 근거는 `docs/re/playlist-transition.md` 이고, 여기서 단언하는 상수·경계는 전부
/// 디스어셈으로 재확인한 것이다(0x1400691ba–0x140069249 추첨 · 0x14005a351–0x14005a3d1
/// 타이밍 · 0x140068010–0x1400681a0 셔플백).
final class PlaylistTransitionTests: XCTestCase {

    // MARK: - 27종 + 특수값 3

    func testEffectCountIs27() {
        XCTAssertEqual(PlaylistTransitionKind.allEffects.count, 27,
                       "셰이더 분기 27 ↔ getTransitionOptions() 27 ↔ 로케일 키 27 ↔ 추첨 상수 27.0f")
        XCTAssertEqual(PlaylistTransitionKind.allSpecials.count, 3)
        XCTAssertEqual(PlaylistTransitionKind.allCases.count, 30)
    }

    func testEffectIDsAreContiguousZeroToTwentySix() {
        let ids = PlaylistTransitionKind.allEffects.map(\.weConfigValue)
        XCTAssertEqual(ids, Array(0...26), "id 는 0..26 이 빈틈없이 이어져야 한다")
        XCTAssertEqual(PlaylistRandomDraw.maxEffectID, 26, "0x1400691c6 mov ecx, 0x1a")
        XCTAssertEqual(PlaylistRandomDraw.effectCount, 27, "0x140492894 f32=27.0")
    }

    func testAllThirtyKindsRoundTrip() {
        for kind in PlaylistTransitionKind.allCases {
            let back = PlaylistTransitionKind(weConfigValue: kind.weConfigValue)
            XCTAssertEqual(back, kind, "\(kind) 왕복 실패")
        }
    }

    func testSpecialValues() {
        XCTAssertEqual(PlaylistTransitionKind(weConfigValue: -1), .noTransition)
        XCTAssertEqual(PlaylistTransitionKind(weConfigValue: -2), .noTransitionReduceFlicker)
        XCTAssertEqual(PlaylistTransitionKind(weConfigValue: -3), .random)
        XCTAssertEqual(PlaylistTransitionKind.noTransition.weConfigValue, -1)
        XCTAssertEqual(PlaylistTransitionKind.noTransitionReduceFlicker.weConfigValue, -2)
        XCTAssertEqual(PlaylistTransitionKind.random.weConfigValue, -3)
        for special in PlaylistTransitionKind.allSpecials {
            XCTAssertNil(special.effectID, "특수값에는 효과 id 가 없다")
        }
    }

    func testStrictInitRejectsOutOfRange() {
        XCTAssertNil(PlaylistTransitionKind(weConfigValue: 27))
        XCTAssertNil(PlaylistTransitionKind(weConfigValue: -4))
        XCTAssertNil(PlaylistTransitionKind(weConfigValue: 99))
        XCTAssertNil(PlaylistTransitionKind(weConfigValue: Int.min))
    }

    /// 엔진은 거부가 아니라 클램프다 — 0x14006924e cmp ecx,0x1a / 0x140069255 test ecx,ecx.
    func testResolvingClampsInsteadOfRejecting() {
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: 27), .boilover, "상한 26")
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: 99), .boilover)
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: -4), .fade,
                       "-4 는 특수값이 아니라 하한 0 에 걸린다")
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: Int.min), .fade)
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: Int.max), .boilover)
        // 특수값은 클램프 전에 가로채진다
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: -1), .noTransition)
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: -2), .noTransitionReduceFlicker)
        XCTAssertEqual(PlaylistTransitionKind.resolving(weConfigValue: -3), .random)
    }

    func testDisplayNamesAreUniqueAndNonEmpty() {
        let names = PlaylistTransitionKind.allCases.map(\.weDisplayName)
        XCTAssertEqual(Set(names).count, names.count, "UI 라벨은 30개 전부 달라야 한다")
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(PlaylistTransitionKind.fade.weDisplayName, "Fade")
        XCTAssertEqual(PlaylistTransitionKind.bricks.weDisplayName, "Bricks")
        XCTAssertEqual(PlaylistTransitionKind.boilover.weDisplayName, "Boilover")
    }

    // MARK: - transition 설정 파스

    func testBoolConfigValue() {
        // 0x140075813  lea eax, [rax*2 - 2]
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromBool: true), 0, "true → Fade")
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromBool: false), -2,
                       "false → None (reduce flicker)")
    }

    func testStringConfigValue() {
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "random"), -3)
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "none"), -1,
                       "저장을 건너뛰어 진입 초기값 -1 이 남는다")
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "16"), 16)
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "0"), 0)
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "26"), 26)
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "Random"), 0,
                       "대소문자 구분 — memcmp 라 'Random' 은 매치되지 않고 atoi 가 0 을 낸다")
        XCTAssertEqual(PlaylistTransitionKind.weConfigValue(fromString: "쓰레기"), 0,
                       "atoi 관례: 숫자가 없으면 0 = Fade")
    }

    func testWeAtoi() {
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("42"), 42)
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("  -7"), -7, "선행 공백 + 부호")
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("+3"), 3)
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("12abc"), 12, "첫 비숫자에서 멈춘다")
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("abc12"), 0)
        XCTAssertEqual(PlaylistTransitionKind.weAtoi(""), 0)
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("-"), 0)
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("99999999999999999999"), 2_147_483_647,
                       "포화 — 트랩하지 않는다(WE 주장이 아니라 Waple 의 안전 선택)")
        XCTAssertEqual(PlaylistTransitionKind.weAtoi("-99999999999999999999"), -2_147_483_648)
    }

    // MARK: - 무작위 추첨

    func testUnitIsClosedInterval() {
        XCTAssertEqual(PlaylistRandomDraw.unit(weRand: 0), 0.0)
        XCTAssertEqual(PlaylistRandomDraw.unit(weRand: 32767), 1.0,
                       "rand() 최대값은 정확히 1.0 을 만든다 — 그래서 클램프가 필요하다")
        XCTAssertEqual(PlaylistRandomDraw.unit(weRand: 40000), 1.0, "범위 밖 방어")
    }

    func testIndexDrawMatchesClampShape() {
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 0.0, count: 27), 0)
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 0.999_999, count: 27), 26)
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 1.0, count: 27), 26,
                       "1.0 × 27 = 27 → 상한 26 으로 잘린다")
        XCTAssertEqual(PlaylistRandomDraw.index(unit: -1.0, count: 27), 0, "하한 0")
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 0.5, count: 27), 13)
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 0.5, count: 1), 0)
        XCTAssertEqual(PlaylistRandomDraw.index(unit: 0.5, count: 0), 0, "빈 컬렉션 방어")
        // x86 `cvttss2si` 는 NaN·inf·범위밖에서 "정수 부정값" 0x80000000(INT_MIN)을 낸다.
        // 이어지는 min(26, INT_MIN) = INT_MIN, max(0, INT_MIN) = 0 이라 엔진도 0 이다.
        // `safeInt` 가 nil 을 내고 우리가 0 으로 떨어뜨리는 경로가 우연이 아니라 같은 답이다.
        XCTAssertEqual(PlaylistRandomDraw.index(unit: .nan, count: 27), 0, "NaN → 0 (cvttss2si 부정값)")
        XCTAssertEqual(PlaylistRandomDraw.index(unit: .infinity, count: 27), 0, "inf → 0 (같은 이유)")
        XCTAssertEqual(PlaylistRandomDraw.index(unit: -.infinity, count: 27), 0)
    }

    func testEmptyPoolDrawsFromAllTwentySeven() {
        var seen = Set<Int>()
        for rand in 0...32767 {
            seen.insert(PlaylistRandomDraw.effectID(pool: [], unit: PlaylistRandomDraw.unit(weRand: rand)))
        }
        XCTAssertEqual(seen, Set(0...26), "빈 풀 = 전체 허용. 27종이 전부 뽑혀야 한다")
    }

    func testNonEmptyPoolDrawsOnlyFromPool() {
        let pool: Set<Int> = [0, 13, 26]
        var seen = Set<Int>()
        for rand in 0...32767 {
            seen.insert(PlaylistRandomDraw.effectID(pool: pool, unit: PlaylistRandomDraw.unit(weRand: rand)))
        }
        XCTAssertEqual(seen, pool)
    }

    func testPoolIsOrderedAscendingLikeStdSet() {
        // std::set 이라 인덱스 0 은 항상 최솟값이다. 순서가 계약이라는 것을 잠근다.
        let pool: Set<Int> = [26, 3, 9]
        XCTAssertEqual(PlaylistRandomDraw.effectID(pool: pool, unit: 0.0), 3)
        XCTAssertEqual(PlaylistRandomDraw.effectID(pool: pool, unit: 0.5), 9)
        XCTAssertEqual(PlaylistRandomDraw.effectID(pool: pool, unit: 1.0), 26)
    }

    /// 풀 경로는 0..26 클램프를 **거치지 않는다**(0x14006924c 의 jmp 가 클램프를 건너뛴다).
    /// 그래서 원시 id 는 범위를 벗어날 수 있고, Waple 쪽 `kind(pool:unit:)` 이 그걸 막는다.
    func testPoolBypassesEngineClampButKindDoesNot() {
        let pool: Set<Int> = [99]
        XCTAssertEqual(PlaylistRandomDraw.effectID(pool: pool, unit: 0.5), 99,
                       "엔진과 같게 — 원시값을 그대로 낸다")
        XCTAssertEqual(PlaylistRandomDraw.kind(pool: pool, unit: 0.5), .boilover,
                       "Waple 소비 지점에서는 클램프한다")
    }

    // MARK: - 타이밍 (0x14005a351–0x14005a3d1)

    func testProgressIsPurelyLinear() {
        let ms = 1000
        // 리드인 0.1 이후 1초 동안 선형. 중간점들이 정확히 비례해야 한다.
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.1, transitionTimeMillis: ms), 0.0, accuracy: 1e-6)
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.35, transitionTimeMillis: ms), 0.25, accuracy: 1e-5)
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.6, transitionTimeMillis: ms), 0.5, accuracy: 1e-5)
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.85, transitionTimeMillis: ms), 0.75, accuracy: 1e-5)
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 1.1, transitionTimeMillis: ms), 1.0, accuracy: 1e-6)
    }

    func testProgressLeadIn() {
        // elapsed < 0.1 → 전부 0. 새 벽지가 첫 프레임을 띄울 시간을 벌어 준다.
        for elapsed in stride(from: Float(0), to: Float(0.1), by: 0.01) {
            XCTAssertEqual(TransitionTimeline.progress(elapsed: elapsed, transitionTimeMillis: 500), 0.0,
                           "리드인 구간(elapsed=\(elapsed))은 진행도 0")
        }
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.0999, transitionTimeMillis: 500), 0.0)
    }

    func testProgressSaturatesAtOne() {
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.6, transitionTimeMillis: 500), 1.0,
                       "0.1 + 0.5 = 0.6 이 정확히 끝")
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 100.0, transitionTimeMillis: 500), 1.0)
        XCTAssertEqual(TransitionTimeline.progress(elapsed: .infinity, transitionTimeMillis: 500), 1.0)
    }

    /// `transitiontime == 0` 은 크래시가 아니라 1프레임 전환이다 — `comiss` 클램프가 inf/NaN 을 먹는다.
    func testProgressZeroTransitionTime() {
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.2, transitionTimeMillis: 0), 1.0,
                       "+inf → 1.0")
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.1, transitionTimeMillis: 0), 1.0,
                       "0/0 = NaN → comiss 의 jbe 가 먹어서 1.0")
        XCTAssertEqual(TransitionTimeline.progress(elapsed: 0.05, transitionTimeMillis: 0), 0.0,
                       "-inf → 0.0")
    }

    func testProgressNegativeTransitionTimeStaysFinite() {
        // 손으로 고친 config 방어. 부호가 뒤집혀도 clamp 밖으로 못 나간다.
        let p = TransitionTimeline.progress(elapsed: 0.5, transitionTimeMillis: -500)
        XCTAssertEqual(p, 0.0)
        XCTAssertTrue(p.isFinite)
    }

    func testProgressIsMonotonic() {
        var previous: Float = -1
        for step in 0...200 {
            let elapsed = Float(step) * 0.01
            let p = TransitionTimeline.progress(elapsed: elapsed, transitionTimeMillis: 1500)
            XCTAssertGreaterThanOrEqual(p, previous, "단조 증가여야 한다(elapsed=\(elapsed))")
            XCTAssertTrue((0.0...1.0).contains(p))
            previous = p
        }
        XCTAssertEqual(previous, 1.0)
    }

    func testDoubleOverloadMatchesFloat() {
        for ms in [0, 1, 500, 1500, 3000] {
            for elapsed in [0.0, 0.05, 0.1, 0.4, 1.6, 99.0] {
                XCTAssertEqual(TransitionTimeline.progress(elapsedSeconds: elapsed, transitionTimeMillis: ms),
                               Double(TransitionTimeline.progress(elapsed: Float(elapsed),
                                                                  transitionTimeMillis: ms)),
                               accuracy: 1e-9)
            }
        }
    }

    func testTimelineConstants() {
        XCTAssertEqual(TransitionTimeline.leadInSeconds, 0.1, "0x140492654")
        XCTAssertEqual(TransitionTimeline.millisToSeconds, 0.001, "0x140492608")
        XCTAssertEqual(TransitionTimeline.frameSleepMilliseconds, 15, "0x14005a790 mov ecx, 0xf")
        XCTAssertEqual(TransitionTimeline.totalSeconds(transitionTimeMillis: 500), 0.6, accuracy: 1e-6)
    }

    // MARK: - 셔플백 불변식

    func testShuffleBagExhaustsBeforeRepeating() {
        let items = ["a", "b", "c", "d", "e"]
        var bag = ShuffleBag(items: items, seed: 0xDEAD_BEEF)
        var cycle: [String] = []
        for _ in 0..<items.count { cycle.append(bag.next()!) }
        XCTAssertEqual(Set(cycle), Set(items), "한 바퀴 안에서 전원이 정확히 한 번씩")
        XCTAssertEqual(cycle.count, Set(cycle).count, "한 바퀴 안에서 무반복")
    }

    /// 백 하나 안에서는 절대 중복이 없다 — 그게 "소진형" 의 정의다.
    ///
    /// **첫 백만 n 개이고 이후 백은 n-1 개다.** 리필 직후 현재 재생 항목을 빼기 때문이다
    /// (0x1400680a0–0x140068114). 처음 이 테스트를 "매 바퀴 n 개" 로 썼다가 틀렸다 —
    /// 기록으로 남긴다.
    func testShuffleBagNeverRepeatsWithinOneBag() {
        let items = ["a", "b", "c", "d", "e", "f", "g"]
        var bag = ShuffleBag(items: items, seed: 7)
        var current: String?
        var bags: [[String]] = [[]]
        for _ in 0..<60 {
            if bag.needsRefill && !bags[bags.count - 1].isEmpty { bags.append([]) }
            let picked = bag.next(current: current)!
            bags[bags.count - 1].append(picked)
            current = picked
        }
        XCTAssertGreaterThan(bags.count, 5, "60회면 백이 여러 번 리필된다")
        for (index, one) in bags.enumerated() {
            XCTAssertEqual(one.count, Set(one).count, "백 \(index) 안에서 중복: \(one)")
        }
        XCTAssertEqual(bags[0].count, items.count, "첫 백은 전원 소진")
        for (index, one) in bags.enumerated().dropFirst() where index < bags.count - 1 {
            XCTAssertEqual(one.count, items.count - 1,
                           "리필 백은 현재 항목이 빠져 n-1 개다(백 \(index))")
        }
    }

    /// Waple 의 shuffleNext 는 직전 1개만 회피하므로 3곡에서 A,B,A,B 가 무한히 가능하다
    /// (c 가 영원히 안 나올 수 있다). 셔플백은 구조적으로 불가능하다 — 그 차이를 잠근다.
    func testShuffleBagCoversEveryItemUnlikeLastOnlyAvoidance() {
        let items = ["a", "b", "c"]
        for seed in UInt64(0)..<64 {
            var bag = ShuffleBag(items: items, seed: seed)
            var current: String?
            var drawn: [String] = []
            for _ in 0..<30 {
                let picked = bag.next(current: current)!
                drawn.append(picked)
                current = picked
            }
            for index in 1..<drawn.count {
                XCTAssertNotEqual(drawn[index], drawn[index - 1],
                                  "seed=\(seed) 즉시 반복: \(drawn)")
            }
            // 5연속 창 안에 3종이 전부 든다. '직전 1개 회피' 는 이걸 보장하지 못한다.
            for start in 0...(drawn.count - 5) {
                XCTAssertEqual(Set(drawn[start..<(start + 5)]), Set(items),
                               "seed=\(seed) \(start) 부터 5개 창에 빠진 항목: \(Array(drawn[start..<(start + 5)]))")
            }
        }
    }

    func testShuffleBagIsDeterministicForSameSeed() {
        let items = ["a", "b", "c", "d", "e", "f"]
        func run(_ seed: UInt64) -> [String] {
            var bag = ShuffleBag(items: items, seed: seed)
            return (0..<18).map { _ in bag.next()! }
        }
        XCTAssertEqual(run(12345), run(12345), "같은 시드 = 같은 수열")
        XCTAssertNotEqual(run(12345), run(54321), "다른 시드 = 다른 수열(이 목록에서는 실제로 갈린다)")
    }

    func testShuffleBagRemovesCurrentOnlyAtRefill() {
        let items = ["a", "b", "c", "d"]
        var bag = ShuffleBag(items: items, seed: 99)
        // 한 바퀴 다 뽑는다.
        var last: String?
        for _ in 0..<items.count { last = bag.next(current: last) }
        XCTAssertTrue(bag.needsRefill)
        // 다음 호출은 리필 → current 를 백에서 뺀다 → 절대 같은 게 안 나온다.
        let next = bag.next(current: last)
        XCTAssertNotEqual(next, last, "리필 직후 같은 벽지가 연달아 나오면 안 된다(0x1400680a0–0x140068114)")
    }

    func testShuffleBagSingleItemDegenerates() {
        var bag = ShuffleBag(items: ["only"], seed: 1)
        // 백 크기가 1 이라 current 제거 가드가 걸리지 않는다 — 같은 항목이 계속 나온다.
        XCTAssertEqual(bag.next(current: nil), "only")
        XCTAssertEqual(bag.next(current: "only"), "only",
                       "1개짜리는 회피가 불가능하다 — 0x14006805b cmp rax,1 가드")
        XCTAssertEqual(bag.next(current: "only"), "only")
    }

    func testShuffleBagTwoItemsAlternateStrictly() {
        var bag = ShuffleBag(items: ["a", "b"], seed: 4242)
        var current: String?
        var drawn: [String] = []
        for _ in 0..<10 {
            let picked = bag.next(current: current)!
            drawn.append(picked)
            current = picked
        }
        // 2개짜리 소진형 + 리필 시 현재 제거 ⇒ 반드시 교대한다.
        for index in 1..<drawn.count {
            XCTAssertNotEqual(drawn[index], drawn[index - 1], "2곡은 엄격 교대해야 한다: \(drawn)")
        }
    }

    func testShuffleBagEmptyList() {
        var bag = ShuffleBag(items: [String](), seed: 1)
        XCTAssertNil(bag.next())
        XCTAssertNil(bag.next(current: "x"))
    }

    func testShuffleBagPlayIntroSkipsFirstItem() {
        let items = ["intro", "a", "b", "c"]
        var bag = ShuffleBag(items: items, seed: 555, playIntro: true)
        var drawn: [String] = []
        for _ in 0..<12 { drawn.append(bag.next()!) }
        XCTAssertFalse(drawn.contains("intro"),
                       "playintro 는 첫 항목을 리필에서 뺀다(0x14006803b add r9, 0x48)")
        XCTAssertEqual(Set(drawn), ["a", "b", "c"])
    }

    func testShuffleBagPlayIntroWithSingleItemYieldsNothing() {
        var bag = ShuffleBag(items: ["only"], seed: 1, playIntro: true)
        XCTAssertNil(bag.next(), "첫 항목을 빼면 백이 비어 0x140068121 의 포기 경로로 간다")
    }

    func testShuffleBagDrainForcesRefill() {
        var bag = ShuffleBag(items: ["a", "b", "c"], seed: 3)
        _ = bag.next()
        XCTAssertFalse(bag.needsRefill)
        bag.drain()
        XCTAssertTrue(bag.needsRefill)
        XCTAssertNotNil(bag.next())
    }

    // MARK: - 순서 · 모드 열거

    func testOrderParse() {
        XCTAssertEqual(PlaylistOrder(weConfigString: "sorted"), .sorted)
        XCTAssertEqual(PlaylistOrder(weConfigString: "random"), .random)
        XCTAssertEqual(PlaylistOrder(weConfigString: "Sorted"), .random, "단일 비교라 대소문자 구분")
        XCTAssertEqual(PlaylistOrder(weConfigString: ""), .random, "그 밖의 모든 문자열 → 0")
        XCTAssertEqual(PlaylistOrder.random.rawValue, 0)
        XCTAssertEqual(PlaylistOrder.sorted.rawValue, 1)
    }

    func testModeParse() {
        XCTAssertEqual(PlaylistMode(weConfigString: "logon"), .logon)
        XCTAssertEqual(PlaylistMode(weConfigString: "daytime"), .daytime)
        XCTAssertEqual(PlaylistMode(weConfigString: "dayofweek"), .dayOfWeek)
        XCTAssertEqual(PlaylistMode(weConfigString: "never"), .never)
        XCTAssertEqual(PlaylistMode(weConfigString: "timer"), .timer,
                       "'timer' 문자열은 바이너리에 없다 — 매치 실패 → 기본값 1 = timer")
        XCTAssertEqual(PlaylistMode(weConfigString: "쓰레기"), .timer)
        XCTAssertNil(PlaylistMode.timer.weConfigString)
        XCTAssertEqual(PlaylistMode.dayOfWeek.weConfigString, "dayofweek")
    }

    func testModeRawValues() {
        XCTAssertEqual(PlaylistMode.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }

    func testModeTimerAndDelayRules() {
        XCTAssertFalse(PlaylistMode.logon.clearsDelayOnParse, "logon 은 0x140075cb1 로 건너뛴다")
        XCTAssertFalse(PlaylistMode.timer.clearsDelayOnParse)
        XCTAssertTrue(PlaylistMode.daytime.clearsDelayOnParse)
        XCTAssertTrue(PlaylistMode.dayOfWeek.clearsDelayOnParse)
        XCTAssertTrue(PlaylistMode.never.clearsDelayOnParse)

        XCTAssertTrue(PlaylistMode.logon.usesTimerTick, "logon 은 타이머도 같이 돈다")
        XCTAssertTrue(PlaylistMode.timer.usesTimerTick)
        XCTAssertFalse(PlaylistMode.daytime.usesTimerTick)
        XCTAssertFalse(PlaylistMode.dayOfWeek.usesTimerTick)
        XCTAssertTrue(PlaylistMode.never.usesTimerTick,
                      "never 는 mode 로 걸러지지 않는다 — delay=0 이 0.01 가드에 걸려 멎는다")
    }

    // MARK: - 설정 기본값과 정규화

    func testEngineDefaults() {
        let settings = PlaylistSettings()
        XCTAssertEqual(settings.delayMinutes, 60.0, "0x140075b14 imm 0x42700000")
        XCTAssertEqual(settings.order, .random)
        XCTAssertEqual(settings.mode, .timer)
        XCTAssertFalse(settings.videoSequence)
        XCTAssertFalse(settings.updateOnPause)
        XCTAssertFalse(settings.beginFirst)
        XCTAssertFalse(settings.playIntro)
        XCTAssertEqual(settings.transitionConfigValue, -1, "0x14007579f mov dword [r8], 0xffffffff")
        XCTAssertEqual(settings.transition, .noTransition)
        XCTAssertEqual(settings.transitionTimeMillis, 500, "0x140075a2f mov dword [r14+4], 0x1f4")
        XCTAssertTrue(settings.transitionPool.isEmpty, "빈 풀 = 전체 허용")
        XCTAssertEqual(PlaylistSettings.uiDefaultTransitionTimeMillis, 1500, "UI 는 다른 값을 쓴다")
        XCTAssertEqual(PlaylistSettings.minimumDelayMinutes, 0.01, "0x140492620")
    }

    func testNormalizedClearsDelayForTimeBasedModes() {
        for mode in [PlaylistMode.daytime, .dayOfWeek, .never] {
            var settings = PlaylistSettings()
            settings.mode = mode
            XCTAssertEqual(settings.normalized().delayMinutes, 0, "\(mode) → delay 0 (0x140075d41)")
        }
        var logon = PlaylistSettings()
        logon.mode = .logon
        XCTAssertEqual(logon.normalized().delayMinutes, 60.0, "logon 은 delay 가 살아 있다")
    }

    func testNormalizedGatesBeginFirstAndPlayIntro() {
        var settings = PlaylistSettings()
        settings.mode = .logon
        settings.beginFirst = true
        settings.playIntro = true
        let out = settings.normalized()
        XCTAssertFalse(out.beginFirst, "beginfirst 는 mode == timer 일 때만 읽힌다")
        XCTAssertFalse(out.playIntro, "playintro 는 beginfirst 가 켜졌을 때만 읽힌다")

        var timer = PlaylistSettings()
        timer.beginFirst = false
        timer.playIntro = true
        XCTAssertFalse(timer.normalized().playIntro)

        var both = PlaylistSettings()
        both.beginFirst = true
        both.playIntro = true
        XCTAssertTrue(both.normalized().beginFirst)
        XCTAssertTrue(both.normalized().playIntro)
    }

    // MARK: - 타이머 틱 관문

    func testTimerAdvanceGates() {
        var settings = PlaylistSettings()
        settings.delayMinutes = 30

        XCTAssertTrue(settings.shouldTimerAdvance(elapsedSeconds: 1800, isPaused: false, currentIsVideo: false))
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 1799, isPaused: false, currentIsVideo: false),
                       "경계 직전")
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 1800, isPaused: true, currentIsVideo: false),
                       "정지 중 + updateonpause 꺼짐 → 보류")

        settings.updateOnPause = true
        XCTAssertTrue(settings.shouldTimerAdvance(elapsedSeconds: 1800, isPaused: true, currentIsVideo: false))

        settings.videoSequence = true
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 1800, isPaused: false, currentIsVideo: true),
                       "동영상은 끝날 때 다른 경로가 전환한다")
        XCTAssertTrue(settings.shouldTimerAdvance(elapsedSeconds: 1800, isPaused: false, currentIsVideo: false))
    }

    func testTimerAdvanceDelayFloor() {
        var settings = PlaylistSettings()
        settings.delayMinutes = 0
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 99999, isPaused: false, currentIsVideo: false),
                       "delay 0 (never 모드가 여기 걸린다)")
        settings.delayMinutes = 0.009
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 99999, isPaused: false, currentIsVideo: false),
                       "0.01분 하한 미만")
        settings.delayMinutes = 0.01
        XCTAssertTrue(settings.shouldTimerAdvance(elapsedSeconds: 0.6, isPaused: false, currentIsVideo: false),
                       "0.01분 = 0.6초")
    }

    func testTimerAdvanceSkipsTimeBasedModes() {
        for mode in [PlaylistMode.daytime, PlaylistMode.dayOfWeek] {
            var settings = PlaylistSettings()
            settings.mode = mode
            settings.delayMinutes = 1
            XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 99999, isPaused: false,
                                                       currentIsVideo: false),
                           "\(mode) 는 타이머를 안 쓴다")
        }
    }

    // MARK: - 동영상 종료 전진 관문 (0x140067762–0x14006778f)

    /// `videosequence` 는 `mode == timer` 밖에서는 죽은 키다 — 0x140067762 의 `cmp [rbx+0x70],1`.
    /// 파서는 mode 와 무관하게 이 비트를 읽으므로 설정 파일만 봐서는 이 의존이 안 보인다.
    func testVideoEndAdvanceNeedsTimerMode() {
        var settings = PlaylistSettings()
        settings.videoSequence = true
        XCTAssertTrue(settings.shouldAdvanceOnVideoEnd(introShowing: false), "timer + videosequence")

        for mode in [PlaylistMode.logon, .daytime, .dayOfWeek, .never] {
            settings.mode = mode
            XCTAssertFalse(settings.shouldAdvanceOnVideoEnd(introShowing: false),
                           "\(mode) 에서는 videosequence 가 동영상 종료 전진을 만들지 않는다")
        }
    }

    /// 두 번째 항 — `playintro` 가 켜져 있고 지금 걸린 것이 인트로 벽지면, `videosequence` 가
    /// 꺼져 있어도(그리고 mode 가 timer 가 아니어도) 종료가 전진을 만든다(0x140067774–0x140067789).
    func testVideoEndAdvanceIntroPath() {
        var settings = PlaylistSettings()
        settings.videoSequence = false
        settings.playIntro = true
        XCTAssertFalse(settings.shouldAdvanceOnVideoEnd(introShowing: false),
                       "인트로가 안 걸려 있으면 playintro 만으로는 안 된다")
        XCTAssertTrue(settings.shouldAdvanceOnVideoEnd(introShowing: true))

        settings.mode = .never
        XCTAssertTrue(settings.shouldAdvanceOnVideoEnd(introShowing: true),
                      "인트로 항은 mode 게이트 밖이다 — `or cl, al` 이 두 항을 대등하게 합친다")

        settings.playIntro = false
        XCTAssertFalse(settings.shouldAdvanceOnVideoEnd(introShowing: true))
    }

    /// 타이머 틱과 종료 전진이 정확히 상보적인지 — `videosequence` 가 보류시킨 것을
    /// 종료 경로가 받는다(0x140076d81 ↔ 0x140067768).
    func testVideoSequenceHandsTimerAdvanceToVideoEnd() {
        var settings = PlaylistSettings()
        settings.delayMinutes = 1
        settings.videoSequence = true
        XCTAssertFalse(settings.shouldTimerAdvance(elapsedSeconds: 600, isPaused: false, currentIsVideo: true),
                       "타이머는 보류한다")
        XCTAssertTrue(settings.shouldAdvanceOnVideoEnd(introShowing: false),
                      "그 전진을 종료 경로가 받는다")

        settings.videoSequence = false
        XCTAssertTrue(settings.shouldTimerAdvance(elapsedSeconds: 600, isPaused: false, currentIsVideo: true),
                      "끄면 타이머가 동영상도 그냥 넘긴다")
        XCTAssertFalse(settings.shouldAdvanceOnVideoEnd(introShowing: false),
                       "그리고 종료 경로는 아무것도 안 한다")
    }

    // MARK: - sorted 커서

    func testSortedCursorCycles() {
        var cursor = PlaylistSortedCursor()
        let picks = (0..<7).map { _ in cursor.next(count: 3, playIntro: false)! }
        XCTAssertEqual(picks, [0, 1, 2, 0, 1, 2, 0])
    }

    func testSortedCursorPlayIntroSkipsIndexZeroOnWrap() {
        var cursor = PlaylistSortedCursor()
        let picks = (0..<7).map { _ in cursor.next(count: 3, playIntro: true)! }
        XCTAssertEqual(picks, [1, 2, 1, 2, 1, 2, 1],
                       "되감길 때마다 인덱스 1 로 건너뛴다 — 인트로는 재생하지 않는다")
    }

    func testSortedCursorReset() {
        var cursor = PlaylistSortedCursor()
        _ = cursor.next(count: 4, playIntro: false)
        _ = cursor.next(count: 4, playIntro: false)
        cursor.reset()
        XCTAssertEqual(cursor.next(count: 4, playIntro: false), 0, "beginfirst 는 커서를 0 으로")
    }

    func testSortedCursorDegenerate() {
        var cursor = PlaylistSortedCursor()
        XCTAssertNil(cursor.next(count: 0, playIntro: false))
        XCTAssertEqual(cursor.next(count: 1, playIntro: false), 0)
        XCTAssertEqual(cursor.next(count: 1, playIntro: true), 0,
                       "항목 1개 + playintro 는 Waple 이 더한 가드로 0 을 낸다(WE 는 1 을 낸다)")
    }

    // MARK: - 시각 기반 선택

    func testNormalizedTimeOfDay() {
        XCTAssertEqual(PlaylistDaytime.normalizedTimeOfDay(hour: 0, minute: 0), 0.0)
        XCTAssertEqual(PlaylistDaytime.normalizedTimeOfDay(hour: 12, minute: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PlaylistDaytime.normalizedTimeOfDay(hour: 23, minute: 59),
                       1439.0 / 1440.0, accuracy: 1e-6)
    }

    func testDaytimeSelectsFirstItemPastNow() {
        let items = [
            PlaylistItem(file: "morning.pkg", daytimeEnd: 0.5),
            PlaylistItem(file: "evening.pkg", daytimeEnd: 0.9),
            PlaylistItem(file: "night.pkg"),   // UI 는 마지막 항목의 daytimeend 를 지운다
        ]
        XCTAssertEqual(PlaylistDaytime.index(items: items, normalizedNow: 0.0), 0)
        XCTAssertEqual(PlaylistDaytime.index(items: items, normalizedNow: 0.5), 1,
                       "경계는 '초과' 라 0.5 는 첫 항목을 넘긴다")
        XCTAssertEqual(PlaylistDaytime.index(items: items, normalizedNow: 0.7), 1)
        XCTAssertNil(PlaylistDaytime.index(items: items, normalizedNow: 0.95),
                     "매치 없음 → 0x140067b61 의 이탈 경로")
        XCTAssertNil(PlaylistDaytime.index(items: [], normalizedNow: 0.5))
    }

    func testDayOfWeekIndex() {
        // 기본 로케일(월요일 시작): 월=슬롯0 … 일=슬롯6
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 1, firstDayOfWeek: 0), 0, "월요일")
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 2, firstDayOfWeek: 0), 1)
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 6, firstDayOfWeek: 0), 5, "토요일")
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 0, firstDayOfWeek: 0), 6, "일요일")
        // 일요일 시작 로케일(firstDayOfWeek = 6)
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 0, firstDayOfWeek: 6), 0)
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 1, firstDayOfWeek: 6), 1)
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 6, firstDayOfWeek: 6), 6)
        // 모든 조합이 0..6 안에 든다
        for first in 0...6 {
            var slots = Set<Int>()
            for weekday in 0...6 {
                let slot = PlaylistDayOfWeek.index(weekday: weekday, firstDayOfWeek: first)
                XCTAssertTrue((0..<7).contains(slot))
                slots.insert(slot)
            }
            XCTAssertEqual(slots.count, 7, "first=\(first) 에서 전단사여야 한다")
        }
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: 1, firstDayOfWeek: 99),
                       PlaylistDayOfWeek.index(weekday: 1, firstDayOfWeek: 6),
                       "firstDayOfWeek 는 6 으로 상한(0x14003dd1e–0x14003dd25)")
    }

    // MARK: - 항목

    func testItemStride() {
        XCTAssertEqual(PlaylistItem.weStructStride, 0x48, "0x140075ae7 add rbx, 0x48")
    }

    func testItemDefaults() {
        let item = PlaylistItem(file: "a.pkg")
        XCTAssertNil(item.daytimeEnd, "키가 없으면 daytime 선택에서 매치되지 않는다")
        XCTAssertEqual(item.preset, "")
    }
}
