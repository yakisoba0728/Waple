import XCTest
@testable import WapleCore

/// `formatcombo` 슬롯 판정 — `TEXnFORMAT` 을 심을 자리를 정하는 유일한 기준이다.
///
/// 이 테스트가 있는 이유: 처음 구현할 때 `samplerCombos`(`"combo"` 어노테이션)로 슬롯을 찾았다.
/// **정작 고치려던 `effects/refraction/shaders/effects/refract.frag:8` 이 안 걸렸다** — 그 줄엔
/// `"formatcombo":true` 만 있고 `"combo"` 가 없다. 주석은 맞는 규칙을 적어 두고 코드는 다른 규칙을
/// 구현한, 조용히 아무것도 안 하는 수정이었다. 그 부류를 여기서 못박는다.
final class GLSLFormatComboSlotsTests: XCTestCase {

    /// 실물(`refract.frag:8`) 그대로 — `"combo"` 없이 `"formatcombo"` 만 있는 줄.
    func testFormatComboWithoutComboIsFound() {
        let src = #"uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal","default":"","format":"normalmap","formatcombo":true}"#
        XCTAssertEqual(GLSLTranslator.formatComboSlots(src), [1])
        // 같은 줄을 `samplerCombos` 로는 못 찾는다는 것이 이 함수가 존재하는 이유다.
        XCTAssertTrue(GLSLTranslator.samplerCombos(src).isEmpty)
    }

    /// 둘 다 있는 줄(실물 `genericimage2.frag:21`)은 양쪽에서 다 잡혀야 한다.
    func testBothAnnotationsCoexist() {
        let src = #"uniform sampler2D g_Texture1; // {"combo":"NORMALMAP","format":"rg88","formatcombo":true}"#
        XCTAssertEqual(GLSLTranslator.formatComboSlots(src), [1])
        XCTAssertEqual(GLSLTranslator.samplerCombos(src), [1: "NORMALMAP"])
    }

    /// `"combo"` 만 있는 줄은 포맷 슬롯이 아니다(반대 방향 오검출).
    func testComboOnlyIsNotAFormatSlot() {
        let src = #"uniform sampler2D g_Texture2; // {"mode":"opacitymask","combo":"MASK"}"#
        XCTAssertTrue(GLSLTranslator.formatComboSlots(src).isEmpty)
    }

    /// 죽은 선언은 콤보를 켜면 안 된다 — 줄 주석 처리분과 블록 주석 속 선언.
    func testCommentedOutDeclarationsAreIgnored() {
        let src = """
        //uniform sampler2D g_Texture3; // {"formatcombo":true}
        /* uniform sampler2D g_Texture5; // {"formatcombo":true} */
        uniform sampler2D g_Texture4; // {"formatcombo":true}
        """
        XCTAssertEqual(GLSLTranslator.formatComboSlots(src), [4])
    }

    /// 여러 슬롯이 섞인 실물 형태(`fur4.frag`: 1·4·8).
    func testMultipleSlots() {
        let src = """
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"format":"normalmap","formatcombo":true,"combo":"NORMALMAP"}
        uniform sampler2D g_Texture4; // {"default":"gradient/gradient_toon_smooth","formatcombo":true,"nonremovable":true}
        uniform sampler2D g_Texture8; // {"material":"fur","default":"util/fur","formatcombo":true}
        """
        XCTAssertEqual(GLSLTranslator.formatComboSlots(src), [1, 4, 8])
    }

    /// CRLF 실물 개행에서도 동작해야 한다(`samplerCombos` 주석이 경고하는 그 자리).
    func testCRLFSource() {
        let src = "uniform sampler2D g_Texture2; // {\"formatcombo\":true}\r\nuniform sampler2D g_Texture0; // {}\r\n"
        XCTAssertEqual(GLSLTranslator.formatComboSlots(src), [2])
    }
}
