import Foundation

/// 사용자 프로퍼티의 `condition`(표시 조건식) 평가기.
///
/// **문법의 정체는 AngularJS 표현식이다** — 그리고 그 파서를 이번에 실물에서 직접 떴다
/// (2026-08-21 클러스터 K). WE 의 브라우저 UI 가 `evalCondition = function(e){ return ….$eval(e, …) }`
/// 로 평가하고(`ui/dist/scripts/scripts.js` **byte** @106657 편집기 · @375400 프로퍼티 목록 ·
/// @613938 플러그인 설정), 그 `$eval` 이 부르는 파서는 번들된 AngularJS **1.6.10**
/// (`ui/dist/scripts/vendor.js`, `full:"1.6.10"` @byte 98389)의 재귀하강 파서다.
/// 우선순위 사슬은 `vendor.js` byte @167616 부터 그대로 읽힌다:
/// ```
/// assignment     → ternary ( "=" assignment )?
/// ternary        → logicalOR ( "?" expression ":" expression )?
/// logicalOR      → logicalAND ( "||" logicalAND )*                     ; 좌결합 반복
/// logicalAND     → equality  ( "&&" equality )*
/// equality       → relational ( ("=="|"!="|"==="|"!==") relational )*  ; @167616
/// relational     → additive ( ("<"|">"|"<="|">=") additive )*          ; @167789
/// additive       → multiplicative ( ("+"|"-") multiplicative )*        ; @167960
/// multiplicative → unary ( ("*"|"/"|"%") unary )*                      ; @168124
/// unary          → ("+"|"-"|"!") unary | primary                       ; @168262
/// ```
/// `wallpaper64.exe` 쪽에는 이 식을 평가하는 자리가 없다 — `condition` 은 **설정 패널의 표시
/// 여부**이지 렌더 파이프라인 입력이 아니다. Waple 도 같은 자리에서만 쓴다
/// (`PropertyDecoration.visibleIndices` → `PropertyEditorView`, 그리고 분석기
/// `WallpaperCompatibilityAnalyzer` 의 `canEvaluate` 경고).
///
/// **아래 파서가 실물과 갈리는 지점**(전부 설치본 코퍼스 도달 0 — `condition` 문자열 22건 /
/// 고유 16종 전수 확인, 아래 §도달 참조. 고치지 않은 이유는 각 항목에 적었다):
///
/// 1. **equality 와 relational 이 한 레벨이고 반복하지 않는다.** `parseComparison` 은 여덟 연산자를
///    한 묶음으로 보고 **한 번만** 소비한다. 그래서 Angular 가 `(a==b)==c` 로 읽는 `a == b == c`,
///    `(a>b)==c` 로 읽는 `a > b == c`, `a == (b>c)` 로 읽는 `a == b > c` 를 Waple 은 **파스 실패**
///    (`nil`)로 흘린다 → `isVisible` 은 관용적으로 **표시**한다. 실패 방향이 "숨김" 이 아니라
///    "표시" 라 조건식을 못 읽어도 토글이 사라지지는 않는다. 코퍼스 도달 0(비교 연산자가 둘 이상
///    연쇄하는 조건이 22건 중 0건 — `&&` 로만 이어진다).
/// 2. **`+ - * / %` 와 단항 `+`/`-` 가 없다.** 토크나이저가 미지 연산자를 만나면 `failed` 로
///    전체를 파스 실패시킨다(부분 평가로 엉뚱한 확정을 내는 것보다 안전). 코퍼스 도달 0.
/// 3. **`==` 와 `===` 를 구분하지 않는다.** `equals()` 가 먼저 `number()` 로 양변을 수치화하므로
///    `'1' === 1` 이 **true** 다(JS/Angular 는 `false`). 반대로 느슨한 쪽도 완전하지는 않다 —
///    `'' == 0` 은 JS 가 `true` 인데 여기서는 `Double("")` 이 nil 이라 `false` 다.
///    코퍼스 도달 0: `===`/`!==` 를 쓰는 12건은 전건 좌변이 문자열 프로퍼티이고 우변이 문자열
///    리터럴 또는 `true`/`false` 라 두 규약이 같은 답을 낸다.
/// 4. **`&&`/`||` 가 피연산자가 아니라 `Bool` 을 돌려준다.** Angular 는 JS 처럼 피연산자를
///    돌려주지만, 이 평가기의 최종 소비는 `truthy` 하나뿐이라 관측 차이가 없다.
///
/// **도달**(설치본 전수, 2026-08-21 재측정 — 동봉 트리 0건 · `assets/` 0건 · `projects/` **22건**):
/// 고유 16종은 `'1'`×4 · `scene.value !== 'cartoon' && scene.value !== 'ram'`×3 ·
/// `effect.value.startsWith('rainbow') === false`×2 · `'0'` · `''` · `style.value=='1'` ·
/// `rainbowscheme.value` · `showbottom.value > 0` · `effect.value === 'visor'` ·
/// `effect.value.endsWith(…) === true` 계열 7종이다. 전건이 위 문법 부분집합 안에 들어온다.
public enum PropertyConditionEvaluator {
    public static func isVisible(_ property: WallpaperProperty, in properties: [WallpaperProperty]) -> Bool {
        guard let condition = property.condition?.trimmingCharacters(in: .whitespacesAndNewlines),
              !condition.isEmpty else { return true }
        // 중복 키는 **뒤가 이긴다**(uniquingKeysWith). properties 는 공개 API 가 받는 호출자 배열이라
        // 같은 key 가 두 번 들어올 수 있고, 종전 `uniqueKeysWithValues` 는 그 입력에서 그대로 트랩했다
        // (파서 버그가 아니라 입력 데이터로 프로세스가 죽는 경로). 뒤가 이기는 선택은 WE 가 나중 선언을
        // 유효 선언으로 쓰는 것과 같은 방향이다.
        let values = Dictionary(properties.map { ($0.key, $0.value) }, uniquingKeysWith: { _, later in later })
        return evaluate(condition, values: values) ?? true
    }

