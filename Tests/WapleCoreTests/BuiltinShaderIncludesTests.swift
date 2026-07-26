import XCTest
@testable import WapleCore

/// BuiltinShaderIncludes.commonBlending 의 소스 계약 — :17-18 주석이 주장하는
/// "정본 WapleRender/BlendMSL.swift(F676)와 식 단위 일치" 가 참인지 검증한다.
final class BuiltinShaderIncludesTests: XCTestCase {
    /// 감사 V06: GLSL rgb2hsl 은 정본 we_rgb2hsl 과 같이 입력을 saturate 해야 한다 — 누락 시
    /// HDR>1 입력에서 블렌드 모드 26-29(Hue/Saturation/Color/Luminosity)가 경로별로 다른 색을 낸다.
    func testRGB2HSLSaturatesInputLikeBlendMSL() throws {
        let src = try XCTUnwrap(BuiltinShaderIncludes.lookup("common_blending.h"))
        // rgb2hsl 헤더부터 min/max 계산(fmin) 직전까지의 전두부에 saturate 선적용이 있어야 한다.
        guard let head = src.range(of: "vec3 rgb2hsl(vec3 c) {"),
              let fmin = src.range(of: "float fmin", range: head.upperBound..<src.endIndex) else {
            return XCTFail("rgb2hsl 본문을 찾지 못함")
        }
        let prelude = src[head.upperBound..<fmin.lowerBound]
        XCTAssertTrue(prelude.contains("c = saturate(c);"),
                      "rgb2hsl 전두부에 saturate 선적용 없음 — BlendMSL we_rgb2hsl(F676)과 불일치")
    }
}
