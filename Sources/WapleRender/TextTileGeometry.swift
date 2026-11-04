import Foundation

/// Subdivides already near/far-clipped text triangles in homogeneous coordinates.
/// Linear interpolation of NDC would bend a tilted text layer at every tile boundary.
enum TextTileGeometry {
    struct Result {
        let vertices: [SIMD4<Float>]
        let projectiveDepth: SIMD4<Float>
    }

    private struct Vertex {
        var clip: SIMD3<Float> // x*w, y*w, w
        var uv: SIMD2<Float>
        func interpolated(to other: Vertex, fraction: Float) -> Vertex {
            Vertex(clip: clip + (other.clip - clip) * fraction,
                   uv: uv + (other.uv - uv) * fraction)
        }
    }

    /// rect = original full-layer UV min/max, textureRect = corresponding tile texture UV min/max.
    static func crop(vertices: [SIMD4<Float>], projectiveDepth: SIMD4<Float>,
                     rect: SIMD4<Float>, textureRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)) -> Result {
        let du = rect.z - rect.x, dv = rect.w - rect.y
        guard du > 0, dv > 0, vertices.count.isMultiple(of: 3) else {
            return Result(vertices: [], projectiveDepth: SIMD4(0, 0, 1, 0))
        }
        var output: [SIMD4<Float>] = []
        for start in stride(from: 0, to: vertices.count, by: 3) {
            var polygon = vertices[start..<(start + 3)].map { value -> Vertex in
                let w = projectiveDepth.w > 0.5
                    ? projectiveDepth.x * value.z + projectiveDepth.y * value.w + projectiveDepth.z : 1
                return Vertex(clip: SIMD3(value.x * w, value.y * w, w), uv: SIMD2(value.z, value.w))
            }
            for edge in 0..<4 {
                guard !polygon.isEmpty else { break }
                let input = polygon
                polygon = []
                func distance(_ vertex: Vertex) -> Float {
                    switch edge {
                    case 0: return vertex.uv.x - rect.x
                    case 1: return rect.z - vertex.uv.x
                    case 2: return vertex.uv.y - rect.y
                    default: return rect.w - vertex.uv.y
                    }
                }
                var previous = input[input.count - 1]
                var previousDistance = distance(previous)
                for current in input {
                    let currentDistance = distance(current)
                    if (previousDistance >= 0) != (currentDistance >= 0) {
                        let t = previousDistance / (previousDistance - currentDistance)
                        polygon.append(previous.interpolated(to: current, fraction: t))
                    }
                    if currentDistance >= 0 { polygon.append(current) }
                    previous = current
                    previousDistance = currentDistance
                }
            }
            guard polygon.count >= 3 else { continue }
            for index in 1..<(polygon.count - 1) {
                let triangle = [polygon[0], polygon[index], polygon[index + 1]]
                guard triangle.allSatisfy({ $0.clip.z.isFinite && abs($0.clip.z) > 1e-8 }) else { continue }
                for vertex in triangle {
                    let u = (vertex.uv.x - rect.x) / du
                    let v = (vertex.uv.y - rect.y) / dv
                    output.append(SIMD4(vertex.clip.x / vertex.clip.z, vertex.clip.y / vertex.clip.z,
                                        textureRect.x + u * (textureRect.z - textureRect.x),
                                        textureRect.y + v * (textureRect.w - textureRect.y)))
                }
            }
        }
        // v_main reconstructs w from the *tile texture* UV, including its filtering gutter.
        let textureDU = textureRect.z - textureRect.x, textureDV = textureRect.w - textureRect.y
        guard textureDU > 0, textureDV > 0 else { return Result(vertices: [], projectiveDepth: .zero) }
        let a = projectiveDepth.x * du / textureDU
        let b = projectiveDepth.y * dv / textureDV
        let c = projectiveDepth.z + projectiveDepth.x * rect.x + projectiveDepth.y * rect.y
            - a * textureRect.x - b * textureRect.y
        return Result(vertices: output, projectiveDepth: SIMD4(a, b, c, projectiveDepth.w))
    }
}
