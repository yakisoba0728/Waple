import XCTest
@testable import WapleCore

/// X-⑩ (G-E2-01~04): WE 64밴드 오디오 파이프라인 파리티.
///
/// 종전 구현은 **네 군데가 전부 달랐다** — 등폭 비닝 + 평균 + 틸트 없음 + 실측 캘리브 게인.
/// 넷이 한 커밋인 이유: 현행 게인(`0.75/32.2446`)이 나머지 셋의 부재를 흡수하도록 맞춰져
/// 있어서, 하나만 고치면 레벨이 무너진다.
///
/// 아래 기대값은 전부 원본 `wallpaper64.exe` 디스어셈블에서 유도했고, 수치는 독립 계산으로
/// 교차검증했다(44.1 kHz·N=1920·B=640 기준표).
final class AudioSpectrumWEParityTests: XCTestCase {

    // MARK: 밴드 매핑 (G-E2-01)

    /// **하위 29밴드가 FFT 빈 1:1** — 이게 이 매핑의 서명이다.
    /// 선형도 로그도 아니고, 별도의 선형 구간이 있는 것도 아니다. `pow(t, 0.25)` 가 저역에서
    /// 급격히 커지는 걸 `min(raw, prev+1)` 클램프가 막아서 생기는 결과다.
    func testLowestTwentyNineBandsMapOneToOneWithBins() {
        let bandOf = AudioSpectrum.bandOfBin(binCount: AudioSpectrum.referenceBinCount)
        for i in 1...29 {
            XCTAssertEqual(bandOf[i], i - 1,
                           "빈 \(i) 은 밴드 \(i - 1) 이어야 한다(1:1 구간)")
        }
        XCTAssertEqual(bandOf[30], 29, "30번째 빈부터 밴드가 빈을 나눠 갖기 시작한다")
        XCTAssertEqual(bandOf[31], 29, "밴드 29 는 빈 2개(30,31)를 갖는다")
    }

    /// 64밴드가 **전부** 채워진다. 종전 등폭 비닝의 증상 "상위 22바가 항상 0" 은
    /// WE 동작이 아니라 우리 쪽 비닝 부작용이었다.
    func testAllSixtyFourBandsAreReachedAndMonotonic() {
        let bandOf = AudioSpectrum.bandOfBin(binCount: AudioSpectrum.referenceBinCount)
        XCTAssertEqual(bandOf.max(), AudioSpectrum.bandCount - 1, "최상위 밴드까지 도달해야 한다")
        var seen = Set<Int>()
        var prev = 0
        for i in 1..<bandOf.count {
            seen.insert(bandOf[i])
            XCTAssertGreaterThanOrEqual(bandOf[i], prev, "밴드는 단조 비감소")
            XCTAssertLessThanOrEqual(bandOf[i], prev + 1, "빈당 최대 1밴드씩만 전진")
            prev = bandOf[i]
        }
        XCTAssertEqual(seen.count, AudioSpectrum.bandCount, "빈 밴드가 하나도 없어야 한다")
    }