    public static func visibleIndices(in properties: [WallpaperProperty]) -> [Int] {
        properties.indices.filter { isVisible(properties[$0], in: properties) }
    }

    public static func canEvaluate(_ condition: String) -> Bool {
        // F423: 최상위 삼항을 guard 부분만으로 축약 평가한 경우(갈래가 미지원 문법)는
        // "평가 가능"이 아니다 — false 로 돌려 analyzer 의 propertyDisplayCondition 경고가 나가게 한다.
        evaluate(condition, values: [:], ternaryDepth: 0).exact
    }

    public static func evaluate(_ condition: String, values: [String: PropertyValue]) -> Bool? {
        evaluate(condition, values: values, ternaryDepth: 0).value
    }

    /// 재귀 평가 코어. exact=false 는 "결과는 냈지만 WE 의 실제 분기와 다를 수 있는 관용값"
    /// (최상위 삼항의 guard-only 폴백)을 뜻한다 — canEvaluate 는 이 경우 false 여야 한다.
    private static func evaluate(_ condition: String, values: [String: PropertyValue],
                                 ternaryDepth: Int) -> (value: Bool?, exact: Bool) {
        // F423: 최상위 삼항 `guard ? then : else` — 종전엔 guard 만 평가해(절단) 분기 값의
        // truthiness 가 guard 와 다를 때 표시 여부가 반대로 됐다. 양 갈래를 재귀 평가해 셋 다
        // 깨끗이 되면 실제 삼항 결과를 낸다. 갈래가 미지원 문법(대입식 등 — 실물 corpus 의
        // `effect.text = 'x'` 류)이면 종전 guard-only 관용을 유지하되 exact=false 로 표시한다.
        if ternaryDepth < 32, let ternary = splitTopLevelTernary(condition) {
            let g = evaluate(String(ternary.condition), values: values, ternaryDepth: ternaryDepth + 1)
            let t = evaluate(String(ternary.whenTrue), values: values, ternaryDepth: ternaryDepth + 1)
            let e = evaluate(String(ternary.whenFalse), values: values, ternaryDepth: ternaryDepth + 1)
            if g.exact, t.exact, e.exact, let gv = g.value, let tv = t.value, let ev = e.value {
                return (gv ? tv : ev, true)
            }
            // F694: 갈래가 대입식(`a ? x.text = '…' : x.text = '…'` — 실물 1081733658 의 18개 조건)이면
            // WE 는 JS 로 평가해 대입 결과값(비어있지 않은 문자열)이 항상 truthy → 토글 항상 표시.
            // 종전 guard-only 관용(g.value)은 기본값 false 인 토글을 영구 은닉시켰다. 대입 갈래는
            // truthy 로 근사해 삼항을 완성하되 근사 사용 시 exact=false(canEvaluate 는 계속 false).
            let tvApprox = t.value ?? (isAssignmentExpression(ternary.whenTrue) ? true : nil)
            let evApprox = e.value ?? (isAssignmentExpression(ternary.whenFalse) ? true : nil)
            if let gv = g.value, let tv = tvApprox, let ev = evApprox {
                return (gv ? tv : ev, false)
            }
            return (g.value, false)
        }
        let normalized = replaceStringMethods(in: replaceIncludes(in: condition, values: values),
                                              values: values)
        guard let tokens = Tokenizer(normalized).tokens() else { return (nil, false) }
        guard !tokens.isEmpty else { return (true, true) }
        var parser = Parser(tokens: tokens, values: values)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return (nil, false) }
        return (value.truthy, true)
    }

    /// 최상위(괄호/대괄호/따옴표 밖) 첫 `?` 와 그 짝 `:` 로 삼항을 셋으로 분할 — 중첩 삼항은
    /// 깊이 추적으로 건너뛴다(`a ? b ? c : d : e` 의 짝 `:` 는 마지막). 짝 `:` 가 없으면 nil.
    private static func splitTopLevelTernary(_ condition: String)
        -> (condition: Substring, whenTrue: Substring, whenFalse: Substring)? {
        var parenDepth = 0
        var bracketDepth = 0
        var ternaryDepth = 0
        var quote: Character?
        var previous: Character?
        var questionIndex: String.Index?
        for i in condition.indices {
            let char = condition[i]
            if let currentQuote = quote {
                if char == currentQuote, previous != "\\" { quote = nil }
                previous = char
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
            } else if char == "(" {
                parenDepth += 1
            } else if char == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if char == "[" {
                bracketDepth += 1
            } else if char == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if parenDepth == 0, bracketDepth == 0 {
                if char == "?" {
                    if questionIndex == nil { questionIndex = i }
                    ternaryDepth += 1
                } else if char == ":", ternaryDepth > 0 {
                    ternaryDepth -= 1
                    if ternaryDepth == 0, let q = questionIndex {
                        return (condition[..<q],
                                condition[condition.index(after: q)..<i],
                                condition[condition.index(after: i)...])
                    }
                }
            }
            previous = char
        }
        return nil
    }

    /// F694: 식이 최상위 대입(`lhs = rhs`)을 포함하는가 — 따옴표 밖의 단독 `=` 탐지
    /// (`==`/`===`/`!=`/`>=`/`<=` 등 비교 연산은 양옆 문자로 제외). JS 대입식의 값은 대입된 값이다.
    private static func isAssignmentExpression(_ expr: Substring) -> Bool {
        var quote: Character?
        var previous: Character?
        let chars = Array(expr)
        for (i, char) in chars.enumerated() {
            if let currentQuote = quote {
                if char == currentQuote, previous != "\\" { quote = nil }
                previous = char
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
            } else if char == "=" {
                let prev = previous
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if prev != "=" && prev != "!" && prev != ">" && prev != "<" && next != "=" { return true }
            }
            previous = char
        }
        return false
    }

    private static func replaceIncludes(in condition: String, values: [String: PropertyValue]) -> String {
        let pattern = #"\[([^\]]*)\]\.includes\(([A-Za-z0-9_\.]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return condition }
        let nsRange = NSRange(condition.startIndex..<condition.endIndex, in: condition)
        let matches = regex.matches(in: condition, range: nsRange).reversed()
        var out = condition
        for match in matches {
            guard let full = Range(match.range(at: 0), in: out),
                  let listRange = Range(match.range(at: 1), in: out),
                  let refRange = Range(match.range(at: 2), in: out) else { continue }
            let literals = String(out[listRange]).split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let ref = String(out[refRange])
            let value = value(forReference: ref, values: values)
            out.replaceSubrange(full, with: literals.contains { literalMatches($0, value) } ? "true" : "false")
        }
        return out
    }

    /// `ref.startsWith('x')` / `endsWith` / `includes` → `true`/`false` 로 미리 접는다.
    ///
    /// **근거**: `condition` 은 JS 가 아니라 **AngularJS 표현식**이다 — 브라우저 UI 가
    /// `evalCondition(e) { return scope.$eval(e, currentSelection.properties[location]) }` 로 평가하고
    /// (`ui/dist/scripts/scripts.js` @106522), 에디터 프로퍼티 목록도 같은 `$eval` 을 쓴다(@375231).
    /// 그래서 문자열 메서드 호출이 그대로 성립한다.
    ///
    /// **도달**: WE 설치본의 실물 `condition` 22건(고유 16종) 중 **9건(고유 8종)** 이 이 형태다
    /// (`projects/defaultprojects/corsair_collection/project.json` 의
    /// `effect.value.endsWith('pulse') === true` 류). 종전에는 `effect.value.startsWith` 가 식별자로
    /// 토큰화된 뒤 남은 `('rainbow')` 때문에 파스 실패 → 조건 무시(항상 표시)로 흘렀다.
    /// 반대로 이미 지원하던 `[a,b].includes(x)` 배열 형태는 이 코퍼스 도달이 0 이다.
    ///
    /// 좌변이 문자열이 아닐 때만 손대지 않는다(JS 에서도 숫자·불리언에는 이 메서드가 없어
    /// TypeError 다). 좌변이 **부재**면 빈 문자열로 접는다 — `canEvaluate` 가 값 없이(`[:]`)
    /// 문법 가능 여부만 물어보는 경로를 살리기 위한 것이고, `replaceIncludes` 가 부재를
    /// "어느 리터럴과도 불일치 = false" 로 접는 것과 같은 방향이다.
    private static func replaceStringMethods(in condition: String,
                                             values: [String: PropertyValue]) -> String {
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\."#
            + #"(startsWith|endsWith|includes)\(\s*(?:'([^']*)'|"([^"]*)")\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return condition }
        var out = condition
        let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
        for match in regex.matches(in: out, range: nsRange).reversed() {
            guard let full = Range(match.range(at: 0), in: out),
                  let refRange = Range(match.range(at: 1), in: out),
                  let opRange = Range(match.range(at: 2), in: out) else { continue }
            let literalRange = Range(match.range(at: 3), in: out) ?? Range(match.range(at: 4), in: out)
            guard let litRange = literalRange else { continue }
            let haystack: String
            switch value(forReference: String(out[refRange]), values: values) {
            case .string(let s): haystack = s
            case .none: haystack = ""
            case .number, .bool: continue      // JS 에서도 메서드가 없다 — 손대지 않고 파스 실패로 둔다
            }
            let literal = String(out[litRange])
            let result: Bool
            switch String(out[opRange]) {
            case "startsWith": result = haystack.hasPrefix(literal)
            case "endsWith": result = haystack.hasSuffix(literal)
            default: result = literal.isEmpty || haystack.contains(literal)
            }
            out.replaceSubrange(full, with: result ? "true" : "false")
        }
        return out
    }

    private static func value(forReference ref: String, values: [String: PropertyValue]) -> PropertyValue {
        let key = ref.hasSuffix(".value") ? String(ref.dropLast(".value".count)) : ref
        return values[key] ?? .none
    }

    private static func literalMatches(_ literal: String, _ value: PropertyValue) -> Bool {
        let unquoted = literal.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        switch value {
        case .number(let number):
            return Double(unquoted) == number
        case .string(let string):
            return unquoted == string
        case .bool(let bool):
            return (unquoted == "true") == bool
        case .none:
            return false
        }
    }
}

