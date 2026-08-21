import Foundation

// MARK: - 값 타입

/// 한 프레임의 씬 카메라 자세. 실물 슬롯은 `scene+0xf0`(eye) · `+0xfc`(center) ·
/// `+0x108`(up) · `+0x114`(zoom) 이다(`docs/re/camera-motion.md` §1.2).
public struct CameraPose: Equatable {
    public var eye: Vec3
    public var center: Vec3
    public var up: Vec3
    public var zoom: Float

    public init(eye: Vec3, center: Vec3, up: Vec3, zoom: Float) {
        self.eye = eye; self.center = center; self.up = up; self.zoom = zoom
    }
}

/// `camera.paths` → `scripts/camera_XX.json` 의 한 transform.
///
/// 바이너리 레이아웃은 스트라이드 `0x2c`: `+0x00` timestamp · `+0x04` eye(3) ·
/// `+0x10` center(3) · `+0x1c` up(3) · `+0x28` zoom
/// (로드 VA `0x1401894eb`/`0x140189506`/`0x1401896db`/`0x140189815`/`0x140189951`).
public struct CameraPathTransform: Equatable {
    public var timestamp: Float
    public var eye: Vec3
    public var center: Vec3
    public var up: Vec3
    public var zoom: Float

    public init(timestamp: Float, eye: Vec3, center: Vec3, up: Vec3, zoom: Float = 1) {
        self.timestamp = timestamp; self.eye = eye; self.center = center
        self.up = up; self.zoom = zoom
    }

    public var pose: CameraPose { CameraPose(eye: eye, center: center, up: up, zoom: zoom) }
}

/// 하나의 카메라 경로. 스트라이드 `0x20`: `+0x00/+0x08` transforms begin/end ·
/// `+0x18` duration(`0x1401899d4`, `0x140189ab5`, camerafade `0x140180c4c`).
public struct CameraPath: Equatable {
    public var duration: Float
    public var transforms: [CameraPathTransform]

    public init(duration: Float, transforms: [CameraPathTransform]) {
        self.duration = duration; self.transforms = transforms
    }
}

/// 경로 재생 상태. 실물은 `scene+0xe4`(경로 인덱스) · `+0xe8`(transform 인덱스) ·
/// `+0xec`(현재 경로 안에서의 **절대** 경과 초)에 있다.
///
/// `+0xe8` 과 `+0xec` 이 **연속한 qword** 라는 점이 의미가 있다 — 경로를 넘길 때
/// `0x140189ad9  mov qword ptr [rbx+0xe8], 0` 한 번으로 **둘 다** 0 이 된다.
/// 즉 경로 전환은 transform 인덱스와 경과 시간을 함께 리셋하고, transform 만 넘길 때는
/// 경과 시간을 유지한다(`0x140189ac5` 는 dword 스토어다).
public struct CameraPathState: Equatable {
    public var pathIndex: Int
    public var transformIndex: Int
    public var elapsed: Float

    public init(pathIndex: Int = 0, transformIndex: Int = 0, elapsed: Float = 0) {
        self.pathIndex = pathIndex; self.transformIndex = transformIndex; self.elapsed = elapsed
    }
}

// MARK: - CameraMotion

