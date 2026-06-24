import Foundation

// MARK: - 요소 타입

public enum Emitter: Equatable {
    /// 평면화 가능한 구 분포. dir = normalize(randUnit ⊙ directions); pos = origin + dir*rand(distMin,distMax).
    case sphere(origin: Vec3, directions: Vec3, distanceMin: Float, distanceMax: Float, rate: Float)
    /// 박스 분포. pos.axis = origin.axis + rand(-distanceMax.axis, +distanceMax.axis).
    case box(origin: Vec3, distanceMax: Vec3, rate: Float)

    public var rate: Float {
        switch self {
        case let .sphere(_, _, _, _, r): return r
        case let .box(_, _, r): return r
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
}

public enum RendererKind: Equatable { case sprite; case unsupported(String) }

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

// MARK: - 시스템 정의

public struct ParticleSystemDef: Equatable {
    public let emitters: [Emitter]
    public let initializers: [Initializer]
    public let operators: [ParticleOperator]
    public let renderer: RendererKind
    public let maxCount: Int
    public let startTime: Float
    public let material: ParticleMaterial?

    public init(emitters: [Emitter], initializers: [Initializer], operators: [ParticleOperator],
                renderer: RendererKind, maxCount: Int, startTime: Float, material: ParticleMaterial?) {
        self.emitters = emitters; self.initializers = initializers; self.operators = operators
        self.renderer = renderer; self.maxCount = maxCount; self.startTime = startTime; self.material = material
    }

    public static func parse(_ json: [String: Any], material: ParticleMaterial?) -> ParticleSystemDef {
        var emitters: [Emitter] = []
        for case let e as [String: Any] in (json["emitter"] as? [Any] ?? []) {
            switch e["name"] as? String {
            case "sphererandom":
                emitters.append(.sphere(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    directions: pvec3(e["directions"]) ?? Vec3(x: 1, y: 1, z: 1),
                    distanceMin: pfloat(e["distancemin"]) ?? 0,
                    distanceMax: pfloat(e["distancemax"]) ?? 0,
                    rate: pfloat(e["rate"]) ?? 0))
            case "boxrandom":
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: pfloat(e["rate"]) ?? 0))
            case let other:
                NSLog("%@", "[Waple] SP4 unsupported emitter dropped: \(other ?? "nil")")
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
            case let other:
                NSLog("%@", "[Waple] SP4 unsupported initializer dropped: \(other ?? "nil")")
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
            case let other:
                NSLog("%@", "[Waple] SP4 unsupported operator dropped: \(other ?? "nil")")
            }
        }

        var renderer: RendererKind = .unsupported("none")
        if let r0 = (json["renderer"] as? [Any])?.first as? [String: Any] {
            let n = r0["name"] as? String ?? "none"
            if n == "sprite" { renderer = .sprite }
            else { renderer = .unsupported(n); NSLog("%@", "[Waple] SP4 unsupported renderer (drawn as sprite): \(n)") }
        }

        return ParticleSystemDef(
            emitters: emitters, initializers: inits, operators: ops, renderer: renderer,
            maxCount: pint(json["maxcount"]) ?? 100, startTime: pfloat(json["starttime"]) ?? 0, material: material)
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
