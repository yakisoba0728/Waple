import Foundation
import simd

/// 3D 모델(MDLV0023 + MDLA0006) 스킨 행렬 평가(순수) — 2D PuppetPose 의 3D 대응.
///
/// 규약(2026-07-04 헥스 리버스 + 실측): bind = 부모상대 로컬 레스트 변환 → bindWorld(부모 체인).
/// 애니 키 = pos + 오일러각(라디안) + scale, 프레임당 1키(트랙 인덱스 = 본 인덱스).
/// 키 각 3축의 **파일 순서는 (X, Y, Z)** 이고 합성은 `Rz(z)·Ry(y)·Rx(x)` 다 — MDL 로더의
/// 오일러→쿼터니언 굽기(0x140264188–0x1402642ae, 반각 상수 0x1404926c0)가 네 값을 포즈 SoA
/// 슬롯 3..6 = (w,x,y,z) 에 넣는 데서 확정(슬롯 순서 근거: 시딩 0x1401fe2f2–0x1401fe657 +
/// 행렬→쿼터니언 0x140215730 이 스칼라부 0.5·sqrt(1+trace) 를 첫 칸 [rdi+0x00] 에 쓴다).
/// **종전 이 주석은 (Z, Y, X) 라고 적고 있었다** — `18a7ae6` 이 굽기 식 넷에 저장 슬롯을 보지 않고
/// "ZYX 공식의 모양" 으로 이름을 붙인 결과다(함정 16). 무작위 3축 400쌍 수치대조에서
/// (X,Y,Z) 불일치 0/400 · (Z,Y,X) 불일치 400/400. 상세는 PuppetPose.rotationQuaternion.
/// 스킨_i = world_i(t) × bindWorld_i⁻¹ (메시 정점은 bindWorld 레스트 포즈에서 저작).
/// 2D 와 달리 키0 ≠ bind 인 캐릭터가 흔함(바인드=T포즈, idle=이완포즈) — t=0 항등 가정은 버리되
/// 위 식은 그대로 정답(애니 첫 프레임 포즈로 변형). 오일러 순서·bindWorld 합성은 렌더 실측으로 게이트.
public enum Model3DPose {
    public static func replacingLocalOrigin(in matrix: simd_float4x4, origin: SIMD3<Float>) -> simd_float4x4 {
        var result = matrix
        result.columns.3 = SIMD4(origin, matrix.columns.3.w)
        return result
    }

    public static func replacingLocalAngles(in matrix: simd_float4x4,
                                             anglesRadians: SIMD3<Float>) -> simd_float4x4? {
        guard var pose = PuppetPose.decomposeTRS(matrix) else { return nil }
        pose.rotation = PuppetPose.rotationQuaternion(anglesRadians)
        return PuppetPose.trsMatrix(pose)
    }
    /// 트랙 키 보간(프레임당 1키) → TRS. 빈 트랙 → nil(바인드 로컬 사용).
    ///
    /// 위치·스케일은 성분 lerp, **회전은 오일러 lerp 가 아니라 쿼터니언 nlerp**(최단호 부호보정 +
    /// 재정규화)다 — WE 는 로드 시점에 키의 오일러를 쿼터니언으로 굽고(0x140264188–0x1402642ae)
    /// 보간을 전부 쿼터니언 공간에서 한다(0x1401f8d3f–0x1401f8e1a). 오일러 성분 lerp 는 두 키의
    /// 각도차가 크거나 축이 여러 개일 때 다른 경로를 그린다(±π 를 넘나드는 키에서 특히).
    /// 프레임 인덱스/보간계수 규약은 `PuppetPose.sampledTRS` 주석(0x140170580) 참조.
    static func sampledTRS(_ keys: [Model3D.Key], frame: Float) -> PuppetPose.TRS? {
        guard !keys.isEmpty else { return nil }
        let f = max(0, min(frame, Float(keys.count - 1)))
        let i = Int(f)
        let j = min(i + 1, keys.count - 1)
        let t = f - Float(i)
        let a = keys[i], b = keys[j]
        return PuppetPose.TRS(
            position: a.position + (b.position - a.position) * t,
            rotation: PuppetPose.nlerpShortest(PuppetPose.rotationQuaternion(a.angles),
                                               PuppetPose.rotationQuaternion(b.angles), t),
            scale: a.scale + (b.scale - a.scale) * t)
    }

