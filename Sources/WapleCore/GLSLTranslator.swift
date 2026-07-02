import Foundation

public enum GLSLType: String, Equatable {
    case float, vec2, vec3, vec4, mat3, mat4, sampler2D

    /// GLSL(vec2)·HLSL(float2) 타입명 겸용 해석 — WE 방언은 혼용한다(실물 rand_1_05(in float2 uv)).
    public static func from(_ s: String) -> GLSLType? {
        if let t = GLSLType(rawValue: s) { return t }
        switch s {
        case "float2": return .vec2; case "float3": return .vec3; case "float4": return .vec4
        case "float3x3": return .mat3; case "float4x4": return .mat4
        default: return nil
        }
    }
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
        let (vsrc, vArrays) = expandArrayVaryings(stripPrecision(ShaderPreprocessor.preprocess(vertex, combos: combos, include: include)))
        let (fsrc, fArrays) = expandArrayVaryings(stripPrecision(ShaderPreprocessor.preprocess(fragment, combos: combos, include: include)))

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
        // 본문/함수/const 스캔은 주석 제거본에서 — 주석 속 토큰(예: 죽은 코드의 g_AudioSpectrum16Left)이
        // usesAudio 를 켜 TCC 프롬프트를 유발하거나, 주석 속 중괄호가 깊이 카운터를 깨는 것을 방지.
        // (parseUniforms/varyings/attributes 는 JSON 어노테이션 주석이 필요해 원본 유지.)
        let vClean = stripComments(vsrc)
        let fClean = stripComments(fsrc)
        // 엔진 심볼은 선언이 common.h(베이스팩 전용, 대체로 부재)에 있어 파싱에 안 잡힌다 —
        // 본문 토큰 출현으로도 인식(Stage-2 gate 1). 텍스처 슬롯도 방어적으로 본문 스캔 병합.
        let bodyIds = identifiers(in: vClean).union(identifiers(in: fClean))
        for id in bodyIds {
            if id.contains("AudioSpectrum") { usesAudio = true }
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

        // 함수 파싱은 주석 제거본에서(annotation JSON 중괄호가 balance 를 깨지 않도록).
        let vFns = parseFunctions(vClean)
        let fFns = parseFunctions(fClean)
        guard let vertMainF = vFns.first(where: { $0.name == "main" }),
              let fragMainF = fFns.first(where: { $0.name == "main" }) else { return nil }
        // 헬퍼: vert+frag 합집합(이름 dedupe — 공용 헤더가 양 스테이지에 인라인되는 경우).
        var helperSeen = Set<String>()
        var helpers: [GLSLFunction] = []
        for h in vFns + fFns where h.name != "main" && helperSeen.insert(h.name).inserted { helpers.append(h) }

        // Stage-3 phase 2: 식-레벨 타입체커 — HLSL-관용 벡터 크기 혼합을 절단 삽입으로 MSL 화.
        // 확실한 크기만 개입(미지 0 = 무개입). 스테이지별 env(frag 는 frag 선언 varying 타입 우선).
        var sizeEnv: [String: Int] = ["gl_FragColor": 4, "gl_FragCoord": 4, "gl_Position": 4,
                                      "g_Time": 1, "g_PointerPosition": 2,
                                      "a_TexCoord": 2, "a_Position": 3]
        for vy in varyings { sizeEnv[vy.name] = vy.type.components }
        for m in materials { sizeEnv[m.glslName] = m.type.components }
        for id in bodyIds where isEngine(id) && id.hasSuffix("Resolution") { sizeEnv[id] = 4 }
        var fnSizes: [String: Int] = [:]
        for h in helpers { fnSizes[h.name] = GLSLTypeAdapter.typeSize(h.ret) ?? 0 }
        var fragSizeEnv = sizeEnv
        for vy in parseVaryings(fsrc) { fragSizeEnv[vy.name] = vy.type.components }
        let fragMainBody = GLSLTypeAdapter.adapt(body: fragMainF.body,
                                                 env: .init(vars: fragSizeEnv, functions: fnSizes))
        let vertMainBody = GLSLTypeAdapter.adapt(body: vertMainF.body,
                                                 env: .init(vars: sizeEnv, functions: fnSizes))

        // Stage-3 ①②: 지역 섀도잉(varying/머티리얼과 동명의 로컬 선언) → 해당 본문 맵에서 제외
        // (치환하면 `float4 in.x = ...` 로 깨짐); fragment 의 varying 대입 → 로컬 사본으로 승격.
        let fragLocals = localDeclNames(in: fragMainBody)
        let vertLocals = localDeclNames(in: vertMainBody)
        var fragMap = frag, vertMap = vert
        var fragVaryingPrelude = ""
        let fragVaryingTypes = Dictionary(parseVaryings(fsrc).map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        for vy in varyings {
            if fragLocals.contains(vy.name) { fragMap.removeValue(forKey: vy.name) }
            else if isAssigned(vy.name, in: fragMainBody) {
                fragMap[vy.name] = vy.name
                let ty = fragVaryingTypes[vy.name] ?? vy.type  // 스테이지 간 타입 불일치 시 frag 선언 우선
                fragVaryingPrelude += "\(ty.msl) \(vy.name) = in.\(vy.name);\n"
            }
            if vertLocals.contains(vy.name) { vertMap.removeValue(forKey: vy.name) }
        }
        for m in materials {
            if fragLocals.contains(m.glslName) { fragMap.removeValue(forKey: m.glslName) }
            if vertLocals.contains(m.glslName) { vertMap.removeValue(forKey: m.glslName) }
        }
        guard let fragBodyT = translateBody(fragMainBody, symbols: fragMap, isFragment: true),
              let vertBodyT = translateBody(vertMainBody, symbols: vertMap, isFragment: false) else { return nil }
        var fragBody = fragVaryingPrelude + fragBodyT
        var vertBody = vertBodyT

        // 헬퍼 캡처 분석: 본문이 참조하는 컨텍스트 심볼(머티리얼/엔진/varying/attribute/텍스처/오디오/샘플러)을
        // 추가 파라미터로 승격. 호출 그래프 전이 폐쇄(A→B 호출 시 A ⊇ B).
        let captureOf = computeCaptures(helpers: helpers, materials: materials, varyings: varyings, textures: textures)

        // 헬퍼 방출: 프로토타입 전량 선행(정의 순서 무관 호출 가능) + 정의.
        // 헬퍼 내부의 다른 헬퍼 호출엔 캡처 인자를 원 이름으로 전달(자신의 파라미터로 존재).
        var helperProtos: [String] = []
        var helperDefs: [String] = []
        for h in helpers {
            let caps = captureOf[h.name] ?? []
            guard let sig = helperSignature(h, captures: caps, materials: materials) else { continue }  // 미지원 타입 → 스킵
            var helperEnv = sizeEnv
            for prm in h.params { helperEnv[prm.name] = prm.array ? 0 : (GLSLTypeAdapter.typeSize(prm.type) ?? 0) }
            let adaptedBody = GLSLTypeAdapter.adapt(body: h.body, env: .init(vars: helperEnv, functions: fnSizes),
                                                    returnSize: GLSLTypeAdapter.typeSize(h.ret))
            let withCalls = appendCaptureArgs(adaptedBody, helpers: helpers, captureOf: captureOf) { cap in
                rawCaptureName(cap, materials: materials)
            }
            guard let body = translateBody(withCalls, symbols: typeAndMacroRenames(), isFragment: false) else { continue }
            helperProtos.append(sig + ";")
            helperDefs.append(sig + " {\n" + indent(body) + "\n}")
        }
        // main 본문의 헬퍼 호출: 스테이지별 매핑 값으로 캡처 인자 전달.
        fragBody = appendCaptureArgs(fragBody, helpers: helpers, captureOf: captureOf) { cap in
            captureCallArg(cap, isFragment: true, materials: materials)
        }
        vertBody = appendCaptureArgs(vertBody, helpers: helpers, captureOf: captureOf) { cap in
            captureCallArg(cap, isFragment: false, materials: materials)
        }
        // 배열 varying 로컬 배열: frag 는 진입 시 Vary 스칼라 멤버로 구성, vert 는 선언 후 말미에 out 으로 복사.
        for a in fArrays {
            let init0 = (0..<a.count).map { "in.\(a.name)_\($0)" }.joined(separator: ", ")
            fragBody = "\(a.type.msl) \(a.name)[\(a.count)] = { \(init0) };\n" + fragBody
        }
        for a in vArrays {
            vertBody = "\(a.type.msl) \(a.name)[\(a.count)];\n" + vertBody
            vertBody += "\n" + (0..<a.count).map { "out.\(a.name)_\($0) = \(a.name)[\($0)];" }.joined(separator: "\n")
        }

        // 파일 스코프 const: vert/frag 합집합(이름 dedupe — 공용 헤더가 양쪽에 인라인되는 경우), 타입/매크로만 치환.
        // 단, 엔진/머티리얼 심볼을 참조하는 const 는 전역 constant 가 될 수 없다(eng/p 는 함수 파라미터) —
        // main 로컬(const)로 강등해 스테이지 맵으로 치환(잔여 스킵 진단 클래스 2026-07-03).
        var constNames = Set<String>()
        var consts: [String] = []
        var fragLocalConsts = ""
        var vertLocalConsts = ""
        let materialNames = Set(materials.map { $0.glslName })
        for line in fileScopeConsts(vClean) + fileScopeConsts(fClean) {
            let refs = identifiers(in: line)
            let name = line.dropFirst("const ".count).split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard constNames.insert(name).inserted else { continue }
            if refs.contains(where: { isEngine($0) || materialNames.contains($0) }) {
                if let f = translateBody(line, symbols: fragMap, isFragment: false) { fragLocalConsts += f + "\n" }
                if let v = translateBody(line, symbols: vertMap, isFragment: false) { vertLocalConsts += v + "\n" }
            } else {
                let translated = replaceIdentifiers(line, typeAndMacroRenames())
                consts.append("constant " + translated.dropFirst("const ".count))
            }
        }
        fragBody = fragLocalConsts + fragBody
        vertBody = vertLocalConsts + vertBody

        // 스테이지별 오디오 파라미터: 최종 본문에 남은 참조 이름별로 방출(word-정확; 16/32/64 해상도별 버퍼).
        let vertIds = identifiers(in: vertBody)
        let fragIds = identifiers(in: fragBody)
        let msl = assemble(varyings: varyings, textures: textures, materialCount: materials.count,
                           vertAudioNames: audioBufferNames.filter { vertIds.contains($0.name) },
                           fragAudioNames: audioBufferNames.filter { fragIds.contains($0.name) },
                           consts: consts, helperProtos: helperProtos, helperDefs: helperDefs,
                           vertBody: vertBody, fragBody: fragBody)
        return TranslatedShader(msl: msl, materialParams: materials, textureSlots: textures, usesAudio: usesAudio)
    }

    // MARK: - 함수 파싱 (Stage 2)

    struct GLSLFunction: Equatable {
        let ret: String
        let name: String
        let params: [Param]
        let body: String
        struct Param: Equatable { let type: String; let byRef: Bool; let name: String; var array: Bool = false }
    }

    /// GLSL 타입 → MSL 타입(시그니처용). 미지원 타입 nil → 해당 헬퍼 스킵(사용 시 컴파일 실패 → 폴백 안전망).
    static func mslType(_ glsl: String) -> String? {
        switch glsl {
        case "void", "float", "int", "bool": return glsl
        case "vec2", "float2": return "float2"; case "vec3", "float3": return "float3"; case "vec4", "float4": return "float4"
        case "mat3", "float3x3": return "float3x3"; case "mat4", "float4x4": return "float4x4"
        case "sampler2D": return "texture2d<float>"
        default: return nil
        }
    }

    /// 주석 제거(`//` 줄 주석, `/* */` 블록). 함수 본문 balanced-brace 추출이 주석 속 중괄호
    /// (유니폼 JSON 어노테이션 등)에 깨지지 않도록, 함수 파싱은 주석 제거본 위에서 수행한다.
    static func stripComments(_ src: String) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// 파일 스코프 함수 정의 파싱(주석 제거본 입력 가정). `<type> <name>(<params>) { body }`.
    /// 프로토타입(`;`)은 무시. main 포함 전부 반환.
    static func parseFunctions(_ src: String) -> [GLSLFunction] {
        let chars = Array(src)
        var out: [GLSLFunction] = []
        var i = 0
        var depth = 0
        func skipWS(_ j: inout Int) { while j < chars.count, chars[j].isWhitespace { j += 1 } }
        func readIdent(_ j: inout Int) -> String {
            var s = ""
            while j < chars.count, chars[j].isLetter || chars[j] == "_" || (!s.isEmpty && chars[j].isNumber) { s.append(chars[j]); j += 1 }
            return s
        }
        func readBalanced(_ j: inout Int, open: Character, close: Character) -> String? {
            guard j < chars.count, chars[j] == open else { return nil }
            var d = 0; var s = ""
            while j < chars.count {
                if chars[j] == open { d += 1; if d == 1 { j += 1; continue } }
                if chars[j] == close { d -= 1; if d == 0 { j += 1; return s } }
                s.append(chars[j]); j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "{" { depth += 1; i += 1; continue }
            if c == "}" { depth = max(0, depth - 1); i += 1; continue }
            if depth == 0, c.isLetter || c == "_" {
                var j = i
                let t1 = readIdent(&j)
                if mslType(t1) != nil {
                    skipWS(&j)
                    let t2 = readIdent(&j)
                    if !t2.isEmpty {
                        skipWS(&j)
                        if let paramText = readBalanced(&j, open: "(", close: ")") {
                            skipWS(&j)
                            if let body = readBalanced(&j, open: "{", close: "}") {
                                out.append(GLSLFunction(ret: t1, name: t2, params: parseParams(paramText), body: body))
                                i = j
                                continue
                            }
                        }
                    }
                }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    /// 파라미터 목록 파싱: "inout vec2 uv, in float k" → [(vec2,byRef,uv),(float,byVal,k)].
    static func parseParams(_ text: String) -> [GLSLFunction.Param] {
        var out: [GLSLFunction.Param] = []
        for piece in text.split(separator: ",") {
            var toks = piece.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            var byRef = false
            while let first = toks.first, ["in", "out", "inout", "const"].contains(first) {
                if first == "out" || first == "inout" { byRef = true }
                toks.removeFirst()
            }
            guard toks.count >= 2 else { continue }
            var name = toks[1]
            var array = false
            if let br = name.firstIndex(of: "[") {  // `float buf[16]` — 배열 파라미터(실물 pulse.vert)
                name = String(name[..<br])
                array = true
            }
            out.append(GLSLFunction.Param(type: toks[0], byRef: byRef, name: name, array: array))
        }
        return out
    }

    // MARK: - 선언 파싱

    /// precision 한정자 제거: `precision ...;` 문 전체 + highp/mediump/lowp 토큰(선언 파서가 타입으로 오인 방지).
    static func stripPrecision(_ src: String) -> String {
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("precision ") }
            .joined(separator: "\n")
        return replaceIdentifiers(lines, ["highp": "", "mediump": "", "lowp": ""])
    }

    struct ArrayVarying: Equatable { let type: GLSLType; let name: String; let count: Int }

    /// 배열 varying(`varying vec2 v_TexCoord[13];` — 실물 blur/localcontrast 계열) 처리:
    /// Metal 은 stage-in/반환 구조체에 배열을 허용하지 않으므로 선언을 스칼라 멤버(v_TexCoord_0..)로 펼친다.
    /// 본문 접근은 재작성하지 않는다 — main 에 로컬 배열을 놓고(vert: 말미 out 복사, frag: 진입 시 구성)
    /// 리터럴/변수 인덱스 모두 자연 동작(다운샘플 for-루프 등).
    static func expandArrayVaryings(_ src: String) -> (source: String, arrays: [ArrayVarying]) {
        var out: [String] = []
        var arrays: [ArrayVarying] = []
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("varying "), t.contains("[") {
                let toks = t.dropFirst("varying ".count).split(separator: ";").first?
                    .split(separator: " ").map(String.init) ?? []
                if toks.count >= 2, let type = GLSLType.from(toks[0]),
                   let b = toks[1].firstIndex(of: "["), let e = toks[1].firstIndex(of: "]"),
                   b < e, let n = Int(toks[1][toks[1].index(after: b)..<e]), n > 0, n <= 64 {
                    let name = String(toks[1][..<b])
                    arrays.append(ArrayVarying(type: type, name: name, count: n))
                    for k in 0..<n { out.append("varying \(toks[0]) \(name)_\(k);") }
                    continue
                }
            }
            out.append(String(line))
        }
        return (out.joined(separator: "\n"), arrays)
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
            guard toks.count >= 2, let type = GLSLType.from(toks[0]) else { continue }
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
            guard toks.count >= 2, let type = GLSLType.from(toks[0]) else { continue }
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
            guard toks.count >= 2, let type = GLSLType.from(toks[0]) else { continue }
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
        name == "g_Time" || name == "g_ModelViewProjectionMatrix" || name == "g_PointerPosition"
            || name.hasPrefix("g_AudioSpectrum")
            || (name.hasPrefix("g_Texture") && name.hasSuffix("Resolution"))
    }
    static func engineReplacement(_ name: String) -> String {
        if name == "g_Time" { return "eng.timeAndPad.x" }
        if name == "g_PointerPosition" { return "eng.timeAndPad.yz" }  // 마우스 UV(0..1), 미구동 시 0.5,0.5
        if name == "g_ModelViewProjectionMatrix" { return "eng.mvp" }
        if name == "g_AudioSpectrum16Left" { return "audioL" }
        if name == "g_AudioSpectrum16Right" { return "audioR" }
        if name == "g_AudioSpectrum32Left" { return "audioL32" }
        if name == "g_AudioSpectrum32Right" { return "audioR32" }
        if name == "g_AudioSpectrum64Left" { return "audioL64" }
        if name == "g_AudioSpectrum64Right" { return "audioR64" }
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
         "frac": "fract", "lerp": "mix", "ddx": "dfdx", "ddy": "dfdy", "inverse": "we_inverse", "mod": "we_mod",
         "M_PI": "3.14159265359", "M_PI_HALF": "1.57079632679", "M_PI_2": "6.28318530718"]
    }

    // MARK: - 본문 변환

    static func translateBody(_ body: String, symbols: [String: String], isFragment: Bool) -> String? {
        var s = body
        // 1) mul(a,b) → (b * a)
        s = rewriteCall(s, "mul") { args in args.count == 2 ? "(\(args[1]) * \(args[0]))" : nil }
        // 2) texSample2DLod(t, uv, l) → t.sample(smp, uv, level(l)) / texSample2D(t, uv) → t.sample(smp, uv).
        //    UV 는 we_uv() 로 절단 — WE GLSL(HLSL 방언)은 vec3/vec4 를 UV 로 암시적 절단해 넘기는 걸 허용한다.
        s = rewriteCall(s, "texSample2DLod") { args in args.count == 3 ? "\(args[0]).sample(smp, we_uv(\(args[1])), level(\(args[2])))" : nil }
        s = rewriteCall(s, "texSample2D") { args in args.count == 2 ? "\(args[0]).sample(smp, we_uv(\(args[1])))" : nil }
        // 2b) GLSL 2-인자 atan(y,x) → MSL atan2 (1-인자는 유지)
        s = rewriteCall(s, "atan") { args in args.count == 2 ? "atan2(\(args[0]), \(args[1]))" : nil }
        // 3) 식별자/타입 단일 패스 치환
        s = replaceIdentifiers(s, symbols)
        // 4) gl_Position / gl_FragColor
        if isFragment {
            // gl_FragColor 로컬 변수 방식(설계 §3): 다중/스위즐 대입 + 조기 bare return 지원.
            // straight-alpha 출력 — premultiply 주입 없음(WE GLSL 과 1:1; 컴포지트가 1회 premult).
            if s.contains("gl_FragColor") {
                s = rewriteBareReturns(s, with: "return gl_FragColor;")
                s = "float4 gl_FragColor = float4(0.0);\n" + s + "\nreturn gl_FragColor;"
            }
        } else {
            s = s.replacingOccurrences(of: "gl_Position", with: "out.gl_Position")
        }
        return s
    }

    /// `return ;` / `return;`(값 없는 return)을 대체 문장으로 치환(fragment main 용).
    static func rewriteBareReturns(_ src: String, with replacement: String) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            if chars[i] == "r", matchWord(chars, i, "return"),
               i + 6 <= chars.count, String(chars[i..<min(i + 6, chars.count)]) == "return" {
                var j = i + 6
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j < chars.count, chars[j] == ";" {
                    out += replacement
                    i = j + 1
                    continue
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    // MARK: - 어셈블

    // MARK: - 헬퍼 캡처 (Stage 2)

    /// 헬퍼가 참조하는 컨텍스트 심볼 종류. MSL 파일 스코프 함수는 유니폼/varying/텍스처 접근이 불가하므로
    /// 파라미터로 승격한다(설계 §2).
    enum Capture: Hashable {
        case material(Int)                    // materials[i] — 원 GLSL 이름의 값 파라미터
        case engine(String)                   // g_Time / g_ModelViewProjectionMatrix / g_TextureNResolution
        case varying(String, GLSLType)
        case attribute(String, GLSLType)      // a_Position / a_TexCoord
        case texture(Int)                     // g_TextureN
        case audio(String)                    // g_AudioSpectrum16Left/Right
        case sampler                          // texSample2D 사용 시 smp
    }

    /// 헬퍼별 캡처 목록(결정적 순서) + 호출 그래프 전이 폐쇄.
    static func computeCaptures(helpers: [GLSLFunction], materials: [MaterialParam],
                                varyings: [(type: GLSLType, name: String)], textures: [Int]) -> [String: [Capture]] {
        let helperNames = Set(helpers.map { $0.name })
        var refsOf: [String: Set<String>] = [:]
        for h in helpers {
            refsOf[h.name] = identifiers(in: h.body).subtracting(h.params.map { $0.name })
        }
        // 전이 폐쇄: A 가 B 를 호출하면 refs(A) ⊇ refs(B) − B.params (이미 위에서 제외됨).
        var changed = true
        while changed {
            changed = false
            for h in helpers {
                var refs = refsOf[h.name]!
                for g in helpers where g.name != h.name && refs.contains(g.name) {
                    let before = refs.count
                    refs.formUnion(refsOf[g.name]!.subtracting(helperNames))
                    if refs.count != before { changed = true }
                }
                refsOf[h.name] = refs
            }
        }
        var out: [String: [Capture]] = [:]
        for h in helpers {
            let refs = refsOf[h.name]!
            var caps: [Capture] = []
            for (i, m) in materials.enumerated() where refs.contains(m.glslName) { caps.append(.material(i)) }
            for name in refs.filter({ isEngine($0) && !$0.contains("AudioSpectrum") }).sorted() { caps.append(.engine(name)) }
            for v in varyings where refs.contains(v.name) { caps.append(.varying(v.name, v.type)) }
            for (n, t) in [("a_Position", GLSLType.vec3), ("a_TexCoord", GLSLType.vec2)] where refs.contains(n) {
                caps.append(.attribute(n, t))
            }
            for n in textures where refs.contains("g_Texture\(n)") { caps.append(.texture(n)) }
            for n in ["g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
                      "g_AudioSpectrum32Left", "g_AudioSpectrum32Right",
                      "g_AudioSpectrum64Left", "g_AudioSpectrum64Right"] where refs.contains(n) { caps.append(.audio(n)) }
            // 텍스처 샘플링(자기 파라미터의 sampler2D 포함)엔 공용 샘플러가 필요.
            if refs.contains("texSample2D") || refs.contains("texSample2DLod")
                || h.params.contains(where: { $0.type == "sampler2D" }) || caps.contains(where: { if case .texture = $0 { return true }; return false }) {
                caps.append(.sampler)
            }
            out[h.name] = caps
        }
        return out
    }

    /// 오디오 스펙트럼 파라미터 이름 ↔ 고정 버퍼 인덱스(양 스테이지 공통; 4 는 vertex 쿼드 버퍼라 회피).
    static let audioBufferNames: [(name: String, buffer: Int)] = [
        ("audioL", 2), ("audioR", 3), ("audioL32", 5), ("audioR32", 6), ("audioL64", 7), ("audioR64", 8),
    ]

    /// 캡처 파라미터의 헬퍼 내부 이름(원 GLSL 이름 유지 — 다른 헬퍼 호출 시 그대로 전달).
    static func rawCaptureName(_ cap: Capture, materials: [MaterialParam]) -> String {
        switch cap {
        case .material(let i): return materials[i].glslName
        case .engine(let n): return n
        case .varying(let n, _): return n
        case .attribute(let n, _): return n
        case .texture(let n): return "g_Texture\(n)"
        case .audio(let n): return n
        case .sampler: return "smp"
        }
    }

    /// main 호출부에서 전달할 스테이지별 실값.
    static func captureCallArg(_ cap: Capture, isFragment: Bool, materials: [MaterialParam]) -> String {
        switch cap {
        case .material(let i): return "p[\(i)]\(materials[i].type.swizzle)"
        case .engine(let n): return engineReplacement(n)
        case .varying(let n, _): return isFragment ? "in.\(n)" : "out.\(n)"
        case .attribute(let n, _): return "vin.\(n)"  // fragment 에선 비합법 → 컴파일 실패 → 폴백(의도)
        case .texture(let n): return "g_Texture\(n)"
        case .audio(let n): return engineReplacement(n)  // audioL/audioR/audioL32/... 매핑 공유
        case .sampler: return "smp"
        }
    }

    private static func captureParamDecl(_ cap: Capture, materials: [MaterialParam]) -> String {
        switch cap {
        case .material(let i): return "\(materials[i].type.msl) \(materials[i].glslName)"
        case .engine(let n):
            let t = n == "g_ModelViewProjectionMatrix" ? "float4x4"
                : (n.hasSuffix("Resolution") ? "float4" : (n == "g_PointerPosition" ? "float2" : "float"))
            return "\(t) \(n)"
        case .varying(let n, let t): return "\(t.msl) \(n)"
        case .attribute(let n, let t): return "\(t.msl) \(n)"
        case .texture(let n): return "texture2d<float> g_Texture\(n)"
        case .audio(let n): return "constant float* \(n)"
        case .sampler: return "sampler smp"
        }
    }

    /// 본문의 헬퍼 호출에 캡처 인자를 덧붙인다. `argFor` 가 호출 문맥(헬퍼 내부=원 이름, main=매핑 값)을 결정.
    static func appendCaptureArgs(_ body: String, helpers: [GLSLFunction], captureOf: [String: [Capture]],
                                  argFor: (Capture) -> String) -> String {
        var out = body
        for g in helpers {
            guard let caps = captureOf[g.name], !caps.isEmpty else { continue }
            let extra = caps.map(argFor)
            out = rewriteCall(out, g.name) { args in
                "\(g.name)(\((args + extra).joined(separator: ", ")))"
            }
        }
        return out
    }

    /// 헬퍼 시그니처(MSL): 원 파라미터 + 캡처 파라미터. 미지원 타입 포함 시 nil.
    static func helperSignature(_ h: GLSLFunction, captures: [Capture] = [], materials: [MaterialParam] = []) -> String? {
        guard let ret = mslType(h.ret) else { return nil }
        var ps: [String] = []
        for p in h.params {
            guard let t = mslType(p.type) else { return nil }
            // 배열 파라미터는 constant 포인터(호출부의 audioL/캡처 배열과 정합; MSL 은 값-배열 불가).
            if p.array { ps.append("constant \(t)* \(p.name)") }
            else { ps.append(p.byRef ? "thread \(t)& \(p.name)" : "\(t) \(p.name)") }
        }
        ps.append(contentsOf: captures.map { captureParamDecl($0, materials: materials) })
        return "inline \(ret) \(h.name)(\(ps.joined(separator: ", ")))"
    }

    private static func assemble(varyings: [(type: GLSLType, name: String)], textures: [Int],
                                 materialCount: Int,
                                 vertAudioNames: [(name: String, buffer: Int)] = [],
                                 fragAudioNames: [(name: String, buffer: Int)] = [],
                                 consts: [String] = [],
                                 helperProtos: [String] = [], helperDefs: [String] = [],
                                 vertBody: String, fragBody: String) -> String {
        var vary = "struct Vary {\n  float4 gl_Position [[position]];\n"
        for v in varyings { vary += "  \(v.type.msl) \(v.name);\n" }
        vary += "};\n"
        let vin = "struct VIn { float3 a_Position [[attribute(0)]]; float2 a_TexCoord [[attribute(1)]]; };\n"
        let eng = "struct EngineU { float4x4 mvp; float4 timeAndPad; float4 texRes[8]; };\n"
        // UV 암시적 절단(HLSL 방언 호환): 오버로드로 타입별 안전 절단.
        let uvHelpers = """
        inline float2 we_uv(float2 v) { return v; }
        inline float2 we_uv(float3 v) { return v.xy; }
        inline float2 we_uv(float4 v) { return v.xy; }
        inline float2 we_uv(float v) { return float2(v); }
        // GLSL mod(x,y) = x - y*floor(x/y) — fmod 와 달리 음수에서 항상 y 부호(오프셋 스크롤 등에 중요).
        inline float we_mod(float x, float y) { return x - y * metal::floor(x / y); }
        inline float2 we_mod(float2 x, float y) { return x - y * metal::floor(x / y); }
        inline float2 we_mod(float2 x, float2 y) { return x - y * metal::floor(x / y); }
        inline float3 we_mod(float3 x, float y) { return x - y * metal::floor(x / y); }
        inline float3 we_mod(float3 x, float3 y) { return x - y * metal::floor(x / y); }
        inline float4 we_mod(float4 x, float y) { return x - y * metal::floor(x / y); }
        inline float4 we_mod(float4 x, float4 y) { return x - y * metal::floor(x / y); }
        // GLSL inverse() 대응(MSL 미내장) — 3x3 adjugate. det≈0 가드(항등 반환).
        inline float3x3 we_inverse(float3x3 m) {
            float3 r0 = cross(m[1], m[2]);
            float3 r1 = cross(m[2], m[0]);
            float3 r2 = cross(m[0], m[1]);
            float det = dot(m[0], r0);
            if (metal::abs(det) < 1e-12) { return float3x3(1.0); }
            return transpose(float3x3(r0, r1, r2)) * (1.0 / det);
        }

        """

        // fragment 텍스처 파라미터
        var fragTex = textures.map { "texture2d<float> g_Texture\($0) [[texture(\($0))]]" }.joined(separator: ",\n                        ")
        if !fragTex.isEmpty { fragTex = ",\n                        " + fragTex }
        func audioDecl(_ names: [(name: String, buffer: Int)], sep: String) -> String {
            names.map { "\(sep)constant float* \($0.name) [[buffer(\($0.buffer))]]" }.joined()
        }
        let audioParams = audioDecl(vertAudioNames, sep: ", ")
        let audioFrag = audioDecl(fragAudioNames, sep: ",\n                        ")
        let pFrag = materialCount > 0 ? ",\n                        constant float4* p [[buffer(0)]]" : ""

        let vertSig = """
        vertex Vary ev_main(VIn vin [[stage_in]]\(materialCount > 0 ? ", constant float4* p [[buffer(0)]]" : ""), constant EngineU& eng [[buffer(1)]]\(audioParams)) {
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
        let protoBlock = helperProtos.isEmpty ? "" : helperProtos.joined(separator: "\n") + "\n"
        let defBlock = helperDefs.isEmpty ? "" : helperDefs.joined(separator: "\n\n") + "\n"
        return "#include <metal_stdlib>\nusing namespace metal;\n\(eng)\(vin)\(vary)\(uvHelpers)\(constBlock)\(protoBlock)\(defBlock)\n\(vertSig)\n\n\(fragSig)\n"
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

    /// 본문의 지역 선언 이름( `<type> NAME =|;|,` ) — varying/머티리얼 섀도잉 감지용(Stage-3 ①).
    static func localDeclNames(in body: String) -> Set<String> {
        var out = Set<String>()
        let chars = Array(body); var i = 0
        func ident(_ j: inout Int) -> String {
            var s = ""
            while j < chars.count, chars[j].isLetter || chars[j] == "_" || (!s.isEmpty && chars[j].isNumber) { s.append(chars[j]); j += 1 }
            return s
        }
        while i < chars.count {
            if chars[i].isLetter || chars[i] == "_" {
                var j = i
                let t1 = ident(&j)
                if mslType(t1) != nil, t1 != "void" {
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    var k = j
                    let name = ident(&k)
                    if !name.isEmpty {
                        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                        if k < chars.count, chars[k] == "=" || chars[k] == ";" || chars[k] == "," { out.insert(name) }
                    }
                }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    /// 본문에서 NAME(스위즐 허용)에 대입(=, +=, -=, *=, /=; == 제외)이 있는지 — varying 쓰기 감지(Stage-3 ②).
    static func isAssigned(_ name: String, in body: String) -> Bool {
        let chars = Array(body); var i = 0
        let n = Array(name)
        while i <= chars.count - n.count {
            if chars[i] == n[0], matchWord(chars, i, name), Array(chars[i..<i+n.count]) == n {
                var j = i + n.count
                if j < chars.count, chars[j] == "." {  // 스위즐 스킵
                    j += 1
                    while j < chars.count, chars[j].isLetter { j += 1 }
                }
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j < chars.count {
                    if chars[j] == "=", j + 1 < chars.count, chars[j+1] != "=" { return true }
                    if "+-*/".contains(chars[j]), j + 1 < chars.count, chars[j+1] == "=" { return true }
                }
                i += n.count
                continue
            }
            i += 1
        }
        return false
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
