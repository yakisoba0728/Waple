import XCTest
@testable import WapleCore

/// scene.json 최상위 `version` 기능 게이트(2026-08-25).
///
/// 근거(외부 코퍼스 관측, Waple-wallpaper-source 저장소):
/// `corpus_scan/scene-json-schema.md:20` — version 관측치 {1(33씬), 3(31), 4(32), 5(63)}, 누락 2씬.
/// 같은 문서 :60-72 가 `hdr`·`zoom`·`bloomhdr*`·`bloomtint`·`perspectiveoverridefov` 를
/// "version ≥ 3" 블록으로 묶고, :74-82 가 `wind*`·`gravity*` 를 "(version ≥ 4–5)" 로 묶으며,
/// :189 가 임계를 확정한다 — "pre-v3 scenes lack HDR/zoom; pre-v4 lack wind/gravity."
///
/// 종전 파서는 version 을 읽지 않고 이 키들을 무조건 소비했다 — v1 씬에 저작된 hdr/wind 값이
/// 기본값 대신 먹는 오차. 이 스위트는 **같은 general 블록을 version 만 바꿔** 대조한다:
/// v1 에선 무시(생성자 기본값 착지), v5 에선 소비. version 누락 시엔 종전 동작(무게이트
/// 전소비)을 유지한다 — WE 미관츠 행동이라 현행 보존(SceneDocument.versionGatedGeneral 주석).
final class SceneVersionFeatureGateTests: XCTestCase {

    private let emptyObjects = #""objects":[]"#

