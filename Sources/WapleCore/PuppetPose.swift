import Foundation
import simd

/// 퍼펫 포즈 평가(순수): 트랙 키 보간 → 본 로컬 → 계층 합성 → 스킨 행렬 → CPU 스키닝.
///
/// 실측 근거(2809885105): 트랙 첫 키가 바인드 평행이동과 일치 → 키와 바인드는 같은 공간.
/// 바인드/키를 동일한 방식(부모 체인 합성)으로 계산하면 t=0 에 스킨이 항등이 되어 좌표계 가정과
/// 무관하게 정확하다. 스킨_i = world_i(t) × bindWorld_i⁻¹.
public enum PuppetPose {
    /// 재생 모드 시간 매핑 → 프레임(0..length 실수).
    static func frame(time: Float, fps: Float, length: Int, mode: String) -> Float {
        guard length > 0, fps > 0 else { return 0 }
        let f = time * fps
        let L = Float(length)
        switch mode {
        case "mirror":
            let cycle = f.truncatingRemainder(dividingBy: 2 * L)
            return cycle <= L ? cycle : 2 * L - cycle
        case "single":
            return min(f, L)
        default:  // loop
            return f.truncatingRemainder(dividingBy: L)
        }
    }

    /// 키 → 로컬 행렬(T·Rz·Ry·Rx·S).
    static func localMatrix(_ k: PuppetModel.Key) -> simd_float4x4 {
        localMatrix(position: k.position, angles: k.angles, scale: k.scale)
    }

    /// 성분 → 로컬 행렬(T·Rz·Ry·Rx·S). 2D 퍼펫·3D 모델(Model3DPose) 공용 — 오일러 순서 규약 단일 소스.
    static func localMatrix(position: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        let cz = cos(angles.z), sz = sin(angles.z)
        let cy = cos(angles.y), sy = sin(angles.y)
        let cx = cos(angles.x), sx = sin(angles.x)
        let rz = simd_float4x4(SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        let ry = simd_float4x4(SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1))
        let rx = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0), SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1))
        let s = simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
        var m = rz * ry * rx * s
        m.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return m
    }

    /// 트랙 키 선형 보간(프레임당 1키 규약). 빈 트랙 → nil(바인드 로컬 사용).
    static func sampledLocal(_ keys: [PuppetModel.Key], frame: Float) -> simd_float4x4? {
        guard !keys.isEmpty else { return nil }
        let f = max(0, min(frame, Float(keys.count - 1)))
        let i = Int(f)
        let j = min(i + 1, keys.count - 1)
        let t = f - Float(i)
        let a = keys[i], b = keys[j]
        let k = PuppetModel.Key(position: a.position + (b.position - a.position) * t,
                                angles: a.angles + (b.angles - a.angles) * t,
                                scale: a.scale + (b.scale - a.scale) * t)
        return localMatrix(k)
    }

    /// 본별 스킨 행렬. animation 인덱스가 범위 밖이면 항등(정지 포즈).
    public static func skinMatrices(model: PuppetModel, animation: Int, time: Float) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        // 바인드 월드(부모 체인 합성)
        var bindWorld = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            bindWorld[i] = b.parent >= 0 ? bindWorld[Int(b.parent)] * b.bind : b.bind
        }
        guard animation >= 0, animation < model.animations.count else {
            return [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        }
        let anim = model.animations[animation]
        let f = frame(time: time, fps: anim.fps, length: anim.lengthFrames, mode: anim.mode)
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            let local = (i < anim.tracks.count ? sampledLocal(anim.tracks[i], frame: f) : nil) ?? b.bind
            world[i] = b.parent >= 0 ? world[Int(b.parent)] * local : local
        }
        return (0..<n).map { world[$0] * bindWorld[$0].inverse }
    }

    /// CPU 스키닝: p' = Σ wᵏ · skin[idxᵏ] · p. 가중치 합 0 → 원위치.
    public static func skinnedPositions(model: PuppetModel, matrices: [simd_float4x4]) -> [SIMD3<Float>] {
        model.vertices.map { v in
            let wsum = v.weights.x + v.weights.y + v.weights.z + v.weights.w
            guard wsum > 0, !matrices.isEmpty else { return v.position }
            var out = SIMD3<Float>(0, 0, 0)
            let p4 = SIMD4(v.position.x, v.position.y, v.position.z, 1)
            for k in 0..<4 {
                let w = v.weights[k]
                guard w > 0 else { continue }
                let bi = min(Int(v.boneIndices[k]), matrices.count - 1)
                let q = matrices[bi] * p4
                out += SIMD3(q.x, q.y, q.z) * (w / wsum)
            }
            return out
        }
    }
}
