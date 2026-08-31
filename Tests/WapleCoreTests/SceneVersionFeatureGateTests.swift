import XCTest
@testable import WapleCore

/// scene.json 최상위 `version` 은 general 키 소비를 **게이트하지 않는다** — 키 존재 여부가 유일한
/// 판정 기준이다(2026-08-30 전환).
///
/// **[2026-08-30 전면 반전 — 이 스위트는 종전에 틀린 동작을 잠그고 있었다]**
///
/// 종전 이 파일(2026-08-25)은 `SceneDocument.versionGatedGeneral` 이 v3 미만 씬에서 `hdr`·`zoom`·
/// `bloomhdr*`·`bloomtint`·`perspectiveoverridefov` 를, v4 미만에서 `wind*`·`gravity*` 를
/// **삭제하는 것**을 오라클로 못 박았다 — 예를 들어 `testSameKeysIgnoredAtV1ButConsumedAtA5` 는
/// `hdr:true` 가 저작된 general 블록에 대해 `XCTAssertFalse(v1.hdr)` 를 단언했다.
/// 근거는 짝 저장소 `corpus_scan/scene-json-schema.md:189` 한 줄이었다 —
/// "pre-v3 scenes lack HDR/zoom; pre-v4 lack wind/gravity."
///
/// **그 줄이 취소선으로 철회됐다.** 짝 저장소 커밋 `0bb963ed`(2026-08-28, HEAD 의 조상)가 같은
/// 파일 `:189-201` 에 "**[CORRECTED 2026-08-28 — the corpus refutes this, and a consumer was built
/// on it.]** `version` does **not** gate those keys." 를 붙이고 소비자로 `SceneDocument.swift` 의
/// 그 함수를 명시했다. 이 리포 자신의 정본 `spec/corpus/scene-schema.json` 으로도 반증된다 —
/// version {5:63, 1:33, 4:32, 3:31, None:3}(162씬, v≥3 은 126 · v≥4 는 95)인데 `hdr`/`zoom` 은
/// 159씬, wind/gravity 는 109씬이 저작한다. 비둘기집으로 **최소 33씬이 v3 미만인데 `hdr` 을,
/// 최소 14씬이 v4 미만인데 wind 를** 갖는다. 게이트는 어느 방향으로도 성립할 수 없다.
///
/// 그래서 함수와 호출부를 걷어냈고(그 자리의 날짜 붙은 묘비가 근거를 보존한다),
/// **이 스위트는 지우는 대신 뒤집었다** — 오라클을 잃지 않는 쪽이 우선이라는 판단이다.
/// 지금 단언하는 것은 정반대다: **version 이 무엇이든 저작된 키는 살아남고, 미저작 키만
/// 생성자 기본값에 착지한다.** 게이트가 되살아나면 아래 v1/v3 케이스가 즉시 빨개진다.
final class SceneVersionFeatureGateTests: XCTestCase {

    private let emptyObjects = #""objects":[]"#

    /// 종전 게이트가 지웠던 14키가 전부 저작된 general 블록. 값은 전부 생성자 기본값과 다르게 잡아
    /// "소비됐다" 와 "무시됐다" 가 어느 쪽으로도 오판되지 않게 한다(반전 후에도 같은 성질이 필요하다 —
    /// 기본값과 같은 값을 넣으면 게이트가 되살아나도 초록이 나온다).
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

    /// 저작된 14키가 **version 과 무관하게** 전부 소비된다고 단언한다. 종전 오라클의 정확한 반전이다 —
    /// 이 함수의 옛 판본은 v1 에서 `XCTAssertFalse(v1.hdr)` 를 단언했다.
    ///
    /// v1 은 게이트가 있었다면 14키를 **전부** 떨어뜨렸을 세대이고, 실제 코퍼스에서 최소 33씬이
    /// 이 상태로 `hdr` 을 저작한다(머리말 산수). 즉 이 케이스가 곧 회귀 감시 지점이다.
    func testAuthoredKeysSurviveAtEveryVersion() throws {
        for version in [1, 3, 4, 5] {
            let doc = try parse(sceneJSON: """
            {"version":\(version),\(gatedGeneral)\(emptyObjects)}
            """)
            // v3+ 블록(종전 게이트가 v<3 에서 지웠던 9키) — 실렌더 소비처가 있는 절반이다.
            XCTAssertTrue(doc.hdr, "version \(version): 저작된 hdr 이 게이트로 떨어졌다")
            XCTAssertEqual(doc.zoom, 1.05, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.bloomHDRStrength, 1.4, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.bloomHDRThreshold, 0.70, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.bloomHDRFeather, 0.25, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.bloomHDRIterations, 6, "version \(version)")
            XCTAssertEqual(doc.bloomHDRScatter, 2.0, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.bloomTint, Vec3(x: 0.2, y: 0.4, z: 0.8), "version \(version)")
            XCTAssertEqual(doc.perspectiveOverrideFov, 90.760002, accuracy: 1e-5, "version \(version)")
            // v4+ 블록(종전 게이트가 v<4 에서 지웠던 5키) — 오늘 소비처가 없는 파스·보존 절반이지만
            // 파스 값 자체가 오라클이다(ParticleSimulator 가 받게 되면 그때 렌더에도 닿는다).
            XCTAssertTrue(doc.windEnabled, "version \(version): 저작된 windenabled 가 게이트로 떨어졌다")
            XCTAssertEqual(doc.windStrength, 2.5, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.windDirection.x, 0.707, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.windDirection.y, 0.707, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.gravityStrength, 3.5, accuracy: 1e-6, "version \(version)")
            XCTAssertEqual(doc.gravityDirection, Vec3(x: 0, y: -1, z: 0), "version \(version)")
        }
    }

