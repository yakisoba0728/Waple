import XCTest
@testable import WapleCore

/// **동봉 셰이더 전건 GLSL→MSL 번역 회귀.**
///
/// 왜 있는가
/// ---------
/// 종전 번역기 테스트는 전부 **합성 입력**이었다(`GLSLTranslatorTests` 68건 · `GLSLShimGapTests` 8건).
/// 합성 입력은 "이 구문을 이렇게 번역한다"는 계약은 지켜 주지만, **어떤 구문이 남아 있는지**는
/// 알려 주지 않는다 — 아무도 쓰지 않는 테스트를 통과시키며 실물의 구멍을 못 본다.
/// 이 클래스는 반대 방향이다: 동봉 자산 트리의 `.vert`/`.frag` **쌍 전건**을 실제로 번역하고,
/// 방출된 MSL 에 GLSL/HLSL 방언 토큰이 남았는지 훑는다.
///
/// 무엇을 확정하고 무엇을 못 하나
/// -----------------------------
/// - **확정**: 번역기가 nil 을 내지 않는다 · 방출물에 MSL 이 모르는 방언 토큰이 없다 ·
///   스테이지 빌트인을 쓰면 선언도 함께 나온다.
/// - **확정 안 됨**: MSL 이 **컴파일되는지**. Metal 컴파일러는 리눅스에 없고 이 타깃은 Core 전용이라
///   타입 정합·오버로드 해석은 여기서 못 잡는다 — 그건 `WapleRenderTests/GLSLTranslatorMSLTests`
///   (`makeLibrary`)의 몫이다. 즉 여기 초록은 **필요조건**이지 충분조건이 아니다.
///
/// 코퍼스: `WAPLE_WE_ASSETS`(리눅스 하네스가 넣는다) → 상위 디렉터리 탐색. 없으면 스킵.
final class GLSLBundledShaderRegressionTests: XCTestCase {

    // MARK: - 코퍼스 수집

    /// 번역 가능한 셰이더 쌍 하나. `id` 는 자산 루트 상대 경로(확장자 제외).
    struct Pair {
        let id: String
        let vert: String
        let frag: String
        let comboDefaults: [String: Int]
        /// 스윕용 콤보 노브 — `[COMBO]` 기본값 + 인라인 소스의 `#if` 식에 등장하는 대문자 토큰.
        let knobs: [String]
        let include: (String) -> String?
    }

    /// 동봉 자산 루트. `AssetJSONLenientTests.bundledAssetsRoot` 과 같은 규약(중복이 아니라 같은 계약).
    static func assetsRoot() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
           fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// `shaders/HLSL/` 은 **GLSL 이 아니다** — `dx11` 접두 파일명 그대로 D3D11 백엔드용 HLSL 원본이고
    /// (`shaders/HLSL/dx11fallback.frag:1-4` 가 `struct PS_OUTPUT { float4 gl_FragColor : SV_TARGET; };`),
    /// WE 는 이 파일들을 셰이더 심 없이 `D3DCompile` 로 바로 먹인다. GLSL 번역기에 넣으면
    /// "번역 성공"이 나오지만 그건 의미 없는 통과다 — 코퍼스에서 뺀다.
    static let excludedPrefixes = ["shaders/HLSL/"]

    static func collectPairs(root: URL) -> [Pair] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var rels: [String] = []
        for case let url as URL in en where url.pathExtension == "vert" {
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(rootPath + "/") else { continue }
            rels.append(String(p.dropFirst(rootPath.count + 1)))
        }
        rels.sort()

