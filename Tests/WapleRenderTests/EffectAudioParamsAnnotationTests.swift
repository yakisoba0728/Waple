import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// `SceneRenderer.audioParams(for:shaderSource:)` — 오디오 선언 기본값의 **출처**를 잠근다.
///
/// 종전에는 이 함수가 `[0.5,1.0]`/`[0.0,1.2]`(`audioBoundsAnnotationDefault`)와 `?? 0`/`?? 1`
/// 넷을 리터럴로 들고 있었다. 지금은 셰이더 원문이 있으면
/// `AudioResponse.declaredDefaults(effectName:shaderSource:)` 가 실제 어노테이션을 읽고,
/// 없을 때만 이름표(`pulse`/`shake`) 표로 떨어진다.
///
/// **우선순위: 씬 상수(`constantshadervalues`) > 셰이더 어노테이션 > 이름표.**
///
/// ⚠️ **이 파일은 리눅스에서 실행되지 않는다**(`WapleRenderTests` 는 타입체크만 된다 —
/// `docs/dev/re-methodology.md` §4.1/§4.3). 값 판정은 macOS CI 가 한다. 그래서 파스 규약 자체는
/// `Tests/WapleCoreTests/AudioResponseTests` 와 `AudioAnnotationCorpusTests` 가 리눅스에서
/// 따로 들고, 여기서는 **배선**(어느 값이 어느 우선순위로 흘러 들어오는가)만 본다.
final class EffectAudioParamsAnnotationTests: XCTestCase {

    /// 워크샵 셰이더를 흉내 낸 원문 — 다섯 값이 스톡(`pulse`/`shake`) 어느 쪽과도 다르다.
    /// 이름은 `pulse` 로 두어서, **이름표를 썼다면 통과할 수 없게** 만든다.
    private static let exoticSource = """
    #if AUDIOPROCESSING
    uniform float g_AudioFrequencyMin; // {"material":"frequencymin","default":3,"int":true,"range":[0,15]}
    uniform float g_AudioFrequencyMax; // {"material":"frequencymax","default":9,"int":true,"range":[0,15]}
    uniform float g_AudioPower; // {"material":"audioexponent","default":2.5,"range":[0,4]}
    uniform vec2 g_AudioBounds; // {"material":"audiobounds","default":"0.25 0.75"}
    uniform float g_AudioMultiply; // {"material":"audioamount","default":1.75,"range":[0,2]}
    #endif
    """

    private func effect(_ name: String, mode: Int, constants: [String: [Float]] = [:]) -> SceneEffect {
        SceneEffect(name: name, constants: constants, textureNames: [nil],
                    combos: ["AUDIOPROCESSING": mode], file: "effects/\(name)/effect.json")
    }

    // MARK: 게이트

    /// `AUDIOPROCESSING` 이 0 이거나 범위 밖이면 nil — 종전과 같다.
    func testModeGateIsUnchanged() {
        let r = SceneRenderer()
        XCTAssertNil(r.audioParams(for: effect("pulse", mode: 0)))
        XCTAssertNil(r.audioParams(for: effect("pulse", mode: 4)))
        XCTAssertNotNil(r.audioParams(for: effect("pulse", mode: 1)))
        XCTAssertNotNil(r.audioParams(for: effect("pulse", mode: 3)))
    }

    // MARK: 이름표 폴백 — 원문이 없을 때(= 종전 동작)

    /// 원문이 없으면 `pulse`/`shake` 표로 떨어진다. 이 값들이 종전 리터럴과 **같아야** 한다
    /// (그래야 이 변경이 무회귀다).
    func testNameFallbackReproducesTheOldLiterals() {
        let r = SceneRenderer()
        let pulse = r.audioParams(for: effect("pulse", mode: 3))
        XCTAssertEqual(pulse?.bounds, SIMD2<Float>(0.5, 1.0))   // 종전 audioBoundsAnnotationDefault 기본가지
        let shake = r.audioParams(for: effect("shake", mode: 3))
        XCTAssertEqual(shake?.bounds, SIMD2<Float>(0.0, 1.2))   // 종전 "shake" 가지
        // 나머지 넷의 종전 리터럴: freqMin 0 · freqMax 1 · power 1 · multiply 1.
        for p in [pulse, shake] {
            XCTAssertEqual(p?.freqMin, 0)
            XCTAssertEqual(p?.freqMax, 1)
            XCTAssertEqual(p?.power, 1)
            XCTAssertEqual(p?.multiply, 1)
        }
        // 표에 없는 이름도 pulse 쪽으로 떨어진다(종전 `default:` 가지와 같다).
        XCTAssertEqual(r.audioParams(for: effect("workshoppy", mode: 3))?.bounds, SIMD2<Float>(0.5, 1.0))
    }

