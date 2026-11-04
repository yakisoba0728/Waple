import XCTest
@testable import WapleRender

final class VideoVolumeRampTests: XCTestCase {
    func testPauseFadesBeforeRequestingTransportPause() {
        var ramp = VideoVolumeRamp(volume: 1)
        ramp.update(target: 1, paused: true, muted: false, outputEnabled: true)
        XCTAssertFalse(ramp.shouldPauseTransport)
        for _ in 0..<19 { ramp.tick() }
        XCTAssertGreaterThan(ramp.current, 0)
        XCTAssertFalse(ramp.shouldPauseTransport)
        for _ in 0..<2 { ramp.tick() }
        XCTAssertEqual(ramp.current, 0)
        XCTAssertTrue(ramp.shouldPauseTransport)
    }

    func testUnmuteRisesMoreSlowlyThanPauseFadeOut() {
        var ramp = VideoVolumeRamp(volume: 0)
        ramp.update(target: 1, paused: false, muted: false, outputEnabled: true)
        for _ in 0..<20 { ramp.tick() }
        XCTAssertEqual(ramp.current, 0.4, accuracy: 1e-5)
        for _ in 0..<29 { ramp.tick() }
        XCTAssertLessThan(ramp.current, 1)
        for _ in 0..<2 { ramp.tick() }
        XCTAssertEqual(ramp.current, 1)
        XCTAssertFalse(ramp.shouldPauseTransport)
    }

    func testMuteLeavesTransportRunningAfterFadeCompletes() {
        var ramp = VideoVolumeRamp(volume: 1)
        ramp.update(target: 1, paused: false, muted: true, outputEnabled: true)
        for _ in 0..<21 { ramp.tick() }
        XCTAssertTrue(ramp.isComplete)
        XCTAssertEqual(ramp.current, 0)
        XCTAssertFalse(ramp.shouldPauseTransport)
    }

    func testResumeReversesPendingPauseWithoutFinishingItsOldGoal() {
        var ramp = VideoVolumeRamp(volume: 1)
        ramp.update(target: 1, paused: true, muted: false, outputEnabled: true)
        for _ in 0..<10 { ramp.tick() }
        let beforeResume = ramp.current
        ramp.update(target: 1, paused: false, muted: false, outputEnabled: true)
        ramp.tick()
        XCTAssertGreaterThan(ramp.current, beforeResume)
        XCTAssertFalse(ramp.shouldPauseTransport)
        for _ in 0..<60 { ramp.tick() }
        XCTAssertEqual(ramp.current, 1)
    }

    func testDisabledOutputAndZeroUserVolumeSnapWithoutWaiting() {
        var ramp = VideoVolumeRamp(volume: 0.8)
        ramp.update(target: 0.8, paused: true, muted: false, outputEnabled: false)
        XCTAssertEqual(ramp.current, 0)
        XCTAssertTrue(ramp.shouldPauseTransport)
        ramp = VideoVolumeRamp(volume: 0.8)
        ramp.update(target: 0, paused: false, muted: false, outputEnabled: true)
        XCTAssertEqual(ramp.current, 0)
        XCTAssertFalse(ramp.shouldPauseTransport)
    }
}
