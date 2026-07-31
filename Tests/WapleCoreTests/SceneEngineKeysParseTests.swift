import XCTest
@testable import WapleCore

/// 엔진(WE 2.8.42)이 읽지만 Waple 이 버리던 scene.json 키 파스 추가 검증(2026-07-28):
/// - general.clearenabled/camerafade/windenabled/windstrength/winddirection/gravitystrength/
///   gravitydirection (analysis/strings/json-keys.txt:667/686/696-700)
/// - 텍스트 오브젝트 depthtest (corpus_scan/scene-json-schema.md:123 — 머티리얼 패스 키와 별개)
/// - 머티리얼 패스 alphawriting (json-keys.txt:622)
/// - 사운드 spatialization/attenuation/mindistance (json-keys.txt:935/933/928) + sound 단수 문자열
///   관용(scene-json-schema.md:141 "path to audio entry" 단수형 기술)
/// - F057: 텍스트 자식의 부모 회전(angleZ) 상속(텍스트→텍스트 체인 포함)
/// 기본값은 전부 항등(키 부재 시 종전 동작과 동치)이어야 한다.
final class SceneEngineKeysParseTests: XCTestCase {

    private func doc(_ scene: String, _ extra: [(String, String)] = []) throws -> SceneDocument {
        try SceneDocument.parse(package: pkg([("scene.json", scene)] + extra))
    }

    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
    private let emptyScene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#

    // MARK: general 키

