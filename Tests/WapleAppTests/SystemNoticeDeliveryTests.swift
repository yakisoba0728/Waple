import XCTest
@testable import Waple

@MainActor
final class SystemNoticeDeliveryTests: XCTestCase {
    func testDeliveryIsOptInBackgroundOnlyAndDeduplicated() {
        var sent: [String] = []
        let delivery = SystemNoticeDelivery(authorize: { $0(true) }, post: { sent.append($0) })
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(delivery.deliver("failure", enabled: false, windowVisible: false, now: now))
        XCTAssertFalse(delivery.deliver("failure", enabled: true, windowVisible: true, now: now))
        XCTAssertTrue(delivery.deliver("failure", enabled: true, windowVisible: false, now: now))
        XCTAssertFalse(delivery.deliver("failure", enabled: true, windowVisible: false, now: now.addingTimeInterval(1)))
        XCTAssertTrue(delivery.deliver("failure", enabled: true, windowVisible: false, now: now.addingTimeInterval(31)))
        XCTAssertEqual(sent, ["failure", "failure"])
    }

    func testAuthorizationDenialIsReturnedWithoutPosting() {
        var granted: Bool?
        let delivery = SystemNoticeDelivery(authorize: { $0(false) }, post: { _ in XCTFail("denied") })
        delivery.requestAuthorization { granted = $0 }
        XCTAssertEqual(granted, false)
    }
}
