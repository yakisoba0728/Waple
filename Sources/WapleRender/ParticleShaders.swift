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

    // C4-(ii): overbright(genericparticle.frag "color.rgb *= g_Overbright" — material 유니폼, 기본
    // 1.0, range[0,5]). 곱셈은 순서 무관(스칼라)이라 premultiply 전/후 어디에 곱해도 동치 — 기본 1 이면
    // 렌더 비트동일. 3D 비-포그 파티클(particle3DAdditive/Translucent)도 이 함수를 공유해 함께 적용됨.
    fragment float4 pf_main(PVOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                            constant float& overbright [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = tex.sample(s, in.uv);
        float A = t.a * in.color.a;
        return float4(t.rgb * in.color.rgb * A * overbright, A);
    }

    // M(④): 3D 파티클 씬 포그(genericparticle.frag FOG 콤보 기본 1 — 3706286085 실증). 별도 MSL
    // 컴파일 단위(파일)라 Mesh3DShaders.applySceneFog 를 직접 호출할 수 없어 동일 수식을 포트한다.
    // WE genericparticle.frag 는 ApplyFog(rgb)+ApplyFogAlpha(alpha) 를 ADDITIVE 게이트 없이 무조건
    // 적용(mesh generic4.frag 는 ApplyFogAlpha 가 #if ADDITIVE 안에만 있어 다름 — common_fog.h 참조).
    struct PVOut3DFog { float4 pos [[position]]; float2 uv; float4 color; float3 worldPos; };
    // FrameU(Mesh3DShaders) 의 마지막 5개 필드와 동일 레이아웃(eye+포그 4종) — Scene3DFrameUniform 에서
    // 발췌한 Particle3DFogUniform 을 그대로 바인딩.
    struct FogU3D { float4 eye; float4 fogDistanceColor; float4 fogDistanceParams; float4 fogHeightColor; float4 fogHeightParams; };

    vertex PVOut3DFog pv3d_fog_main(uint vid [[vertex_id]],
                                    const device float* v [[buffer(0)]],
                                    constant float4x4& viewProj [[buffer(1)]]) {
        uint b = vid * 9;
        float3 wp  = float3(v[b + 0], v[b + 1], v[b + 2]);
        float2 uv  = float2(v[b + 3], v[b + 4]);
        float4 col = float4(v[b + 5], v[b + 6], v[b + 7], v[b + 8]);
        PVOut3DFog o; o.pos = viewProj * float4(wp, 1.0); o.uv = uv; o.color = col; o.worldPos = wp; return o;
    }

    fragment float4 pf3d_fog(PVOut3DFog in [[stage_in]], texture2d<float> tex [[texture(0)]],
                             constant FogU3D& fog [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = tex.sample(s, in.uv);
        float3 rgb = t.rgb * in.color.rgb;
        // C4-(ii): overbright — eye.xyz 만 거리 계산에 쓰이고 .w 는 미사용 패딩이라 재사용(기본 1, 무회귀).
        rgb *= fog.eye.w;
        float alpha = t.a * in.color.a;
        float viewDist = distance(fog.eye.xyz, in.worldPos);
        float heightFactor = 0.0;
        float distFactor = 0.0;
        if (fog.fogHeightColor.w > 0.5) {
            float ht = saturate((in.worldPos.y - fog.fogHeightParams.x) / fog.fogHeightParams.y);
            heightFactor = fog.fogHeightParams.z + fog.fogHeightParams.w * ht * ht;
            rgb = mix(rgb, fog.fogHeightColor.xyz, heightFactor);
        }
        if (fog.fogDistanceColor.w > 0.5) {
            float dt = saturate((viewDist - fog.fogDistanceParams.x) / fog.fogDistanceParams.y);
            distFactor = fog.fogDistanceParams.z + fog.fogDistanceParams.w * dt * dt;
            rgb = mix(rgb, fog.fogDistanceColor.xyz, distFactor);
        }
        // ApplyFogAlpha: WE 는 REFRACT/LIGHTING 무관 무조건 적용(ADDITIVE 게이트 없음, mesh 와 차이).
        float fogFactor = saturate(max(distFactor, heightFactor));
        alpha *= 1.0 - fogFactor * fogFactor;
        return float4(rgb * alpha, alpha);
    }

    // REFRACT(스크린 굴절 — WE genericparticle.frag:103-116). 파티클 컬러에 씬 컬러 타깃(fb=뒤 배경
    // 누적 스냅샷)을 노멀맵 오프셋으로 재샘플해 **곱한다**(유리/물방울/열왜곡). vert 는 pv_main 공유
    // (8-float 정점) — 화면 UV 는 in.pos(렌더타깃 픽셀)에서 얻어 f_compose 규약과 동일(y-flip 없음).
    // refractParams = (g_RefractAmount, rg88Flag, g_Overbright(C4-(ii), 기본 1), 0).
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
        // 스크린-정렬 2D 빌보드 → v_ScreenTangents = refractAmount·I (ViewRight/Up=축, 회전 생략).
        // C4-(iii): spriteTrail(F790 신장 쿼드)도 이 경로에 진입 — 속도 방향 회전 쿼드(atan2 각도)라
        // 엄밀한 축-정렬은 아니지만, 코퍼스 유일 실물(rain_on_the_glass1)의 시각 결과는 정접(수용된 근사 —
        // 계획 문서상 "trail은 회전 쿼드라 탄젠트 근사 미세 차이 수용"). ponytail: 회전 refract 오차가
        // 눈에 띄면 per-vertex 탄젠트로 축 정렬.
        // y 부호: WE GLSL 의 -offset.y 는 Metal y-down UV(in.pos) 규약과 상쇄 → 무플립(A/B 육안이 최종 게이트).
        float2 off = refractParams.x * float2(nx, ny) * (mask * in.color.a);
        float2 uv = in.pos.xy / float2(fbTex.get_width(), fbTex.get_height()) + off;
        float3 bg = fbTex.sample(s, uv).rgb;
        float3 rgb = t.rgb * in.color.rgb * bg;   // WE: color.rgb = v_Color*albedo; color.rgb *= framebuffer.rgb
        rgb *= refractParams.z;                   // C4-(ii): overbright(기본 1, 무회귀)
        float A = t.a * in.color.a;
        return float4(rgb * A, A);                // premultiplied(블렌드 src=one)
    }
    """
    /// 감사 V07: 파티클 알베도 NoInterpolation(TexImage flags bit0) 전용 nearest 변형 — pf_main/pf_refract
    /// 의 유일한 선형 샘플러 선언만 filter::nearest 로 치환. 어드레스 모드(clamp_to_edge)는 보존(WE
    /// NoInterpolation 은 필터만 point). 원본 source 는 불변 — 기존 선형 파이프라인 비트동일(무회귀).
    static let nearestSource = source.replacingOccurrences(
        of: "constexpr sampler s(filter::linear, address::clamp_to_edge);",
        with: "constexpr sampler s(filter::nearest, address::clamp_to_edge);")
}
