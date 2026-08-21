import XCTest
@testable import WapleCore

/// AJ-B1: `colorBlendMode` / `BLENDMODE` 의 **정수 도메인**을 동봉 원본 헤더로 잠근다.
///
/// 잠그는 사실은 둘이고 둘 다 실물에서 왔다(근거 전문·VA 는 `docs/re/material-blend.md` §7.5
/// 와 `Sources/WapleRender/BlendMSL.swift` 주석).
///
/// 1. **도메인은 0…32 다.** 동봉 `shaders/common_blending.h` 의 `ApplyBlending` 은
///    `#if BLENDMODE == n` 을 n=1…32 로 정확히 32개 갖는다.
/// 2. **범위 밖은 클램프가 아니라 Normal 로 흘러내린다.** 원본은 `#if` 가 하나도 안 맞으면
///    마지막 줄 `return mix(A,BlendNormal(A,B),opacity)` 로 떨어진다. 우리 GLSL 심
///    `BuiltinShaderIncludes.commonBlending` 은 `vec3 r = B;` 초기값 + `else if` 사슬로 같은
///    동작을 낸다(`switch`/`default` 가 아니라 초기값이 Normal 을 담당한다).
///
/// **자기 산수를 단언하지 않는다** — 기대값은 전부 동봉 헤더 원문에서 읽는다. 헤더가 없으면
/// (WEAssets 미배치) 스킵한다. `BlendMSL`(MSL 쌍둥이)은 WapleRender 라 여기서 못 본다 —
/// 그쪽은 `Tests/WapleRenderTests/BlendModeCoverageTests.swift` 가 같은 오라클로 잠근다.
final class BlendModeDomainTests: XCTestCase {

