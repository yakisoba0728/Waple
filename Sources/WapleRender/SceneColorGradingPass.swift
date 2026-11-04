import Foundation
import Metal
import simd

public struct SceneColorGradingSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    public var hue: Float
    public var lutName: String?
    public var lutAmount: Float
    public init(enabled: Bool = false, brightness: Float = 1, contrast: Float = 1,
                saturation: Float = 1, hue: Float = 0, lutName: String? = nil, lutAmount: Float = 1) {
        self.enabled = enabled; self.brightness = brightness; self.contrast = contrast
        self.saturation = saturation; self.hue = hue; self.lutName = lutName; self.lutAmount = lutAmount
    }
    var parameters: SIMD4<Float> {
        SIMD4(brightness.isFinite ? max(0, brightness) : 1, contrast.isFinite ? max(0, contrast) : 1,
              saturation.isFinite ? max(0, saturation) : 1, hue.isFinite ? hue : 0)
    }
    var usesColor: Bool { enabled && parameters != SIMD4<Float>(1, 1, 1, 0) }
}

final class SceneColorGradingPass {
    private let plain: MTLRenderPipelineState
    private let lookup: MTLRenderPipelineState
    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "gradingVertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        plain = try pipeline("gradingColor")
        lookup = try pipeline("gradingLUT")
    }
    func encode(source: MTLTexture, destination: MTLTexture, commandBuffer: MTLCommandBuffer,
                settings: SceneColorGradingSettings, lut: MTLTexture?, hdr: Bool,
                fadeAlpha: Float = 0, fadeTint: SIMD3<Float> = .zero) -> Bool {
        guard source !== destination, source.width == destination.width, source.height == destination.height,
              lut == nil || lut?.textureType == .type3D else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(lut == nil ? plain : lookup)
        encoder.setFragmentTexture(source, index: 0)
        if let lut { encoder.setFragmentTexture(lut, index: 1) }
        var params = settings.parameters
        var options = SIMD4<Float>(settings.usesColor ? 1 : 0,
            settings.lutAmount.isFinite ? max(0, min(1, settings.lutAmount)) : 0, hdr ? 1 : 0,
            fadeAlpha.isFinite ? max(0, min(1, fadeAlpha)) : 0)
        var tint = SIMD4(fadeTint.x, fadeTint.y, fadeTint.z, 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct GradeOut { float4 pos [[position]]; float2 uv; };
    vertex GradeOut gradingVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return { float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y) };
    }
    float3 gradingHSV(float3 RGB) {
        float4 P = RGB.g < RGB.b ? float4(RGB.bg, -1.0, 2.0/3.0) : float4(RGB.gb, 0.0, -1.0/3.0);
        float4 Q = RGB.r < P.x ? float4(P.xyw, RGB.r) : float4(RGB.r, P.yzx);
        float C = Q.x - min(Q.w, Q.y);
        float H = abs((Q.w - Q.y) / (6.0 * C + 1e-10) + Q.z);
        return float3(H, C / (Q.x + 1e-10), Q.x);
    }
    float3 gradingRGB(float3 c) {
        float4 K = float4(1, 2.0/3.0, 1.0/3.0, 3);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }
    float4 gradeColor(float4 color, float4 params, float4 options) {
        if (options.x > 0) {
            color.rgb = mix(float3(0.5), color.rgb, params.y);
            float3 hsv = gradingHSV(color.rgb);
            hsv.z *= params.x; hsv.y *= params.z; hsv.x += params.w;
            color.rgb = gradingRGB(hsv);
        }
        return color;
    }
    float4 gradeFade(float4 color, float4 options, float4 tint) {
        color.rgb = mix(color.rgb, tint.rgb * 0.7, options.w);
        color.a = options.w + color.a * (1.0 - options.w);
        return color;
    }
    fragment float4 gradingColor(GradeOut in [[stage_in]], texture2d<float> source [[texture(0)]],
        constant float4& params [[buffer(0)]], constant float4& options [[buffer(1)]], constant float4& tint [[buffer(2)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return gradeFade(gradeColor(source.sample(s, in.uv), params, options), options, tint);
    }
    fragment float4 gradingLUT(GradeOut in [[stage_in]], texture2d<float> source [[texture(0)]],
        texture3d<float> lut [[texture(1)]], constant float4& params [[buffer(0)]],
        constant float4& options [[buffer(1)]], constant float4& tint [[buffer(2)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        constexpr sampler lookup(filter::linear, address::clamp_to_edge);
        float4 color = gradeColor(source.sample(s, in.uv), params, options);
        float3 excess = max(float3(0), color.rgb - 1.0);
        float3 filtered = lut.sample(lookup, color.rgb).rgb;
        if (options.z > 0) filtered *= 1.0 + dot(excess, float3(1));
        color.rgb = mix(color.rgb, filtered, options.y);
        return gradeFade(color, options, tint);
    }
    """
}
