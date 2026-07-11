import Foundation

enum VorbisError: Error, Equatable {
    case badHeader(String)
    case unsupported(String)     // 명세 내 미구현 기능(floor0 등) — 명확히 스킵
    case corrupt(String)
}

/// Vorbis 코드북(명세 §3). 스칼라 Huffman 디코드 + (lookup_type 1/2) VQ 벡터 복원.
/// codeword 배정은 stb_vorbis(퍼블릭 도메인) `compute_codewords` 알고리즘을 충실히 재현한다
/// (libvorbis 와 동일한 canonical prefix code 를 얻어야 디코드가 성립).
struct VorbisCodebook {
    let dimensions: Int
    let entries: Int
    let lookupType: Int
    /// VQ 벡터(lookup_type>0). entries*dimensions 평탄 배열. lookup_type 0 이면 비어 있음.
    let vqFlat: [Float]

    // Huffman 디코드 trie(평탄 int 배열). child0/child1 = -1(빈), leaf = -1(내부 노드).
    private let child0: [Int32]
    private let child1: [Int32]
    private let leaf: [Int32]

    /// 스칼라 1개 디코드(Huffman) → entry index. EOP/무효 코드 시 nil.
    func decodeScalar(_ r: inout VorbisBitReader) -> Int? {
        var node: Int32 = 0
        while leaf[Int(node)] < 0 {
            let bit = r.readBit()
            if r.endOfPacket { return nil }
            node = bit == 0 ? child0[Int(node)] : child1[Int(node)]
            if node < 0 { return nil }
        }
        return Int(leaf[Int(node)])
    }

    /// VQ 벡터 시작 오프셋(vqFlat 내). residue 가 dim 개를 연속 접근.
    @inline(__always) func vectorBase(_ entry: Int) -> Int { entry * dimensions }

    // MARK: setup 파싱

    static func parse(_ r: inout VorbisBitReader) throws -> VorbisCodebook {
        // sync pattern 0x564342 ("BCV", 24 bit)
        let sync = r.read(24)
        guard sync == 0x564342 else { throw VorbisError.corrupt("codebook sync \(String(sync, radix: 16))") }
        let dimensions = Int(r.read(16))
        let entries = Int(r.read(24))
        // 곱 상한: multiplicands/vqFlat 이 entries*dimensions 크기 — 미검증 시 거대 할당 폭발(A-B4).
        // 16bit×24bit 라 Int 곱 자체는 안전. 상한값은 기존 entries 상한(1<<24)과 일관.
        guard dimensions > 0, entries > 0, entries <= 1 << 24, dimensions * entries <= 1 << 24 else {
            throw VorbisError.corrupt("codebook dim/entries \(dimensions)/\(entries)")
        }

        // codeword 길이(0 = 미사용)
        var lengths = [Int](repeating: 0, count: entries)
        let ordered = r.readBit() == 1
        if !ordered {
            let sparse = r.readBit() == 1
            for i in 0..<entries {
                if sparse {
                    if r.readBit() == 1 { lengths[i] = Int(r.read(5)) + 1 }   // 아니면 0(미사용)
                } else {
                    lengths[i] = Int(r.read(5)) + 1
                }
            }
        } else {
            var currentEntry = 0
            var currentLength = Int(r.read(5)) + 1
            while currentEntry < entries {
                let bits = ilog(entries - currentEntry)
                let number = Int(r.read(bits))
                guard currentEntry + number <= entries else { throw VorbisError.corrupt("ordered codebook overflow") }
                for j in currentEntry..<currentEntry + number { lengths[j] = currentLength }
                currentEntry += number
                currentLength += 1
            }
        }
        if r.endOfPacket { throw VorbisError.corrupt("EOP in codebook lengths") }

        // Huffman codeword 배정 → trie
        let (child0, child1, leaf) = try buildTrie(lengths: lengths)

        // VQ lookup
        let lookupType = Int(r.read(4))
        var vqFlat: [Float] = []
        if lookupType == 1 || lookupType == 2 {
            let minimumValue = float32Unpack(r.read(32))
            let deltaValue = float32Unpack(r.read(32))
            let valueBits = Int(r.read(4)) + 1
            let sequenceP = r.readBit() == 1
            let lookupValues: Int = (lookupType == 1) ? lookup1Values(entries, dimensions) : entries * dimensions
            var multiplicands = [Double](repeating: 0, count: lookupValues)
            for i in 0..<lookupValues { multiplicands[i] = Double(r.read(valueBits)) }
            if r.endOfPacket { throw VorbisError.corrupt("EOP in codebook VQ") }
            vqFlat = reconstructVQ(entries: entries, dimensions: dimensions, lookupType: lookupType,
                                   minimumValue: minimumValue, deltaValue: deltaValue,
                                   sequenceP: sequenceP, lookupValues: lookupValues, multiplicands: multiplicands)
        } else if lookupType != 0 {
            throw VorbisError.corrupt("codebook lookup type \(lookupType)")
        }

        return VorbisCodebook(dimensions: dimensions, entries: entries, lookupType: lookupType,
                              vqFlat: vqFlat, child0: child0, child1: child1, leaf: leaf)
    }

    // MARK: Huffman trie 빌드 (stb_vorbis compute_codewords 재현)