/// 씬 **카메라 모션**의 순수 산술 오라클 — 경로 재생 · camerafade · 실효 fov/zoom ·
/// 2D eye 재중심화, 그리고 이 넷과 shake/parallax 를 한 프레임으로 엮는 합성기.
///
/// 왜 `SceneCameraMath` 와 따로 있는가
/// -----------------------------------
/// `SceneCameraMath`(`SceneGeometry.swift`)는 **무상태 스칼라 수식**(shake 델타, 시차 초점,
/// 수렴 계수, 레이어 오프셋/유니폼, 레이어 원근)을 담는다. 여기 있는 것은 **시간에 따라
/// 상태가 굴러가는** 축이다 — 경로 인덱스·transform 인덱스·경과 시간이 프레임마다 바뀐다.
/// 두 축을 한 파일에 섞으면 "이 함수는 상태를 만지나?" 를 매번 다시 읽어야 한다.
///
/// `import simd` 를 쓰지 않는다
/// ---------------------------
/// `Model3DFormat.swift` 머리말과 같은 이유다. simd 를 쓰면 리눅스에서 타입체크조차 못 하고,
/// 그러면 이 산술은 macOS CI 에 닿기 전까지 한 줄도 검증되지 않는다. 카메라 shake 수식이
/// 실물과 전혀 다른 근사로 오래 살아남은 것(`docs/re/camera-motion.md` §7 C-1..C-3)이 정확히
/// 그 공백에서 나왔다. `Vec2`/`Vec3` 는 `SceneGeometry.swift` 의 Foundation 전용 값 타입이다.
///
/// 근거
/// ----
/// `wallpaper64.exe`(imagebase `0x140000000`) 실측. `Scene::updateCamera`
/// `0x1401891a0` – `0x140189e07`(`.pdata` 9조각, `merged()` 로 병합 확인).
/// 전문·재현 절차는 `docs/re/camera-motion.md` §2·§3·§4·§8.
///
/// **자동회전(autorotate)은 존재하지 않는다.** 씬 JSON 에도 `lib.sceneScript.d.ts` 에도
/// 그런 키가 없고, 바이너리가 아는 카메라 키 15개(`docs/re/camera-motion.md` §6.7)에도 없다.
/// WE 에서 "시간이 알아서 미는" 유일한 카메라 축은 **`camera.paths` 재생**이다 —
/// shake 는 시간의 함수지만 진폭이 상수라 감쇠도 트리거도 없고, parallax 는 시간 항이
/// 아예 없다(마우스 전용).
///
/// **난수원이 없다.** 여기 있는 어떤 함수도 RNG·노이즈 테이블을 타지 않는다.
///
/// `Sendable` 을 붙이지 않는 이유
/// ---------------------------
/// 값 타입뿐이라 붙여도 맞지만, 재료인 `Vec2`/`Vec3`(`SceneGeometry.swift`)가 아직
/// `Sendable` 이 아니다. 그 상태에서 여기만 `Sendable` 을 선언하면
/// "stored property … has non-sendable type 'Vec3'; this is an error in the Swift 6 language mode"
/// 경고가 파일당 아홉 줄 난다 — 이 패키지는 `-strict-concurrency=complete` 로 그 목록을
/// **소진하는 중**이라(Package.swift 머리말) 새 항목을 얹는 셈이 된다. 순서가 반대다:
/// `Vec2`/`Vec3` 에 `Sendable` 이 붙은 뒤에 여기도 붙이면 경고 없이 끝난다.
public enum CameraMotion {

    // MARK: - 경로 보간 — 3차 에르미트 (0x1401894a9 – 0x1401899d2)

    /// 3차 에르미트 기저. 실물은 `u`, `u²`, `u³` 에서 네 계수를 이 순서로 만든다:
    ///
    /// ```
    /// 0x140189572  xmm1  = u·u                     ; u²
    /// 0x140189582  xmm12 = u²·u                    ; u³
    /// 0x14018957d  xmm0  = u²·3.0                  ; 3u²   (3.0 @0x140492830)
    /// 0x140189593  xmm11 = u³ − u²                 ; h11
    /// 0x140189598  xmm13 = u³ + u³                 ; 2u³
    /// 0x14018959d  xmm1  = u² + u²                 ; 2u²
    /// 0x1401895a1  xmm14 = 3u² − 2u³               ; h01
    /// 0x1401895a6  xmm13 = 2u³ − 3u²
    /// 0x1401895b3  xmm12 = u³ − 2u²
    /// 0x1401895c0  xmm13 = (2u³ − 3u²) + 1.0       ; h00
    /// 0x1401895c5  xmm12 = (u³ − 2u²) + u          ; h10
    /// ```
    public struct HermiteBasis: Equatable {
        public let h00: Float
        public let h10: Float
        public let h01: Float
        public let h11: Float
    }

