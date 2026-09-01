import Foundation

/// WE GLSL 전처리기: `[COMBO]` 기본값 + `#include` 인라인 + `#if/#ifdef/#else/#elif/#endif` 평가.
/// 순수(테스트 가능). 미발견 인클루드/미지원 #include 는 안전 무시(빈 줄)하고 로그. 단, F421:
/// 미지원 #if 식은 안전 무시가 아니라 전처리 "거부"(오분기 = 오역 — "오역보다 폴터" 위반) — preprocessStrict nil.
///
/// **실물이 인식하는 지시문은 9종뿐이다**(디스패처 0x14016b0e0-0x14016c3f8, 줄 인식 정규식
/// `^\s*#\s*([a-z]+)\b\s*(.*)` @0x14048d048): `define`(0x14016b8e3) `ifdef`(0x14016bd26)
/// `ifndef`(0x14016bde0) `else`(0x14016be73) `endif`(0x14016bf30) `if`(0x14016bf9e)
/// `elif`(0x14016c00b) `require`(0x14016c0ec) `undef`(0x14016c201).
/// `#version`/`#extension`/`#pragma`/`#error`/`#line` 은 **지시문이 아니다** — 실물은 인식하지
/// 못해 본문에 그대로 남긴다(0x14016c1f8 → 0x14016bbb0 의 "미지의 지시문" 경로).
/// 이 파일은 그 9종을 전부 다룬다(`#require` 는 소비만 — 아래 분기의 [미해결] 참조).
public enum ShaderPreprocessor {
    /// 실물이 지시문으로 **인식하는 이름 9종**(디스패처 0x14016b0e0-0x14016c3f8 · 줄 인식 정규식
    /// `^\s*#\s*([a-z]+)\b\s*(.*)` — 원본 파일오프셋 0x48be48 부근의 키워드 풀과 일치).
    /// `version`/`extension`/`pragma`/`error`/`line` 은 **여기 없다** — 실물이 못 알아보고 본문에 남긴다.
    static let engineDirectives: [String] = [
        "ifndef", "ifdef", "define", "elif", "endif", "else", "undef", "require", "if",
    ]

    /// - combos: scene.json 에서 온 명시적 콤보 값(소스의 [COMBO] 기본값보다 우선).
    /// - include: `#include "name"` → 헤더 소스(없으면 nil → 빈 인라인).
    public static func preprocess(_ source: String, combos: [String: Int],
                                  include: (String) -> String? = { _ in nil }) -> String {
        // F421: 미지원 #if 식(삼항 `?:`·렉서가 모르는 문자·잔여 토큰)은 어느 분기를 골라도 오역 —
        // (모듈로·비트·시프트·16진/접미 리터럴은 G2 에서, 소수 리터럴은 BK 에서 실물대로 평가로 넘어갔다.)
        // 조용한 오분기 대신 안전 거부(빈 결과 → 번역 실패 → 폴터로 폴백; "오역보다 폴터").
        preprocessStrict(source, combos: combos, include: include) ?? ""
    }

    /// 전처리 엄격판: 미지원 #if 식 감지 시 nil(거부). 호출부는 nil 을 번역 실패로 승격해야 한다.
    static func preprocessStrict(_ source: String, combos: [String: Int],
                                 include: (String) -> String? = { _ in nil }) -> String? {
        // 실물 WE 셰이더는 CRLF — 정규화하지 않으면 `#endif\r` 미인식으로 조건부 스택이 안 닫혀
        // 첫 비활성 분기 이후 전체가 소실된다(실측 31씬 전 효과 폴백의 근본 원인).
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var defines = combos
        // F3: WE 는 GLSL 문법 셰이더를 항상 HLSL(D3D11) 백엔드로 컴파일한다(WE-2.8-clean-room-KR.md:266-267,
        // 단일 백엔드 확정). base-assets 셰이더(composelayer.vert/effectcomposebackground.vert/
        // passthroughblend.vert/common_particles.h/model_vertex_v1.h/model_fragment_v1.h 등)의
        // `#ifdef HLSL`/`#if HLSL` 분기는 D3D11/Metal 공통의 화면공간 Y-플립 보정(v_ScreenCoord.y=-y 등)
        // 이라 Metal 백엔드에도 필요 — 미시딩 시 GLSL(비-HLSL) 분기가 골라져 보정이 누락된다.
        // HLSL_SM30(구형 SM3.0 텍스처 채널 워크어라운드)는 대상 밖이라 주입하지 않는다(정상 폴백 유지).
        defines["HLSL"] = 1
        defines["HLSL_SM40"] = 1
        // S2-shaderlab②(정정): WE 는 HLSL/HLSL_SM40 외 SHADERVERSION 도 시딩한다 — wallpaper64.exe 에
        // "SHADERVERSION" 문자열이 있고 그 직후에 "69" 가 온다(뒤이어 ifndef/ifdef/define/elif/if/
        // endif 지시문 키워드 풀 — 메모리의 SHDV0069 와도 일치).
        //
        // [오프셋 정정 2026-08-19] 종전 주석은 `0x48BF38` 을 "실제 파일 오프셋" 이라 불렀다.
        // **반대다** — 0x48BF38 은 분석 리포의 rich-header **주입본**(5,360,320 B) 기준이고,
        // 원본(5,360,112 B, sha256 40e2ce02…)에서는 `0x48BE68` 이다(정확히 −0xD0).
        // 두 파일을 바이트 대조해 확인했다. 원본으로 보려면:  xxd -s 0x48BE68 -l 64
        // 주입본은 삭제 예정 리포에만 있으므로, 남겨야 할 인용은 원본 기준이다.
        // 규약은 `spec/engine/decompilation-provenance.json` 의 richHeaderShift 참조 —
        // 다만 그 문서는 VA(0x140…) 39개만 분류하고 이 줄 같은 **파일 오프셋** 인용은 다루지 않는다. 미시딩 시 실물 소비처 assets/shaders/generic3.frag:83,
        // genericimage3.frag:88 의 `#if SHADERVERSION < 62` 가 undefined→0 평가로 항상 참이 되어
        // 구형 PerformLighting_Deprecated 분기를 고른다(WE 는 69<62=false 로 최신 분기).
        // 로컬 코퍼스(backgrounds/ 460씬) 실측: LIGHTS_POINT/SPOT/TUBE/DIRECTIONAL 콤보 참조 0건 —
        // 콤보가 없으면 두 분기 내부의 `#if LIGHTS_*` 서브블록이 양쪽 다 사라져 `vec3 light = CAST3(0);
        // return light;` 로 텍스트 동일 → 오늘 시점 렌더 무변화, WE 정합만 개선(장래 라이트 콤보 지원 대비).
        defines["SHADERVERSION"] = 69
        // WE 컴파일러 내장 캐스트 매크로(헤더에 없음 — 실물 depthparallax 의 CAST3X3 등).
        // 소스가 자체 정의하면 그것이 우선(아래 builtinCasts 는 부재 시에만 주입).
        // [COMBO] 기본값(명시 combos 가 없을 때만 채움)
        for (name, def) in parseComboDefaults(source) where defines[name] == nil { defines[name] = def }
        var included = inlineIncludes(source, include: include, depth: 0)
        // CAST3X3(mat4) 는 GLSL 에선 상단 3x3 절단이지만 MSL 엔 float3x3(float4x4) 생성자가 없다 —
        // 번역기 프리앰블의 오버로드 헬퍼 we_cast3x3(절단/통과) 로 위임(실물 depthparallax).
        // S2-shaderlab①(정정): WE 바이너리 임베디드 셰이더 shim 전수 대조 결과 CASTI/
        // CASTU/CASTF/CAST4U 4 종이 기존 목록에 없었다. WE shim 은 이 4종 + 기존 CAST2/CAST3/CAST4/
        // CAST3X3 총 8종뿐.
        //
        // [오프셋 정정 2026-08-19] 종전 주석은 이 shim 을 `0x486bf6-0x486cec` 로 인용하며
        // "실제 파일 오프셋으로 보려면 +0xD0 보정 필요" 라고 썼다. **반대다** — `0x486bf6` 은
        // 이미 **원본** 기준이고(원본에서 `#define CASTI` 가 정확히 그 자리), 주입본이 `0x486cc6` 다.
        // 바로 위 SHADERVERSION 주석과 같은 파일 안에서 규약이 서로 반대로 적혀 있었다.
        // 정확한 쪽 대조군: `SystemAudioSpectrumProvider.swift:92` · `Model3D.swift:54,320`(둘 다 −0xD0).
        //
        // 아래 CAST2X2/CAST4X4 는 WE shim 에 없는 로컬 추가(무해한 상위집합)라
        // 우리 주입 목록 = WE 8종 ∪ 로컬 2종. 실사용처(로컬 코퍼스 전수 실측): CASTU 69회·CASTF 12회
        // (model_vertex_v1.h 모프타깃 블렌딩 + generic3/genericimage3 라이팅 루프 `CASTU(LIGHTS_POINT)`
        // 등 양쪽) — CASTI·CAST4U 는 전 셰이더 자산 0회(4종 모두가 MORPHING 소비라는 서술은 부정확,
        // 완전성 갭이 실재해 4종 다 주입은 유지).
        // CASTU/CASTI/CASTF 는 스칼라라 MSL 생성자 스펠링이 GLSL 과 동일(uint/int/float) — 별도 치환 불요.
        // CAST4U(x)=((uint4)(x)) 는 HLSL/MSL 공통 스펠링(uint4)이라 vecN 계열과 달리 typeAndMacroRenames
        // 경유 없이 바로 유효.
        for (name, body) in builtinCastMacros
        where !identifierDefined(name, in: included) && identifierReferenced(name, in: included) {
            included = "#define \(name)(x) \(body)\n" + included
        }
        // 인라인된 헤더의 [COMBO] 기본값도 반영
        for (name, def) in parseComboDefaults(included) where defines[name] == nil { defines[name] = def }
        return evaluateConditionals(spliceDefineContinuations(included), defines: defines)
    }

