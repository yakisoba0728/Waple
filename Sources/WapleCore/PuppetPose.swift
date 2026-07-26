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
        case "single", "clamp":   // clamp: 마지막 프레임 유지(Model3D animModes·PropertyAnimation 과 일관)
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

    /// F442: 퇴화(영스케일) 행렬의 .inverse 는 NaN/Inf 를 만들어 스킨 행렬 전체로 번진다(Metal 은 NaN
    /// 정점을 크래시 없이 쓰레기 렌더로 처리). 행렬식이 0/비유한이면 항등으로 폴터(묵스킨에 준함).
    static func safeInverse(_ m: simd_float4x4) -> simd_float4x4 {
        let d = m.determinant
        guard d.isFinite, abs(d) > 1e-12 else { return matrix_identity_float4x4 }
        return m.inverse
    }

    /// 본별 스킨 행렬. animation 인덱스가 범위 밖이면 항등(정지 포즈).
    public static func skinMatrices(model: PuppetModel, animation: Int, time: Float) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        // 바인드 월드(부모 체인 합성)
        var bindWorld = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            let p = Int(b.parent)
            bindWorld[i] = (b.parent >= 0 && p < i) ? bindWorld[p] * b.bind : b.bind  // 부모가 자신 이후/범위 밖이면 루트
        }
        guard animation >= 0, animation < model.animations.count else {
            return [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        }
        let anim = model.animations[animation]
        let f = frame(time: time, fps: anim.fps, length: anim.lengthFrames, mode: anim.mode)
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            let local = (i < anim.tracks.count ? sampledLocal(anim.tracks[i], frame: f) : nil) ?? b.bind
            let p = Int(b.parent)
            world[i] = (b.parent >= 0 && p < i) ? world[p] * local : local  // 부모가 자신 이후/범위 밖이면 루트
        }
        return (0..<n).map { world[$0] * safeInverse(bindWorld[$0]) }
    }

    /// 두 로컬 행렬 성분별 lerp(캐스케이드 절대 블렌드). t=0→a, t=1→b 정확, 중간=보간.
    /// 회전 slerp 미사용(2D 퍼펫은 z회전·평행이동 위주 — 성분 블렌드로 충분; WE 도 근사).
    static func mixLocal(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        simd_float4x4(a.columns.0 + (b.columns.0 - a.columns.0) * t,
                      a.columns.1 + (b.columns.1 - a.columns.1) * t,
                      a.columns.2 + (b.columns.2 - a.columns.2) * t,
                      a.columns.3 + (b.columns.3 - a.columns.3) * t)
    }

    /// 레이어 → 애니 클립 인덱스. C③: clipId(scene.json animationlayers[].animation, 모델 클립의 실제
    /// id — PuppetModel.Animation.id, 컨테이너형(MDLV0016+) 퍼펫만 보유·네이티브 MDLV0013 은 항상 nil)
    /// 가 있고 매칭되면 최우선(저작 도구가 클립명을 제네릭 "动画 1/2/3" 으로 남기고 레이어 이름에만
    /// 의미부여하는 실물 사례 — 이름 휴리스틱 오선택 회피). 없거나 미매칭이면 종전 이름 서브스트링
    /// 매칭 → fallback 위치 클램프(무회귀: clipId nil 인 씬은 100% 종전 경로). 애니 없음 → 0.
    public static func clipIndex(model: PuppetModel, name: String, fallback: Int, clipId: Int? = nil) -> Int {
        let count = model.animations.count
        guard count > 0 else { return 0 }
        if let cid = clipId, let i = model.animations.firstIndex(where: { $0.id == cid }) { return i }
        let ln = name.lowercased()
        if !ln.isEmpty, let i = model.animations.firstIndex(where: {
            // F443: 빈 클립명(V0013 파스는 빈 애니 이름을 허용 — PuppetModel.parseV0013)은 contains("") 가
            // 항상 참이라 아무 쿼리에나 선택된다 — 매칭 후보에서 제외.
            let cn = $0.name.lowercased(); return !cn.isEmpty && (cn.contains(ln) || ln.contains(cn))
        }) { return i }
        return min(max(fallback, 0), count - 1)
    }

    /// 본별 바인드 월드(부모 체인 합성) — 스킨/부착점 공용.
    static func bindWorlds(_ model: PuppetModel) -> [simd_float4x4] {
        var bw = [simd_float4x4](repeating: matrix_identity_float4x4, count: model.bones.count)
        for (i, b) in model.bones.enumerated() {
            let p = Int(b.parent)
            bw[i] = (b.parent >= 0 && p < i) ? bw[p] * b.bind : b.bind
        }
        return bw
    }

    /// 본 월드 행렬(모델공간 — 스킨의 bindWorld⁻¹ 곱 이전). layers 캐스케이드 규약은
    /// blendedSkinMatrices 와 동일, 빈 layers = 바인드 포즈. 부착점(attachment) 프레임 산출용.
    /// C④: overrideFrames[i] 가 non-nil 이면 그 레이어의 프레임을 time×rate 순간위상 대신 그대로 쓴다
    /// (호출측이 dt 적분한 값 — 스크립트 구동 rate 전용). nil 인 인덱스는 기존 계산 그대로(비트동일).
    static func worldMatrices(model: PuppetModel,
                              layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                              time: Float, overrideFrames: [Float?]? = nil) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        let bind = bindWorlds(model)
        guard !layers.isEmpty else { return bind }
        // 레이어별 프레임(자기 클립의 fps/mode/length + rate 배속) — override 우선.
        let frames: [Float] = layers.enumerated().map { (li, L) in
            if let of = overrideFrames, li < of.count, let f = of[li] { return f }
            guard L.anim >= 0, L.anim < model.animations.count else { return 0 }
            let a = model.animations[L.anim]
            return frame(time: time * L.rate, fps: a.fps, length: a.lengthFrames, mode: a.mode)
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        for (i, b) in model.bones.enumerated() {
            var local = b.bind
            for (li, L) in layers.enumerated() {
                guard L.anim >= 0, L.anim < model.animations.count else { continue }
                let tracks = model.animations[L.anim].tracks
                let clip = (i < tracks.count ? sampledLocal(tracks[i], frame: frames[li]) : nil) ?? b.bind
                if L.additive {
                    let ref = (i < tracks.count ? sampledLocal(tracks[i], frame: 0) : nil) ?? b.bind
                    // 가중 델타: weight 0 → 항등(무기여), 1 → 전체 델타.
                    let wdelta = mixLocal(matrix_identity_float4x4, clip * safeInverse(ref), L.weight)
                    local = wdelta * local
                } else {
                    local = mixLocal(local, clip, L.weight)
                }
            }
            let p = Int(b.parent)
            world[i] = (b.parent >= 0 && p < i) ? world[p] * local : local
        }
        return world
    }

    /// 다층 animationlayers 캐스케이드 블렌드 스킨 행렬(순수). `layers` 순서 = 합성 순서.
    /// 각 본 로컬은 bind 에서 시작해 레이어 순차 합성:
    ///   - 절대(additive=false): `local = lerp(local, clip, weight)` — 캐스케이드(첫 절대·weight=1 = 그 클립).
    ///   - 가산(additive=true):  `local = (clip × clipFrame0⁻¹) × local` — 델타 합성(기준=클립 프레임0).
    /// 이후 부모체인 world → `skin = world × bindWorld⁻¹`(skinMatrices 와 동일).
    /// 단일 절대 레이어 weight=1 → `skinMatrices(animation:)` 와 동일(= 단층 무회귀 보장).
    /// ⚠️ 가산 델타 기준(클립 프레임0)·정규화·성분 lerp 는 WE C++ 내부 규약의 근사 — SP 리포트 참조.
    /// C④: overrideFrames 는 worldMatrices 로 그대로 전달(스크립트 구동 rate dt 적분 — 상세는 그쪽 주석).
    public static func blendedSkinMatrices(model: PuppetModel,
                                           layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                                           time: Float, overrideFrames: [Float?]? = nil) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0, !layers.isEmpty else {
            return [simd_float4x4](repeating: matrix_identity_float4x4, count: n)
        }
        let world = worldMatrices(model: model, layers: layers, time: time, overrideFrames: overrideFrames)
        let bindWorld = bindWorlds(model)
        return (0..<n).map { world[$0] * safeInverse(bindWorld[$0]) }
    }

    /// C④: 스크립트 구동 rate(매프레임 재평가)의 캐스케이드 위상 dt 적분. rate 가 프레임마다 바뀌면
    /// time×rate 순간위상은 위상이 t×Δrate 만큼 순간 이동해 포즈가 매 프레임 무작위로 점프한다(감사
    /// C④ — 오디오 반응 rate 씬 실측). 이전 누적위상에 dt×rate×fps 를 더해 위상을 연속시킨다.
    /// previousPhase가 nil(첫 프레임/캐스케이드 레이어 구성 변경으로 무효화)이면 그 프레임만
    /// time×rate 순간위상으로 시딩(다음 프레임부터 연속 적분 — 정적 rate 경로와 값이 일치하는 시작점).
    /// 반환 phase 는 래핑 전 원시 누적값(다음 호출에 그대로 넘겨야 연속성 유지), frame 은 표시용(래핑됨).
    public static func integratedCascadeFrame(model: PuppetModel, anim: Int, rate: Float,
                                               time: Float, dt: Float,
                                               previousPhase: Float?) -> (phase: Float, frame: Float) {
        guard anim >= 0, anim < model.animations.count else { return (0, 0) }
        let a = model.animations[anim]
        let base = previousPhase.map { $0 + dt * rate * a.fps } ?? (time * rate * a.fps)
        let f = frame(time: base / max(a.fps, 1e-6), fps: a.fps, length: a.lengthFrames, mode: a.mode)
        return (base, f)
    }

    /// 부착점 프레임(퍼펫 모델공간 y-up): `boneWorld(t) × attLocal` — 씬 오브젝트 `attachment`
    /// (이름 본-슬롯 부착)의 시변 부모 프레임. 이름 미존재/본 인덱스 범위 밖 → nil(무부착 폴백).
    /// 빈 layers 는 **첫 클립 재생**으로 폴백 — encodeLayer 부모 퍼펫의 단일 경로
    /// `skinMatrices(animation: 0)` 과 포즈 클록을 일치시킨다(단일 절대 weight=1 캐스케이드 ≡ 클립 0).
    public static func attachmentFrame(model: PuppetModel, name: String,
                                       layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                                       time: Float) -> simd_float4x4? {
        guard let att = model.attachments.first(where: { $0.name == name }),
              att.bone >= 0, Int(att.bone) < model.bones.count else { return nil }
        let L = (layers.isEmpty && !model.animations.isEmpty)
            ? [(anim: 0, additive: false, weight: Float(1), rate: Float(1))] : layers
        return worldMatrices(model: model, layers: L, time: time)[Int(att.bone)] * att.local
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
