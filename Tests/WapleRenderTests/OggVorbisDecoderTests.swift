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

    // ── 조작 ogg 회귀(S2/S3): fatalError 트랩 = 프로세스 크래시(DoS) 방어 ──────────
    // 아래 스트림들은 손수 프레이밍한 유효 id+comment+setup+audio 로 **실제 decodeResidue 경로에
    // 도달**한다(OggPageReader 는 CRC/버전 미검증이라 합성 가능). 가드 이전엔 프로세스가 abort 했다
    // (`Fatal error: Negative Array...`/`Index out of range`, 수동 확인). 트랩은 throw 가 아니라 프로세스
    // 종료라 XCTAssertThrows 로 못 잡는다 — "크래시 없이 완주"만 검증한다.

    /// S2: residue begin(4096) > end(0) → nRead 음수 → partsToRead 음수 →
    /// `[Int](repeating:0,count: 음수)`(type0/1 경로, 줄 614) 트랩. 가드 후 우아히 반환.
    func testResidueBeginGreaterThanEndDoesNotCrash() {
        let data = makeVorbisOgg(
            setup: setupHeaderPacket(residueType: 0, begin: 4096, end: 0, partitionSize: 1,
                                     classifications: 1, cascade0: 0, book0: 0),
            audio: audioPacketFloorUnused())
        XCTAssertNoThrow(try OggVorbisDecoder.decode(data))
    }

    /// S3(scatter): residue 값 북이 lookupType0(vqFlat 빈) → `vqFlat[base]` OOB(줄 674) 트랩.
    /// type0 이라 decodeVectorScatter 경로. 가드 후 false 전파 → 우아히 반환.
    func testEmptyVQBookScatterDoesNotCrash() {
        let data = makeVorbisOgg(
            setup: setupHeaderPacket(residueType: 0, begin: 0, end: 128, partitionSize: 128,
                                     classifications: 1, cascade0: 1, book0: 0),
            audio: audioPacketFloorUsedThenResidue())
        XCTAssertNoThrow(try OggVorbisDecoder.decode(data))
    }

    /// S3(contig): 동일 결함, type1 → decodeVectorContig 경로(줄 659) 트랩. 가드 후 우아히 반환.
    func testEmptyVQBookContigDoesNotCrash() {
        let data = makeVorbisOgg(
            setup: setupHeaderPacket(residueType: 1, begin: 0, end: 128, partitionSize: 128,
                                     classifications: 1, cascade0: 1, book0: 0),
            audio: audioPacketFloorUsedThenResidue())
        XCTAssertNoThrow(try OggVorbisDecoder.decode(data))
    }

    /// BitWriter 가 실제 리더(VorbisBitReader)와 왕복 일치하는지 — 합성 스트림의 신뢰 근거.
    func testBitWriterRoundTripMatchesReader() {
        var w = BitWriter()
        w.bit(1); w.bits(2, 3); w.bits(0x564342, 24); w.bits(513, 16)
        var r = VorbisBitReader(w.bytes)
        XCTAssertEqual(r.readBit(), 1)
        XCTAssertEqual(r.read(3), 2)
        XCTAssertEqual(r.read(24), 0x564342)      // 코드북 sync 패턴
        XCTAssertEqual(r.read(16), 513)
        // sync 24bit 는 LSB-first 라 바이트열이 42 43 56 여야 리더가 0x564342 로 읽는다.
        var w2 = BitWriter(); w2.bits(0x564342, 24)
        XCTAssertEqual(w2.bytes, [0x42, 0x43, 0x56])
    }
}

// MARK: - 합성 Vorbis/Ogg 빌더(S2/S3 회귀 전용, 이 파일 안에서만)

/// LSB-first 비트 라이터 — VorbisBitReader 의 판독 규약과 정확히 대칭(testBitWriterRoundTrip 로 고정).
private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitPos = 0
    mutating func bit(_ b: UInt32) {
        if bitPos == 0 { bytes.append(0) }
        if b & 1 != 0 { bytes[bytes.count - 1] |= UInt8(1 << bitPos) }
        bitPos = (bitPos + 1) & 7
    }
    mutating func bits(_ v: UInt32, _ n: Int) { for i in 0..<n { bit((v >> UInt32(i)) & 1) } }
}

private let vorbisMagic: [UInt32] = [0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]   // "vorbis"

/// id 헤더(packet 0). 모노 8kHz, blocksize 256/256(0x88). n2 = 128.
private func idHeaderPacket(channels: Int) -> [UInt8] {
    var w = BitWriter()
    w.bits(1, 8); for m in vorbisMagic { w.bits(m, 8) }   // type1 + magic
    w.bits(0, 32)                                          // version 0
    w.bits(UInt32(channels), 8)
    w.bits(8000, 32)                                       // sample rate
    w.bits(0, 32); w.bits(0, 32); w.bits(0, 32)           // bitrate max/nom/min
    w.bits(0x88, 8)                                        // blocksize0/1 = 256/256
    w.bit(1)                                               // framing
    return w.bytes
}

/// comment 헤더(packet 1) — 디코더는 타입(3)+magic 만 검증.
private func commentHeaderPacket() -> [UInt8] {
    var w = BitWriter(); w.bits(3, 8); for m in vorbisMagic { w.bits(m, 8) }; return w.bytes
}

