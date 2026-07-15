import Foundation

public enum GLSLType: String, Equatable {
    case float, vec2, vec3, vec4, mat2, mat3, mat4, sampler2D

    /// GLSL(vec2)·HLSL(float2) 타입명 겸용 해석 — WE 방언은 혼용한다(실물 rand_1_05(in float2 uv)).
    public static func from(_ s: String) -> GLSLType? {
        if let t = GLSLType(rawValue: s) { return t }
        switch s {
        case "float2": return .vec2; case "float3": return .vec3; case "float4": return .vec4
        case "float2x2": return .mat2; case "float3x3": return .mat3; case "float4x4": return .mat4
        default: return nil
        }
    }
    var components: Int { switch self { case .float: return 1; case .vec2: return 2; case .vec3: return 3; case .vec4: return 4; default: return 0 } }
    var msl: String {
        switch self {
        case .float: return "float"; case .vec2: return "float2"; case .vec3: return "float3"
        case .vec4: return "float4"; case .mat2: return "float2x2"; case .mat3: return "float3x3"; case .mat4: return "float4x4"
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
    // MARK: - 번역 메모이즈 (프로세스 전역, 마운트 간·재마운트 공유)
    // 번역은 (vertex, fragment, combos, include) 의 순수 함수(씬 상수 값은 번역기 밖 buildPassMaterial 에서
    // 적용 → 출력에 안 굽힘 → 전역 공유 안전). 키 = raw 소스 + 인라인된 소스 + 정규화 combos:
    //   · raw(vertex/fragment): 교차스테이지 콤보 union 은 _translate 가 raw 소스에서 parseComboDefaults 로
    //     만든다(인라인 前) — 인클루드-내 [COMBO] 는 raw 엔 없어 union 에 안 들어간다. raw 를 키에 넣어야
    //     union 을 정확히 고정(인라인만으론 인클루드 [COMBO] 를 과다 계상해 vertex 분기 aliasing).
    //   · 인라인(inlinedSource): #include 는 조건부 평가 前 무조건 인라인되므로 include 내용을 정확히 포착
    //     = base-assets 교체/패키지별 인클루드 상이 시 자동 분기(스테일 히트 없음). raw 만으론 include 내용 미포착.
    //   · 히트 시 조건부 평가/매크로 fixpoint(preprocess 의 66-87% 실측) + 파싱/방출(core) 전량 스킵.
    //     inlinedSource 비용은 preprocess 의 1-2% 뿐 → 키 생성 저렴(측정: `ppInline` 1-2% vs `ppCond` 66-87%).
    // 완전성: 동일 키 ⟹ raw v/f·combos 동일 ⟹ union 등 include 외 전부 동일, include 는 인라인이 고정.
    // 무효화 불필요(내용 기반), teardown 에서 비우지 않음(재마운트·크로스씬 수혜가 목적).
    private struct MemoKey: Hashable {
        let vRaw: String; let fRaw: String; let vInlined: String; let fInlined: String; let combos: String
    }
    private static var memoCache: [MemoKey: TranslatedShader?] = [:]
    private static let memoLock = NSLock()   // DeepScan.concurrentPerform 가 translate 를 동시 호출 → 필수.
    // 상한 불요: 유니크 키는 사용자 라이브러리의 유한 셰이더 수(수백~저수천)로 바운드,
    // 엔트리당 인라인소스+MSL 수십 KB → 수십 MB 천장. 필요 시 count 상한+FIFO 로 승격.

    /// 테스트 전용: 프로세스 전역 캐시라 테스트 간 격리·미스(실번역) 카운트 관측을 위해 제공(@testable).
    public private(set) static var memoComputeCount = 0
    static func _resetTranslationMemoForTesting() {
        memoLock.lock(); defer { memoLock.unlock() }
        memoCache.removeAll(); memoComputeCount = 0
    }

    public static func translate(vertex: String, fragment: String, combos: [String: Int],
                                 include: (String) -> String? = { _ in nil }) -> TranslatedShader? {
        guard WapleProfiler.enabled else {
            return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { WapleProfiler.recordTranslate(seconds: CFAbsoluteTimeGetCurrent() - t0) }
        return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include)
    }

    /// 메모이즈 진입: 키(인라인 소스+combos) 조회 → 히트 반환, 미스 시 실번역 후 저장. 실패(nil)도 캐시
    /// (결정적 — 동일 입력 재실패 반복 회피). 실번역은 락 밖(동시 미스 = 동일 순수출력 재계산일 뿐 무해).
    private static func _memoizedTranslate(vertex: String, fragment: String, combos: [String: Int],
                                           include: (String) -> String?) -> TranslatedShader? {
        let key = MemoKey(vRaw: vertex, fRaw: fragment,
                          vInlined: ShaderPreprocessor.inlinedSource(vertex, include: include),
                          fInlined: ShaderPreprocessor.inlinedSource(fragment, include: include),
                          combos: combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
        memoLock.lock()
        if let cached = memoCache[key] { memoLock.unlock(); return cached }
        memoLock.unlock()
        let result = _translate(vertex: vertex, fragment: fragment, combos: combos, include: include)
        memoLock.lock()
        memoCache[key] = result
        memoComputeCount += 1
        memoLock.unlock()
        return result
    }

    private static func _translate(vertex: String, fragment: String, combos: [String: Int],
                                   include: (String) -> String?) -> TranslatedShader? {
        // [COMBO] 기본값은 스테이지 합집합 — vert 에만 선언된 콤보(실물 auto_sway 의 AA_VERSION)를
        // frag 도 봐야 한다(WE 는 효과 단위로 콤보를 병합).
        var combos = combos
        for src in [vertex, fragment] {
            for (k, v) in ShaderPreprocessor.parseComboDefaults(src) where combos[k] == nil { combos[k] = v }
        }
        // 블록 주석은 여기서 제거(`//` 어노테이션은 보존) — `/* uniform ... */` 속 죽은 선언이
        // 줄 단위 선언 파서에 실선언으로 잡히면 usesAudio 오점화(불필요 TCC 프롬프트)/유령 슬롯이 생긴다.
        let (vsrc, vArrays) = expandArrayVaryings(stripPrecision(stripBlockComments(ShaderPreprocessor.preprocess(vertex, combos: combos, include: include))))
        let (fsrc, fArrays) = expandArrayVaryings(stripPrecision(stripBlockComments(ShaderPreprocessor.preprocess(fragment, combos: combos, include: include))))

        // 유니폼/attribute/varying 수집(주석 어노테이션 보존 위해 본문 정리 전에).
        let vUniforms = parseUniforms(vsrc), fUniforms = parseUniforms(fsrc)
        let vVaryings = parseVaryings(vsrc)
        let varyings = parseVaryings(vsrc + "\n" + fsrc)   // 합집합
        let vVaryingTypes = Dictionary(uniqueKeysWithValues: vVaryings.map { ($0.name, $0.type) })
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
                                               defaultValue: u.annotationDefault ?? engineNeutralDefault(u.name, u.type)))
            }
        }
        // 본문/함수/const 스캔은 주석 제거본에서 — 주석 속 토큰(예: 죽은 코드의 g_AudioSpectrum16Left)이
        // usesAudio 를 켜 TCC 프롬프트를 유발하거나, 주석 속 중괄호가 깊이 카운터를 깨는 것을 방지.
        // (parseUniforms/varyings/attributes 는 `//` JSON 어노테이션이 필요해 줄 주석만 보존 — 블록 주석은 위에서 제거.)
        // MSL 예약어가 GLSL 식별자(파라미터/지역 등)로 쓰이는 실물(test_shader 의 `vec2 fragment`) —
        // 소스 수준에서 안전 리네임. 우리가 방출하는 `fragment float4 ef_main` 은 이후 생성이라 무관.
        let reservedRenames = ["fragment": "we_fragment", "vertex": "we_vertex", "kernel": "we_kernel",
                               "device": "we_device", "thread": "we_thread", "threadgroup": "we_threadgroup",
                               "constant": "we_constant", "using": "we_using", "namespace": "we_namespace",
                               "half": "we_half",
                               // C++ 대체 토큰(MSL 예약어)이 GLSL 식별자로 쓰이는 실물(dot_matrix 의 지역 `vec2 or`).
                               "or": "we_or", "and": "we_and", "not": "we_not", "xor": "we_xor",
                               "compl": "we_compl", "bitand": "we_bitand", "bitor": "we_bitor",
                               // 우리 방출 파라미터명과의 충돌(실물 geodraw: 지역 float2 p)
                               "p": "we_p", "eng": "we_eng", "smp": "we_smp", "vin": "we_vin"]
        let vClean = replaceIdentifiers(stripComments(vsrc), reservedRenames)
        let fClean = replaceIdentifiers(stripComments(fsrc), reservedRenames)
        // 소스 정의 struct(실물 dot_matrix 의 `struct Grid`): 함수 파싱 전에 이름 등록(반환/파라미터 타입 통과).
        var structDefs: [GLSLStruct] = []
        var structSeen = Set<String>()
        for s in parseStructs(vClean) + parseStructs(fClean) where structSeen.insert(s.name).inserted { structDefs.append(s) }
        let structNames = structSeen
        // 엔진 심볼은 선언이 common.h(베이스팩 전용, 대체로 부재)에 있어 파싱에 안 잡힌다 —
        // 본문 토큰 출현으로도 인식(Stage-2 gate 1). 텍스처 슬롯도 방어적으로 본문 스캔 병합.
        let bodyIds = identifiers(in: vClean).union(identifiers(in: fClean))
        for id in bodyIds {
            if id.contains("AudioSpectrum") { usesAudio = true }
            if id.hasPrefix("g_Texture"), !id.hasSuffix("Resolution"), let n = textureIndex(id) { textures.append(n) }
        }
        textures = Array(Set(textures)).sorted()

