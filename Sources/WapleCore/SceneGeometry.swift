import Foundation

public struct Vec2: Equatable {
    public let x: Float
    public let y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

public struct Vec3: Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}

/// 씬 **카메라 모션**(shake · parallax · 레이어 원근)의 순수 산술.
///
/// 왜 `WapleCore` 에 있는가
/// -----------------------
/// 소비자는 전부 `WapleRender`(`import Metal`/`AppKit`)라 **리눅스에서 한 줄도 실행 검증이
/// 안 된다** — `scripts/dev/linux-render-typecheck.sh` 는 타입만 본다. camerashake 수식이
/// 실물과 완전히 다른 근사로 오래 살아남은 것(§C-1..C-3, `docs/re/camera-motion.md` §7)도
/// 그 공백 때문이다. 그래서 산수 본체를 여기 두고 렌더 쪽은 **얇은 위임만** 남긴다.
/// 여기 있는 함수는 전부 `Tests/WapleCoreTests/SceneGeometryCameraMathTests.swift` 가
/// 닫힌 식 값으로 잠근다.
///
/// 근거
/// ----
/// `wallpaper64.exe`(imagebase `0x140000000`) 실측. 전문·재현 절차는 `docs/re/camera-motion.md`.
/// 이 파일의 주석에 적힌 VA 는 전부 이 레인에서 직접 다시 떠서 확인한 것이다.
///
/// **난수원 없음.** shake 도 parallax 도 `g_Time`·마우스·`dt` 의 **결정적** 함수다 —
/// 노이즈 테이블도 RNG 도 타지 않는다(§2.4 배제 근거). 즉 이 산술을 켠다고
/// `SnapshotPipeline.captureRandomSeed` 의 캡처 결정성이 깨지지 않는다.
public enum SceneCameraMath {

    // MARK: - camerashake  (0x140199580 – 0x14019977c)

    /// shake 위상. **속도의 제곱**이다(`0x1401995f7 mulss xmm6, xmm6` → `0x140199600 mulss xmm6, [rs+0x130]`).
    /// `speed` 를 2배로 하면 주파수가 4배가 된다. 에디터 기본 `speed=3` → `phi = 9·t`.
    @inline(__always)
    public static func shakePhase(speed: Float, time: Float) -> Float { speed * speed * time }

    /// `camerashake` 한 프레임의 카메라 델타. eye 와 target 에 **같은 값**을 더하므로
    /// 순수 평행이동이다 — 회전도 롤도 없다(`0x140199712`–`0x14019976a`, `up`(scene+0x108) 미접촉).
    ///
    /// ```
    /// phi = speed² · time
    /// v   = ( cosf(phi), sinf(phi · 1.3329999446868896), sinf(phi) )   ; 0x14019960b/0x14019961e/0x14019962a
    /// k   = powf(roughness, 3)                                        ; 0x1401995cd (상수 3.0 @0x140492830)
    /// if k > 0.001 && k != 1 { v = v / |v| · powf(|v|, k) }            ; 0x140199657 · 0x14019966e
    /// 2D(정사영): v.z = 0 ;  scale = orthoHeight · 0.1 · (amplitude · 0.1)   ; 0x14019963b–0x14019964c
    /// 3D(원근)  :            scale = amplitude · 0.1                        ; 0x1401995fb / 0x140199653
    /// delta = v · scale
    /// ```
    ///
    /// - `roughness` 는 **주파수 노브가 아니다.** `powf` 지수로만 쓰이는 **크기 리매핑**(`|v|^(r³)`)이라
    ///   저작 기본값 1.0 은 `ucomiss … je` 로 블록을 통째로 건너뛰어 **완전 무연산**이다.
    ///   `r ≤ 0.1` 이면 `r³ ≤ 0.001` 경계에 걸려 역시 건너뛴다.
    /// - 2D 진폭 단위는 **정사영 픽셀**(`amplitude · H / 100`), 3D 는 **월드 단위**(`amplitude · 0.1`).
    ///   NDC 상수 배율이 아니다.
    ///
    /// - Parameter time: `g_Time`(초). 실물은 432000초에서 0 으로 되감는다(`0x14017fcde`–`0x14017fcf6`).
    /// - Parameter orthoHeight: `orthogonalprojection.height`. `orthographic == false` 면 무시된다.
    public static func shakeDelta(time: Float, speed: Float, amplitude: Float, roughness: Float,
                                  orthographic: Bool, orthoHeight: Float) -> Vec3 {
        let k = powf(roughness, 3)
        let phi = shakePhase(speed: speed, time: time)
        var vx = cosf(phi)
        var vy = sinf(phi * 1.3329999446868896)
        var vz = sinf(phi)
        let scale: Float
        if orthographic {
            vz = 0
            scale = orthoHeight * 0.1 * (amplitude * 0.1)
        } else {
            scale = amplitude * 0.1
        }
        // 거칠기 리매핑 — k 가 0.001 이하거나 정확히 1.0 이면 실물이 건너뛴다(부동소수 동점 포함).
        if k > 0.0010000000474974513 && k != 1 {
            let len = sqrtf(vx * vx + vy * vy + vz * vz)
            let m = powf(len, k)
            vx = (vx / len) * m
            vy = (vy / len) * m
            vz = (vz / len) * m
        }
        return Vec3(x: vx * scale, y: vy * scale, z: vz * scale)
    }