/// setup 헤더(packet 2). 최소 구성: 코드북1(dim1/entries1/lookupType0=빈 vqFlat),
/// floor1(0 파티션), residue1(파라미터), mapping1(모노/무커플링), mode1. residue 필드로 S2/S3 유발.
private func setupHeaderPacket(residueType: Int, begin: Int, end: Int, partitionSize: Int,
                               classifications: Int, cascade0: Int, book0: Int) -> [UInt8] {
    var w = BitWriter()
    w.bits(5, 8); for m in vorbisMagic { w.bits(m, 8) }   // type5 + magic

    // 코드북 1개: sync/dim1/entries1/비ordered·비sparse/len1/lookupType0(vqFlat 빔)
    w.bits(0, 8)                                           // cbCount-1 = 0
    w.bits(0x564342, 24); w.bits(1, 16); w.bits(1, 24)
    w.bit(0); w.bit(0); w.bits(0, 5); w.bits(0, 4)

    w.bits(0, 6); w.bits(0, 16)                            // time transforms: 1개, 값 0

    // floor 1개: type1, 0 파티션(코드북 불요) → xList=[0,1]
    w.bits(0, 6); w.bits(1, 16); w.bits(0, 5); w.bits(0, 2); w.bits(0, 4)

    // residue 1개
    w.bits(0, 6)
    w.bits(UInt32(residueType), 16)
    w.bits(UInt32(begin), 24); w.bits(UInt32(end), 24)
    w.bits(UInt32(partitionSize - 1), 24)
    w.bits(UInt32(classifications - 1), 6)
    w.bits(0, 8)                                           // classbook = 0
    for c in 0..<classifications {                         // cascade
        let casc = c == 0 ? cascade0 : 0
        w.bits(UInt32(casc & 0x7), 3)
        if casc >> 3 != 0 { w.bit(1); w.bits(UInt32(casc >> 3), 5) } else { w.bit(0) }
    }
    for c in 0..<classifications {                         // 각 pass 의 값 북 인덱스
        let casc = c == 0 ? cascade0 : 0
        for j in 0..<8 where (casc & (1 << j)) != 0 { w.bits(UInt32(book0), 8) }
    }

    // mapping 1개: type0, 1 submap, 무커플링, mux 없음
    w.bits(0, 6); w.bits(0, 16); w.bit(0); w.bit(0); w.bits(0, 2)
    w.bits(0, 8); w.bits(0, 8); w.bits(0, 8)               // time/floor/residue idx = 0

    // mode 1개: blockflag0, window0, transform0, mapping0
    w.bits(0, 6); w.bit(0); w.bits(0, 16); w.bits(0, 16); w.bits(0, 8)

    w.bit(1)                                               // framing
    return w.bytes
}

/// 오디오 패킷: floor 미사용(첫 비트 0) → 채널 zero → residue 는 여전히 호출됨(S2 트랩).
private func audioPacketFloorUnused() -> [UInt8] {
    var w = BitWriter()
    w.bit(0)   // 오디오 패킷
    // mode = read(ilog(modeCount-1)) = read(0) → 0비트
    w.bit(0)   // floor1: 미사용
    return w.bytes.isEmpty ? [0] : w.bytes
}

/// 오디오 패킷: floor 사용(0 파티션이라 코드북 디코드 없이 finalY 2개만) → residue 실제 디코드(S3 트랩).
private func audioPacketFloorUsedThenResidue() -> [UInt8] {
    var w = BitWriter()
    w.bit(0)                         // 오디오 패킷
    w.bit(1)                         // floor1: 사용
    w.bits(0, 8); w.bits(0, 8)       // finalY[0], finalY[1] (nbits=ilog(255)=8)
    w.bit(0)                         // classbook.decodeScalar: 1비트(0 → class 0)
    w.bit(0)                         // 값 북 decodeScalar: 1비트(0 → entry 0) → vqFlat OOB
    while w.bytes.count < 4 { w.bit(0) }
    return w.bytes
}

/// Ogg 페이지 1개(단일 세그먼트, body<255). CRC 는 파서가 미검증 → 0.
private func oggPage(_ body: [UInt8], serial: UInt32, seq: UInt32, granule: Int64, headerType: UInt8) -> [UInt8] {
    precondition(body.count < 255)
    var p: [UInt8] = [0x4F, 0x67, 0x67, 0x53, 0, headerType]   // "OggS", version, header type
    let g = UInt64(bitPattern: granule)
    for i in 0..<8 { p.append(UInt8((g >> (8 * UInt64(i))) & 0xFF)) }
    for i in 0..<4 { p.append(UInt8((serial >> (8 * UInt32(i))) & 0xFF)) }
    for i in 0..<4 { p.append(UInt8((seq >> (8 * UInt32(i))) & 0xFF)) }
    p.append(contentsOf: [0, 0, 0, 0])                         // CRC(미검증)
    p.append(1); p.append(UInt8(body.count))                   // nsegs=1, lace
    p.append(contentsOf: body)
    return p
}

/// packet 들을 페이지당 1개로 프레이밍(첫=BOS, 끝=EOS). serial 고정.
private func oggStream(_ packets: [[UInt8]], finalGranule: Int64) -> Data {
    var out: [UInt8] = []
    for (i, pkt) in packets.enumerated() {
        let ht: UInt8 = i == 0 ? 0x02 : (i == packets.count - 1 ? 0x04 : 0x00)
        let gran: Int64 = i == packets.count - 1 ? finalGranule : 0
        out.append(contentsOf: oggPage(pkt, serial: 1, seq: UInt32(i), granule: gran, headerType: ht))
    }
    return Data(out)
}

private func makeVorbisOgg(setup: [UInt8], audio: [UInt8]) -> Data {
    oggStream([idHeaderPacket(channels: 1), commentHeaderPacket(), setup, audio], finalGranule: 480)
}
