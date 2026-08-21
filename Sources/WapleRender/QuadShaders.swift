enum QuadShaders {
    // verts buffer: float4 per vertex = (ndc.x, ndc.y, uv.x, uv.y)
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };

    """ + BlendMSL.source + """
    vertex VOut v_main(uint vid [[vertex_id]],
                       const device float4* verts [[buffer(0)]],
                       constant float2& cameraOffset [[buffer(1)]],
                       constant float2& parallaxDepth [[buffer(2)]],
                       constant float2& aspectScale [[buffer(3)]],
                       constant float2& shakeOffset [[buffer(4)]]) {
        float4 v = verts[vid];
        // shakeOffset = camerashake 전역 지터 — parallaxDepth 무관(전역 카메라 병진). 미보유 씬 = 0 → 비트동일.
        float2 p = (v.xy + cameraOffset * parallaxDepth + shakeOffset) * aspectScale;
        VOut o; o.pos = float4(p.x, p.y, 0.0, 1.0); o.uv = float2(v.z, v.w); return o;
    }
    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        // 파이프라인 규약(설계 §3): 입력(텍스처/이펙트 결과)은 straight-alpha.
        // 블렌드가 src=one(premultiplied-over)이므로 여기서 단 한 번 premultiply 한다.
        float a = c.a * tint.a;
        return float4(c.rgb * tint.rgb * a, a);
    }
    // DIRECTDRAW 이펙트 체인 출력 전용 변형 — 입력이 **이미 premultiplied** 라 알파를 다시 곱하지 않는다.
    // lightshafts(DIRECTDRAW=1)는 albedo=0 에서 시작해 ApplyBlending(31,·)=A+B·opacity 로
    // rgb=fxColor·intensity·fx, a=fx 를 낸다 — 정의상 색×커버리지, 즉 premultiplied 다. f_main 의
    // 규약대로 여기서 다시 a 를 곱하면 fx² 가 되고, 실측 fx 최대 0.0314 에서 fx²<1/255 라 광선이
    // 8비트에서 통째로 소멸한다(성질이 다른 노이즈 텍스처들이 전부 "숨김"과 비트동일해진다).
    // 알파/틴트는 그대로 곱한다(레이어 opacity) — 금지되는 것은 c.a 재곱 하나뿐이다.
    // 반대안(체인 에필로그에서 rgb/a 로 straight 복원)은 기각했다: 이펙트 체인 중간 타깃이
    // rgba8Unorm 고정이라 fxColor·intensity 가 1.0 에 클램프된다. 코퍼스 41건 중 intensity>1 이
    // 다수이고(3690417937 id152 는 4.02 → 색이 1.92~4.02) 광선이 2~4배 어두워진다. 반대로
    // premultiplied 로 두면 저장값이 곧 최종 기여분이라 8비트 양자화가 출력 정밀도와 같다.
    fragment float4 f_main_premul(VOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float a = c.a * tint.a;
        return float4(c.rgb * tint.rgb * tint.a, a);
    }
    // 스프라이트 프레임 추출(spriteFrameTexture): 아틀라스 서브렉트를 프레임크기 dst 로 1:1 복사한다.
    // 종전 blit.copy 대체 — blit 은 BC 아틀라스를 CPU rgba8 로 강제했으나(BC→rgba8 blit 무효), 샘플은
    // BC 를 GPU 에서 디코드하므로 아틀라스가 네이티브 BC 로 상주할 수 있다(keepFullAtlas 네이티브 허용).
    // fullscreen 쿼드(effectVertexBuffer) + rect=(u0,v0,du,dv) 정규화 서브렉트. dst 가 정확히 프레임
    // 크기(fw×fh)라 **nearest** 샘플이 dst 픽셀중심 (i+0.5)/fw → 아틀라스 텍셀 sx+i 로 떨어져 blit 과
    // **텍셀 동일**(비-BC bit-identical). tint/premultiply 없음 — straight-alpha 규약(§3, 합성서 1회 premult) 보존.
    vertex VOut v_spriteframe(uint vid [[vertex_id]], const device float2* verts [[buffer(0)]]) {
        float2 p = verts[vid];
        VOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5); return o;
    }
    fragment float4 f_spriteframe(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                  constant float4 &rect [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float2 uv = float2(rect.x + in.uv.x * rect.z, rect.y + in.uv.y * rect.w);
        return atlas.sample(s, uv);
    }
    // 컴포지션(_rt_FullFrameBuffer) 레이어 전용: 프레임버퍼 스냅샷(tex)을 **화면좌표**로 샘플한다
    // (f_blend 의 dst 샘플과 동일 규약 — in.pos = 렌더타깃 픽셀좌표, y-flip 없음이 정본:
    // BlendModeLayerTests 로 검증됨). f_main 처럼 로컬 UV(0-1) 로 샘플하면 전체 화면이 부분 쿼드에
    // stretch 되어 회색 삼각형 덩어리가 됨(E1). tint/premult 규약은 f_main 동일(스트레이트→프리멀티 1회).
    fragment float4 f_compose(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 uv = float2(in.pos.x / float(tex.get_width()), in.pos.y / float(tex.get_height()));
        float4 c = tex.sample(s, uv);
        float a = c.a * tint.a;
        return float4(c.rgb * tint.rgb * a, a);
    }
    // 레이어 colorBlendMode 합성: dst = acc 스냅샷(화면좌표 샘플), src = 레이어 텍스처×tint.
    // 블렌딩은 셰이더에서 계산(HW 블렌딩 OFF, 결과 rgb 직기록·dst 알파 보존).
    // acc 는 premultiplied 누적 — 불투명 배경(일반 씬)에선 straight 와 동일(컴포지션과 같은 전제).
    fragment float4 f_blend(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            texture2d<float> dst [[texture(1)]],
                            constant float4 &tint [[buffer(0)]],
                            constant int &mode [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float2 duv = float2(in.pos.x / float(dst.get_width()), in.pos.y / float(dst.get_height()));
        float4 d = dst.sample(s, duv);
        float o = c.a * tint.a;
        float3 r = applyBlending(mode, d.rgb, c.rgb * tint.rgb, o);
        return float4(r, d.a);
    }
    // H4: REFRACT(스크린 굴절 — WE genericimage2/4 의 refract 분기). 레이어 컬러에 씬 컬러 타깃(fb=뒤 배경
    // 누적 스냅샷)을 노멀맵 오프셋으로 재샘플해 **곱한다**(유리/물방울/열왜곡). vert 는 v_main 공유
    // (4-float 정점) — 화면 UV 는 in.pos(렌더타깃 픽셀)에서 얻어 f_compose 규약과 동일(y-flip 없음).
    // refractParams = (g_RefractAmount, rg88Flag, 0, 0).
    fragment float4 f_refract(VOut in [[stage_in]],
                              texture2d<float> albedoTex [[texture(0)]],
                              texture2d<float> normalTex [[texture(1)]],
                              texture2d<float> fbTex [[texture(2)]],
                              constant float4& tint [[buffer(0)]],
                              constant float4& refractParams [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 t = albedoTex.sample(s, in.uv);
        float4 nraw = normalTex.sample(s, in.uv);
        bool rg88 = refractParams.y > 0.5;
        // WE common_fragment.h DecompressNormalWithMask 포트(ParticleShaders.pf_refract 와 동일 규약).
        float nx = nraw.a * 2.0 - (rg88 ? 1.0 : 0.965);
        float ny = nraw.g * 2.0 - 1.0;
        float mask = rg88 ? 1.0 : nraw.r;
        // y 부호: WE GLSL 의 -offset.y 는 Metal y-down UV(in.pos) 규약과 상쇄 → 무플립(A/B 육안이 최종 게이트).
        float2 off = refractParams.x * float2(nx, ny) * (mask * tint.a);
        float2 uv = in.pos.xy / float2(fbTex.get_width(), fbTex.get_height()) + off;
        float3 bg = fbTex.sample(s, uv).rgb;
        float3 rgb = t.rgb * tint.rgb * bg;   // WE: color.rgb = v_Color*albedo; color.rgb *= framebuffer.rgb
        float A = t.a * tint.a;
        return float4(rgb * A, A);            // premultiplied(블렌드 src=one)
    }
    // WE genericimage4 유한광 감쇠의 HLSL lane/Metal 포트. 반경 컷오프 없음(exponent=0 이면 전역 무감쇠).
    inline float finiteLightFalloff(float dist, float radius, float exponent) {
        // F543(F-75): radius<=0 가드(Mesh3DShaders 사본과 대칭) — 호출부(f_lit)가 선차단하지만 방어 일관성.
        if (radius <= 0.0) return 0.0;
        float falloff = clamp(1.0 - dist / radius, 0.0, 1.0);
        // WE 2.8.42 HLSL lane(Mesh3DShaders 사본과 대칭): pow(falloff + 1.17549435e-38, exponent).
        return pow(falloff + 1.17549435e-38, exponent);
    }
    // 영벡터 방어 정규화(Mesh3DShaders:48 사본과 대칭) — 라이트 축/L 정규화 전용.
    inline float3 normalizedOr(float3 value, float3 fallback) {
        float length2 = dot(value, value);
        return length2 > 1e-12 ? value * rsqrt(length2) : fallback;
    }
    struct PBRMaterialUniforms {
        float4 scalars;       // x=roughness, y=metallic
        float4 specularTint;  // xyz=specular tint
    };
    inline float distributionGGX(float3 N, float3 H, float roughness) {
        float r2 = roughness * roughness;
        float r4 = r2 * r2;
        float NH = max(dot(N, H), 0.0);
        float rawDenominator = NH * NH * (r4 - 1.0) + 1.0;
        // [safety deviation] Native has no floor and reaches 0/0 at roughness=0, N·H=1.
        constexpr float ggxDenominatorFloor = 1e-4;
        float denominator = max(rawDenominator, ggxDenominatorFloor);
        return r4 / (3.14159265359 * denominator * denominator);
    }
    inline float schlickGGX(float ND, float roughness) {
        float r = roughness + 1.0;
        float k = r * r / 8.0;
        return ND / (ND * (1.0 - k) + k);
    }
    inline float geometrySmith(float3 N, float3 V, float3 L, float roughness) {
        return schlickGGX(max(dot(N, V), 0.001), roughness)
             * schlickGGX(max(dot(N, L), 0.001), roughness);
    }
    inline float3 fresnelSchlick(float cosTheta, float3 F0) {
        return F0 + (1.0 - F0) * pow(max(1.0 - cosTheta, 0.001), 5.0);
    }
    // 2D 포워드 라이팅(라이트 씬의 LIGHTING:1 레이어 전용). P2a = orthographic finite-point PBR.
    //   worldPos: uv → 레이어 월드 사각형 재구성. N=V=+Z.
    //   미사용 슬롯/짧은반경 라이트는 radius≤0 로 스킵(count 유니폼 불필요 — directional 은 무감쇠라 제외).
    //   비-HDR bgra8Unorm 블로아웃 정책은 기존 경로를 보존한다.
    //   F800(S-9): kind 분기(point/spot cone/directional) — 3D 경로(Mesh3DShaders 의
    //   directionalPBR/spotPBR) 확정 수식의 2D 포트. kind/axis/cone 데이터는 ForwardUniforms
    //   (WapleCore SceneDocument.swift)가 blue축(Rz·Ry·Rx col2 = WE Mat4.forward 규약)·half-angle
    //   코사인으로 팩한다. buffer 6/7 은 상위 5개 슬롯 규약을 건드리지 않는 후방 확장.
    //   tube(kind 4): 세그먼트 최근접점 유한광 — WE genericimage3.frag:115/157
    //   PointSegmentDelta(common_pbr.h:9-16) 포트(무섀도우, A2-pbr-lighting.md §4.4). axis 슬롯은
    //   tube 에선 forward 가 아니라 단점 B(g_LTube_OriginB)를 실는다(ForwardUniforms 주석 참조).
    fragment float4 f_lit(VOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          constant float4 &tint [[buffer(0)]],
                          constant float4 *rect [[buffer(1)]],      // [0]=(ox,oy,hw,hh) [1]=(cosA,sinA,z,_)
                          constant float4 *lightPos [[buffer(2)]],  // [8] xyz=world, w=exponent
                          constant float4 *lightCol [[buffer(3)]],  // [8] rgb=color×intensity, w=radius
                          constant float4 &ambient [[buffer(4)]],   // xyz=flat ambient (genericimage4)
                          constant PBRMaterialUniforms &material [[buffer(5)]],
                          constant float4 *lightAxisCone [[buffer(6)]],  // [8] xyz=forward|tube 단점B, w=cone outer cos
                          constant float4 *lightKindCone [[buffer(7)]]) { // [8] x=kind(0/1/2/4), y=cone inner cos
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        // uv(0..1) → 레이어 로컬(-hw..hw) → 회전 → 월드 픽셀(quadVertices 역산). z = 레이어 originZ.
        float lx = (in.uv.x * 2.0 - 1.0) * rect[0].z;
        float ly = (in.uv.y * 2.0 - 1.0) * rect[0].w;
        float ca = rect[1].x, sa = rect[1].y;
        float3 world = float3(rect[0].x + lx * ca - ly * sa, rect[0].y + lx * sa + ly * ca, rect[1].z);
        float3 N = float3(0.0, 0.0, 1.0);
        float3 V = float3(0.0, 0.0, 1.0);
        float3 albedo = c.rgb * tint.rgb;
        float roughness = material.scalars.x;
        float metallic = material.scalars.y;
        float3 F0 = mix(float3(0.04), albedo, metallic);
        float3 direct = float3(0.0);
        // 슬롯 8 — 3D 레인(Scene3DLighting.maximumLights)과 같은 상한. F660 이 3D 를 8 로 올릴 때
        // 이 2D 루프만 4 로 남아 5번째 라이트부터 2D 라이팅 레이어에서만 사라졌다.
        // 바인딩 길이는 ForwardUniforms.slotCount(WapleCore) · SceneRenderer 의 light* 배열과 동기.
        //
        // ⚠️ WE 에는 이 상한이 없다 — 씬 `general.lightconfig` 의 종류별 카운트가 그대로 배열 길이가
        // 되고(생성기 0x140169140–0x14016b0d4, 콤보 세터 0x1401a5c40) 저장 폭이 니블이라 종별 최대 15,
        // 섀도우/쿠키 계열은 2비트라 최대 3 이다. 8 은 **Waple 쪽 캡**이다. 미사용 슬롯은
        // `radius<=0`(kind!=1) 로 스킵되므로 카운트를 **줄이는** 쪽은 데이터만으로 재현되고,
        // 늘리는 쪽만 퍼뮤테이션이 필요하다 — 규약 전문은 `SceneLightSlotBudget`(WapleCore) 주석과
        // `docs/re/scene-lighting.md` §3/§6.
        // 다만 이 2D 레인의 라이트 팩은 `SceneDocument.ForwardUniforms`(WapleCore, 타 레인 소유)라
        // lightconfig 예산은 **아직 2D 에 배선되지 않았다**. 3D 레인은 배선됐다 —
        // `SceneRenderer3D.build3D` 가 `scene3DLightConfig` 에 담고
        // `Scene3DLighting.resolveLights(_:nodes:config:)` 가 `SceneLightSlotBudget` 으로 소비한다.
        for (int i = 0; i < 8; i++) {
            int kind = int(lightKindCone[i].x + 0.5);
            float3 L;
            float3 radiance;
            if (kind == 1) {
                // directional(F800): 무한거리 무감쇠 radiance = color×intensity, L = -forward
                // (Mesh3DShaders directionalPBR 포트). radius=0(미저작)이 정상이라 반경 가드 전에 분기.
                L = normalizedOr(-lightAxisCone[i].xyz, float3(0.0, 1.0, 0.0));
                radiance = lightCol[i].xyz;
            } else {
                float radius = lightCol[i].w;
                if (radius <= 0.0) continue;
                float3 delta;
                if (kind == 4) {
                    // tube: 세그먼트 최근접점까지의 델타 — WE common_pbr.h:9-16 PointSegmentDelta 1:1
                    // (saturate=clamp(x,0,1); A==B 퇴화(v==0)는 A-pos 반환이라 아래 point 경로와 동치).
                    float3 a = lightPos[i].xyz;
                    float3 ab = lightAxisCone[i].xyz - a;
                    float vv = dot(ab, ab);
                    delta = (vv == 0.0 ? a : a + clamp(dot(world - a, ab) / vv, 0.0, 1.0) * ab) - world;
                } else {
                    delta = lightPos[i].xyz - world;
                }
                float dist = length(delta);
                if (dist < 1e-5) continue;
                L = delta / dist;
                float attenuation = finiteLightFalloff(dist, radius, lightPos[i].w);
                radiance = lightCol[i].xyz * attenuation;
                if (kind == 2) {
                    // spot(F800): point 감쇠 × 콘 스무드스텝(축 forward 기준, 콘 밖 0)
                    // — Mesh3DShaders spotPBR 포트. 광자 진행 방향 forward vs light→surface(-L) 코사인.
                    float cosAngle = dot(normalizedOr(lightAxisCone[i].xyz, float3(0.0, 0.0, 1.0)), -L);
                    float cosInner = lightKindCone[i].y;
                    float cosOuter = lightAxisCone[i].w;
                    float cone = clamp((cosAngle - cosOuter) / max(cosInner - cosOuter, 1e-4), 0.0, 1.0);
                    cone = cone * cone * (3.0 - 2.0 * cone);     // smoothstep
                    if (cone <= 0.0) continue;
                    radiance *= cone;
                }
            }
            float NL = max(dot(N, L), 0.0);
            // Back-facing output is already zero; return early to avoid normalize(V+L) NaN.
            if (NL <= 0.0) continue;
            float3 H = normalize(V + L);
            float D = distributionGGX(N, H, roughness);
            float G = geometrySmith(N, V, L, roughness);
            float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
            float3 kD = (1.0 - metallic) * (1.0 - F);
            float denominator = max(4.0 * max(dot(N, V), 0.0) * NL, 0.001);
            float3 specular = (D * G * F) / denominator;
            direct += (kD * albedo / 3.14159265359 + specular * material.specularTint.xyz)
                    * radiance * NL;
        }
        // Direct PBR already contains diffuse albedo; ambient gets albedo exactly once.
        // f_main 규약대로 straight→premultiplied 를 마지막에 단 한 번(블렌드 src=one).
        float3 lit = ambient.xyz * albedo + direct;
        float a = c.a * tint.a;
        return float4(lit * a, a);
    }
    """
    /// 감사 V07: 베이스 레이어 NoInterpolation(TexImage flags bit0) 전용 nearest 변형 — 4개 frag
    /// (f_main/f_blend/f_compose/f_lit)의 유일한 선형 샘플러 선언만 filter::nearest 로 치환.
    /// 어드레스 모드(clamp_to_edge)·mip 필터(linear — 1단계 mip 활성화, 단일레벨은 LOD 클램프로 무연산)는
    /// 보존(WE NoInterpolation 은 min/mag 필터만 point). v_main/f_spriteframe 은 샘플러가 없거나 이미
    /// nearest 라 무영향. 원본 source 는 불변 — 기존 선형 파이프라인 비트동일(무회귀).
    static let nearestSource = source.replacingOccurrences(
        of: "constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);",
        with: "constexpr sampler s(filter::nearest, mip_filter::linear, address::clamp_to_edge);")
}
