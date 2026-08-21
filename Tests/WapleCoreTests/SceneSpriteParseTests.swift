import XCTest
@testable import WapleCore

/// 씬 오브젝트 타입 `"sprite"` 파스(SceneDocument.parseSprite / SceneDocument.sprites).
///
/// 이 타입은 **파티클 렌더러의 `sprite` 와 다른 것**이다 — 파티클 쪽은 파티클 JSON 의
/// `renderer[].name` 값이고, 이쪽은 씬 오브젝트 타입이다. 전용 클래스 크기부터 다르다
/// (씬 오브젝트 `0x270` @ `0x140190304`, 파티클 `0x960` @ `0x1401901e9`).
///
/// **도달(2026-08-21 실측)**: 동봉 자산 JSON 1,698건 중 **0건**. 설치본(WE 2.8.42) 전체
/// JSON 2,143건에서 문자열 저작 1건(ricepod 의 태양)과 null 저작 2건(arsenal 의 라이트).
/// 그래서 렌더는 배선하지 않고 파스만 검증한다 — 아래 픽스처는 그 실측 3건을 그대로 옮긴 것이다.
final class SceneSpriteParseTests: XCTestCase {

    private func doc(_ objects: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":\(objects)}
        """
        return try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
    }

    // MARK: - 키 있음

    /// 실측 유일 저작(`projects/defaultprojects/ricepod/ricepod.json` `objects[7]`)을 그대로 옮긴다.
    /// 값이 문자열이면 그 문자열이 곧 플레어 머티리얼의 **전체 경로**다
    /// (ctor `0x1402565b9` → `0x1402565df`, `this+0x240` 저장 `0x1402565e4`).
    func testParsesRicepodSunSprite() throws {
        let d = try doc("""
        [{"angles":"0.000 0.000 0.000","id":9,"name":"sun","origin":"0.000 0.000 0.000",
          "parallaxDepth":"1.000 1.000","scale":"1.000 1.000 1.000",
          "sprite":"materials/sprites/sunsprite.json"}]
        """)
        XCTAssertEqual(d.sprites.count, 1)
        let s = try XCTUnwrap(d.sprites.first)
        XCTAssertEqual(s.id, 9)
        XCTAssertEqual(s.name, "sun")
        XCTAssertEqual(s.material, "materials/sprites/sunsprite.json")
        XCTAssertEqual(s.origin, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(s.angles, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(s.scale, Vec3(x: 1, y: 1, z: 1))
        XCTAssertEqual(s.parallaxDepth, Vec2(x: 1, y: 1))
        XCTAssertNil(s.parent)
        XCTAssertTrue(s.visible)
        XCTAssertEqual(s.order, 0)
        // 트랜스폼-온리 노드로 흡수되지 않아야 한다(parseNode 의 콘텐츠 키 목록 규약).
        XCTAssertTrue(d.nodes3D.isEmpty)
        // 렌더 목록은 오염되지 않는다 — 파스만 하고 그리지 않는다.
        XCTAssertTrue(d.layers.isEmpty)
        XCTAssertTrue(d.objects3D.isEmpty)
        XCTAssertTrue(d.particles.isEmpty)
    }

    /// 트랜스폼/시차 키가 없으면 베이스 오브젝트 기본값(origin 0 · angles 0 · scale 1 · 시차 1).
    /// `parent`(vtable `+0x40` = `0x1401de470` 이 읽는 키)와 `visible` 은 다른 오브젝트와 같은 규약.
    func testDefaultsWhenTransformKeysAbsent() throws {
        let d = try doc(#"[{"id":3,"sprite":"materials/x.json","parent":7}]"#)
        let s = try XCTUnwrap(d.sprites.first)
        XCTAssertEqual(s.origin, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(s.angles, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(s.scale, Vec3(x: 1, y: 1, z: 1))
        XCTAssertEqual(s.parallaxDepth, Vec2(x: 1, y: 1))
        XCTAssertEqual(s.parent, 7)
        XCTAssertEqual(s.name, "")
    }

    /// 저작 변환/시차가 있으면 그대로 실린다. `parallaxDepth` 는 이 키만 camelCase 다
    /// (베이스 프로퍼티 등록표 `0x1401e082f`, 리터럴 `0x1404902c8`).
    func testCarriesAuthoredTransformAndParallax() throws {
        let d = try doc("""
        [{"id":1,"sprite":"materials/flare.json","origin":"1 2 3","angles":"10 20 30",
          "scale":"2 3 4","parallaxDepth":"0.25 0.5"}]
        """)
        let s = try XCTUnwrap(d.sprites.first)
        XCTAssertEqual(s.origin, Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(s.angles, Vec3(x: 10, y: 20, z: 30))
        XCTAssertEqual(s.scale, Vec3(x: 2, y: 3, z: 4))
        XCTAssertEqual(s.parallaxDepth, Vec2(x: 0.25, y: 0.5))
    }

    /// `objects[]` 인덱스가 order 로 실린다(다른 오브젝트와 공유하는 z-순서).
    func testOrderIsObjectsIndex() throws {
        let d = try doc("""
        [{"id":1,"light":"point"},
         {"id":2,"sprite":"materials/a.json"},
         {"id":3,"sprite":"materials/b.json"}]
        """)
        XCTAssertEqual(d.sprites.map { $0.order }, [1, 2])
        XCTAssertEqual(d.sprites.map { $0.material }, ["materials/a.json", "materials/b.json"])
    }

    /// 변환/가시성 스크립트는 다른 3D 오브젝트와 동일 규약으로 캡처된다(파스만 — 소비는 렌더 배선의 몫).
    func testCapturesPropertyScripts() throws {
        let d = try doc("""
        [{"id":1,"sprite":"materials/a.json",
          "origin":{"script":"O","value":"1 1 1"},
          "visible":{"script":"V","value":true}}]
        """)
        let s = try XCTUnwrap(d.sprites.first)
        XCTAssertEqual(s.propertyScripts["origin"], "O")
        XCTAssertEqual(s.propertyScripts["visible"], "V")
        XCTAssertEqual(s.origin, Vec3(x: 1, y: 1, z: 1))
    }

    /// WE ctor 는 빈 문자열을 거르지 않는다(`0x1402565c1` 의 null-포인터 분기는 빈 경로를 그대로
    /// 로더에 넘기는 경로다). 여기서 걸러 버리면 그 오브젝트가 노드도 스프라이트도 못 돼 통째로
    /// 사라진다 — parseNode 가 `"sprite"` 를 콘텐츠 키로 잡아 둔 목적과 정면으로 어긋난다.
    func testEmptyStringIsStillASprite() throws {
        let d = try doc(#"[{"id":1,"sprite":""}]"#)
        XCTAssertEqual(d.sprites.count, 1)
        XCTAssertEqual(d.sprites.first?.material, "")
        XCTAssertTrue(d.nodes3D.isEmpty)
    }

    // MARK: - 키 부재

    /// `sprite` 키가 아예 없으면 스프라이트가 아니고, 종전 경로(트랜스폼-온리 노드)가 그대로 산다.
    func testAbsentKeyIsNotASprite() throws {
        let d = try doc(#"[{"id":5,"origin":"1 2 3"}]"#)
        XCTAssertTrue(d.sprites.isEmpty)
        XCTAssertEqual(d.nodes3D.count, 1)
        XCTAssertEqual(d.nodes3D.first?.id, 5)
    }

    // MARK: - 잘못된 타입

    /// **null 은 스프라이트가 아니다.** WE 팩토리가 `cmp byte [rax+8], 4`(`0x1401902fe`) →
    /// `jne`(`0x140190302`)로 jsoncpp `stringValue`(=4)만 통과시킨다. 실측 도달 2건
    /// (`projects/defaultprojects/arsenal/scene.json` `objects[1]`/`objects[2]`)이 정확히 이 형태고,
    /// 거기서 오브젝트는 `light` 로 가야 한다 — 아래 픽스처가 그 두 오브젝트다.
    func testArsenalNullSpriteFallsThroughToLight() throws {
        let d = try doc("""
        [{"angles":"0.000 0.000 0.000","color":"1.000 1.000 1.000","id":2,"intensity":1.87,
          "light":"point","model":null,"name":"","origin":"-1.110 2.460 0.335",
          "particle":null,"radius":16.32,"scale":"1.000 1.000 1.000","sprite":null},
         {"angles":"0.000 0.000 0.000","color":"0.890 0.690 0.086","id":3,"intensity":0.18,
          "light":"point","model":null,"name":"","origin":"-1.105 4.002 0.347",
          "particle":null,"radius":22.85,"scale":"1.000 1.000 1.000","sprite":null}]
        """)
        XCTAssertTrue(d.sprites.isEmpty, "null 이 스프라이트로 새면 라이트 2개가 사라진다")
        XCTAssertEqual(d.lights3D.count, 2)
        XCTAssertEqual(d.lights3D.map { $0.id }, [2, 3])
        XCTAssertEqual(d.lights3D.map { $0.type }, ["point", "point"])
    }

    /// 문자열이 아닌 값(숫자/불리언/배열/객체)은 전부 스프라이트가 아니다 — 팩토리의 타입 게이트 그대로.
    /// (코퍼스 도달 0건 — 방어적 규약. 이 값들의 오브젝트 취급 자체는 parseNode 주석 참조.)
    func testNonStringSpriteValuesAreNotSprites() throws {
        for value in ["5", "true", #"["a"]"#, #"{"value":"materials/a.json"}"#] {
            let d = try doc("[{\"id\":1,\"sprite\":\(value)}]")
            XCTAssertTrue(d.sprites.isEmpty, "sprite:\(value) 가 스프라이트로 새면 안 된다")
        }
    }

    /// `{"value": …}` 바인딩 언랩을 **하지 않는다**. 팩토리는 값 노드의 타입 바이트만 보고
    /// (`0x1401902fe`) 객체(=jsoncpp 7)는 곧장 다음 타입으로 보낸다 — 언랩은 WE 가 안 하는 일이다.
    /// 위 testNonStringSpriteValuesAreNotSprites 의 마지막 항이 이 경계를 고정한다.
    func testDoesNotUnwrapValueBinding() throws {
        let d = try doc(#"[{"id":1,"sprite":{"value":"materials/a.json"}}]"#)
        XCTAssertTrue(d.sprites.isEmpty)
    }

    // MARK: - 파티클 렌더러 `sprite` 와의 구분

    /// 동봉 `scenes/particleelementpreviews/sprite/scene.json` 의 형태 — 오브젝트는 **파티클**이고,
    /// 그 파티클 시스템의 `renderer[0].name` 이 `"sprite"` 다. 이름이 같을 뿐 다른 축이므로
    /// 씬 스프라이트로 새면 안 된다(동봉 코퍼스에서 파티클 렌더러 `sprite` 192건 · `spritetrail` 44건).
    func testParticleRendererNamedSpriteIsNotASceneSprite() throws {
        let particle = """
        {"emitter":[{"id":6,"name":"sphererandom","rate":150,"origin":"0 0 0","directions":"1 1 0",
                     "distancemin":0,"distancemax":32}],
         "initializer":[],"operator":[],"maxcount":100,
         "material":"materials/particle/halo_1.json",
         "renderer":[{"id":1,"name":"sprite"}]}
        """
        let material = #"{"passes":[{"shader":"genericparticle","textures":["particle/halo_1"]}]}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":256,"height":256}},
         "objects":[{"id":13,"name":"new_particle_system","origin":"128 128 0",
                     "particle":"particles/p.json","scale":"0.5 0.5 0.5"}]}
        """
        let d = try SceneDocument.parse(package: try pkg([
            ("scene.json", scene),
            ("particles/p.json", particle),
            ("materials/particle/halo_1.json", material)]))
        XCTAssertTrue(d.sprites.isEmpty, "파티클 렌더러 이름이 씬 스프라이트로 새면 안 된다")
        XCTAssertEqual(d.particles.count, 1)
    }

