import Foundation
import XCTest
@testable import WapleCore

/// WE 볼류메트릭 라이트(`shaders/volumetricsfront.frag`) 이식 산술을 **리눅스에서 실행해** 잠근다.
///
/// ## 왜 이 파일이 생겼나 (2026-08-21)
/// 이식 자체는 `7c66d46` 에 들어갔지만, 값을 실제로 계산해 보는 테스트는
/// `Tests/WapleRenderTests/VolumetricLightTests.swift` **하나뿐**이었고 그건 macOS 전용이다
/// (`import Metal`). 리눅스에서는 `scripts/dev/linux-render-typecheck.sh` 가 타입만 보고 값은
/// 한 번도 계산하지 않는다. 그래서 산술을 `SceneWEVolumetricMath` 로 옮기고(WapleCore) 여기서
/// 실행한다 — 공통 브리프 §3.2 의 "순수 계산 로직은 WapleCore 로 빼서 리눅스 테스트로 덮어라".
///
/// ## 대조 방식: **오라클 재구현**
/// 아래 `Oracle` 은 `volumetricsfront.frag` 를 **줄 단위로 다시 옮긴 독립 전사본**이다.
/// 이식본(`SceneWEVolumetricMath`)과 코드를 공유하지 않는다 — 일부러 다른 꼴로 적었다:
/// - 감쇠: 이식본은 역수 곱(`d * (1/R)`), 오라클은 GLSL 원문 그대로 `invRadius` 를 한 번 잡는다(`:116`).
/// - 구 교차: 이식본은 `a = dot(d,d) = 1` 축약형, 오라클은 **축약하지 않은 이차식**
///   (`a·t² + b·t + c`, `t = (−b ± √(b²−4ac)) / 2a`)으로 푼다 — 부호·계수 오류가 여기서 갈린다.
/// - `smoothstep`: 오라클은 GLSL 명세 정의를 그대로 적는다.
/// 두 벌이 같은 답을 내야 "수식이 맞다" 가 성립한다. 값이 갈리면 둘 중 하나가 원문과 다르다.
///
/// ## 셰이더 원문 줄 번호는 이 컨테이너에서 직접 확인했다
/// `Sources/WapleRender/Resources/WEAssets/shaders/volumetricsfront.frag`(192줄, md5
/// `22f6d8608151a60e0568c741227e2c03` — 설치본
/// `wallpaper_engine/assets/shaders/volumetricsfront.frag` 와 **바이트 동일**):
/// `:113` 스텝 `(sampleCount + 1.0)` · `:115-122` `maxLightScale`(`:119` POINTLIGHT ×0.5) ·
/// `:128-130` 더한 뒤 샘플 · `:132` 반경 감쇠 · `:139-140` 콘 스무드스텝 · `:187` `/= sampleCount` ·
/// `:190` `× 0.1`. 남의 주석을 베끼지 않았다(공통 브리프 함정 #16).
///
/// ## 도달 (같은 날 이 컨테이너 실측)
/// 게이트 키 `castvolumetrics` 는 동봉 172 ∪ 설치본 186 = **distinct 186 씬에서 0건**이다.
/// 즉 이 산술을 고쳐도 두 트리의 어떤 씬도 화면이 바뀌지 않는다. 그래도 값을 잠그는 이유는
/// 워크샵 씬(4건/3씬)과 앞으로의 회귀 때문이다.
final class SceneVolumetricMathTests: XCTestCase {

    // MARK: - `volumetricsfront.frag` 독립 전사 오라클

    /// 셰이더 원문을 그대로 옮긴 참조 구현. 이식본과 **코드를 공유하지 않는다**.
    private enum Oracle {
        /// GLSL `saturate` = `clamp(x, 0, 1)`.
        static func saturate(_ x: Float) -> Float { min(1, max(0, x)) }

        /// GLSL 명세의 `smoothstep(edge0, edge1, x)`.
        static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = saturate((x - edge0) / (edge1 - edge0))
            return t * t * (3 - 2 * t)
        }

        /// `:78-97` — QUALITY 콤보. 원문 분기 순서를 그대로 옮긴다.
        static func sampleCount(quality: Int, shadowOrCookie: Bool) -> Int {
            if shadowOrCookie {
                if quality == 4 { return 64 }
                if quality == 3 { return 32 }
                if quality == 2 { return 24 }
                return 12
            }
            if quality == 4 { return 8 }
            if quality == 3 { return 5 }
            if quality == 2 { return 3 }
            return 2
        }

        /// `:132` — `pow(saturate(1.0 - (length(lightDelta) * invRadius)), VAR_EXPONENT)`.
        /// `invRadius` 는 `:116` 에서 한 번 잡는다.
        static func radiusFalloff(distance: Float, radius: Float, exponent: Float) -> Float {
            let invRadius = 1.0 / radius
            let base = saturate(1.0 - (distance * invRadius))
            // GPU `pow(0, 0) = 1`. 이식본이 `encode` 와 같은 음수-지수 클램프를 하므로 오라클도 맞춘다.
            let e = max(0, exponent)
            if base <= 0 { return e <= 0 ? 1 : 0 }
            return powf(base, e)
        }

