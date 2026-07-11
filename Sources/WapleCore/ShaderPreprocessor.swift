import Foundation

/// WE GLSL 전처리기: `[COMBO]` 기본값 + `#include` 인라인 + `#if/#ifdef/#else/#elif/#endif` 평가.
/// 순수(테스트 가능). 미발견 인클루드/미지원은 안전 무시(빈 줄)하고 로그.
public enum ShaderPreprocessor {
    /// - combos: scene.json 에서 온 명시적 콤보 값(소스의 [COMBO] 기본값보다 우선).
    /// - include: `#include "name"` → 헤더 소스(없으면 nil → 빈 인라인).
    public static func preprocess(_ source: String, combos: [String: Int],
                                  include: (String) -> String? = { _ in nil }) -> String {
        // 실물 WE 셰이더는 CRLF — 정규화하지 않으면 `#endif\r` 미인식으로 조건부 스택이 안 닫혀
        // 첫 비활성 분기 이후 전체가 소실된다(실측 31씬 전 효과 폴백의 근본 원인).
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var defines = combos
        // WE 컴파일러 내장 캐스트 매크로(헤더에 없음 — 실물 depthparallax 의 CAST3X3 등).
        // 소스가 자체 정의하면 그것이 우선(아래 builtinCasts 는 부재 시에만 주입).
        // [COMBO] 기본값(명시 combos 가 없을 때만 채움)
        for (name, def) in parseComboDefaults(source) where defines[name] == nil { defines[name] = def }
        var included = inlineIncludes(source, include: include, depth: 0)
        // CAST3X3(mat4) 는 GLSL 에선 상단 3x3 절단이지만 MSL 엔 float3x3(float4x4) 생성자가 없다 —
        // 번역기 프리앰블의 오버로드 헬퍼 we_cast3x3(절단/통과) 로 위임(실물 depthparallax).
        for (name, body) in [("CAST2", "vec2(x)"), ("CAST3", "vec3(x)"), ("CAST4", "vec4(x)"),
                             ("CAST2X2", "mat2(x)"), ("CAST3X3", "we_cast3x3(x)"), ("CAST4X4", "mat4(x)")]
        where !included.contains("#define \(name)") && included.contains(name) {
            included = "#define \(name)(x) \(body)\n" + included
        }
        // 인라인된 헤더의 [COMBO] 기본값도 반영
        for (name, def) in parseComboDefaults(included) where defines[name] == nil { defines[name] = def }
        return evaluateConditionals(spliceDefineContinuations(included), defines: defines)
    }

