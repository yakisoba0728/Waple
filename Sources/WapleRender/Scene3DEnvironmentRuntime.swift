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
