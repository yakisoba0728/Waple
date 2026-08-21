import Foundation
import simd

/// 퍼펫/스켈레톤 포즈 평가(순수): 트랙 키 보간 → 본 로컬 → 계층 합성 → 스킨 행렬 → CPU 스키닝.
///
/// 실측 근거(2809885105): 트랙 첫 키가 바인드 평행이동과 일치 → 키와 바인드는 같은 공간.
/// 바인드/키를 동일한 방식(부모 체인 합성)으로 계산하면 t=0 에 스킨이 항등이 되어 좌표계 가정과
/// 무관하게 정확하다. 스킨_i = world_i(t) × bindWorld_i⁻¹.
///
/// 2026-08-21 헥스 리버스(wallpaper64.exe 2.8.42, imagebase 0x140000000)로 WE 의 스켈레톤 평가
/// 파이프라인을 성분 단위로 대조했다. 요지:
///   · WE 는 포즈를 **TRS(pos3 + quat4 + scale3, 10 float)** SoA 로 들고 다닌다.
///     바인드 시딩 0x1401fe531–0x1401fe650, 키 보간 0x1401f89a0–0x1401f8f81,
///     가중 블렌드 0x1401f9020–0x1401f97f8, 가산 0x1401f9820–0x1401fa270.
///   · 로드 시점에 키의 오일러 3축을 쿼터니언으로 굽는다(0x140264188–0x1402642ae).
///   · 회전 보간은 **nlerp + 최단호 부호보정 + 재정규화**이지 slerp 가 아니다.
///   · 로컬→월드는 `world[i] = world[parent] × local[i]`(0x1401fea63–0x1401feada).
/// 상세는 docs/re/skeleton-animation.md.
public enum PuppetPose {

    // MARK: - TRS 포즈 성분 (WE 스켈레톤의 실제 표현)

    /// 본 로컬 포즈 = 평행이동 + 쿼터니언 회전 + 스케일.
    ///
    /// WE 는 본 로컬을 행렬이 아니라 이 10 float 로 들고 있고(포즈 SoA 배열 `skel+0x230`,
    /// 본 수 `skel+0x228` — 씨딩 루프 0x1401fe2f2–0x1401fe657 에서 pos3/quat4/scale3 을
    /// 배열 0..9 에 흩어 쓴다), 레이어 블렌드도 전부 이 공간에서 한다. 행렬화는 마지막에 한 번.
    struct TRS: Equatable {
        var position: SIMD3<Float>
        /// (x, y, z, w) — 단위 쿼터니언.
        var rotation: SIMD4<Float>
        var scale: SIMD3<Float>
    }

    static let identityQuaternion = SIMD4<Float>(0, 0, 0, 1)

