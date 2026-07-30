import XCTest
import Metal
@testable import WapleRender

/// WE 2.8.42 대조 확정 발산 수정 회귀(Render 측) — MSL 감쇠 HLSL lane·V1 rim 게이트 상수·Hann 미적용.
/// CPU 오라클(ScenePBRLighting) 측은 WapleCoreTests/EngineDefaultFixRegressionTests 가 커버.
final class EngineAttenuationLaneTests: XCTestCase {

    // MARK: - 감쇠 HLSL lane (WE 는 #define HLSL 1 크로스컴파일 — wallpaper64.exe 스트링 @0x485698)

    /// Mesh3DShaders: pow(falloff + 1.17549435e-38, exponent), 반경 컷오프 없음(common_pbr_2.h:265-266).
    func testMesh3DFalloffUsesHLSLLaneNoRadiusCutoff() {
        let s = Mesh3DShaders.source
        XCTAssertTrue(s.contains("pow(falloff + 1.17549435e-38, exponent)"),
                      "WE 2.8.42 HLSL lane — exponent=0 이면 전역 무감쇠가 엔진 동작")
        XCTAssertFalse(s.contains("6.103515625e-5"), "구 GLSL lane epsilon/hard-zero 잔존 금지")
    }

    /// QuadShaders: Mesh3DShaders 사본과 동일 수식(CPU↔GPU 비트 일치 규약의 GPU 측).
    func testQuadFalloffUsesHLSLLaneNoRadiusCutoff() {
        let s = QuadShaders.source
        XCTAssertTrue(s.contains("pow(falloff + 1.17549435e-38, exponent)"))
        XCTAssertFalse(s.contains("6.103515625e-5"), "구 GLSL lane epsilon/hard-zero 잔존 금지")
    }

    /// 두 MSL 사본이 실제로 컴파일되는지(수식 교체 후 MSL 문법 회귀 가드).
    func testAttenuationShaderSourcesCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let meshLib = try device.makeLibrary(source: Mesh3DShaders.source, options: nil)
        XCTAssertNotNil(meshLib)
        let quadLib = try device.makeLibrary(source: QuadShaders.source, options: nil)
        XCTAssertNotNil(quadLib.makeFunction(name: "f_lit"))
    }

    // MARK: - rim 게이트 상수 (V1 lane: common_pbr_2.h:294/305/342/353 — 0.01 은 구경로 common_pbr.h 값)

    func testMesh3DRimGateIsV1Constant() {
        let s = Mesh3DShaders.source
        XCTAssertTrue(s.contains("step(0.001, lightColorRaw.x + lightColorRaw.y + lightColorRaw.z)"),
                      "V1 lane rim 게이트는 0.001")
        XCTAssertFalse(s.contains("step(0.01,"), "구경로 상수 0.01 잔존 금지")
    }

    // MARK: - Hann 미적용 (WE 는 캡처 샘플에 테이퍼를 적용하지 않음 — 디컴파일 FUN_1400d0380:285-308)

    /// DC 입력 에너지는 bin 0 에만: 무윈도우면 mags[0]=2N·나머지 0, Hann 이면 mags[0]=N·bin1 에 ≈N/2 가 샌다.
    /// = SystemAudioSpectrumProvider 가 윈도우 벡터를 만들지(곱하지) 않음을 행동으로 단언.
    /// (2N: vDSP_fft_zrip packed-real 경로의 기저 ×2 스케일 — Hann 시절 DC=1024 에서 2048 로.)
    func testConstantSignalEnergyStaysInDCBin() throws {
        let fftSize = 1024
        let mags = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(
            from: [Float](repeating: 1, count: fftSize), fftSize: fftSize))
        XCTAssertEqual(mags[0], Float(2 * fftSize), accuracy: 1e-1, "무윈도우: DC bin = 2N(비정규화 FFT)")
        for k in [1, 2, 3, 100] {
            XCTAssertLessThan(mags[k], 1.0,
                              "무윈도우: DC 는 인접 bin 으로 새지 않는다(Hann 적용 시 bin1 수백 대)")
        }
    }

    /// 정수 사이클 정현파 피크 진폭 = N(무윈도우; 기저 ×2 포함). Hann(coherent gain 0.5)이면 N/2 로 반토막 —
    /// Hann 제거로 진폭이 약 2배 되는 것은 의도된 방향.
    func testIntegerCycleSinePeakIsFullAmplitude() throws {
        let fftSize = 1024
        let k = 64
        let samples = (0..<fftSize).map {
            Float(sin(2.0 * Double.pi * Double(k) * Double($0) / Double(fftSize)))
        }
        let mags = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(from: samples, fftSize: fftSize))
        XCTAssertEqual(mags[k], Float(fftSize), accuracy: 1e-1,
                       "테이퍼 미적용 시 피크 = N(Hann 이면 N/2)")
    }
}
