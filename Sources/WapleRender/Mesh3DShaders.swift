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
        float4 extra;          // x=g_Brightness(HDR 최종 곱 — 비HDR 씬은 CPU 가 1 로 중화). y/z/w 예약
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
        float4 shadow;        // x=slice, y=vp start, z=kind(0=point,1=directional,2=spot,4=tube), w=spot inner cos
        float4 axis;          // xyz=forward(+Z blue축, 광자 진행 방향), w=spot outer cos | tube: xyz=단점B(g_LTube_OriginB)
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
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        float alpha = tex.sample(s, in.uv).a * u.tint.a;
        if (alpha < u.material.z) discard_fragment();
    }

    inline float finiteLightFalloff(float distance, float radius, float exponent) {
        if (radius <= 0.0) return 0.0;
        float falloff = clamp(1.0 - distance / radius, 0.0, 1.0);
        // WE 2.8.42 HLSL lane(#define HLSL 1 크로스컴파일 — wallpaper64.exe 스트링 @0x486898):
        // pow(falloff + 1.17549435e-38, exponent), 반경 컷오프 없음. exponent=0 이면 pow(x,0)=1
        // 이라 반경 무관 전역 무감쇠가 엔진 동작(구 GLSL lane 의 hard zero 는 오이식).
        return pow(falloff + 1.17549435e-38, exponent);
    }

    // WE common_pbr.h:9-16 PointSegmentDelta 1:1 — 표면에서 세그먼트(tube 광축) 최근접점까지의 델타.
    // A==B 퇴화(v==0)는 A-pos 반환이라 point 라이트와 수치 동치. saturate = clamp(x,0,1).
    inline float3 pointSegmentDelta(float3 pos, float3 segmentA, float3 segmentB) {
        float3 delta = segmentB - segmentA;
        float v = dot(delta, delta);
        if (v == 0.0) return segmentA - pos;
        return segmentA + clamp(dot(pos - segmentA, delta) / v, 0.0, 1.0) * delta - pos;
    }

    inline float Distribution_GGX(float3 N, float3 H, float roughness) {
        float r2 = roughness * roughness;
        float r4 = r2 * r2;
        float NH = max(dot(N, H), 0.0);
        float rawDenominator = NH * NH * (r4 - 1.0) + 1.0;
        // [의도적 이탈 — 유지 확정 2026-08-01] WE common_pbr.h:23 에는 바닥값이 없다.
        // 갈리는 지점은 roughness=0 · N·H=1 하나뿐이고 거기서 WE 는 0/0 = NaN, 여기는 0 이다.
        // NaN 이 픽셀을 오염시키므로 이쪽이 엄밀히 낫다. HDR 씬 A/B(release) 화면 영향 0 실측.
        // 근거·A/B 결과·재검토 조건: spec/engine/deviations.json (deviation.D1, deviation.decision)
        // 이건 조사 완료 항목이다 — "안전장치처럼 보이는 이탈" 로 다시 적출하지 마라.
        float denominator = max(rawDenominator, 1e-4);
        return r4 / (3.14159265359 * denominator * denominator);
    }

    inline float Schlick_GGX(float ND, float roughness) {
        float base = roughness + 1.0;
        float k = base * base / 8.0;
        return ND / (ND * (1.0 - k) + k);
    }

    // 아래 0.001 하한은 **이탈이 아니다** — WE common_pbr.h:36 GeoSmith 원문과 같은 값이다.
    // (FresnelSchlick 의 max(1.0-cosTheta, 0.001) 도 WE common_pbr.h:6 과 동일.)
    // 한 번 "Waple 이 넣은 안전장치" 로 오분류된 적이 있다 — spec/engine/deviations.json (deviation.D2).
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
    // RIMLIGHTING on/off,SHADINGGRADIENT on/off). lightColorRaw 는 감쇠 적용 "전" 광원색(WE V1 lane 의
    // step(0.001, lightColor.x+y+z) 게이트와 동일 — 감쇠된 radiance 가 아니라 광원 자체의 세기를 본다).
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
                           * step(0.001, lightColorRaw.x + lightColorRaw.y + lightColorRaw.z);
                           // ^ WE 2.8.42 V1 lane: common_pbr_2.h:294/305/342/353 (0.01 은 구경로 common_pbr.h 값).
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

    // tube: 세그먼트 최근접점을 광원점으로 하는 유한광 — WE PerformLighting_V1 tube 분기
    // (A2-pbr-lighting.md §4.4: lightDelta=PointSegmentDelta(worldPos, OriginA, OriginB),
    //  ComputePBRLightShadow(..., Color.w=radius, OriginA.w=exponent, shadowFactor=1.0 — tube 무섀도우).
    // pointPBR 과의 유일한 차이는 델타 산출(세그먼트 최근접점)뿐 — 패킹 규약(OriginA.w=exponent,
    // Color.w=radius)은 point 와 동형(A2 §4.5 표).
    inline float3 tubePBR(float3 worldPos, float3 N, float3 V, float3 albedo,
                          float roughness, float metallic, float3 specularTint,
                          constant LightU& light, float4 rim,
                          texture2d<float> gradientTex, sampler gradientSampler) {
        float3 delta = pointSegmentDelta(worldPos, light.positionExponent.xyz, light.axis.xyz);
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

    // F661(S-47): directional 섀도우 — F780 이후 2단계. cascades.w==3 이면 CSM 3-스플릿: WE mix 체인
    // (캐스케이드별 투영 박스 포함 검사, 아래 주석)으로 골라 point 와 같은 2×3 셀 배치의 셀(0..2)을 샘플(VP 슬롯 shadow.y+cascade). 아니면
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
            // CSM 선택 — WE 정본(common_pbr_2.h:131-147 CalculateProjectedCoordsCascades +
            // A2-pbr-lighting.md §4.4 directional mix 체인): 각 캐스케이드 VP 로 투영해 NDC 박스
            // (|xy|<0.99, z 가장자리 이내) 포함 여부로 mix — 종전 radial distance(eye, worldPos)
            // 비교(F780 근사)를 대체한다. 캐스케이드 xy 피팅이 카메라 프러스텀 슬라이스([near,d0]/
            // [d0,d1]/[d1,d2])라 박스 선택은 사실상 뷰 z(far 평면) 기준이며 측면 범위 검사도 겸한다.
            // (cameraForward 유니폼 신설 없이 기존 shadowVP 만으로 결정되므로 dot(worldPos-eye, fwd)
            //  근사보다 엔진 수식 그대로인 이 형태를 택했다.)
            int vpBase = int(light.shadow.y + 0.5);
            float4 p0 = shadowVP[vpBase + 0] * float4(worldPos, 1.0);
            float4 p1 = shadowVP[vpBase + 1] * float4(worldPos, 1.0);
            float4 p2 = shadowVP[vpBase + 2] * float4(worldPos, 1.0);
            if (p0.w <= 0.0 || p1.w <= 0.0 || p2.w <= 0.0) return 1.0;
            float3 ndc0 = p0.xyz / p0.w;
            float3 ndc1 = p1.xyz / p1.w;
            float3 ndc2 = p2.xyz / p2.w;
            // WE: step(1.0, dot(CAST3(1.0), step(0.99, abs(proj.xyz)))) — 비-REVERSEDEPTH lane.
            // Metal NDC z(0..1)는 WE GLSL z(-1..1)와 달리 ±1 로 재중심해 같은 0.99 임계를 쓴다.
            float out0 = step(0.99, max(abs(ndc0.x), max(abs(ndc0.y), abs(ndc0.z * 2.0 - 1.0))));
            float out1 = step(0.99, max(abs(ndc1.x), max(abs(ndc1.y), abs(ndc1.z * 2.0 - 1.0))));
            float out2 = step(0.99, max(abs(ndc2.x), max(abs(ndc2.y), abs(ndc2.z * 2.0 - 1.0))));
            // mix 체인(A2 §4.4): mix(mix(pc0,pc1,w0),pc2,w1) — 인덱스도 같은 체인(uvTransforms 대응).
            // 전 캐스케이드 밖(out2=1)은 WE 의 max(pc3.w, shadow)=1 과 동치라 lit 폴터.
            if (out2 > 0.5) return 1.0;
            int cascade = int(mix(mix(0.0, 1.0, out0), 2.0, out1) + 0.5);
            float3 ndc = mix(mix(ndc0, ndc1, out0), ndc2, out1);
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
        // G-E1-3: 비교 샘플러는 **LINEAR** 여야 한다(= 하드웨어 PCF). WE 샘플러 캐시가 만들 수 있는
        // 유일한 비교 필터값은 `0x95 = D3D11_FILTER_COMPARISON_MIN_MAG_MIP_LINEAR` 다
        // (원본 0x140099b67 `mov ecx, 0x95`; Filter 슬롯에 쓰는 명령이 0x140099b05 앞의 한 곳뿐이고
        // ecx 경로가 셋뿐이라 배타적으로 확정). 9탭 오프셋(0.81616/1.02323)은 이미 WE 와 같지만,
        // nearest 로는 각 탭이 단일 비교라 visibility 가 k/9 의 10단계 계단값만 갖는다 — 그림자
        // 반그림자 경계가 블록으로 보인다. linear 로 두면 탭마다 2×2 가중 비교가 걸려 연속값이 된다.
        // `compare_func::less_equal` 은 WE 의 GREATER 와 어긋난 게 아니다 — WE 쪽이 리버스드-Z
        // 규약(common_pbr_2.h `#if REVERSEDEPTH`)이라 Waple 의 정방향 깊이에서는 이쪽이 등가다.
        // address 도 WE 는 BORDER 지만 Waple 은 uv 를 직접 clamp 하므로 무영향.
        constexpr sampler compareSampler(coord::normalized, filter::linear,
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
        // G-E1-3: 비교 샘플러는 **LINEAR** 여야 한다(= 하드웨어 PCF). WE 샘플러 캐시가 만들 수 있는
        // 유일한 비교 필터값은 `0x95 = D3D11_FILTER_COMPARISON_MIN_MAG_MIP_LINEAR` 다
        // (원본 0x140099b67 `mov ecx, 0x95`; Filter 슬롯에 쓰는 명령이 0x140099b05 앞의 한 곳뿐이고
        // ecx 경로가 셋뿐이라 배타적으로 확정). 9탭 오프셋(0.81616/1.02323)은 이미 WE 와 같지만,
        // nearest 로는 각 탭이 단일 비교라 visibility 가 k/9 의 10단계 계단값만 갖는다 — 그림자
        // 반그림자 경계가 블록으로 보인다. linear 로 두면 탭마다 2×2 가중 비교가 걸려 연속값이 된다.
        // `compare_func::less_equal` 은 WE 의 GREATER 와 어긋난 게 아니다 — WE 쪽이 리버스드-Z
        // 규약(common_pbr_2.h `#if REVERSEDEPTH`)이라 Waple 의 정방향 깊이에서는 이쪽이 등가다.
        // address 도 WE 는 BORDER 지만 Waple 은 uv 를 직접 clamp 하므로 무영향.
        constexpr sampler compareSampler(coord::normalized, filter::linear,
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

    // WE `#if HDR  albedo.rgb *= g_Brightness` — 소비 위치가 규약이다: 라이팅·반사를 **다 더한 뒤**,
    // 포그 **직전**(generic2.frag:79-81, generic4.frag:166-172 = REFLECTION 블록 다음 · FOG 블록 앞).
    // 알베도 샘플 직후가 아니다 — 거기 곱하면 스페큘러/반사 가산분이 배율을 안 받는다.
    // LIGHTING 콤보와 무관하게 발화하므로 unlit 조기 반환 경로도 통과해야 한다.
    // 비HDR 씬은 CPU 가 extra.x=1 을 실어 항등이 된다(게이트 근거는 SceneRenderer3D encode3D 주석).
    inline float3 applyHDRBrightness(float3 color, constant MeshU& u) {
        return color * u.extra.x;
    }

    fragment float4 mf_main(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            depth2d_array<float> shadowAtlas [[texture(1)]],
                            texture2d<float> gradientTex [[texture(2)]],
                            constant MeshU& u [[buffer(1)]],
                            constant FrameU& frame [[buffer(2)]],
                            constant LightU* lights [[buffer(3)]],
                            constant float4x4* shadowVP [[buffer(4)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
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
            rgb = applyHDRBrightness(rgb, u);
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
            } else if (kind < 2.5) {   // spot: 감쇠 + 콘(섀도우 스코프 밖)
                direct += spotPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {                   // tube(kind 4): 세그먼트 최근접점 유한광(무섀도우 — WE 정본)
                direct += tubePBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
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
        lit = applyHDRBrightness(lit, u);
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }

    // M3: PBR 노멀맵/마스크 지원 — 스크린공간 미분으로 TBN 근사, 노멀맵 샘플로 법선 보정,
    // 마스크 텍스처로 per-pixel roughness/metallic 오버라이드.
    // 노멀맵: texture(3), 마스크: texture(4), normalParams(포맷/보유 플래그): buffer(5).
    fragment float4 mf_normal(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              depth2d_array<float> shadowAtlas [[texture(1)]],
                              texture2d<float> gradientTex [[texture(2)]],
                              texture2d<float> normalTex [[texture(3)]],
                              texture2d<float> maskTex [[texture(4)]],
                              constant MeshU& u [[buffer(1)]],
                              constant FrameU& frame [[buffer(2)]],
                              constant LightU* lights [[buffer(3)]],
                              constant float4x4* shadowVP [[buffer(4)]],
                              // x=DecompressNormal 포맷(0=블록압축/1=RG88/2=그 외), y=마스크 보유,
                              // z=노멀맵 보유, w=미사용.
                              constant float4& normalParams [[buffer(5)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        constexpr sampler gradientSampler(filter::linear, address::clamp_to_edge);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();
        float mode = u.material.w;
        float fogMode = u.specularTint.w;
        if (mode < 0.5) {
            float3 rgb = sampled.rgb;
            float alpha = sampled.a;
            rgb = applyHDRBrightness(rgb, u);
            applySceneFog(rgb, alpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
            return float4(rgb * alpha, alpha);
        }

        float3 albedo = sampled.rgb;
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        // M3: 노멀맵 보유 시에만 TBN 근사(스크린공간 미분) + 언팩. WE common_fragment.h:18-30 DecompressNormal
        // 포트(2채널 저장 + Z 재구성) — mf_refract(:571-576)의 DecompressNormalWithMask 와는 별개 함수라
        // 바이어스가 다른 축에 실린다(DecompressNormal: 블록압축 x=alpha*2-1/y=green*2-0.965, WithMask 는
        // x=alpha*2-0.965/y=green*2-1 — 통일하면 둘 중 하나가 깨지므로 의도된 차이, 임의 정리 금지).
        // RG88 은 Waple 디코드가 byte0→(r,g,b) 복제·byte1→a(TexDecoder.swift rg88)라 x=.r/y=.a 로 대응.
        if (normalParams.z > 0.5) {
            float3 dpx = dfdx(in.worldPos);
            float3 dpy = dfdy(in.worldPos);
            float2 duvx = dfdx(in.uv);
            float2 duvy = dfdy(in.uv);
            float3 T = normalizedOr(dpx * duvy.y - dpy * duvx.y, float3(1.0, 0.0, 0.0));
            float3 B = normalizedOr(dpy * duvx.x - dpx * duvy.x, float3(0.0, 1.0, 0.0));
            float3x3 TBN = float3x3(T, B, N);
            float4 nraw = normalTex.sample(s, in.uv);
            float nx, ny;
            if (normalParams.x < 0.5) {          // 블록압축(DXT5nm 등 BC1-3)
                nx = nraw.a * 2.0 - 1.0;
                ny = nraw.g * 2.0 - 0.965;
            } else if (normalParams.x < 1.5) {   // RG88
                nx = nraw.r * 2.0 - 1.0;
                ny = nraw.a * 2.0 - 1.0;
            } else {                              // 그 외(비압축) — 바이어스 없음
                nx = nraw.a * 2.0 - 1.0;
                ny = nraw.g * 2.0 - 1.0;
            }
            float nz = sqrt(saturate(1.0 - nx * nx - ny * ny));
            N = normalizedOr(TBN * float3(nx, ny, nz), N);
        }

        // M3: 마스크 텍스처(PBRMASKS)로 per-pixel roughness/metallic 오버라이드(없으면 머티리얼 상수).
        // generic4.frag:96/100 규약 — componentMaps.x(R)=metallic, .y(G)=roughness(① 종전 반전 수정).
        // 게이트는 normalParams.y(hasMask) 플래그로만 판정 — 정당한 마스크 값 0(완전 무광/비금속)이
        // "마스크 없음"으로 오폴백되던 종전 버그(mask.r>0.0 류 값 기반 게이트) 제거.
        float roughness = u.material.x;
        float metallic = u.material.y;
        if (normalParams.y > 0.5) {
            float4 mask = maskTex.sample(s, in.uv);
            metallic = mask.r;
            roughness = mask.g;
        }

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
            } else if (kind < 2.5) {   // spot
                direct += spotPBR(in.worldPos, N, V, albedo, roughness, metallic,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {                   // tube(kind 4 — 무섀도우)
                direct += tubePBR(in.worldPos, N, V, albedo, roughness, metallic,
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
        lit = applyHDRBrightness(lit, u);
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
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
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
            rgb = applyHDRBrightness(rgb, u);
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
            } else if (kind < 2.5) {   // spot
                direct += spotPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                  u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
            } else {                   // tube(kind 4 — 무섀도우)
                direct += tubePBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
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
        lit = applyHDRBrightness(lit, u);
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }

    // M6(⑥): REFLECTION(스크린공간 반사) 메시 — generic4.frag:134-165 1:1(g_Texture3=_rt_MipMappedFrameBuffer
    // 를 acc 스냅샷으로 근사, model_fragment_v1.h ApplyReflection 과 동일 수식). WE 는 이 블록이
    // `#if LIGHTING || REFLECTION`(normal 계산)과 별개로 unlit 에서도 발화하므로(CombineLighting 이후 가산),
    // mf_main 의 조기 unlit return 을 쓰지 않고 lit 베이스(unlit=albedo 그대로 / lit=ambient*albedo+direct)를
    // 계산한 뒤 반사를 공통으로 더한다. 노멀맵과 미결합(기하 노멀만 — WE 의 `#else normalize(v_WorldNormal)`
    // 분기와 동치, NORMALMAP 결합 마스크/탄젠트공간 변환은 과대 스코프라 미포함 — ⑥ caveat).
    // mip 기반 roughness 블러(g_Texture3MipMapInfo)는 **2026-08-18 에 배선했다** — 반사 스냅샷이
    // 밉체인을 갖고(SceneRenderer3D 반사 분기 generateMipmaps) roughness × (밉수-1) 로 LOD 를 고른다.
    // ⚠️ 그런데 이것만으로 3470948192 의 성단은 **안 나온다**(실측). 밉 블러는 필요조건이었지
    // 충분조건이 아니다 — 그 씬의 남은 관문은 따로 있다(REFLECTION_MAP 마스크 미결합? 반사 소스
    // 시점? 미규명). 다음 사람이 "밉을 넣었는데 왜 안 나오지" 로 시간을 쓰지 않도록 적어 둔다.
    // REFLECTION_MAP(마스크 B채널) 은 여전히 미결합, g_Reflectivity 상수만 적용.
    // 씬 스냅샷 texture(4), reflectParams=(g_Reflectivity, aspect=width/height, 0, 0) buffer(5),
    // viewProj(카메라 전용, 모델 미포함) buffer(6).
    fragment float4 mf_reflect(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               depth2d_array<float> shadowAtlas [[texture(1)]],
                               texture2d<float> gradientTex [[texture(2)]],
                               texture2d<float> fbTex [[texture(4)]],
                               constant MeshU& u [[buffer(1)]],
                               constant FrameU& frame [[buffer(2)]],
                               constant LightU* lights [[buffer(3)]],
                               constant float4x4* shadowVP [[buffer(4)]],
                               constant float4& reflectParams [[buffer(5)]],
                               constant float4x4& viewProj [[buffer(6)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
        constexpr sampler gradientSampler(filter::linear, address::clamp_to_edge);
        // 씬 스냅샷은 화면 경계 클램프(REFRACT 의 fbSampler 와 동일 규약).
        // **mip_filter::linear 필수** — MSL 은 mip_filter 를 안 적으면 mip_filter::none 이 기본이고,
        // none 이면 아래 `level(reflectLod)` 가 통째로 무시돼 텍스처에 밉이 있어도 base 만 샘플된다
        // (토큰을 안 쓴 것뿐이라 "mip_filter::none 이 없다" 는 검사로는 안 잡혔다 —
        //  TubeLightCSMandMipTests 가 이 결함을 놓친 이유).
        constexpr sampler fbSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 sampled = tex.sample(s, in.uv) * u.tint;
        if (u.material.z > 0.0 && sampled.a < u.material.z) discard_fragment();

        float3 albedo = sampled.rgb;
        // REFLECTION 은 LIGHTING 여부와 무관하게 geometric normal 이 필요(generic4.frag
        // `#if LIGHTING || REFLECTION`) — mode<0.5(unlit) 에서도 계산.
        float3 N = normalizedOr(in.worldNormal, float3(0.0, 0.0, 1.0));
        float3 V = normalizedOr(frame.cameraEye.xyz - in.worldPos, float3(0.0, 0.0, 1.0));
        float mode = u.material.w;
        float3 lit;
        if (mode < 0.5) {
            // unlit: WE CombineLighting(light=0, ambient=albedo) = albedo 그대로(mf_main 무라이팅 경로와 동치).
            lit = albedo;
        } else {
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
                } else if (kind < 2.5) {
                    direct += spotPBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                      u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
                } else {               // tube(kind 4 — 무섀도우)
                    direct += tubePBR(in.worldPos, N, V, albedo, u.material.x, u.material.y,
                                      u.specularTint.xyz, lights[i], u.rim, gradientTex, gradientSampler);
                }
            }
            float3 ambientColor = frame.ambient.xyz;
            if (mode < 1.5) {
                float hemisphere = clamp(dot(N, float3(0.0, 1.0, 0.0)) * 0.5 + 0.5, 0.0, 1.0);
                ambientColor = mix(frame.skylight.xyz, frame.ambient.xyz, hemisphere);
            }
            lit = ambientColor * albedo + direct;
        }

        // REFLECTION: mul(v,M)=M*v(GLSL 네이티브 규약, 전치 불요 — H1 커스텀 셰이더의 mvp 전치는 GLSLTranslator
        // 산출물 전용이라 여기 무관) 로 world normal 을 카메라 클립공간에 재투영해 화면 오프셋을 만든다.
        // in.pos(윈도우 픽셀, y-down)는 이미 뷰포트변환을 거쳤지만 viewProj*N 결과는 클립공간(y-up)이라
        // y 성분만 부호 반전해야 두 공간이 정합한다.
        float reflectivity = reflectParams.x;
        float fresnelTerm = abs(dot(N, V));
        float3 reflectN = normalize((viewProj * float4(N, 0.0)).xyz);
        float2 aspectScale = float2(0.15, 0.15 * reflectParams.y);
        float2 screenUV = in.pos.xy / float2(fbTex.get_width(), fbTex.get_height());
        screenUV += float2(reflectN.x, -reflectN.y) * pow(fresnelTerm, 4.0) * 10.0 * aspectScale;
        float clipReflection = smoothstep(1.3, 1.0, screenUV.x) * smoothstep(-0.3, 0.0, screenUV.x)
                              * smoothstep(1.3, 1.0, screenUV.y) * smoothstep(-0.3, 0.0, screenUV.y);
        // WE: `texSample2DLod(g_Texture3, uv, roughness * g_Texture3MipMapInfo)`(generic4.frag:159).
        // g_Texture3MipMapInfo 는 그 텍스처의 밉 개수라 roughness(0..1)를 밉 인덱스로 편다.
        // 스냅샷이 이제 밉체인을 갖는다(SceneRenderer3D 반사 분기의 generateMipmaps).
        float reflectLod = u.material.x * float(fbTex.get_num_mip_levels() - 1);
        float3 reflectionColor = fbTex.sample(fbSampler, screenUV, level(reflectLod)).rgb * clipReflection;
        reflectionColor = reflectionColor * (1.0 - fresnelTerm) * reflectivity;
        reflectionColor = pow(max(float3(0.001), reflectionColor), float3(2.0 - u.material.y));
        lit += saturate(reflectionColor);

        float outAlpha = sampled.a;
        float fogMode = u.specularTint.w;
        lit = applyHDRBrightness(lit, u);
        applySceneFog(lit, outAlpha, fogMode, in.worldPos, frame.cameraEye.xyz, frame);
        return float4(lit * outAlpha, outAlpha);
    }
    """
}