    /// 위 명령 순서를 그대로 따른다(부동소수 결합 순서까지).
    public static func hermiteBasis(_ u: Float) -> HermiteBasis {
        let u2 = u * u
        let u3 = u2 * u
        let threeU2 = u2 * 3.0
        let h11 = u3 - u2
        let twoU3 = u3 + u3
        let twoU2 = u2 + u2
        let h01 = threeU2 - twoU3
        let h00 = (twoU3 - threeU2) + 1.0
        let h10 = (u3 - twoU2) + u
        return HermiteBasis(h00: h00, h10: h10, h01: h01, h11: h11)
    }

    /// 구간 접선. **양 끝이 같다** — 실물은 이웃 제어점을 구간 끝점으로 **클램프**한 채
    /// 카트멀-롬 접선을 계산하므로, 컴파일러가 `p0 − p0` / `p1 − p1` 을 남긴 형태로 나온다:
    ///
    /// ```
    /// 0x140189969  subss xmm3, xmm0   ; (p0 − p0)   ← 이전 제어점 = p0
    /// 0x140189975  subss xmm1, xmm0   ; (p1 − p0)
    /// 0x14018997e  mulss xmm3, 0.5    ; 0.5·(p0 − p0)
    /// 0x140189989  mulss xmm1, 0.5    ; 0.5·(p1 − p0)
    /// 0x14018998d  addss xmm3, xmm1   ; m0
    /// 0x140189985  subss xmm0, xmm2   ; (p1 − p1)   ← 다음 제어점 = p1
    /// 0x140189995  addss xmm0, xmm1   ; m1
    /// ```
    ///
    /// 그래서 `m0 = m1 = 0.5·(p1 − p0)` 이고, **구간 안에서 두 제어점 말고는 아무것도 읽지
    /// 않는다**(`imul` 이 `idx`·`idx+1` 두 개뿐 — `0x1401894bd`/`0x140189530`).
    /// 경로 사이 C¹ 연속이 아니라 **구간별 이즈**다.
    ///
    /// 실물이 남긴 `0.5·(x − x)` 항은 **유한한 입력에서 항상 정확히 +0.0** 이라
    /// (`-0.0 − -0.0 = +0.0` 포함) 여기서는 생략했다. ±Inf/NaN 제어점에서만 갈리는데
    /// 그런 자산은 코퍼스에 없다.
    @inline(__always)
    public static func segmentTangent(_ p0: Float, _ p1: Float) -> Float {
        (p1 - p0) * 0.5
    }

    /// 한 성분의 에르미트 보간. 누산 순서까지 실물과 같다
    /// (`((m0·h10 + h00·p0) + m1·h11) + h01·p1` — `0x14018961b`→`0x140189620`→`0x140189631`→`0x140189636`).
    public static func hermite(p0: Float, p1: Float, u: Float) -> Float {
        let b = hermiteBasis(u)
        let m = segmentTangent(p0, p1)
        var acc = m * b.h10
        acc += b.h00 * p0
        acc += m * b.h11
        acc += b.h01 * p1
        return acc
    }

    /// 위 에르미트가 **닫힌 식으로는** `p0 + (p1 − p0)·f(u)`, `f(u) = −u³ + 1.5u² + 0.5u` 라는 것.
    ///
    /// `m0 = m1 = 0.5Δ` 를 대입하면
    /// `h00·p0 + h01·p1 + (h10 + h11)·0.5Δ = p0 + Δ·(3u² − 2u³) + Δ·(u³ − 1.5u² + 0.5u)` 다.
    /// `f(0) = 0`, `f(1) = 1`, `f′(0) = f′(1) = 0.5` — **양 끝 기울기가 0 이 아니다**.
    /// 스무스스텝(`3u² − 2u³`, 양 끝 기울기 0)이 **아니라는** 것이 요점이다.
    ///
    /// 부동소수 누산 순서가 달라 `hermite(p0:p1:u:)` 와 비트동일하지는 않다 — 확인용 항등식이다.
    @inline(__always)
    public static func hermiteFraction(_ u: Float) -> Float {
        -(u * u * u) + 1.5 * (u * u) + 0.5 * u
    }

