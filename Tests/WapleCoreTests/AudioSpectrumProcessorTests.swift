import XCTest
@testable import WapleCore

/// X-⑩: WE 소비단 오디오 스테이지. 원본 `0x140111085` 실측 규약을 고정한다.
///
/// 이 단계를 통째로 빼먹어서 우리 스펙트럼은 레벨이 3.5~5배 모자랐다. 프로듀서의 절대 게인
/// (162.56)을 소수점까지 유도해 놓고 정작 그 뒤를 안 붙인 것이다.
final class AudioSpectrumProcessorTests: XCTestCase {

    private func raw(_ f: (Int) -> Float) -> [Float] { (0..<128).map(f) }

    // MARK: 축약 — 평균이 아니라 MAX

    /// 64 → 32 → 16 은 인접 2개씩 `maxss` 두 번. 64→16 은 곧 4개 중 최댓값이다.
    /// 평균이었다면 4밴드 중 하나만 뜬 경우 1/4 로 줄었을 것이다 — 그 차이가 이 테스트의 전부다.
    func testReductionTakesMaximumNotMean() {
        var stereo = [Float](repeating: 0, count: 128)
        stereo[5] = 1.0          // Left 밴드 5 → 16빈 인덱스 1(밴드 4..7)
        let out = AudioSpectrumProcessor.reduce(stereo)
        XCTAssertEqual(out.spec16[1], 1.0, accuracy: 1e-6, "MAX 라면 그대로 1.0")
        XCTAssertEqual(out.spec32[2], 1.0, accuracy: 1e-6, "32빈에서도 MAX")
        // 평균이었다면 16빈은 0.25, 32빈은 0.5 였다.
        XCTAssertNotEqual(out.spec16[1], 0.25, accuracy: 1e-6)
        XCTAssertNotEqual(out.spec32[2], 0.5, accuracy: 1e-6)
    }

    /// 세 버퍼는 [Left | Right | Mono] 3분면이고 크기가 다르다(192 / 96 / 48).
    /// mono 는 `0.5·(L+R)` 이며 셰이더 유니폼으로는 노출되지 않는다.
    func testBufferLayoutAndMonoQuadrant() {
        var stereo = [Float](repeating: 0, count: 128)
        for i in 0..<64 { stereo[i] = 1.0 }        // Left 만 1
        let out = AudioSpectrumProcessor.reduce(stereo)
        XCTAssertEqual(out.spec64.count, 192)
        XCTAssertEqual(out.spec32.count, 96)
        XCTAssertEqual(out.spec16.count, 48)
        XCTAssertEqual(out.left64, [Float](repeating: 1, count: 64))
        XCTAssertEqual(out.right64, [Float](repeating: 0, count: 64))
        for i in 0..<64 {
            XCTAssertEqual(out.spec64[128 + i], 0.5, accuracy: 1e-6, "mono = 0.5·(1 + 0)")
        }
        XCTAssertEqual(out.left16.count, 16)
        XCTAssertEqual(out.right16.count, 16)
    }

    // MARK: 그룹 정규화

    /// 그룹은 128 float 을 **연속 8개씩** 16개로 나눈다 — 그룹 0..7 이 Left, 8..15 가 Right 다.
    /// 정규화가 그룹 단위라, 한 그룹 안에서만 상대 크기가 보존되고 그룹 간 절대 레벨은 눌린다.
    func testGroupPeakNormalizationIsPerEightBands() {
        var p = AudioSpectrumProcessor()
        // 그룹 0 은 최대 1.0, 그룹 1 은 최대 0.5 — 정규화 후 둘 다 자기 그룹 안에서 1.0 이 돼야 한다.
        // (0.5 는 0.333·globalPeak(=0.333) 보다 커서 비율 하한에 걸리지 않는다.)
        var input = [Float](repeating: 0, count: 128)
        input[0] = 1.0
        input[8] = 0.5
        // dt 를 크게 줘서 1-pole·슬루가 한 프레임에 수렴하게 한다(alpha=1, slew=1).
        let out = p.process(raw: input, dt: 1.0)
        XCTAssertEqual(out.spec64[0], 1.0, accuracy: 1e-5, "그룹 0 의 피크는 자기 그룹으로 정규화")
        XCTAssertEqual(out.spec64[8], 1.0, accuracy: 1e-5, "그룹 1 도 자기 그룹 피크로 정규화")
    }

    /// 비율 하한 `0.333·globalPeak` — 조용한 그룹이 통째로 증폭돼 노이즈가 만개하는 것을 막는다.
    func testQuietGroupIsFlooredByGlobalPeakRatio() {
        var p = AudioSpectrumProcessor()
        var input = [Float](repeating: 0, count: 128)
        input[0] = 1.0        // 그룹 0
        input[8] = 0.01       // 그룹 1 — 0.333·1.0 보다 훨씬 작다
        let out = p.process(raw: input, dt: 1.0)
        XCTAssertEqual(out.spec64[0], 1.0, accuracy: 1e-5)
        // 하한이 0.333 이므로 0.01/0.333 = 0.03 — 1.0 으로 부풀지 않는다.
        XCTAssertEqual(out.spec64[8], 0.01 / AudioSpectrumProcessor.groupPeakFloorRatio, accuracy: 1e-4)
        XCTAssertLessThan(out.spec64[8], 0.05, "하한이 없었다면 1.0 이 됐을 것")
    }

