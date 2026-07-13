import Foundation

/// 디코드 결과. samples 는 **인터리브** Float PCM(스테레오면 L,R,L,R…), -1…1 근방.
public struct DecodedAudio: Equatable {
    public let samples: [Float]
    public let channels: Int
    public let sampleRate: Int
    /// 채널당 프레임 수.
    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }

    /// 16-bit PCM WAV(RIFF) 바이트. AVAudioPlayer(data:) 로 바로 재생 가능(ogg → 기존 재생 경로 연결점).
    public func pcm16WAV() -> Data {
        let ch = max(1, channels), sr = sampleRate
        let byteRate = sr * ch * 2
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(ch)
        u32(sr); u32(byteRate); u16(ch * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            pcm[i] = Int16(v < 0 ? v * 32768 : v * 32767)
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

/// 순수 Swift Ogg/Vorbis I 디코더(외부 의존성 0). Vorbis I, floor1, residue 0/1/2, 모노/스테레오+.
/// 미지원(floor0 등)은 VorbisError 로 명확히 스킵. 알고리즘 근거: Vorbis I 명세 + stb_vorbis(퍼블릭 도메인).
public enum OggVorbisDecoder {
    /// Ogg 컨테이너에서 Vorbis 스트림을 디코드해 인터리브 PCM 반환.
    /// - useFastIMDCT: true=FFT 기반(기본, 실사용), false=naive(검증 기준).
    public static func decode(_ data: Data, useFastIMDCT: Bool = true) throws -> DecodedAudio {
        let ogg = try OggPageReader.parse(data)
        let stream = try VorbisStream(packets: ogg.packets, useFastIMDCT: useFastIMDCT)
        return try stream.decodeAll(finalGranule: ogg.finalGranule)
    }
}

// MARK: - 설정 구조

private struct Floor1Config {
    var partitions = 0
    var partitionClassList: [Int] = []
    var classDimensions: [Int] = []
    var classSubclasses: [Int] = []
    var classMasterbooks: [Int] = []
    var subclassBooks: [[Int]] = []
    var multiplier = 1
    var values = 0
    var xList: [Int] = []
    var sortedOrder: [Int] = []
    var neighborsLow: [Int] = []
    var neighborsHigh: [Int] = []
}

private struct ResidueConfig {
    var type = 0
    var begin = 0
    var end = 0
    var partitionSize = 1
    var classifications = 1
    var classbook = 0
    var books: [[Int]] = []     // [classification][8], -1 = 없음
}

private struct MappingConfig {
    var submaps = 1
    var couplingMag: [Int] = []
    var couplingAng: [Int] = []
    var mux: [Int] = []          // channel → submap
    var submapFloor: [Int] = []
    var submapResidue: [Int] = []
}

private struct ModeConfig {
    var blockflag = false
    var mapping = 0
}

// MARK: - Vorbis 스트림

private final class VorbisStream {
    let channels: Int
    let sampleRate: Int
    let blocksize0: Int
    let blocksize1: Int
    let useFastIMDCT: Bool

    private var codebooks: [VorbisCodebook] = []
    private var floorTypes: [Int] = []
    private var floors: [Floor1Config] = []
    private var residues: [ResidueConfig] = []
    private var mappings: [MappingConfig] = []
    private var modes: [ModeConfig] = []
    private let audioPackets: ArraySlice<[UInt8]>

    // IMDCT/윈도 캐시
    private var fftPlans: [Int: FFTPlan] = [:]
    private var windowCache: [Int: [Float]] = [:]

    init(packets: [[UInt8]], useFastIMDCT: Bool) throws {
        guard packets.count >= 3 else { throw VorbisError.badHeader("need 3 header packets, got \(packets.count)") }
        self.useFastIMDCT = useFastIMDCT
        self.audioPackets = packets[3...]

        // 1) identification header
        var r0 = VorbisBitReader(packets[0])
        try Self.expectHeaderType(&r0, 1)
        let version = r0.read(32)
        guard version == 0 else { throw VorbisError.unsupported("vorbis version \(version)") }
        channels = Int(r0.read(8))
        sampleRate = Int(r0.read(32))
        _ = r0.read(32); _ = r0.read(32); _ = r0.read(32)   // bitrate max/nom/min (무시)
        let bsByte = r0.read(8)
        blocksize0 = 1 << (Int(bsByte) & 0x0F)
        blocksize1 = 1 << (Int(bsByte) >> 4)
        guard channels >= 1, sampleRate > 0,
              blocksize0 >= 64, blocksize1 >= blocksize0, blocksize1 <= 8192 else {
            throw VorbisError.badHeader("id header ch=\(channels) sr=\(sampleRate) bs=\(blocksize0)/\(blocksize1)")
        }
        _ = r0.readBit()   // framing

        // 2) comment header — 타입만 검증, 내용 스킵
        var r1 = VorbisBitReader(packets[1])
        try Self.expectHeaderType(&r1, 3)

        // 3) setup header
        var r2 = VorbisBitReader(packets[2])
        try Self.expectHeaderType(&r2, 5)
        try parseSetup(&r2)
    }

    private static func expectHeaderType(_ r: inout VorbisBitReader, _ type: UInt32) throws {
        let t = r.read(8)
        let v = [r.read(8), r.read(8), r.read(8), r.read(8), r.read(8), r.read(8)]
        guard t == type, v == [0x76, 0x6F, 0x72, 0x62, 0x69, 0x73] else {   // "vorbis"
            throw VorbisError.badHeader("header type \(t) magic mismatch")
        }
    }

    // MARK: setup 파싱

    private func parseSetup(_ r: inout VorbisBitReader) throws {
        // 코드북
        let cbCount = Int(r.read(8)) + 1
        codebooks.reserveCapacity(cbCount)
        // 코드북 개별 상한(2^24 셀)만으로는 256개 합산 시 수십 GB — 총량도 같은 상한으로 캡(OOM 방어).
        var totalCells = 0
        for _ in 0..<cbCount {
            let book = try VorbisCodebook.parse(&r)
            totalCells += book.entries * max(1, book.dimensions)
            guard totalCells <= 1 << 24 else { throw VorbisError.corrupt("codebooks total size \(totalCells)") }
            codebooks.append(book)
        }

        // time domain transforms (placeholder, 전부 0)
        let timeCount = Int(r.read(6)) + 1
        for _ in 0..<timeCount { guard r.read(16) == 0 else { throw VorbisError.corrupt("time transform != 0") } }

        // floors
        let floorCount = Int(r.read(6)) + 1
        for _ in 0..<floorCount {
            let type = Int(r.read(16))
            floorTypes.append(type)
            if type == 1 { floors.append(try parseFloor1(&r)) }
            else if type == 0 { throw VorbisError.unsupported("floor0 (LSP) — 코퍼스 미사용, 스킵") }
            else { throw VorbisError.corrupt("floor type \(type)") }
        }

        // residues
        let residueCount = Int(r.read(6)) + 1
        for _ in 0..<residueCount { residues.append(try parseResidue(&r)) }

        // mappings
        let mappingCount = Int(r.read(6)) + 1
        for _ in 0..<mappingCount { mappings.append(try parseMapping(&r)) }

        // modes
        let modeCount = Int(r.read(6)) + 1
        for _ in 0..<modeCount {
            var m = ModeConfig()
            m.blockflag = r.readBit() == 1
            guard r.read(16) == 0 else { throw VorbisError.corrupt("window type != 0") }
            guard r.read(16) == 0 else { throw VorbisError.corrupt("transform type != 0") }
            m.mapping = Int(r.read(8))
            guard m.mapping < mappings.count else { throw VorbisError.corrupt("mode mapping oob") }
            modes.append(m)
        }
        guard r.readBit() == 1 else { throw VorbisError.corrupt("setup framing bit") }
        if r.endOfPacket { throw VorbisError.corrupt("EOP in setup") }
    }

    private func parseFloor1(_ r: inout VorbisBitReader) throws -> Floor1Config {
        var f = Floor1Config()
        f.partitions = Int(r.read(5))
        var maxClass = -1
        f.partitionClassList = (0..<f.partitions).map { _ in Int(r.read(4)) }
        for c in f.partitionClassList { maxClass = max(maxClass, c) }
        f.classDimensions = [Int](repeating: 0, count: maxClass + 1)
        f.classSubclasses = [Int](repeating: 0, count: maxClass + 1)
        f.classMasterbooks = [Int](repeating: 0, count: maxClass + 1)
        f.subclassBooks = [[Int]](repeating: [], count: maxClass + 1)
        for i in 0...max(0, maxClass) where maxClass >= 0 {
            f.classDimensions[i] = Int(r.read(3)) + 1
            f.classSubclasses[i] = Int(r.read(2))
            if f.classSubclasses[i] > 0 {
                f.classMasterbooks[i] = Int(r.read(8))
                // 손상 스트림의 masterbook OOB → decodeFloor1 트랩 방지(residue classbook 검증과 동형)
                guard f.classMasterbooks[i] < codebooks.count else { throw VorbisError.corrupt("floor1 masterbook oob") }
            }
            let sub = 1 << f.classSubclasses[i]
            f.subclassBooks[i] = try (0..<sub).map { _ in
                let b = Int(r.read(8)) - 1   // -1 = 책 없음(허용)
                guard b < codebooks.count else { throw VorbisError.corrupt("floor1 subclass book oob") }
                return b
            }
        }
        f.multiplier = Int(r.read(2)) + 1
        let rangebits = Int(r.read(4))
        var xList = [0, 1 << rangebits]
        for i in 0..<f.partitions {
            let cdim = f.classDimensions[f.partitionClassList[i]]
            for _ in 0..<cdim { xList.append(Int(r.read(rangebits))) }
        }
        f.xList = xList
        f.values = xList.count
        guard f.values <= 65 else { throw VorbisError.corrupt("floor1 values \(f.values)") }
        // sorted order + neighbors 사전계산
        f.sortedOrder = Array(0..<f.values).sorted { xList[$0] < xList[$1] }
        // X 중복은 명세 §7.2.2 상 undecodable — neighbor 부재(-1 인덱스)·predictPoint 0나눗셈의 근원을 여기서 차단
        for q in 1..<f.values where xList[f.sortedOrder[q]] == xList[f.sortedOrder[q - 1]] {
            throw VorbisError.corrupt("floor1 xList duplicate")
        }
        f.neighborsLow = [Int](repeating: 0, count: f.values)
        f.neighborsHigh = [Int](repeating: 0, count: f.values)
        for j in 0..<f.values {
            var low = -1, lowVal = -1, high = -1, highVal = Int.max
            for i in 0..<j {
                if xList[i] > lowVal && xList[i] < xList[j] { low = i; lowVal = xList[i] }
                if xList[i] < highVal && xList[i] > xList[j] { high = i; highVal = xList[i] }
            }
            f.neighborsLow[j] = low; f.neighborsHigh[j] = high
        }
        if r.endOfPacket { throw VorbisError.corrupt("EOP in floor1 header") }
        return f
    }

    private func parseResidue(_ r: inout VorbisBitReader) throws -> ResidueConfig {
        var res = ResidueConfig()
        res.type = Int(r.read(16))
        guard res.type <= 2 else { throw VorbisError.corrupt("residue type \(res.type)") }
        res.begin = Int(r.read(24))
        res.end = Int(r.read(24))
        res.partitionSize = Int(r.read(24)) + 1
        res.classifications = Int(r.read(6)) + 1
        res.classbook = Int(r.read(8))
        guard res.classbook < codebooks.count else { throw VorbisError.corrupt("residue classbook oob") }
        var cascade = [Int](repeating: 0, count: res.classifications)
        for i in 0..<res.classifications {
            var highBits = 0
            let lowBits = Int(r.read(3))
            let bitflag = r.readBit() == 1
            if bitflag { highBits = Int(r.read(5)) }
            cascade[i] = highBits * 8 + lowBits
        }
        res.books = [[Int]](repeating: [Int](repeating: -1, count: 8), count: res.classifications)
        for i in 0..<res.classifications {
            for j in 0..<8 where (cascade[i] & (1 << j)) != 0 {
                let b = Int(r.read(8))
                guard b < codebooks.count else { throw VorbisError.corrupt("residue book oob") }
                res.books[i][j] = b
            }
        }
        if r.endOfPacket { throw VorbisError.corrupt("EOP in residue header") }
        return res
    }

    private func parseMapping(_ r: inout VorbisBitReader) throws -> MappingConfig {
        var m = MappingConfig()
        guard r.read(16) == 0 else { throw VorbisError.corrupt("mapping type != 0") }
        m.submaps = r.readBit() == 1 ? Int(r.read(4)) + 1 : 1
        if r.readBit() == 1 {
            let steps = Int(r.read(8)) + 1
            let bits = ilog(channels - 1)
            for _ in 0..<steps {
                let mag = Int(r.read(bits)); let ang = Int(r.read(bits))
                guard mag != ang, mag < channels, ang < channels else { throw VorbisError.corrupt("coupling ch oob") }
                m.couplingMag.append(mag); m.couplingAng.append(ang)
            }
        }
        guard r.read(2) == 0 else { throw VorbisError.corrupt("mapping reserved != 0") }
        if m.submaps > 1 {
            m.mux = (0..<channels).map { _ in Int(r.read(4)) }
            for v in m.mux { guard v < m.submaps else { throw VorbisError.corrupt("mux oob") } }
        } else {
            m.mux = [Int](repeating: 0, count: channels)
        }
        for _ in 0..<m.submaps {
            _ = r.read(8)   // time placeholder (무시)
            let floorIdx = Int(r.read(8)); let resIdx = Int(r.read(8))
            guard floorIdx < floorTypes.count, resIdx < residues.count else {
                throw VorbisError.corrupt("mapping floor/residue oob")
            }
            m.submapFloor.append(floorIdx); m.submapResidue.append(resIdx)
        }
        if r.endOfPacket { throw VorbisError.corrupt("EOP in mapping header") }
        return m
    }

    // MARK: 전체 디코드

    func decodeAll(finalGranule: Int64) throws -> DecodedAudio {
        var output = [[Float]](repeating: [], count: channels)
        // granulepos 는 파일 제어값 — 실제 산출 가능한 최대 프레임 수(패킷수×최대블록)로 clamp(거대 예약 방지).
        let frameCapacity = min(max(0, Int(clamping: finalGranule)), audioPackets.count * blocksize1)
        for ch in 0..<channels { output[ch].reserveCapacity(frameCapacity) }

        var prevWindow = [[Float]](repeating: [], count: channels)
        var prevLength = 0

        for packet in audioPackets {
            var r = VorbisBitReader(packet)
            guard r.readBit() == 0 else { continue }   // 오디오 패킷이 아님(헤더류) → 스킵
            let modeNumber = Int(r.read(ilog(modes.count - 1)))
            // 무효 mode·EOP(런트 패킷 — 어차피 그 패킷엔 더 읽을 게 없음)는 해당 패킷만 버림. break 는 정상 트랙을 절단(A-B5)
            if r.endOfPacket || modeNumber >= modes.count { continue }
            let mode = modes[modeNumber]
            let blockflag = mode.blockflag
            let n = blockflag ? blocksize1 : blocksize0
            let n2 = n / 2
            var prevFlag = true, nextFlag = true
            if blockflag { prevFlag = r.readBit() == 1; nextFlag = r.readBit() == 1 }
            let (leftStart, leftEnd, rightStart, rightEnd) = windowBounds(n: n, blockflag: blockflag, prev: prevFlag, next: nextFlag)

            let map = mappings[mode.mapping]

            // 채널 스펙트럼 버퍼(n2). floor → residue → coupling → floor곱 → IMDCT.
            var chBuf = [[Float]](repeating: [Float](repeating: 0, count: n2), count: channels)
            var zeroChannel = [Bool](repeating: false, count: channels)
            var finalYs = [[Int]?](repeating: nil, count: channels)

            // FLOOR
            var floorEOP = false
            for ch in 0..<channels {
                let floorIdx = map.submapFloor[map.mux[ch]]
                let (used, fy, eop) = decodeFloor1(floors[floorIndexToConfig(floorIdx)], &r)
                if eop { floorEOP = true; break }
                if used { finalYs[ch] = fy } else { zeroChannel[ch] = true }
            }
            // EOP 는 해당 패킷만 폐기(참조 구현 동작) — break 는 손상 패킷 1개로 이후 트랙 전부 절단.
            if floorEOP { continue }

            // 커플드 채널 재활성(둘 중 하나라도 살아있으면 둘 다 디코드)
            let reallyZero = zeroChannel
            for s in 0..<map.couplingMag.count {
                let mg = map.couplingMag[s], an = map.couplingAng[s]
                if !zeroChannel[mg] || !zeroChannel[an] { zeroChannel[mg] = false; zeroChannel[an] = false }
            }

            // RESIDUE (submap 별)
            for sm in 0..<map.submaps {
                var chans: [Int] = []
                for ch in 0..<channels where map.mux[ch] == sm { chans.append(ch) }
                if chans.isEmpty { continue }
                let dnd = chans.map { zeroChannel[$0] }
                decodeResidue(residues[map.submapResidue[sm]], &chBuf, chans: chans, doNotDecode: dnd, n2: n2, &r)
            }

            // INVERSE COUPLING (역순)
            for s in stride(from: map.couplingMag.count - 1, through: 0, by: -1) {
                let mg = map.couplingMag[s], an = map.couplingAng[s]
                for j in 0..<n2 {
                    let mv = chBuf[mg][j], av = chBuf[an][j]
                    var m2: Float, a2: Float
                    if mv > 0 {
                        if av > 0 { m2 = mv; a2 = mv - av } else { a2 = mv; m2 = mv + av }
                    } else {
                        if av > 0 { m2 = mv; a2 = mv + av } else { a2 = mv; m2 = mv - av }
                    }
                    chBuf[mg][j] = m2; chBuf[an][j] = a2
                }
            }

            // FLOOR 곱(마감) + IMDCT
            var timeBuf = [[Float]](repeating: [], count: channels)
            for ch in 0..<channels {
                if reallyZero[ch] {
                    chBuf[ch] = [Float](repeating: 0, count: n2)
                } else if let fy = finalYs[ch] {
                    let floorIdx = map.submapFloor[map.mux[ch]]
                    let curve = renderFloor1(floors[floorIndexToConfig(floorIdx)], fy, n2)
                    for j in 0..<n2 { chBuf[ch][j] *= curve[j] }
                }
                timeBuf[ch] = imdct(chBuf[ch], n: n)
            }

            // OVERLAP-ADD (vorbis_finish_frame)
            let len = rightEnd
            if prevLength > 0 {
                let w = window(prevLength)
                for ch in 0..<channels {
                    let pw = prevWindow[ch]
                    let lim = min(prevLength, pw.count, n - leftStart)
                    for j in 0..<lim {
                        timeBuf[ch][leftStart + j] = timeBuf[ch][leftStart + j] * w[j] + pw[j] * w[prevLength - 1 - j]
                    }
                }
            }
            let hadPrev = prevLength > 0
            // 다음 프레임용 오른쪽 저장
            let saveCount = len - rightStart
            var newPrev = [[Float]](repeating: [], count: channels)
            for ch in 0..<channels { newPrev[ch] = Array(timeBuf[ch][rightStart..<rightStart + saveCount]) }
            if hadPrev {
                for ch in 0..<channels { output[ch].append(contentsOf: timeBuf[ch][leftStart..<rightStart]) }
            }
            prevWindow = newPrev
            prevLength = saveCount
        }

        // 인터리브 + granule 기준 후행 트림
        var frames = output.map { $0.count }.min() ?? 0
        if finalGranule > 0 && Int(finalGranule) < frames { frames = Int(finalGranule) }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for ch in 0..<channels {
            let src = output[ch]
            for i in 0..<frames { interleaved[i * channels + ch] = src[i] }
        }
        return DecodedAudio(samples: interleaved, channels: channels, sampleRate: sampleRate)
    }

    /// floorIdx(글로벌 floor 번호) → floors 배열 인덱스. 코퍼스는 전부 floor1 이라 동일하지만,
    /// floor 목록에 floor0 이 섞이면 parse 단계에서 이미 throw(unsupported)했으므로 여기 도달 시 1:1.
    private func floorIndexToConfig(_ idx: Int) -> Int { idx }

    private func windowBounds(n: Int, blockflag: Bool, prev: Bool, next: Bool) -> (Int, Int, Int, Int) {
        let center = n / 2
        let ls: Int, le: Int, rs: Int, re: Int
        if blockflag && !prev { ls = (n - blocksize0) >> 2; le = (n + blocksize0) >> 2 } else { ls = 0; le = center }
        if blockflag && !next { rs = (n * 3 - blocksize0) >> 2; re = (n * 3 + blocksize0) >> 2 } else { rs = center; re = n }
        return (ls, le, rs, re)
    }

    // MARK: floor1 디코드/합성

    private func decodeFloor1(_ f: Floor1Config, _ r: inout VorbisBitReader) -> (used: Bool, finalY: [Int], eop: Bool) {
        guard r.readBit() == 1 else { return (false, [], false) }
        let rangeTable = [256, 128, 86, 64]
        let range = rangeTable[f.multiplier - 1]
        // 명세 §7.2.3: ilog(range-1) 비트. 2의 거듭제곱 range 는 ilog(range)-1 과 동치지만
        // range 86(multiplier 3)은 7비트가 맞다(ilog(86)-1=6 은 0..85 표현 불가 — 오디코드).
        let nbits = ilog(range - 1)
        var finalY = [Int](repeating: 0, count: f.values)
        finalY[0] = Int(r.read(nbits))
        finalY[1] = Int(r.read(nbits))
        var offset = 2
        for i in 0..<f.partitions {
            let pclass = f.partitionClassList[i]
            let cdim = f.classDimensions[pclass]
            let cbits = f.classSubclasses[pclass]
            let csub = (1 << cbits) - 1
            var cval = 0
            if cbits > 0 {
                guard let v = codebooks[f.classMasterbooks[pclass]].decodeScalar(&r) else { return (false, [], true) }
                cval = v
            }
            for _ in 0..<cdim {
                let book = f.subclassBooks[pclass][cval & csub]
                cval >>= cbits
                if book >= 0 {
                    guard let temp = codebooks[book].decodeScalar(&r) else { return (false, [], true) }
                    finalY[offset] = temp
                } else { finalY[offset] = 0 }
                offset += 1
            }
        }
        if r.endOfPacket { return (false, [], true) }
        // step2 unwrap
        var step2 = [Bool](repeating: false, count: f.values)
        step2[0] = true; step2[1] = true
        for j in 2..<f.values {
            let low = f.neighborsLow[j], high = f.neighborsHigh[j]
            let pred = predictPoint(f.xList[j], f.xList[low], f.xList[high], finalY[low], finalY[high])
            let val = finalY[j]
            let highroom = range - pred
            let lowroom = pred
            let room = (highroom < lowroom) ? highroom * 2 : lowroom * 2
            if val != 0 {
                step2[low] = true; step2[high] = true; step2[j] = true
                if val >= room {
                    finalY[j] = (highroom > lowroom) ? (val - lowroom + pred) : (pred - val + highroom - 1)
                } else {
                    finalY[j] = (val & 1 != 0) ? (pred - ((val + 1) >> 1)) : (pred + (val >> 1))
                }
            } else {
                step2[j] = false
                finalY[j] = pred
            }
        }
        for j in 0..<f.values where !step2[j] { finalY[j] = -1 }   // defer: 미활성 점 표시
        return (true, finalY, false)
    }

    private func predictPoint(_ x: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Int {
        let dy = y1 - y0, adx = x1 - x0
        let off = (abs(dy) * (x - x0)) / adx
        return dy < 0 ? y0 - off : y0 + off
    }

    private func renderFloor1(_ f: Floor1Config, _ finalY: [Int], _ n2: Int) -> [Float] {
        var target = [Float](repeating: 0, count: n2)
        var lx = 0
        var ly = finalY[0] * f.multiplier
        for q in 1..<f.values {
            let j = f.sortedOrder[q]
            if finalY[j] >= 0 {
                let hy = finalY[j] * f.multiplier
                let hx = f.xList[j]
                if lx != hx { drawLine(&target, lx, ly, hx, hy, n2) }
                lx = hx; ly = hy
            }
        }
        if lx < n2 {
            let v = vorbisInverseDBTable[min(255, max(0, ly))]
            for j in lx..<n2 { target[j] = v }
        }
        return target
    }

    /// Bresenham 정수 라인. target[x] = inverse_dB[y&255](대입). 명세가 요구하는 정확한 연산열.
    private func drawLine(_ output: inout [Float], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ n: Int) {
        let dy = y1 - y0
        let adx = x1 - x0
        var ady = abs(dy)
        let base = dy / adx
        let sy = dy < 0 ? base - 1 : base + 1
        ady -= abs(base) * adx
        var x = x0, y = y0
        var err = 0
        var xend = x1
        if xend > n { xend = n }
        if x < xend {
            output[x] = vorbisInverseDBTable[y & 255]
            x += 1
            while x < xend {
                err += ady
                if err >= adx { err -= adx; y += sy } else { y += base }
                output[x] = vorbisInverseDBTable[y & 255]
                x += 1
            }
        }
    }

    // MARK: residue 디코드

    private func decodeResidue(_ res: ResidueConfig, _ chBuf: inout [[Float]], chans: [Int], doNotDecode: [Bool], n2: Int, _ r: inout VorbisBitReader) {
        let ch = chans.count
        let classbook = codebooks[res.classbook]
        let classwords = classbook.dimensions
        let nClass = res.classifications

        // 디코드 대상 채널 버퍼 0으로
        for k in 0..<ch where !doNotDecode[k] { for j in 0..<n2 { chBuf[chans[k]][j] = 0 } }

        if res.type == 2 && ch > 1 {
            if doNotDecode.allSatisfy({ $0 }) { return }
            let vlen = n2 * ch
            let rbegin = min(res.begin, vlen)
            let rend = min(res.end, vlen)
            let nRead = rend - rbegin
            let partsToRead = res.partitionSize > 0 ? nRead / res.partitionSize : 0
            // begin>end(미검증 24bit) → nRead 음수 → partsToRead 음수. <=0 로 막지 않으면
            // 아래 count 가 음수라 트랩. 우아히 반환 = 잔차 없음(채널 버퍼 0 유지)이라 정합.
            if partsToRead <= 0 { return }
            var V = [Float](repeating: 0, count: vlen)
            var cls = [Int](repeating: 0, count: partsToRead + classwords)
            for pass in 0..<8 {
                var pcount = 0
                while pcount < partsToRead {
                    if pass == 0 {
                        guard let q = classbook.decodeScalar(&r) else { deinterleave(V, chBuf: &chBuf, chans: chans, ch: ch, n2: n2); return }
                        var temp = q
                        var tmp = [Int](repeating: 0, count: classwords)
                        for i in stride(from: classwords - 1, through: 0, by: -1) { tmp[i] = temp % nClass; temp /= nClass }
                        for i in 0..<classwords where pcount + i < partsToRead { cls[pcount + i] = tmp[i] }
                    }
                    var i = 0
                    while i < classwords && pcount < partsToRead {
                        let b = res.books[cls[pcount]][pass]
                        if b >= 0 {
                            let offset = rbegin + pcount * res.partitionSize
                            if !decodeVectorContig(codebooks[b], &V, offset, res.partitionSize, &r) {
                                deinterleave(V, chBuf: &chBuf, chans: chans, ch: ch, n2: n2); return
                            }
                        }
                        i += 1; pcount += 1
                    }
                }
            }
            deinterleave(V, chBuf: &chBuf, chans: chans, ch: ch, n2: n2)
            return
        }

        // type 0/1 (및 type2+mono → contig)
        let rbegin = min(res.begin, n2)
        let rend = min(res.end, n2)
        let nRead = rend - rbegin
        let partsToRead = res.partitionSize > 0 ? nRead / res.partitionSize : 0
        // begin>end → partsToRead 음수 → 아래 count(partsToRead+classwords) 음수 트랩. type2 사이트와 동형.
        if partsToRead <= 0 { return }
        var cls = [[Int]](repeating: [Int](repeating: 0, count: partsToRead + classwords), count: ch)
        for pass in 0..<8 {
            var pcount = 0
            while pcount < partsToRead {
                if pass == 0 {
                    for k in 0..<ch where !doNotDecode[k] {
                        guard let q = classbook.decodeScalar(&r) else { return }
                        var temp = q
                        var tmp = [Int](repeating: 0, count: classwords)
                        for i in stride(from: classwords - 1, through: 0, by: -1) { tmp[i] = temp % nClass; temp /= nClass }
                        for i in 0..<classwords where pcount + i < partsToRead { cls[k][pcount + i] = tmp[i] }
                    }
                }
                var i = 0
                while i < classwords && pcount < partsToRead {
                    for k in 0..<ch where !doNotDecode[k] {
                        let b = res.books[cls[k][pcount]][pass]
                        if b >= 0 {
                            let offset = rbegin + pcount * res.partitionSize
                            let ok = res.type == 0
                                ? decodeVectorScatter(codebooks[b], &chBuf[chans[k]], offset, res.partitionSize, &r)
                                : decodeVectorContig(codebooks[b], &chBuf[chans[k]], offset, res.partitionSize, &r)
                            if !ok { return }
                        }
                    }
                    i += 1; pcount += 1
                }
            }
        }
    }

    private func deinterleave(_ V: [Float], chBuf: inout [[Float]], chans: [Int], ch: Int, n2: Int) {
        for p in 0..<V.count {
            let c = p % ch, idx = p / ch
            if idx < n2 { chBuf[chans[c]][idx] = V[p] }
        }
    }

    /// type 1/2: 코드북 벡터를 연속 배치(+=). EOP 시 false.
    private func decodeVectorContig(_ book: VorbisCodebook, _ buf: inout [Float], _ offset: Int, _ n: Int, _ r: inout VorbisBitReader) -> Bool {
        // VQ 테이블 없는 책(lookupType0)은 벡터 기여 불가 → vqFlat[..] OOB 트랩 대신 EOP형 실패로 처리.
        guard !book.vqFlat.isEmpty else { return false }
        let dim = book.dimensions
        var k = 0, off = offset
        while k < n {
            guard let entry = book.decodeScalar(&r) else { return false }
            let base = book.vectorBase(entry)
            for d in 0..<dim { if off < buf.count { buf[off] += book.vqFlat[base + d] }; off += 1 }
            k += dim
        }
        return true
    }

    /// type 0: step=n/dim 회 읽어 dim 값을 stride=step 로 산포(+=). EOP 시 false.
    private func decodeVectorScatter(_ book: VorbisCodebook, _ buf: inout [Float], _ offset: Int, _ n: Int, _ r: inout VorbisBitReader) -> Bool {
        // VQ 테이블 없는 책(lookupType0)은 벡터 기여 불가 → vqFlat[..] OOB 트랩 대신 EOP형 실패로 처리.
        guard !book.vqFlat.isEmpty else { return false }
        let dim = book.dimensions
        let step = n / dim
        for s in 0..<step {
            guard let entry = book.decodeScalar(&r) else { return false }
            let base = book.vectorBase(entry)
            for d in 0..<dim {
                let pos = offset + s + d * step
                if pos < buf.count { buf[pos] += book.vqFlat[base + d] }
            }
        }
        return true
    }

    // MARK: IMDCT / 윈도

    private func imdct(_ spectrum: [Float], n: Int) -> [Float] {
        if useFastIMDCT {
            let plan = fftPlans[n] ?? { let p = FFTPlan(n); fftPlans[n] = p; return p }()   // DCT-IV(N/2)=2·(N/2)=N 점
            return VorbisImdct.fast(spectrum, n, plan)
        }
        return VorbisImdct.naive(spectrum, n)
    }

    /// 오버랩 윈도(길이 L, 상승 0→1). w[i]=sin(π/2·sin²((i+½)/(2L)·π)). w[i]²+w[L-1-i]²=1(완전복원).
    private func window(_ L: Int) -> [Float] {
        if let w = windowCache[L] { return w }
        var w = [Float](repeating: 0, count: L)
        for i in 0..<L {
            let inner = sin((Double(i) + 0.5) / Double(2 * L) * Double.pi)
            w[i] = Float(sin(Double.pi / 2 * inner * inner))
        }
        windowCache[L] = w
        return w
    }
}