        /// `:139-140` — 스팟 콘. 인자 `cos` 는 **라이트→샘플** 방향과 forward 의 내적이다.
        static func spotCookie(cosAngle: Float, cosInner: Float, cosOuter: Float) -> Float {
            smoothstep(cosOuter, cosInner, cosAngle)
        }

        /// 뷰 레이 ↔ 반경 구 교차. **축약하지 않은 이차식**으로 푼다(이식본은 `a=1` 축약형).
        /// 반환은 파라미터 t 두 개(작은 것/큰 것). 교차 없으면 nil.
        static func sphereHit(eye: (Float, Float, Float), dir: (Float, Float, Float),
                              center: (Float, Float, Float), radius: Float) -> (Float, Float)? {
            let ox = eye.0 - center.0, oy = eye.1 - center.1, oz = eye.2 - center.2
            let a = dir.0 * dir.0 + dir.1 * dir.1 + dir.2 * dir.2
            let b = 2 * (ox * dir.0 + oy * dir.1 + oz * dir.2)
            let c = ox * ox + oy * oy + oz * oz - radius * radius
            let disc = b * b - 4 * a * c
            guard disc > 0 else { return nil }
            let sq = sqrtf(disc)
            return ((-b - sq) / (2 * a), (-b + sq) / (2 * a))
        }

