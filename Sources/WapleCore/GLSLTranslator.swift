import Foundation

public enum GLSLType: String, Equatable {
    case float, vec2, vec3, vec4, mat3, mat4, sampler2D
    var components: Int { switch self { case .float: return 1; case .vec2: return 2; case .vec3: return 3; case .vec4: return 4; default: return 0 } }
    var msl: String {
        switch self {
        case .float: return "float"; case .vec2: return "float2"; case .vec3: return "float3"
        case .vec4: return "float4"; case .mat3: return "float3x3"; case .mat4: return "float4x4"
        case .sampler2D: return "texture2d<float>"
        }
    }
    /// float4 슬롯 내 스위즐(파라미터당 float4 패킹).
    var swizzle: String { switch self { case .float: return ".x"; case .vec2: return ".xy"; case .vec3: return ".xyz"; default: return "" } }
}

/// 머티리얼 파라미터(선언 순서 보존). 값은 scene.json constantshadervalues[sceneKey] 또는 default.
public struct MaterialParam: Equatable {
    public let glslName: String
    public let type: GLSLType
    public let sceneKey: String
    public let defaultValue: [Float]
}

public struct TranslatedShader: Equatable {
    public let msl: String                 // ev_main + ef_main 단일 라이브러리
    public let materialParams: [MaterialParam]
    public let textureSlots: [Int]         // 선언된 g_TextureN 의 N 들(오름차순)
    public let usesAudio: Bool
}

/// WE GLSL(방언) → MSL 소스-투-소스 변환기. 실패 시 nil(→ 손-포팅 폴백).
public enum GLSLTranslator {
    public static func translate(vertex: String, fragment: String, combos: [String: Int],
                                 include: (String) -> String? = { _ in nil }) -> TranslatedShader? {
        let vsrc = stripPrecision(ShaderPreprocessor.preprocess(vertex, combos: combos, include: include))
        let fsrc = stripPrecision(ShaderPreprocessor.preprocess(fragment, combos: combos, include: include))

        // 유니폼/attribute/varying 수집(주석 어노테이션 보존 위해 본문 정리 전에).
        let vUniforms = parseUniforms(vsrc), fUniforms = parseUniforms(fsrc)
        let varyings = parseVaryings(vsrc + "\n" + fsrc)   // 합집합
        let allUniforms = mergeUniforms(vUniforms + fUniforms)

        var textures: [Int] = []
        var materials: [MaterialParam] = []
        var usesAudio = false
        for u in allUniforms {
            if u.type == .sampler2D, let n = textureIndex(u.name) { textures.append(n) }
            else if isEngine(u.name) { if u.name.contains("AudioSpectrum") { usesAudio = true } }
            else if u.type != .sampler2D {
                let key = u.annotationMaterial ?? defaultKey(u.name)
                materials.append(MaterialParam(glslName: u.name, type: u.type, sceneKey: key,
                                               defaultValue: u.annotationDefault ?? padDefault(u.type)))
            }
        }
        // 엔진 심볼은 선언이 common.h(베이스팩 전용, 대체로 부재)에 있어 파싱에 안 잡힌다 —
        // 본문 토큰 출현으로도 인식(Stage-2 gate 1). 텍스처 슬롯도 방어적으로 본문 스캔 병합.
        let bodyIds = identifiers(in: vsrc).union(identifiers(in: fsrc))
        for id in bodyIds {
            if id.contains("AudioSpectrum16") { usesAudio = true }
            if id.hasPrefix("g_Texture"), !id.hasSuffix("Resolution"), let n = textureIndex(id) { textures.append(n) }
        }
        textures = Array(Set(textures)).sorted()

        // 심볼 치환 사전 구축.
        var frag = symbolMap(materials: materials, stage: .fragment)
        var vert = symbolMap(materials: materials, stage: .vertex)
        for (n, v) in typeAndMacroRenames() { frag[n] = v; vert[n] = v }
        for vy in varyings { frag[vy.name] = "in.\(vy.name)"; vert[vy.name] = "out.\(vy.name)" }
        for a in parseAttributes(vsrc) { vert[a.name] = "vin.\(a.name)" }
        for u in allUniforms where isEngine(u.name) {
            let rep = engineReplacement(u.name)
            frag[u.name] = rep; vert[u.name] = rep
        }
        // 본문 출현 기반 엔진 심볼(선언 부재 시에도 매핑).
        for id in bodyIds where isEngine(id) {
            let rep = engineReplacement(id)
            if frag[id] == nil { frag[id] = rep }
            if vert[id] == nil { vert[id] = rep }
        }
        // 표준 attribute 는 VIn 에 상시 존재 — 선언 없이도 vertex 에서 매핑.
        if vert["a_Position"] == nil { vert["a_Position"] = "vin.a_Position" }
        if vert["a_TexCoord"] == nil { vert["a_TexCoord"] = "vin.a_TexCoord" }
        frag["gl_FragCoord"] = "in.gl_Position"  // [[position]] = 픽셀 좌표

        guard let fragMain = extractMain(fsrc), let vertMain = extractMain(vsrc) else { return nil }

        let fragBody = translateBody(fragMain, symbols: frag, isFragment: true)
        let vertBody = translateBody(vertMain, symbols: vert, isFragment: false)
        guard let fragBody, let vertBody else { return nil }

        // 파일 스코프 const: vert/frag 합집합(이름 dedupe — 공용 헤더가 양쪽에 인라인되는 경우), 타입/매크로만 치환.
        var constNames = Set<String>()
        var consts: [String] = []
        for line in fileScopeConsts(vsrc) + fileScopeConsts(fsrc) {
            let translated = replaceIdentifiers(line, typeAndMacroRenames())
            let name = translated.dropFirst("const ".count).split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if constNames.insert(name).inserted {
                consts.append("constant " + translated.dropFirst("const ".count))
            }
        }

        let msl = assemble(varyings: varyings, textures: textures, materialCount: materials.count,
                           usesAudio: usesAudio, consts: consts, vertBody: vertBody, fragBody: fragBody)
        return TranslatedShader(msl: msl, materialParams: materials, textureSlots: textures, usesAudio: usesAudio)
    }

