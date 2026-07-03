import Foundation

/// Stage-3 phase 2: 식-레벨 벡터 크기 추론 + 절단 삽입(설계 2026-07-03).
/// WE GLSL(HLSL-관용)은 크기가 다른 벡터 혼합을 "작은 쪽으로 절단"으로 허용하지만 MSL 은 금지한다.
/// 방침: 확실히 아는 크기(1..4)에서만 개입하고, 미지(0)는 절대 건드리지 않는다(무개입 = 기존 폴백 안전망).
public enum GLSLTypeAdapter {
    public struct Env {
        public var vars: [String: Int]        // 이름 → 벡터 크기(1..4), 0 = 불투명
        public var functions: [String: Int]   // 함수 이름 → 반환 크기
        public var functionParams: [String: [Int]]  // 호출 인자 절단용(0=불투명)
        public init(vars: [String: Int], functions: [String: Int] = [:], functionParams: [String: [Int]] = [:]) {
            self.vars = vars; self.functions = functions; self.functionParams = functionParams
        }
    }

    // MARK: - 토크나이저(트리비아 보존 — 무개입 영역 바이트 보존)

    private struct Tok {
        let trivia: String   // 이 토큰 앞의 공백/개행
        let text: String
        var full: String { trivia + text }
        var isIdent: Bool { text.first.map { $0.isLetter || $0 == "_" } ?? false }
    }