    /// C 줄연속(`\` + 개행) 스플라이스 — `#define` 지시문 한정. 일반 코드/주석 줄의 트레일링
    /// 백슬래시(Windows 경로 주석 등)가 다음 줄을 삼키지 않도록 지시문 밖은 건드리지 않는다.
    /// ponytail: 멀티라인 매크로 "호출"의 줄단위 미확장은 별도(실입력 미확인 — 필요 시 확장).
    static func spliceDefineContinuations(_ source: String) -> String {
        guard source.contains("\\\n") else { return source }
        var out: [String] = []
        var iter = source.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        while let line = iter.next() {
            var s = String(line)
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("#define") {
                while s.hasSuffix("\\"), let next = iter.next() {
                    s = String(s.dropLast()) + " " + String(next)
                }
            }
            out.append(s)
        }
        return out.joined(separator: "\n")
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
                        // 헤더 파일도 CRLF 일 수 있음 — 인라인 전 정규화.
                        let normalized = header.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
                        lines.append(inlineIncludes(normalized, include: include, depth: depth + 1))
                    } else {
                        WapleLog.warn("[Waple] GLSL include not found: \(name)")
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
    /// 함수형 매크로(`#define F(x, y) body`)도 확장한다 — 실물 common_blending.h 의 Blend* 가 전부 이 형태.
    /// 매크로가 매크로를 부르는 체인/별칭은 fixpoint 루프로 수렴시킨다.
    private static func evaluateConditionals(_ source: String, defines: [String: Int]) -> String {
        var d = defines
        var textDefines: [String: String] = [:]
        var funcMacros: [String: (params: [String], body: String)] = [:]
        var flagDefines = Set<String>()   // 값 없는 소스 #define — #ifdef 전용, 본문 "1" 치환 금지
        // C 규약(위치-인지): 정의는 이후 줄부터, 재정의 시 이전 정의는 그 줄까지(실물 frame_builder).
        struct MacroDef { let name: String; let value: String?; let fn: (params: [String], body: String)?
                          let fromLine: Int; var toLine: Int = Int.max }
        var macroDefs: [MacroDef] = []
        func closePrev(_ name: String, at line: Int) {
            for i in macroDefs.indices where macroDefs[i].name == name && macroDefs[i].toLine == Int.max {
                macroDefs[i].toLine = line
            }
        }
        var out: [String] = []
        // 스택: (이 분기 출력중?, 이 #if 체인에서 이미 참 분기를 만났나?, 부모가 활성인가)
        struct Frame { var active: Bool; var taken: Bool; var parentActive: Bool }
        var stack: [Frame] = []
        func emitting() -> Bool { stack.allSatisfy { $0.active } }
        func definedNames() -> Set<String> { Set(d.keys).union(textDefines.keys).union(funcMacros.keys) }
        func isDefined(_ name: String) -> Bool { definedNames().contains(name) }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            var t = line.trimmingCharacters(in: .whitespaces)
            // 지시문 줄 트레일링 주석 제거 — `#if C_TYPE == 4 // 설명` 이 식 평가를 깨면
            // 관용 유지로 모든 분기가 방출된다(실물 frame_builder 의 offset 재정의 원인).
            // `/* */` 도 절단 — 잔존 시 ExprEval 이 `/`·`*` 를 연산자로 토큰화해 오평가(`#if AUDIO /* mic */`).
            if t.hasPrefix("#") {
                if let c = t.range(of: "//") { t = String(t[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
                if let c = t.range(of: "/*") { t = String(t[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
            }
            // `#if(cond)`/`#elif(cond)` — `#if`/`#elif` 뒤 공백 없이 `(` 가 오면 아래 prefix 검사가 놓쳐
            // 지시문이 MSL 에 그대로 방출되고 짝 `#endif` 만 소비돼 미종결 조건부가 된다(실물 halftone).
            // 공백을 끼워 정규화(다운스트림 dropFirst 카운트 불변).
            if t.hasPrefix("#if(") { t = "#if " + t.dropFirst(3) }
            else if t.hasPrefix("#elif(") { t = "#elif " + t.dropFirst(5) }
            if t.hasPrefix("#if ") || t.hasPrefix("#ifdef ") || t.hasPrefix("#ifndef ") {
                let parentActive = emitting()
                var cond = false
                if t.hasPrefix("#ifdef ") { cond = isDefined(token(after: "#ifdef", t)) }
                else if t.hasPrefix("#ifndef ") { cond = !isDefined(token(after: "#ifndef", t)) }
                else { cond = ExprEval.eval(String(t.dropFirst(3)), defines: d, definedNames: definedNames()) != 0 }
                stack.append(Frame(active: parentActive && cond, taken: cond, parentActive: parentActive))
            } else if t.hasPrefix("#elif ") {
                guard !stack.isEmpty else { continue }
                var f = stack.removeLast()
                let cond = !f.taken && ExprEval.eval(String(t.dropFirst(5)), defines: d, definedNames: definedNames()) != 0
                f.active = f.parentActive && cond
                f.taken = f.taken || cond
                stack.append(f)
            } else if t == "#else" || t.hasPrefix("#else ") || t.hasPrefix("#else//") {
                // 꼬리 주석 허용(`#else // foo`) — 미인식 시 지시문이 출력에 남아 MSL 컴파일 실패.
                guard !stack.isEmpty else { continue }
                var f = stack.removeLast()
                f.active = f.parentActive && !f.taken
                f.taken = true
                stack.append(f)
            } else if t == "#endif" || t.hasPrefix("#endif ") || t.hasPrefix("#endif//") {
                if !stack.isEmpty { stack.removeLast() }
            } else if t.hasPrefix("#undef ") {
                if emitting() {
                    let name = token(after: "#undef", t)
                    d.removeValue(forKey: name)
                    textDefines.removeValue(forKey: name)
                    funcMacros.removeValue(forKey: name)
                    flagDefines.remove(name)
                    closePrev(name, at: out.count)
                }
            } else if t.hasPrefix("#define "), emitting() {
                let decl = String(t.dropFirst(8))
                let nameEnd = decl.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "\t" }) ?? decl.endIndex
                let name = String(decl[..<nameEnd])
                if name.isEmpty {
                    // 빈 이름: 정의 줄만 제거.
                } else if nameEnd < decl.endIndex, decl[nameEnd] == "(" {
                    // 함수형 매크로: `NAME(p1, p2) body` — 파라미터는 괄호 미포함 단순 목록.
                    let afterName = decl[decl.index(after: nameEnd)...]
                    if let close = afterName.firstIndex(of: ")") {
                        let params = afterName[..<close].split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        var bodyRaw = String(afterName[afterName.index(after: close)...])
                        // 객체형과 동일: 트레일링 주석이 본문에 들어가면 사용처의 ';' 를 삼킨다(실물 oscilloscope avg()).
                        if let c = bodyRaw.range(of: "//") { bodyRaw = String(bodyRaw[..<c.lowerBound]) }
                        if let c = bodyRaw.range(of: "/*") { bodyRaw = String(bodyRaw[..<c.lowerBound]) }
                        let body = bodyRaw.trimmingCharacters(in: .whitespaces)
                        if !body.isEmpty {
                            funcMacros[name] = (params, body)
                            closePrev(name, at: out.count)
                            macroDefs.append(MacroDef(name: name, value: nil, fn: (params, body), fromLine: out.count))
                        }
                    }
                } else {
                    // 트레일링 주석은 치환값에서 제거 — `#define K 0.0625 // 1/16` 이 그대로 들어가면
                    // 사용처의 세미콜론까지 주석에 삼켜진다(실물 oscilloscope).
                    var raw = String(decl[nameEnd...])
                    if let c = raw.range(of: "//") { raw = String(raw[..<c.lowerBound]) }
                    if let c = raw.range(of: "/*") { raw = String(raw[..<c.lowerBound]) }
                    let value = raw.trimmingCharacters(in: .whitespaces)
                    if value.isEmpty {
                        d[name] = 1  // 값 없는 #define NAME → #ifdef 용, 본문 치환은 안 함(빈 치환은 위험)
                        flagDefines.insert(name)
                    } else {
                        if let v = Int(value) { d[name] = v }
                        textDefines[name] = value
                        closePrev(name, at: out.count)
                        macroDefs.append(MacroDef(name: name, value: value, fn: nil, fromLine: out.count))
                    }
                }
                // #define 줄은 출력에서 제거
            } else if emitting() {
                out.append(line)
            }
        }
        // 본문 매크로 확장: object-like 치환 + 함수형 매크로 호출 확장을 한 루프에서 fixpoint 까지(캡 12)
        // — 별칭(#define A Bf)·매크로가 매크로를 부르는 체인(실물 Blend* 계열)이 수렴하도록.
        // combos/[COMBO] 기본값 등 소스 밖에서 온 정의는 전체 범위(fromLine 0).
        for (k, v) in d where textDefines[k] == nil && funcMacros[k] == nil && !flagDefines.contains(k) {
            // 소스 밖(combos/[COMBO] 기본값)에서 온 정의 — 전체 범위. 값 없는 소스 define 은
            // 위 주석대로 본문 치환 제외(여기 걸리면 본문 NAME 이 "1" 로 둔갑 — C 빈치환과 다름).
            macroDefs.append(MacroDef(name: k, value: String(v), fn: nil, fromLine: 0))
        }
        guard !macroDefs.isEmpty else { return out.joined(separator: "\n") }
        var lines = out
        for _ in 0..<12 {
            var changed = false
            for def in macroDefs {
                let hi = min(def.toLine, lines.count)
                guard def.fromLine < hi else { continue }
                for i in def.fromLine..<hi {
                    let before = lines[i]
                    if let v = def.value {
                        lines[i] = substituteIdentifiers(before, [def.name: v])
                    } else if let m = def.fn {
                        lines[i] = GLSLTranslator.rewriteCall(before, def.name) { args in
                            guard args.count == m.params.count else { return nil }
                            return GLSLTranslator.replaceIdentifiers(m.body, Dictionary(uniqueKeysWithValues: zip(m.params, args)))
                        }
                    }
                    if lines[i] != before { changed = true }
                }
            }
            if !changed { break }
        }
        let body = lines.joined(separator: "\n")
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
                out += map[id].map(bodyMacroReplacement) ?? id
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    private static func bodyMacroReplacement(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return isNegativeNumericLiteral(trimmed) ? "(\(trimmed))" : value
    }

    private static func isNegativeNumericLiteral(_ value: String) -> Bool {
        let chars = Array(value)
        guard chars.first == "-" else { return false }
        var i = 1
        var hasDigit = false
        while i < chars.count, chars[i].isNumber { hasDigit = true; i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber { hasDigit = true; i += 1 }
        }
        guard hasDigit else { return false }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var exponentDigits = false
            while i < chars.count, chars[i].isNumber { exponentDigits = true; i += 1 }
            guard exponentDigits else { return false }
        }
        if i < chars.count, chars[i] == "f" || chars[i] == "F" { i += 1 }
        return i == chars.count
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
    static func eval(_ expr: String, defines: [String: Int], definedNames: Set<String>? = nil) -> Int {
        let toks = tokenize(expr)
        let knownNames = definedNames ?? Set(defines.keys)
        var pos = 0
        func peek() -> String? { pos < toks.count ? toks[pos] : nil }
        func next() -> String? { defer { pos += 1 }; return peek() }

        // 재귀 하강(우선순위: || , && , 비교 , 가감 , 곱나눗 , 단항)
        func parsePrimary() -> Int {
            guard let t = next() else { return 0 }
            if t == "(" { let v = parseOr(); if peek() == ")" { pos += 1 }; return v }
            if t == "!" { return parsePrimary() == 0 ? 1 : 0 }
            if t == "-" { return 0 &- parsePrimary() }  // 랩핑 — defines 에 Int.min 이 실릴 수 있음
            if t == "defined" {
                if peek() == "(" {
                    pos += 1
                    let name = next() ?? ""
                    if peek() == ")" { pos += 1 }
                    return knownNames.contains(name) ? 1 : 0
                }
                return knownNames.contains(next() ?? "") ? 1 : 0
            }
            if let n = Int(t) { return n }
            return defines[t] ?? 0
        }
        // 산술은 랩핑(&*, &+, &-) + 나눗셈 트랩 가드 — #if 는 분기 결정만 하면 되므로 근사면 충분하고,
        // 악성 리터럴(`#if 9223372036854775807+1`)의 오버플로 트랩(크래시) 방지가 우선.
        func parseMul() -> Int {
            var v = parsePrimary()
            while let op = peek(), op == "*" || op == "/" {
                pos += 1; let r = parsePrimary()
                v = op == "*" ? v &* r : (r == 0 ? 0 : (v == Int.min && r == -1 ? 0 : v / r))
            }
            return v
        }
        func parseAdd() -> Int {
            var v = parseMul()
            while let op = peek(), op == "+" || op == "-" {
                pos += 1; let r = parseMul(); v = op == "+" ? v &+ r : v &- r
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