    /// 트랙 키 보간 → 로컬 행렬. 빈 트랙 → nil(바인드 로컬 사용).
    static func sampledLocal(_ keys: [Model3D.Key], frame: Float) -> simd_float4x4? {
        sampledTRS(keys, frame: frame).map(PuppetPose.trsMatrix)
    }

    /// 바인드 월드(부모 체인 합성) — PuppetPose.bindWorlds 의 Model3D.Bone 판. 부모 인덱스가 자신 이후면(비정상 순서) 루트 취급.
    /// 합성 순서(`world[parent] * local`, 로컬 먼저)와 **스케일 상속**(4×4 전체 곱, 스케일 제거 없음)의
    /// 실측 근거는 `PuppetPose.bindWorlds` 주석 단일 소스 — `0x14005ecb0` 산술 + 호출부 `0x1401fea8b`.
    private static func buildBindWorlds(_ bones: [Model3D.Bone]) -> [simd_float4x4] {
        var bw = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        for (i, b) in bones.enumerated() {
            let p = Int(b.parent)
            bw[i] = (b.parent >= 0 && p < i) ? bw[p] * b.bind : b.bind
        }
        return bw
    }

    /// 본별 스킨 행렬. animation 인덱스 범위 밖 → 전부 항등(바인드 포즈 = 정지). rate 는 재생 배속.
    ///
    /// **`rate` 가 음수면 `time * rate` 가 음수로 들어온다.** WE 는 그것을 역방향 비트
    /// (`0x1401a9fc5` 의 `xorps` 로 `dt` 부호 반전)로 표현하고 모드별로 되돌린다 — loop 는
    /// `T += D` 후 `fmodf`(`0x1401aa064`), mirror 는 0 에서 반사(`0x1401aa140`). 그 되돌림은
    /// `PuppetPose.frame` 단일 소스에 있고 이 함수는 그것을 그대로 경유한다(2026-08-21 4차 수정 —
    /// 종전에는 음수 프레임이 그대로 나와 아래 `sampledTRS` 의 `max(0, …)` 가 프레임 0 으로
    /// 뭉갰다: 역방향 재생이 클립 **끝**이 아니라 **시작**에 붙어 버렸다).
    ///
    /// 트랙 키 수 = `frameCount + 1` 이 엔진 불변식이라(`0x140263c85` → `int 0x29`
    /// `0x140263c8c`, 서술은 docs/re/skeleton-animation.md §6.1) `frame()` 의 상한 `lengthFrames`
    /// 와 `sampledTRS` 의 상한 `keys.count-1` 이 같은 값이 된다 — 정상 데이터에서는 클램프가
    /// 무동작이다. 회귀 핀: `PuppetMDLAFramingTests.testKeyCountIsFrameCountPlusOne…`.
    public static func skinMatrices(model: Model3D, animation: Int, time: Float, rate: Float = 1) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        let bindWorld = buildBindWorlds(model.bones)
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
    ///
    /// **선형 블렌드 스키닝(LBS)** 이고 정점당 본은 정확히 4개다 — 네 슬롯을 가중치와 무관하게
    /// 전부 더하는 것도 WE 셰이더와 같다(`genericimage3.vert:139-142` 외 8개). 듀얼 쿼터니언
    /// 경로는 WE 에 없다(동봉 셰이더 137개 grep 0건). 법선도 같은 가중합의 3×3 부분을 쓴다
    /// (`CAST3X3(g_Bones[…])` — `genericimage3.vert:170-173`). 근거 단일 소스는
    /// `PuppetPose.skinnedPositions` 주석. wsum 나눗셈은 Waple 자체 셰이더 정합용 발산이다.
    public static func cpuSkinnedPacked(mesh: Model3D.Mesh, matrices: [simd_float4x4],
                                        includeTangents: Bool = false, includeUV1: Bool = false) -> [Float] {
        guard !matrices.isEmpty else { return [] }
        let mx = UInt32(matrices.count - 1)
        var out: [Float] = []
        out.reserveCapacity(mesh.vertices.count * (8 + (includeTangents ? 4 : 0) + (includeUV1 ? 2 : 0)))
        for v in mesh.vertices {
            var p = v.position
            var n = v.normal
            var tangent = SIMD3(v.tangent.x, v.tangent.y, v.tangent.z)
            let wsum = v.weights.x + v.weights.y + v.weights.z + v.weights.w
            if wsum > 0 {
                let w = v.weights / wsum
                let idx = SIMD4<UInt32>(min(v.boneIndices.x, mx), min(v.boneIndices.y, mx),
                                        min(v.boneIndices.z, mx), min(v.boneIndices.w, mx))
                let p4 = SIMD4<Float>(v.position, 1)
                let n4 = SIMD4<Float>(v.normal, 0)
                let t4 = SIMD4<Float>(tangent, 0)
                var sp = SIMD3<Float>(0, 0, 0)
                var sn = SIMD3<Float>(0, 0, 0)
                var st = SIMD3<Float>(0, 0, 0)
                for k in 0..<4 {
                    let tp = matrices[Int(idx[k])] * p4
                    let tn = matrices[Int(idx[k])] * n4
                    sp += w[k] * SIMD3<Float>(tp.x, tp.y, tp.z)
                    sn += w[k] * SIMD3<Float>(tn.x, tn.y, tn.z)
                    if includeTangents {
                        let tt = matrices[Int(clamping: idx[k])] * t4
                        st += w[k] * SIMD3<Float>(tt.x, tt.y, tt.z)
                    }
                }
                p = sp; n = sn
                if includeTangents { tangent = st }
            }
            out.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
            if includeTangents { out.append(contentsOf: [tangent.x, tangent.y, tangent.z, v.tangent.w]) }
            out.append(contentsOf: [v.uv.x, v.uv.y])
            if includeUV1 { out.append(contentsOf: [v.uv1.x, v.uv1.y]) }
        }
        return out
    }

