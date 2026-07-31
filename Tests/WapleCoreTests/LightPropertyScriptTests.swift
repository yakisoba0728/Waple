import XCTest
@testable import WapleCore

/// F222: parseLight 는 intensity/color/radius 등을 float()/vec3() 정적 언랩만 하고 스크립트 바인딩을
/// 캡처하지 않는다 — SceneLight3D 에 propertyScripts 부재(SceneObject3D/SceneNode3D 는
/// transformScripts 로 캡처하는 것과 비대칭). 실측: intensity 스크립트 8건(주야 조명 감쇠),
/// color 스크립트 1건(3737268876 젤다). 파스 캡처만 추가(per-frame 소비는 코퍼스 저빈도 → TODO).
final class LightPropertyScriptTests: XCTestCase {

    /// intensity/color 스크립트가 SceneLight3D.propertyScripts 에 캡처돼야(정적 value 는 기존대로 유지).
    func testIntensityAndColorScriptsCaptured() throws {
        let scene = """
        {"objects":[{"id":1,"light":"lpoint","origin":"0 0 5",
                     "color":{"value":"1 1 1","script":"export function update(v){ return v; }"},
                     "intensity":{"value":1,"script":"export function update(v){ return shared.dayNight; }"},
                     "radius":10,"exponent":3}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.lights3D.count, 1)
        XCTAssertEqual(doc.lights3D[0].intensity, 1, accuracy: 1e-4, "정적 초기값은 그대로 유지")
        XCTAssertEqual(doc.lights3D[0].propertyScripts["intensity"], "export function update(v){ return shared.dayNight; }")
        XCTAssertEqual(doc.lights3D[0].propertyScripts["color"], "export function update(v){ return v; }")
    }

    /// 가드: 스크립트 없는 라이트는 propertyScripts 가 비어야(무회귀).
    func testStaticLightHasNoPropertyScripts() throws {
        let scene = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 5","color":"1 1 1","intensity":1,"radius":10}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.lights3D[0].propertyScripts.isEmpty)
    }
}
