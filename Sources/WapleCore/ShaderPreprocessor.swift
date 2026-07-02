import Foundation

/// WE GLSL 전처리기: `[COMBO]` 기본값 + `#include` 인라인 + `#if/#ifdef/#else/#elif/#endif` 평가.
/// 순수(테스트 가능). 미발견 인클루드/미지원은 안전 무시(빈 줄)하고 로그.
public enum ShaderPreprocessor {
    /// - combos: scene.json 에서 온 명시적 콤보 값(소스의 [COMBO] 기본값보다 우선).
    /// - include: `#include "name"` → 헤더 소스(없으면 nil → 빈 인라인).
    public static func preprocess(_ source: String, combos: [String: Int],
                                  include: (String) -> String? = { _ in nil }) -> String {
        var defines = combos
        // [COMBO] 기본값(명시 combos 가 없을 때만 채움)
        for (name, def) in parseComboDefaults(source) where defines[name] == nil { defines[name] = def }
        let included = inlineIncludes(source, include: include, depth: 0)
        // 인라인된 헤더의 [COMBO] 기본값도 반영
        for (name, def) in parseComboDefaults(included) where defines[name] == nil { defines[name] = def }
        return evaluateConditionals(included, defines: defines)
    }

    /// `// [COMBO] {"combo":"NAME","default":N,...}` → [NAME: N].
    static func parseComboDefaults(_ source: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("[COMBO]") else { continue }
            guard let combo = jsonString(in: line, key: "combo") else { continue }
            out[combo] = jsonInt(in: line, key: "default") ?? 0
        }
        return out
    }

    private static func inlineIncludes(_ source: String, include: (String) -> String?, depth: Int) -> String {
        if depth > 16 { return source }
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#include") {
                if let name = firstQuoted(t) {
                    if let header = include(name) {
                        lines.append(inlineIncludes(header, include: include, depth: depth + 1))
                    } else {
                        NSLog("%@", "[Waple] GLSL include not found: \(name)")
                    }
                }
                continue
            }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    /// `#if/#ifdef/#ifndef/#elif/#else/#endif` 평가. 활성 줄만 출력(지시문 줄 제거).
    /// `#define NAME VAL` 은 정수면 식 평가에 쓰고, object-like 정의는 모두 본문 텍스트 치환한다
    /// (combos 포함 — WE 는 combos 를 #define 으로 주입하므로 본문 참조가 합법).
    /// 함수형 매크로(`#define F(x) ...`)는 v1 미지원: 정의 줄만 제거(호출부 원형 → 컴파일 실패 시 스킵 안전망).
    private static func evaluateConditionals(_ source: String, defines: [String: Int]) -> String {
        var d = defines
        var textDefines: [String: String] = [:]
        var out: [String] = []
        // 스택: (이 분기 출력중?, 이 #if 체인에서 이미 참 분기를 만났나?, 부모가 활성인가)
        struct Frame { var active: Bool; var taken: Bool; var parentActive: Bool }
        var stack: [Frame] = []
        func emitting() -> Bool { stack.allSatisfy { $0.active } }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if ") || t.hasPrefix("#ifdef ") || t.hasPrefix("#ifndef ") {
                let parentActive = emitting()
                var cond = false
                if t.hasPrefix("#ifdef ") { cond = d[token(after: "#ifdef", t)] != nil }
                else if t.hasPrefix("#ifndef ") { cond = d[token(after: "#ifndef", t)] == nil }
                else { cond = ExprEval.eval(String(t.dropFirst(3)), defines: d) != 0 }
                stack.append(Frame(active: parentActive && cond, taken: cond, parentActive: parentActive))
            } else if t.hasPrefix("#elif ") {
                guard !stack.isEmpty else { continue }
                var f = stack.removeLast()
                let cond = !f.taken && ExprEval.eval(String(t.dropFirst(5)), defines: d) != 0
                f.active = f.parentActive && cond
                f.taken = f.taken || cond
                stack.append(f)
            } else if t == "#else" {
                guard !stack.isEmpty else { continue }
                var f = stack.removeLast()
                f.active = f.parentActive && !f.taken
                f.taken = true
                stack.append(f)
            } else if t == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
            } else if t.hasPrefix("#define "), emitting() {
                let parts = t.dropFirst(8).split(separator: " ", maxSplits: 1)
                let name = parts.count >= 1 ? String(parts[0]) : ""
                if name.isEmpty || name.contains("(") {
                    // 함수형 매크로 또는 빈 이름: 정의 줄만 제거.
                } else if parts.count == 2 {
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if let v = Int(value) { d[name] = v }
                    textDefines[name] = value
                } else {
                    d[name] = 1  // 값 없는 #define NAME → #ifdef 용, 본문 치환은 안 함(빈 치환은 위험)
                }
                // #define 줄은 출력에서 제거
            } else if emitting() {
                out.append(line)
            }
        }
        // 본문 텍스트 치환: object-like 정의 + 정수 defines(combos 포함). 체인 정의는 fixpoint 까지(캡 8).
        var subst = textDefines
        for (k, v) in d where subst[k] == nil { subst[k] = String(v) }
        var body = out.joined(separator: "\n")
        guard !subst.isEmpty else { return body }
        for _ in 0..<8 {
            let next = substituteIdentifiers(body, subst)
            if next == body { break }
            body = next
        }
        return body
    }

    /// whole-word 식별자 치환(단일 패스).
    private static func substituteIdentifiers(_ src: String, _ map: [String: String]) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c == "_" {
                var id = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { id.append(chars[i]); i += 1 }
                out += map[id] ?? id
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    // MARK: - 작은 헬퍼

    private static func token(after kw: String, _ line: String) -> String {
        line.dropFirst(kw.count).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
    }
    private static func firstQuoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "\""), let b = s[s.index(after: a)...].firstIndex(of: "\"") else { return nil }
        return String(s[s.index(after: a)..<b])
    }
    private static func jsonString(in line: Substring, key: String) -> String? {
        guard let r = line.range(of: "\"\(key)\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let after = rest[rest.index(after: colon)...]
        guard let q1 = after.firstIndex(of: "\""), let q2 = after[after.index(after: q1)...].firstIndex(of: "\"") else { return nil }
        return String(after[after.index(after: q1)..<q2])
    }
    private static func jsonInt(in line: Substring, key: String) -> Int? {
        guard let r = line.range(of: "\"\(key)\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        var num = ""
        for ch in rest[rest.index(after: colon)...] {
            if ch == "," || ch == "}" { break }
            if ch.isNumber || ch == "-" { num.append(ch) }
            else if !ch.isWhitespace && !num.isEmpty { break }
        }
        return Int(num)
    }
}

/// `#if` 식 평가기. **안전**: 임의 코드 실행이 아니라 직접 작성한 재귀하강 정수 파서다.
/// 정수 리터럴 + 식별자(defines 룩업, 미정의=0) + `!  *  /  +  -  <  >  <=  >=  ==  !=  &&  ||` + 괄호만
/// 다룬다. 함수 호출/문자열/부수효과 없음 → 셰이더 입력으로부터 코드 인젝션 불가.
enum ExprEval {
    static func eval(_ expr: String, defines: [String: Int]) -> Int {
        let toks = tokenize(expr)
        var pos = 0
        func peek() -> String? { pos < toks.count ? toks[pos] : nil }
        func next() -> String? { defer { pos += 1 }; return peek() }

        // 재귀 하강(우선순위: || , && , 비교 , 가감 , 곱나눗 , 단항)
        func parsePrimary() -> Int {
            guard let t = next() else { return 0 }
            if t == "(" { let v = parseOr(); if peek() == ")" { pos += 1 }; return v }
            if t == "!" { return parsePrimary() == 0 ? 1 : 0 }
            if t == "-" { return -parsePrimary() }
            if let n = Int(t) { return n }
            return defines[t] ?? 0
        }
        func parseMul() -> Int {
            var v = parsePrimary()
            while let op = peek(), op == "*" || op == "/" {
                pos += 1; let r = parsePrimary()
                v = op == "*" ? v * r : (r == 0 ? 0 : v / r)
            }
            return v
        }
        func parseAdd() -> Int {
            var v = parseMul()
            while let op = peek(), op == "+" || op == "-" {
                pos += 1; let r = parseMul(); v = op == "+" ? v + r : v - r
            }
            return v
        }
        func parseCmp() -> Int {
            var v = parseAdd()
            while let op = peek(), ["==", "!=", "<", ">", "<=", ">="].contains(op) {
                pos += 1; let r = parseAdd()
                switch op {
                case "==": v = v == r ? 1 : 0
                case "!=": v = v != r ? 1 : 0
                case "<": v = v < r ? 1 : 0
                case ">": v = v > r ? 1 : 0
                case "<=": v = v <= r ? 1 : 0
                default: v = v >= r ? 1 : 0
                }
            }
            return v
        }
        func parseAnd() -> Int {
            var v = parseCmp()
            while peek() == "&&" { pos += 1; let r = parseCmp(); v = (v != 0 && r != 0) ? 1 : 0 }
            return v
        }
        func parseOr() -> Int {
            var v = parseAnd()
            while peek() == "||" { pos += 1; let r = parseAnd(); v = (v != 0 || r != 0) ? 1 : 0 }
            return v
        }
        return parseOr()
    }

    private static func tokenize(_ s: String) -> [String] {
        var toks: [String] = []
        let chars = Array(s)
        var i = 0
        let two: Set<String> = ["==", "!=", "<=", ">=", "&&", "||"]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if i + 1 < chars.count, two.contains(String([c, chars[i + 1]])) {
                toks.append(String([c, chars[i + 1]])); i += 2; continue
            }
            if "()!*/+-<>".contains(c) { toks.append(String(c)); i += 1; continue }
            if c.isLetter || c == "_" {
                var id = ""; while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { id.append(chars[i]); i += 1 }
                toks.append(id); continue
            }
            if c.isNumber {
                var n = ""; while i < chars.count, chars[i].isNumber { n.append(chars[i]); i += 1 }
                toks.append(n); continue
            }
            i += 1  // 알 수 없는 문자 무시
        }
        return toks
    }
}
