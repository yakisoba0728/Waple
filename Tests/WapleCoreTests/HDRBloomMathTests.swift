import XCTest
import Foundation
import simd
@testable import WapleCore

/// `HDRBloomMath` — WE HDR 블룸 피라미드 산술(`Composite::allocateTargets` 0x14017f1b0–0x14017fa6f ·
/// `Composite::drawBloomChain` 0x140183610–0x140183a61)의 순수 재현 검증.
///
/// 이 클래스가 존재하는 이유는 하나다. 이 산술은 종전에 `HDRBloomPyramidPass`(WapleRender)의
/// `static` 이라 **리눅스에서 한 줄도 실행되지 않았고**, 그래서 탭 반경(`b19db5b`)과 레벨 수(W-25)
/// 두 이탈이 전부 macOS CI 왕복으로만 드러났다. 여기서 리눅스 레인이 덮는다.
final class HDRBloomMathTests: XCTestCase {

    // MARK: - 레벨 수 (W-25)

    /// WE 루프를 **독립 재구현**한 오라클. 명세를 옮겨 적은 것이 아니라 실물 명령을 그대로 따른다:
    /// `W' = max(W,2)`(cmovg 0x14017f1ec) · `H' = max(H,2)`(0x14017f200) ·
    /// `d = min(W',H')`(cmovg 0x14017f363) · `d /= 2`(sar 0x14017f376) ·
    /// `d <= 0` 이면 그 단은 안 만든다(jle 0x14017f37d) · 만들면 카운트(inc 0x14017f383) ·
    /// 루프는 8회(cmp ebx,8 0x14017f541). 실효 N = `max(1, min(iterations, 생성단수))`
    /// (comiss 0x14017f815 / 0x14017f822 → mov obj+0x3108 0x14017f82d·0x14017f841).
    private func weOracle(requested: Int, width: Int, height: Int) -> Int {
        var d = min(max(width, 2), max(height, 2))
        var allocated = 0
        for _ in 0..<8 {
            d /= 2
            if d <= 0 { break }
            allocated += 1
        }
        return max(1, min(requested, allocated))
    }