    /// 동봉 자산 루트(`GLSLBundledShaderRegressionTests.assetsRoot` 와 같은 규약).
    private static func assetsRoot() -> URL? {
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

    /// 원본 헤더가 `#if BLENDMODE == n` 으로 다루는 n 의 집합.
    ///
    /// **동봉 헤더는 CRLF 다**(`file(1)` 확인). Swift `String` 은 그래핌 클러스터 단위라
    /// `"\r\n"` 이 **한 개의 `Character`** 이고 `"\n"` 과 같지 않다 — `split(separator: "\n")`
    /// 은 한 줄도 못 쪼갠다(공통 브리프 함정 #11, `AssetJSON.relaxed` 가 같은 것에 당했다).
    /// `isNewline` 으로 쪼개고 꼬리도 `.whitespacesAndNewlines` 로 턴다.
    static func originalModes(header: String) -> Set<Int> {
        var out: Set<Int> = []
        for line in header.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("#if BLENDMODE ==") else { continue }
            let tail = t.dropFirst("#if BLENDMODE ==".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(tail) { out.insert(n) }
        }
        return out
    }

    /// 우리 GLSL 심의 `ApplyBlending` 이 `mode == n` 으로 다루는 n 의 집합.
    static func shimModes(source: String) -> Set<Int> {
        guard let body = source.range(of: "vec3 ApplyBlending(int mode,") else { return [] }
        let tail = source[body.lowerBound...]
        var out: Set<Int> = []
        var rest = Substring(tail)
        while let hit = rest.range(of: "mode == ") {
            let after = rest[hit.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let n = Int(digits) { out.insert(n) }
            rest = after
        }
        return out
    }

    private func bundledHeader() throws -> String {
        guard let root = Self.assetsRoot() else { throw XCTSkip("WEAssets 미배치(WAPLE_WE_ASSETS 미지정)") }
        let url = root.appendingPathComponent("shaders/common_blending.h")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("동봉 common_blending.h 없음: \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 원본이 다루는 모드 집합이 **정확히 1…32** 임을 원문에서 확인한다.
    /// (이 리포의 `SceneDocument.blendModeVal` 이 쓰는 `0...32` 상수의 근거다.)
    func testOriginalHeaderCoversExactlyOneThroughThirtyTwo() throws {
        let modes = Self.originalModes(header: try bundledHeader())
        XCTAssertEqual(modes, Set(1...32),
                       "동봉 common_blending.h 의 #if BLENDMODE 집합이 1…32 가 아니다: \(modes.sorted())")
        // 0 은 `#if` 로 다루지 않는다 — 마지막 fallthrough 가 담당한다(= Normal).
        XCTAssertFalse(modes.contains(0), "0 은 #if 로 다루면 안 된다(fallthrough 담당)")
    }

    /// 원본의 **마지막 줄이 BlendNormal fallthrough** 인지 — 범위 밖 정수가 클램프되지 않고
    /// Normal 로 떨어진다는 사실의 원문 근거다. 이게 없으면 `blendModeVal` 이 범위 밖을 0 으로
    /// 접는 선택의 정당성이 사라진다.
    func testOriginalHeaderFallsThroughToBlendNormal() throws {
        let header = try bundledHeader()
        guard let fn = header.range(of: "vec3 ApplyBlending(") else {
            return XCTFail("동봉 헤더에서 ApplyBlending 을 못 찾았다")
        }
        let body = header[fn.upperBound...]
        // 마지막 `#endif` 뒤에 남는 실행문이 곧 fallthrough 다.
        guard let lastEndif = body.range(of: "#endif", options: .backwards) else {
            return XCTFail("ApplyBlending 본문에 #endif 가 없다")
        }
        let epilogue = body[lastEndif.upperBound...]
        XCTAssertTrue(epilogue.contains("BlendNormal"),
                      "ApplyBlending 의 fallthrough 가 BlendNormal 이 아니다 — 범위 밖 규약이 바뀌었다: \(epilogue)")
        XCTAssertFalse(epilogue.contains("clamp("),
                       "fallthrough 에 clamp 가 생겼다 — 원본은 클램프하지 않는다")
    }

    /// 우리 GLSL 심이 원본과 **같은 모드 집합**을 다루는가. 한 팔이라도 빠지면 그 모드가 조용히
    /// Normal 로 새고, 원본에 없는 팔이 생기면 워크샵 자산이 우리에서만 다르게 보인다.
    func testBuiltinShimCoversTheSameModeSetAsTheOriginal() throws {
        let original = Self.originalModes(header: try bundledHeader())
        let shim = Self.shimModes(source: BuiltinShaderIncludes.commonBlending)
        XCTAssertEqual(shim, original,
                       "GLSL 심의 ApplyBlending 모드 집합이 원본과 다르다 — 빠진 것 \(original.subtracting(shim).sorted()) · 남는 것 \(shim.subtracting(original).sorted())")
    }

    /// 심의 fallthrough 도 Normal 이어야 한다 — `vec3 r = B;` 초기값이 그 역할을 한다.
    /// (`else if` 사슬이라 아무 가지도 안 맞으면 `r` 이 그대로 `mix(A, r, o)` 로 나간다.)
    func testBuiltinShimFallsThroughToNormal() throws {
        let src = BuiltinShaderIncludes.commonBlending
        guard let fn = src.range(of: "vec3 ApplyBlending(int mode,") else {
            return XCTFail("심에서 ApplyBlending 을 못 찾았다")
        }
        let body = src[fn.upperBound...]
        guard let firstBrace = body.firstIndex(of: "{") else { return XCTFail("본문 시작 `{` 없음") }
        let head = body[body.index(after: firstBrace)...].prefix(80)
        XCTAssertTrue(head.contains("vec3 r = B;"),
                      "ApplyBlending 초기값이 `vec3 r = B;`(=Normal) 가 아니다 — 범위 밖 규약이 바뀐다: \(head)")
    }

    /// `BuiltinShaderIncludes.lookup` 이 이 헤더를 **심으로 가로채는지**. 가로채지 못하면
    /// 번역기가 원본 GLSL(전처리기 `#if BLENDMODE`)을 그대로 먹어 콤보 값 하나마다 다른
    /// 소스를 굽게 된다 — 우리 규약(런타임 정수)과 어긋난다.
    func testLookupServesTheShimForCommonBlending() throws {
        let served = try XCTUnwrap(BuiltinShaderIncludes.lookup("common_blending.h"))
        XCTAssertTrue(served.contains("vec3 ApplyBlending(int mode,"),
                      "common_blending.h 심이 런타임 int 시그니처를 내지 않는다")
        XCTAssertFalse(served.contains("#if BLENDMODE"),
                       "심이 전처리기 분기를 그대로 갖고 있다 — 런타임 모드 규약과 어긋난다")
    }
}