    /// 게이트가 되살아나도 **똑같은 값이 나오는 세대에 속지 않도록**, v1 을 v5 와 직접 대조한다.
    /// 종전 이 대조는 "같은 키가 v1 에선 무시되고 v5 에선 소비된다" 를 단언했다 —
    /// 지금은 **두 세대의 문서가 동일해야** 한다(version 은 general 소비에 관여하지 않는다).
    func testV1AndV5ProduceIdenticalGeneralDocuments() throws {
        let v1 = try parse(sceneJSON: """
        {"version":1,\(gatedGeneral)\(emptyObjects)}
        """)
        let v5 = try parse(sceneJSON: """
        {"version":5,\(gatedGeneral)\(emptyObjects)}
        """)
        XCTAssertEqual(v1.hdr, v5.hdr)
        XCTAssertEqual(v1.zoom, v5.zoom, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRStrength, v5.bloomHDRStrength, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRThreshold, v5.bloomHDRThreshold, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRFeather, v5.bloomHDRFeather, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomHDRIterations, v5.bloomHDRIterations)
        XCTAssertEqual(v1.bloomHDRScatter, v5.bloomHDRScatter, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomTint, v5.bloomTint)
        XCTAssertEqual(v1.perspectiveOverrideFov, v5.perspectiveOverrideFov, accuracy: 1e-5)
        XCTAssertEqual(v1.windEnabled, v5.windEnabled)
        XCTAssertEqual(v1.windStrength, v5.windStrength, accuracy: 1e-6)
        XCTAssertEqual(v1.windDirection, v5.windDirection)
        XCTAssertEqual(v1.gravityStrength, v5.gravityStrength, accuracy: 1e-6)
        XCTAssertEqual(v1.gravityDirection, v5.gravityDirection)
    }

    /// 게이트 밖이었던 전씬 공통(core) 키 `bloom/bloomstrength/bloomthreshold`
    /// (scene-json-schema.md:38-42, 161/161)는 게이트 철회 뒤에도 그대로 소비된다.
    /// 종전 판본은 "게이트는 키 단위다" 를 지키던 테스트인데, 지금은 **철회가 이 셋을 건드리지
    /// 않았다**(수정 범위가 14키를 넘지 않았다)는 것을 지킨다 — 반전 후에도 오라클이 남는다.
    func testCoreBloomKeysStillConsumedAtV1() throws {
        let v1 = try parse(sceneJSON: """
        {"version":1,"general":{"orthogonalprojection":{"width":100,"height":100},
          "bloom":true,"bloomstrength":3.37,"bloomthreshold":0.36},"objects":[]}
        """)
        XCTAssertTrue(v1.bloom)
        XCTAssertEqual(v1.bloomStrength, 3.37, accuracy: 1e-6)
        XCTAssertEqual(v1.bloomThreshold, 0.36, accuracy: 1e-6)
    }

    /// version 누락(코퍼스 162씬 중 3건)과 비정수 version 은 종전에도 게이트 밖이었다 —
    /// 철회 뒤에는 **저작·미저작 씬 전부가** 그 자리에 놓인다. 이 테스트는 반전 전에는 사실상
    /// 무의미해질 수 있었으나(무게이트가 보편이 되므로), 저작 키와 **미저작 키의 기본값 착지**를
    /// 같은 문서에서 함께 단언해 오라클을 유지한다 — 키 부재가 여전히 기본값으로 떨어지는지가
    /// "존재 여부로 읽는다" 의 나머지 절반이다.
    func testMissingVersionConsumesAuthoredAndDefaultsUnauthored() throws {
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

        // 미저작 절반 — 14키를 하나도 적지 않은 v1 씬은 전부 생성자 기본값에 착지한다.
        // (기본값 출처는 SceneDocument 선언부 주석의 VA 실측.) 게이트 철회가 "키가 없어도 값이
        // 생긴다" 로 번지지 않았음을 고정한다.
        let bare = try parse(sceneJSON: """
        {"version":1,"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}
        """)
        XCTAssertFalse(bare.hdr)
        XCTAssertEqual(bare.zoom, 1, accuracy: 1e-6)
        XCTAssertEqual(bare.bloomHDRStrength, 2, accuracy: 1e-6)
        XCTAssertEqual(bare.bloomHDRThreshold, 1, accuracy: 1e-6)
        XCTAssertEqual(bare.bloomHDRFeather, 0.1, accuracy: 1e-6)
        XCTAssertEqual(bare.bloomHDRIterations, 8)
        XCTAssertEqual(bare.bloomHDRScatter, 1.619, accuracy: 1e-6)
        XCTAssertEqual(bare.perspectiveOverrideFov, 95, accuracy: 1e-6)
        XCTAssertFalse(bare.windEnabled)
        XCTAssertEqual(bare.windStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(bare.windDirection, Vec3(x: 0.707, y: 0.707, z: 0))
        XCTAssertEqual(bare.gravityStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(bare.gravityDirection, Vec3(x: 0, y: -1, z: 0))
    }
}
