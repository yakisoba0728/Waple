import SwiftUI
import XCTest
@testable import Waple

/// 공유 컴포넌트의 **순수 로직**만 검증한다(2026-08-17 UI 전면 개편 Unit S).
///
/// 뷰 자체는 검증 대상이 아니다 — 이 저장소에는 SwiftUI 뷰를 인스턴스화하는 테스트가 없고
/// (청사진 §7.4), 여기서 그걸 시작할 이유도 없다. 대신 컴포넌트에서 **판정**에 해당하는 부분,
/// 즉 "어떤 상태가 어떤 링이 되는가" 와 "그 링이 어떤 토큰 값을 쓰는가" 를 못으로 박는다.
/// 이 둘이 화면마다 삼항으로 흩어져 있던 것이 컴포넌트를 만든 이유이므로, 흩어짐이 되돌아오면
/// 여기가 빨개져야 한다.
final class ComponentTests: XCTestCase {

    // MARK: - TileRing 상태 → 링 결정

    /// 선택이 포커스를 이긴다. 둘 다인 타일에서 포커스 링이 이기면 "지금 적용 중" 이 화면에서
    /// 사라진다 — 종전 그리드가 이 순서였고, 순서 자체가 규약이다.
    func testTileRingSelectedOutranksFocused() {
        XCTAssertEqual(TileRing.tile(selected: true, focused: true), .selected)
        XCTAssertEqual(TileRing.tile(selected: true, focused: false), .selected)
        XCTAssertEqual(TileRing.tile(selected: false, focused: true), .focus)
        XCTAssertEqual(TileRing.tile(selected: false, focused: false), .none)
    }

    /// 드롭 대상이 선택을 이긴다. 드래그 중에는 "놓으면 여기" 가 유일하게 필요한 정보다.
    func testSurfaceRingDropTargetOutranksSelection() {
        XCTAssertEqual(TileRing.surface(dropTargeted: true, selected: true), .dropTarget)
        XCTAssertEqual(TileRing.surface(dropTargeted: true, selected: false), .dropTarget)
        XCTAssertEqual(TileRing.surface(dropTargeted: false, selected: true), .emphasis)
    }

    /// 큰 면의 평상시는 링 없음이 아니라 헤어라인이다. 실측: 모니터 박스는 우물 위에 놓인
    /// 큰 사각형이라 테두리를 빼면 경계가 사라진다. 이게 `.none` 으로 바뀌면 그 화면이 다시
    /// 자기 스트로크를 직접 그리게 되고, 그 순간 열거형이 있는 이유가 없어진다.
    func testSurfaceRingRestsOnHairlineNotNone() {
        XCTAssertEqual(TileRing.surface(dropTargeted: false, selected: false), .hairline)
        XCTAssertNotEqual(TileRing.surface(dropTargeted: false, selected: false), TileRing.none)
    }

    // MARK: - TileRing → 토큰

    /// 두께는 전부 `Surface` 에서 온다. 하나라도 리터럴로 돌아가면 두께 위계가 다시 갈라진다.
    func testRingLineWidthsComeFromSurfaceTokens() {
        XCTAssertEqual(TileRing.none.lineWidth, 0)
        XCTAssertEqual(TileRing.hairline.lineWidth, Surface.strokeHairline)
        XCTAssertEqual(TileRing.focus.lineWidth, Surface.strokeFocus)
        XCTAssertEqual(TileRing.selected.lineWidth, Surface.strokeSelected)
        XCTAssertEqual(TileRing.emphasis.lineWidth, Surface.strokeEmphasis)
        XCTAssertEqual(TileRing.dropTarget.lineWidth, Surface.strokeDropTarget)
    }

    /// **두께가 상태를 구분한다**(`Surface` 규약). 강한 상태일수록 굵다는 순서가 깨지면
    /// 색을 늘리지 않고 두께로 위계를 만든다는 전제 자체가 무너진다.
    func testRingThicknessIsStrictlyOrderedByStrength() {
        let ladder: [TileRing] = [.none, .hairline, .focus, .selected, .emphasis, .dropTarget]
        for (weaker, stronger) in zip(ladder, ladder.dropFirst()) {
            XCTAssertLessThan(weaker.lineWidth, stronger.lineWidth,
                              "\(weaker) 가 \(stronger) 보다 굵거나 같다 — 두께 위계가 깨졌다")
        }
    }

    /// 링 없음만 투명하다. 나머지가 투명해지면 화면에서 상태가 사라지는데 테스트는 초록이다.
    func testOnlyNoneRingIsInvisible() {
        XCTAssertEqual(TileRing.none.color, Color.clear)
        for ring: TileRing in [.hairline, .focus, .selected, .emphasis, .dropTarget] {
            XCTAssertNotEqual(ring.color, Color.clear, "\(ring) 의 색이 투명하다")
        }
    }

    /// 선택과 강조는 같은 색(액센트)이고 구분은 두께가 한다 — 색을 하나 더 만들지 않는다는
    /// 결정이 코드에 남아 있어야 한다. 포커스는 그 둘과 **달라야** 한다(액센트면 "무엇이
    /// 적용 중인가" 를 잃는다).
    func testSelectionUsesAccentAndFocusDoesNot() {
        XCTAssertEqual(TileRing.selected.color, TileRing.emphasis.color)
        XCTAssertEqual(TileRing.selected.color, ColorRole.selected)
        XCTAssertNotEqual(TileRing.focus.color, TileRing.selected.color)
        XCTAssertEqual(TileRing.focus.color, ColorRole.focusRing)
    }
}

// `PreviewImageCache` 의 이동은 여기서 다시 검증하지 않는다 — 동결 파일인
// `AppUIFixRegressionTests` 가 이미 그 타입을 이름으로 참조하므로, 이름이나 API 가 바뀌면
// 그쪽이 컴파일 단계에서 먼저 빨개진다. 같은 계약을 두 곳에서 단언하면 나중에 한쪽만 고친다.