        // 심볼 치환 사전 구축.
        var frag = symbolMap(materials: materials)
        var vert = symbolMap(materials: materials)
        for (n, v) in typeAndMacroRenames() { frag[n] = v; vert[n] = v }
        for vy in varyings {
            // 스테이지 간 타입 불일치(vert vec4/frag vec2)는 타입어댑터가 union 크기로 coerce 한다 —
            // 치환맵에 스위즐을 붙이면 사용처 자체 스위즐과 이중화(실물 water_caustics `.xy.zw`).
            frag[vy.name] = "in.\(vy.name)"
            if let vt = vVaryingTypes[vy.name], vt.components > 0, vt.components < vy.type.components {
                vert[vy.name] = "out.\(vy.name)\(swizzle(vt.components))"
            } else {
                vert[vy.name] = "out.\(vy.name)"
            }
        }
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
        var vFns = parseFunctions(vClean, structs: structNames)
        var fFns = parseFunctions(fClean, structs: structNames)
        var overloadSizeEnv: [String: Int] = ["gl_FragColor": 4, "gl_FragCoord": 4, "gl_Position": 4,
                                              "g_Time": 1, "g_PointerPosition": 2,
                                              "a_TexCoord": 2, "a_Position": 3]
        for vy in varyings { overloadSizeEnv[vy.name] = vy.type.components }
        for m in materials { overloadSizeEnv[m.glslName] = m.type.components }
        for id in bodyIds where isEngine(id) && id.hasSuffix("Resolution") { overloadSizeEnv[id] = 4 }
        var vertexOverloadSizeEnv = overloadSizeEnv
        for (name, type) in vVaryingTypes where type.components > 0 { vertexOverloadSizeEnv[name] = type.components }
        vFns = rewriteSameStageOverloads(vFns, baseEnv: vertexOverloadSizeEnv)
        fFns = rewriteSameStageOverloads(fFns, baseEnv: overloadSizeEnv)
        guard let vertMainF = vFns.first(where: { $0.name == "main" }),
              let fragMainF = fFns.first(where: { $0.name == "main" }) else { return nil }
        // 헬퍼: vert+frag 합집합(이름 dedupe — 공용 헤더가 양 스테이지에 인라인되는 경우).
        var helperSeen = Set<String>()
        var helpers: [GLSLFunction] = []
        var fragMainBodyPre = fragMainF.body
        for h in vFns where h.name != "main" && helperSeen.insert(h.name).inserted { helpers.append(h) }
        var fragHelperRenames: [String: String] = [:]
        for h in fFns where h.name != "main" {
            if helperSeen.insert(h.name).inserted {
                helpers.append(h)
            } else if let existing = helpers.first(where: { $0.name == h.name }),
                      existing.params.map({ $0.type }) != h.params.map({ $0.type }) || existing.body != h.body {
                // 동명이지만 다른 정의(실물 radial_blur: vert/frag 각자 computeUV) — frag 쪽 리네임.
                let newName = h.name + "_f"
                guard helperSeen.insert(newName).inserted else { continue }
                var renamed = h
                renamed.body = replaceIdentifiers(h.body, [h.name: newName])
                helpers.append(GLSLFunction(ret: renamed.ret, name: newName, params: renamed.params, body: renamed.body))
                fragHelperRenames[h.name] = newName
            }
        }
        if !fragHelperRenames.isEmpty {
            fragMainBodyPre = replaceIdentifiers(fragMainBodyPre, fragHelperRenames)
            for i in helpers.indices where fFns.contains(where: { $0.name == helpers[i].name || helpers[i].name == $0.name + "_f" }) {
                // frag 유래 헬퍼 본문 내 호출도 리네임(vert 유래 정의를 잘못 부르지 않도록).
                if fFns.contains(where: { $0.name + "_f" == helpers[i].name }) || (fFns.contains(where: { $0.name == helpers[i].name }) && !vFns.contains(where: { $0.name == helpers[i].name })) {
                    helpers[i].body = replaceIdentifiers(helpers[i].body, fragHelperRenames)
                }
            }
        }

        // 파일 스코프 const 중 전역 MSL `constant` 가 될 수 없어 함수 스코프로 강등해야 하는 것들(mustDemote):
        //  ① 엔진/머티리얼 심볼 참조(eng/p 는 함수 파라미터라 전역에서 안 보임) 또는
        //  ② 비-constexpr 초기화 — pow/sin 등 런타임 호출은 전역 생성자(llvm.global_ctors)가 필요해 makeLibrary
        //     가 거부(실물 audio_responsive_oscilloscope 의 pow(userBalance.x/userBalance.y, 2.0)). 또는
        //  ③ ①②에 해당하는 다른 const 참조(전이 폐쇄 — 전역 const 가 로컬 강등 const 를 못 봄).
        let materialNames0 = Set(materials.map { $0.glslName })
        var constByName: [String: String] = [:]      // 이름 → 선언 줄(dedupe)
        var constOrder: [String] = []                // 소스 순서(강등 로컬 방출 시 의존성 순서 보존)
        for line in fileScopeConsts(vClean) + fileScopeConsts(fClean) {
            let n = constDeclName(line)
            guard !n.isEmpty, constByName[n] == nil else { continue }
            constByName[n] = line; constOrder.append(n)
        }
        var mustDemote = Set<String>()
        for n in constOrder {
            let line = constByName[n]!
            if identifiers(in: line).contains(where: { isEngine($0) || materialNames0.contains($0) })
                || constInitHasRuntimeCall(line) { mustDemote.insert(n) }
        }
        var demoteChanged = true
        while demoteChanged {
            demoteChanged = false
            for n in constOrder where !mustDemote.contains(n) {
                if identifiers(in: constByName[n]!).contains(where: { $0 != n && mustDemote.contains($0) }) {
                    mustDemote.insert(n); demoteChanged = true
                }
            }
        }

