import XCTest
@testable import WapleCore

/// `.pkg`(워크샵 다운로드) 안의 `.tex` 는 **신뢰 경계 밖**이다. 헤더의 모든 정수는 파일이 시키는 값이고,
/// Swift 의 정수 좁힘·범위 생성·배열 첨자는 넘치면 클램프가 아니라 **트랩**(프로세스 사망)이다.
/// 여기서 재는 것은 "값이 맞는가" 가 아니라 **"거짓말하는 헤더가 프로세스를 죽이지 못하는가"** 다 —
/// 테스트가 트랩하면 러너가 통째로 죽으므로, 아래 케이스들은 통과/실패가 아니라 **생존**이 판정이다.
///
/// 근거가 되는 엔진 상한(재확인 2026-08-21, `wallpaper64.exe` imagebase 0x140000000):
///   · mip w/h ≤ 0x2000, depth ≤ 0x80 — 0x14015d3a2 / 0x14015d3ab / 0x14015d3b4,
///     위반 시 `"Invalid texture resolution: w=%u h=%u d=%u"`(0x14048b8a0) 에러 경로 0x1400986c0
///   · w·h·depth·4 가 0xffffffff 를 넘으면 같은 에러 경로(0x14015d3c4–0x14015d3e6)
/// Waple 의 상한은 그보다 넓지만(렌더 한계 16384) **없는 것과는 다르다** — 넓은 상한도 상한이다.
final class TexHostileInputTests: XCTestCase {