    /// The Model3D track type uses the same recovered cascade/TRS math as PuppetPose.worldMatrices.
    public static func worldMatrices(model: Model3D,
                                      layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                                      time: Float, overrideFrames: [Float?]? = nil,
                                      localOverrides: [Int: simd_float4x4] = [:]) -> [simd_float4x4] {
        guard !model.bones.isEmpty else { return [] }
        if layers.isEmpty && localOverrides.isEmpty { return buildBindWorlds(model.bones) }
        let frames = layers.enumerated().map { (i, layer) -> Float in
            if let overrideFrames, i < overrideFrames.count, let frame = overrideFrames[i] { return frame }
            guard model.animations.indices.contains(layer.anim) else { return 0 }
            let clip = model.animations[layer.anim]
            return PuppetPose.frame(time: time * layer.rate, fps: clip.fps, length: clip.lengthFrames, mode: clip.mode)
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: model.bones.count)
        for (i, bone) in model.bones.enumerated() {
            let local: simd_float4x4
            if var pose = PuppetPose.decomposeTRS(bone.bind) {
                for (li, layer) in layers.enumerated() {
                    guard model.animations.indices.contains(layer.anim) else { continue }
                    let tracks = model.animations[layer.anim].tracks
                    guard tracks.indices.contains(i), let clip = sampledTRS(tracks[i], frame: frames[li]) else { continue }
                    if layer.additive {
                        guard let reference = sampledTRS(tracks[i], frame: 0) else { continue }
                        pose = PuppetPose.addTRS(pose, clip: clip, reference: reference, weight: layer.weight)
                    } else {
                        pose = PuppetPose.mixTRS(pose, clip, layer.weight)
                    }
                }
                local = PuppetPose.trsMatrix(pose)
            } else {
                var matrix = bone.bind
                for (li, layer) in layers.enumerated() {
                    guard model.animations.indices.contains(layer.anim) else { continue }
                    let tracks = model.animations[layer.anim].tracks
                    guard tracks.indices.contains(i), let clip = sampledLocal(tracks[i], frame: frames[li]) else { continue }
                    if layer.additive {
                        let reference = sampledLocal(tracks[i], frame: 0) ?? bone.bind
                        matrix = PuppetPose.mixLocal(matrix_identity_float4x4,
                                                     clip * PuppetPose.safeInverse(reference), layer.weight) * matrix
                    } else {
                        matrix = PuppetPose.mixLocal(matrix, clip, layer.weight)
                    }
                }
                local = matrix
            }
            let parent = Int(clamping: bone.parent)
            let effectiveLocal = localOverrides[i] ?? local
            world[i] = parent >= 0 && parent < i ? world[parent] * effectiveLocal : effectiveLocal
        }
        return world
    }

