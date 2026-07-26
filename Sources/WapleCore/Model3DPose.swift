import Foundation
import simd

/// 3D 모델(MDLV0023 + MDLA0006) 스킨 행렬 평가(순수) — 2D PuppetPose 의 3D 대응.
///
/// 규약(2026-07-04 헥스 리버스 + 실측): bind = 부모상대 로컬 레스트 변환 → bindWorld(부모 체인).
/// 애니 키 = pos + 오일러각(라디안, Rz·Ry·Rx) + scale, 프레임당 1키(트랙 인덱스 = 본 인덱스).
/// 스킨_i = world_i(t) × bindWorld_i⁻¹ (메시 정점은 bindWorld 레스트 포즈에서 저작).
/// 2D 와 달리 키0 ≠ bind 인 캐릭터가 흔함(바인드=T포즈, idle=이완포즈) — t=0 항등 가정은 버리되
/// 위 식은 그대로 정답(애니 첫 프레임 포즈로 변형). 오일러 순서·bindWorld 합성은 렌더 실측으로 게이트.
public enum Model3DPose {
    /// 트랙 키 선형 보간(프레임당 1키). 빈 트랙 → nil(바인드 로컬 사용).
    static func sampledLocal(_ keys: [Model3D.Key], frame: Float) -> simd_float4x4? {
        guard !keys.isEmpty else { return nil }
        let f = max(0, min(frame, Float(keys.count - 1)))
        let i = Int(f)
        let j = min(i + 1, keys.count - 1)
        let t = f - Float(i)
        let a = keys[i], b = keys[j]
        return PuppetPose.localMatrix(position: a.position + (b.position - a.position) * t,
                                      angles: a.angles + (b.angles - a.angles) * t,
                                      scale: a.scale + (b.scale - a.scale) * t)
    }

    /// 본별 스킨 행렬. animation 인덱스 범위 밖 → 전부 항등(바인드 포즈 = 정지). rate 는 재생 배속.
    public static func skinMatrices(model: Model3D, animation: Int, time: Float, rate: Float = 1) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        // 바인드 월드(부모 체인 합성). 부모 인덱스가 자신 이후면(비정상 순서) 항등 처리.
        var bindWorld = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            let p = Int(b.parent)
            bindWorld[i] = (b.parent >= 0 && p < i) ? bindWorld[p] * b.bind : b.bind
        }
        guard animation >= 0, animation < model.animations.count else {
            return [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        }
        let anim = model.animations[animation]
        let f = PuppetPose.frame(time: time * rate, fps: anim.fps, length: anim.lengthFrames, mode: anim.mode)
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            let p = Int(b.parent)
            let local = (i < anim.tracks.count ? sampledLocal(anim.tracks[i], frame: f) : nil) ?? b.bind
            world[i] = (b.parent >= 0 && p < i) ? world[p] * local : local
        }
        return (0..<n).map { world[$0] * PuppetPose.safeInverse(bindWorld[$0]) }
    }

    /// 커스텀 셰이더 경로용 CPU 정점 스키닝 — Mesh3DShaders mv_skin(MSL)과 같은 수학을 CPU 에서 수행해
    /// rigid 8f 패킹(pos3+normal3+uv2)으로 반환한다. matrices = skinMatrices 결과.
    /// 본 인덱스는 GPU 패킹과 같이 matrices.count-1 로 clamp, 가중치 합 0 이면 바인드 포즈 통과도 mv_skin 과 동치.
    public static func cpuSkinnedPacked(mesh: Model3D.Mesh, matrices: [simd_float4x4]) -> [Float] {
        guard !matrices.isEmpty else { return [] }
        let mx = UInt32(matrices.count - 1)
        var out: [Float] = []
        out.reserveCapacity(mesh.vertices.count * 8)
        for v in mesh.vertices {
            var p = v.position
            var n = v.normal
            let wsum = v.weights.x + v.weights.y + v.weights.z + v.weights.w
            if wsum > 0 {
                let w = v.weights / wsum
                let idx = SIMD4<UInt32>(min(v.boneIndices.x, mx), min(v.boneIndices.y, mx),
                                        min(v.boneIndices.z, mx), min(v.boneIndices.w, mx))
                let p4 = SIMD4<Float>(v.position, 1)
                let n4 = SIMD4<Float>(v.normal, 0)
                var sp = SIMD3<Float>(0, 0, 0)
                var sn = SIMD3<Float>(0, 0, 0)
                for k in 0..<4 {
                    let tp = matrices[Int(idx[k])] * p4
                    let tn = matrices[Int(idx[k])] * n4
                    sp += w[k] * SIMD3<Float>(tp.x, tp.y, tp.z)
                    sn += w[k] * SIMD3<Float>(tn.x, tn.y, tn.z)
                }
                p = sp; n = sn
            }
            out.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, v.uv.x, v.uv.y])
        }
        return out
    }

    /// animationlayers 레이어 이름 → 파스된 애니 인덱스. 실측: 레이어 "Idle" → 애니 "..._arm|idle_bone".
    /// 서브스트링 매칭(소문자) → 폴백 "idle" → 폴백 인덱스 0. 애니 없음 → -1.
    public static func resolveAnimation(model: Model3D, layerName: String?) -> Int {
        guard !model.animations.isEmpty else { return -1 }
        if let ln = layerName?.lowercased(), !ln.isEmpty,
           let i = model.animations.firstIndex(where: { $0.name.lowercased().contains(ln) }) {
            return i
        }
        if let i = model.animations.firstIndex(where: { $0.name.lowercased().contains("idle") }) { return i }
        return 0
    }
}