    // MARK: - cameraparallax  (0x140189b42 – 0x140189cf3)

    /// 시차 **초점**(정사영 픽셀 좌표). 캔버스 중앙과 마우스 위치를 `mouseInfluence` 로 선형보간하고
    /// 카메라 eye 의 xy 를 더한다(`0x140189bda`–`0x140189c24`).
    ///
    /// ```
    /// focus.x = W·0.5·(1 − infl) + W·clamp01(pointer.x)       ·infl + eye.x
    /// focus.y = H·0.5·(1 − infl) + H·clamp01(1 − pointer.y)   ·infl + eye.y
    /// ```
    ///
    /// **시간 항이 없다.** 자동 드리프트는 존재하지 않으며 `dt` 는 아래 스무딩에만 들어간다.
    /// `mouseInfluence` 는 게인이 아니라 보간 계수라 **0 이어도 초점이 캔버스 중앙에 남는다** —
    /// 그 상태의 레이어 오프셋은 시차가 아니라 초점 기준 **정적 확대**가 된다.
    ///
    /// - Parameter pointer: `g_PointerPosition`(renderState+0x8c, 0..1). y 는 실물이 뒤집어 쓴다.
    /// - Parameter eye: shake 가 이미 가산된 런타임 eye(scene+0xf0/0xf4) — 2D 코퍼스는 전건 (0,0).
    /// - Parameter mirrorX: renderState 플래그 bit11(포인터 X 미러, `0x140189bac`).
    public static func parallaxFocus(pointer: Vec2, mouseInfluence infl: Float,
                                     projW: Float, projH: Float,
                                     eye: Vec2 = Vec2(x: 0, y: 0), mirrorX: Bool = false) -> Vec2 {
        var mx = min(max(pointer.x, 0), 1)
        let my = min(max(1 - pointer.y, 0), 1)
        if mirrorX { mx = 1 - mx }
        let fx = projW * 0.5 * (1 - infl) + projW * mx * infl + eye.x
        let fy = projH * 0.5 * (1 - infl) + projH * my * infl + eye.y
        return Vec2(x: fx, y: fy)
    }