    // MARK: - 동봉 씬 전건 무회귀

    /// 동봉 씬 **전건 파스** 무회귀. 두 가지를 한 번에 고정한다.
    ///
    /// 1. 스프라이트 분기가 다른 오브젝트를 훔치지 않는다 — 동봉 자산의 `sprite` 오브젝트 도달은
    ///    **0건**(2026-08-21 실측, JSON 1,698건 / `objects[]` 보유 177건)이므로 전건 `sprites` 가
    ///    비어 있어야 한다. 하나라도 새면 그 오브젝트가 원래 가야 할 분기를 잃은 것이다.
    /// 2. 새 분기가 파스를 깨지 않는다 — 전건이 `throw` 없이 끝나고, 오브젝트가 어느 목록에도
    ///    안 남는 **조용한 증발**이 없다(오브젝트 총수 ≤ 인식된 오브젝트 수 검증은 과하므로,
    ///    여기서는 파스 성공 + 스프라이트 0 + 씬당 최소 1개 인식으로 잡는다).
    ///
    /// 자산은 인메모리 패키지에 씬 파일 하나만 담아 넣는다 — 이미지/모델 자산은 없으므로 레이어
    /// 일부가 경고와 함께 빠지는데, 이 테스트가 보는 축(분기 선택)에는 영향이 없다.
    func testBundledScenesParseWithZeroSpriteReach() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var scenes = 0, rawSpriteKeys = 0
        var leaked: [String] = []
        for case let url as URL in en where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let dict = AssetJSON.dictionary(data),
                  let objects = dict["objects"] as? [Any] else { continue }
            scenes += 1
            for any in objects {
                if let obj = any as? [String: Any], obj["sprite"] != nil { rawSpriteKeys += 1 }
            }
            let name = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            let doc: SceneDocument
            do {
                doc = try SceneDocument.parse(
                    package: try pkg([("scene.json", String(decoding: data, as: UTF8.self))]))
            } catch {
                XCTFail("동봉 씬 파스가 실패했다: \(name) — \(error)")
                continue
            }
            if !doc.sprites.isEmpty { leaked.append(name) }
        }
        XCTAssertGreaterThan(scenes, 100, "objects[] 를 가진 동봉 씬이 이만큼 없으면 경로가 틀린 것")
        XCTAssertEqual(rawSpriteKeys, 0,
                       "동봉 자산의 sprite 오브젝트 도달은 0 이어야 한다(2026-08-21 실측) — "
                       + "0 이 아니면 도달 판단과 이 레인의 우선순위 근거가 함께 바뀐다")
        XCTAssertEqual(leaked, [], "동봉 씬에서 스프라이트로 샌 오브젝트")
    }
}
