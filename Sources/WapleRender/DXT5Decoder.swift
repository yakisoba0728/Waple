import Foundation

public enum DXT5Decoder {
    /// 565 엔드포인트 채널 정수 보간(4-색 팔레트 슬롯 t=1,2). BC3/BC1 공용.
    private static func lerp3(_ x: Int, _ y: Int, _ t: Int) -> Int { (x * (3 - t) + y * t) / 3 }
    /// 565 → RGB8(정수). BC1/BC2/BC3 공용. **비트 복제**(상위비트를 하위로 되풀이)가 정본이다.
    ///
    /// 종전은 `c * 255 / 31`(·`/63`)이었다. 두 식은 대부분 같은 값을 내지만 **일부 채널값에서 1 씩
    /// 어긋난다**(예 r=13: 복제 107 vs 나눗셈 106, r=5: 41 vs 41 은 같음). 어긋나는 쪽이 우리다:
    ///   · WE 자체 디코더(resourcecompiler64 `-transcode`) 가 비트 복제다 —
    ///     spec/formats/tex-deep.json `format.tex.bcDecodeRounding`(status 확정, 12표본 바이트 동일).
    ///   · Metal/D3D 하드웨어 BC 디코드도 비트 복제다. 즉 종전 규칙은 Waple 의 CPU 경로를
    ///     **자기 GPU 경로(TexDecoder.nativeBC)와도** 어긋나게 하고 있었다.
    /// 동봉 자산 실측(2026-08-21, format 4 BC3 9개 mip0 전수): 두 규칙의 RGB 바이트 차이가
    /// `splash_1_normal` 1,010,677B · `fern1` 24,916B · `flatnormal` 256B(= 전 픽셀) — 전부 ±1.
    /// 노멀맵에서 특히 나쁘다(flatnormal 은 (128,128,255) 여야 하는데 한 채널이 1 낮게 나왔다).
    private static func color565(_ c: Int) -> (Int, Int, Int) {
        let r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }
    /// 리틀엔디안 u16(블록 엔드포인트 읽기 — 픽셀 루프 밖이라 정적 호출 무해).
    private static func u16(_ src: [UInt8], _ o: Int) -> Int { Int(src[o]) | (Int(src[o + 1]) << 8) }

    /// DXT5(BC3) 블록 → RGBA8888. blocks 크기는 ((w+3)/4)*((h+3)/4)*16 이어야 함.
    public static func decode(_ blocks: Data, width: Int, height: Int) -> Data? {
        // bx/by 계산 전에 차원을 검증해야 bx*by*16 / width*height*4 정수 오버플로 트랩(크래시)을 방지한다.
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let bx = (width + 3) / 4, by = (height + 3) / 4
        guard blocks.count >= bx * by * 16 else { return nil }
        let src = [UInt8](blocks)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 16
                // --- alpha (BC4) ---
                let a0 = Int(src[o]), a1 = Int(src[o + 1])
                // ⚠️ **미적용 파리티 갭**: WE(그리고 D3D/Metal 하드웨어)는 이 보간을 **반올림**한다 —
                // `((7-i)*a0 + i*a1 + 3) / 7`, 6단은 `+ 2) / 5`(spec `format.tex.bcDecodeRounding`, 확정).
                // 아래는 floor 라 알파가 최대 1 낮게 나온다(동봉 BC3 9개 실측: splash_1 11,608B ·
                // splash_1_normal 48,400B 가 ±1 불일치). 고치려면 `DXT5DecoderTests
                // .testDecodesEightValueAlphaRamp` 의 기댓값 [218,182,145,109,72,36] 을
                // [219,182,146,109,73,36] 으로 함께 바꿔야 하는데 그 파일은 이 작업의 담당 범위 밖이라
                // 손대지 않았다. 색(color565)만 먼저 맞췄다.
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
                let c0 = u16(src, o + 8), c1 = u16(src, o + 10)
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

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 8
                let c0 = u16(src, o), c1 = u16(src, o + 2)
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

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 16
                // --- alpha (BC2: 픽셀당 4bit 명시값, 8B = 16 니블) ---
                var abits: UInt64 = 0
                for i in 0..<8 { abits |= UInt64(src[o + i]) << (8 * i) }
                // --- color (BC1 블록, 단 BC2 는 항상 4-색 — BC3 와 동일 팔레트) ---
                let c0 = u16(src, o + 8), c1 = u16(src, o + 10)
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