    /// `cameraparallaxdelay` 의 수렴 계수. **지연 시간(초)이 아니라 수렴률의 역파라미터다.**
    ///
    /// ```
    /// 0x140189c15  comiss xmm0, xmm5 / jbe   ; delay <= 0 → 스무딩 자체를 건너뜀(즉시 스냅)
    /// 0x140189c2e  divss  xmm0, xmm11        ; xmm11 = 3.0  (0x1401899b1 ← 0x140492830)
    /// 0x140189c37  subss  xmm4, xmm0         ; 1 − delay/3  (xmm15 = 1.0)
    /// 0x140189c3b  mulss  xmm4, [0x140492868]; × 10.0
    /// 0x140189c43  mulss  xmm4, xmm6         ; × dt
    /// 0x140189c47  comiss xmm15, xmm4 / ja   ; alpha = min(1, ·)   ← 상한만 있다
    /// ```
    ///
    /// **하한 클램프를 넣지 않는다.** `delay == 3` 이면 alpha 가 정확히 0 이라 영구 정지하고,
    /// `delay > 3` 이면 음수가 되어 발산한다 — 실물 그대로다. 코퍼스 도달은 `0.1` 176건 · `1` 1건뿐이라
    /// (동봉 168 + 설치본 175 씬 기준) 이 구간에 닿는 자산이 없다.
    ///
    /// **프레임률 독립이 아니다.** alpha 가 `dt` 에 **선형**(1차 저역통과의 지수 형태
    /// `1 − exp(−dt/τ)` 가 아니다)이라 60Hz 와 120Hz 가 엄밀히는 다르다. 스텝당 alpha 가 작을 때만
    /// 둘 다 `e^{−rate·t}` 를 근사해 가까워진다(실측 1초 후 차이 2.8e-5 @delay 0.3).
    /// `rate = 10·(1 − delay/3)` [1/s], 실효 시상수 `τ = 0.3/(3 − delay)` 초.
    @inline(__always)
    public static func parallaxAlpha(dt: Float, delay: Float) -> Float {
        min(1, 10 * (1 - delay / 3) * dt)
    }

    /// 시차 초점 스무딩 한 스텝. `delay <= 0` 이면 실물이 분기 자체를 건너뛰어 즉시 스냅한다.
    public static func parallaxSmoothed(current: Vec2, target: Vec2, dt: Float, delay: Float) -> Vec2 {
        guard delay > 0 else { return target }
        let a = parallaxAlpha(dt: dt, delay: delay)
        return Vec2(x: current.x + (target.x - current.x) * a,
                    y: current.y + (target.y - current.y) * a)
    }

    /// 레이어 시차 오프셋 — `(origin − focus) × amount × parallaxDepth`, **z 는 항상 0**
    /// (`0x14018a0b3`–`0x14018a115`, z 항은 `amount × 0`).
    ///
    /// 게이트가 **둘**이다(`0x140189f17`–`0x140189f22`): `cameraparallax`(scene flags bit8) **그리고**
    /// `orthogonalprojection`(bit3). 3D 씬에서는 이 채널이 아예 없고 `g_ParallaxPosition` 유니폼만 갱신된다.
    ///
    /// 기하학적으로는 초점 기준 스케일 아웃이다: `newOrigin = focus + (origin − focus)·(1 + amount·depth)`.
    public static func parallaxLayerOffset(origin: Vec2, focus: Vec2, amount: Float, depth: Vec2) -> Vec3 {
        Vec3(x: amount * (origin.x - focus.x) * depth.x,
             y: amount * (origin.y - focus.y) * depth.y,
             z: 0)
    }

    /// `g_ParallaxPosition`(renderState+0x9c) — `clamp01(focus / 정사영크기)`.
    /// 무저작 2D 씬(eye=(0,0), infl=0)은 정확히 `(0.5, 0.5)` 다.
    /// `depthparallax.vert:44` 의 `g_ParallaxPosition*2−1` 이 이 정규화를 확증한다.
    public static func parallaxUniform(focus: Vec2, projW: Float, projH: Float, mirrorX: Bool = false) -> Vec2 {
        var ux = min(max(focus.x / projW, 0), 1)
        let uy = min(max(focus.y / projH, 0), 1)
        if mirrorX { ux = 1 - ux }
        return Vec2(x: ux, y: uy)
    }

    // MARK: - 레이어 perspective 플래그  (0x140184f00 – 0x140184ff7)

