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
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        // 파이프라인 규약(설계 §3): 입력(텍스처/이펙트 결과)은 straight-alpha.
        // 블렌드가 src=one(premultiplied-over)이므로 여기서 단 한 번 premultiply 한다.
        float a = c.a * tint.a;
        return float4(c.rgb * tint.rgb * a, a);
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
        constexpr sampler s(filter::linear, address::clamp_to_edge);
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
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float2 duv = float2(in.pos.x / float(dst.get_width()), in.pos.y / float(dst.get_height()));
        float4 d = dst.sample(s, duv);
        float o = c.a * tint.a;
        float3 r = applyBlending(mode, d.rgb, c.rgb * tint.rgb, o);
        return float4(r, d.a);
    }
    // WE genericimage4 유한광 감쇠의 GLSL/Metal 포트. 반경 경계는 0^0 스파이크를 막도록 hard zero.
    inline float finiteLightFalloff(float dist, float radius, float exponent) {
        // F543(F-75): radius<=0 가드(Mesh3DShaders:142 사본과 대칭) — 호출부(f_lit)가 선차단하지만 방어 일관성.
        if (radius <= 0.0) return 0.0;
        float falloff = clamp(1.0 - dist / radius, 0.0, 1.0);
        constexpr float eps = 6.103515625e-5;
        return falloff >= eps ? pow(falloff + eps, exponent) : 0.0;
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
    //   worldPos: uv → 레이어 월드 사각형 재구성. N=V=+Z; light type specialization is P2b.
    //   미사용 슬롯/짧은반경 라이트는 radius≤0 로 스킵(count 유니폼 불필요).
    //   비-HDR bgra8Unorm 블로아웃 정책은 기존 경로를 보존한다.
    //   TODO(S-9): spot/directional 분기는 kind/axis/cone 데이터가 유니폼에 없어 이 파일만으로는 불가
    //   — forwardUniforms 팩(WapleCore SceneDocument.swift) + 렌더러 바인딩(SceneRenderer.swift /
    //   SceneRendererFrameEncoder.swift) 확장이 선행돼야 한다. WE CPU 측 angles→2D 방향 규약도 미확정
    //   (docs/superpowers/specs/2026-07-14-we-2d-pbr-p2a-design.md 의 의도적 보류). 3D 경로는 F274 계열
    //   Mesh3DShaders 의 directional/spot 분기를 참조.
    fragment float4 f_lit(VOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          constant float4 &tint [[buffer(0)]],
                          constant float4 *rect [[buffer(1)]],      // [0]=(ox,oy,hw,hh) [1]=(cosA,sinA,z,_)
                          constant float4 *lightPos [[buffer(2)]],  // [4] xyz=world, w=exponent
                          constant float4 *lightCol [[buffer(3)]],  // [4] rgb=color×intensity, w=radius
                          constant float4 &ambient [[buffer(4)]],   // xyz=flat ambient (genericimage4)
                          constant PBRMaterialUniforms &material [[buffer(5)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
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
        for (int i = 0; i < 4; i++) {
            float radius = lightCol[i].w;
            if (radius <= 0.0) continue;
            float3 delta = lightPos[i].xyz - world;
            float dist = length(delta);
            if (dist < 1e-5) continue;
            float3 L = delta / dist;
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
            float attenuation = finiteLightFalloff(dist, radius, lightPos[i].w);
            float3 radiance = lightCol[i].xyz * attenuation;
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
}