    // MARK: 어노테이션이 이름표를 이긴다

    /// 원문이 있으면 **다섯 값 전부**가 어노테이션에서 온다. 이름은 `pulse` 지만 어느 값도
    /// `pulseDefaults` 와 같지 않으므로, 이름표를 쓰는 구현은 이 테스트를 통과할 수 없다.
    func testAnnotationBeatsTheNameTableForAllFiveValues() {
        let r = SceneRenderer()
        let p = r.audioParams(for: effect("pulse", mode: 3), shaderSource: Self.exoticSource)
        XCTAssertEqual(p?.freqMin, 3)
        XCTAssertEqual(p?.freqMax, 9)
        XCTAssertEqual(p?.power, 2.5)
        XCTAssertEqual(p?.bounds, SIMD2<Float>(0.25, 0.75))
        XCTAssertEqual(p?.multiply, 1.75)
    }

    /// 오디오 어노테이션이 **하나도 없는** 원문은 이름표로 떨어진다(파서가 nil 을 준다).
    func testSourceWithoutAudioAnnotationsFallsBackToTheNameTable() {
        let r = SceneRenderer()
        let plain = """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec2 g_Something; // {"material":"bounds","default":"0 1"}
        """
        XCTAssertEqual(r.audioParams(for: effect("shake", mode: 3), shaderSource: plain)?.bounds,
                       SIMD2<Float>(0.0, 1.2))
    }

    // MARK: 씬 상수가 최우선

    /// `constantshadervalues` 가 있으면 어노테이션을 덮는다 — 종전 우선순위 그대로다.
    func testSceneConstantsStillWinOverTheAnnotation() {
        let r = SceneRenderer()
        let eff = effect("pulse", mode: 3, constants: [
            "audiobounds": [0.1, 0.9], "frequencymin": [5], "frequencymax": [6],
            "audioexponent": [0.5], "audioamount": [0.25],
        ])
        let p = r.audioParams(for: eff, shaderSource: Self.exoticSource)
        XCTAssertEqual(p?.bounds, SIMD2<Float>(0.1, 0.9))
        XCTAssertEqual(p?.freqMin, 5)
        XCTAssertEqual(p?.freqMax, 6)
        XCTAssertEqual(p?.power, 0.5)
        XCTAssertEqual(p?.multiply, 0.25)
    }

    /// **성분별 폴백**: 씬이 `audiobounds` 를 1성분만 적으면 y 는 그 셰이더의 선언값으로 채운다.
    /// 종전에는 그 자리가 리터럴 1.0 이라 `shake` 에서 1.2 대신 1.0 이 됐다.
    /// 도달은 0 이다(동봉 1,698 · 설치본 2,143 JSON 전수에서 `audiobounds` 저작 0건) — 규약만 잠근다.
    func testSingleComponentBoundsFillsTheMissingComponentFromTheDeclaration() {
        let r = SceneRenderer()
        let eff = effect("shake", mode: 3, constants: ["audiobounds": [0.1]])
        XCTAssertEqual(r.audioParams(for: eff)?.bounds, SIMD2<Float>(0.1, 1.2))
        let eff2 = effect("pulse", mode: 3, constants: ["audiobounds": [0.1]])
        XCTAssertEqual(r.audioParams(for: eff2, shaderSource: Self.exoticSource)?.bounds,
                       SIMD2<Float>(0.1, 0.75))
    }
}
