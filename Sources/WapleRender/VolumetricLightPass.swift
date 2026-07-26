import Metal
import simd
import WapleCore

/// H5: 볼륨 라이트 샤프트(god rays) — castVolumetrics 라이트의 밀도 기반 산란.
/// 3D 씬 렌더 후 fullscreen 패스로 라이트 샤프트를 additive 합성한다.
/// 각 픽셀에서 라이트 방향과의 각도/거리를 지수 감쇠로 누적(density/volumetricsExponent 소비).
struct VolumetricLightParameters: Equatable {
    let color: SIMD3<Float>
    let position: SIMD3<Float>
    let direction: SIMD3<Float>
    let density: Float
    let exponent: Float
    let intensity: Float
    let innerCone: Float
    let outerCone: Float
}

final class VolumetricLightPass {
    private struct VolumetricUniforms {
        var cameraEye: SIMD4<Float>
        var cameraFwd: SIMD4<Float>
        var cameraRight: SIMD4<Float>
        var cameraUp: SIMD4<Float>
        var projParams: SIMD4<Float>   // x=fovY(rad), y=aspect, z=near, w=far
        var lightColor: SIMD4<Float>
        var lightPosition: SIMD4<Float>
        var lightDirection: SIMD4<Float>
        var lightParams: SIMD4<Float>   // x=density, y=exponent, z=intensity, w=innerCone
        var lightCone: SIMD4<Float>     // x=outerCone, y=0, z=0, w=0
    }

    private let pipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "volumetricVertex"),
              let fragment = library.makeFunction(name: "volumetricFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]!.pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0]!.isBlendingEnabled = true
        descriptor.colorAttachments[0]!.rgbBlendOperation = .add
        descriptor.colorAttachments[0]!.alphaBlendOperation = .add
        descriptor.colorAttachments[0]!.sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0]!.sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0]!.destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0]!.destinationAlphaBlendFactor = .one
        let pipeline: MTLRenderPipelineState?
        do {
            pipeline = try WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
        } catch {
            return nil
        }
        guard let pipeline else { return nil }
        self.pipeline = pipeline
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        cameraEye: SIMD3<Float>,
        cameraFwd: SIMD3<Float>,
        cameraRight: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        fovY: Float,
        aspect: Float,
        nearZ: Float,
        farZ: Float,
        light: VolumetricLightParameters
    ) -> Bool {
        guard destination.textureType == .type2D,
              destination.pixelFormat == .bgra8Unorm else {
            return false
        }
        var uniforms = VolumetricUniforms(
            cameraEye: SIMD4(cameraEye.x, cameraEye.y, cameraEye.z, 1),
            cameraFwd: SIMD4(cameraFwd.x, cameraFwd.y, cameraFwd.z, 0),
            cameraRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0),
            cameraUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0),
            projParams: SIMD4(fovY * .pi / 180, aspect, nearZ, farZ),
            lightColor: SIMD4(light.color.x, light.color.y, light.color.z, 1),
            lightPosition: SIMD4(light.position.x, light.position.y, light.position.z, 1),
            lightDirection: SIMD4(light.direction.x, light.direction.y, light.direction.z, 0),
            lightParams: SIMD4(light.density, light.exponent, light.intensity, light.innerCone),
            lightCone: SIMD4(light.outerCone, 0, 0, 0))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumetricUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VolumetricVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VolumetricVertexOut volumetricVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0, vertexID == 1 ? 3.0 : -1.0);
        VolumetricVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    struct VolumetricUniforms {
        float4 cameraEye;
        float4 cameraFwd;
        float4 cameraRight;
        float4 cameraUp;
        float4 projParams;   // x=fovY(rad), y=aspect, z=near, w=far
        float4 lightColor;
        float4 lightPosition;
        float4 lightDirection;
        float4 lightParams;  // x=density, y=exponent, z=intensity, w=innerCone
        float4 lightCone;    // x=outerCone
    };

    fragment float4 volumetricFragment(
        VolumetricVertexOut in [[stage_in]],
        constant VolumetricUniforms &u [[buffer(0)]]
    ) {
        // 픽셀 뷰 레이(월드) — fovY/aspect 로부터 perspective 재구성.
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float tanHalf = tan(u.projParams.x * 0.5);
        float3 viewRay = normalize(
            u.cameraFwd.xyz +
            u.cameraRight.xyz * (ndc.x * tanHalf * u.projParams.y) +
            u.cameraUp.xyz * (ndc.y * tanHalf));

        // 라이트 방향과 뷰 레이의 각도 — 콘 낮이면 샤프트 강함.
        float cosAngle = dot(viewRay, -u.lightDirection.xyz);
        float cone = clamp((cosAngle - u.lightCone.x) / max(u.lightParams.w - u.lightCone.x, 1e-4), 0.0, 1.0);
        cone = cone * cone * (3.0 - 2.0 * cone);
        if (cone <= 0.0) { return float4(0.0, 0.0, 0.0, 0.0); }

        // 라이트까지의 거리 — 지수 감쇠(density/volumetricsExponent 소비).
        float3 toLight = u.lightPosition.xyz - u.cameraEye.xyz;
        float dist = length(toLight);
        float falloff = exp(-u.lightParams.x * dist * 0.001);
        float intensity = u.lightParams.z * falloff * cone;

        // 볼륨 산란 근사: 지수에 따라 샤프트 형상 조절.
        float shaft = pow(intensity, u.lightParams.y);
        return float4(u.lightColor.rgb * shaft, 1.0);
    }
    """
}
