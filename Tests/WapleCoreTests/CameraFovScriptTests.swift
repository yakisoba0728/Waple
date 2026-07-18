import XCTest
@testable import WapleCore

/// F217: parseCameraObject 는 origin/zoom 스크립트만 캡처하고 바로 위에서 정적 파스한 fov 의
/// 스크립트는 누락한다(같은 함수 내부의 비대칭). 실측: camera 의사-오브젝트 fov 스크립트 바인딩
/// 9씬(예 3706286085 createScriptProperties() 슬라이더 연동 줌). base 는 cam.scripts 에 "fov" 키가
/// 아예 안 생겨 카메라 fov(줌) 애니 일부가 정지한다.
final class CameraFovScriptTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }

    /// fov={value,script} → cam.scripts["fov"] 캡처(기존 origin/zoom 과 동형).
    func testFovScriptCaptured() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"camera":true,"name":"Main Camera","origin":"0 0 0","zoom":1,
                     "fov":{"value":50,"script":"export function update(v){ return 50 + shared.slider; }"}}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.cameraObjects.count, 1)
        XCTAssertEqual(doc.cameraObjects[0].fov, 50, accuracy: 1e-4, "정적 초기값은 그대로 유지")
        XCTAssertEqual(doc.cameraObjects[0].scripts["fov"], "export function update(v){ return 50 + shared.slider; }",
                       "fov 스크립트가 origin/zoom 과 동일하게 cam.scripts 에 캡처돼야")
    }

    /// 가드: origin/zoom 스크립트 캡처는 fov 캡처 추가로 회귀하면 안 된다.
    func testOriginAndZoomScriptsStillCaptured() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"camera":true,"name":"Main Camera",
                     "origin":{"value":"0 0 0","script":"export function update(v){ return v; }"},
                     "zoom":{"value":1,"script":"export function update(v){ return v; }"},
                     "fov":50}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertNotNil(doc.cameraObjects[0].scripts["origin"])
        XCTAssertNotNil(doc.cameraObjects[0].scripts["zoom"])
        XCTAssertNil(doc.cameraObjects[0].scripts["fov"], "fov 정적값만이면 스크립트 키가 없어야")
    }
}
