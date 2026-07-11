import Foundation

/// Vorbis 비트팩 리더 — **LSB-first**(각 바이트의 하위 비트부터, 먼저 읽은 비트가 결과의 LSB).
/// Vorbis I 명세 §2 및 stb_vorbis(퍼블릭 도메인)의 비트 규약을 따른다.
///
/// 패킷 끝을 넘겨 읽으면 `endOfPacket=true` 로 표시하고 0 을 반환한다(마지막 부분 프레임 판정용).
/// 한 패킷(= reassemble 된 논리 패킷) 바이트열 위에서 동작.
struct VorbisBitReader {
    private let bytes: [UInt8]
    private var bytePos: Int = 0
    private var bitPos: Int = 0          // 현재 바이트에서 다음에 읽을 비트(0…7)
    private(set) var endOfPacket = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    /// 남은 비트가 있는지(디버그/루프 종료용).
    var bitsRemaining: Int { max(0, (bytes.count - bytePos) * 8 - bitPos) }

    /// 비트 1개(0/1). 끝을 넘기면 eop + 0.
    mutating func readBit() -> UInt32 {
        if bytePos >= bytes.count { endOfPacket = true; return 0 }
        let bit = (UInt32(bytes[bytePos]) >> UInt32(bitPos)) & 1
        bitPos += 1
        if bitPos == 8 { bitPos = 0; bytePos += 1 }
        return bit
    }

    /// n 비트 정수(0…32). 먼저 읽은 비트가 LSB. 끝을 넘기면 eop + 얻은 만큼(나머지 0).
    mutating func read(_ n: Int) -> UInt32 {
        precondition(n >= 0 && n <= 32)
        var result: UInt32 = 0
        var got = 0
        while got < n {
            if bytePos >= bytes.count { endOfPacket = true; break }
            let avail = 8 - bitPos
            let take = min(avail, n - got)
            let mask: UInt32 = take == 32 ? 0xFFFF_FFFF : (UInt32(1) << UInt32(take)) - 1
            let chunk = (UInt32(bytes[bytePos]) >> UInt32(bitPos)) & mask
            result |= chunk << UInt32(got)
            got += take
            bitPos += take
            if bitPos == 8 { bitPos = 0; bytePos += 1 }
        }
        return result
    }

    /// n 비트 부호 정수(2의 보수). 현재 프로덕션 미사용 — 테스트(OggVorbisDecoderTests)가 규약을 검증.
    mutating func readSigned(_ n: Int) -> Int32 {
        let v = read(n)
        guard n > 0, n < 32 else { return Int32(bitPattern: v) }
        let signBit = UInt32(1) << UInt32(n - 1)
        if v & signBit != 0 { return Int32(bitPattern: v | ~((signBit << 1) - 1)) }
        return Int32(bitPattern: v)
    }
}
