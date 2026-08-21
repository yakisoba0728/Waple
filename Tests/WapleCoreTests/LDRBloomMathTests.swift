import XCTest
import simd
@testable import WapleCore

/// `LDRBloomMath` — WE LDR 블룸 3패스 산술. 근거 VA 는 `Sources/WapleCore/LDRBloomMath.swift` 헤더.
final class LDRBloomMathTests: XCTestCase {

    // MARK: - 저작값 기본치

    func testAuthoringDefaultsMatchSceneConstructorImmediates() {
        // Scene::Scene 0x1401870ac = 0x40000000, 0x1401870b7 = 0x3f266666.
        XCTAssertEqual(LDRBloomMath.defaultStrength, 2)
        XCTAssertEqual(LDRBloomMath.defaultThreshold.bitPattern, UInt32(0x3f26_6666))
        XCTAssertEqual(LDRBloomMath.defaultTint, SIMD3<Float>(1, 1, 1))
    }

    // MARK: - 탭 기하

    func testExtractTapIsOneFullResolutionTexel() {
        let t = LDRBloomMath.extractTapOffsetUV(sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(t.x, 1.0 / 1920, accuracy: 1e-9)
        XCTAssertEqual(t.y, 1.0 / 1080, accuracy: 1e-9)
    }

    /// 대각 4탭이 4×4 박스 **정확 평균**이 되는지: 목적지 픽셀 i 의 중심은 소스 텍셀좌표 4i+2 이고
    /// ±1 소스텍셀 지점(4i+1, 4i+3)의 bilinear 는 각각 텍셀 4i..4i+1 / 4i+2..4i+3 을 0.5:0.5 로
    /// 섞는다 — 1차원 두 탭이 소스 텍셀 4개를 균등하게 덮는다.
    func testDiagonalTapsCoverTheFourByFourBoxExactly() {
        let width = 64
        let t = LDRBloomMath.extractTapOffsetUV(sourceWidth: width, sourceHeight: width)
        let destination = 3
        let centerUV = (Float(destination) + 0.5) / Float(width / 4)
        var coverage = [Float](repeating: 0, count: width)
        for sign in [Float(-1), Float(1)] {
            // 탭 지점을 소스 텍셀좌표로: t_tex = uv * width
            let texel = (centerUV + sign * t.x) * Float(width)
            // bilinear: texel - 0.5 의 양옆 두 텍셀
            let lower = Int((texel - 0.5).rounded(.down))
            let frac = (texel - 0.5) - Float(lower)
            coverage[lower] += 0.5 * (1 - frac)
            coverage[lower + 1] += 0.5 * frac
        }
        // 이 축의 두 탭이 소스 텍셀 12..15 를 각각 정확히 1/4 씩 덮어야 한다.
        for k in 0..<width {
            let expected: Float = (12...15).contains(k) ? 0.25 : 0
            XCTAssertEqual(coverage[k], expected, accuracy: 1e-5, "texel \(k)")
        }
    }

    /// F671 의 핵심: X·Y 블러 스트라이드가 **둘 다 풀해상도 8텍셀**이라 등방이다.
    func testBlurStridesAreIsotropicInFullResolutionTexels() {
        let fullW = 1920, fullH = 1080
        let quarterW = fullW / 4, eighthH = fullH / 8
        let hx = LDRBloomMath.horizontalStepUV(quarterWidth: quarterW).x
        let vy = LDRBloomMath.verticalStepUV(eighthHeight: eighthH).y
        XCTAssertEqual(hx * Float(fullW), 8, accuracy: 1e-4, "X = 8 풀텍셀")
        XCTAssertEqual(vy * Float(fullH), 8, accuracy: 1e-4, "Y = 8 풀텍셀")
        // 축 방향은 서로 배타적이어야 한다(1D 분리형).
        XCTAssertEqual(LDRBloomMath.horizontalStepUV(quarterWidth: quarterW).y, 0)
        XCTAssertEqual(LDRBloomMath.verticalStepUV(eighthHeight: eighthH).x, 0)
    }

    func testHorizontalStepIsTwoQuarterTexels() {
        let step = LDRBloomMath.horizontalStepUV(quarterWidth: 480)
        XCTAssertEqual(step.x * 480, 2, accuracy: 1e-5)
    }

    func testDegenerateDimensionsDoNotDivideByZero() {
        XCTAssertTrue(LDRBloomMath.extractTapOffsetUV(sourceWidth: 0, sourceHeight: 0).x.isFinite)
        XCTAssertTrue(LDRBloomMath.horizontalStepUV(quarterWidth: 0).x.isFinite)
        XCTAssertTrue(LDRBloomMath.verticalStepUV(eighthHeight: 0).y.isFinite)
    }

    // MARK: - 13탭 커널

    func testBlur13WeightsMatchShaderLiteralsAndAreNormalized() {
        let w = LDRBloomMath.blur13Weights
        XCTAssertEqual(w.count, 13)
        // downsample_eighth_blur_v.frag:7-19 / blur_h_bloom.frag:7-19 의 리터럴 순서 그대로.
        let expected: [Float] = [
            0.006299, 0.017298, 0.039533, 0.075189, 0.119007, 0.156756,
            0.171834,
            0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299
        ]
        for (a, b) in zip(w, expected) { XCTAssertEqual(a, b, accuracy: 1e-7) }
        XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-4, "WE 커널은 합 1 로 정규화돼 있다")
        // common_blur.h 의 blur13(7탭 bilinear)과 혼동 금지 — 그쪽 중앙값은 0.19764 다.
        XCTAssertNotEqual(LDRBloomMath.blur13HalfWeights[0], 0.1976406528809576)
    }