    /// 벡터 3성분 에르미트.
    public static func hermite(_ p0: Vec3, _ p1: Vec3, u: Float) -> Vec3 {
        Vec3(x: hermite(p0: p0.x, p1: p1.x, u: u),
             y: hermite(p0: p0.y, p1: p1.y, u: u),
             z: hermite(p0: p0.z, p1: p1.z, u: u))
    }

    // MARK: - 경로 샘플링

    /// `sample(paths:state:)` 이 고른 팔. 팔마다 **구간 종료 시각의 정의가 다르다**.
    public enum PathArm: Equatable {
        /// `elapsed < transforms[i].timestamp` — 아직 구간이 시작하지 않았다(`0x1401894f7 jb`).
        /// 자세는 `transforms[i]` 로 스냅하고, 구간 끝은
        /// `timestamp[i] + (다음이 있으면 timestamp[i+1] 아니면 0)` 이다(`0x1401899f3 addss`).
        case beforeSegment
        /// `i+1 >= count` — 마지막 transform 을 붙들고 있다(`0x140189500 jae`).
        /// 구간 끝은 `duration − timestamp[i]` 다(`0x1401899da subss`).
        case holdingLast
        /// 두 제어점 사이 에르미트 보간. 구간 끝은 `timestamp[i+1]` 이다(`0x140189552`).
        case interpolating
    }

    public struct PathSample: Equatable {
        public let pose: CameraPose
        /// `elapsed` 가 이 값을 **넘으면**(초과, 같으면 아니다 — `0x140189a8f jbe`) 전진한다.
        public let segmentEnd: Float
        public let arm: PathArm
        public let u: Float
    }

    /// 경로 재생 한 프레임의 자세. 실물의 세 팔을 그대로 재현한다.
    ///
    /// `nil` 을 주는 경우: 경로 배열이 비었거나 인덱스가 범위를 벗어났거나 transform 이 없다.
    /// 실물은 **첫 경로**의 transform 유무만 보고(`0x140189261`–`0x140189269`) 나머지는 방어하지
    /// 않아 그런 자산에서는 범위 밖을 읽는다 — 여기서는 읽지 않고 `nil` 을 준다.
    /// (설치본 21경로 전건이 transform 1~2개라 실제로 갈리는 자산은 없다.)
    public static func sample(paths: [CameraPath], state: CameraPathState) -> PathSample? {
        guard paths.indices.contains(state.pathIndex) else { return nil }
        let path = paths[state.pathIndex]
        guard path.transforms.indices.contains(state.transformIndex) else { return nil }
        let cur = path.transforms[state.transformIndex]
        let next = state.transformIndex + 1
        let count = path.transforms.count

        // 0x1401894f4  comiss xmm3(elapsed), xmm2(cur.timestamp) / jb
        if state.elapsed < cur.timestamp {
            let tail: Float = next < count ? path.transforms[next].timestamp : 0
            return PathSample(pose: cur.pose, segmentEnd: tail + cur.timestamp,
                              arm: .beforeSegment, u: 0)
        }
        // 0x1401894fd  cmp r8(i+1), rax(count) / jae
        if next >= count {
            return PathSample(pose: cur.pose, segmentEnd: path.duration - cur.timestamp,
                              arm: .holdingLast, u: 0)
        }
        let nxt = path.transforms[next]
        // 0x14018950d  subss xmm3, xmm2  →  0x140189567  divss xmm3, xmm0
        let u = (state.elapsed - cur.timestamp) / (nxt.timestamp - cur.timestamp)
        let pose = CameraPose(eye: hermite(cur.eye, nxt.eye, u: u),
                              center: hermite(cur.center, nxt.center, u: u),
                              up: hermite(cur.up, nxt.up, u: u),
                              zoom: hermite(p0: cur.zoom, p1: nxt.zoom, u: u))
        return PathSample(pose: pose, segmentEnd: nxt.timestamp, arm: .interpolating, u: u)
    }

