import XCTest
import Metal
@testable import WapleCore

/// Exercises real translation, Metal compilation, packed CPU values and observable GPU output together.
final class ShaderFeatureMetalTests: XCTestCase {
    private let vertex = "void main() { gl_Position = vec4(a_Position, 1.0); }"

    private func render(vertex: String? = nil, fragment: String, combos: [String: Int] = [:],
                        material: [String: [Float]] = [:], engine: [String: [Float]] = [:],
                        include: (String) -> String? = { _ in nil },
                        textures: [Int: MTLTexture] = [:], device suppliedDevice: MTLDevice? = nil) throws -> SIMD4<Float> {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let translated = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex ?? self.vertex, fragment: fragment,
                                                               combos: combos, include: include))
        let library = try device.makeLibrary(source: translated.msl, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "ev_main")
        pipeline.fragmentFunction = library.makeFunction(name: "ef_main")
        pipeline.colorAttachments[0].pixelFormat = .rgba32Float
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3; descriptor.attributes[0].offset = 0; descriptor.attributes[0].bufferIndex = 4
        descriptor.attributes[1].format = .float2; descriptor.attributes[1].offset = 12; descriptor.attributes[1].bufferIndex = 4
        descriptor.layouts[4].stride = 20
        pipeline.vertexDescriptor = descriptor
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(state)
        let vertices: [Float] = [-1, -1, 0, 0, 0, 3, -1, 0, 0, 0, -1, 3, 0, 0, 0]
        let buffer = try XCTUnwrap(vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        encoder.setVertexBuffer(buffer, offset: 0, index: 4)
        var engineU = [Float](repeating: 0, count: 100)
        for i in [0, 5, 10, 15] { engineU[i] = 1 }
        engineU.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        var packed = [SIMD4<Float>](repeating: .zero, count: max(1, translated.materialSlotCount))
        for p in translated.materialParams {
            let values = GLSLTranslator.packUniform(type: p.type, arrayCount: p.arrayCount, values: material[p.sceneKey] ?? p.defaultValue)
            packed.replaceSubrange(p.slotOffset..<(p.slotOffset + p.slotCount), with: values)
        }
        packed.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        var enginePacked = [SIMD4<Float>](repeating: .zero, count: max(1, translated.engineSlotCount))
        for p in translated.engineParams {
            let values = GLSLTranslator.packUniform(type: p.type, arrayCount: p.arrayCount, values: engine[p.name] ?? [])
            enginePacked.replaceSubrange(p.slotOffset..<(p.slotOffset + p.slotCount), with: values)
        }
        enginePacked.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 9)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 9)
        }
        for slot in translated.vertexTextureSlots { encoder.setVertexTexture(textures[slot], index: slot) }
        for slot in translated.fragmentTextureSlots { encoder.setFragmentTexture(textures[slot], index: slot) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, String(describing: command.error))
        var pixel = SIMD4<Float>.zero
        withUnsafeMutableBytes(of: &pixel) { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return pixel
    }

    private func assertColor(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 0.0001, file: file, line: line) }
    }

    func testTypedArraysAndMatrixReadActualPackedValuesThroughHelpers() throws {
        let pixel = try render(fragment: """
        uniform float weights[5]; // {"material":"weights"}
        uniform vec3 colors[2]; // {"material":"colors"}
        uniform mat3 transform; // {"material":"transform"}
        vec3 value() { return transform * colors[1] * weights[4]; }
        void main() { gl_FragColor = vec4(value(), 1.0); }
        """, material: ["weights": [0, 0, 0, 0, 0.5], "colors": [9, 9, 9, 0.2, 0.3, 0.4],
                         "transform": [2, 0, 0, 0, 3, 0, 0, 0, 4]])
        assertColor(pixel, SIMD4(0.2, 0.45, 0.8, 1))
    }

    func testEngineLegacyArrayCameraAndAmbientAreFedIndependently() throws {
        let pixel = try render(fragment: """
        uniform vec4 g_LightsColorRadius[4];
        uniform vec3 g_EyePosition;
        uniform vec3 g_LightAmbientColor;
        uniform vec3 g_LightSkylightColor;
        vec3 value() { return g_LightsColorRadius[1].rgb + g_EyePosition + g_LightAmbientColor + g_LightSkylightColor; }
        void main() { gl_FragColor = vec4(value(), 1.0); }
        """, engine: ["g_LightsColorRadius": [9, 9, 9, 9, 0.1, 0.2, 0.3, 4], "g_EyePosition": [0.01, 0.02, 0.03],
                       "g_LightAmbientColor": [0.2, 0, 0], "g_LightSkylightColor": [0, 0, 0.4]])
        assertColor(pixel, SIMD4(0.31, 0.22, 0.73, 1))
    }

    func testIntegerUniformArraysPreserveNumericBits() throws {
        let pixel = try render(fragment: """
        uniform uint offsets[3]; // {"material":"offsets"}
        uniform int delta; // {"material":"delta"}
        void main() { gl_FragColor = vec4(float(offsets[2]) / 10.0, float(delta) / 10.0, 0.0, 1.0); }
        """, material: ["offsets": [100, 200, 7], "delta": [-3]])
        assertColor(pixel, SIMD4(0.7, -0.3, 0, 1))
    }

    func testArrayElementWidthParticipatesInHelperReturnCoercion() throws {
        let pixel = try render(fragment: """
        uniform vec4 colors[2]; // {"material":"colors"}
        vec3 value() { return colors[1]; }
        void main() { gl_FragColor = vec4(value(), 1.0); }
        """, material: ["colors": [9, 9, 9, 9, 0.2, 0.3, 0.4, 0.9]])
        assertColor(pixel, SIMD4(0.2, 0.3, 0.4, 1))
    }

    func testArrayParametersAcceptBothThreadAndConstantAddressSpaces() throws {
        let pixel = try render(fragment: """
        uniform float weights[2]; // {"material":"weights"}
        float total(float values[2]) { return values[0] + values[1]; }
        void main() {
            float local[2] = {0.2, 0.3};
            gl_FragColor = vec4(total(local), total(weights), 0.0, 1.0);
        }
        """, material: ["weights": [0.3, 0.4]])
        assertColor(pixel, SIMD4(0.5, 0.7, 0, 1))
    }

    func testScalarCast3x3ReplicatesOffDiagonalValues() throws {
        let pixel = try render(fragment: """
        void main() {
            mat3 m = CAST3X3(0.25);
            gl_FragColor = vec4(m[0][1], m[1][0], m[2][1], 1.0);
        }
        """)
        assertColor(pixel, SIMD4(0.25, 0.25, 0.25, 1))
    }

    func testArrayAndMatrixVaryingsPassThroughTransitiveHelpers() throws {
        let pixel = try render(vertex: """
        varying mat3 basis;
        varying vec3 colors[2];
        void setValues() { basis = mat3(1.0); colors[1] = vec3(0.2, 0.3, 0.4); }
        void wrapper() { setValues(); }
        void main() { wrapper(); gl_Position = vec4(a_Position, 1.0); }
        """, fragment: """
        varying mat3 basis;
        varying vec3 colors[2];
        vec3 value() { return basis * colors[1]; }
        vec3 wrapper() { return value(); }
        void main() { gl_FragColor = vec4(wrapper(), 1.0); }
        """)
        assertColor(pixel, SIMD4(0.2, 0.3, 0.4, 1))
    }

    func testGeneratedLightingUsesBoundParallelArraysAndActualFunctionArguments() throws {
        // A diagnostic PBR leaf isolates generation and bindings from the already-tested BRDF formula.
        let pixel = try render(fragment: """
        vec3 ComputePBRLightShadow(vec3 n, vec3 l, vec3 v, vec3 color, vec3 lightColor, float radius, float exponent, vec3 spec, vec3 f0, float roughness, float metallic, float shadow) {
            return lightColor * radius + l * exponent;
        }
        #require LightingV1
        void main() { gl_FragColor = vec4(PerformLighting_V1(vec3(0), vec3(1), vec3(0,0,1), vec3(0,0,1), vec3(1), vec3(0.04), 0.5, 0.0), 1.0); }
        """, combos: ["LIGHTING": 1, "LIGHTS_POINT": 1],
        engine: ["g_LPoint_Color": [0.1, 0.2, 0.3, 2], "g_LPoint_Origin": [0.01, 0.02, 0.03, 3]])
        assertColor(pixel, SIMD4(0.23, 0.46, 0.69, 1))
    }

    func testVertexTextureIsBoundToVertexStage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var texel = SIMD4<Float>(0.2, 0.3, 0.4, 1)
        withUnsafeBytes(of: &texel) { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        let pixel = try render(vertex: """
        uniform sampler2D g_Texture5;
        varying vec4 value;
        vec4 readValue() { return texSample2DLod(g_Texture5, vec2(0.5), 0.0); }
        void main() { value = readValue(); gl_Position = vec4(a_Position, 1.0); }
        """, fragment: """
        varying vec4 value;
        void main() { gl_FragColor = value; }
        """, textures: [5: texture], device: device)
        assertColor(pixel, SIMD4(0.2, 0.3, 0.4, 1))
    }

    func testAllGeneratedLightingBranchesCompileWithActualPBRHeader() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/WapleRender/Resources/WEAssets/shaders")
        let include: (String) -> String? = { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertNotNil(include("common_pbr_2.h"), "The real bundled PBR fixture must be present")
        let fragment = """
        #define SHADOW_ATLAS_SAMPLER g_Texture6
        #define SHADOW_ATLAS_TEXEL g_Texture6Texel
        #define COOKIE_SAMPLER g_Texture7
        uniform sampler2DComparison g_Texture6;
        uniform sampler2D g_Texture7;
        #include "common_pbr_2.h"
        #require LightingV1
        void main() { gl_FragColor = vec4(PerformLighting_V1(vec3(0), vec3(1), vec3(0,0,1), vec3(0,0,1), vec3(1), vec3(0.04), 0.5, 0.0), 1.0); }
        """
        let translated = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [
            "LIGHTING": 1, "LIGHTS_POINT": 2, "LIGHTS_POINT_SHADOW": 1,
            "LIGHTS_SPOT": 4, "LIGHTS_SPOT_SHADOW_COOKIE": 1, "LIGHTS_SPOT_COOKIE": 1, "LIGHTS_SPOT_SHADOW": 1,
            "LIGHTS_TUBE": 1, "LIGHTS_DIRECTIONAL": 2, "LIGHTS_DIRECTIONAL_SHADOW": 1,
        ], include: include))
        let library = try device.makeLibrary(source: translated.msl, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "ef_main"))
    }

    func testCustomSkinTangentAndUV1AttributesCompileWithTypedPalette() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let translated = try XCTUnwrap(GLSLTranslator.translate(vertex: """
        uniform mat4x3 g_Bones[1];
        attribute vec3 a_Position;
        attribute vec4 a_TexCoordVec4;
        attribute vec4 a_Tangent4;
        attribute uvec4 a_BlendIndices;
        attribute vec4 a_BlendWeights;
        varying vec4 value;
        vec3 position() { return mul(vec4(a_Position, 1.0), g_Bones[a_BlendIndices.x]) * a_BlendWeights.x; }
        void main() {
            value = a_TexCoordVec4 + vec4(a_Tangent4.xyz, 0.0);
            gl_Position = vec4(position(), 1.0);
        }
        """, fragment: "varying vec4 value;\nvoid main() { gl_FragColor = value; }", combos: [:]))
        XCTAssertEqual(translated.vertexAttributes, ["a_Position", "a_TexCoordVec4", "a_Tangent4", "a_BlendIndices", "a_BlendWeights"])
        XCTAssertEqual(translated.engineParams.first { $0.name == "g_Bones" }?.arrayCount, 1)
        let library = try device.makeLibrary(source: translated.msl, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "ev_main"))
    }
}
