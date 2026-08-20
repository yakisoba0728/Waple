import Foundation
import simd

// MARK: - 요소 타입

public enum Emitter: Equatable {
    /// 평면화 가능한 구 분포. dir = normalize(randUnit ⊙ directions); pos = origin + dir*rand(distMin,distMax).
    /// burst = 실물 "instantaneous"(버스트 개수, 0=연속 rate 방출). sign = 축별 방향 강제(+1/-1, 0=무클램프).
    case sphere(origin: Vec3, directions: Vec3, distanceMin: Float, distanceMax: Float,
                rate: Float, burst: Int, sign: Vec3)
    /// 박스 분포. 기본 pos.axis = origin.axis + rand(-distanceMax.axis, +distanceMax.axis).
    /// F620: 실물 speedmin/speedmax(초기속도)와 F627 distancemin(코너 쌍)은 케이스 시그니처 무회귀를
    /// 위해 def.emitterSpeed/def.boxDistanceMin 병렬 배열에 둔다(emitterAudio 와 동형).
    case box(origin: Vec3, distanceMax: Vec3, rate: Float, burst: Int)

    public var rate: Float {
        switch self {
        case let .sphere(_, _, _, _, r, _, _): return r
        case let .box(_, _, r, _): return r
        }
    }

    public var burst: Int {
        switch self {
        case let .sphere(_, _, _, _, _, b, _): return b
        case let .box(_, _, _, b): return b
        }
    }
}

public enum Initializer: Equatable {
    case lifetimeRandom(min: Float, max: Float, exponent: Float = 1)
    case sizeRandom(min: Float, max: Float, exponent: Float = 1)
    /// 0..255. [보존/추측] 한 t 로 min↔max 색 라인을 보간; WE RGB 축별 draw 반증 시 color만 재검토.
    case colorRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case alphaRandom(min: Float, max: Float, exponent: Float)
    /// [보존/추측] 방향/회전 스프레드 보존을 위해 성분별 독립 t를 사용한다.
    case velocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case rotationRandom(min: Vec3, max: Vec3, exponent: Float = 1)          // radians
    case angularVelocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)   // radians/s
    case turbulentVelocityRandom(speedMin: Float, speedMax: Float, scale: Float, offset: Float)
    case colorList(colors: [Vec3])                     // 0..1 (실물 "r g b" 문자열 목록) — 균등 랜덤 선택
    /// S5④: HSV 공간 색 랜덤(magic_color_sparkle 등 프리셋 — 실물 예제 huemin/huemax/saturationmin/max/
    /// valuemin/max, 전부 0..1 스케일). 종전 case 이름 불인식 → 전 initializer drop(무색 랜덤 = 백색 고정).
    /// h/s/v 는 colorRandom(공유 t, RGB 라인 보간)과 달리 서로 무관한 축이라 velocityRandom 과 같이
    /// 채널별 독립 t. [보존/추측] "huesteps"(코퍼스 실측 2/4 존재, 이산 색상환 스텝 수)는 미구현 —
    /// 연속 hue 랜덤으로 근사(전무→근사, 폴백 방향 유지). 반증 시 재검토.
    case hsvColorRandom(hueMin: Float, hueMax: Float, satMin: Float, satMax: Float, valMin: Float, valMax: Float,
                        hueSteps: Int = 0, hueNoise: Float = 0, satNoise: Float = 0, valNoise: Float = 0)
    // hueSteps = 실물키 huesteps(코퍼스 실측 2/4, 이산 색상환 스텝 수 — [추정] 구간 등분 인덱스 선택,
    // 0=연속 랜덤 레거시). hueNoise/satNoise/valNoise = 실물키 huenoise/saturationnoise/valuenoise
    // (@0x48e3c0–0x48e3e0 — [추정] 스폰 위치 값노이즈로 채널 t 산출, 0=부재 시 레거시 rng 드로
    // — 무키 씬 비트동일).
    /// 스프라이트시트 프레임 선택(스폰 시 확정). between=false: CP0 기준 각도 → 시퀀스,
    /// true: CP0→CP1 구간 투영 → 시퀀스. count=시퀀스 길이(시트 프레임 수와 다를 수 있음 — mirror 폴드).
    case mapSequence(count: Float, mirror: Bool, between: Bool)
    /// 스폰 위치 오프셋 랜덤(실물키 positionoffsetrandom 의 offsetmin/offsetmax @0x48e380/398).
    /// [보존/추측] velocityRandom 과 동형 성분별 독립 t.
    case positionOffsetRandom(offsetMin: Vec3, offsetMax: Vec3)
    /// 파스·보존 전용(이벤트 시스템 연동 보류 — 시뮬레이터 무시, RNG 드로 0).
    /// 실물 inheritcontrolpointvelocity: CP 속도 상속 [추정].
    case inheritControlPointVelocity(controlPoint: Int, scale: Float)
    /// 파스·보존 전용(이벤트 시스템 연동 보류). 실물 inheritinitialvaluefromevent / inheritvaluefromevent.
    case inheritValueFromEvent(name: String, valueName: String?)
    /// 파스·보존 전용(이벤트 시스템 연동 보류). 실물 remapinitialvalue — 출력 리맵 스펙 미확정.
    case remapInitialValue(output: String?, min: Vec3?, max: Vec3?)
}

/// 시퀀스 인덱스(스폰 시 0..count) → 시트 프레임 인덱스. mirror=핑퐁(주기 2N-2), 아니면 순환.
public func sheetFrameIndex(sequence: Float, frameCount: Int, mirror: Bool) -> Int {
    guard frameCount > 0, sequence.isFinite else { return 0 }
    let rounded = sequence.rounded(.down)
    let s = rounded <= 0 ? 0 : (rounded >= Float(Int.max) ? Int.max : Int(rounded))
    guard frameCount > 1 else { return 0 }
    if mirror {
        let period = 2 * frameCount - 2
        let m = s % period
        return m < frameCount ? m : period - m
    }
    return s % frameCount
}

/// vortex_v2 ring 키(ringradius/ringpulldistance/ringpullforce/ringwidth @0x48e8a8–0x48e8e0).
/// [추정] 링 근사: 회전면 반경 dist 가 링 대역(|dist−radius| ≤ width/2) 밖이고 pullDistance 이내이면
/// 링 원주를 향한 반경 방향 인력(pullForce)을 가한다(대역 안·범위 밖은 묵영향).
public struct VortexRing: Equatable {
    public let radius: Float
    public let pullDistance: Float
    public let pullForce: Float
    public let width: Float
    public init(radius: Float, pullDistance: Float, pullForce: Float, width: Float) {
        self.radius = radius; self.pullDistance = pullDistance
        self.pullForce = pullForce; self.width = width
    }
}

public enum ParticleOperator: Equatable {
    case movement(gravity: Vec3, drag: Float)
    case alphaFade(fadeInTime: Float, fadeOutTime: Float)          // 수명 비율 0..1 (fadeOut 0=없음)
    /// 수명 비율 구간에서 factor를 보간해 현재 크기에 곱한다.
    case sizeChange(startTime: Float, startValue: Float, endValue: Float, endTime: Float = 1)
    /// 수명 비율 구간에서 RGB factor를 성분별 보간해 현재 색에 곱한다.
    case colorChange(startTime: Float, startValue: Vec3, endValue: Vec3, endTime: Float = 1)
    /// 각가속 + 선형 movement(위 61행)와 대칭인 drag 감쇠(기본 0=무감쇠, 종전 동작 무회귀).
    case angularMovement(force: Vec3, drag: Float = 0)
    /// 위상 진동: alpha ×= lerp(scaleMin, scaleMax, 0.5(1+sin(2πf·(age/lifetime)+phase))). 파티클별 f/phase 는
    /// 스폰 시 range(min,max) 샘플(phasemin/max 부재 시 0 — 전 파티클 동위상, fireworks 근동기 의도).
    /// f 단위 = 수명당 진동 횟수(F832, WE 공식 디자이너 문서 operator.html — oscillate 3종 공통).
    case oscillateAlpha(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                        phaseMin: Float = 0, phaseMax: Float = 0)
    case oscillatePosition(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                           phaseMin: Float, phaseMax: Float, mask: Vec3)
    /// 컨트롤포인트로의 인력/척력. 실물키: scale(가속, 음수=척력), threshold(근접 반경), origin(대상, 헤드리스=기본 0).
    /// deleteThreshold = 실물키 deletethreshold(@0x48e788): threshold 이내 근접 파티클 삭제(기본 false =
    /// 기존 min(1,threshold/dist) 감쇠 추정 경로 무회귀).
    case controlPointAttract(scale: Float, threshold: Float, target: Vec3, deleteThreshold: Bool = false)
    /// 축 기준 소용돌이. 실물키: axis, distanceinner/outer, speedinner/outer, offset(중심).
    /// 확장 키: centerforce(@0x48e7c8, 축 중심을 향한 반경 인력 — 의미 명확, 구현),
    /// variablestrength/reductioninner/reductionouter(@0x48e7e0–0x48e840 — 의미 부호화 불가,
    /// 파스·보존 전용), ring(vortex_v2 의 ringradius/ringpulldistance/ringpullforce/ringwidth
    /// @0x48e8a8–0x48e8e0 — [추정] 링 대역 인력 근사, 부재 시 기존 경로).
    case vortex(axis: Vec3, distanceInner: Float, distanceOuter: Float,
                speedInner: Float, speedOuter: Float, offset: Vec3,
                centerForce: Float = 0, variableStrength: Float = 0,
                reductionInner: Float = 0, reductionOuter: Float = 0, ring: VortexRing? = nil)
    /// 결정적 노이즈 흐름장 난류. 실물키(정찰 55인스턴스): speedmin/speedmax(파티클별 속도 범위),
    /// scale(공간 주파수, 기본 0.01), timescale(시간 진화 속도, 기본 0=정적장), mask(축별 게이트 "x y z"),
    /// phasemin/phasemax(파티클별 위상 오프셋). 노이즈장 속도로 위치를 이류(advection)한다(vel 미누적 → 유계).
    case turbulence(speedMin: Float, speedMax: Float, scale: Float, timeScale: Float,
                    mask: Vec3, phaseMin: Float, phaseMax: Float)
    /// 크기 진동: size ×= lerp(scaleMin, scaleMax, 0.5(1+sin(2πf·(age/lifetime)+phase))). 파티클별 f/phase 스폰 샘플.
    case oscillateSize(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                       phaseMin: Float, phaseMax: Float)
    /// 수명 비율 구간에서 alpha factor를 보간해 현재 알파에 곱한다.
    case alphaChange(startTime: Float, endTime: Float, startValue: Float, endValue: Float)
    /// 노이즈 리맵: velocity = 범위 보간(덮어쓰기, 매 스텝) / speed = 적분 속도 배수(비파괴 — 복리 방지).
    /// 노이즈 입력은 파티클별 위상 + age (근사 — WE 정의 미공개, 유계·탈동기·결정성 보장).
    case remapValue(output: RemapOutput, fbm: Bool, inputScale: Float)
    /// remapvalue 확장 파이프라인(엔진 어휘 전종 — input/operation/transform/동사형 출력/blend 창).
    /// 확장 키가 하나라도 있거나 출력이 velocity/speed 외 동사형이면 이 케이스로 파스된다.
    case remapValueEx(spec: RemapSpec)
}