    private static func tokenize(_ s: String) -> [Tok] {
        let chars = Array(s)
        var out: [Tok] = []
        var i = 0
        let two: Set<String> = ["==","!=","<=",">=","&&","||","+=","-=","*=","/=","++","--"]
        while i < chars.count {
            var trivia = ""
            while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" || chars[i] == "\r" {
                trivia.append(chars[i]); i += 1
            }
            guard i < chars.count else { if !trivia.isEmpty { out.append(Tok(trivia: trivia, text: "")) }; break }
            let c = chars[i]
            if c.isLetter || c == "_" {
                var t = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { t.append(chars[i]); i += 1 }
                out.append(Tok(trivia: trivia, text: t)); continue
            }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var t = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E"
                    || ((chars[i] == "+" || chars[i] == "-") && (t.last == "e" || t.last == "E"))
                    || chars[i] == "f" || chars[i] == "F" { t.append(chars[i]); i += 1 }
                out.append(Tok(trivia: trivia, text: t)); continue
            }
            if i + 1 < chars.count, two.contains(String([c, chars[i + 1]])) {
                out.append(Tok(trivia: trivia, text: String([c, chars[i + 1]]))); i += 2; continue
            }
            out.append(Tok(trivia: trivia, text: String(c))); i += 1
        }
        return out
    }

    // MARK: - 크기 테이블

    static func typeSize(_ name: String) -> Int? {
        switch GLSLType.from(name) {
        case .some(.float): return 1
        case .some(.vec2): return 2
        case .some(.vec3): return 3
        case .some(.vec4): return 4
        case .some(.mat2), .some(.mat3), .some(.mat4), .some(.sampler2D): return 0
        case .none:
            return (name == "int" || name == "bool") ? 1 : nil
        }
    }

    private static let scalarFns: Set<String> = ["dot", "distance", "length"]
    private static let broadcastFns: Set<String> = [
        "sin","cos","tan","asin","acos","atan","atan2","abs","floor","ceil","fract","frac","exp","exp2","log","log2",
        "sqrt","rsqrt","normalize","saturate","pow","min","max","mix","lerp","clamp","step","smoothstep",
        "reflect","refract","sign","mod","we_mod",
    ]

    // MARK: - 파서 상태

    private final class P {
        let toks: [Tok]
        var pos = 0
        var env: Env
        var intVars = Set<String>()   // int 선언 지역 — % 연산자 유지 판별용
        let returnSize: Int?
        var out = ""   // 재구성 출력
        init(_ toks: [Tok], env: Env, returnSize: Int?) { self.toks = toks; self.env = env; self.returnSize = returnSize }
        func peek(_ k: Int = 0) -> String? { pos + k < toks.count ? toks[pos + k].text : nil }
        func advance() -> Tok { defer { pos += 1 }; return toks[pos] }
    }

    private struct Node { var text: String; var size: Int }  // size 0 = 불투명

    /// 본문 전체를 문장 단위로 처리. returnSize: 헬퍼의 선언 반환 크기(return 식 절단용).
    public static func adapt(body: String, env: Env, returnSize: Int? = nil) -> String {
        let p = P(tokenize(body), env: env, returnSize: returnSize)
        statements(p, until: nil)
        return p.out
    }

    /// until: 이 토큰을 만나면(소비하지 않고) 중단. nil = 끝까지.
    private static func statements(_ p: P, until: String?) {
        while p.pos < p.toks.count {
            if let u = until, p.peek() == u { return }
            statement(p)
        }
    }

    private static func statement(_ p: P) {
        guard let t = p.peek() else { p.out += p.advance().full; return }
        switch t {
        case "{":
            p.out += p.advance().full
            statements(p, until: "}")
            if p.peek() == "}" { p.out += p.advance().full }
        case "}", ";":
            p.out += p.advance().full
        case "if", "while":
            p.out += p.advance().full
            if p.peek() == "(" {
                p.out += p.advance().full
                let cond = expression(p)
                p.out += cond.text
                if p.peek() == ")" { p.out += p.advance().full }
            }
        case "for":
            p.out += p.advance().full
            if p.peek() == "(" {
                p.out += p.advance().full
                // 초기화(선언 가능); 조건; 증감 — 각각 문장/식으로 처리.
                statement(p)                      // "int i = 0;"
                let cond = expression(p); p.out += cond.text
                if p.peek() == ";" { p.out += p.advance().full }
                let inc = expression(p); p.out += inc.text
                if p.peek() == ")" { p.out += p.advance().full }
            }
        case "return":
            p.out += p.advance().full
            if p.peek() != ";" {
                var e = expression(p)
                if let want = p.returnSize { e = coerce(e, to: want) }
                p.out += e.text
            }
            if p.peek() == ";" { p.out += p.advance().full }
        case "else", "break", "continue", "discard", "const":
            p.out += p.advance().full
        default:
            // 선언? `<type> <ident> [= expr] [, ...] ;`
            if let sz = typeSize(t), p.pos + 1 < p.toks.count, p.toks[p.pos + 1].isIdent {
                declaration(p, declaredSize: sz)
                return
            }
            // 대입? `<ident>(.swz)? <assignop> expr`
            if assignment(p) { return }
            // 일반 식 문장(호출/증감 등)
            let e = expression(p)
            p.out += e.text
            if p.peek() == ";" { p.out += p.advance().full }
        }
    }

    /// `<type> name = expr(, name2 = expr2)*;` — env 등록 + 초기화 절단.
    private static func declaration(_ p: P, declaredSize: Int) {
        let typeTok = p.toks[p.pos].text
        p.out += p.advance().full  // type
        while true {
            guard p.pos < p.toks.count, p.toks[p.pos].isIdent else { break }
            let nameTok = p.advance()
            p.out += nameTok.full
            p.env.vars[nameTok.text] = declaredSize
            if typeTok == "int" || typeTok == "uint" { p.intVars.insert(nameTok.text) }
            if p.peek() == "[" {  // 배열 선언 — 불투명 처리
                p.env.vars[nameTok.text] = 0
                while p.pos < p.toks.count, p.peek() != ";" { p.out += p.advance().full }
                break
            }
            if p.peek() == "=" {
                p.out += p.advance().full
                var e = expression(p)
                if declaredSize > 0 { e = coerce(e, to: declaredSize) }
                p.out += e.text
            }
            if p.peek() == "," { p.out += p.advance().full; continue }
            break
        }
        if p.peek() == ";" { p.out += p.advance().full }
    }

    /// lvalue 대입 문장이면 처리하고 true. 아니면 위치 복원 후 false.
    private static func assignment(_ p: P) -> Bool {
        let start = p.pos
        guard p.pos < p.toks.count, p.toks[p.pos].isIdent else { return false }
        let name = p.toks[p.pos].text
        var look = p.pos + 1
        var lvalSize = p.env.vars[name] ?? 0
        if look < p.toks.count, p.toks[look].text == "." {
            let swz = look + 1 < p.toks.count ? p.toks[look + 1].text : ""
            if swz.allSatisfy({ "xyzwrgbastpq".contains($0) }) {
                lvalSize = swz.count
                look += 2
            } else { return false }
        }
        guard look < p.toks.count, ["=", "+=", "-=", "*=", "/="].contains(p.toks[look].text) else { return false }
        // 소비: lvalue + op
        while p.pos <= look { p.out += p.advance().full }
        var e = expression(p)
        if lvalSize > 0 { e = coerce(e, to: lvalSize) }
        p.out += e.text
        if p.peek() == ";" { p.out += p.advance().full }
        _ = start
        return true
    }

    /// 목표 크기로 절단/스플랫. 미지(0)·동일 크기는 무개입.
    private static func coerce(_ e: Node, to want: Int) -> Node {
        guard e.size > 0, want > 0, e.size != want else { return e }
        if e.size > want {
            let swz = ["", ".x", ".xy", ".xyz"][want]
            // 트리비아 유지: 선두 공백을 괄호 밖으로.
            let (lead, core) = splitLead(e.text)
            return Node(text: "\(lead)(\(core))\(swz)", size: want)
        }
        return e  // 확대(1→N 브로드캐스트)는 문맥상 유효(MSL 대입은 불가지만 HLSL 원본도 드묾 — 무개입)
    }

    private static func splitLead(_ s: String) -> (String, String) {
        var i = s.startIndex
        while i < s.endIndex, s[i] == " " || s[i] == "\n" || s[i] == "\t" { i = s.index(after: i) }
        return (String(s[..<i]), String(s[i...]))
    }

    // MARK: - Pratt 식 파서(우선순위: 삼항 < || < && < 비교 < 가감 < 곱나눗 < 단항 < 후위)

    private static func expression(_ p: P) -> Node { ternary(p) }

    private static func ternary(_ p: P) -> Node {
        var cond = orExpr(p)
        guard p.peek() == "?" else { return cond }
        cond.text += p.advance().full
        var a = ternary(p)
        var mid = ""
        if p.peek() == ":" { mid = p.advance().full }
        var b = ternary(p)
        // 분기 크기 불일치 → 큰 쪽 절단.
        if a.size > 0, b.size > 0, a.size != b.size {
            if a.size > b.size { a = coerce(a, to: b.size) } else { b = coerce(b, to: a.size) }
        }
        return Node(text: cond.text + a.text + mid + b.text, size: max(a.size, b.size) == 0 ? 0 : min(a.size == 0 ? b.size : a.size, b.size == 0 ? a.size : b.size))
    }

    private static func binary(_ p: P, ops: Set<String>, next: (P) -> Node, arithmetic: Bool, resultScalar: Bool = false) -> Node {
        var lhs = next(p)
        while let op = p.peek(), ops.contains(op) {
            let opTok = p.advance()
            var rhs = next(p)
            if arithmetic, lhs.size > 1, rhs.size > 1, lhs.size != rhs.size {
                // HLSL 절단 규칙: 작은 쪽으로.
                if lhs.size > rhs.size { lhs = coerce(lhs, to: rhs.size) } else { rhs = coerce(rhs, to: lhs.size) }
            }
            let size: Int
            if resultScalar { size = 1 }
            else if lhs.size == 0 || rhs.size == 0 { size = 0 }
            else { size = max(lhs.size, rhs.size) }  // 스칼라 브로드캐스트
            lhs = Node(text: lhs.text + opTok.full + rhs.text, size: size)
        }
        return lhs
    }

    private static func orExpr(_ p: P) -> Node { binary(p, ops: ["||"], next: andExpr, arithmetic: false, resultScalar: true) }
    private static func andExpr(_ p: P) -> Node { binary(p, ops: ["&&"], next: cmpExpr, arithmetic: false, resultScalar: true) }
    private static func cmpExpr(_ p: P) -> Node {
        var lhs = addExpr(p)
        while let op = p.peek(), ["==","!=","<",">","<=",">="].contains(op) {
            let opTok = p.advance()
            let rhs = addExpr(p)
            lhs = Node(text: lhs.text + opTok.full + rhs.text, size: 1)
        }
        return lhs
    }
    private static func addExpr(_ p: P) -> Node { binary(p, ops: ["+","-"], next: mulExpr, arithmetic: true) }
    private static func mulExpr(_ p: P) -> Node {
        var lhs = unary(p)
        while let op = p.peek(), op == "*" || op == "/" || op == "%" {
            let opTok = p.advance()
            var rhs = unary(p)
            if lhs.size > 1, rhs.size > 1, lhs.size != rhs.size {
                if lhs.size > rhs.size { lhs = coerce(lhs, to: rhs.size) } else { rhs = coerce(rhs, to: lhs.size) }
            }
            let size = (lhs.size == 0 || rhs.size == 0) ? 0 : max(lhs.size, rhs.size)
            if opTok.text == "%" {
                // MSL 의 % 는 정수 전용(실물 Simple_Audio_Bars 의 float %) — 양쪽이 int 확실일 때만 유지.
                func intish(_ n: Node) -> Bool {
                    let t = n.text.trimmingCharacters(in: .whitespaces)
                    return t.allSatisfy { $0.isNumber } || p.intVars.contains(t)
                        || t.hasPrefix("int(") || t.hasPrefix("uint(")   // 명시 캐스트(실물 i % int(4))
                }
                if intish(lhs) && intish(rhs) {
                    lhs = Node(text: lhs.text + opTok.full + rhs.text, size: size)
                } else {
                    // fmod 는 float 전용 — 정수 리터럴 인자는 실수 리터럴로 승격(모호성 방지).
                    func lit(_ t: String) -> String {
                        let c = t.trimmingCharacters(in: .whitespaces)
                        return c.allSatisfy { $0.isNumber } ? c + ".0" : c
                    }
                    let (lead, core) = splitLead(lhs.text)
                    lhs = Node(text: "\(lead)fmod(\(lit(core)), \(lit(rhs.text)))", size: size)
                }
            } else {
                lhs = Node(text: lhs.text + opTok.full + rhs.text, size: size)
            }
        }
        return lhs
    }

    private static func unary(_ p: P) -> Node {
        if let t = p.peek(), ["-","!","+","~","++","--"].contains(t) {
            let opTok = p.advance()
            let e = unary(p)
            return Node(text: opTok.full + e.text, size: e.size)
        }
        return postfix(p)
    }

    private static func maxComponent(_ swz: String) -> Int {
        var m = 0
        for c in swz {
            for set in ["xyzw", "rgba", "stpq"] {
                if let i = set.firstIndex(of: c) { m = max(m, set.distance(from: set.startIndex, to: i)) }
            }
        }
        return m
    }

    private static func postfix(_ p: P) -> Node {
        var base = primary(p)
        var preSwizzle: (text: String, size: Int)? = nil
        while let t = p.peek() {
            if t == "." {
                let dotTok = p.advance()
                guard p.pos < p.toks.count else { base.text += dotTok.full; break }
                let member = p.advance()
                if member.text.allSatisfy({ "xyzwrgbastpq".contains($0) }) {
                    // 스위즐 체인 초과(실물 water_caustics `.xy.zw`): 직전 스위즐을 대체.
                    if let pre = preSwizzle, base.size > 0, maxComponent(member.text) >= base.size {
                        base = Node(text: pre.text + dotTok.full + member.full, size: member.text.count)
                        continue
                    }
                    preSwizzle = (base.text, base.size)
                    base = Node(text: base.text + dotTok.full + member.full, size: member.text.count)
                } else {
                    preSwizzle = nil
                    base = Node(text: base.text + dotTok.full + member.full, size: 0)
                }
            } else if t == "[" {
                preSwizzle = nil
                var text = base.text + p.advance().full
                let idx = expression(p)
                text += idx.text
                if p.peek() == "]" { text += p.advance().full }
                base = Node(text: text, size: base.size > 1 ? 1 : 0)
            } else if t == "++" || t == "--" {
                base = Node(text: base.text + p.advance().full, size: base.size)
            } else { break }
        }
        return base
    }

    private static func primary(_ p: P) -> Node {
        guard p.pos < p.toks.count else { return Node(text: "", size: 0) }
        let tok = p.advance()
        let t = tok.text
        if t == "(" {
            let inner = expression(p)
            var text = tok.full + inner.text
            if p.peek() == ")" { text += p.advance().full }
            return Node(text: text, size: inner.size)
        }
        if tok.isIdent {
            // 호출?
            if p.peek() == "(" {
                let open = p.advance().full
                var argTexts: [String] = []
                var seps: [String] = []
                var argSizes: [Int] = []
                if p.peek() != ")" {
                    while true {
                        let a = expression(p)
                        argTexts.append(a.text)
                        argSizes.append(a.size)
                        if p.peek() == "," { seps.append(p.advance().full); continue }
                        break
                    }
                }
                let close = p.peek() == ")" ? p.advance().full : ""
                // MSL 은 min/max/clamp 의 정수·실수 혼합 오버로드가 모호(실물 rounded_mask `max(1, x/y)`).
                // 다른 인자가 실수/벡터면 정수 리터럴 인자를 실수 리터럴로 승격.
                if ["min", "max", "clamp", "mix", "step", "pow", "mod"].contains(t), argTexts.count >= 2 {
                    func isIntLiteral(_ x: String) -> Bool {
                        let c = x.trimmingCharacters(in: .whitespaces)
                        return !c.isEmpty && c.allSatisfy { $0.isNumber }
                    }
                    let anyNonInt = argTexts.contains { !isIntLiteral($0) }
                    if anyNonInt {
                        for i in argTexts.indices where isIntLiteral(argTexts[i]) {
                            let lead = argTexts[i].prefix(while: { $0 == " " || $0 == "\t" })
                            argTexts[i] = lead + argTexts[i].trimmingCharacters(in: .whitespaces) + ".0"
                        }
                    }
                }
                // 알려진 헬퍼: 인자를 파라미터 크기로 절단(HLSL 관용 — 실물 shimmer).
                if let ps = p.env.functionParams[t] {
                    for i in argTexts.indices where i < ps.count && ps[i] > 0 && argSizes[i] > ps[i] {
                        let node = coerce(Node(text: argTexts[i], size: argSizes[i]), to: ps[i])
                        argTexts[i] = node.text
                        argSizes[i] = ps[i]
                    }
                }
                var text = tok.full + open
                for (i, a) in argTexts.enumerated() {
                    text += a
                    if i < seps.count { text += seps[i] }
                }
                text += close
                return Node(text: text, size: callSize(t, argSizes: argSizes, env: p.env))
            }
            if t.first!.isNumber { return Node(text: tok.full, size: 1) }
            if t == "true" || t == "false" { return Node(text: tok.full, size: 1) }
            let size = p.env.vars[t] ?? (typeSize(t) != nil ? 0 : 0)
            return Node(text: tok.full, size: size)
        }
        if t.first?.isNumber == true || (t.first == "." && t.count > 1) {
            return Node(text: tok.full, size: 1)
        }
        return Node(text: tok.full, size: 0)
    }

    private static func callSize(_ name: String, argSizes: [Int], env: Env) -> Int {
        if let n = typeSize(name), n > 0 { return n }               // vecN/floatN 생성자
        if name == "texSample2D" || name == "texSample2DLod" { return 4 }
        if name == "cross" { return 3 }
        if scalarFns.contains(name) { return 1 }
        if broadcastFns.contains(name) {
            let known = argSizes.filter { $0 > 0 }
            if known.count == argSizes.count, !known.isEmpty { return known.max()! }
            return 0
        }
        if let r = env.functions[name] { return r }
        return 0
    }
}