    /// 번역 메모이즈 키 전용: `#include` 무조건 재귀 인라인 + CRLF 정규화만 수행(조건부 평가·매크로 확장 제외).
    /// 근거: preprocess 는 조건부 평가 전에 include 를 무조건 인라인하므로(위 line 19) 이 결과가 실제
    /// 해석과 정확히 일치 = 내용 기반 완전 키. 비용은 preprocess 의 1-2%(실측) — 조건부 평가/매크로 fixpoint
    /// (66-87%)를 히트 시 건너뛰기 위한 저렴한 지문. base-assets 교체/패키지별 인클루드 상이 시 자동 분기.
    static func inlinedSource(_ source: String, include: (String) -> String?) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return inlineIncludes(normalized, include: include, depth: 0)
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
    /// **[2026-08-21] `public` 이던 사유는 사라졌다.** 종전 사유는 "렌더러(WapleRender)의
    /// `resolvePassCombos` 가 선언된 콤보 이름 집합을 알아야 씬 저작 키를 선언 철자로 정규화한다"
    /// (G-A3-1) 였는데, 그 정규화가 `GLSLTranslator.uppercasedComboKeys`(선언 유무와 무관한 전건
    /// 대문자화 — 실물 `toupper` 0x14015458c-0x1401545aa 와 같은 계약)로 옮겨가면서 그 호출부가
    /// 없어졌다. 지금 모듈 밖 호출자는 **테스트뿐**이다(`Sources/WapleRender/**` 의
    /// `ShaderPreprocessor` 참조 0건, 2026-08-21 실측). `internal` 로 낮춰도 되지만 반환값이
    /// 순수 파스 결과라 노출에 위험이 없어 그대로 둔다.
    public static func parseComboDefaults(_ source: String) -> [String: Int] {
        var out: [String: Int] = [:]
        // **CRLF 함정 — 반드시 `isNewline` 로 쪼갠다.** Swift 의 `"\r\n"` 은 **단일 grapheme** 이라
        // `split(separator: "\n")` 에 걸리지 않는다. 동봉 셰이더는 `.vert`/`.frag`/`.h` **498개 전건이
        // CRLF** 이므로, 종전 구현은 파일 전체를 한 줄로 보고 `guard line.contains("[COMBO]")` 를
        // 통과한 뒤 **첫 `[COMBO]` 하나만** 돌려주고 있었다(실측: `shaders/fur4.frag` 의 6개 중
        // `LIGHTING` 만 — FOG/REFLECTION/RIMLIGHTING/SHADINGGRADIENT/INSTANCECOUNT 전부 유실).
        // `[COMBO]` 가 2개 이상인 동봉 셰이더가 **59개**다.
        //
        // 왜 여태 안 터졌나: `preprocessStrict` 가 **자기 입력만** CRLF 정규화하고 그 안에서
        // 다시 부르므로 단일 스테이지 기본값은 복구된다. 구멍은 **정규화 밖의 호출부**다 —
        // `GLSLTranslator._translate` 의 교차스테이지 union(`for src in [vertex, fragment]` 루프)이
        // raw 소스를 넘긴다.
        //
        // [r4-06 정정] 종전 이 자리는 호출부를 **둘**로 적고 그중 하나로
        // `SceneRendererResources.resolvePassCombos` 를 지목했지만, 그 함수는 이 함수를 **부르지
        // 않는다**. 전수 재현: `grep -rn 'parseComboDefaults' Sources` → 이 파일 자신(2자리)과
        // `GLSLTranslator._translate` 하나뿐이다. 줄 번호 인용(`:20-22` `:173` `:1042` `:784`)도
        // 전부 무효라 심볼 인용으로 바꿨다.
        // 형제 함수 `GLSLTranslator.samplerCombos`/`formatComboSlots` 는 이미 `isNewline` 로 쪼개고
        // 그 이유를 주석에 적어 두었다 — 그 수정이 이 함수로 전파되지 않았던 것이다.
        for line in source.split(whereSeparator: { $0.isNewline }) {
            guard line.contains("[COMBO]") else { continue }
            guard let combo = jsonString(in: line, key: "combo") else { continue }
            out[combo] = jsonInt(in: line, key: "default") ?? 0
        }
        return out
    }

    private static func inlineIncludes(_ source: String, include: (String) -> String?, depth: Int) -> String {
        var seen = Set<String>()
        return inlineIncludes(source, include: include, depth: depth, seen: &seen)
    }

