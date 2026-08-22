import XCTest
@testable import WapleRender

/// CJ: `BlendMSL.source`(MSL 쌍둥이)의 **식**을 문면으로 잠근다.
///
/// 형제 `Tests/WapleCoreTests/BlendModeFormulaParityTests` 가 같은 사실을 GLSL 심에 대해
/// **동봉 헤더에서 파스한 기대값으로** 잠근다. 그쪽은 리눅스에서 실행되지만 `WapleRender` 를
/// 볼 수 없다. 이 파일은 macOS 에서만 실행된다(리눅스는 타입체크만) — 그래서 여기서는
/// **헤더를 다시 파스하지 않고**, 갈리면 화면이 바뀌는 자리만 짧게 못 박는다.
///
/// 왜 이 다섯인가: 2026-08-21 에 WE 원문 · 이 파일 · GLSL 심 셋을 격자로 대조해
/// **[0,1] 입력에서 어긋나는 자리가 0** 임을 확인했다(`docs/re/material-blend.md` §7.6.4).
/// 그 대조는 사람이 한 번 돌린 것이고 CI 에 없다. 아래 다섯은 그 대조가 통과한 상태에서
/// **되돌리기 쉬운 자리**들이다 — 전부 "고치고 싶어지는" 원본 결함이거나 관용구 차이다.
final class BlendMSLFormulaParityTests: XCTestCase {

