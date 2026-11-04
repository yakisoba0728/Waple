import Metal
import simd
import WapleCore

extension Scene3DLighting {
    /// The original V1 arrays partition by kind; w carries radius/exponent/cone, never a guessed value.
    static func shaderLightValues(_ lights: [Scene3DResolvedLight]) -> (combos: [String: Int], values: [String: [Float]]) {
        var values: [String: [Float]] = [:]
        var counts: [Scene3DLightKind: Int] = [:]
        func append(_ name: String, _ vector: SIMD4<Float>) { values[name, default: []] += [vector.x, vector.y, vector.z, vector.w] }
        for light in lights {
            counts[light.kind, default: 0] += 1
            switch light.kind {
            case .point:
                append("g_LPoint_Color", light.colorRadius)
                append("g_LPoint_Origin", SIMD4(light.position, light.exponent))
            case .spot:
                append("g_LSpot_Color", light.colorRadius)
                append("g_LSpot_Origin", SIMD4(light.position, light.coneInnerCos))
                append("g_LSpot_Direction", SIMD4(light.forward, light.coneOuterCos))
                append("g_LSpot_Exponent", SIMD4(light.exponent, 0, 0, 0))
            case .tube:
                append("g_LTube_Color", light.colorRadius)
                append("g_LTube_OriginA", SIMD4(light.position, light.exponent))
                append("g_LTube_OriginB", SIMD4(light.originB ?? light.position, 0))
            case .directional:
                append("g_LDirectional_Color", light.colorRadius)
                append("g_LDirectional_Direction", SIMD4(light.forward, 0))
            }
        }
        return (["LIGHTS_POINT": counts[.point] ?? 0, "LIGHTS_SPOT": counts[.spot] ?? 0,
                 "LIGHTS_TUBE": counts[.tube] ?? 0, "LIGHTS_DIRECTIONAL": counts[.directional] ?? 0,
                 "LIGHTS_POINT_SHADOW": 0, "LIGHTS_SPOT_SHADOW": 0, "LIGHTS_SPOT_SHADOW_COOKIE": 0,
                 "LIGHTS_SPOT_COOKIE": 0, "LIGHTS_DIRECTIONAL_SHADOW": 0,
                 "LIGHTS_COOKIE": 0, "LIGHTS_SHADOW_MAPPING": 0], values)
    }
}

extension SceneRenderer {
    func shader3DEngineValues(model: simd_float4x4, view: simd_float4x4, projection: simd_float4x4,
                              eye: SIMD3<Float>, lights: [Scene3DResolvedLight],
                              bones: [simd_float4x4] = []) -> [String: [Float]] {
        let viewProjection = projection * view
        let modelView = view * model
        let normal = Scene3DMath.normalMatrix4x4(model)
        var values = Scene3DLighting.shaderLightValues(lights).values
        let matrices = ["g_ModelMatrix": model, "g_ModelViewMatrix": modelView,
                        "g_ViewMatrix": view, "g_ProjectionMatrix": projection,
                        "g_ViewProjectionMatrix": viewProjection, "g_ModelViewProjectionMatrix": viewProjection * model,
                        "g_ModelMatrixInverse": PuppetPose.safeInverse(model),
                        "g_ModelViewMatrixInverse": PuppetPose.safeInverse(modelView),
                        "g_ViewMatrixInverse": PuppetPose.safeInverse(view),
                        "g_ProjectionMatrixInverse": PuppetPose.safeInverse(projection),
                        "g_ViewProjectionMatrixInverse": PuppetPose.safeInverse(viewProjection),
                        "g_ModelViewProjectionMatrixInverse": PuppetPose.safeInverse(viewProjection * model),
                        "g_AltModelMatrix": model, "g_AltViewProjectionMatrix": viewProjection]
        for (name, matrix) in matrices { values[name] = Scene3DMath.matrixElements(matrix) }
        let normalValues = (0..<3).flatMap { column in (0..<3).map { normal[column][$0] } }
        values["g_NormalModelMatrix"] = normalValues
        values["g_AltNormalModelMatrix"] = normalValues
        values["g_EyePosition"] = [eye.x, eye.y, eye.z]
        let inverseView = PuppetPose.safeInverse(view)
        values["g_ViewRight"] = [inverseView[0].x, inverseView[0].y, inverseView[0].z]
        values["g_ViewUp"] = [inverseView[1].x, inverseView[1].y, inverseView[1].z]
        values["g_ViewForward"] = [-inverseView[2].x, -inverseView[2].y, -inverseView[2].z]
        values["g_LightAmbientColor"] = [scene3DAmbient.x, scene3DAmbient.y, scene3DAmbient.z]
        values["g_LightSkylightColor"] = [scene3DSkylight.x, scene3DSkylight.y, scene3DSkylight.z]
        values["g_Bones"] = bones.flatMap { matrix in (0..<4).flatMap { c in (0..<3).map { matrix[c][$0] } } }
        let legacy = lights.prefix(4)
        values["g_LightsPosition"] = legacy.flatMap { [$0.position.x, $0.position.y, $0.position.z] }
        values["g_LightsColorRadius"] = legacy.flatMap { [$0.colorRadius.x, $0.colorRadius.y, $0.colorRadius.z, $0.colorRadius.w] }
        let colors = Array(legacy.map(\.colorRadius)) + Array(repeating: SIMD4<Float>.zero, count: max(0, 4 - legacy.count))
        values["g_LightsColorPremultiplied"] = [colors[0].x, colors[0].y, colors[0].z, colors[3].x,
                                               colors[1].x, colors[1].y, colors[1].z, colors[3].y,
                                               colors[2].x, colors[2].y, colors[2].z, colors[3].z]
        return values
    }
}
