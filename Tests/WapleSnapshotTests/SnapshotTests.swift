import XCTest
@testable import WapleSnapshot

final class SnapshotTests: XCTestCase {

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255, count: Int = 16) -> [UInt8] {
        var px = [UInt8](); px.reserveCapacity(count * 4)
        for _ in 0..<count { px.append(contentsOf: [r, g, b, a]) }
        return px
    }

    // MARK: diff 메트릭

    func testDiffIdenticalIsZero() {
        let a = solid(10, 20, 30)
        let m = diffRGBA(a, a)
        XCTAssertEqual(m.meanAbsDiff, 0)
        XCTAssertEqual(m.maxAbsDiff, 0)
        XCTAssertEqual(m.fracExceeding, 0)
    }

    func testDiffUniformDelta() {
        // 모든 픽셀 R 채널 +40. 채널 평균차 = 40/4 = 10. maxAbsDiff = 40. 모든 픽셀 초과(thr=16).
        let a = solid(100, 100, 100)
        let b = solid(140, 100, 100)
        let m = diffRGBA(a, b, perPixelThreshold: 16)
        XCTAssertEqual(m.meanAbsDiff, 10.0, accuracy: 1e-9)
        XCTAssertEqual(m.maxAbsDiff, 40)
        XCTAssertEqual(m.fracExceeding, 1.0, accuracy: 1e-9)
    }

    func testDiffBelowThresholdNotCounted() {
        // R +8 < thr 16 → 초과 픽셀 0, 하지만 평균차/최대차는 반영.
        let a = solid(100, 100, 100)
        let b = solid(108, 100, 100)
        let m = diffRGBA(a, b, perPixelThreshold: 16)
        XCTAssertEqual(m.maxAbsDiff, 8)
        XCTAssertEqual(m.fracExceeding, 0.0, accuracy: 1e-9)
        XCTAssertEqual(m.meanAbsDiff, 2.0, accuracy: 1e-9)  // 8/4
    }

    func testDiffPartialPixelsExceed() {
        // 절반 픽셀만 크게 변경 → fracExceeding ≈ 0.5.
        let a = solid(0, 0, 0, count: 100)
        var b = a
        for p in 0..<50 { b[p * 4] = 200 }  // 앞 50픽셀 R=200
        let m = diffRGBA(a, b, perPixelThreshold: 16)
        XCTAssertEqual(m.fracExceeding, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.maxAbsDiff, 200)
    }

    func testDiffMismatchedLengthUsesShorter() {
        let a = solid(50, 50, 50, count: 8)
        let b = solid(50, 50, 50, count: 4)
        XCTAssertEqual(diffRGBA(a, b).maxAbsDiff, 0)  // 겹치는 4픽셀은 동일
    }

    // MARK: 임계 판정

    func testThresholdStrictRejectsRealChange() {
        let a = solid(100, 100, 100)
        let b = solid(140, 100, 100)  // 눈에 띄는 변화
        XCTAssertFalse(passes(diffRGBA(a, b), .strict))
    }

    func testThresholdStrictAcceptsEncodingNoise() {
        let a = solid(100, 100, 100)
        let b = solid(101, 100, 100)  // 1채널 +1 → mean 0.25, frac 0
        XCTAssertTrue(passes(diffRGBA(a, b), .strict))
    }

    func testThresholdLaxAcceptsModerateDrift() {
        let a = solid(100, 100, 100)
        let b = solid(108, 108, 108)  // 관대 임계 내
        XCTAssertTrue(passes(diffRGBA(a, b), .lax))
    }

    func testSelfConsistentIsTightest() {
        // strict 는 통과하지만 selfConsistent 는 잡는 미세 변동이 존재해야(임계 순서 검증).
        let a = solid(100, 100, 100)
        let b = solid(101, 101, 101)  // mean 0.75
        XCTAssertTrue(passes(diffRGBA(a, b), .strict))
        XCTAssertFalse(passes(diffRGBA(a, b), .selfConsistent))
    }

    // MARK: 게이트 보강 — 어두운 씬 사각지대(spec/golden/gate-analysis.json)

    /// 어두운 씬을 전면 검정으로 바꾸면 잡혀야 한다.
    /// 종전 절대 임계만으로는 3종이 통과했다(spec/golden/gate-analysis.json).
    func testBlackoutOfDarkSceneIsCaught() {
        // 기준선 meanLuma 0.0034 인 씬을 전면 검정으로: 평균 절대차 ≈ 0.87
        let m = DiffMetrics(meanAbsDiff: 0.87, maxAbsDiff: 3, fracExceeding: 0.0)
        XCTAssertTrue(passes(m, .strict), "절대 임계만으로는 통과한다(종전 동작)")
        // 리터럴만으로는 `<` 오버로드가 모호해 타입체커가 거부한다 — 타입을 명시한다.
        let baseLuma: Double = 0.0034      // 기준선 meanLuma
        let meanAbs: Double = 0.87         // 전면 검정 시 평균 절대차
        let rel = meanAbs / (max(baseLuma, 0.02) * 255.0)
        let structureLoss = baseLuma < 0.02 && meanAbs > baseLuma * 255.0 * 0.5
        XCTAssertTrue(structureLoss, "구조 소실 판정이 이걸 잡아야 한다")
        _ = rel
    }

    /// 밝은 씬의 미세 인코딩 노이즈는 통과해야 한다(오탐 방지).
    func testMinorNoiseOnBrightSceneStillPasses() {
        let m = DiffMetrics(meanAbsDiff: 0.4, maxAbsDiff: 3, fracExceeding: 0.0005)
        let rel = 0.4 / (max(0.39, 0.02) * 255.0)   // median 밝기 씬
        XCTAssertTrue(passes(m, .strict))
        XCTAssertLessThanOrEqual(rel, 0.05)
    }

    // MARK: 해시 / luma

    func testFNVDeterministicAndDistinct() {
        let a = solid(1, 2, 3)
        XCTAssertEqual(fnv1a(a), fnv1a(a))
        XCTAssertNotEqual(fnv1a(a), fnv1a(solid(1, 2, 4)))
    }

    func testMeanLuma() {
        XCTAssertEqual(meanLuma(rgba: solid(255, 255, 255)), 1.0, accuracy: 1e-6)
        XCTAssertEqual(meanLuma(rgba: solid(0, 0, 0)), 0.0, accuracy: 1e-6)
        XCTAssertEqual(meanLuma(rgba: solid(128, 128, 128)), 128.0 / 255.0, accuracy: 1e-6)
    }

    // MARK: 매니페스트 파스

    func testManifestRoundTrip() throws {
        let m = SnapshotManifest(
            gitSHA: "66f3ec9", label: "test", thumbWidth: 256, thumbHeight: 144,
            captureTime: 6.0, createdAt: "2026-07-10T00:00:00Z",
            entries: [
                SnapshotEntry(id: "a", width: 256, height: 144, hash: "deadbeef",
                              meanLuma: 0.5, deterministic: true, selfMaxDiff: 0),
                SnapshotEntry(id: "b", width: 256, height: 144, hash: "cafe",
                              meanLuma: 0.1, deterministic: false, selfMaxDiff: 42,
                              note: "self-diff exceeds threshold"),
            ],
            empties: ["vid1"], failures: ["broken1"])
        let decoded = try SnapshotManifest.decode(m.encoded())
        XCTAssertEqual(decoded, m)
        XCTAssertEqual(decoded.entries[1].note, "self-diff exceeds threshold")
        XCTAssertEqual(decoded.empties, ["vid1"])
    }

    func testManifestRejectsGarbage() {
        XCTAssertThrowsError(try SnapshotManifest.decode(Data("{not json".utf8)))
    }

    // MARK: 캡처 시각 파싱(F2-puppet①)

    func testParseCaptureTimesNilUsesFallback() {
        XCTAssertEqual(parseCaptureTimes(nil, fallback: [6.0]), [6.0])
    }

    func testParseCaptureTimesEmptyUsesFallback() {
        XCTAssertEqual(parseCaptureTimes("", fallback: [6.0]), [6.0])
        XCTAssertEqual(parseCaptureTimes("   ", fallback: [6.0]), [6.0])
    }

    func testParseCaptureTimesSingleValue() {
        XCTAssertEqual(parseCaptureTimes("12", fallback: [6.0]), [12.0])
    }

    func testParseCaptureTimesMultiplePreservesOrder() {
        // 정렬하지 않고 입력 순서 그대로 — 캡처 파이프라인이 정렬 여부를 스스로 결정.
        XCTAssertEqual(parseCaptureTimes("0, 2,6,12, 30", fallback: [6.0]), [0.0, 2.0, 6.0, 12.0, 30.0])
    }

    func testParseCaptureTimesSkipsInvalidTokensButKeepsValid() {
        // 빈 토큰/문자열 토큰은 무시되지만, 나머지 유효 값은 살아남는다(전부 무효일 때만 fallback).
        XCTAssertEqual(parseCaptureTimes("0,,abc, 6.5 ,", fallback: [6.0]), [0.0, 6.5])
    }

    func testParseCaptureTimesAllInvalidUsesFallback() {
        XCTAssertEqual(parseCaptureTimes("abc,def", fallback: [6.0]), [6.0])
    }
}
