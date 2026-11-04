import Foundation

/// The CPU and Metal use the same natural element stride; each declaration starts at a float4 boundary.
public struct ShaderEngineParam: Equatable, Hashable, Sendable {
    public let name: String
    public let type: GLSLType
    public let arrayCount: Int
    public let isArray: Bool
    public let slotOffset: Int
    public var slotCount: Int { type.uniformSlotCount(arrayCount: arrayCount) }
}

extension GLSLType {
    var uniformLogicalComponents: Int {
        switch self {
        case .mat2: return 4
        case .mat3: return 9
        case .mat4: return 16
        case .mat4x3: return 12
        default: return max(1, components)
        }
    }

    var uniformStride: Int {
        switch self {
        case .mat2: return 4
        case .mat3: return 12
        case .mat4, .mat4x3: return 16
        case .vec3, .uvec3, .ivec3: return 4
        default: return max(1, components)
        }
    }

    func uniformSlotCount(arrayCount: Int) -> Int { (uniformStride * max(1, arrayCount) + 3) / 4 }

    func uniformExpression(buffer: String, offset: Int, isArray: Bool) -> String {
        if !isArray, self == .float || self == .vec2 || self == .vec3 || self == .vec4 {
            return "\(buffer)[\(offset)]\(swizzle)"
        }
        let pointer = "reinterpret_cast<constant \(msl)*>(\(buffer) + \(offset))"
        return isArray ? "(\(pointer))" : "(*\(pointer))"
    }
}

extension GLSLTranslator {
    /// Input matrix components are column-major, without Metal's float3 column padding.
    /// Integer uniforms use their bit representation, rather than reinterpreting a floating-point value.
    public static func packUniform(type: GLSLType, arrayCount: Int = 1, values: [Float]) -> [SIMD4<Float>] {
        guard (1...4096).contains(arrayCount) else { return [] }
        var floats = [Float](repeating: 0, count: type.uniformSlotCount(arrayCount: arrayCount) * 4)
        for element in 0..<arrayCount {
            for component in 0..<type.uniformLogicalComponents {
                let source = element * type.uniformLogicalComponents + component
                guard source < values.count else { continue }
                let target: Int
                if type == .mat3 || type == .mat4x3 {
                    target = element * type.uniformStride + (component / 3) * 4 + component % 3
                } else { target = element * type.uniformStride + component }
                let value = values[source]
                switch type {
                case .int, .ivec2, .ivec3, .ivec4:
                    let bounded = value.isFinite ? min(max(Double(value), Double(Int32.min)), Double(Int32.max)) : 0
                    floats[target] = Float(bitPattern: UInt32(bitPattern: Int32(bounded)))
                case .uint, .uvec2, .uvec3, .uvec4:
                    let bounded = value.isFinite ? min(max(Double(value), 0), Double(UInt32.max)) : 0
                    floats[target] = Float(bitPattern: UInt32(bounded))
                default: floats[target] = value
                }
            }
        }
        return stride(from: 0, to: floats.count, by: 4).map {
            SIMD4(floats[$0], floats[$0 + 1], floats[$0 + 2], floats[$0 + 3])
        }
    }
}
