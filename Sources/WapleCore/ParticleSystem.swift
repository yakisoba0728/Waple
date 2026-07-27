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
    /// 스프라이트시트 프레임 선택(스폰 시 확정). between=false: CP0 기준 각도 → 시퀀스,
    /// true: CP0→CP1 구간 투영 → 시퀀스. count=시퀀스 길이(시트 프레임 수와 다를 수 있음 — mirror 폴드).
    case mapSequence(count: Float, mirror: Bool, between: Bool)
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
    case controlPointAttract(scale: Float, threshold: Float, target: Vec3)
    /// 축 기준 소용돌이. 실물키: axis, distanceinner/outer, speedinner/outer, offset(중심).
    case vortex(axis: Vec3, distanceInner: Float, distanceOuter: Float,
                speedInner: Float, speedOuter: Float, offset: Vec3)
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
}

public enum RemapOutput: Equatable {
    case velocity(min: Vec3, max: Vec3)
    case speed(min: Float, max: Float)
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
    /// 무신장). 1/1/1 이면 무신장 회전만(공식 문서의 우주선 예시). 실물 코퍼스 123건 키 조합 실측
    /// (length 만 30건 / maxlength 만 26건 / minlength 포함 24건 — 부재·null 혼재) 기반 부재값 규칙:
    /// length 부재/0/null → 1(곱 항등 — 아니면 maxlength 만 쓴 26건이 전부 소멸), minlength 부재 →
    /// 0(하한 없음), maxlength 부재 → 1(공식 문서의 무신장 중립값). ponytail: 부재 기본 1 은 추론 —
    /// 상한 개방이면 전부재 spritetrail 6씬(신장=속도 그대로, 수백 배)이 붕괴하고, 1 은 코퍼스 123건
    /// 전 조합에서 모순 없음(ember 0.7–1.0 / 벚꽃 회전만 / wind-blur 20배 클램프 유지).
    public func spriteTrailStretch(speed: Float) -> Float {
        guard case let .spriteTrail(maxLength, length, minLength) = self else { return 1 }
        let mul = length > 0 ? length : 1
        var s = speed * mul
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
        let refract = ((p0["combos"] as? [String: Any])?["REFRACT"] as? NSNumber)?.intValue == 1
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
    /// bounds 부재 → [0,1](실측 modal "0 1"; A/B 무관 — 무음은 어떤 bounds 든 스킵).
    static func parse(_ o: [String: Any]) -> AudioProcessing? {
        guard let mode = strictInt(o["audioprocessingmode"]), mode >= 1, mode <= 3 else { return nil }
        return AudioProcessing(
            mode: mode,
            freqStart: strictFloat(o["audioprocessingfrequencystart"]) ?? 0,
            freqEnd: strictFloat(o["audioprocessingfrequencyend"]) ?? 15,
            bounds: bounds2(o["audioprocessingbounds"]) ?? SIMD2(0, 1),  // ponytail: 부재 기본 [0,1]
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
    /// F623: 실물 def "flags" 비트(1=worldspace, 4=perspective z-원근 — snowperspective 프리셋 실측).
    /// 파스·보존 전용(렌더 소비는 WapleRender 경로 후속).
    public var flags: Int = 0
    /// F622: 스프라이트시트 재생 모드/배속. animationMode nil = frametime 기반 기본 재생(기존 폴터).
    public var animationMode: ParticleAnimationMode? = nil
    public var sequenceMultiplier: Float = 1
    /// F626: 렌더러 orientation(기본 screen — 기존 스크린 빌보드 폴터와 동일).
    public var orientation: ParticleOrientation = .screen
    /// F630: mapsequencearoundcontrolpoint "axis"(회전 평면 선택, 기본 z축=XY 평면 레거시).
    public var mapSequenceAxis: Vec3? = nil

    public init(emitters: [Emitter], initializers: [Initializer], operators: [ParticleOperator],
                renderer: RendererKind, maxCount: Int, startTime: Float, material: ParticleMaterial?,
                children: [ChildLink] = []) {
        self.emitters = emitters; self.initializers = initializers; self.operators = operators
        self.renderer = renderer; self.maxCount = maxCount; self.startTime = startTime; self.material = material
        self.children = children
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
        for case let e as [String: Any] in (json["emitter"] as? [Any] ?? []) {
            // F620: speedmin 부재 시 0, speedmax 부재 시 speedmin 승계(고정속도) — 부호 있는 초기속도.
            let speedMin = pfloat(e["speedmin"]) ?? 0
            let speedMax = pfloat(e["speedmax"]) ?? speedMin
            switch e["name"] as? String {
            case "sphererandom":
                emitters.append(.sphere(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    directions: pvec3(e["directions"]) ?? Vec3(x: 1, y: 1, z: 1),
                    distanceMin: pfloat(e["distancemin"]) ?? 0,
                    distanceMax: pfloat(e["distancemax"]) ?? 0,
                    rate: pfloat(e["rate"]) ?? 0,
                    burst: pint(e["instantaneous"]) ?? 0,
                    sign: pvec3(e["sign"]) ?? Vec3(x: 0, y: 0, z: 0)))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(nil)
            case "boxrandom":
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: pfloat(e["rate"]) ?? 0,
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
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
                    rate: pfloat(e["rate"]) ?? 0,
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported emitter dropped: \(other ?? "nil")")
            }
        }

        var inits: [Initializer] = []
        var mapSeqAxis: Vec3? = nil   // F630: mapsequencearoundcontrolpoint "axis"
        for case let i as [String: Any] in (json["initializer"] as? [Any] ?? []) {
            switch i["name"] as? String {
            case "lifetimerandom":
                inits.append(.lifetimeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "sizerandom":
                inits.append(.sizeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                         exponent: pexponent(i["exponent"]) ?? 1))
            case "colorrandom":
                inits.append(.colorRandom(min: pvec3(i["min"]) ?? Vec3(x: 255, y: 255, z: 255),
                                          max: pvec3(i["max"]) ?? Vec3(x: 255, y: 255, z: 255),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "alpharandom":
                // C4-(i): min/max 부재 시 WE 실기본값은 0,0(불투명 아님 — bokeh 백화 원인).
                inits.append(.alphaRandom(min: pfloat(i["min"]) ?? 0, max: pfloat(i["max"]) ?? 0,
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "velocityrandom":
                inits.append(.velocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "rotationrandom":
                inits.append(.rotationRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "angularvelocityrandom":
                inits.append(.angularVelocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                    max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                    exponent: pexponent(i["exponent"]) ?? 1))
            case "turbulentvelocityrandom":
                inits.append(.turbulentVelocityRandom(speedMin: pfloat(i["speedmin"]) ?? 0, speedMax: pfloat(i["speedmax"]) ?? 0,
                                                      scale: pfloat(i["scale"]) ?? 1, offset: pfloat(i["offset"]) ?? 0))
            case "colorlist":
                // 실물: colors = ["r g b", ...] 0..1 스케일(colorrandom 의 0..255 와 다름 — 실측).
                let colors = (i["colors"] as? [Any] ?? []).compactMap { pvec3($0) }
                if !colors.isEmpty { inits.append(.colorList(colors: colors)) }
            case "mapsequencearoundcontrolpoint":
                inits.append(.mapSequence(count: pfloat(i["count"]) ?? 0,
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: false))
                // F630: "0 1 0" 같은 회전축 — 각도 평면 선택(기본 z축 레거시, 마지막 지정 승).
                mapSeqAxis = pvec3(i["axis"]) ?? mapSeqAxis
            case "mapsequencebetweencontrolpoints":
                inits.append(.mapSequence(count: pfloat(i["count"]) ?? 0,
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: true))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported initializer dropped: \(other ?? "nil")")
            }
        }

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

        var ops: [ParticleOperator] = []
        // controlpointattract 의 CP id — controlpoint 배열이 오퍼레이터보다 뒤에 파스되므로
        // (ops 인덱스, cpid)만 보관했다가 def 조립 직전에 target 재조립(감사 V04).
        var attractCPIds: [(op: Int, cp: Int)] = []
        // F624: vortex 출현 순 병렬 오디오반응(WE: vortex 오디오반응 = particle speed 를 오디오에 연결).
        var vortexAudio: [AudioProcessing?] = []
        for case let o as [String: Any] in (json["operator"] as? [Any] ?? []) {
            switch o["name"] as? String {
            case "movement":
                ops.append(.movement(gravity: pvec3(o["gravity"]) ?? Vec3(x: 0, y: 0, z: 0), drag: pfloat(o["drag"]) ?? 0))
            case "alphafade":
                ops.append(.alphaFade(fadeInTime: pfloat(o["fadeintime"]) ?? 0, fadeOutTime: pfloat(o["fadeouttime"]) ?? 0))
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
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = pfloat(o["frequencymin"]) ?? 0
                ops.append(.oscillateAlpha(frequencyMin: fmin, frequencyMax: pfloat(o["frequencymax"]) ?? fmin,
                                           scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? 1,
                                           phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0))
            case "oscillateposition":
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = pfloat(o["frequencymin"]) ?? 0
                ops.append(.oscillatePosition(frequencyMin: fmin, frequencyMax: pfloat(o["frequencymax"]) ?? fmin,
                                              scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? smin,
                                              phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0,
                                              mask: pvec3(o["mask"]) ?? Vec3(x: 1, y: 1, z: 1)))
            case "controlpointattract":
                // CP 지정(범위 내) 시 CP offset 이 target, 미지정 시 origin 유지(무회귀).
                if let cpid = pint(o["controlpoint"]), cpid >= 0, cpid < 8 {
                    attractCPIds.append((op: ops.count, cp: cpid))
                }
                ops.append(.controlPointAttract(scale: pfloat(o["scale"]) ?? 0,
                                                threshold: pfloat(o["threshold"]) ?? 0,
                                                target: pvec3(o["origin"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "vortex":
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),
                                   distanceInner: pfloat(o["distanceinner"]) ?? 0,
                                   distanceOuter: pfloat(o["distanceouter"]) ?? 0,
                                   speedInner: pfloat(o["speedinner"]) ?? 0,
                                   speedOuter: pfloat(o["speedouter"]) ?? 0,
                                   offset: pvec3(o["offset"]) ?? Vec3(x: 0, y: 0, z: 0)))
                vortexAudio.append(AudioProcessing.parse(o))
            case "vortex_v2":
                // F631: 실측 2인스턴스(3585875739)는 ring 키 없이 표준 vortex 파라미터(distanceinner/
                // outer·speedinner)만 — 표준 vortex 로 근사 매핑(종전 default 드롭 → 소용돌이 복원).
                // axis/offset 부재 = vortex 기본과 동일, speedouter 부재 = speedinner 승계.
                let sIn = pfloat(o["speedinner"]) ?? 0
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),
                                   distanceInner: pfloat(o["distanceinner"]) ?? 0,
                                   distanceOuter: pfloat(o["distanceouter"]) ?? 0,
                                   speedInner: sIn,
                                   speedOuter: pfloat(o["speedouter"]) ?? sIn,
                                   offset: pvec3(o["offset"]) ?? Vec3(x: 0, y: 0, z: 0)))
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
                let smin = pfloat(o["scalemin"]) ?? 1
                let fmin = pfloat(o["frequencymin"]) ?? 0
                ops.append(.oscillateSize(frequencyMin: fmin, frequencyMax: pfloat(o["frequencymax"]) ?? fmin,
                                          scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? smin,
                                          phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0))
            case "alphachange":
                ops.append(.alphaChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        endTime: pfloat(o["endtime"]) ?? 1,
                                        startValue: pfloat(o["startvalue"]) ?? 1,
                                        endValue: pfloat(o["endvalue"]) ?? 0))
            case "remapvalue":
                let fbm = (o["transformfunction"] as? String) == "fbmnoise"
                let scale = pfloat(o["transforminputscale"]) ?? 1
                switch o["output"] as? String {
                case "velocity":
                    ops.append(.remapValue(output: .velocity(min: pvec3OrScalar(o["outputrangemin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                             max: pvec3OrScalar(o["outputrangemax"]) ?? Vec3(x: 0, y: 0, z: 0)),
                                           fbm: fbm, inputScale: scale))
                case "speed":
                    ops.append(.remapValue(output: .speed(min: pfloat(o["outputrangemin"]) ?? 0,
                                                          max: pfloat(o["outputrangemax"]) ?? 1),
                                           fbm: fbm, inputScale: scale))
                case let other:
                    WapleLog.warn("[Waple] remapvalue unsupported output dropped: \(other ?? "nil")")
                }
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported operator dropped: \(other ?? "nil")")
            }
        }

        var renderer: RendererKind = .unsupported("none")
        var orientation: ParticleOrientation = .screen
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
                children.append(ChildLink(
                    def: childDef, trigger: trigger,
                    maxInstances: pint(c["maxcount"]) ?? (trigger == .always ? 1 : maxCount),
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
            if case let .controlPointAttract(scale, threshold, _) = ops[i] {
                ops[i] = .controlPointAttract(scale: scale, threshold: threshold, target: controlPoints[cpid])
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
        def.vortexAudio = vortexAudio
        def.flags = pint(json["flags"]) ?? 0                                        // F623
        // F622: animationmode("sequence"/"randomframe")·sequencemultiplier(배속, 기본 1).
        def.animationMode = (json["animationmode"] as? String).flatMap { ParticleAnimationMode(rawValue: $0) }
        def.sequenceMultiplier = pfloat(json["sequencemultiplier"]) ?? 1
        def.orientation = orientation
        def.mapSequenceAxis = mapSeqAxis
        return def
    }
}

// MARK: - 파싱 헬퍼 (공용 JSONNumerics 위임 — 파티클 규약: 문자열 스칼라 거부, 언랩 없음)

private func pfloat(_ v: Any?) -> Float? { strictFloat(v) }
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
