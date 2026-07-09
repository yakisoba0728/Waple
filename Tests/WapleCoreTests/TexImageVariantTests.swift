import XCTest
@testable import WapleCore

/// TEXB0004 조건 변형(tuniccolor 류) 파스·선택 — 실측 레이아웃(2026-07-09 전 코퍼스 8종 확정) 합성 픽스처.
final class TexImageVariantTests: XCTestCase {
    private static func i32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
    }
    private static func cond(_ value: String) -> [UInt8] {
        Array(#"{"condition":{"condition":"\#(value)","name":"tuniccolor"}}"#.utf8)
    }

    /// 실측 레이아웃대로 조건 변형 tex 합성(format=4 BC3, 전부 비압축 comp==dec):
    ///   헤더[imageCount 1][fmt -1][변형수 N] | 조건체인 N | 기본 mip | 변형섹션[1][N] + 변형 image N.
    /// 반환 = (데이터, 기본 payloadRange, idx→변형 payloadRange) — 선택이 어느 mip 을 골랐는지 range 로 식별.
    static func makeVariantTex(w: Int, h: Int, defaultPayload: [UInt8],
                               variants: [(idx: Int, value: String, payload: [UInt8])])
        -> (data: Data, defaultRange: Range<Int>, variantRanges: [Int: Range<Int>]) {
        let dec = ((w + 3) / 4) * ((h + 3) / 4) * 16
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0004".utf8) + [0]
        b += i32(1) + i32(-1) + i32(variants.count)                 // imageCount, imageFormat=-1, 변형수
        for v in variants { b += i32(1) + i32(v.idx) + i32(0) + cond(v.value) + [0] }   // [1][idx][0][json NUL]
        b += i32(1)                                                 // 기본 mipCount
        b += i32(w) + i32(h) + i32(0) + i32(dec) + i32(defaultPayload.count)   // w,h,isLZ4=0,dec,comp
        let defaultStart = b.count
        b += defaultPayload
        let defaultRange = defaultStart..<(defaultStart + defaultPayload.count)
        b += i32(1) + i32(variants.count)                           // 변형 섹션: imageCount, 변형수
        var ranges: [Int: Range<Int>] = [:]
        for v in variants {
            b += i32(1) + i32(v.idx) + i32(0) + i32(0) + i32(w) + i32(h) + i32(13) + i32(v.payload.count)
            let s = b.count
            b += v.payload
            ranges[v.idx] = s..<(s + v.payload.count)
        }
        return (Data(b), defaultRange, ranges)
    }

    private func p16(_ byte: UInt8) -> [UInt8] { [UInt8](repeating: byte, count: 16) }  // 4×4 BC3 = 16B(비압축)

    /// childlink_01 클래스(변형 3): idx1=cond"2"(파랑) idx2=cond"1"(빨강) idx3=cond"3"(검정), 기본=초록.
    /// 파스가 변형 3개 + 기본을 분리하고, 프로퍼티 값이 서로 다른 payloadRange 를 고르는지.
    func testParsesAndSelectsMultiVariant() {
        let f = Self.makeVariantTex(w: 4, h: 4, defaultPayload: p16(0x10),
            variants: [(1, "2", p16(0x21)), (2, "1", p16(0x22)), (3, "3", p16(0x23))])
        let t = TexImage.parse(f.data)
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.mip?.payloadRange, f.defaultRange, "기본 mip = 변형 섹션 앞(초록)")
        XCTAssertEqual(t?.variants.count, 3)
        XCTAssertEqual(t?.variants.map { $0.condition },
                       [TexImage.VariantCondition(name: "tuniccolor", value: "2"),
                        TexImage.VariantCondition(name: "tuniccolor", value: "1"),
                        TexImage.VariantCondition(name: "tuniccolor", value: "3")])
        func sel(_ v: String) -> Range<Int>? {
            t?.selectedMip(properties: ["tuniccolor": .string(v)])?.payloadRange
        }
        XCTAssertEqual(sel("2"), f.variantRanges[1], "tuniccolor=2 → idx1")
        XCTAssertEqual(sel("1"), f.variantRanges[2], "tuniccolor=1 → idx2")
        XCTAssertEqual(sel("3"), f.variantRanges[3], "tuniccolor=3 → idx3")
        // 변형 3개의 payloadRange 는 서로, 그리고 기본과 전부 다름(= 서로 다른 픽셀 페이로드).
        let all = [f.defaultRange, f.variantRanges[1]!, f.variantRanges[2]!, f.variantRanges[3]!]
        XCTAssertEqual(Set(all).count, 4, "기본+변형3 = 4개 고유 payloadRange")
    }

    /// 미매치(기본값 0) 와 값 부재 → 기본 image 폴백.
    func testMismatchAndAbsentFallBackToDefault() {
        let f = Self.makeVariantTex(w: 4, h: 4, defaultPayload: p16(0x10),
            variants: [(1, "2", p16(0x21)), (2, "1", p16(0x22)), (3, "3", p16(0x23))])
        let t = TexImage.parse(f.data)
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .string("0")])?.payloadRange, f.defaultRange)
        XCTAssertEqual(t?.selectedMip(properties: [:])?.payloadRange, f.defaultRange)
        XCTAssertEqual(t?.selectedMip(properties: ["other": .string("2")])?.payloadRange, f.defaultRange)
    }

    /// 숫자형 프로퍼티 값도 매치(콤보가 .number 로 저장된 경우 대비 — Double 동등).
    func testNumberValuedPropertyMatches() {
        let f = Self.makeVariantTex(w: 4, h: 4, defaultPayload: p16(0x10),
            variants: [(1, "2", p16(0x21))])
        let t = TexImage.parse(f.data)
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .number(2)])?.payloadRange, f.variantRanges[1])
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .number(9)])?.payloadRange, f.defaultRange)
    }

    /// 단일 변형(link_00 클래스, 변형수 1, cond"3"): 변형 1개 파스 + 선택.
    func testSingleVariant() {
        let f = Self.makeVariantTex(w: 4, h: 4, defaultPayload: p16(0x10),
            variants: [(1, "3", p16(0x33))])
        let t = TexImage.parse(f.data)
        XCTAssertEqual(t?.variants.count, 1)
        XCTAssertEqual(t?.variants.first?.condition, TexImage.VariantCondition(name: "tuniccolor", value: "3"))
        XCTAssertEqual(t?.variants.first?.mip.lz4, false, "comp==dec → 비압축")
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .string("3")])?.payloadRange, f.variantRanges[1])
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .string("0")])?.payloadRange, f.defaultRange)
    }

    /// 비-조건 BC3 텍스처: variants 는 []이고 기본 mip 정상(무회귀 — selectedMip 는 항상 기본).
    func testNonConditionalHasNoVariants() {
        func i32(_ v: Int) -> [UInt8] { Self.i32(v) }
        let payload = [UInt8](repeating: 7, count: 16)
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0004".utf8) + [0] + i32(1) + i32(-1) + i32(0) + i32(1)   // v4 필드=0(변형 없음), mipCount=1
        b += i32(4) + i32(4) + i32(0) + i32(16) + i32(payload.count) + payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.variants.count, 0)
        XCTAssertNotNil(t?.mip)
        XCTAssertEqual(t?.selectedMip(properties: ["tuniccolor": .string("2")])?.payloadRange, t?.mip?.payloadRange)
    }

    /// 변형 섹션 헤더가 체인 수와 불일치하면 variants=[](기본 mip 무회귀 — 방어).
    func testMalformedVariantSectionFallsBackToDefault() {
        func i32(_ v: Int) -> [UInt8] { Self.i32(v) }
        let payload = [UInt8](repeating: 0x44, count: 16)
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0004".utf8) + [0] + i32(1) + i32(-1) + i32(2)            // 변형수 2
        b += i32(1) + i32(1) + i32(0) + Self.cond("2") + [0]                     // 조건 2개
        b += i32(1) + i32(2) + i32(0) + Self.cond("1") + [0]
        b += i32(1) + i32(4) + i32(4) + i32(0) + i32(16) + i32(payload.count) + payload  // 기본 mip
        b += i32(1) + i32(99)                                                    // 섹션 변형수=99 ≠ 체인 2
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.variants.count, 0, "섹션 변형수 불일치 → 변형 없음")
        XCTAssertNotNil(t?.mip, "기본 mip 은 온전")
    }

    /// VariantCondition(json:) 직접: 실측 문법 파스, 잘못된 구조/타입 → nil.
    func testVariantConditionJSONParsing() {
        let ok = TexImage.VariantCondition(json: #"{"condition":{"condition":"2","name":"tuniccolor"}}"#)
        XCTAssertEqual(ok, TexImage.VariantCondition(name: "tuniccolor", value: "2"))
        // 숫자값도 허용(문자열화)
        XCTAssertEqual(TexImage.VariantCondition(json: #"{"condition":{"condition":2,"name":"x"}}"#)?.value, "2")
        // name 누락 / 구조 불일치 → nil
        XCTAssertNil(TexImage.VariantCondition(json: #"{"condition":{"condition":"2"}}"#))
        XCTAssertNil(TexImage.VariantCondition(json: #"{"foo":1}"#))
        XCTAssertNil(TexImage.VariantCondition(json: "not json"))
    }
}
