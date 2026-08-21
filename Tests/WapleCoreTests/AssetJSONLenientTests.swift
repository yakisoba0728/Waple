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
}
