import Foundation

public struct TexImage {
    public enum PayloadKind: Equatable { case png, jpeg, rawRGBA8888, bc3, lz4RGBA, video, unknown }

    /// LZ4-compressed mip (TEXB0003/0004). `decode*` = padded texture dims(디코드 단위),
    /// `image*` = 실제 이미지 dims(크롭 대상).
    public struct CompressedMip: Equatable {
        public let decodeWidth: Int
        public let decodeHeight: Int
        public let imageWidth: Int
        public let imageHeight: Int
        public let decompressedSize: Int
        public let payloadRange: Range<Int>
    }

    public let width: Int   // 이미지 width (imgW)
    public let height: Int
    public let format: Int
    public let payload: PayloadKind
    public let payloadRange: Range<Int>
    public let mip: CompressedMip?

    public static func parse(_ data: Data) -> TexImage? {
        let b = [UInt8](data)
        guard b.count > 42, b[0..<8].elementsEqual(Array("TEXV0005".utf8)) else { return nil }
        func i32(_ o: Int) -> Int {
            Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        let format = i32(18)
        let texW = i32(26), texH = i32(30)
        let imgW = i32(34), imgH = i32(38)
        // 차원은 무경계 UInt32 에서 옴. Metal 렌더 한계(16384) 를 넘으면 거부해 w*h*4 정수 오버플로 트랩(크래시) 차단.
        let maxDim = 16384
        guard texW >= 0, texH >= 0, imgW >= 0, imgH >= 0,
              texW <= maxDim, texH <= maxDim, imgW <= maxDim, imgH <= maxDim else { return nil }

        func make(_ kind: PayloadKind, _ range: Range<Int>, _ mip: CompressedMip?) -> TexImage {
            TexImage(width: imgW, height: imgH, format: format, payload: kind, payloadRange: range, mip: mip)
        }

        // 1) 내장 이미지/비디오 시그니처 우선(작은 윈도우에서만 — LZ4 데이터의 우연 일치 방지).
        if let p = findSig(b, [0x89, 0x50, 0x4E, 0x47], limit: 512) { return make(.png, p..<b.count, nil) }
        if let p = findSig(b, [0xFF, 0xD8, 0xFF], limit: 512) { return make(.jpeg, p..<b.count, nil) }
        if let p = findSig(b, Array("ftyp".utf8), limit: 512), p >= 4 { return make(.video, (p - 4)..<b.count, nil) }

        // 2) LZ4 압축 mip(TEXB0003/0004): RGBA(fmt0) 또는 DXT5(fmt9).
        if let mip = parseMip(b, decodeW: texW, decodeH: texH, imgW: imgW, imgH: imgH) {
            let kind: PayloadKind = (format == 9) ? .bc3 : (format == 0 ? .lz4RGBA : .unknown)
            return make(kind, mip.payloadRange, mip)
        }
        // 3) 비압축 raw RGBA(드묾).
        if format == 0 { return make(.rawRGBA8888, 0..<b.count, nil) }
        return make(.unknown, 0..<b.count, nil)
    }

    /// "TEXB000N\0" + mipCount 다음 int 스트림에서 compressedSize K(= p+4+K == 파일끝)를 찾고,
    /// 직전 int를 decompressedSize로 본다(버전·패딩 무관, ground truth 검증됨).
    private static func parseMip(_ b: [UInt8], decodeW: Int, decodeH: Int, imgW: Int, imgH: Int) -> CompressedMip? {
        guard let ti = indexOf(b, Array("TEXB".utf8)) else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        var p = ti + 9 + 4
        let limit = min(b.count - 4, ti + 9 + 4 + 80)
        while p <= limit {
            // dec 는 공격자 제어 필드. 단일 mip 의 정당한 한계(512MB)를 넘으면 거부해 ~4GB 할당 DoS 차단.
            if let k = i32(p), k > 0, p + 4 + k == b.count, let dec = i32(p - 4), dec > 0, dec <= 512 << 20 {
                return CompressedMip(decodeWidth: decodeW, decodeHeight: decodeH,
                                     imageWidth: imgW, imageHeight: imgH,
                                     decompressedSize: dec, payloadRange: (p + 4)..<b.count)
            }
            p += 4
        }
        return nil
    }

    private static func findSig(_ b: [UInt8], _ sig: [UInt8], limit: Int) -> Int? {
        let upper = min(b.count - sig.count, limit)
        guard upper >= 0 else { return nil }
        var i = 0
        while i <= upper {
            if Array(b[i..<i + sig.count]) == sig { return i }
            i += 1
        }
        return nil
    }

    private static func indexOf(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        guard b.count >= sig.count else { return nil }
        var i = 0
        while i <= b.count - sig.count { if Array(b[i..<i + sig.count]) == sig { return i }; i += 1 }
        return nil
    }
}
