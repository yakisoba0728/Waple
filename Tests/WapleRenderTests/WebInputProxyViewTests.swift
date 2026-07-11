import XCTest
import WebKit
@testable import WapleRender

/// 감사 W-B3: fit 사각형 밖 마우스 릴리즈가 미전송되면 웹이 buttons=1(드래그 중)로 고착 —
/// 드래그 릴리즈는 경계로 클램프해 항상 전달한다. 좌표 변환(webPoint)의 클램프 규약 검증.
final class WebInputProxyViewTests: XCTestCase {
    func testWebPointClampsOnlyWhenAsked() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let proxy = WebInputProxyView(target: web)
        proxy.frame = NSRect(x: 0, y: 0, width: 800, height: 600)  // fit == bounds(레터박스 없음)

        // 안: 클램프 여부와 무관하게 동일 매핑(회귀 없음). y 는 상단 원점으로 반전.
        XCTAssertEqual(proxy.webPoint(from: NSPoint(x: 400, y: 300))?.x, 400)
        XCTAssertEqual(proxy.webPoint(from: NSPoint(x: 400, y: 300))?.y, 300)
        XCTAssertEqual(proxy.webPoint(from: NSPoint(x: 400, y: 300), clampToFit: true)?.x, 400)
        XCTAssertEqual(proxy.webPoint(from: NSPoint(x: 400, y: 300), clampToFit: true)?.y, 300)

        // 밖: 기본은 nil(이동/클릭은 종전대로 무시) — 클램프 요청 시에만 경계 안 좌표 반환.
        XCTAssertNil(proxy.webPoint(from: NSPoint(x: 900, y: 700)))
        let topRight = proxy.webPoint(from: NSPoint(x: 900, y: 700), clampToFit: true)
        XCTAssertEqual(topRight?.x, 799)  // 상한 width-1 — 뷰포트 밖(x==width) 매핑 금지
        XCTAssertEqual(topRight?.y, 0)
        let bottomLeft = proxy.webPoint(from: NSPoint(x: -50, y: -50), clampToFit: true)
        XCTAssertEqual(bottomLeft?.x, 0)
        XCTAssertEqual(bottomLeft?.y, 599)
        withExtendedLifetime(web) {}  // target 은 weak — 검증 끝까지 생존 보장
    }

    func testWebPointClampInsideLetterboxedFit() {
        // 뷰(1000x600)가 웹(800x600)보다 넓음 → fit 은 x=100..900. 레터박스 영역 릴리즈도 fit 경계로.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let proxy = WebInputProxyView(target: web)
        proxy.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)

        XCTAssertNil(proxy.webPoint(from: NSPoint(x: 50, y: 300)))
        let p = proxy.webPoint(from: NSPoint(x: 50, y: 300), clampToFit: true)
        XCTAssertEqual(p?.x, 0)
        XCTAssertEqual(p?.y, 300)
        withExtendedLifetime(web) {}
    }
}
