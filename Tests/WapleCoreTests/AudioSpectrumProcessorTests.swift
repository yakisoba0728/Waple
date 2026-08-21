import XCTest
@testable import WapleCore

/// X-⑩: WE 소비단 오디오 스테이지. 원본 `0x140110630`(primary)의 오디오 구간
/// `0x140111662–0x1401131bf` 실측 규약을 고정한다.
///
/// 이 단계를 통째로 빼먹어서 우리 스펙트럼은 레벨이 3.5~5배 모자랐다. 프로듀서의 절대 게인
/// (162.56)을 소수점까지 유도해 놓고 정작 그 뒤를 안 붙인 것이다.
///
/// 그리고 그 뒤를 붙일 때 **분모를 틀렸다**. 아래 `MARK: 그룹 정규화` 의 두 테스트는 원래
/// "그룹 순간 피크로 한 프레임에 나눈다" 를 고정하고 있었는데, 원본의 분모는 프레임을 넘어
/// 사는 **피크 엔벨로프**다(`[r15+0x1b0]`, `0x1401121b1` 이 그걸 읽어 역수를 만든다). 그래서
/// 두 테스트를 "엔벨로프가 수렴한 뒤" 로 고쳤고, 엔벨로프 자체를 고정하는 절을 새로 붙였다.
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
    ///
    /// 종전 이 테스트는 dt=1.0 **한 프레임**으로 두 그룹이 다 1.0 이 되기를 요구했다. 그건
    /// "분모 = 그룹 순간 피크" 일 때 이야기다. 원본의 분모는 엔벨로프라 그룹 1 은 첫 프레임에
    /// 0.5/0.75 = 0.667 이 나온다(엔벨로프가 리시드 1.0 에서 dt·0.5 만큼만 내려오므로).
    /// "자기 그룹 피크로 정규화" 는 **엔벨로프가 수렴한 뒤에** 성립하는 성질이다.
    func testGroupPeakNormalizationIsPerEightBandsOnceEnvelopeSettles() {
        var p = AudioSpectrumProcessor()
        // 그룹 0 은 최대 1.0, 그룹 1 은 최대 0.5 — 수렴 후 둘 다 자기 그룹 안에서 1.0 이 돼야 한다.
        // (0.5 는 0.333·globalPeak(=0.333) 보다 커서 비율 하한에 걸리지 않는다.)
        var input = [Float](repeating: 0, count: 128)
        input[0] = 1.0
        input[8] = 0.5

        // 첫 프레임은 아직 아니다 — 분모가 엔벨로프라는 증거 그 자체.
        let first = p.process(raw: input, dt: 1.0)
        XCTAssertEqual(first.spec64[8], 0.5 / 0.75, accuracy: 1e-5,
                       "리시드 1.0 → dt=1 에 0.5·1.0 만큼 하강해 0.75, 0.5/0.75 = 0.667")

        // 하강 0.5/s 이므로 1.0 → 0.5 에 1초. 60fps 로 200프레임(≈3.3초)이면 넉넉하다.
        var out = first
        for _ in 0..<200 { out = p.process(raw: input, dt: 1.0 / 60) }
        XCTAssertEqual(out.spec64[0], 1.0, accuracy: 1e-5, "그룹 0 의 피크는 자기 그룹으로 정규화")
        XCTAssertEqual(out.spec64[8], 1.0, accuracy: 1e-5, "그룹 1 도 자기 그룹 피크로 정규화")
        XCTAssertEqual(p.peakEnvelope[1], 0.5, accuracy: 1e-5, "엔벨로프가 그룹 1 의 피크에 앉았다")
    }

    /// 비율 하한 `0.333·globalPeak` — 조용한 그룹이 통째로 증폭돼 노이즈가 만개하는 것을 막는다.
    /// 하한은 **엔벨로프의 목표**에 걸린다(`0x140111c99` 의 `maxps` 가 슬루 계산 앞이다).
    func testQuietGroupIsFlooredByGlobalPeakRatio() {
        var p = AudioSpectrumProcessor()
        var input = [Float](repeating: 0, count: 128)
        input[0] = 1.0        // 그룹 0
        input[8] = 0.01       // 그룹 1 — 0.333·1.0 보다 훨씬 작다
        var out = AudioSpectrumProcessor.reduce([Float](repeating: 0, count: 128))
        for _ in 0..<200 { out = p.process(raw: input, dt: 1.0 / 60) }
        XCTAssertEqual(out.spec64[0], 1.0, accuracy: 1e-5)
        // 하한이 0.333 이므로 엔벨로프도 0.333 에 앉고 0.01/0.333 = 0.03 — 1.0 으로 부풀지 않는다.
        XCTAssertEqual(p.peakEnvelope[1], AudioSpectrumProcessor.groupPeakFloorRatio, accuracy: 1e-6)
        XCTAssertEqual(out.spec64[8], 0.01 / AudioSpectrumProcessor.groupPeakFloorRatio, accuracy: 1e-4)
        XCTAssertLessThan(out.spec64[8], 0.05, "하한이 없었다면 1.0 이 됐을 것")
    }

    // MARK: 피크 엔벨로프 — 분모의 정체

    /// 분모는 그룹 **순간 피크가 아니라** 프레임을 넘어 사는 엔벨로프다(`0x1401121b1` 이
    /// `[r15+0x1b0]` 을 읽어 `rcpps` 로 역수를 만든다). 순간 피크였다면 아래 그룹 1 은 한
    /// 프레임에 1.0 이 됐을 것이다.
    func testNormalizationDividesByEnvelopeNotInstantPeak() {
        var p = AudioSpectrumProcessor()
        var input = [Float](repeating: 0, count: 128)
        input[0] = 1.0
        input[8] = 0.5
        let out = p.process(raw: input, dt: 1.0)     // alpha=1, slew=1 — 시간 스무딩은 다 빠진다
        XCTAssertEqual(out.spec64[8], 2.0 / 3.0, accuracy: 1e-5)
        XCTAssertNotEqual(out.spec64[8], 1.0, accuracy: 1e-3, "순간 피크로 나눴다면 1.0 이었다")
    }

    /// 비대칭 슬루 — 상승 1.0/s(`0x140111ef1` 의 `xmm11`=1.0), 하강 0.5/s(`0x140111ef7` 의 -0.5).
    /// 같은 dt 에서 올라가는 폭이 내려가는 폭의 정확히 2배여야 한다.
    func testPeakEnvelopeRisesTwiceAsFastAsItFalls() {
        var p = AudioSpectrumProcessor()
        let loud = [Float](repeating: 1, count: 128)
        for _ in 0..<200 { _ = p.process(raw: loud, dt: 1.0 / 60) }
        XCTAssertEqual(p.peakEnvelope[1], 1.0, accuracy: 1e-6, "먼저 1.0 에 앉혀 둔다")

        // 그룹 0 만 소리를 남겨 globalPeak=1.0 을 유지한다. 그룹 1 의 목표는 비율 하한 0.333.
        var group0Only = [Float](repeating: 0, count: 128)
        for i in 0..<8 { group0Only[i] = 1.0 }

        _ = p.process(raw: group0Only, dt: 0.1)
        XCTAssertEqual(p.peakEnvelope[1], 0.95, accuracy: 1e-6, "하강 = 0.1초 × 0.5/s = 0.05")
        _ = p.process(raw: group0Only, dt: 0.1)
        XCTAssertEqual(p.peakEnvelope[1], 0.90, accuracy: 1e-6, "두 번째도 같은 폭")

        _ = p.process(raw: loud, dt: 0.1)
        XCTAssertEqual(p.peakEnvelope[1], 1.0, accuracy: 1e-6, "상승 = 0.1초 × 1.0/s = 0.10 — 2배")
    }

    /// 무음에도 엔벨로프는 계속 내려간다 — 원본은 엔벨로프 루프(`0x140111ed0`)를 무음 분기
    /// (`0x14011242f`)보다 **앞에서** 돈다. 출력만 0 이고 분모는 살아 움직인다.
    func testEnvelopeKeepsDecayingWhileSilent() {
        var p = AudioSpectrumProcessor()
        let loud = [Float](repeating: 1, count: 128)
        for _ in 0..<200 { _ = p.process(raw: loud, dt: 1.0 / 60) }

        let silent = [Float](repeating: 0, count: 128)
        let out = p.process(raw: silent, dt: 0.1)
        XCTAssertTrue(out.spec64.allSatisfy { $0 == 0 }, "출력은 0")
        XCTAssertEqual(p.peakEnvelope[0], 0.95, accuracy: 1e-6, "그래도 0.1초 × 0.5/s 만큼 내려갔다")
    }

    /// 리시드 — 엔벨로프가 죽은 상태에서 소리를 만나면 16개 전부가 **1.0** 으로 앉는다
    /// (`0x140111cd2`부터 16번의 `mov dword [rax+n], 0x3f800000`). 이게 없으면
    /// `max(env, 0.001)` 때문에 첫 프레임이 1000배로 터진다.
    func testDeadEnvelopeReseedsToOneWhenAudioReturns() {
        var p = AudioSpectrumProcessor()
        // dt=0 이면 슬루 스텝이 0 이라 리시드 값만 남는다 — 리시드 단독 관찰.
        _ = p.process(raw: [Float](repeating: 0.25, count: 128), dt: 0)
        XCTAssertEqual(p.peakEnvelope, [Float](repeating: 1.0, count: 16),
                       "첫 소리 프레임: 순간 피크(0.25)가 아니라 1.0 으로 앉는다")

        // 무음을 길게 흘리면 엔벨로프가 0 까지 죽는다(하강 → 스냅).
        let silent = [Float](repeating: 0, count: 128)
        for _ in 0..<30 { _ = p.process(raw: silent, dt: 1.0) }
        XCTAssertEqual(p.peakEnvelope[0], 0, accuracy: 1e-9)

        // 그리고 다시 소리가 들어오면 또 1.0 에서 시작한다.
        _ = p.process(raw: [Float](repeating: 0.5, count: 128), dt: 0.01)
        XCTAssertEqual(p.peakEnvelope[0], 0.995, accuracy: 1e-5,
                       "1.0 리시드 후 dt=0.01 만큼 하강 → 1.0 − 0.01·0.5")
    }

    /// 무음은 **출력만** 0 이고 1-pole 상태는 유지된다 — 원본이 그렇다(`0x140112646` 이 출력 버퍼만
    /// memset 하고 `state`/`prev` 는 별도 버퍼라 안 만진다). 소리가 돌아오면 처음부터가 아니라
    /// 끊긴 자리에서 이어 올라간다. 상태까지 지우면 무음이 낄 때마다 어택이 재시작돼 굼떠진다.
    /// (엔벨로프만은 예외로 계속 내려간다 — `testEnvelopeKeepsDecayingWhileSilent`.)
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

    // MARK: 32밴드 유니폼 — 접근자가 없어서 호출부가 평균으로 다시 짰던 자리

    /// `g_AudioSpectrum32Left/Right` 로 나가야 하는 32밴드 반쪽. `spec32` 는 [L|R|Mono] 3분면
    /// (96 float)이므로 좌는 `[0..<32]`, 우는 `[32..<64]` 다.
    ///
    /// 이 접근자가 없던 동안 `SceneRenderer.setSpectrum64` 는 `left64`/`right64` 만 받아
    /// **자기 축약을 다시 짰고 그게 평균이었다** — 실물은 `maxss`(`0x1401128e0`,
    /// 원시 바이트 `f30f5f048b`). 아래 두 단언이 그 재발을 막는다.
    func testLeft32AndRight32SliceTheMaxReducedQuadrants() {
        var stereo = [Float](repeating: 0, count: 128)
        stereo[5] = 1.0            // Left  밴드 5 → 32밴드 인덱스 2 (밴드 4·5)
        stereo[64 + 9] = 0.75      // Right 밴드 9 → 32밴드 인덱스 4 (밴드 8·9)
        let out = AudioSpectrumProcessor.reduce(stereo)

        XCTAssertEqual(out.left32.count, 32)
        XCTAssertEqual(out.right32.count, 32)
        XCTAssertEqual(out.left32, Array(out.spec32[0..<32]))
        XCTAssertEqual(out.right32, Array(out.spec32[32..<64]))

        XCTAssertEqual(out.left32[2], 1.0, accuracy: 1e-6, "MAX 라면 그대로 1.0")
        XCTAssertEqual(out.right32[4], 0.75, accuracy: 1e-6)
        // 좌/우가 서로 섞이지 않는다 — 종전 호출부처럼 left64 만 보고 다시 접으면 이게 깨진다.
        XCTAssertEqual(out.left32[4], 0, accuracy: 1e-6)
        XCTAssertEqual(out.right32[2], 0, accuracy: 1e-6)
    }

    /// **평균과 MAX 가 실제로 갈리는 것을 수치로 못 박는다.** 인접 두 밴드 중 하나만 뜨는
    /// 신호(순음 저역이 정확히 이 모양이다)에서 평균은 MAX 의 **절반**이다.
    /// 이 테스트가 실패하면 누군가 32밴드 축약을 다시 평균으로 되돌린 것이다.
    func test32BandFoldIsMaxAndDivergesFromMeanByTwoX() {
        var stereo = [Float](repeating: 0, count: 128)
        stereo[6] = 1.0            // 32밴드 인덱스 3 = 밴드 6·7 중 하나만 뜬다
        let out = AudioSpectrumProcessor.reduce(stereo)

        let mine = out.left32[3]
        let ifItHadBeenMean = (stereo[6] + stereo[7]) / 2      // 종전 호출부가 쓰던 식
        XCTAssertEqual(mine, 1.0, accuracy: 1e-6)
        XCTAssertEqual(ifItHadBeenMean, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mine, ifItHadBeenMean * 2, accuracy: 1e-6, "좁은 피크에서 정확히 2배 갈린다")
    }

    /// mono 사분면 접근자. 유니폼으로는 안 나가지만(등록표에 오디오는 0x62…0x67 여섯 개뿐),
    /// 세 해상도 전부에서 `0.5·(L+R)` 규약이 유지되는지는 고정해 둔다(`0x1401126b6` 의 `mulss …, 0.5`).
    func testMonoQuadrantAccessorsAtAllThreeResolutions() {
        var stereo = [Float](repeating: 0, count: 128)
        for i in 0..<64 { stereo[i] = 1.0 }        // Left 만 1, Right 0
        let out = AudioSpectrumProcessor.reduce(stereo)
        XCTAssertEqual(out.mono64.count, 64)
        XCTAssertEqual(out.mono32.count, 32)
        XCTAssertEqual(out.mono16.count, 16)
        XCTAssertEqual(out.mono64, [Float](repeating: 0.5, count: 64))
        // 32·16 의 mono 분면은 mono64 를 MAX 로 접은 것이지 L/R 을 다시 평균한 게 아니다.
        XCTAssertEqual(out.mono32, [Float](repeating: 0.5, count: 32))
        XCTAssertEqual(out.mono16, [Float](repeating: 0.5, count: 16))
    }
}
