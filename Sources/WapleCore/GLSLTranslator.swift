import Foundation

public enum GLSLType: String, Equatable, Sendable {
    case float, vec2, vec3, vec4, mat2, mat3, mat4, mat4x3, sampler2D
    /// 비교(섀도우) 샘플러 — `sampler2DComparison`(shader-strings.txt :25)은 HLSL 백엔드에서
    /// `Texture2D` + `SamplerComparisonState` 쌍으로 선언된다(같은 파일 :32 `SamplerComparisonState:register(s`,
    /// :34 `SamplerComparisonState `). MSL 대응은 `depth2d<float>` + `sampler_compare`.
    /// 동봉 실물 선언 9건 — `shaders/generic4.frag:24`, `chroma4.frag:23`, `fur4.frag:23`,
    /// `foliage4.frag:25`, `genericimage4.frag:9`, `genericparticle.frag:46`,
    /// `genericropeparticle.frag:40`, `volumetricsfront.frag:11` 여덟과
    /// `effects/fluidsimulation/shaders/effects/fluidsimulation_combine.frag` 하나
    /// (전건 `"default":"_rt_shadowAtlas"` 어노테이션).
    case sampler2DComparison
    /// 3D 볼륨 텍스처 — `sampler3D`(shader-strings.txt :24, 짝 선언 :29 `Texture3D `). 동봉 실물 1건:
    /// `shaders/ccsimple.frag:9`(컬러그레이딩 LUT). MSL 대응은 `texture3d<float>`.
    case sampler3D

    /// GLSL(vec2)·HLSL(float2) 타입명 겸용 해석 — WE 방언은 혼용한다(실물 rand_1_05(in float2 uv)).
    public static func from(_ s: String) -> GLSLType? {
        if let t = GLSLType(rawValue: s) { return t }
        switch s {
        case "float2": return .vec2; case "float3": return .vec3; case "float4": return .vec4
        case "float2x2": return .mat2; case "float3x3": return .mat3; case "float4x4": return .mat4
        case "float4x3": return .mat4x3
        // WE shim(wallpaper64.exe 임베디드, shader-strings.txt :44): #define uvec4 uint4 — ivec/2/3성분
        // 포함 정수 벡터는 크기 추론용으로 vecN 등가 취급(MSL 스펠링 치환은 typeAndMacroRenames/mslType).
        case "uvec2", "ivec2": return .vec2; case "uvec3", "ivec3": return .vec3
        case "uvec4", "ivec4": return .vec4
        case "sampler2DBackBuffer": return .sampler2D   // WE shim :22 — texture2d<float> 취급
        default: return nil
        }
    }
    var components: Int { switch self { case .float: return 1; case .vec2: return 2; case .vec3: return 3; case .vec4: return 4; default: return 0 } }
    var msl: String {
        switch self {
        case .float: return "float"; case .vec2: return "float2"; case .vec3: return "float3"
        case .vec4: return "float4"; case .mat2: return "float2x2"; case .mat3: return "float3x3"; case .mat4: return "float4x4"
        case .mat4x3: return "float4x3"   // WE shim :46 #define mat4x3 float4x3(MSL float4x3 존재)
        case .sampler2D: return "texture2d<float>"
        case .sampler2DComparison: return "depth2d<float>"
        case .sampler3D: return "texture3d<float>"
        }
    }
    /// 텍스처 슬롯(`g_TextureN`)으로 등록돼야 하는 샘플러 타입인가 — 머티리얼 파라미터 분류의 여집합.
    /// 종전엔 `== .sampler2D` 한 곳뿐이라 `sampler2DComparison`/`sampler3D` 선언이 파스에서 통째로
    /// 탈락했고(GLSLType.from 이 nil), 본문 스캔 폴백이 같은 슬롯을 **texture2d 로** 등록해
    /// `depth2d`/`texture3d` 로 선언돼야 할 슬롯이 조용히 2D 로 굳었다.
    var isTextureSampler: Bool {
        switch self { case .sampler2D, .sampler2DComparison, .sampler3D: return true; default: return false }
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
    /// F-X4: 샘플러 주석의 `"default":"경로"`(문자열) — 씬/머티리얼이 슬롯을 지정하지 않을 때의 텍스처
    /// 폴백(WE 관례: util/noise, _rt_FullFrameBuffer 등). 슬롯 → 경로 문자열.
    public let textureDefaults: [Int: String]
    /// [2026-08-21] 방출된 `VIn` 이 실제로 싣고 있는 정점 attribute 이름들(슬롯 오름차순).
    /// **정점 디스크립터와의 계약**이다 — 소비처는 이 목록에 있는 것만 꽂아야 한다.
    /// 슬롯 번호는 `GLSLTranslator.vertexAttributeWhitelist` 가 정한다.
    /// 항상 `a_Position`(0)·`a_TexCoord`(1) 로 시작하고, 그 뒤는 셰이더가 **실제로 참조할 때만**
    /// 붙는다(현재 `a_Normal`(2) 하나). 근거·도달은 `docs/re/shader-uniforms.md` §7.6/§7.7.
    public let vertexAttributes: [String]
}

/// WE GLSL(방언) → MSL 소스-투-소스 변환기. 실패 시 nil(→ 손-포팅 폴백).
public enum GLSLTranslator {
    // MARK: - 정점 attribute 화이트리스트 (docs/re/shader-uniforms.md §7.6)

    /// `VIn` 에 실을 수 있는 attribute 와 그 `[[attribute(n)]]` 슬롯.
    ///
    /// **슬롯 번호는 정점 디스크립터와의 계약이다.** 소비처
    /// (`SceneRenderer3D.buildCustomMeshShader` · `SceneRendererResources.translatedPipeline` /
    /// `translatedLayerPipeline`)가 같은 번호로 버퍼 오프셋을 꽂는다. 번호를 바꾸면 그 세 자리를
    /// 같이 바꿔야 한다.
    ///
    /// **왜 화이트리스트인가.** `parseAttributes` 는 선언된 이름을 **전부** `vin.<이름>` 으로
    /// 매핑하므로, `VIn` 에 없는 attribute 를 선언한 셰이더는 없는 멤버를 읽어 MSL 컴파일이
    /// **확정 실패**한다(→ 스톡 폴백). 설치본 실측 도달:
    /// `a_Normal` 17파일(저작레인 8) · `a_Color` 9(1) · `a_Tangent4` 8(1) ·
    /// `a_BlendIndices`/`a_BlendWeights` 10/9(0) — `docs/re/shader-uniforms.md` §7.6 의 표.
    ///
    /// **`a_Normal` 만 넣은 이유**는 그것만 정점 버퍼에 **실제로 있기** 때문이다. 메시 정점은
    /// `pos3+normal3+uv2`(8f, stride 32)라 법선이 오프셋 12 에 이미 있다. `a_Color`/`a_Tangent4`/
    /// 스키닝 attribute 는 버퍼에 없으므로 `VIn` 에만 실으면 **컴파일 실패가 파이프라인 생성
    /// 실패로 바뀔 뿐**이다(둘 다 폴백이지만 진단이 나빠진다). 그 셋은 버퍼 레이아웃 확장이
    /// 선행돼야 하는 별건이다.
    public static let vertexAttributeWhitelist: [(name: String, type: GLSLType, slot: Int)] = [
        ("a_Position", .vec3, 0),
        ("a_TexCoord", .vec2, 1),
        ("a_Normal", .vec3, 2),
    ]

    /// 슬롯 0·1 은 **무조건** 싣는다 — 이 리포의 세 정점 디스크립터가 전부 그 둘을 선언하고,
    /// 어느 쪽도 참조하지 않는 셰이더에서 `VIn` 이 비면 `[[stage_in]]` 자체가 불법이 된다.
    /// 조건부는 슬롯 2 이상이다.
    static let alwaysLoadedVertexAttributes = ["a_Position", "a_TexCoord"]

    /// 방출된 vertex 본문이 `vin.<name>` 을 **낱말 단위로** 참조하는가.
    /// 단순 `contains` 를 쓰면 안 된다 — `a_TexCoord` 는 실물 `a_TexCoordVec4`/`a_TexCoordC2` 의
    /// 접두라(동봉 자산 실측: `a_TexCoordVec4` 6 · `a_TexCoordVec4C1` 4 · `a_TexCoordC2` 1 …)
    /// 화이트리스트가 넓어지는 날 조용히 틀린다.
    static func referencesVertexAttribute(_ name: String, in vertBody: String) -> Bool {
        let needle = "vin.\(name)"
        var idx = vertBody.startIndex
        while let r = vertBody.range(of: needle, range: idx..<vertBody.endIndex) {
            if r.upperBound == vertBody.endIndex { return true }
            let c = vertBody[r.upperBound]
            if !(c.isLetter || c.isNumber || c == "_") { return true }
            idx = r.upperBound
        }
        return false
    }

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
        let premultiply: Bool
    }
    // nonisolated(unsafe): 직렬화 주체는 바로 아래 memoLock 이다(모든 읽기·쓰기가 lock/unlock 구간
    // 안에 있다 — _memoizedTranslate·_resetTranslationMemoForTesting 이 전부). 컴파일러가 그 사실을
    // 볼 수 없을 뿐이라 표기로 알린다. 락을 지우려면 이 표기도 같이 지워야 한다.
    nonisolated(unsafe) private static var memoCache: [MemoKey: TranslatedShader?] = [:]
    private static let memoLock = NSLock()   // DeepScan.concurrentPerform 가 translate 를 동시 호출 → 필수.
    // 상한 불요: 유니크 키는 사용자 라이브러리의 유한 셰이더 수(수백~저수천)로 바운드,
    // 엔트리당 인라인소스+MSL 수십 KB → 수십 MB 천장. 필요 시 count 상한+FIFO 로 승격.

    /// 테스트 전용: 프로세스 전역 캐시라 테스트 간 격리·미스(실번역) 카운트 관측을 위해 제공(@testable).
    /// nonisolated(unsafe): 증가·리셋 모두 memoLock 구간 안이다(위 memoCache 주석과 같은 근거).
    nonisolated(unsafe) public private(set) static var memoComputeCount = 0
    static func _resetTranslationMemoForTesting() {
        memoLock.lock(); defer { memoLock.unlock() }
        memoCache.removeAll(); memoComputeCount = 0
    }

