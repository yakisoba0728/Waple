import XCTest
@testable import WapleCore

/// `general.*` 후처리/카메라 키의 **키 부재 기본값**을 WE 실측에 고정한다.
///
/// 근거는 두 함수를 직접 읽어 뽑은 것이다(2026-08-21 재판독):
/// - 리플렉션 등록 테이블 `Scene::registerProperties` `0x140199780`–`0x14019b4d6` — 47키의
///   이름·타입(`desc+0x30`: 0=int · 2=vec3 · 4=float · 6=bool)·씬 오브젝트 오프셋(`desc+0x34`)
/// - 씬 생성자 `Scene::Scene` `0x140186c90`–`0x1401872ba` — 그 오프셋들에 깔리는 초기값
///
/// bool 11키는 전부 플래그 워드 `scene+0xe0` 의 비트다. 생성자가 `0x26` 을 기록하므로
/// (`0x140186d1f`) set 인 것은 bit1 `bloom` · bit2 `camerafade` · bit5 `clearenabled` 셋뿐이고
/// 나머지(bit7 `camerashake` · bit8 `cameraparallax` · bit10 `hdr` · bit12 `transparentsorting` ·
/// bit13 `customsortorder` · bit14 `fogdistance` · bit15 `fogheight` · bit16 `windenabled`)는 clear 다.
/// 비트 번호는 각 키의 게터 썽크에서 읽었다(예: `bloom` `0x14019b6e0` 이 `shr edx,1 / and dl,1`).
///
/// `fog*` 12키는 이 파일(WapleCore)이 파스하지 않는다 — 렌더 레인(`Scene3DLighting`) 소관이라 범위 밖.
final class SceneGeneralDefaultsWEParityTests: XCTestCase {

    /// `general` 이 `orthogonalprojection` 하나만 든 최소 2D 씬 — 파스되는 모든 general 키가 기본값 경로다.
    private static let bareScene =
        #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#

    /// 2D 씬 전 기본값 전수 — 씬 생성자 초기값과 1:1.
    func testEveryParsedGeneralDefaultMatchesSceneConstructor() throws {
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", Self.bareScene)]))

        // bool — flags `scene+0xe0` = 0x26 (`0x140186d1f`)
        // bit1 `bloom`(게터 `0x14019b6e0`)만 **의도적 이탈** — WE 는 true, Waple 은 false 로 둔다
        // (근거: `SceneDocument.bloom` 선언부 주석 / §7 W-4. 뒤집을 때 이 줄도 같이 뒤집는다).
        XCTAssertFalse(doc.bloom, "WE 는 true — 의도적 이탈, 렌더 픽스처와 함께 뒤집을 것")
        XCTAssertTrue(doc.cameraFade, "bit2 set (`0x14019c1a0`)")
        XCTAssertTrue(doc.clearEnabled, "bit5 set (`0x14019bb20`)")
        XCTAssertFalse(doc.cameraShake, "bit7 clear (`0x14019c830`)")
        XCTAssertFalse(doc.parallaxEnabled, "bit8 clear (`0x14019ca60`)")
        XCTAssertFalse(doc.hdr, "bit10 clear (`0x14019b900`)")
        XCTAssertFalse(doc.windEnabled, "bit16 clear (`0x14019cc90`)")

        // float/int/vec3 — 오프셋과 기록 VA 는 각 줄 끝 주석
        XCTAssertEqual(doc.bloomStrength, 2, accuracy: 1e-6)                    // 0x3bc ← 0x1401870ac
        XCTAssertEqual(doc.bloomThreshold, 0.65, accuracy: 1e-6)                // 0x3c0 ← 0x1401870b7
        XCTAssertEqual(doc.bloomHDRStrength, 2, accuracy: 1e-6)                 // 0x3c4 ← 0x1401870c2
        XCTAssertEqual(doc.bloomHDRThreshold, 1, accuracy: 1e-6)                // 0x3c8 ← 0x1401870cd
        XCTAssertEqual(doc.bloomHDRFeather, 0.1, accuracy: 1e-6)                // 0x3cc ← 0x1401870d8
        XCTAssertEqual(doc.bloomHDRScatter, 1.619, accuracy: 1e-6)              // 0x3d0 ← 0x1401870e3
        XCTAssertEqual(doc.bloomHDRIterations, 8)                               // 0x3d4 ← 0x1401870ee
        XCTAssertEqual(doc.bloomTint, Vec3(x: 1, y: 1, z: 1))                   // 0x3d8 ← 0x140186ff0
        XCTAssertEqual(doc.clearColor, Vec3(x: 0, y: 0, z: 0))                  // 0x35c ← 0x140186f61
        XCTAssertEqual(doc.ambientColor, Vec3(x: 0, y: 0, z: 0))                // 0x368 ← 0x140186f6f
        XCTAssertEqual(doc.skylightColor, Vec3(x: 0, y: 0, z: 0))               // 0x374 ← 0x140186f76
        XCTAssertEqual(doc.perspectiveOverrideFov, 95, accuracy: 1e-6)          // 0x144 ← 0x140186d67
        XCTAssertEqual(doc.zoom, 1, accuracy: 1e-6)                             // 0x154 ← 0x140186d93
        XCTAssertEqual(doc.cameraShakeSpeed, 3, accuracy: 1e-6)                 // 0x328 ← 0x140186f84
        XCTAssertEqual(doc.cameraShakeAmplitude, 0.5, accuracy: 1e-6)           // 0x32c ← 0x140186f8f
        XCTAssertEqual(doc.cameraShakeRoughness, 1, accuracy: 1e-6)             // 0x330 ← 0x140186f9a
        XCTAssertEqual(doc.parallaxAmount, 0.5, accuracy: 1e-6)                 // 0x334 ← 0x140186fa5
        XCTAssertEqual(doc.parallaxDelay, 0.1, accuracy: 1e-6)                  // 0x338 ← 0x140186fb0
        XCTAssertEqual(doc.parallaxMouseInfluence, 0.5, accuracy: 1e-6)         // 0x33c ← 0x140186fbb
        XCTAssertEqual(doc.gravityDirection, Vec3(x: 0, y: -1, z: 0))           // 0x3e4 ← 0x140187006
        XCTAssertEqual(doc.gravityStrength, 1, accuracy: 1e-6)                  // 0x3f0 ← 0x1401870f9
        XCTAssertEqual(doc.windDirection, Vec3(x: 0.707, y: 0.707, z: 0))       // 0x3f4 ← 0x140187023
        XCTAssertEqual(doc.windStrength, 1, accuracy: 1e-6)                     // 0x400 ← 0x140187104
    }

