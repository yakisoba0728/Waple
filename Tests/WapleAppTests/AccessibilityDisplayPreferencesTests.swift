import XCTest
import AppKit
import Observation
@testable import Waple

@MainActor
final class AccessibilityDisplayPreferencesTests: XCTestCase {
    func testWorkspaceNotificationInvalidatesObservedSnapshotImmediately() {
        let center = NotificationCenter()
        var next = AccessibilityDisplayPreferences.Snapshot(reduceMotion: false, reduceTransparency: false,
                                                            differentiateWithoutColor: false, increaseContrast: false)
        let preferences = AccessibilityDisplayPreferences(center: center, read: { next })
        var invalidated = false
        withObservationTracking {
            _ = preferences.snapshot.reduceMotion
        } onChange: {
            invalidated = true
        }
        next.reduceMotion = true
        next.reduceTransparency = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertTrue(invalidated)
        XCTAssertTrue(preferences.snapshot.reduceMotion)
        XCTAssertTrue(preferences.snapshot.reduceTransparency)
    }

    func testUnchangedWorkspaceNotificationDoesNotInvalidateViews() {
        let center = NotificationCenter()
        let snapshot = AccessibilityDisplayPreferences.Snapshot(reduceMotion: true, reduceTransparency: true,
                                                                differentiateWithoutColor: true, increaseContrast: true)
        let preferences = AccessibilityDisplayPreferences(center: center, read: { snapshot })
        var invalidated = false
        withObservationTracking { _ = preferences.snapshot } onChange: { invalidated = true }
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertFalse(invalidated)
    }
}