    /// `applyBlending` 본문의 `case n:` → 그 팔의 문면(다음 `case`/`default` 직전까지).
    private static func arms() -> [Int: String] {
        let src = BlendMSL.source
        guard let fn = src.range(of: "inline float3 applyBlending(int mode,") else { return [:] }
        let body = String(src[fn.upperBound...])
        var out: [Int: String] = [:]
        var pending: Int?
        var buf = ""
        for raw in body.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("case ") || line.hasPrefix("default:") {
                if let n = pending { out[n] = buf.trimmingCharacters(in: .whitespaces) }
                pending = nil
                buf = ""
                if line.hasPrefix("case ") {
                    let digits = line.dropFirst("case ".count).prefix { $0.isNumber }
                    pending = Int(digits)
                    if let colon = line.firstIndex(of: ":") {
                        buf = String(line[line.index(after: colon)...])
                    }
                }
                continue
            }
            if pending != nil { buf += " " + line }
        }
        if let n = pending { out[n] = buf.trimmingCharacters(in: .whitespaces) }
        return out
    }

    /// 모드 4 와 20 은 원본에서 **문자 그대로 같은 매크로**(`BlendSubstract`)다. UI 이름만
    /// `linear_burn` / `subtract` 로 갈린다(`docs/re/material-blend.md` §7.6.2). 원본의 결함이고,
    /// "20 을 진짜 뺄셈으로 고치는" 편집이 들어오면 워크샵 자산이 우리에서만 다르게 보인다.
    func testMode20IsLiterallyMode4() {
        let a = Self.arms()
        let four = (a[4] ?? "").replacingOccurrences(of: " ", with: "")
        let twenty = (a[20] ?? "").replacingOccurrences(of: " ", with: "")
        XCTAssertFalse(four.isEmpty, "case 4 를 못 찾았다")
        // 주석(`// Subtract` / `// Substract(=4)`)만 다르므로 식 부분만 견준다.
        func expr(_ s: String) -> String { String(s.split(separator: "/").first ?? "") }
        XCTAssertEqual(expr(four), expr(twenty),
                       "모드 20 이 모드 4 와 다른 식이 됐다 — 원본은 같은 매크로다: \(four) vs \(twenty)")
    }

    /// 13(HardLight) · 22(Glow) 는 원본에서 인자를 **뒤집어** 넘긴다
    /// (`BlendHardLight(base,blend) = BlendOverlay(blend,base)`).
    func testArgumentSwappedModes() {
        let a = Self.arms()
        XCTAssertTrue((a[13] ?? "").contains("we_overlay(B, A)"),
                      "case 13 이 we_overlay(B, A) 가 아니다: \(a[13] ?? "<없음>")")
        XCTAssertTrue((a[22] ?? "").contains("we_reflect(B, A)"),
                      "case 22 가 we_reflect(B, A) 가 아니다: \(a[22] ?? "<없음>")")
        XCTAssertTrue((a[11] ?? "").contains("we_overlay(A, B)"),
                      "case 11(Overlay)은 뒤집지 않는다: \(a[11] ?? "<없음>")")
        XCTAssertTrue((a[21] ?? "").contains("we_reflect(A, B)"),
                      "case 21(Reflect)은 뒤집지 않는다: \(a[21] ?? "<없음>")")
    }

    /// 5 · 10 · 31 은 opacity 를 **안 쓴다**(원본이 `mix` 없이 즉시 반환한다).
    /// 32 는 즉시 반환이 아니라 `mix` 로 나가므로 여기 끼면 안 된다.
    func testOpacityIgnoringModes() {
        let a = Self.arms()
        for n in [5, 10, 31] {
            let arm = a[n] ?? ""
            XCTAssertTrue(arm.hasPrefix("return "),
                          "case \(n) 이 즉시 반환이 아니다 — opacity 가 섞인다: \(arm)")
            XCTAssertFalse(arm.contains("mix("), "case \(n) 에 mix 가 생겼다: \(arm)")
        }
        for n in [4, 9, 32] {
            let arm = a[n] ?? ""
            XCTAssertTrue(arm.contains("break;"),
                          "case \(n) 은 mix(A, r, o) 로 나가야 한다: \(arm)")
        }
    }

    /// `f` 접미 매크로는 클램프가 없다(`BlendLinearDodgef(base,blend) = base + blend`).
    /// 모드 15 의 `s >= 0.5` 가지가 그것을 쓰므로 **1을 넘을 수 있고**, 클램프는 렌더타깃이 한다.
    func testLinearLightSecondBranchIsUnclamped() {
        let src = BlendMSL.source
        guard let r = src.range(of: "inline float3 we_linearlight("),
              let end = src[r.upperBound...].firstIndex(of: "\n") else {
            return XCTFail("we_linearlight 를 못 찾았다")
        }
        let line = String(src[r.lowerBound..<end])
        XCTAssertTrue(line.contains("b+2.0*(s-0.5)"),
                      "LinearLight 의 dodge 가지가 원본 식이 아니다: \(line)")
        XCTAssertFalse(line.contains("min("),
                       "LinearLight 에 min 이 생겼다 — 원본 f 변형은 클램프가 없다: \(line)")
    }

    /// F676: 원본은 `#ifdef HDR` 안에서만 saturate 하지만 우리는 단일 소스라 **무조건** 적용한다.
    /// LDR(UNORM ≤1)에서는 항등이므로 무회귀이고, HDR >1 입력의 모드 26–29 왜곡을 봉인한다.
    func testRGB2HSLSaturatesUnconditionally() {
        let src = BlendMSL.source
        guard let r = src.range(of: "inline float3 we_rgb2hsl(float3 c) {") else {
            return XCTFail("we_rgb2hsl 을 못 찾았다")
        }
        // `contains` 가 아니라 **줄 전문 일치**로 본다 — 주석 처리(`// c = saturate(c);`)를
        // `contains` 는 못 잡는다(CJ 돌연변이 M7 에서 실측했다).
        let head = src[r.upperBound...].prefix(400)
        let hasLine = head.split(whereSeparator: { $0.isNewline })
            .contains { $0.trimmingCharacters(in: .whitespaces) == "c = saturate(c);" }
        XCTAssertTrue(hasLine,
                      "we_rgb2hsl 이 saturate 를 선적용하지 않는다(주석 처리 포함, F676): \(head.prefix(120))")
    }
}
