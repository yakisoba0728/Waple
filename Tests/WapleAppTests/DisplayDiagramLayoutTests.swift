import XCTest
@testable import Waple

final class DisplayDiagramLayoutTests: XCTestCase {
    func testSideBySideMonitorsFillContainerProportionally() {
        // 주모니터(0,0,1920,1080) + 우측 보조(1920,0,1920,1080) → 컨테이너 800×300, 패딩 0
        let rects = DisplayDiagramLayout.rects(
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           CGRect(x: 1920, y: 0, width: 1920, height: 1080)],
            container: CGSize(width: 800, height: 300), padding: 0)
        // 전체 3840×1080 → 스케일 = min(800/3840, 300/1080) = 0.2083…
        let s = min(800.0 / 3840.0, 300.0 / 1080.0)
        XCTAssertEqual(rects[0].width, 1920 * s, accuracy: 0.5)
        XCTAssertEqual(rects[1].minX, rects[0].maxX, accuracy: 0.5)
        // 수직 중앙 정렬
        XCTAssertEqual(rects[0].midY, 150, accuracy: 0.5)
    }
    func testAppKitBottomOriginIsFlippedToTopOrigin() {
        // 보조가 주모니터 '위'(AppKit y+) → 다이어그램(상단 원점)에선 더 작은 y
        let rects = DisplayDiagramLayout.rects(
            screenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 500),
                           CGRect(x: 0, y: 500, width: 1000, height: 500)],
            container: CGSize(width: 500, height: 500), padding: 0)
        XCTAssertLessThan(rects[1].minY, rects[0].minY)
    }
    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(DisplayDiagramLayout.rects(screenFrames: [], container: CGSize(width: 100, height: 100), padding: 8).isEmpty)
    }
}
