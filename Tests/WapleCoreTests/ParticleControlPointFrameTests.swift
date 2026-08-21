import XCTest
@testable import WapleCore

/// `ParticleControlPointFrame.swift` 회귀 — **엔진과 갈리는 자리를 값으로** 잠근다.
///
/// 근거 VA 는 소스 주석에 있다(전부 이 레인에서 `.pdata` 시작부터 선형으로 다시 떴다).
/// 여기 단언은 "코드가 지금 이렇다" 가 아니라 **"실물이 이렇다"** 를 적는다 — 돌연변이를
/// 넣었을 때 반드시 깨져야 하는 것들이다.
final class ParticleControlPointFrameTests: XCTestCase {

    private let eps: Float = 1e-5

    private typealias Feed = ParticleControlPointMath.ChildControlPointFeed

    private func assertMatrix(_ a: CPMatrix4, _ b: [Float],
                              _ tol: Float = 1e-5,
                              file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<16 {
            XCTAssertEqual(a.m[i], b[i], accuracy: tol, "성분 \(i)", file: file, line: line)
        }
    }

    // MARK: - 상한과 클램프

    /// **상한 8.** 파스 루프가 고정 8회(`cmp r14d, 8` @0x1401d080a)이고 디스크립터 배열
    /// 메모리셋이 `0x100` 바이트(`mov r8d, 0x100` @0x1401d04e1)다.
    func testSlotCountIsEight() {
        XCTAssertEqual(ParticleControlPointLimits.slotCount, 8)
        XCTAssertEqual(ParticleControlPointLimits.descriptorStride, 0x20)
        XCTAssertEqual(0x100 / ParticleControlPointLimits.descriptorStride,
                       ParticleControlPointLimits.slotCount)
        XCTAssertEqual(ParticleControlPointLimits.recordStride, 0xD0)
        XCTAssertTrue(ParticleControlPointLimits.acceptsSlot(7))
        XCTAssertFalse(ParticleControlPointLimits.acceptsSlot(8))
        XCTAssertFalse(ParticleControlPointLimits.acceptsSlot(-1))
    }

