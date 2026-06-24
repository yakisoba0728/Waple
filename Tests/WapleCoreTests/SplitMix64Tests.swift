import XCTest
@testable import WapleCore

final class SplitMix64Tests: XCTestCase {
    func testDeterministicAcrossInstances() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.nextUInt(), b.nextUInt()) }
    }

    func testDifferentSeedsDiverge() {
        var a = SplitMix64(seed: 1), b = SplitMix64(seed: 2)
        XCTAssertNotEqual(a.nextUInt(), b.nextUInt())
    }

    func testFloatInUnitInterval() {
        var r = SplitMix64(seed: 7)
        for _ in 0..<1000 {
            let f = r.nextFloat()
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThan(f, 1)
        }
    }

    func testRange() {
        var r = SplitMix64(seed: 9)
        for _ in 0..<1000 {
            let v = r.range(2, 5)
            XCTAssertGreaterThanOrEqual(v, 2)
            XCTAssertLessThan(v, 5)
        }
    }
}
