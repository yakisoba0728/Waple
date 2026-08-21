import Foundation

/// `effects/fluidsimulation` 의 **패스별 프래그먼트 산술**을 Foundation 만으로 재현한다.
///
/// 왜 여기(WapleCore)인가
/// ---------------------
/// 이 이펙트의 규약은 전부 GLSL 소스에 평문으로 적혀 있다(공통 브리프 함정 #6). 그런데
/// 그 산식이 Waple 쪽에서 사는 자리는 `Sources/WapleRender` 의 MSL 번역·인코더라, 리눅스
/// 레인에서는 **타입체크까지만** 검사된다(`docs/dev/re-methodology.md` §4.3). 값이 맞는지는
/// 아무것도 잠그지 않는다. 그래서 "원본과 갈리면 그림이 틀리는" 자리들만 순수 스칼라로 뽑아
/// 리눅스 테스트로 덮는다. `import simd` 는 쓰지 않는다 — 쓰면 리눅스에서 타입체크조차
/// 못 한다(`Model3DFormat.swift` 머리말과 같은 이유).
///
/// 출처
/// ----
/// 동봉 `Sources/WapleRender/Resources/WEAssets/effects/fluidsimulation/shaders/effects/*.frag|vert`
/// (설치본 `wallpaper_engine/assets/...` 와 `diff -rq` 0건). 각 함수 주석에 **그 줄의 GLSL 을
/// 그대로** 옮겨 적는다 — 줄 번호는 적지 않는다(`re-methodology.md` #22: 한 줄만 밀려도
/// 엉뚱한 곳을 가리킨다).
///
/// 단위 규약(§2.12)
/// ---------------
/// * 속도 단위 = **그리드 텍셀 / 초**. UV 로 되돌릴 때만 `× 1/해상도` 를 곱한다.
/// * 유한차분은 전부 `Δx = Δy = 1 텍셀` 을 가정한다. 그래서 `fit` 이 종횡비를 보존한다.
/// * 시뮬 `dt = min(1/20, g_Frametime)`. **압력 감쇠와 중력만 생 `g_Frametime`** 을 쓴다.
public enum FluidSimulation {

    /// 2성분 벡터. `SIMD2<Double>` 를 안 쓰는 이유는 하나 — `XCTAssertEqual` 로 한 줄 대조가
    /// 되게 `Equatable` 을 보장하고, 튜플이 아니라 이름 붙은 값으로 남기기 위해서다.
    public struct Vec2: Equatable, CustomStringConvertible {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
        public var length: Double { (x * x + y * y).squareRoot() }
        public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
        public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
        public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
        public var description: String { "(\(x), \(y))" }
    }

    // MARK: - GLSL 프리미티브

    /// GLSL `step(edge, x)` — `x < edge ? 0 : 1`. **`x == edge` 는 1** 이다.
    @inlinable
    public static func step(_ edge: Double, _ x: Double) -> Double { x < edge ? 0 : 1 }

