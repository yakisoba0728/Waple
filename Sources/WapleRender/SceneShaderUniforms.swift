import Metal
import simd
import WapleCore

extension SceneRenderer {
    @discardableResult func bindUniformSlots(_ values: [SIMD4<Float>], to encoder: MTLRenderCommandEncoder, index: Int) -> Bool {
        guard !values.isEmpty else { return true }
        return values.withUnsafeBytes { raw in
            if raw.count <= 4096 {
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: index)
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: index)
                return true
            } else if let buffer = encoder.device.makeBuffer(bytes: raw.baseAddress!, length: raw.count) {
                encoder.setVertexBuffer(buffer, offset: 0, index: index)
                encoder.setFragmentBuffer(buffer, offset: 0, index: index)
                return true
            }
            return false
        }
    }
    func logicalUniform(_ packed: [SIMD4<Float>], parameter: MaterialParam) -> [Float] {
        let columns: Int
        let rows: Int
        switch parameter.type {
        case .mat2: columns = 2; rows = 2
        case .mat3: columns = 3; rows = 3
        case .mat4: columns = 4; rows = 4
        case .mat4x3: columns = 4; rows = 3
        default: columns = 1; rows = max(1, parameter.type.components)
        }
        let columnStride = rows == 3 ? 4 : rows
        let elementStride = columns * columnStride
        return (0..<(columns * rows * parameter.arrayCount)).map { logical in
            let element = logical / (columns * rows)
            let component = logical % (columns * rows)
            let offset = element * elementStride + (component / rows) * columnStride + component % rows
            let value = packed[parameter.slotOffset + offset / 4][offset % 4]
            if parameter.type.msl.hasPrefix("int") { return Float(Int32(bitPattern: value.bitPattern)) }
            if parameter.type.msl.hasPrefix("uint") { return Float(value.bitPattern) }
            return value
        }
    }

    func replaceUniform(_ packed: inout [SIMD4<Float>], parameter: MaterialParam, values: [Float]) {
        var logical = logicalUniform(packed, parameter: parameter)
        for (index, value) in values.prefix(logical.count).enumerated() { logical[index] = value }
        for (index, value) in GLSLTranslator.packUniform(type: parameter.type,
            arrayCount: parameter.arrayCount, values: logical).enumerated() {
            packed[parameter.slotOffset + index] = value
        }
    }
    func packedMaterial(_ parameters: [MaterialParam], values: (MaterialParam) -> [Float]) -> [SIMD4<Float>] {
        let count = parameters.map { $0.slotOffset + $0.slotCount }.max() ?? 0
        var result = [SIMD4<Float>](repeating: .zero, count: count)
        for parameter in parameters {
            let packed = GLSLTranslator.packUniform(type: parameter.type,
                arrayCount: parameter.arrayCount, values: values(parameter))
            for (index, value) in packed.enumerated() { result[parameter.slotOffset + index] = value }
        }
        return result
    }

    /// Shared by 2D effects and custom 3D producers; producers supply world/view/bone matrices explicitly.
    func shaderEngineValues(_ parameters: [ShaderEngineParam], overrides: [String: [Float]] = [:]) -> [SIMD4<Float>] {
        let count = parameters.map { $0.slotOffset + $0.slotCount }.max() ?? 0
        var result = [SIMD4<Float>](repeating: .zero, count: count)
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        func flattened(_ vectors: [SIMD4<Float>]) -> [Float] {
            vectors.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        for parameter in parameters {
            var values = overrides[parameter.name]
            if values == nil {
                switch parameter.name {
                case "g_LightAmbientColor":
                    let color = runtimeSceneDocument?.ambientColor
                    values = [color?.x ?? lightAmbient.x, color?.y ?? lightAmbient.y, color?.z ?? lightAmbient.z]
                case "g_LightSkylightColor":
                    let color = runtimeSceneDocument?.skylightColor
                    values = [color?.x ?? 0, color?.y ?? 0, color?.z ?? 0]
                case "g_LightsPosition": values = flattened(lightPositions)
                case "g_LightsColorRadius", "g_LightsColorPremultiplied": values = flattened(lightColorRadius)
                case "g_EyePosition": values = [sceneCameraEye2D.x, sceneCameraEye2D.y, 0]
                case "g_ViewRight": values = [1, 0, 0]
                case "g_ViewUp": values = [0, 1, 0]
                case "g_ViewForward": values = [0, 0, -1]
                default:
                    if parameter.type == .mat4 || parameter.type == .mat4x3 || parameter.type == .mat3 || parameter.type == .mat2 {
                        let element: [Float]
                        switch parameter.type {
                        case .mat2: element = [1, 0, 0, 1]
                        case .mat3: element = [1, 0, 0, 0, 1, 0, 0, 0, 1]
                        case .mat4x3: element = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
                        default: element = identity
                        }
                        values = Array(repeating: element, count: parameter.arrayCount).flatMap { $0 }
                    }
                }
            }
            let packed = GLSLTranslator.packUniform(type: parameter.type,
                arrayCount: parameter.arrayCount, values: values ?? [])
            for (index, value) in packed.enumerated() { result[parameter.slotOffset + index] = value }
        }
        return result
    }

    @discardableResult func bindEngineParameters(_ parameters: [ShaderEngineParam], to encoder: MTLRenderCommandEncoder,
                              overrides: [String: [Float]] = [:]) -> Bool {
        let values = shaderEngineValues(parameters, overrides: overrides)
        return bindUniformSlots(values, to: encoder, index: 9)
    }
}