    /// 무음은 **출력만** 0 이고 상태는 유지된다 — 원본이 그렇다(`0x140112646` 이 출력 버퍼만
    /// memset 하고 `state`/`prev` 는 별도 버퍼라 안 만진다). 소리가 돌아오면 처음부터가 아니라
    /// 끊긴 자리에서 이어 올라간다. 상태까지 지우면 무음이 낄 때마다 어택이 재시작돼 굼떠진다.
    func testSilenceZeroesOutputButKeepsState() {
        var p = AudioSpectrumProcessor()
        let loud = raw { _ in 1.0 }
        let dt: Float = 1.0 / 60
        for _ in 0..<200 { _ = p.process(raw: loud, dt: dt) }   // 1.0 으로 수렴시켜 두고

        let silent = p.process(raw: [Float](repeating: 0, count: 128), dt: dt)
        XCTAssertTrue(silent.spec64.allSatisfy { $0 == 0 }, "무음 → 출력 전건 0")
        XCTAssertTrue(silent.spec16.allSatisfy { $0 == 0 })

        // 소리가 돌아오면 **한 프레임 만에** 거의 원래 값으로 돌아온다(상태가 남아 있으므로).
        let resumed = p.process(raw: loud, dt: dt)
        XCTAssertGreaterThan(resumed.spec64[0], 0.9,
                             "상태를 지웠다면 alpha 만큼(≈0.33)에서 다시 시작했을 것")
    }

    /// 임계(1e-4) 바로 아래는 무음 처리다.
    func testBelowSilenceThresholdIsTreatedAsSilent() {
        var p = AudioSpectrumProcessor()
        var input = [Float](repeating: 0, count: 128)
        input[0] = AudioSpectrumProcessor.silenceThreshold * 0.5
        XCTAssertTrue(p.process(raw: input, dt: 1.0).spec64.allSatisfy { $0 == 0 })
    }

    // MARK: 시간 동작

    /// 1-pole `min(dt·20, 1)` 과 슬루 `±min(dt·40, 1)`. 작은 dt 에서는 한 프레임에 다 못 간다.
    func testSmoothingAndSlewLimitProgressOverFrames() {
        var p = AudioSpectrumProcessor()
        let input = raw { _ in 1.0 }
        let dt: Float = 1.0 / 60          // alpha = 1/3, slew = 2/3
        let f1 = p.process(raw: input, dt: dt)
        XCTAssertEqual(f1.spec64[0], 1.0 / 3, accuracy: 1e-5, "첫 프레임은 alpha 만큼만")
        let f2 = p.process(raw: input, dt: dt)
        XCTAssertGreaterThan(f2.spec64[0], f1.spec64[0], "프레임마다 목표로 접근")
        XCTAssertLessThan(f2.spec64[0], 1.0, "한 번에 도달하지 않는다")
        // 충분히 반복하면 수렴한다.
        var last: Float = 0
        for _ in 0..<200 { last = p.process(raw: input, dt: dt).spec64[0] }
        XCTAssertEqual(last, 1.0, accuracy: 1e-3, "결국 정규화 상한 1.0 으로 수렴")
    }

    /// 슬루 제한이 실제로 무는가 — dt 가 아주 작으면 상승폭이 그만큼 잘려야 한다.
    func testSlewLimitCapsPerFrameDelta() {
        var p = AudioSpectrumProcessor()
        let dt: Float = 1.0 / 1000        // slew = 0.04, alpha = 0.02
        let out = p.process(raw: raw { _ in 1.0 }, dt: dt)
        XCTAssertLessThanOrEqual(out.spec64[0], dt * AudioSpectrumProcessor.slewRate + 1e-6)
        XCTAssertGreaterThan(out.spec64[0], 0)
    }

    // MARK: 방어

    func testNonFiniteInputIsIgnored() {
        var p = AudioSpectrumProcessor()
        var input = [Float](repeating: 0.5, count: 128)
        input[3] = .nan
        input[9] = .infinity
        let out = p.process(raw: input, dt: 1.0)
        XCTAssertTrue(out.spec64.allSatisfy { $0.isFinite }, "비유한값이 밴드로 새면 안 된다")
    }

    func testShortAndLongInputAreAccepted() {
        var p = AudioSpectrumProcessor()
        XCTAssertEqual(p.process(raw: [], dt: 1.0).spec64.count, 192)
        XCTAssertEqual(p.process(raw: [Float](repeating: 1, count: 300), dt: 1.0).spec64.count, 192)
        XCTAssertEqual(p.process(raw: [Float](repeating: 1, count: 10), dt: 1.0).spec16.count, 48)
    }

    /// `AudioSpectrum16.downsample16` 도 MAX 여야 한다 — 같은 규약을 두 곳에서 쓰므로 함께 고정한다.
    func testDownsample16IsGroupMaxNotMean() {
        var spec = [Float](repeating: 0, count: 64)
        spec[5] = 1.0
        let bins = AudioSpectrum16.downsample16(spec)
        XCTAssertEqual(bins.count, 16)
        XCTAssertEqual(bins[1], 1.0, accuracy: 1e-6, "4개 중 최댓값 — 평균이었다면 0.25")
        XCTAssertEqual(bins[0], 0, accuracy: 1e-6)
    }
}
