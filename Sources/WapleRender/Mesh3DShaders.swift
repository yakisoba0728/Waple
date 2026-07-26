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
        float4 rim;            // x=g_RimAmount, y=g_RimExponent, z=RIMLIGHTING on/off, w=SHADINGGRADIENT on/off
    };
    struct FrameU {
        float4 cameraEye;
        float4 ambient;
        float4 skylight;
        float4 meta;          // x=light count; shadow fields are introduced by P4
        // F662: scene fog(common_fog.h 대응) — color.w=활성 플래그, params=(start, end-start, startDensity, Δdensity).
        float4 fogDistanceColor;
        float4 fogDistanceParams;
        float4 fogHeightColor;
        float4 fogHeightParams;
    };
    struct LightU {
        float4 positionExponent;
        float4 colorRadius;
        float4 shadow;        // x=slice, y=vp start, z=kind(0=point,1=directional,2=spot), w=spot inner cos
        float4 axis;          // xyz=forward(+Z blue축, 광자 진행 방향), w=spot outer cos
        float4 cascades;      // F780: directional CSM far 경계 xyz, w=캐스케이드 수(3=CSM, 0=단일 오소)
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

    // Cook–Torrance BRDF × NL (source-confirmed generic4 코어). radiance 는 호출부가 곱한다.
    // NL<=0 이면 최종 *NL 로 0(포인트 조기반환과 수치 동일). point/directional/spot 공유.
    // F274(RIMLIGHTING/SHADINGGRADIENT — common_pbr.h:53-75 1:1 이식): rim=(g_RimAmount,g_RimExponent,
    // RIMLIGHTING on/off,SHADINGGRADIENT on/off). lightColorRaw 는 감쇠 적용 "전" 광원색(WE 의
    // step(0.01, lightColor.x+y+z) 게이트와 동일 — 감쇠된 radiance 가 아니라 광원 자체의 세기를 본다).
    inline float3 pbrDirect(float3 N, float3 V, float3 L, float3 albedo,
                            float roughness, float metallic, float3 specularTint,
                            float3 lightColorRaw, float4 rim,
                            texture2d<float> gradientTex, sampler gradientSampler) {
        float dNL = dot(N, L);
        float3 H = normalizedOr(V + L, N);
        float D = Distribution_GGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        float3 F0 = mix(float3(0.04), albedo, metallic);
        float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

        // SHADINGGRADIENT: half-Lambert 리맵(dNL*0.5+0.5)을 g_Texture4 툰 램프에서 룩업. 고정 자산
        // gradient_toon_smooth 는 항상 r8 포맷(F274 실측)이라 WE 의 TEX4FORMAT R8/RG88 분기(.rrr)와
        // 동치인 .r 스칼라를 채택 — 우리 NL 은 애초에 스칼라 구조(WE 의 vec3 NL 분기는 미포팅).
        float NL;
        if (rim.w > 0.5) {
            float halfLambert = max(dNL * 0.5 + 0.5, 0.0);
            NL = gradientTex.sample(gradientSampler, float2(halfLambert, 0.0)).r;
        } else {
            NL = max(dNL, 0.0);
        }
        // RIMLIGHTING: 그레이징 뷰 앵글(1-NV)^exponent × amount × NL × (광원 비활성 게이트) 를 NL 에
        // max 로 얹고, metallic 을 그만큼 깎아 림 부분을 diffuse 처럼 밝힌다(WE: metallic -= saturate(rimTerm),
        // 상한 클램프 없음 — F0/Fresnel 은 원래 metallic 으로 이미 계산됐으므로 무관).
        float adjustedMetallic = metallic;
        if (rim.z > 0.5) {
            float NV = max(dot(N, V), 0.0);
            float rimTerm = pow(1.0 - NV, rim.y) * rim.x * NL
                           * step(0.01, lightColorRaw.x + lightColorRaw.y + lightColorRaw.z);
            NL = max(NL, rimTerm);
            adjustedMetallic -= saturate(rimTerm);
        }

        float3 diffuseWeight = (1.0 - adjustedMetallic) * (1.0 - F);
        float denominator = max(4.0 * max(dot(N, V), 0.0) * NL, 0.001);
        float3 specular = D * G * F / denominator;
        return (diffuseWeight * albedo / 3.14159265359 + specular * specularTint) * NL;
    }

    inline float3 pointPBR(float3 worldPos, float3 N, float3 V, float3 albedo,
                           float roughness, float metallic, float3 specularTint,
                           constant LightU& light, float4 rim,
                           texture2d<float> gradientTex, sampler gradientSampler) {
        float3 delta = light.positionExponent.xyz - worldPos;
        float distance = length(delta);
        if (distance < 1e-5 || light.colorRadius.w <= 0.0) return float3(0.0);
        float3 L = delta / distance;
        if (dot(N, L) <= 0.0) return float3(0.0);
        float attenuation = finiteLightFalloff(distance, light.colorRadius.w,
                                               light.positionExponent.w);
        float3 radiance = light.colorRadius.xyz * attenuation;
        return pbrDirect(N, V, L, albedo, roughness, metallic, specularTint,
                         light.colorRadius.xyz, rim, gradientTex, gradientSampler) * radiance;
    }

    // 무한거리(directional): 무감쇠 radiance = lightColor. L = -forward(surface→light).
    // WE common_pbr_2.h::ComputePBRLightShadowInfinite (shadowFactor=1: directional 섀도우 스코프 밖).
    inline float3 directionalPBR(float3 N, float3 V, float3 albedo,
                                 float roughness, float metallic, float3 specularTint,
                                 constant LightU& light, float4 rim,
                                 texture2d<float> gradientTex, sampler gradientSampler) {
        float3 L = normalizedOr(-light.axis.xyz, float3(0.0, 1.0, 0.0));
        if (dot(N, L) <= 0.0) return float3(0.0);
        return pbrDirect(N, V, L, albedo, roughness, metallic, specularTint,
                         light.colorRadius.xyz, rim, gradientTex, gradientSampler) * light.colorRadius.xyz;
    }

    // spot: point 감쇠 × 콘 스무드스텝(축 forward 기준). 콘 밖은 0.
    inline float3 spotPBR(float3 worldPos, float3 N, float3 V, float3 albedo,
                          float roughness, float metallic, float3 specularTint,
                          constant LightU& light, float4 rim,
                          texture2d<float> gradientTex, sampler gradientSampler) {
        float3 delta = light.positionExponent.xyz - worldPos;
        float distance = length(delta);
        if (distance < 1e-5 || light.colorRadius.w <= 0.0) return float3(0.0);
        float3 L = delta / distance;                 // surface→light
        if (dot(N, L) <= 0.0) return float3(0.0);
        // 광자 진행 방향 forward vs light→surface(-L) 의 코사인.
        float cosAngle = dot(normalizedOr(light.axis.xyz, float3(0.0, 0.0, 1.0)), -L);
        float cosInner = light.shadow.w;
        float cosOuter = light.axis.w;
        float cone = clamp((cosAngle - cosOuter) / max(cosInner - cosOuter, 1e-4), 0.0, 1.0);
        cone = cone * cone * (3.0 - 2.0 * cone);     // smoothstep
        if (cone <= 0.0) return float3(0.0);
        float attenuation = finiteLightFalloff(distance, light.colorRadius.w,
                                               light.positionExponent.w);
        float3 radiance = light.colorRadius.xyz * attenuation * cone;
        return pbrDirect(N, V, L, albedo, roughness, metallic, specularTint,
                         light.colorRadius.xyz, rim, gradientTex, gradientSampler) * radiance;
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

    // F661(S-47): directional 섀도우 — F780 이후 2단계. cascades.w==3 이면 CSM 3-스플릿: 카메라 거리로
    // 캐스케이드를 골라 point 와 같은 2×3 셀 배치의 셀(0..2)을 샘플(VP 슬롯 shadow.y+cascade). 아니면
    // 종전 단일 오소(아틀라스 슬라이스 전체, VP shadow.y 하나). PCF 는 point 경로와 동일 9탭 공유.
    inline float directionalShadowVisibility(float3 worldPos,
                                             constant LightU& light,
                                             constant FrameU& frame,
                                             constant float4x4* shadowVP,
                                             depth2d_array<float> shadowAtlas) {
        if (light.shadow.x < 0.0 || frame.meta.y <= 0.0 || frame.meta.z <= 0.0) return 1.0;
        float2 texel = frame.meta.yz;
        float2 uv, uvMin, uvMax;
        float referenceDepth;
        if (light.cascades.w > 2.5) {
            // F780: CSM — 카메라-표면 거리로 슬라이스 선택. 마지막 경계 밖은 맵 없음(lit 폴터).
            float viewDist = distance(frame.cameraEye.xyz, worldPos);
            if (viewDist >= light.cascades.z) return 1.0;
            int cascade = viewDist < light.cascades.x ? 0 : (viewDist < light.cascades.y ? 1 : 2);
            float4 projected = shadowVP[int(light.shadow.y + 0.5) + cascade] * float4(worldPos, 1.0);
            if (projected.w <= 0.0) return 1.0;
            float3 ndc = projected.xyz / projected.w;
            if (ndc.z < 0.0 || ndc.z > 1.0) return 1.0;
            // 셀 낭비 없이 point 경로와 동일 규약(0.49 보정, y 플립, 2×3 배치)으로 셀 i 에 매핑.
            float2 cell = pointShadowCell(cascade);
            float2 localUV = ndc.xy * float2(0.49, -0.49) + 0.5;
            float2 atlasScale = float2(0.5, 0.3333333333);
            uv = (cell + localUV) * atlasScale;
            uvMin = cell * atlasScale + texel * 0.5;
            uvMax = (cell + 1.0) * atlasScale - texel * 0.5;
            referenceDepth = ndc.z - frame.meta.w;
        } else {
            int matrixIndex = int(light.shadow.y + 0.5);
            float4 projected = shadowVP[matrixIndex] * float4(worldPos, 1.0);
            if (projected.w <= 0.0) return 1.0;
            float3 ndc = projected.xyz / projected.w;
            if (ndc.z < 0.0 || ndc.z > 1.0) return 1.0;
            // Metal NDC y-up → 텍스처 v-down 풀슬라이스 매핑(point 경로의 y 플립과 동일 규약).
            uv = ndc.xy * float2(0.5, -0.5) + 0.5;
            // 오소 상자 밖은 깊이 정보 없음 — 그림자 판정 불가라 lit 폴터(clamp_to_edge 스미어 방지).
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
            uvMin = texel * 0.5;
            uvMax = 1.0 - texel * 0.5;
            referenceDepth = ndc.z - frame.meta.w;
        }
        uint slice = uint(light.shadow.x + 0.5);
        constexpr sampler compareSampler(coord::normalized, filter::nearest,
                                         address::clamp_to_edge, compare_func::less_equal);
        float2 roundOffset = texel * 0.81616;
        float2 axialOffset = texel * 1.02323;
        float visibility = 0.0;
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv - roundOffset, uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(0.0, -axialOffset.y), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(roundOffset.x, -roundOffset.y), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(-axialOffset.x, 0.0), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv, uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(axialOffset.x, 0.0), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(-roundOffset.x, roundOffset.y), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + float2(0.0, axialOffset.y), uvMin, uvMax), slice, referenceDepth);
        visibility += shadowAtlas.sample_compare(compareSampler, clamp(uv + roundOffset, uvMin, uvMax), slice, referenceDepth);
        return visibility / 9.0;
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

    // F662(S-45): common_fog.h ApplyFog 1:1 — HEIGHT 먼저, DIST 순. factor = z + w·saturate(t)²,
    // mix 계수 미적용 클램프(WE 와 동일 — saturate 는 t 에만). fogMode: 0=비적용, 1=rgb 만, 2=rgb+alpha(ADDITIVE — ApplyFogAlpha).
    inline void applySceneFog(thread float3& color, thread float& alpha, float fogMode,
                              float3 worldPos, float3 eye, constant FrameU& frame) {
        if (fogMode < 0.5) return;
        float viewDist = distance(eye, worldPos);
        float heightFactor = 0.0;
        float distFactor = 0.0;
        if (frame.fogHeightColor.w > 0.5) {
            float t = saturate((worldPos.y - frame.fogHeightParams.x) / frame.fogHeightParams.y);
            heightFactor = frame.fogHeightParams.z + frame.fogHeightParams.w * t * t;
            color = mix(color, frame.fogHeightColor.xyz, heightFactor);
        }
        if (frame.fogDistanceColor.w > 0.5) {
            float t = saturate((viewDist - frame.fogDistanceParams.x) / frame.fogDistanceParams.y);
            distFactor = frame.fogDistanceParams.z + frame.fogDistanceParams.w * t * t;
            color = mix(color, frame.fogDistanceColor.xyz, distFactor);
        }
        if (fogMode > 1.5) {
            // ApplyFogAlpha: fogFactor = saturate(max(distFactor, heightFactor)); alpha *= 1 - factor².
            float fogFactor = saturate(max(distFactor, heightFactor));
            alpha *= 1.0 - fogFactor * fogFactor;
        }
    }

    fragment float4 mf_main(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            depth2d_array<float> shadowAtlas [[texture(1)]],
                            texture2d<float> gradientTex [[texture(2)]],
                            constant MeshU& u [[buffer(1)]],
                            constant FrameU& frame [[buffer(2)]],
                            constant LightU* lights [[buffer(3)]],
                            constant float4x4* shadowVP [[buffer(4)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        // gradient_toon_smooth 는 clampuvs 자산(F274 실측) — 램프 끝(NL≈0/1)에서 wrap 대신 edge 고정.
        constexpr sampler gradientSampler(filter::linear, address::clamp_to_edge);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();
        float mode = u.material.w;
        // F662: specularTint.w(미사용 채널 재활용) = fog 모드(0 비적용/1 rgb/2 rgb+alpha additive).
        float fogMode = u.specularTint.w;
        if (mode < 0.5) {
            // unlit 도 WE(generic4 CombineLighting 이후 ApplyFog)와 같이 fog 대상.
            float3 rgb = sampled.rgb;
            float alpha = sampled.a;
            applySceneFog(rgb, alpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
            return float4(rgb * alpha, alpha);
        }

        float3 albedo = sampled.rgb;
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        float3 V = normalizedOr(frame.cameraEye.xyz - in.worldPos, float3(0.0, 0.0, 1.0));
        float3 direct = float3(0.0);
        int count = clamp(int(frame.meta.x + 0.5), 0, 8);   // F660: 라이트 캡 4 → 8(젤다 6슬롯)
        for (int i = 0; i < count; ++i) {
            float kind = lights[i].shadow.z;
            if (kind < 0.5) {          // point: 감쇠 + 6면 큐브 섀도우
                float visibility = pointShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * pointPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                                u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else if (kind < 1.5) {   // directional: 무감쇠 + CSM/단일 오소 섀도우(F661/F780)
                float visibility = directionalShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * directionalPBR(N, V, albedo, u.material.x, u.material.y,
                                                      u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {                   // spot: 감쇠 + 콘(섀도우 스코프 밖)
                direct += spotPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            }
        }
        float3 ambientColor = frame.ambient.xyz;
        if (mode < 1.5) {
            float hemisphere = clamp(dot(N, float3(0.0, 1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
            ambientColor = mix(frame.skylight.xyz, frame.ambient.xyz, hemisphere);
        }
        float3 lit = ambientColor * albedo + direct;
        float outAlpha = sampled.a;
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }

    // M3: PBR 노멀맵/마스크 지원 — 스크린공간 미분으로 TBN 근사, 노멀맵 샘플로 법선 보정,
    // 마스크 텍스처로 per-pixel roughness/metallic 오버라이드.
    // 노멀맵: texture(3), 마스크: texture(4).
    fragment float4 mf_normal(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              depth2d_array<float> shadowAtlas [[texture(1)]],
                              texture2d<float> gradientTex [[texture(2)]],
                              texture2d<float> normalTex [[texture(3)]],
                              texture2d<float> maskTex [[texture(4)]],
                              constant MeshU& u [[buffer(1)]],
                              constant FrameU& frame [[buffer(2)]],
                              constant LightU* lights [[buffer(3)]],
                              constant float4x4* shadowVP [[buffer(4)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        constexpr sampler gradientSampler(filter::linear, address::clamp_to_edge);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();
        float mode = u.material.w;
        float fogMode = u.specularTint.w;
        if (mode < 0.5) {
            float3 rgb = sampled.rgb;
            float alpha = sampled.a;
            applySceneFog(rgb, alpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
            return float4(rgb * alpha, alpha);
        }

        float3 albedo = sampled.rgb;
        // M3: TBN 근사(스크린공간 미분). 정점 탄젠트 부재 시 ddx/ddy 로부터 탄젠트/비탄젠트 계산.
        float3 dpx = dfdx(in.worldPos);
        float3 dpy = dfdy(in.worldPos);
        float2 duvx = dfdx(in.uv);
        float2 duvy = dfdy(in.uv);
        float3 T = normalizedOr(dpx * duvy.y - dpy * duvx.y, float3(1.0, 0.0, 0.0));
        float3 B = normalizedOr(dpy * duvx.x - dpx * duvy.x, float3(0.0, 1.0, 0.0));
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        float3x3 TBN = float3x3(T, B, N);
        float3 normalMap = normalTex.sample(s, in.uv).xyz * 2.0 - 1.0;
        N = normalizedOr(TBN * normalMap, N);

        // M3: 마스크 텍스처로 per-pixel roughness/metallic 오버라이드(없으면 머티리얼 상수).
        float4 mask = maskTex.sample(s, in.uv);
        float roughness = mask.r > 0.0 ? mask.r : u.material.x;
        float metallic = mask.g > 0.0 ? mask.g : u.material.y;

        float3 V = normalizedOr(frame.cameraEye.xyz - in.worldPos, float3(0.0, 0.0, 1.0));
        float3 direct = float3(0.0);
        int count = clamp(int(frame.meta.x + 0.5), 0, 8);
        for (int i = 0; i < count; ++i) {
            float kind = lights[i].shadow.z;
            if (kind < 0.5) {
                float visibility = pointShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * pointPBR(in.worldPos, N, V, albedo, roughness, metallic,
                                                u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else if (kind < 1.5) {
                float visibility = directionalShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * directionalPBR(N, V, albedo, roughness, metallic,
                                                      u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {
                direct += spotPBR(in.worldPos, N, V, albedo, roughness, metallic,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            }
        }
        float3 ambientColor = frame.ambient.xyz;
        if (mode < 1.5) {
            float hemisphere = clamp(dot(N, float3(0.0, 1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
            ambientColor = mix(frame.skylight.xyz, frame.ambient.xyz, hemisphere);
        }
        float3 lit = ambientColor * albedo + direct;
        float outAlpha = sampled.a;
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }

    // H4: REFRACT(스크린 굴절) 메시 — mf_main 과 동형이나 알베도 샘플 직후 씬 컬러 스냅샷(fbTex=그리기
    // 시점까지의 acc 누적)을 노멀맵 오프셋으로 재샘플해 **곱한다**(유리/물/열왜곡). 2D f_refract /
    // pf_refract 와 동일 규약: 화면 UV 는 in.pos(프래그먼트 픽셀, y-down — 무플립), 노멀 언팩은
    // common_fragment.h DecompressNormalWithMask 포트(DXT5nm vs RG88 분기), 곱 위치는 라이팅 전
    // 알베도(2D 경로의 color=albedo*tint*bg 와 unlit 에서 동치).
    // 편차: WE generic4 는 v_ScreenTangents 로 탄젠트공간 노멀을 스크린공간으로 변환하지만, 여기선
    // 2D/스프라이트 경로와 같은 최소 근사(노멀맵 xy 를 스크린 오프셋으로 직용 — 스키닝/탄젠트 부재).
    // 노멀맵 texture(3), 씬 스냅샷 texture(4), refractParams=(g_RefractAmount, rg88Flag, 0, 0) buffer(5).
    fragment float4 mf_refract(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               depth2d_array<float> shadowAtlas [[texture(1)]],
                               texture2d<float> gradientTex [[texture(2)]],
                               texture2d<float> normalTex [[texture(3)]],
                               texture2d<float> fbTex [[texture(4)]],
                               constant MeshU& u [[buffer(1)]],
                               constant FrameU& frame [[buffer(2)]],
                               constant LightU* lights [[buffer(3)]],
                               constant float4x4* shadowVP [[buffer(4)]],
                               constant float4& refractParams [[buffer(5)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        constexpr sampler gradientSampler(filter::linear, address::clamp_to_edge);
        // 씬 스냅샷은 화면 경계 클램프(2D f_refract 와 동일 — repeat 면 오프셋이 가장자리에서 반대편을 샘플).
        constexpr sampler fbSampler(filter::linear, address::clamp_to_edge);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();
        // REFRACT: 노멀맵 오프셋으로 씬 스냅샷 재샘플 → 알베도에 곱(QuadShaders.f_refract 주석 참조).
        float4 nraw = normalTex.sample(s, in.uv);
        bool rg88 = refractParams.y > 0.5;
        float nx = nraw.a * 2.0 - (rg88 ? 1.0 : 0.965);
        float ny = nraw.g * 2.0 - 1.0;
        float mask = rg88 ? 1.0 : nraw.r;
        float2 off = refractParams.x * float2(nx, ny) * (mask * u.tint.a);
        float2 ruv = in.pos.xy / float2(fbTex.get_width(), fbTex.get_height()) + off;
        sampled.rgb *= fbTex.sample(fbSampler, ruv).rgb;
        float mode = u.material.w;
        float fogMode = u.specularTint.w;
        if (mode < 0.5) {
            float3 rgb = sampled.rgb;
            float alpha = sampled.a;
            applySceneFog(rgb, alpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
            return float4(rgb * alpha, alpha);
        }

        float3 albedo = sampled.rgb;
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        float3 V = normalizedOr(frame.cameraEye.xyz - in.worldPos, float3(0.0, 0.0, 1.0));
        float3 direct = float3(0.0);
        int count = clamp(int(frame.meta.x + 0.5), 0, 8);
        for (int i = 0; i < count; ++i) {
            float kind = lights[i].shadow.z;
            if (kind < 0.5) {
                float visibility = pointShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * pointPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                                u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else if (kind < 1.5) {
                float visibility = directionalShadowVisibility(in.worldPos, lights[i], frame, shadowVP, shadowAtlas);
                direct += visibility * directionalPBR(N, V, albedo, u.material.x, u.material.y,
                                                      u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {
                direct += spotPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            }
        }
        float3 ambientColor = frame.ambient.xyz;
        if (mode < 1.5) {
            float hemisphere = clamp(dot(N, float3(0.0, 1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
            ambientColor = mix(frame.skylight.xyz, frame.ambient.xyz, hemisphere);
        }
        float3 lit = ambientColor * albedo + direct;
        float outAlpha = sampled.a;
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }
    """
}
