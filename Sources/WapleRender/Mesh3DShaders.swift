/// 3D 메시(MDLV0023) 렌더 MSL — v1 unlit(텍스처 × 머티리얼 tint).
/// 정점은 [[stage_in]] 대신 buffer(0) 수동 페치: CPU 에서 pos3+normal3+uv2 = 8 float(32B)로 재패킹
/// (원본 .mdl 의 tangent/bone/weight 는 v1 미사용 — 스트라이드 48/80 을 그대로 쓰지 않는다).
/// drawIndexedPrimitives 에서 vertex_id = 인덱스 버퍼 값.
enum Mesh3DShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // params: misc.x = 알파컷(>0 이면 a < misc.x 프래그먼트 discard — alphatocoverage/컷아웃 근사)
    struct MeshU {
        float4x4 mvp;
        float4 tint;
        float4 misc;
    };
    struct VOut { float4 pos [[position]]; float2 uv; float3 normal; };

    vertex VOut mv_main(uint vid [[vertex_id]],
                        const device float* vtx [[buffer(0)]],
                        constant MeshU& u [[buffer(1)]]) {
        uint b = vid * 8;
        VOut o;
        o.pos = u.mvp * float4(vtx[b], vtx[b + 1], vtx[b + 2], 1.0);
        o.normal = float3(vtx[b + 3], vtx[b + 4], vtx[b + 5]);
        // UV 원점 = 상단(V 플립 없음): A/B 실측 — 플립 시 젤다 담쟁이/이끼가 벽 상단에 붙음.
        // .tex 디코더 행 순서(top-down, 2D GT 검증)와 모델 UV 가 같은 규약.
        o.uv = float2(vtx[b + 6], vtx[b + 7]);
        return o;
    }

    fragment float4 mf_main(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            constant MeshU& u [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        float4 c = tex.sample(s, in.uv) * u.tint;
        if (u.misc.x > 0.0 && c.a < u.misc.x) { discard_fragment(); }
        // 합성 규약(설계 §3)과 동일하게 premultiplied 출력(파이프라인 블렌드 src=one).
        return float4(c.rgb * c.a, c.a);
    }
    """
}
