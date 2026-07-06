import Foundation

// MARK: - 요소 타입

public enum Emitter: Equatable {
    /// 평면화 가능한 구 분포. dir = normalize(randUnit ⊙ directions); pos = origin + dir*rand(distMin,distMax).
    /// burst = 실물 "instantaneous"(버스트 개수, 0=연속 rate 방출). sign = 축별 방향 강제(+1/-1, 0=무클램프).
    case sphere(origin: Vec3, directions: Vec3, distanceMin: Float, distanceMax: Float,
                rate: Float, burst: Int, sign: Vec3)
    /// 박스 분포. pos.axis = origin.axis + rand(-distanceMax.axis, +distanceMax.axis).
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
    case lifetimeRandom(min: Float, max: Float)
    case sizeRandom(min: Float, max: Float)
    case colorRandom(min: Vec3, max: Vec3)            // 0..255
    case alphaRandom(min: Float, max: Float, exponent: Float)
    case velocityRandom(min: Vec3, max: Vec3)
    case rotationRandom(min: Vec3, max: Vec3)          // degrees
    case angularVelocityRandom(min: Vec3, max: Vec3)   // degrees/s
    case turbulentVelocityRandom(speedMin: Float, speedMax: Float, scale: Float, offset: Float)
    case colorList(colors: [Vec3])                     // 0..1 (실물 "r g b" 문자열 목록) — 균등 랜덤 선택
    /// 스프라이트시트 프레임 선택(스폰 시 확정). between=false: CP0 기준 각도 → 시퀀스,
    /// true: CP0→CP1 구간 투영 → 시퀀스. count=시퀀스 길이(시트 프레임 수와 다를 수 있음 — mirror 폴드).
    case mapSequence(count: Float, mirror: Bool, between: Bool)
}

/// 시퀀스 인덱스(스폰 시 0..count) → 시트 프레임 인덱스. mirror=핑퐁(주기 2N-2), 아니면 순환.
public func sheetFrameIndex(sequence: Float, frameCount: Int, mirror: Bool) -> Int {
    guard frameCount > 0 else { return 0 }
    let s = max(0, Int(sequence.rounded(.down)))
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
    case sizeChange(startTime: Float, startValue: Float, endValue: Float)
    case colorChange(startTime: Float, startValue: Vec3, endValue: Vec3)
    case angularMovement(force: Vec3)
    case oscillateAlpha(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float)
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
    /// 크기 진동: size ×= lerp(scaleMin, scaleMax, 0.5(1+sin(2πf·age+phase))). 파티클별 f/phase 스폰 샘플.
    case oscillateSize(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                       phaseMin: Float, phaseMax: Float)
    /// 알파 램프(초 단위 — 실물 长2.json lifetime3/endtime2 로 단위 확정): st..et 사이 sv→ev, 밖은 홀드.
    case alphaChange(startTime: Float, endTime: Float, startValue: Float, endValue: Float)
    /// 노이즈 리맵: velocity = 범위 보간(덮어쓰기, 매 스텝) / speed = 적분 속도 배수(비파괴 — 복리 방지).
    /// 노이즈 입력은 파티클별 위상 + age (근사 — WE 정의 미공개, 유계·탈동기·결정성 보장).
    case remapValue(output: RemapOutput, fbm: Bool, inputScale: Float)
}

public enum RemapOutput: Equatable {
    case velocity(min: Vec3, max: Vec3)
    case speed(min: Float, max: Float)
}

/// 파티클 렌더러. sprite = 빌보드 쿼드. trail 계열(spriteTrail/rope/ropeTrail)은
/// 파티클별 위치 히스토리를 두께 있는 리본(삼각 스트립)으로 그린다.
public enum RendererKind: Equatable {
    case sprite
    case spriteTrail(maxLength: Float, length: Float)
    case rope(subdivision: Int)
    case ropeTrail(length: Float, subdivision: Int)
    case unsupported(String)

    /// 히스토리 리본으로 그리는 트레일 계열인가.
    public var isTrail: Bool {
        switch self {
        case .spriteTrail, .rope, .ropeTrail: return true
        default: return false
        }
    }