private enum ConditionToken: Equatable {
    case identifier(String)
    case number(Double)
    case string(String)
    case bool(Bool)
    case op(String)
    case leftParen
    case rightParen
}

private struct Tokenizer {
    let input: [Character]
    var index = 0
    /// 미지 문자(+,* 등) 조우 — 잔여 토큰을 조용히 버리는 대신 조건 전체를 파스 실패로
    /// (nil → 호출측 visible 유지 폴백; "a+b>1" 이 "a" 만으로 확정 평가되는 것 방지).
    var failed = false

    init(_ string: String) {
        input = Array(string.replacingOccurrences(of: ";", with: " "))
    }

    func tokens() -> [ConditionToken]? {
        var tokenizer = self
        var tokens: [ConditionToken] = []
        while let token = tokenizer.nextToken() {
            tokens.append(token)
        }
        return tokenizer.failed ? nil : tokens
    }

    private mutating func nextToken() -> ConditionToken? {
        skipWhitespace()
        guard index < input.count else { return nil }
        let char = input[index]

        if char == "(" { index += 1; return .leftParen }
        if char == ")" { index += 1; return .rightParen }
        if char == "\"" || char == "'" { return readString(quote: char) }
        if char.isNumber || char == "-" { return readNumber() }
        if char.isLetter || char == "_" { return readIdentifier() }
        return readOperator()
    }

