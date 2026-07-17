import simd
import WapleCore

/// 3D 씬 카메라/변환 순수 함수(TDD). Metal NDC(z 0..1) 규약.
/// 실측 확정 규약(2026-07-03, 3662790108 태양계 / 3737268876 젤다 렌더 vs preview 판정 — SceneRenderer
/// build3D 의 주석 참조): 뷰는 우수(RH, 전방 -Z), fov 는 세로축, 오일러는 R = Rz·Ry·Rx (X 먼저 적용).
enum Scene3DMath {
    /// gluLookAt 동형(우수 좌표, 카메라 전방 = 뷰 -Z). eye 는 원점으로, center 는 -Z 축 위로 사상.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)             // 전방
        let s = simd_normalize(simd_cross(f, up))        // 우측
        let u = simd_cross(s, f)                         // 상방(직교화)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// 원근 투영(세로 화각 도(度), Metal 뎁스 0..1). 뷰 z=-near → ndc z 0, z=-far → 1.
    static func perspective(fovYDegrees: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYDegrees * .pi / 180 / 2)
        let x = y / aspect
        let zz = farZ / (nearZ - farZ)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, zz, -1),
            SIMD4<Float>(0, 0, nearZ * zz, 0)))
    }

    /// clip-space 병진행렬. viewProj 에 좌승(clipTranslation(s)·viewProj)하면 (s·w) 가 clip.xy 에 더해져
    /// 원근분할 후 전 정점이 depth 무관하게 ndc 만큼 병진한다 — camerashake 3D 전역 카메라 지터를
    /// 셰이더 무수정으로 viewProj 한 곳에 적용(2D shakeOffset 의 3D 동형). s=.zero → 항등(무회귀 가드).
    static func clipTranslation(_ ndc: SIMD2<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(ndc.x, ndc.y, 0, 1)))
    }

    /// 오브젝트 모델행렬 = T(origin) · Rz(z)·Ry(y)·Rx(x) · S(scale). angles 라디안.
    /// 오일러 순서 실측(2026-07-03): 실물 회전의 절대다수가 단축(yaw 전용)이라 순서 무관하게 동일 —
    /// 유일한 판정 지점인 짐벌 표현 (π, θ, -π)(젤다 Rupee Root/happy_mask_salesman)은 순수 yaw(π-θ)와
    /// 동치여야 하며 Rz·Ry·Rx 가 이를 만족(단 Rx·Ry·Rz 도 이 케이스에선 동치 — 대칭성).
    /// 다축 혼합 회전(moon)은 이 코퍼스의 카메라 밖이라 미판정. ZYX 채택 근거: 위 동치 + 젤다/소닉
    /// 전 오브젝트 배치가 preview 구도와 일치. 반례 실물 발견 시 이 함수 하나만 교체하면 된다.
    static func modelMatrix(origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        let (sx, cx) = (sin(angles.x), cos(angles.x))
        let (sy, cy) = (sin(angles.y), cos(angles.y))
        let (sz, cz) = (sin(angles.z), cos(angles.z))
        // R = Rz·Ry·Rx (열우선 — 열 c 는 R 의 c번째 열)
        let r00 = cz * cy, r01 = cz * sy * sx - sz * cx, r02 = cz * sy * cx + sz * sx
        let r10 = sz * cy, r11 = sz * sy * sx + cz * cx, r12 = sz * sy * cx - cz * sx
        let r20 = -sy,     r21 = cy * sx,                r22 = cy * cx
        return simd_float4x4(columns: (
            SIMD4<Float>(r00 * scale.x, r10 * scale.x, r20 * scale.x, 0),
            SIMD4<Float>(r01 * scale.y, r11 * scale.y, r21 * scale.y, 0),
            SIMD4<Float>(r02 * scale.z, r12 * scale.z, r22 * scale.z, 0),
            SIMD4<Float>(origin.x, origin.y, origin.z, 1)))
    }

    /// 비균등 스케일에서도 노멀을 올바르게 월드 공간으로 옮기는 inverse-transpose 행렬.
    /// 0 스케일/비유한 입력은 역행렬이 NaN이 되므로 항등으로 폴백해 프레임 전체 오염을 막는다.
    static func normalMatrix4x4(_ model: simd_float4x4) -> simd_float4x4 {
        let upper = simd_float3x3(columns: (
            SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)))
        let determinant = simd_determinant(upper)
        guard determinant.isFinite, abs(determinant) > 1e-8 else {
            return matrix_identity_float4x4
        }
        let normal = simd_transpose(simd_inverse(upper))
        guard (0..<3).allSatisfy({ column in
            normal[column].x.isFinite && normal[column].y.isFinite && normal[column].z.isFinite
        }) else {
            return matrix_identity_float4x4
        }
        return simd_float4x4(columns: (
            SIMD4(normal.columns.0.x, normal.columns.0.y, normal.columns.0.z, 0),
            SIMD4(normal.columns.1.x, normal.columns.1.y, normal.columns.1.z, 0),
            SIMD4(normal.columns.2.x, normal.columns.2.y, normal.columns.2.z, 0),
            SIMD4(0, 0, 0, 1)))
    }

    /// 계층 합성용 노드(트랜스폼 + 부모 + 정적 가시성).
    struct Node {
        let origin: SIMD3<Float>
        let angles: SIMD3<Float>
        let scale: SIMD3<Float>
        let parent: Int?
        let visible: Bool
    }

    /// id 노드의 월드행렬(부모 체인 합성)과 유효 가시성(조상 중 하나라도 false → false).
    /// 사이클/미지 id 는 안전 종단: 사이클이면 그 지점에서 체인 중단(자기 로컬까지만), 미지 부모는 루트 취급.
    static func worldMatrix(id: Int, nodes: [Int: Node]) -> (matrix: simd_float4x4, visible: Bool)? {
        guard let node = nodes[id] else { return nil }
        var m = modelMatrix(origin: node.origin, angles: node.angles, scale: node.scale)
        var visible = node.visible
        var seen: Set<Int> = [id]
        var pid = node.parent
        while let p = pid, !seen.contains(p), let pn = nodes[p] {
            seen.insert(p)
            m = modelMatrix(origin: pn.origin, angles: pn.angles, scale: pn.scale) * m
            visible = visible && pn.visible
            pid = pn.parent
        }
        return (m, visible)
    }

    /// SceneDocument 의 3D 오브젝트+그룹 노드 → id 인덱스 노드 맵(월드행렬 합성 입력).
    static func nodeMap(objects: [SceneObject3D], groups: [SceneNode3D]) -> [Int: Node] {
        var map: [Int: Node] = [:]
        for g in groups {
            map[g.id] = Node(origin: SIMD3(g.origin.x, g.origin.y, g.origin.z),
                             angles: SIMD3(g.angles.x, g.angles.y, g.angles.z),
                             scale: SIMD3(g.scale.x, g.scale.y, g.scale.z),
                             parent: g.parent, visible: g.visible)
        }
        for o in objects {  // 모델 오브젝트도 다른 모델의 부모가 될 수 있다(Sonic BoostModel → RioSonic).
            map[o.id] = Node(origin: SIMD3(o.origin.x, o.origin.y, o.origin.z),
                             angles: SIMD3(o.angles.x, o.angles.y, o.angles.z),
                             scale: SIMD3(o.scale.x, o.scale.y, o.scale.z),
                             parent: o.parent, visible: true)
        }
        return map
    }
}