    /// G3 — **콤보 키는 무조건 대문자화한다.** 실물은 패스 `combos` 딕셔너리를 읽을 때 키를
    /// 한 글자씩 `toupper` 로 돌려 새 버퍼에 담는다(0x14015458c-0x1401545aa, `toupper`=0x1402bfb48:
    /// `lea eax,[rcx-0x61]; cmp eax,0x19; add ecx,-0x20` = `'a'..'z'` 만 −0x20). 선언(`[COMBO]`)이
    /// 있든 없든 무관하다 — 그래서 `"normalmap":1` 저작이 셰이더의 `#ifdef NORMALMAP` 에 닿는다.
    ///
    /// 왜 여기인가: 실물의 대문자화 자리는 JSON 파스 시점이고 Waple 의 대응 자리
    /// (`WapleRender/SceneRendererResources.resolvePassCombos`)는 이 파일 밖이다. 주입 결과가
    /// 관측 대상이므로 **주입 직전**인 번역기 진입에서 접으면 같은 계약이 성립하고, 메모 키도
    /// 함께 정규화되어 `normalmap`/`NORMALMAP` 두 철자가 캐시를 가르지 않는다.
    /// (`resolvePassCombos` 의 `canonical()` 은 선언 이름 집합 안에서만 접던 근사인데, 저작된
    /// 소문자 15종 중 14종이 어떤 셰이더에도 선언이 없어 대부분 놓치고 있었다.
    /// **[2026-08-21] 그 함수는 제거됐다** — 동봉+설치본 JSON 3655건 전수로 셰이더 `[COMBO]`
    /// 선언 68종이 전건 대문자이고 `canonical()` 의 두 모집단에 대문자 아닌 키가 0건임을 보인 뒤,
    /// 코퍼스 전수 비트동일을 확인하고 지웠다(근거는 그 함수 자리의 주석). 다만 렌더 계층에는
    /// 반환 딕셔너리를 **정확일치로 조회**하는 자리가 둘 남아 있어, 이 함수를 `public` 으로 노출해
    /// 렌더 계층이 **딕셔너리별로** 접게 하는 것이 정본이다 — 실물이 접는 자리(JSON 파스 시점
    /// `toupper` 0x14015458c-0x1401545aa)와 같은 위치다.)
    ///
    /// 충돌 규약: 접었을 때 이미 대문자 철자가 있으면 **대문자 쪽이 이긴다.** 근거는 실물의
    /// `#define` 방출 순서다 — 값 있는 패스 콤보(0x14016c400-0x14016c7fe)를 먼저 쏟고 그 다음
    /// 텍스처 유래 콤보(0x14016c800-0x14016c984, 값 항상 1)를 쏟으므로 뒤에 오는 쪽이 이긴다.
    /// Waple 에서 텍스처 유래 키는 셰이더 어노테이션 철자(= 전건 대문자)로 들어온다.
    /// 실측: 동봉 자산의 `[COMBO]` 67종·샘플러 `combo` 9종·`components` 5종 **전부 대문자**라
    /// 동봉 코퍼스에서 이 접기로 바뀌는 번역 결과는 0건이다(변화는 씬 저작 키에서만 난다).
    public static func translate(vertex: String, fragment: String, combos: [String: Int],
                                 include: (String) -> String? = { _ in nil },
                                 premultiplyOutput: Bool = false) -> TranslatedShader? {
        let combos = uppercasedComboKeys(combos)
        guard WapleProfiler.enabled else {
            return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include,
                                      premultiplyOutput: premultiplyOutput)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { WapleProfiler.recordTranslate(seconds: CFAbsoluteTimeGetCurrent() - t0) }
        return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include,
                                  premultiplyOutput: premultiplyOutput)
    }

    /// 실물 0x140154598 의 `toupper` 접기. 이미 전건 대문자면 원본을 그대로 돌려준다(할당 회피).
    /// `uppercased()` 는 로케일 무관 유니코드 대문자화라 ASCII 밖 문자도 건드리는데, 실물은
    /// `'a'..'z'` 만 −0x20 한다. 콤보 이름은 JSON 키이고 동봉/설치본 전건 ASCII 라 실측 차이는
    /// 없지만, 차이가 나는 입력(워크샵의 비-ASCII 콤보 키)에서는 우리가 더 공격적이다 — 그 경우
    /// 실물도 셰이더의 `#if` 이름과 못 맞추므로 어느 쪽이든 미정의(0)로 같은 결말이다.
    public static func uppercasedComboKeys(_ combos: [String: Int]) -> [String: Int] {
        guard combos.keys.contains(where: { $0 != $0.uppercased() }) else { return combos }
        var out: [String: Int] = [:]
        out.reserveCapacity(combos.count)
        // 대문자 철자를 먼저 심고, 접힌 소문자는 빈 자리에만 채운다(위 충돌 규약).
        for (k, v) in combos where k == k.uppercased() { out[k] = v }
        for (k, v) in combos where k != k.uppercased() {
            let up = k.uppercased()
            if out[up] == nil { out[up] = v }
        }
        return out
    }

    /// 메모이즈 진입: 키(인라인 소스+combos) 조회 → 히트 반환, 미스 시 실번역 후 저장. 실패(nil)도 캐시
    /// (결정적 — 동일 입력 재실패 반복 회피). 실번역은 락 밖(동시 미스 = 동일 순수출력 재계산일 뿐 무해).
    private static func _memoizedTranslate(vertex: String, fragment: String, combos: [String: Int],
                                           include: (String) -> String?, premultiplyOutput: Bool) -> TranslatedShader? {
        let key = MemoKey(vRaw: vertex, fRaw: fragment,
                          vInlined: ShaderPreprocessor.inlinedSource(vertex, include: include),
                          fInlined: ShaderPreprocessor.inlinedSource(fragment, include: include),
                          combos: combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                          premultiply: premultiplyOutput)
        memoLock.lock()
        if let cached = memoCache[key] { memoLock.unlock(); return cached }
        memoLock.unlock()
        let result = _translate(vertex: vertex, fragment: fragment, combos: combos, include: include,
                                premultiplyOutput: premultiplyOutput)
        memoLock.lock()
        memoCache[key] = result
        memoComputeCount += 1
        memoLock.unlock()
        return result
    }

    /// MSL 예약어/C++ 대체 토큰/방출 파라미터명과 충돌하는 GLSL 식별자의 안전 리네임 사전.
    /// 전 엔트리 순수 리터럴 — 런타임 불변(매 호출 사전 재구성 배제).
    /// 실물: test_shader(`vec2 fragment`), dot_matrix(`vec2 or`), geodraw(`float2 p`).
    private static let mslReservedRenames: [String: String] = [
        "fragment": "we_fragment", "vertex": "we_vertex", "kernel": "we_kernel",
        "device": "we_device", "thread": "we_thread", "threadgroup": "we_threadgroup",
        "constant": "we_constant", "using": "we_using", "namespace": "we_namespace",
        "half": "we_half",
        // C++ 대체 토큰(MSL 예약어)이 GLSL 식별자로 쓰이는 실물(dot_matrix 의 지역 `vec2 or`).
        "or": "we_or", "and": "we_and", "not": "we_not", "xor": "we_xor",
        "compl": "we_compl", "bitand": "we_bitand", "bitor": "we_bitor",
        // 우리 방출 파라미터명과의 충돌(실물 geodraw: 지역 float2 p)
        "p": "we_p", "eng": "we_eng", "smp": "we_smp", "vin": "we_vin",
    ]

    /// 정적 엔진 심볼의 벡터 크기(overloadSizeEnv/sizeEnv 공용 초기값).
    /// F618: g_PointerState = float4.
    /// F771: 미등재 시 식 전체를 0(불투명)으로 오염 → 필요한 절단 누락.
    private static let engineSymbolSizes: [String: Int] = [
        "gl_FragColor": 4, "gl_FragCoord": 4, "gl_Position": 4,
        "g_Time": 1, "g_PointerPosition": 2, "g_ParallaxPosition": 2,
        "g_Frametime": 1, "g_PointerPositionLast": 2,
        "g_PointerState": 4,
        "a_TexCoord": 2, "a_Position": 3,
        // 반구 앰비언트 짝 — WEAssets 선언 전건 vec3(vec4 선언 0건).
        "g_LightAmbientColor": 3, "g_LightSkylightColor": 3,
    ]

    private static func _translate(vertex: String, fragment: String, combos: [String: Int],
                                   include: (String) -> String?, premultiplyOutput: Bool) -> TranslatedShader? {
        // [COMBO] 기본값은 스테이지 합집합 — vert 에만 선언된 콤보(실물 auto_sway 의 AA_VERSION)를
        // frag 도 봐야 한다(WE 는 효과 단위로 콤보를 병합).
        var combos = combos
        for src in [vertex, fragment] {
            for (k, v) in ShaderPreprocessor.parseComboDefaults(src) where combos[k] == nil { combos[k] = v }
        }
        // `formatcombo` 슬롯의 `TEXnFORMAT` 도 **선언에서 오는 기본값**이다(위 `[COMBO]` 와 같은 성격) —
        // 호출부가 값을 안 주면 0(= `FORMAT_RGBA8888`, `shaders/common_fragment.h:2`)으로 심는다.
        //
        // 왜 필요한가(실측): `shaders/fur4.frag:152` 는 이 매크로를 **값으로** 쓴다 —
        //   `float furMask = ConvertTextureFormat(TEX8FORMAT, texSample2D(g_Texture8, …)).a;`
        // `#if` 안이 아니므로 미정의면 전처리가 지워 주지 않고 식별자가 그대로 MSL 로 새어
        // `conv(TEX8FORMAT, …)` 가 된다(방출 MSL 실측: 동봉·설치본 양쪽 `shaders/fur4` 의 세 구성
        // 전건 = 6건). 방언 토큰이 아니라 그냥 미정의 식별자라 종전 토큰 린트로는 안 잡혔고,
        // Metal 컴파일 실패로만 드러났다. 이 시딩 뒤 그 6건이 0건이 된다.
        //
        // 실물 대조: WE 는 슬롯 0..9 를 돌며 이름을 `"TEX"`(0x14048ee70) + itoa(slot) + `"FORMAT"`
        // (0x14048ee98) 로 조립해 매크로맵에 넣는다(루프 0x1401a6870-0x1401a6a52, 이름 조립
        // 0x1401a697e-0x1401a699f, 값 저장 `mov dword ptr [rax], edi` @0x1401a69e4 — `edi` 는
        // `dword ptr [rdi+0x18]` = 그 슬롯 텍스처의 포맷 코드). 어노테이션 플래그가 없거나
        // (0x1401a695d `cmp byte ptr [rbx+0x80], 0`) 텍스처를 못 구하면(0x1401a694d) 건너뛴다.
        // 즉 실물도 "선언에 formatcombo 가 있고 텍스처가 있으면 **항상** 정의" 이고, 값 0 도 그대로
        // 정의한다(0 스킵 분기 없음 — 값 방출은 0x14016c5c5 의 무조건 itoa).
        //
        // 무회귀 근거: `#if` 평가에서 미정의는 이미 0 이므로(evalChecked 의 미지 식별자 = 0) 이 시딩으로
        // 바뀌는 것은 **본문 텍스트 치환뿐**이다. 호출부(`SceneRendererResources.resolvePassCombos`)가
        // 실제 포맷 코드를 주면 그 값이 이긴다(`combos[k] == nil` 가드).
        for slot in formatComboSlots(vertex).union(formatComboSlots(fragment)) {
            let key = "TEX\(slot)FORMAT"
            if combos[key] == nil { combos[key] = 0 }
        }
        // 블록 주석은 여기서 제거(`//` 어노테이션은 보존) — `/* uniform ... */` 속 죽은 선언이
        // 줄 단위 선언 파서에 실선언으로 잡히면 usesAudio 오점화(불필요 TCC 프롬프트)/유령 슬롯이 생긴다.
        let (vsrc, vArrays, vMats) = expandArrayVaryings(stripPrecision(stripBlockComments(ShaderPreprocessor.preprocess(vertex, combos: combos, include: include))))
        let (fsrc, fArrays, fMats) = expandArrayVaryings(stripPrecision(stripBlockComments(ShaderPreprocessor.preprocess(fragment, combos: combos, include: include))))

        // 유니폼/attribute/varying 수집(주석 어노테이션 보존 위해 본문 정리 전에).
        let vUniforms = parseUniforms(vsrc), fUniforms = parseUniforms(fsrc)
        let vVaryings = parseVaryings(vsrc)
        let varyings = parseVaryings(vsrc + "\n" + fsrc)   // 합집합
        // `uniqueKeysWithValues` 가 여기서는 안전하다 — `parseVaryings`(:1128-1146)가 `seen` Set 으로
        // **이미 중복 이름을 제거**한다(같은 이름이 다시 오면 타입만 큰 쪽으로 갱신). 셰이더 소스가
        // 신뢰 경계 밖이라 의심스러워 보이지만 실제로는 도달 불가다. 2026-08-19 스윕에서 확인.
        let vVaryingTypes = Dictionary(uniqueKeysWithValues: vVaryings.map { ($0.name, $0.type) })
        let allUniforms = mergeUniforms(vUniforms + fUniforms)
        // BK/G7: **엔진 행렬 유니폼의 선언 타입은 mat4 가 아닐 수 있다.** 아래 참조.
        let engineTypes = engineDeclaredTypes(allUniforms)

        var textures: [Int] = []
        var textureDefaults: [Int: String] = [:]
        // 슬롯별 MSL 텍스처 선언 종류. 미등재 슬롯(본문 스캔으로만 발견)은 texture2d<float> 기본.
        // depth2d/texture3d 는 sample 호출 형태가 다르므로 선언만 바꿔도 안 되고
        // texSample2DCompare/texSample3D 재작성과 **짝**이다(둘 중 하나만 있으면 컴파일 실패).
        var textureKinds: [Int: GLSLType] = [:]
        var materials: [MaterialParam] = []
        var usesAudio = false
        for u in allUniforms {
            if u.type.isTextureSampler, let n = textureIndex(u.name) {
                textures.append(n)
                if u.type != .sampler2D { textureKinds[n] = u.type }
                if let def = u.annotationDefaultTexture, !def.isEmpty { textureDefaults[n] = def }
            }
            else if isEngine(u.name) { if u.name.contains("AudioSpectrum") { usesAudio = true } }
            else if !u.type.isTextureSampler {
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
        let reservedRenames = mslReservedRenames
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
            // Texel 가드: textureIndex("g_Texture6Texel")=6 — 엔진 유니폼 토큰이 팬텀 텍스처 슬롯으로 등록되는 것 방지.
            // F617: 숫자부가 전부 숫자인 g_TextureN 만 인정 — g_Texture3MipMapInfo·g_Texture0Rotation 류는
            // textureIndex 가 접두 숫자만 읽어 팬텀 슬롯(3/0)이 생겼다(본문 스캔 잔여 경로).
            if id.hasPrefix("g_Texture"), !id.hasSuffix("Resolution"), !id.hasSuffix("Texel"),
               id.dropFirst("g_Texture".count).allSatisfy({ $0.isNumber }), let n = textureIndex(id) { textures.append(n) }
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
            let rep = engineReplacement(u.name, engineTypes: engineTypes)
            frag[u.name] = rep; vert[u.name] = rep
        }
        // 본문 출현 기반 엔진 심볼(선언 부재 시에도 매핑).
        for id in bodyIds where isEngine(id) {
            let rep = engineReplacement(id, engineTypes: engineTypes)
            if frag[id] == nil { frag[id] = rep }
            if vert[id] == nil { vert[id] = rep }
        }
        // 표준 attribute 는 VIn 에 상시 존재 — 선언 없이도 vertex 에서 매핑.
        if vert["a_Position"] == nil { vert["a_Position"] = "vin.a_Position" }
        if vert["a_TexCoord"] == nil { vert["a_TexCoord"] = "vin.a_TexCoord" }
        frag["gl_FragCoord"] = "in.gl_Position"  // [[position]] = 픽셀 좌표
        // WE PS_INPUT 의 gl_Position 도 픽셀 좌표(RE: gl_Position 심 — vertex 측 out.gl_Position(:1399)
        // 과는 별개 매핑). frag 본문의 gl_Position 참조를 in.gl_Position 로.
        frag["gl_Position"] = "in.gl_Position"
        // WE 방언의 정수 빌트인(HLSL SV_ 시맨틱 대응). 원문 선언은 `in uint gl_VertexID;`(실물
        // `shaders/generic4.vert:44`, `generic3.vert:43`, `shadowcaster.vert:24`) / `varying uint
        // gl_ViewportIndex;`(`shadowcaster.vert:11`, `shadowcasterfoliage4.vert:13`,
        // `shadowcasterfur4.vert:11`) 인데, `in ...` 줄은 uniform/varying/attribute 어느 파서에도
        // 안 잡히고 `varying uint` 은 GLSLType.from("uint")==nil 로 탈락한다 — 즉 **선언은 사라지고
        // 본문 참조만 남아** MSL 미정의 식별자가 됐다(동봉 실물 전수: VertexID 8 · InstanceID 4 ·
        // ViewportIndex 3 셰이더).
        // gl_VertexID/gl_InstanceID 는 MSL 에서 이름 그대로의 함수 파라미터가 되므로 치환이 없고
        // (assemble 이 [[vertex_id]]/[[instance_id]] 를 붙인다), gl_ViewportIndex 만 Vary 멤버라
        // out. 접두가 필요하다.
        vert["gl_ViewportIndex"] = "out.gl_ViewportIndex"

        // 함수 파싱은 주석 제거본에서(annotation JSON 중괄호가 balance 를 깨지 않도록).
        var vFns = parseFunctions(vClean, structs: structNames)
        var fFns = parseFunctions(fClean, structs: structNames)
        var overloadSizeEnv: [String: Int] = engineSymbolSizes
        for vy in varyings { overloadSizeEnv[vy.name] = vy.type.components }
        for m in materials { overloadSizeEnv[m.glslName] = m.type.components }
        for id in bodyIds where isEngine(id) && (id.hasSuffix("Resolution") || id.hasSuffix("Texel")) { overloadSizeEnv[id] = 4 }
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
        let mustDemote = computeConstDemoteSet(constOrder: constOrder, constByName: constByName,
                                                materialNames: materialNames0)

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
        var sizeEnv: [String: Int] = engineSymbolSizes
        for vy in varyings { sizeEnv[vy.name] = vy.type.components }
        for m in materials { sizeEnv[m.glslName] = m.type.components }
        for id in bodyIds where isEngine(id) && (id.hasSuffix("Resolution") || id.hasSuffix("Texel")) { sizeEnv[id] = 4 }
        var fnSizes: [String: Int] = [:]
        var fnParamSizes: [String: [Int]] = [:]
        for h in helpers {
            fnSizes[h.name] = GLSLTypeAdapter.typeSize(h.ret) ?? 0
            fnParamSizes[h.name] = h.params.map { $0.array ? 0 : (GLSLTypeAdapter.typeSize($0.type) ?? 0) }
        }
        // F612 재발 차단: 어댑터가 `.a`/`.st`/`.xy` 같은 **struct 필드 이름**을 스위즐로 오독하지
        // 않도록 소스 struct 의 멤버 이름을 넘긴다(GLSLTypeAdapter.assignment/postfix 주석 참조).
        let structFieldSet = structMemberNames(structDefs)
        var vertSizeEnv = sizeEnv
        for (name, type) in vVaryingTypes where type.components > 0 { vertSizeEnv[name] = type.components }
        let fragSizeEnv = sizeEnv  // varying 크기는 union(Vary 멤버 실타입) — frag 소형 선언은 어댑터가 coerce
        let fragMainBody = GLSLTypeAdapter.adapt(body: fragMainBodyPre,
                                                 env: .init(vars: fragSizeEnv, functions: fnSizes, functionParams: fnParamSizes,
                                                            structFields: structFieldSet))
        let vertMainBody = GLSLTypeAdapter.adapt(body: vertMainF.body,
                                                 env: .init(vars: vertSizeEnv, functions: fnSizes, functionParams: fnParamSizes,
                                                            structFields: structFieldSet))

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
        // perTextureSampler: true 는 최상위 frag 본문 한정(F162/F163) — vert/헬퍼/file-scope const 호출부는
        // 모두 기본값(false)이라 무변경(vert 는 애초 smp 미선언 — 텍스처 샘플 시 기존과 동일하게 컴파일 실패).
        guard let fragBodyT = translateBody(fragMainBody, symbols: fragMap, isFragment: true, perTextureSampler: true),
              let vertBodyT = translateBody(vertMainBody, symbols: vertMap, isFragment: false) else { return nil }
        var fragBody = fragVaryingPrelude + fragBodyT
        var vertBody = vertBodyT

        // 헬퍼 캡처 분석: 본문이 참조하는 컨텍스트 심볼(머티리얼/엔진/varying/attribute/텍스처/오디오/샘플러)을
        // 추가 파라미터로 승격. 호출 그래프 전이 폐쇄(A→B 호출 시 A ⊇ B).
        let captureOf = computeCaptures(helpers: helpers, materials: materials, varyings: varyings,
                                        textures: textures, textureKinds: textureKinds)

        // 헬퍼 방출: 프로토타입 전량 선행(정의 순서 무관 호출 가능) + 정의.
        // 헬퍼 내부의 다른 헬퍼 호출엔 캡처 인자를 원 이름으로 전달(자신의 파라미터로 존재).
        var helperProtos: [String] = []
        var helperDefs: [String] = []
        for h in helpers {
            let caps = captureOf[h.name] ?? []
            guard let sig = helperSignature(h, captures: caps, materials: materials, structs: structNames,
                                            textureKinds: textureKinds,
                                            engineTypes: engineTypes) else { continue }  // 미지원 타입 → 스킵
            var helperEnv = sizeEnv
            for prm in h.params { helperEnv[prm.name] = prm.array ? 0 : (GLSLTypeAdapter.typeSize(prm.type) ?? 0) }
            // int/uint 파라미터명은 어댑터에 int 로 알려 min/max(int,float) 모호성 해소(실물 multistage_wave).
            let intParams = Set(h.params.filter { $0.type == "int" || $0.type == "uint" }.map { $0.name })
            let adaptedBody = GLSLTypeAdapter.adapt(body: h.body,
                                                    env: .init(vars: helperEnv, functions: fnSizes, functionParams: fnParamSizes,
                                                               intVars: intParams, structFields: structFieldSet),
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
            if case .varying(let n, _, _) = cap, promotedVaryings.contains(n) { return n }
            return captureCallArg(cap, isFragment: true, materials: materials, engineTypes: engineTypes)
        }
        vertBody = appendCaptureArgs(vertBody, helpers: helpers, captureOf: captureOf) { cap in
            captureCallArg(cap, isFragment: false, materials: materials, engineTypes: engineTypes)
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
        // 행렬 varying 로컬(같은 규약): frag 는 열 벡터 멤버로 재구성, vert 는 선언 후 말미에 열별로 out 에 복사.
        // MSL `floatNxM(colVec0, …, colVecN-1)` 은 열 벡터 생성자로 합법이고 열-우선이다
        // (스펙 2.3.2: "construct a matrix of type T with n columns and m rows from n vectors of type T
        //  with m components" · "Metal constructs and consumes matrix components in column-major order").
        // GLSL 도 `m[i]` 가 열이라 `out.<n>_i = <n>[i]` ↔ `<T>(in.<n>_0, …)` 왕복이 성분 보존이다.
        for m in fMats {
            let cols = (0..<m.count).map { "in.\(m.name)_\($0)" }.joined(separator: ", ")
            fragBody = "\(m.type.msl) \(m.name) = \(m.type.msl)(\(cols));\n" + fragBody
        }
        for m in vMats {
            vertBody = "\(m.type.msl) \(m.name);\n" + vertBody
            vertBody += "\n" + (0..<m.count).map { "out.\(m.name)_\($0) = \(m.name)[\($0)];" }.joined(separator: "\n")
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
        // vertex 스테이지 빌트인 사용 여부 — 쓰지 않는 셰이더의 시그니처는 종전 그대로 두기 위해
        // (무회귀) 참조가 있을 때만 파라미터/Vary 멤버를 붙인다.
        let vertexBuiltins = VertexBuiltins(vertexID: vertIds.contains("gl_VertexID"),
                                            instanceID: vertIds.contains("gl_InstanceID"),
                                            viewportIndex: vertBody.contains("out.gl_ViewportIndex"))
        // 정점 attribute: 슬롯 0·1 은 항상, 그 위는 **최종 본문이 실제로 참조할 때만**.
        // `vertexBuiltins` 와 같은 규율이다 — 안 쓰는 셰이더의 방출물을 종전 그대로 두려면
        // 참조 여부를 **번역이 끝난 본문**에서 봐야 한다(선언만 보고 실으면 `#if` 로 잘려 나간
        // 참조까지 세어 2D 쿼드 파이프라인을 깬다).
        let vertexAttributes = alwaysLoadedVertexAttributes + vertexAttributeWhitelist
            .filter { !alwaysLoadedVertexAttributes.contains($0.name) }
            .sorted { $0.slot < $1.slot }
            .filter { referencesVertexAttribute($0.name, in: vertBody) }
            .map { $0.name }
        // 소스 struct 정의: 멤버 타입 리네임(vec2→float2 등) 후 프리앰블 선두에 방출(헬퍼 시그니처가 참조).
        let structBlock = structDefs.map { "struct \($0.name) {" + replaceIdentifiers($0.body, typeAndMacroRenames()) + "};" }
            .joined(separator: "\n")
        let msl = assemble(varyings: varyings, textures: textures, textureKinds: textureKinds,
                           vertexBuiltins: vertexBuiltins, vertexAttributes: vertexAttributes,
                           materialCount: materials.count,
                           vertAudioNames: audioBufferNames.filter { vertIds.contains($0.name) },
                           fragAudioNames: audioBufferNames.filter { fragIds.contains($0.name) },
                           consts: consts, helperProtos: helperProtos, helperDefs: helperDefs,
                           vertBody: vertBody, fragBody: fragBody, structs: structBlock,
                           premultiplyOutput: premultiplyOutput)
        return TranslatedShader(msl: msl, materialParams: materials, textureSlots: textures, usesAudio: usesAudio,
                                textureDefaults: textureDefaults, vertexAttributes: vertexAttributes)
    }

    /// 파일 스코프 const 중 전역 MSL `constant` 가 될 수 없는 이름 집합(전이 폐쇄 포함).
    /// ① 엔진/머티리얼 심볼 참조, ② 비-constexpr 초기화, ③ ①②에 해당하는 다른 const 참조.
    private static func computeConstDemoteSet(constOrder: [String], constByName: [String: String],
                                              materialNames: Set<String>) -> Set<String> {
        var mustDemote = Set<String>()
        for n in constOrder {
            let line = constByName[n]!
            if identifiers(in: line).contains(where: { isEngine($0) || materialNames.contains($0) })
                || constInitHasRuntimeCall(line) { mustDemote.insert(n) }
        }
        // ③ 전이 폐쇄 — 이미 강등 대상인 const 를 참조하는 다른 const 도 강등.
        var changed = true
        while changed {
            changed = false
            for n in constOrder where !mustDemote.contains(n) {
                if identifiers(in: constByName[n]!).contains(where: { $0 != n && mustDemote.contains($0) }) {
                    mustDemote.insert(n); changed = true
                }
            }
        }
        return mustDemote
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
    /// uint 는 MSL 네이티브 — 없으면 uint 반환 헬퍼는 parseFunctions 의 반환타입 인식(:555)이,
    /// uint 파라미터 헬퍼는 helperSignature nil(→ :349 스킵)이 실패해 호출부만 남는다.
    static func mslType(_ glsl: String, structs: Set<String> = []) -> String? {
        switch glsl {
        case "void", "float", "int", "uint", "bool": return glsl
        case "vec2", "float2": return "float2"; case "vec3", "float3": return "float3"; case "vec4", "float4": return "float4"
        case "mat2", "float2x2": return "float2x2"; case "mat3", "float3x3": return "float3x3"; case "mat4", "float4x4": return "float4x4"
        case "mat4x3", "float4x3": return "float4x3"      // WE shim :46 #define mat4x3 float4x3
        // WE shim :44 #define uvec4 uint4(ivec/2/3성분 〃) — 헬퍼 시그니처의 정수 벡터 타입.
        case "uvec2": return "uint2"; case "uvec3": return "uint3"; case "uvec4": return "uint4"
        case "ivec2": return "int2"; case "ivec3": return "int3"; case "ivec4": return "int4"
        case "sampler2D", "sampler2DBackBuffer": return "texture2d<float>"   // BackBuffer: WE shim :22
        // 비교 샘플러/3D 샘플러 헬퍼 파라미터(실물 common_pbr_2.h 의 DECLARE_SAMPLER2D_COMPARE_PARAMETER(shim :61)
        // 전개형). depth2d 라야 sample_compare 가, texture3d 라야 3성분 sample 이 유효하다.
        case "sampler2DComparison": return "depth2d<float>"
        case "sampler3D": return "texture3d<float>"
        default: return structs.contains(glsl) ? glsl : nil
        }
    }

    struct GLSLStruct: Equatable { let name: String; let body: String }  // body = 원문 멤버 선언들(타입 리네임 전)

    /// struct 본문(원문 멤버 선언들)에서 멤버 이름 집합 추출 — `;` 로 끊고 선언마다 첫 식별자(타입)를 버린다.
    /// 배열 멤버(`float k[4]`)는 첨자를 버리고 이름만, 콤마 다중 선언(`vec3 st, xy`)은 전부 담는다.
    /// 용도는 하나: 어댑터가 스위즐 글자 이름 필드를 스위즐로 오독하지 않게 하는 것(F612 재발 차단).
    static func structMemberNames(_ defs: [GLSLStruct]) -> Set<String> {
        var out = Set<String>()
        for d in defs {
            for decl in d.body.split(separator: ";") {
                var ids: [String] = []
                let chars = Array(decl)
                var i = 0
                while i < chars.count {
                    if chars[i].isLetter || chars[i] == "_" {
                        var t = ""
                        while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                            t.append(chars[i]); i += 1
                        }
                        ids.append(t)
                    } else {
                        i += 1
                    }
                }
                guard ids.count >= 2 else { continue }   // ids[0] = 타입
                out.formUnion(ids.dropFirst())
            }
        }
        return out
    }

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
                    // 2단계 매칭. 크기 0 은 "다른 크기"가 아니라 **미지**다 — mat2/mat3/mat4/mat4x3/
                    // sampler2D 는 `GLSLTypeAdapter.typeSize` 가 0 을 내고 배열 파라미터도 0 이다.
                    // 종전처럼 `want == 0 || got == 0` 을 즉시 실격 처리하면 **불투명 파라미터를 가진
                    // 오버로드는 영원히 매칭되지 않는다**. 그런데 오버로드된 이름은 이미 전부 맹글링돼
                    // 방출되므로(위 `renameByNameAndKey`), 매칭 실패 = 호출부가 존재하지 않는 원래
                    // 이름을 부르는 것 = **정의되지 않은 심볼 → MSL 컴파일 실패 → 셰이더 통째 드롭**.
                    // 실물: WEAssets `shaders/common_vertex.h` 가 `BuildTangentSpace` 를 3중 오버로드로
                    // 정의하는데(:1 `(vec3,vec4)`, :8 `(mat3,vec3,vec4)`, :17 `(mat3,vec3,vec4,out vec3,
                    // out vec3)`) 호출부 9곳이 **전부 mat3 를 첫 인자로 넘긴다**(generic{,2,3,4}.vert ·
                    // genericimage{2,3,4}.vert · base/model_vertex_v1.h ×2).
                    // 1단계는 아는 크기끼리만 대조하고 미지는 실격시키지 않는다. 2단계(엄격)는 종전
                    // 규칙 그대로이며, 1단계가 모호할 때만 쓴다. 어느 단계든 생존자가 정확히 1일 때만
                    // 재작성하므로 모호한 경우의 동작(재작성 안 함)은 종전과 같다.
                    func resolve(strict: Bool) -> OverloadCandidate? {
                        let matches = candidates.filter { candidate in
                            guard candidate.paramSizes.count == argSizes.count else { return false }
                            for (want, got) in zip(candidate.paramSizes, argSizes) {
                                if strict {
                                    if want == 0 || got == 0 || want != got { return false }
                                } else if want != 0, got != 0, want != got {
                                    return false
                                }
                            }
                            return true
                        }
                        return matches.count == 1 ? matches[0] : nil
                    }
                    guard let hit = resolve(strict: false) ?? resolve(strict: true) else { return nil }
                    return "\(hit.mangledName)(\(args.joined(separator: ", ")))"
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
            if name == "texSample2D" || name == "texSample2DLod"
                || name == "texSample3D" || name == "texSample2DCompare" { return 4 }
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

    /// 행렬 varying(`varying mat3 v_XForm;`) — 배열과 **같은 이유로** 펼쳐야 한다.
    /// `column` 은 열 벡터 타입, `count` 는 열 개수(MSL `floatNxM` = N 열 × M 행,
    /// `m[i]` 가 i 번째 **열**: MSL 스펙 2.3 "A matrix of type floatnxm consists of n floatm vectors").
    struct MatrixVarying: Equatable { let type: GLSLType; let name: String; let column: GLSLType; let count: Int }

    /// GLSL 행렬 타입 → (열 벡터 타입, 열 개수). 행렬이 아니면 nil.
    static func matrixVaryingShape(_ t: GLSLType) -> (column: GLSLType, count: Int)? {
        switch t {
        case .mat2:   return (.vec2, 2)
        case .mat3:   return (.vec3, 3)
        case .mat4:   return (.vec4, 4)
        case .mat4x3: return (.vec3, 4)   // GLSL mat4x3 = 4열 × 3행 = MSL float4x3
        default:      return nil
        }
    }

    /// 배열 varying(`varying vec2 v_TexCoord[13];` — 실물 blur/localcontrast 계열)과
    /// 행렬 varying(`varying mat3 v_XForm;` — 실물 cursorripple preview) 처리:
    ///
    /// **MSL 은 stage-in/정점 반환 구조체에 배열도 행렬도 허용하지 않는다.** 스펙 인용(2026-06-04 판):
    /// - 5.2.4: "You cannot use the `stage_in` attribute to declare members of the structure that are
    ///   packed vectors, **matrices**, structures, bitfields, references or pointers to a type, or
    ///   **arrays** of scalars, vectors, or matrices."
    /// - 함수 제약 절: "The return type of a vertex or fragment function cannot include an element that is
    ///   a packed vector type, **matrix type**, a structure type, a reference, or a pointer to a type."
    /// `Vary` 는 정점 반환 타입이자 프래그먼트 `[[stage_in]]` 이므로 **양쪽 금지에 다 걸린다.**
    ///
    /// 그래서 선언을 스칼라/열-벡터 멤버(`v_TexCoord_0..` / `v_XForm_0..`)로 펼친다.
    /// 본문 접근은 재작성하지 않는다 — main 에 로컬 배열/행렬을 놓고(vert: 말미 out 복사,
    /// frag: 진입 시 구성) 리터럴/변수 인덱스와 `mul(v, m)` 이 자연 동작한다.
    ///
    /// **한계(배열과 동일)**: 로컬은 main 스코프라 **헬퍼 함수 안의 참조는 못 본다** — 그 경우
    /// 미정의 식별자가 남아 MSL 컴파일이 실패하고 폴백한다(조용한 오답이 아니라 폴터).
    /// 동봉 코퍼스에서 행렬 varying 을 헬퍼가 읽는 사례는 0건이다(2026-08-21 실측).
    static func expandArrayVaryings(_ src: String)
        -> (source: String, arrays: [ArrayVarying], matrices: [MatrixVarying]) {
        var out: [String] = []
        var arrays: [ArrayVarying] = []
        var matrices: [MatrixVarying] = []
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
            } else if t.hasPrefix("varying ") {
                let toks = t.dropFirst("varying ".count).split(separator: ";").first?
                    .split(separator: " ").map(String.init) ?? []
                if toks.count >= 2, let type = GLSLType.from(toks[0]),
                   let shape = matrixVaryingShape(type) {
                    // `parseVaryings` 와 같은 이름 절단 규약(실물 오타 `v_Size.xy` 관용).
                    let name = String(toks[1].prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                    if !name.isEmpty {
                        matrices.append(MatrixVarying(type: type, name: name,
                                                      column: shape.column, count: shape.count))
                        // 펼친 선언은 **GLSL 철자**로 낸다 — 이후 parseVaryings 가 다시 읽는다.
                        for k in 0..<shape.count { out.append("varying \(shape.column.rawValue) \(name)_\(k);") }
                        continue
                    }
                }
            }
            out.append(String(line))
        }
        return (out.joined(separator: "\n"), arrays, matrices)
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

    struct Uniform { let type: GLSLType; let name: String; let annotationMaterial: String?; let annotationDefault: [Float]?
                     let annotationDefaultTexture: String? }

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
                // F-X4: sampler2D 의 "default" 는 텍스처 경로 문자열(예: "util/noise", "_rt_FullFrameBuffer")
                // — jsonFloats 는 이를 숫자 파싱 실패로 빈 배열을 내므로 별도 jsonStr 로 포착.
                out.append(Uniform(type: type, name: name,
                                   annotationMaterial: idx == 0 ? jsonStr(ann, "material") : nil,
                                   annotationDefault: idx == 0 ? jsonFloats(ann, "default") : nil,
                                   annotationDefaultTexture: idx == 0 && type.isTextureSampler ? jsonStr(ann, "default") : nil))
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

    /// F162/F163: texSample2D 텍스처 식(예: "g_Texture1")의 슬롯을 eng.texWrap 인덱스로 매핑해
    /// smp(clamp)/smpRepeat 런타임 삼항 분기 식을 만든다(감사 V07: 바깥에 eng.texFilter 삼항을 한 겹 더 씌운 2×2).
    /// eng.texWrap[N]·texFilter[N] 는 buildPassBindings 가 빌드 시
    /// 1 회 계산(bind 출처=clamp 고정, aux 출처=TexImage.clampUVs, WE 기본=repeat) — 번역 캐시는 GLSL
    /// 소스 기반(프로세스 전역, 재마운트·크로스씬 공유)이라 실제 바인딩 자산을 텍스트에 구울 수 없어
    /// 반드시 런타임 분기. 슬롯 미상(헬퍼 로컬 별칭 등 — capture 매커니즘은 원명 유지라 실전 거의 없음)이거나
    /// texRes 와 동일한 8 슬롯 상한 밖이면 폴백 smp(기존 clamp 동작, 무회귀).
    private static func perTextureSamplerExpr(_ texExpr: String) -> String {
        guard let n = textureIndex(texExpr), (0..<8).contains(n) else { return "smp" }
        // 감사 V07: 바깥=eng.texFilter(1=nearest/0=linear — TexImage.noInterpolation, WE tex Flags bit0),
        // 안쪽=eng.texWrap — 2×2 런타임 분기(필터만 point, 어드레스 모드는 wrap 차원이 그대로 결정 — WE 의미론).
        let wrap = "eng.texWrap[\(n / 4)][\(n % 4)] > 0.5"
        let filter = "eng.texFilter[\(n / 4)][\(n % 4)] > 0.5"
        return "(\(filter) ? (\(wrap) ? smpNearest : smpRepeatNearest) : (\(wrap) ? smp : smpRepeat))"
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

    /// 샘플러 주석의 **포맷 콤보** 표시: `uniform sampler2D g_TextureN; // {..."formatcombo":true...}` → {N}.
    ///
    /// `samplerCombos` 의 `"combo"` 와 **다른 어노테이션**이다. 같은 줄에 둘 다 있을 수도, 한쪽만
    /// 있을 수도 있다 — 실측(동봉 WEAssets = WE 설치본 assets, 17파일 전수):
    ///
    ///     formatcombo 슬롯 {1:12, 2:5, 4:5, 8:1} · 그중 `"combo"` 겸비는 슬롯 1 의 11건뿐
    ///
    /// 남는 6건(슬롯 1 의 1건 + 슬롯 2·4·8 전부)은 `formatcombo` **단독**이라 `samplerCombos` 로는
    /// 절대 안 잡힌다. 하필 그 1건이 `effects/refraction/shaders/effects/refract.frag:8` 이다 —
    /// 이 함수 없이 `samplerCombos` 로 `TEXnFORMAT` 을 심으면 정작 고치려던 자리에서 안 걸린다.
    public static func formatComboSlots(_ src: String) -> Set<Int> {
        var out: Set<Int> = []
        // 판정 규약은 samplerCombos 와 동일 — 선언은 코드부, 어노테이션은 후행 `//` 주석부에서만
        // 인정하고 블록 주석 속 선언은 제외한다(주석 처리된 죽은 샘플러가 콤보를 켜는 것 방지).
        for line in stripBlockComments(src).split(whereSeparator: { $0.isNewline }) {
            guard let commentStart = line.range(of: "//") else { continue }
            let code = line[..<commentStart.lowerBound]
            let comment = line[commentStart.upperBound...]
            guard code.contains("sampler2D"),
                  let texRange = code.range(of: "g_Texture"),
                  comment.contains("\"formatcombo\"") else { continue }
            let digits = code[texRange.upperBound...].prefix(while: { $0.isNumber })
            if let slot = Int(digits) { out.insert(slot) }
        }
        return out
    }

    static func isEngine(_ name: String) -> Bool {
        name == "g_Time" || name == "g_ModelViewProjectionMatrix" || name == "g_PointerPosition"
            || name == "g_TexelSize" || name == "g_TexelSizeHalf"
            || name == "g_ParallaxPosition"
            || name == "g_Frametime" || name == "g_PointerPositionLast"  // ★짝 — last 단독 배선 시 유령 링플
            || name == "g_PointerState"  // 클릭 상태(.z=버튼 힘) — cursorripple/fluidsim, 미클릭 0
            // 주의: bare g_* 전면 엔진 승격 금지 — g_RenderVar0..4 는 폴리모픽(파일마다 의미 상이),
            // g_Lights*/g_L{Point,Spot,...}_* 배열형은 parseUniforms [N] 스트립과 충돌. 표적 등재만.
            || name.hasPrefix("g_AudioSpectrum")
            || (name.hasPrefix("g_Texture") && name.hasSuffix("Resolution"))
            || (name.hasPrefix("g_Texture") && name.hasSuffix("Texel"))  // g_TextureNTexel — g_TexelSize 동족(텍스처별 텍셀)
            // F614: g_Screen = (렌더타깃 w, h, w/h) — 미분류 시 머티리얼 팬텀 슬롯(padDefault 0) 강등.
            || name == "g_Screen"
            // F744: 2D genericimage4/fluidsim 이 bare g_LightAmbientColor 선언 시 padDefault=0 폭백.
            // 엔진 상수로 승격해 흰색(1,1,1,1)을 주입; 실제 scene ambientColor 연동은 후속 범위.
            || name == "g_LightAmbientColor"
            // 짝 유니폼 — generic{,2,3,4}.vert / genericimage{2,3,4}.frag / genericparticle.frag 가
            // `mix(g_LightSkylightColor, g_LightAmbientColor, dot(n,+Y)*0.5+0.5)` 로 함께 소비한다.
            || name == "g_LightSkylightColor"
            || (name.hasPrefix("g_") && name.contains("Matrix"))  // 레이어/이펙트 행렬 계열(실물 frame_builder);
                                                                   // ...MatrixInverse/...MatrixInverseTranspose 변형 포함(실물 depthparallax)
            // F4-polish②: Forward+ 라이팅 유니폼(generic3.frag/genericimage3.frag PerformLighting_Deprecated
            // 실측 — g_LPoint_Color/Origin, g_LSpot_Color/Origin/Direction, g_LTube_Color/OriginA/OriginB,
            // g_LDirectional_Color/Direction, g_LFeature_Shadow{Projection,ProjectionTransform,
            // PointProjection,PointProjectionTransform}) — **인식만(재분류 차단), 실값 주입 없음**.
            // 네이티브 3D 라이팅은 Scene3DLighting.swift 가 전담(Cook–Torrance PBR, 최대 4 lpoint +
            // point-shadow atlas)하고 커스텀 GLSL→MSL 번역 경로는 이 라이트 피드에 도달하지 않는다
            // (buildCustomMeshShader 는 라이트 유니폼 버퍼를 바인딩하지 않음). 미등재 시 g_TexelSize
            // 사고와 동형 클래스로 머티리얼 파라미터(sceneKey 소문자화)에 잘못 편입돼 팬텀 슬롯이 된다.
            // **잔여 한계(의도적 미해결)**: WE 선언은 배열(`vec4 g_LPoint_Color[LIGHTS_POINT]`)이고
            // 사용부는 `g_LPoint_Color[l].rgb` 인덱스 접근이다 — 아래 engineReplacement 가 돌려주는
            // 스칼라 float4(0)/항등 리터럴은 `[l]`과 결합하면(예: `float4(0.0)[l]`은 스칼라 컴포넌트
            // 접근이 되어 뒤따르는 `.rgb`가 MSL 컴파일 실패) 인덱스 배열 접근에는 컴파일 안전하지 않다
            // — 이 등재는 순수 "머티리얼 오분류 차단"용이며 실제 인덱스 피드 배선은 스코프 밖(로컬
            // 코퍼스 460씬 LIGHTS_POINT/SPOT/TUBE/DIRECTIONAL 콤보 참조 0건이라 ShaderPreprocessor
            // 의 `#if LIGHTS_*` 게이트가 이 블록 자체를 항상 전처리 단계에서 제거함 —
            // ShaderPreprocessor.swift:38-40 참조, 오늘 시점 커스텀 경로 도달 0건 확정). 콤보가 없어도
            // 이 이름을 그대로 무가드 선언하는 셰이더가 나타나면(에디터가 막지 않음) 여전히 위 subscript
            // 갭이 남는다 — 실물 관측 시 인덱스 가능한 constant 배열 피드로 교체할 것.
            || name.hasPrefix("g_LPoint_") || name.hasPrefix("g_LSpot_") || name.hasPrefix("g_LTube_")
            || name.hasPrefix("g_LDirectional_") || name.hasPrefix("g_LFeature_Shadow")
    }
    /// BK/G7 — **엔진 행렬 유니폼 중 `mat4` 가 아닌 것의 선언 타입 표.**
    ///
    /// `isEngine` 은 이름만 본다(`name.contains("Matrix")`). 그래서 `engineReplacement` 도 종전에는
    /// 이름만 보고 **무조건 `float4x4(1.0)`** 을 돌려줬다. 그런데 WE 자산에는 같은 이름 계열을
    /// `mat3` 로 선언하는 셰이더가 있다 — 설치본(`assets/` + `projects/`) 전수 실측:
    ///
    /// | 이름 | 선언 | 선언 파일 |
    /// |---|---|---|
    /// | `g_NormalModelMatrix` | `mat3` | `shaders/generic4.vert` · `genericimage2/3/4.vert` · `shaders/base/model_vertex_v1.h` (5) |
    /// | `g_AltNormalModelMatrix` | `mat3` | `shaders/genericimage2/3/4.vert` (3) |
    /// | `g_ModelMatrix` | `mat3` | `projects/defaultprojects/{audiophile,fantasticcar}/shaders/grid.vert` (2) |
    ///
    /// 이 셋이 **설치본 전체에서 선언 타입 ≠ 치환 타입인 유일한 자리**다(엔진 유니폼 56 이름의
    /// 선언 타입을 전수 대조 — 나머지는 전건 일치). `mat3` 자리에 `float4x4(1.0)` 을 넣으면
    /// `mul(localNormal, g_NormalModelMatrix)` → `(float4x4(1.0) * float3)` 이 되어 **MSL 컴파일이
    /// 확정 실패**한다(리눅스 스윕은 이걸 못 잡는다 — 방출 토큰만 보고 컴파일은 안 한다).
    /// 본문 소비 도달: 직접 4쌍(`generic4` · `genericimage2/3/4`) + `base/model_vertex_v1.h` 를
    /// 인클루드하는 5쌍(`chroma4` · `foliage4` · `fur4` · `shadowcasterfoliage4` · `shadowcasterfur4`)
    /// = **동봉/설치본 502 셰이더 중 9쌍**. `grid.vert` 2건은 선언만 하고 본문에서 안 써서
    /// 종전에도 컴파일은 안 깨졌다(치환 대상 자체가 없다).
    ///
    /// **`mat4` 는 일부러 표에 안 넣는다** — 표에 없으면 종전대로 `float4x4` 라 방출물이 바이트 동일하다.
    static func engineDeclaredTypes(_ uniforms: [Uniform]) -> [String: GLSLType] {
        var out: [String: GLSLType] = [:]
        for u in uniforms where isEngine(u.name) {
            // `mat2`/`mat3` 만 — 둘 다 MSL 정방행렬이라 `floatNxN(1.0)` 대각 생성자가 확실하다.
            // `mat4x3` 은 비정방이라 `float4x3(1.0)` 의 MSL 유효성을 이 컨테이너에서 확인할 수 없고,
            // 어차피 그 타입으로 선언되는 엔진 유니폼(`g_Bones`·`g_MorphBoneTransform`)은 이름에
            // "Matrix" 가 없어 `isEngine` 을 통과하지 못한다 — 도달 0 이라 넓히지 않는다.
            switch u.type {
            case .mat2, .mat3: out[u.name] = u.type
            default: break
            }
        }
        return out
    }

    /// 엔진 행렬의 항등 리터럴. 선언 타입이 없거나 `mat4` 면 종전과 같은 `float4x4(1.0)`.
    private static func matrixIdentity(_ name: String, _ engineTypes: [String: GLSLType]) -> String {
        "\(engineTypes[name]?.msl ?? GLSLType.mat4.msl)(1.0)"
    }

    static func engineReplacement(_ name: String, engineTypes: [String: GLSLType] = [:]) -> String {
        if name == "g_Time" { return "eng.timeAndPad.x" }
        // 마우스 UV(0..1). **미구동 시 (0,0)** — renderState ctor `0x14017c6d0` 이 `xor eax,eax`
        // (`0x14017c73d`) 후 qword 0 을 심는다(`0x14017c77d`/`0x14017c784`). 종전 이 주석은 0.5,0.5
        // 라고 적었는데 틀렸다. 값은 `SceneRenderer` 가 공급하므로 이 줄의 동작은 무영향이다.
        if name == "g_PointerPosition" { return "eng.timeAndPad.yz" }
        // 실물 depthparallax: 엔진이 매프레임 채우는 시차 위치 — 포인터 UV alias(중앙 0.5,0.5 = 시차 정지).
        // 머티리얼-0 고정이면 코너 고정 시차 왜곡.
        if name == "g_ParallaxPosition" { return "eng.timeAndPad.yz" }
        // 실물 fluidsim/cursorripple: dt(초) + 이전 프레임 포인터 UV — 머티리얼-0 고정이면
        // 시간적분 동결/이전 포인터 부재. 짝 배선(위 isEngine 주석).
        if name == "g_Frametime" { return "eng.timeAndPad.w" }
        if name == "g_PointerPositionLast" { return "eng.pointerLastAndPad.xy" }
        // 실물 cursorripple/fluidsim: g_PointerState.z = 클릭 버튼 힘(미클릭 0). .z 만 참조되므로 pad 슬롯 재사용.
        if name == "g_PointerState" { return "float4(0.0, 0.0, eng.pointerLastAndPad.z, 0.0)" }
        // F614: g_Screen = (width, height, width/height) — tex0(texRes[0]) 근사 유지(이펙트 패스는
        // tex0=framebuffer=타깃 크기가 통례). X-⑤ 스코프 밖: g_TexelSize 와 달리 dst 전용 필드로
        // 옮기지 않았다(감사 근거 없음 — g_Screen 은 별건). 교차배치 참고: 다른 배치가 g_Screen.z=
        // aspect(w/h) 로 반사 오프셋을 스케일하는 소비처를 추가했을 수 있음 — 이 규약은 아직 한 곳에
        // 고정 문서화되지 않았으니 g_Screen 을 건드리는 다음 변경 전에 실제 소비처를 재확인할 것.
        if name == "g_Screen" { return "float3(eng.texRes[0].xy, eng.texRes[0].x / eng.texRes[0].y)" }
        if name == "g_ModelViewProjectionMatrix" || name == "g_EffectModelViewProjectionMatrix" { return "eng.mvp" }
        // 레이어 모델/기타 행렬(...Matrix / ...MatrixInverse 등): 효과 쿼드 기준 항등이 정답
        // (레이어 회전·스케일은 v1 미반영 — 무회전 레이어 정확. 항등의 역/역전치도 항등).
        // BK/G7: **선언 타입이 mat3 면 float3x3(1.0)** — 위 engineDeclaredTypes 주석의 9쌍 참조.
        if name.hasPrefix("g_"), name.contains("Matrix") { return matrixIdentity(name, engineTypes) }
        // X-⑤: 이펙트 체인 경로는 g_TexelSize = 이펙트 **출력(dst)** 1텍셀(UV), 체인 전 패스에 걸쳐
        // 고정값(패스별 타깃도 tex0 도 아님) 규약으로 채택했다. 근거는 WE gaussian.vert
        // `ratio = g_TexelSize * g_Texture0Resolution` — 단, 이 근거는 **판별력이 없다**: ratio 는
        // ratio.y/ratio.x 로만 소비되므로 dst 기준·tex0 기준 어느 해석이든 같은 값(1)이 나온다.
        // bokeh_blur 7패스 전수 대조에서도 tex0≠target 인 유일한 소비 패스가 두 해석에서 우연히 같은
        // 스케일비를 내 정적으로 더 갈리지 않는다. 확실한 것은 downsample.vert 가 소스 텍셀이 필요할
        // 땐 g_TexelSize 가 아니라 `1.0/g_Texture0Resolution.zw` 를 쓴다는 것뿐(="소스 아님"만 지지).
        // 따라서 이 규약은 "실측으로 확정"이 아니라 **채택된 정본(가장 근거 있는 후보) + 라이브 A/B
        // 판독 대기 항목** — bokeh_blur 12씬의 블러 폭이 게이트다(BACKLOG.md 시각 충실도 표 참조).
        // SceneRendererFrameEncoder 가 applyEffect 진입 시 dst 1 회로 eng.targetRes 를 채운다.
        // 스케일드 fbo 를 패스 타깃/소스로 쓰는 체인(bokeh 등)에서 종전 tex0 근사(4× 과대 블러) 대신
        // 이 정본을 쓴다. 레이어 커스텀 셰이더 경로는 여전히 tex0 근사(다른 정본) — 아래 X-⑤ 스코프
        // 밖 주석 참조. 같은 심볼이 경로별로 다른 값을 낸다는 뜻이며, 어느 쪽도 실측으로 확정되지
        // 않았으니 둘 다 향후 라이브 A/B 로 재검증 대상이다.
        // 머티리얼로 오인되면 기본값 (0,0) → 0/0=NaN UV → 검정(3544152633 ×0.4 luma 손실 근원) — isEngine 등재 유지.
        if name == "g_TexelSize" { return "(1.0 / eng.targetRes.xy)" }
        if name == "g_TexelSizeHalf" { return "(0.5 / eng.targetRes.xy)" }
        // F744: g_LightAmbientColor 는 엔진 상수로 승격. 실제 scene ambientColor 연동 전 흰색 중립값.
        // G-A2/A4/B2: **타입은 vec3 다.** 동봉 WEAssets 의 선언 12건이 전부 `uniform vec3
        // g_LightAmbientColor` 이고 vec4 선언은 0건(generic{,2,3,4}.vert · genericimage{2,3,4}.frag ·
        // genericparticle.frag · genericropeparticle.frag · base/model_vertex_v1.h ·
        // fluidsimulation_combine.frag ×2). float4 를 주입하면 소비처가 전부 타입 불일치로
        // MSL 컴파일에 실패한다 — 예: fluidsimulation_combine.frag:117 `max(CAST3(0.001), g_LightAmbientColor)`.
        if name == "g_LightAmbientColor" { return "float3(1.0, 1.0, 1.0)" }
        // 같은 반구 앰비언트 짝(generic4.vert:9 등 `uniform vec3 g_LightSkylightColor`). 미등재 시
        // 머티리얼 팬텀 슬롯(padDefault 0)으로 강등돼 위쪽 반구가 검게 죽는다.
        if name == "g_LightSkylightColor" { return "float3(1.0, 1.0, 1.0)" }
        // F4-polish②: Forward+ 라이팅 유니폼 — 위 isEngine 주석의 "인식만, 인덱스 배열 피드는 스코프
        // 밖" 한계를 그대로 유지. g_LFeature_ShadowProjection 만 실측 mat4(WE HLSL 크로스컴파일형
        // `const float4x4 g_LFeature_ShadowProjection[...]`, A2-pbr-lighting.md:238) — 항등 반환.
        // 나머지(Color/Origin/Direction/OriginA/OriginB/Exponent/…Transform/PointProjection)는 전부
        // vec4 — 0 벡터 반환(radius/exponent 로 쓰이는 .w 도 0 = 광량 0과 동형, 안전).
        if name == "g_LFeature_ShadowProjection" { return matrixIdentity(name, engineTypes) }
        if name.hasPrefix("g_LPoint_") || name.hasPrefix("g_LSpot_") || name.hasPrefix("g_LTube_")
            || name.hasPrefix("g_LDirectional_") || name.hasPrefix("g_LFeature_Shadow") {
            return "float4(0.0, 0.0, 0.0, 0.0)"
        }
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
        // WE g_TextureNTexel = 슬롯 N 텍스처의 (1/w, 1/h, w, h) — g_TexelSize 동족(텍스처별 텍셀 크기).
        // 머티리얼-0 고정이면 커널 오프셋 0 = 블러/다운샘플 무력화. 모프 코드(model_vertex_v1.h
        // `% morphTexel.z`)가 .zw(=dims)를 쓰므로 .xy 만 주면 재파손 — vec4 전체 치환.
        if name.hasPrefix("g_Texture"), name.hasSuffix("Texel"),
           let n = Int(name.dropFirst("g_Texture".count).dropLast("Texel".count)),
           (0..<8).contains(n) {   // Resolution 과 동일 상한 — N≥8 은 미치환(컴파일 실패→폴백)
            return "float4(1.0 / eng.texRes[\(n)].xy, eng.texRes[\(n)].xy)"
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
        case "g_Alpha", "g_UserAlpha", "g_Brightness", "g_Color",
             // F613: g_Color 의 vec4 변형 — 미등재 시 padDefault (0,0,0,0) 으로 color*=0 즉시 검정.
             "g_Color4",
             // 실물 blend.vert TRANSFORMUV 콤보: UV 를 이 값으로 나눔 — 0 이면 ÷0 NaN, 중립은 항등 배율 1.
             "g_TextureReductionScale",
             // F744: 2D genericimage4/fluidsim 이 bare g_LightAmbientColor 을 선언하면 padDefault=0 으로
             // 레이어가 검게 나옴. WE 는 ambient 를 흰색(1,1,1)으로 폭백하는 케이스가 많다.
             "g_LightAmbientColor":
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

    /// `const <type> <name> ...` 에서 <name> 추출.
    /// 종전 구현은 공백 split 이라 **`=` 앞에 공백이 없는 선언에서 무너졌다** — `const float x=1;` 이
    /// 이름 "x=1;" 을 내고, 그러면 constByName/constNames 키와 identifiers(in:) 가 절대 만나지 않아
    /// 전이 const 강등(computeConstDemoteSet)이 그 선언을 **조용히** 건너뛴다. 배열 선언
    /// `const float k[3] = {…}` 도 같은 이유로 "k[3]" 이었다. 식별자 문자 경계로 토큰을 잘라
    /// 두 번째 토큰(= 타입 다음)을 이름으로 쓴다(정밀도 한정자 형태는 종전과 동일하게 미지원).
    static func constDeclName(_ line: String) -> String {
        let chars = Array(line.dropFirst("const ".count))
        func isIdent(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
        var tokens: [String] = []
        var i = 0
        while i < chars.count && tokens.count < 2 {
            guard isIdent(chars[i]) else { i += 1; continue }
            var t = ""
            while i < chars.count && isIdent(chars[i]) { t.append(chars[i]); i += 1 }
            tokens.append(t)
        }
        return tokens.count >= 2 ? tokens[1] : ""
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
         // WE shim :44/#define uvec4 uint4(ivec/2/3성분 〃), :46 #define mat4x3 float4x3.
         "uvec2": "uint2", "uvec3": "uint3", "uvec4": "uint4",
         "ivec2": "int2", "ivec3": "int3", "ivec4": "int4", "mat4x3": "float4x3",
         "CAST2": "float2", "CAST3": "float3", "CAST4": "float4",
         "frac": "fract", "lerp": "mix", "ddx": "dfdx", "ddy": "dfdy", "inverse": "we_inverse", "mod": "we_mod",
         "M_PI": "3.14159265359", "M_PI_HALF": "1.57079632679",
         "M_PI_2": "6.28318530718"]  // WE 관용: M_PI_2 = 2π(실물 common.h 대조; π/2 는 M_PI_HALF 담당)
    }

    // MARK: - 본문 변환

    /// perTextureSampler: 최상위(main) 본문 전용(호출부 한정, 헬퍼 본문은 항상 false — 캡처 매커니즘의
    /// 단일 제네릭 `sampler smp` 파라미터 threading 은 절대 불변). true 면 texSample2D 의 텍스처별
    /// eng.texWrap/texFilter 런타임 분기(perTextureSamplerExpr)로 clamp/repeat·linear/nearest 선택, false 면 기존 "smp"(clamp) 그대로.
    static func translateBody(_ body: String, symbols: [String: String], isFragment: Bool,
                              perTextureSampler: Bool = false) -> String? {
        var s = body
        // 번역 실패 신호(Optional 반환의 실제 근거). WE 전용 인트린식을 **호출 형태로** 만났는데
        // (rewriteCall 이 이름 뒤의 `(` 를 이미 확인했다) 인자 수가 계약과 달라 재작성하지 못한 경우다.
        // 종전에는 그 자리에서 nil 을 돌려 원문을 그대로 흘려보냈고, 그래서 이 함수는 `-> String?`
        // 이면서도 nil 을 절대 내지 않았다 — :350/:375/:411 의 폴백 3곳이 통째로 도달 불가였고,
        // 실패는 makeLibrary 가 MSL 을 거부할 때까지(사유 로그 없이) 미뤄졌다.
        // 이 다섯은 전부 MSL 내장이 아니므로 원문 통과 = 컴파일 실패 확정 — 여기서 끊어도 무회귀다.
        var unsupported: [String] = []
        // 1) mul(a,b) → (b * a) — **인자 순서를 뒤집는다.** WE 셰이더는 GLSL 문법으로 저작되지만
        //    함수는 HLSL 네이티브를 쓴다(엔진이 매크로 프롤로그로 HLSL 트랜스파일 — `mul` 은 프롤로그에
        //    정의되지 않아 HLSL 빌트인 그대로다). HLSL 은 m[행][열], GLSL/MSL 은 m[열][행]이라 **같은
        //    소스 대입문이 만드는 행렬은 서로 전치**다. 그래서 HLSL `mul(v,M)`(행벡터 v·M)과 등가인
        //    GLSL/MSL 식은 `M*v` 이고, `v*M` 은 전치된 다른 사상이다.
        //
        //    판별식(추론 아님): common_perspective.h 의 squareToQuad 는 정의상 단위정사각형 코너를
        //    (p0,p1,p2,p3) 로 보내야 한다. 실측 — 실물 점열 p0=(0.67728,0.01297) p1=(0.76007,0.14043)
        //    p2=(0.46654,1.09592) p3=(0.16363,0.44881) 에서
        //      (b*a)=M·v : (0,0)(1,0)(1,1)(0,1) → p0,p1,p2,p3 **정확 일치**
        //      (a*b)=v·M : → (-0.031,-0.757) (0.017,-0.831) (0.089,-0.768) (0.091,-0.652) — 전혀 다름
        //    즉 (a*b) 로는 이 함수가 이름값을 못 한다. RE 산출물도 같은 결론을 독립 확립했다
        //    (WE-2.8-COMPLETE-KR.md §A.1 / deep/lanes/A4 §1.4: "포팅 시 `#define mul(a,b) ((b)*(a))`").
        //
        //    이 순서는 벡터-우선(`mul(v,M)`)·행렬-우선(`mul(tangentSpace, lightDir)` — generic.vert)
        //    두 형태 모두에 동시에 옳다. 그게 ((b)*(a)) 가 보편 셰임인 이유다.
        //
        //    d45c259 가 이걸 (a*b) 로 뒤집었고 근거는 "(b*a)→가로띠" 라는 육안 판정이었다. 그 판정은
        //    2026-07-17 — DIRECTDRAW 출력에 알파가 이중으로 곱해져(3c57a8c 가 고침) 실제 fx 광선이
        //    8비트에서 소멸해 있던 시기다. 즉 그때 본 것은 광선이 아니었다. 되돌린 뒤 실측:
        //    lightshafts 41패스 중 mask≡0 이던 19패스가 전부 살아나고(GPU 알파 리드백), WE 실기
        //    대조에서 3299228616 이 개선된다(파리티 표는 docs/we-parity-2026-08-16.md).
        //
        //    호출부 계약: 엔진이 올리는 MVP 는 이 순서에 맞춰 **전치하지 않은** 채로 바인딩한다
        //    (SceneRendererFrameEncoder 커스텀 레이어·SceneRenderer3D 커스텀 메시). 이펙트 경로의
        //    MVP 는 항등이라 순서 무관.
        s = rewriteCall(s, "mul") { args in
            guard args.count == 2 else { unsupported.append("mul/\(args.count)"); return nil }
            return "(\(args[1]) * \(args[0]))"
        }
        // 2) texSample2DLod(t, uv, l) → t.sample(smp, uv, level(l)) / texSample2D(t, uv) → t.sample(smp, uv).
        //    UV 는 we_uv() 로 절단 — WE GLSL(HLSL 방언)은 vec3/vec4 를 UV 로 암시적 절단해 넘기는 걸 허용한다.
        s = rewriteCall(s, "texSample2DLod") { args in
            guard args.count == 3 else { unsupported.append("texSample2DLod/\(args.count)"); return nil }
            let smp = perTextureSampler ? perTextureSamplerExpr(args[0]) : "smp"
            return "\(args[0]).sample(\(smp), we_uv(\(args[1])), level(\(args[2])))"
        }
        s = rewriteCall(s, "texSample2D") { args in
            guard args.count == 2 else { unsupported.append("texSample2D/\(args.count)"); return nil }
            let smp = perTextureSampler ? perTextureSamplerExpr(args[0]) : "smp"
            return "\(args[0]).sample(\(smp), we_uv(\(args[1])))"
        }
        // 2a2) texLoad2D(s, u, r) → 정수 texel fetch — WE shim :66 `#define texLoad2D(s, u, r)
        //      s.Load(int3((u) * (r), 0))` 의 MSL 대응(read 는 lod 기본 0).
        s = rewriteCall(s, "texLoad2D") { args in
            guard args.count == 3 else { unsupported.append("texLoad2D/\(args.count)"); return nil }
            return "\(args[0]).read(uint2((\(args[1])) * (\(args[2]))))"
        }
        // 2a3) texSample2DBackBuffer(s, u, r) → 비MS 변형 texSample2D(s, u) 로 하강(WE shim :70-71 —
        //      두 #define 중 MS Load 변형이 아닌 sample 형태). sampler2DBackBuffer 선언은
        //      texture2d<float> 취급(GLSLType.from).
        s = rewriteCall(s, "texSample2DBackBuffer") { args in
            guard args.count == 3 else { unsupported.append("texSample2DBackBuffer/\(args.count)"); return nil }
            let smp = perTextureSampler ? perTextureSamplerExpr(args[0]) : "smp"
            return "\(args[0]).sample(\(smp), we_uv(\(args[1])))"
        }
        // 2a4) texSample2DCompare(s, u, d) → depth2d 하드웨어 PCF. WE shim :65
        //      `#define texSample2DCompare(s, u, d) s.SampleCmpLevelZero(s##SamplerComparisonState, u, d)`
        //      의 MSL 대응이 `sample_compare` 다. LevelZero = mip 0 고정인데
        //      섀도우 아틀라스는 단일 레벨이라 `mip_filter::none` 로 등가(smpCmp 선언 참조).
        //      **float4 로 감싸는 이유**: HLSL SampleCmpLevelZero 는 float 를 돌려주고 실물은
        //      `texSample2DCompare(...).r` 로 받는다(common_pbr_2.h:75). MSL 은 스칼라에 `.r` 이
        //      없어 그대로 두면 컴파일 실패 — 감싸면 `.r`/무스위즐 양쪽이 성립한다.
        s = rewriteCall(s, "texSample2DCompare") { args in
            guard args.count == 3 else { unsupported.append("texSample2DCompare/\(args.count)"); return nil }
            return "float4(\(args[0]).sample_compare(smpCmp, we_uv(\(args[1])), \(args[2])))"
        }
        // 2a5) texSample3D(s, u) → texture3d 샘플(WE shim :67 `#define texSample3D(s, u) s.Sample(s##SamplerState, u)`).
        //      3D 좌표는 절단하지 않는다(we_uv 는 2성분 전용) — 실물 ccsimple.frag:32,35 가 `albedo.rgb` 를 넘긴다.
        //      샘플러는 `smp`(clamp) 고정: LUT 은 경계 클램프가 정본이고 eng.texWrap 는 2D 슬롯 규약이다.
        s = rewriteCall(s, "texSample3D") { args in
            guard args.count == 2 else { unsupported.append("texSample3D/\(args.count)"); return nil }
            return "\(args[0]).sample(smp, \(args[1]))"
        }
        // 2a6) clip(x) — HLSL 인트린식(WE 방언). x < 0 이면 픽셀 폐기. 실물 소비처:
        //      `shaders/puppettexturechannels.frag:15`, `shaders/volumetricsfront.frag:67,70`.
        //      문장 자리에서만 쓰이므로 블록 문장으로 치환한다(뒤따르는 `;` 는 빈 문장 = 합법).
        //      벡터 인자(HLSL 은 any-성분 음수면 폐기)는 `if (bool2)` 가 되어 **컴파일 실패**한다 —
        //      동봉 실물은 전건 스칼라라 도달 0건이고, 오역 대신 폴터가 이 리포의 규약이다.
        s = rewriteCall(s, "clip") { args in
            guard args.count == 1 else { unsupported.append("clip/\(args.count)"); return nil }
            return "if ((\(args[0])) < 0.0) { discard_fragment(); }"
        }
        // 2b) GLSL 2-인자 atan(y,x) → MSL atan2 (1-인자는 유지)
        s = rewriteCall(s, "atan") { args in args.count == 2 ? "atan2(\(args[0]), \(args[1]))" : nil }
        // 2c) radians()/degrees() 는 MSL 미내장(실물 color_grading 의 radians(u_hueShift)) — 상수 곱으로 치환(π/180, 180/π).
        s = rewriteCall(s, "radians") { args in args.count == 1 ? "((\(args[0])) * 0.017453292519943295)" : nil }
        s = rewriteCall(s, "degrees") { args in args.count == 1 ? "((\(args[0])) * 57.29577951308232)" : nil }
        // 3) 식별자/타입 단일 패스 치환
        s = replaceIdentifiers(s, symbols)
        // F616: 본문 내 배열 생성자 `TYPE[N](...)` 도 MSL brace-init 으로(종전엔 파일스코프 const 만
        // 재작성 — 함수 본문 사용은 MSL 문법 오류 LOUD 폴 fallback). 배열 인덱싱(`a[i]`)은
        // `]` 뒤 `(` 가 아니라 미검출이라 안전.
        s = rewriteArrayConstructors(s)
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
        guard unsupported.isEmpty else {
            // 폴백 경로(:350 전체 번역 포기 / :375 헬퍼 스킵 / :411 강등 const 스킵)가 여기서 살아난다.
            WapleLog.warn("[Waple] GLSL translate failed — unsupported intrinsic arity: \(unsupported.joined(separator: ", "))")
            return nil
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
        case varying(String, GLSLType, written: Bool)  // written: 헬퍼(전이 포함)가 대입하는가 → 참조 승격
        case attribute(String, GLSLType)      // a_Position / a_TexCoord
        case texture(Int)                     // g_TextureN
        case audio(String)                    // g_AudioSpectrum16Left/Right
        case sampler                          // texSample2D 사용 시 smp
        /// texSample2DCompare 사용 시 smpCmp — `compare_func` 가 설정된 샘플러라야 `sample_compare` 가
        /// 유효하다(일반 `smp` 로는 MSL 컴파일 실패). 값은 Mesh3DShaders.swift:399-403 의 손-포팅과 동일.
        case samplerCompare
    }

    /// 헬퍼별 캡처 목록(결정적 순서) + 호출 그래프 전이 폐쇄.
    static func computeCaptures(helpers: [GLSLFunction], materials: [MaterialParam],
                                varyings: [(type: GLSLType, name: String)], textures: [Int],
                                textureKinds: [Int: GLSLType] = [:]) -> [String: [Capture]] {
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
        // F420: varying "쓰기" 전이 폐쇄 — 헬퍼가 직접 대입하거나, 호출하는 헬퍼가 대입하는 varying.
        // 이 경우 캡처를 값이 아닌 참조(thread&)로 받아야 호출자의 out.<n> 에 대입이 반영된다
        // (by-value 면 지역 사본만 갱신돼 컴파일은 성공하지만 varying 이 미갱신으로 오렌더).
        var writesOf: [String: Set<String>] = [:]
        for h in helpers {
            writesOf[h.name] = Set(varyings.map(\.name).filter { isAssigned($0, in: h.body) })
        }
        changed = true
        while changed {
            changed = false
            for h in helpers {
                var w = writesOf[h.name] ?? []
                for g in helpers where g.name != h.name && (refsOf[h.name] ?? []).contains(g.name) {
                    let before = w.count
                    w.formUnion(writesOf[g.name] ?? [])
                    if w.count != before { changed = true }
                }
                writesOf[h.name] = w
            }
        }
        var out: [String: [Capture]] = [:]
        for h in helpers {
            let refs = refsOf[h.name] ?? []
            var caps: [Capture] = []
            for (i, m) in materials.enumerated() where refs.contains(m.glslName) { caps.append(.material(i)) }
            for name in refs.filter({ isEngine($0) && !$0.contains("AudioSpectrum") }).sorted() { caps.append(.engine(name)) }
            for v in varyings where refs.contains(v.name) {
                caps.append(.varying(v.name, v.type, written: (writesOf[h.name] ?? []).contains(v.name)))
            }
            for (n, t) in [("a_Position", GLSLType.vec3), ("a_TexCoord", GLSLType.vec2)] where refs.contains(n) {
                caps.append(.attribute(n, t))
            }
            for n in textures where refs.contains("g_Texture\(n)") { caps.append(.texture(n)) }
            for n in ["g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
                      "g_AudioSpectrum32Left", "g_AudioSpectrum32Right",
                      "g_AudioSpectrum64Left", "g_AudioSpectrum64Right"] where refs.contains(n) { caps.append(.audio(n)) }
            // 텍스처 샘플링(자기 파라미터의 sampler2D 포함)엔 공용 샘플러가 필요.
            // texSample3D 도 같은 `smp`(clamp)를 쓴다 — 3D LUT 은 경계 클램프가 정본(실물 ccsimple).
            if refs.contains("texSample2D") || refs.contains("texSample2DLod") || refs.contains("texSample2DBackBuffer")
                || refs.contains("texSample3D")
                || h.params.contains(where: { $0.type == "sampler2D" || $0.type == "sampler2DBackBuffer"
                                              || $0.type == "sampler3D" })
                || caps.contains(where: { if case .texture(let n) = $0 { return (textureKinds[n] ?? .sampler2D) != .sampler2DComparison }; return false }) {
                caps.append(.sampler)
            }
            // 비교 샘플링 전용 — `smp` 와 별개 파라미터다(compare_func 유무가 다른 샘플러 객체).
            if refs.contains("texSample2DCompare")
                || h.params.contains(where: { $0.type == "sampler2DComparison" })
                || caps.contains(where: { if case .texture(let n) = $0 { return textureKinds[n] == .sampler2DComparison }; return false }) {
                caps.append(.samplerCompare)
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
        case .varying(let n, _, _): return n
        case .attribute(let n, _): return n
        case .texture(let n): return "g_Texture\(n)"
        case .audio(let n): return n
        case .sampler: return "smp"
        case .samplerCompare: return "smpCmp"
        }
    }

    /// main 호출부에서 전달할 스테이지별 실값.
    static func captureCallArg(_ cap: Capture, isFragment: Bool, materials: [MaterialParam],
                               engineTypes: [String: GLSLType] = [:]) -> String {
        switch cap {
        case .material(let i): return "p[\(i)]\(materials[i].type.swizzle)"
        case .engine(let n): return engineReplacement(n, engineTypes: engineTypes)
        case .varying(let n, _, _): return isFragment ? "in.\(n)" : "out.\(n)"
        case .attribute(let n, _): return "vin.\(n)"  // fragment 에선 비합법 → 컴파일 실패 → 폴백(의도)
        case .texture(let n): return "g_Texture\(n)"
        case .audio(let n): return engineReplacement(n)  // audioL/audioR/audioL32/... 매핑 공유
        case .sampler: return "smp"
        case .samplerCompare: return "smpCmp"
        }
    }

    private static func captureParamDecl(_ cap: Capture, materials: [MaterialParam],
                                         textureKinds: [Int: GLSLType] = [:],
                                         engineTypes: [String: GLSLType] = [:]) -> String {
        switch cap {
        case .material(let i): return "\(materials[i].type.msl) \(materials[i].glslName)"
        case .engine(let n):
            // BK/G7: 헬퍼 캡처 파라미터의 타입도 선언 타입을 따라야 한다 — 호출부가 넘기는
            // `captureCallArg` 값(`float3x3(1.0)`)과 갈리면 그 자리에서 컴파일이 깨진다.
            let t = n.contains("Matrix") ? (engineTypes[n]?.msl ?? "float4x4")
                // Texel 접미는 isEngine 통과분만 도달 = g_TextureNTexel 한정(g_TexelSize 는 "Size" 접미).
                : (n.hasSuffix("Resolution") || n.hasSuffix("Texel") || n == "g_PointerState" ? "float4"
                    // F614: g_Screen 은 vec3 — 헬퍼 캡처 승격 시 치환식(float3)과 타입 정합.
                    : (n == "g_Screen" ? "float3"
                        : (n == "g_PointerPosition" || n == "g_ParallaxPosition" || n == "g_PointerPositionLast"
                            || n == "g_TexelSize" || n == "g_TexelSizeHalf" ? "float2" : "float")))
            return "\(t) \(n)"
        case .varying(let n, let t, let written):
            // F420: 헬퍼가 쓰는 varying 은 참조로 — by-value 면 호출부(out.<n>)와 끊긴 지역 사본이라
            // 헬퍼의 대입이 유실된다(컴파일 성공·오렌더). 읽기 전용은 기존 값 파라미터 유지.
            return written ? "thread \(t.msl)& \(n)" : "\(t.msl) \(n)"
        case .attribute(let n, let t): return "\(t.msl) \(n)"
        case .texture(let n): return "\((textureKinds[n] ?? .sampler2D).msl) g_Texture\(n)"
        case .audio(let n): return "constant float* \(n)"
        case .sampler: return "sampler smp"
        case .samplerCompare: return "sampler smpCmp"
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
                                structs: Set<String> = [], textureKinds: [Int: GLSLType] = [:],
                                engineTypes: [String: GLSLType] = [:]) -> String? {
        guard let ret = mslType(h.ret, structs: structs) else { return nil }
        var ps: [String] = []
        for p in h.params {
            guard let t = mslType(p.type, structs: structs) else { return nil }
            // 배열 파라미터는 constant 포인터(호출부의 audioL/캡처 배열과 정합; MSL 은 값-배열 불가).
            if p.array { ps.append("constant \(t)* \(p.name)") }
            else { ps.append(p.byRef ? "thread \(t)& \(p.name)" : "\(t) \(p.name)") }
        }
        ps.append(contentsOf: captures.map {
            captureParamDecl($0, materials: materials, textureKinds: textureKinds, engineTypes: engineTypes)
        })
        return "inline \(ret) \(h.name)(\(ps.joined(separator: ", ")))"
    }

    /// vertex 스테이지 빌트인 사용 플래그(전부 false 면 방출물이 종전과 바이트 동일).
    struct VertexBuiltins: Equatable {
        var vertexID = false        // → `uint gl_VertexID [[vertex_id]]`
        var instanceID = false      // → `uint gl_InstanceID [[instance_id]]`
        var viewportIndex = false   // → Vary 의 `uint gl_ViewportIndex [[viewport_array_index]]`
    }

    private static func assemble(varyings: [(type: GLSLType, name: String)], textures: [Int],
                                 textureKinds: [Int: GLSLType] = [:],
                                 vertexBuiltins: VertexBuiltins = VertexBuiltins(),
                                 vertexAttributes: [String] = alwaysLoadedVertexAttributes,
                                 materialCount: Int,
                                 vertAudioNames: [(name: String, buffer: Int)] = [],
                                 fragAudioNames: [(name: String, buffer: Int)] = [],
                                 consts: [String] = [],
                                 helperProtos: [String] = [], helperDefs: [String] = [],
                                 vertBody: String, fragBody: String, structs: String = "",
                                 premultiplyOutput: Bool = false) -> String {
        var vary = "struct Vary {\n  float4 gl_Position [[position]];\n"
        // 레이어드 렌더 타깃 선택자(실물 shadowcaster 계열: 아틀라스 슬라이스를 인스턴스로 고른다).
        // MSL 은 uint + [[viewport_array_index]] 를 요구한다 — GLSL 원문의 `varying uint` 과 같은 폭.
        if vertexBuiltins.viewportIndex { vary += "  uint gl_ViewportIndex [[viewport_array_index]];\n" }
        for v in varyings { vary += "  \(v.type.msl) \(v.name);\n" }
        vary += "};\n"
        // [2026-08-21] 종전엔 이 줄이 `a_Position`/`a_TexCoord` **두 개 고정**이었다. 지금은
        // 화이트리스트에서 골라 싣는다 — 두 개만 실린 경우의 방출 문자열은 종전과 **글자 그대로
        // 같다**(무회귀). 셋째(`a_Normal`)는 셰이더가 참조할 때만 붙는다.
        let vinMembers = vertexAttributes.compactMap { n -> String? in
            guard let e = vertexAttributeWhitelist.first(where: { $0.name == n }) else { return nil }
            return "\(e.type.msl) \(e.name) [[attribute(\(e.slot))]];"
        }
        let vin = "struct VIn { " + vinMembers.joined(separator: " ") + " };\n"
        // timeAndPad = (time, pointerUV.x, pointerUV.y, frametime dt) / pointerLastAndPad = (직전 프레임 포인터 UV.xy, g_PointerState.z 클릭힘, 0).
        // texWrap[2](8 슬롯, texRes 와 동일 상한): 슬롯별 1=clamp/0=repeat(F162/F163) — buildPassBindings 가
        // bind 출처(fbo/previous)=clamp, aux 출처=TexImage.clampUVs 로 빌드 시 1 회 계산(WE 기본=repeat).
        // texFilter[2](감사 V07, 동일 상한): 슬롯별 1=nearest/0=linear — TexImage.noInterpolation(WE tex Flags
        // bit0). bind 출처=선형(단, 체인 첫 이펙트의 previous=베이스 직결은 baseNoInterp), aux 출처=자산 플래그.
        // Swift 측 단일 빌더 SceneRendererFrameEncoder.engineUniform 과 레이아웃 동기 필수.
        // H1: layerTint = 레이어 color×brightness/alpha — 이펙트는 (1,1,1,1) 기본값으로 물변경.
        // X-⑤: targetRes(layerTint 뒤 추가 — 앞 오프셋 불변) = 이펙트 **출력(dst)** 해상도, 전 패스 불변.
        // 채택 근거·이 근거의 판별력 한계·레이어 커스텀 경로와의 규약 이원화·라이브 A/B 대기 상태는
        // 위 g_TexelSize 치환부(computeUV 근처) 주석 참조 — "실측으로 확정" 아님.
        let eng = "struct EngineU { float4x4 mvp; float4 timeAndPad; float4 pointerLastAndPad; float4 texRes[8]; float4 texWrap[2]; float4 texFilter[2]; float4 layerTint; float4 targetRes; };\n"
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

        // 비교 샘플러(smpCmp): sampler2DComparison 슬롯이 있을 때만 방출한다 — 미사용 constexpr
        // 샘플러는 무해하지만 프리앰블 노이즈이고, 이 셰이더가 섀도우 아틀라스를 쓴다는 신호가 된다.
        // 파라미터는 Mesh3DShaders.swift:399-403 손-포팅과 **동일**해야 한다(두 레인이 같은 아틀라스를
        // 읽는다): filter::linear = 하드웨어 PCF(WE 샘플러 캐시가 만드는 유일한 비교 필터값
        // 0x95 = D3D11_FILTER_COMPARISON_MIN_MAG_MIP_LINEAR, 원본 `0x140099b67 mov ecx, 0x95`),
        // compare_func::less_equal = WE 의 GREATER 에 리버스드-Z(common_pbr_2.h `#if REVERSEDEPTH`)를
        // 되돌린 등가, address 는 WE 가 BORDER 지만 소비처가 uv 를 직접 clamp 하므로 무영향.
        // mip_filter::none = SampleCmpLevelZero(shim :65) 의 mip 0 고정.
        let cmpSampler = textureKinds.values.contains(.sampler2DComparison)
            ? "    constexpr sampler smpCmp(filter::linear, mip_filter::none, address::clamp_to_edge, compare_func::less_equal);\n"
            : ""

        // fragment 텍스처 파라미터
        // 슬롯별 선언 종류: sampler2DComparison → depth2d<float>, sampler3D → texture3d<float>,
        // 그 외(미등재 포함) → texture2d<float>. `textureKinds` 미등재는 본문 스캔으로만 발견된
        // 슬롯이라 2D 기본이 맞다(선언이 있으면 파스가 종류를 실었다).
        var fragTex = textures.map { "\((textureKinds[$0] ?? .sampler2D).msl) g_Texture\($0) [[texture(\($0))]]" }
            .joined(separator: ",\n                        ")
        if !fragTex.isEmpty { fragTex = ",\n                        " + fragTex }
        func audioDecl(_ names: [(name: String, buffer: Int)], sep: String) -> String {
            names.map { "\(sep)constant float* \($0.name) [[buffer(\($0.buffer))]]" }.joined()
        }
        let audioParams = audioDecl(vertAudioNames, sep: ", ")
        let audioFrag = audioDecl(fragAudioNames, sep: ",\n                        ")
        let pFrag = materialCount > 0 ? ",\n                        constant float4* p [[buffer(0)]]" : ""

        var fragBody = fragBody
        // 프리멀티플라이 주입. 종전엔 `return gl_FragColor;` 리터럴 치환 하나뿐이었는데, 그 리터럴은
        // translateBody 가 **본문에 gl_FragColor 가 있을 때만** 만들어 붙인다(:1465 근처). 즉
        // `return vec4(...)` 로 직접 반환하는 셰이더에서는 이 블록이 조용히 무연산이었고 tint·premult
        // 가 통째로 빠졌다. 두 모양 모두 처리한다 — gl_FragColor 형은 검증된 기존 치환 그대로,
        // 직접 반환형은 본문의 `return <식>;` 을 we_premultiply 로 감싼다(의미 동일).
        var premulHelper = ""
        if premultiplyOutput {
            premulHelper = """
            // premultiplyOutput 전용: 레이어 tint 적용 후 alpha 프리멀티플라이(위 gl_FragColor 경로와 동일 식).
            inline float4 we_premultiply(float4 c, float4 tint) {
                float3 rgb = c.rgb * tint.rgb;
                float a = c.a * tint.a;
                return float4(rgb * a, a);
            }

            """
            if fragBody.contains("return gl_FragColor;") {
                fragBody = fragBody.replacingOccurrences(
                    of: "return gl_FragColor;",
                    with: """
                    gl_FragColor.rgb *= eng.layerTint.rgb;
                    gl_FragColor.a *= eng.layerTint.a;
                    return float4(gl_FragColor.rgb * gl_FragColor.a, gl_FragColor.a);
                    """)
            } else {
                fragBody = premultiplyReturns(fragBody)
            }
        }

        // WE `in uint gl_VertexID/gl_InstanceID` → MSL 스테이지 빌트인 파라미터(이름 유지라 본문 치환 불요).
        let builtinParams = (vertexBuiltins.vertexID ? ", uint gl_VertexID [[vertex_id]]" : "")
            + (vertexBuiltins.instanceID ? ", uint gl_InstanceID [[instance_id]]" : "")
        let vertSig = """
        vertex Vary ev_main(VIn vin [[stage_in]]\(materialCount > 0 ? ", constant float4* p [[buffer(0)]]" : ""), constant EngineU& eng [[buffer(1)]]\(audioParams)\(builtinParams)) {
            Vary out = {};
        \(indent(vertBody))
            return out;
        }
        """
        let fragSig = """
        fragment float4 ef_main(Vary in [[stage_in]]\(pFrag), constant EngineU& eng [[buffer(1)]]\(fragTex)\(audioFrag)) {
            // 1단계 mip 활성화(mip_filter::linear): mipCount>1 텍스처는 실제 mip 샘플, 단일레벨은 LOD 클램프로 비트동일.
            // level() 명시 LOD 도 none 이면 base 클램프(TexMipChainUploadTests 실측 주석)였던 것이
            // linear 로 지정 레벨이 유효해진다 — WE texture2DLod 의미론 복원이며 단일레벨은 역시 동일(클램프).
            constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
            // F162/F163: 최상위 본문 텍스처 샘플 호출은 슬롯별 eng.texWrap 로 smp(clamp)/smpRepeat 런타임 분기
            // (perTextureSamplerExpr) — 헬퍼 내부·전달용 smp 는 위 clamp 그대로(캡처 매커니즘 무변경).
            constexpr sampler smpRepeat(filter::linear, mip_filter::linear, address::repeat);
            // 감사 V07: NoInterpolation(eng.texFilter) 용 nearest 쌍 — 필터만 point, 어드레스 모드 보존.
            constexpr sampler smpNearest(filter::nearest, mip_filter::linear, address::clamp_to_edge);
            constexpr sampler smpRepeatNearest(filter::nearest, mip_filter::linear, address::repeat);
        \(cmpSampler)\(indent(fragBody))
        }
        """
        let structBlock = structs.isEmpty ? "" : structs + "\n"
        let constBlock = consts.isEmpty ? "" : consts.joined(separator: "\n") + "\n"
        let protoBlock = helperProtos.isEmpty ? "" : helperProtos.joined(separator: "\n") + "\n"
        let defBlock = helperDefs.isEmpty ? "" : helperDefs.joined(separator: "\n\n") + "\n"
        return "#include <metal_stdlib>\nusing namespace metal;\n\(structBlock)\(eng)\(vin)\(vary)\(uvHelpers)\(premulHelper)\(constBlock)\(protoBlock)\(defBlock)\n\(vertSig)\n\n\(fragSig)\n"
    }

    /// fragment main 본문의 `return <식>;` 을 `return we_premultiply(<식>, eng.layerTint);` 로 감싼다.
    /// gl_FragColor 를 쓰지 않고 vec4 를 직접 반환하는 셰이더용(premultiplyOutput 경로 전용).
    /// - 본문은 main 한 함수분이다(헬퍼는 helperDefs 로 따로 방출) — 다른 함수의 return 을 건드리지 않는다.
    /// - `returnValue` 같은 식별자 오인 방지: `return` 뒤 문자가 식별자 문자면 건너뛴다.
    /// - 값 없는 `return;`(있을 수 없지만 방어)은 감싸지 않는다.
    static func premultiplyReturns(_ src: String) -> String {
        let chars = Array(src)
        var out = ""
        var i = 0
        let kw = "return"
        while i < chars.count {
            if chars[i] == "r", isWordStart(chars, i), i + kw.count <= chars.count,
               String(chars[i..<i + kw.count]) == kw {
                var j = i + kw.count
                let boundary: Bool
                if j < chars.count {
                    let c = chars[j]
                    boundary = !(c.isLetter || c.isNumber || c == "_")
                } else {
                    boundary = true
                }
                if boundary {
                    var depth = 0
                    var expr = ""
                    var terminated = false
                    while j < chars.count {
                        let c = chars[j]
                        if c == "(" || c == "[" { depth += 1 }
                        if c == ")" || c == "]" { depth -= 1 }
                        if c == ";" && depth == 0 { terminated = true; break }
                        expr.append(c)
                        j += 1
                    }
                    let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if terminated && !trimmed.isEmpty {
                        out += "return we_premultiply(\(trimmed), eng.layerTint);"
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
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
                // [2026-08-28] 구분자에 콤마를 넣는다. 종전의 `split(separator: " ")` 은
                // `"0.315, 0.135, 0.1125"` 를 `["0.315,", "0.135,", "0.1125"]` 로 쪼갰고
                // `Float("0.315,")` 가 nil 이라 **앞 성분이 조용히 사라져** `[0.1125]` 만 남았다.
                // 설치본 도달 3파일 5건 — `assets/shaders/fade.frag:6` ·
                // `assets/zcompat/scene/shaders/2084198056/Simple_Audio_Bars.frag:22,23,27` ·
                // `projects/defaultprojects/fantasticcar/shaders/dome.vert:9`. 다섯 건 전부
                // 현재가 오답이라 고쳐서 나빠지는 자리가 없다.
                //
                // `dome.vert` 는 짝 머티리얼(`materials/dome/dome.json`)에 `constantshadervalues`
                // 가 없고 `usershadervalues` 는 `SceneDocument.swift:3546`(2D)에만 있어 **3D 메시
                // 경로에 대체 공급원이 없다** — 어노테이션 기본값이 유일한 값이다.
                //
                // 같은 결함이 `AudioResponse.swift:220-222` 에도 있고 그 주석이 이 정정을 예고했다.
                return String(after[after.index(after: q1)..<q2])
                    .split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { Float($0) }
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