    /// TEXI 헤더(previewColor 는 안 적는다 — 기존 픽스처와 같은 규약이라 뒤따르는 "TEXB" 4바이트가
    /// previewColor 로 읽힌다. 이 테스트들은 previewColor 값을 보지 않는다).
    private static func head(format: Int, flags: Int = 0, w: Int = 8, h: Int = 8,
                             depth: Int? = nil) -> [UInt8] {
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32(format), i32(flags), i32(w), i32(h), i32(w), i32(h))
        if let d = depth { b += i32(d) }
        return b
    }

    private static func cond(_ value: String) -> [UInt8] {
        Array(#"{"condition":{"condition":"\#(value)","name":"tuniccolor"}}"#.utf8)
    }

    // MARK: - 조건 변형 블록은 개수 기반이다(패턴 매칭이 아니다)

    /// TEXB0004 의 `imageFormat` 다음 i32 는 **조건 변형 개수**다(리더 0x14015c9a0 읽기,
    /// 루프 상한 0x14015d1c9 `cmp esi, [rbp-0x78]` → `jb 0x14015ca00`). 블록 본문은
    /// `[i32][i32 idx][i32][NUL 종단 JSON]` 이고 **엔진은 세 정수의 값을 보지 않는다**
    /// (0x14015ca2d · 0x14015ca57 · 0x14015ca7c 는 그냥 읽고 저장, 검사 없음).
    ///
    /// 종전 Waple 은 개수를 버리고 `첫 정수 == 1 && idx ∈ 1...64 && 셋째 == 0` 패턴으로 블록을 찾았다.
    /// 관측된 zelda 8종이 우연히 `1, idx, 0` 이었을 뿐이라, 다른 값이 오면 블록을 못 찾고 그 자리를
    /// mip 테이블로 읽어 **컨테이너를 통째로 잃는다**(= 텍스처가 통째로 안 나온다).
    /// 아래 픽스처의 세 정수는 `7, 5, 9` 다 — 개수 기반이면 정상 파스, 패턴 기반이면 `.unknown` 이다.
    func testVariantBlocksAreCountDrivenNotPatternMatched() {
        let payload: [UInt8] = Array(repeating: 0x5A, count: 32)      // 8×8 BC3 = 32B
        var b = Self.head(format: 4)
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(1))          // imageCount, imageFormat=-1, 변형수 1
        b += bytes(i32(7), i32(5), i32(9), Self.cond("2"), [0])       // 세 정수가 1/idx/0 이 **아니다**
        b += i32(1)                                                   // mipCount
        b += bytes(i32(8), i32(8), i32(0), i32(32), i32(payload.count))
        let mipStart = b.count
        b += payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3, "패턴 매칭으로 되돌아가면 컨테이너를 잃고 .unknown 이 된다")
        XCTAssertEqual(t?.mip?.payloadRange, mipStart..<(mipStart + payload.count))
        XCTAssertEqual(t?.mip?.decodeWidth, 8)
        XCTAssertEqual(t?.mip?.lz4, false)
        // 블록의 두 번째 정수가 idx 다(5). 변형 섹션이 없으니 variants 는 비지만 조건 체인은 읽혔다.
        XCTAssertEqual(t?.variants.count, 0, "변형 섹션이 없으면 variants 는 [] — 기본 mip 폴백")
    }

    /// 조건 JSON 이 문법에 안 맞아도 **블록 프레이밍은 성립해야 한다** — 엔진도 문자열만 떠서 나중에
    /// 파스한다. 조건이 못 읽히면 그 변형이 영영 매치 안 될 뿐이고 기본 mip 은 온전해야 한다.
    func testMalformedConditionJSONStillKeepsBaseMip() {
        let payload: [UInt8] = Array(repeating: 0x33, count: 32)
        var b = Self.head(format: 4)
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(1))
        b += bytes(i32(1), i32(1), i32(0), Array("not json at all".utf8), [0])
        b += i32(1)
        b += bytes(i32(8), i32(8), i32(0), i32(32), i32(payload.count))
        let mipStart = b.count
        b += payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.mip?.payloadRange, mipStart..<(mipStart + payload.count))
        XCTAssertEqual(t?.variants.count, 0)
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .string("2")])?.payloadRange,
                       t?.mip?.payloadRange, "조건 불명 → 항상 기본")
    }

    /// 변형 개수가 터무니없으면 컨테이너를 폐기한다(각 블록이 최대 64KB 를 훑으므로 개수에 상한이 필요).
    /// 폐기 = 시그니처 스캔 폴백이고, fmt4 는 시그니처가 없으니 `.unknown` + mip 없음이 정답이다.
    func testAbsurdVariantCountIsRejected() {
        var b = Self.head(format: 4)
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0x7FFF_FFFF))
        b += Array(repeating: UInt8(0x41), count: 4096)
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .unknown)
        XCTAssertNil(t?.mip)
    }

    /// 위 상한(1024)이 **실제로 걸리는지** 양쪽에서 못박는다 — 블록이 전부 정상이어도 개수가 넘으면 거부.
    /// 엔진엔 이 상한이 없다(개수만 믿는다). Waple 이 두는 이유는 블록마다 최대 64KB 를 훑기 때문이고,
    /// 실물 최대는 3 이다(코퍼스 4,991건: 0×2865 · 1×7 · 3×1) — 1024 는 충분히 넉넉하다.
    func testVariantCountCapIsEnforcedAtBothSides() {
        func tex(blocks: Int) -> Data {
            let payload: [UInt8] = Array(repeating: 0x5A, count: 32)
            var b = Self.head(format: 4)
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(blocks))
            for k in 0..<blocks { b += bytes(i32(1), i32(k + 1), i32(0), Array("{}".utf8), [0]) }
            b += i32(1)
            b += bytes(i32(8), i32(8), i32(0), i32(32), i32(payload.count))
            b += payload
            return Data(b)
        }
        XCTAssertEqual(TexImage.parse(tex(blocks: 1024))?.payload, .bc3, "상한 안(1024)은 통과해야 한다")
        XCTAssertEqual(TexImage.parse(tex(blocks: 1025))?.payload, .unknown, "상한 밖(1025)은 컨테이너 폐기")
        XCTAssertNil(TexImage.parse(tex(blocks: 1025))?.mip)
    }

    // MARK: - 거짓말하는 헤더

    /// 차원이 렌더 한계를 넘으면 **파스 자체를 거부**한다. 통과시키면 소비처에서 `w*h*4` 를 만드는
    /// 순간 크래시다(TexDecoder.rawRGBA8888 의 `need`, cropped 의 `dw*dh*4`).
    func testOversizedHeaderDimensionsRejectParse() {
        for (w, h) in [(0x7FFF_FFFF, 8), (8, 0x7FFF_FFFF), (0xFFFF_FFFF, 0xFFFF_FFFF), (16385, 16385)] {
            var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
            b += bytes(i32(0), i32(0), i32(w), i32(h), i32(w), i32(h))
            b += bytes(tag("TEXB0001"), Array(repeating: UInt8(0), count: 64))
            XCTAssertNil(TexImage.parse(Data(b)), "w=\(w) h=\(h) 를 통과시켰다")
        }
    }

    /// slice3d(flags 0x40) 인데 depth 가 0/음수/엔진 상한(0x80) 초과면 거부. depth 0 을 통과시키면
    /// 소비처가 `imgW / depth` 로 슬라이스를 자를 때 0 나눗셈이다.
    func testVolumeDepthOutOfRangeRejectsParse() {
        for d in [0, -1, 129, 0x7FFF_FFFF] {
            var b = Self.head(format: 0, flags: 0x40, depth: d)
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            b += bytes(i32(8), i32(8), i32(1), i32(0), i32(256), i32(4), [0, 0, 0, 0])
            XCTAssertNil(TexImage.parse(Data(b)), "depth=\(d) 를 통과시켰다")
        }
        // 경계 자체(1 과 128)는 통과해야 한다 — 상한을 너무 좁히면 실물을 거부한다.
        for d in [1, 128] {
            var b = Self.head(format: 0, flags: 0x40, depth: d)
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            b += bytes(i32(2), i32(2), i32(d), i32(0), i32(16), i32(16))
            b += Array(repeating: UInt8(0x10), count: 16)
            XCTAssertEqual(TexImage.parse(Data(b))?.depth, d, "depth=\(d) 경계를 거부했다")
        }
    }

    /// mip 레코드가 거짓말하는 세 자리 — 압축 크기가 파일 밖 / 해제 크기가 512MB 초과 / w·h 가 한계 초과.
    /// 셋 다 컨테이너 폐기(mip 없음)여야 한다. 통과하면 `Data.subdata(in:)` 범위 밖 또는 GB 급 할당이다.
    func testLyingMipRecordDropsContainer() {
        func tex(w: Int, h: Int, dec: Int, comp: Int, payloadBytes: Int) -> Data {
            var b = Self.head(format: 4)
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            b += bytes(i32(w), i32(h), i32(1), i32(dec), i32(comp))
            b += Array(repeating: UInt8(0x77), count: payloadBytes)
            return Data(b)
        }
        // comp 가 실제 남은 바이트보다 크다
        XCTAssertNil(TexImage.parse(tex(w: 8, h: 8, dec: 64, comp: 1 << 20, payloadBytes: 16))?.mip)
        // dec 가 512MB 초과(LZ4 목적지 할당 폭탄)
        XCTAssertNil(TexImage.parse(tex(w: 8, h: 8, dec: 0x7FFF_FFFF, comp: 16, payloadBytes: 16))?.mip)
        // w/h 가 한계 초과
        XCTAssertNil(TexImage.parse(tex(w: 0x7FFF_FFFF, h: 8, dec: 64, comp: 16, payloadBytes: 16))?.mip)
        XCTAssertNil(TexImage.parse(tex(w: 8, h: -4, dec: 64, comp: 16, payloadBytes: 16))?.mip)
        // comp <= 0
        XCTAssertNil(TexImage.parse(tex(w: 8, h: 8, dec: 64, comp: 0, payloadBytes: 16))?.mip)
    }

    /// mipCount / imageCount 가 거대해도 파일 크기가 상한이다 — 레코드 하나가 최소 12바이트 이상을
    /// 먹으므로 루프는 즉시 끊겨야 하고, 그 사이 어떤 첨자도 범위를 벗어나면 안 된다.
    func testHugeCountsTerminateWithoutOverread() {
        var b = Self.head(format: 4)
        b += bytes(tag("TEXB0004"), i32(0x7FFF_FFFF), i32(-1), i32(0), i32(0x7FFF_FFFF))
        b += bytes(i32(8), i32(8), i32(0), i32(32), i32(32))
        b += Array(repeating: UInt8(0x5A), count: 32)
        let t = TexImage.parse(Data(b))
        // imageCount 상한(1024)에 걸려 컨테이너 폐기 → fmt4 는 시그니처가 없으니 .unknown.
        XCTAssertEqual(t?.payload, .unknown)
        XCTAssertNil(t?.mip)

        // imageCount 는 정상, mipCount 만 거대 — mip0 은 읽히고 체인만 끊긴다(우아한 저하).
        // `for level in 1..<0x7FFFFFFF` 는 첫 레벨에서 곧바로 실패해야 한다(파일 크기가 상한).
        var c = Self.head(format: 4)
        c += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(0x7FFF_FFFF))
        c += bytes(i32(8), i32(8), i32(0), i32(32), i32(32))
        let mipStart = c.count
        c += Array(repeating: UInt8(0x5A), count: 32)
        let u = TexImage.parse(Data(c))
        XCTAssertEqual(u?.payload, .bc3, "mip0 은 온전 — 거짓 mipCount 는 체인만 못 만든다")
        XCTAssertEqual(u?.mip?.payloadRange, mipStart..<(mipStart + 32))
        XCTAssertEqual(u?.mipChain.count, 0, "레벨이 끊겼으면 체인은 폐기")
    }

    /// TEXS 프레임 수가 거짓이면 프레임을 통째로 버린다(= 1프레임 텍스처와 동등). 범위 밖 f32 읽기 금지.
    /// 두 가지 방어가 겹쳐 있고 **둘 다 필요하다**:
    ///   ① `count × 32 ≤ 남은 바이트` — 잘린 파일에서 범위 밖 읽기를 막는다
    ///   ② `count ≤ 4096` 상한 — ①만으로는 **거대하지만 잘리지 않은** 파일(16MB 면 50만 프레임)이
    ///      그대로 통과해 `reserveCapacity`/배열이 부풀어 오른다. 엔진엔 이 상한이 없다(리더
    ///      0x14015e54c `sub esi,1 / jne` 가 count 번 돈다) — Waple 자체 방어선이고 실물 최대는 128 이다.
    func testLyingFrameCountYieldsNoFrames() {
        /// 헤더의 프레임 수는 `count`, 실제로 실어 주는 유효 레코드는 `records` 장.
        func sheet(count: Int, records: Int) -> Data {
            var b = Self.head(format: 0, flags: 4)
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            b += bytes(i32(8), i32(8), i32(0), i32(256), i32(16))
            b += Array(repeating: UInt8(0x22), count: 16)
            b += bytes(tag("TEXS0003"), i32(count), i32(8), i32(8))
            for _ in 0..<records {
                b += bytes(i32(0), f32(0.05), f32(0), f32(0), f32(8), f32(0), f32(0), f32(8))
            }
            return Data(b)
        }
        for count in [0x7FFF_FFFF, 4097, -1, 0] {
            let t = TexImage.parse(sheet(count: count, records: 1))   // ① 잘린 경우
            XCTAssertEqual(t?.frames.count, 0, "count=\(count) 에서 프레임이 나왔다")
            XCTAssertEqual(t?.framesVersion, 0, "count=\(count)")
        }
        // ② 안 잘린 경우 — 바이트가 전부 있어도 상한 밖이면 거부해야 한다(①로는 안 걸린다).
        XCTAssertEqual(TexImage.parse(sheet(count: 4097, records: 4097))?.frames.count, 0,
                       "프레임 상한 4096 이 풀렸다")
        // 상한 안쪽(4096)은 통과 — 상한을 너무 좁히면 실물을 거부한다.
        XCTAssertEqual(TexImage.parse(sheet(count: 4096, records: 4096))?.frames.count, 4096)
    }

    // MARK: - 잘림·비트 반전 스윕

    /// **모든 길이로 잘라 본다.** 조건부 필드가 셋(헤더 depth · previewColor · mip depth)이라 잘림 위치마다
    /// 다른 분기가 반쯤 읽힌 상태로 들어간다. 어느 길이에서도 트랩하면 안 되고, 파스가 성공했다면
    /// 밖으로 나가는 모든 범위가 **입력 안**이어야 한다(소비처가 그대로 `subdata(in:)` 를 건다).
    func testEveryTruncationIsSafe() {
        let full = Self.richFixture()
        for n in 0...full.count {
            let d = full.prefix(n)
            guard let t = TexImage.parse(Data(d)) else { continue }
            assertRangesInside(t, count: n, why: "prefix \(n)")
        }
    }

    /// 헤더 구간의 바이트를 하나씩 0xFF / 0x00 으로 뒤집어 본다 — 길이 필드 하나가 뒤집히면 곧바로
    /// 거대한 오프셋이 되는 자리들이다.
    func testHeaderByteFlipsAreSafe() {
        let full = Self.richFixture()
        for i in 0..<min(96, full.count) {
            for v in [UInt8(0xFF), UInt8(0x00), UInt8(0x80)] {
                var b = full
                b[i] = v
                guard let t = TexImage.parse(Data(b)) else { continue }
                assertRangesInside(t, count: b.count, why: "byte \(i) → \(v)")
            }
        }
    }

    /// `payloadRange` 규약: 인덱스 공간은 **파스에 넘긴 Data 그 자체**다. 0-베이스가 아닌 슬라이스로도
    /// `data.subdata(in:)` 이 성립해야 한다(ScenePackage 가 슬라이스를 넘기는 순간 아니면 트랩).
    func testRangesFollowSliceIndexSpace() throws {
        let full = Self.richFixture()
        let pad = 37
        let padded = Data(repeating: 0xCD, count: pad) + Data(full)
        let slice = padded.dropFirst(pad)
        let sliced = try XCTUnwrap(TexImage.parse(slice), "슬라이스 파스 실패")
        let flat = try XCTUnwrap(TexImage.parse(Data(full)), "0-베이스 파스 실패")
        let slicedMip = try XCTUnwrap(sliced.mip)
        let flatMip = try XCTUnwrap(flat.mip)
        // 범위는 넘긴 Data 의 인덱스 공간 — subdata 가 그대로 성립해야 한다.
        XCTAssertEqual(padded.subdata(in: slicedMip.payloadRange).count, slicedMip.payloadRange.count)
        XCTAssertEqual(slicedMip.payloadRange.count, flatMip.payloadRange.count)
        XCTAssertEqual(slicedMip.payloadRange.lowerBound - pad, flatMip.payloadRange.lowerBound)
        XCTAssertEqual(sliced.variants.count, flat.variants.count)
        for (a, f) in zip(sliced.variants, flat.variants) {
            XCTAssertEqual(a.mip.payloadRange.lowerBound - pad, f.mip.payloadRange.lowerBound)
        }
        XCTAssertEqual(sliced.mipChain.count, flat.mipChain.count)
    }

    // MARK: - 도구

    private func assertRangesInside(_ t: TexImage, count: Int, why: String) {
        func ok(_ r: Range<Int>) -> Bool { r.lowerBound >= 0 && r.upperBound <= count && r.lowerBound <= r.upperBound }
        XCTAssertTrue(ok(t.payloadRange), "\(why): payloadRange \(t.payloadRange) 가 입력 밖")
        for m in t.mips { XCTAssertTrue(ok(m.payloadRange), "\(why): mips 범위 밖") }
        for m in t.mipChain { XCTAssertTrue(ok(m.payloadRange), "\(why): mipChain 범위 밖") }
        for v in t.variants { XCTAssertTrue(ok(v.mip.payloadRange), "\(why): variant 범위 밖") }
        if let m = t.mip { XCTAssertTrue(ok(m.payloadRange), "\(why): mip 범위 밖") }
    }

    /// 조건부 필드를 최대한 켠 픽스처: slice3d(헤더 depth + mip depth) + TEXB0004 조건 변형 + 다중 mip + TEXS0003.
    /// 잘림/반전 스윕이 실제로 여러 분기를 통과하도록 하나에 다 담는다.
    private static func richFixture() -> [UInt8] {
        var b = head(format: 0, flags: 0x42 | 0x4, w: 8, depth: 2)
        b += i32(0x1122_3344)                                              // previewColor(TEXI0001)
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(1))               // imageCount, imageFormat=-1, 변형수 1
        b += bytes(i32(1), i32(1), i32(0), cond("2"), [0])
        b += i32(2)                                                        // mipCount 2
        b += bytes(i32(8), i32(8), i32(2), i32(0), i32(512), i32(512))     // w,h,depth,isLZ4=0,dec,comp
        b += Array(repeating: UInt8(0x61), count: 512)
        b += bytes(i32(4), i32(4), i32(2), i32(0), i32(128), i32(128))
        b += Array(repeating: UInt8(0x62), count: 128)
        b += bytes(i32(1), i32(1))                                         // 변형 섹션 헤더
        b += bytes(i32(1), i32(1), i32(0), i32(0), i32(8), i32(8), i32(13), i32(256))
        b += Array(repeating: UInt8(0x63), count: 256)
        b += bytes(tag("TEXS0003"), i32(1), i32(8), i32(8))
        b += bytes(i32(0), f32(0.25), f32(0), f32(0), f32(8), f32(0), f32(0), f32(8))
        return b
    }
}
