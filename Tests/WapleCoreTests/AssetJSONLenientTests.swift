import XCTest
@testable import WapleCore

/// WE 파서의 관용도(jsoncpp `allowComments` + `allowTrailingCommas`)를 자산 리더 전반에
/// 적용한 것을 못박는다.
///
/// 종전에는 `EffectManifest.parse` 만 관용이었고, 머티리얼·모델·씬·프로젝트 리더는 맨
/// `JSONSerialization` 이었다. 그래서 **동봉 기본 프로젝트에서 실제로 깨졌다** —
/// `projects/defaultprojects/fantasticcar/materials/car/glass.json:6` 의 `//` 줄 주석과
/// `assets/presets/water/preset.json:55` 의 트레일링 콤마.
final class AssetJSONLenientTests: XCTestCase {

    /// 실물 `fantasticcar/materials/car/glass.json` 의 축약본. 줄 주석 한 줄 때문에
    /// 머티리얼 전체(textures·blending·constantshadervalues)가 유실되던 모양 그대로다.
    private let glassLike = Data("""
    {
        "passes": [{
            "shader": "car",
            "textures": ["car/glass"],
            "blending": "translucent",
            //"cullmode": "nocull",
            "constantshadervalues": { "specularstrength": 5 }
        }]
    }
    """.utf8)

    func testLineCommentMaterialParses() {
        XCTAssertNil(try? JSONSerialization.jsonObject(with: glassLike),
                     "전제: 이 입력은 RFC 엄격 파스에 실패한다")
        guard let d = AssetJSON.dictionary(glassLike) else {
            return XCTFail("관용 파스가 실패했다")
        }
        let pass = (d["passes"] as? [[String: Any]])?.first
        XCTAssertEqual(pass?["shader"] as? String, "car")
        XCTAssertEqual(pass?["textures"] as? [String], ["car/glass"])
        XCTAssertEqual(pass?["blending"] as? String, "translucent")
        XCTAssertNotNil(pass?["constantshadervalues"], "주석 뒤 키까지 살아야 한다")
    }

