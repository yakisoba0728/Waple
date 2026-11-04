import Foundation

/// The engine's generated text, reconstructed in docs/re/scene-lighting.md §2.2/§3.1.
/// Counts and parallel-array order must come from the same resolved light list in the renderer.
enum ShaderLightingV1 {
    static func source(defines: [String: Int]) -> String? {
        guard (defines["LIGHTING"] ?? 0) != 0 else { return "" }
        let p = defines["LIGHTS_POINT"] ?? 0, s = defines["LIGHTS_SPOT"] ?? 0
        let t = defines["LIGHTS_TUBE"] ?? 0, d = defines["LIGHTS_DIRECTIONAL"] ?? 0
        let ps = defines["LIGHTS_POINT_SHADOW"] ?? 0, ds = defines["LIGHTS_DIRECTIONAL_SHADOW"] ?? 0
        let ssc = defines["LIGHTS_SPOT_SHADOW_COOKIE"] ?? 0
        let sc = defines["LIGHTS_SPOT_COOKIE"] ?? 0, ss = defines["LIGHTS_SPOT_SHADOW"] ?? 0
        guard [p, s, t, d].allSatisfy({ (0...15).contains($0) }),
              [ps, ds, ssc, sc, ss].allSatisfy({ (0...3).contains($0) }),
              ps <= p, ds <= d, ssc + sc + ss <= s else { return nil }
        let projections = 3 * ds + ssc + sc + ss
        var declarations: [String] = []
        func declare(_ type: String, _ names: [String], _ count: Int) {
            guard count > 0 else { return }
            declarations += names.map { "uniform \(type) \($0)[\(count)];" }
        }
        declare("vec4", ["g_LPoint_Color", "g_LPoint_Origin"], p)
        declare("vec4", ["g_LSpot_Color", "g_LSpot_Origin", "g_LSpot_Direction", "g_LSpot_Exponent"], s)
        declare("vec4", ["g_LTube_Color", "g_LTube_OriginA", "g_LTube_OriginB"], t)
        declare("vec4", ["g_LDirectional_Color", "g_LDirectional_Direction"], d)
        declare("mat4", ["g_LFeature_ShadowProjection"], projections)
        declare("vec4", ["g_LFeature_ShadowProjectionTransform"], projections)
        declare("vec4", ["g_LFeature_ShadowPointProjection", "g_LFeature_ShadowPointProjectionTransform"], ps)
        var blocks: [String] = []
        for i in 0..<p {
            var body = "vec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"
            if i < ps {
                body += "vec4 projectedCoords = CalculateProjectedCoordsPoint(worldPos, g_LPoint_Origin[i].xyz, g_LFeature_ShadowPointProjection[i], g_LFeature_ShadowPointProjectionTransform[i]);\n"
                body += "float shadowFactor = PerformPointShadowMapping(projectedCoords);\n"
            }
            body += "light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w, g_LPoint_Origin[i].w, specularTint, ambient, roughness, metallic, \(i < ps ? "shadowFactor" : "1.0"));"
            blocks.append("{ const uint i = \(i)u;\n\(body)\n}")
        }
        for i in 0..<s {
            let cookie = i < ssc + sc
            let shadow = i < ssc || (i >= ssc + sc && i < ssc + sc + ss)
            var body = "vec3 lightDelta = g_LSpot_Origin[i].xyz - worldPos;\n"
            if cookie || shadow {
                body += "vec3 projectedCoords = CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i]);\n"
            }
            if shadow { body += "float shadowFactor = PerformShadowMapping(projectedCoords, g_LFeature_ShadowProjectionTransform[i]);\n" }
            if cookie { body += "vec3 colorCookie = texSample2D(COOKIE_SAMPLER, projectedCoords.xy).rgb;\n" }
            else {
                body += "float spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz);\n"
                body += "spotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie);\n"
            }
            body += "light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LSpot_Color[i].rgb * \(cookie ? "colorCookie" : "spotCookie"), g_LSpot_Color[i].w, g_LSpot_Exponent[i].x, specularTint, ambient, roughness, metallic, \(shadow ? "shadowFactor" : "1.0"));"
            blocks.append("{ const uint i = \(i)u;\n\(body)\n}")
        }
        for i in 0..<t {
            blocks.append("""
            { const uint i = \(i)u;
            vec3 lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz);
            light += ComputePBRLightShadow(normal, lightDelta, viewVector, color, g_LTube_Color[i].rgb, g_LTube_Color[i].w, g_LTube_OriginA[i].w, specularTint, ambient, roughness, metallic, 1.0);
            }
            """)
        }
        for i in 0..<d {
            var body = ""
            if i < ds {
                // Waple deliberately fixes WE's overlapping +1 cascade cursor (scene-lighting.md §4).
                let base = ssc + sc + ss + 3 * i
                body += "const uint p1 = \(base)u; const uint p2 = \(base + 1)u; const uint p3 = \(base + 2)u;\n"
                for c in 1...3 { body += "vec4 projectedCoords\(c) = CalculateProjectedCoordsCascades(worldPos, g_LFeature_ShadowProjection[p\(c)]);\n" }
                body += """
                projectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords2.xyz, projectedCoords1.w);
                projectedCoords1.xyz = mix(projectedCoords1.xyz, projectedCoords3.xyz, projectedCoords2.w);
                vec4 uvTransforms = mix(g_LFeature_ShadowProjectionTransform[p1], g_LFeature_ShadowProjectionTransform[p2], projectedCoords1.w);
                uvTransforms = mix(uvTransforms, g_LFeature_ShadowProjectionTransform[p3], projectedCoords2.w);
                float shadowFactor = max(projectedCoords3.w, PerformShadowMapping(projectedCoords1.xyz, uvTransforms));

                """
            }
            body += "light += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, color, g_LDirectional_Color[i].rgb, specularTint, ambient, roughness, metallic, \(i < ds ? "shadowFactor" : "1.0"));"
            blocks.append("{ const uint i = \(i)u;\n\(body)\n}")
        }
        return declarations.joined(separator: "\n") + "\n" + """
        vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic) {
            vec3 light = CAST3(0.0);
        \(blocks.joined(separator: "\n"))
            return light;
        }
        """
    }
}