        // 강등 const 를 참조하는 헬퍼 → 본문 선두에 const 선언 주입(캡처 계산 전 — 우변 엔진/머티리얼 심볼이
        // 파라미터로 승격되도록). 실물 radial_blur: `const vec2 type = ...(g_Texture0Resolution...)` 를 computeUV 가 사용.
        if !mustDemote.isEmpty {
            let demoted = constOrder.filter { mustDemote.contains($0) }.map { (name: $0, line: constByName[$0]!) }
            for i in helpers.indices {
                let refs = identifiers(in: helpers[i].body)
                let needed = demoted.filter { refs.contains($0.name) }
                guard !needed.isEmpty else { continue }
                helpers[i].body = needed.map { $0.line }.joined(separator: "\n") + "\n" + helpers[i].body
            }
        }

        // Stage-3 phase 2: 식-레벨 타입체커 — HLSL-관용 벡터 크기 혼합을 절단 삽입으로 MSL 화.
        // 확실한 크기만 개입(미지 0 = 무개입). 스테이지별 env(frag 는 frag 선언 varying 타입 우선).
        var sizeEnv: [String: Int] = ["gl_FragColor": 4, "gl_FragCoord": 4, "gl_Position": 4,
                                      "g_Time": 1, "g_PointerPosition": 2,
                                      "a_TexCoord": 2, "a_Position": 3]
        for vy in varyings { sizeEnv[vy.name] = vy.type.components }
        for m in materials { sizeEnv[m.glslName] = m.type.components }
        for id in bodyIds where isEngine(id) && id.hasSuffix("Resolution") { sizeEnv[id] = 4 }
        var fnSizes: [String: Int] = [:]
        var fnParamSizes: [String: [Int]] = [:]
        for h in helpers {
            fnSizes[h.name] = GLSLTypeAdapter.typeSize(h.ret) ?? 0
            fnParamSizes[h.name] = h.params.map { $0.array ? 0 : (GLSLTypeAdapter.typeSize($0.type) ?? 0) }
        }
        var vertSizeEnv = sizeEnv
        for (name, type) in vVaryingTypes where type.components > 0 { vertSizeEnv[name] = type.components }
        let fragSizeEnv = sizeEnv  // varying 크기는 union(Vary 멤버 실타입) — frag 소형 선언은 어댑터가 coerce
        let fragMainBody = GLSLTypeAdapter.adapt(body: fragMainBodyPre,
                                                 env: .init(vars: fragSizeEnv, functions: fnSizes, functionParams: fnParamSizes))
        let vertMainBody = GLSLTypeAdapter.adapt(body: vertMainF.body,
                                                 env: .init(vars: vertSizeEnv, functions: fnSizes, functionParams: fnParamSizes))