    /// 경로 재생 상태 전진(`0x140189a74` – `0x140189b07`).
    ///
    /// ```
    /// elapsed += dt                                          ; 0x140189a77 · 0x140189a87
    /// if (elapsed <= segmentEnd) return                       ; 0x140189a8f jbe
    /// if (i+1 < count && duration > timestamp[i+1])           ; 0x140189ab0 jae · 0x140189abf jbe
    ///      transformIndex = i+1                               ; 0x140189ac5  (dword — elapsed 유지)
    /// else transformIndex = 0, elapsed = 0                    ; 0x140189ad9  (qword — 둘 다 0)
    ///      pathIndex = (pathIndex + 1) % pathCount            ; 0x140189afc cmovae
    /// ```
    ///
    /// `duration > timestamp[i+1]` 조건이 중요하다 — 마지막 transform 의 timestamp 가 duration 과
    /// **같으면**(설치본 21경로 중 16건) transform 을 넘기지 않고 곧장 **다음 경로**로 간다.
    public static func advanced(paths: [CameraPath], state: CameraPathState,
                                dt: Float, segmentEnd: Float) -> CameraPathState {
        var s = state
        s.elapsed += dt
        guard s.elapsed > segmentEnd else { return s }
        guard paths.indices.contains(s.pathIndex) else { return s }
        let path = paths[s.pathIndex]
        let next = s.transformIndex + 1
        if next < path.transforms.count, path.duration > path.transforms[next].timestamp {
            s.transformIndex = next
            return s
        }
        s.transformIndex = 0
        s.elapsed = 0
        s.pathIndex = (s.pathIndex + 1 >= paths.count) ? 0 : s.pathIndex + 1
        return s
    }

    /// 샘플 + 전진을 한 번에. 실물 순서를 지킨다 — **자세를 먼저 뽑고(그 자세로 shake 를 얹고)
    /// 그 다음에 시간을 민다**(`0x140189a6f` shake → `0x140189a77` elapsed += dt).
    public static func step(paths: [CameraPath], state: CameraPathState,
                            dt: Float) -> (sample: PathSample, next: CameraPathState)? {
        guard let s = sample(paths: paths, state: state) else { return nil }
        return (s, advanced(paths: paths, state: state, dt: dt, segmentEnd: s.segmentEnd))
    }

    /// 한 경로가 실제로 재생되는 시간(구간 경계를 무한소 정밀도로 본 값).
    ///
    /// `holdingLast` 팔의 구간 끝이 `duration − timestamp[last]` 라서, 마지막 timestamp 가
    /// 0 이 아니면서 `duration > timestamp[last]` 인 경로는 **저작한 duration 보다
    /// `timestamp[last]` 만큼 짧게** 끝난다.
    ///
    /// 설치본 21경로 중 이 조건에 걸리는 것은 `demon_core/scripts/camera_00.json` 의 4개뿐이다
    /// (300→260 · 450→416 · 400→360 · 350→314초). 나머지 16경로는 `duration == timestamp[last]`
    /// 라 마지막 transform 으로 아예 넘어가지 않고 곧장 다음 경로로 간다. `neon_sunset` 은
    /// transform 이 하나이고 그 timestamp 가 0 이라 `5 − 0 = 5` 로 저작값과 같다.
    public static func effectivePathDuration(_ path: CameraPath) -> Float {
        let ts = path.transforms
        guard !ts.isEmpty else { return path.duration }
        var i = 0
        while i + 1 < ts.count {
            // 0x140189abf  comiss duration, timestamp[i+1] / jbe → 다음 **경로** 로 간다
            if !(path.duration > ts[i + 1].timestamp) { return ts[i + 1].timestamp }
            i += 1
        }
        return max(ts[i].timestamp, path.duration - ts[i].timestamp)
    }

    // MARK: - camerafade  (0x140180c0b – 0x140180cc0)