    /// 커밋된 기대치 표 — `Tests/WapleRenderTests/HDRBloomTests.swift` 와 같은 다섯 줄.
    /// 64×32 만 6 → **5** 로 바뀌었다(min 축 32 → floor(log2 32)=5).
    func testLevelCountMatchesCommittedTable() {
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 2048, sourceHeight: 1024), 8)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 512, sourceHeight: 512), 8)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 64, sourceHeight: 32), 5)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 3, sourceWidth: 512, sourceHeight: 512), 3)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 4, sourceHeight: 4), 2)
    }

    /// **min 축이 지배한다** — 긴 변을 아무리 키워도 값이 안 변한다. 종전 max 기준 구현은
    /// 여기서 긴 변을 따라 올라갔다(이 테스트가 W-25 회귀의 1차 그물이다).
    func testLevelCountIsDrivenByShortSideNotLongSide() {
        for long in [32, 64, 128, 256, 512, 1024, 4096] {
            XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: long, sourceHeight: 32), 5,
                           "짧은 변 32 인데 긴 변 \(long) 을 따라갔다 — max 기준 회귀")
            XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 32, sourceHeight: long), 5,
                           "축 대칭이 깨졌다(긴 변 \(long))")
        }
    }

    /// 상한 8 — WE 루프가 `cmp ebx,8`(0x14017f541)로 여덟 번만 돈다. 요청이 더 커도 8 이다.
    func testLevelCountCapsAtEightEvenWhenRequestedMore() {
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 99, sourceWidth: 4096, sourceHeight: 4096), 8)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 12, sourceWidth: 3840, sourceHeight: 2160), 8)
    }

    /// 하한 1 — `comiss xmm8(=1.0), xmm2`(0x14017f822) 가 0 을 1 로 끌어올린다.
    func testLevelCountFloorsAtOne() {
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 1, sourceHeight: 1), 1)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 0, sourceWidth: 1920, sourceHeight: 1080), 1)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: -5, sourceWidth: 1920, sourceHeight: 1080), 1)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 0, sourceHeight: 0), 1)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: -8, sourceHeight: -8), 1)
    }

    /// 오라클과 **전수 대조**. 폭 1…600 + 실사용 해상도 × 높이 27종 × 요청 0…12.
    func testLevelCountMatchesWEOracleExhaustively() {
        let widths = Array(1...600) + [640, 720, 800, 1024, 1080, 1280, 1440, 1920, 2048, 2560, 3840, 4096]
        let heights = [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 31, 32, 63, 64, 100,
                       127, 128, 144, 255, 256, 257, 360, 512, 720, 1080, 1440, 2160]
        var mismatches = 0
        for w in widths {
            for h in heights {
                for r in 0...12 {
                    let got = HDRBloomMath.levelCount(requested: r, sourceWidth: w, sourceHeight: h)
                    let want = weOracle(requested: r, width: w, height: h)
                    if got != want {
                        mismatches += 1
                        if mismatches <= 5 {
                            XCTFail("levelCount(requested: \(r), \(w)×\(h)) = \(got), WE 오라클 = \(want)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "WE 오라클과 \(mismatches)건 불일치")
    }

    /// 닫힌 식 `min(8, floor(log2(min(W,H))))` 와도 맞는다(요청이 충분히 클 때).
    func testLevelCountEqualsFloorLog2OfShortSide() {
        for w in [3, 5, 17, 33, 100, 144, 255, 256, 257, 1080, 1920] {
            for h in [3, 5, 17, 33, 100, 144, 255, 256, 257, 1080, 1920] {
                let m = min(w, h)
                var expected = 0
                var d = m
                while d > 1 && expected < 8 { d /= 2; expected += 1 }
                XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: w, sourceHeight: h),
                               max(1, expected), "\(w)×\(h)")
            }
        }
    }

    /// **도달 경계** — 짧은 변이 256 이상이면 상한 8 이라 max 기준이든 min 기준이든 같은 값이다
    /// (그래서 풀스크린 실사용의 화면 차이는 0 이다).
    func testNoDivergenceWhenShortSideAtLeast256() {
        for (w, h) in [(3840, 2160), (2560, 1440), (1920, 1080), (1680, 1050), (1440, 900),
                       (1366, 768), (1280, 720), (1024, 768), (800, 600), (640, 360),
                       (640, 480), (512, 512), (256, 256)] {
            XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: w, sourceHeight: h), 8,
                           "\(w)×\(h) 는 짧은 변 ≥ 256 이라 상한 8 이어야 한다")
        }
    }

    /// **도달이 0 은 아니다** — 이 리포의 골든 썸네일(`SnapshotPipeline.thumbW/thumbH` = 256×144)과
    /// 64×32 렌더 테스트는 갈리는 쪽에 있다. 갈리는 조건은 "짧은 변 < 256 이고 두 변의
    /// 2-거듭제곱 구간이 다름". 이 값이 바뀌면 골든 재기준선이 필요하다는 뜻이므로 못박아 둔다.
    func testDivergentSizesAreExplicit() {
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 256, sourceHeight: 144), 7)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 192, sourceHeight: 108), 6)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 128, sourceHeight: 72), 6)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 64, sourceHeight: 36), 5)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 32, sourceHeight: 18), 4)
        // 정사각 2의 거듭제곱은 min == max 라 종전 산식과 같은 값이다(회귀 판정의 음성 대조).
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 64, sourceHeight: 64), 6)
        XCTAssertEqual(HDRBloomMath.levelCount(requested: 8, sourceWidth: 16, sourceHeight: 16), 4)
    }

    // MARK: - 강도 정규화

    /// `bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)`
    /// (powf 0x14017f85e → +1.0 0x14017f86b → divss 0x14017f88f).
    func testNormalizedStrengthMatchesWEFormula() {
        let scatter: Float = 1.619
        for n in 1...8 {
            let expected = Float(2) / (powf(scatter, Float(max(n, 2) - 2)) + 1)
            XCTAssertEqual(HDRBloomMath.normalizedStrength(strength: 2, scatter: scatter, levels: n),
                           expected, accuracy: 1e-6, "N=\(n)")
        }
        // 기본 저작값(scatter 1.619, N 8): 분모 ≈ 19.01 → 실효 ≈ 0.1052.
        XCTAssertEqual(HDRBloomMath.normalizedStrength(strength: 2, scatter: 1.619, levels: 8),
                       0.10521, accuracy: 1e-4)
        // N=7(골든 썸네일 256×144 의 실제 값): 분모 ≈ 12.12 → 실효 ≈ 0.1650. 약 1.57배 밝다.
        XCTAssertEqual(HDRBloomMath.normalizedStrength(strength: 2, scatter: 1.619, levels: 7),
                       0.16497, accuracy: 1e-4)
    }

    /// `max(N,2)-2` 클램프 — N=1 과 N=2 는 분모가 둘 다 2 다.
    func testNormalizedStrengthClampsExponentBelowTwoLevels() {
        let a = HDRBloomMath.normalizedStrength(strength: 4, scatter: 1.619, levels: 1)
        let b = HDRBloomMath.normalizedStrength(strength: 4, scatter: 1.619, levels: 2)
        XCTAssertEqual(a, b, accuracy: 1e-7)
        XCTAssertEqual(a, 2, accuracy: 1e-6)      // 4 / (scatter^0 + 1) = 4 / 2
    }

    /// 레벨이 늘수록 실효 강도는 **줄어든다**(scatter > 1). 부호가 뒤집히면 백화된다.
    func testNormalizedStrengthDecreasesWithLevels() {
        var previous = Float.greatestFiniteMagnitude
        for n in 2...8 {
            let v = HDRBloomMath.normalizedStrength(strength: 2, scatter: 1.619, levels: n)
            XCTAssertLessThan(v, previous, "N=\(n) 에서 강도가 줄지 않았다")
            previous = v
        }
    }

    // MARK: - 블렌드 파라미터

    /// `K = T*F`, `P = (T, T-K, 2K, 0.25/(K+1e-5))` (0x14017f8bc–0x14017f900).
    func testBlendParamsPacking() {
        let p = HDRBloomMath.blendParams(threshold: 1, feather: 0.1)
        XCTAssertEqual(p.x, 1, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0.9, accuracy: 1e-5)
        XCTAssertEqual(p.z, 0.2, accuracy: 1e-5)
        XCTAssertEqual(p.w, 2.49975, accuracy: 1e-3)

        let q = HDRBloomMath.blendParams(threshold: 2, feather: 0.5)   // K = 1
        XCTAssertEqual(q.x, 2, accuracy: 1e-6)
        XCTAssertEqual(q.y, 1, accuracy: 1e-6)
        XCTAssertEqual(q.z, 2, accuracy: 1e-6)
        XCTAssertEqual(q.w, 0.25 / 1.00001, accuracy: 1e-5)
    }

    /// 음수 knee 방어는 **Waple 추가분**이다(WE 는 음수 feather 를 막지 않는다) — 0 으로 잘린다.
    func testBlendParamsClampsNegativeKnee() {
        let p = HDRBloomMath.blendParams(threshold: 1, feather: -0.5)
        XCTAssertEqual(p.y, 1, accuracy: 1e-6)
        XCTAssertEqual(p.z, 0, accuracy: 1e-6)
        XCTAssertEqual(p.w, 0.25 / 1e-5, accuracy: 1)
    }

    // MARK: - 탭 배율·오프셋

    /// 다운샘플 `1 << i`(0x14018374a–0x14018375c) · 업샘플 `2 << (i−1)`(0x140183856–0x14018386b).
    func testTapScales() {
        XCTAssertEqual(HDRBloomMath.downsampleTapScale(level: 0), 1)
        XCTAssertEqual(HDRBloomMath.downsampleTapScale(level: 1), 2)
        XCTAssertEqual(HDRBloomMath.downsampleTapScale(level: 7), 128)
        XCTAssertEqual(HDRBloomMath.downsampleTapScale(level: -3), 1)   // 음수 방어

        XCTAssertEqual(HDRBloomMath.upsampleTapScale(sourceLevel: 1), 2)
        XCTAssertEqual(HDRBloomMath.upsampleTapScale(sourceLevel: 2), 4)
        XCTAssertEqual(HDRBloomMath.upsampleTapScale(sourceLevel: 7), 128)
        XCTAssertEqual(HDRBloomMath.upsampleTapScale(sourceLevel: 0), 2)  // 2 << max(0,-1) = 2

        // 숫자는 같지만 소스 레벨이 한 단 다르다 — 그것이 반경 절반의 정체다.
        for i in 1...7 {
            XCTAssertEqual(HDRBloomMath.upsampleTapScale(sourceLevel: i),
                           HDRBloomMath.downsampleTapScale(level: i))
        }
    }

    /// 오프셋 기저는 **풀 프레임버퍼** 기준이다(0x1401836a0–0x1401836ba).
    func testTapOffsetUVUsesFullFramebufferBase() {
        let o = HDRBloomMath.tapOffsetUV(scale: 4, baseWidth: 1024, baseHeight: 512)
        XCTAssertEqual(o.x, 4.0 / 1024, accuracy: 1e-9)
        XCTAssertEqual(o.y, 4.0 / 512, accuracy: 1e-9)
        // 0 나눗셈 방어.
        let z = HDRBloomMath.tapOffsetUV(scale: 1, baseWidth: 0, baseHeight: 0)
        XCTAssertEqual(z.x, 1, accuracy: 1e-9)
        XCTAssertEqual(z.y, 1, accuracy: 1e-9)
    }

    /// **W-1 의 판정식** — 추출·다운샘플은 ±1.0 소스 텍셀, 업샘플만 ±0.5 다.
    /// `b19db5b` 이전 구현은 세 계열 전부 ±0.5 였다(공용 헬퍼의 `0.5/텍스처크기` 되짚기).
    func testTapRadiusInSourceTexelsIsOneForDownsampleAndHalfForUpsample() {
        let baseW = 1024, baseH = 512

        // 추출(level 0): 소스 = 풀 프레임버퍼.
        let extract = HDRBloomMath.tapOffsetUV(
            scale: HDRBloomMath.downsampleTapScale(level: 0), baseWidth: baseW, baseHeight: baseH)
        XCTAssertEqual(HDRBloomMath.tapRadiusInSourceTexels(offsetUV: extract.x, sourceWidth: baseW),
                       1.0, accuracy: 1e-5)

        // 다운샘플 i: 소스 = level[i−1] = 폭 baseW >> i.
        for i in 1...7 {
            let off = HDRBloomMath.tapOffsetUV(
                scale: HDRBloomMath.downsampleTapScale(level: i), baseWidth: baseW, baseHeight: baseH)
            XCTAssertEqual(
                HDRBloomMath.tapRadiusInSourceTexels(offsetUV: off.x, sourceWidth: baseW >> i),
                1.0, accuracy: 1e-5, "다운샘플 level \(i)")
        }

        // 업샘플 소스레벨 i: 소스 = level[i] = 폭 baseW >> (i+1).
        for i in 1...6 {
            let off = HDRBloomMath.tapOffsetUV(
                scale: HDRBloomMath.upsampleTapScale(sourceLevel: i), baseWidth: baseW, baseHeight: baseH)
            XCTAssertEqual(
                HDRBloomMath.tapRadiusInSourceTexels(offsetUV: off.x, sourceWidth: baseW >> (i + 1)),
                0.5, accuracy: 1e-5, "업샘플 sourceLevel \(i)")
        }
    }

    // MARK: - BICUBIC 슬롯 선택

    /// `cmp ebp, N-2 ; cmovl`(0x140183810–0x140183822) — **가장 깊은 두 단만** 큐빅이다.
    func testUpsampleUsesBicubicOnlyForDeepestTwoStages() {
        let n = 8
        var cubic: [Int] = []
        for sourceLevel in stride(from: n - 1, through: 1, by: -1)
        where HDRBloomMath.upsampleUsesBicubic(sourceLevel: sourceLevel, levelCount: n) {
            cubic.append(sourceLevel)
        }
        XCTAssertEqual(cubic, [7, 6], "N=8 에서 큐빅 단이 소스레벨 7·6 이 아니다")

        // 다른 N 에서도 항상 두 단이다(N ≥ 3).
        for levels in 3...8 {
            let count = (1...(levels - 1)).filter {
                HDRBloomMath.upsampleUsesBicubic(sourceLevel: $0, levelCount: levels)
            }.count
            XCTAssertEqual(count, 2, "N=\(levels)")
        }
        // N=2 는 업샘플 단이 하나뿐이고 그 하나가 큐빅이다.
        XCTAssertTrue(HDRBloomMath.upsampleUsesBicubic(sourceLevel: 1, levelCount: 2))
    }
}