    /// G4 — **`#include` 는 이름 기준 include-once 다.** 실물(`wallpaper64.exe`, imagebase 0x140000000)의
    /// `Shader::resolveIncludes`(0x140162100-0x140162ab9)는 이미 인라인한 이름 목록을 선형 탐색해
    /// (0x1401624b0-0x1401624f4 `memcmp`) 걸리면 **그 줄을 건너뛴다**(0x14016250d → 0x1401627a4).
    /// 깊이 카운터는 없다 — 순환은 이 목록만으로 끊긴다. 목록은 스테이지마다 리셋된다
    /// (`Shader::loadAndPreprocess` 0x140162ee0/0x140162f2e 가 컨테이너를 새로 만든다) — 여기서도
    /// `preprocessStrict`/`inlinedSource` 가 스테이지마다 이 함수를 새로 부르므로 같은 범위다.
    ///
    /// **왜 필요한가**: 종전에는 깊이 16 캡만 있어 같은 헤더를 두 번 인라인했다. 헤더에 함수 정의가
    /// 있으면(동봉 `common*.h` 전건이 그렇다) 중복 인라인은 MSL `redefinition` 에러 = 셰이더 폴백이다.
    ///
    /// **도달(범위 라벨)**: 한 TU 안에서 같은 헤더가 두 번 닫히는 자산은 **설치본
    /// (`assets/` + `projects/`) 의 `.vert`/`.frag`/`.geom` 전수에서 0건**이다(재귀 인클루드 폐포를
    /// 실제로 돌려 실측). 즉 이 변경은 오늘 방출물을 **바꾸지 않고**(무회귀), 워크샵 셰이더 대비의
    /// 잠복 게이트다. 깊이 16 캡도 그대로 둔다 — include-once 로 순환은 이미 끊기지만, 병렬 분기가
    /// 깊게 중첩된 병리적 입력의 스택 방어로 남긴다.
    private static func inlineIncludes(_ source: String, include: (String) -> String?, depth: Int,
                                       seen: inout Set<String>) -> String {
        if depth > 16 { return source }
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#include") {
                if let name = firstQuoted(t) {
                    if !seen.insert(name).inserted {
                        // 이미 인라인한 이름 — 실물처럼 줄을 그냥 건너뛴다(에러도 경고도 아니다).
                    } else if let header = include(name) {
                        // 헤더 파일도 CRLF 일 수 있음 — 인라인 전 정규화.
                        let normalized = header.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
                        lines.append(inlineIncludes(normalized, include: include, depth: depth + 1, seen: &seen))
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
    private static func evaluateConditionals(_ source: String, defines: [String: Int]) -> String? {
        var d = defines
        var textDefines: [String: String] = [:]
        var funcMacros: [String: (params: [String], body: String)] = [:]
        var flagDefines = Set<String>()   // 값 없는 소스 #define — #ifdef 전용, 본문 "1" 치환 금지
        // F421: 비-10진 수치 리터럴 값 define(`#define X 0x10` 류) — #if 식에서 참조되면
        // 10진 파서로는 오평가이므로 그 #if 를 거부한다(본문 텍스트 치환은 기존대로 동작).
        var suspectDefines = Set<String>()
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

        // F610: 인덱스 루프 — 미지원 #if 식의 동일-분기 관용 판정에 전방 탐색(srcLines)이 필요.
        let srcLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var li = 0
        while li < srcLines.count {
            let line = srcLines[li]; li += 1
            var t = line.trimmingCharacters(in: .whitespaces)
            // 지시문 줄 트레일링 주석 제거 — `#if C_TYPE == 4 // 설명` 이 식 평가를 깨면
            // 관용 유지로 모든 분기가 방출된다(실물 frame_builder 의 offset 재정의 원인).
            // `/* */` 도 절단 — 잔존 시 ExprEval 이 `/`·`*` 를 연산자로 토큰화해 오평가(`#if AUDIO /* mic */`).
            // **[2026-08-21 정정] 실물은 절단이 아니라 "건너뛰고 계속" 이다.** `#if` 식 렉서
            // (0x140166a90-0x1401670ba)가 `/` 를 보면 `//` 는 줄 끝까지(0x140166b10-0x140166b26),
            // `/* */` 는 닫는 자리까지(0x140166b28-0x140166b74) 삼키고 **그 뒤부터 다시 렉싱한다.**
            // 즉 `#if A /* x */ == 1` 을 실물은 `A == 1` 로 보고 우리는 `A` 로 본다 — 값이 갈릴 수 있다.
            // `//` 는 어차피 줄 끝이라 결과가 같다. 동봉·설치본 자산에서 지시문 줄에 `/*` 가 오는
            // 경우는 **0건**(실측)이라 지금은 도달 없음. 고치려면 절단이 아니라 "구간 삭제" 여야 한다.
            if t.hasPrefix("#") {
                if let c = t.range(of: "//") { t = String(t[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
                if let c = t.range(of: "/*") { t = String(t[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
                // G4 — `# if COND` 처럼 `#` 와 키워드 사이에 공백이 있어도 실물은 **지시문으로 읽는다**:
                // 줄 인식 정규식이 `^\s*#\s*([a-z]+)\b\s*(.*)`(원본 파일오프셋 0x48be48, 그 직후에
                // SHADERVERSION/69/ifndef/ifdef/define/elif/if/endif/else/undef/require 문자열이 이어진다).
                // 아래 검사는 전부 `hasPrefix("#if ")` 류라 종전에는 이 형태를 **못 알아보고**
                // 지시문 줄을 본문으로 흘려보냈다 — 짝 `#endif` 만 소비돼 조건부가 어긋난다.
                // **아는 9종에만** 공백을 접는다. `# version 120` 같은 미지의 지시문은 실물도
                // 지시문으로 취급하지 않고 본문에 그대로 남기므로(0x14016c1f8 → 0x14016bbb0) 손대면 안 된다.
                // 동봉·설치본 자산에는 이 형태가 0건이다(실측) — 워크샵 셰이더 대비의 잠복 게이트.
                //
                // **[H1 2026-08-30] 같은 게이트가 한 글자 오른쪽에도 열려 있었다.** 위 G4 는 `#` 와
                // 키워드 **사이**의 탭만 접었는데, 정작 키워드 **뒤**의 탭은 접지 않았다. 아래 인식
                // 검사는 전부 `hasPrefix("#define ")` 류 리터럴 **한 칸 공백**이라
                // (`#if`/`#ifdef`/`#ifndef` · `#elif` · `#else` · `#endif` · `#undef` · `#define`
                // 분기) `#define\tMODE 2` 는 지시문으로 안 보이고 본문으로 흘렀다.
                // 9종 중 `#require` 만 `hasPrefix("#require\t")` 로 탭을 명시 처리하고
                // 있었던 것이 이 누락이 판단이 아니라 빠뜨림이라는 증거다.
                // 실측(컴파일 프로브): `#define\tMODE 2` + `#if MODE == 2` → FALSE_BRANCH(공백형은
                // TRUE_BRANCH) · `#undef\tK` 는 무동작(게다가 본문으로 흘러 `K`→`1` 매크로 치환까지
                // 먹어 `#undef\t1` 이 된다) · `#if 0/DEAD/#endif\tx/…` 는 프레임이 안 닫혀 그 뒤
                // **전부 소실**(공백형은 `EVERYTHING_AFTER MORE`).
                // 실물 줄 인식 정규식 `^\s*#\s*([a-z]+)\b\s*(.*)` 의 `\b\s*` 는 키워드 뒤 임의 공백을
                // 받으므로 탭 거부는 실물과의 이탈이다.
                // 접는 범위는 **탭이 든 구분자뿐**이다 — 구분자가 비었거나(`#if(cond)`: 아래 무공백
                // 기존 정규화 담당) 공백만이면 한 바이트도 건드리지 않는다. 동봉 WEAssets 502
                // 셰이더 + 형제 코퍼스 전수에서 탭형 도달 0건(실측)이라 자산 번역 결과는 불변이다.
                //   grep -rlE '^[ ]*#[ \t]*(if|ifdef|ifndef|elif|else|endif|define|undef|require)\t' → 0
                let rest = t.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                let known = Self.engineDirectives.first {
                    guard rest.hasPrefix($0) else { return false }
                    guard let n = rest.dropFirst($0.count).first else { return true }
                    return !(n.isLetter || n.isNumber || n == "_")
                }
                if let kw = known {
                    let after = rest.dropFirst(kw.count)
                    let sep = after.prefix(while: { $0 == " " || $0 == "\t" })
                    // 구분자에 탭이 없으면 종전 경로 그대로(`#if(` 는 sep 이 비어 여기 안 걸린다).
                    if sep.contains("\t") {
                        let arg = after.dropFirst(sep.count)
                        t = arg.isEmpty ? "#" + kw : "#" + kw + " " + arg
                    } else if t.dropFirst().first == " " || t.dropFirst().first == "\t" {
                        t = "#" + rest
                    }
                }
            }
            // `#if(cond)`/`#elif(cond)` — `#if`/`#elif` 뒤 공백 없이 `(` 가 오면 아래 prefix 검사가 놓쳐
            // 지시문이 MSL 에 그대로 방출되고 짝 `#endif` 만 소비돼 미종결 조건부가 된다(실물 halftone).
            // 공백을 끼워 정규화(다운스트림 dropFirst 카운트 불변).
            if t.hasPrefix("#if(") { t = "#if " + t.dropFirst(3) }
            else if t.hasPrefix("#elif(") { t = "#elif " + t.dropFirst(5) }
            // F611: 지시문 식의 후행 `;` 절단 — WE/C 전처리기는 관용(실물 simple_gradient_audio_bar 의
            // `#elif AUDIOSAMPLES == 32;`). ExprEval 은 `;` 를 미지원 문자로 거부하므로 절단으로
            // 달라지는 입력은 "종전 거부" 뿐이고 식의 값 자체는 불변.
            if t.hasPrefix("#if ") || t.hasPrefix("#elif ") {
                while t.hasSuffix(";") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
            }
            if t.hasPrefix("#if ") || t.hasPrefix("#ifdef ") || t.hasPrefix("#ifndef ") {
                let parentActive = emitting()
                var cond = false
                if t.hasPrefix("#ifdef ") { cond = isDefined(token(after: "#ifdef", t)) }
                else if t.hasPrefix("#ifndef ") { cond = !isDefined(token(after: "#ifndef", t)) }
                else {
                    let expr = String(t.dropFirst(3))
                    if let v = ExprEval.evalChecked(expr, defines: d, definedNames: definedNames(),
                                                    suspect: suspectDefines, textDefines: textDefines) {
                        cond = v != 0
                    } else if parentActive {
                        // F610: 미지원 식이지만 단순 #if/#else/#endif 형태에서 양 분기 텍스트가 동일하면
                        // 어느 분기를 택해든 출력이 같다 — 전량 폐기는 순손해(실물 lens_distorsion 의
                        // `#if g_Texture0Resolution.x < g_Texture0Resolution.y` uniform 멤버 비교).
                        // 분기가 다르거나 #elif/비정형 구조면 종전대로 거부("오역보다 폴터").
                        if hasIdenticalBranches(srcLines, from: li) {
                            cond = false
                        } else {
                            // F421: 활성 분기의 #if 가 미지원 식 — 어느 분기든 오역이므로 전처리 거부.
                            // (비활성 부모 안쪽은 출력에 무영향이라 관용 유지.)
                            WapleLog.warn("[Waple] GLSL #if unsupported expression, refusing shader: \(expr)")
                            return nil
                        }
                    }
                }
                stack.append(Frame(active: parentActive && cond, taken: cond, parentActive: parentActive))
            } else if t.hasPrefix("#elif ") {
                guard !stack.isEmpty else { continue }
                var f = stack.removeLast()
                var cond = false
                if !f.taken {
                    let expr = String(t.dropFirst(5))
                    if let v = ExprEval.evalChecked(expr, defines: d, definedNames: definedNames(),
                                                    suspect: suspectDefines, textDefines: textDefines) {
                        cond = v != 0
                    } else if f.parentActive {
                        // F421: #elif 도 동일 — 활성 체인의 미지원 식은 거부.
                        WapleLog.warn("[Waple] GLSL #elif unsupported expression, refusing shader: \(expr)")
                        return nil
                    }
                }
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
            } else if t == "#require" || t.hasPrefix("#require ") || t.hasPrefix("#require\t") {
                // [H1 2026-08-30] `#require\t` 는 위 키워드 뒤 탭 접기가 이미 `#require ` 로 정규화하므로
                // 이 세 번째 검사는 지금 도달하지 않는다. 남겨 두는 것은 접기 범위가 좁아지더라도
                // 이 지시문만은 종전대로 동작하게 하는 안전망이고(9종 중 유일하게 탭을 원래부터
                // 다뤘다), 지우면 그 이력이 사라진다.
                // G1 — `#require <Name>` 은 **지시문이 아니라 코드 생성기 호출**이다.
                // 실물(`wallpaper64.exe`, imagebase 0x140000000):
                //  · 지시문 인식 = 이름 길이 7 + `memcmp "require"`(0x14016c0ec).
                //  · 생성기 호출 `0x140169140(요청이름, 매크로맵, &out)`(0x14016c127). 결과가 **비어 있지
                //    않을 때만**(0x14016c12c `cmp qword [rbp+0x20], 0`) `std::string::insert`
                //    (0x14016c15c → 0x1400f9070)로 **그 줄 자리에 그대로 끼워 넣는다** — 파일 머리가
                //    아니다. 삽입 뒤 줄 시작/끝 포인터를 삽입 길이만큼 밀어(0x14016c16a-0x14016c18c)
                //    지시문 줄 자신은 뒤이어 공백으로 memset 된다(0x14016bc63-0x14016bc71, `bl=1` 은
                //    0x14016c1cc). 즉 **줄은 언제나 소비**되고, 주입은 그 자리에 선행한다.
                //  · 생성기(0x140169140-0x14016b0d4)의 **빈 문자열 반환 조건 3가지**(전부 0x14016b0b2
                //    로 점프 = out 을 손대지 않고 ret):
                //      (a) 요청 이름 길이 != 10 또는 `memcmp "LightingV1"` 불일치(0x1401691eb/0x1401691f5)
                //      (b) 매크로맵에 `LIGHTING` 이 **없다**(0x1401691b8 조회 → 0x14016920c `cmp rbx, r12`)
                //      (c) `LIGHTING` 의 값 문자열을 정수로 읽어(0x140169223) **0 이면**(0x14016922a)
                //    → **미지의 이름도, `LIGHTING` 이 0/미정의여도 아무것도 주입하지 않고 줄만 삼킨다.**
                //  · `LIGHTING != 0` 일 때 주입하는 것: `uniform vec4 g_LPoint_Color[N];` 류 라이트 배열
                //    선언(0x140169573-0x140169b4f, 길이 N 은 `LIGHTS_POINT`/`LIGHTS_SPOT`/`LIGHTS_TUBE`/
                //    `LIGHTS_DIRECTIONAL` 등 매크로맵 값)과 `vec3 PerformLighting_V1(...)`(0x14048c070)
                //    본문 — 라이트마다 `const uint i = <n>u;` 로 **언롤**한 `ComputePBRLightShadow` 누적.
                //  · **emitting 가드가 없다**: 형제 `#define`(0x14016b8f7)·`#undef`(0x14016c215)는
                //    `test r13b, r13b` 로 비활성 분기를 건너뛰는데 `#require` 경로에는 그 검사가 없다.
                //    즉 거짓 `#if` 안의 `#require` 도 실물은 주입한다(동봉 도달: genericparticle.frag:68 ·
                //    genericropeparticle.frag:56 의 depth 1 — 둘 다 Waple 은 네이티브 레인이라 무해).
                //    여기서도 `emitting()` 을 보지 않고 무조건 소비해 같은 형태를 유지한다.
                //
                // Waple 이 하는 것: **줄을 소비만 한다.** 주입은 하지 않는다 — 근거는 아래 [미해결].
                // 종전에는 마지막 `else if emitting()` 로 떨어져 줄이 본문에 남았다. 그 잔재가 MSL 을
                // 깨지는 않았다(GLSLTranslator 는 파스된 선언·함수만 조립해 방출한다 — :2059 — 인식
                // 못 한 최상위 줄은 어디에도 안 실린다. 실측: 동봉 239쌍 × 3구성에서 `#require` 방출 0건).
                // 그래도 소비로 바꾸는 이유는 셋이다: (a) 실물과 형태가 같아지고, (b) 번역기 조립부가
                // 관대해서 우연히 안 새던 것을 명시 계약으로 바꾸며, (c) 아래 회귀 린트의
                // `require` 패턴이 "잠복" 이 아니라 "여기서 소비된다" 는 뜻이 된다.
                //
                // **[미해결] `LIGHTING != 0` 일 때의 주입은 구현하지 않았다.** 주입하려면 라이트 배열
                // 유니폼(`g_LPoint_*`/`g_LSpot_*`/`g_LTube_*`/`g_LDirectional_*`/`g_LFeature_*`)을
                // 렌더러가 씬 라이트로 채워야 하는데 그 바인딩은 GLSL 레인에 없다(WapleRender 의
                // 유니폼 빌더 소관 — 이 파일 밖). `LIGHTS_*` 매크로도 시딩되지 않아 지금 주입하면
                // 길이 0 배열 + `return CAST3(0.0)` = **조용히 검은 라이팅**이 된다("오역보다 폴터" 위반).
                // 그래서 소비만 하고, 실물이 주입했을 자리에서는 경고를 남긴다 → 호출부 참조가
                // 미정의로 남아 MSL 컴파일이 실패하고 이펙트가 폴백한다(= 지금과 같은 결말, 다만 시끄럽게).
                // 판정: **소비만으로 조용히 틀린 그림이 되지는 않는다.** `LIGHTING == 0`(동봉 GLSL 레인
                // 도달 유일건 fluidsimulation_combine 의 기본값)에서는 실물도 주입하지 않으므로 소비가
                // 정확히 일치하고, `LIGHTING != 0` 에서는 `PerformLighting_V1` 호출부가 남아 컴파일이
                // 확정 실패한다(조용한 오답이 아니라 폴백).
                let requested = token(after: "#require", t)
                if requested == "LightingV1", let lighting = d["LIGHTING"], lighting != 0 {
                    WapleLog.warn("[Waple] GLSL #require LightingV1 (LIGHTING=\(lighting)): "
                                  + "PerformLighting_V1 주입 미구현 — 소비만 한다(호출부는 미정의로 남는다)")
                }
                // 주입 여부와 무관하게 줄은 삼킨다(실물 0x14016bc63 의 공백 memset 과 같은 결말).
            } else if t.hasPrefix("#undef ") {
                if emitting() {
                    let name = token(after: "#undef", t)
                    d.removeValue(forKey: name)
                    textDefines.removeValue(forKey: name)
                    funcMacros.removeValue(forKey: name)
                    flagDefines.remove(name)
                    suspectDefines.remove(name)
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
                        if let v = Int(value) {
                            d[name] = v
                        } else if let v = parenthesizedDecimalInt(value) {
                            // F422: `#define MODE (2)` — 괄호 감싼 10진 정수도 #if 평가값으로 등록.
                            // (종전 Int("(2)") == nil → d 미등재라 #if MODE 는 0 인데 본문 치환은 "(2)" 라 불일치.)
                            d[name] = v
                        } else if let v = ExprEval.numericLiteral(value) {
                            // G2: `#define X 0x10` / `1u` / `2UL` — 실물 렉서(0x140166f90-0x14016708b)가
                            // 아는 수치 리터럴 문법이므로 여기서도 값으로 등록한다. 종전에는 아래
                            // suspect 로 몰려 이 이름을 쓰는 `#if` 가 통째로 거부됐다(= 이펙트 폴백).
                            d[name] = v
                        } else if value.first?.isNumber == true {
                            // F421: 숫자로 시작하지만 위 어느 문법도 아닌 값(`1e5` 류 지수 표기) —
                            // #if 에서 참조 시 오평가 방지를 위해 거부 대상으로 표시.
                            // **[BK 2026-08-21] `1.5` 는 더 이상 여기 안 온다** — 실물 렉서가 소수부를
                            // 읽고 버려 1 로 보는 것을 확정해(0x140167021-0x140167046) 위
                            // `ExprEval.numericLiteral` 가 값 1 로 받는다. 남은 거부는 실물이
                            // **수로도 안 읽는** 형태뿐이다(`1e5` = 수 `1` + 식별자 `e5` → 잔여 토큰).
                            suspectDefines.insert(name)
                        }
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
                            // 중복 키는 **뒤가 이긴다**(uniquingKeysWith). `#define FOO(a,a)` 는 애초에
                            // 불법 GLSL 이지만, pkg 안의 셰이더는 신뢰 경계 밖이라 파서가 죽는 대신
                            // 뭐라도 내야 한다 — 종전 `uniqueKeysWithValues` 는 그 입력에서 그대로 트랩했다.
                            // 형제 `PropertyConditionEvaluator.isVisible` 이 2026-08 에 같은 이유로
                            // 같은 선택(`uniquingKeysWith: { _, later in later }`)을 했는데 이 자리로
                            // 오지 않았다(수정의 전파 누락).
                            // (r3-M55 정정: 종전 인용 `PropertyConditionEvaluator.swift:12` 는
                            //  AngularJS 문법 우선순위 사슬 주석이라 `uniquingKeysWith` 와 무관했다.
                            //  같은 무효 인용이 `WebRenderer.swift` 와 `ShaderPreprocessorTests.swift`
                            //  에도 있었다 — 세 자리 모두 심볼 인용으로 바꿨다.)
                            return GLSLTranslator.replaceIdentifiers(
                                m.body,
                                Dictionary(zip(m.params, args), uniquingKeysWith: { _, later in later }))
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

    /// F610: `lines[from…]` 에서 현재 #if 와 같은 깊이의 #else/#endif 를 찾아 양 분기 텍스트가
    /// 동일한지 비교(동일하면 어느 분기든 출력이 같아 관용 가능). 안쪽 중첩은 깊이로 건어너뛰고,
    /// 깊이-0 #elif(다분기)/짝 #endif 미발견 등 비정형은 false(보수적 — 거부로 회귀).
    private static func hasIdenticalBranches(_ lines: [String], from start: Int) -> Bool {
        var depth = 0
        var elseIdx: Int? = nil
        var i = start
        while i < lines.count {
            let lt = lines[i].trimmingCharacters(in: .whitespaces)
            if lt.hasPrefix("#endif") {
                if depth == 0 {
                    let a = lines[start..<(elseIdx ?? i)]
                    let b = elseIdx.map { lines[($0 + 1)..<i] } ?? []
                    return a.elementsEqual(b)
                }
                depth -= 1
            } else if lt.hasPrefix("#if") {          // #if/#ifdef/#ifndef/#if( 공통 오프너
                depth += 1
            } else if depth == 0, lt.hasPrefix("#elif") {
                return false                          // 다분기 비교는 미지원(보수)
            } else if depth == 0, lt.hasPrefix("#else"), elseIdx == nil {
                elseIdx = i
            }
            i += 1
        }
        return false
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

    /// S2-shaderlab: 단어 경계 참조 판별 — 단순 `String.contains` 부분일치는 `CAST4`⊂`CAST4U`,
    /// `CAST2`⊂`CAST2X2`류를 오매치한다(현재는 둘 다 우리 주입 목록에 공존 — CAST4/CAST4U 신규 추가로
    /// 실제 충돌 표면이 생겼다). `\b` 는 앞뒤가 식별자 문자(영문/숫자/`_`)가 아닐 때만 성립해
    /// "CAST4U" 안의 "CAST4" 는 경계 미성립으로 제외된다.
    static func identifierReferenced(_ name: String, in source: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// S2-shaderlab: `#define NAME` 선행 정의 판별(경계 인지) — `#define CAST4U` 를 `#define CAST4`
    /// 정의로 오인해 실제로 미정의인 CAST4 주입을 스킵하는 것 방지.
    static func identifierDefined(_ name: String, in source: String) -> Bool {
        let pattern = "#define\\s+\(NSRegularExpression.escapedPattern(for: name))\\b"
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// F422: `#define MODE (2)` / `((3))` — 바깥 괄호로 감싼 정수 리터럴을 벗겨 파스.
    /// 괄호가 아니거나 안쪽이 정수가 아니면 nil(`(2)+(3)` 등).
    /// G2: 안쪽은 10진뿐 아니라 실물 문법(16진·`u`/`f`/`l` 접미)도 받는다 — `(0x10)`.
    private static func parenthesizedDecimalInt(_ value: String) -> Int? {
        var v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("(") else { return nil }
        while v.hasPrefix("("), v.hasSuffix(")") {
            v = v.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        }
        return Int(v) ?? ExprEval.numericLiteral(v)
    }

    /// 지시문 인자 이름 한 토큰 추출(`#ifdef`/`#ifndef`/`#undef`/`#require`).
    ///
    /// **[H2 2026-08-30] 종전에는 `split(separator: " ")` 로 리터럴 한 칸 공백만 구분자로 봤다.**
    /// 그래서 `#ifdef HQ\tenable hq` 의 이름이 `"HQ\tenable"` 로 나와 어떤 define 키에도 안 맞고
    /// `isDefined` 가 false — 지시문 인식은 성공했으므로 **아무 것도 새지 않고 조용히 반대 분기**를
    /// 골랐다(실측 프로브: FALSE_BRANCH, 공백형은 TRUE_BRANCH. `#undef K\ttrailing` 은 무동작).
    /// 위 `#` 뒤 **탭 접기**(H1 — `let rest = t.dropFirst().drop(while: …)` 블록)로는 닫히지 않는다.
    /// 그쪽은 **키워드 뒤** 구분자를 고치고, 이건 **인자 뒤** 구분자 문제라 접기 뒤에도 남는다.
    /// 같은 뿌리(공백)지만 실패 지점이 다르다.
    /// (r2-4.1-lane4 정정: 종전 인용 `:261` 은 그 접기 코드가 아니었다 — 자기참조 줄 번호가
    ///  썩은 자리라 심볼·코드 인용으로 바꿨다.)
    /// 실물 줄 인식 정규식 `^\s*#\s*([a-z]+)\b\s*(.*)`(이 파일 헤더 주석에 인용)의 `\s*` 가 탭을
    /// 포함하므로 임의 공백 분리가 실물 형태다.
    ///
    /// **범위 주의 — 이것은 트레일링 주석과 무관하다.** `#ifdef HQ\t// comment` 는 `#` 줄의
    /// 주석 절단이 먼저 돌아 종전에도 **올바른** 분기를 골랐다(실측 TRUE_BRANCH). 살아 있던 형태는
    /// 탭 + 비주석 트레일러뿐이다. 동봉 WEAssets + 형제 코퍼스 전수 실측 도달 **0건** —
    ///   grep -rlE '^[ ]*#[ \t]*(ifdef|ifndef|undef)[ \t]+[A-Za-z_][A-Za-z0-9_]*\t' → 0
    /// 즉 오늘 시점 자산 번역 결과는 불변이고, 고치는 이유는 `#define`(그 분기의
    /// `let nameEnd = decl.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "\t" })` 가 `\t` 를
    /// 이미 구분자로 포함한다. 종전 인용 `:401` 은 무관한 줄이었다 — r2-4.1-lane4)·
    /// `#require` 와의 일관성이다.
    private static func token(after kw: String, _ line: String) -> String {
        line.dropFirst(kw.count).trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
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

    /// WE 컴파일러 내장 캐스트/샘플러 매크로 — 소스가 자체 정의하면 그것이 우선(부재 시에만 주입).
    /// S2-shaderlab①: WE 바이너리 셰이더 shim 전수 대조 8종 + 로컬 확장 2종 + 샘플러 전달 매크로 4종.
    /// CASTU/CASTI/CASTF 는 스칼라라 MSL 생성자 스펠링 동일 — 별도 치환 불요.
    /// DECLARE_SAMPLER2D_PARAMETER/MAKE_SAMPLER2D_ARGUMENT: 텍스처/샘플러를 Waple MSL 규약에 맞게
    /// `sampler2D t` / `t` 로 전개.
    /// [2026-08-21 정정] COMPARE 계열은 종전 `sampler2D t` 로 전개했고 주석은 "SampleCmp 미지원 —
    /// 사용 시 번역 실패 폴터, 선언만 수용" 이었다. `texSample2DCompare` 재작성이 들어오면서
    /// 그 전제가 깨진다 — 헬퍼 파라미터가 `texture2d<float>` 로 방출되면 `sample_compare` 가 없어
    /// 컴파일이 터진다. 비교 샘플러 전용 타입으로 전개해 `depth2d<float>` 파라미터가 되게 한다
    /// (실물 소비처: `shaders/common_pbr_2.h:75,80-83` 의 PerformShadowMapping 계열).
    private static let builtinCastMacros: [(String, String)] = [
        ("CAST2", "vec2(x)"), ("CAST3", "vec3(x)"), ("CAST4", "vec4(x)"),
        ("CAST2X2", "mat2(x)"), ("CAST3X3", "we_cast3x3(x)"), ("CAST4X4", "mat4(x)"),
        ("CASTI", "int(x)"), ("CASTU", "uint(x)"), ("CASTF", "float(x)"), ("CAST4U", "uint4(x)"),
        ("DECLARE_SAMPLER2D_PARAMETER", "sampler2D x"),
        ("MAKE_SAMPLER2D_ARGUMENT", "x"),
        ("DECLARE_SAMPLER2D_COMPARE_PARAMETER", "sampler2DComparison x"),
        ("MAKE_SAMPLER2D_COMPARE_ARGUMENT", "x"),
    ]
}

/// `#if` 식 평가기. **안전**: 임의 코드 실행이 아니라 직접 작성한 재귀하강 정수 파서다.
/// 정수 리터럴(10진·16진·`u`/`f`/`l` 접미) + 식별자(defines 룩업, 미정의=0) + `defined()` +
/// `!  ~  *  /  %  +  -  <<  >>  <  >  <=  >=  ==  !=  &  ^  |  &&  ||` + 괄호만 다룬다.
/// 함수 호출/문자열/부수효과 없음 → 셰이더 입력으로부터 코드 인젝션 불가.
///
/// **우선순위와 토큰 집합은 실물 렉서·파서에서 그대로 뜬 것이다**(`wallpaper64.exe`, imagebase
/// 0x140000000). 렉서 0x140166a90-0x1401670ba, 파서는 느슨→촘촘 순으로 한 단계씩 함수가 있다:
///
/// | 단계 | 실물 VA | 토큰(코드) |
/// |---|---|---|
/// | `\|\|`            | 0x1401670d0 | 0xd |
/// | `&&`              | 0x140167390 | 0xc |
/// | `\|`              | 0x140167520 | 0x14 |
/// | `^`               | 0x1401675e0 (같은 함수에 `&` 인라인) | 0x15 |
/// | `&`               | 0x1401675e0 | 0x13 |
/// | `==` `!=`         | 0x140167680 (`lea edx,[rbp-6]; cmp edx,1`) | 6·7 |
/// | `<` `<=` `>` `>=` | 0x140167850 (`lea ecx,[rbx-8]; cmp ecx,3`) | 8·9·0xa·0xb |
/// | `<<` `>>`         | 0x1401679d0 (`lea edx,[r13-0x17]; cmp edx,1`) | 0x17·0x18 |
/// | `+` `-`           | 0x140167ad0 (`lea ecx,[rbp-0xe]; cmp ecx,1`) | 0xe·0xf |
/// | `*` `/` `%`       | 0x140167b80 (`lea eax,[rdi-0x10]; cmp eax,2`) | 0x10·0x11·0x12 |
/// | 단항·원자          | 0x140167c00 | `!`(5) `~`(0x16) `-`(0xf) `+`(0xe) 수(1) 이름(2) `(`(3) |
///
/// 즉 **C 와 같은 사슬**이다(종전 Waple 은 `==`/`!=` 와 비교를 한 단계로 뭉쳤고 비트·시프트·`%`
/// 가 아예 없었다). 삼항 `?:` 는 실물에도 없다 — `?`/`:` 는 렉서에서 "그 외 문자"(0x19)로 떨어진다.
///
/// **산술 폭은 32비트다.** 실물은 전 구간 `eax`/`esi` 로 돌린다(`imul ebx,ecx`@0x140167bc2,
/// `idiv`@0x140167bd3, `and esi,eax`@0x140167610, `xor esi,edi`@0x14016765a, `not eax`@0x140167e04,
/// `neg eax`@0x140167de2). 여기서는 **새로 넣는 비트·시프트·`~` 만** `Int32` 로 절단해 맞춘다 —
/// 기존 `+ - * /` 는 종전 `Int` 랩핑 그대로 둔다(값 도메인이 콤보 정수라 실측 차이 0, 무회귀 우선).
/// 0 나눗셈은 실물도 트랩이 아니라 **0**(0x140167bcc-0x140167be9 `test ecx,ecx; je → xor ebx,ebx`) —
/// 종전 Waple 규약과 같다. `%` 도 같은 가드를 공유한다.
enum ExprEval {
    /// 실물이 32비트로 도는 자리(비트·시프트·`~`·리터럴 누적)의 폭 맞춤. 둘 다
    /// `truncatingIfNeeded:` 라 **트랩이 원리적으로 불가능**하다 — 셰이더 소스는 신뢰 경계 밖이고
    /// `Int32(_:)`/`Int(_:)` 맨 이니셜라이저는 범위를 넘으면 클램프가 아니라 크래시다.
    /// (`wide` 는 Int32→Int 확대라 절단이 일어날 수 없지만, 좁힘 인구조사 게이트가 맨 `Int(` 를
    /// 세므로 같은 라벨을 달아 의도를 코드에 적어 둔다.)
    private static func w32(_ v: Int) -> Int32 { Int32(truncatingIfNeeded: v) }
    private static func wide(_ v: Int32) -> Int { Int(truncatingIfNeeded: v) }

    /// 관용 래퍼(기존 호환): 거부 대상 식은 0. 파이프라인(#if/#elif)은 evalChecked 를 써야 한다.
    static func eval(_ expr: String, defines: [String: Int], definedNames: Set<String>? = nil) -> Int {
        evalChecked(expr, defines: defines, definedNames: definedNames) ?? 0
    }

    /// 엄격 평가 — 미지원 패턴이면 nil(분기 선택 거부). F421: 종전에는 미지 문자를 조용히 버리고
    /// 잔여 토큰도 무시해 `#if A % 2`→A, `#if 0x10`→0 처럼 오분기가 "성공"으로 빠졌다.
    /// **[G2] 거부 규약은 유지하되 아는 문법을 넓혔다.** 이제 거부는 이것뿐이다:
    /// 렉서가 모르는 문자(`? : ; @ …`)·수로 못 읽는 수치 define(suspect) 참조·잔여 토큰.
    /// (`.` 는 수 리터럴의 일부일 때는 소비된다 — `weNumericLiteral` 주석 참조. 수 밖의 `.` 만 미지 문자다.)
    /// (`% & | ^ ~ << >>`·16진/접미 리터럴은 **더 이상 거부가 아니라 평가**된다 — 실물과 같게.)
    static func evalChecked(_ expr: String, defines: [String: Int], definedNames: Set<String>? = nil,
                            suspect: Set<String> = [], textDefines: [String: String] = [:],
                            macroDepth: Int = 0) -> Int? {
        let lexed = tokenize(expr)
        guard !lexed.unsupported else { return nil }
        let toks = lexed.tokens
        let knownNames = definedNames ?? Set(defines.keys)
        var pos = 0
        var failed = false   // suspect define 참조 — 값은 내지만 결과는 nil 로 거부
        // 중첩 깊이(괄호 `(`·단항 `!`/`-`/`~` 재귀 공용) — 악성 중첩 입력(`#if ((((…))))`)의 스택
        // 오버플로 방지. 256 은 SceneDocument.world() 의 32 캡을 본떴으되 넉넉히 잡음(실제 식은 10 미만 중첩).
        var depth = 0
        let maxDepth = 256
        func peek() -> String? { pos < toks.count ? toks[pos] : nil }
        func next() -> String? { defer { pos += 1 }; return peek() }

        func parsePrimary() -> Int {
            depth += 1
            defer { depth -= 1 }
            guard depth <= maxDepth else { return 0 }   // 캡 초과 — 그레이스풀 0(미정의 취급), 크래시 대신
            guard let t = next() else { return 0 }
            if t == "(" { let v = parseOr(); if peek() == ")" { pos += 1 }; return v }
            if t == "!" { return parsePrimary() == 0 ? 1 : 0 }
            if t == "~" { return wide(~w32(parsePrimary())) }   // 실물 `not eax`(0x140167e04)
            if t == "-" { return 0 &- parsePrimary() }  // 랩핑 — defines 에 Int.min 이 실릴 수 있음
            if t == "+" { return parsePrimary() }       // 실물 0x140167c29: 단항 `+` 는 그냥 통과
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
            if suspect.contains(t) { failed = true; return 0 }  // `#define X 1.5` 류 — 10진 평가 불가
            if let v = defines[t] { return v }
            // G5 — **실물은 `#if` 식 안에서도 매크로를 확장한다.** 확장은 파서가 아니라 **렉서**가 한다:
            // 식별자를 매크로맵에서 찾으면(0x140166c39-0x140166cb1) 본문 포인터를 스택에 밀고
            // (0x140166cc1-0x140166db7 `inc dword [rbx+0x40]`) 그 자리에서 **재렉싱**하며, 본문이
            // 끝나면 팝한다(0x140166ada-0x140166af7 `dec`). 깊이 캡은 **0x63 = 99**
            // (0x140166cb7 `cmp dword [rbx+0x40], 0x63; jge` → 넘으면 그냥 식별자 토큰(2)).
            // 그래서 `#define A B` + `#define B 1` 에서 `#if A` 가 실물은 **참**이다.
            // 종전 Waple 은 정수 값 맵(`d`)만 봐서 이런 이름을 전부 **0** 으로 읽었다.
            // 여기서 본문을 재귀 평가해 같은 결말로 맞춘다. 본문이 식으로 안 읽히면 **0**
            // (실물도 미지 식별자를 0 으로 보고 잔여 토큰은 그냥 버린다 — 거부가 아니다).
            // 동봉·설치본 자산에서 `#if` 가 비-정수 object-like 매크로를 참조하는 경우는 **0건**(실측)
            // 이라 도달은 워크샵 셰이더뿐이다.
            if let body = textDefines[t], macroDepth < 99 {
                var inner = textDefines
                inner.removeValue(forKey: t)   // 자기 참조(`#define A A`) 무한재귀 차단
                return evalChecked(body, defines: defines, definedNames: knownNames,
                                   suspect: suspect, textDefines: inner, macroDepth: macroDepth + 1) ?? 0
            }
            return 0
        }
        // 산술은 랩핑(&*, &+, &-) + 나눗셈 트랩 가드 — #if 는 분기 결정만 하면 되므로 근사면 충분하고,
        // 악성 리터럴(`#if 9223372036854775807+1`)의 오버플로 트랩(크래시) 방지가 우선.
        func parseMul() -> Int {
            var v = parsePrimary()
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                pos += 1; let r = parsePrimary()
                switch op {
                case "*": v = v &* r
                // 실물 0x140167bcc/0x140167bdc: 제수 0 이면 idiv 를 아예 안 돌고 결과 0.
                case "/": v = r == 0 ? 0 : (v == Int.min && r == -1 ? 0 : v / r)
                default:  v = r == 0 ? 0 : (v == Int.min && r == -1 ? 0 : v % r)
                }
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
        // 실물 0x140167a8e: `cmp ebp, 0x1f; ja → 결과 0`. **부호 없는 비교**라 음수 시프트량도 0 이다.
        // 그 밖에는 `shl`(<<) / `sar`(>>, 산술) 32비트.
        func parseShift() -> Int {
            var v = parseAdd()
            while let op = peek(), op == "<<" || op == ">>" {
                pos += 1; let r = parseAdd()
                if r < 0 || r > 31 { v = 0 }
                else { v = wide(op == "<<" ? w32(v) << w32(r) : w32(v) >> w32(r)) }
            }
            return v
        }
        func parseRel() -> Int {
            var v = parseShift()
            while let op = peek(), ["<", ">", "<=", ">="].contains(op) {
                pos += 1; let r = parseShift()
                switch op {
                case "<": v = v < r ? 1 : 0
                case ">": v = v > r ? 1 : 0
                case "<=": v = v <= r ? 1 : 0
                default: v = v >= r ? 1 : 0
                }
            }
            return v
        }
        func parseEq() -> Int {
            var v = parseRel()
            while let op = peek(), op == "==" || op == "!=" {
                pos += 1; let r = parseRel(); v = (op == "==" ? v == r : v != r) ? 1 : 0
            }
            return v
        }
        func parseBitAnd() -> Int {
            var v = parseEq()
            while peek() == "&" { pos += 1; let r = parseEq(); v = wide(w32(v) & w32(r)) }
            return v
        }
        func parseBitXor() -> Int {
            var v = parseBitAnd()
            while peek() == "^" { pos += 1; let r = parseBitAnd(); v = wide(w32(v) ^ w32(r)) }
            return v
        }
        func parseBitOr() -> Int {
            var v = parseBitXor()
            while peek() == "|" { pos += 1; let r = parseBitXor(); v = wide(w32(v) | w32(r)) }
            return v
        }
        func parseAnd() -> Int {
            var v = parseBitOr()
            while peek() == "&&" { pos += 1; let r = parseBitOr(); v = (v != 0 && r != 0) ? 1 : 0 }
            return v
        }
        func parseOr() -> Int {
            var v = parseAnd()
            while peek() == "||" { pos += 1; let r = parseAnd(); v = (v != 0 || r != 0) ? 1 : 0 }
            return v
        }
        let value = parseOr()
        // 잔여 토큰(`#if 1 0`·`A -> 2`·`#if 1e5` 류)도 오평가 신호 — 전량 소비됐을 때만 유효 평가.
        // 실물은 잔여를 그냥 버리지만(관용) 여기서는 "오역보다 폴터" 규약대로 거부한다.
        guard !failed, pos == toks.count else { return nil }
        return value
    }

    /// WE 수치 리터럴 문법(렉서 0x140166f90-0x14016708b)으로 `chars[i...]` 를 읽는다.
    /// - `0x`/`0X` 접두(0x140166f9c `add al,0xa8; test al,0xdf` = `x`/`X` 판정) → 16진 누적
    ///   `esi = esi*16 + digit`(0x140166fe7).
    /// - 그 밖엔 10진 누적 `esi = esi*10 + digit`(0x140167007-0x140167019).
    /// - 정수부 뒤에 `.` 이 오면 **소수점과 소수부를 읽고 버린다**(누적기를 안 건드린다) —
    ///   즉 `#if 1.5` 는 **1** 이다. [BK 2026-08-21 해소] 실물을 직접 다시 떠서 확정했다
    ///   (`0x140167021 cmp byte ptr [rax], 0x2e` → `0x140167026 inc rax`(무조건 소비) →
    ///   `0x140167031`-`0x140167046` 가 `isdigit` 인 동안 포인터만 전진, `esi` 미변경).
    ///   `.` 뒤에 숫자가 없어도 `.` 자체는 소비된다(`#if 1.` = 1, `#if 1.x` = 1 + 식별자 `x`).
    ///   **종전에는 흉내내지 않고 `.` 를 모르는 문자로 남겨 식을 거부했다**("오역보다 폴터").
    ///   뒤집는 근거 셋: (a) 실물 동작이 **측정으로 확정**돼 추정이 아니다 — "오역보다 폴터" 는
    ///   *모르는* 문법에 대한 규약이지 *아는* 문법에 대한 것이 아니고, 거부는 이제 실물과 갈리는
    ///   쪽이다. (b) 회귀 폭 0 — `#if`/`#elif` 식 안의 소수 리터럴도, `#define NAME <비정수 수치>`
    ///   를 `#if` 가 참조하는 자리도 **설치본(`assets/` + `projects/`) 전수에서 0건**이다(실측).
    ///   (c) 이 확장이 없으면 워크샵 셰이더의 `#define BLUR 1.5` 한 줄이 **이펙트 전체를 폴백**시킨다.
    ///   `1e5` 같은 지수 표기는 여전히 거부다 — 실물도 `1` 에서 수를 끊고 `e5` 를 식별자 토큰으로
    ///   내는데, 우리는 그 **잔여 토큰**을 거부하기 때문이다(그 규약은 그대로 유지, §10.9 참조).
    /// - 뒤이어 `u`/`f`/`l`(대소문자 무관, 0x140167058/68/78) 접미를 **여러 개** 소비한다.
    /// - 누적은 실물과 같이 32비트 랩핑(`Int32`) — `0xFFFFFFFF` 는 실물에서 -1 이다.
    /// 반환: (값, 다음 인덱스).
    private static func weNumericLiteral(_ chars: [Character], _ start: Int) -> (value: Int, next: Int)? {
        // 실물은 `isdigit`/`isxdigit`(ASCII) 로 판정한다 — Swift 의 `isNumber`/`hexDigitValue` 는
        // 유니코드 숫자(전각·아라비아-인도 숫자 등)까지 먹으므로 ASCII 로 좁힌다. 좁힌 결과
        // 그런 문자는 아래 토크나이저에서 "모르는 문자"로 떨어져 식이 거부된다(보수적 = 실물과 같은 결말).
        func asciiDigit(_ c: Character, radix: Int) -> Int? {
            guard c.isASCII, let v = c.hexDigitValue, v < radix else { return nil }
            return v
        }
        var i = start
        guard i < chars.count, asciiDigit(chars[i], radix: 10) != nil else { return nil }
        var acc: Int32 = 0
        if chars[i] == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
            i += 2
            while i < chars.count, let d = asciiDigit(chars[i], radix: 16) {
                acc = acc &* 16 &+ w32(d); i += 1
            }
        } else {
            while i < chars.count, let d = asciiDigit(chars[i], radix: 10) {
                acc = acc &* 10 &+ w32(d); i += 1
            }
        }
        // 소수부: `.` 은 **무조건** 소비하고(실물 0x140167026 이 isdigit 검사 전에 inc 한다),
        // 이어지는 숫자도 소비하되 **값에는 안 넣는다**(실물 0x140167031-0x140167046 은 `esi` 를
        // 안 건드린다). **16진 분기도 여기로 온다** — 실물의 16진 루프 출구가 `0x140166ff1 jmp
        // 0x14016701e` 로 바로 이 `.` 검사에 합류한다(즉 `#if 0x10.5` = 16). 이 합류를 놓치고
        // 10진 분기 안에만 넣으면 16진에서 갈린다.
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, asciiDigit(chars[i], radix: 10) != nil { i += 1 }
        }
        while i < chars.count, "uUfFlL".contains(chars[i]) { i += 1 }
        return (wide(acc), i)
    }

    /// 문자열 **전체**가 하나의 WE 수치 리터럴일 때 그 값. `#define X 0x10` 을 `#if` 평가값으로
    /// 등록하기 위한 진입점(종전엔 suspect 로 몰아 그 `#if` 를 통째로 거부했다).
    static func numericLiteral(_ s: String) -> Int? {
        let chars = Array(s.trimmingCharacters(in: .whitespaces))
        guard let r = weNumericLiteral(chars, 0), r.next == chars.count else { return nil }
        return r.value
    }

    private static func tokenize(_ s: String) -> (tokens: [String], unsupported: Bool) {
        var toks: [String] = []
        let chars = Array(s)
        var i = 0
        var unsupported = false
        // 2글자 토큰은 1글자보다 **먼저** 본다 — `<<` 가 `<`+`<` 로 쪼개지면 `A << 2` 가 `A < 0` 처럼
        // 오평가된다(F421 이 종전에 시프트를 통째로 거부한 이유). 이제 쪼개지 않고 제대로 읽는다.
        let two: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "<<", ">>"]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if i + 1 < chars.count, two.contains(String([c, chars[i + 1]])) {
                toks.append(String([c, chars[i + 1]])); i += 2; continue
            }
            // 1글자 연산자 — `%`·비트(`& | ^ ~`)가 여기 들어오면서 "모르는 문자" 거부에서 빠졌다.
            if "()!*/%+-<>&|^~".contains(c) { toks.append(String(c)); i += 1; continue }
            if c.isLetter || c == "_" {
                var id = ""; while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { id.append(chars[i]); i += 1 }
                toks.append(id); continue
            }
            if c.isNumber {
                // 16진/접미 리터럴을 실물 문법대로 읽는다. 접미가 아닌 글자가 붙으면(`1e5`) 수는
                // 거기서 끝나고 나머지는 식별자 토큰이 된다 — 실물과 같고, 그 결과 잔여 토큰이
                // 생겨 위 `pos == toks.count` 가 거부한다(종전의 명시 거부와 결말 동일).
                guard let r = weNumericLiteral(chars, i) else { unsupported = true; i += 1; continue }
                toks.append(String(r.value)); i = r.next; continue
            }
            // 렉서가 모르는 문자(`?` `:` `@` `;` 등 — 실물 토큰 코드 0x19). 수 리터럴 안의 `.` 는
            // 위 `weNumericLiteral` 가 이미 먹었으므로 여기 오는 `.` 는 수 밖의 것뿐이다(실물도 0x19).
            unsupported = true
            i += 1
        }
        return (toks, unsupported)
    }
}
