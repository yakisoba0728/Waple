import Foundation
import XCTest
@testable import WapleCore

/// spot 콘 각도 규약 — **리포에 산식이 한 벌만 있다**는 것과, 그 한 벌이 WE 와 같다는 것을 못박는다.
///
/// ## 왜 이 파일이 따로 있나
/// 종전엔 같은 변환이 두 벌이었다. `SceneLight3D.forwardSpotConeCosines`(2D 포워드 팩 + 볼류메트릭
/// 호출부)는 `도 × π/180 × 0.5` 를, `Scene3DLighting.spotConeCosines`(3D PBR 레인)는 `도 × π/180`
/// 을 썼다. 즉 **같은 라이트가 포워드에서는 30° 콘, 갓레이에서는 15° 콘**이었다. 한 벌만 고치면
/// 다시 갈리므로 구현을 하나로 접었고(3D 쪽이 2D 쪽으로 위임), 이 파일이 그 규약을 잠근다.
///
/// ## 확정 근거 (2026-08-21 재확인, 남의 주석을 베끼지 않고 직접 떴다)
/// **① 셰이더가 코사인 슬롯의 의미를 먼저 정한다.** `shaders/genericimage3.frag` 스팟 루프:
/// `vec3 lightDelta = g_LSpot_Origin[l].xyz - worldPos;`
/// `float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[l].xyz);`
/// `spotCookie = smoothstep(g_LSpot_Direction[l].w, g_LSpot_Origin[l].w, spotCookie);`
/// `lightDelta` 가 표면→라이트라 부호를 뒤집은 쪽이 라이트→표면이고, 그 내적은 **광축에서 잰
/// 각의 코사인**이다. 그러므로 두 `.w` 는 반각 코사인 슬롯이다. `shaders/volumetricsfront.frag`
/// 도 같다 — `dot(normalize(lightDelta), VAR_SPOT_FORWARD)` 뒤
/// `smoothstep(VAR_SPOT_PARAMS_OUTER, VAR_SPOT_PARAMS_INNER, spotCookie)`.
///
/// **② C++ 이 그 슬롯에 무엇을 굽는가 — `cos(도 × π/180)`, `× 0.5` 없음.**
/// - V1 PBR 패커(`.pdata` 범위 `0x140190c80`–`0x1401964b8`):
///   `0x140192e64 movss xmm0, [r14+0x2f0]`(innercone) → `0x140192e6d mulss xmm0, xmm7`
///   → `0x140192e71 call 0x14041a2e0` → `0x140192e86 movss [rdi+rax*4], xmm0`
///   (`rax = rbx+3` = vec4 `.w` = `g_LSpot_Origin[i].w`).
///   outercone 은 `0x140192eaa`/`0x140192eb3`/`0x140192eb7` → `0x140192ebf`(`g_LSpot_Direction[i].w`).
/// - 볼류메트릭 패커(`0x140196ce0`–`0x1401988d7`): `0x140198724`/`0x14019872c`/`0x140198730`
///   → `0x140198770`(상수블록 `+0xbc` = `VAR_SPOT_PARAMS_INNER`), 그리고 `0x140198738`/
///   `0x140198740`/`0x140198744` → `0x140198778`(`+0xc0` = `..._OUTER`).
/// - 승수는 `0x140492628` f32 = `0.01745329238474369` = π/180 이다. V1 쪽 `xmm7` 은 라이트 루프
///   안에서 여러 번 재정의되므로 **도달정의를 계산해서** 확인했다 — 루프 진입 전 `0x1401910bf`
///   적재와 루프 꼬리 `0x14019317c` 재적재가 두 `mulss` 를 모두 지배한다. 볼류메트릭 쪽은
///   `0x1401986ac` 적재가 같은 직선 블록 안이다.
/// - `0x14041a2e0` = `cosf`: 소인수 경로가 `1.0 − x²·0.5 + …`(상수 `0x140471bb0`=1.0,
///   `0x140471bc0`=0.5)로 **짝함수**이고 극소 |x| 에서 `x` 가 아니라 `1.0`(`0x140471cb8`)을 낸다.
///
/// ## 기대값을 어떻게 정했나
/// 산식을 다시 적어 만든 기대값(`cos(도 × 배율)`)은 배율이 회귀해도 같이 움직여 **아무것도 잠그지
/// 못한다**. 그래서 여기서는 두 종류만 쓴다.
/// 1. 각도만으로 정해지는 코사인(0°→1, 60°→½, 90°→0, 120°→−½, 180°→−1).
/// 2. **거동** — "저작 콘 20°/30° 라이트는 광축에서 25° 비낀 표면을 부분 조명한다".
///    종전 `× 0.5` 해석이면 컷오프가 15° 라 그 자리가 **정확히 0**(완전 암부)이다.
final class SceneSpotConeTests: XCTestCase {
    private let tol: Float = 1e-6

