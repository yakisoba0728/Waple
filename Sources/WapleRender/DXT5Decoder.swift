import Foundation

public enum DXT5Decoder {
    /// DXT5(BC3) 블록 → RGBA8888. blocks 크기는 ((w+3)/4)*((h+3)/4)*16 이어야 함.
    public static func decode(_ blocks: Data, width: Int, height: Int) -> Data? {
        // bx/by 계산 전에 차원을 검증해야 bx*by*16 / width*height*4 정수 오버플로 트랩(크래시)을 방지한다.
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let bx = (width + 3) / 4, by = (height + 3) / 4
        guard blocks.count >= bx * by * 16 else { return nil }
        let src = [UInt8](blocks)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        func u16(_ o: Int) -> Int { Int(src[o]) | (Int(src[o + 1]) << 8) }
        func color565(_ c: Int) -> (Int, Int, Int) {
            let r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f
            return (r * 255 / 31, g * 255 / 63, b * 255 / 31)
        }

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 16
                // --- alpha (BC4) ---
                let a0 = Int(src[o]), a1 = Int(src[o + 1])
                var alpha = [Int](repeating: 0, count: 8)
                alpha[0] = a0; alpha[1] = a1
                if a0 > a1 {
                    for i in 1...6 { alpha[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
                } else {
                    for i in 1...4 { alpha[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
                    alpha[6] = 0; alpha[7] = 255
                }
                var abits: UInt64 = 0
                for i in 0..<6 { abits |= UInt64(src[o + 2 + i]) << (8 * i) }
                // --- color (BC1, DXT5 always 4-color) ---
                let c0 = u16(o + 8), c1 = u16(o + 10)
                let (r0, g0, b0) = color565(c0), (r1, g1, b1) = color565(c1)
                func lerp(_ x: Int, _ y: Int, _ t: Int) -> Int { (x * (3 - t) + y * t) / 3 }
                let palette: [(Int, Int, Int)] = [
                    (r0, g0, b0), (r1, g1, b1),
                    (lerp(r0, r1, 1), lerp(g0, g1, 1), lerp(b0, b1, 1)),
                    (lerp(r0, r1, 2), lerp(g0, g1, 2), lerp(b0, b1, 2)),
                ]
                let cbits = UInt32(src[o + 12]) | (UInt32(src[o + 13]) << 8) | (UInt32(src[o + 14]) << 16) | (UInt32(src[o + 15]) << 24)
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bxi * 4 + px, y = byi * 4 + py
                        if x >= width || y >= height { continue }
                        let idx = py * 4 + px
                        let ai = Int((abits >> UInt64(3 * idx)) & 0x7)
                        let ci = Int((cbits >> UInt32(2 * idx)) & 0x3)
                        let (r, g, b) = palette[ci]
                        let d = (y * width + x) * 4
                        out[d] = UInt8(r); out[d + 1] = UInt8(g); out[d + 2] = UInt8(b); out[d + 3] = UInt8(alpha[ai])
                    }
                }
            }
        }
        return Data(out)
    }
}