    func testTrailingCommaParses() {
        let d = AssetJSON.dictionary(Data(#"{"a":[1,2,],"b":{"c":1,},}"#.utf8))
        XCTAssertEqual((d?["a"] as? [Int]), [1, 2])
        XCTAssertEqual(((d?["b"] as? [String: Any])?["c"] as? Int), 1)
    }

    /// 관용이 **문자열 리터럴 안을 건드리면 안 된다.** 스캐너가 값 안의 `//` 나 `,]` 를
    /// 문법으로 오인하면 정상 자산이 깨진다 — 그쪽이 훨씬 나쁜 회귀다.
    func testStringLiteralsAreUntouched() {
        let d = AssetJSON.dictionary(Data(#"{"url":"http://a/b","x":"y,]","esc":"q\"//z"}"#.utf8))
        XCTAssertEqual(d?["url"] as? String, "http://a/b")
        XCTAssertEqual(d?["x"] as? String, "y,]")
        XCTAssertEqual(d?["esc"] as? String, #"q"//z"#)
    }

    /// 엄격을 **먼저** 시도한다 — 정상 자산은 전처리를 아예 안 탄다(무회귀 보장).
    func testWellFormedInputIsUnchanged() {
        let src = Data(#"{"a":1,"b":[2,3],"s":"//not-a-comment"}"#.utf8)
        let strict = try? JSONSerialization.jsonObject(with: src) as? [String: Any]
        let ours = AssetJSON.dictionary(src)
        XCTAssertEqual(ours?["a"] as? Int, (strict as? [String: Any])?["a"] as? Int)
        XCTAssertEqual(ours?["s"] as? String, "//not-a-comment")
    }

    /// 블록 주석은 **일부러 지원하지 않는다.** WE 토크나이저는 소비하지만
    /// (0x14008e949–0x14008e9d6) 동봉·설치본 자산 전수에서 0건이라, 근거 없는 관용을
    /// 늘리지 않는다는 판단을 여기 못박는다. 지원하기로 결정하면 이 테스트를 뒤집어라.
    func testBlockCommentIsDeliberatelyUnsupported() {
        XCTAssertNil(AssetJSON.dictionary(Data("{/* c */\"a\":1}".utf8)))
    }

    func testGarbageStaysNil() {
        XCTAssertNil(AssetJSON.dictionary(Data("{not json".utf8)))
        XCTAssertNil(AssetJSON.dictionary(Data([0xff, 0xfe, 0x00])))
    }

    // MARK: CRLF — Swift 그래핌 클러스터 함정

    /// **[2026-08-21]** `while text[i] != "\n"` 이 CRLF 를 못 넘었다. Swift `String` 은 그래핌
    /// 클러스터 단위로 순회하고 `"\r\n"` 은 **한 개의 `Character`** 이므로 `== "\n"` 이 false 다.
    /// 그래서 CRLF 파일에서 줄 주석 스키퍼가 개행에 멈추지 못하고 **파일 끝까지** 지웠다.
    /// 동봉 `effects/**/effect.json` 은 122개 전건이 CRLF 이고, 엄격 파스가 실패해 관용이 필요한
    /// 자산 31건도 전건 CRLF 였다 — 즉 이 경로는 실전에서 **거의 전부** 깨져 있었다.
    func testLineCommentInCRLFFileStopsAtTheLineEnd() {
        let src = Data("{\r\n\"a\": 1, // 주석\r\n\"b\": 2\r\n}".utf8)
        guard let d = AssetJSON.dictionary(src) else { return XCTFail("CRLF + 줄 주석이 복구되지 않았다") }
        XCTAssertEqual(d["a"] as? Int, 1)
        XCTAssertEqual(d["b"] as? Int, 2, "주석 뒤 줄이 통째로 사라졌다면 b 가 없다")
    }

    /// 파일 마지막 줄의 주석(뒤에 개행이 없다)도 안전해야 한다 — 루프가 endIndex 에서 끝난다.
    func testLineCommentAtEndOfFileWithoutNewline() {
        let src = Data("{\"a\": 1}\r\n// 꼬리 주석".utf8)
        XCTAssertEqual(AssetJSON.dictionary(src)?["a"] as? Int, 1)
    }

    /// 트레일링 콤마 스키퍼의 공백 집합도 같은 함정에 걸려 있었다(`"\r\n"` 은 `"\r"` 도 `"\n"` 도 아니다).
    func testTrailingCommaAcrossCRLF() {
        let src = Data("{\r\n\"a\": [1, 2,\r\n],\r\n}".utf8)
        guard let d = AssetJSON.dictionary(src) else { return XCTFail("CRLF 트레일링 콤마가 복구되지 않았다") }
        XCTAssertEqual((d["a"] as? [Int])?.count, 2)
    }

    /// CRLF + 주석 + 트레일링 콤마가 한 파일에 다 있는 실전 형태(동봉 effect.json 이 이 모양이다).
    func testCRLFCommentAndTrailingCommaTogether() {
        let src = Data("{\r\n// 머리 주석\r\n\"passes\": [\r\n{ \"material\": \"m\", },\r\n],\r\n}".utf8)
        guard let d = AssetJSON.dictionary(src) else { return XCTFail("복합 형태가 복구되지 않았다") }
        XCTAssertEqual((d["passes"] as? [[String: Any]])?.first?["material"] as? String, "m")
    }

    /// 문자열 리터럴 안의 CRLF 이스케이프(`\r\n` 두 글자)는 건드리면 안 된다 — 그건 개행이 아니다.
    func testEscapedCRLFInsideStringIsUntouched() {
        let d = AssetJSON.dictionary(Data(#"{"a":"x\r\n// not a comment","b":1}"#.utf8))
        XCTAssertEqual(d?["a"] as? String, "x\r\n// not a comment")
        XCTAssertEqual(d?["b"] as? Int, 1)
    }

    // MARK: 실물 `CharReaderBuilder` 설정과의 대조 (2026-08-21 전수)

    /// `CharReaderBuilder::setDefaults`(`0x140091ef0`–`0x1400924b4`) 12개 설정을 전수한 결과,
    /// **관용이 필요한 실제 차이는 주석과 트레일링 콤마 둘뿐**이었다. 나머지는 이미 일치하거나
    /// 우리가 더 엄격하다. 아래 테스트들은 그 "이미 일치" 를 못박는다 — 일치는 우연히 성립하는
    /// 것이라 누가 `.allowFragments` 를 켜거나 전처리를 넓히면 조용히 깨진다.

    /// `skipBom = true`(`0x140092423`). Foundation 도 BOM 을 먹는다 — 손댈 것이 없다.
    /// **관용 경로에서도** 살아야 한다(`relaxed` 가 U+FEFF 를 그대로 흘려보내고 재인코딩한다).
    func testBOMIsAcceptedOnBothTheStrictAndLenientPaths() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        XCTAssertEqual(AssetJSON.dictionary(Data(bom + Array(#"{"a":1}"#.utf8)))?["a"] as? Int, 1)
        // BOM + 줄 주석 = 엄격 실패 → 관용 경로. 여기서 BOM 이 깨지면 nil 이 된다.
        let jsonc = Data(bom + Array("{\r\n\"a\": 1, // c\r\n\"b\": 2\r\n}".utf8))
        XCTAssertNil(try? JSONSerialization.jsonObject(with: jsonc), "전제: 엄격 파스 실패")
        let d = AssetJSON.dictionary(jsonc)
        XCTAssertEqual(d?["a"] as? Int, 1, "BOM + 주석 조합이 관용 경로에서 살아야 한다")
        XCTAssertEqual(d?["b"] as? Int, 2)
    }

    /// `rejectDupKeys = false`(`0x14009238b`) — jsoncpp 는 중복 키를 받고 **뒤가 이긴다**
    /// (`currentValue()[name] = …` 대입 의미).
    ///
    /// **[2026-08-21 정정] "Foundation 도 뒤가 이긴다 → 일치" 는 틀렸다.** 이 테스트의 원래 판은
    /// 리눅스에서 통과하고 **macOS CI 에서 깨졌다**(run 32492467832 job 96803096432, 커밋
    /// `1bc9835` — `("Optional(1)") is not equal to ("Optional(2)")`, 141행과 143행 둘 다).
    /// 즉 실측 결과는 이렇다:
    ///
    /// | | `{"a":1,"a":2}` → `a` |
    /// | --- | --- |
    /// | WE(jsoncpp) | **2** (뒤가 이긴다) |
    /// | swift-corelibs-foundation (리눅스) | **2** |
    /// | Apple Foundation (macOS) | **1** (앞이 이긴다) |
    ///
    /// **그래서 macOS 의 Waple 은 이 한 축에서 WE 와 갈린다.** 고치려면 파스 전에 중복 키를
    /// 훑어 뒤를 남기는 전처리가 필요한데, 모든 자산 JSON 에 그 비용을 물리는 변경이다.
    /// 도달을 재 보면 **자산 트리 0건 · 설치본 `locale/ui_en-us.json` 1건**이고 그 파일은
    /// `AssetJSON` 소비자가 읽지 않는다(편집기 UI 문자열이다). 그래서 **[미해결]로 두고
    /// 거동을 기록만 한다** — 워크샵 코퍼스는 이 컨테이너에 없어 도달을 못 쟀다.
    ///
    /// 이 자리는 **리눅스 코어 테스트가 권위가 없는 축**이라는 실례이기도 하다.
    /// `AssetJSON` 은 두 Foundation 구현 위에서 답이 다르므로, 여기서 초록이라고 macOS 가
    /// 초록인 것이 아니다(`scripts/dev/linux-core-tests.sh` 머리말의 한계 절 참조).
    func testDuplicateKeysWinnerIsPlatformDependent() {
        #if canImport(Darwin)
        let expected = 1   // Apple Foundation — 앞이 이긴다 (WE 와 갈린다)
        #else
        let expected = 2   // swift-corelibs-foundation — 뒤가 이긴다 (WE 와 같다)
        #endif
        XCTAssertEqual(AssetJSON.dictionary(Data(#"{"a":1,"a":2}"#.utf8))?["a"] as? Int, expected)
        // 관용 경로(주석 때문에 엄격 실패)를 타도 **같은 플랫폼 승자**여야 한다 — 관용 전처리가
        // 중복 키 순서를 뒤집으면 안 된다는 뜻이다. 원래 판은 여기서도 함께 깨졌다(143행).
        XCTAssertEqual(AssetJSON.dictionary(Data("{\"a\":1,//c\n\"a\":2}".utf8))?["a"] as? Int, expected)
    }

    /// `allowSpecialFloats = false`(`0x1400923dd`) · `allowSingleQuotes = false`(`0x1400922c1`) ·
    /// `allowNumericKeys = false`(`0x14009227b`) — 실물이 거부하는 것은 우리도 거부해야 한다.
    /// **관용을 넓히다가 이쪽이 통과하기 시작하면 실물보다 관대해진 것**이다.
    func testRealAlsoRejectsTheseSoWeMustToo() {
        XCTAssertNil(AssetJSON.dictionary(Data(#"{"a":NaN}"#.utf8)), "allowSpecialFloats=false")
        XCTAssertNil(AssetJSON.dictionary(Data(#"{"a":Infinity}"#.utf8)))
        XCTAssertNil(AssetJSON.dictionary(Data(#"{"a":-Infinity}"#.utf8)))
        XCTAssertNil(AssetJSON.dictionary(Data("{'a':1}".utf8)), "allowSingleQuotes=false")
        XCTAssertNil(AssetJSON.dictionary(Data("{1:2}".utf8)), "allowNumericKeys=false")
    }

    /// **우리가 더 엄격한 두 갈래(의도적, 도달 0건).**
    /// `failIfExtra = false`(`0x140092351`)라 실물은 루트 뒤 잔여 바이트를 무시하고,
    /// `strictRoot = false`(`0x140092195`)라 스칼라 루트도 받는다. 우리는 둘 다 거부한다 —
    /// 자산 리더는 전부 컨테이너 루트를 기대하고, 잔여 바이트 관용은 잘린 파일을 조용히
    /// 통과시키는 쪽으로 작동한다. 이 테스트는 그 선택을 **기록**하는 것이지 옳다고 주장하는
    /// 것이 아니다 — 워크샵에서 도달이 나오면 뒤집을 근거가 된다.
    func testWeAreDeliberatelyStricterThanRealOnRootShape() {
        XCTAssertNil(AssetJSON.object(Data(#"{"a":1} trailing"#.utf8)), "failIfExtra=false 인데 우리는 거부")
        XCTAssertNil(AssetJSON.object(Data("42".utf8)), "strictRoot=false 인데 우리는 거부")
        XCTAssertNotNil(AssetJSON.object(Data("[1,2]".utf8)), "배열 루트는 양쪽 다 허용")
    }

    /// 동봉 자산 전건 회귀 — 엄격 파스가 실패하는 자산이 **전부** 관용으로 복구돼야 한다.
    /// `WAPLE_WE_ASSETS` 가 없으면(외부 체크아웃) 조용히 건너뛴다.
    func testEveryBundledAssetRecoversWithLeniency() throws {
        guard let root = Self.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var total = 0, needed = 0, failed: [String] = []
        for case let url as URL in en where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            total += 1
            if (try? JSONSerialization.jsonObject(with: data)) != nil { continue }
            needed += 1
            if AssetJSON.object(data) == nil { failed.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(total, 1000, "자산 트리가 비었다 — 경로가 틀린 것")
        XCTAssertGreaterThan(needed, 20, "관용이 필요한 자산이 0 이면 판정 자체가 무의미하다")
        XCTAssertEqual(failed, [], "관용 파스가 못 살린 자산")
    }

    /// 동봉 자산 루트. `WAPLE_WE_ASSETS`(리눅스 하네스가 넣는다) → 상위 디렉터리 탐색 순.
    static func bundledAssetsRoot() -> URL? {
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

    /// **스코프 라벨을 붙인 JSONC 인구조사 — 동봉 WEAssets 단독.**
    ///
    /// 2026-08-21 재측정: 동봉 WEAssets `.json` **1,698**개 중 JSONC 는 **31**개
    /// (줄 주석 **27** + 트레일링 콤마 **4**, 겹침 0)이고 그 31개는 **전건 CRLF** 다.
    /// 블록 주석·BOM 은 **0건**.
    ///
    /// 다른 스코프는 여기서 재지 않는다(CI 에 설치본이 없다) — 설치본
    /// `wallpaper_engine/assets` 는 동봉본과 바이트 동일이라 같은 31, `projects/` 가 1
    /// (`defaultprojects/fantasticcar/materials/car/glass.json`)을 더해 **설치본 32**,
    /// 합 **63** 이다. 그 63 도 전건 CRLF 다.
    ///
    /// **[중요] "JSONC 31" 과 "엄격 파스가 실패하는 31" 은 같은 수가 아니다.**
    /// 이 세션에서 잰 리눅스 `swift-corelibs-foundation` 의 `JSONSerialization` 은
    /// **트레일링 콤마를 그냥 받는다** — 그래서 이 플랫폼에서 엄격 파스가 실패하는 것은
    /// 줄 주석 **27**건뿐이다. Darwin `NSJSONSerialization` 은 RFC 엄격이라 31건 전부
    /// 실패한다고 알려져 있으나 이 세션에서 macOS 를 돌릴 수단이 없다(**추정**).
    /// `scripts/spec/check_lenient_json_reach.py` 와 `scripts/re/bundled_key_coverage.py` 가
    /// 말하는 "31" 은 **파이썬 `json.loads` 기준**이라 그쪽은 항상 31 이다.
    /// 그래서 아래 단정은 **문법 스캔**(플랫폼 무관)으로 하고, 플랫폼 파서 쪽은 범위로만 잠근다.
    ///
    /// 이 수가 틀어지면 자산 트리가 재벤더링된 것이다 — 그때 `docs/re/bundled-key-coverage.md`
    /// §8 과 `scripts/spec/check_lenient_json_reach.py` 의 `MIN_LENIENT_NEEDED` 도 같이 갱신해라.
    func testBundledJSONCCensusIsExactlyTwentySevenCommentsAndFourTrailingCommas() throws {
        guard let root = Self.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var total = 0, lineComment = 0, trailingComma = 0, blockComment = 0
        var bom = 0, jsonc = 0, jsoncCRLF = 0, strictFails = 0, recovered = 0
        for case let url as URL in en where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            total += 1
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { bom += 1 }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let f = Self.jsoncFeatures(text)
            if f.line { lineComment += 1 }
            if f.trailing { trailingComma += 1 }
            if f.block { blockComment += 1 }
            if f.line || f.trailing || f.block {
                jsonc += 1
                if text.contains("\r\n") { jsoncCRLF += 1 }
            }
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                strictFails += 1
                if AssetJSON.object(data) != nil { recovered += 1 }
            }
        }
        // ── 문법 스캔(플랫폼 무관) ──
        XCTAssertEqual(total, 1698, "동봉 WEAssets `.json` 파일 수")
        XCTAssertEqual(lineComment, 27, "줄 주석 `//` 을 가진 동봉 자산")
        XCTAssertEqual(trailingComma, 4, "트레일링 콤마를 가진 동봉 자산")
        XCTAssertEqual(blockComment, 0, "블록 주석은 0건 — 그래서 `relaxed` 가 지원하지 않는다")
        XCTAssertEqual(bom, 0, "동봉 트리에 BOM 자산은 없다")
        XCTAssertEqual(jsonc, 31, "JSONC 총계 = 27 + 4(겹침 0)")
        XCTAssertEqual(jsoncCRLF, jsonc, "JSONC 는 **전건 CRLF** — 그게 이 경로가 실전에서 깨져 있던 이유")
        // ── 플랫폼 파서(범위로만) ──
        XCTAssertGreaterThanOrEqual(strictFails, 27, "줄 주석은 어느 플랫폼에서도 엄격 파스를 깬다")
        XCTAssertLessThanOrEqual(strictFails, 31, "많아야 JSONC 전건")
        XCTAssertEqual(recovered, strictFails, "엄격이 깨진 것은 **전부** 관용으로 복구돼야 한다")
    }

    /// JSONC 문법 스캔 — 문자열 리터럴 밖에서 `//` · `/* */` · `,` 뒤 `]`/`}` 를 찾는다.
    /// 파서를 타지 않으므로 플랫폼 무관이다.
    private static func jsoncFeatures(_ text: String) -> (line: Bool, block: Bool, trailing: Bool) {
        var line = false, block = false, trailing = false
        var inString = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if c == "\\" {
                    let n = text.index(after: i)
                    if n < text.endIndex { i = text.index(after: n); continue }
                } else if c == "\"" { inString = false }
                i = text.index(after: i); continue
            }
            if c == "\"" { inString = true; i = text.index(after: i); continue }
            if c == "/" {
                let n = text.index(after: i)
                if n < text.endIndex {
                    if text[n] == "/" { line = true }
                    if text[n] == "*" { block = true }
                }
            }
            if c == "," {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] == " " || text[j] == "\t" || text[j].isNewline {
                    j = text.index(after: j)
                }
                if j < text.endIndex, text[j] == "]" || text[j] == "}" { trailing = true }
            }
            i = text.index(after: i)
        }
        return (line, block, trailing)
    }

}
