import Foundation

enum OggError: Error, Equatable {
    case notOgg
    case truncated
    case noPackets
    case corrupt(String)   // F563: 페이지 메타(버전/시퀀스/continued) 검증 실패
}

/// Ogg 컨테이너 파서 — 페이지를 논리 패킷으로 재조립한다(Vorbis I 명세 §2 / RFC 3533).
/// 첫 페이지의 스트림 serial 에 고정해 그 스트림의 패킷만 뽑는다.
/// (코퍼스의 사운드 참조 ogg 는 전부 단일 Vorbis 스트림. ponytail: 다중화(theora+vorbis)
///  muxed 파일은 첫 스트림만 — 참조 사운드엔 없음. 필요 시 serial 스캔으로 확장.)
struct OggPageReader {
    /// 재조립된 논리 패킷들(첫 스트림).
    let packets: [[UInt8]]
    /// 마지막 페이지 granulepos(Vorbis 는 채널당 총 출력 샘플 위치) — 샘플수 정합 검증용.
    let finalGranule: Int64

    static func parse(_ data: Data) throws -> OggPageReader {
        let b = [UInt8](data)
        guard b.count >= 27, b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 else {
            throw OggError.notOgg
        }
        var pos = 0
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var streamSerial: UInt32? = nil
        var expectedSeq: UInt32? = nil   // F563: 대상 스트림의 기대 페이지 시퀀스
        var finalGranule: Int64 = 0

        while pos + 27 <= b.count {
            // capture pattern
            guard b[pos] == 0x4F, b[pos+1] == 0x67, b[pos+2] == 0x67, b[pos+3] == 0x53 else {
                throw OggError.truncated   // 페이지 경계 어긋남
            }
            let granule = Int64(bitPattern:
                UInt64(b[pos+6]) | UInt64(b[pos+7]) << 8 | UInt64(b[pos+8]) << 16 | UInt64(b[pos+9]) << 24 |
                UInt64(b[pos+10]) << 32 | UInt64(b[pos+11]) << 40 | UInt64(b[pos+12]) << 48 | UInt64(b[pos+13]) << 56)
            let serial = UInt32(b[pos+14]) | UInt32(b[pos+15]) << 8 | UInt32(b[pos+16]) << 16 | UInt32(b[pos+17]) << 24
            let nsegs = Int(b[pos+26])
            let segTableStart = pos + 27
            guard segTableStart + nsegs <= b.count else { throw OggError.truncated }
            var bodySize = 0
            for i in 0..<nsegs { bodySize += Int(b[segTableStart + i]) }
            let bodyStart = segTableStart + nsegs
            guard bodyStart + bodySize <= b.count else { throw OggError.truncated }

            // F563: 페이지 메타 최소 검증 — 버전 바이트/시퀀스/continued 플래그. 손상·유실 페이지가
            // 이질 데이터를 한 패킷으로 접합해 무음 아닌 잘못된 오디오를 내는 것을 오류로 표면화한다.
            // (CRC 는 의도적으로 미검사: 배포 fixture(TinyOgg)조차 저장 CRC 가 깨져 있어(ffprobe 확인)
            //  엄격 검사 시 디코드 가능한 실전 파일을 거부하게 된다 — 접합 오류는 시퀀스/continued 로 차단.)
            guard b[pos+4] == 0 else { throw OggError.corrupt("ogg stream version \(b[pos+4])") }

            if streamSerial == nil { streamSerial = serial }
            let isTargetStream = (serial == streamSerial)

            if isTargetStream {
                // continued 플래그는 직전 페이지 말미의 미완 패킷(current 비어있지 않음)과 정확히 대응해야 한다.
                let continued = (b[pos+5] & 1) != 0
                guard continued == !current.isEmpty else {
                    throw OggError.corrupt("ogg continuation flag mismatch")
                }
                let seq = UInt32(b[pos+18]) | UInt32(b[pos+19]) << 8 | UInt32(b[pos+20]) << 16 | UInt32(b[pos+21]) << 24
                if let expected = expectedSeq {
                    guard seq == expected else { throw OggError.corrupt("ogg page sequence gap") }
                }
                expectedSeq = seq &+ 1
                if granule >= 0 { finalGranule = granule }   // -1 = 완결 패킷 없음(무시)
                // 세그먼트 테이블을 훑어 패킷 재조립. <255 = 패킷 종료.
                var bodyPos = bodyStart
                for i in 0..<nsegs {
                    let lace = Int(b[segTableStart + i])
                    current.append(contentsOf: b[bodyPos..<bodyPos + lace])
                    bodyPos += lace
                    if lace < 255 {
                        packets.append(current)
                        current = []
                    }
                }
            }
            pos = bodyStart + bodySize
        }
        guard !packets.isEmpty else { throw OggError.noPackets }
        return OggPageReader(packets: packets, finalGranule: finalGranule)
    }
}