public enum RemapOutput: Equatable {
    /// 레거시 출력 "velocity" — 엔진 어휘 setvelocity 계열로 해석(매 스텝 덮어쓰기). 동작 무회귀.
    case velocity(min: Vec3, max: Vec3)
    /// 레거시 출력 "speed" — 엔진 어휘 multiplyspeed 계열로 해석(적분 속도 비파괴 배수). 동작 무회귀.
    case speed(min: Float, max: Float)
}

/// remapvalue 출력 동사(wallpaper64.exe 스트링 @0x490dd0–0x490eb0). set*=덮어쓰기, add*=가산
/// ([추정] rotation/angularvelocity 는 프레임 독립을 위해 dt 곱 가산율), multiply*=곱.
/// opacity/color/size 는 표시 파생(display 단계) 적용, velocity/speed/rotation/angularvelocity 는
/// 스텝 적분 단계 적용. 레거시 문자열 매핑: "velocity"→setVelocity, "speed"→multiplySpeed.
public enum RemapVerb: String, Equatable {
    case setVelocity = "setvelocity"
    case addVelocity = "addvelocity"
    case multiplySpeed = "multiplyspeed"
    case setOpacity = "setopacity"
    case multiplyOpacity = "multiplyopacity"
    case setColor = "setcolor"
    case multiplyColor = "multiplycolor"
    case setSize = "setsize"
    case multiplySize = "multiplysize"
    case setRotation = "setrotation"
    case addRotation = "addrotation"
    case setAngularVelocity = "setangularvelocity"
    case addAngularVelocity = "addangularvelocity"
}

/// remapvalue 입력 소스(wallpaper64.exe 스트링 @0x490c78–0x490d60). [추정] 시계열 류(layertime/
/// runtime/timeofday)는 헤드리스 결정성 우선으로 시뮬 누적시간 근사. directiontocontrolpoint 는
/// component 키로 성분 선택(기본 x).
public enum RemapInput: String, Equatable {
    case lifetimeFraction = "lifetimefraction"
    case particleSystemTime = "particlesystemtime"
    case layerTime = "layertime"
    case velocity = "velocity"
    case deltaToControlPoint = "deltatocontrolpoint"
    case distanceToControlPoint = "distancetocontrolpoint"
    case directionToControlPoint = "directiontocontrolpoint"
    case positionBetweenControlPoints = "positionbetweentwocontrolpoints"
    case layerOrigin = "layerorigin"
    case runtime = "runtime"
    case timeOfDay = "timeofday"
}

/// remapvalue operation(엔진 어휘). [추정] 정규화값 v∈[0,1] 의 단항 셰이핑으로 해석(제2 피연산자
/// 부재): remap=항등(기본), subtract=1−v, square=v². multiply/average 는 단항 의미 부호화 불가 —
/// 파스·보존 전용(항등 적용).
public enum RemapOperation: String, Equatable {
    case remap, subtract, multiply, average, square
}

/// remapvalue transformfunction(엔진 어휘). [추정] simplexnoise 는 코퍼스에 심플렉스 구현이 없어
/// 단일 옥타브 값노이즈 근사. fbmnoise 는 transformoctaves(@0x48e6d8, 기본 3) 옥타브 합성.
public enum RemapTransform: String, Equatable {
    case triangle, simplexnoise, fbmnoise
}

/// remapvalue 확장 스펙(엔진 어휘 전종 파스). 의미 구현 가능한 것만 시뮬레이터가 소비하고
/// 나머지(outputcontrolpoint0/1, multiply/average operation)는 보존 전용.
public struct RemapSpec: Equatable {
    public let verb: RemapVerb
    /// nil = input 키 부재 → 레거시 동형 노이즈 입력((remapPhase+age)·K·inputScale).
    public let input: RemapInput?
    public let operation: RemapOperation      // 부재 remap
    public let transform: RemapTransform?     // nil = 변환 없음(입력을 0..1 클램프해 직접 매핑 [추정])
    public let octaves: Int                   // transformoctaves (기본 3)
    public let inputScale: Float              // transforminputscale (기본 1)
    public let outMin: Vec3                   // outputrangemin (스칼라 브로드캐스트)
    public let outMax: Vec3                   // outputrangemax
    /// blendinstart/end · blendoutstart/end (@0x48e650–0x48e680): 수명 비율 창에서 효과 가중
    /// 0→1(in)/1→0(out) 램프 [추정]. 전부 0(부재)이면 가중 1(무창).
    public let blendInStart: Float
    public let blendInEnd: Float
    public let blendOutStart: Float
    public let blendOutEnd: Float
    public let inputCP0: Int                  // inputcontrolpoint0 (기본 0)
    public let inputCP1: Int                  // inputcontrolpoint1 (기본 1)
    public let outputCP0: Int                 // outputcontrolpoint0/1 — 파스·보존 전용(소비처 보류)
    public let outputCP1: Int
    public let component: Int                 // component: 0=x/1=y/2=z (기본 0)
    public init(verb: RemapVerb, input: RemapInput?, operation: RemapOperation,
                transform: RemapTransform?, octaves: Int, inputScale: Float,
                outMin: Vec3, outMax: Vec3,
                blendInStart: Float, blendInEnd: Float, blendOutStart: Float, blendOutEnd: Float,
                inputCP0: Int, inputCP1: Int, outputCP0: Int, outputCP1: Int, component: Int) {
        self.verb = verb; self.input = input; self.operation = operation
        self.transform = transform; self.octaves = octaves; self.inputScale = inputScale
        self.outMin = outMin; self.outMax = outMax
        self.blendInStart = blendInStart; self.blendInEnd = blendInEnd
        self.blendOutStart = blendOutStart; self.blendOutEnd = blendOutEnd
        self.inputCP0 = inputCP0; self.inputCP1 = inputCP1
        self.outputCP0 = outputCP0; self.outputCP1 = outputCP1; self.component = component
    }
}

/// F622: 실물 def 최상위 "animationmode"(스프라이트시트 재생 모드). 부재/미지 = frametime 기반
/// 기본 재생(기존 폴터). sequence = 수명에 걸쳐 순차 재생(×sequencemultiplier — 프레임 수가
/// 필요해 렌더 경로 소비, 본 갭에서는 파스·보존), randomframe = 스폰 시 랜덤 프레임 1개 고정
/// (시뮬이 p.frame 을 스폰 확정 → 정지 파티클의 프레임 깜빡임 해소).
public enum ParticleAnimationMode: String, Equatable {
    case sequence
    case randomframe
}

/// F626: 실물 렌더러 "orientation"(공식 문서: screen=기본 빌보드, upright=Y축 고정, fixed=축 고정).
/// 파스·보존 전용 — 실제 쿼드 배향은 WapleRender 경로 소비(본 갭 스코프 밖).
public enum ParticleOrientation: Equatable {
    case screen
    case upright
    case fixed(axis: Vec3)
}

/// 파티클 렌더러. sprite = 빌보드 쿼드. F790 부터 분화 — rope/ropeTrail 만 위치 히스토리 리본,
/// spriteTrail 은 WE 공식 의미(속도 방향 신장 쿼드 — spriteTrailStretch 참고)로 정정.
/// isTrail 은 3D 경로 호환을 위해 spriteTrail 을 여전히 포함(2D 경로만 신장 쿼드로 분기).
public enum RendererKind: Equatable {
    case sprite
    case spriteTrail(maxLength: Float, length: Float, minLength: Float)
    case rope(subdivision: Int)
    case ropeTrail(length: Float, subdivision: Int)
    case unsupported(String)

    /// 히스토리 리본 계열인가. spriteTrail 은 2D 경로에선 F790 신장 쿼드로 분기하고
    /// 리본을 그리지 않는다 — 이 플래그는 3D 경로 소비·refract 제외 판정 호환으로 유지.
    public var isTrail: Bool {
        switch self {
        case .spriteTrail, .rope, .ropeTrail: return true
        default: return false
        }
    }

    /// C4-(iii): REFRACT 디스패치 게이트 전용 — rope/ropeTrail(위치 히스토리 리본)만 배제한다.
    /// spriteTrail(F790 신장 쿼드)은 sprite 와 동형의 쿼드 지오메트리라 REFRACT 정접 대상(코퍼스
    /// additive+REFRACT 10씬 중 rain_on_the_glass1 등 spriteTrail 실측) — isTrail(위, 벡터
    /// reservation/appendRibbon 분기용)과 달리 spriteTrail 을 false 로 분리한다.
    public var isRopeTrail: Bool {
        switch self {
        case .rope, .ropeTrail: return true
        default: return false
        }
    }

    /// 리본에 보관할 위치 히스토리 샘플 수(step 당 1샘플, captureFrames=30fps 가정).
    /// spriteTrail=maxlength(세그먼트 수 근사), ropeTrail=length(초)×30, rope=subdivision(F629,
    /// 부재/0 시 종전 고정 16). F625: 캡 24→240 — maxlength 100/ropetrail 수초 트레일이 24샘플
    /// (30fps 0.8초)로 절단됐다. WE spritetrail 의 length 는 "speed×length 신장" 의미(공식 문서)라
    /// 샘플 수에 쓰지 않는다(속도-신장 렌더 = F790 에서 2D 경로 소비. 히스토리는 3D 경로 호환으로 유지).
    public var trailSampleCount: Int {
        func clamp(_ v: Int) -> Int { min(240, max(4, v)) }
        func clampedRounded(_ value: Float) -> Int? {
            guard value.isFinite, value > 0 else { return nil }
            if value >= 240 { return 240 }
            return clamp(Int(value.rounded()))
        }
        switch self {
        case let .spriteTrail(maxLength, _, _):
            return clampedRounded(maxLength) ?? 8
        case let .rope(subdivision):
            return clampedRounded(Float(subdivision)) ?? 16
        case let .ropeTrail(length, subdivision):
            return clampedRounded(length * 30) ?? clampedRounded(Float(subdivision)) ?? 12
        default:
            return 0
        }
    }

