import XCTest
@testable import WapleRender

/// 순수 Swift Vorbis 디코더 코어 유닛테스트(코드북/FFT/IMDCT/윈도 — 실물 파일 불요, 결정적).
final class OggVorbisDecoderTests: XCTestCase {

    // ── 비트 리더(LSB-first) ────────────────────────────────────────────────
    func testBitReaderLSBFirst() {
        // 0xB4 = 1011_0100. LSB부터: 0,0,1,0,1,1,0,1
        var r = VorbisBitReader([0xB4])
        XCTAssertEqual(r.readBit(), 0)          // pos0
        XCTAssertEqual(r.read(3), 2)            // pos1,2,3 = 0,1,0 → 0|1<<1|0<<2 = 2
        XCTAssertEqual(r.read(4), 11)           // pos4,5,6,7 = 1,1,0,1 → 1+2+0+8 = 11
        XCTAssertFalse(r.endOfPacket)
        XCTAssertEqual(r.readBit(), 0)          // 끝 넘김
        XCTAssertTrue(r.endOfPacket)
    }

    func testBitReaderMultiByteAndSigned() {
        // 두 바이트 걸친 읽기: 0x01,0x02 → LSB-first 16bit = 0x0201 = 513
        var r = VorbisBitReader([0x01, 0x02])
        XCTAssertEqual(r.read(16), 0x0201)
        var s = VorbisBitReader([0x0F])         // 1111 (low 4 = 15) → signed 4bit = -1
        XCTAssertEqual(s.readSigned(4), -1)
    }

    // ── 코드북 헬퍼(advisor 지목: lookup1_values / float32_unpack) ───────────
    func testLookup1Values() {
        XCTAssertEqual(VorbisCodebook.lookup1Values(64, 2), 8)      // 8²=64≤64, 9²=81>64
        XCTAssertEqual(VorbisCodebook.lookup1Values(63, 2), 7)      // 7²=49≤63, 8²=64>63
        XCTAssertEqual(VorbisCodebook.lookup1Values(1000, 3), 10)   // 10³=1000≤1000, 11³>1000
        XCTAssertEqual(VorbisCodebook.lookup1Values(1, 1), 1)
    }

    func testFloat32Unpack() {
        // mantissa * 2^(exp-788). exp=788, mantissa=1 → 1.0
        let one: UInt32 = (788 << 21) | 1
        XCTAssertEqual(VorbisCodebook.float32Unpack(one), 1.0, accuracy: 1e-9)
        // 부호비트 → 음수
        let negOne: UInt32 = 0x8000_0000 | (788 << 21) | 1
        XCTAssertEqual(VorbisCodebook.float32Unpack(negOne), -1.0, accuracy: 1e-9)
        // mantissa=2, exp=787 → 2*2^-1 = 1.0
        let alsoOne: UInt32 = (787 << 21) | 2
        XCTAssertEqual(VorbisCodebook.float32Unpack(alsoOne), 1.0, accuracy: 1e-9)
    }

    func testBitReverse() {
        XCTAssertEqual(VorbisCodebook.bitReverse(0), 0)
        XCTAssertEqual(VorbisCodebook.bitReverse(1), 0x8000_0000)   // bit0 → bit31
        XCTAssertEqual(VorbisCodebook.bitReverse(0x8000_0000), 1)
    }

