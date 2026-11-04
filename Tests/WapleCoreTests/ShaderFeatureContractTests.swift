import XCTest
@testable import WapleCore

final class ShaderFeatureContractTests: XCTestCase {
    private let vertex = "void main() { gl_Position = vec4(a_Position, 1.0); }"

    func testUniformArraysPreserveElementTypeExtentAndNonoverlappingOffsets() throws {
        let shader = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: """
        uniform float weights[5];
        uniform vec3 colors[2];
        uniform mat3 transform;
        uniform float opacity;
        void main() { gl_FragColor = vec4(transform * colors[1], weights[4] * opacity); }
        """, combos: [:]))
        XCTAssertEqual(shader.materialParams.map(\.arrayCount), [5, 2, 1, 1])
        XCTAssertEqual(shader.materialParams.map(\.slotOffset), [0, 2, 4, 7])
        XCTAssertEqual(shader.materialParams.map(\.slotCount), [2, 2, 3, 1])
        XCTAssertEqual(shader.materialSlotCount, 8)
    }

    func testPackingUsesNaturalScalarVectorAndMatrixStrides() {
        XCTAssertEqual(GLSLTranslator.packUniform(type: .float, arrayCount: 5, values: [1, 2, 3, 4, 5]),
                       [SIMD4(1, 2, 3, 4), SIMD4(5, 0, 0, 0)])
        XCTAssertEqual(GLSLTranslator.packUniform(type: .vec2, arrayCount: 2, values: [1, 2, 3, 4]),
                       [SIMD4(1, 2, 3, 4)])
        XCTAssertEqual(GLSLTranslator.packUniform(type: .vec3, arrayCount: 2, values: [1, 2, 3, 4, 5, 6]),
                       [SIMD4(1, 2, 3, 0), SIMD4(4, 5, 6, 0)])
        XCTAssertEqual(GLSLTranslator.packUniform(type: .mat3, values: [1, 2, 3, 4, 5, 6, 7, 8, 9]),
                       [SIMD4(1, 2, 3, 0), SIMD4(4, 5, 6, 0), SIMD4(7, 8, 9, 0)])
    }

    func testIntegerPackingPreservesBitsAndBoundsHostileValues() {
        let signed = GLSLTranslator.packUniform(type: .int, arrayCount: 2, values: [-7, 12])
        XCTAssertEqual(Int32(bitPattern: signed[0].x.bitPattern), -7)
        XCTAssertEqual(Int32(bitPattern: signed[0].y.bitPattern), 12)
        let unsigned = GLSLTranslator.packUniform(type: .uvec4, values: [1, -1, .infinity, 42])
        XCTAssertEqual(unsigned[0].x.bitPattern, 1)
        XCTAssertEqual(unsigned[0].y.bitPattern, 0)
        XCTAssertEqual(unsigned[0].z.bitPattern, 0)
        XCTAssertEqual(unsigned[0].w.bitPattern, 42)
    }

    func testEngineArrayValuesAreDistinctFromMaterialConstants() throws {
        let shader = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: """
        uniform vec4 g_LightsColorRadius[4];
        uniform vec3 g_EyePosition;
        uniform vec3 g_LightAmbientColor;
        void main() { gl_FragColor = vec4(g_LightsColorRadius[1].rgb + g_EyePosition + g_LightAmbientColor, 1.0); }
        """, combos: [:]))
        XCTAssertTrue(shader.materialParams.isEmpty)
        XCTAssertEqual(shader.engineParams.map(\.name), ["g_LightsColorRadius", "g_EyePosition", "g_LightAmbientColor"])
        XCTAssertEqual(shader.engineParams.map(\.slotOffset), [0, 4, 5])
        XCTAssertEqual(shader.engineSlotCount, 6)
    }

    func testOneElementArrayKeepsArraySemanticsAndInvalidExtentsRefuseTranslation() throws {
        let shader = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: """
        uniform vec4 colors[1];
        void main() { gl_FragColor = colors[0]; }
        """, combos: [:]))
        XCTAssertTrue(try XCTUnwrap(shader.materialParams.first).isArray)
        for extent in ["0", "-1", "4097", "missing", "1 ? 2 : 3"] {
            XCTAssertNil(GLSLTranslator.translate(vertex: vertex, fragment: "uniform vec4 colors[\(extent)];\nvoid main() { gl_FragColor=colors[0]; }", combos: [:]))
        }
    }

    func testVertexAndFragmentTextureRequirementsStaySeparate() throws {
        let shader = try XCTUnwrap(GLSLTranslator.translate(vertex: """
        uniform sampler2D g_Texture5;
        void main() { gl_Position = vec4(a_Position + texSample2DLod(g_Texture5, a_TexCoord, 0.0).xyz, 1.0); }
        """, fragment: """
        uniform sampler3D g_Texture1;
        void main() { gl_FragColor = texSample3D(g_Texture1, vec3(0.25)); }
        """, combos: [:]))
        XCTAssertEqual(shader.vertexTextureSlots, [5])
        XCTAssertEqual(shader.fragmentTextureSlots, [1])
        XCTAssertEqual(shader.textureKinds[1], .sampler3D)
        XCTAssertEqual(shader.textureKinds[5], .sampler2D)
    }

    func testDirectiveBlockCommentsContinueLexingAndCannotJoinTokens() throws {
        let output = try XCTUnwrap(ShaderPreprocessor.preprocessStrict("""
        #if 2 /* comment */ == 1
        wrong
        #else
        right
        #endif
        #define A /* ignored */ 3
        #if A == 3
        alias
        #endif
        """, combos: [:]))
        XCTAssertFalse(output.contains("wrong"))
        XCTAssertTrue(output.contains("right"))
        XCTAssertTrue(output.contains("alias"))
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#if 1 /* unfinished", combos: [:]))
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#if 1 /* c */ ? 2 : 3\nX\n#endif", combos: [:]))
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#if 1/*c*/2\nX\n#endif", combos: [:]))
        for invalid in ["(1", "1 +", "defined()", "defined(1)", "defined(A", ")"] {
            XCTAssertNil(ExprEval.evalChecked(invalid, defines: [:]), invalid)
        }
    }

    func testAlreadySupportedArithmeticWrapsAt32Bits() {
        XCTAssertEqual(ExprEval.evalChecked("2147483647 + 1 < 0", defines: [:]), 1)
        XCTAssertEqual(ExprEval.evalChecked("65536 * 65536", defines: [:]), 0)
        XCTAssertEqual(ExprEval.evalChecked("-(-2147483648)", defines: [:]), -2147483648)
        XCTAssertEqual(ExprEval.evalChecked("(-2147483648) / -1", defines: [:]), -2147483648)
        XCTAssertEqual(ExprEval.evalChecked("(-2147483648) % -1", defines: [:]), 0)
        XCTAssertEqual(ExprEval.evalChecked("7 / 0", defines: [:]), 0)
    }

    func testLightingGeneratorDeclaresExactParallelArrayShapes() throws {
        let output = try XCTUnwrap(ShaderPreprocessor.preprocessStrict("#require LightingV1", combos: [
            "LIGHTING": 1, "LIGHTS_POINT": 2, "LIGHTS_POINT_SHADOW": 1,
            "LIGHTS_SPOT": 4, "LIGHTS_SPOT_SHADOW_COOKIE": 1, "LIGHTS_SPOT_COOKIE": 1, "LIGHTS_SPOT_SHADOW": 1,
            "LIGHTS_TUBE": 1, "LIGHTS_DIRECTIONAL": 2, "LIGHTS_DIRECTIONAL_SHADOW": 1,
        ]))
        let uniforms = GLSLTranslator.parseUniforms(output)
        XCTAssertEqual(uniforms.first { $0.name == "g_LPoint_Color" }?.arrayCount, 2)
        XCTAssertEqual(uniforms.first { $0.name == "g_LFeature_ShadowProjection" }?.arrayCount, 6)
        XCTAssertEqual(uniforms.first { $0.name == "g_LFeature_ShadowPointProjection" }?.arrayCount, 1)
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#require LightingV1", combos: ["LIGHTING": 1, "LIGHTS_POINT": 1, "LIGHTS_POINT_SHADOW": 2]))
        XCTAssertEqual(ShaderPreprocessor.preprocess("#require LightingV1", combos: ["LIGHTING": 0]), "")
    }

    func testShaderAttributesMatchAllLosslessModelChannels() throws {
        let layout = try XCTUnwrap(Model3D.vertexAttributeLayout(for: 0x03ff_ffff))
        let shaderAttributes = GLSLTranslator.vertexAttributeWhitelist
        XCTAssertEqual(Set(shaderAttributes.map(\.name)), Set(layout.attributes.map(\.name)))
        XCTAssertEqual(shaderAttributes.count, 26)
        for attribute in layout.attributes {
            let shader = try XCTUnwrap(shaderAttributes.first { $0.name == attribute.name })
            XCTAssertEqual(shader.type.components, attribute.components, attribute.name)
            XCTAssertEqual(shader.type == .uvec4, attribute.isInteger, attribute.name)
            XCTAssertTrue((0..<31).contains(shader.slot), attribute.name)
        }
    }
}