    /// general 신규 키 파스 — 실측 코퍼스 형태 그대로(direction 은 "x y z" vec3 문자열, 109/161씬).
    func testGeneralEngineKeysParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "clearenabled":false,"camerafade":false,
          "windenabled":true,"windstrength":2.5,"winddirection":"0.70700 0.70700 0.00000",
          "gravitystrength":3.5,"gravitydirection":"0.00000 -1.00000 0.00000"},"objects":[]}
        """
        let d = try doc(scene)
        XCTAssertFalse(d.clearEnabled)
        XCTAssertFalse(d.cameraFade)
        XCTAssertTrue(d.windEnabled)
        XCTAssertEqual(d.windStrength, 2.5, accuracy: 1e-6)
        XCTAssertEqual(d.windDirection.x, 0.707, accuracy: 1e-6)
        XCTAssertEqual(d.windDirection.y, 0.707, accuracy: 1e-6)
        XCTAssertEqual(d.windDirection.z, 0, accuracy: 1e-6)
        XCTAssertEqual(d.gravityStrength, 3.5, accuracy: 1e-6)
        XCTAssertEqual(d.gravityDirection, Vec3(x: 0, y: -1, z: 0))
    }

    /// 키 부재 시 항등(종전 동작과 동치) — 기본값은 코퍼스 전건 모달값(에디터 기본 저작치).
    func testGeneralEngineKeysDefaultsWhenAbsent() throws {
        let d = try doc(emptyScene)
        XCTAssertTrue(d.clearEnabled)
        XCTAssertTrue(d.cameraFade)
        XCTAssertFalse(d.windEnabled)
        XCTAssertEqual(d.windStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(d.windDirection, Vec3(x: 0.707, y: 0.707, z: 0))
        XCTAssertEqual(d.gravityStrength, 1, accuracy: 1e-6)
        XCTAssertEqual(d.gravityDirection, Vec3(x: 0, y: -1, z: 0))
    }

    // MARK: 텍스트 depthtest / 머티리얼 alphawriting

    /// 텍스트 오브젝트 depthtest — 실측 코퍼스는 문자열("enabled" 1394건)이 정본, 불리언도 관용.
    func testTextDepthTestParsesStringAndBoolForms() throws {
        func textLayer(_ obj: String) throws -> SceneTextLayer {
            let d = try doc("""
            {"general":{"orthogonalprojection":{"width":100,"height":100}},
             "objects":[\(obj)]}
            """)
            return try XCTUnwrap(d.texts.first)
        }
        // 부재 → true(항등)
        XCTAssertTrue(try textLayer(#"{"id":1,"text":"A"}"#).depthTest)
        // 문자열(실측 정본): enabled → true / disabled → false
        XCTAssertTrue(try textLayer(#"{"id":1,"text":"A","depthtest":"enabled"}"#).depthTest)
        XCTAssertFalse(try textLayer(#"{"id":1,"text":"A","depthtest":"disabled"}"#).depthTest)
        // 불리언 형태 관용
        XCTAssertFalse(try textLayer(#"{"id":1,"text":"A","depthtest":false}"#).depthTest)
        XCTAssertTrue(try textLayer(#"{"id":1,"text":"A","depthtest":true}"#).depthTest)
    }

    /// 머티리얼 패스 alphawriting("default"|"enabled" — 코퍼스 806엔트리 중 enabled 16건). 파스만.
    func testMaterialPassAlphaWritingParses() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"8 8"}]}
        """
        let enabled = try doc(scene, [("models/x.json", model),
                                      ("materials/m.json", #"{"passes":[{"alphawriting":"enabled","textures":["pic"]}]}"#)])
        XCTAssertEqual(enabled.layers.first?.alphaWriting, "enabled")
        // 부재 → "default"(항등)
        let plain = try doc(scene, [("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(plain.layers.first?.alphaWriting, "default")
    }

    // MARK: 사운드

    /// 사운드 공간화 키 파스(실측 3737268876 형태) + 부재 시 기본(false/1/1 = 비공간화 현행과 동치).
    func testSoundSpatialKeysParseAndDefaults() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"sound":["sounds/a.mp3"],"spatialization":true,"attenuation":0.5,"mindistance":2.0},
           {"id":2,"sound":["sounds/b.mp3"]}]}
        """
        let d = try doc(scene)
        XCTAssertEqual(d.sounds.count, 2)
        let s1 = try XCTUnwrap(d.sounds.first { $0.id == 1 })
        XCTAssertTrue(s1.spatialization)
        XCTAssertEqual(s1.attenuation, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s1.minDistance, 2.0, accuracy: 1e-6)
        let s2 = try XCTUnwrap(d.sounds.first { $0.id == 2 })
        XCTAssertFalse(s2.spatialization)
        XCTAssertEqual(s2.attenuation, 1, accuracy: 1e-6)
        XCTAssertEqual(s2.minDistance, 1, accuracy: 1e-6)
    }

    /// sound 가 배열이 아니라 단수 경로 문자열(scene-json-schema.md:141)이어도 1개짜리 사운드로 파스
    /// — 종전엔 배열 전용 게이트가 문자열 형태를 조용히 누락시켰다.
    func testSoundSingleStringPathParses() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":9,"name":"bgm","sound":"sounds/x.mp3","volume":0.4,"playbackmode":"loop"}]}
        """
        let d = try doc(scene)
        let s = try XCTUnwrap(d.sounds.first)
        XCTAssertEqual(d.sounds.count, 1)
        XCTAssertEqual(s.sounds, ["sounds/x.mp3"])
        XCTAssertEqual(s.name, "bgm")
        XCTAssertEqual(s.volume, 0.4, accuracy: 1e-6)
        XCTAssertEqual(s.playbackMode, "loop")
    }

    // MARK: F057 — 텍스트 부모 회전 상속

    /// F057: 부모(이미지 레이어) 회전이 텍스트 자식 angleZ 에 누적된다 — 이미지 레이어의
    /// composed()(:1666-1698)와 동일 의미론. 회귀 게이트 씬 형상: 3146703458(부모 회전 텍스트).
    func testTextChildInheritsParentRotation() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[
           {"id":7,"image":"models/x.json","origin":"100 100 0","size":"8 8","scale":"1 1 1",
            "angles":"0 0 1.5707963"},
           {"id":8,"parent":7,"text":"A","font":"systemfont_arial","pointsize":8,
            "origin":"10 0 0","angles":"0 0 0.5"}]}
        """
        let d = try doc(scene, [("models/x.json", model), ("materials/m.json", material)])
        let t = try XCTUnwrap(d.texts.first { $0.id == 8 })
        XCTAssertEqual(t.angleZ, 0.5 + Float.pi / 2, accuracy: 1e-4, "자식 angleZ += 부모 누적 각(π/2)")
        // origin 도 부모 회전으로 굽힘(종전 동작 — 회귀 가드): (10,0) 을 90° 회전 → (100,110)
        XCTAssertEqual(t.origin.x, 100, accuracy: 1e-3)
        XCTAssertEqual(t.origin.y, 110, accuracy: 1e-3)
    }

    /// F057 텍스트→텍스트 체인(회귀 게이트 3516106265: id 790/798/804 parent=783 형상):
    /// 그룹 노드(90°) → 텍스트A(0.5) → 텍스트B(0.25). 각 단계가 조상 누적 각을 상속한다.
    func testTextToTextChainAccumulatesRotation() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[
           {"id":1,"origin":"100 100 0","angles":"0 0 1.5707963","scale":"1 1 1"},
           {"id":2,"parent":1,"text":"A","font":"systemfont_arial","pointsize":8,
            "origin":"10 0 0","angles":"0 0 0.5"},
           {"id":3,"parent":2,"text":"B","font":"systemfont_arial","pointsize":8,
            "origin":"5 0 0","angles":"0 0 0.25"}]}
        """
        let d = try doc(scene)
        let a = try XCTUnwrap(d.texts.first { $0.id == 2 })
        let b = try XCTUnwrap(d.texts.first { $0.id == 3 })
        XCTAssertEqual(a.angleZ, 0.5 + Float.pi / 2, accuracy: 1e-4)
        // B 의 부모 월드 각 = 노드(π/2) + A 로컬(0.5) — B 는 그 누적에 자기 로컬(0.25)을 더한다.
        XCTAssertEqual(b.angleZ, 0.25 + 0.5 + Float.pi / 2, accuracy: 1e-4)
        // B origin: A 의 월드(100,110) 에 로컬 (5,0) 을 누적 각(π/2+0.5)으로 회전해 더한다.
        let r = 0.5 + Float.pi / 2
        XCTAssertEqual(b.origin.x, 100 + 5 * cos(r), accuracy: 1e-3)
        XCTAssertEqual(b.origin.y, 110 + 5 * sin(r), accuracy: 1e-3)
    }

    /// 부모 없는 텍스트는 저작 angleZ 그대로(무회귀 가드).
    func testTextWithoutParentKeepsAuthoredAngle() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"text":"A","font":"systemfont_arial","pointsize":8,
                     "origin":"50 60 0","angles":"0 0 3.1241393"}]}
        """
        let d = try doc(scene)
        let t = try XCTUnwrap(d.texts.first)
        XCTAssertEqual(t.angleZ, 3.1241393, accuracy: 1e-6)
        XCTAssertEqual(t.origin, Vec2(x: 50, y: 60))
    }
}