    /// 32·16 밴드의 **빈 경계**(`docs/re/audio-capture.md` §8.4 표). 축약이 인접 2개씩 MAX 라
    /// 32밴드 j 는 64밴드 2j·2j+1 의 빈 합집합이고, 16밴드 j 는 64밴드 4j…4j+3 의 합집합이다.
    ///
    /// 못 박는 성질은 **하위 구간이 정확히 등간격**이라는 것이다 — 16밴드 0…6 이 각 4빈
    /// (44.1 kHz·B=640 에서 91.875 Hz), 32밴드 0…13 이 각 2빈. 문서 표가 그 위에 서 있다.
    /// 등간격의 출처는 별도 규칙이 아니라 `prev+1` 클램프의 1:1 구간(밴드 0…28)이다.
    func testThirtyTwoAndSixteenBandBinBoundariesMatchTheDocumentedTable() {
        let B = AudioSpectrum.referenceBinCount           // 640
        let bandOf = AudioSpectrum.bandOfBin(binCount: B)
        var lo = [Int](repeating: Int.max, count: 64)
        var hi = [Int](repeating: Int.min, count: 64)
        for i in 1..<B {
            let b = bandOf[i]
            lo[b] = Swift.min(lo[b], i); hi[b] = Swift.max(hi[b], i)
        }
        // `[lo, hi]` 배열로 든다 — Swift 튜플은 `Equatable` 이 아니라 `XCTAssertEqual` 이 안 받는다.
        func folded(_ group: Int) -> [[Int]] {
            (0..<(64 / group)).map { j in
                [(0..<group).map { lo[group * j + $0] }.min()!,
                 (0..<group).map { hi[group * j + $0] }.max()!]
            }
        }
        let b32 = folded(2), b16 = folded(4)
        XCTAssertEqual(b32.count, 32); XCTAssertEqual(b16.count, 16)

        // 하위 등간격 구간.
        for j in 0...13 {
            XCTAssertEqual(b32[j], [2 * j + 1, 2 * j + 2], "32밴드 \(j) 는 빈 2개")
        }
        for j in 0...6 {
            XCTAssertEqual(b16[j], [4 * j + 1, 4 * j + 4], "16밴드 \(j) 는 빈 4개(등간격 구간)")
        }
        // 그 위 — 문서 §8.4 표에서 뽑은 대표 행.
        XCTAssertEqual(b32[14], [29, 31]);  XCTAssertEqual(b32[15], [32, 40])
        XCTAssertEqual(b32[31], [564, 639])
        XCTAssertEqual(b16[7],  [29, 40]);  XCTAssertEqual(b16[8],  [41, 64])
        XCTAssertEqual(b16[15], [495, 639])

        // 두 해상도 모두 빈 1…639 를 빠짐없이 덮고 겹치지 않는다(DC 빈 0 만 제외).
        for table in [b32, b16] {
            XCTAssertEqual(table[0][0], 1)
            XCTAssertEqual(table[table.count - 1][1], B - 1)
            for k in 1..<table.count { XCTAssertEqual(table[k][0], table[k - 1][1] + 1) }
        }

        // 등간격의 실제 폭 — 문서가 적은 91.875 Hz(= 4 × 22.96875).
        let binWidth = AudioSpectrum.referenceRate / Double(AudioSpectrum.referenceFFTLength)
        XCTAssertEqual(binWidth * 4, 91.875, accuracy: 1e-9)
        // 선언 기본값 frequencymin=0 / frequencymax=1 이 덮는 대역(§8.4 의 따름정리).
        XCTAssertEqual(Double(b16[0][0]) * binWidth, 22.96875, accuracy: 1e-9)
        XCTAssertEqual(Double(b16[1][1] + 1) * binWidth, 206.71875, accuracy: 1e-9)
    }

    /// 원본의 상한 주파수 — bin 639 × (44100/1920).
    func testTopFrequencyMatchesOriginal() {
        XCTAssertEqual(AudioSpectrum.topFrequency, 14677.03125, accuracy: 1e-6)
    }

    /// 우리 구성(48 kHz·N=2048)이 원본과 **주파수 축에서** 등가인지.
    /// 길이는 못 맞추지만(vDSP 가 비-2거듭제곱 실수 FFT 를 못 한다) 이게 실제로 중요한 것이다.
    func testOurConfigurationReproducesTheOriginalBandStructure() {
        let n = 2048
        let rate = 48000.0
        let B = AudioSpectrum.binCount(fftLength: n, sampleRate: rate)
        XCTAssertEqual(B, 627, "원본 상한(≈14677 Hz)까지 덮는 빈 수")

        let binWidth = rate / Double(n)
        XCTAssertEqual(binWidth, 23.4375, accuracy: 1e-9)
        XCTAssertEqual(binWidth / (AudioSpectrum.referenceRate / Double(AudioSpectrum.referenceFFTLength)),
                       1.0204, accuracy: 1e-3, "원본 빈 폭 22.96875 Hz 대비 1.02배")

        let bandOf = AudioSpectrum.bandOfBin(binCount: B)
        // 1:1 구간 길이가 원본과 같아야 한다 — 저역 구조가 보존됐다는 뜻이다.
        for i in 1...29 { XCTAssertEqual(bandOf[i], i - 1) }
        XCTAssertEqual(bandOf.max(), 63, "여기서도 64밴드 전부 채워진다")
        // 상한 주파수 오차 0.05% 미만.
        let top = Double(B - 1) * binWidth
        XCTAssertEqual(top / AudioSpectrum.topFrequency, 1.0, accuracy: 5e-4)
    }