    private mutating func skipWhitespace() {
        while index < input.count, input[index].isWhitespace { index += 1 }
    }

    private mutating func readString(quote: Character) -> ConditionToken {
        index += 1
        var out = ""
        while index < input.count {
            let char = input[index]
            index += 1
            if char == quote { break }
            if char == "\\", index < input.count {
                out.append(input[index])
                index += 1
            } else {
                out.append(char)
            }
        }
        return .string(out)
    }

    private mutating func readNumber() -> ConditionToken {
        let start = index
        if input[index] == "-" { index += 1 }
        while index < input.count, input[index].isNumber { index += 1 }
        if index < input.count, input[index] == "." {
            index += 1
            while index < input.count, input[index].isNumber { index += 1 }
        }
        let raw = String(input[start..<index])
        return .number(Double(raw) ?? 0)
    }

    private mutating func readIdentifier() -> ConditionToken {
        let start = index
        while index < input.count {
            let char = input[index]
            if char.isLetter || char.isNumber || char == "_" || char == "." {
                index += 1
            } else {
                break
            }
        }
        let raw = String(input[start..<index])
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        return .identifier(raw)
    }

    private mutating func readOperator() -> ConditionToken? {
        let remaining = String(input[index..<input.count])
        for op in ["===", "!==", "&&", "||", "==", "!=", ">=", "<=", ">", "<", "!"] where remaining.hasPrefix(op) {
            index += op.count
            return .op(op)
        }
        failed = true   // 미지 토큰 — 부분 평가 대신 전체 파스 실패
        index += 1
        return nil
    }
}