        /// 한 픽셀의 최종 스칼라. `:105-191` 을 카메라 기저 레이로 옮긴 것.
        /// `radius` 는 셰이더가 받는 값(= 씬 `radius × 0.99`)이 아니라 **씬 저작값**을 받는다 —
        /// `× 0.99` 도 여기서 원문(`0x140198760`) 대로 다시 적는다.
        static func pixel(x: Int, y: Int, width: Int, height: Int,
                          eye: (Float, Float, Float),
                          forward: (Float, Float, Float), right: (Float, Float, Float),
                          up: (Float, Float, Float),
                          fovYDegrees: Float, aspect: Float, nearZ: Float, farZ: Float,
                          lightPosition: (Float, Float, Float), lightForward: (Float, Float, Float),
                          density: Float, exponent: Float, intensity: Float,
                          cosInner: Float, cosOuter: Float, sceneRadius: Float,
                          sampleCount: Int, isPoint: Bool) -> Float {
            let hull = (sceneRadius > 0 ? sceneRadius : 1) * 0.99
            guard hull > 0, farZ > nearZ, nearZ > 0 else { return 0 }

            // 픽셀 중심 NDC — 광축이 아니다.
            let u = (Float(x) + 0.5) / Float(width)
            let v = (Float(y) + 0.5) / Float(height)
            let ndcX = u * 2 - 1
            let ndcY = 1 - v * 2

            let tanHalf = tanf(fovYDegrees * Float.pi / 180 / 2)
            let sx = ndcX * tanHalf * aspect
            let sy = ndcY * tanHalf
            var dx = forward.0 + right.0 * sx + up.0 * sy
            var dy = forward.1 + right.1 * sx + up.1 * sy
            var dz = forward.2 + right.2 * sx + up.2 * sy
            let dn = sqrtf(dx * dx + dy * dy + dz * dz)
            if dn > 0 { dx /= dn; dy /= dn; dz /= dn }

            guard let hit = sphereHit(eye: eye, dir: (dx, dy, dz), center: lightPosition, radius: hull)
            else { return 0 }
            let tEnter = max(hit.0, nearZ)
            let tExit = min(hit.1, farZ)
            guard tExit > tEnter else { return 0 }

            let segment = tExit - tEnter
            // `:115-122` — POINTLIGHT 만 ×0.5.
            var maxLightScale = intensity * segment * (1.0 / hull)
            if isPoint { maxLightScale *= 0.5 }

            // `:113` — (N+1) 분할, `:128-130` — 더한 뒤 샘플.
            let stepLen = segment / (Float(sampleCount) + 1)
            var px = eye.0 + dx * tEnter, py = eye.1 + dy * tEnter, pz = eye.2 + dz * tEnter
            var shadowFactor: Float = 0
            for _ in 0..<sampleCount {
                px += dx * stepLen; py += dy * stepLen; pz += dz * stepLen
                let lx = px - lightPosition.0, ly = py - lightPosition.1, lz = pz - lightPosition.2
                let dist = sqrtf(lx * lx + ly * ly + lz * lz)
                let rf = radiusFalloff(distance: dist, radius: hull, exponent: exponent)
                var cookie: Float = 1
                if !isPoint {
                    let inv = 1 / max(dist, 1e-6)
                    let cosAngle = (lx * inv) * lightForward.0 + (ly * inv) * lightForward.1
                        + (lz * inv) * lightForward.2
                    cookie = spotCookie(cosAngle: cosAngle, cosInner: cosInner, cosOuter: cosOuter)
                }
                shadowFactor += rf * cookie
            }
            shadowFactor /= Float(sampleCount)          // `:187`
            return density * maxLightScale * shadowFactor * 0.1   // `:190`
        }
    }

    // MARK: - 픽스처

    /// macOS 렌더 테스트(`VolumetricLightTests.directionFixtureInput`)와 **같은 픽스처**.
    /// 카메라 eye (0,0,10) → 원점 · up (0,1,0) ⇒ fwd (0,0,-1) · right (1,0,0) · camUp (0,1,0).
    /// near/far 는 씬 미저작 기본값(0.1 / 10000), fov 50, 라이트는 원점의 정면 스팟
    /// (`innercone 10` / `outercone 30` 을 **종전** 변환기(`× 0.5`)가 주던 `cos5°`/`cos15°`.
    ///  2026-08-21 에 변환기가 `cos10°`/`cos30°` 로 정정됐지만, 이 픽스처는 아래 골든 값과
    ///  짝이라 **의도적으로 옛 코사인을 리터럴로 고정**한다 — 여기서 재는 것은 콘 규약이
    ///  아니라 마치 산술이다. 콘 규약을 재는 곳은 `SceneSpotConeTests` 이고,
    ///  변환기를 실제로 태우는 픽스처는 `Tests/WapleRenderTests/VolumetricLightTests.swift`
    ///  다(그쪽 골든은 새 콘으로 갱신했다).
    private static func fixture(radius: Float) -> SceneWEVolumetricMath.PixelInput {
        SceneWEVolumetricMath.PixelInput(
            eye: SIMD3(0, 0, 10), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            fovYDegrees: 50, aspect: 1, nearZ: 0.1, farZ: 10000,
            lightPosition: SIMD3(0, 0, 0), lightForward: SIMD3(0, 0, 1),
            density: 3, exponent: 1, intensity: 6,
            innerCos: cosf(5 * Float.pi / 180), outerCos: cosf(15 * Float.pi / 180),
            radius: radius, sampleCount: 8)
    }

    private static func oracleFixture(_ i: SceneWEVolumetricMath.PixelInput,
                                      x: Int, y: Int, width: Int, height: Int) -> Float {
        Oracle.pixel(x: x, y: y, width: width, height: height,
                     eye: (i.eye.x, i.eye.y, i.eye.z),
                     forward: (i.forward.x, i.forward.y, i.forward.z),
                     right: (i.right.x, i.right.y, i.right.z),
                     up: (i.up.x, i.up.y, i.up.z),
                     fovYDegrees: i.fovYDegrees, aspect: i.aspect, nearZ: i.nearZ, farZ: i.farZ,
                     lightPosition: (i.lightPosition.x, i.lightPosition.y, i.lightPosition.z),
                     lightForward: (i.lightForward.x, i.lightForward.y, i.lightForward.z),
                     density: i.density, exponent: i.exponent, intensity: i.intensity,
                     cosInner: i.innerCos, cosOuter: i.outerCos, sceneRadius: i.radius,
                     sampleCount: i.sampleCount, isPoint: i.isPoint)
    }

    // MARK: - 1. QUALITY 콤보 샘플 수 (`:78-97`)

    func testSampleCountTableMatchesShaderCombos() {
        // 셰도우/쿠키 가지 — `:79`,`:81`,`:83`,`:85`.
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 4, shadowed: true), 64)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 3, shadowed: true), 32)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 2, shadowed: true), 24)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 1, shadowed: true), 12)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 0, shadowed: true), 12)
        // 셰도우·쿠키 둘 다 없는 가지 — `:89`,`:91`,`:93`,`:95`. **여기가 Waple 이 가는 길이다.**
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 4, shadowed: false), 8)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 3, shadowed: false), 5)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 2, shadowed: false), 3)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 1, shadowed: false), 2)
        XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: 0, shadowed: false), 2)
        // 오라클 전수 대조 — 범위를 넘는 티어도 `else` 가지로 접히는지 함께 본다.
        for q in -1...6 {
            for shadowed in [true, false] {
                XCTAssertEqual(SceneWEVolumetricMath.sampleCount(quality: q, shadowed: shadowed),
                               Oracle.sampleCount(quality: q, shadowOrCookie: shadowed),
                               "quality=\(q) shadowed=\(shadowed)")
            }
        }
    }

    /// `scene-postprocessing.md` §W-17 의 "12~64 샘플" 은 **셰도우/쿠키 가지 전용**이다.
    /// 그 외 가지는 2~8 이고, Waple 은 셰도우/쿠키 텍스처를 바인딩하지 않으므로 항상 후자다.
    func testShadowlessBranchIsFarCheaperThanShadowedBranch() {
        for q in 0...4 {
            XCTAssertLessThan(SceneWEVolumetricMath.sampleCount(quality: q, shadowed: false),
                              SceneWEVolumetricMath.sampleCount(quality: q, shadowed: true))
        }
    }

    // MARK: - 2. 라이트버퍼 FBO 스케일 / 블러 (복원 전용 — 현 경로 미소비)

    func testLightBufferDivisorAndBlurGate() {
        // `0x140196d79`–`0x140196d88`: `edi = quality >= 3 ? 4 : 8`.
        XCTAssertEqual(SceneWEVolumetricMath.lightBufferDivisor(quality: 4), 4)
        XCTAssertEqual(SceneWEVolumetricMath.lightBufferDivisor(quality: 3), 4)
        XCTAssertEqual(SceneWEVolumetricMath.lightBufferDivisor(quality: 2), 8)
        XCTAssertEqual(SceneWEVolumetricMath.lightBufferDivisor(quality: 0), 8)
        // `0x140196ea0`(RT 미생성) · `0x140198d21`(리졸브 스킵) — 블러는 QUALITY<3 에서만 존재.
        XCTAssertFalse(SceneWEVolumetricMath.blursLightBuffer(quality: 4))
        XCTAssertFalse(SceneWEVolumetricMath.blursLightBuffer(quality: 3))
        XCTAssertTrue(SceneWEVolumetricMath.blursLightBuffer(quality: 2))
        XCTAssertTrue(SceneWEVolumetricMath.blursLightBuffer(quality: 0))
        // 분모가 바뀌는 지점과 블러가 꺼지는 지점이 **같은 티어 3** 이다(두 규칙의 단일 경계).
        for q in 0...4 {
            XCTAssertEqual(SceneWEVolumetricMath.blursLightBuffer(quality: q),
                           SceneWEVolumetricMath.lightBufferDivisor(quality: q) == 8)
        }
        // `common_blur.h:25-30` blur3 — 합이 1 인 3탭.
        XCTAssertEqual(SceneWEVolumetricMath.blur3Weights, [0.25, 0.5, 0.25])
        XCTAssertEqual(SceneWEVolumetricMath.blur3Weights.reduce(0, +), 1, accuracy: 1e-7)
    }

    // MARK: - 3. 반경 감쇠 (`:132`) — W-19 해소분

    /// **W-19 의 본체.** WE 는 `pow(saturate(1 − d/R), E)` 다 — 종전 Waple 의
    /// `exp(−density·dist·0.001)` 지수 꼬리가 아니다. 두 성질을 각각 못박는다:
    /// (a) 반경 밖이 **정확히 0**, (b) 지수가 곡선을 정한다.
    func testRadialFalloffMatchesOracleAndIsExactlyZeroOutsideRadius() {
        let radius: Float = 100
        for exponent in [Float(0.5), 1, 2, 3.04, 4] {
            for i in 0...24 {
                let d = Float(i) * 6   // 0 … 144 — 반경 안팎을 모두 훑는다
                let ported = SceneWEVolumetricMath.radialFalloff(distance: d, hullRadius: radius,
                                                                 exponent: exponent)
                let oracle = Oracle.radiusFalloff(distance: d, radius: radius, exponent: exponent)
                XCTAssertEqual(ported, oracle, accuracy: 1e-6, "d=\(d) E=\(exponent)")
                if d >= radius {
                    XCTAssertEqual(ported, 0, "반경 밖은 정확히 0 이어야 한다(지수 꼬리 없음) d=\(d)")
                }
            }
        }
        // 문서 §6 이 인용한 격자값(R=100)을 직접 못박는다.
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 0, hullRadius: 100, exponent: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 20, hullRadius: 100, exponent: 1), 0.8, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 20, hullRadius: 100, exponent: 2), 0.64, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 20, hullRadius: 100, exponent: 4), 0.4096, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 80, hullRadius: 100, exponent: 4), 0.0016, accuracy: 1e-6)
    }

    /// **옛 모델과의 분리 못.** 종전 이식은 `exp(−density·d·0.001)` 이었다 — 그 식은 반경 밖에서
    /// 절대 0 이 되지 않는다. 실물이 0 이라는 것이 W-19 정정의 요점이므로 두 식이 갈리는 것을
    /// 값으로 남긴다(회귀하면 이 단언이 먼저 깨진다).
    func testRadialFalloffIsNotTheOldExponentialTail() {
        let legacy = expf(-3 * 150 * 0.001)   // 옛 식: density 3, dist 150
        XCTAssertGreaterThan(legacy, 0.6, "옛 지수 꼬리는 반경 밖에서도 크게 남는다(대조군)")
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 150, hullRadius: 100, exponent: 1), 0,
                       "실물은 반경 밖에서 정확히 0")
    }

    /// `pow(0, 0) = 1` 규약과 음수 지수 클램프. `VolumetricLightPass.encode` 가 업로드 전
    /// `max(0, exponent)` 를 하므로 GPU 는 음수 지수를 **절대 못 본다** — CPU 미러도 같아야 한다.
    func testRadialFalloffExponentConventions() {
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 100, hullRadius: 100, exponent: 0), 1,
                       "base=0, exp=0 → pow(0,0)=1")
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 100, hullRadius: 100, exponent: 1), 0)
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 50, hullRadius: 100, exponent: 0), 1,
                       "지수 0 은 반경 안 전부 1")
        XCTAssertEqual(SceneWEVolumetricMath.radialFalloff(distance: 0, hullRadius: 0, exponent: 1), 0,
                       "헐 0 은 기여 0(0 나눗셈 금지)")
    }

    // MARK: - 4. 콘 감쇠 (`:139-140`) — W-18 해소분

    /// **W-18 의 본체.** WE 는 `smoothstep(outer, inner, cos)`(3차)다 — 선형 clamp 램프가 아니다.
    /// 선형과 3차는 중간에서 최대 ~0.1 갈리므로 값으로 가른다.
    func testConeFalloffIsCubicSmoothstepNotLinearRamp() {
        let inner = cosf(15 * Float.pi / 180)
        let outer = cosf(30 * Float.pi / 180)
        for i in 0...40 {
            let deg = Float(i)
            let cosAngle = cosf(deg * Float.pi / 180)
            let ported = SceneWEVolumetricMath.coneFalloff(cosAngle: cosAngle, innerCos: inner, outerCos: outer)
            let oracle = Oracle.spotCookie(cosAngle: cosAngle, cosInner: inner, cosOuter: outer)
            XCTAssertEqual(ported, oracle, accuracy: 1e-6, "deg=\(deg)")
        }
        // 문서 §6 이 인용한 각도값.
        func at(_ deg: Float) -> Float {
            SceneWEVolumetricMath.coneFalloff(cosAngle: cosf(deg * Float.pi / 180),
                                              innerCos: inner, outerCos: outer)
        }
        XCTAssertEqual(at(0), 1, accuracy: 1e-6)
        XCTAssertEqual(at(10), 1, accuracy: 1e-6)
        XCTAssertEqual(at(20), 0.8293, accuracy: 1e-3)
        XCTAssertEqual(at(30), 0, accuracy: 1e-6)
        XCTAssertEqual(at(40), 0, accuracy: 1e-6)
        // 선형 램프였다면 20° 에서 t 그대로다 — 3차가 그 위로 밀어 올린다(두 모델이 갈리는 증거).
        let t = (cosf(20 * Float.pi / 180) - outer) / (inner - outer)
        XCTAssertEqual(t, 0.7374, accuracy: 1e-3, "선형 램프값(대조군)")
        XCTAssertGreaterThan(at(20), t + 0.08, "3차 스무드스텝은 중간에서 선형보다 뚜렷이 높다(0.8293 vs 0.7374)")
    }

    /// 콘 계수는 **뷰 레이 각도가 아니라 `normalize(샘플 − 라이트)`** 로 잰다(`:139`).
    /// 화면공간 갓레이(옛 모델)와 볼륨 라이트를 가르는 지점이라 규약만 따로 못박는다.
    func testConeFalloffEdgesAreExactlyZeroAndOne() {
        let inner = cosf(15 * Float.pi / 180)
        let outer = cosf(30 * Float.pi / 180)
        XCTAssertEqual(SceneWEVolumetricMath.coneFalloff(cosAngle: outer, innerCos: inner, outerCos: outer), 0)
        XCTAssertEqual(SceneWEVolumetricMath.coneFalloff(cosAngle: inner, innerCos: inner, outerCos: outer), 1)
        XCTAssertEqual(SceneWEVolumetricMath.coneFalloff(cosAngle: -1, innerCos: inner, outerCos: outer), 0,
                       "라이트 뒤쪽 샘플은 0")
        // 퇴화(inner == outer) — 호출부가 `+1e-4` 로 벌려 도달 0 인 자리지만 규약을 남긴다.
        XCTAssertEqual(SceneWEVolumetricMath.coneFalloff(cosAngle: 1, innerCos: 0.5, outerCos: 0.5), 1)
        XCTAssertEqual(SceneWEVolumetricMath.coneFalloff(cosAngle: 0, innerCos: 0.5, outerCos: 0.5), 0)
    }

    // MARK: - 5. 헐 반경 · POINTLIGHT 스케일 · 구간 분할

    func testHullRadiusAppliesThe099UniformScale() {
        // `0x140198760` f32=0.99 — 셰이더가 받는 `VAR_SPOT_PARAMS_RADIUS`.
        XCTAssertEqual(SceneWEVolumetricMath.hullRadius(radius: 100), 99, accuracy: 1e-4)
        // 동봉 코퍼스의 유일한 볼류메트릭 저작 라이트(collisionmodel/scene.json)의 실제 반경.
        XCTAssertEqual(SceneWEVolumetricMath.hullRadius(radius: 811.69), 803.57312, accuracy: 1e-2)
        // 반경 미저작 → WE 라이트 생성자 기본 1.0(`0x140190494`) × 0.99.
        XCTAssertEqual(SceneWEVolumetricMath.hullRadius(radius: 0), 0.99, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.hullRadius(radius: -5), 0.99, accuracy: 1e-6)
    }

    func testPointLightHalvesMaxLightScale() {
        // `:119` vs `:121`.
        XCTAssertEqual(SceneWEVolumetricMath.pointLightScale(isPoint: true), 0.5)
        XCTAssertEqual(SceneWEVolumetricMath.pointLightScale(isPoint: false), 1)
        let spot = SceneWEVolumetricMath.maxLightScale(intensity: 6, segmentLength: 2,
                                                       hullRadius: 4, isPoint: false)
        let point = SceneWEVolumetricMath.maxLightScale(intensity: 6, segmentLength: 2,
                                                        hullRadius: 4, isPoint: true)
        XCTAssertEqual(spot, 3, accuracy: 1e-6)      // 6 × 2 / 4
        XCTAssertEqual(point, spot * 0.5, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.maxLightScale(intensity: 6, segmentLength: 2,
                                                           hullRadius: 0, isPoint: false), 0)
    }

    /// `:113` — `(N+1)` 분할이라 샘플이 **양 끝점을 절대 밟지 않는다**.
    /// 이게 `N` 분할이었다면 첫 샘플이 헐 표면(감쇠 0)에 앉아 기여가 통째로 사라진다.
    func testSamplePositionsNeverTouchSpanEndpoints() {
        let n = 8
        for k in 0..<n {
            let p = SceneWEVolumetricMath.samplePosition(index: k, count: n)
            XCTAssertEqual(p, Float(k + 1) / Float(n + 1), accuracy: 1e-6)
            XCTAssertGreaterThan(p, 0)
            XCTAssertLessThan(p, 1)
        }
        XCTAssertEqual(SceneWEVolumetricMath.samplePosition(index: 0, count: 8), 1.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.samplePosition(index: 7, count: 8), 8.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.samplePosition(index: 0, count: 0), 0)
    }

    /// `:190` — `VAR_DENSITY` 는 **순수 배수**다. 거리 감쇠 계수가 아니다(옛 이식의 핵심 오류).
    func testDensityIsAPureMultiplierAndZeroDrawsNothing() {
        XCTAssertEqual(SceneWEVolumetricMath.finalScale(density: 0, maxLightScale: 12, meanFactor: 0.5), 0)
        let one = SceneWEVolumetricMath.finalScale(density: 1, maxLightScale: 12, meanFactor: 0.5)
        let three = SceneWEVolumetricMath.finalScale(density: 3, maxLightScale: 12, meanFactor: 0.5)
        XCTAssertEqual(three, one * 3, accuracy: 1e-6)
        XCTAssertEqual(one, 12 * 0.5 * 0.1, accuracy: 1e-6, "하드코딩 스케일 0.1(`:190`)")
    }

    // MARK: - 6. 픽셀 NDC — "광축 위에 앉는 픽셀은 없다"

    func testPixelNDCIsPixelCenterNotOpticalAxis() {
        let c = SceneWEVolumetricMath.pixelNDC(x: 32, y: 32, width: 64, height: 64)
        XCTAssertEqual(c.x, 0.015625, accuracy: 1e-7, "짝수 해상도의 가운데 픽셀은 반 픽셀 비껴 있다")
        XCTAssertEqual(c.y, -0.015625, accuracy: 1e-7)
        // 1×1 로 부르면 정확히 광축 — 두 레이를 한 API 로 나란히 보게 하는 규약.
        let axis = SceneWEVolumetricMath.pixelNDC(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(axis.x, 0, accuracy: 1e-7)
        XCTAssertEqual(axis.y, 0, accuracy: 1e-7)
        // y 는 위가 0 — 위쪽 픽셀이 NDC +y.
        XCTAssertGreaterThan(SceneWEVolumetricMath.pixelNDC(x: 0, y: 0, width: 64, height: 64).y,
                             SceneWEVolumetricMath.pixelNDC(x: 0, y: 63, width: 64, height: 64).y)
        XCTAssertEqual(SceneWEVolumetricMath.pixelNDC(x: 0, y: 0, width: 0, height: 0).x, 0,
                       "퇴화 해상도 방어값")
    }

    // MARK: - 7. 프래그먼트 전체 — 오라클 전수 대조

    /// 이식본 `pixelValue` 와 독립 전사 오라클이 **같은 픽셀에서 같은 값**을 내는지 본다.
    /// 구 교차를 축약형/비축약형으로 각각 풀었으므로, 부호·계수 오류는 여기서 갈린다.
    func testPixelValueMatchesIndependentOracleAcrossGrid() {
        var checked = 0
        for radius in [Float(0), 2, 20, 811.69] {
            for isPointFixture in [false, true] {
                var input = Self.fixture(radius: radius)
                if isPointFixture {
                    // 종 프록시: `outerCos <= -0.999` 가 POINTLIGHT 를 뜻한다(`isPoint`).
                    input.innerCos = 1
                    input.outerCos = -1
                    XCTAssertTrue(input.isPoint)
                } else {
                    XCTAssertFalse(input.isPoint)
                }
                for sampleCount in [2, 3, 5, 8] {
                    input.sampleCount = sampleCount
                    for (x, y) in [(32, 32), (2, 2), (0, 0), (63, 63), (10, 50), (40, 20)] {
                        let ported = SceneWEVolumetricMath.pixelValue(input, x: x, y: y, width: 64, height: 64)
                        let oracle = Self.oracleFixture(input, x: x, y: y, width: 64, height: 64)
                        XCTAssertEqual(ported, oracle, accuracy: max(1e-5, abs(oracle) * 1e-4),
                                       "radius=\(radius) point=\(isPointFixture) N=\(sampleCount) px=(\(x),\(y))")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 192, "대조 케이스 수 — 격자가 줄면 커버가 준다")
    }

    /// 동봉 코퍼스의 **실제 저작값**으로도 두 벌을 맞댄다
    /// (`scenes/particleelementpreviews/collisionmodel/scene.json` 의 `lpoint`:
    ///  `density 7.48` · `volumetricsexponent 4.0` · `radius 811.69` · `intensity 6.44`).
    /// 그 씬은 `castvolumetrics` 가 없어 WE 에서도 이 패스가 안 켜지지만, 값의 크기대(帶)는 실물이다.
    func testPixelValueMatchesOracleForRealCorpusLightValues() {
        var input = SceneWEVolumetricMath.PixelInput(
            eye: SIMD3(281.837, 315.168, 900), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0), fovYDegrees: 50, aspect: 16.0 / 9.0, nearZ: 0.1, farZ: 10000,
            lightPosition: SIMD3(281.837, 315.168, 162), lightForward: SIMD3(0, 0, 1),
            density: 7.48, exponent: 4, intensity: 6.44,
            innerCos: 1, outerCos: -1, radius: 811.69, sampleCount: 8)
        XCTAssertTrue(input.isPoint, "`lpoint` 는 POINTLIGHT 가지다")
        for (x, y) in [(64, 36), (0, 0), (127, 71), (100, 20)] {
            let ported = SceneWEVolumetricMath.pixelValue(input, x: x, y: y, width: 128, height: 72)
            let oracle = Self.oracleFixture(input, x: x, y: y, width: 128, height: 72)
            XCTAssertEqual(ported, oracle, accuracy: max(1e-5, abs(oracle) * 1e-4), "px=(\(x),\(y))")
        }
        // 스팟 가지로도 같은 라이트를 돌려 콘 경로가 오라클과 붙는지 본다.
        input.innerCos = cosf(20 * Float.pi / 180)
        input.outerCos = cosf(30 * Float.pi / 180)   // WE 라이트 생성자 기본 콘(`0x1401904a8`/`0x1401904b2`)
        XCTAssertFalse(input.isPoint)
        for (x, y) in [(64, 36), (30, 30)] {
            let ported = SceneWEVolumetricMath.pixelValue(input, x: x, y: y, width: 128, height: 72)
            let oracle = Self.oracleFixture(input, x: x, y: y, width: 128, height: 72)
            XCTAssertEqual(ported, oracle, accuracy: max(1e-5, abs(oracle) * 1e-4), "spot px=(\(x),\(y))")
        }
    }

    /// macOS 렌더 테스트(`VolumetricLightTests.testVolumetricMathMirrorsShaderForFixturePixel`)가
    /// 단언하는 **바로 그 수들**을 리눅스에서도 못박는다. 종전에는 이 값들이 macOS 에서만
    /// 실행됐고 리눅스는 타입만 봤다 — 그 공백이 이 파일의 존재 이유다.
    func testFixturePixelValuesAreLockedOnLinuxToo() {
        let wired = Self.fixture(radius: 20)
        XCTAssertEqual(SceneWEVolumetricMath.pixelValue(wired, x: 32, y: 32, width: 64, height: 64),
                       0.506209, accuracy: 1e-4, "radius=20 픽스처의 중앙 픽셀")
        XCTAssertEqual(SceneWEVolumetricMath.pixelValue(wired, x: 2, y: 2, width: 64, height: 64),
                       0.047063, accuracy: 1e-4, "radius=20 픽스처의 코너 픽셀")

        let bare = Self.fixture(radius: 0)   // 씬이 `radius` 를 저작하지 않은 경우 → 헐 0.99
        let barePixel = SceneWEVolumetricMath.pixelValue(bare, x: 32, y: 32, width: 64, height: 64)
        XCTAssertEqual(barePixel, 0.225425, accuracy: 1e-4,
                       "radius 무저작 픽스처의 중앙 픽셀 — 실측 Metal 값 57/255=0.2235 와 같은 자리다")
        XCTAssertEqual((min(1, max(0, barePixel)) * 255).rounded(), 57,
                       "bgra8Unorm 양자화 바이트가 캡처 PNG 의 57 과 같아야 한다")

        // 같은 입력을 **광축 레이**(1×1 = ndc 정확히 (0,0))로 풀면 1.0 이다. 이 1.0 과 위 0.2254 의
        // 비가 곧 보고된 "4.5배" 이고, 두 구현이 갈린 것이 아니라 **레이가 갈린 것**이다.
        let onAxis = SceneWEVolumetricMath.pixelValue(bare, x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(onAxis, 1.0, accuracy: 1e-4, "광축 레이 값 — 종전 검산이 보던 수")
        XCTAssertEqual(onAxis / barePixel, 4.436, accuracy: 0.01,
                       "광축/픽셀중심 비 = 보고된 4.5배의 정체(반 픽셀 각도 × 좁은 콘 × 작은 헐)")

        // 오라클도 같은 수를 내야 한다 — 위 상수들이 이식본 자기 자신의 출력이 아니라는 근거.
        XCTAssertEqual(Self.oracleFixture(wired, x: 32, y: 32, width: 64, height: 64),
                       0.506209, accuracy: 1e-4)
        XCTAssertEqual(Self.oracleFixture(bare, x: 32, y: 32, width: 64, height: 64),
                       0.225425, accuracy: 1e-4)
        XCTAssertEqual(Self.oracleFixture(bare, x: 0, y: 0, width: 1, height: 1),
                       1.0, accuracy: 1e-4)
    }

    /// 헐 구간(`hullSpan`) 자체의 성질 — 근평면 클램프와 "교차 없음" 규약.
    func testHullSpanClampsToNearPlaneAndRejectsMisses() {
        let eye = SIMD3<Float>(0, 0, 10)
        let toward = SIMD3<Float>(0, 0, -1)
        // 카메라가 헐 밖(거리 10, 헐 19.8) → 이미 안이라 enter 가 근평면으로 잘린다.
        guard let span = SceneWEVolumetricMath.hullSpan(eye: eye, direction: toward,
                                                        lightPosition: .zero, hullRadius: 19.8,
                                                        nearZ: 0.1, farZ: 10000) else {
            return XCTFail("헐 안에서 시작하는 레이는 구간을 가져야 한다")
        }
        XCTAssertEqual(span.enter, 0.1, accuracy: 1e-5, "헐 안이면 근평면에서 시작(FULLSCREEN 콤보와 같은 뜻)")
        XCTAssertEqual(span.exit, 29.8, accuracy: 1e-4, "출구는 구 반대편")
        // 완전히 빗나간 레이 — `:67`/`:70` 의 clip() 자리.
        XCTAssertNil(SceneWEVolumetricMath.hullSpan(eye: eye, direction: SIMD3(1, 0, 0),
                                                     lightPosition: .zero, hullRadius: 0.99,
                                                     nearZ: 0.1, farZ: 10000))
        // 원평면이 구 앞이면 구간이 없다.
        XCTAssertNil(SceneWEVolumetricMath.hullSpan(eye: eye, direction: toward,
                                                     lightPosition: SIMD3(0, 0, -100),
                                                     hullRadius: 1, nearZ: 0.1, farZ: 5))
    }

    // MARK: - 8. 벡터 헬퍼 (simd 없이 서는 성질)

    func testVectorHelpersMatchTextbookDefinitions() {
        let a = SIMD3<Float>(1, 2, 3)
        let b = SIMD3<Float>(-4, 5, 6)
        XCTAssertEqual(SceneWEVolumetricMath.dot3(a, b), -4 + 10 + 18, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.length3(SIMD3(3, 4, 0)), 5, accuracy: 1e-6)
        let n = SceneWEVolumetricMath.normalize3(SIMD3(0, 0, 7))
        XCTAssertEqual(n.z, 1, accuracy: 1e-6)
        XCTAssertEqual(SceneWEVolumetricMath.length3(n), 1, accuracy: 1e-6)
        // 영벡터는 그대로 — MSL `normalize` 는 NaN 이지만 호출부가 영벡터를 만들 수 없는 자리다.
        XCTAssertEqual(SceneWEVolumetricMath.normalize3(.zero), .zero)
    }

    /// 뷰 레이 재구성 — `aspect` 가 **x 에만** 붙는다(fov 가 세로축이기 때문).
    func testViewRayDirectionAppliesAspectToXOnly() {
        let fwd = SIMD3<Float>(0, 0, -1), right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)
        let axis = SceneWEVolumetricMath.viewRayDirection(ndc: (0, 0), fovYDegrees: 50, aspect: 1.777,
                                                          forward: fwd, right: right, up: up)
        XCTAssertEqual(axis.x, 0, accuracy: 1e-6)
        XCTAssertEqual(axis.y, 0, accuracy: 1e-6)
        XCTAssertEqual(axis.z, -1, accuracy: 1e-6, "광축은 aspect 와 무관하다")
        let wide = SceneWEVolumetricMath.viewRayDirection(ndc: (1, 0), fovYDegrees: 50, aspect: 2,
                                                          forward: fwd, right: right, up: up)
        let narrow = SceneWEVolumetricMath.viewRayDirection(ndc: (1, 0), fovYDegrees: 50, aspect: 1,
                                                            forward: fwd, right: right, up: up)
        XCTAssertGreaterThan(wide.x, narrow.x, "aspect 가 크면 가로 시야가 넓다")
        let vertical = SceneWEVolumetricMath.viewRayDirection(ndc: (0, 1), fovYDegrees: 50, aspect: 2,
                                                              forward: fwd, right: right, up: up)
        let verticalNarrow = SceneWEVolumetricMath.viewRayDirection(ndc: (0, 1), fovYDegrees: 50, aspect: 1,
                                                                    forward: fwd, right: right, up: up)
        XCTAssertEqual(vertical.y, verticalNarrow.y, accuracy: 1e-6, "세로는 aspect 무관")
        XCTAssertEqual(SceneWEVolumetricMath.length3(wide), 1, accuracy: 1e-6, "정규화 보장(hullSpan 의 a=1 축약 전제)")
    }
}
