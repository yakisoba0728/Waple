/// 3D 메시(MDLV0023) 렌더 MSL — v1 unlit(텍스처 × 머티리얼 tint).
/// 정점은 [[stage_in]] 대신 buffer(0) 수동 페치:
///   • 정적 메시: CPU 에서 pos3+normal3+uv2 = 8 float(32B)로 재패킹(mv_main).
///   • 스키닝 메시(v3): pos3+normal3+uv2+boneIdx4+weight4 = 16 float(64B) 재패킹 + 본행렬 버퍼(buffer(2))로
///     GPU 정점 스키닝(mv_skin). CPU 는 프레임당 본행렬(skin=world×bindWorld⁻¹)만 계산(Model3DPose).
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

    // 스키닝 정점 셰이더: 16 float 스트라이드(pos3,normal3,uv2,boneIdx4,weight4).
    // p' = Σ (wᵏ/Σw) · bones[idxᵏ] · p. 가중치 합 0 → 원위치(정적). idx 는 CPU 에서 clamp 됨.
    vertex VOut mv_skin(uint vid [[vertex_id]],
                        const device float* vtx [[buffer(0)]],
                        constant MeshU& u [[buffer(1)]],
                        const device float4x4* bones [[buffer(2)]]) {
        uint b = vid * 16;
        float3 pos = float3(vtx[b], vtx[b + 1], vtx[b + 2]);
        float4 w = float4(vtx[b + 12], vtx[b + 13], vtx[b + 14], vtx[b + 15]);
        uint4 idx = uint4(uint(vtx[b + 8] + 0.5), uint(vtx[b + 9] + 0.5),
                          uint(vtx[b + 10] + 0.5), uint(vtx[b + 11] + 0.5));
        float wsum = w.x + w.y + w.z + w.w;
        float4 p4 = float4(pos, 1.0);
        float3 sp;
        if (wsum > 0.0) {
            float4 acc = (w.x / wsum) * (bones[idx.x] * p4)
                       + (w.y / wsum) * (bones[idx.y] * p4)
                       + (w.z / wsum) * (bones[idx.z] * p4)
                       + (w.w / wsum) * (bones[idx.w] * p4);
            sp = acc.xyz;
        } else { sp = pos; }
        VOut o;
        o.pos = u.mvp * float4(sp, 1.0);
        o.normal = float3(vtx[b + 3], vtx[b + 4], vtx[b + 5]);  // unlit — 미변환 무영향
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