private enum ConditionValue: Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case none

    var truthy: Bool {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .none: return false
        }
    }
}

private struct Parser {
    let tokens: [ConditionToken]
    let values: [String: PropertyValue]
    var index = 0
    // parsePrimary 자기재귀(괄호·`!` 중첩) 깊이 — 악성 중첩 입력의 스택 오버플로 방지.
    // 256 은 SceneDocument.world() 의 32 캡을 본떴으되 넉넉히 잡음(실제 조건식은 10 미만 중첩).
    var depth = 0
    private static let maxDepth = 256

    var isAtEnd: Bool { index >= tokens.count }

    mutating func parseExpression() -> ConditionValue? {
        parseOr()
    }

    private mutating func parseOr() -> ConditionValue? {
        guard var lhs = parseAnd() else { return nil }
        while match(.op("||")) {
            guard let rhs = parseAnd() else { return nil }
            lhs = .bool(lhs.truthy || rhs.truthy)
        }
        return lhs
    }

    private mutating func parseAnd() -> ConditionValue? {
        guard var lhs = parseComparison() else { return nil }
        while match(.op("&&")) {
            guard let rhs = parseComparison() else { return nil }
            lhs = .bool(lhs.truthy && rhs.truthy)
        }
        return lhs
    }

    /// AngularJS 1.6.10 은 여기를 **두 레벨**로 나누고 각각 좌결합으로 **반복**한다
    /// (`equality → relational (…)*` @vendor.js byte 167616 · `relational → additive (…)*` @167789).
    /// 여기는 여덟 연산자를 한 레벨로 묶고 **한 번만** 소비한다 — 연쇄하면 남은 토큰 때문에
    /// `parser.isAtEnd` 가 거짓이 되어 조건 전체가 파스 실패(`nil`)로 떨어지고, 호출부는
    /// 관용적으로 **표시**한다. 실물 코퍼스 22건에 비교 연산자 연쇄가 0건이라 도달 0 이다
    /// (타입 선언 주석 §1). 고치려면 두 레벨로 갈라 while 루프를 씌우면 되지만, 그러면
    /// `canEvaluate` 가 지금 false 를 돌리는 입력에서 true 로 바뀌어 분석기 경고
    /// (`WallpaperCompatibilityAnalyzer`)와 `DeepScan` 집계가 함께 움직인다 — 이 레인 밖이다.
    private mutating func parseComparison() -> ConditionValue? {
        guard let lhs = parsePrimary() else { return nil }
        guard case .op(let op)? = peek(), ["==", "===", "!=", "!==", ">", "<", ">=", "<="].contains(op) else {
            return lhs
        }
        index += 1
        guard let rhs = parsePrimary() else { return nil }
        return .bool(compare(lhs, rhs, op: op))
    }