    /// v3+ / v4+ 키가 전부 저작된 general 블록. 값은 전부 생성자 기본값과 다르게 잡아
    /// "소비됐다" 와 "무시됐다" 가 어느 쪽으로도 오판되지 않게 한다.
    private let gatedGeneral = #"""
    "general":{"orthogonalprojection":{"width":100,"height":100},
      "hdr":true,"zoom":1.05,
      "bloomhdrstrength":1.4,"bloomhdrthreshold":0.70,"bloomhdrfeather":0.25,
      "bloomhdriterations":6,"bloomhdrscatter":2.0,
      "bloomtint":"0.2 0.4 0.8","perspectiveoverridefov":90.760002,
      "windenabled":true,"windstrength":2.5,"winddirection":"0.70700 0.70700 0.00000",
      "gravitystrength":3.5,"gravitydirection":"0.00000 -1.00000 0.00000"},
    """#

    private func parse(sceneJSON: String) throws -> SceneDocument {
        try SceneDocument.parse(package: pkg([("scene.json", sceneJSON)]))
    }

    /// 핵심 대조 — 같은 키가 version 1 에선 무시되고 version 5 에선 소비된다(scene-json-schema.md:189).
    func testSameKeysIgnoredAtV1ButConsumedAtA5() throws {
        let v1 = try parse(sceneJSON: """
        {"version":1,\(gatedGeneral)\(emptyObjects)}
        """)
        // v1 < 3 → v3+ 키 전부 무시, 생성자 기본값 착지(기본값 출처는 SceneDocument 선언부 주석의 VA 실측).
        XCTAssertFalse(v1.hdr)
        XCTAssertEqual(v1.zoom, 1, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRStrength, 2, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRThreshold, 1, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRFeather, 0.1, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRIterations, 8)
        XCTAssertEqual(v1.bloomHDRScatter, 1.619, accuracy: 1e-6)
        XCTAssertEqual(v1.perspectiveOverrideFov, 95, accuracy: 1e-6)
        // v1 < 4 → v4+ 키도 무시.
        XCTAssertFalse(v1.windEnabled)
        XCTAssertEqual(v1.windStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(v1.windDirection, Vec3(x: 0.707, y: 0.707, z: 0))
        XCTAssertEqual(v1.gravityStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(v1.gravityDirection, Vec3(x: 0, y: -1, z: 0))

        let v5 = try parse(sceneJSON: """
        {"version":5,\(gatedGeneral)\(emptyObjects)}
        """)
        // v5 ≥ 4 → 전부 소비.
        XCTAssertTrue(v5.hdr)
        XCTAssertEqual(v5.zoom, 1.05, accuracy: 1e-6)
        XCTAssertEqual(v5.bloomHDRStrength, 1.4, accuracy: 1e-6)
        XCTAssertEqual(v5.bloomHDRThreshold, 0.70, accuracy: 1e-6)
        XCTAssertEqual(v5.bloomHDRFeather, 0.25, accuracy: 1e-6)
        XCTAssertEqual(v5.bloomHDRIterations, 6)
        XCTAssertEqual(v5.bloomHDRScatter, 2.0, accuracy: 1e-6)
        XCTAssertEqual(v5.bloomTint, Vec3(x: 0.2, y: 0.4, z: 0.8))
        XCTAssertEqual(v5.perspectiveOverrideFov, 90.760002, accuracy: 1e-5)
        XCTAssertTrue(v5.windEnabled)
        XCTAssertEqual(v5.windStrength, 2.5, accuracy: 1e-6)
        XCTAssertEqual(v5.windDirection.x, 0.707, accuracy: 1e-6)
        XCTAssertEqual(v5.windDirection.y, 0.707, accuracy: 1e-6)
        XCTAssertEqual(v5.gravityStrength, 3.5, accuracy: 1e-6)
        XCTAssertEqual(v5.gravityDirection, Vec3(x: 0, y: -1, z: 0))
    }

    /// 중간 세대 경계 — v3 는 v3+ 키는 소비하고 v4+ 키(wind/gravity)만 무시한다(:74-82, :189).
    func testV3ConsumesHDRBlockButStillIgnoresWindGravity() throws {
        let v3 = try parse(sceneJSON: """
        {"version":3,\(gatedGeneral)\(emptyObjects)}
        """)
        XCTAssertTrue(v3.hdr)
        XCTAssertEqual(v3.zoom, 1.05, accuracy: 1e-6)
        XCTAssertEqual(v3.bloomHDRStrength, 1.4, accuracy: 1e-6)
        XCTAssertEqual(v3.perspectiveOverrideFov, 90.760002, accuracy: 1e-5)
        XCTAssertFalse(v3.windEnabled)
        XCTAssertEqual(v3.windStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(v3.windDirection, Vec3(x: 0.707, y: 0.707, z: 0))
        XCTAssertEqual(v3.gravityStrength, 1, accuracy: 1e-6)

        let v4 = try parse(sceneJSON: """
        {"version":4,\(gatedGeneral)\(emptyObjects)}
        """)
        XCTAssertTrue(v4.windEnabled)
        XCTAssertEqual(v4.windStrength, 2.5, accuracy: 1e-6)
        XCTAssertEqual(v4.gravityStrength, 3.5, accuracy: 1e-6)
    }

    /// 게이트는 키 단위다 — 전씬 공통(core) 키인 `bloom/bloomstrength/bloomthreshold`
    /// (scene-json-schema.md:38-42, 161/161)는 v1 에서도 그대로 소비된다.
    func testCoreBloomKeysSurviveAtV1() throws {
        let v1 = try parse(sceneJSON: """
        {"version":1,"general":{"orthogonalprojection":{"width":100,"height":100},
          "bloom":true,"bloomstrength":3.37,"bloomthreshold":0.36},"objects":[]}
        """)
        XCTAssertTrue(v1.bloom)
        XCTAssertEqual(v1.bloomStrength, 3.37, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomThreshold, 0.36, accuracy: 1e-6)
    }

    /// version 누락(관측 161씬 중 2건 — scene-json-schema.md:20)은 WE 미관츠 행동이라
    /// 종전 동작(무게이트 전소비)을 유지한다 — 게이트 도입이 누락 씬의 문서를 바꾸지 않음을 고정.
    /// 비정수 version(`true`)도 numericInt 의 엄격 판정으로 동일 취급한다.
    func testMissingOrNonNumericVersionKeepsLegacyUngatedBehavior() throws {
        let missing = try parse(sceneJSON: """
        {\(gatedGeneral)\(emptyObjects)}
        """)
        XCTAssertTrue(missing.hdr)
        XCTAssertEqual(missing.zoom, 1.05, accuracy: 1e-6)
        XCTAssertEqual(missing.bloomHDRStrength, 1.4, accuracy: 1e-6)
        XCTAssertTrue(missing.windEnabled)
        XCTAssertEqual(missing.windStrength, 2.5, accuracy: 1e-6)
        XCTAssertEqual(missing.gravityStrength, 3.5, accuracy: 1e-6)

        let nonNumeric = try parse(sceneJSON: """
        {"version":true,\(gatedGeneral)\(emptyObjects)}
        """)
        XCTAssertTrue(nonNumeric.hdr)
        XCTAssertTrue(nonNumeric.windEnabled)
    }
}