    /// 종전 1024 는 빈 폭이 43.07 Hz 로 원본의 1.88배였다 — 저역 밴드가 통째로 밀린다.
    /// 이 테스트는 "왜 2048 로 올렸는가" 를 수치로 남긴다.
    func testOldFFTSizeWouldHaveMissedTheLowBandsByNearlyTwoBins() {
        let old = 48000.0 / 1024
        let we = AudioSpectrum.referenceRate / Double(AudioSpectrum.referenceFFTLength)
        XCTAssertEqual(old / we, 2.0408, accuracy: 1e-3, "종전 빈 폭은 원본의 2.04배였다")
    }

    // MARK: 틸트 (G-E2-03)

    /// `w = C − (1−C)·cos(π·t)`, 진폭에 `sqrt(w)`.
    /// **t 는 밴드가 아니라 빈 인덱스의 정규화값이다** — 원장 초안은 밴드로 적었는데 틀렸다.
    /// 빈이 30~39개 들어가는 상위 밴드에서 값이 크게 갈린다.
    func testTiltIsSqrtOfHannLikeCurveOverBinIndex() {
        let B = AudioSpectrum.referenceBinCount
        let w = AudioSpectrum.tiltAmplitudeWeights(binCount: B)
        XCTAssertEqual(w[0], 0, "DC 는 안 쓴다")
        // t=0 → w = C − (1−C) = 2C − 1 = 0.002
        XCTAssertEqual(w[1], Float(0.002).squareRoot(), accuracy: 1e-5)
        // t≈1 → w ≈ 1
        XCTAssertEqual(w[B - 1], 1.0, accuracy: 1e-4)
        // 중간점 t=0.5 → w = C = 0.501
        let mid = 1 + (B - 1) / 2
        XCTAssertEqual(w[mid], Float(AudioSpectrum.tiltC).squareRoot(), accuracy: 2e-3)
        // 단조 증가.
        for i in 2..<B { XCTAssertGreaterThanOrEqual(w[i], w[i - 1]) }
        // 최저↔최고 감쇠비 22.36배. 이게 "베이스만 흔들리던" 증상의 반대편이다 —
        // 원본은 오히려 저역을 22배 **깎는다**.
        XCTAssertEqual(w[B - 1] / w[1], 22.3608, accuracy: 1e-3)
    }

    /// 틸트가 시간영역 창(Hann)이 아니라는 것. 곡선 모양은 Hann 과 같지만 **적용 축이 다르다** —
    /// 시간영역엔 창이 전혀 없고(사각창), 이 가중치는 FFT 출력 빈에 곱해진다.
    /// 코드로는 "샘플 배열 길이가 아니라 빈 배열 길이로 만들어진다" 는 사실이 그 증거다.
    func testTiltLengthFollowsBinCountNotWindowLength() {
        let n = 2048
        let B = AudioSpectrum.binCount(fftLength: n, sampleRate: 48000)
        XCTAssertEqual(AudioSpectrum.tiltAmplitudeWeights(binCount: B).count, B)
        XCTAssertNotEqual(B, n, "빈 배열은 창 길이와 다르다")
        XCTAssertNotEqual(B, AudioSpectrum.windowLength(fftLength: n))
    }

    // MARK: 축약 (G-E2-02)