    /// 리본에 보관할 위치 히스토리 샘플 수(step 당 1샘플, captureFrames=30fps 가정).
    /// spriteTrail=maxlength(세그먼트 수 근사), ropeTrail=length(초)×30, rope=고정 16. 4..24 로 클램프.
    public var trailSampleCount: Int {
        func clamp(_ v: Int) -> Int { min(24, max(4, v)) }
        switch self {
        case let .spriteTrail(maxLength, _):
            return maxLength > 0 ? clamp(Int(maxLength.rounded())) : 8
        case .rope:
            return 16
        case let .ropeTrail(length, _):
            return length > 0 ? clamp(Int((length * 30).rounded())) : 12
        default:
            return 0
        }
    }
}

public enum BlendKind: Equatable { case additive, translucent }

public struct ParticleMaterial: Equatable {
    public let textureName: String?
    public let blend: BlendKind
    public init(textureName: String?, blend: BlendKind) { self.textureName = textureName; self.blend = blend }

    public static func parse(_ json: [String: Any]) -> ParticleMaterial {
        guard let passes = json["passes"] as? [Any], let p0 = passes.first as? [String: Any] else {
            return ParticleMaterial(textureName: nil, blend: .translucent)
        }
        let blend: BlendKind = (p0["blending"] as? String) == "additive" ? .additive : .translucent
        var name: String? = nil
        if let texs = p0["textures"] as? [Any] {
            name = texs.compactMap { $0 as? String }.first(where: { !$0.isEmpty })
        }
        return ParticleMaterial(textureName: name, blend: blend)
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

    public init(emitters: [Emitter], initializers: [Initializer], operators: [ParticleOperator],
                renderer: RendererKind, maxCount: Int, startTime: Float, material: ParticleMaterial?,
                children: [ChildLink] = []) {
        self.emitters = emitters; self.initializers = initializers; self.operators = operators
        self.renderer = renderer; self.maxCount = maxCount; self.startTime = startTime; self.material = material
        self.children = children
    }

    /// resolveChild: 자식 json 경로 → def (호출측이 pkg/머티리얼/재귀 리졸브 담당). nil 리졸브 = 링크 드롭+로그.
    public static func parse(_ json: [String: Any], material: ParticleMaterial?,
                             resolveChild: ((String) -> ParticleSystemDef?)? = nil) -> ParticleSystemDef {
        var emitters: [Emitter] = []
        for case let e as [String: Any] in (json["emitter"] as? [Any] ?? []) {
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
            case "boxrandom":
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: pfloat(e["rate"]) ?? 0,
                    burst: pint(e["instantaneous"]) ?? 0))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported emitter dropped: \(other ?? "nil")")
            }
        }

        var inits: [Initializer] = []
        for case let i as [String: Any] in (json["initializer"] as? [Any] ?? []) {
            switch i["name"] as? String {
            case "lifetimerandom": inits.append(.lifetimeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1))
            case "sizerandom": inits.append(.sizeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1))
            case "colorrandom":
                inits.append(.colorRandom(min: pvec3(i["min"]) ?? Vec3(x: 255, y: 255, z: 255),
                                          max: pvec3(i["max"]) ?? Vec3(x: 255, y: 255, z: 255)))
            case "alpharandom":
                inits.append(.alphaRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1, exponent: pfloat(i["exponent"]) ?? 1))
            case "velocityrandom":
                inits.append(.velocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "rotationrandom":
                inits.append(.rotationRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "angularvelocityrandom":
                inits.append(.angularVelocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                    max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0)))
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
            case "mapsequencebetweencontrolpoints":
                inits.append(.mapSequence(count: pfloat(i["count"]) ?? 0,
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: true))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported initializer dropped: \(other ?? "nil")")
            }
        }

        var ops: [ParticleOperator] = []
        for case let o as [String: Any] in (json["operator"] as? [Any] ?? []) {
            switch o["name"] as? String {
            case "movement":
                ops.append(.movement(gravity: pvec3(o["gravity"]) ?? Vec3(x: 0, y: 0, z: 0), drag: pfloat(o["drag"]) ?? 0))
            case "alphafade":
                ops.append(.alphaFade(fadeInTime: pfloat(o["fadeintime"]) ?? 0, fadeOutTime: pfloat(o["fadeouttime"]) ?? 0))
            case "sizechange":
                ops.append(.sizeChange(startTime: pfloat(o["starttime"]) ?? 0, startValue: pfloat(o["startvalue"]) ?? 1, endValue: pfloat(o["endvalue"]) ?? 1))
            case "colorchange":
                ops.append(.colorChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        startValue: pvec3(o["startvalue"]) ?? Vec3(x: 1, y: 1, z: 1),
                                        endValue: pvec3(o["endvalue"]) ?? Vec3(x: 1, y: 1, z: 1)))
            case "angularmovement":
                ops.append(.angularMovement(force: pvec3(o["force"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "oscillatealpha":
                let smin = pfloat(o["scalemin"]) ?? 0
                ops.append(.oscillateAlpha(frequencyMin: pfloat(o["frequencymin"]) ?? 0, frequencyMax: pfloat(o["frequencymax"]) ?? 0,
                                           scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? smin))
            case "oscillateposition":
                let smin = pfloat(o["scalemin"]) ?? 0
                ops.append(.oscillatePosition(frequencyMin: pfloat(o["frequencymin"]) ?? 0, frequencyMax: pfloat(o["frequencymax"]) ?? 0,
                                              scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? smin,
                                              phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0,
                                              mask: pvec3(o["mask"]) ?? Vec3(x: 1, y: 1, z: 1)))
            case "controlpointattract":
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
                ops.append(.oscillateSize(frequencyMin: pfloat(o["frequencymin"]) ?? 0, frequencyMax: pfloat(o["frequencymax"]) ?? 0,
                                          scaleMin: smin, scaleMax: pfloat(o["scalemax"]) ?? smin,
                                          phaseMin: pfloat(o["phasemin"]) ?? 0, phaseMax: pfloat(o["phasemax"]) ?? 0))
            case "alphachange":
                // ponytail: 기본 sv0→ev1/et1(WE 에디터 관례 추정) — 실물 preview 대비 어긋나면 여기 튜닝.
                ops.append(.alphaChange(startTime: pfloat(o["starttime"]) ?? 0, endTime: pfloat(o["endtime"]) ?? 1,
                                        startValue: pfloat(o["startvalue"]) ?? 0, endValue: pfloat(o["endvalue"]) ?? 1))
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
        if let r0 = (json["renderer"] as? [Any])?.first as? [String: Any] {
            let n = r0["name"] as? String ?? "none"
            switch n {
            case "sprite": renderer = .sprite
            case "spritetrail":
                renderer = .spriteTrail(maxLength: pfloat(r0["maxlength"]) ?? 0, length: pfloat(r0["length"]) ?? 0)
            case "rope":
                renderer = .rope(subdivision: pint(r0["subdivision"]) ?? 0)
            case "ropetrail":
                renderer = .ropeTrail(length: pfloat(r0["length"]) ?? 0, subdivision: pint(r0["subdivision"]) ?? 0)
            default:
                renderer = .unsupported(n); WapleLog.warn("[Waple] SP4 unsupported renderer (drawn as sprite): \(n)")
            }
        }

        let maxCount = pint(json["maxcount"]) ?? 100

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

        var def = ParticleSystemDef(
            emitters: emitters, initializers: inits, operators: ops, renderer: renderer,
            maxCount: maxCount, startTime: pfloat(json["starttime"]) ?? 0, material: material,
            children: children)
        for case let cp as [String: Any] in (json["controlpoint"] as? [Any] ?? []) {
            if let id = pint(cp["id"]), id >= 0, id < 8, let off = pvec3(cp["offset"]) {
                def.controlPoints[id] = off
            }
        }
        return def
    }
}

// MARK: - 파싱 헬퍼

private func pfloat(_ v: Any?) -> Float? {
    if let d = v as? Double { return Float(d) }
    if let i = v as? Int { return Float(i) }
    return nil
}
private func pint(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    return nil
}
private func pvec3(_ v: Any?) -> Vec3? {
    guard let s = v as? String else { return nil }
    let f = s.split(separator: " ").compactMap { Float($0) }
    return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
}
/// "x y z" 벡터 또는 단일 스칼라(브로드캐스트).
private func pvec3OrScalar(_ v: Any?) -> Vec3? {
    if let vec = pvec3(v) { return vec }
    if let s = pfloat(v) { return Vec3(x: s, y: s, z: s) }
    return nil
}
