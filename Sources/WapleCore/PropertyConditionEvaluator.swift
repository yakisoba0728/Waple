import Foundation

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
        let normalized = replaceIncludes(in: condition, values: values)
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