    static func quatDot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }

    /// 쿼터니언 정규화. 길이가 0(수치 퇴화)이면 항등 — WE 는 `rsqrtps`+뉴턴 1스텝
    /// (0x1401f8df1–0x1401f8e0b)이라 0 근처가 Inf 로 새지만, 여기선 항등으로 막는다.
    static func quatNormalize(_ q: SIMD4<Float>) -> SIMD4<Float> {
        let n2 = quatDot(q, q)
        guard n2.isFinite, n2 > 1e-20 else { return identityQuaternion }
        return q * (1 / n2.squareRoot())
    }

    static func quatMultiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
              a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
              a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
              a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    static func quatConjugate(_ q: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(-q.x, -q.y, -q.z, q.w)
    }

    /// **nlerp + 최단호 부호보정 + 재정규화** — WE 의 회전 보간 전량이 이것이다.
    ///
    /// 0x1401f8d3f–0x1401f8e1a (키 보간), 0x1401f9483–0x1401f9513 / 0x1401f9589–0x1401f9613
    /// (레이어 가중 블렌드). 구현은 분기 없는 부호 트릭이다:
    /// ```
    /// dot = Σ q0ᵢ·q1ᵢ                      ; 0x1401f8d5e–0x1401f8d6b
    /// s   = signbit(dot) XOR t             ; andps 0x140483730(-0.0) → xorps  (0x1401f8d6f/0x1401f8d77)
    /// q   = (1-t)·q0 + s·q1                ; 0x1401f8d7b–0x1401f8dae
    /// q  /= |q|                            ; rsqrtps + 뉴턴 1스텝 (0x1401f8df1–0x1401f8e0b)
    /// ```
    /// 즉 dot<0 이면 q1 을 뒤집는 대신 **가중치 t 의 부호를 뒤집는다**(수학적으로 동일).
    /// slerp 는 스켈레톤 경로에 없다 — 반증 근거는 아래 `slerpShortest` 주석.
    static func nlerpShortest(_ q0: SIMD4<Float>, _ q1: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        let s = quatDot(q0, q1) < 0 ? -t : t
        let q = q0 * (1 - t) + q1 * s
        // 정확히 반대인 두 쿼터니언을 t=0.5 로 섞으면 길이 0 — WE 도 여기선 NaN/Inf 가 나온다.
        // 렌더가 통째로 깨지므로 q0 으로 폴백(묵스킨에 준하는 방어).
        let n2 = quatDot(q, q)
        guard n2.isFinite, n2 > 1e-20 else { return q0 }
        return q * (1 / n2.squareRoot())
    }

    /// WE 의 **진짜 slerp**(0x140216070–0x140216270). 스켈레톤 애니메이션은 이걸 쓰지 않는다 —
    /// 호출자는 본 물리/IK 솔버(0x1401fdf90 SSE / 0x14021c480 AVX)뿐이다. 파리티 기준선으로만 둔다.
    /// ```
    /// dot = q0·q1
    /// if dot < 0 { q1 = -q1; dot = -dot }        ; 0x1402160df–0x1402160fc (xorps -0.0)
    /// if dot > 0x3F7FFFFE(=0.99999988f = 1 − FLT_EPSILON)  ; 상수 VA 0x140492700, 비교 0x1402160ff
    ///      → out = (1-t)·q0 + t·q1               ; **정규화 없는** 순수 lerp (0x140216116–0x14021616c)
    /// else Ω = acos(dot)                          ; 0x14021618b
    ///      out = (sin((1-t)Ω)·q0 + sin(tΩ)·q1) / sin(Ω)   ; 0x140216193–0x14021621f
    /// ```
    /// ⚠️ 과제 단서의 `0.9995f`/`0.0001f` 는 이 빌드의 slerp 상수가 **아니다**(반증: 아래 문서 참조).
    static func slerpShortest(_ q0: SIMD4<Float>, _ q1: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var b = q1
        var d = quatDot(q0, b)
        if d < 0 { b = -b; d = -d }
        // 0x3F7FFFFE = 1 − FLT_EPSILON. 이 위면 lerp 폴백(정규화 없음 — WE 그대로).
        if d > Float(bitPattern: 0x3F7F_FFFE) { return q0 * (1 - t) + b * t }
        let omega = acos(min(max(d, -1), 1))
        let s = sin(omega)
        guard abs(s) > 1e-20 else { return q0 * (1 - t) + b * t }
        return (q0 * (sin((1 - t) * omega) / s)) + (b * (sin(t * omega) / s))
    }

    /// 키의 오일러 3축 → 쿼터니언.
    ///
    /// **파일에 저장된 3축 순서는 (Z, Y, X)** 다. MDL 로더가 36B 키의 +0x0c/+0x10/+0x14 를 읽어
    /// 반각(×0.5f, 상수 VA 0x1404926c0)으로 sin/cos 한 뒤 조립하는 식(0x140264188–0x1402642ae,
    /// 두 번째 사본 0x1402644c7–0x1402645ea)을 그대로 옮기면:
    /// ```
    /// γ = key[+0x0c]·0.5, β = key[+0x10]·0.5, α = key[+0x14]·0.5
    /// w = cα·cβ·cγ + sα·sβ·sγ        ; 0x14026422e
    /// x = sα·cβ·cγ − cα·sβ·sγ        ; 0x140264250
    /// y = sα·cβ·sγ + cα·sβ·cγ        ; 0x14026427c
    /// z = cα·cβ·sγ − sα·sβ·cγ        ; 0x14026426e
    /// ```
    /// 이는 `Rz(key[+0x0c]) · Ry(key[+0x10]) · Rx(key[+0x14])` 와 항등(수치 검증 완료).
    /// 즉 파서가 (+0x0c,+0x10,+0x14) 를 (x,y,z) 로 이름 붙여 담아도 **의미는 (z,y,x)** 다.
    /// 종전 Waple 은 이 셋을 (x,y,z) 로 읽어 `Rz(.z)·Ry(.y)·Rx(.x)` 를 만들었다 — X 축과 Z 축이
    /// 뒤바뀐 상태였고, z 회전 위주인 2D 퍼펫이 화면 밖으로 접히는 결함이었다.
    ///
    /// 참고로 씬스크립트 `setLocalBoneAngles(bone, Vec3)` 은 **공개 API 답게 (x,y,z)** 다
    /// (0x14020fd38–0x14020fe09: m00 = cos(v.y)·cos(v.z) → `Rz(v.z)·Ry(v.y)·Rx(v.x)`).
    /// 뒤바뀐 것은 파일 바이트 순서지 회전 합성 순서가 아니다.
    static func rotationQuaternion(_ fileAngles: SIMD3<Float>) -> SIMD4<Float> {
        let g = fileAngles.x * 0.5   // Z (yaw)   — 파일 +0x0c
        let b = fileAngles.y * 0.5   // Y (pitch) — 파일 +0x10
        let a = fileAngles.z * 0.5   // X (roll)  — 파일 +0x14
        let ca = cos(a), sa = sin(a)
        let cb = cos(b), sb = sin(b)
        let cg = cos(g), sg = sin(g)
        return SIMD4(sa * cb * cg - ca * sb * sg,
                     sa * cb * sg + ca * sb * cg,
                     ca * cb * sg - sa * sb * cg,
                     ca * cb * cg + sa * sb * sg)
    }

    /// 단위 쿼터니언 → 회전 행렬(열 우선).
    static func quaternionMatrix(_ q: SIMD4<Float>) -> simd_float4x4 {
        let x = q.x, y = q.y, z = q.z, w = q.w
        return simd_float4x4(
            SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0),
            SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0),
            SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0),
            SIMD4(0, 0, 0, 1))
    }

    /// TRS → 로컬 행렬 `T · R · S`.
    static func trsMatrix(_ t: TRS) -> simd_float4x4 {
        var m = quaternionMatrix(t.rotation)
        m.columns.0 *= t.scale.x
        m.columns.1 *= t.scale.y
        m.columns.2 *= t.scale.z
        m.columns.3 = SIMD4(t.position.x, t.position.y, t.position.z, 1)
        return m
    }

    /// 행렬 → TRS 분해. 회전부가 직교(스케일 제거 후)·오른손이 아니면 nil —
    /// 그 본은 호출측이 종전 행렬 성분 lerp 경로로 폴백한다(스큐/거울 바인드 방어).
    static func decomposeTRS(_ m: simd_float4x4) -> TRS? {
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        // 아핀 행(w) 이 (0,0,0,1) 이 아니면 TRS 가 아니다.
        guard m.columns.0.w == 0, m.columns.1.w == 0, m.columns.2.w == 0, m.columns.3.w == 1 else { return nil }
        let sx = simd_length(c0), sy = simd_length(c1), sz = simd_length(c2)
        guard sx.isFinite, sy.isFinite, sz.isFinite, sx > 1e-6, sy > 1e-6, sz > 1e-6 else { return nil }
        let r0 = c0 / sx, r1 = c1 / sy, r2 = c2 / sz
        let tol: Float = 1e-3
        guard abs(simd_dot(r0, r1)) < tol, abs(simd_dot(r0, r2)) < tol, abs(simd_dot(r1, r2)) < tol,
              simd_dot(simd_cross(r0, r1), r2) > 0 else { return nil }
        // Shepperd — 행 우선 R[r][c] = 열 rᶜ 의 r 성분.
        let m00 = r0.x, m01 = r1.x, m02 = r2.x
        let m10 = r0.y, m11 = r1.y, m12 = r2.y
        let m20 = r0.z, m21 = r1.z, m22 = r2.z
        var q = identityQuaternion
        let tr = m00 + m11 + m22
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            q = SIMD4((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s)
        } else if m00 > m11, m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = SIMD4(0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = SIMD4((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = SIMD4((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s)
        }
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite else { return nil }
        return TRS(position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                   rotation: quatNormalize(q), scale: SIMD3(sx, sy, sz))
    }

    // MARK: - 재생 모드 / 프레임

    /// 재생 모드 시간 매핑 → 프레임(0..length 실수).
    ///
    /// WE 의 모드 문자열 해석(0x1401a8c10–0x1401a8ca9)은 딱 두 개다:
    /// ```
    /// stricmp(mode, "mirror") == 0 → flags |= 1      ; 0x1401a8c71
    /// stricmp(mode, "single") == 0 → flags |= 2      ; 0x1401a8c87
    /// 그 밖(빈 문자열 포함)         → 플래그 없음 = loop
    /// ```
    /// 그리고 시간 전진(0x1401a9f60–0x1401aa18d, `fmodf` = 0x14041d0c0):
    ///   · loop  : `T = fmodf(T, D)` (음수면 D 를 먼저 더한다)        — 0x1401aa0b9–0x1401aa0d7
    ///   · mirror: 끝에 닿으면 `T = D − fmodf(T, D)` 하고 **역방향 비트**(0x80000000) 를 세운다
    ///             (0x1401aa150–0x1401aa170), 0 을 지나면 `T = −fmodf(T,D)` 로 되접고 비트를 지운다
    ///             (0x1401aa129–0x1401aa14e). 등속에서는 2L 삼각파와 동치라 여기선 삼각파로 둔다.
    ///   · single: `T = D` 로 물리고 종료 비트(0x40000000) 를 세운다 — 0x1401aa177–0x1401aa188
    /// `D = frameCount / fps`(0x1401a8c3f), 프레임 = `T·fps`(0x1401705ac).
    ///
    /// **반증**: 종전 Waple 은 `"clamp"` 를 single 의 별칭으로 취급했지만 WE 에는 그런 분기가 없다 —
    /// `"clamp"` 모드 클립은 WE 에서 **loop** 로 돈다. 또 비교가 `stricmp` 라 대소문자를 가리지 않는다.
    static func frame(time: Float, fps: Float, length: Int, mode: String) -> Float {
        guard length > 0, fps > 0 else { return 0 }
        let f = time * fps
        let L = Float(length)
        // stricmp 동치 — "Mirror"/"SINGLE" 도 WE 는 잡는다.
        switch mode.lowercased() {
        case "mirror":
            let cycle = f.truncatingRemainder(dividingBy: 2 * L)
            return cycle <= L ? cycle : 2 * L - cycle
        case "single":
            return min(f, L)
        default:  // loop — "clamp" 를 포함해 그 밖의 모든 문자열
            return f.truncatingRemainder(dividingBy: L)
        }
    }

    /// 애니메이션 레이어의 **유효 가중치** = `blend × blendIn 램프 × blendOut 램프`.
    ///
    /// `IAnimationLayer::effectiveBlend` 0x14026c8b0–0x14026c97b 그대로:
    /// ```
    /// eps = 1.1920929e-07 (FLT_EPSILON, VA 0x1404925e0)
    /// w = blend                                        ; layer+0xcc
    /// if (flags & 4) {                                  // blendin  ; layer+0xd0 비트2
    ///     if (min(D, bt) > eps) { r = min(D·0.5, bt); f = min(T / r, 1) } else f = 1
    ///     w *= f
    /// }
    /// if (flags & 8) {                                  // blendout ; layer+0xd0 비트3
    ///     if (min(D, bt) > eps) { r = min(D·0.5, bt); g = (D − T)/r; w *= min(g, 1) }
    /// }
    /// ```
    /// `D` = 클립 길이(초, layer+0x100), `T` = 현재 시간(layer+0xfc), `bt` = blendtime(layer+0x18c,
    /// 기본 0.5f — 생성자 0x14026c7af). 램프 길이가 `min(D/2, bt)` 인 게 핵심(짧은 클립에서
    /// 인/아웃이 겹치지 않게 하는 장치). blendin 은 한 번 1 에 닿으면 플래그가 꺼진다(0x14026c923).
    public static func layerWeight(blend: Float, blendIn: Bool, blendOut: Bool,
                                   blendTime: Float = 0.5, duration: Float, time: Float) -> Float {
        let eps: Float = 1.1920929e-07
        var w = blend
        if blendIn {
            var f: Float = 1
            if min(duration, blendTime) > eps {
                let r = min(duration * 0.5, blendTime)
                f = min(time / r, 1)
            }
            w *= f
        }
        if blendOut, min(duration, blendTime) > eps {
            let r = min(duration * 0.5, blendTime)
            w *= min((duration - time) / r, 1)
        }
        return w
    }

    // MARK: - 키 샘플링

    /// 키 → 로컬 행렬(T·R·S).
    static func localMatrix(_ k: PuppetModel.Key) -> simd_float4x4 {
        localMatrix(position: k.position, angles: k.angles, scale: k.scale)
    }

    /// 성분 → 로컬 행렬. 2D 퍼펫·3D 모델(Model3DPose) 공용 — 회전 규약 단일 소스.
    /// `angles` 는 **파일 바이트 순서**(+0x0c,+0x10,+0x14) 그대로다 — 의미는 (Z, Y, X).
    /// 자세한 근거는 `rotationQuaternion` 주석 참조.
    static func localMatrix(position: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        trsMatrix(TRS(position: position, rotation: rotationQuaternion(angles), scale: scale))
    }

    /// 트랙 키 보간(프레임당 1키 규약) → TRS. 빈 트랙 → nil.
    ///
    /// 프레임 인덱스/보간계수는 `Playback::sample` 0x140170580–0x1401705f6:
    /// ```
    /// i = clamp(trunc(T/fd), 0, frameCount-1)   ; fd = 1/fps
    /// j = min(i+1, frameCount)
    /// t = fmodf(T, fd) / fd
    /// ```
    /// (여기선 트랙 길이로 클램프한다 — 헤더 frameCount 가 트랙 키 수와 어긋난 손상 데이터에서
    ///  WE 는 범위 밖을 읽지만 우리는 마지막 키로 물린다.)
    /// 위치·스케일은 성분 lerp, 회전은 nlerp(최단호 + 재정규화) — 0x1401f8c67–0x1401f8e1a.
    static func sampledTRS(_ keys: [PuppetModel.Key], frame: Float) -> TRS? {
        guard !keys.isEmpty else { return nil }
        let f = max(0, min(frame, Float(keys.count - 1)))
        let i = Int(f)
        let j = min(i + 1, keys.count - 1)
        let t = f - Float(i)
        let a = keys[i], b = keys[j]
        return TRS(position: a.position + (b.position - a.position) * t,
                   rotation: nlerpShortest(rotationQuaternion(a.angles), rotationQuaternion(b.angles), t),
                   scale: a.scale + (b.scale - a.scale) * t)
    }

    /// 트랙 키 보간 → 로컬 행렬. 빈 트랙 → nil(바인드 로컬 사용).
    static func sampledLocal(_ keys: [PuppetModel.Key], frame: Float) -> simd_float4x4? {
        sampledTRS(keys, frame: frame).map(trsMatrix)
    }

    /// F442: 퇴화(영스케일) 행렬의 .inverse 는 NaN/Inf 를 만들어 스킨 행렬 전체로 번진다(Metal 은 NaN
    /// 정점을 크래시 없이 쓰레기 렌더로 처리). 행렬식이 0/비유한이면 항등으로 폴백(묵스킨에 준함).
    static func safeInverse(_ m: simd_float4x4) -> simd_float4x4 {
        let d = m.determinant
        guard d.isFinite, abs(d) > 1e-12 else { return matrix_identity_float4x4 }
        return m.inverse
    }

    /// 본별 스킨 행렬. animation 인덱스가 범위 밖이면 항등(정지 포즈).
    public static func skinMatrices(model: PuppetModel, animation: Int, time: Float) -> [simd_float4x4] {
        let n = model.bones.count
        guard n > 0 else { return [] }
        let bindWorld = bindWorlds(model)
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

    /// TRS 성분 블렌드(절대/오버라이드) — 위치·스케일 lerp, 회전 nlerp(최단호).
    /// WE 가중 블렌드 0x1401f9020–0x1401f97f8 (스칼라 채널은 0x140178e00 lerp 두 번).
    static func mixTRS(_ a: TRS, _ b: TRS, _ t: Float) -> TRS {
        TRS(position: a.position + (b.position - a.position) * t,
            rotation: nlerpShortest(a.rotation, b.rotation, t),
            scale: a.scale + (b.scale - a.scale) * t)
    }

    /// 두 로컬 행렬 성분별 lerp — TRS 분해가 불가능한 바인드(스큐/거울) 전용 폴백 경로.
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

    /// 본 월드 행렬(모델공간 — 스킨의 bindWorld⁻¹ 곱 이전). 빈 layers = 바인드 포즈.
    /// 부착점(attachment) 프레임 산출용.
    ///
    /// 합성 규약(실측):
    ///   1. 본 로컬을 **바인드 TRS 로 시딩**한다 — WE 도 매 프레임 포즈 SoA 를 본의 레스트 TRS 로
    ///      채우고 시작한다(0x1401fe2f2–0x1401fe657).
    ///   2. `layers` 순서대로 누적한다. **가중치 정규화는 없다** — 레이어 가중치 합이 1을 넘든
    ///      말든 각 레이어가 순서대로 현재 포즈를 자기 포즈 쪽으로 끌어당길 뿐이다
    ///      (0x1401fed50 루프 → 0x1401f9020 호출).
    ///   3. **그 레이어가 이 본을 건드리지 않으면 건너뛴다.** WE 는 본별 마스크를 `blendvps` 로
    ///      적용해(마스크 로드 0x1401f8c7b, 선택 0x1401f8c9f) 미애니 본의 값을 보존한다.
    ///      종전 Waple 은 빈 트랙을 바인드로 간주해 앞 레이어 결과를 바인드 쪽으로 되끌었다.
    ///   4. weight == 1 이고 가산이 아니면 WE 는 아예 덮어쓰기 경로(0x1401f89a0)로 빠진다 —
    ///      `mixTRS(_, _, 1)` 과 동치라 여기선 분기하지 않는다(부호 트릭 상 nlerp(t=1)=q1).
    /// C④: overrideFrames[i] 가 non-nil 이면 그 레이어의 프레임을 time×rate 순간위상 대신 그대로 쓴다.
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
            let local: simd_float4x4
            if var pose = decomposeTRS(b.bind) {
                for (li, L) in layers.enumerated() {
                    guard L.anim >= 0, L.anim < model.animations.count else { continue }
                    let tracks = model.animations[L.anim].tracks
                    guard i < tracks.count, let clip = sampledTRS(tracks[i], frame: frames[li]) else { continue }
                    if L.additive {
                        guard let ref = sampledTRS(tracks[i], frame: 0) else { continue }
                        pose = addTRS(pose, clip: clip, reference: ref, weight: L.weight)
                    } else {
                        pose = mixTRS(pose, clip, L.weight)
                    }
                }
                local = trsMatrix(pose)
            } else {
                // 폴백: 바인드가 TRS 로 분해되지 않는다(스큐/거울/퇴화) — 종전 행렬 성분 lerp.
                var m = b.bind
                for (li, L) in layers.enumerated() {
                    guard L.anim >= 0, L.anim < model.animations.count else { continue }
                    let tracks = model.animations[L.anim].tracks
                    guard i < tracks.count, let clip = sampledLocal(tracks[i], frame: frames[li]) else { continue }
                    if L.additive {
                        let ref = sampledLocal(tracks[i], frame: 0) ?? b.bind
                        m = mixLocal(matrix_identity_float4x4, clip * safeInverse(ref), L.weight) * m
                    } else {
                        m = mixLocal(m, clip, L.weight)
                    }
                }
                local = m
            }
            let p = Int(b.parent)
            world[i] = (b.parent >= 0 && p < i) ? world[p] * local : local
        }
        return world
    }

    /// 가산 레이어 합성: 기준(클립 프레임0) 대비 델타를 weight 배로 현재 포즈에 얹는다.
    /// ⚠️ WE 의 가산 경로(0x1401f9820–0x1401fa270: 위치 `subps` 델타 + 쿼터니언 켤레곱 `xorps`
    /// 0x1401f9e48/0x1401f9e60/0x1401f9e79 + nlerp 0x1401f9f3b)의 **구조**는 확인했으나 기준 포즈가
    /// 클립 프레임0 인지 본 레스트인지는 미확정 — 종전 Waple 규약(클립 프레임0)을 유지한다.
    static func addTRS(_ base: TRS, clip: TRS, reference ref: TRS, weight: Float) -> TRS {
        let delta = quatMultiply(clip.rotation, quatConjugate(ref.rotation))
        let scaleRatio = SIMD3<Float>(ref.scale.x != 0 ? clip.scale.x / ref.scale.x : 1,
                                      ref.scale.y != 0 ? clip.scale.y / ref.scale.y : 1,
                                      ref.scale.z != 0 ? clip.scale.z / ref.scale.z : 1)
        return TRS(position: base.position + (clip.position - ref.position) * weight,
                   rotation: nlerpShortest(base.rotation, quatMultiply(delta, base.rotation), weight),
                   scale: base.scale * (SIMD3<Float>(1, 1, 1) + (scaleRatio - SIMD3<Float>(1, 1, 1)) * weight))
    }

    /// 다층 animationlayers 캐스케이드 블렌드 스킨 행렬(순수). `layers` 순서 = 합성 순서.
    /// 상세 규약은 `worldMatrices` 주석. 단일 절대 레이어 weight=1 → `skinMatrices(animation:)` 와 동일.
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

    /// CPU 스키닝: p' = Σ wᵏ · skin[idxᵏ] · p.
    ///
    /// ⚠️ **반증 주의**: WE 는 가중치를 정규화하지 **않는다**. 셰이더가 원시 가중합을 그대로 쓴다
    /// (`assets/shaders/base/model_vertex_v1.h:147-150`,`assets/shaders/genericimage3.vert:139-142`:
    ///  `mul(vec4(p,1), g_Bones[i.x]*w.x + g_Bones[i.y]*w.y + g_Bones[i.z]*w.z + g_Bones[i.w]*w.w)`).
    /// 즉 합이 1이 아닌 데이터는 WE 에서 축소/확대되어 렌더된다. 여기서 wsum 으로 나누는 것은
    /// Waple 자체 셰이더(Mesh3DShaders.mv_skin)와의 정합을 위한 것이지 WE 파리티가 아니다 —
    /// 실물 자산은 리소스 컴파일러가 정규화해 두므로 차이가 드러나지 않는다. 가중치 합 0 → 원위치.
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