    /// 경로 구간의 처음/끝 0.5초를 덮는 페이드 알파. **씬 시작 페이드인이 아니다** —
    /// `camerafade` 가 켜져도 `camera.paths` 가 없으면 머티리얼조차 로드되지 않는다
    /// (`0x140181bb7`–`0x140181bc5`).
    ///
    /// ```
    /// rem = duration − elapsed                    ; 0x140180c56
    /// if (0.5 > rem)          a = 1 − 2·rem       ; 0x140180c5e → 0x140180c81
    /// else if (rem <= duration − 0.5) a = 0       ; 0x140180c6c jbe  (구간 한가운데)
    /// else                    a = 1 − 2·(duration − rem)   ; 0x140180c77
    /// draw only if a > 0                          ; 0x140180c90 comiss/jbe
    /// ```
    ///
    /// 덮는 색은 검정이 아니라 `materials/util/fade.json` 의 `schemecolor × 0.7` 이다
    /// (`fade.frag`: `gl_FragColor = vec4(color * 0.7, g_Alpha)`).
    ///
    /// - Note: 알파는 `renderState+0x120`(= `g_Alpha`)에 실린다(`0x140180ca2`).
    public static func fadeAlpha(elapsed: Float, duration: Float) -> Float {
        let rem = duration - elapsed
        if 0.5 > rem { return 1 - (rem + rem) }
        if rem <= duration - 0.5 { return 0 }
        let inElapsed = duration - rem
        return 1 - (inElapsed + inElapsed)
    }

    /// 페이드 오버레이가 실제로 그려지는가. `camerafade` 플래그 · 경로 존재 · 인덱스 유효 ·
    /// `alpha > 0` 을 전부 본다(`0x140180c1a` · `0x140180c34` · `0x140180c46` · `0x140180c90`).
    public static func fadeOverlayAlpha(cameraFade: Bool, paths: [CameraPath],
                                        state: CameraPathState) -> Float? {
        guard cameraFade, !paths.isEmpty, paths.indices.contains(state.pathIndex) else { return nil }
        let a = fadeAlpha(elapsed: state.elapsed, duration: paths[state.pathIndex].duration)
        return a > 0 ? a : nil
    }

    // MARK: - 실효 fov / zoom / 2D eye

    /// 실효 fov(도) 선택 — **2D 는 `perspectiveoverridefov`, 3D 는 `fov`** 다.
    ///
    /// ```
    /// 0x140189278  mov   eax, 0x144        ; perspectiveoverridefov 슬롯
    /// 0x140189292  mov   edx, 0x140        ; fov 슬롯
    /// 0x140189286  test  r9b, 8            ; scene flags bit3 = orthogonalprojection
    /// 0x1401892a0  cmove eax, edx          ; bit3 == 0(3D) 이면 fov
    /// ```
    @inline(__always)
    public static func effectiveFovDegrees(orthographic: Bool, fov: Float,
                                           perspectiveOverrideFov: Float) -> Float {
        orthographic ? perspectiveOverrideFov : fov
    }

    /// fov 클램프 `[0.1, 179.9]`(`0x140189b1a` – `0x140189b3f`).
    ///
    /// 비교 형태까지 실물을 따른다 — 상한은 `minss`(피연산자 하나가 NaN 이면 **두 번째**를 준다),
    /// 하한은 `comiss` + `ja`(순서 없음이면 점프하지 않는다). 그래서 `fov = NaN` 이면
    /// 결과가 NaN 이 아니라 **179.9** 다. Swift 의 `min(_:_:)` 은 NaN 을 그대로 흘리므로
    /// 여기서 삼항 연산을 쓰는 것이 의도한 것이다.
    public static func clampedFovDegrees(_ fov: Float) -> Float {
        let upper: Float = (fov < 179.89999389648438) ? fov : 179.89999389648438
        let lower: Float = 0.10000000149011612
        return (lower > upper) ? lower : upper
    }

    /// 실효 zoom — **정사영(2D) 씬에서만** 살아 있고 두 채널의 곱이다
    /// (`0x14017fd45` 게이트 · `0x14017fd50` `general.zoom` · `0x14017fd5d` × 카메라/경로 zoom).
    /// 3D 씬에서는 zoom 블록 자체를 건너뛴다 — 그래서 여기서는 1 을 준다.
    @inline(__always)
    public static func effectiveZoom(orthographic: Bool, generalZoom: Float,
                                     cameraZoom: Float) -> Float {
        orthographic ? generalZoom * cameraZoom : 1
    }

