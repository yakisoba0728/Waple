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
}
