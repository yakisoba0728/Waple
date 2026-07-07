import Foundation

public enum PropertyConditionEvaluator {
    public static func isVisible(_ property: WallpaperProperty, in properties: [WallpaperProperty]) -> Bool {
        guard let condition = property.condition?.trimmingCharacters(in: .whitespacesAndNewlines),
              !condition.isEmpty else { return true }
        let values = Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })
        return evaluate(condition, values: values) ?? true
    }

    public static func visibleIndices(in properties: [WallpaperProperty]) -> [Int] {
        properties.indices.filter { isVisible(properties[$0], in: properties) }
    }

    public static func canEvaluate(_ condition: String) -> Bool {
        evaluate(condition, values: [:]) != nil
    }

    public static func evaluate(_ condition: String, values: [String: PropertyValue]) -> Bool? {
        let normalized = normalize(condition, values: values)
        let tokens = Tokenizer(normalized).tokens()
        guard !tokens.isEmpty else { return true }
        var parser = Parser(tokens: tokens, values: values)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value.truthy
    }

    private static func normalize(_ condition: String, values: [String: PropertyValue]) -> String {
        replaceIncludes(in: stripTopLevelTernary(condition), values: values)
    }

    private static func stripTopLevelTernary(_ condition: String) -> String {
        var parenDepth = 0
        var bracketDepth = 0
        var quote: Character?
        var previous: Character?
        for (offset, char) in condition.enumerated() {
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
            } else if char == "?", parenDepth == 0, bracketDepth == 0 {
                let index = condition.index(condition.startIndex, offsetBy: offset)
                return String(condition[..<index])
            }
            previous = char
        }
        return condition
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

    init(_ string: String) {
        input = Array(string.replacingOccurrences(of: ";", with: " "))
    }

    func tokens() -> [ConditionToken] {
        var tokenizer = self
        var tokens: [ConditionToken] = []
        while let token = tokenizer.nextToken() {
            tokens.append(token)
        }
        return tokens
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