    /// 레이어 `perspective:true` 가 쓰는 가상 카메라의 **거리**.
    ///
    /// 실물은 정사영 씬의 view/proj 를 그 레이어에 대해서만 갈아끼운다(`0x1401ed265` 게이트 →
    /// `0x140184f00`). 거리는 정사영 투영행렬의 `m[1][1]` 에서 역산한다:
    ///
    /// ```
    /// 0x140184f17  xmm6 = rs[0x110]                 ; 실효 fov(라디안) = perspectiveoverridefov·π/180
    /// 0x140184f30  xmm0 = tanf(fov · 0.5)           ; 0x14041b0d0 = tanf(소각 근사 x + x³/3 @0x140471e98)
    /// 0x140184f43  xmm1 = 1.0 / proj[0x14]          ; proj[0x14] = m[1][1] = 2/H
    /// 0x140184f54  d    = 1.0 / (tan(fov/2) · m11)  ; = H / (2·tan(fov/2))
    /// ```
    ///
    /// 즉 **z=0 평면이 정사영과 똑같은 크기로 찍히는 거리**다. 저작 기본 `fov=95°, H=256` → `d ≈ 117.29`.
    public static func layerPerspectiveDistance(orthoHeight: Float, fovRadians: Float) -> Float {
        let m11 = 2 / orthoHeight                    // 정사영 투영 [1][1] = 2/H
        let inv = 1 / m11                            // 0x140184f43  divss xmm1, [proj+0x14]
        let t = tanf(fovRadians * 0.5)               // 0x140184f28/0x140184f30
        return 1 / (t / inv)                         // 0x140184f48 → 0x140184f54 (나눗셈 순서 그대로)
    }

    /// `general.fov` / `general.perspectiveoverridefov` 의 도(度) → 라디안. 실물이 쓰는 상수
    /// `0x140492628` = `0.01745329238474369`(f32)를 그대로 쓴다(`0x140183dd1` 정사영 경로 ·
    /// `0x140183f38` 원근 경로 — 둘 다 같은 상수라 **fov 단위는 도**로 확정).
    @inline(__always)
    public static func fovDegreesToRadians(_ deg: Float) -> Float { deg * 0.01745329238474369 }

    /// 도 단위 편의 오버로드.
    public static func layerPerspectiveDistance(orthoHeight: Float, fovDegrees: Float) -> Float {
        layerPerspectiveDistance(orthoHeight: orthoHeight, fovRadians: fovDegreesToRadians(fovDegrees))
    }

    /// 레이어 `perspective:true` 에서 **z 가 화면 크기에 먹는 배율**.
    ///
    /// 카메라는 캔버스 중앙 `(W·cx, H·cy)` 위 거리 `d` 에 놓이고 −z 를 본다
    /// (`view.m[12] -= W·rs[0xf8]` / `view.m[13] -= H·rs[0xfc]` / `view.m[14] = −d`,
    /// `0x140184f4c`–`0x140184fb3`). 크롭이 없으면 `rs[0xf8] = rs[0xfc] = 0.5`
    /// (`0x140183d96`/`0x140183dc1`: `0.5 − (크롭차)/(2·크기)`).
    ///
    /// 그래서 원근분할 뒤 화면 좌표는
    ///
    /// ```
    /// s(z)       = d / (d − z)
    /// screen_xy  = center + (world_xy − center) · s(z)
    /// ```
    ///
    /// `z = 0` 이면 `s = 1` 이라 정사영과 **픽셀 동일**이다 — 코퍼스의 유일한 저작 사례
    /// (`presets/clock/preview3dclock/scene.json`)가 `origin.z = 0` 이라 실피해가 0인 이유가 이것이다.
    /// `z ≥ d` 는 카메라 평면 뒤라 실물도 클립된다. 이 순수 배율 함수는 식 자체만 반환하고,
    /// 실제 쿼드 소비자는 `layerPerspectiveClip`으로 near/far를 먼저 자른다.
    public static func layerPerspectiveScale(z: Float, orthoHeight: Float, fovDegrees: Float) -> Float {
        let d = layerPerspectiveDistance(orthoHeight: orthoHeight, fovDegrees: fovDegrees)
        return d / (d - z)
    }

    /// 레이어 원근 카메라의 near/far. near 는 리터럴 5.0(`0x140184fd2`),
    /// far 는 `max(15000, d + 1000)`(`0x140184f6f`/`0x140184fa7`/`0x140184faf`).
    public static func layerPerspectiveClip(distance d: Float) -> (near: Float, far: Float) {
        (5, max(15000, d + 1000))
    }
}
