import Foundation

public enum DXT5Decoder {
    /// 565 엔드포인트 채널 정수 보간(4-색 팔레트 슬롯 t=1,2). BC3/BC1 공용.
    private static func lerp3(_ x: Int, _ y: Int, _ t: Int) -> Int { (x * (3 - t) + y * t) / 3 }

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
                let palette: [(Int, Int, Int)] = [
                    (r0, g0, b0), (r1, g1, b1),
                    (lerp3(r0, r1, 1), lerp3(g0, g1, 1), lerp3(b0, b1, 1)),
                    (lerp3(r0, r1, 2), lerp3(g0, g1, 2), lerp3(b0, b1, 2)),
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

    /// DXT1(BC1) 블록 → RGBA8888. blocks 크기는 ((w+3)/4)*((h+3)/4)*8 이어야 함.
    /// c0 <= c1 이면 3-색 + 인덱스 3 = 투명 검정(1비트 알파 변형).
    /// 실측 근거(2026-07-03): .tex format 7 이 decompressedSize == w*h/2(4bpp) 전수 일치 —
    /// 태양계 스카이박스/태양/행성(8k_earth_ps 등)이 이 포맷.
    public static func decodeBC1(_ blocks: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let bx = (width + 3) / 4, by = (height + 3) / 4
        guard blocks.count >= bx * by * 8 else { return nil }
        let src = [UInt8](blocks)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        func u16(_ o: Int) -> Int { Int(src[o]) | (Int(src[o + 1]) << 8) }
        func color565(_ c: Int) -> (Int, Int, Int) {
            let r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f
            return (r * 255 / 31, g * 255 / 63, b * 255 / 31)
        }

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 8
                let c0 = u16(o), c1 = u16(o + 2)
                let (r0, g0, b0) = color565(c0), (r1, g1, b1) = color565(c1)
                var palette: [(Int, Int, Int, Int)]
                if c0 > c1 {
                    palette = [(r0, g0, b0, 255), (r1, g1, b1, 255),
                               (lerp3(r0, r1, 1), lerp3(g0, g1, 1), lerp3(b0, b1, 1), 255),
                               (lerp3(r0, r1, 2), lerp3(g0, g1, 2), lerp3(b0, b1, 2), 255)]
                } else {
                    palette = [(r0, g0, b0, 255), (r1, g1, b1, 255),
                               ((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2, 255),
                               (0, 0, 0, 0)]
                }
                let cbits = UInt32(src[o + 4]) | (UInt32(src[o + 5]) << 8) | (UInt32(src[o + 6]) << 16) | (UInt32(src[o + 7]) << 24)
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bxi * 4 + px, y = byi * 4 + py
                        if x >= width || y >= height { continue }
                        let ci = Int((cbits >> UInt32(2 * (py * 4 + px))) & 0x3)
                        let (r, g, b, a) = palette[ci]
                        let d = (y * width + x) * 4
                        out[d] = UInt8(r); out[d + 1] = UInt8(g); out[d + 2] = UInt8(b); out[d + 3] = UInt8(a)
                    }
                }
            }
        }
        return Data(out)
    }

    /// DXT3(BC2) 블록 → RGBA8888. blocks 크기는 ((w+3)/4)*((h+3)/4)*16 이어야 함.
    /// 앞 8B = 픽셀당 4bit 명시 알파(리틀엔디안 니블 순 — 4bit 값 v 는 v*17 로 8bit 확장),
    /// 뒤 8B = BC1 과 동일한 컬러 블록. 단 BC2 는 color0<=color1 이어도 항상 4-색 모드(BC1 의
    /// 3색+투명 모드 없음 — DXT3 규약)이므로 컬러 로직은 BC3(decode)의 always-4-color 를 재사용한다.
    /// 실측 근거(2026-07-06): WE .tex format 6 이 이 포맷 — 태양계 씬 3662790108 의 fmt6 텍스처 16개
    /// (sun-1/planet color map 등)이 전부 여기로 온다(종전 미매핑 → 흰 폴백).
    public static func decodeBC2(_ blocks: Data, width: Int, height: Int) -> Data? {
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
                // --- alpha (BC2: 픽셀당 4bit 명시값, 8B = 16 니블) ---
                var abits: UInt64 = 0
                for i in 0..<8 { abits |= UInt64(src[o + i]) << (8 * i) }
                // --- color (BC1 블록, 단 BC2 는 항상 4-색 — BC3 와 동일 팔레트) ---
                let c0 = u16(o + 8), c1 = u16(o + 10)
                let (r0, g0, b0) = color565(c0), (r1, g1, b1) = color565(c1)
                let palette: [(Int, Int, Int)] = [
                    (r0, g0, b0), (r1, g1, b1),
                    (lerp3(r0, r1, 1), lerp3(g0, g1, 1), lerp3(b0, b1, 1)),
                    (lerp3(r0, r1, 2), lerp3(g0, g1, 2), lerp3(b0, b1, 2)),
                ]
                let cbits = UInt32(src[o + 12]) | (UInt32(src[o + 13]) << 8) | (UInt32(src[o + 14]) << 16) | (UInt32(src[o + 15]) << 24)
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bxi * 4 + px, y = byi * 4 + py
                        if x >= width || y >= height { continue }
                        let idx = py * 4 + px
                        let a4 = Int((abits >> UInt64(4 * idx)) & 0xF)  // 니블 → 8bit: v*17
                        let ci = Int((cbits >> UInt32(2 * idx)) & 0x3)
                        let (r, g, b) = palette[ci]
                        let d = (y * width + x) * 4
                        out[d] = UInt8(r); out[d + 1] = UInt8(g); out[d + 2] = UInt8(b); out[d + 3] = UInt8(a4 * 17)
                    }
                }
            }
        }
        return Data(out)
    }
}