        func read(_ p: String) -> String? {
            guard let d = fm.contents(atPath: p) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        var out: [Pair] = []
        for rel in rels where !excludedPrefixes.contains(where: { rel.hasPrefix($0) }) {
            let id = String(rel.dropLast(".vert".count))
            let vertPath = rootPath + "/" + rel
            let fragPath = rootPath + "/" + id + ".frag"
            guard let v = read(vertPath), let f = read(fragPath) else { continue }
            // 인클루드 해석: `.vert` 가 있는 디렉터리부터 자산 루트까지 조상 사슬을 거슬러
            // `<dir>/<header>` 와 `<dir>/shaders/<header>` 를 본다 — 이펙트-로컬 헤더가 공용
            // `shaders/` 헤더를 가리는 실제 조회 순서(SceneRendererResources :624-630)와 같다.
            var dirs: [String] = []
            var cur = (vertPath as NSString).deletingLastPathComponent
            while cur.hasPrefix(rootPath) { dirs.append(cur); cur = (cur as NSString).deletingLastPathComponent }
            dirs.append(rootPath + "/shaders")
            let include: (String) -> String? = { header in
                for d in dirs {
                    for cand in ["\(d)/\(header)", "\(d)/shaders/\(header)"] { if let s = read(cand) { return s } }
                }
                return BuiltinShaderIncludes.lookup(header)
            }
            var defaults = ShaderPreprocessor.parseComboDefaults(v)
            for (k, n) in ShaderPreprocessor.parseComboDefaults(f) where defaults[k] == nil { defaults[k] = n }
            // 샘플러 어노테이션 콤보는 "슬롯이 묶였으면 1" 이 렌더러 규약(SceneRendererResources :1608-1610).
            for (_, name) in GLSLTranslator.samplerCombos(f) where defaults[name] == nil { defaults[name] = 1 }
            let inlined = inlineIncludes(v, include: include) + "\n" + inlineIncludes(f, include: include)
            var knobs = Set(defaults.keys)
            for cond in matches(Self.ifDirectiveRe, in: inlined) { knobs.formUnion(matches(Self.capsRe, in: cond)) }
            // 엔진이 항상 시딩하는 것(ShaderPreprocessor :30-46)은 노브가 아니다 — 뒤집으면
            // WE 가 절대 만들지 않는 조합을 검사하게 된다.
            knobs.subtract(["HLSL", "HLSL_SM40", "HLSL_SM30", "SHADERVERSION", "PLATFORM_ANDROID"])
            out.append(Pair(id: id, vert: v, frag: f, comboDefaults: defaults,
                            knobs: knobs.sorted(), include: include))
        }
        return out
    }