    /// 2D eye 재중심화(`0x140189da0` – `0x140189df0`). 뷰 행렬은 **이 보정 전** eye 로 이미
    /// 만들어졌으므로(`0x140189d0b`–`0x140189d8b`) 이것은 **셰이더가 보는 `g_EyePosition`** 만 고친다.
    ///
    /// ```
    /// rs[0x68] += (float)rs[0x84] · 0.5     ; 정사영 폭은 정수 슬롯이다(cvtdq2ps)
    /// rs[0x6c] += (float)rs[0x88] · 0.5
    /// rs[0x70]  = 2000.0                    ; imm 0x44fa0000 — 정사영 far 평면과 같은 값
    /// ```
    public static func recentered2DEye(eye: Vec3, orthoWidth: Int32, orthoHeight: Int32) -> Vec3 {
        Vec3(x: eye.x + Float(orthoWidth) * 0.5,
             y: eye.y + Float(orthoHeight) * 0.5,
             z: 2000)
    }

    // MARK: - 프레임 합성

    /// `Scene::updateCamera` 한 프레임의 입력. 이름은 전부 저작 키를 따른다.
    public struct FrameInput {
        /// `g_Time`(초). 실물은 432000초에서 0 으로 되감는다(`0x14017fcde`).
        public var time: Float
        /// 프레임 델타. **시차 수렴 계수와 경로 전진에만** 들어간다 — shake 는 `time` 만 본다.
        public var dt: Float
        /// `general.orthogonalprojection` 이 있는가(scene flags bit3).
        public var orthographic: Bool
        /// 정사영 폭/높이(`scene+0x354`/`+0x358`).
        public var orthoWidth: Float
        public var orthoHeight: Float
        /// shake 를 얹기 **전** 자세(카메라 레이어 · 경로 · `camera.eye/center/up` 중 하나).
        public var pose: CameraPose
        public var cameraShake: Bool
        public var shakeSpeed: Float
        public var shakeAmplitude: Float
        public var shakeRoughness: Float
        public var cameraParallax: Bool
        public var parallaxAmount: Float
        public var parallaxDelay: Float
        public var parallaxMouseInfluence: Float
        /// `g_PointerPosition`(renderState+0x8c, 0..1).
        public var pointer: Vec2
        /// 직전 프레임의 초점(`scene+0x340/0x344`).
        public var previousFocus: Vec2
        /// `renderState+0x118 & 0x200200` — 서면 마우스 영향이 0 으로 강제된다(`0x140189b67`).
        /// 두 비트의 이름은 미상이다.
        public var forcePointerCenter: Bool
        /// `renderState+0x118` bit11 — 포인터 X 미러(`0x140189bac`).
        public var mirrorPointerX: Bool
        /// 클램프 **전** 실효 fov(도).
        public var fovDegrees: Float

        public init(time: Float, dt: Float, orthographic: Bool,
                    orthoWidth: Float, orthoHeight: Float, pose: CameraPose,
                    cameraShake: Bool = false, shakeSpeed: Float = 3,
                    shakeAmplitude: Float = 0.5, shakeRoughness: Float = 1,
                    cameraParallax: Bool = false, parallaxAmount: Float = 0.5,
                    parallaxDelay: Float = 0.1, parallaxMouseInfluence: Float = 0,
                    pointer: Vec2 = Vec2(x: 0.5, y: 0.5),
                    previousFocus: Vec2 = Vec2(x: 0, y: 0),
                    forcePointerCenter: Bool = false, mirrorPointerX: Bool = false,
                    fovDegrees: Float = 95) {
            self.time = time; self.dt = dt; self.orthographic = orthographic
            self.orthoWidth = orthoWidth; self.orthoHeight = orthoHeight; self.pose = pose
            self.cameraShake = cameraShake; self.shakeSpeed = shakeSpeed
            self.shakeAmplitude = shakeAmplitude; self.shakeRoughness = shakeRoughness
            self.cameraParallax = cameraParallax; self.parallaxAmount = parallaxAmount
            self.parallaxDelay = parallaxDelay
            self.parallaxMouseInfluence = parallaxMouseInfluence
            self.pointer = pointer; self.previousFocus = previousFocus
            self.forcePointerCenter = forcePointerCenter; self.mirrorPointerX = mirrorPointerX
            self.fovDegrees = fovDegrees
        }
    }