    static func buildTrie(lengths: [Int]) throws -> (child0: [Int32], child1: [Int32], leaf: [Int32]) {
        let n = lengths.count
        var child0: [Int32] = [-1]; var child1: [Int32] = [-1]; var leaf: [Int32] = [-1]  // root = 0
        func newNode() -> Int32 { child0.append(-1); child1.append(-1); leaf.append(-1); return Int32(child0.count - 1) }
        func insert(codeword: UInt32, len: Int, entry: Int) throws {
            var node: Int32 = 0
            for i in 0..<len {
                let bit = (codeword >> UInt32(i)) & 1
                var next = bit == 0 ? child0[Int(node)] : child1[Int(node)]
                if leaf[Int(node)] >= 0 { throw VorbisError.corrupt("codebook not prefix-free") }
                if next < 0 { next = newNode(); if bit == 0 { child0[Int(node)] = next } else { child1[Int(node)] = next } }
                node = next
            }
            leaf[Int(node)] = Int32(entry)
        }

        // 첫 사용 엔트리
        var k = 0
        while k < n, lengths[k] == 0 { k += 1 }
        if k == n { return (child0, child1, leaf) }   // 전부 미사용

        var available = [UInt32](repeating: 0, count: 33)
        try insert(codeword: bitReverse(0), len: lengths[k], entry: k)
        if lengths[k] < 32 { for i in 1...lengths[k] { available[i] = UInt32(1) << UInt32(32 - i) } }
        else { for i in 1..<32 { available[i] = UInt32(1) << UInt32(32 - i) }; available[32] = 1 }

        var i = k + 1
        while i < n {
            defer { i += 1 }
            let li = lengths[i]
            if li == 0 { continue }
            var z = li
            while z > 0, available[z] == 0 { z -= 1 }
            guard z > 0 else { throw VorbisError.corrupt("over-subscribed codebook") }
            let res = available[z]
            available[z] = 0
            try insert(codeword: bitReverse(res), len: li, entry: i)
            if z != li {
                var y = li
                while y > z { available[y] = res &+ (UInt32(1) << UInt32(32 - y)); y -= 1 }
            }
        }
        return (child0, child1, leaf)
    }

    // MARK: 순수 헬퍼 (직접 테스트 대상)

    /// v^dimensions <= entries 를 만족하는 최대 정수 v(명세 lookup1_values).
    static func lookup1Values(_ entries: Int, _ dimensions: Int) -> Int {
        guard dimensions > 0 else { return 0 }
        var v = 0
        while true {
            let next = v + 1
            var p = 1
            var overflow = false
            for _ in 0..<dimensions {
                p *= next
                if p > entries { overflow = true; break }
            }
            if overflow { break }
            v = next
        }
        return v
    }

    /// Vorbis codebook float32 언팩(명세 9.2.2). mantissa 21bit + exp + sign.
    static func float32Unpack(_ x: UInt32) -> Double {
        let mantissa = Double(x & 0x1fffff)
        let sign = x & 0x80000000
        let exponent = Int((x & 0x7fe00000) >> 21)
        let m = sign != 0 ? -mantissa : mantissa
        return m * pow(2.0, Double(exponent - 788))
    }

    /// entries 개 VQ 벡터(각 dimensions) 복원 → 평탄 배열. lookup_type 1(암시)/2(명시).
    static func reconstructVQ(entries: Int, dimensions: Int, lookupType: Int,
                              minimumValue: Double, deltaValue: Double, sequenceP: Bool,
                              lookupValues: Int, multiplicands: [Double]) -> [Float] {
        var out = [Float](repeating: 0, count: entries * dimensions)
        for e in 0..<entries {
            var last = 0.0
            if lookupType == 1 {
                var indexDivisor = 1
                for j in 0..<dimensions {
                    let off = (e / indexDivisor) % lookupValues
                    let v = multiplicands[off] * deltaValue + minimumValue + last
                    out[e * dimensions + j] = Float(v)
                    if sequenceP { last = v }
                    indexDivisor *= lookupValues
                }
            } else { // lookupType == 2
                let base = e * dimensions
                for j in 0..<dimensions {
                    let v = multiplicands[base + j] * deltaValue + minimumValue + last
                    out[e * dimensions + j] = Float(v)
                    if sequenceP { last = v }
                }
            }
        }
        return out
    }

    /// 32비트 전체 비트 반전(stb_vorbis bit_reverse) — codeword 를 LSB-first 판독형으로.
    static func bitReverse(_ v: UInt32) -> UInt32 {
        var n = v
        n = ((n & 0xAAAAAAAA) >> 1) | ((n & 0x55555555) << 1)
        n = ((n & 0xCCCCCCCC) >> 2) | ((n & 0x33333333) << 2)
        n = ((n & 0xF0F0F0F0) >> 4) | ((n & 0x0F0F0F0F) << 4)
        n = ((n & 0xFF00FF00) >> 8) | ((n & 0x00FF00FF) << 8)
        return (n >> 16) | (n << 16)
    }
}

/// ilog(x) = x 를 표현하는 비트수(명세): x<=0 → 0, else floor(log2(x))+1.
func ilog(_ x: Int) -> Int {
    var v = x, r = 0
    while v > 0 { r += 1; v >>= 1 }
    return r
}