    /// `#include` 만 재귀 인라인(조건부 평가 없음) — 노브 수집용이라 조건 분기와 무관해야 한다.
    private static func inlineIncludes(_ src: String, include: (String) -> String?, depth: Int = 0) -> String {
        if depth > 8 { return src }
        var out: [String] = []
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#include"), let a = t.firstIndex(of: "\""), let b = t.lastIndex(of: "\""), a < b {
                out.append(include(String(t[t.index(after: a)..<b])).map { inlineIncludes($0, include: include, depth: depth + 1) } ?? "")
            } else {
                out.append(String(line))
            }
        }
        return out.joined(separator: "\n")
    }

    private static let ifDirectiveRe = try! NSRegularExpression(
        pattern: "^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\\b([^\n]*)", options: [.anchorsMatchLines])
    private static let capsRe = try! NSRegularExpression(pattern: "\\b([A-Z][A-Z0-9_]{2,})\\b")

    private static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: 1)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    // MARK: - 미번역 토큰 린트

    /// 방출 MSL(주석 제거본)에 남으면 **MSL 컴파일이 확정 실패**하는 방언 토큰들.
    /// 선행 부정탐색 `(?<![A-Za-z0-9_])` 가 핵심이다 — 없으면 오버로드 맹글링 이름
    /// (`CombineLighting_vec3_vec3`)이 `vec3(` 로 잡혀 **가짜 실패 22건**이 난다(실제로 당했다).
    static let untranslated: [(name: String, pattern: String)] = [
        ("vecN 생성자", "(?<![A-Za-z0-9_])(?:vec2|vec3|vec4|ivec[234]|uvec[234]|bvec[234])\\s*\\("),
        ("matN 타입", "(?<![A-Za-z0-9_])mat[234](?:x[234])?(?![A-Za-z0-9_])"),
        ("sampler 선언 타입", "(?<![A-Za-z0-9_])sampler(?:2D|3D|Cube)[A-Za-z]*(?![A-Za-z0-9_])"),
        ("texSample*/texLoad2D 인트린식",
         "(?<![A-Za-z0-9_])(?:texSample2D|texSample2DLod|texSample2DCompare|texSample2DBackBuffer|texSample3D|texLoad2D)\\s*\\("),
        ("HLSL clip", "(?<![A-Za-z0-9_])clip\\s*\\("),
        ("HLSL mul", "(?<![A-Za-z0-9_])mul\\s*\\("),
        ("CAST* 매크로", "(?<![A-Za-z0-9_])CAST(?:2|3|4|I|U|F|4U|2X2|3X3|4X4)\\s*\\("),
        ("샘플러 전달 매크로", "(?<![A-Za-z0-9_])(?:DECLARE|MAKE)_SAMPLER2D[A-Z_]*"),
        ("소비 못 하는 gl_ 빌트인",
         "(?<![A-Za-z0-9_])gl_(?:FragData|FragDepth|PointCoord|PointSize|Layer|FrontFacing)(?![A-Za-z0-9_])"),
        // `attribute` 는 `[[attribute(0)]]` 로 정당하게 나오므로 **줄머리 선언**만 본다.
        ("GLSL 선언 한정자", "^[ \t]*(?:varying|attribute|uniform|precision)[ \t]"),
        ("정밀도 한정자", "(?<![A-Za-z0-9_])(?:highp|mediump|lowp)(?![A-Za-z0-9_])"),
        // `#include <metal_stdlib>` 은 우리가 방출하는 정당한 줄이다 — `include` 를 이 목록에 넣으면
        // **전건이 가짜로 걸린다**(실제로 당했다). GLSL 인클루드는 따옴표형이라 따로 본다.
        ("전처리 잔재", "^[ \t]*#[ \t]*(?:if|ifdef|ifndef|else|elif|endif|define|extension|version)\\b"),
        ("GLSL #include 잔재", "^[ \t]*#[ \t]*include[ \t]*\""),
        ("GLSL 전용 함수",
         "(?<![A-Za-z0-9_])(?:inversesqrt|dFdx|dFdy|lessThan|greaterThan|notEqual|matrixCompMult|outerProduct|texture2D|textureLod|texelFetch|textureSize)\\s*\\("),
        ("엔진 주입 함수", "(?<![A-Za-z0-9_])PerformLighting_V1\\s*\\("),
        // 번역기가 **모델하지 않는** 엔진 심볼 — 방출물에 이름 그대로 남는다. 새로 하나가 새면
        // 여기 집합이 커지므로 바로 걸린다(아래 knownGaps 근거 참조).
        ("모델 밖 엔진 심볼", "(?<![A-Za-z0-9_])(?:g_MorphOffsets|g_Texture(?:[89]|1[0-9])Resolution)(?![A-Za-z0-9_])"),
        ("M_PI 매크로", "(?<![A-Za-z0-9_])M_PI(?![A-Za-z0-9_])"),
    ]

    private static let compiled: [(name: String, re: NSRegularExpression)] = untranslated.map {
        ($0.name, try! NSRegularExpression(pattern: $0.pattern, options: [.anchorsMatchLines]))
    }
    private static let blockCommentRe = try! NSRegularExpression(pattern: "/\\*.*?\\*/", options: [.dotMatchesLineSeparators])
    private static let lineCommentRe = try! NSRegularExpression(pattern: "//[^\n]*")

    /// 주석 제거 — 프리앰블 주석에 `mod(x,y)` · `texture2DLod` · `mat3(x)` 같은 **설명용** 토큰이
    /// 잔뜩 들어 있다. 안 지우면 전건이 가짜로 걸린다(실제로 당했다: 239/239 오탐).
    static func stripComments(_ s: String) -> String {
        let ns0 = s as NSString
        let a = Self.blockCommentRe.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns0.length), withTemplate: " ")
        let ns1 = a as NSString
        return Self.lineCommentRe.stringByReplacingMatches(
            in: a, range: NSRange(location: 0, length: ns1.length), withTemplate: " ")
    }

    static func untranslatedTokens(in msl: String) -> [String] {
        let s = stripComments(msl)
        let ns = s as NSString
        return compiled.filter { $0.re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil }
            .map { $0.name }
    }

    /// **선언되면 쓰인다** 불변식 — 스테이지 빌트인은 이름만 남고 선언이 빠지는 것이 종전 실패 모드였다.
    /// (`in uint gl_VertexID;` 선언 줄이 어느 파서에도 안 잡혀 사라졌다 — GLSLTranslator :268 주석.)
    static let builtinDeclarations: [(symbol: String, attribute: String)] = [
        ("gl_VertexID", "[[vertex_id]]"),
        ("gl_InstanceID", "[[instance_id]]"),
        ("gl_ViewportIndex", "[[viewport_array_index]]"),
    ]

    // MARK: - 인벤토리

    /// 동봉 셰이더 총수와 확장자 분포 — 코퍼스가 조용히 비거나 줄면 아래 스윕이 **0건을 통과**한다.
    /// 2026-08-21 실측: `shaders/` 137 파일 = vert 59 · frag 59 · h 14 · geom 4 · json 1.
    func testBundledShaderInventory() throws {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let fm = FileManager.default
        let shaders = root.appendingPathComponent("shaders")
        guard let en = fm.enumerator(at: shaders, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return XCTFail("shaders/ 를 못 훑었다")
        }
        var byExt: [String: Int] = [:]
        var total = 0
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            total += 1
            byExt[url.pathExtension, default: 0] += 1
        }
        XCTAssertEqual(total, 137, "동봉 shaders/ 파일 수(자산 갱신 시 이 값을 함께 고쳐라)")
        XCTAssertEqual(byExt, ["vert": 59, "frag": 59, "h": 14, "geom": 4, "json": 1])
    }

    /// `.geom` 4건은 **번역 범위 밖**이다(Metal 에 지오메트리 스테이지가 없다) — 조용히 빠지는 게
    /// 아니라 여기에 못 박아 둔다. WE 는 `#define GS_ENABLED 1`(shader-strings.txt :73)로 GS 경로를
    /// 켜고 `genericparticle`/`genericropeparticle` 이 그걸 본다.
    func testGeometryShadersAreOutOfScopeAndCounted() throws {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let fm = FileManager.default
        var geoms: [String] = []
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in en where url.pathExtension == "geom" {
                geoms.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(geoms.sorted(),
                       ["dx11playlisttransition.geom", "flatpoint.geom",
                        "genericparticle.geom", "genericropeparticle.geom"])
    }

    // MARK: - 전건 번역

    func testEveryBundledShaderPairTranslatesAtDeclaredCombos() throws {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let pairs = Self.collectPairs(root: root)
        XCTAssertGreaterThan(pairs.count, 200, "쌍이 이만큼도 안 나오면 경로가 틀린 것 (2026-08-21 실측 239)")
        var failed: [String] = []
        for p in pairs where GLSLTranslator.translate(vertex: p.vert, fragment: p.frag,
                                                      combos: p.comboDefaults, include: p.include) == nil {
            failed.append(p.id)
        }
        XCTAssertEqual(failed, [], "선언된 콤보 기본값에서 번역이 nil 을 냈다")
    }

    /// 선언 기본값 구성에서 방출 MSL 에 남은 방언 토큰. **아무것도 남으면 안 된다** —
    /// 아래 `knownGaps` 는 근거가 적힌 예외뿐이고, 새 항목을 추가하려면 근거도 같이 적어야 한다.
    func testNoUntranslatedTokensAtDeclaredCombos() throws {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let pairs = Self.collectPairs(root: root)
        var found: [String: Set<String>] = [:]     // 토큰 종류 → 셰이더 id
        for p in pairs {
            guard let t = GLSLTranslator.translate(vertex: p.vert, fragment: p.frag,
                                                   combos: p.comboDefaults, include: p.include) else { continue }
            for name in Self.untranslatedTokens(in: t.msl) { found[name, default: []].insert(p.id) }
            for (sym, attr) in Self.builtinDeclarations where t.msl.contains(sym) {
                XCTAssertTrue(t.msl.contains(attr),
                              "\(p.id): \(sym) 을 쓰는데 \(attr) 선언이 없다")
            }
        }
        XCTAssertEqual(Set(found.keys), Set(Self.knownGaps.keys),
                       "미번역 토큰 종류 집합이 바뀌었다: \(found.mapValues { $0.sorted() })")
        for (name, ids) in found {
            XCTAssertEqual(ids, Set(Self.knownGaps[name] ?? []), "\(name) 잔존 셰이더 집합이 바뀌었다")
        }
    }

    /// 콤보 스윕 — 선언 기본값만 보면 **`#if` 뒤에 숨은 구문을 통째로 못 본다**.
    /// `texSample2DCompare`(`common_pbr_2.h:75`)·`gl_ViewportIndex`(`shadowcaster.vert:105`)가
    /// 정확히 그 자리에 있었다. 구성: 기본값 · 전부 1 · 전부 0(셰이더당 3).
    /// 노브 하나씩 뒤집는 전량 스윕(2,003 구성)은 릴리스에서도 8분이라 테스트에 못 넣는다 —
    /// 그건 개발 중 `scripts/` 밖 일회성 하네스로 돌렸고, 여기 3구성이 그 결과를 지키는 상시 게이트다.
    func testNoUntranslatedTokensAcrossComboExtremes() throws {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let pairs = Self.collectPairs(root: root)
        var found: [String: Set<String>] = [:]
        var nilFailed: [String] = []
        for p in pairs {
            var allOn = p.comboDefaults, allOff = p.comboDefaults
            for k in p.knobs { allOn[k] = 1; allOff[k] = 0 }
            for combos in [allOn, allOff] {
                guard let t = GLSLTranslator.translate(vertex: p.vert, fragment: p.frag,
                                                       combos: combos, include: p.include) else {
                    nilFailed.append(p.id); continue
                }
                for name in Self.untranslatedTokens(in: t.msl) { found[name, default: []].insert(p.id) }
            }
        }
        XCTAssertEqual(nilFailed, [], "콤보 극단값에서 번역이 nil 을 냈다")
        XCTAssertEqual(Set(found.keys), Set(Self.knownGapsSweep.keys),
                       "스윕 미번역 토큰 종류 집합이 바뀌었다: \(found.mapValues { $0.sorted() })")
        for (name, ids) in found {
            XCTAssertEqual(ids, Set(Self.knownGapsSweep[name] ?? []), "\(name) 잔존 셰이더 집합이 바뀌었다")
        }
    }

    // MARK: - 남은 갭(근거 필수)

    /// **`PerformLighting_V1` 은 소스에 정의가 없다.** 동봉 자산·WE 설치본 어디에도 없고,
    /// wallpaper64.exe 원본 파일오프셋 `0x48ae75` 에 본문 템플릿이 문자열로 박혀 있다:
    /// `vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector,`
    /// `vec3 specularTint, vec3 ambient, float roughness, float metallic)` — 그 앞뒤로
    /// `uniform vec4 g_LPoint_Origin[` 등 라이트 배열 선언과 `const uint i =` 언롤 조각이 붙어 있다.
    /// 즉 WE 는 씬의 라이트 개수를 보고 **컴파일 시점에 본문을 합성해 주입**한다.
    /// Waple 의 3D 라이팅은 이 경로를 재현하지 않고 `WapleRender/Mesh3DShaders.swift` 손-포팅이
    /// 전담하므로(번역 실패 → 폴백), 여기서는 "실패하되 조용하지 않게" 를 못 박는다.
    ///
    /// **모델 밖 엔진 심볼** 둘도 같은 성격이다:
    /// - `g_TextureNResolution` 의 **N ≥ 8**: `EngineU.texRes` 가 `float4[8]` 고정이라 치환 대상이
    ///   없다(`GLSLTranslator.engineReplacement` 의 `(0..<8).contains(n)` 가드 — 그 자리에
    ///   "미치환(컴파일 실패→폴백)" 이라고 이미 적혀 있다). 동봉 실물은 `shaders/chroma4.frag:76`
    ///   한 건뿐이다. 슬롯 상한을 올리려면 `WapleRender` 의 유니폼 빌더까지 같이 바꿔야 한다.
    /// - `uniform uint g_MorphOffsets[12]`(`shaders/generic4.vert:50` 외 — `shaders/base/model_vertex_v1.h`
    ///   경유로 3D 모델 계열 vert 전반, 아래 스윕 집합이 정확한 목록이다): 모프 타깃 오프셋
    ///   테이블이다. `GLSLType.from("uint")` 가 nil 이라 선언이 파스에서 탈락한다. 짝인
    ///   `uniform float g_MorphWeights[12]` 는 파스되지만 배열이 스칼라 머티리얼 슬롯으로 접히므로
    ///   어차피 모프는 성립하지 않는다 — Waple 은 모프 타깃을 어느 경로에서도 모델하지 않는다.
    ///   **부분 지원은 조용히 틀린 그림이라 일부러 안 한다**(폴터가 정답).
    static let knownGaps: [String: [String]] = [
        // 선언 콤보 기본값에서 도달하는 4건 — 나머지 4건은 기본값이 `LIGHTING=0` 이라 호출부가
        // `#if` 로 잘려 나간다(아래 스윕 집합에서 드러난다).
        "엔진 주입 함수": ["shaders/chroma4", "shaders/foliage4", "shaders/fur4", "shaders/generic4"],
        // 기본값에서는 `g_Texture8Resolution`(chroma4) 하나뿐 — 모프 경로는 `MORPHING=0` 이라 잠겨 있다.
        "모델 밖 엔진 심볼": ["shaders/chroma4"],
    ]

    /// 콤보 극단값(전부 1 / 전부 0)까지 포함한 잔존 집합 — 기본값에서 안 보이던 것들이 더 붙는다.
    /// **이 차이 자체가 스윕이 필요한 이유의 증거다**: 기본값만 봤다면 엔진 주입 함수는 절반을,
    /// 모프 심볼은 열 중 열을 못 봤다.
    static let knownGapsSweep: [String: [String]] = [
        "엔진 주입 함수": knownGaps["엔진 주입 함수"]! + [
            "effects/fluidsimulation/shaders/effects/fluidsimulation_combine",
            "shaders/genericimage4", "shaders/genericparticle", "shaders/genericropeparticle",
        ],
        "모델 밖 엔진 심볼": knownGaps["모델 밖 엔진 심볼"]! + [
            "shaders/clippingmaskimage4", "shaders/foliage4", "shaders/fur4", "shaders/generic3",
            "shaders/generic4", "shaders/genericimage3", "shaders/genericimage4",
            "shaders/shadowcaster", "shaders/shadowcasterfoliage4", "shaders/shadowcasterfur4",
        ],
    ]
}