    /// 밴드 안에서 **MAX**. 평균이면 넓은 밴드(빈 39개)의 피크가 뭉개진다.
    func testBandReductionTakesMaximumNotMean() {
        let B = 640
        var mags = [Float](repeating: 0, count: B)
        let bandOf = AudioSpectrum.bandOfBin(binCount: B)
        // 마지막 밴드(빈 39개)에 한 빈만 크게 세운다.
        let lastBandBins = (1..<B).filter { bandOf[$0] == 63 }
        XCTAssertGreaterThan(lastBandBins.count, 10, "상위 밴드는 빈이 여러 개다")
        mags[lastBandBins[lastBandBins.count / 2]] = 1.0

        let out = AudioSpectrum.spectrum(normalizedMagnitudes: mags, binCount: B)
        let tilt = AudioSpectrum.tiltAmplitudeWeights(binCount: B)
        let expected = 1.0 * tilt[lastBandBins[lastBandBins.count / 2]] * AudioSpectrum.gain
        XCTAssertEqual(out[63], expected, accuracy: expected * 1e-4,
                       "MAX 라면 그 빈 하나가 그대로 밴드값이 된다")
        // 평균이었다면 1/39 로 줄었을 것 — 그 값과는 확실히 달라야 한다.
        XCTAssertGreaterThan(out[63], expected * 0.9)
    }

    // MARK: 게인 (G-E2-04)

    /// `162.56 = 127 × 0.001 × 2 × 640`. 원장 초안의 유도식(`0.001 × 2000000 × 127`)은
    /// 틀렸다 — `2000000` 은 바이너리에 존재하지 않는다. 결과값만 우연히 맞았다.
    func testAbsoluteGainMatchesTheDerivedConstant() {
        XCTAssertEqual(AudioSpectrum.gain, 162.56, accuracy: 1e-4)
        let derived = Float(127) * 0.001 * 2 * Float(AudioSpectrum.referenceBinCount)
        XCTAssertEqual(AudioSpectrum.gain, derived, accuracy: 1e-3, "127 × 0.001 × 2 × 640")
        // 종전 캘리브 게인 대비 배율(vDSP packed-real, N=1024 규약 기준 3.41배)을 기록으로 남긴다.
        let previousCalibrated: Float = 0.75 / 32.2446
        let equivalentAtOldN = AudioSpectrum.gain / (2 * 1024)
        XCTAssertEqual(equivalentAtOldN / previousCalibrated, 3.4125, accuracy: 1e-3)
    }

    // MARK: 파이프라인 성질

