import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// 씬의 camera 의사-오브젝트를 3D 카메라로 쓰는 경로의 회귀 핀.
///
/// 종전 결함: `parseCameraObject` 가 `angles`/`parent` 를 아예 안 읽어 카메라 오브젝트의 **방향과
/// 계층이 파스에서 소실**됐고, 렌더러는 3D 카메라를 `scene.camera`(WE 에디터의 수동 카메라) 로만
/// 만들었다. 실측 3477054430 은 두 카메라가 21.32 유닛 떨어져 있고 scene.camera 로 투영하면 달이
/// 광축에서 55.64°(fov 42.43 밖 = 화면 밖)라 씬이 통째로 다른 구도로 그려졌다.
/// 근거·게이트·코퍼스 A/B 는 `SceneRenderer.camera3DFromObject` 주석에 있다.
final class CameraObjectAsSceneCameraTests: XCTestCase {

    private func doc(_ objects: String) throws -> SceneDocument {
        let scene = """
        {"general":{"fov":50},"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "objects":[\(objects)]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8))
        ]))
    }

    private let base = SceneCamera3D(eye: Vec3(x: 0, y: 0, z: 0), center: Vec3(x: 0, y: 0, z: -1),
                                     up: Vec3(x: 0, y: 1, z: 0), fov: 50, nearZ: 0.05, farZ: 500)

    /// angles/parent/visible-키 존재가 파스된다(종전 3필드 전부 누락).
    func testCameraObjectParsesAnglesParentAndVisibleBinding() throws {
        let d = try doc("""
        {"id":1,"camera":true,"origin":"0.53864 2.22436 4.44038","angles":"0.04597 0.22400 0.00000","fov":42.4},
        {"id":2,"camera":true,"origin":"1 2 3","angles":"0 0 0","parent":9,
         "visible":{"user":"camera2","value":true}}
        """)
        XCTAssertEqual(d.cameraObjects.count, 2)
        XCTAssertEqual(d.cameraObjects[0].angles.y, 0.224, accuracy: 1e-5, "angles 는 라디안 원값 그대로")
        XCTAssertNil(d.cameraObjects[0].parent)
        XCTAssertFalse(d.cameraObjects[0].hasVisibleBinding, "visible 키가 없으면 무조건 활성")
        XCTAssertEqual(d.cameraObjects[1].parent, 9, "parent 가 파스돼야 부모 구동 카메라를 걸러낼 수 있다")
        XCTAssertTrue(d.cameraObjects[1].hasVisibleBinding, "유저 프로퍼티 바인딩은 조건부 대안 카메라")
    }

    /// 실물 3477054430 카메라(id=34)의 수치로 뷰가 만들어진다 — 전방 = R·(0,0,−1), R = Rz·Ry·Rx.
    /// 검산: 달(월드 (35.680, 37.193, −169.298))이 광축에서 25.53° 로 fov 42.4 프러스텀 안이어야 한다
    /// (scene.camera 축에서는 55.64° 로 화면 밖이었다).
    func testDerivedViewPutsRealMoonInsideFrustum() throws {
        let d = try doc("""
        {"id":34,"camera":true,"origin":"0.53864 2.22436 4.44038","angles":"0.04597 0.22400 0.00000","fov":42.4}
        """)
        let cam = try XCTUnwrap(SceneRenderer.camera3DFromObject(d.cameraObjects, base: base))
        XCTAssertEqual(cam.fov, 42.4, accuracy: 1e-4, "fov 는 카메라 오브젝트 값")
        XCTAssertEqual(cam.eye.x, 0.53864, accuracy: 1e-5, "eye = 카메라 오브젝트 origin")
        XCTAssertEqual(cam.nearZ, base.nearZ, "near/far 는 scene.camera 를 물려받는다")

        let eye = SIMD3<Float>(cam.eye.x, cam.eye.y, cam.eye.z)
        let fwd = simd_normalize(SIMD3<Float>(cam.center.x, cam.center.y, cam.center.z) - eye)
        XCTAssertEqual(fwd.x, -0.2219, accuracy: 1e-3)
        XCTAssertEqual(fwd.z, -0.97399, accuracy: 1e-3)
        let moon = SIMD3<Float>(35.67972, 37.19315, -169.29837)
        let deg = acos(simd_dot(fwd, simd_normalize(moon - eye))) * 180 / .pi
        XCTAssertEqual(deg, 25.53, accuracy: 0.1,
                       "달이 카메라 오브젝트 광축에서 25.5° — scene.camera(55.6°, 화면 밖)와 갈리는 지점")
        XCTAssertEqual(cam.up.y, 0.99894, accuracy: 1e-3, "상방 = R·(0,1,0)")
    }

    /// 게이트: 부모 구동 카메라는 고르지 않는다(3706286085 소닉 추종 CameraBoneMoveMesh 형).
    /// 포즈가 오브젝트가 아니라 스크립트 구동 부모 체인에 있어, 오브젝트 값만 쓰면 월드 원점에 놓인다.
    func testParentedCameraIsRejected() throws {
        let d = try doc("""
        {"id":109,"camera":true,"origin":"0 0 0","angles":"0 0 0","parent":274,"fov":60}
        """)
        XCTAssertNil(SceneRenderer.camera3DFromObject(d.cameraObjects, base: base),
                     "부모가 있으면 scene.camera 를 유지해야(cams[0] 추측이 이 씬을 0.520→0.396 으로 악화시켰다)")
    }

    /// 게이트: visible 이 유저 프로퍼티에 묶인 카메라는 조건부 대안이라 고르지 않는다
    /// (3737268876 은 `cameratype` 기본 "0"=Manual 이라 11개 중 기본 활성이 하나도 없다).
    func testUserBoundVisibleCameraIsRejected() throws {
        let d = try doc("""
        {"id":2085,"camera":true,"origin":"2.30187 1.20235 0.63958","angles":"-0.014 1.52599 0",
         "visible":{"value":true,"script":"export function update(v){ return v; }"},"fov":25.42}
        """)
        XCTAssertNil(SceneRenderer.camera3DFromObject(d.cameraObjects, base: base),
                     "visible 바인딩 보유 카메라는 사용자 설정으로 켜지는 대안 — 기본 경로는 scene.camera")
    }

    /// 게이트 통과 카메라가 여럿이면 파일 순서 첫 번째. 조건부/부모 카메라가 앞에 있어도 건너뛴다.
    func testFirstUnconditionalRootCameraWins() throws {
        let d = try doc("""
        {"id":1,"camera":true,"origin":"9 9 9","angles":"0 0 0","parent":5,"fov":10},
        {"id":2,"camera":true,"origin":"1 2 3","angles":"0 0 0","fov":33},
        {"id":3,"camera":true,"origin":"7 7 7","angles":"0 0 0","fov":77}
        """)
        let cam = try XCTUnwrap(SceneRenderer.camera3DFromObject(d.cameraObjects, base: base))
        XCTAssertEqual(cam.fov, 33, accuracy: 1e-4)
        XCTAssertEqual(cam.eye.z, 3, accuracy: 1e-4)
    }

    /// 카메라 오브젝트가 없으면 nil(= scene.camera 유지) — 3D 씬 대다수의 무회귀 경로.
    func testNoCameraObjectKeepsSceneCamera() throws {
        let d = try doc("""
        {"id":1,"model":"models/x.mdl","origin":"0 0 0","angles":"0 0 0","scale":"1 1 1"}
        """)
        XCTAssertNil(SceneRenderer.camera3DFromObject(d.cameraObjects, base: base))
    }
}
