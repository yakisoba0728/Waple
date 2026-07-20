import XCTest
@testable import WapleSnapshot

/// F522/F523 회귀 — 매니페스트 스키마 계약 고정.
/// 파이프라인 로직(SnapshotPipeline/SnapshotCompare)은 WapleCompat 실행타깃(main.swift 최상위 코드가
/// import 시 실행돼 테스트 불가)이라, 스키마 생산/소비의 접점인 WapleSnapshot 코어에서 계약을 고정한다.
final class SnapshotFixRegressionTests: XCTestCase {

    /// 전-F145 베이스라인 JSON 픽스처(activeDebugGates 키 부재 — 당시 스키마 그대로).
    private func preF145ManifestJSON(extraKey: String? = nil) -> Data {
        var json = """
        {
          "gitSHA": "abc1234",
          "label": "old-baseline",
          "thumbWidth": 256,
          "thumbHeight": 144,
          "captureTime": 6.0,
          "createdAt": "2026-01-01T00:00:00Z",
          "entries": [],
          "empties": [],
          "failures": []
        """
        if let extraKey { json += ",\n  \"activeDebugGates\": \(extraKey)\n" }
        json += "\n}"
        return json.data(using: .utf8)!
    }

    // MARK: F523 — activeDebugGates nil("기록 안 됨") vs []("0개 활성") 구분 유지

    /// 전-F145 매니페스트(키 자체가 없음)는 nil 로 디코드돼야 compare 가 "대조 불가"를 명시할 수 있다.
    /// nil → [] 붕괴가 스키마에서부터 생기면(비옵셔널 전환 등) 구 베이스라인 게이트 오염 경고가 소실.
    func testPreF145ManifestWithoutGatesKeyDecodesAsNil() throws {
        let m = try SnapshotManifest.decode(preF145ManifestJSON())
        XCTAssertNil(m.activeDebugGates, "키 부재 구 매니페스트는 nil(기록 안 됨)이어야 — [] 와 구분")
    }

    /// 키가 있고 빈 배열이면 "0개 활성" — nil 과 구분된 채 디코드.
    func testManifestWithEmptyGatesDecodesAsEmptyNotNil() throws {
        let m = try SnapshotManifest.decode(preF145ManifestJSON(extraKey: "[]"))
        XCTAssertNotNil(m.activeDebugGates)
        XCTAssertEqual(m.activeDebugGates, [])
    }

    /// 게이트 기록이 있는 매니페스트는 값이 그대로 왕복.
    func testManifestWithGatesRoundTrips() throws {
        let m = try SnapshotManifest.decode(preF145ManifestJSON(extraKey: "[\"WAPLE_NO_BLOOM\"]"))
        XCTAssertEqual(m.activeDebugGates, ["WAPLE_NO_BLOOM"])
    }

    // MARK: F522 — selfMaxDiff: 셀프체크 미실행 = -1 스키마 계약

    /// 스키마 주석("셀프체크 안 했으면 -1") 계약: 생산자(SnapshotPipeline.runCapture)는 2차 캡처가
    /// 픽셀을 내지 못하면 -1 을 기록한다. -1 이 인코드/디코드에서 보존돼야 "미실행"과 "최대차 0"이 구분된다.
    func testSelfMaxDiffMinusOneRoundTrip() throws {
        let e = SnapshotEntry(id: "scene_a", width: 256, height: 144, hash: "ff", meanLuma: 0.5,
                              deterministic: false, selfMaxDiff: -1, note: "second capture empty")
        let back = try JSONDecoder().decode(SnapshotEntry.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.selfMaxDiff, -1)
    }
}