    func testSilenceYieldsZeroBands() {
        let out = AudioSpectrum.spectrum(normalizedMagnitudes: [Float](repeating: 0, count: 640),
                                         binCount: 640)
        XCTAssertEqual(out.count, AudioSpectrum.bandCount)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    /// 진폭 선형 — 채널별 호출이 L/R 레벨비를 보존해야 한다(#17 회귀 가드).
    func testScaleLinearAndChannelIndependent() {
        let base = (0..<640).map { Float($0 + 1) / 640 }
        let a = AudioSpectrum.spectrum(normalizedMagnitudes: base, binCount: 640)
        let b = AudioSpectrum.spectrum(normalizedMagnitudes: base.map { $0 * 2 }, binCount: 640)
        for i in a.indices { XCTAssertEqual(b[i], a[i] * 2, accuracy: max(1e-4, a[i] * 1e-4)) }
        let quiet = AudioSpectrum.spectrum(normalizedMagnitudes: base.map { $0 * 0.25 }, binCount: 640)
        XCTAssertEqual((quiet.max() ?? 0) / max(1e-9, a.max() ?? 0), 0.25, accuracy: 1e-3)
        XCTAssertTrue(a.allSatisfy { $0 >= 0 })
    }

    /// Inf/NaN 빈은 0 으로 친다 — 원본도 지수 필드를 검사해 power 를 0 으로 만든다(`0x1400d1c62`).
    func testNonFiniteBinsAreIgnoredRatherThanPoisoningTheBand() {
        var mags = [Float](repeating: 0.5, count: 640)
        mags[100] = .infinity
        mags[200] = .nan
        let out = AudioSpectrum.spectrum(normalizedMagnitudes: mags, binCount: 640)
        XCTAssertTrue(out.allSatisfy { $0.isFinite }, "비유한값이 밴드로 새면 안 된다")
        XCTAssertTrue(out.allSatisfy { $0 > 0 }, "나머지 빈은 정상적으로 밴드를 채운다")
    }

    /// 창 길이 규약 `int(N − (10/30)·N)`, 오버랩 없음. 나머지 1/3 은 패딩이다.
    ///
    /// **1366 → 1365 는 정정이다.** 종전 구현은 `n - n/3`(정수 나눗셈)이라 절삭이 몫에
    /// 걸렸는데, 원본은 `subss` 뒤 `cvttss2si`(`0x1400d149b`-`0x1400d14a0`)라 **차**에 걸린다.
    /// `N % 3 == 0` 이면 같고 아니면 1 어긋난다 — 아래 2089(실물 48 kHz)가 그 증거다.
    func testWindowLengthFollowsTheOriginalTwoThirdsRule() {
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 1920), 1280, "원본 44.1 kHz 값(N%3==0 이라 두 방식이 같다)")
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 2089), 1392, "실물 48 kHz — 정수 나눗셈이면 1393")
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 2048), 1365, "우리 구성 — 정수 나눗셈이면 1366")
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 1), 1, "퇴화 입력에서도 0 이 아니어야 한다")
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 0), 1)
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: -8), 1)
    }

    /// 퇴화 입력 방어.
    func testDegenerateInputs() {
        XCTAssertEqual(AudioSpectrum.spectrum(normalizedMagnitudes: []).count, AudioSpectrum.bandCount)
        XCTAssertEqual(AudioSpectrum.spectrum(normalizedMagnitudes: [1]).count, AudioSpectrum.bandCount)
        XCTAssertTrue(AudioSpectrum.bandOfBin(binCount: 0).isEmpty)
        XCTAssertTrue(AudioSpectrum.tiltAmplitudeWeights(binCount: 1).count <= 1)
        XCTAssertGreaterThanOrEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: 0), 2)
    }

    // MARK: 절대 레벨 오라클 (S8-7)

    /// 캡처 경로 재현: 창 `L` 샘플의 사인을 `N` 으로 제로패딩해 `|DFT(k)|/N` 을 만든다.
    /// 이게 `SystemAudioSpectrumProvider` 가 `AudioSpectrum.spectrum` 에 넘기는 규약이다.
    private func normalizedMagnitudes(sineAtBin k0: Int, amplitude a: Double,
                                      fftLength n: Int, windowLength l: Int) -> [Float] {
        var x = [Double](repeating: 0, count: n)
        for i in 0..<l { x[i] = a * sin(2 * Double.pi * Double(k0) * Double(i) / Double(n)) }
        var mags = [Float](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) {
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let ang = 2 * Double.pi * Double(k) * Double(i) / Double(n)
                re += x[i] * cos(ang); im -= x[i] * sin(ang)
            }
            mags[k] = Float((re * re + im * im).squareRoot() / Double(n))
        }
        return mags
    }

    /// **S8-7: 절대 레벨 오라클.** 이게 없으면 전역 게인·틸트·축약이 통째로 바뀌어도 CI 가 초록이다.
    ///
    /// 왜 필요한가 — 기존 오디오 단언은 전부 **형상**(비율·단조성·max-vs-mean)이거나
    /// 자기참조(`expected = 1.0 * tilt[...] * gain`)라 값이 코드를 따라 움직인다.
    /// `AudioSpectrum.gain` 상수 자체는 `testAbsoluteGainMatchesTheDerivedConstant` 가 잡지만,
    /// **합성 회귀**(예: `spectrum` 이 `binCount:` 인자를 무시해 B=1024 로 도는 것)는 아무도 못 잡는다 —
    /// 기존 테스트는 전부 `mags.count == binCount` 인 입력만 주기 때문에 그 인자의 제한 역할이
    /// 한 번도 행사되지 않는다. 실제 프로덕션은 1024개 크기를 주면서 `binCount: 627` 을 건다.
    ///
    /// 자극은 만스케일(A=1) 사인이고 주파수는 2048 격자의 빈 중심에 정확히 얹는다.
    /// 자기검증: 전길이 정수사이클 사인이면 `|X(k0)|/N == 0.5` 여야 한다(아래 첫 단언).
    ///
    /// 허용오차 **0.5% 상대**. 아래로는 Float FFT 누산·libm 1-ULP 가 전부 1e-6 상대 이하라
    /// 약 5000배 여유가 있고(밴드 경계도 안정적이다 — `pow(t,0.25)*64` 의 최소 정수 여유가
    /// Float eps 의 45배), 위로는 잡아야 할 **가장 작은** 회귀가 2.03% 다(게인을 B=640 대신
    /// B=627 에서 재유도하면 162.56 → 159.26). 나머지 회귀는 훨씬 크다 — 1/N↔1/(2N) 규약 혼동
    /// 100%, 종전 캘리브레이션 게인 3.41배, `downsample16` 을 평균으로 되돌리면 −70%.
    ///
    /// **이 오라클이 못 보는 것**: 리눅스에서 돌아야 해서 DFT 를 자체 구현하므로, 고정하는 것은
    /// "문서화된 입력 규약이 주어졌을 때의 WapleCore 생산단" 이다. WapleRender 쪽
    /// `norm = 1/(2 * fftSize)` 가 바뀌면 전 레벨이 두 배가 되는데 이 테스트는 못 본다.
    func testAbsoluteOutputLevelOfFullScaleSine() {
        let n = 2048
        let window = AudioSpectrum.windowLength(fftLength: n)                    // 1365
        let bins = AudioSpectrum.binCount(fftLength: n, sampleRate: 48000)       // 627
        XCTAssertEqual(window, 1365)
        XCTAssertEqual(bins, 627)

        // 자기검증 — 규약이 |X|/N 이라는 것을 테스트 안에서 증명한다.
        let full = normalizedMagnitudes(sineAtBin: 64, amplitude: 1.0, fftLength: n, windowLength: n)
        XCTAssertEqual(full[64], 0.5, accuracy: 1e-6, "전길이 정수사이클 사인 = |X|/N = A/2")
        XCTAssertLessThan(full[63], 1e-6, "이웃 빈 누설 없음")

        // 중역 1007.8 Hz — 틸트가 아직 작은 자리(밴드 32)
        let mid = AudioSpectrum.spectrum(
            normalizedMagnitudes: normalizedMagnitudes(sineAtBin: 43, amplitude: 1.0,
                                                       fftLength: n, windowLength: window),
            binCount: bins)
        let midPeak: Float = 6.174861
        XCTAssertEqual(mid.max() ?? 0, midPeak, accuracy: midPeak * 5e-3,
                       "만스케일 사인 1007.8 Hz 의 절대 출력")
        XCTAssertEqual(mid.firstIndex(of: mid.max() ?? 0), 32, "밴드 위치도 계약이다")

        // 고역 14062.5 Hz — 틸트가 거의 1 인 자리(밴드 63)
        let top = AudioSpectrum.spectrum(
            normalizedMagnitudes: normalizedMagnitudes(sineAtBin: 600, amplitude: 1.0,
                                                       fftLength: n, windowLength: window),
            binCount: bins)
        let topPeak: Float = 54.057377
        XCTAssertEqual(top.max() ?? 0, topPeak, accuracy: topPeak * 5e-3,
                       "만스케일 사인 14062.5 Hz 의 절대 출력")
        XCTAssertEqual(top.firstIndex(of: top.max() ?? 0), 63)

        // 두 자극의 비 = 틸트 곡선 자체 — 게인이 함께 움직여도 이건 안 움직인다.
        XCTAssertEqual(Double((top.max() ?? 0) / (mid.max() ?? 1)), 8.7544, accuracy: 0.01,
                       "고역/중역 비 = sqrt 틸트 비 — 게인과 독립인 두 번째 축")

        // 16밴드 축약이 MAX 이므로 피크가 보존된다(평균이었다면 여기서 떨어진다).
        XCTAssertEqual(AudioSpectrum16.downsample16(mid).max() ?? 0, midPeak, accuracy: midPeak * 5e-3,
                       "MAX 축약은 피크를 보존한다 — 평균이면 1.86 으로 떨어진다")
    }
}
