import XCTest
@testable import WapleCore

/// CJ: `BuiltinShaderIncludes.commonBlending`(GLSL 심)의 **식**이 동봉 원본
/// `shaders/common_blending.h` 와 갈리지 않는지를, **기대값을 원본에서 읽어** 잠근다.
///
/// 형제 `BlendModeDomainTests` 는 **모드 번호 집합**만 본다 — 팔이 다 있는지. 식이 맞는지는
/// 어느 리눅스 테스트도 보지 않았다. `Tests/WapleRenderTests/BlendModeCoverageTests` 가
/// `BlendMSL` 쪽을 보지만 **리눅스에서는 실행되지 않고 타입체크만 된다**
/// (`docs/dev/re-methodology.md` §4.1 마지막 두 문단). 그래서 이 파일이 필요하다.
///
/// **자기 산수를 단언하지 않는다.** 기대값은 전부 동봉 헤더 원문에서 파스한다 — 리터럴 모드
/// 목록을 적지 않는 것이 규율이다(적으면 헤더가 바뀌어도 테스트가 옛 사실을 지킨다).
/// 헤더가 없으면(WEAssets 미배치) 스킵한다.
///
/// 잠그는 사실 다섯:
///  1. **opacity 를 무시하는 모드**(즉시 `return`) 집합이 원본과 심에서 같다.
///  2. **인자를 뒤집는 모드**(HardLight = Overlay(blend, base) 꼴)가 심에서도 뒤집혀 있다.
///  3. **식이 완전히 같은 모드 쌍**(원본의 4 와 20)이 심에서도 같은 식이다 — 원본의 결함을
///     "고치면" 워크샵 자산이 우리에서만 다르게 보인다.
///  4. **클램프 없는 `f` 변형**(`BlendLinearDodgef`)이 심에서도 클램프 없다.
///  5. `RGBToHSL` 의 `saturate` 가 원본에서는 `#ifdef HDR` 안인데 심은 **무조건** 적용한다 —
///     의도적 이탈(F676)이므로 "원본과 같게" 되돌리는 편집을 여기서 막는다.
final class BlendModeFormulaParityTests: XCTestCase {

    // MARK: - 원본 헤더

