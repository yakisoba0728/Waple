import XCTest
import simd
@testable import WapleCore

/// WE 스켈레톤/퍼펫 평가 파리티 — wallpaper64.exe 2.8.42(imagebase 0x140000000) 헥스 리버스 대조.
/// 근거 VA 는 각 테스트 주석에. 배경 문서: docs/re/skeleton-animation.md.
final class PuppetPoseWEParityTests: XCTestCase {

    private func rotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let m = PuppetPose.quaternionMatrix(q)
        let r = m * SIMD4(v.x, v.y, v.z, 0)
        return SIMD3(r.x, r.y, r.z)
    }

    // MARK: - 키 각 3축의 파일 순서 (X, Y, Z)

    /// MDL 로더는 36B 키의 +0x0c/+0x10/+0x14 를 반각(0.5f @ 0x1404926c0)으로 sin·cos 해
    /// 포즈 SoA 슬롯 3/4/5/6 에 굽는다(0x140264188–0x1402642ae). 그 슬롯의 성분 순서는
    /// **(w, x, y, z)** 이고 — 같은 SoA 를 본 레스트로 시딩하는 0x1401fe2f2–0x1401fe657 이
    /// 행렬→쿼터니언 0x140215730 의 출력을 슬롯 3,4,5,6 순으로 흩어 쓰는데 그 함수는
    /// trace 분기(0x14021590b–0x140215934)에서 스칼라부 `0.5·sqrt(1+trace)` 를 첫 칸에 쓴다 —
    /// 대입하면 결과는 `Rz(+0x14)·Ry(+0x10)·Rx(+0x0c)`, 즉 **파일 순서는 (X, Y, Z)** 다.
    ///
    /// 회귀 가드: 커밋 18a7ae6 이 슬롯 순서를 (w,z,y,x)로 가정해 X·Z 를 맞바꿔 놨었다.
    func testKeyAngleTripleIsFileOrderXYZ() {
        let t: Float = .pi / 2
        // 첫 슬롯 = X(roll): +y → +z
        let qx = PuppetPose.rotationQuaternion(SIMD3(t, 0, 0))
        let vx = rotate(qx, SIMD3(0, 1, 0))
        XCTAssertEqual(vx.x, 0, accuracy: 1e-5)
        XCTAssertEqual(vx.y, 0, accuracy: 1e-5)
        XCTAssertEqual(vx.z, 1, accuracy: 1e-5, "파일 첫 각 슬롯(+0x0c)은 X 회전")

        // 가운데 슬롯 = Y(pitch): +z → +x
        let qy = PuppetPose.rotationQuaternion(SIMD3(0, t, 0))
        let vy = rotate(qy, SIMD3(0, 0, 1))
        XCTAssertEqual(vy.x, 1, accuracy: 1e-5, "파일 두 번째 각 슬롯(+0x10)은 Y 회전")
        XCTAssertEqual(vy.y, 0, accuracy: 1e-5)
        XCTAssertEqual(vy.z, 0, accuracy: 1e-5)

        // 마지막 슬롯 = Z(yaw): +x → +y
        let qz = PuppetPose.rotationQuaternion(SIMD3(0, 0, t))
        let vz = rotate(qz, SIMD3(1, 0, 0))
        XCTAssertEqual(vz.x, 0, accuracy: 1e-5)
        XCTAssertEqual(vz.y, 1, accuracy: 1e-5, "파일 세 번째 각 슬롯(+0x14)은 Z 회전")
        XCTAssertEqual(vz.z, 0, accuracy: 1e-5)
    }

    /// 굽힌 쿼터니언의 행렬 == `Rz(a[2])·Ry(a[1])·Rx(a[0])`. (헥스 식과 수치 항등 확인용 고정점)
    func testRotationQuaternionEqualsRzRyRxOfFileOrder() {
        func rz(_ a: Float) -> simd_float4x4 {
            let c = cos(a), s = sin(a)
            return simd_float4x4(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        }
        func ry(_ a: Float) -> simd_float4x4 {
            let c = cos(a), s = sin(a)
            return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
        }
        func rx(_ a: Float) -> simd_float4x4 {
            let c = cos(a), s = sin(a)
            return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
        }
        let a = SIMD3<Float>(0.3, -0.7, 1.1)   // 파일 순서 (+0x0c, +0x10, +0x14) = (x, y, z)
        let fromQuat = PuppetPose.quaternionMatrix(PuppetPose.rotationQuaternion(a))
        let expected = rz(a.z) * ry(a.y) * rx(a.x)
        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(fromQuat[c][r], expected[c][r], accuracy: 1e-5, "열\(c) 행\(r)")
            }
        }
    }

    /// 엔진의 굽기 식을 **슬롯 순서까지 그대로** 옮겨 대조한다(디스어셈블 재현 고정점).
    /// 슬롯 하나만 자리를 바꿔도 여기서 깨진다 — 커밋 18a7ae6 의 오류가 정확히 그 부류였다.
    func testBakeMatchesEngineSlotExpressions() {
        for (p, q, r) in [(Float(0.3), Float(-0.7), Float(1.1)),
                          (Float(-2.0), Float(0.45), Float(2.7)),
                          (Float(1.9), Float(-1.3), Float(-0.2))] {
            // 0x140264188–0x1402642ae: a = key[+0x14]·0.5, b = key[+0x10]·0.5, g = key[+0x0c]·0.5
            let a = r * 0.5, b = q * 0.5, g = p * 0.5
            let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b), cg = cos(g), sg = sin(g)
            let slot3 = ca * cb * cg + sa * sb * sg    // addss 0x14026422e → store 0x140264244
            let slot4 = ca * cb * sg - sa * sb * cg    // subss 0x14026426e → store 0x140264277
            let slot5 = sa * cb * sg + ca * sb * cg    // addss 0x14026427c → store 0x140264291
            let slot6 = sa * cb * cg - ca * sb * sg    // subss 0x140264250 → store 0x1402642ae
            // 슬롯 3..6 = (w, x, y, z) — 근거는 rotationQuaternion 주석(0x1401fe2f2 / 0x140215730).
            let engine = SIMD4<Float>(slot4, slot5, slot6, slot3)
            let ours = PuppetPose.rotationQuaternion(SIMD3(p, q, r))
            XCTAssertEqual(abs(PuppetPose.quatDot(engine, ours)), 1, accuracy: 1e-5,
                           "엔진 굽기 식과 불일치 (\(p), \(q), \(r))")
        }
    }

    /// 씬스크립트 `setLocalBoneAngles(bone, Vec3)` 0x14020fce0 은 Vec3 를 (x,y,z) 로 읽어
    /// 열 우선 행렬을 만든다 — 0x14020fe09/0x14020fe2b/0x14020fe31 이 각각
    /// `m[0]=cos(v.y)·cos(v.z)`, `m[1]=cos(v.y)·sin(v.z)`, `m[2]=−sin(v.y)`.
    /// 파일 규약이 API 규약과 **같다**는 교차 확인(둘이 어긋난다는 종전 주장의 반증).
    func testPublicApiEulerConventionMatchesFileConvention() {
        let v = SIMD3<Float>(0.37, -0.82, 1.24)
        let m = PuppetPose.quaternionMatrix(PuppetPose.rotationQuaternion(v))
        XCTAssertEqual(m[0][0], cos(v.y) * cos(v.z), accuracy: 1e-5, "m00 = cos(v.y)·cos(v.z)")
        XCTAssertEqual(m[0][1], cos(v.y) * sin(v.z), accuracy: 1e-5, "m10 = cos(v.y)·sin(v.z)")
        XCTAssertEqual(m[0][2], -sin(v.y), accuracy: 1e-5, "m20 = −sin(v.y)")
        XCTAssertEqual(m[2][2], cos(v.x) * cos(v.y), accuracy: 1e-5, "m22 = cos(v.x)·cos(v.y)")
        XCTAssertEqual(m[1][2], sin(v.x) * cos(v.y), accuracy: 1e-5, "m21 = sin(v.x)·cos(v.y)")
    }

    // MARK: - 회전 보간: nlerp + 최단호

    /// 키 보간은 오일러 성분 lerp 가 아니라 쿼터니언 nlerp 다(0x1401f8d3f–0x1401f8e1a).
    /// +170° 와 −170° 사이는 **최단호(20°, 180° 를 지나감)** 로 가야 한다 — 오일러 lerp 였다면
    /// 중간에 0°(정반대 방향으로 340° 를 도는 경로) 가 나온다.
    func testKeyInterpolationTakesShortestArcNotEulerLerp() {
        let d2r: Float = .pi / 180
        let k0 = PuppetModel.Key(position: .zero, angles: SIMD3(0, 0, 170 * d2r), scale: SIMD3(1, 1, 1))
        let k1 = PuppetModel.Key(position: .zero, angles: SIMD3(0, 0, -170 * d2r), scale: SIMD3(1, 1, 1))
        guard let mid = PuppetPose.sampledTRS([k0, k1], frame: 0.5) else { return XCTFail("샘플 실패") }
        let v = rotate(mid.rotation, SIMD3(1, 0, 0))
        XCTAssertEqual(v.x, -1, accuracy: 1e-4, "최단호 중간 = 180°")
        XCTAssertEqual(v.y, 0, accuracy: 1e-4)
        // 오일러 성분 lerp 였다면 (170 + −170)/2 = 0° → v.x == +1 이 나왔다(회귀 가드).
    }

    /// t=0/1 은 정확히 양 끝 키(부호 트릭 상 −q 가 나와도 회전은 동일).
    func testNlerpEndpointsAreExactRotations() {
        let d2r: Float = .pi / 180
        let a = PuppetPose.rotationQuaternion(SIMD3(0, 0, 30 * d2r))
        let b = PuppetPose.rotationQuaternion(SIMD3(0, 0, -160 * d2r))
        let m0 = PuppetPose.quaternionMatrix(PuppetPose.nlerpShortest(a, b, 0))
        let m1 = PuppetPose.quaternionMatrix(PuppetPose.nlerpShortest(a, b, 1))
        let ea = PuppetPose.quaternionMatrix(a), eb = PuppetPose.quaternionMatrix(b)
        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(m0[c][r], ea[c][r], accuracy: 1e-5)
                XCTAssertEqual(m1[c][r], eb[c][r], accuracy: 1e-5)
            }
        }
    }

    /// nlerp 결과는 항상 단위 쿼터니언(재정규화 — WE 는 rsqrtps+뉴턴 0x1401f8df1–0x1401f8e0b).
    func testNlerpResultIsUnitLength() {
        let d2r: Float = .pi / 180
        let a = PuppetPose.rotationQuaternion(SIMD3(0, 0, 0))
        let b = PuppetPose.rotationQuaternion(SIMD3(120 * d2r, 40 * d2r, -70 * d2r))
        for i in 0...10 {
            let q = PuppetPose.nlerpShortest(a, b, Float(i) / 10)
            XCTAssertEqual(PuppetPose.quatDot(q, q).squareRoot(), 1, accuracy: 1e-5)
        }
    }

    /// WE 의 slerp(0x140216070)는 스켈레톤 경로가 **아니라** 본 물리/IK 에서만 쓰인다.
    /// 파리티 기준선으로만 보존하되, 임계 상수(0x3F7FFFFF @ VA 0x140492700)와 분기 구조를 고정한다.
    func testSlerpBaselineThresholdAndEndpoints() {
        XCTAssertEqual(Float(bitPattern: 0x3F7F_FFFE), 1 - Float.ulpOfOne, accuracy: 0,
                       "VA 0x140492700 = 0x3F7FFFFE = 1 − FLT_EPSILON — 단서의 0.9995f 가 아니다")
        XCTAssertNotEqual(Float(bitPattern: 0x3F7F_FFFE), 0.9995)
        let d2r: Float = .pi / 180
        let a = PuppetPose.rotationQuaternion(SIMD3(0, 0, 0))
        let b = PuppetPose.rotationQuaternion(SIMD3(0, 0, 90 * d2r))
        // 끝점은 nlerp 와 동일.
        for t in [Float(0), Float(1)] {
            let s = PuppetPose.slerpShortest(a, b, t), n = PuppetPose.nlerpShortest(a, b, t)
            XCTAssertEqual(abs(PuppetPose.quatDot(s, n)), 1, accuracy: 1e-4)
        }
        // 중간에서는 slerp 가 균일 각속도라 nlerp 와 값이 다르다(둘이 같으면 구현이 뒤바뀐 것).
        let sm = PuppetPose.slerpShortest(a, b, 0.25)
        let nm = PuppetPose.nlerpShortest(a, b, 0.25)
        XCTAssertGreaterThan(abs(1 - abs(PuppetPose.quatDot(sm, nm))), 1e-6,
                             "slerp 와 nlerp 는 중간값이 달라야 한다")
        // 거의 평행하면(dot > 0x3F7FFFFE) WE 는 **정규화 없는 순수 lerp** 로 빠진다
        // (0x140216114 jbe → 0x140216116…0x14021616c). 그 분기가 살아 있는지 식으로 대조한다.
        let c = PuppetPose.rotationQuaternion(SIMD3(0, 0, 0.0002))
        XCTAssertGreaterThan(PuppetPose.quatDot(a, c), Float(bitPattern: 0x3F7F_FFFE))
        let lerped = PuppetPose.slerpShortest(a, c, 0.5)
        let raw = a * 0.5 + c * 0.5
        XCTAssertEqual(lerped.x, raw.x, accuracy: 0, "정규화 없는 lerp 그대로")
        XCTAssertEqual(lerped.w, raw.w, accuracy: 0)
    }

    // MARK: - 재생 모드

    /// WE 는 모드 문자열을 `stricmp` 로 "mirror"/"single" 딱 둘만 본다(0x1401a8c71/0x1401a8c87).
    /// 그 밖은 전부 loop — **"clamp" 도 loop 다**(종전 Waple 은 single 별칭으로 취급 → 반증·수정).
    func testUnknownModeIncludingClampLoops() {
        // length=2, fps=10 → 주기 0.2s. t=0.25s → f=2.5 → loop 면 0.5, clamp 면 2.0.
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "clamp"), 0.5, accuracy: 1e-5,
                       "\"clamp\" 는 WE 에 없는 모드 — loop 로 돈다")
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "loop"), 0.5, accuracy: 1e-5)
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: ""), 0.5, accuracy: 1e-5)
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "single"), 2.0, accuracy: 1e-5)
    }

    /// 비교가 `stricmp`(0x1402c10d0) 라 대소문자를 가리지 않는다.
    func testModeMatchingIsCaseInsensitive() {
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "SINGLE"), 2.0, accuracy: 1e-5)
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "Single"), 2.0, accuracy: 1e-5)
        // mirror: f=2.5 → 2L=4 주기 폴드 → 4-2.5 = 1.5
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "Mirror"), 1.5, accuracy: 1e-5)
        XCTAssertEqual(PuppetPose.frame(time: 0.25, fps: 10, length: 2, mode: "MIRROR"), 1.5, accuracy: 1e-5)
    }

    // MARK: - 레이어 유효 가중치 (blendin / blendout)

    /// `IAnimationLayer::effectiveBlend` 0x14026c8b0–0x14026c97b:
    /// 램프 길이는 `min(duration·0.5, blendtime)`, 인/아웃 각각 1 로 클램프, 최종 곱.
    func testLayerWeightBlendInOutRamps() {
        // duration 4s, blendtime 0.5 → 램프 = min(2, 0.5) = 0.5s
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: true, blendOut: false,
                                              blendTime: 0.5, duration: 4, time: 0.25), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: true, blendOut: false,
                                              blendTime: 0.5, duration: 4, time: 0.5), 1, accuracy: 1e-6)
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: true, blendOut: false,
                                              blendTime: 0.5, duration: 4, time: 3.0), 1, accuracy: 1e-6,
                       "1 을 넘으면 클램프")
        // blendout: (D - T)/램프
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: false, blendOut: true,
                                              blendTime: 0.5, duration: 4, time: 3.75), 0.5, accuracy: 1e-6)
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: false, blendOut: true,
                                              blendTime: 0.5, duration: 4, time: 1.0), 1, accuracy: 1e-6)
        // 램프가 duration·0.5 로 잘리는 경우: duration 0.4s, blendtime 0.5 → 램프 = 0.2s
        XCTAssertEqual(PuppetPose.layerWeight(blend: 1, blendIn: true, blendOut: false,
                                              blendTime: 0.5, duration: 0.4, time: 0.1), 0.5, accuracy: 1e-6,
                       "램프는 min(D/2, blendtime)")
        // blend 는 그대로 곱해진다 + 인/아웃 동시
        XCTAssertEqual(PuppetPose.layerWeight(blend: 0.5, blendIn: true, blendOut: true,
                                              blendTime: 0.5, duration: 4, time: 0.25), 0.25, accuracy: 1e-6)
        // duration 0 → 램프 계산 스킵(FLT_EPSILON 게이트, VA 0x1404925e0) → blend 그대로.
        XCTAssertEqual(PuppetPose.layerWeight(blend: 0.8, blendIn: true, blendOut: true,
                                              blendTime: 0.5, duration: 0, time: 0), 0.8, accuracy: 1e-6)
    }

    // MARK: - 캐스케이드 합성

    private func oneBoneModel(_ clips: [[PuppetModel.Key]], bind: simd_float4x4 = matrix_identity_float4x4,
                              vertex: SIMD3<Float> = SIMD3(10, 0, 0)) -> PuppetModel {
        var m = PuppetModel(material: "m",
                            vertices: [.init(position: vertex, boneIndices: SIMD4(0, 0, 0, 0),
                                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0, 0))],
                            indices: [0])
        m.bones = [.init(name: "root", parent: -1, bind: bind)]
        m.animations = clips.enumerated().map {
            .init(name: "c\($0.offset)", mode: "single", fps: 10, lengthFrames: 1, tracks: [$0.element])
        }
        return m
    }

    /// WE 는 레이어가 **건드리지 않는 본은 건너뛴다**(본별 마스크 blendvps — 로드 0x1401f8c7b,
    /// 선택 0x1401f8c9f). 종전 Waple 은 빈 트랙을 바인드로 간주해 앞 레이어 결과를 바인드로 되끌었다.
    func testCascadeSkipsBonesALayerDoesNotAnimate() {
        var m = oneBoneModel([[PuppetModel.Key(position: SIMD3(100, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))]],
                             vertex: .zero)
        // 두 번째 클립은 이 본에 트랙이 없다(빈 배열).
        m.animations.append(.init(name: "empty", mode: "single", fps: 10, lengthFrames: 1, tracks: [[]]))
        let layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)] =
            [(0, false, 1, 1), (1, false, 1, 1)]
        let p = PuppetPose.skinnedPositions(
            model: m, matrices: PuppetPose.blendedSkinMatrices(model: m, layers: layers, time: 0)).first!
        XCTAssertEqual(p.x, 100, accuracy: 1e-4,
                       "트랙 없는 레이어는 그 본을 건너뛴다 — 종전엔 바인드(0)로 되끌려 0 이 나왔다")
    }

    /// 절대 레이어 가중 블렌드의 **회전**은 nlerp 다(0x1401f9589–0x1401f9613) — 행렬 성분 lerp 가
    /// 아니다. Rz(0) 과 Rz(90°) 를 0.5 로 섞으면 정확히 Rz(45°)(길이 보존), 행렬 lerp 였다면
    /// 열 길이가 cos(22.5°)≈0.924 로 줄어 정점이 안쪽으로 빨려든다.
    func testWeightedCascadeRotationUsesNlerpNotMatrixLerp() {
        let k0 = PuppetModel.Key(position: .zero, angles: .zero, scale: SIMD3(1, 1, 1))
        let k90 = PuppetModel.Key(position: .zero, angles: SIMD3(0, 0, .pi / 2), scale: SIMD3(1, 1, 1))
        let m = oneBoneModel([[k0], [k90]])
        let layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)] =
            [(0, false, 1, 1), (1, false, 0.5, 1)]
        let p = PuppetPose.skinnedPositions(
            model: m, matrices: PuppetPose.blendedSkinMatrices(model: m, layers: layers, time: 0)).first!
        let r = Float(10) / Float(2).squareRoot()
        XCTAssertEqual(p.x, r, accuracy: 1e-3, "Rz(45°) — 행렬 lerp 였다면 5.0")
        XCTAssertEqual(p.y, r, accuracy: 1e-3)
        XCTAssertEqual(simd_length(p), 10, accuracy: 1e-3, "회전 블렌드는 길이를 보존한다")
    }

    // MARK: - TRS 분해

    func testDecomposeTRSRoundTrips() {
        let src = PuppetPose.TRS(position: SIMD3(3, -4, 5),
                                 rotation: PuppetPose.rotationQuaternion(SIMD3(0.4, 1.1, -0.6)),
                                 scale: SIMD3(2, 0.5, 3))
        let m = PuppetPose.trsMatrix(src)
        guard let back = PuppetPose.decomposeTRS(m) else { return XCTFail("분해 실패") }
        XCTAssertEqual(back.position.x, src.position.x, accuracy: 1e-4)
        XCTAssertEqual(back.position.y, src.position.y, accuracy: 1e-4)
        XCTAssertEqual(back.position.z, src.position.z, accuracy: 1e-4)
        XCTAssertEqual(back.scale.x, src.scale.x, accuracy: 1e-4)
        XCTAssertEqual(back.scale.y, src.scale.y, accuracy: 1e-4)
        XCTAssertEqual(back.scale.z, src.scale.z, accuracy: 1e-4)
        XCTAssertEqual(abs(PuppetPose.quatDot(back.rotation, src.rotation)), 1, accuracy: 1e-4)
        let m2 = PuppetPose.trsMatrix(back)
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(m2[c][r], m[c][r], accuracy: 1e-3) } }
    }

    /// 스큐/거울 바인드는 TRS 로 표현할 수 없으므로 분해가 nil 이고, 캐스케이드는 종전 행렬 lerp
    /// 경로로 폴백한다(크래시·NaN 없이 값이 나와야 한다).
    func testSkewedBindFallsBackToMatrixCascade() {
        // x 축만 뒤집은 거울 바인드(det < 0).
        let mirror = simd_float4x4(SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        XCTAssertNil(PuppetPose.decomposeTRS(mirror), "거울 행렬은 TRS 분해 불가")
        // 전단(shear) 바인드
        let skew = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0.5, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        XCTAssertNil(PuppetPose.decomposeTRS(skew), "전단 행렬은 TRS 분해 불가")

        let m = oneBoneModel([[PuppetModel.Key(position: SIMD3(7, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1))]],
                             bind: skew, vertex: .zero)
        let mats = PuppetPose.blendedSkinMatrices(
            model: m, layers: [(anim: 0, additive: false, weight: 1, rate: 1)], time: 0)
        let p = PuppetPose.skinnedPositions(model: m, matrices: mats).first!
        XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, "폴백 경로도 유한값을 낸다")
        XCTAssertEqual(p.x, 7, accuracy: 1e-3, "weight=1 절대 레이어는 클립 포즈 그대로")
    }

    // MARK: - 본 계층 합성 (0x14005ecb0 피연산자 순서 + 스케일 상속)

    /// WE 의 4×4 곱 `0x14005ecb0` 을 **평탄 인덱스 산술 그대로** 옮긴 것.
    ///
    /// `0x14005ecba`–`0x14005ee4b`: A=rdx 는 8바이트씩 통째로 읽고(`movsd [rdx+8k]`),
    /// B=r8 은 성분을 하나씩 읽어 `shufps ..,0` 으로 브로드캐스트해 곱한다
    /// (`movss xmm5,[r8]` 0x14005ecd3 → `shufps xmm5,xmm5,0` 0x14005edd6 → `mulps xmm3,xmm5`
    /// 0x14005edda → `addps` 0x14005edfc/0x14005ee11/0x14005ee29 → `movsd [rcx],xmm3` 0x14005ee3d).
    /// 결과: `out[4j+i] = Σₖ A[4k+i]·B[4j+k]`.
    /// 전원소 0 행렬. `simd_float4x4(0)` 은 애플 simd 에서 **대각** 행렬이라 쓸 수 없다.
    private func zeroMatrix() -> simd_float4x4 {
        simd_float4x4(SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0))
    }

    private func engineMatMul(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 {
        func flat(_ m: simd_float4x4, _ n: Int) -> Float { m[n / 4][n % 4] }   // m[4c+r] = 열 c 행 r
        var out = zeroMatrix()
        for j in 0..<4 {
            for i in 0..<4 {
                var s: Float = 0
                for k in 0..<4 { s += flat(a, 4 * k + i) * flat(b, 4 * j + k) }
                out[j][i] = s
            }
        }
        return out
    }

    /// 결정적 의사난수(테스트 재현성 — 플랫폼 RNG 에 기대지 않는다).
    private struct LCG {
        var s: UInt64
        mutating func next() -> Float {   // [-1, 1)
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(bitPattern: UInt32(truncatingIfNeeded: s >> 33))) / Float(1 << 31)
        }
    }

    /// 엔진 산술 전사(轉寫)와 `simd_float4x4` 곱이 같은지 — 열우선 규약 고정점.
    /// 이게 깨지면 아래 계층 테스트의 기준선이 무너진 것이다.
    func testEngineMatMulFlatFormulaEqualsColumnVectorProduct() {
        var r = LCG(s: 0x5EED_1234)
        var mismatches = 0
        for _ in 0..<200 {
            var a = zeroMatrix(), b = zeroMatrix()
            for c in 0..<4 { for row in 0..<4 { a[c][row] = r.next() * 3; b[c][row] = r.next() * 3 } }
            let engine = engineMatMul(a, b)
            let simdp = a * b
            for c in 0..<4 {
                for row in 0..<4 where abs(engine[c][row] - simdp[c][row]) > 1e-3 * max(1, abs(simdp[c][row])) {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "0x14005ecb0 전사 == simd 열우선 곱 (불일치 \(mismatches)/3200 성분)")
    }

    /// **부모→자식 합성 순서.** `0x1401fea10`–`0x1401feadf` 는 `0x14005ecb0(out, world[parent], local)`
    /// 을 부르고(호출부 인자: `rdx` = 부모 월드 `0x1401fea7e`, `r8` = 자기 로컬 `0x1401fea88`),
    /// 위 산술상 **r8 이 먼저 적용된다** — 곧 열벡터 규약의 `world[parent] * local` 이다.
    /// 무작위 본 체인 400건으로 Waple 의 `bindWorlds` 와 대조하고, 뒤바꾼 순서도 함께 센다.
    func testHierarchyComposesParentThenLocalNumerically() {
        var r = LCG(s: 0xA11C_E5)
        var okMismatch = 0, reversedMismatch = 0
        let n = 400
        for _ in 0..<n {
            // 부모 인덱스가 항상 자신보다 앞인 6본 체인(가지 포함).
            var bones: [PuppetModel.Bone] = []
            for i in 0..<6 {
                let t = SIMD3<Float>(r.next() * 20, r.next() * 20, r.next() * 20)
                let a = SIMD3<Float>(r.next() * 3, r.next() * 3, r.next() * 3)
                let s = SIMD3<Float>(0.4 + abs(r.next()), 0.4 + abs(r.next()), 0.4 + abs(r.next()))
                let parent: Int32 = i == 0 ? -1 : Int32(Int(abs(r.next()) * Float(i)) % max(i, 1))
                bones.append(.init(name: "b\(i)", parent: parent,
                                   bind: PuppetPose.localMatrix(position: t, angles: a, scale: s)))
            }
            var m = PuppetModel(material: "m", vertices: [], indices: [])
            m.bones = bones
            let got = PuppetPose.bindWorlds(m)

            // 엔진 규칙 그대로: world[i] = engineMatMul(world[parent], local[i])
            var ref = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
            var rev = ref
            for (i, b) in bones.enumerated() {
                let p = Int(b.parent)
                ref[i] = b.parent >= 0 ? engineMatMul(ref[p], b.bind) : b.bind
                rev[i] = b.parent >= 0 ? engineMatMul(b.bind, rev[p]) : b.bind   // 뒤바꾼 가설
            }
            func differs(_ x: simd_float4x4, _ y: simd_float4x4) -> Bool {
                for c in 0..<4 {
                    for row in 0..<4 where abs(x[c][row] - y[c][row]) > 1e-2 * max(1, abs(y[c][row])) {
                        return true
                    }
                }
                return false
            }
            for i in 0..<bones.count {
                if differs(got[i], ref[i]) { okMismatch += 1 }
                if differs(got[i], rev[i]) { reversedMismatch += 1 }
            }
        }
        print("AG-METRIC hierarchy: ok=\(okMismatch) reversed=\(reversedMismatch) total=\(n * 6)")
        XCTAssertEqual(okMismatch, 0, "world[parent] × local 불일치 \(okMismatch)/\(n * 6)")
        XCTAssertGreaterThan(reversedMismatch, n * 4,
                             "뒤바꾼 순서는 대부분 어긋나야 한다 — 불일치 \(reversedMismatch)/\(n * 6)")
    }

    /// **스케일은 상속된다.** 합성이 4×4 아핀 전체 곱이고(`movups` 64B 복사 4번 `0x1401feace`–
    /// `0x1401feadf`) 스케일 제거·정규직교화 단계가 없다 — 부모의 비균등 스케일이 자식의 회전
    /// 기저까지 늘려 전단을 만든다.
    func testNonUniformParentScaleIsInheritedAndShearsChild() {
        var m = PuppetModel(material: "m", vertices: [], indices: [])
        let parent = PuppetPose.localMatrix(position: .zero, angles: .zero, scale: SIMD3(2, 1, 1))
        let child = PuppetPose.localMatrix(position: SIMD3(1, 0, 0), angles: SIMD3(0, 0, .pi / 2),
                                           scale: SIMD3(1, 1, 1))
        m.bones = [.init(name: "p", parent: -1, bind: parent), .init(name: "c", parent: 0, bind: child)]
        let w = PuppetPose.bindWorlds(m)
        // 평행이동이 부모 스케일을 먹는다: (1,0,0) → (2,0,0). 상속이 없었다면 1.0.
        XCTAssertEqual(w[1].columns.3.x, 2, accuracy: 1e-5, "부모 스케일이 자식 평행이동에 곱해진다")
        // 회전 기저도 비등방으로 늘어난다(전단): Rz(90°) 의 열1 = (-1,0,0) → (-2,0,0).
        XCTAssertEqual(simd_length(SIMD3(w[1].columns.0.x, w[1].columns.0.y, w[1].columns.0.z)),
                       1, accuracy: 1e-4, "열0 길이 1 (y 축 방향)")
        XCTAssertEqual(simd_length(SIMD3(w[1].columns.1.x, w[1].columns.1.y, w[1].columns.1.z)),
                       2, accuracy: 1e-4, "열1 길이 2 — 스케일이 회전 기저까지 상속돼 비등방이 된다")
    }

    // MARK: - 정점 스키닝: LBS (듀얼 쿼터니언 아님)

    /// WE 셰이더의 두 철자가 대수적으로 같은지 — `genericimage3.vert:139-142`(행렬 먼저 섞기)와
    /// `passthroughblend.vert:19-22`(각각 곱하고 섞기). 아핀이라 동치이고, Waple 은 후자 형태다.
    func testTwoShaderSpellingsOfLinearBlendSkinningAgree() {
        var r = LCG(s: 0xB1E4_D1)
        var mismatches = 0
        for _ in 0..<200 {
            var mats: [simd_float4x4] = []
            for _ in 0..<4 {
                mats.append(PuppetPose.localMatrix(
                    position: SIMD3(r.next() * 10, r.next() * 10, r.next() * 10),
                    angles: SIMD3(r.next() * 3, r.next() * 3, r.next() * 3),
                    scale: SIMD3(0.5 + abs(r.next()), 0.5 + abs(r.next()), 0.5 + abs(r.next()))))
            }
            var w = SIMD4<Float>(abs(r.next()), abs(r.next()), abs(r.next()), abs(r.next()))
            let sum = w.x + w.y + w.z + w.w
            guard sum > 1e-3 else { continue }
            w /= sum
            let p = SIMD4<Float>(r.next() * 30, r.next() * 30, r.next() * 30, 1)

            // (a) 행렬을 먼저 가중합
            var blended = zeroMatrix()
            for k in 0..<4 {
                blended.columns.0 += mats[k].columns.0 * w[k]
                blended.columns.1 += mats[k].columns.1 * w[k]
                blended.columns.2 += mats[k].columns.2 * w[k]
                blended.columns.3 += mats[k].columns.3 * w[k]
            }
            let a = blended * p
            // (b) 각각 곱하고 나중에 가중합
            var b = SIMD4<Float>(0, 0, 0, 0)
            for k in 0..<4 { b += (mats[k] * p) * w[k] }
            for c in 0..<3 where abs(a[c] - b[c]) > 1e-2 * max(1, abs(b[c])) { mismatches += 1 }
        }
        print("AG-METRIC lbs-spellings: mismatches=\(mismatches)")
        XCTAssertEqual(mismatches, 0, "LBS 두 철자는 동치 — 불일치 \(mismatches)")
    }

    /// **선형 블렌드 스키닝이지 듀얼 쿼터니언이 아니다.** 판별식은 고전적인 "사탕 포장지" 붕괴다:
    /// 같은 축의 0°/180° 두 본을 0.5/0.5 로 섞으면 LBS 는 회전 기저가 상쇄돼 정점이 축으로
    /// 눌린다(듀얼 쿼터니언이면 90° 회전이 나와 길이가 보존된다).
    /// 근거: 동봉 셰이더 137개에 `dualquat`/`DQS` 식별자 0건, `g_Bones` 사용 9개 전부 가중 행렬합.
    func testSkinningCollapsesLikeLinearBlendNotDualQuaternion() {
        var m = PuppetModel(material: "m",
                            vertices: [.init(position: SIMD3(1, 0, 0), boneIndices: SIMD4(0, 1, 0, 0),
                                             weights: SIMD4(0.5, 0.5, 0, 0), uv: SIMD2(0, 0))],
                            indices: [0])
        m.bones = [.init(name: "a", parent: -1, bind: matrix_identity_float4x4),
                   .init(name: "b", parent: -1, bind: matrix_identity_float4x4)]
        let rot180 = PuppetPose.quaternionMatrix(PuppetPose.rotationQuaternion(SIMD3(0, 0, .pi)))
        let p = PuppetPose.skinnedPositions(model: m, matrices: [matrix_identity_float4x4, rot180]).first!
        XCTAssertEqual(simd_length(p), 0, accuracy: 1e-4,
                       "LBS 는 0.5·I + 0.5·Rz(180°) 로 붕괴한다 — 듀얼 쿼터니언이면 길이 1 이 남는다")
    }

    /// 가중치 0 슬롯: WE 셰이더는 네 슬롯을 무조건 더하므로 **0 슬롯은 결과에 기여하지 않지만**
    /// 인덱싱 자체는 일어난다. 음수 가중치는 그대로 빼진다 — Waple 도 `w != 0` 만 건너뛴다.
    /// (종전 `w > 0` 게이트는 음수 슬롯을 통째로 버려 WE 와 값이 달랐다.)
    func testNegativeWeightSlotContributesAndZeroSlotDoesNot() {
        // 두 본: 본0 = 항등, 본1 = +x 로 10 이동. 가중치 (1.5, -0.5, 0, 0) → 합 1.0.
        var m = PuppetModel(material: "m",
                            vertices: [.init(position: SIMD3(0, 0, 0), boneIndices: SIMD4(0, 1, 1, 1),
                                             weights: SIMD4(1.5, -0.5, 0, 0), uv: SIMD2(0, 0))],
                            indices: [0])
        m.bones = [.init(name: "a", parent: -1, bind: matrix_identity_float4x4),
                   .init(name: "b", parent: -1, bind: matrix_identity_float4x4)]
        var shift = matrix_identity_float4x4
        shift.columns.3 = SIMD4(10, 0, 0, 1)
        let p = PuppetPose.skinnedPositions(model: m, matrices: [matrix_identity_float4x4, shift]).first!
        XCTAssertEqual(p.x, -5, accuracy: 1e-4,
                       "1.5·0 + (−0.5)·10 = −5 — 음수 슬롯을 버리면 0 이 나온다")
        // 0 슬롯(3, 4번째)은 기여가 없다: 같은 정점의 0 가중 슬롯 인덱스를 바꿔도 결과 불변.
        var m2 = PuppetModel(material: "m",
                             vertices: [.init(position: SIMD3(0, 0, 0), boneIndices: SIMD4(0, 1, 0, 0),
                                              weights: SIMD4(1.5, -0.5, 0, 0), uv: SIMD2(0, 0))],
                             indices: [0])
        m2.bones = m.bones
        let p2 = PuppetPose.skinnedPositions(model: m2, matrices: [matrix_identity_float4x4, shift]).first!
        XCTAssertEqual(p2.x, p.x, accuracy: 0, "가중치 0 슬롯의 본 인덱스는 결과에 영향이 없다")
    }

    /// 정점당 본은 정확히 4개 — 5번째 슬롯이 있다면 `SIMD4` 로는 담기지 않는다는 구조적 고정점.
    /// (정점 포맷 비트 0x00800000 = boneIndices 4×u32, 0x01000000 = weights 4×f32.)
    func testVertexHasExactlyFourBoneSlots() {
        let v = PuppetModel.Vertex(position: .zero, boneIndices: SIMD4(0, 1, 2, 3),
                                   weights: SIMD4(0.25, 0.25, 0.25, 0.25), uv: .zero)
        XCTAssertEqual(v.weights.scalarCount, 4)
        XCTAssertEqual(v.boneIndices.scalarCount, 4)
    }
}
