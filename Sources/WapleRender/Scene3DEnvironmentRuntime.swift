import Foundation
import WapleCore

final class Scene3DEnvironmentRuntime {
    private let general: [String: Any]
    private let animations: [String: PropertyAnimation]
    private let scripts: [(key: String, engine: TextScriptEngine)]
    var isDynamic: Bool { !animations.isEmpty || scripts.contains { $0.engine.hasUpdate } }
    static let keys = ["fogdistance", "fogdistancecolor", "fogdistancestart", "fogdistanceend",
                       "fogdistancestartdensity", "fogdistanceenddensity", "fogheight", "fogheightcolor",
                       "fogheightstart", "fogheightend", "fogheightstartdensity", "fogheightenddensity"]

    init(general: [String: Any], makeEngine: (String) -> TextScriptEngine?) {
        self.general = general
        var animations: [String: PropertyAnimation] = [:]
        var scripts: [(String, TextScriptEngine)] = []
        for key in Self.keys {
            guard let binding = general[key] as? [String: Any] else { continue }
            if let animation = PropertyAnimation.parse(binding) { animations[key] = animation }
            if let source = binding["script"] as? String, let engine = makeEngine(source) {
                scripts.append((key, engine))
            }
        }
        self.animations = animations; self.scripts = scripts
    }

    func evaluate(time: Float) -> Scene3DFog {
        var current = general
        for (key, animation) in animations {
            let base = Self.components(general[key])
            let count = key.hasSuffix("color") ? 3 : 1
            let values = (0..<count).map { animation.value(component: $0, atTime: time, base: $0 < base.count ? base[$0] : 0) }
            current[key] = count == 1 ? values[0] as Any : values as Any
        }
        for script in scripts {
            script.engine.setRuntime(Double(time))
            if script.key == "fogheight" || script.key == "fogdistance" {
                let value = Self.components(current[script.key]).first ?? 0
                if let result = script.engine.evaluateBool(current: value >= 0.5) { current[script.key] = result }
            } else {
                let value = Self.components(current[script.key])
                if let result = script.engine.evaluateVec(current: value) { current[script.key] = result.count == 1 ? result[0] as Any : result as Any }
            }
        }
        return Scene3DFog.parse(general: current)
    }

    static func components(_ value: Any?) -> [Float] {
        if let binding = value as? [String: Any] { return components(binding["value"]) }
        if let number = value as? NSNumber, number.doubleValue.isFinite,
           abs(number.doubleValue) <= Double(Float.greatestFiniteMagnitude) { return [number.floatValue] }
        if let value = value as? String { return value.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }.filter(\.isFinite) }
        if let values = value as? [Any] { return values.compactMap { components($0).first } }
        return []
    }
}

struct Scene3DLightRuntime {
    static let keys = ["visible", "color", "intensity", "radius", "origin", "angles", "exponent",
                       "innercone", "outercone", "density", "volumetricsexponent", "castvolumetrics", "castshadow"]

    let index: Int
    let authored: SceneLight3D
    let scripts: [String: TextScriptEngine]

    func evaluate(time: Float) -> SceneLight3D {
        func animated(_ key: String, _ values: [Float]) -> [Float] {
            guard let animation = authored.propertyAnimations[key] else { return values }
            return values.enumerated().map { animation.value(component: $0.offset, atTime: time, base: $0.element) }
        }
        func engine(_ key: String) -> TextScriptEngine? {
            let script = scripts[key]
            script?.setRuntime(Double(time))
            return script
        }
        func flag(_ key: String, _ base: Bool) -> Bool {
            let value = animated(key, [base ? 1 : 0])[0] >= 0.5
            return engine(key)?.evaluateBool(current: value) ?? value
        }
        func scalar(_ key: String, _ base: Float) -> Float {
            let value = animated(key, [base])
            return engine(key)?.evaluateVec(current: value)?.first ?? value[0]
        }
        func vector(_ key: String, _ base: Vec3) -> Vec3 {
            let values = animated(key, [base.x, base.y, base.z])
            let evaluated = key == "angles"
                ? engine(key)?.evaluateAnglesVec(currentRadians: values)
                : engine(key)?.evaluateVec(current: values)
            let result = evaluated.flatMap { $0.count >= 3 ? $0 : nil } ?? values
            return Vec3(x: result[0], y: result[1], z: result[2])
        }
        var light = authored
        light.initialVisible = flag("visible", authored.initialVisible)
        light.color = vector("color", authored.color)
        light.intensity = scalar("intensity", authored.intensity)
        light.radius = scalar("radius", authored.radius)
        light.origin = vector("origin", authored.origin)
        light.angles = vector("angles", authored.angles)
        light.exponent = scalar("exponent", authored.exponent)
        light.innerCone = scalar("innercone", authored.innerCone)
        light.outerCone = scalar("outercone", authored.outerCone)
        light.density = scalar("density", authored.density)
        light.volumetricsExponent = scalar("volumetricsexponent", authored.volumetricsExponent)
        light.castVolumetrics = flag("castvolumetrics", authored.castVolumetrics)
        light.castShadow = flag("castshadow", authored.castShadow)
        return light
    }
}

extension SceneRenderer {
    var scene3DUserValues: [String: Any] {
        variantProperties.mapValues { value in
            switch value {
            case .string(let value): return value as Any
            case .number(let value): return value as Any
            case .bool(let value): return value as Any
            case .none: return NSNull()
            }
        }
    }
}