    // MARK: - 추출 산술

    func testBelowThresholdExtractsNothing() {
        let out = LDRBloomMath.extract(
            boxAverage: SIMD3(0.5, 0.4, 0.3), threshold: 0.65, strength: 2,
            tint: SIMD3(1, 1, 1))
        XCTAssertEqual(out, SIMD3<Float>(0, 0, 0))
    }

    /// 게이트는 **비율이 아니라 초과분**이다 — `saturate(max − T)`.
    func testGateIsExcessOverThresholdNotRatio() {
        let rgb = SIMD3<Float>(0.9, 0.9, 0.9)
        let out = LDRBloomMath.extract(
            boxAverage: rgb, threshold: 0.65, strength: 1, tint: SIMD3(1, 1, 1))
        // gate = saturate(0.9-0.65) = 0.25, gated = 0.225 균일 → 2*0.225 - gray(≈0.225) ≈ 0.225.
        // 비율 게이트(0.9-0.65)/0.9 = 0.278 이었다면 0.25 가 나온다 — 값이 갈린다.
        XCTAssertEqual(out.x, 0.225, accuracy: 1e-4)
        XCTAssertEqual(out.y, 0.225, accuracy: 1e-4)
        XCTAssertEqual(out.z, 0.225, accuracy: 1e-4)
    }

    /// 게이트는 1 로 saturate 된다 — 임계를 1 이상 넘겨도 더 세지지 않는다.
    func testGateSaturatesAtOne() {
        let a = LDRBloomMath.extract(
            boxAverage: SIMD3(2.0, 2.0, 2.0), threshold: 0, strength: 1, tint: SIMD3(1, 1, 1))
        let b = LDRBloomMath.extract(
            boxAverage: SIMD3(2.0, 2.0, 2.0), threshold: -5, strength: 1, tint: SIMD3(1, 1, 1))
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
    }

    /// `albedo = 2*c − gray` = `mix(gray, c, 2)` — **luma 를 축으로 채도를 2배로 민다**.
    /// 무채색은 (계수 합이 0.9999 라 반올림 오차만 빼면) 그대로 통과하고, 순색은 luma 만큼 더 밀린다.
    func testSaturationBoostIsIdentityOnGrayAndPushesPureHue() {
        let gray = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 1, 1), threshold: 0, strength: 1, tint: SIMD3(1, 1, 1))
        XCTAssertEqual(gray.x, 1, accuracy: 1e-3, "회색은 채도 부스트의 고정점이다")
        XCTAssertEqual(gray.y, 1, accuracy: 1e-3)
        XCTAssertEqual(gray.z, 1, accuracy: 1e-3)

        let red = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 0, 0), threshold: 0, strength: 1, tint: SIMD3(1, 1, 1))
        // gray = 0.2989 → r = 2 - 0.2989 = 1.7011, g = b = -0.2989 → max(0,·) = 0
        XCTAssertEqual(red.x, 1.7011, accuracy: 1e-4)
        XCTAssertEqual(red.y, 0)
        XCTAssertEqual(red.z, 0)
    }

    func testNegativeLobeIsClampedNotWrapped() {
        let out = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 0.2, 0.2), threshold: 0, strength: 4, tint: SIMD3(1, 1, 1))
        XCTAssertTrue(out.min() >= 0, "max(vec3(0), ·) 가 음수를 잘라야 한다")
    }

    func testTintAndStrengthAreAppliedAfterSaturationBoost() {
        let base = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 0, 0), threshold: 0, strength: 1, tint: SIMD3(1, 1, 1))
        let scaled = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 0, 0), threshold: 0, strength: 3, tint: SIMD3(1, 1, 1))
        XCTAssertEqual(scaled.x, base.x * 3, accuracy: 1e-4)

        let tinted = LDRBloomMath.extract(
            boxAverage: SIMD3(1, 0, 0), threshold: 0, strength: 1, tint: SIMD3(0, 1, 1))
        XCTAssertEqual(tinted.x, 0, accuracy: 1e-6, "틴트 R=0 이면 R 성분이 죽는다")
    }

    /// 채널 최대값이 게이트를 정한다 — 파랑만 밝아도 세 채널 전부가 통과 대상이 된다.
    func testGateUsesChannelMaximum() {
        let out = LDRBloomMath.extract(
            boxAverage: SIMD3(0.1, 0.1, 0.9), threshold: 0.65, strength: 1, tint: SIMD3(1, 1, 1))
        XCTAssertGreaterThan(out.z, 0)
    }

    // MARK: - 합성

    func testCompositeIsPlainAddition() {
        // combine.frag:13-15 — 감마도 톤커브도 없다. 클램프는 UNORM 타깃이 한다.
        let out = LDRBloomMath.composite(scene: SIMD3(0.5, 0.25, 0), glow: SIMD3(0.75, 0, 0.5))
        XCTAssertEqual(out, SIMD3<Float>(1.25, 0.25, 0.5))
    }
}
