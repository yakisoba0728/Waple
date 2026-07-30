import XCTest
@testable import WapleCore

/// WE 2.8.42 대조 확정 발산 수정 회귀 — 라이트 감쇠 HLSL lane(CPU 오라클) + 파티클 디폴트 3종.
/// 근거: WE 는 #define HLSL 1 로 크로스컴파일(wallpaper64.exe 스트링 @0x485698)되므로 실행 수식은
/// HLSL lane `pow(falloff + 1.17549435e-38, exponent)`(common_pbr_2.h:265-266); 파티클 디폴트는
/// wallpaper64.exe 스트링 테이블.
final class EngineDefaultFixRegressionTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
    }

    // MARK: - 감쇠 HLSL lane (ScenePBRLighting CPU 오라클 — GPU MSL 2곳과 동일 수식 규약)

    /// exponent=0 라이트는 반경 밖에서도 감쇠 1.0(전역 무감쇠) — pow(x, 0) == 1.
    /// 구 GLSL lane 의 반경 밖 hard zero 는 오이식(최대 발산 지점).
    func testZeroExponentIsGlobalUnattenuatedBeyondRadius() {
        let inside = SceneLight3D.finiteLightFalloff(distance: 5, radius: 10, exponent: 0)
        let atEdge = SceneLight3D.finiteLightFalloff(distance: 10, radius: 10, exponent: 0)
        let outside = SceneLight3D.finiteLightFalloff(distance: 15, radius: 10, exponent: 0)
        XCTAssertEqual(inside, 1, accuracy: 1e-6)
        XCTAssertEqual(atEdge, 1, accuracy: 1e-6)
        XCTAssertEqual(outside, 1, accuracy: 1e-6, "exponent=0 은 반경 무관 1.0 이 엔진 동작")
    }

    /// exponent>0 은 반경 밖에서 hard zero 가 아니라 pow(FLT_MIN, exponent) 로 이어진다.
    func testPositiveExponentHasNoHardZeroBeyondRadius() {
        let fltMin: Float = 1.17549435e-38
        // exponent=1: falloff 가 0 으로 포화돼도 결과는 FLT_MIN(작은 양수) — hard zero 금지.
        let beyond = SceneLight3D.finiteLightFalloff(distance: 15, radius: 10, exponent: 1)
        XCTAssertGreaterThan(beyond, 0, "hard zero 금지 — pow(falloff + 1.17549435e-38, exponent)")
        XCTAssertEqual(beyond, fltMin, accuracy: fltMin * 1e-6)
        // exponent=0.5: sqrt(FLT_MIN) ≈ 1.0842e-19 — Float 언더플로 없는 작은 양수로 연속.
        let beyondHalf = SceneLight3D.finiteLightFalloff(distance: 15, radius: 10, exponent: 0.5)
        XCTAssertGreaterThan(beyondHalf, 0)
        XCTAssertEqual(beyondHalf, powf(fltMin, 0.5), accuracy: powf(fltMin, 0.5) * 1e-5)
        // 반경 내는 종전과 동일한 saturate(1-d/r) 곡선(FLT_MIN 은 Float 정밀도 아래라 무영향).
        let within = SceneLight3D.finiteLightFalloff(distance: 5, radius: 10, exponent: 2)
        XCTAssertEqual(within, powf(0.5 + fltMin, 2), accuracy: 1e-6)
    }

    // MARK: - 파티클 디폴트 3종 (키 부재 시 파싱 결과)

    /// sphererandom directions 부재 기본 (1,1,0) — wallpaper64.exe 스트링 "1 1 0" @0x48e288
    /// ("directions" 키 @0x48e290 에 바로 인접).
    func testSphereEmitterDirectionsDefaultIsXYPlane() throws {
        let def = ParticleSystemDef.parse(
            json(#"{"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil)
        guard case let .sphere(_, directions, _, _, _, _, _) = def.emitters.first else {
            return XCTFail("sphere emitter 파스 실패")
        }
        XCTAssertEqual(directions.x, 1, accuracy: 1e-6)
        XCTAssertEqual(directions.y, 1, accuracy: 1e-6)
        XCTAssertEqual(directions.z, 0, accuracy: 1e-6, "엔진 디폴트는 XY 평면 방출(1,1,0)")
    }

    /// rotationrandom max 부재 기본 (0,0,2π) — wallpaper64.exe 스트링 "0 0 6.28318530717" @0x48e498
    /// (키 귀속은 인접 추정).
    func testRotationRandomDefaultMaxIsFullTurnZ() throws {
        let def = ParticleSystemDef.parse(
            json(#"{"emitter":[{"name":"boxrandom","rate":1}],"initializer":[{"name":"rotationrandom"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil)
        guard case let .rotationRandom(min, max, _) = def.initializers.first else {
            return XCTFail("rotationRandom 이니셜라이저 파스 실패")
        }
        XCTAssertEqual(min.x, 0, accuracy: 1e-6)
        XCTAssertEqual(min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(max.x, 0, accuracy: 1e-6)
        XCTAssertEqual(max.y, 0, accuracy: 1e-6)
        XCTAssertEqual(max.z, 6.28318530717, accuracy: 1e-5, "z 회전만 풀턴(2π) 랜덤이 엔진 디폴트")
    }

    /// audioprocessingbounds 부재 기본 [0.8,1.0] — wallpaper64.exe 스트링 "0.8 1.0" @0x48e1b8
    /// (audioprocessing* 스트링 클러스터 내; 키 귀속은 인접 추정).
    func testAudioProcessingBoundsDefault() throws {
        let def = ParticleSystemDef.parse(
            json(#"{"emitter":[{"name":"sphererandom","rate":1,"audioprocessingmode":3}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil)
        let audio = try XCTUnwrap(def.emitterAudio.first ?? nil)
        XCTAssertEqual(audio.bounds.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(audio.bounds.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(audio.freqStart, 0)   // 기존 디폴트 무회귀
        XCTAssertEqual(audio.freqEnd, 15)
        XCTAssertEqual(audio.exponent, 1)
    }
}
