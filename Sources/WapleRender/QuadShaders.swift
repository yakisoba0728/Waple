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
                       constant float2& aspectScale [[buffer(3)]]) {
        float4 v = verts[vid];
        float2 p = (v.xy + cameraOffset * parallaxDepth) * aspectScale;
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
        float falloff = clamp(1.0 - dist / radius, 0.0, 1.0);
        constexpr float eps = 6.103515625e-5;
        return falloff >= eps ? pow(falloff + eps, exponent) : 0.0;
    }
    // 2D 포워드 라이팅(라이트 씬의 LIGHTING:1 레이어 전용). P1 범위는 exponent 감쇠 + flat ambient.
    //   worldPos: uv → 레이어 월드 사각형 재구성(quadVertices 와 동일 규약). N=+Z(평면 레이어).
    //   light = ambient + Σ color·saturate(dot(normalize(lightPos-world), N))·pow(falloff+eps, exponent).
    //   미사용 슬롯/짧은반경 라이트는 radius≤0 로 스킵(count 유니폼 불필요).
    //   블로아웃: bgra8Unorm 이 [0,1] 클램프 = 고강도(HDR)는 white(HDR/톤맵 패스 전까지 — 보고).
    fragment float4 f_lit(VOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          constant float4 &tint [[buffer(0)]],
                          constant float4 *rect [[buffer(1)]],      // [0]=(ox,oy,hw,hh) [1]=(cosA,sinA,z,_)
                          constant float4 *lightPos [[buffer(2)]],  // [4] xyz=world, w=exponent
                          constant float4 *lightCol [[buffer(3)]],  // [4] rgb=color×intensity, w=radius
                          constant float4 &ambient [[buffer(4)]]) { // xyz=flat ambient (genericimage4)
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        // uv(0..1) → 레이어 로컬(-hw..hw) → 회전 → 월드 픽셀(quadVertices 역산). z = 레이어 originZ.
        float lx = (in.uv.x * 2.0 - 1.0) * rect[0].z;
        float ly = (in.uv.y * 2.0 - 1.0) * rect[0].w;
        float ca = rect[1].x, sa = rect[1].y;
        float3 world = float3(rect[0].x + lx * ca - ly * sa, rect[0].y + lx * sa + ly * ca, rect[1].z);
        float3 N = float3(0.0, 0.0, 1.0);
        float3 light = ambient.xyz;
        for (int i = 0; i < 4; i++) {
            float radius = lightCol[i].w;
            if (radius <= 0.0) continue;
            float3 delta = lightPos[i].xyz - world;
            float dist = length(delta);
            if (dist < 1e-5) continue;
            float attenuation = finiteLightFalloff(dist, radius, lightPos[i].w);
            float ndl = max(0.0, dot(delta / dist, N));
            light += lightCol[i].xyz * (ndl * attenuation);
        }
        // WE genericimage*/generic2: albedo *= g_TintColor(=color×brightness), albedo.rgb *= light.
        // f_main 규약대로 straight→premultiplied 를 마지막에 단 한 번(블렌드 src=one).
        float3 lit = c.rgb * tint.rgb * light;
        float a = c.a * tint.a;
        return float4(lit * a, a);
    }
    """
}
