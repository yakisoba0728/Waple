import XCTest
@testable import WapleCore

/// `SimplexNoise` 는 원본 바이너리(`wallpaper64.exe`, imagebase `0x140000000`)에서 읽어낸
/// 표·상수·분기를 그대로 옮긴 것이라, 테스트도 **바이너리 실측치**를 계약으로 건다.
///
/// 골든 수치는 이 Swift 코드로 뽑지 않았다 — 디스어셈블리만 보고 파이썬으로 따로 짠 float32
/// 레퍼런스에서 뽑았고, 그 레퍼런스를 다시 float64 교과서 구현(알고리즘 서술에서 독립 작성)과
/// 대조해 2D 3만점 최대 오차 1.6e-05, 3D 2만점 최대 오차 1.3e-05 로 일치함을 확인했다.
final class SimplexNoiseTests: XCTestCase {

    /// 골든 허용오차. float32 연산 순서 차이(스칼라 vs 4레인 SIMD)까지 흡수한다.
    private let tol: Float = 1e-5

    private func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        return h
    }

    // MARK: - 표

    /// `perm[512]` @ `0x1404833a0`–`0x1404835a0`. 파일에 박힌 512바이트가 실물 덤프와 같은지
    /// 해시로 고정한다(FNV-1a 64, 파이썬으로 원본 바이트에서 직접 계산).
    func testPermTableIsTheBinaryDump() {
        XCTAssertEqual(SimplexNoise.perm.count, 512)
        XCTAssertEqual(fnv1a64(SimplexNoise.perm), 0x52e5_7fda_088e_fc05)

        // 앞 256 이 뒤 256 에 그대로 반복된다 — 실물이 그렇게 생겼고, snoise2/snoise3 의
        // 인덱스가 최대 511 까지 올라가는 것이 안전한 이유다.
        XCTAssertEqual(Array(SimplexNoise.perm[0..<256]), Array(SimplexNoise.perm[256..<512]))

        // 0..255 의 순열이다(Ken Perlin 표준 표).
        XCTAssertEqual(Array(SimplexNoise.perm[0..<256]).sorted(), (0...255).map { UInt8($0) })

        // `0x1404833a0` 첫 16바이트.
        XCTAssertEqual(Array(SimplexNoise.perm[0..<16]),
                       [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225])
    }

    /// `permMod12[512]` @ `0x1404831a0`–`0x1404833a0`. 소스는 `perm % 12` 로 파생하는데,
    /// 그 파생물이 **실물 표와 512바이트 전부 일치**하는지 해시로 확인한다
    /// (해시는 바이너리의 `0x1404831a0` 바이트에서 뽑았다 — 파생식에서 뽑은 게 아니다).
    func testPermMod12MatchesBinaryTable() {
        XCTAssertEqual(SimplexNoise.permMod12.count, 512)
        XCTAssertEqual(fnv1a64(SimplexNoise.permMod12), 0x38f4_f2ff_c6ff_8165)
        XCTAssertTrue(SimplexNoise.permMod12.allSatisfy { $0 < 12 })
    }

    /// `grad3[12]` — y @`0x140483140`, x @`0x140483170`, z @`0x1404835a0`.
    /// Gustavson 표준 12방향: 성분 하나가 0, 나머지 둘이 ±1.
    func testGrad3TablesAreTheStandardTwelveDirections() {
        XCTAssertEqual(SimplexNoise.grad3X.count, 12)
        XCTAssertEqual(SimplexNoise.grad3Y.count, 12)
        XCTAssertEqual(SimplexNoise.grad3Z.count, 12)
        var seen = Set<String>()
        for g in 0..<12 {
            let v = [SimplexNoise.grad3X[g], SimplexNoise.grad3Y[g], SimplexNoise.grad3Z[g]]
            XCTAssertEqual(v.filter { $0 == 0 }.count, 1, "gradient \(g) 는 0 성분이 정확히 하나여야 한다")
            XCTAssertEqual(v.filter { $0 == 1 || $0 == -1 }.count, 2)
            seen.insert(v.map { "\($0)" }.joined(separator: ","))
        }
        XCTAssertEqual(seen.count, 12, "12방향이 전부 서로 달라야 한다")
    }

    // MARK: - grad2 해시 분기 (upstream 과 갈리는 지점)

    /// `0x14027b300` 은 `test al, 0x3C` 다. upstream `simplexnoise1234.c` 였다면 `h = hash & 7`
    /// 이므로 `test al, 4` 여야 한다. 비트 3·4·5 가 살아 있는 해시에서 결과가 갈린다.
    func testGrad2SwapUsesBits2Through5NotJustBit2() {
        // hash 8: (8 & 0x3C) = 8 ≠ 0 → u,v 스왑 → 2·x. upstream(8 & 7 = 0 < 4)이면 스왑 없이 x.
        XCTAssertEqual(SimplexNoise.grad2(8, 1, 0), 2)
        XCTAssertEqual(SimplexNoise.grad2(16, 1, 0), 2)   // upstream 이면 1
        XCTAssertEqual(SimplexNoise.grad2(32, 1, 0), 2)   // upstream 이면 1
        // 비트 2..5 가 전부 0 인 해시만 스왑을 건너뛴다.
        XCTAssertEqual(SimplexNoise.grad2(0, 1, 0), 1)
        XCTAssertEqual(SimplexNoise.grad2(64, 1, 0), 1)
        XCTAssertEqual(SimplexNoise.grad2(128, 1, 0), 1)
        XCTAssertEqual(SimplexNoise.grad2(192, 1, 0), 1)

        // (x, y) = (1, 0) 을 넣으면 스왑한 해시는 ±2, 안 한 해시는 ±1 을 뱉는다.
        // 256개 중 스왑을 건너뛰는 것은 16개뿐이다 — upstream(`hash & 4`)이었다면 128개다.
        let noSwap = (0...255).filter { abs(SimplexNoise.grad2(UInt8($0), 1, 0)) == 1 }
        XCTAssertEqual(noSwap.count, 16)
        XCTAssertTrue(noSwap.allSatisfy { $0 & 0x3C == 0 })
    }

    /// 부호 규칙은 upstream 그대로다 — `h&1` 이 u 를 뒤집고(`0x14027b315` xorps -0.0),
    /// `h&2` 가 v 를 `-2` 배(`0x14027b320`) 또는 `+2` 배(`0x14027b32d` addss v,v) 한다.
    func testGrad2SignRules() {
        // hash 1: 스왑 없음(1 & 0x3C == 0), h&1 → u = -x, h&2 = 0 → v = 2y
        XCTAssertEqual(SimplexNoise.grad2(1, 3, 5), -3 + 10)
        // hash 2: 스왑 없음, h&1 = 0 → u = x, h&2 → v = -2y
        XCTAssertEqual(SimplexNoise.grad2(2, 3, 5), 3 - 10)
        // hash 3: 스왑 없음, u = -x, v = -2y
        XCTAssertEqual(SimplexNoise.grad2(3, 3, 5), -3 - 10)
        // hash 5: 스왑(5 & 0x3C = 4), u = -y, v = 2x
        XCTAssertEqual(SimplexNoise.grad2(5, 3, 5), -5 + 6)
    }

    // MARK: - 골든 값

    func testSnoise2GoldenValues() {
        let golden: [(Float, Float, Float)] = [
            (0.0, 0.0, 0.0),
            (0.5, 0.0, 0.83780044),
            (0.0, 0.5, -0.24154590),
            (0.5, 0.5, -0.59540957),
            (1.0, 1.0, 0.31621855),
            (1.5, -2.25, 0.52122104),
            (-3.75, 7.125, -0.33336529),
            (0.1, 0.2, -0.01708817),
            (-0.5, -0.5, 0.19846985),
            (3.0, 4.0, 0.11659756),
            (12.34, -5.678, 0.82376236),
        ]
        for (x, y, want) in golden {
            XCTAssertEqual(SimplexNoise.snoise2(x, y), want, accuracy: tol, "snoise2(\(x), \(y))")
        }
    }

    func testSnoise3GoldenValues() {
        let golden: [(Float, Float, Float, Float)] = [
            (0.5, 0.0, 0.0, 0.42975712),
            (0.0, 0.5, 0.0, 0.05364288),
            (0.0, 0.0, 0.25, 0.00006328),
            (-1.25, 0.75, 2.5, -0.44939530),
            (0.1, 0.2, 0.3, 0.63589025),
            (0.3333, 0.6667, 1.0, -0.21721594),
            (2.5, -1.5, 0.75, 0.01854978),
            (12.34, -5.678, 9.012, -0.40561116),
        ]
        for (x, y, z, want) in golden {
            XCTAssertEqual(SimplexNoise.snoise3(x, y, z), want, accuracy: tol, "snoise3(\(x), \(y), \(z))")
        }
    }

    // MARK: - 알려진 성질

    /// 심플렉스 격자점에서는 값이 정확히 0 이다(네 코너 중 하나는 거리 0 이라 기울기 내적이
    /// 0 이고, 나머지 셋은 `t < 0` 으로 잘린다).
    ///
    /// 격자점은 스큐 후 정수가 되는 점이다 — 3D 는 `s = (x+y+z)/3` 이므로 **성분 합이 3의 배수인
    /// 정수점**만 해당한다. `(-4, 0, 11)` 은 합이 7 이라 격자점이 아니고 값도 0 이 아니다.
    /// 2D 는 `F2` 가 무리수라 원점 말고는 정수 격자점이 없다((1,1) 은 0 이 아니다).
    func testZeroAtLatticePoints() {
        XCTAssertEqual(SimplexNoise.snoise2(0, 0), 0)
        XCTAssertEqual(SimplexNoise.snoise3(0, 0, 0), 0)
        for (x, y, z) in [(1, 2, 3), (7, 7, 7), (-1, -1, -1), (0, 3, 6), (-4, 1, 12), (5, -2, 0)] {
            XCTAssertEqual(SimplexNoise.snoise3(Float(x), Float(y), Float(z)), 0,
                           "성분 합이 3의 배수인 정수점은 3D 심플렉스 격자점이다: (\(x), \(y), \(z))")
        }
        XCTAssertNotEqual(SimplexNoise.snoise3(-4, 0, 11), 0)   // 합 7 — 격자점 아님
        XCTAssertNotEqual(SimplexNoise.snoise2(1, 1), 0)
    }

    /// 2D 봉우리가 ±1 에 닿는지 — `0x1404928c8` 의 `45.23065185546875` 를 고정하는 회귀 게이트다.
    /// upstream 의 `40.0f` 였다면 이 격자에서 최대 진폭이 0.885 를 못 넘는다.
    func testSnoise2RangeAndPeakPinsTheRescaledConstant() {
        var lo: Float = 0, hi: Float = 0
        for a in -60...60 {
            let x = Float(a) * 0.137
            for b in -60...60 {
                let v = SimplexNoise.snoise2(x, Float(b) * 0.211)
                lo = min(lo, v); hi = max(hi, v)
            }
        }
        XCTAssertGreaterThanOrEqual(lo, -1)
        XCTAssertLessThanOrEqual(hi, 1)
        XCTAssertGreaterThan(hi, 0.99, "봉우리가 ±1 에 닿아야 한다(스케일 40 이면 0.885 에서 막힌다)")
        XCTAssertLessThan(lo, -0.99)
    }

    /// 3D 는 동률(아래 테스트 참조)만 피하면 [-1, 1] 안에 있다.
    func testSnoise3StaysInRangeOnTieFreeGrid() {
        var lo: Float = 0, hi: Float = 0
        for a in -12...12 {
            let x = Float(a) * 0.3109
            for b in -12...12 {
                let y = Float(b) * 0.2711
                for c in -12...12 {
                    let v = SimplexNoise.snoise3(x, y, Float(c) * 0.2297)
                    lo = min(lo, v); hi = max(hi, v)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(lo, -1)
        XCTAssertLessThanOrEqual(hi, 1)
        XCTAssertGreaterThan(hi, 0.9)
        XCTAssertLessThan(lo, -0.9)
    }

    /// **실물의 결함을 그대로 옮겼다는 고정 테스트.**
    ///
    /// 4레인 SIMD 화하면서 코너 선택이 분기 없는 마스크로 펼쳐졌는데, `j1` 은 `z0 < y0`
    /// (`cmpltps` @`0x1400fc590`)를, `j2` 는 `z0 <= y0`(`cmpleps` @`0x1400fc536`)를 쓴다.
    /// 그래서 `y0 == z0 && x0 < y0` 인 점에서 `(i1,j1,k1)` 이 `(0,0,0)` 이 되어 버린다 —
    /// 자바 원본의 if/else 사슬은 절대 그런 조합을 내지 않는다(항상 1 이 정확히 하나).
    /// 결과로 코너 0 과 코너 1 이 같은 격자점을 두 번 세고, |값| 이 1 을 넘는다(실측 최대 ~1.39).
    ///
    /// SSE4.1 경로(`0x1400fd18d` / `0x1400fd1f2`)도 같은 술어라 두 디스패치가 일치한다.
    /// 좌표 두 성분의 차가 정확한 정수면 동률이 나므로 "예쁜" 좌표에서는 드물지 않다 —
    /// 아래 (1.55, 2.7, -2.3) 은 `y - z = 5.0` 이라 걸린다.
    func testSnoise3ReproducesBinaryCornerDegeneracyOnTies() {
        let v = SimplexNoise.snoise3(1.55, 2.7, -2.3)
        XCTAssertEqual(v, -1.0602951, accuracy: tol)
        XCTAssertLessThan(v, -1, "실물이 여기서 -1 을 밑돈다 — 자바 원본대로 고치면 실물과 갈린다")

        // 동률이지만 x0 >= y0 쪽은 멀쩡하다(자바와 같은 코너를 고른다).
        XCTAssertEqual(SimplexNoise.snoise3(0, 1, 1), -0.65222132, accuracy: tol)
        XCTAssertEqual(SimplexNoise.snoise3(0.25, 1.5, 1.5), 0.10090604, accuracy: tol)
    }

    /// 셀 경계를 넘어도 2D 는 매끄럽다 — 코너 선택(`0x14027b252` 의 단일 비교)이 옳다는 증거.
    func testSnoise2IsContinuousAcrossCells() {
        var worst: Float = 0
        for a in -400...400 {
            let x = Float(a) * 0.05
            for b in -20...20 {
                let y = Float(b) * 0.31
                worst = max(worst, abs(SimplexNoise.snoise2(x, y) - SimplexNoise.snoise2(x + 0.001, y)))
            }
        }
        XCTAssertLessThan(worst, 0.02, "dx = 1e-3 에서 점프가 나면 코너 선택이 틀린 것이다")
    }

    func testDeterministic() {
        for (x, y, z) in [(0.1 as Float, 0.2 as Float, 0.3 as Float), (-9.75, 3.5, 0.125)] {
            XCTAssertEqual(SimplexNoise.snoise2(x, y), SimplexNoise.snoise2(x, y))
            XCTAssertEqual(SimplexNoise.snoise3(x, y, z), SimplexNoise.snoise3(x, y, z))
        }
    }

    /// 실물은 `cvttss2si` 라 오버플로/NaN 에서 그냥 쓰레기 정수를 뱉고 지나간다.
    /// Swift 의 `Int(Float)` 는 트랩하므로 `fold` 로 정의역을 접었다 — 여기서 죽지 않는지 본다.
    func testNonFiniteAndHugeInputsDoNotTrap() {
        let nasty: [Float] = [.nan, .infinity, -.infinity, 3.0e38, -3.0e38, 1e12, -1e12, 0]
        for x in nasty {
            for y in nasty {
                XCTAssertTrue(SimplexNoise.snoise2(x, y).isFinite, "snoise2(\(x), \(y))")
                XCTAssertTrue(SimplexNoise.snoise3(x, y, 0.5).isFinite, "snoise3(\(x), \(y), 0.5)")
            }
        }
        // 비유한은 0 으로 접는다 → 원점과 같은 값.
        XCTAssertEqual(SimplexNoise.snoise2(.nan, .nan), SimplexNoise.snoise2(0, 0))
        XCTAssertEqual(SimplexNoise.snoise3(.infinity, .nan, -.infinity), SimplexNoise.snoise3(0, 0, 0))
    }

    /// `fastFloor` 는 `cvttss2si` + 보정(`0x14027b1e1`–`0x14027b1f1`)이다 — 음수에서 내림.
    func testFastFloor() {
        XCTAssertEqual(SimplexNoise.fastFloor(0), 0)
        XCTAssertEqual(SimplexNoise.fastFloor(0.9), 0)
        XCTAssertEqual(SimplexNoise.fastFloor(1), 1)
        XCTAssertEqual(SimplexNoise.fastFloor(-0.1), -1)
        XCTAssertEqual(SimplexNoise.fastFloor(-1), -1)
        XCTAssertEqual(SimplexNoise.fastFloor(-1.5), -2)
    }
}