    public static func blendedSkinMatrices(model: Model3D,
                                            layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                                            time: Float, overrideFrames: [Float?]? = nil,
                                            localOverrides: [Int: simd_float4x4] = [:]) -> [simd_float4x4] {
        guard !layers.isEmpty || !localOverrides.isEmpty else {
            return Array(repeating: matrix_identity_float4x4, count: model.bones.count)
        }
        let world = worldMatrices(model: model, layers: layers, time: time, overrideFrames: overrideFrames,
                                  localOverrides: localOverrides)
        let bind = buildBindWorlds(model.bones)
        return world.indices.map { world[$0] * PuppetPose.safeInverse(bind[$0]) }
    }

    public static func attachmentFrame(model: Model3D, name: String,
                                        layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                                        time: Float, overrideFrames: [Float?]? = nil,
                                        localOverrides: [Int: simd_float4x4] = [:]) -> simd_float4x4? {
        guard let attachment = model.attachments.first(where: { $0.name == name }),
              attachment.bone >= 0, Int(clamping: attachment.bone) < model.bones.count else { return nil }
        // 3D animation=nil is a bind pose; unlike the 2D single-clip fallback it must not start clip0.
        return worldMatrices(model: model, layers: layers, time: time,
                             overrideFrames: overrideFrames, localOverrides: localOverrides)[Int(clamping: attachment.bone)] * attachment.local
    }

    public static func integratedCascadeFrame(model: Model3D, anim: Int, rate: Float, time: Float, dt: Float,
                                               previousPhase: Float?) -> (phase: Float, frame: Float) {
        guard model.animations.indices.contains(anim) else { return (0, 0) }
        let clip = model.animations[anim]
        let phase = previousPhase.map { $0 + dt * rate * clip.fps } ?? (time * rate * clip.fps)
        return (phase, PuppetPose.frame(time: phase / max(clip.fps, 1e-6), fps: clip.fps,
                                       length: clip.lengthFrames, mode: clip.mode))
    }

    /// animationlayers 레이어 → 파스된 애니 인덱스. C③: clipId(scene.json animationlayers[].animation,
    /// 모델 클립의 실제 id — Model3D.Animation.id, 클립 레코드 선두 u64 경유)가 있고 매칭되는 클립이
    /// 있으면 최우선(저작 도구가 클립명을 "动画 1/2/3" 같은 제네릭으로 남기고 레이어 이름만 의미
    /// 부여하는 실물 사례 — 이름 휴리스틱은 오선택). 없거나 미매칭이면 종전 이름 서브스트링 매칭 →
    /// "idle" 폴백 → 인덱스 0 폴백(무회귀: clipId nil 인 씬은 100% 종전 경로).
    public static func resolveAnimation(model: Model3D, layerName: String?, clipId: Int? = nil) -> Int {
        guard !model.animations.isEmpty else { return -1 }
        if let cid = clipId, let i = model.animations.firstIndex(where: { $0.id == cid }) {
            return i
        }
        if let ln = layerName?.lowercased(), !ln.isEmpty,
           let i = model.animations.firstIndex(where: { $0.name.lowercased().contains(ln) }) {
            return i
        }
        if let i = model.animations.firstIndex(where: { $0.name.lowercased().contains("idle") }) { return i }
        return 0
    }
}
