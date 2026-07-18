enum ParticleShaders {
    /// 버텍스 버퍼: 정점당 인터리브드 8 float = [ndc.x, ndc.y, u, v, r, g, b, a].
    /// frag 는 premultiplied-alpha 를 출력하므로 additive/translucent 둘 다 src=one 으로 합성 가능
    /// (translucent: dst=oneMinusSrcAlpha, additive: dst=one).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct PVOut { float4 pos [[position]]; float2 uv; float4 color; };

    vertex PVOut pv_main(uint vid [[vertex_id]],
                         const device float* v [[buffer(0)]],
                         constant float2& cameraOffset [[buffer(1)]],
                         constant float2& parallaxDepth [[buffer(2)]],
                         constant float2& aspectScale [[buffer(3)]],
                         constant float2& shakeOffset [[buffer(4)]]) {
        uint b = vid * 8;
        float2 pos = float2(v[b + 0], v[b + 1]);
        float2 uv  = float2(v[b + 2], v[b + 3]);
        float4 col = float4(v[b + 4], v[b + 5], v[b + 6], v[b + 7]);
        // shakeOffset = camerashake 전역 지터 — parallaxDepth 무관(전역 카메라 병진). 미보유 씬 = 0 → 비트동일.
        // parallaxDepth(F200) = 파티클 오브젝트 마우스 시차 가중치(QuadShaders.v_main 과 동형). 기본(1,1)
        // 이거나 cameraOffset=0(헤드리스 captureFrames 항상 0 — draw() 참조)이면 곱해도 종전과 비트동일.
        float2 p = (pos + cameraOffset * parallaxDepth + shakeOffset) * aspectScale;
        PVOut o; o.pos = float4(p.x, p.y, 0.0, 1.0); o.uv = uv; o.color = col; return o;
    }

    // 3D 씬 파티클: 월드 위치(카메라-페이싱 빌보드로 CPU 전개) → viewProj 원근 투영. 정점당 9 float =
    // [world.xyz, u, v, r, g, b, a]. frag(pf_main)·블렌드는 2D 와 공유(premult α).
    vertex PVOut pv3d_main(uint vid [[vertex_id]],
                           const device float* v [[buffer(0)]],
                           constant float4x4& viewProj [[buffer(1)]]) {
        uint b = vid * 9;
        float3 wp  = float3(v[b + 0], v[b + 1], v[b + 2]);
        float2 uv  = float2(v[b + 3], v[b + 4]);
        float4 col = float4(v[b + 5], v[b + 6], v[b + 7], v[b + 8]);
        PVOut o; o.pos = viewProj * float4(wp, 1.0); o.uv = uv; o.color = col; return o;
    }

    fragment float4 pf_main(PVOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = tex.sample(s, in.uv);
        float A = t.a * in.color.a;
        return float4(t.rgb * in.color.rgb * A, A);
    }

    // REFRACT(스크린 굴절 — WE genericparticle.frag:103-116). 파티클 컬러에 씬 컬러 타깃(fb=뒤 배경
    // 누적 스냅샷)을 노멀맵 오프셋으로 재샘플해 **곱한다**(유리/물방울/열왜곡). vert 는 pv_main 공유
    // (8-float 정점) — 화면 UV 는 in.pos(렌더타깃 픽셀)에서 얻어 f_compose 규약과 동일(y-flip 없음).
    // refractParams = (g_RefractAmount, rg88Flag, 0, 0).
    fragment float4 pf_refract(PVOut in [[stage_in]],
                               texture2d<float> albedoTex [[texture(0)]],
                               texture2d<float> normalTex [[texture(1)]],
                               texture2d<float> fbTex [[texture(2)]],
                               constant float4& refractParams [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = albedoTex.sample(s, in.uv);
        float4 nraw = normalTex.sample(s, in.uv);
        bool rg88 = refractParams.y > 0.5;
        // WE common_fragment.h DecompressNormalWithMask 포트. Waple RG88 디코드가 (b0,b0,b0,b1) 라
        //   normal.x=.a (DXT5nm=alpha / RG88=byte1), normal.y=.g (DXT=green / RG88=byte0 복제) 로 양 포맷 공통.
        //   차이만 분기: x-bias(DXT 0.965 / RG88 1.0), mask(DXT=red / RG88=없음→1.0).
        float nx = nraw.a * 2.0 - (rg88 ? 1.0 : 0.965);
        float ny = nraw.g * 2.0 - 1.0;
        float mask = rg88 ? 1.0 : nraw.r;
        // 스크린-정렬 2D 빌보드 → v_ScreenTangents = refractAmount·I (ViewRight/Up=축, 회전 생략:
        // sprite refract 코퍼스에 회전 이니셜라이저 0건. ponytail: 회전 refract 발견 시 per-vertex 탄젠트).
        // y 부호: WE GLSL 의 -offset.y 는 Metal y-down UV(in.pos) 규약과 상쇄 → 무플립(A/B 육안이 최종 게이트).
        float2 off = refractParams.x * float2(nx, ny) * (mask * in.color.a);
        float2 uv = in.pos.xy / float2(fbTex.get_width(), fbTex.get_height()) + off;
        float3 bg = fbTex.sample(s, uv).rgb;
        float3 rgb = t.rgb * in.color.rgb * bg;   // WE: color.rgb = v_Color*albedo; color.rgb *= framebuffer.rgb
        float A = t.a * in.color.a;
        return float4(rgb * A, A);                // premultiplied(블렌드 src=one)
    }
    """
}
