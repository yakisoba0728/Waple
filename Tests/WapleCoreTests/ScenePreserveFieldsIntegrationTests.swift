import XCTest
@testable import WapleCore

/// fix-i3 통합: 1차 수정 스웜이 "다른 그룹 선행 파스 필요"로 남긴 파스·보존 잔여 항목 연결.
/// - F750(S-47): fix-s7 이 렌더 측 directional 섀도우(F661)/fog(F662)를 구현했으나 라이트 오브젝트의
///   `cascadedistance0-2`/`castvolumetrics`/`volumetricsexponent`/`density` 는 미파스로 남았다 — 파스·보존
///   (렌더 소비는 후속). 실측(코퍼스 스캔 2026-07, 119씬): cascadedistance 3키 동반 11건
///   (lpoint 7/lspot 1/ldirectional 3 — 종 무관), castvolumetrics 2건(전부 true), volumetricsexponent
///   13건(기본 1.0, 비기본 1.7/2.82/3.04), density 13건(기본 2.0, 비기본 0.65..4.12).
/// - F751(S-20): 모델 json 루트 `cropoffset` — 1차는 RE 문서 의미 미확정으로 기각. 실물 전수 분석으로
///   의미 확정(크롭 영역 중심 − 원본 이미지 중심, px — 전수 1386 컴포넌트가 0.5 배수) 후 파스·보존.
final class ScenePreserveFieldsIntegrationTests: XCTestCase {

    // MARK: - F750(S-47): 라이트 CSM/볼류메트릭 필드

    /// 4필드 전부 저작된 directional 라이트 — 실측 비기본값 조합으로 파스·보존 확인.
    func testCascadeAndVolumetricsFieldsParsed() throws {
        let scene = """
        {"objects":[{"id":1,"light":"ldirectional","origin":"0 0 5","color":"1 1 1","intensity":1,
                     "castshadow":true,
                     "cascadedistance0":400.0,"cascadedistance1":900.0,"cascadedistance2":1600.0,
                     "castvolumetrics":true,"volumetricsexponent":3.04,"density":0.92}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.lights3D.count, 1)
        let light = doc.lights3D[0]
        let cascades = try XCTUnwrap(light.cascadeDistances, "cascadedistance0-2 저작 시 보존")
        XCTAssertEqual(cascades.x, 400, accuracy: 1e-3)
        XCTAssertEqual(cascades.y, 900, accuracy: 1e-3)
        XCTAssertEqual(cascades.z, 1600, accuracy: 1e-3)
        XCTAssertTrue(light.castVolumetrics)
        XCTAssertEqual(light.volumetricsExponent, 3.04, accuracy: 1e-4)
        XCTAssertEqual(light.density, 0.92, accuracy: 1e-4)
    }

    /// 가드: 필드 미저작 라이트는 기본값(cascadeDistances nil / castVolumetrics false /
    /// volumetricsExponent 1 / density 2) — 기존 씬 무회귀.
    func testLightDefaultsWhenFieldsAbsent() throws {
        let scene = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 5","color":"1 1 1","intensity":1,"radius":10}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let light = doc.lights3D[0]
        XCTAssertNil(light.cascadeDistances)
        XCTAssertFalse(light.castVolumetrics)
        XCTAssertEqual(light.volumetricsExponent, 1, accuracy: 1e-6)
        XCTAssertEqual(light.density, 2, accuracy: 1e-6)
    }

    /// 방어: 부분 저작(실물 0건)은 결측 컴포넌트 0 으로 채워 Vec3 를 만든다(nil 아님).
    func testPartialCascadeDistancesZeroFilled() throws {
        let scene = #"{"objects":[{"id":1,"light":"lspot","origin":"0 0 5","cascadedistance1":400.10001}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let cascades = try XCTUnwrap(doc.lights3D[0].cascadeDistances)
        XCTAssertEqual(cascades.x, 0, accuracy: 1e-6)
        XCTAssertEqual(cascades.y, 400.10001, accuracy: 1e-3)
        XCTAssertEqual(cascades.z, 0, accuracy: 1e-6)
    }

    // MARK: - F751(S-20): 모델 json cropoffset

    /// image: models/x.json 레이어 — 모델 json 루트의 cropoffset 이 SceneLayer.cropOffset 으로 보존.
    func testCropOffsetParsedFromModelJson() throws {
        let scene = """
        {"objects":[{"id":1,"image":"models/mouth.json","origin":"1376.65332 1331.63110 0.00000",
                     "scale":"2 2 1","size":"163 109"}]}
        """
        let model = #"{"autosize":true,"cropoffset":"-278.50000 126.50000","material":"materials/mouth.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["mouth"]}]}"#
        let doc = try SceneDocument.parse(package: try pkg([
            ("scene.json", scene), ("models/mouth.json", model), ("materials/mouth.json", material)]))
        XCTAssertEqual(doc.layers.count, 1)
        let co = try XCTUnwrap(doc.layers[0].cropOffset, "모델 json cropoffset 보존")
        XCTAssertEqual(co.x, -278.5, accuracy: 1e-3)
        XCTAssertEqual(co.y, 126.5, accuracy: 1e-3)
    }

    /// 가드: cropoffset 없는 모델 json 레이어는 nil — 기존 씬 무회귀.
    func testCropOffsetNilWhenAbsent() throws {
        let scene = """
        {"objects":[{"id":1,"image":"models/plain.json","origin":"0 0 0","size":"10 10"}]}
        """
        let model = #"{"autosize":true,"material":"materials/plain.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
        let doc = try SceneDocument.parse(package: try pkg([
            ("scene.json", scene), ("models/plain.json", model), ("materials/plain.json", material)]))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertNil(doc.layers[0].cropOffset, "cropoffset 부재 모델 json")
    }
}