    /// F790: WE 공식 문서 확정 — spritetrail 은 히스토리 리본이 아니라 "속도 방향으로 신장된 쿼드":
    /// 이상 신장 = speed×length, [minlength, maxlength] 클램프, 쿼드 장축 = size×신장(단축 = size
    /// 무신장). 1/1/1 이면 무신장 회전만(공식 문서의 우주선 예시). minlength 부재 → 0(하한 없음),
    /// maxlength 부재 → 1(공식 문서의 무신장 중립값).
    ///
    /// H3(핫픽스, 웨이브 W0b, 3489263099/3465215190 회귀 — F790 재해석 정정): length 는 speed 의
    /// 유일한 승수라 length 부재 시엔 신장 자체가 정의되지 않는다. 종전엔 이 경우 "곱 항등 1"
    /// (mul=1 → s=speed) 로 폴백했으나, 씬의 전형적 속도(수백 px/s)가 그대로 [minlength,maxlength]
    /// 로 밀려 들어가 사실상 항상 maxlength 로 포화된다 — 신장의 speed 의존성 자체가 관측 불가해진다
    /// (spriteTrailStretch(speed: 10) == spriteTrailStretch(speed: 1000)). rain_on_the_glass(워크샵
    /// 2446129945, 14+씬 공유)·wind-blur·rainfall·Magic_Vortex·Random_sparks·Particle_flow·yuluj 등
    /// length 미저작 코퍼스 전건이 동일 증상(구 베이스라인 95fad7a 리본 구현 대비 명백한 회귀 — 3489263099
    /// 는 창밖 도시가 흰 스미어에 가려짐). length 를 실제로 저작한 씬(ember length=0.007 등)만 저작자가
    /// 의도한 speed 의존 신장이 성립하므로, length 가 명시된 시스템에만 신장 산정을 적용하고 — 부재
    /// (≤0)면 신장을 항등(1, 공식 문서의 회전만 케이스)으로 되돌린다. minlength/maxlength 단독 저작은
    /// speed 승수 없이는 의미가 없어 이 폴백에 포함(코퍼스 123건 전 조합에서 모순 없음).
    public func spriteTrailStretch(speed: Float) -> Float {
        guard case let .spriteTrail(maxLength, length, minLength) = self else { return 1 }
        guard length > 0 else { return 1 }
        var s = speed * length
        if minLength > 0 { s = max(s, minLength) }
        s = min(s, maxLength > 0 ? maxLength : 1)
        return s
    }
}

public enum BlendKind: Equatable { case additive, translucent }

public struct ParticleMaterial: Equatable {
    public let textureName: String?
    public let blend: BlendKind
    /// REFRACT 콤보(스크린 굴절): 노멀맵(normalTextureName=textures[1]) 의 xy 로 씬 컬러 타깃을 재샘플해 곱한다.
    public let refract: Bool
    public let normalTextureName: String?
    public let refractAmount: Float   // g_RefractAmount (WE 기본 0.05)
    /// M(④): combos.FOG(genericparticle.frag/genericropeparticle.frag 기본 1 — 명시 0 만 씬 포그 제외).
    /// 메시 경로(SceneRenderer3D.loadMesh3DMaterial `foggy`)와 동일 기본값·게이트 규약.
    public let foggy: Bool
    /// C4-(ii): g_Overbright(genericparticle.frag/genericropeparticle.frag — material 유니폼,
    /// 기본 1.0, range [0,5]). RGB 만 곱(알파 제외). 기본 1 이면 렌더 비트동일(무회귀).
    public let overbright: Float
    public init(textureName: String?, blend: BlendKind,
                refract: Bool = false, normalTextureName: String? = nil, refractAmount: Float = 0.05,
                foggy: Bool = true, overbright: Float = 1) {
        self.textureName = textureName; self.blend = blend
        self.refract = refract; self.normalTextureName = normalTextureName; self.refractAmount = refractAmount
        self.foggy = foggy; self.overbright = overbright
    }