    private mutating func parsePrimary() -> ConditionValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { return nil }  // 캡 초과 — 기존 파스실패 경로(nil) 재사용
        guard let token = advance() else { return nil }
        switch token {
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .identifier(let name):
            return value(for: name)
        case .op("!"):
            guard let value = parsePrimary() else { return nil }
            return .bool(!value.truthy)
        case .leftParen:
            guard let value = parseExpression(), match(.rightParen) else { return nil }
            return value
        case .rightParen, .op:
            return nil
        }
    }

    private func value(for name: String) -> ConditionValue {
        let key = name.hasSuffix(".value") ? String(name.dropLast(".value".count)) : name
        guard let value = values[key] else { return .none }
        switch value {
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .none: return .none
        }
    }

    private func compare(_ lhs: ConditionValue, _ rhs: ConditionValue, op: String) -> Bool {
        switch op {
        case "==", "===":
            return equals(lhs, rhs)
        case "!=", "!==":
            return !equals(lhs, rhs)
        case ">", "<", ">=", "<=":
            guard let l = number(lhs), let r = number(rhs) else { return false }
            if op == ">" { return l > r }
            if op == "<" { return l < r }
            if op == ">=" { return l >= r }
            return l <= r
        default:
            return false
        }
    }

    /// **`==` 와 `===` 를 같은 것으로 본다.** 양변을 먼저 `number()` 로 수치화해 비교하므로
    /// `'1' === 1` 이 true 다(Angular/JS 는 strict 라 false). 반대로 `'' == 0` 은 JS 가 true 인데
    /// 여기서는 `Double("")` 이 nil 이라 false 다 — 느슨한 쪽도 JS 규약 그대로는 아니다.
    /// 코퍼스 도달 0(타입 선언 주석 §3). 실물 조건은 전건 "문자열 프로퍼티 vs 문자열 리터럴"
    /// 또는 "bool vs bool" 이라 두 규약이 같은 답을 낸다.
    private func equals(_ lhs: ConditionValue, _ rhs: ConditionValue) -> Bool {
        if let l = number(lhs), let r = number(rhs) { return l == r }
        switch (lhs, rhs) {
        case (.bool(let l), .bool(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.none, .none): return true
        default: return String(describing: lhs) == String(describing: rhs)
        }
    }

    private func number(_ value: ConditionValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .bool(let bool): return bool ? 1 : 0
        case .string(let string): return Double(string)
        case .none: return nil
        }
    }

    private func peek() -> ConditionToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advance() -> ConditionToken? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func match(_ token: ConditionToken) -> Bool {
        guard peek() == token else { return false }
        index += 1
        return true
    }
}