        // Stage-3 ①②: 지역 섀도잉(varying/머티리얼과 동명의 로컬 선언) → 해당 본문 맵에서 제외
        // (치환하면 `float4 in.x = ...` 로 깨짐); fragment 의 varying 대입 → 로컬 사본으로 승격.
        let fragLocals = localDeclNames(in: fragMainBody, structs: structNames)
        let vertLocals = localDeclNames(in: vertMainBody, structs: structNames)
        var fragMap = frag, vertMap = vert
        var fragVaryingPrelude = ""
        var promotedVaryings = Set<String>()  // frag 대입→로컬 승격된 varying(헬퍼 캡처 인자 결정용)
        for vy in varyings {
            if fragLocals.contains(vy.name) { fragMap.removeValue(forKey: vy.name) }
            else if isAssigned(vy.name, in: fragMainBody) {
                fragMap[vy.name] = vy.name
                fragVaryingPrelude += "\(vy.type.msl) \(vy.name) = in.\(vy.name);\n"
                promotedVaryings.insert(vy.name)
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
            guard let sig = helperSignature(h, captures: caps, materials: materials, structs: structNames) else { continue }  // 미지원 타입 → 스킵
            var helperEnv = sizeEnv
            for prm in h.params { helperEnv[prm.name] = prm.array ? 0 : (GLSLTypeAdapter.typeSize(prm.type) ?? 0) }
            // int/uint 파라미터명은 어댑터에 int 로 알려 min/max(int,float) 모호성 해소(실물 multistage_wave).
            let intParams = Set(h.params.filter { $0.type == "int" || $0.type == "uint" }.map { $0.name })
            let adaptedBody = GLSLTypeAdapter.adapt(body: h.body, env: .init(vars: helperEnv, functions: fnSizes, functionParams: fnParamSizes, intVars: intParams),
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
            // 승격 varying 은 로컬 사본을 전달 — `in.<n>` 은 대입 전 보간값이라 헬퍼가 낡은 값을 읽는다.
            // (GLSL 에서 varying 은 전역: main 의 대입을 헬퍼가 봐야 한다.)
            if case .varying(let n, _) = cap, promotedVaryings.contains(n) { return n }
            return captureCallArg(cap, isFragment: true, materials: materials)
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
        for line in fileScopeConsts(vClean) + fileScopeConsts(fClean) {
            let name = constDeclName(line)
            guard constNames.insert(name).inserted else { continue }
            if mustDemote.contains(name) {
                // 함수 로컬 강등(스테이지별) — 소스 순서 유지로 강등 const 간 의존성 보존.
                if let f = translateBody(line, symbols: fragMap, isFragment: false) { fragLocalConsts += f + "\n" }
                if let v = translateBody(line, symbols: vertMap, isFragment: false) { vertLocalConsts += v + "\n" }
            } else {
                let translated = rewriteArrayConstructors(replaceIdentifiers(line, typeAndMacroRenames()))
                consts.append("constant " + translated.dropFirst("const ".count))
            }
        }
        fragBody = fragLocalConsts + fragBody
        vertBody = vertLocalConsts + vertBody

        // 스테이지별 오디오 파라미터: 최종 본문에 남은 참조 이름별로 방출(word-정확; 16/32/64 해상도별 버퍼).
        let vertIds = identifiers(in: vertBody)
        let fragIds = identifiers(in: fragBody)
        // 소스 struct 정의: 멤버 타입 리네임(vec2→float2 등) 후 프리앰블 선두에 방출(헬퍼 시그니처가 참조).
        let structBlock = structDefs.map { "struct \($0.name) {" + replaceIdentifiers($0.body, typeAndMacroRenames()) + "};" }
            .joined(separator: "\n")
        let msl = assemble(varyings: varyings, textures: textures, materialCount: materials.count,
                           vertAudioNames: audioBufferNames.filter { vertIds.contains($0.name) },
                           fragAudioNames: audioBufferNames.filter { fragIds.contains($0.name) },
                           consts: consts, helperProtos: helperProtos, helperDefs: helperDefs,
                           vertBody: vertBody, fragBody: fragBody, structs: structBlock)
        return TranslatedShader(msl: msl, materialParams: materials, textureSlots: textures, usesAudio: usesAudio)
    }

    // MARK: - 함수 파싱 (Stage 2)

    struct GLSLFunction: Equatable {
        let ret: String
        let name: String
        let params: [Param]
        var body: String
        struct Param: Equatable { let type: String; let byRef: Bool; let name: String; var array: Bool = false }
    }

    /// GLSL 타입 → MSL 타입(시그니처용). 미지원 타입 nil → 해당 헬퍼 스킵(사용 시 컴파일 실패 → 폴백 안전망).
    /// `structs`: 소스 정의 struct 이름(그대로 MSL 타입). 실물 dot_matrix 의 `struct Grid`.
    static func mslType(_ glsl: String, structs: Set<String> = []) -> String? {
        switch glsl {
        case "void", "float", "int", "bool": return glsl
        case "vec2", "float2": return "float2"; case "vec3", "float3": return "float3"; case "vec4", "float4": return "float4"
        case "mat2", "float2x2": return "float2x2"; case "mat3", "float3x3": return "float3x3"; case "mat4", "float4x4": return "float4x4"
        case "sampler2D": return "texture2d<float>"
        default: return structs.contains(glsl) ? glsl : nil
        }
    }

    struct GLSLStruct: Equatable { let name: String; let body: String }  // body = 원문 멤버 선언들(타입 리네임 전)

    /// 파일 스코프 `struct <name> { <members> };` 파싱(주석 제거본 입력 가정). 함수 파싱 전에 이름을 등록해야
    /// struct 반환/파라미터 헬퍼가 mslType 을 통과한다(실물 dot_matrix: `Grid squareGrid(vec2)`).
    static func parseStructs(_ src: String) -> [GLSLStruct] {
        let chars = Array(src)
        var out: [GLSLStruct] = []
        var i = 0, depth = 0
        func skipWS(_ j: inout Int) { while j < chars.count, chars[j].isWhitespace { j += 1 } }
        func readIdent(_ j: inout Int) -> String {
            var s = ""
            while j < chars.count, chars[j].isLetter || chars[j] == "_" || (!s.isEmpty && chars[j].isNumber) { s.append(chars[j]); j += 1 }
            return s
        }
        while i < chars.count {
            let c = chars[i]
            if depth == 0, c == "s", i + 6 <= chars.count, String(chars[i..<i + 6]) == "struct",
               i + 6 < chars.count, !(chars[i + 6].isLetter || chars[i + 6].isNumber || chars[i + 6] == "_") {
                var j = i + 6
                skipWS(&j)
                let name = readIdent(&j)
                skipWS(&j)
                if !name.isEmpty, j < chars.count, chars[j] == "{" {
                    var d = 0, body = ""
                    while j < chars.count {
                        if chars[j] == "{" { d += 1; if d == 1 { j += 1; continue } }
                        if chars[j] == "}" { d -= 1; if d == 0 { j += 1; break } }
                        body.append(chars[j]); j += 1
                    }
                    out.append(GLSLStruct(name: name, body: body))
                    i = j; continue
                }
            }
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            i += 1
        }
        return out
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

    /// 블록 주석(`/* */`)만 제거, `//` 줄 주석은 보존 — 선언 파서는 `//` JSON 어노테이션이 필요하다.
    /// `//` 주석 내부의 `/*` 는 텍스트로 취급(그 줄 통과), 주석 내부 개행은 보존해 줄 구조 불변.
    static func stripBlockComments(_ src: String) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { out.append(chars[i]); i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") {
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                i = min(i + 2, chars.count)
                continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// 파일 스코프 함수 정의 파싱(주석 제거본 입력 가정). `<type> <name>(<params>) { body }`.
    /// 프로토타입(`;`)은 무시. main 포함 전부 반환.
    static func parseFunctions(_ src: String, structs: Set<String> = []) -> [GLSLFunction] {
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
                if mslType(t1, structs: structs) != nil {
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
            // 여러 줄 시그니처(실물 dqss2 calcShadowMask): 개행 포함 공백류 전체로 분리.
            var toks = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
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

    private struct OverloadCandidate {
        let mangledName: String
        let paramSizes: [Int]
    }

    /// Same-stage GLSL helper overloads are legal in WE shaders, but emitted MSL helpers live in a C-style namespace.
    /// Mangle only real overload sets and rewrite calls when argument sizes identify one candidate.
    private static func rewriteSameStageOverloads(_ fns: [GLSLFunction], baseEnv: [String: Int]) -> [GLSLFunction] {
        let grouped = Dictionary(grouping: fns.filter { $0.name != "main" }, by: { $0.name })
        var overloads: [String: [OverloadCandidate]] = [:]
        var renameByNameAndKey: [String: [String: String]] = [:]
        var usedNames = Set(fns.map { $0.name })
        for (name, group) in grouped {
            let paramKeys = Set(group.map { overloadParamKey($0.params) })
            guard paramKeys.count > 1 else { continue }
            var candidates: [OverloadCandidate] = []
            var byKey: [String: String] = [:]
            for fn in group {
                let key = overloadParamKey(fn.params)
                if let existing = byKey[key] {
                    candidates.append(OverloadCandidate(mangledName: existing, paramSizes: overloadParamSizes(fn.params)))
                    continue
                }
                let base = "\(name)_\(overloadSuffix(fn.params))"
                var mangled = base
                var n = 2
                while usedNames.contains(mangled) {
                    mangled = "\(base)_\(n)"
                    n += 1
                }
                usedNames.insert(mangled)
                byKey[key] = mangled
                candidates.append(OverloadCandidate(mangledName: mangled, paramSizes: overloadParamSizes(fn.params)))
            }
            overloads[name] = candidates
            renameByNameAndKey[name] = byKey
        }
        guard !overloads.isEmpty else { return fns }

        var functionReturns: [String: Int] = [:]
        for fn in fns where fn.name != "main" {
            let emittedName = renameByNameAndKey[fn.name]?[overloadParamKey(fn.params)] ?? fn.name
            functionReturns[emittedName] = GLSLTypeAdapter.typeSize(fn.ret) ?? 0
        }

        return fns.map { fn in
            var env = baseEnv
            for p in fn.params { env[p.name] = p.array ? 0 : (GLSLTypeAdapter.typeSize(p.type) ?? 0) }
            for (name, size) in localTypeSizes(in: fn.body) { env[name] = size }
            let body = rewriteOverloadCalls(fn.body, overloads: overloads, env: env, functionReturns: functionReturns)
            let emittedName = renameByNameAndKey[fn.name]?[overloadParamKey(fn.params)] ?? fn.name
            return GLSLFunction(ret: fn.ret, name: emittedName, params: fn.params, body: body)
        }
    }

    private static func overloadParamKey(_ params: [GLSLFunction.Param]) -> String {
        params.map { "\($0.byRef ? "&" : "")\(canonicalOverloadType($0.type))\($0.array ? "[]" : "")" }
            .joined(separator: "|")
    }

    private static func overloadSuffix(_ params: [GLSLFunction.Param]) -> String {
        guard !params.isEmpty else { return "void" }
        return params.map {
            var s = canonicalOverloadType($0.type)
            if $0.byRef { s = "ref_\(s)" }
            if $0.array { s += "_array" }
            return s.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        }.joined(separator: "_")
    }

    private static func canonicalOverloadType(_ type: String) -> String {
        GLSLType.from(type)?.rawValue ?? type
    }

    private static func overloadParamSizes(_ params: [GLSLFunction.Param]) -> [Int] {
        params.map { $0.array ? 0 : (GLSLTypeAdapter.typeSize($0.type) ?? 0) }
    }

    private static func rewriteOverloadCalls(_ body: String, overloads: [String: [OverloadCandidate]],
                                             env: [String: Int], functionReturns: [String: Int]) -> String {
        var out = body
        let names = overloads.keys.sorted { $0.count > $1.count }
        for _ in 0..<4 {
            let beforePass = out
            for name in names {
                guard let candidates = overloads[name] else { continue }
                out = rewriteCall(out, name) { args in
                    let argSizes = args.map { inferExpressionSize($0, vars: env, functionReturns: functionReturns) }
                    let matches = candidates.filter { candidate in
                        guard candidate.paramSizes.count == argSizes.count else { return false }
                        for (want, got) in zip(candidate.paramSizes, argSizes) where want == 0 || got == 0 || want != got {
                            return false
                        }
                        return true
                    }
                    guard matches.count == 1 else { return nil }
                    return "\(matches[0].mangledName)(\(args.joined(separator: ", ")))"
                }
            }
            if out == beforePass { break }
        }
        return out
    }

    private static func localTypeSizes(in body: String) -> [String: Int] {
        let chars = Array(body)
        var out: [String: Int] = [:]
        var i = 0
        func readIdent(_ j: inout Int) -> String {
            var s = ""
            while j < chars.count, chars[j].isLetter || chars[j] == "_" || (!s.isEmpty && chars[j].isNumber) {
                s.append(chars[j])
                j += 1
            }
            return s
        }
        func skipWS(_ j: inout Int) {
            while j < chars.count, chars[j].isWhitespace { j += 1 }
        }
        func skipInitializer(_ j: inout Int) {
            var depth = 0
            while j < chars.count {
                if chars[j] == "(" || chars[j] == "[" || chars[j] == "{" { depth += 1 }
                else if chars[j] == ")" || chars[j] == "]" || chars[j] == "}" { depth = max(0, depth - 1) }
                else if depth == 0, chars[j] == "," || chars[j] == ";" { return }
                j += 1
            }
        }
        while i < chars.count {
            guard chars[i].isLetter || chars[i] == "_" else { i += 1; continue }
            var j = i
            let type = readIdent(&j)
            guard type != "void", let size = GLSLTypeAdapter.typeSize(type) else {
                i = max(j, i + 1)
                continue
            }
            skipWS(&j)
            var foundName = false
            while j < chars.count {
                skipWS(&j)
                guard j < chars.count, chars[j].isLetter || chars[j] == "_" else { break }
                let name = readIdent(&j)
                out[name] = size
                foundName = true
                skipWS(&j)
                if j < chars.count, chars[j] == "[" { out[name] = 0; skipInitializer(&j) }
                if j < chars.count, chars[j] == "=" { j += 1; skipInitializer(&j) }
                skipWS(&j)
                if j < chars.count, chars[j] == "," { j += 1; continue }
                break
            }
            i = foundName ? j : max(j, i + 1)
        }
        return out
    }

    private static func inferExpressionSize(_ expr: String, vars: [String: Int], functionReturns: [String: Int]) -> Int {
        let s = stripOuterParens(expr.trimmingCharacters(in: .whitespaces))
        guard !s.isEmpty else { return 0 }
        if isNumericLiteral(s) || s == "true" || s == "false" { return 1 }
        // 이항 분해를 트레일링 스위즐보다 먼저 — `a+b.x` 를 `(a+b).x` 로 오판하지 않도록
        // (스위즐이 최상위인 `(a+b).x` 는 괄호 깊이 때문에 여기서 분해되지 않고 아래로 떨어진다).
        if let (lhs, rhs) = splitTopLevelBinary(s, ops: ["+", "-"])
            ?? splitTopLevelBinary(s, ops: ["*", "/", "%"]) {
            let l = inferExpressionSize(lhs, vars: vars, functionReturns: functionReturns)
            let r = inferExpressionSize(rhs, vars: vars, functionReturns: functionReturns)
            if l > 1, r > 1, l != r { return min(l, r) }
            if l == 0 || r == 0 { return 0 }
            return max(l, r)
        }
        if let (base, size) = trailingSwizzle(s) {
            let baseSize = inferExpressionSize(base, vars: vars, functionReturns: functionReturns)
            return baseSize > 0 ? size : 0
        }
        if let (name, args) = wholeCall(s) {
            if let n = GLSLTypeAdapter.typeSize(name), n > 0 { return n }
            if name == "texSample2D" || name == "texSample2DLod" { return 4 }
            if ["dot", "distance", "length"].contains(name) { return 1 }
            if let r = functionReturns[name] { return r }
            let argSizes = args.map { inferExpressionSize($0, vars: vars, functionReturns: functionReturns) }.filter { $0 > 0 }
            if ["sin", "cos", "tan", "abs", "floor", "ceil", "fract", "frac", "sqrt", "normalize", "min", "max",
                "mix", "lerp", "clamp", "pow", "mod", "we_mod"].contains(name), !argSizes.isEmpty {
                return argSizes.max() ?? 0
            }
        }
        if let (base, _) = trailingIndex(s) {
            return inferExpressionSize(base, vars: vars, functionReturns: functionReturns) > 1 ? 1 : 0
        }
        return isIdentifier(s) ? (vars[s] ?? 0) : 0
    }

    private static func stripOuterParens(_ s: String) -> String {
        var current = s
        while current.hasPrefix("("), current.hasSuffix(")") {
            let chars = Array(current)
            var depth = 0
            var wraps = true
            for i in chars.indices {
                if chars[i] == "(" { depth += 1 }
                else if chars[i] == ")" {
                    depth -= 1
                    if depth == 0, i != chars.count - 1 { wraps = false; break }
                }
                if depth < 0 { wraps = false; break }
            }
            guard wraps, chars.count >= 2 else { break }
            current = String(chars[1..<(chars.count - 1)]).trimmingCharacters(in: .whitespaces)
        }
        return current
    }

    private static func trailingSwizzle(_ s: String) -> (base: String, size: Int)? {
        let chars = Array(s)
        guard !chars.isEmpty else { return nil }
        var depth = 0
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] == ")" || chars[i] == "]" { depth += 1 }
            else if chars[i] == "(" || chars[i] == "[" { depth = max(0, depth - 1) }
            else if depth == 0, chars[i] == "." {
                let member = String(chars[(i + 1)..<chars.count])
                guard !member.isEmpty, member.allSatisfy({ "xyzwrgbastpq".contains($0) }) else { return nil }
                return (String(chars[..<i]), min(member.count, 4))
            }
            i -= 1
        }
        return nil
    }

    private static func trailingIndex(_ s: String) -> (base: String, index: String)? {
        let chars = Array(s)
        guard chars.last == "]" else { return nil }
        var depth = 0
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] == "]" { depth += 1 }
            else if chars[i] == "[" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[..<i]), String(chars[(i + 1)..<(chars.count - 1)]))
                }
            }
            i -= 1
        }
        return nil
    }

    private static func splitTopLevelBinary(_ s: String, ops: Set<Character>) -> (String, String)? {
        let chars = Array(s)
        guard !chars.isEmpty else { return nil }
        var depth = 0
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if c == ")" || c == "]" { depth += 1 }
            else if c == "(" || c == "[" { depth = max(0, depth - 1) }
            else if depth == 0, ops.contains(c), !isUnaryOperator(chars, at: i) {
                return (String(chars[..<i]), String(chars[(i + 1)..<chars.count]))
            }
            i -= 1
        }
        return nil
    }

    private static func isUnaryOperator(_ chars: [Character], at i: Int) -> Bool {
        // 지수 부호(1e-5)는 앞이 숫자 리터럴일 때만 — 'e' 로 끝나는 식별자(value-1 등) 뒤 부호 오판 방지.
        if chars[i] == "+" || chars[i] == "-", i >= 2, chars[i - 1] == "e" || chars[i - 1] == "E",
           i + 1 < chars.count, chars[i + 1].isNumber {
            var j = i - 2
            var sawDigit = false
            while j >= 0, chars[j].isNumber || chars[j] == "." {
                if chars[j].isNumber { sawDigit = true }
                j -= 1
            }
            if sawDigit, j < 0 || !(chars[j].isLetter || chars[j] == "_") { return true }
        }
        var j = i - 1
        while j >= 0, chars[j].isWhitespace { j -= 1 }
        guard j >= 0 else { return true }
        return "([,{?:+-*/%<>=!".contains(chars[j])
    }

    private static func wholeCall(_ s: String) -> (name: String, args: [String])? {
        let chars = Array(s)
        var i = 0
        guard i < chars.count, chars[i].isLetter || chars[i] == "_" else { return nil }
        var name = ""
        while i < chars.count, chars[i].isLetter || chars[i] == "_" || (!name.isEmpty && chars[i].isNumber) {
            name.append(chars[i])
            i += 1
        }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "(" else { return nil }
        let open = i
        var depth = 0
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            else if chars[i] == ")" {
                depth -= 1
                if depth == 0 {
                    let close = i
                    i += 1
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    guard i == chars.count else { return nil }
                    return (name, splitArguments(String(chars[(open + 1)..<close])))
                }
            }
            i += 1
        }
        return nil
    }

    private static func splitArguments(_ s: String) -> [String] {
        let chars = Array(s)
        var args: [String] = []
        var cur = ""
        var depth = 0
        for c in chars {
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            else if c == ")" || c == "]" || c == "}" { depth = max(0, depth - 1) }
            if c == ",", depth == 0 {
                args.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !args.isEmpty { args.append(tail) }
        return args
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isNumericLiteral(_ s: String) -> Bool {
        var chars = Array(s)
        if chars.first == "+" || chars.first == "-" { chars.removeFirst() }
        guard chars.contains(where: { $0.isNumber }) else { return false }
        var i = 0
        while i < chars.count, chars[i].isNumber { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
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
                    let expandedCount = packedVec4VaryingCount(name: name, declaredCount: n, source: src) ?? n
                    arrays.append(ArrayVarying(type: type, name: name, count: expandedCount))
                    for k in 0..<expandedCount { out.append("varying \(toks[0]) \(name)_\(k);") }
                    continue
                }
            }
            out.append(String(line))
        }
        return (out.joined(separator: "\n"), arrays)
    }

    private static func packedVec4VaryingCount(name: String, declaredCount: Int, source: String) -> Int? {
        guard declaredCount > 4 else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let packedPatterns = [
            #"\#(escaped)\s*\[\s*uint\s*\([^)]*\)\s*/\s*uint\s*\(\s*4\s*\)\s*\]"#,
            #"\#(escaped)\s*\[\s*int\s*\([^)]*\*\s*0\.25[^)]*\)\s*\]"#
        ]
        for pattern in packedPatterns {
            if source.range(of: pattern, options: .regularExpression) != nil {
                return max(1, (declaredCount + 3) / 4)
            }
        }
        return nil
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
            let parts = codePart.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, let type = GLSLType.from(parts[0]) else { continue }
            // 주의: range 와 인덱싱 대상이 같은 문자열이어야 함(Substring `line` 에 직접 적용).
            let ann = line.range(of: "//").map { String(line[$0.upperBound...]) } ?? ""
            let names = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for (idx, rawName) in names.enumerated() {
                var name = rawName
                if let br = name.firstIndex(of: "[") { name = String(name[..<br]) }  // 배열 유니폼(g_AudioSpectrum16Left[16])
                guard !name.isEmpty else { continue }
                out.append(Uniform(type: type, name: name,
                                   annotationMaterial: idx == 0 ? jsonStr(ann, "material") : nil,
                                   annotationDefault: idx == 0 ? jsonFloats(ann, "default") : nil))
            }
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
            // 실물 오타 관용: `varying vec4 v_Size.xy;` — 이름은 식별자까지만.
            let name = String(toks[1].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
            guard !name.isEmpty else { continue }
            if seen.insert(name).inserted {
                out.append((type, name))
            } else if let i = out.firstIndex(where: { $0.1 == name }), type.components > out[i].0.components {
                // 스테이지 간 타입 불일치(vert vec2/frag vec4 등): 큰 쪽이 Vary 멤버 — 양쪽 접근 모두 유효.
                out[i].0 = type
            }
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
    /// 샘플러 주석의 콤보 어노테이션: `uniform sampler2D g_TextureN; // {..."combo":"NAME"...}` → [N: NAME].
    /// WE 규약: 해당 슬롯에 텍스처가 바인딩되면 콤보 자동 활성(페인트 마스크 등).
    public static func samplerCombos(_ src: String) -> [Int: String] {
        var out: [Int: String] = [:]
        // 주의: 실물은 CRLF 이고 Swift 의 "\r\n" 은 단일 grapheme 이라 separator "\n" 에 안 걸린다.
        // 선언은 코드부, 어노테이션은 후행 `//` 주석부에서만 인정 — 주석 처리된(죽은) 샘플러 선언이
        // 콤보를 등록해 의도치 않은 #if 분기를 켜는 것 방지. 블록 주석 속 선언도 제외.
        for line in stripBlockComments(src).split(whereSeparator: { $0.isNewline }) {
            guard let commentStart = line.range(of: "//") else { continue }
            let code = line[..<commentStart.lowerBound]
            let comment = line[commentStart.upperBound...]
            guard code.contains("sampler2D"),
                  let texRange = code.range(of: "g_Texture") else { continue }
            let after = code[texRange.upperBound...]
            let digits = after.prefix(while: { $0.isNumber })
            guard let slot = Int(digits) else { continue }
            guard let comboKey = comment.range(of: "\"combo\"") else { continue }
            let tail = comment[comboKey.upperBound...]
            guard let q1 = tail.firstIndex(of: "\"") else { continue }
            let afterQ1 = tail[tail.index(after: q1)...]
            guard let q2 = afterQ1.firstIndex(of: "\"") else { continue }
            out[slot] = String(afterQ1[..<q2])
        }
        return out
    }

    static func isEngine(_ name: String) -> Bool {
        name == "g_Time" || name == "g_ModelViewProjectionMatrix" || name == "g_PointerPosition"
            || name == "g_TexelSize" || name == "g_TexelSizeHalf"
            || name.hasPrefix("g_AudioSpectrum")
            || (name.hasPrefix("g_Texture") && name.hasSuffix("Resolution"))
            || (name.hasPrefix("g_") && name.contains("Matrix"))  // 레이어/이펙트 행렬 계열(실물 frame_builder);
                                                                   // ...MatrixInverse/...MatrixInverseTranspose 변형 포함(실물 depthparallax)
    }
    static func engineReplacement(_ name: String) -> String {
        if name == "g_Time" { return "eng.timeAndPad.x" }
        if name == "g_PointerPosition" { return "eng.timeAndPad.yz" }  // 마우스 UV(0..1), 미구동 시 0.5,0.5
        if name == "g_ModelViewProjectionMatrix" || name == "g_EffectModelViewProjectionMatrix" { return "eng.mvp" }
        // 레이어 모델/기타 행렬(...Matrix / ...MatrixInverse 등): 효과 쿼드 기준 항등이 정답
        // (레이어 회전·스케일은 v1 미반영 — 무회전 레이어 정확. 항등의 역/역전치도 항등).
        if name.hasPrefix("g_"), name.contains("Matrix") { return "float4x4(1.0)" }
        // WE g_TexelSize = 렌더 타깃 1텍셀(UV). EngineU 에 타깃 dims 가 없어 tex0 해상도로 근사 —
        // 효과 패스는 tex0(framebuffer)=타깃 크기가 통례라 대체로 정확(실물 bokeh 7패스 중 6 정확).
        // 머티리얼로 오인되면 기본값 (0,0) → 0/0=NaN UV → 검정(3544152633 ×0.4 luma 손실 근원).
        // ponytail: 스케일드 fbo 에서 타깃≠tex0 인 패스는 tex0 텍셀로 근사 — 타깃 dims 가 EngineU 에 실리면 교체.
        if name == "g_TexelSize" { return "(1.0 / eng.texRes[0].xy)" }
        if name == "g_TexelSizeHalf" { return "(0.5 / eng.texRes[0].xy)" }
        if name == "g_AudioSpectrum16Left" { return "audioL" }
        if name == "g_AudioSpectrum16Right" { return "audioR" }
        if name == "g_AudioSpectrum32Left" { return "audioL32" }
        if name == "g_AudioSpectrum32Right" { return "audioR32" }
        if name == "g_AudioSpectrum64Left" { return "audioL64" }
        if name == "g_AudioSpectrum64Right" { return "audioR64" }
        if name.hasPrefix("g_Texture"), name.hasSuffix("Resolution"),
           let n = Int(name.dropFirst("g_Texture".count).dropLast("Resolution".count)),
           (0..<8).contains(n) {   // EngineU.texRes 는 [8] 고정 — N≥8 은 미치환(컴파일 실패→폴백)
            return "eng.texRes[\(n)]"
        }
        return name
    }
    private static func defaultKey(_ name: String) -> String {
        name.hasPrefix("g_") ? String(name.dropFirst(2)).lowercased() : name.lowercased()
    }
    private static func padDefault(_ t: GLSLType) -> [Float] { Array(repeating: 0, count: max(1, t.components)) }
    /// WE 엔진 빌트인 레이어 상수(g_Alpha=레이어 알파, g_Color=틴트, g_Brightness=밝기, g_UserAlpha=유저 알파)를
    /// 머티리얼 어노테이션 없이(bare) 선언한 셰이더 — 엔진이 매 프레임 주입하는 값이라 씬 constantshadervalues 에
    /// 키가 없어 padDefault=0 으로 떨어지면 레이어가 투명(alpha=0)/검정(color=0,0,0)이 된다. WE 중립값(항등)으로 폴백:
    /// alpha·brightness·useralpha=1, color=(1,1,1). 어노테이션이 있으면 이 함수는 안 탐(annotationDefault 우선).
    /// 실제 레이어 알파/색은 컴포지터가 별도 적용(base 이미지는 QuadShaders 하드포트) — 라이브 값 주입은
    /// 렌더 파이프라인 밖이라 스코프 아웃(중립값이면 이중적용도 없음).
    private static func engineNeutralDefault(_ name: String, _ t: GLSLType) -> [Float] {
        switch name {
        case "g_Alpha", "g_UserAlpha", "g_Brightness", "g_Color":
            return Array(repeating: 1, count: max(1, t.components))
        default: return padDefault(t)
        }
    }
    private static func swizzle(_ components: Int) -> String {
        switch components {
        case 1: return ".x"
        case 2: return ".xy"
        case 3: return ".xyz"
        default: return ""
        }
    }

    /// 파일 스코프(중괄호 깊이 0) `const <type> <name> = ...;` 줄 수집.
    static func fileScopeConsts(_ src: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var pending: String? = nil  // 여러 줄 const(실물 tone_mapping 의 mat3 리터럴) — ';' 까지 수집
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if var acc = pending {
                acc += " " + t
                if t.contains(";") { out.append(acc); pending = nil } else { pending = acc }
            } else if depth == 0, t.hasPrefix("const ") {
                if t.contains(";") { out.append(t) } else { pending = t }
            }
            for c in line { if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) } }
        }
        return out
    }

    /// `const <type> <name> ...` 에서 <name> 추출(기존 인라인 추출과 동일 규약).
    static func constDeclName(_ line: String) -> String {
        line.dropFirst("const ".count).split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    /// const 초기화 우변(`= …`)에 non-constructor 함수 호출이 있으면 컴파일타임 상수가 아니다 →
    /// 전역 `constant` 로 두면 전역 생성자(llvm.global_ctors)가 필요해 makeLibrary 가 거부한다.
    /// 벡터/행렬/스칼라 생성자 캐스트(float2(…) 등)는 constexpr 이라 제외.
    static func constInitHasRuntimeCall(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "=") else { return false }
        let constructors: Set<String> = ["float", "int", "uint", "bool", "half",
            "vec2", "vec3", "vec4", "float2", "float3", "float4", "half2", "half3", "half4",
            "ivec2", "ivec3", "ivec4", "mat2", "mat3", "mat4",
            "float2x2", "float3x3", "float4x4", "we_cast3x3"]
        let chars = Array(line[line.index(after: eq)...])
        var i = 0
        while i < chars.count {
            if chars[i].isLetter || chars[i] == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[i..<j])
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                if k < chars.count, chars[k] == "(", !constructors.contains(name) { return true }
                i = j
            } else { i += 1 }
        }
        return false
    }

    private static func symbolMap(materials: [MaterialParam]) -> [String: String] {
        var m: [String: String] = [:]
        for (i, p) in materials.enumerated() { m[p.glslName] = "p[\(i)]\(p.type.swizzle)" }
        return m
    }
    private static func typeAndMacroRenames() -> [String: String] {
        ["vec2": "float2", "vec3": "float3", "vec4": "float4", "mat2": "float2x2", "mat3": "float3x3", "mat4": "float4x4",
         "CAST2": "float2", "CAST3": "float3", "CAST4": "float4",
         "frac": "fract", "lerp": "mix", "ddx": "dfdx", "ddy": "dfdy", "inverse": "we_inverse", "mod": "we_mod",
         "M_PI": "3.14159265359", "M_PI_HALF": "1.57079632679",
         "M_PI_2": "6.28318530718"]  // WE 관용: M_PI_2 = 2π(실물 common.h 대조; π/2 는 M_PI_HALF 담당)
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
        // 2c) radians()/degrees() 는 MSL 미내장(실물 color_grading 의 radians(u_hueShift)) — 상수 곱으로 치환(π/180, 180/π).
        s = rewriteCall(s, "radians") { args in args.count == 1 ? "((\(args[0])) * 0.017453292519943295)" : nil }
        s = rewriteCall(s, "degrees") { args in args.count == 1 ? "((\(args[0])) * 57.29577951308232)" : nil }
        // 3) 식별자/타입 단일 패스 치환
        s = replaceIdentifiers(s, symbols)
        s = rewriteDiscardStatements(s)
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

    static func rewriteDiscardStatements(_ src: String) -> String {
        let chars = Array(src)
        var out = ""
        var i = 0
        while i < chars.count {
            if isWordStart(chars, i), i + "discard".count <= chars.count,
               String(chars[i..<i + "discard".count]) == "discard" {
                var j = i + "discard".count
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && chars[j] == ";" {
                    out += "discard_fragment();"
                    i = j + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// `return ;` / `return;`(값 없는 return)을 대체 문장으로 치환(fragment main 용).
    static func rewriteBareReturns(_ src: String, with replacement: String) -> String {
        let chars = Array(src); var out = ""; var i = 0
        while i < chars.count {
            if chars[i] == "r", isWordStart(chars, i),
               i + 6 <= chars.count, String(chars[i..<min(i + 6, chars.count)]) == "return" {
                var j = i + 6
                while j < chars.count, chars[j].isWhitespace { j += 1 }
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
                var refs = refsOf[h.name] ?? []
                for g in helpers where g.name != h.name && refs.contains(g.name) {
                    let before = refs.count
                    refs.formUnion((refsOf[g.name] ?? []).subtracting(helperNames))
                    if refs.count != before { changed = true }
                }
                refsOf[h.name] = refs
            }
        }
        var out: [String: [Capture]] = [:]
        for h in helpers {
            let refs = refsOf[h.name] ?? []
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
            let t = n.contains("Matrix") ? "float4x4"
                : (n.hasSuffix("Resolution") ? "float4"
                    : (n == "g_PointerPosition" || n == "g_TexelSize" || n == "g_TexelSizeHalf" ? "float2" : "float"))
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
    static func helperSignature(_ h: GLSLFunction, captures: [Capture] = [], materials: [MaterialParam] = [],
                                structs: Set<String> = []) -> String? {
        guard let ret = mslType(h.ret, structs: structs) else { return nil }
        var ps: [String] = []
        for p in h.params {
            guard let t = mslType(p.type, structs: structs) else { return nil }
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
                                 vertBody: String, fragBody: String, structs: String = "") -> String {
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
        // CAST3X3(x): GLSL mat3(x) 대응. mat4→상단 3x3 절단(MSL 엔 float3x3(float4x4) 생성자 부재),
        // mat3→통과(실물 depthparallax 의 g_EffectTextureProjectionMatrixInverse 회전 추출).
        inline float3x3 we_cast3x3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
        inline float3x3 we_cast3x3(float3x3 m) { return m; }
        inline float3x3 we_cast3x3(float s) { return float3x3(s); }  // mat3(scalar)=대각(GLSL 단일 스칼라)
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
            Vary out = {};
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
        let structBlock = structs.isEmpty ? "" : structs + "\n"
        let constBlock = consts.isEmpty ? "" : consts.joined(separator: "\n") + "\n"
        let protoBlock = helperProtos.isEmpty ? "" : helperProtos.joined(separator: "\n") + "\n"
        let defBlock = helperDefs.isEmpty ? "" : helperDefs.joined(separator: "\n\n") + "\n"
        return "#include <metal_stdlib>\nusing namespace metal;\n\(structBlock)\(eng)\(vin)\(vary)\(uvHelpers)\(constBlock)\(protoBlock)\(defBlock)\n\(vertSig)\n\n\(fragSig)\n"
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    /// GLSL 배열 생성자 `TYPE[N](e0, e1, ...)` → MSL brace-init `{ e0, e1, ... }`.
    /// MSL 은 `float2[22](...)` 형식을 지원하지 않는다(실물 bokeh 의 커널 상수 배열). 선언 LHS(`x[22] =`)는
    /// `]` 뒤가 `(` 가 아니라 미검출; 배열 인덱싱(`arr[i]`)도 `](` 인접이 아니라 안전. 중첩도 재귀 처리.
    static func rewriteArrayConstructors(_ src: String) -> String {
        let chars = Array(src)
        var out: [Character] = []
        var i = 0
        let n = chars.count
        func isIdent(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
        while i < n {
            let c = chars[i]
            if (c.isLetter || c == "_"), out.isEmpty || !isIdent(out.last!) {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                var k = j
                while k < n && chars[k] == " " { k += 1 }
                if k < n && chars[k] == "[" {
                    var depth = 1, m = k + 1
                    while m < n && depth > 0 { if chars[m] == "[" { depth += 1 } else if chars[m] == "]" { depth -= 1 }; m += 1 }
                    var q = m
                    while q < n && chars[q] == " " { q += 1 }
                    if depth == 0 && q < n && chars[q] == "(" {
                        var pdepth = 1, r = q + 1
                        while r < n && pdepth > 0 { if chars[r] == "(" { pdepth += 1 } else if chars[r] == ")" { pdepth -= 1 }; r += 1 }
                        let inner = String(chars[(q + 1)..<(r - 1)])
                        out.append(contentsOf: "{ ")
                        out.append(contentsOf: rewriteArrayConstructors(inner))
                        out.append(contentsOf: " }")
                        i = r
                        continue
                    }
                }
                out.append(contentsOf: chars[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: - 저수준 문자열 도구

    /// `name(args)` 를 balanced-paren 으로 찾아 transform(args) 로 치환. transform nil → 원형 유지.
    static func rewriteCall(_ src: String, _ name: String, _ transform: ([String]) -> String?) -> String {
        let chars = Array(src)
        var out = ""
        var i = 0
        while i < chars.count {
            if isWordStart(chars, i), i + name.count <= chars.count,
               String(chars[i..<i + name.count]) == name {
                var open = i + name.count
                while open < chars.count && chars[open].isWhitespace { open += 1 }
                guard open < chars.count, chars[open] == "(" else {
                    out.append(chars[i]); i += 1; continue
                }
                // 인자 추출(balanced)
                var depth = 0; var j = open; var args: [String] = []; var cur = ""
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
                var id = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { id.append(chars[i]); i += 1 }
                // 스위즐 문맥(직전 '.', xyzwrgbastpq 조합 ≤4)은 멤버 접근이라 리네임 제외 —
                // 예약어 맵의 "p" 가 stpq 스위즐 `.p` 를 `.we_p` 로 변형(MSL 컴파일 실패)하는 것 방지.
                if out.last == ".", id.count <= 4, !id.isEmpty, id.allSatisfy({ "xyzwrgbastpq".contains($0) }) {
                    out += id
                } else {
                    out += map[id] ?? id   // 사전에 없으면 그대로(내장 함수·미지 식별자)
                }
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// 본문의 지역 선언 이름( `<type> NAME =|;|,` ) — varying/머티리얼 섀도잉 감지용(Stage-3 ①).
    static func localDeclNames(in body: String, structs: Set<String> = []) -> Set<String> {
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
                if mslType(t1, structs: structs) != nil, t1 != "void" {
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
            if chars[i] == n[0], isWordStart(chars, i), Array(chars[i..<i+n.count]) == n {
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

    /// i 가 단어 시작 위치인지(직전 문자가 식별자 문자가 아님). 단어 본문 일치는 호출부가 확인.
    private static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
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
        for ch in after {
            if ch == "," || ch == "}" { break }
            // 지수 표기 허용(`1e-3`) — e/E 는 숫자 뒤에서만, `+` 는 e/E 뒤에서만(isNegativeNumericLiteral 과 동일 규칙).
            if ch.isNumber || ch == "." || ch == "-"
                || ((ch == "e" || ch == "E") && (num.last?.isNumber ?? false))
                || (ch == "+" && (num.last == "e" || num.last == "E")) { num.append(ch) }
            else if !ch.isWhitespace && !num.isEmpty { break }
        }
        return Float(num).map { [$0] }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