    /// 생성자가 기록하는 float 비트패턴이 Swift 리터럴과 **비트동일**인지 — 반올림으로 미끄러지지 않게 못박는다.
    func testDefaultLiteralsAreBitIdenticalToEngineConstants() {
        XCTAssertEqual(Float(0.65).bitPattern, 0x3f26_6666)   // bloomthreshold  `0x1401870b7`
        XCTAssertEqual(Float(0.1).bitPattern, 0x3dcc_cccd)    // feather/delay/nearz `0x1401870d8`
        XCTAssertEqual(Float(1.619).bitPattern, 0x3fcf_3b64)  // bloomhdrscatter `0x1401870e3`
        XCTAssertEqual(Float(0.707).bitPattern, 0x3f34_fdf4)  // winddirection.x `0x140187023`
        XCTAssertEqual(Float(95).bitPattern, 0x42be_0000)     // perspectiveoverridefov `0x140186d67`
        XCTAssertEqual(Float(50).bitPattern, 0x4248_0000)     // fov `0x140186d5c`
    }

    /// `skylightcolor` 는 `ambientcolor` 로 폴백하지 않는다 — 두 키는 등록도 저장도 독립이고
    /// (`0x14019a26f`→`scene+0x374` · `0x14019a1c6`→`scene+0x368`) 생성자는 둘 다 0 만 깐다.
    func testSkylightColorDoesNotFallBackToAmbientColor() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"ambientcolor":"0.3 0.3 0.3"},
         "objects":[]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.ambientColor, Vec3(x: 0.3, y: 0.3, z: 0.3))
        XCTAssertEqual(doc.skylightColor, Vec3(x: 0, y: 0, z: 0), "종전 `?? ambientColor` 는 하늘광 이중 가산")
    }

    /// 3D 원근 씬의 `nearz` 기본은 0.1(`scene+0x14c` ← `0x140186d7d`), `farz` 는 10000(`0x140186d88`).
    /// 정사영 씬은 이 두 값을 아예 안 읽는다(±2000 하드코딩 — `0x140183df9`·`0x140183e01`).
    func test3DCameraClipDefaultsMatchSceneConstructor() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null},"objects":[]}
        """
        let cam = try XCTUnwrap(try SceneDocument.parse(package: try pkg([("scene.json", scene)])).camera3D)
        XCTAssertEqual(cam.fov, 50, accuracy: 1e-6)
        XCTAssertEqual(cam.nearZ, 0.1, accuracy: 1e-6, "종전 0.01 은 깊이 정밀도를 10배 낭비했다")
        XCTAssertEqual(cam.farZ, 10000, accuracy: 1e-3)
    }

    /// 저작값은 언제나 기본값을 이긴다 — 기본값을 WE 쪽으로 옮긴 뒤에도 파스 경로가 그대로인지.
    func testAuthoredValuesStillWinOverNewDefaults() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "bloom":false,"bloomhdrstrength":0.25,"skylightcolor":"1 0 0",
          "cameraparallaxamount":1,"cameraparallaxmouseinfluence":1,"cameraparallaxdelay":0,
          "perspectiveoverridefov":90.760002},
         "objects":[]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertFalse(doc.bloom)
        XCTAssertEqual(doc.bloomHDRStrength, 0.25, accuracy: 1e-6)
        XCTAssertEqual(doc.skylightColor, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(doc.parallaxAmount, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxMouseInfluence, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxDelay, 0, accuracy: 1e-6)
        XCTAssertEqual(doc.perspectiveOverrideFov, 90.760002, accuracy: 1e-5)
    }

    // MARK: - 동봉 코퍼스 영향 범위 고정

    /// 기본값 변경이 실제로 **어느 동봉 씬을 바꾸는지**를 세어 소스 주석의 숫자와 맞물려 둔다.
    /// 주석이 "영향 0건" 이라고 적은 자리에 씬이 생기면 여기서 먼저 터진다.
    func testBundledSceneOmissionCensusMatchesSourceComments() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        let generals = Self.bundledGenerals(root: root)
        XCTAssertEqual(generals.count, 172, "동봉 씬 수가 바뀌었다 — 아래 숫자를 다시 세야 한다")

        func unwrapped(_ v: Any?) -> Any? {
            var cur = v
            while let d = cur as? [String: Any], let inner = d["value"] { cur = inner }
            return cur
        }
        func isTrue(_ g: [String: Any], _ k: String) -> Bool { (unwrapped(g[k]) as? Bool) == true }

        // bloom: 전건 저작 → WE 기본값 true 로 뒤집어도 갈리는 동봉 씬이 0건이라는 근거
        XCTAssertEqual(generals.filter { $0["bloom"] == nil }.count, 0)

        // bloomhdrstrength: 84건 생략이지만 `hdr && bloom` 이면서 생략한 씬은 0건
        XCTAssertEqual(generals.filter { $0["bloomhdrstrength"] == nil }.count, 84)
        XCTAssertEqual(generals.filter {
            isTrue($0, "hdr") && isTrue($0, "bloom") && $0["bloomhdrstrength"] == nil
        }.count, 0)

        // 패럴랙스 3키: 4씬이 생략하지만 그 4씬은 `cameraparallax` 도 생략(=비활성)
        for k in ["cameraparallaxamount", "cameraparallaxmouseinfluence", "cameraparallaxdelay"] {
            XCTAssertEqual(generals.filter { $0[k] == nil }.count, 4, k)
            XCTAssertEqual(generals.filter { $0[k] == nil && isTrue($0, "cameraparallax") }.count, 0, k)
        }

        // skylightcolor: 2씬 생략, 그 2씬은 ambientcolor 도 생략 → 종전 폴백 결과도 (0,0,0)
        XCTAssertEqual(generals.filter { $0["skylightcolor"] == nil }.count, 2)
        XCTAssertEqual(generals.filter { $0["skylightcolor"] == nil && $0["ambientcolor"] != nil }.count, 0)

        // nearz: 3D(=orthogonalprojection 이 딕셔너리가 아닌) 씬 2건 중 생략은 1건
        let threeD = generals.filter { !($0["orthogonalprojection"] is [String: Any]) }
        XCTAssertEqual(threeD.count, 2)
        XCTAssertEqual(threeD.filter { $0["nearz"] == nil }.count, 1)

        // perspectiveoverridefov: 77건 저작 중 95 가 아닌 값(90.760002)이 6건 — 렌더 리터럴 95 가 틀리는 자리
        let authored = generals.compactMap { unwrapped($0["perspectiveoverridefov"]) as? NSNumber }
        XCTAssertEqual(authored.count, 77)
        XCTAssertEqual(authored.filter { abs($0.floatValue - 95) > 1e-3 }.count, 6)
    }

    /// 동봉 씬 172건의 `general` 딕셔너리(전건 파스 성공이 전제 — 하나라도 못 읽으면 count 로 드러난다).
    private static func bundledGenerals(root: URL) -> [[String: Any]] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [[String: Any]] = []
        for case let url as URL in en
        where url.lastPathComponent == "scene.json" || url.lastPathComponent == "gifscene.json" {
            guard let data = try? Data(contentsOf: url),
                  let dict = AssetJSON.dictionary(data) else { continue }
            out.append(dict["general"] as? [String: Any] ?? [:])
        }
        return out
    }
}