    // MARK: 각도 스케일 — π/180 이지 π/360 이 아니다

    /// 저작 도(度)가 그대로 코사인 인자다. 다섯 자리 모두 **각도만으로 정해지는 값**이라
    /// 배율이 절반이 되면 (0° 를 뺀) 네 자리가 전부 갈린다.
    func testDegreeScaleIsPiOver180() {
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 0), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 60), 0.5, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 90), 0, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 120), -0.5, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 180), -1, accuracy: tol)
    }

    /// `outercone > 90` 을 클램프하지 않는다 — WE 도 그냥 `cosf` 를 취해 콘이 반구를 넘는다.
    /// 코사인이 **음수**로 내려가는 것이 그 신호다.
    func testWideConeIsNotClampedAtNinetyDegrees() {
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 90, outer: 120)
        XCTAssertEqual(cone.inner, 0, accuracy: tol)     // cos 90°
        XCTAssertEqual(cone.outer, -0.5, accuracy: tol)  // cos 120°
        XCTAssertLessThan(cone.outer, 0, "반구를 넘는 콘이 클램프되면 안 된다")
    }

    // MARK: 단일 정본 — 두 갈래가 실제로 접혔는가

    /// 콘 변환기가 `SceneWELightMath.coneCosine` **하나**를 쓴다. 어느 한쪽에 배율이 다시 끼면
    /// 여기서 잡힌다(양쪽에 같은 배율이 끼는 것은 위 `testDegreeScaleIsPiOver180` 이 잡는다).
    func testConverterDelegatesToSingleConeCosine() {
        for (inner, outer) in [(Float(20), Float(30)), (10.63, 14.28), (5, 89), (44.830605, 67.129997)] {
            let cone = SceneLight3D.forwardSpotConeCosines(inner: inner, outer: outer)
            XCTAssertEqual(cone.inner, SceneWELightMath.coneCosine(degrees: inner), accuracy: tol,
                           "inner=\(inner)")
            XCTAssertEqual(cone.outer, SceneWELightMath.coneCosine(degrees: outer), accuracy: tol,
                           "outer=\(outer)")
        }
    }

    /// 2D 포워드 팩(`forwardUniforms`)이 싣는 두 슬롯이 변환기 출력과 같은 자리에 같은 값으로 간다.
    /// `axisCone.w` = outer, `kindCone.y` = inner — 셰이더 `smoothstep(edge0=outer, edge1=inner, ·)`
    /// 과 짝이 맞아야 하므로 **outer < inner** 도 함께 본다.
    func testForwardPackCarriesTheSameCosinesInShaderOrder() {
        let spot = SceneLight3D(id: 7, name: "s", type: "lspot",
                                origin: Vec3(x: 0, y: 0, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
                                color: Vec3(x: 1, y: 1, z: 1), radius: 100, intensity: 1,
                                exponent: 2, innerCone: 20, outerCone: 30,
                                castShadow: false, parent: nil)
        let u = SceneLight3D.forwardUniforms([spot], ambient: Vec3(x: 0, y: 0, z: 0),
                                             skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.kindCone[0].y, 0.9396926, accuracy: tol)   // cos 20°
        XCTAssertEqual(u.axisCone[0].w, 0.8660254, accuracy: tol)   // cos 30° = √3/2
        XCTAssertLessThan(u.axisCone[0].w, u.kindCone[0].y,
                          "edge0(outer) 가 edge1(inner) 보다 작아야 smoothstep 이 0→1 로 증가한다")
    }

    // MARK: 거동 — half 해석과 full 해석이 실제로 갈리는 자리

    /// **이 테스트가 half/full 을 실제로 가른다.** WE 라이트 기본 콘(20°/30°, 생성자 상수)에서
    /// 광축 25° 는 inner 와 outer 사이라 **부분 조명**이어야 한다. 종전 `× 0.5` 해석은 콘을
    /// 10°/15° 로 좁혀 같은 자리를 완전 암부(정확히 0)로 만든다.
    func testAuthoredTwentyThirtyConeLitAtTwentyFiveDegreesOffAxis() {
        let cone = SceneLight3D.forwardSpotConeCosines(
            inner: SceneLight3D.WEDefaults.innerConeDegrees,
            outer: SceneLight3D.WEDefaults.outerConeDegrees)
        let cosAt25 = SceneWELightMath.coneCosine(degrees: 25)
        let lit = SceneWELightMath.spotCone(cosAngle: cosAt25, cosInner: cone.inner, cosOuter: cone.outer)
        XCTAssertGreaterThan(lit, 0.05, "25° 는 콘 안(20°~30° 사이)이라 꺼져 있으면 안 된다")
        XCTAssertLessThan(lit, 0.95, "25° 는 inner 를 넘었으니 완전 포화도 아니다")

        // 경계 두 점은 정확히 0 / 1 이다(smoothstep 정의).
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: cone.outer,
                                                 cosInner: cone.inner, cosOuter: cone.outer), 0, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: cone.inner,
                                                 cosInner: cone.inner, cosOuter: cone.outer), 1, accuracy: tol)

        // 종전 `× 0.5` 레인의 재현 — 같은 25° 가 컷오프(15°) 밖이라 정확히 0 이다.
        let halved = (inner: SceneWELightMath.coneCosine(degrees: 10),
                      outer: SceneWELightMath.coneCosine(degrees: 15))
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: cosAt25,
                                                 cosInner: halved.inner, cosOuter: halved.outer), 0, accuracy: tol,
                       "이 값이 0 이 아니면 대조군 자체가 틀린 것이다")
    }

    /// 코퍼스에 실제로 있는 다른 한 쌍(`spec/corpus/scene-schema.json`: innercone 5건/2씬,
    /// 범위 `[10.63, 20.0]` · outercone `[14.28, 30.0]` — 즉 저작값은 {10.63, 20.0}/{14.28, 30.0}).
    /// 좁은 쪽 쌍에서도 두 해석이 갈리는지 본다: 12° 는 10.63°~14.28° 사이라 켜져 있어야 하고,
    /// 절반 해석(5.315°/7.14°)에서는 꺼진다.
    func testNarrowCorpusConePairAlsoSeparatesTheTwoReadings() {
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 10.63, outer: 14.28)
        let cosAt12 = SceneWELightMath.coneCosine(degrees: 12)
        XCTAssertGreaterThan(
            SceneWELightMath.spotCone(cosAngle: cosAt12, cosInner: cone.inner, cosOuter: cone.outer), 0,
            "12° 는 저작 콘 안이다")
        let halved = (inner: SceneWELightMath.coneCosine(degrees: 5.315),
                      outer: SceneWELightMath.coneCosine(degrees: 7.14))
        XCTAssertEqual(
            SceneWELightMath.spotCone(cosAngle: cosAt12, cosInner: halved.inner, cosOuter: halved.outer),
            0, accuracy: tol)
    }

    // MARK: 퇴화 규약

    /// 콘 미저작(`outercone` 부재 → 파스 기본 0)은 `(1, −1)` — 소비처가 반구 그라디언트로 접는
    /// **신호값**이지 "전방향 통과" 가 아니다. 볼류메트릭의 `isPointLight` 프록시도 이 값을 본다.
    func testMissingConeSignalsHemisphereFallback() {
        for outer in [Float(0), -1, .nan, .infinity] {
            let cone = SceneLight3D.forwardSpotConeCosines(inner: 20, outer: outer)
            XCTAssertEqual(cone.inner, 1, accuracy: tol, "outer=\(outer)")
            XCTAssertEqual(cone.outer, -1, accuracy: tol, "outer=\(outer)")
        }
        // 볼류메트릭 종 프록시가 이 신호를 POINTLIGHT 로 읽는다(같은 규약 한 벌인지 확인).
        let degenerate = SceneLight3D.forwardSpotConeCosines(inner: 0, outer: 0)
        XCTAssertTrue(degenerate.outer <= -0.999)
    }

    /// `inner ≥ outer`(저작 실수) 여도 smoothstep 이 미정의가 되지 않게 **1e-4 만** 벌린다.
    /// WE 자신은 벌리지 않으므로, 이 엡실론이 정상 저작값을 건드리지 않는다는 것도 함께 본다.
    func testInnerIsSeparatedFromOuterOnlyWhenAuthoringInverts() {
        let inverted = SceneLight3D.forwardSpotConeCosines(inner: 40, outer: 30)
        XCTAssertEqual(inverted.outer, 0.8660254, accuracy: tol)          // outer 는 손대지 않는다
        XCTAssertEqual(inverted.inner, inverted.outer + 1e-4, accuracy: 1e-7)
        XCTAssertGreaterThan(inverted.inner, inverted.outer)

        // 정상 저작(20/30)은 엡실론이 붙지 않은 순수 cos 다.
        let normal = SceneLight3D.forwardSpotConeCosines(inner: 20, outer: 30)
        XCTAssertEqual(normal.inner, 0.9396926, accuracy: tol)
    }

    // MARK: 파스 → 팩 전 구간

    /// scene.json 의 `innercone`/`outercone` 이 팩까지 **저작값 그대로의 각도**로 살아 간다.
    /// 파스가 각도를 만지기 시작하면(예: 반각 변환을 파스로 옮기면) 여기서 잡힌다.
    func testAuthoredDegreesSurviveParseIntoPack() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"light":"lspot","origin":"0 0 250","angles":"0 0 0",
                     "color":"1 1 1","intensity":1,"radius":100,
                     "innercone":60,"outercone":90}]}
        """
        let pkg = ScenePackage.assemble([("scene.json", Data(scene.utf8))])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.innerCone, 60, accuracy: tol)
        XCTAssertEqual(light.outerCone, 90, accuracy: tol)
        let u = SceneLight3D.forwardUniforms(doc.lights3D, ambient: Vec3(x: 0, y: 0, z: 0),
                                             skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.kindCone[0].y, 0.5, accuracy: tol)   // cos 60°
        XCTAssertEqual(u.axisCone[0].w, 0, accuracy: tol)     // cos 90°
    }

    /// 볼류메트릭 레인의 콘 소비(`SceneWEVolumetricMath.coneFalloff`)와 메시 레인
    /// (`SceneWELightMath.spotCone`)이 **같은 콘에 대해 같은 값**을 낸다. 두 레인이 같은
    /// 변환기 출력을 받는 것이 이번 통합의 요점이라, 소비 쪽도 함께 못박는다.
    /// (퇴화 규약만 서로 다르다 — `span ≤ 0` 처리. 그래서 정상 콘 구간에서만 대조한다.)
    func testVolumetricAndMeshLanesAgreeOnTheSameCone() {
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 20, outer: 30)
        for degrees in stride(from: Float(0), through: 40, by: 2.5) {
            let cosAngle = SceneWELightMath.coneCosine(degrees: degrees)
            let mesh = SceneWELightMath.spotCone(cosAngle: cosAngle,
                                                 cosInner: cone.inner, cosOuter: cone.outer)
            let volumetric = SceneWEVolumetricMath.coneFalloff(cosAngle: cosAngle,
                                                               innerCos: cone.inner, outerCos: cone.outer)
            XCTAssertEqual(mesh, volumetric, accuracy: 1e-6, "\(degrees)°")
        }
    }
}
