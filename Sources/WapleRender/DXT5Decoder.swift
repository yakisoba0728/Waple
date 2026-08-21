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
                // BC3(=BC4) 알파 보간은 **반올림**이다 — `((7-i)*a0 + i*a1 + 3) / 7`, 6단은 `+ 2) / 5`.
                //
                // [2026-08-21 적용] 종전 이 자리는 floor 였고 주석에 "미적용 파리티 갭" 으로 남아
                // 있었다(막고 있던 것은 아래 근거 부재가 아니라 기대값을 든 테스트 파일의 소유였다).
                // 근거 셋이 같은 값을 가리킨다:
                //   · **WE 자체 디코더** — `spec/formats/tex-deep.json` `format.tex.bcDecodeRounding`
                //     (status 확정): `we.bc3AlphaLerp8 = ((7-i)*a0 + i*a1 + 3)/7`,
                //     `we.bc3AlphaLerp6 = ((5-i)*a0 + i*a1 + 2)/5`. 그 규약으로 12/12 표본이
                //     `resourcecompiler64 -transcode` 출력과 **바이트 동일**이다.
                //   · **하드웨어** — S3TC/BC3 규격의 알파 보간식이 바로 이 `+3)/7` · `+2)/5` 다.
                //     즉 Waple 의 `TexDecoder.nativeBC`(Metal 이 디코드) 결과와도 이제 맞물린다.
                //     종전 floor 는 **WE 와도, 우리 자신의 GPU 경로와도** 어긋나 있었다
                //     (그래서 `NativeBCUploadTests.testBC3InterpolatedParity` 가 정확 일치가 아니라
                //      `maxD < 24` 라는 느슨한 상한으로만 재고 있었다 — 이 수정은 그 차이를 줄인다).
                //   · **도달** — 동봉 BC3(format 4) **9개 전수**의 mip0 을 실제로 풀어(LZ4 해제 후
                //     블록별 알파 인덱스까지) 두 규칙이 갈리는 픽셀을 세면 **합계 86,809 픽셀**이다
                //     (전부 ±1): `splash_1_normal` 48,400 · `shower_stream_0_normal` 15,664 ·
                //     `splash_1` 11,608 · `fern1` 3,169 · `rain_drops_0` 3,105 · `splash_9` 3,069 ·
                //     `splash_10` 1,794 · `flatnormal`·`sphere` 0(엔드포인트가 같아 보간 슬롯 미사용).
                //     노멀맵 비중이 큰 것에 주목 — 알파에 채널을 접어 넣는 포맷이라 그렇다.
                // 색 보간(`lerp3`)은 **floor 가 정본**이라 그대로 둔다(같은 spec 키
                // `we.colorLerp` = floor, 반올림으로 바꾸면 fmt4 1,261 B · fmt6 71,970 B 어긋난다).
                var alpha = [Int](repeating: 0, count: 8)
                alpha[0] = a0; alpha[1] = a1
                if a0 > a1 {
                    for i in 1...6 { alpha[i + 1] = ((7 - i) * a0 + i * a1 + 3) / 7 }
                } else {
                    for i in 1...4 { alpha[i + 1] = ((5 - i) * a0 + i * a1 + 2) / 5 }
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