    public struct FrameOutput: Equatable {
        /// shake 가 얹힌 최종 자세.
        public let pose: CameraPose
        /// 클램프된 fov(도).
        public let fovDegrees: Float
        /// 이번 프레임의 시차 초점(`scene+0x340/0x344`). `cameraParallax` 가 꺼져 있으면
        /// **직전 값 그대로**다 — 실물이 블록 전체를 건너뛰기 때문이다(`0x140189b54 je`).
        public let focus: Vec2
        /// `g_ParallaxPosition`(renderState+0x9c). 시차가 꺼져 있으면 `nil` — 실물은 이 슬롯을
        /// 갱신하지 않는다(생성자 값이 남는다).
        public let parallaxUniform: Vec2?
    }

    /// `Scene::updateCamera` 의 **소비 순서**를 그대로 밟는다. 이 순서가 결과를 바꾼다:
    /// 시차 초점이 `scene+0xf0`(= shake 가 **이미 더해진** eye)을 읽으므로
    /// (`0x140189c18`/`0x140189c24`), 2D 에서 shake 와 parallax 를 같이 켜면
    /// `g_ParallaxPosition` 도 함께 떤다.
    ///
    /// ```
    /// ① shake 를 eye/center 에 같은 델타로 가산     0x140199712 – 0x14019976a
    /// ② fov 클램프                                  0x140189b1a – 0x140189b4c
    /// ③ 시차 초점 + 스무딩 + 유니폼                 0x140189b42 – 0x140189cf3
    /// ```
    ///
    /// 경로 전진(`elapsed += dt`)은 ①과 ② 사이에 있지만 자세에 영향을 주지 않으므로
    /// 여기서는 다루지 않는다 — `step(paths:state:dt:)` 를 따로 부르면 된다.
    public static func frame(_ input: FrameInput) -> FrameOutput {
        var pose = input.pose

        // ① camerashake — eye 와 target 에 **같은** 델타. up 은 건드리지 않는다(= 롤 없음).
        if input.cameraShake {
            let d = SceneCameraMath.shakeDelta(time: input.time, speed: input.shakeSpeed,
                                               amplitude: input.shakeAmplitude,
                                               roughness: input.shakeRoughness,
                                               orthographic: input.orthographic,
                                               orthoHeight: input.orthoHeight)
            pose.eye = Vec3(x: pose.eye.x + d.x, y: pose.eye.y + d.y, z: pose.eye.z + d.z)
            pose.center = Vec3(x: pose.center.x + d.x, y: pose.center.y + d.y,
                               z: pose.center.z + d.z)
        }

        // ② fov 클램프
        let fov = clampedFovDegrees(input.fovDegrees)

        // ③ cameraparallax
        guard input.cameraParallax else {
            return FrameOutput(pose: pose, fovDegrees: fov, focus: input.previousFocus,
                               parallaxUniform: nil)
        }
        let infl = input.forcePointerCenter ? 0 : input.parallaxMouseInfluence
        let target = SceneCameraMath.parallaxFocus(pointer: input.pointer, mouseInfluence: infl,
                                                   projW: input.orthoWidth,
                                                   projH: input.orthoHeight,
                                                   eye: Vec2(x: pose.eye.x, y: pose.eye.y),
                                                   mirrorX: input.mirrorPointerX)
        let focus = SceneCameraMath.parallaxSmoothed(current: input.previousFocus, target: target,
                                                     dt: input.dt, delay: input.parallaxDelay)
        let uniform = SceneCameraMath.parallaxUniform(focus: focus, projW: input.orthoWidth,
                                                      projH: input.orthoHeight,
                                                      mirrorX: input.mirrorPointerX)
        return FrameOutput(pose: pose, fovDegrees: fov, focus: focus, parallaxUniform: uniform)
    }
}