    /// **클램프는 부호 없는 비교다 — 음수는 0 이 아니라 7 이 된다.**
    /// `mov edx, 7` / `cmp ecx, edx` / `cmovb edx, ecx`(0x1401cef35–0x1401cef4f).
    func testClampIndexIsUnsigned() {
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(0), 0)
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(6), 6)
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(7), 7)
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(8), 7)
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(9999), 7)
        // 여기가 갈리는 자리다 — 부호 있는 클램프였다면 0 이 나온다.
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(-1), 7)
        XCTAssertEqual(ParticleControlPointLimits.clampIndex(-8), 7)
    }

    /// 마스크 값 자체. `0x10005 = bit0 | bit2 | bit16`.
    func testFlagBitValues() {
        XCTAssertEqual(ParticleControlPointFlag.pointerDriven, 0x1)
        XCTAssertEqual(ParticleControlPointFlag.worldAuthored, 0x2)
        XCTAssertEqual(ParticleControlPointFlag.parentAttached, 0x4)
        XCTAssertEqual(ParticleControlPointFlag.parentCopyWholesale, 0x8)
        XCTAssertEqual(ParticleControlPointFlag.remapOutput, 0x10000)
        XCTAssertEqual(ParticleControlPointFlag.overrideBlockMask, 0x10005)
        XCTAssertEqual(ParticleControlPointFlag.overrideBlockMask,
                       ParticleControlPointFlag.pointerDriven
                           | ParticleControlPointFlag.parentAttached
                           | ParticleControlPointFlag.remapOutput)
        // 저작값 16 은 **bit4** 이고 remap 출력 비트가 아니다(동봉 10원소).
        XCTAssertEqual(16 & ParticleControlPointFlag.overrideBlockMask, 0)
        // bit1 은 게이트 대상이 아니다 — 씬 오버라이드를 막지 않는다.
        XCTAssertEqual(ParticleControlPointFlag.worldAuthored
                           & ParticleControlPointFlag.overrideBlockMask, 0)
    }

    // MARK: - 디스크립터 기본값

    /// **저장을 건너뛰는 분기는 false 가 아니라 0-메모리셋을 남긴다**(방법론 함정 13).
    /// 파서는 슬롯 배열을 `memset(def + 0xa4, 0, 0x100)`(0x1401d04d8) 로 깔고 시작하고,
    /// `offset`/`angles` 는 **문자열일 때만** 저장한다(`cmp byte ptr [rax + 8], 4`).
    func testDescriptorDefaultsAreZero() {
        let d = ParticleControlPointDescriptor()
        XCTAssertEqual(d.flags, 0)
        XCTAssertEqual(d.parentControlPoint, 0)
        XCTAssertEqual(d.offset, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(d.angles, Vec3(x: 0, y: 0, z: 0))
    }

    /// 실물 `thunderbolt_fizzle.json` 의 CP 1 은 `"offset": null` 이다 — 태그 4 검사에 걸려
    /// 저장이 안 되고 0 이 남는다. base 는 항등 + 원점이 된다.
    func testNullOffsetKeepsZeroTranslation() {
        let base = ParticleControlPointMath.authoredBase(offset: ParticleControlPointDescriptor().offset)
        assertMatrix(base, CPMatrix4.identity.m)
    }

    /// 파티클 `.json` 의 `angles` 는 파스되지만 **base 에 안 실린다**(생성자 0x14022c3c0 가
    /// 회전 3행에 항등을 넣는다). 그래서 `authoredBase` 는 각도를 인자로 받지 않는다.
    func testParticleAnglesAreInertAndBaseRotationIsIdentity() {
        XCTAssertTrue(ParticleControlPointMath.particleAnglesAreInert)
        let base = ParticleControlPointMath.authoredBase(offset: Vec3(x: 450, y: 0, z: 0))
        assertMatrix(base, [1, 0, 0, 0,
                            0, 1, 0, 0,
                            0, 0, 1, 0,
                            450, 0, 0, 1])
    }

    /// `locktopointer` 는 WE 설치본 어느 바이너리에도 없다 — 마우스 게이트는 `flags` bit0 뿐이다.
    /// 그래서 `exampleturbolence3d.json` CP 1(`locktopointer: true`, `flags: 0`)은 안 따라간다.
    func testPointerLockKeyIsDead() {
        XCTAssertTrue(ParticleControlPointMath.pointerLockKeyIsDead)
        let update = ParticleControlPointMath.frameUpdate(
            cpFlags: 0, index: 1, parentControlPoint: 0, parentControlPointCount: 8,
            hasParentSystem: false, systemSimulatesInWorldSpace: false,
            parentSimulatesInWorldSpace: false, childFeedEnabled: false, childFeedStartIndex: 0)
        XCTAssertNotEqual(update, .pointer)
    }

    // MARK: - 회전 3×3

    /// **회전식을 닫힌 값으로 잠근다.** 세 각을 서로 다르게 줘서 축 순서·부호가 갈리게 한다.
    /// 실물 스토어(0x14022bfcd–0x14022c069)를 그대로 옮긴 것:
    /// `m02 = -sin(y)` 하나만으로도 축 순서가 확정된다.
    func testRotationMatchesEngineStoreOrder() {
        let a: Float = 0.3, b: Float = 0.7, c: Float = 1.1
        let r = ParticleControlPointMath.rotation(angles: Vec3(x: a, y: b, z: c))
        let ca = cosf(a), sa = sinf(a), cb = cosf(b), sb = sinf(b), cc = cosf(c), sc = sinf(c)
        assertMatrix(r, [cb * cc, cb * sc, -sb, 0,
                         sa * sb * cc - ca * sc, sa * sb * sc + ca * cc, sa * cb, 0,
                         ca * sb * cc + sa * sc, ca * sb * sc - sa * cc, ca * cb, 0,
                         0, 0, 0, 1])
    }

    /// `m02 = -sin(y)` 이지 `+sin(y)` 가 아니다 — 부호가 뒤집히면 화면이 거울이 된다.
    /// y 만 90° 로 돌려 닫힌 값으로 못 박는다.
    func testRotationYawSignIsNegative() {
        let r = ParticleControlPointMath.rotation(angles: Vec3(x: 0, y: .pi / 2, z: 0))
        XCTAssertEqual(r[0, 2], -1, accuracy: eps)
        XCTAssertEqual(r[2, 0], 1, accuracy: eps)
        XCTAssertEqual(r[0, 0], 0, accuracy: eps)
        XCTAssertEqual(r[2, 2], 0, accuracy: eps)
    }

    /// 행벡터 규약 확인 — `(1,0,0) · R(z=90°) = (0,1,0)`.
    /// 열벡터로 곱했다면 `(0,-1,0)` 이 나온다.
    func testRotationIsRowVectorConvention() {
        let r = ParticleControlPointMath.rotation(angles: Vec3(x: 0, y: 0, z: .pi / 2))
        // p' = p · R  →  p'.x = p.x*R[0][0] + p.y*R[1][0] + p.z*R[2][0]
        let px: Float = 1, py: Float = 0, pz: Float = 0
        let outX = px * r[0, 0] + py * r[1, 0] + pz * r[2, 0]
        let outY = px * r[0, 1] + py * r[1, 1] + pz * r[2, 1]
        XCTAssertEqual(outX, 0, accuracy: eps)
        XCTAssertEqual(outY, 1, accuracy: eps)
    }

    /// 각도 0 이면 항등이다(w 성분 포함).
    func testRotationZeroIsIdentity() {
        assertMatrix(ParticleControlPointMath.rotation(angles: Vec3(x: 0, y: 0, z: 0)),
                     CPMatrix4.identity.m)
    }

    // MARK: - 4×4 곱

    /// `0x14024f0e0(dst, rdx = B, r8 = A)` 은 `dst = A × B` 다 — 순서가 갈리는 자리라
    /// **비가환** 짝으로 잠근다.
    func testMultiplyOrderIsRowMajorSelfTimesRHS() {
        var a = CPMatrix4.identity
        a[3, 0] = 10                       // 평행이동 (10, 0, 0)
        let b = ParticleControlPointMath.rotation(angles: Vec3(x: 0, y: 0, z: .pi / 2))
        // A × B : 먼저 옮기고 나서 돌린다 → (10,0,0) 이 (0,10,0) 으로 간다.
        let ab = a.multiplied(by: b)
        XCTAssertEqual(ab.translation.x, 0, accuracy: eps)
        XCTAssertEqual(ab.translation.y, 10, accuracy: eps)
        // B × A : 먼저 돌리고 옮긴다 → 평행이동이 그대로 (10,0,0).
        let ba = b.multiplied(by: a)
        XCTAssertEqual(ba.translation.x, 10, accuracy: eps)
        XCTAssertEqual(ba.translation.y, 0, accuracy: eps)
    }

    func testMultiplyByIdentityIsIdentity() {
        let m = ParticleControlPointMath.baseMatrix(offset: Vec3(x: 1, y: 2, z: 3),
                                                    angles: Vec3(x: 0.2, y: 0.4, z: 0.6))
        assertMatrix(m.multiplied(by: .identity), m.m)
        assertMatrix(CPMatrix4.identity.multiplied(by: m), m.m)
    }

    // MARK: - 씬 instanceoverride

    /// 센티널은 `FLT_MAX`(`0x7f7fffff`)이고 **`.x` 만** 판정에 쓰인다.
    /// NaN 은 `jp` 때문에 "지정됨" 으로 친다.
    func testUnspecifiedSentinel() {
        XCTAssertEqual(ParticleControlPointMath.unspecified.bitPattern, 0x7f7f_ffff)
        XCTAssertTrue(ParticleControlPointMath.isUnspecified(.greatestFiniteMagnitude))
        XCTAssertFalse(ParticleControlPointMath.isUnspecified(0))
        XCTAssertFalse(ParticleControlPointMath.isUnspecified(.nan))
        XCTAssertFalse(ParticleControlPointMath.isUnspecified(.infinity))
    }

    /// **절대 대체다 — 합산이 아니다.** 저작 base 가 (450,0,0) 인데 오버라이드가 (7,8,9) 면
    /// 결과는 (7,8,9) 다(합산이었다면 (457,8,9)).
    func testInstanceOverridePositionReplacesNotAdds() {
        let base = ParticleControlPointMath.authoredBase(offset: Vec3(x: 450, y: 0, z: 0))
        let r = ParticleControlPointMath.applyInstanceOverride(
            base: base, flags: 0,
            overrideAngles: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0),
            overrideTranslation: Vec3(x: 7, y: 8, z: 9))
        XCTAssertFalse(r.skipped)
        XCTAssertFalse(r.wroteRotation)
        XCTAssertTrue(r.wroteTranslation)
        XCTAssertEqual(r.base.translation, Vec3(x: 7, y: 8, z: 9))
        // 회전은 base 그대로(항등).
        XCTAssertEqual(r.base[0, 0], 1, accuracy: eps)
        XCTAssertEqual(r.base[1, 1], 1, accuracy: eps)
    }

    /// **각도만 지정도 성립한다** — 두 센티널 검사가 독립이고, 각도만 서면 `cl = 1` 이라
    /// 위치 검사를 통과한 뒤 재합성으로 간다(0x14022c085).
    func testInstanceOverrideAnglesOnlyKeepsAuthoredTranslation() {
        let base = ParticleControlPointMath.authoredBase(offset: Vec3(x: 450, y: -1, z: 2))
        let r = ParticleControlPointMath.applyInstanceOverride(
            base: base, flags: 0,
            overrideAngles: Vec3(x: 0, y: .pi / 2, z: 0),
            overrideTranslation: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0))
        XCTAssertFalse(r.skipped)
        XCTAssertTrue(r.wroteRotation)
        XCTAssertFalse(r.wroteTranslation)
        XCTAssertEqual(r.base.translation, Vec3(x: 450, y: -1, z: 2))
        XCTAssertEqual(r.base[0, 2], -1, accuracy: eps)
    }

    /// 둘 다 미지정이면 이 CP 는 **통째로 건너뛴다**(재합성도 안 한다).
    func testInstanceOverrideBothUnspecifiedSkips() {
        let base = ParticleControlPointMath.authoredBase(offset: Vec3(x: 3, y: 4, z: 5))
        let r = ParticleControlPointMath.applyInstanceOverride(
            base: base, flags: 0,
            overrideAngles: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0),
            overrideTranslation: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0))
        XCTAssertTrue(r.skipped)
        assertMatrix(r.base, base.m)
    }

    /// `flags & 0x10005` 는 위치도 각도도 **보기 전에** 걸린다(0x14022bf26).
    /// bit1(=2)과 bit3(=8)과 bit4(=16)은 안 걸린다.
    func testInstanceOverrideBlockMask() {
        let base = ParticleControlPointMath.authoredBase(offset: Vec3(x: 1, y: 1, z: 1))
        func apply(_ flags: Int) -> ParticleControlPointMath.InstanceOverrideOutcome {
            ParticleControlPointMath.applyInstanceOverride(
                base: base, flags: flags,
                overrideAngles: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0),
                overrideTranslation: Vec3(x: 99, y: 0, z: 0))
        }
        for blocked in [0x1, 0x4, 0x10000, 0x10005, 0x5] {
            XCTAssertTrue(apply(blocked).skipped, "flags=\(blocked)")
            XCTAssertEqual(apply(blocked).base.translation, Vec3(x: 1, y: 1, z: 1))
        }
        for allowed in [0x0, 0x2, 0x8, 0x10, 0x1A] {
            XCTAssertFalse(apply(allowed).skipped, "flags=\(allowed)")
            XCTAssertEqual(apply(allowed).base.translation.x, 99, accuracy: eps)
        }
    }

    // MARK: - 매 프레임 갈래

    private func update(_ flags: Int,
                        index: Int = 1,
                        parentCP: Int = 0,
                        parentCount: Int = 8,
                        hasParent: Bool = true,
                        world: Bool = false,
                        parentWorld: Bool = false,
                        feed: Bool = false,
                        feedStart: Int = 0) -> ParticleControlPointMath.FrameUpdate {
        ParticleControlPointMath.frameUpdate(
            cpFlags: flags, index: index, parentControlPoint: parentCP,
            parentControlPointCount: parentCount, hasParentSystem: hasParent,
            systemSimulatesInWorldSpace: world, parentSimulatesInWorldSpace: parentWorld,
            childFeedEnabled: feed, childFeedStartIndex: feedStart)
    }

    /// 우선순위: bit16 > bit0 > bit2 > (자식 피드) > 기본.
    func testFrameUpdatePriority() {
        XCTAssertEqual(update(0x10000 | 0x1 | 0x4), .untouched)
        XCTAssertEqual(update(0x1 | 0x4), .pointer)
        XCTAssertEqual(update(0x4), .parentCompose)
    }

    /// **bit1 의 진짜 의미 — 공간이 어긋날 때만 변환한다.** 이 표가 갈리면 CP 가 엉뚱한
    /// 좌표계로 간다(0x14022a08c–0x14022a10f).
    func testFrameUpdateSpaceTable() {
        XCTAssertEqual(update(0x0, world: true), .composeWithObject)
        XCTAssertEqual(update(0x2, world: true), .keepCurrent)
        XCTAssertEqual(update(0x2, world: false), .composeWithInverseObject)
        XCTAssertEqual(update(0x0, world: false), .keepCurrent)
    }

    /// **슬롯 0 예외** — `test edx, edx`(0x14022a099) 때문에 index 0 의 bit1 은
    /// worldspace 시스템에서 무시된다. (동봉 도달 0 이지만 실물 동작이다.)
    func testFrameUpdateSlotZeroWorldAuthoredException() {
        XCTAssertEqual(update(0x2, index: 0, world: true), .composeWithObject)
        // 로컬 시스템에서는 슬롯 0 도 역행렬 경로로 간다(C → B).
        XCTAssertEqual(update(0x2, index: 0, world: false), .composeWithInverseObject)
    }

    /// bit3 은 **OR** 조건의 한쪽이다 — 부모/자식이 둘 다 월드여도 통째 복사가 된다.
    func testFrameUpdateParentWholesaleIsOr() {
        XCTAssertEqual(update(0x4, world: false, parentWorld: false), .parentCompose)
        XCTAssertEqual(update(0x4, world: true, parentWorld: false), .parentCompose)
        XCTAssertEqual(update(0x4, world: false, parentWorld: true), .parentCompose)
        XCTAssertEqual(update(0x4, world: true, parentWorld: true), .parentCopy)
        XCTAssertEqual(update(0x4 | 0x8, world: false, parentWorld: false), .parentCopy)
    }

    /// 부모 경계검사는 부호 없는 `jbe` 다(0x14022e68b) — 범위 밖이면 아무것도 안 한다.
    func testFrameUpdateParentBounds() {
        XCTAssertEqual(update(0x4, parentCP: 7, parentCount: 8), .parentCompose)
        XCTAssertEqual(update(0x4, parentCP: 8, parentCount: 8), .parentUnavailable)
        XCTAssertEqual(update(0x4, parentCP: -1, parentCount: 8), .parentUnavailable)
        XCTAssertEqual(update(0x4, hasParent: false), .parentUnavailable)
    }

    /// `startIndex` 이상의 슬롯은 엔진이 기본 갱신조차 안 한다(0x14022eb47) — 부모가 채운다.
    func testFrameUpdateChildFeedSkipsDefaultUpdate() {
        XCTAssertEqual(update(0x0, index: 0, world: true, feed: true, feedStart: 1),
                       .composeWithObject)
        XCTAssertEqual(update(0x0, index: 1, world: true, feed: true, feedStart: 1),
                       .fedByParentParticles)
        XCTAssertEqual(update(0x0, index: 7, world: true, feed: true, feedStart: 1),
                       .fedByParentParticles)
        // 피드가 꺼져 있으면 그대로 기본 갱신.
        XCTAssertEqual(update(0x0, index: 7, world: true, feed: false, feedStart: 1),
                       .composeWithObject)
    }

    // MARK: - 마우스

    /// NDC 변환 — x 는 `2x−1`, y 는 **뒤집힌다**(`1−2y`).
    func testPointerNDCFlipsY() {
        let n = ParticleControlPointMath.pointerNDC(Vec2(x: 0.75, y: 0.25))
        XCTAssertEqual(n.x, 0.5, accuracy: eps)
        XCTAssertEqual(n.y, 0.5, accuracy: eps)
        let c = ParticleControlPointMath.pointerNDC(Vec2(x: 0.5, y: 0.5))
        XCTAssertEqual(c.x, 0, accuracy: eps)
        XCTAssertEqual(c.y, 0, accuracy: eps)
        let tl = ParticleControlPointMath.pointerNDC(Vec2(x: 0, y: 0))
        XCTAssertEqual(tl.x, -1, accuracy: eps)
        XCTAssertEqual(tl.y, 1, accuracy: eps)
    }

    /// 역투영은 `(ndc.x, ndc.y, 0, 1) · M` 뒤 `x/w`, `y/w` — **z 는 계산되지 않는다.**
    /// 여기서는 w 가 1 이 아닌 행렬을 넣어 나눗셈이 실제로 걸리게 한다.
    func testPointerPlanePointDividesByW() {
        // row0=(2,0,0,0) row1=(0,3,0,0) row2=(0,0,1,0) row3=(5,6,0,2)
        let m = CPMatrix4([2, 0, 0, 0,
                           0, 3, 0, 0,
                           0, 0, 1, 0,
                           5, 6, 0, 2])
        // pointer (1, 0) → ndc (1, 1)
        let p = ParticleControlPointMath.pointerPlanePoint(pointer: Vec2(x: 1, y: 0),
                                                           inverseViewProjection: m)
        // x = 1*2 + 1*0 + 5 = 7 ; y = 1*0 + 1*3 + 6 = 9 ; w = 1*0 + 1*0 + 2 = 2
        XCTAssertEqual(p.x, 3.5, accuracy: eps)
        XCTAssertEqual(p.y, 4.5, accuracy: eps)
    }

    /// worldspace 시스템은 `(u, v, 0)` 을 **그대로** 쓴다(오브젝트 역행렬을 안 탄다).
    func testPointerTranslationWorldSpaceIgnoresObjectInverse() {
        let vp = CPMatrix4([2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        var objInv = CPMatrix4.identity
        objInv[3, 0] = 1000     // 이 값이 새면 테스트가 깨진다
        let t = ParticleControlPointMath.pointerControlPointTranslation(
            pointer: Vec2(x: 1, y: 0), inverseViewProjection: vp,
            inverseObjectWorld: objInv, systemSimulatesInWorldSpace: true)
        XCTAssertEqual(t.x, 2, accuracy: eps)
        XCTAssertEqual(t.y, 2, accuracy: eps)
        XCTAssertEqual(t.z, 0, accuracy: eps)
    }

    /// 로컬 시스템은 `inverse(objectWorld)` 로 한 번 더 내린다 — **z 성분도 나온다**.
    func testPointerTranslationLocalSpaceAppliesObjectInverse() {
        let vp = CPMatrix4.identity   // ndc 를 그대로 통과시킨다
        // row0=(1,0,0,0) row1=(0,1,0,0) row2=(0,0,1,0) row3=(10,20,30,1)
        var objInv = CPMatrix4.identity
        objInv[3, 0] = 10
        objInv[3, 1] = 20
        objInv[3, 2] = 30
        let t = ParticleControlPointMath.pointerControlPointTranslation(
            pointer: Vec2(x: 1, y: 1), inverseViewProjection: vp,
            inverseObjectWorld: objInv, systemSimulatesInWorldSpace: false)
        // ndc = (1, -1) → plane = (1, -1) → · objInv = (11, 19, 30)
        XCTAssertEqual(t.x, 11, accuracy: eps)
        XCTAssertEqual(t.y, 19, accuracy: eps)
        XCTAssertEqual(t.z, 30, accuracy: eps)
    }

    /// 마우스는 **평행이동 행만** 덮는다 — 회전 3행은 base 그대로다.
    func testPointerKeepsBaseRotation() {
        let base = ParticleControlPointMath.baseMatrix(offset: Vec3(x: 1, y: 2, z: 3),
                                                       angles: Vec3(x: 0, y: .pi / 2, z: 0))
        var cur = base
        let t = ParticleControlPointMath.pointerControlPointTranslation(
            pointer: Vec2(x: 0.5, y: 0.5), inverseViewProjection: .identity,
            inverseObjectWorld: .identity, systemSimulatesInWorldSpace: true)
        cur[3, 0] = t.x; cur[3, 1] = t.y; cur[3, 2] = t.z
        XCTAssertEqual(cur[0, 2], -1, accuracy: eps)     // base 회전 보존
        XCTAssertEqual(cur.translation, Vec3(x: 0, y: 0, z: 0))
    }

    /// CP 에 들어오는 외부 입력은 마우스뿐이다(마스터 갱신 전문의 `call` 다섯 개에 오디오 없음).
    func testOnlyExternalInputIsPointer() {
        XCTAssertTrue(ParticleControlPointMath.onlyExternalInputIsPointer)
    }

    // MARK: - inheritcontrolpointvelocity

    func testInheritedVelocityIsDeltaOverDt() {
        let v = ParticleControlPointMath.inheritedControlPointVelocity(
            current: Vec3(x: 10, y: 4, z: -2), previous: Vec3(x: 4, y: 4, z: 1), dt: 0.5)
        XCTAssertEqual(v.x, 12, accuracy: eps)
        XCTAssertEqual(v.y, 0, accuracy: eps)
        XCTAssertEqual(v.z, -6, accuracy: eps)
    }

    /// `s = min + r·span` — `mulss` 가 먼저고 `addss` 가 나중이다(0x14023bd0b → 0x14023bd22).
    func testInheritScaleIsLerpFromMin() {
        XCTAssertEqual(ParticleControlPointMath.inheritScale(random: 0, min: 0.1, span: 0.1),
                       0.1, accuracy: eps)
        XCTAssertEqual(ParticleControlPointMath.inheritScale(random: 1, min: 0.1, span: 0.1),
                       0.2, accuracy: eps)
        XCTAssertEqual(ParticleControlPointMath.inheritScale(random: 0.5, min: -1, span: 4),
                       1, accuracy: eps)
    }

    /// 보정 게이트는 **AND** 다 — 시스템 worldspace 이고 CP bit1 이 **없어야** 한다.
    func testInheritObjectCorrectionGate() {
        XCTAssertTrue(ParticleControlPointMath.inheritAppliesObjectCorrection(
            systemSimulatesInWorldSpace: true, cpFlags: 0))
        XCTAssertFalse(ParticleControlPointMath.inheritAppliesObjectCorrection(
            systemSimulatesInWorldSpace: true, cpFlags: 0x2))
        XCTAssertFalse(ParticleControlPointMath.inheritAppliesObjectCorrection(
            systemSimulatesInWorldSpace: false, cpFlags: 0))
        // bit0/bit2 는 이 게이트와 무관하다.
        XCTAssertTrue(ParticleControlPointMath.inheritAppliesObjectCorrection(
            systemSimulatesInWorldSpace: true, cpFlags: 0x1 | 0x4))
    }

    // MARK: - 자식 CP 피드

    func testChildFeedFillsSlotsInOrder() {
        let feed = ParticleControlPointMath.childControlPointFeed(
            startIndex: 1, parentLifetimes: [1, 1, 1], childControlPointFlags: Array(repeating: 0, count: 8))
        XCTAssertEqual(feed, [Feed(slot: 1, parentParticle: 0),
                              Feed(slot: 2, parentParticle: 1),
                              Feed(slot: 3, parentParticle: 2)])
    }

    /// 죽은 파티클(`lifetime == 0`)은 슬롯을 **안 먹는다** — 슬롯이 안 밀린다.
    func testChildFeedSkipsDeadParticlesWithoutConsumingSlot() {
        let feed = ParticleControlPointMath.childControlPointFeed(
            startIndex: 0, parentLifetimes: [0, 5, 0, 7],
            childControlPointFlags: Array(repeating: 0, count: 8))
        XCTAssertEqual(feed, [Feed(slot: 0, parentParticle: 1),
                              Feed(slot: 1, parentParticle: 3)])
    }

    /// **NaN 수명은 살아 있는 것으로 친다** — `ucomiss` + `jp` 가 같음 분기를 건너뛴다.
    func testChildFeedTreatsNaNLifetimeAsAlive() {
        let feed = ParticleControlPointMath.childControlPointFeed(
            startIndex: 0, parentLifetimes: [.nan],
            childControlPointFlags: Array(repeating: 0, count: 8))
        XCTAssertEqual(feed, [Feed(slot: 0, parentParticle: 0)])
    }

    /// **막힌 슬롯은 영구 정체다** — 실물 `thunderbolt.json → thunderbolt_child_spawner.json`
    /// 이 정확히 이 모양이다(자식 CP 1 이 `flags: 4`). 슬롯 0 하나만 채워지고 끝난다.
    /// 정체가 아니라 "다음 슬롯으로 넘어간다" 로 구현하면 이 단언이 깨진다.
    func testChildFeedBlockedSlotStallsForever() {
        var flags = Array(repeating: 0, count: 8)
        flags[1] = 0x4                                  // 부모 부착 CP — 피드가 못 쓴다
        let feed = ParticleControlPointMath.childControlPointFeed(
            startIndex: 0, parentLifetimes: [1, 1, 1, 1, 1], childControlPointFlags: flags)
        XCTAssertEqual(feed, [Feed(slot: 0, parentParticle: 0)])
    }

    /// 슬롯이 8 에 닿으면 남은 부모 파티클을 무시하고 끝난다.
    func testChildFeedStopsAtEightSlots() {
        let feed = ParticleControlPointMath.childControlPointFeed(
            startIndex: 6, parentLifetimes: [1, 1, 1, 1],
            childControlPointFlags: Array(repeating: 0, count: 8))
        XCTAssertEqual(feed, [Feed(slot: 6, parentParticle: 0),
                              Feed(slot: 7, parentParticle: 1)])
    }

    /// `startIndex >= 8` 이면 아예 안 돈다(`cmp edx, 8` / `jge` @0x14022a715).
    func testChildFeedStartIndexAtLimitDoesNothing() {
        XCTAssertTrue(ParticleControlPointMath.childControlPointFeed(
            startIndex: 8, parentLifetimes: [1, 1],
            childControlPointFlags: Array(repeating: 0, count: 8)).isEmpty)
        XCTAssertEqual(ParticleControlPointMath.childFeedForcesEightSlots, 8)
    }

    // MARK: - remap 출력 CP 표시

    /// bit16 은 저작 키가 아니라 파서가 세운다 — **출력 채널이 `controlpoint`(16)일 때만**.
    func testRemapOutputMark() {
        XCTAssertEqual(ParticleControlPointMath.remapOutputMarkedSlot(
            outputChannelIndex: 16, outputControlPoint0: 3), 3)
        // 다른 채널은 표시하지 않는다 — 동봉에서 실제로 쓰이는 것들.
        for channel in [0, 2, 3, 4, 13, 14, 15, 17, 18] {
            XCTAssertNil(ParticleControlPointMath.remapOutputMarkedSlot(
                outputChannelIndex: channel, outputControlPoint0: 3), "channel=\(channel)")
        }
        // 8 이상은 상한 검사(0x1401d0863)에 걸려 무시된다.
        XCTAssertNil(ParticleControlPointMath.remapOutputMarkedSlot(
            outputChannelIndex: 16, outputControlPoint0: 8))
        XCTAssertNil(ParticleControlPointMath.remapOutputMarkedSlot(
            outputChannelIndex: 16, outputControlPoint0: -1))
    }

    /// 표시된 CP 는 `0x10005` 게이트에 걸려 씬 오버라이드를 못 받고, 매 프레임 갱신도 안 받는다.
    func testRemapOutputMarkBlocksOverrideAndUpdate() {
        guard let slot = ParticleControlPointMath.remapOutputMarkedSlot(
            outputChannelIndex: 16, outputControlPoint0: 1) else { return XCTFail("표시 실패") }
        XCTAssertEqual(slot, 1)
        let flags = ParticleControlPointFlag.remapOutput
        let r = ParticleControlPointMath.applyInstanceOverride(
            base: .identity, flags: flags,
            overrideAngles: Vec3(x: ParticleControlPointMath.unspecified, y: 0, z: 0),
            overrideTranslation: Vec3(x: 5, y: 5, z: 5))
        XCTAssertTrue(r.skipped)
        XCTAssertEqual(update(flags, index: slot, world: true), .untouched)
    }
}
