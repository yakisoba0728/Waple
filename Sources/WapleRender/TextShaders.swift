import Foundation
import Metal
import WapleCore

enum TextShaders {
    static let tintRGBFunction = """
    float3 textForegroundRGB(float3 whiteRGB, float3 blackRGB, float3 tint) {
        return blackRGB + (whiteRGB - blackRGB) * tint;
    }
    """
    static let fragments = tintRGBFunction + "\n" + """
    fragment float4 f_text(VOut in [[stage_in]],
                          texture2d<float> whiteTex [[texture(0)]],
                          texture2d<float> blackTex [[texture(2)]],
                          constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 white = whiteTex.sample(s, in.uv);
        float4 black = blackTex.sample(s, in.uv);
        float alpha = white.a * tint.a;
        return float4(textForegroundRGB(white.rgb, black.rgb, tint.rgb) * alpha, alpha);
    }
    fragment float4 f_text_blend(VOut in [[stage_in]],
                                texture2d<float> whiteTex [[texture(0)]],
                                texture2d<float> dst [[texture(1)]],
                                texture2d<float> blackTex [[texture(2)]],
                                constant float4 &tint [[buffer(0)]],
                                constant int &mode [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 white = whiteTex.sample(s, in.uv);
        float4 black = blackTex.sample(s, in.uv);
        float2 dstUV = float2(in.pos.x / float(dst.get_width()), in.pos.y / float(dst.get_height()));
        float4 d = dst.sample(s, dstUV);
        float3 rgb = textForegroundRGB(white.rgb, black.rgb, tint.rgb);
        return float4(applyBlending(mode, d.rgb, rgb, white.a * tint.a), d.a);
    }
    """
    static var source: String { QuadShaders.source + "\n" + fragments }
}

final class TextShaderPipelines {
    let normal: MTLRenderPipelineState
    let blend: MTLRenderPipelineState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        let source = TextShaders.source
        let library = try WapleProfiler.compile(source) { try device.makeLibrary(source: source, options: nil) }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v_main")
        descriptor.fragmentFunction = library.makeFunction(name: "f_text")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        normal = try WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
        descriptor.fragmentFunction = library.makeFunction(name: "f_text_blend")
        attachment.isBlendingEnabled = false
        blend = try WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
    }
}