    // MARK: - 선언 파싱

    /// precision 한정자 제거: `precision ...;` 문 전체 + highp/mediump/lowp 토큰(선언 파서가 타입으로 오인 방지).
    static func stripPrecision(_ src: String) -> String {
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("precision ") }
            .joined(separator: "\n")
        return replaceIdentifiers(lines, ["highp": "", "mediump": "", "lowp": ""])
    }

    struct Uniform { let type: GLSLType; let name: String; let annotationMaterial: String?; let annotationDefault: [Float]? }

    static func parseUniforms(_ src: String) -> [Uniform] {
        var out: [Uniform] = []
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("uniform ") else { continue }
            // "uniform <type> <name>[...]; // {ann}"
            let afterKw = s.dropFirst("uniform ".count)
            let codePart = afterKw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? String(afterKw)
            let toks = codePart.split(separator: " ").map(String.init)
            guard toks.count >= 2, let type = GLSLType(rawValue: toks[0]) else { continue }
            var name = toks[1]
            if let br = name.firstIndex(of: "[") { name = String(name[..<br]) }  // 배열 유니폼(g_AudioSpectrum16Left[16])
            // 주의: range 와 인덱싱 대상이 같은 문자열이어야 함(Substring `line` 에 직접 적용).
            let ann = line.range(of: "//").map { String(line[$0.upperBound...]) } ?? ""
            out.append(Uniform(type: type, name: name,
                               annotationMaterial: jsonStr(ann, "material"),
                               annotationDefault: jsonFloats(ann, "default")))
        }
        return out
    }

    static func parseVaryings(_ src: String) -> [(type: GLSLType, name: String)] {
        var out: [(GLSLType, String)] = []
        var seen = Set<String>()
        for line in src.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("varying ") else { continue }
            let toks = s.dropFirst("varying ".count).split(separator: ";").first?.split(separator: " ").map(String.init) ?? []
            guard toks.count >= 2, let type = GLSLType(rawValue: toks[0]) else { continue }
            let name = toks[1]
            if seen.insert(name).inserted { out.append((type, name)) }
        }
        return out
    }

    static func parseAttributes(_ src: String) -> [(type: GLSLType, name: String)] {
        var out: [(GLSLType, String)] = []
        for line in src.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("attribute ") else { continue }
            let toks = s.dropFirst("attribute ".count).split(separator: ";").first?.split(separator: " ").map(String.init) ?? []
            guard toks.count >= 2, let type = GLSLType(rawValue: toks[0]) else { continue }
            out.append((type, toks[1]))
        }
        return out
    }

    private static func mergeUniforms(_ all: [Uniform]) -> [Uniform] {
        var seen = Set<String>(); var out: [Uniform] = []
        for u in all where seen.insert(u.name).inserted { out.append(u) }
        return out
    }

    // MARK: - 분류 헬퍼

    static func textureIndex(_ name: String) -> Int? {
        guard name.hasPrefix("g_Texture") else { return nil }
        let rest = name.dropFirst("g_Texture".count)
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }
    static func isEngine(_ name: String) -> Bool {
        name == "g_Time" || name == "g_ModelViewProjectionMatrix"
            || name.hasPrefix("g_AudioSpectrum")
            || (name.hasPrefix("g_Texture") && name.hasSuffix("Resolution"))
    }
    static func engineReplacement(_ name: String) -> String {
        if name == "g_Time" { return "eng.timeAndPad.x" }
        if name == "g_ModelViewProjectionMatrix" { return "eng.mvp" }
        if name == "g_AudioSpectrum16Left" { return "audioL" }
        if name == "g_AudioSpectrum16Right" { return "audioR" }
        if name.hasPrefix("g_Texture"), name.hasSuffix("Resolution"),
           let n = Int(name.dropFirst("g_Texture".count).dropLast("Resolution".count)) {
            return "eng.texRes[\(n)]"
        }
        return name
    }
    private static func defaultKey(_ name: String) -> String {
        name.hasPrefix("g_") ? String(name.dropFirst(2)).lowercased() : name.lowercased()
    }
    private static func padDefault(_ t: GLSLType) -> [Float] { Array(repeating: 0, count: max(1, t.components)) }

    /// 파일 스코프(중괄호 깊이 0) `const <type> <name> = ...;` 줄 수집.
    static func fileScopeConsts(_ src: String) -> [String] {
        var out: [String] = []
        var depth = 0
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if depth == 0, t.hasPrefix("const ") { out.append(t) }
            for c in line { if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) } }
        }
        return out
    }

    private enum Stage { case vertex, fragment }
    private static func symbolMap(materials: [MaterialParam], stage: Stage) -> [String: String] {
        var m: [String: String] = [:]
        for (i, p) in materials.enumerated() { m[p.glslName] = "p[\(i)]\(p.type.swizzle)" }
        return m
    }
    private static func typeAndMacroRenames() -> [String: String] {
        ["vec2": "float2", "vec3": "float3", "vec4": "float4", "mat3": "float3x3", "mat4": "float4x4",
         "CAST2": "float2", "CAST3": "float3", "CAST4": "float4",
         "frac": "fract", "lerp": "mix", "M_PI": "3.14159265359", "M_PI_HALF": "1.57079632679", "M_PI_2": "6.28318530718"]
    }

    // MARK: - 본문 변환

    static func extractMain(_ src: String) -> String? {
        guard let r = src.range(of: "void main") else { return nil }
        guard let braceStart = src[r.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = braceStart
        while i < src.endIndex {
            if src[i] == "{" { depth += 1 }
            else if src[i] == "}" { depth -= 1; if depth == 0 { return String(src[src.index(after: braceStart)..<i]) } }
            i = src.index(after: i)
        }
        return nil
    }

    static func translateBody(_ body: String, symbols: [String: String], isFragment: Bool) -> String? {
        var s = body
        // 1) mul(a,b) → (b * a)
        s = rewriteCall(s, "mul") { args in args.count == 2 ? "(\(args[1]) * \(args[0]))" : nil }
        // 2) texSample2D(t, uv) → t.sample(smp, uv)
        s = rewriteCall(s, "texSample2D") { args in args.count == 2 ? "\(args[0]).sample(smp, \(args[1]))" : nil }
        // 3) 식별자/타입 단일 패스 치환
        s = replaceIdentifiers(s, symbols)
        // 4) gl_Position / gl_FragColor
        if isFragment {
            // gl_FragColor = EXPR;  →  premultiplied 반환
            s = rewriteAssign(s, "gl_FragColor") { expr in
                "{ float4 _frag = (\(expr)); _frag.rgb *= _frag.a; return _frag; }"
            }
        } else {
            s = s.replacingOccurrences(of: "gl_Position", with: "out.gl_Position")
        }
        return s
    }

    // MARK: - 어셈블

    private static func assemble(varyings: [(type: GLSLType, name: String)], textures: [Int],
                                 materialCount: Int, usesAudio: Bool, consts: [String] = [],
                                 vertBody: String, fragBody: String) -> String {
        var vary = "struct Vary {\n  float4 gl_Position [[position]];\n"
        for v in varyings { vary += "  \(v.type.msl) \(v.name);\n" }
        vary += "};\n"
        let vin = "struct VIn { float3 a_Position [[attribute(0)]]; float2 a_TexCoord [[attribute(1)]]; };\n"
        let eng = "struct EngineU { float4x4 mvp; float4 timeAndPad; float4 texRes[8]; };\n"

        // fragment 텍스처 파라미터
        var fragTex = textures.map { "texture2d<float> g_Texture\($0) [[texture(\($0))]]" }.joined(separator: ",\n                        ")
        if !fragTex.isEmpty { fragTex = ",\n                        " + fragTex }
        let audioFrag = usesAudio ? ",\n                        constant float* audioL [[buffer(2)]], constant float* audioR [[buffer(3)]]" : ""
        let pFrag = materialCount > 0 ? ",\n                        constant float4* p [[buffer(0)]]" : ""

        let vertSig = """
        vertex Vary ev_main(VIn vin [[stage_in]]\(materialCount > 0 ? ", constant float4* p [[buffer(0)]]" : ""), constant EngineU& eng [[buffer(1)]]) {
            Vary out;
        \(indent(vertBody))
            return out;
        }
        """
        let fragSig = """
        fragment float4 ef_main(Vary in [[stage_in]]\(pFrag), constant EngineU& eng [[buffer(1)]]\(fragTex)\(audioFrag)) {
            constexpr sampler smp(filter::linear, address::clamp_to_edge);
        \(indent(fragBody))
        }
        """
        let constBlock = consts.isEmpty ? "" : consts.joined(separator: "\n") + "\n"
        return "#include <metal_stdlib>\nusing namespace metal;\n\(eng)\(vin)\(vary)\(constBlock)\n\(vertSig)\n\n\(fragSig)\n"
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    // MARK: - 저수준 문자열 도구

    /// `name(args)` 를 balanced-paren 으로 찾아 transform(args) 로 치환. transform nil → 원형 유지.
    static func rewriteCall(_ src: String, _ name: String, _ transform: ([String]) -> String?) -> String {
        let chars = Array(src)
        var out = ""
        var i = 0
        let pat = Array(name + "(")
        while i < chars.count {
            if matchWord(chars, i, name), i + pat.count <= chars.count, Array(chars[i..<i + pat.count]) == pat {
                // 인자 추출(balanced)
                var depth = 0; var j = i + name.count; var args: [String] = []; var cur = ""
                while j < chars.count {
                    let c = chars[j]
                    if c == "(" { depth += 1; if depth == 1 { j += 1; continue } }
                    if c == ")" { depth -= 1; if depth == 0 { if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !args.isEmpty { args.append(cur.trimmingCharacters(in: .whitespaces)) }; j += 1; break } }
                    if c == "," && depth == 1 { args.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; j += 1; continue }
                    cur.append(c); j += 1
                }
                // 인자 자체에 동일 매크로가 중첩될 수 있으니 재귀 적용
                let recArgs = args.map { rewriteCall($0, name, transform) }
                if let rep = transform(recArgs) { out += rep; i = j; continue }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// `target = EXPR;` (단순 대입; target 에 스위즐 없는 경우) → transform(EXPR).
    private static func rewriteAssign(_ src: String, _ target: String, _ transform: (String) -> String) -> String {
        var out = src
        while let r = out.range(of: target + " = ") {
            guard let semi = out[r.upperBound...].firstIndex(of: ";") else { break }
            let expr = String(out[r.upperBound..<semi]).trimmingCharacters(in: .whitespaces)
            out.replaceSubrange(r.lowerBound...semi, with: transform(expr))
        }
        return out
    }

    /// whole-word 식별자를 사전으로 단일 패스 치환(재매치 없음).
    static func replaceIdentifiers(_ src: String, _ map: [String: String]) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c == "_" {
                var id = ""; let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { id.append(chars[i]); i += 1 }
                // 함수 호출(뒤가 '(')이면서 사전에 없으면 그대로(내장 함수 등)
                out += map[id] ?? id
                _ = start
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// 소스의 식별자 토큰 집합(본문 출현 스캔용).
    static func identifiers(in src: String) -> Set<String> {
        var out = Set<String>()
        var id = ""
        for c in src {
            if c.isLetter || c == "_" || (!id.isEmpty && c.isNumber) { id.append(c) }
            else if !id.isEmpty { out.insert(id); id = "" }
        }
        if !id.isEmpty { out.insert(id) }
        return out
    }

    private static func matchWord(_ chars: [Character], _ i: Int, _ name: String) -> Bool {
        if i > 0, let p = chars[safe: i - 1], p.isLetter || p.isNumber || p == "_" { return false }
        return true
    }

    // MARK: - JSON 어노테이션

    private static func jsonStr(_ s: String, _ key: String) -> String? {
        guard let r = s.range(of: "\"\(key)\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let after = rest[rest.index(after: colon)...]
        guard let q1 = after.firstIndex(of: "\""), let q2 = after[after.index(after: q1)...].firstIndex(of: "\"") else { return nil }
        return String(after[after.index(after: q1)..<q2])
    }
    private static func jsonFloats(_ s: String, _ key: String) -> [Float]? {
        guard let r = s.range(of: "\"\(key)\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let after = rest[rest.index(after: colon)...]
        // 문자열("1 1") 또는 숫자(1.0)
        if let q1 = after.firstIndex(of: "\"") {
            let isNumberBeforeQuote = after[..<q1].contains { $0.isNumber }
            if !isNumberBeforeQuote, let q2 = after[after.index(after: q1)...].firstIndex(of: "\"") {
                return String(after[after.index(after: q1)..<q2]).split(separator: " ").compactMap { Float($0) }
            }
        }
        var num = ""
        for ch in after { if ch == "," || ch == "}" { break }; if ch.isNumber || ch == "." || ch == "-" { num.append(ch) } else if !ch.isWhitespace && !num.isEmpty { break } }
        return Float(num).map { [$0] }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