    public static func parse(_ json: [String: Any], userProps: [String: Any] = [:]) -> ParticleMaterial {
        guard let passes = json["passes"] as? [Any], let p0 = passes.first as? [String: Any] else {
            return ParticleMaterial(textureName: nil, blend: .translucent)
        }
        let blend: BlendKind = (p0["blending"] as? String) == "additive" ? .additive : .translucent
        let names = (p0["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
        let albedo = names.first(where: { !$0.isEmpty })
        // combos.REFRACT==1 + textures[1] 노멀맵 + constantshadervalues.ui_editor_properties_refract_amount.
        // 콤보 값은 이 파일의 pint 로 읽는다(종전 `as? NSNumber`.intValue 직접 캐스트 — 헬퍼 우회).
        // 파티클 규약은 **문자열 스칼라 거부·언랩 없음**(:1115 헬퍼 주석)이라 pint = strictInt 를 쓴다 —
        // 씬 경로(SceneDocument 의 intVal)처럼 "1" 을 받아주지 않는 것은 이 파일의 의도된 계약이다.
        var refractComboRaw: Any? = nil
        if let combos = p0["combos"] as? [String: Any] { refractComboRaw = combos["REFRACT"] }
        let refract = pint(refractComboRaw) == 1
        let normalName = (names.count > 1 && !names[1].isEmpty) ? names[1] : nil
        var refractAmount = pfloat((p0["constantshadervalues"] as? [String: Any])?["ui_editor_properties_refract_amount"]) ?? 0.05
        // C⑦a: usershadervalues — {JSON 키=user property 키, JSON 값=셰이더 상수 토큰}(SceneDocument
        // 이미지 레이어 경로와 동일 방향 정정). 파스 시점에 userProps 룩업(런타임 변경은 정적 해석).
        if let usv = p0["usershadervalues"] as? [String: Any] {
            for (userKey, v) in usv {
                guard let token = v as? String, token == "ui_editor_properties_refract_amount" else { continue }
                if let raw = userProps[userKey], let f = pfloat(raw) { refractAmount = f }
            }
        }
        // M(④): FOG 콤보 기본 1(WE 선언) — 명시 0 만 제외. 메시 경로(SceneRenderer3D:608)와 동일하게
        // 키 대소문자 무시(REFRACT 는 기존 정확일치 관례 보존 — 섞지 않음).
        var foggy = true
        if let combos = p0["combos"] as? [String: Any],
           let v = combos.first(where: { $0.key.lowercased() == "fog" })?.value {
            foggy = ((v as? NSNumber)?.intValue ?? 1) != 0
        }
        // C4-(ii): constantshadervalues.ui_editor_properties_overbright(refract_amount 와 동일 파스 패턴).
        // 미명시 시 WE 기본 1.0(무변화 — 60씬 중 값이 다른 씬만 실질 변화).
        let overbright = pfloat((p0["constantshadervalues"] as? [String: Any])?["ui_editor_properties_overbright"]) ?? 1
        return ParticleMaterial(textureName: albedo, blend: blend,
                                refract: refract && normalName != nil, normalTextureName: normalName,
                                refractAmount: refractAmount, foggy: foggy, overbright: overbright)
    }
}

// MARK: - 자식 시스템 링크 (실물 children[] — 107링크 실측)

/// 자식 발화 방식. 실물 type: eventfollow(부모 파티클 추종) / 무type·static(상시, 링크 origin 고정) /
/// eventspawn(부모 스폰 지점 1회) / eventdeath(부모 사망 지점 1회 — rain splash).
public enum ChildTrigger: Equatable { case always, follow, spawnBurst, deathBurst }

public struct ChildLink: Equatable {
    public let def: ParticleSystemDef
    public let trigger: ChildTrigger
    public let maxInstances: Int
    public let probability: Float
    public let origin: Vec3
    public init(def: ParticleSystemDef, trigger: ChildTrigger, maxInstances: Int,
                probability: Float, origin: Vec3) {
        self.def = def; self.trigger = trigger; self.maxInstances = maxInstances
        self.probability = probability; self.origin = origin
    }
}

// MARK: - 인스턴스 오버라이드 (scene object "instanceoverride")

/// 씬 오브젝트의 파티클 인스턴스 모디파이어 — 동일 프리셋 def 를 인스턴스별로 다양화하는 장치
/// (실측 127씬/866건: 눈·불티·버블 재사용). 스칼라는 프리셋 값에 곱하는 **배수**(WE 에디터
/// Count/Rate/Size/… 인스턴스 슬라이더 — 실물 shimmering_particles alpha:10 등 >1 도 유효),
/// controlPoints 는 CP 오프셋 **절대 대체**. 씬 규약 값 언랩({user,value}/문자열)은 SceneDocument 책임.
public struct ParticleInstanceOverride: Equatable {
    public var count: Float? = nil      // maxcount·버스트(instantaneous) 배수
    public var rate: Float? = nil       // 이미터 rate 배수
    public var size: Float? = nil
    public var alpha: Float? = nil
    public var speed: Float? = nil      // 초기 속도(velocityrandom/turbulent) 배수
    public var lifetime: Float? = nil
    /// colorn × brightness × color/255 합성 색 배수(0..1 스페이스, 성분별 곱).
    public var colorMultiplier: Vec3? = nil
    /// controlpointN "x y z" — CP 오프셋 절대 대체(id 0..7).
    public var controlPoints: [Int: Vec3] = [:]
    public init() {}
    public var isEmpty: Bool {
        count == nil && rate == nil && size == nil && alpha == nil && speed == nil
            && lifetime == nil && colorMultiplier == nil && controlPoints.isEmpty
    }
}

// MARK: - 오디오반응 (실측 audioprocessing* — 이미터/이니셜라이저/오퍼레이터 부착, 본 구현은 이미터 rate 스코프)

/// 이미터 오디오반응 파라미터(WE audioprocessing*). 소비는 `AudioResponse.compute`(shake/pulse.vert 1:1):
/// 구간평균([freqStart,freqEnd]) → smoothstep(bounds) → pow(exponent) → saturate → ×1 = rate 배수(0..1).
/// mode 1..3(L/R/Both평균)만 활성 — 0/부재는 nil(무반응, 기존 rate 유지 → 무음 폴백의 근거).
public struct AudioProcessing: Equatable {
    public let mode: Int
    public let freqStart: Float
    public let freqEnd: Float
    public let bounds: SIMD2<Float>
    public let exponent: Float
    public init(mode: Int, freqStart: Float, freqEnd: Float, bounds: SIMD2<Float>, exponent: Float) {
        self.mode = mode; self.freqStart = freqStart; self.freqEnd = freqEnd
        self.bounds = bounds; self.exponent = exponent
    }

    /// 이미터/오퍼레이터 json 의 audioprocessing* 키 → AudioProcessing. mode 1..3 아니면 nil.
    /// 기본값은 셰이더 오디오 경로(SceneRendererResources.audioParams)와 정합: freqStart 0·freqEnd 15·exponent 1.
    /// bounds 부재 → [0.8,1.0](wallpaper64.exe 스트링 "0.8 1.0" @0x48e1b8; 키 귀속은 인접 추정 —
    /// "audioprocessingbounds" @0x48e220 과 같은 audioprocessing* 스트링 클러스터 내).
    static func parse(_ o: [String: Any]) -> AudioProcessing? {
        guard let mode = strictInt(o["audioprocessingmode"]), mode >= 1, mode <= 3 else { return nil }
        return AudioProcessing(
            mode: mode,
            freqStart: strictFloat(o["audioprocessingfrequencystart"]) ?? 0,
            freqEnd: strictFloat(o["audioprocessingfrequencyend"]) ?? 15,
            bounds: bounds2(o["audioprocessingbounds"]) ?? SIMD2(0.8, 1.0),  // 귀속 추정(위 doc 참조)
            exponent: strictFloat(o["audioprocessingexponent"]) ?? 1)
    }
}

/// "min max" 문자열 → SIMD2(앞 두 성분). vec3 파서는 3성분 요구라 2성분 bounds 전용.
private func bounds2(_ v: Any?) -> SIMD2<Float>? {
    guard let s = v as? String else { return nil }
    let parts = s.split(separator: " ").compactMap { Float($0) }
    guard parts.count >= 2 else { return nil }
    return SIMD2(parts[0], parts[1])
}

/// rope/ropetrail 렌더러 확장 키(fadealpha/fadesize/uvscale/uvscrolling/uvsmoothing/segments
/// — wallpaper64.exe 스트링 @0x48e9b0–0x48ea18). 파스·모델 노출 전용 — 렌더 소비는 WapleRender
/// 배선 보류. nil = 키 부재(WE 기본값 미확정이라 보존까지만).
public struct RopeRenderOptions: Equatable {
    public var fadeAlpha: Float? = nil
    public var fadeSize: Float? = nil
    public var uvScale: Float? = nil
    public var uvScrolling: Float? = nil
    public var uvSmoothing: Bool? = nil
    public var segments: Int? = nil
    public init() {}
    public var isEmpty: Bool {
        fadeAlpha == nil && fadeSize == nil && uvScale == nil
            && uvScrolling == nil && uvSmoothing == nil && segments == nil
    }
}

// MARK: - 주기(periodic) 방출

/// 이미터 주기 방출(wallpaper64.exe 스트링: minperiodicduration @0x48e1c0, maxperiodicduration
/// @0x48e1d8, minperiodicdelay @0x48e228?, maxperiodicdelay, maxtoemitperperiod @0x48e2b8 —
/// 0x48e1c0–0x48e2b8 클러스터). [추정] 의미론(WE 에디터 어휘 규약): ON 윈도우(duration 구간 랜덤)
/// 동안 rate/burst 방출(창당 maxtoemitperperiod 상한, 0=무상한) → OFF 딜레이(delay 구간 랜덤) → 반복.
/// rate==0 && burst==0 이면 창 내에 maxtoemitperperiod 를 균등 분배(암시 rate = quota/duration).
/// 키 부재 이미터(nil)는 기존 방출 경로(RNG 드로 순서 포함)와 비트동일.
public struct PeriodicEmission: Equatable {
    public let durationMin: Float   // minperiodicduration
    public let durationMax: Float   // maxperiodicduration (부재 시 0 — 주입 없음)
    public let delayMin: Float      // minperiodicdelay
    public let delayMax: Float      // maxperiodicdelay (부재 시 0 — 주입 없음)
    public let maxPerPeriod: Int    // maxtoemitperperiod (0 = 창 내 상한 없음)
    public init(durationMin: Float, durationMax: Float, delayMin: Float, delayMax: Float, maxPerPeriod: Int) {
        self.durationMin = durationMin; self.durationMax = durationMax
        self.delayMin = delayMin; self.delayMax = delayMax
        self.maxPerPeriod = maxPerPeriod
    }
}

// MARK: - 시스템 정의

public struct ParticleSystemDef: Equatable {
    public let emitters: [Emitter]
    public let initializers: [Initializer]
    public let operators: [ParticleOperator]
    public let renderer: RendererKind
    public let maxCount: Int
    public let startTime: Float
    public let material: ParticleMaterial?
    public let children: [ChildLink]
    /// 컨트롤포인트 오프셋(id 0..7, 시스템 로컬 좌표). mapsequence/트리거류가 참조.
    public var controlPoints: [Vec3] = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
    /// 이미터별 오디오반응(emitters 와 병렬; nil=무반응). 비어 있으면 전 이미터 무반응(기존 def·테스트 호환).
    public var emitterAudio: [AudioProcessing?] = []
    /// F620: 이미터별 speedmin/speedmax(emitters 와 병렬) — 방출 방향을 따르는 초기속도
    /// (WE 문서: "particle speed in conjunction with a movement Operator"). (0,0)=무속도(기존 동작).
    public var emitterSpeed: [SIMD2<Float>] = []
    /// F627: box 이미터별 distancemin(emitters 와 병렬; sphere 는 nil — 구 distancemin 은 케이스 필드).
    /// nil = ±distanceMax 대칭 레거시. 실물은 distancemin/distancemax 코너 쌍(음수·혼합 부호 유효).
    public var boxDistanceMin: [Vec3?] = []
    /// F624: vortex 오퍼레이터별 오디오반응(def.operators 중 vortex 출현 순 병렬; nil=묵반응).
    /// WE 문서: vortex 오디오반응은 "particle speed 를 오디오에 연결" → 속도 배수.
    public var vortexAudio: [AudioProcessing?] = []
    /// 이미터별 주기 방출(emitters 와 병렬; nil=무주기 — 기존 rate/burst 경로 비트동일).
    /// 병렬 배열 관례(emitterAudio/emitterSpeed/boxDistanceMin 동형) — Emitter 케이스 시그니처 무회귀.
    public var emitterPeriodic: [PeriodicEmission?] = []
    /// F623: 실물 def "flags" 비트(1=worldspace, 4=perspective z-원근).
    ///
    /// [정정 2026-08-01] 종전 주석은 "파스·보존 전용(렌더 소비는 후속)" 이라고 적혀 있었는데
    /// **bit1 은 이미 소비된다** — SceneRenderer3D.swift:2050 `(sys.def.flags & 1)`.
    /// 실제 소비 현황(코퍼스 전수 실측, spec/engine/particle-fields.json):
    ///   bit1 worldspace  — 58씬 저작 · **소비됨**
    ///   bit2 (의미 미상) — 26씬 저작 · 미소비
    ///   bit4 perspective — **70씬 저작 · 미소비** (현재 최대 갭)
    /// bit4 는 번들 프리셋 A/B 가 '깊이 정렬' 이 아니라 '원근 **크기 스케일**' 을 지지한다
    /// (bit4 조는 z 부피에 뿌리면서 sizechange·oscillatesize 를 0/30 으로 안 쓴다 —
    ///  엔진이 z 로 크기를 만들어 준다는 뜻). 다만 **공식은 모른다** — 기준 거리도 1/z 여부도
    /// 미확인이라 그럴듯한 원근식을 지어 넣으면 안 된다(스케일 부재보다 더 눈에 띌 수 있다).
    public var flags: Int = 0
    /// F622: 스프라이트시트 재생 모드/배속. animationMode nil = frametime 기반 기본 재생(기존 폴터).
    public var animationMode: ParticleAnimationMode? = nil
    public var sequenceMultiplier: Float = 1
    /// F626: 렌더러 orientation(기본 screen — 기존 스크린 빌보드 폴터와 동일).
    public var orientation: ParticleOrientation = .screen
    /// F630: mapsequencearoundcontrolpoint "axis"(회전 평면 선택, 기본 z축=XY 평면 레거시).
    public var mapSequenceAxis: Vec3? = nil
    /// rope/ropetrail 렌더러 확장 키(@0x48e9b0–0x48ea18) — 모델 노출 전용(렌더 소비 보류).
    public var ropeOptions: RopeRenderOptions? = nil

    public init(emitters: [Emitter], initializers: [Initializer], operators: [ParticleOperator],
                renderer: RendererKind, maxCount: Int, startTime: Float, material: ParticleMaterial?,
                children: [ChildLink] = []) {
        self.emitters = emitters; self.initializers = initializers; self.operators = operators
        self.renderer = renderer; self.maxCount = maxCount; self.startTime = startTime; self.material = material
        self.children = children
    }

    /// remapvalue 출력 문자열 → 동사. 레거시 "velocity"/"speed" 는 엔진 어휘 setvelocity/multiplyspeed
    /// 계열로 해석해 같은 동사에 매핑(레거시 비트동일 경로는 확장 키 부재 시에만 — 위 파스 분기 참조).
    private static func remapVerb(_ output: String?) -> RemapVerb? {
        switch output {
        case "velocity", "setvelocity": return .setVelocity
        case "speed", "multiplyspeed": return .multiplySpeed
        default: return output.flatMap { RemapVerb(rawValue: $0) }
        }
    }

    /// initializer JSON 배열 → (이니셜라이저 목록, mapSequenceAxis) 조립.
    /// F630: mapsequencearoundcontrolpoint "axis" — 마지막 지정 축이 승.
    private static func parseInitializers(_ jsonArray: [Any]) -> (inits: [Initializer], mapSeqAxis: Vec3?) {
        var inits: [Initializer] = []
        var mapSeqAxis: Vec3? = nil   // F630: mapsequencearoundcontrolpoint "axis"
        for case let i as [String: Any] in jsonArray {
            switch i["name"] as? String {
            case "lifetimerandom":
            // [2026-08-20] **부재 기본값은 중립값이 아니라 원본 주입기 상수다.** WE 는 원소 팩토리
            // 직전에 기본값 주입기를 돌린다 — `if (!json.find(k)) json[k] = C;` 꼴이고, 상수 C 는
            // 코드에만 있어서 자산 통계로는 절대 복원되지 않는다. 아래 값은 전부 그 주입기를
            // 디스어셈블해 읽은 것이다(주입기 = `Json::Value::find`(0x140087490) 호출 뒤
            // `test rax,rax` / `jne`(키 있으면 건너뜀) 패턴).
            // lifetimerandom 주입기 0x1401b9c40: max 만 1.0(0x1401b9d12) 을 심고 min 은 상수를
            // 심지 않는다 = **0**. 실물 도달 0건이지만 기록을 맞춘다.
                inits.append(.lifetimeRandom(min: injected(i, "min", 0), max: injected(i, "max", 1),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "sizerandom":
                inits.append(.sizeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                         exponent: pexponent(i["exponent"]) ?? 1))
            case "colorrandom":
            // colorrandom 주입기 0x1401ba110: min = "0 0 0"(0x1401ba16e), max = "255 255 255"
            // (0x1401ba264), exponent = 1.0(0x1401ba332). 종전 min 기본값 (255,255,255)는
            // "중립값" 추정이었다. 실물 도달 0건(258건 전건 min 명시)이라 동작 변화는 없다.
                inits.append(.colorRandom(min: injectedVec3(i, "min", Vec3(x: 0, y: 0, z: 0)),
                                          max: injectedVec3(i, "max", Vec3(x: 255, y: 255, z: 255)),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "alpharandom":
                // **[2026-08-20 정정] 추론이 아니라 실측이다.** 아래 옛 주석은 "같은 스위치의 관례상
                // 부재 기본값은 중립값" 이라는 유추로 min 을 1 로 놓았는데, 원본 주입기
                // 0x1401baa10 이 min = **0.05**(0x1401baa70) · max = 1.0(0x1401baaec) 를 심는다.
                // 즉 WE 의 중립은 불투명(1)이 아니라 거의 투명(0.05)이다.
                //
                // 옛 주석이 든 반증은 여전히 유효하되 결론이 달라진다: `wind-blur.json {"min":0.8}`
                // 은 min 이 명시돼 있어 영향 없고, min/max 둘 다 부재인 것은 동봉 34건 중 1건뿐이다.
                // 그 1건이 [0.05,1] 로 바뀐다 — [1,1] 고정보다 원본에 맞다.
                // (032b66d 의 ??0 은 여전히 틀렸다. 0.05 는 0 이 아니다.)
                inits.append(.alphaRandom(min: injected(i, "min", 0.05), max: injected(i, "max", 1),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "velocityrandom":
                inits.append(.velocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "rotationrandom":
                inits.append(.rotationRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             // 부재 기본 max (0,0,2π) — **키 귀속 확정**(2026-08-20).
                                             // 주입기 0x1401bb390 이 min="0 0 0"(0x1401bb3ee),
                                             // max="0 0 6.28318530717"(0x1401bb4c0) 를 심는다.
                                             // 종전 "인접 추정" 은 이제 실측이다.
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 6.28318530717),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "angularvelocityrandom":
            // 주입기 0x1401bb9c0: min = "0 0 -5"(0x1401bba1e, 길이 6) · max = "0 0 5"(0x1401bbafe,
            // 길이 5) · exponent = 1.0(0x1401bbbe0). 종전 (0,0,0)/(0,0,0)은 **회전이 아예 없다**.
            // 동봉 25건 중 4건이 min·max 를 둘 다 생략한다 — 그 4건이 안 돌고 있었다.
                inits.append(.angularVelocityRandom(min: injectedVec3(i, "min", Vec3(x: 0, y: 0, z: -5)),
                                                    max: injectedVec3(i, "max", Vec3(x: 0, y: 0, z: 5)),
                                                    exponent: pexponent(i["exponent"]) ?? 1))
            case "turbulentvelocityrandom":
                inits.append(.turbulentVelocityRandom(speedMin: pfloat(i["speedmin"]) ?? 0, speedMax: pfloat(i["speedmax"]) ?? 0,
                                                      scale: pfloat(i["scale"]) ?? 1, offset: pfloat(i["offset"]) ?? 0))
            case "colorlist":
                // 실물: colors = ["r g b", ...] 0..1 스케일(colorrandom 의 0..255 와 다름 — 실측).
                let colors = (i["colors"] as? [Any] ?? []).compactMap { pvec3($0) }
                if !colors.isEmpty { inits.append(.colorList(colors: colors)) }
            case "hsvcolorrandom":
                // 실물 예제(particleelementpreviews/hsvcolorrandom) 전 필드 명시값 huemin=0/huemax=1/
                // saturationmin=max=1/valuemin=max=1 — 필드 완전 부재(inheritinitialvaluefromevent) 시
                // 이 값들을 기본값으로 채택(전 스펙트럼 hue 랜덤 + 채도·명도 고정 — 데모가 곧 신규노드
                // 기본값이라는 정황 일치). max 개별 부재는 magic_color_sparkle(saturationmin=1, max 부재)
                // 관례상 max=min(고정값, 무작위폭 0)로 채운다.
                let hueMin = pfloat(i["huemin"]) ?? 0
                let hueMax = pfloat(i["huemax"]) ?? 1
                let satMin = pfloat(i["saturationmin"]) ?? 1
                let satMax = pfloat(i["saturationmax"]) ?? satMin
                let valMin = pfloat(i["valuemin"]) ?? 1
                let valMax = pfloat(i["valuemax"]) ?? valMin
                inits.append(.hsvColorRandom(hueMin: hueMin, hueMax: hueMax,
                                             satMin: satMin, satMax: satMax,
                                             valMin: valMin, valMax: valMax,
                                             hueSteps: max(0, pint(i["huesteps"]) ?? 0),
                                             hueNoise: pfloat(i["huenoise"]) ?? 0,
                                             satNoise: pfloat(i["saturationnoise"]) ?? 0,
                                             valNoise: pfloat(i["valuenoise"]) ?? 0))
            case "mapsequencearoundcontrolpoint":
                inits.append(.mapSequence(count: pfloat(i["count"]) ?? 0,
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: false))
                // F630: "0 1 0" 같은 회전축 — 각도 평면 선택(기본 z축 레거시, 마지막 지정 승).
                mapSeqAxis = pvec3(i["axis"]) ?? mapSeqAxis
            case "mapsequencebetweencontrolpoints":
                inits.append(.mapSequence(count: pfloat(i["count"]) ?? 0,
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: true))
            case "positionoffsetrandom":
                inits.append(.positionOffsetRandom(offsetMin: pvec3(i["offsetmin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                   offsetMax: pvec3(i["offsetmax"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "inheritcontrolpointvelocity":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.inheritControlPointVelocity(controlPoint: pint(i["controlpoint"]) ?? 0,
                                                          scale: pfloat(i["scale"]) ?? 1))
            case "inheritinitialvaluefromevent", "inheritvaluefromevent":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.inheritValueFromEvent(name: i["name"] as? String ?? "",
                                                    valueName: i["value"] as? String))
            case "remapinitialvalue":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.remapInitialValue(output: i["output"] as? String,
                                                min: pvec3OrScalar(i["min"]),
                                                max: pvec3OrScalar(i["max"])))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported initializer dropped: \(other ?? "nil")")
            }
        }
        return (inits, mapSeqAxis)
    }

    /// operator JSON 배열 → (파싱된 오퍼레이터, attract CP 인덱스 쌍, vortex 오디오반응) 조립.
    /// controlpointattract 의 CP id 는 controlpoint 배열이 오퍼레이터보다 뒤에 파스되므로
    /// (ops 인덱스, cpid) 만 보관했다가 def 조립 직전에 target 재조립(감사 V04).
    private static func parseOperators(_ jsonArray: [Any]) -> (ops: [ParticleOperator],
                                                               attractCPIds: [(op: Int, cp: Int)],
                                                               vortexAudio: [AudioProcessing?]) {
        var ops: [ParticleOperator] = []
        var attractCPIds: [(op: Int, cp: Int)] = []
        // F624: vortex 출현 순 병렬 오디오반응(WE: vortex 오디오반응 = particle speed 를 오디오에 연결).
        var vortexAudio: [AudioProcessing?] = []
        for case let o as [String: Any] in jsonArray {
            switch o["name"] as? String {
            case "movement":
                ops.append(.movement(gravity: pvec3(o["gravity"]) ?? Vec3(x: 0, y: 0, z: 0), drag: pfloat(o["drag"]) ?? 0))
            case "alphafade":
                // **[2026-08-20] 부재 기본값은 0 이 아니라 0.5 다.** 원본 주입기 0x1401bce50 이
                // `fadeintime`(0x1401bce63) · `fadeouttime`(0x1401bcf23) 둘 다에
                // `movabs rbp, 0x3fe0000000000000`(= 0.5, 0x1401bce71) 을 심는다 — `Json::Value::find`
                // (0x140087490) 가 null 을 낼 때만이다.
                //
                // 이게 이번 라운드에서 도달이 가장 큰 자리다: 동봉 `alphafade` 177건 중 **97건이
                // `fadeouttime` 을 생략**하고 23건이 `fadeintime` 을 생략한다. fadeOut 0 은
                // `fadeFactor` 에서 페이드를 통째로 끄므로, 그 97건은 수명 끝에 **팝** 하고 사라졌다
                // — WE 는 수명의 마지막 50% 에 걸쳐 서서히 사라진다.
                ops.append(.alphaFade(fadeInTime: injected(o, "fadeintime", 0.5),
                                      fadeOutTime: injected(o, "fadeouttime", 0.5)))
            case "sizechange":
                ops.append(.sizeChange(startTime: pfloat(o["starttime"]) ?? 0,
                                       startValue: pfloat(o["startvalue"]) ?? 1,
                                       endValue: pfloat(o["endvalue"]) ?? 0,
                                       endTime: pfloat(o["endtime"]) ?? 1))
            case "colorchange":
                ops.append(.colorChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        startValue: pvec3(o["startvalue"]) ?? Vec3(x: 1, y: 1, z: 1),
                                        endValue: pvec3(o["endvalue"]) ?? Vec3(x: 0, y: 0, z: 0),
                                        endTime: pfloat(o["endtime"]) ?? 1))
            case "angularmovement":
                // F188: drag 파싱 — movement(위 497-498행)의 선형 drag 와 대칭(부재 시 0, 무회귀).
                ops.append(.angularMovement(force: pvec3(o["force"]) ?? Vec3(x: 0, y: 0, z: 0),
                                            drag: pfloat(o["drag"]) ?? 0))
            case "oscillatealpha":
                // fmax 부재 시 fmin 승계(scaleMax 와 동일 패턴) — 역범위 rng.range(fmin, 0) 방지(감사 V03).
                // scalemax 기본은 scalemin 승계가 아니라 1 고정(비퇴화, F189/F190) — 자매 oscillatesize 는
                // scale 생략 시 상수(무진동)가 정답이지만, alpha 는 scale 생략 인스턴스(데모·
                // magic_color_sparkle 등)도 트윙클을 내야 한다(실측: smax 가 smin 을 승계하면 scale
                // 전체 생략은 진폭 0, scalemin 단독 지정은 진폭이 상수로 죽는다 — WE 데모는 frequency 만
                // 지정하고도 가시 진동을 낸다).
                // **[2026-08-20] 주파수 기본값은 승계가 아니라 고정 상수다.** 주입기 0x1401bd910 이
                // frequencymin = 1.0(0x1401bd979) · frequencymax = **10.0**(0x1401bda2f) ·
                // scalemax = 1.0(0x1401bdb85, `movsd` @0x140492778) 을 심는다. 즉 fmax 는 fmin 을
                // 승계하지 않는다 — 위 "역범위 방지" 주석의 승계는 이제 불필요하다(둘 다 상수라
                // 역범위가 생기지 않는다). frequency 0 은 sin 을 상수로 만들어 연산자를 무력화하므로
                // 동봉 26건 중 frequencymin 부재 3건·frequencymax 부재 2건이 죽어 있었다.
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = injected(o, "frequencymin", 1)
                ops.append(.oscillateAlpha(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 10),
                                           scaleMin: smin, scaleMax: injected(o, "scalemax", 1),
                                           phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi)))
            case "oscillateposition":
                // 주입기 0x1401bd5d0: frequencymin = 1.0(0x1401bd716) · frequencymax = **5.0**
                // (0x1401bd7cc). 자매 alpha/size 는 10.0 인데 **여기만 5.0** 이다 — 승계였다면
                // 절대 나오지 않을 값이라, 이 하나가 "고정 상수" 해석의 반증 가능한 증거다.
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = injected(o, "frequencymin", 1)
                // scalemax 는 **오브젝트 플래그 조건부**다(0x1401bd894 `test r14b,r14b` →
                // 세워졌으면 10.0(0x1401bd899), 아니면 **0.5**(0x1401bd8a3)). r14b 는 이 주입기의
                // 두 번째 인자로 호출부가 파티클 시스템 오브젝트의 비트에서 뽑는다.
                // 두 트리의 파티클 시스템 최상위 `flags` 실측값은 {0,1,2,3,4,6,8,9,248} 뿐이라
                // **bit10(0x400)이 세워진 자산이 하나도 없다** — 실측 동작은 0.5 다. 10.0 분기의
                // 조건 출처는 아직 못 박지 않았으므로 0.5 로 두고 기록만 남긴다.
                // 종전 `?? smin` 승계는 어느 쪽도 아니었다.
                ops.append(.oscillatePosition(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 5),
                                              scaleMin: smin, scaleMax: injected(o, "scalemax", 0.5),
                                              phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi),
                                              mask: injectedVec3(o, "mask", Vec3(x: 1, y: 1, z: 0))))
            case "controlpointattract":
                // CP 지정(범위 내) 시 CP offset 이 target, 미지정 시 origin 유지(무회귀).
                if let cpid = pint(o["controlpoint"]), cpid >= 0, cpid < 8 {
                    attractCPIds.append((op: ops.count, cp: cpid))
                }
                ops.append(.controlPointAttract(scale: pfloat(o["scale"]) ?? 0,
                                                threshold: pfloat(o["threshold"]) ?? 0,
                                                target: pvec3(o["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                deleteThreshold: (pint(o["deletethreshold"]) ?? 0) != 0))
            case "vortex":
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),
                                   distanceInner: pfloat(o["distanceinner"]) ?? 0,
                                   distanceOuter: pfloat(o["distanceouter"]) ?? 0,
                                   speedInner: pfloat(o["speedinner"]) ?? 0,
                                   speedOuter: pfloat(o["speedouter"]) ?? 0,
                                   offset: pvec3(o["offset"]) ?? Vec3(x: 0, y: 0, z: 0),
                                   centerForce: pfloat(o["centerforce"]) ?? 0,
                                   variableStrength: pfloat(o["variablestrength"]) ?? 0,   // 보존 전용(의미 보류)
                                   reductionInner: pfloat(o["reductioninner"]) ?? 0,       // 보존 전용(의미 보류)
                                   reductionOuter: pfloat(o["reductionouter"]) ?? 0))      // 보존 전용(의미 보류)
                vortexAudio.append(AudioProcessing.parse(o))
            case "vortex_v2":
                // F631: 실측 2인스턴스(3585875739)는 ring 키 없이 표준 vortex 파라미터(distanceinner/
                // outer·speedinner)만 — 표준 vortex 로 근사 매핑(종전 default 드롭 → 소용돌이 복원).
                // axis/offset 부재 = vortex 기본과 동일, speedouter 부재 = speedinner 승계.
                let sIn = pfloat(o["speedinner"]) ?? 0
                // ring 키(@0x48e8a8–0x48e8e0)는 하나라도 있을 때만 조립(부재 시 nil → 기존 경로).
                let ring: VortexRing? = {
                    let r = pfloat(o["ringradius"]), pd = pfloat(o["ringpulldistance"])
                    let pf = pfloat(o["ringpullforce"]), w = pfloat(o["ringwidth"])
                    guard r != nil || pd != nil || pf != nil || w != nil else { return nil }
                    return VortexRing(radius: r ?? 0, pullDistance: pd ?? 0,
                                      pullForce: pf ?? 0, width: w ?? 0)
                }()
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),
                                   distanceInner: pfloat(o["distanceinner"]) ?? 0,
                                   distanceOuter: pfloat(o["distanceouter"]) ?? 0,
                                   speedInner: sIn,
                                   speedOuter: pfloat(o["speedouter"]) ?? sIn,
                                   offset: pvec3(o["offset"]) ?? Vec3(x: 0, y: 0, z: 0),
                                   centerForce: pfloat(o["centerforce"]) ?? 0,
                                   variableStrength: pfloat(o["variablestrength"]) ?? 0,   // 보존 전용(의미 보류)
                                   reductionInner: pfloat(o["reductioninner"]) ?? 0,       // 보존 전용(의미 보류)
                                   reductionOuter: pfloat(o["reductionouter"]) ?? 0,       // 보존 전용(의미 보류)
                                   ring: ring))
                vortexAudio.append(AudioProcessing.parse(o))
            case "turbulence":
                // 실물 기본값: speed 부재 → 0(무동작), scale 부재 → 0.01(공간 변동 확보),
                // timescale 부재 → 0(정적장, 파티클 이동만으로 흔들림), mask 부재 → (1,1,1).
                let smin = pfloat(o["speedmin"]) ?? 0
                ops.append(.turbulence(speedMin: smin, speedMax: pfloat(o["speedmax"]) ?? smin,
                                       scale: pfloat(o["scale"]) ?? 0.01, timeScale: pfloat(o["timescale"]) ?? 0,
                                       mask: pvec3(o["mask"]) ?? Vec3(x: 1, y: 1, z: 1),
                                       phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0))
            case "oscillatesize":
                // 주입기 0x1401bdbf0: frequencymin = 1.0(0x1401bdc59) · frequencymax = 10.0
                // (0x1401bdd0f) · scalemin = **0.8**(0x1401bddc5) · scalemax = **1.2**
                // (0x1401bde6f, `movsd` @0x140492790). 종전 (1, 승계)는 진폭 0(= 무진동)이라
                // 동봉 5건 중 scalemin 부재 1건·scalemax 부재 1건·frequency 부재 2~3건이 죽어
                // 있었다. WE 는 크기를 ±20% 로 맥동시킨다.
                let smin = injected(o, "scalemin", 0.8)
                let fmin = injected(o, "frequencymin", 1)
                ops.append(.oscillateSize(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 10),
                                          scaleMin: smin, scaleMax: injected(o, "scalemax", 1.2),
                                          phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi)))
            case "alphachange":
                ops.append(.alphaChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        endTime: pfloat(o["endtime"]) ?? 1,
                                        startValue: pfloat(o["startvalue"]) ?? 1,
                                        endValue: pfloat(o["endvalue"]) ?? 0))
            case "remapvalue":
                let fbm = (o["transformfunction"] as? String) == "fbmnoise"
                let scale = pfloat(o["transforminputscale"]) ?? 1
                let outputName = (o["output"] as? String)?.lowercased()
                // 확장 키(엔진 어휘) 존재 여부 — 전부 부재 + 레거시 출력(velocity/speed)이면
                // 기존 .remapValue 경로(시뮬 비트동일 무회귀).
                let extKeys = ["input", "operation", "transformoctaves",
                               "blendinstart", "blendinend", "blendoutstart", "blendoutend",
                               "inputcontrolpoint0", "inputcontrolpoint1",
                               "outputcontrolpoint0", "outputcontrolpoint1", "component"]
                let hasExt = extKeys.contains { o[$0] != nil }
                if !hasExt, outputName == "velocity" {
                    ops.append(.remapValue(output: .velocity(min: pvec3OrScalar(o["outputrangemin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                             max: pvec3OrScalar(o["outputrangemax"]) ?? Vec3(x: 0, y: 0, z: 0)),
                                           fbm: fbm, inputScale: scale))
                } else if !hasExt, outputName == "speed" {
                    ops.append(.remapValue(output: .speed(min: pfloat(o["outputrangemin"]) ?? 0,
                                                          max: pfloat(o["outputrangemax"]) ?? 1),
                                           fbm: fbm, inputScale: scale))
                } else if let verb = remapVerb(outputName) {
                    let spec = RemapSpec(
                        verb: verb,
                        input: (o["input"] as? String).flatMap { RemapInput(rawValue: $0.lowercased()) },
                        operation: (o["operation"] as? String).flatMap { RemapOperation(rawValue: $0.lowercased()) } ?? .remap,
                        transform: (o["transformfunction"] as? String).flatMap { RemapTransform(rawValue: $0.lowercased()) },
                        octaves: max(1, pint(o["transformoctaves"]) ?? 3),
                        inputScale: scale,
                        outMin: pvec3OrScalar(o["outputrangemin"]) ?? Vec3(x: 0, y: 0, z: 0),
                        outMax: pvec3OrScalar(o["outputrangemax"]) ?? Vec3(x: 1, y: 1, z: 1),
                        blendInStart: pfloat(o["blendinstart"]) ?? 0,
                        blendInEnd: pfloat(o["blendinend"]) ?? 0,
                        blendOutStart: pfloat(o["blendoutstart"]) ?? 0,
                        blendOutEnd: pfloat(o["blendoutend"]) ?? 0,
                        inputCP0: pint(o["inputcontrolpoint0"]) ?? 0,
                        inputCP1: pint(o["inputcontrolpoint1"]) ?? 1,
                        outputCP0: pint(o["outputcontrolpoint0"]) ?? 0,
                        outputCP1: pint(o["outputcontrolpoint1"]) ?? 1,
                        component: pcomponent(o["component"]) ?? 0)
                    ops.append(.remapValueEx(spec: spec))
                } else {
                    WapleLog.warn("[Waple] remapvalue unsupported output dropped: \(outputName ?? "nil")")
                }
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported operator dropped: \(other ?? "nil")")
            }
        }
        return (ops, attractCPIds, vortexAudio)
    }

    /// resolveChild: 자식 json 경로 → def (호출측이 pkg/머티리얼/재귀 리졸브 담당). nil 리졸브 = 링크 드롭+로그.
    /// instanceOverride: 씬 오브젝트 "instanceoverride"(루트 def 전용 — 자식 children 은 비전파 보수 규약).
    /// 파스 **중** 적용해야 하는 이유: controlpointattract 의 target 이 CP 로 베이크되므로(아래 attractCPIds
    /// 재바인딩) CP 오버라이드는 베이크 전에 반영돼야 한다 — 사후 def 복제는 이 지점에 못 미친다.
    public static func parse(_ json: [String: Any], material: ParticleMaterial?,
                             instanceOverride: ParticleInstanceOverride? = nil,
                             resolveChild: ((String) -> ParticleSystemDef?)? = nil) -> ParticleSystemDef {
        var emitters: [Emitter] = []
        // emitters 와 병렬(같은 case 에서 함께 append) — 오디오반응 rate 변조에 이미터별 파라미터 공급.
        var emitterAudio: [AudioProcessing?] = []
        // F620/F627: speedmin/speedmax·box distancemin 도 emitters 와 병렬로 함께 append.
        var emitterSpeed: [SIMD2<Float>] = []
        var boxDistanceMin: [Vec3?] = []
        // 주기 방출(minperiodicduration…maxtoemitperperiod @0x48e1c0–0x48e2b8)도 emitters 와 병렬.
        var emitterPeriodic: [PeriodicEmission?] = []
        /// **[2026-08-20] "[추정]" 을 뗀다 — 이미터 base 파서(0x1401c1c70)를 끝까지 읽었다.**
        ///
        /// 다섯 키의 저장 위치와 처리가 전부 확정이다:
        ///   minperiodicduration → [+0x18](0x1401c1d66)   maxperiodicduration → [+0x1c](0x1401c1dac)
        ///   minperiodicdelay    → [+0x20](0x1401c1d89)   maxperiodicdelay    → [+0x24](0x1401c1dcf)
        ///   maxtoemitperperiod  (0x1401c1dd4)
        /// 그리고 함수 꼬리(0x1401c1deb-0x1401c1e0c)가 **min 을 max 로 클램프**한다:
        ///   `[+0x18] = minss([+0x1c], [+0x18])` · `[+0x20] = minss([+0x24], [+0x20])`
        /// max 는 건드리지 않는다 — 즉 min > max 면 min 이 내려가고 범위가 [max, max] 가 된다.
        ///
        /// **부재 기본값은 0 이 아니다** — 다섯 키 전부 주입 대상이다. 이미터 기본값 주입기
        /// (진입 **0x1401b8df0**)의 꼬리 0x1401b907d-0x1401b90f5 가 심는다:
        ///     minperiodicduration = 2.0(0x1401b907d)   maxperiodicduration = 3.0(0x1401b9094)
        ///     minperiodicdelay    = 1.0(0x1401b90ab)   maxperiodicdelay    = 2.0(0x1401b90c2)
        ///     maxtoemitperperiod  = 0  (정수 헬퍼 0x1401d7be0 으로 tail-jmp)
        /// 실수 주입은 공용 헬퍼 0x1401d7d30 이 한다 — `strlen` → `find`(0x140087490) →
        /// `test rax,rax` / `jne`(있으면 건너뜀) → `cvtss2sd` → 저장. 여기도 **부재일 때만**이다.
        ///
        /// **[정정 2026-08-20] 이 자리를 한 번 틀렸다.** 직전 커밋은 "주기 키에는 기본값 주입이
        /// 없다(= 전부 0)" 고 적었는데 정반대다. 원인은 디스어셈블 방법이었다 — 주입기를
        /// 0x1401b8e09 부터 **고정 바이트 창**으로 읽었는데 그 주소는 함수 진입이 아니라 체인된
        /// `.pdata` 조각의 경계였고, 창이 `instantaneous` 블록에서 끊겨 주기 꼬리를 통째로 놓쳤다.
        /// 교훈: 함수 경계는 `.pdata` 로 잡되 **체인된 조각을 병합**해야 한다. 고정 창은 안 된다.
        ///
        /// 실물 도달 0: 주기 키를 쓰는 이미터 5개(thunderbolt ×2, thunderbolt_beam_child ×2,
        /// water_droplets_periodic)가 네 min/max 를 **전건 명시**하고 전건 min ≤ max 다.
        /// 워크샵 자산이 max 를 생략하면 직전 코드는 창 길이가 0 으로 붕괴해 방출이 죽었다.
        func parsePeriodic(_ e: [String: Any]) -> PeriodicEmission? {
            let dMin = pfloat(e["minperiodicduration"]), dMax = pfloat(e["maxperiodicduration"])
            let pMin = pfloat(e["minperiodicdelay"]), pMax = pfloat(e["maxperiodicdelay"])
            let quota = pint(e["maxtoemitperperiod"])
            guard dMin != nil || dMax != nil || pMin != nil || pMax != nil || quota != nil else { return nil }
            let dLo = injected(e, "minperiodicduration", 2), dHi = injected(e, "maxperiodicduration", 3)
            let pLo = injected(e, "minperiodicdelay", 1), pHi = injected(e, "maxperiodicdelay", 2)
            // 꼬리 클램프(0x1401c1deb-0x1401c1e0c): min 만 max 로 내린다. max 는 안 건드린다.
            return PeriodicEmission(durationMin: Swift.min(dLo, dHi), durationMax: dHi,
                                    delayMin: Swift.min(pLo, pHi), delayMax: pHi,
                                    maxPerPeriod: max(0, quota ?? 0))
        }
        // **[2026-08-20] `rate` 부재 기본값은 0 이 아니라 10.0 이다.** 이미터 기본값 주입기
        // 0x1401b8e09 가 `movabs rcx, 0x4024000000000000`(= 10.0, 0x1401b8e59) 을 심는다 —
        // `Json::Value::find`(0x140087490) 가 null 을 낼 때만이다. 실물 도달은 293건 중 4건
        // (sphererandom 2 + boxrandom 2)으로 작지만, 그 4건은 종전에 **연속 방출이 없었다**.
        //
        // 테스트 픽스처 9곳이 `instantaneous` 만 주고 `rate` 를 생략하고 있었다 — 전부
        // "버스트 전용" 의도라 `"rate":0` 을 명시해 기본값과 분리했다. 픽스처가 기본값에
        // 묵시적으로 기대던 것을 드러낸 것이지, 기대를 바꾼 게 아니다.
        for case let e as [String: Any] in (json["emitter"] as? [Any] ?? []) {
            // F620: speedmin 부재 시 0, speedmax 부재 시 speedmin 승계(고정속도) — 부호 있는 초기속도.
            let speedMin = pfloat(e["speedmin"]) ?? 0
            let speedMax = pfloat(e["speedmax"]) ?? speedMin
            switch e["name"] as? String {
            case "sphererandom":
                emitters.append(.sphere(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    // 부재 기본 (1,1,0): wallpaper64.exe 스트링 "1 1 0" @0x48e288("directions" @0x48e290 에 인접).
                    directions: pvec3(e["directions"]) ?? Vec3(x: 1, y: 1, z: 0),
                    distanceMin: pfloat(e["distancemin"]) ?? 0,
                    distanceMax: pfloat(e["distancemax"]) ?? 0,
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0,
                    sign: pvec3(e["sign"]) ?? Vec3(x: 0, y: 0, z: 0)))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(nil)
                emitterPeriodic.append(parsePeriodic(e))
            case "boxrandom":
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
                emitterPeriodic.append(parsePeriodic(e))
            case "layerimage":
                // E1(②): layerimage(레이어 이미지 픽셀에서 방출) — 케이스 자체가 없어 무조건 드롭돼
                // 이 이미터만 가진 시스템은 emitters=[] 로 파티클을 0개도 생성하지 못했다. 픽셀 불투명
                // 분포 샘플링은 디코드 텍스처(WapleRender 전용) 접근이 필요해 파스 단계(WapleCore)에서는
                // 불가 — sphererandom/boxrandom과 동일한 공용 필드(origin/distancemax/distancemin/rate/
                // instantaneous)만 읽어 균등 박스 방출로 폴백한다. 캐비엇: 이미지 알파 마스크는 반영하지
                // 않음(균등분포) — 코퍼스 실측 n=1(rate 외 필드 미관측)이라 이 필드들은 부재 시 boxrandom과
                // 동일한 원점 스폰(distanceMax=0)으로 퇴화한다(무크래시, "0개"보다는 개선).
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
                emitterPeriodic.append(parsePeriodic(e))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported emitter dropped: \(other ?? "nil")")
            }
        }

        var (inits, mapSeqAxis) = Self.parseInitializers(json["initializer"] as? [Any] ?? [])

        // 인스턴스 오버라이드(배수) 적용 — 이미터 rate/버스트, 이니셜라이저 min/max.
        // 배수 대상 이니셜라이저가 프리셋에 없으면 주입(스폰 기본 1 × 배수 = 배수 자체; m==1 은 무의미라
        // 생략). speed 는 속도원 부재 시 0×배수=0 — 주입 없음. 색 배수는 colorrandom(0..255)·colorlist
        // (0..1) 양쪽에 성분별 곱(선형 배수라 스페이스 무관), 색 이니셜라이저 부재 시 colorList([배수]) 주입
        // (스폰 기본 백색 × 배수 = 배수 자체).
        if let ov = instanceOverride, !ov.isEmpty {
            func mul(_ v: Vec3, _ m: Vec3) -> Vec3 { Vec3(x: v.x * m.x, y: v.y * m.y, z: v.z * m.z) }
            func scale(_ v: Vec3, _ m: Float) -> Vec3 { Vec3(x: v.x * m, y: v.y * m, z: v.z * m) }
            func scaledBurst(_ b: Int, _ m: Float) -> Int { saturatedCount(Float(b) * m) }  // 감사 V06: 포화 클램프
            if ov.rate != nil || ov.count != nil {
                let rm = ov.rate ?? 1, cm = ov.count ?? 1
                emitters = emitters.map { e in
                    switch e {
                    case let .sphere(origin, directions, dMin, dMax, rate, burst, sign):
                        return .sphere(origin: origin, directions: directions, distanceMin: dMin,
                                       distanceMax: dMax, rate: rate * rm, burst: scaledBurst(burst, cm), sign: sign)
                    case let .box(origin, distanceMax, rate, burst):
                        return .box(origin: origin, distanceMax: distanceMax,
                                    rate: rate * rm, burst: scaledBurst(burst, cm))
                    }
                }
            }
            inits = inits.map { i in
                switch i {
                case let .lifetimeRandom(mn, mx, e) where ov.lifetime != nil:
                    return .lifetimeRandom(min: mn * ov.lifetime!, max: mx * ov.lifetime!, exponent: e)
                case let .sizeRandom(mn, mx, e) where ov.size != nil:
                    return .sizeRandom(min: mn * ov.size!, max: mx * ov.size!, exponent: e)
                case let .alphaRandom(mn, mx, e) where ov.alpha != nil:
                    return .alphaRandom(min: mn * ov.alpha!, max: mx * ov.alpha!, exponent: e)
                case let .velocityRandom(mn, mx, e) where ov.speed != nil:
                    return .velocityRandom(min: scale(mn, ov.speed!), max: scale(mx, ov.speed!), exponent: e)
                case let .turbulentVelocityRandom(sMin, sMax, sc, off) where ov.speed != nil:
                    return .turbulentVelocityRandom(speedMin: sMin * ov.speed!, speedMax: sMax * ov.speed!,
                                                    scale: sc, offset: off)
                case let .colorRandom(mn, mx, e) where ov.colorMultiplier != nil:
                    return .colorRandom(min: mul(mn, ov.colorMultiplier!), max: mul(mx, ov.colorMultiplier!), exponent: e)
                case let .colorList(colors) where ov.colorMultiplier != nil:
                    return .colorList(colors: colors.map { mul($0, ov.colorMultiplier!) })
                default:
                    return i
                }
            }
            func lacks(_ isKind: (Initializer) -> Bool) -> Bool { !inits.contains(where: isKind) }
            if let m = ov.size, m != 1, lacks({ if case .sizeRandom = $0 { return true } else { return false } }) {
                inits.append(.sizeRandom(min: m, max: m))
            }
            if let m = ov.alpha, m != 1, lacks({ if case .alphaRandom = $0 { return true } else { return false } }) {
                inits.append(.alphaRandom(min: m, max: m, exponent: 1))
            }
            if let m = ov.lifetime, m != 1, lacks({ if case .lifetimeRandom = $0 { return true } else { return false } }) {
                inits.append(.lifetimeRandom(min: m, max: m))
            }
            if let c = ov.colorMultiplier, c != Vec3(x: 1, y: 1, z: 1),
               lacks({ if case .colorRandom = $0 { return true }
                       if case .colorList = $0 { return true } else { return false } }) {
                inits.append(.colorList(colors: [c]))
            }
        }

        var (ops, attractCPIds, vortexAudio) = Self.parseOperators(json["operator"] as? [Any] ?? [])

        var renderer: RendererKind = .unsupported("none")
        var orientation: ParticleOrientation = .screen
        var ropeOpts: RopeRenderOptions? = nil
        if let r0 = (json["renderer"] as? [Any])?.first as? [String: Any] {
            let n = r0["name"] as? String ?? "none"
            switch n {
            case "sprite": renderer = .sprite
            case "spritetrail":
                // F790: minlength 추가 파스(JSON null → pfloat nil → 0 = 클램프 부재).
                renderer = .spriteTrail(maxLength: pfloat(r0["maxlength"]) ?? 0,
                                        length: pfloat(r0["length"]) ?? 0,
                                        minLength: pfloat(r0["minlength"]) ?? 0)
            case "rope":
                renderer = .rope(subdivision: pint(r0["subdivision"]) ?? 0)
            case "ropetrail":
                renderer = .ropeTrail(length: pfloat(r0["length"]) ?? 0, subdivision: pint(r0["subdivision"]) ?? 0)
            default:
                renderer = .unsupported(n); WapleLog.warn("[Waple] SP4 unsupported renderer (drawn as sprite): \(n)")
            }
            // F626: orientation("screen"/"upright"/"fixed") + axis — 파스·보존(렌더 소비는 후속).
            switch r0["orientation"] as? String {
            case "upright": orientation = .upright
            case "fixed": orientation = .fixed(axis: pvec3(r0["axis"]) ?? Vec3(x: 0, y: 0, z: 1))
            default: orientation = .screen
            }
            // rope/ropetrail 확장 키(@0x48e9b0–0x48ea18) — 하나라도 있으면 조립(전부 부재 시 nil,
            // 모델 노출까지만 — 렌더 소비 보류). uvsmoothing 은 체크박스형(≠0)으로 해석 [추정].
            switch renderer {
            case .rope, .ropeTrail:
                var opts = RopeRenderOptions()
                opts.fadeAlpha = pfloat(r0["fadealpha"])
                opts.fadeSize = pfloat(r0["fadesize"])
                opts.uvScale = pfloat(r0["uvscale"])
                opts.uvScrolling = pfloat(r0["uvscrolling"])
                if let sm = pint(r0["uvsmoothing"]) { opts.uvSmoothing = sm != 0 }
                opts.segments = pint(r0["segments"])
                if !opts.isEmpty { ropeOpts = opts }
            default: break
            }
        }

        // 음수 maxcount 가 시뮬 버스트 Range 상한으로 흘러 트랩 — 0 하한 클램프(감사 V02).
        var maxCount = max(0, pint(json["maxcount"]) ?? 100)
        if let m = instanceOverride?.count {
            maxCount = saturatedCount(Float(maxCount) * m)  // 감사 V06: Int 범위 밖 곱 트랩 — 포화 클램프
        }
        // 상한 65536: 코퍼스 100000 설정 씨 CPU 시뮬 과부하 방지(감사 D-corpus G7).
        maxCount = min(65536, maxCount)

        var children: [ChildLink] = []
        if let resolve = resolveChild {
            for case let c as [String: Any] in (json["children"] as? [Any] ?? []) {
                guard let path = c["name"] as? String else { continue }
                guard let childDef = resolve(path) else {
                    WapleLog.warn("[Waple] particle child resolve failed, dropped: \(path)")
                    continue
                }
                let trigger: ChildTrigger
                switch c["type"] as? String {
                case nil, "static": trigger = .always
                case "eventfollow": trigger = .follow
                case "eventspawn": trigger = .spawnBurst
                case "eventdeath": trigger = .deathBurst
                case let other:
                    WapleLog.warn("[Waple] particle child unknown type '\(other ?? "")' → follow 취급: \(path)")
                    trigger = .follow
                }
                // 자식 maxInstances 에도 루트 maxCount 와 **같은 상한**을 건다(:1032-1037).
                // 루트는 음수 0 클램프 + 65536 상한으로 CPU 시뮬을 묶어두는데 이 자리만 pint 원값을
                // 그대로 썼다 — 자식 인스턴스는 스폰된 부모 파티클 하나당 ParticleSimulator 를 통째로
                // 하나씩 할당하므로(ParticleSimulator:305) 루트 파티클 한 개보다 훨씬 비싼 단위인데
                // 상한이 없었다. 새 한계를 발명하지 않고 루트와 같은 값을 쓰고, 잘리면 로그를 남긴다.
                let rawMaxInstances = max(0, pint(c["maxcount"]) ?? (trigger == .always ? 1 : maxCount))
                let maxInstances = min(65536, rawMaxInstances)
                if maxInstances != rawMaxInstances {
                    WapleLog.warn("[Waple] particle child maxcount \(rawMaxInstances) → \(maxInstances) 클램프: \(path)")
                }
                children.append(ChildLink(
                    def: childDef, trigger: trigger,
                    maxInstances: maxInstances,
                    probability: pfloat(c["probability"]) ?? 1,
                    origin: pvec3(c["origin"]) ?? Vec3(x: 0, y: 0, z: 0)))
            }
        }

        var controlPoints = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
        for case let cp as [String: Any] in (json["controlpoint"] as? [Any] ?? []) {
            if let id = pint(cp["id"]), id >= 0, id < 8, let off = pvec3(cp["offset"]) {
                controlPoints[id] = off
            }
        }
        // 인스턴스 CP 오버라이드(절대 대체)는 attract target 재베이크 **전에** — 재베이크 후면 attract 가
        // 프리셋 CP 를 계속 본다(실측: CP 오버라이드 51오브젝트 중 22가 attract 보유).
        if let ov = instanceOverride {
            for (id, off) in ov.controlPoints where id >= 0 && id < 8 { controlPoints[id] = off }
        }
        for (i, cpid) in attractCPIds {
            if case let .controlPointAttract(scale, threshold, _, deleteThreshold) = ops[i] {
                ops[i] = .controlPointAttract(scale: scale, threshold: threshold,
                                              target: controlPoints[cpid], deleteThreshold: deleteThreshold)
            }
        }

        var def = ParticleSystemDef(
            emitters: emitters, initializers: inits, operators: ops, renderer: renderer,
            maxCount: maxCount, startTime: pfloat(json["starttime"]) ?? 0, material: material,
            children: children)
        def.controlPoints = controlPoints
        // 인스턴스 오버라이드는 emitters 를 .map(순서/개수 보존)만 하므로 emitterAudio 병렬성 유지.
        def.emitterAudio = emitterAudio
        def.emitterSpeed = emitterSpeed
        def.boxDistanceMin = boxDistanceMin
        def.emitterPeriodic = emitterPeriodic
        def.vortexAudio = vortexAudio
        def.flags = pint(json["flags"]) ?? 0                                        // F623
        // F622: animationmode("sequence"/"randomframe")·sequencemultiplier(배속, 기본 1).
        def.animationMode = (json["animationmode"] as? String).flatMap { ParticleAnimationMode(rawValue: $0) }
        def.sequenceMultiplier = pfloat(json["sequencemultiplier"]) ?? 1
        def.orientation = orientation
        def.mapSequenceAxis = mapSeqAxis
        def.ropeOptions = ropeOpts
        return def
    }
}

// MARK: - 파싱 헬퍼 (공용 JSONNumerics 위임 — 파티클 규약: 문자열 스칼라 거부, 언랩 없음)

private func pfloat(_ v: Any?) -> Float? { strictFloat(v) }

/// **기본값 주입기 규약** — 원본은 원소 팩토리 직전에 `if (!json.find(k)) json[k] = C;` 를 돌린다.
/// 결정적으로 **키가 없을 때만** 상수를 심는다. 키가 **있는데 값이 못 읽히는 경우**
/// (`"rate": 1e300` 처럼 Float 범위를 넘는 값)는 주입 대상이 **아니다** — 원본에서도
/// `find` 가 노드를 찾으므로 주입을 건너뛰고 그 노드의 `asFloat` 결과를 쓴다.
///
/// 이 구분이 없으면 `pfloat(d[k]) ?? C` 가 두 경우를 뭉뚱그려, 신뢰불가 입력이 오히려
/// **엔진 기본값으로 승격**된다. 실제로 그렇게 넣었다가
/// `testHugeNumericParticleValuesDefaultInsteadOfTrapping`(rate 1e300 → 0 기대)이 잡았다.
private func injected(_ d: [String: Any], _ key: String, _ constant: Float) -> Float {
    d[key] == nil ? constant : (pfloat(d[key]) ?? 0)
}

/// `injected(_:_:_:)` 의 Vec3 판(문자열 `"x y z"` 규약). 부재만 주입, 그 외는 0 벡터.
private func injectedVec3(_ d: [String: Any], _ key: String, _ constant: Vec3) -> Vec3 {
    d[key] == nil ? constant : (pvec3(d[key]) ?? Vec3(x: 0, y: 0, z: 0))
}
/// JSON false/true는 NSNumber로도 브리지되므로 exponent 숫자 경로에서 명시적으로 배제한다.
private func pexponent(_ v: Any?) -> Float? {
    if let number = v as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    return pfloat(v)
}
private func pint(_ v: Any?) -> Int? { strictInt(v) }
/// 감사 V06: Float→Int 스케일 변환 포화 클램프 — 곱이 Int 범위를 넘는(또는 NaN) 워크샵 입력의
/// Int() 변환 트랩(SIGTRAP, maxcount 1e9 × override count 1e12 실재현) 방지.
/// 0 하한은 V02 음수 클램프와 동일 정책, 상한 포화는 sheetFrameIndex(:52)와 동형.
private func saturatedCount(_ v: Float) -> Int {
    let p = v.rounded()
    guard p.isFinite else { return 0 }
    return p <= 0 ? 0 : (p >= Float(Int.max) ? Int.max : Int(p))
}
private func pvec3(_ v: Any?) -> Vec3? { stringVec3(v) }
/// "x y z" 벡터 또는 단일 스칼라(브로드캐스트).
private func pvec3OrScalar(_ v: Any?) -> Vec3? {
    if let vec = pvec3(v) { return vec }
    if let s = pfloat(v) { return Vec3(x: s, y: s, z: s) }
    return nil
}
/// remapvalue "component": "x"/"y"/"z" 문자열 또는 0/1/2 숫자 → 0/1/2.
private func pcomponent(_ v: Any?) -> Int? {
    if let s = v as? String {
        switch s.lowercased() {
        case "x": return 0
        case "y": return 1
        case "z": return 2
        default: return Int(s)
        }
    }
    return pint(v)
}