    /// A-B4: dims×entries 곱 상한. entries=0xFFFFFF 는 단독 상한(1<<24)은 통과하지만
    /// dims=0xFFFF 와의 곱이 상한 초과 → 거대 할당 전에 parse 초입에서 .corrupt throw.
    func testCodebookRejectsHugeDimTimesEntries() {
        // LSB-first: read(24)=0x564342("BCV") ← [0x42,0x43,0x56], read(16)=0xFFFF, read(24)=0xFFFFFF
        var r = VorbisBitReader([0x42, 0x43, 0x56, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try VorbisCodebook.parse(&r)) { e in
            guard case VorbisError.corrupt = e else { return XCTFail("expected .corrupt, got \(e)") }
        }
    }

    // ── FFT vs naive DFT ────────────────────────────────────────────────────
    func testFFTMatchesNaiveDFT() {
        for n in [64, 128, 512, 1024] {
            let plan = FFTPlan(n)
            var re = (0..<n).map { _ in Double.random(in: -1...1) }
            var im = (0..<n).map { _ in Double.random(in: -1...1) }
            let re0 = re, im0 = im
            plan.transform(&re, &im, inverse: false)
            // naive DFT: X[k] = Σ x[j] exp(-j2πkj/n)
            for k in stride(from: 0, to: n, by: max(1, n / 8)) {
                var sr = 0.0, si = 0.0
                for j in 0..<n {
                    let a = -2.0 * Double.pi * Double(k * j) / Double(n)
                    sr += re0[j] * cos(a) - im0[j] * sin(a)
                    si += re0[j] * sin(a) + im0[j] * cos(a)
                }
                XCTAssertEqual(re[k], sr, accuracy: 1e-6, "FFT re n=\(n) k=\(k)")
                XCTAssertEqual(im[k], si, accuracy: 1e-6, "FFT im n=\(n) k=\(k)")
            }
        }
    }

    func testFFTInverseRoundTrip() {
        let n = 256
        let plan = FFTPlan(n)
        var re = (0..<n).map { _ in Double.random(in: -1...1) }
        var im = (0..<n).map { _ in Double.random(in: -1...1) }
        let re0 = re, im0 = im
        plan.transform(&re, &im, inverse: false)
        plan.transform(&re, &im, inverse: true)
        for i in 0..<n { XCTAssertEqual(re[i], re0[i], accuracy: 1e-9); XCTAssertEqual(im[i], im0[i], accuracy: 1e-9) }
    }

    // ── 빠른 IMDCT ≡ naive IMDCT (advisor 지목: 사전/사후 회전) ──────────────
    func testFastIMDCTMatchesNaive() {
        for n in [256, 2048] {
            let plan = FFTPlan(n)   // DCT-IV(N/2) 은 2·(N/2)=N 점 FFT 사용
            let X = (0..<(n / 2)).map { _ in Float.random(in: -1...1) }
            let a = VorbisImdct.naive(X, n)
            let b = VorbisImdct.fast(X, n, plan)
            var maxDiff: Float = 0
            for i in 0..<n { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
            XCTAssertLessThan(maxDiff, 1e-2, "fast IMDCT != naive for n=\(n) (maxDiff=\(maxDiff))")
        }
    }

    // ── 실물 ogg 전 경로(헤르메틱) ──────────────────────────────────────────
    /// 임베드된 초소형 실물 Vorbis ogg 를 디코드 → 헤더 정합/샘플수/비무음/NaN 없음.
    /// (컨테이너→코드북→floor1→residue→IMDCT→오버랩 전 경로. 비트정확성은 oracle 하니스로 별도 확인.)
    func testDecodeTinyOggEndToEnd() throws {
        let audio = try OggVorbisDecoder.decode(TinyOgg.data)
        XCTAssertEqual(audio.channels, TinyOgg.expectedChannels)
        XCTAssertEqual(audio.sampleRate, TinyOgg.expectedRate)
        XCTAssertLessThanOrEqual(abs(audio.frameCount - TinyOgg.expectedFrames), 128)   // granule 트림 근사
        XCTAssertFalse(audio.samples.contains { $0.isNaN || $0.isInfinite })
        let rms = (audio.samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, audio.samples.count))).squareRoot()
        XCTAssertGreaterThan(rms, 0.01)   // 440Hz 사인 → 비무음
        XCTAssertLessThan(audio.samples.map { abs($0) }.max() ?? 0, 1.01)
    }

    /// naive 와 fast 디코드가 동일 파일에서 수치적으로 일치(fast IMDCT 실경로 회귀).
    func testTinyOggFastEqualsNaive() throws {
        let fast = try OggVorbisDecoder.decode(TinyOgg.data, useFastIMDCT: true)
        let naive = try OggVorbisDecoder.decode(TinyOgg.data, useFastIMDCT: false)
        XCTAssertEqual(fast.samples.count, naive.samples.count)
        var maxDiff: Float = 0
        for i in 0..<min(fast.samples.count, naive.samples.count) { maxDiff = max(maxDiff, abs(fast.samples[i] - naive.samples[i])) }
        XCTAssertLessThan(maxDiff, 1e-3)
    }

    /// 단일 스펙트럼 계수 → windowed 코사인. **stb_vorbis inverse_mdct_slow 공식(π/2N)** 과 직접 대조.
    /// (naive 를 그 공식에 못박아 두어 위상/상수 회귀를 잡는다 — 진짜 검증은 oracle.)
    func testIMDCTSingleCoeffMatchesStbFormula() {
        let n = 256
        var X = [Float](repeating: 0, count: n / 2)
        X[3] = 1.0
        let y = VorbisImdct.naive(X, n)
        for i in stride(from: 0, to: n, by: 17) {
            let expected = cos(Double.pi / Double(2 * n) * Double(2 * i + 1 + n / 2) * Double(2 * 3 + 1))
            XCTAssertEqual(Double(y[i]), expected, accuracy: 1e-4)
        }
    }
}