    /// 동봉 자산 루트(`BlendModeDomainTests.assetsRoot` 와 같은 규약).
    private static func assetsRoot() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
           fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func bundledHeader() throws -> String {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WEAssets 미배치(WAPLE_WE_ASSETS 미지정)") }
        let url = root.appendingPathComponent("shaders/common_blending.h")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("동봉 common_blending.h 없음: \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 동봉 헤더는 **CRLF** 다. Swift `String` 은 그래핌 클러스터 단위라 `"\r\n"` 이 한 개의
    /// `Character` 이고 `"\n"` 과 같지 않다 — `split(separator: "\n")` 은 한 줄도 못 쪼갠다
    /// (방법론 함정 24). `isNewline` 으로 쪼갠다.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 원본 `ApplyBlending` 의 `#if BLENDMODE == n` 팔 → 그 팔의 `return` 문 전문.
    static func originalArms(header: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var cur: Int?
        for line in lines(header) {
            if line.hasPrefix("#if BLENDMODE ==") {
                let tail = line.dropFirst("#if BLENDMODE ==".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cur = Int(tail)
                continue
            }
            if line == "#endif" { cur = nil; continue }
            if let n = cur, line.hasPrefix("return ") { out[n] = line }
        }
        return out
    }

    /// 원본의 `#define <Name>(base, blend) <본문>` 표.
    static func originalMacros(header: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(header) {
            guard line.hasPrefix("#define ") else { continue }
            let body = line.dropFirst("#define ".count)
            guard let paren = body.firstIndex(of: "("),
                  let close = body.firstIndex(of: ")") else { continue }
            let name = String(body[body.startIndex..<paren])
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
            else { continue }
            out[name] = String(body[body.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    // MARK: - GLSL 심

    /// 심 `ApplyBlending` 의 `mode == n` 팔 → 그 팔의 본문(중괄호 안).
    static func shimArms(source: String) -> [Int: String] {
        guard let fn = source.range(of: "vec3 ApplyBlending(int mode,") else { return [:] }
        var out: [Int: String] = [:]
        var rest = Substring(source[fn.lowerBound...])
        while let hit = rest.range(of: "mode == ") {
            let after = rest[hit.upperBound...]
            let digits = after.prefix { $0.isNumber }
            guard let n = Int(digits),
                  let open = after.firstIndex(of: "{"),
                  let close = after[open...].firstIndex(of: "}") else { rest = after; break }
            out[n] = String(after[after.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rest = after[close...]
        }
        return out
    }

    // MARK: - 1. opacity 무시 모드

    func testNoOpacityModesMatchTheOriginal() throws {
        let arms = Self.originalArms(header: try bundledHeader())
        XCTAssertEqual(arms.count, 32, "원본의 #if 팔이 32개가 아니다: \(arms.count)")
        // 원본에서 `return mix(A,…,opacity)` 가 **아닌** 팔 = opacity 를 안 쓰는 모드.
        let originalNoOpacity = Set(arms.filter { !$0.value.hasPrefix("return mix(A,") }.keys)
        XCTAssertFalse(originalNoOpacity.isEmpty, "원본에 opacity 무시 팔이 하나도 없다 — 파스 실패")

        // 심에서 `return` 으로 즉시 빠지는 팔.
        let shim = Self.shimArms(source: BuiltinShaderIncludes.commonBlending)
        XCTAssertEqual(shim.count, 32, "심의 mode == n 팔이 32개가 아니다: \(shim.count)")
        // 심도 같은 규칙으로 가른다 — `return mix(A, …, o)` 는 **opacity 를 쓰는** 즉시 반환이다
        // (모드 32 가 그 꼴이다). `hasPrefix("return ")` 만 보면 32 를 잘못 센다.
        let shimNoOpacity = Set(shim.filter {
            $0.value.hasPrefix("return ") && !$0.value.contains("mix(A,")
        }.keys)

        XCTAssertEqual(shimNoOpacity, originalNoOpacity,
                       "opacity 무시 모드 집합이 원본과 다르다 — 원본 \(originalNoOpacity.sorted()) · 심 \(shimNoOpacity.sorted())")
    }

    // MARK: - 2. 인자를 뒤집는 모드

    func testArgumentSwappedModesStaySwapped() throws {
        let header = try bundledHeader()
        let macros = Self.originalMacros(header: header)
        let arms = Self.originalArms(header: header)
        let shim = Self.shimArms(source: BuiltinShaderIncludes.commonBlending)

        // 원본에서 `#define X(base, blend) BlendY(blend, base)` 꼴 = **다른 블렌드 매크로에**
        // 인자를 뒤집어 넘기는 것. `min(blend, base)` 같은 내장 함수는 뒤집기가 아니라
        // 교환법칙이 성립하는 식이므로 `Blend…` 접두를 요구해 가른다.
        let swapped = macros.filter {
            $0.value.range(of: "^Blend[A-Za-z0-9_]*\\(blend, base\\)$",
                           options: .regularExpression) != nil
        }.keys.sorted()
        XCTAssertFalse(swapped.isEmpty, "원본에 인자 뒤집기 매크로가 없다 — 파스 실패")

        for name in swapped {
            // 그 매크로를 쓰는 모드 번호를 팔에서 찾는다.
            let users = arms.filter { $0.value.contains(name + "(A,B)") }.keys.sorted()
            XCTAssertEqual(users.count, 1, "\(name) 을 쓰는 팔이 정확히 하나가 아니다: \(users)")
            guard let n = users.first, let body = shim[n] else {
                return XCTFail("심에 mode == \(users) 팔이 없다")
            }
            XCTAssertTrue(body.contains("(B, A)"),
                          "mode \(n)(원본 \(name))이 심에서 인자를 뒤집지 않았다: \(body)")
        }
    }

    // MARK: - 3. 식이 같은 모드 쌍

    func testDuplicateFormulaModesStayDuplicated() throws {
        let arms = Self.originalArms(header: try bundledHeader())
        var byExpr: [String: [Int]] = [:]
        for (n, line) in arms { byExpr[line, default: []].append(n) }
        let dupes = byExpr.values.filter { $0.count > 1 }.map { $0.sorted() }
        XCTAssertFalse(dupes.isEmpty,
                       "원본에 완전히 같은 식을 가진 모드 쌍이 없다 — 파스 실패(4 와 20 이 그 쌍이다)")

        let shim = Self.shimArms(source: BuiltinShaderIncludes.commonBlending)
        for group in dupes {
            let bodies = group.compactMap { shim[$0] }
            XCTAssertEqual(bodies.count, group.count, "심에 \(group) 팔이 다 있지 않다")
            XCTAssertEqual(Set(bodies).count, 1,
                           "원본에서 같은 식인 모드 \(group) 가 심에서는 갈렸다: \(bodies)")
        }
    }

    // MARK: - 4. 클램프 없는 f 변형

    func testUnclampedLinearDodgeStaysUnclamped() throws {
        let macros = Self.originalMacros(header: try bundledHeader())
        let dodgeF = try XCTUnwrap(macros["BlendLinearDodgef"], "BlendLinearDodgef 를 못 찾았다")
        // 원본: `(base + blend)` — min/clamp 가 없다. 형제 `BlendLinearDodge`(f 없음)에는 min 이 있다.
        XCTAssertFalse(dodgeF.contains("min("), "원본 BlendLinearDodgef 에 min 이 생겼다: \(dodgeF)")
        XCTAssertFalse(dodgeF.contains("clamp("), "원본 BlendLinearDodgef 에 clamp 가 생겼다: \(dodgeF)")
        let dodge = try XCTUnwrap(macros["BlendLinearDodge"], "BlendLinearDodge 를 못 찾았다")
        XCTAssertTrue(dodge.contains("min("),
                      "원본 BlendLinearDodge(비-f)에 min 이 없다 — 두 변형 구분이 깨졌다: \(dodge)")

        // 심의 LinearLight 는 blend>=0.5 가지에서 그 f 변형을 쓴다 → 클램프가 없어야 한다.
        let src = BuiltinShaderIncludes.commonBlending
        guard let fn = src.range(of: "vec3 BlendLinearLightEx(vec3 b, vec3 s) {"),
              let close = src[fn.upperBound...].firstIndex(of: "}") else {
            return XCTFail("심에서 BlendLinearLightEx 를 못 찾았다")
        }
        let body = String(src[fn.upperBound..<close])
        XCTAssertFalse(body.contains("min("),
                       "심의 BlendLinearLightEx 에 min 이 생겼다 — 원본 f 변형은 클램프가 없다: \(body)")
    }

    // MARK: - 5. HDR saturate 는 의도적 이탈이다

    func testRGB2HSLSaturateIsADeliberateDeviation() throws {
        let lines = Self.lines(try bundledHeader())
        // 원본: RGBToHSL 머리에서 `#ifdef HDR` 로 감싼 saturate.
        guard let fnIdx = lines.firstIndex(where: { $0.hasPrefix("vec3 RGBToHSL(") }) else {
            return XCTFail("원본에서 RGBToHSL 을 못 찾았다")
        }
        let head = lines[fnIdx..<min(fnIdx + 8, lines.count)]
        XCTAssertTrue(head.contains("#ifdef HDR"),
                      "원본 RGBToHSL 머리에 #ifdef HDR 이 없다 — F676 이탈의 전제가 바뀌었다: \(Array(head))")
        XCTAssertTrue(head.contains(where: { $0.contains("saturate(color)") }),
                      "원본 RGBToHSL 의 saturate 가 사라졌다: \(Array(head))")

        // 심: 조건 없이 적용한다(우리는 LDR/HDR 단일 소스라 퍼뮤테이션을 굽지 않는다).
        //
        // **`contains` 로 보면 안 된다** — 이 단언을 `contains("c = saturate(c);")` 로 뒀더니
        // 그 줄을 `// c = saturate(c);` 로 주석 처리하는 돌연변이를 **못 잡았다**(CJ 돌연변이 M7).
        // 줄을 다듬어 **전문 일치**로 본다. 형제 단언
        // (`BuiltinShaderIncludesTests.testRGB2HSLSaturatesInputLikeBlendMSL` ·
        // `RenderColorFixRegressionTests`)에도 같은 구멍이 있다 — 보고서에 패치안으로 넘겼다.
        let src = BuiltinShaderIncludes.commonBlending
        XCTAssertTrue(Self.lines(src).contains("c = saturate(c);"),
                      "심 rgb2hsl 이 saturate 를 선적용하지 않는다(주석 처리 포함) — BlendMSL we_rgb2hsl(F676)과 불일치")
        // 심은 전처리기 분기를 **코드로** 갖지 않는다(런타임 int 규약). 주석에는 원본 문면을
        // 인용하므로 `contains` 로 보면 오탐이다 — 줄 머리가 `#` 인 줄만 센다.
        let directives = Self.lines(src).filter { $0.hasPrefix("#") }
        XCTAssertTrue(directives.isEmpty,
                      "심에 전처리기 지시자가 생겼다 — 심은 런타임 int 규약이다: \(directives)")
    }
}
