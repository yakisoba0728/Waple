/// 3D 메시(MDLV0023) + perspective billboard 렌더 MSL.
/// `generic4`/`genericimage4`의 source-confirmed finite-point Cook–Torrance 코어를 공유한다.
/// 정점은 [[stage_in]] 대신 buffer(0) 수동 페치:
///   • 정적: pos3+normal3+uv2 = 8 float
///   • 스키닝: pos3+normal3+uv2+boneIdx4+weight4 = 16 float
enum Mesh3DShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MeshU {
        float4x4 mvp;
        float4x4 model;
        float4x4 normalMatrix;
        float4 tint;
        float4 material;      // roughness, metallic, alphaCutoff, 0=unlit/1=mesh hemi/2=image flat
        float4 specularTint;
    };
    struct FrameU {
        float4 cameraEye;
        float4 ambient;
        float4 skylight;
        float4 meta;          // x=light count; shadow fields are introduced by P4
    };
    struct LightU {
        float4 positionExponent;
        float4 colorRadius;
        float4 shadow;
    };
    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float3 worldPos;
        float3 worldNormal;
    };
    struct ShadowVOut {
        float4 pos [[position]];
        float2 uv;
    };

    inline float3 normalizedOr(float3 value, float3 fallback) {
        float length2 = dot(value, value);
        return length2 > 1e-12 ? value * rsqrt(length2) : fallback;
    }

    vertex VOut mv_main(uint vid [[vertex_id]],
                        const device float* vtx [[buffer(0)]],
                        constant MeshU& u [[buffer(1)]]) {
        uint b = vid * 8;
        float3 localPos = float3(vtx[b], vtx[b + 1], vtx[b + 2]);
        float3 localNormal = float3(vtx[b + 3], vtx[b + 4], vtx[b + 5]);
        float4 world = u.model * float4(localPos, 1.0);
        VOut o;
        o.pos = u.mvp * float4(localPos, 1.0);
        o.worldPos = world.xyz;
        o.worldNormal = normalizedOr((u.normalMatrix * float4(localNormal, 0.0)).xyz,
                                     normalizedOr(localNormal, float3(0.0, 0.0, 1.0)));
        // UV 원점 = 상단(V flip 없음): 기존 3D A/B 실측 규약 보존.
        o.uv = float2(vtx[b + 6], vtx[b + 7]);
        return o;
    }

    vertex VOut mv_skin(uint vid [[vertex_id]],
                        const device float* vtx [[buffer(0)]],
                        constant MeshU& u [[buffer(1)]],
                        const device float4x4* bones [[buffer(2)]]) {
        uint b = vid * 16;
        float3 localPos = float3(vtx[b], vtx[b + 1], vtx[b + 2]);
        float3 localNormal = float3(vtx[b + 3], vtx[b + 4], vtx[b + 5]);
        uint4 idx = uint4(uint(vtx[b + 8] + 0.5), uint(vtx[b + 9] + 0.5),
                          uint(vtx[b + 10] + 0.5), uint(vtx[b + 11] + 0.5));
        float4 weights = float4(vtx[b + 12], vtx[b + 13], vtx[b + 14], vtx[b + 15]);
        float weightSum = weights.x + weights.y + weights.z + weights.w;
        float3 skinnedPos = localPos;
        float3 skinnedNormal = localNormal;
        if (weightSum > 0.0) {
            weights /= weightSum;
            skinnedPos = (weights.x * (bones[idx.x] * float4(localPos, 1.0))
                        + weights.y * (bones[idx.y] * float4(localPos, 1.0))
                        + weights.z * (bones[idx.z] * float4(localPos, 1.0))
                        + weights.w * (bones[idx.w] * float4(localPos, 1.0))).xyz;
            skinnedNormal = (weights.x * (bones[idx.x] * float4(localNormal, 0.0))
                           + weights.y * (bones[idx.y] * float4(localNormal, 0.0))
                           + weights.z * (bones[idx.z] * float4(localNormal, 0.0))
                           + weights.w * (bones[idx.w] * float4(localNormal, 0.0))).xyz;
        }
        float4 world = u.model * float4(skinnedPos, 1.0);
        VOut o;
        o.pos = u.mvp * float4(skinnedPos, 1.0);
        o.worldPos = world.xyz;
        o.worldNormal = normalizedOr((u.normalMatrix * float4(skinnedNormal, 0.0)).xyz,
                                     normalizedOr(skinnedNormal, float3(0.0, 0.0, 1.0)));
        o.uv = float2(vtx[b + 6], vtx[b + 7]);
        return o;
    }

    vertex ShadowVOut sv_main(uint vid [[vertex_id]],
                              const device float* vtx [[buffer(0)]],
                              constant MeshU& u [[buffer(1)]]) {
        uint b = vid * 8;
        ShadowVOut o;
        o.pos = u.mvp * float4(vtx[b], vtx[b + 1], vtx[b + 2], 1.0);
        o.uv = float2(vtx[b + 6], vtx[b + 7]);
        return o;
    }

    vertex ShadowVOut sv_skin(uint vid [[vertex_id]],
                              const device float* vtx [[buffer(0)]],
                              constant MeshU& u [[buffer(1)]],
                              const device float4x4* bones [[buffer(2)]]) {
        uint b = vid * 16;
        float3 localPos = float3(vtx[b], vtx[b + 1], vtx[b + 2]);
        uint4 idx = uint4(uint(vtx[b + 8] + 0.5), uint(vtx[b + 9] + 0.5),
                          uint(vtx[b + 10] + 0.5), uint(vtx[b + 11] + 0.5));
        float4 weights = float4(vtx[b + 12], vtx[b + 13], vtx[b + 14], vtx[b + 15]);
        float weightSum = weights.x + weights.y + weights.z + weights.w;
        float3 skinnedPos = localPos;
        if (weightSum > 0.0) {
            weights /= weightSum;
            skinnedPos = (weights.x * (bones[idx.x] * float4(localPos, 1.0))
                        + weights.y * (bones[idx.y] * float4(localPos, 1.0))
                        + weights.z * (bones[idx.z] * float4(localPos, 1.0))
                        + weights.w * (bones[idx.w] * float4(localPos, 1.0))).xyz;
        }
        ShadowVOut o;
        o.pos = u.mvp * float4(skinnedPos, 1.0);
        o.uv = float2(vtx[b + 6], vtx[b + 7]);
        return o;
    }

    fragment void sf_cutout(ShadowVOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            constant MeshU& u [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        float alpha = tex.sample(s, in.uv).a * u.tint.a;
        if (alpha < u.material.z) discard_fragment();
    }

    inline float finiteLightFalloff(float distance, float radius, float exponent) {
        if (radius <= 0.0) return 0.0;
        float falloff = clamp(1.0 - distance / radius, 0.0, 1.0);
        constexpr float epsilon = 6.103515625e-5;
        // Native GLSL lane: radius 경계에서 exponent=0이어도 hard zero.
        return falloff >= epsilon ? pow(falloff + epsilon, exponent) : 0.0;
    }

    inline float Distribution_GGX(float3 N, float3 H, float roughness) {
        float r2 = roughness * roughness;
        float r4 = r2 * r2;
        float NH = max(dot(N, H), 0.0);
        float rawDenominator = NH * NH * (r4 - 1.0) + 1.0;
        // [safety deviation] Native의 roughness=0,NH=1 0/0만 방지. 상단은 무클램프.
        float denominator = max(rawDenominator, 1e-4);
        return r4 / (3.14159265359 * denominator * denominator);
    }

    inline float Schlick_GGX(float ND, float roughness) {
        float base = roughness + 1.0;
        float k = base * base / 8.0;
        return ND / (ND * (1.0 - k) + k);
    }

    inline float GeometrySmith(float3 N, float3 V, float3 L, float roughness) {
        return Schlick_GGX(max(dot(N, V), 0.001), roughness)
             * Schlick_GGX(max(dot(N, L), 0.001), roughness);
    }

    inline float3 FresnelSchlick(float cosTheta, float3 F0) {
        return F0 + (1.0 - F0) * pow(max(1.0 - cosTheta, 0.001), 5.0);
    }

    inline float3 pointPBR(float3 worldPos, float3 N, float3 V, float3 albedo,
                           float roughness, float metallic, float3 specularTint,
                           constant LightU& light) {
        float3 delta = light.positionExponent.xyz - worldPos;
        float distance = length(delta);
        if (distance < 1e-5 || light.colorRadius.w <= 0.0) return float3(0.0);
        float3 L = delta / distance;
        float NL = max(dot(N, L), 0.0);
        if (NL <= 0.0) return float3(0.0);
        float3 H = normalizedOr(V + L, N);
        float D = Distribution_GGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        float3 F0 = mix(float3(0.04), albedo, metallic);
        float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);
        float3 diffuseWeight = (1.0 - metallic) * (1.0 - F);
        float denominator = max(4.0 * max(dot(N, V), 0.0) * NL, 0.001);
        float3 specular = D * G * F / denominator;
        float attenuation = finiteLightFalloff(distance, light.colorRadius.w,
                                               light.positionExponent.w);
        float3 radiance = light.colorRadius.xyz * attenuation;
        return (diffuseWeight * albedo / 3.14159265359 + specular * specularTint)
             * radiance * NL;
    }

    inline int pointShadowFace(float3 delta) {
        float3 absolute = abs(delta);
        if (absolute.x >= absolute.y && absolute.x >= absolute.z) return delta.x >= 0.0 ? 0 : 1;
        if (absolute.y >= absolute.x && absolute.y >= absolute.z) return delta.y >= 0.0 ? 2 : 3;
        return delta.z >= 0.0 ? 4 : 5;
    }

    inline float2 pointShadowCell(int face) {
        if (face == 0) return float2(0.0, 0.0);
        if (face == 1) return float2(1.0, 0.0);
        if (face == 2) return float2(0.0, 1.0);
        if (face == 3) return float2(1.0, 1.0);
        if (face == 4) return float2(0.0, 2.0);
        return float2(1.0, 2.0);
    }

    inline float pointShadowVisibility(float3 worldPos,
                                       constant LightU& light,
                                       constant FrameU& frame,
                                       constant float4x4* shadowVP,
                                       depth2d_array<float> shadowAtlas) {
        if (light.shadow.x < 0.0 || frame.meta.y <= 0.0 || frame.meta.z <= 0.0) return 1.0;
        int face = pointShadowFace(worldPos - light.positionExponent.xyz);
        int matrixIndex = int(light.shadow.y + 0.5) + face;
        float4 projected = shadowVP[matrixIndex] * float4(worldPos, 1.0);
        if (projected.w <= 0.0) return 1.0;
        float3 ndc = projected.xyz / projected.w;
        if (ndc.z < 0.0 || ndc.z > 1.0) return 1.0;

        // Native point cube: +X,-X,+Y,-Y,+Z,-Z in a 2×3 atlas.
        float2 cell = pointShadowCell(face);
        float2 localUV = ndc.xy * float2(0.49, -0.49) + 0.5;
        float2 atlasScale = float2(0.5, 0.3333333333);
        float2 uv = (cell + localUV) * atlasScale;
        float2 texel = frame.meta.yz;
        float2 cellMin = cell * atlasScale + texel * 0.5;
        float2 cellMax = (cell + 1.0) * atlasScale - texel * 0.5;
        float referenceDepth = ndc.z - frame.meta.w;
        uint slice = uint(light.shadow.x + 0.5);
        constexpr sampler compareSampler(coord::normalized, filter::nearest,
                                         address::clamp_to_edge, compare_func::less_equal);
        float2 roundOffset = texel * 0.81616;
        float2 axialOffset = texel * 1.02323;
        float visibility = 0.0;
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv - roundOffset, cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(0.0, -axialOffset.y), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(roundOffset.x, -roundOffset.y), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(-axialOffset.x, 0.0), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv, cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(axialOffset.x, 0.0), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(-roundOffset.x, roundOffset.y), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(0.0, axialOffset.y), cellMin, cellMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + roundOffset, cellMin, cellMax), slice, referenceDepth);
        return visibility / 9.0;
    }

    fragment float4 mf_main(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            depth2d_array<float> shadowAtlas [[texture(1)]],
                            constant MeshU& u [[buffer(1)]],
                            constant FrameU& frame [[buffer(2)]],
                            constant LightU* lights [[buffer(3)]],
                            constant float4x4* shadowVP [[buffer(4)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();
        float mode = u.material.w;
        if (mode < 0.5) return float4(sampled.rgb * sampled.a, sampled.a);

        float3 albedo = sampled.rgb;
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        float3 V = normalizedOr(frame.cameraEye.xyz - in.worldPos, float3(0.0, 0.0, 1.0));
        float3 direct = float3(0.0);
        int count = clamp(int(frame.meta.x + 0.5), 0, 4);
        for (int i = 0; i < count; ++i) {
            float visibility = pointShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
            direct += visibility * pointPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                           u.specularTint.xyz, lights[i]);
        }
        float3 ambientColor = frame.ambient.xyz;
        if (mode < 1.5) {
            float hemisphere = clamp(dot(N, float3(0.0, 1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
            ambientColor = mix(frame.skylight.xyz, frame.ambient.xyz, hemisphere);
        }
        float3 lit = ambientColor * albedo + direct;
        return float4(lit * sampled.a, sampled.a);
    }
    """
}
