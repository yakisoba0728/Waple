import Foundation

public struct TexImage {
    public enum PayloadKind: Equatable { case png, jpeg, rawRGBA8888, bc3, video, unknown }

    public struct BC3Mip: Equatable {
        public let width: Int
        public let height: Int
        public let decompressedSize: Int
        public let payloadRange: Range<Int>
    }

    public let width: Int
    public let height: Int
    public let format: Int
    public let payload: PayloadKind
    public let payloadRange: Range<Int>
    public let bc3: BC3Mip?

    public static func parse(_ data: Data) -> TexImage? {
        let b = [UInt8](data)
        guard b.count > 42, b[0..<8].elementsEqual(Array("TEXV0005".utf8)) else { return nil }
        func i32(_ o: Int) -> Int {
            Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        let format = i32(18)
        let width = i32(34)
        let height = i32(38)
        let (kind, start) = detect(b, format: format)
        var bc3: BC3Mip? = nil
        if kind == .bc3 {
            bc3 = parseBC3(b, imgW: width, imgH: height)
        }
        return TexImage(width: width, height: height, format: format, payload: kind, payloadRange: start..<b.count, bc3: bc3)
    }

    private static func detect(_ b: [UInt8], format: Int) -> (PayloadKind, Int) {
        func find(_ sig: [UInt8], limit: Int = 4096) -> Int? {
            let upper = min(b.count - sig.count, limit)
            guard upper >= 0 else { return nil }
            var i = 0
            while i <= upper {
                if Array(b[i..<i + sig.count]) == sig { return i }
                i += 1
            }
            return nil
        }
        if let p = find([0x89, 0x50, 0x4E, 0x47]) { return (.png, p) }
        if let p = find([0xFF, 0xD8, 0xFF]) { return (.jpeg, p) }
        if let p = find(Array("ftyp".utf8), limit: 512), p >= 4 { return (.video, p - 4) }
        if format == 9 { return (.bc3, 0) }
        return (.rawRGBA8888, 0)
    }

    private static func parseBC3(_ b: [UInt8], imgW: Int, imgH: Int) -> BC3Mip? {
        guard let ti = indexOf(b, Array("TEXB".utf8)) else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o + 4 <= b.count else { return nil }
            return Int(UInt32(b[o]) | UInt32(b[o+1])<<8 | UInt32(b[o+2])<<16 | UInt32(b[o+3])<<24)
        }
        let expected = ((imgW + 3) / 4) * ((imgH + 3) / 4) * 16
        var p = ti + 9 + 4   // skip "TEXB000N\0" + mipCount
        for _ in 0..<12 {     // scan ints for decompressedSize == expected
            guard let v = i32(p) else { return nil }
            if v == expected {
                guard let comp = i32(p + 4) else { return nil }
                let start = p + 8
                guard start + comp <= b.count, comp >= 0 else { return nil }
                return BC3Mip(width: imgW, height: imgH, decompressedSize: expected, payloadRange: start..<start + comp)
            }
            p += 4
        }
        return nil
    }
    private static func indexOf(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        guard b.count >= sig.count else { return nil }
        var i = 0
        while i <= b.count - sig.count { if Array(b[i..<i+sig.count]) == sig { return i }; i += 1 }
        return nil
    }
}