/// 위 전건 스윕이 **찾아낸** 방언 구문들의 구현 오라클(입력 GLSL → 기대 MSL 조각).
/// 스윕은 "무엇이 빠졌나" 를 알려 주고, 이 클래스는 "그래서 어떻게 번역하기로 했나" 를 고정한다.
/// 두 쪽이 다 있어야 한다 — 스윕만 있으면 토큰이 사라지기만 하면 통과라 **오역도 초록**이다.
final class GLSLDialectGapTests: XCTestCase {
    /// 최소 vertex(varying 하나) — 프래그먼트만 보는 케이스의 공용 상대.
    private let vert = """
    uniform mat4 g_ModelViewProjectionMatrix;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = a_TexCoord;
    }
    """
    private let passthroughFrag = """
    varying vec2 v_TexCoord;
    void main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }
    """

    // MARK: 1. gl_VertexID → [[vertex_id]] (동봉 8 셰이더: generic3/4·chroma4·fur4·foliage4·shadowcaster*)

    func testVertexIDBecomesStageBuiltinParameter() throws {
        let v = """
        attribute vec3 a_Position;
        varying vec2 v_TexCoord;
        in uint gl_VertexID;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = vec2(float(gl_VertexID), 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: v, fragment: passthroughFrag, combos: [:]))
        XCTAssertTrue(t.msl.contains("uint gl_VertexID [[vertex_id]]"),
                      "`in uint gl_VertexID;` 선언은 사라지고 MSL 스테이지 파라미터로: \(t.msl)")
        XCTAssertTrue(t.msl.contains("float(gl_VertexID)"), "본문 참조는 이름 그대로: \(t.msl)")
        XCTAssertFalse(t.msl.contains("in uint"), "GLSL `in` 선언 줄은 방출되면 안 된다")
    }

    /// 안 쓰는 셰이더의 시그니처는 종전 그대로 — 무회귀의 형태를 못 박는다.
    func testVertexBuiltinsAbsentWhenUnused() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: passthroughFrag, combos: [:]))
        XCTAssertFalse(t.msl.contains("[[vertex_id]]"))
        XCTAssertFalse(t.msl.contains("[[instance_id]]"))
        XCTAssertFalse(t.msl.contains("[[viewport_array_index]]"))
    }

    // MARK: 2. gl_InstanceID + gl_ViewportIndex (동봉 shadowcaster.vert:104-105 — 아틀라스 슬라이스 선택)

    func testInstanceIDAndViewportIndexBecomeLayeredRenderBuiltins() throws {
        let v = """
        attribute vec3 a_Position;
        varying vec2 v_TexCoord;
        in uint gl_InstanceID;
        varying uint gl_ViewportIndex;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            gl_ViewportIndex = gl_InstanceID;
            v_TexCoord = vec2(0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: v, fragment: passthroughFrag, combos: [:]))
        XCTAssertTrue(t.msl.contains("uint gl_InstanceID [[instance_id]]"), t.msl)
        XCTAssertTrue(t.msl.contains("uint gl_ViewportIndex [[viewport_array_index]];"),
                      "Vary 멤버로 방출(레이어드 타깃 선택자): \(t.msl)")
        XCTAssertTrue(t.msl.contains("out.gl_ViewportIndex = gl_InstanceID;"), t.msl)
    }

    // MARK: 3. sampler2DComparison + texSample2DCompare (WE shim :25/:65 — 섀도우 아틀라스 PCF)

    func testComparisonSamplerBecomesDepth2DWithCompareSampler() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2DComparison g_Texture0; // {"hidden":true,"default":"_rt_shadowAtlas"}
        void main() {
            float lit = texSample2DCompare(g_Texture0, v_TexCoord, 0.5).r;
            gl_FragColor = vec4(lit);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.textureSlots, [0], "비교 샘플러도 텍스처 슬롯이다(종전엔 선언이 통째로 탈락)")
        XCTAssertEqual(t.textureDefaults[0], "_rt_shadowAtlas")
        XCTAssertTrue(t.msl.contains("depth2d<float> g_Texture0 [[texture(0)]]"), t.msl)
        XCTAssertTrue(t.msl.contains("float4(g_Texture0.sample_compare(smpCmp, we_uv(in.v_TexCoord), 0.5)).r"),
                      "HLSL SampleCmpLevelZero 는 스칼라라 실물이 `.r` 을 붙인다 — float4 로 감싸야 유효: \(t.msl)")
        XCTAssertTrue(t.msl.contains("compare_func::less_equal"), "compare_func 없는 샘플러로는 sample_compare 가 불가")
        XCTAssertFalse(t.msl.contains("texSample2DCompare"))
    }

    /// 비교 슬롯이 없으면 `smpCmp` 선언도 없다(프리앰블 노이즈 방지 + 이 셰이더가 아틀라스를 안 읽는다는 신호).
    func testCompareSamplerOnlyEmittedWhenNeeded() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: passthroughFrag, combos: [:]))
        XCTAssertFalse(t.msl.contains("smpCmp"))
    }

    /// 헬퍼로 넘어가는 비교 샘플러(실물 `common_pbr_2.h` 의 DECLARE_SAMPLER2D_COMPARE_PARAMETER 전개).
    func testComparisonSamplerHelperParameterAndCapture() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2DComparison g_Texture0;
        float shadow(DECLARE_SAMPLER2D_COMPARE_PARAMETER(g_Texture0), vec2 uv, float d) {
            return texSample2DCompare(MAKE_SAMPLER2D_COMPARE_ARGUMENT(g_Texture0), uv, d).r;
        }
        void main() { gl_FragColor = vec4(shadow(g_Texture0, v_TexCoord, 0.25)); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float shadow(depth2d<float> g_Texture0, float2 uv, float d, sampler smpCmp)"),
                      "비교 샘플러 파라미터 + 전용 smpCmp 캡처: \(t.msl)")
        XCTAssertTrue(t.msl.contains("shadow(g_Texture0, in.v_TexCoord, 0.25, smpCmp)"), t.msl)
    }

    // MARK: 4. sampler3D + texSample3D (WE shim :24/:67 — 동봉 ccsimple.frag:9,32 컬러그레이딩 LUT)

    func testVolumeSamplerBecomesTexture3D() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler3D g_Texture1;
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            vec3 graded = texSample3D(g_Texture1, albedo.rgb);
            gl_FragColor = vec4(graded, albedo.a);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.textureSlots, [0, 1])
        XCTAssertTrue(t.msl.contains("texture3d<float> g_Texture1 [[texture(1)]]"), t.msl)
        // 3성분 좌표는 절단하지 않는다(we_uv 는 2성분 전용). 반환은 float4 라 vec3 대입에 .xyz 가 붙는다.
        XCTAssertTrue(t.msl.contains("g_Texture1.sample(smp, albedo.rgb)"), t.msl)
        XCTAssertTrue(t.msl.contains("float3 graded = (g_Texture1.sample(smp, albedo.rgb)).xyz;"),
                      "HLSL `s.Sample` 은 float4 — vec3 대입의 암시적 절단이 살아야 한다: \(t.msl)")
        XCTAssertFalse(t.msl.contains("texSample3D"))
    }

    // MARK: 5. HLSL clip(x) (동봉 puppettexturechannels.frag:15 · volumetricsfront.frag:67,70)

    func testClipBecomesConditionalDiscard() throws {
        let frag = """
        varying vec2 v_TexCoord;
        void main() {
            clip(v_TexCoord.x - 0.5);
            gl_FragColor = vec4(1.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("if ((in.v_TexCoord.x - 0.5) < 0.0) { discard_fragment(); }"), t.msl)
        XCTAssertFalse(t.msl.contains("clip("))
    }

    /// `clip` 은 인자 1개 계약이다 — 어긋나면 조용히 통과시키지 말고 번역 실패(폴백)여야 한다.
    func testClipWithWrongArityFailsTranslation() {
        let frag = """
        varying vec2 v_TexCoord;
        void main() {
            clip(v_TexCoord.x, 1.0);
            gl_FragColor = vec4(1.0);
        }
        """
        XCTAssertNil(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
    }

    // MARK: 6. CRLF 소스의 [COMBO] 전수 파스 (동봉 셰이더 498개가 전건 CRLF)

    /// Swift 의 `"\r\n"` 은 **단일 grapheme** 이라 `split(separator: "\n")` 에 안 걸린다.
    /// 종전 `parseComboDefaults` 는 CRLF 파일을 한 줄로 보고 **첫 `[COMBO]` 하나만** 돌려줬다.
    /// 실물 대조: `shaders/fur4.frag:3-8` 의 6개 중 `LIGHTING` 만 나왔다.
    func testComboDefaultsParsedFromCRLFSource() {
        let crlf = [
            "// [COMBO] {\"combo\":\"LIGHTING\",\"default\":1}",
            "// [COMBO] {\"combo\":\"FOG\",\"default\":1}",
            "// [COMBO] {\"combo\":\"REFLECTION\",\"default\":0}",
            "// [COMBO] {\"combo\":\"INSTANCECOUNT\",\"default\":5}",
            "void main() {}",
        ].joined(separator: "\r\n")
        XCTAssertEqual(ShaderPreprocessor.parseComboDefaults(crlf),
                       ["LIGHTING": 1, "FOG": 1, "REFLECTION": 0, "INSTANCECOUNT": 5])
        // LF 판은 종전에도 옳았다 — 무회귀 대조군.
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(ShaderPreprocessor.parseComboDefaults(lf), ShaderPreprocessor.parseComboDefaults(crlf))
    }

    /// 그 결과 CRLF 셰이더의 콤보가 **본문 텍스트 치환**까지 도달한다(`CASTF(INSTANCECOUNT)`).
    /// 실물: `shaders/fur4.vert:62` 가 `fur4.frag:8` 에 선언된 INSTANCECOUNT 를 쓴다 — 교차 스테이지다.
    func testCrossStageComboFromCRLFFragmentReachesVertexBody() throws {
        let v = ["attribute vec3 a_Position;",
                 "varying vec2 v_TexCoord;",
                 "void main() {",
                 "    gl_Position = vec4(a_Position, 1.0);",
                 "    v_TexCoord = vec2(1.0 / (CASTF(SHELLCOUNT) - 1.0), 0.0);",
                 "}"].joined(separator: "\r\n")
        let f = ["// [COMBO] {\"combo\":\"UNUSED_FIRST\",\"default\":0}",
                 "// [COMBO] {\"combo\":\"SHELLCOUNT\",\"default\":5}",
                 "varying vec2 v_TexCoord;",
                 "void main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }"].joined(separator: "\r\n")
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: v, fragment: f, combos: [:]))
        XCTAssertTrue(t.msl.contains("(float(5) - 1.0)"),
                      "frag 의 두 번째 [COMBO] 가 vert 본문까지 도달해야 한다: \(t.msl)")
        XCTAssertFalse(t.msl.contains("SHELLCOUNT"))
    }

    // MARK: 7. GLSL unsigned 리터럴 접미(`6u`)와 정수 나머지 (동봉 shadowcaster.vert:55-56)

    /// 종전 토크나이저는 숫자 토큰에 `u` 를 안 붙여 `6u` 를 [6][u] 로 갈랐고, 괄호 안에서 `%` 를
    /// 만나면 파서가 어긋나 **문법이 깨진 MSL** 을 냈다: `(morphMapOffset * 6ufmod(), 4.0)u`.
    func testUnsignedLiteralSuffixKeepsIntegerModulo() {
        let env = GLSLTypeAdapter.Env(vars: ["b": 1], functions: [:], functionParams: [:],
                                      intVars: ["a", "b"], structFields: [])
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "uint a = (b * 6u) % 4u;", env: env),
                       "uint a = (b * 6u) % 4u;")
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "uint a = b % 12u;", env: env), "uint a = b % 12u;")
    }

    /// 대조군 — 실수 나머지는 여전히 `fmod` 로 내려가야 한다(MSL 의 `%` 는 정수 전용).
    /// 실물 `zcompat/.../Simple_Audio_Bars.frag` 가 float `%` 를 쓴다.
    func testFloatModuloStillLowersToFmod() {
        let env = GLSLTypeAdapter.Env(vars: ["x": 1], functions: [:], functionParams: [:],
                                      intVars: [], structFields: [])
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "float y = x % 4;", env: env), "float y = fmod(x, 4.0);")
    }
}