    /// HLSL `saturate(x)` = `clamp(x, 0, 1)`.
    @inlinable
    public static func saturate(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// GLSL `smoothstep(edge0, edge1, x)` — **문면 그대로**(에르미트 다항식).
    ///
    /// `edge0 > edge1` 인 역방향 호출은 GLSL/MSL 명세상 "결과 미정의" 지만 두 백엔드 모두
    /// `t = saturate((x-e0)/(e1-e0)); t*t*(3-2t)` 로 계산한다. 이 이펙트의 염료 에미터가
    /// 정확히 그 형태(`smoothstep(size, 0.0, length(delta))`)를 쓴다 — §5.4.
    @inlinable
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = saturate((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    // MARK: - 시간 · 클램프 규약 (§2.12)

    /// 시뮬 타임스텝 상한. `advection.frag` · `vorticity.frag` 가 각각
    /// `float dt = min(1.0/20.0, g_Frametime);` 로 같은 상수를 박는다. 20 fps 아래로
    /// 떨어져도 한 스텝이 50 ms 를 못 넘는다.
    public static let simulationTimeStepCap: Double = 1.0 / 20.0

    /// `dt = min(1/20, g_Frametime)`.
    @inlinable
    public static func simulationTimeStep(frameTime: Double) -> Double {
        min(simulationTimeStepCap, frameTime)
    }

    /// `velocity = min(max(velocity, -1000.0), 1000.0);` — 텍셀/초.
    public static let velocityClamp: Double = 1000

    // MARK: - 패스 0 : curl (§2.2)

    /// ```glsl
    /// float L = texSample2D(g_Texture0, vL).y;   float R = texSample2D(g_Texture0, vR).y;
    /// float T = texSample2D(g_Texture0, vT).x;   float B = texSample2D(g_Texture0, vB).x;
    /// float vorticity = R - L - T + B;
    /// gl_FragColor = vec4(0.5 * vorticity, 0.0, 0.0, 1.0);
    /// ```
    /// `L`/`R` 은 **속도의 y 성분**, `T`/`B` 는 **x 성분**이다(스위즐이 뒤바뀌어 있다).
    /// `1/(2Δx)` 의 `Δx` 를 접어 버려 결과 단위가 "텍셀" 로 남는다.
    @inlinable
    public static func curl(velocityYLeft: Double, velocityYRight: Double,
                            velocityXTop: Double, velocityXBottom: Double) -> Double {
        0.5 * (velocityYRight - velocityYLeft - velocityXTop + velocityXBottom)
    }

    // MARK: - 패스 1 : 와도 구속 (§2.3)

    /// ```glsl
    /// vec2 force = 0.5 * vec2(abs(T) - abs(B), abs(R) - abs(L));
    /// force /= length(force) + 0.0001;
    /// force *= u_Curl * C;
    /// force.y *= -1.0;
    /// ```
    /// 성분 순서가 **일부러 (∂y, ∂x) 로 뒤바뀌어** 들어오고 그 뒤 `force.y *= -1` 이
    /// 2차원 외적 `ω·(N × ẑ)` 를 만든다. `+0.0001` 이 0-나눗셈 가드다.
    public static func vorticityConfinementForce(curlLeft: Double, curlRight: Double,
                                                 curlTop: Double, curlBottom: Double,
                                                 curlCenter: Double, curlStrength: Double) -> Vec2 {
        var force = Vec2(0.5 * (abs(curlTop) - abs(curlBottom)),
                         0.5 * (abs(curlRight) - abs(curlLeft)))
        let denominator = force.length + 0.0001
        force = Vec2(force.x / denominator, force.y / denominator)
        force = force * (curlStrength * curlCenter)
        return Vec2(force.x, -force.y)
    }

    /// ```glsl
    /// velocity += force * dt;
    /// velocity = min(max(velocity, -1000.0), 1000.0);
    /// ```
    /// **중요 — 클램프는 여기서 끝난다.** 셰이더는 이 뒤에 에미터(§5.4)와 커서 임펄스(§5.2)를
    /// 더하고 **다시 클램프하지 않는다**. 즉 이 패스의 출력은 ±1000 을 넘을 수 있다.
    /// 마지막에 한 번만 클램프하는 순진한 이식은 여기서 갈린다.
    @inlinable
    public static func applyVorticityConfinement(velocity: Vec2, force: Vec2, dt: Double) -> Vec2 {
        let v = Vec2(velocity.x + force.x * dt, velocity.y + force.y * dt)
        return Vec2(min(max(v.x, -velocityClamp), velocityClamp),
                    min(max(v.y, -velocityClamp), velocityClamp))
    }

    // MARK: - 패스 2 : 발산 + 유일한 명시 경계조건 (§2.4)

    /// ```glsl
    /// if (vL.x < 0.0) { L = -C.x; }
    /// if (vR.x > 1.0) { R = -C.x; }
    /// if (vT.y > 1.0) { T = -C.y; }
    /// if (vB.y < 0.0) { B = -C.y; }
    /// float div = 0.5 * (R - L + T - B);
    /// ```
    /// 이 `if` 넷이 **솔버 전체에서 유일한 명시 경계조건**이다 — 도메인 밖 고스트 셀의
    /// 법선 속도를 내부값의 반사 `-C` 로 두어 벽을 통과하지 못하게 한다.
    /// 접선 성분은 손대지 않아 샘플러 clamp(가장자리 복제) = 자유 미끄럼이 된다.
    ///
    /// - Parameters:
    ///   - neighborLeftU/neighborRightU/neighborTopV/neighborBottomV:
    ///     정점보간으로 들어온 **이웃 좌표**. 프래그먼트 중심이 `(i+0.5)/N` 이라
    ///     최외곽 한 줄에서만 조건이 발화한다.
    public static func divergence(velocityXLeft: Double, velocityXRight: Double,
                                  velocityYTop: Double, velocityYBottom: Double,
                                  center: Vec2,
                                  neighborLeftU: Double, neighborRightU: Double,
                                  neighborTopV: Double, neighborBottomV: Double) -> Double {
        var l = velocityXLeft, r = velocityXRight, t = velocityYTop, b = velocityYBottom
        if neighborLeftU < 0.0 { l = -center.x }
        if neighborRightU > 1.0 { r = -center.x }
        if neighborTopV > 1.0 { t = -center.y }
        if neighborBottomV < 0.0 { b = -center.y }
        return 0.5 * (r - l + t - b)
    }

    // MARK: - 패스 3 : 압력 감쇠 (§2.5)

    /// ```glsl
    /// v_TexCoord.z = pow(u_Pressure, 60 * g_Frametime);   // .vert
    /// gl_FragColor = v_TexCoord.z * texSample2D(g_Texture0, v_TexCoord.xy);   // .frag
    /// ```
    /// **여기만 `dt`(1/20 클램프)가 아니라 생 `g_Frametime`** 을 쓴다. 지수를 `60Δt` 로
    /// 두어 감쇠가 프레임률 독립이다 — 60 fps 에서 지수 1(= "1/60 초당 ×u_Pressure").
    /// 이름은 `clear` 지만 완전 소거가 아니라 **지수 감쇠**이고, 전 프레임 압력장을
    /// 초기추정으로 재활용하는 따뜻한 시작 장치다.
    @inlinable
    public static func pressureDecayFactor(pressure: Double, frameTime: Double) -> Double {
        pow(pressure, 60 * frameTime)
    }

    // MARK: - 패스 4–12 : Jacobi ×9 (§2.6)

    /// 매니페스트에 **같은 패스가 9번 복제**돼 있다. 콤보로도 저작 키로도 조절되지 않는다.
    public static let pressureIterationCount = 9

    /// ```glsl
    /// float pressure = (L + R + B + T - divergence) * 0.25;
    /// ```
    /// 표준형 `(L+R+B+T + α·b)/β` 에서 `α = -1`, `β = 4`(Δx = 1 텍셀).
    /// 셰이더가 중심값 `C` 도 읽지만 **쓰지 않는다**(원본에 남은 죽은 로컬).
    @inlinable
    public static func jacobiPressure(left: Double, right: Double, top: Double, bottom: Double,
                                      divergence: Double) -> Double {
        (left + right + bottom + top - divergence) * 0.25
    }

    // MARK: - 패스 13 : 압력 경사 제거 (§2.7)

    /// ```glsl
    /// velocity.xy -= vec2(R - L, T - B);
    /// ```
    /// **`0.5` 가 없다.** curl/divergence 의 중심차분에는 있고 여기만 없어서, 투영이
    /// 발산 연산자 대비 **2배 과이완**이다. 참조 구현(PavelDoGreat)과 같은 형태이고
    /// §2.13(c) 의 수치 실험이 "반복 9회에서는 원본이 이긴다" 를 보였다 —
    /// **반복수와 이 계수는 한 쌍이다. 둘 중 하나만 고치지 마라.**
    @inlinable
    public static func subtractPressureGradient(velocity: Vec2,
                                                pressureLeft: Double, pressureRight: Double,
                                                pressureTop: Double, pressureBottom: Double) -> Vec2 {
        Vec2(velocity.x - (pressureRight - pressureLeft),
             velocity.y - (pressureTop - pressureBottom))
    }

    // MARK: - 패스 14 · 15 : 이류 (§2.8 · §2.9)

    /// ```glsl
    /// vec2 coord = vUv - dt * texSample2D(g_Texture0, vUv).xy * texelSize;
    /// ```
    /// `texelSize = 1/g_Texture0Resolution.xy` 이고 **슬롯 0 은 두 패스 모두 속도 텍스처**다.
    /// 염료 패스에서도 속도 그리드 해상도를 쓴다 — 이걸 염료 해상도로 착각하면
    /// 이류 거리가 `scale:2` 만큼 틀린다(§2.9).
    @inlinable
    public static func advectionSourceCoordinate(uv: Vec2, velocity: Vec2,
                                                 dt: Double, texelSize: Vec2) -> Vec2 {
        Vec2(uv.x - dt * velocity.x * texelSize.x,
             uv.y - dt * velocity.y * texelSize.y)
    }

    /// ```glsl
    /// float decay = 1.0 + decayFactor * m_Dissipation * dt;
    /// ```
    /// `decayFactor` 는 속도 패스에서 `u_Viscosity`(`viscosityfactor`), 염료 패스에서
    /// `u_Dissipation`(`dissipationfactor`). `m_Dissipation` 은 머티리얼 상수로
    /// 속도 0.2 · 염료 0.4 다.
    @inlinable
    public static func advectionDecay(decayFactor: Double, materialDissipation: Double,
                                      dt: Double) -> Double {
        1.0 + decayFactor * materialDissipation * dt
    }

    /// ```glsl
    /// float lowPass = step(length(result.rgb), u_Lifetime) * 0.5;
    /// ```
    /// UI 라벨은 "high pass" 지만 실제는 컷오프다. 분모에 **더해지므로**(곱이 아니다)
    /// 발화 시 `÷1.5` 가 된다. 인자는 **마스킹 전** 샘플의 rgb 길이다.
    @inlinable
    public static func advectionLowPass(sampleMagnitude: Double, lifetime: Double) -> Double {
        step(sampleMagnitude, lifetime) * 0.5
    }

    /// ```glsl
    /// float boundaryMask = step(0.0,coord.x)*step(coord.x,1.0)*step(0.0,coord.y)*step(coord.y,1.0);
    /// ```
    /// **염료 패스에만** 있다(속도 패스에는 없다). 도메인 밖으로 역추적된 픽셀을 경성 절단해
    /// 가장자리에서 염료가 clamp 로 번지는 것을 막는다 — 솔버에서 유일하게 명시적으로
    /// 버리는 자리다.
    @inlinable
    public static func dyeBoundaryMask(_ coord: Vec2) -> Double {
        step(0.0, coord.x) * step(coord.x, 1.0) * step(0.0, coord.y) * step(coord.y, 1.0)
    }

    /// ```glsl
    /// vec2 constantSpeed = vec2(sin(u_ConstantVelocityAngle), -cos(u_ConstantVelocityAngle))
    ///                      * u_ConstantVelocityStrength;
    /// constantSpeed.y *= aspect;
    /// gl_FragColor.xy += constantSpeed * g_Frametime;
    /// ```
    /// **중력만 생 `g_Frametime`** 을 쓴다(다른 항은 `dt`). `aspect = res.y/res.x` 라
    /// §1.3 의 `fit` 종횡비가 여기서 그림에 직접 닿는다 — 정사각으로 읽으면 세로 성분이
    /// 1920×1080 에서 1.78배 세진다.
    @inlinable
    public static func constantForce(angle: Double, strength: Double,
                                     aspect: Double, frameTime: Double) -> Vec2 {
        Vec2(sin(angle) * strength * frameTime,
             -cos(angle) * strength * aspect * frameTime)
    }

    // MARK: - 에미터 (§5.4)

    /// ```glsl
    /// vec2 delta = position - texCoord;
    /// //delta.y *= aspect;
    /// float amt = step(length(delta), size) * speed;
    /// vec2 emitterSpeed = vec2(sin(angle), -cos(angle)) * amt;
    /// //emitterSpeed.y *= aspect;
    /// ```
    /// **`aspect` 를 인자로 받지만 두 줄 다 주석 처리돼 쓰이지 않는다** — 속도 에미터의
    /// 디스크는 UV 상 원이고 화면상으로는 **타원**이다(원본 그대로).
    /// 호출부가 `speed` 자리에 `g_Frametime * m_EmitterSpeedN` 을 넘긴다.
    public static func pointEmitterVelocity(uv: Vec2, position: Vec2, angle: Double,
                                            size: Double, speed: Double,
                                            frameTime: Double) -> Vec2 {
        let delta = position - uv
        let amount = step(delta.length, size) * (frameTime * speed)
        return Vec2(sin(angle) * amount, -cos(angle) * amount)
    }

    /// ```glsl
    /// vec2 delta = position - texCoord;
    /// delta.y *= aspect;
    /// float amt = smoothstep(size, 0.0, length(delta));
    /// ```
    /// **염료 에미터는 `aspect` 를 쓴다** — 즉 속도 주입은 타원, 색 주입은 화면상 원이라는
    /// 원본 비대칭이 여기서 생긴다.
    public static func pointEmitterDyeAmount(uv: Vec2, position: Vec2,
                                             size: Double, aspect: Double) -> Double {
        let delta = Vec2(position.x - uv.x, (position.y - uv.y) * aspect)
        return smoothstep(size, 0.0, delta.length)
    }

    /// 선 에미터의 선분 최근접점.
    /// ```glsl
    /// vec2 lineDelta = linePosB - linePosA;
    /// float distLineDelta = length(lineDelta) + 0.0001;
    /// lineDelta /= distLineDelta;
    /// float distOnEmitterLine = dot(lineDelta, texCoord - linePosA);
    /// distOnEmitterLine = max(0.0, min(distLineDelta, distOnEmitterLine));
    /// vec2 posOnEmitterLine = linePosA + lineDelta * distOnEmitterLine;
    /// ```
    public static func closestPointOnEmitterLine(uv: Vec2, a: Vec2, b: Vec2) -> Vec2 {
        var direction = b - a
        let length = direction.length + 0.0001
        direction = Vec2(direction.x / length, direction.y / length)
        var t = direction.x * (uv.x - a.x) + direction.y * (uv.y - a.y)
        t = max(0.0, min(length, t))
        return Vec2(a.x + direction.x * t, a.y + direction.y * t)
    }

    /// ```glsl
    /// float amt = step(length(delta), size) * g_Frametime * speed;
    /// vec2 emitterSpeed = vec2(sin(angle), -cos(angle)) * amt;
    /// emitterSpeed *= step(CAST2(0.5), noise);
    /// ```
    /// 노이즈 게이트가 **성분별**(x·y 독립)이라 선을 따라 힘이 얼룩덜룩 켜졌다 꺼진다.
    /// 노이즈 UV 는 `emitterUV * 0.1 + g_Time * 0.01`.
    /// 점 에미터와 달리 `g_Frametime` 곱이 **헬퍼 안**에 있다(호출부는 생 speed 를 넘긴다) —
    /// 결과적으로 둘 다 Δt 에 1회 비례한다.
    public static func lineEmitterVelocity(uv: Vec2, a: Vec2, b: Vec2, angle: Double,
                                           size: Double, speed: Double,
                                           frameTime: Double, noise: Vec2) -> Vec2 {
        let onLine = closestPointOnEmitterLine(uv: uv, a: a, b: b)
        let delta = uv - onLine
        let amount = step(delta.length, size) * frameTime * speed
        return Vec2(sin(angle) * amount * step(0.5, noise.x),
                    -cos(angle) * amount * step(0.5, noise.y))
    }

    /// 선 에미터 노이즈 좌표: `emitterUV * 0.1 + g_Time * 0.01`.
    @inlinable
    public static func lineEmitterNoiseCoordinate(uv: Vec2, time: Double) -> Vec2 {
        Vec2(uv.x * 0.1 + time * 0.01, uv.y * 0.1 + time * 0.01)
    }

    // MARK: - 커서 임펄스 (§5.1 · §5.2)

    /// ```glsl
    /// v_PointDelta.y = 60.0 / max(0.0001, u_CursorInfluence);
    /// v_PointerUV.w  = g_Texture0Resolution.y / -g_Texture0Resolution.x;   // 그 뒤 *= -v_PointDelta.y
    /// ```
    /// 결과는 임펄스 반경의 **역수** 쌍 `(60/c, (H/W)·60/c)`. 두 번의 부호가 상쇄돼 양수다.
    /// 반경은 UV 로 x 축 `c/60`, y 축 `(c/60)·(W/H)` — 화면 픽셀로 환산하면 **원**이 된다.
    public static func cursorImpulseFalloffScale(cursorInfluence: Double,
                                                 resolutionWidth: Double,
                                                 resolutionHeight: Double) -> Vec2 {
        let inverseRadius = 60.0 / max(0.0001, cursorInfluence)
        let w = resolutionHeight / -resolutionWidth
        return Vec2(inverseRadius, w * -inverseRadius)
    }

    /// ```glsl
    /// float moveAmt = length(g_PointerPosition - g_PointerPositionLast);
    /// v_PointDelta.x = step(0, moveAmt) * 0.5 + moveAmt * 10.0 * u_CursorInfluence;
    /// float inputStrength = pointerDist * timeAmt * (pointerMoveAmt + g_PointerState.z);
    /// ```
    /// `moveAmt` 는 길이라 항상 ≥ 0 이므로 `step(0, moveAmt)` 는 **항상 1** — 상수항 0.5 다.
    /// `timeAmt` 는 셰이더에 `1.0` 으로 박혀 있다(주석 처리된 `g_Frametime / 0.1` 이 옆에 있다).
    @inlinable
    public static func cursorImpulseStrengthScalar(pointerMove: Double, cursorInfluence: Double,
                                                   pointerButtonForce: Double) -> Double {
        (step(0, pointerMove) * 0.5 + pointerMove * 10.0 * cursorInfluence) + pointerButtonForce
    }

    /// 커서 임펄스 전체(§5.2). 반환값은 속도에 **더할** 증분(텍셀/초)이다.
    ///
    /// ```glsl
    /// vec2 lDelta = unprojectedUVs - unprojectedUVsLast;
    /// float distLDelta = length(lDelta) + 0.0001;   lDelta /= distLDelta;
    /// float distOnLine = dot(lDelta, texSource - unprojectedUVsLast);
    /// float rayMask = max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.1));
    /// distOnLine = saturate(distOnLine / distLDelta) * distLDelta;
    /// vec2 posOnLine = unprojectedUVsLast + lDelta * distOnLine;
    /// ... pointerDist = saturate(1.0 - length((texSource - posOnLine) * vec2(v_PointDelta.y, v_PointerUV.w)));
    /// velocity += colorAdd * 300;
    /// ```
    /// 커서가 멈춰 있으면 `lDelta ≈ 0/1e-4 = 0` 이라 세기의 상수항 0.5 와 클릭 항이 있어도
    /// 힘이 0 이다 — 방향이 0 이기 때문이다.
    public static func cursorImpulse(uv: Vec2, pointer: Vec2, pointerLast: Vec2,
                                     cursorInfluence: Double, pointerButtonForce: Double,
                                     pointerMove: Double,
                                     resolutionWidth: Double, resolutionHeight: Double,
                                     rippleMask: Double = 1.0) -> Vec2 {
        var lineDelta = pointer - pointerLast
        let lineLength = lineDelta.length + 0.0001
        lineDelta = Vec2(lineDelta.x / lineLength, lineDelta.y / lineLength)
        let texDelta = uv - pointerLast
        var distanceOnLine = lineDelta.x * texDelta.x + lineDelta.y * texDelta.y
        let rayMask = max(step(0.0, distanceOnLine) * step(distanceOnLine, lineLength),
                          step(lineLength, 0.1))
        distanceOnLine = saturate(distanceOnLine / lineLength) * lineLength
        let onLine = Vec2(pointerLast.x + lineDelta.x * distanceOnLine,
                          pointerLast.y + lineDelta.y * distanceOnLine)
        let scale = cursorImpulseFalloffScale(cursorInfluence: cursorInfluence,
                                              resolutionWidth: resolutionWidth,
                                              resolutionHeight: resolutionHeight)
        let scaled = Vec2((uv.x - onLine.x) * scale.x, (uv.y - onLine.y) * scale.y)
        let cone = saturate(1.0 - scaled.length) * rayMask * rippleMask
        let strength = cone * cursorImpulseStrengthScalar(pointerMove: pointerMove,
                                                          cursorInfluence: cursorInfluence,
                                                          pointerButtonForce: pointerButtonForce)
        return Vec2(lineDelta.x * strength * 300, lineDelta.y * strength * 300)
    }

    // MARK: - 패스 16 : 염료 α → 노멀 (§2.10)

    /// ```glsl
    /// vec2 base = vec2(s10 - refAlpha, s01 - refAlpha) * CAST2(25.0 * u_Depth);
    /// base = clamp(base, CAST2(-1.0), CAST2(1.0)) * refAlpha;
    /// vec3 normal = vec3(base, 0.0);  normal.x = -normal.x;
    /// normal.z = sqrt(saturate(1.0 - normal.x*normal.x - normal.y*normal.y));
    /// gl_FragColor = vec4(normal * CAST3(0.5) + CAST3(0.5), 1.0);
    /// ```
    /// **전진차분**(중심차분이 아니다)이고, 게인 `25·u_Depth` → `[-1,1]` 클램프 → `×refAlpha`
    /// 순서가 중요하다: 클램프가 곱 **앞**이라 염료가 옅은 곳이 평평(0,0,1)해진다.
    /// 반환값은 `rgba8888` 에 담기는 0…1 패킹값이다.
    public static func dyeNormalPacked(refAlpha: Double, alphaRight: Double, alphaTop: Double,
                                       depth: Double) -> (r: Double, g: Double, b: Double) {
        let gain = 25.0 * depth
        var bx = (alphaRight - refAlpha) * gain
        var by = (alphaTop - refAlpha) * gain
        bx = min(max(bx, -1.0), 1.0) * refAlpha
        by = min(max(by, -1.0), 1.0) * refAlpha
        let nx = -bx
        let ny = by
        let nz = saturate(1.0 - nx * nx - ny * ny).squareRoot()
        return (nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5)
    }

    // MARK: - `functions` 소비 결함 (§4.2)

    /// **원본 결함의 재현식**(Waple 은 이것을 쓰지 않는다 — §4.6 의 의도적 이탈).
    ///
    /// `Effect::executeMaterialFunction`(`0x1401ee3a0`–`0x1401ee51b`)의 루프는 파스된
    /// `fboIndices` 벡터에서 **개수만** 뽑고(`0x1401ee411`–`0x1401ee41b`: end−begin, `sar rax,2`)
    /// 인덱싱은 전부 카운터 `ebp` 로 한다(`0x1401ee447`–`0x1401ee451`). 즉 이름이 가리키는
    /// 버퍼가 아니라 **`fbos` 배열의 앞에서부터 n 장**을 비운다.
    ///
    /// 경계 검사도 없다 — 중복 이름을 걸러내지 않으므로 `n > fboCount` 가 가능하고 실물에서는
    /// 범위 밖 접근이다(§4.5). 여기서는 그 사실을 **관측 가능한 값**으로 남기려고
    /// 잘라내지 않고 `n` 개를 그대로 돌려준다. `outOfRange` 로 몇 개가 밖인지 센다.
    public static func materialFunctionClearedIndicesWE(declaredCount: Int,
                                                        fboCount: Int) -> (indices: [Int], outOfRange: Int) {
        let indices = Array(0..<max(0, declaredCount))
        return (indices, indices.filter { $0 >= fboCount }.count)
    }
}
