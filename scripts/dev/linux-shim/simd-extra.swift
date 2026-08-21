// 리눅스용 **`simd` 모듈 추가 대역** — `WapleRender` 가 쓰고 `simd.swift` 에는 없는 것만.
//
// 왜 별도 파일인가: `simd.swift` 는 `WapleCore` 리눅스 테스트(`linux-core-tests.sh`)의 자산이고
// 그쪽 소유다. 여기에 렌더 계층 전용 심볼을 섞으면 코어 테스트 쪽 빌드 표면이 바뀐다.
// `linux-render-typecheck.sh` 만 이 파일을 함께 컴파일한다(같은 `simd` 모듈에 합류).
//
// **`simd.swift` 에 이미 있는 것을 여기 다시 선언하면 중복 선언 오류가 난다.** 현재 그쪽에 있는 것:
//   simd_float4x4(+연산자·inverse·determinant·subscript·init(diagonal:)), matrix_identity_float4x4,
//   simd_length/length_squared/dot/cross/normalize(SIMD3)/abs/distance/mix/clamp, abs(SIMD2/3/4)
//
// 값이 아니라 **시그니처**가 목적이지만, 순수 수학이라 실제로 맞는 값을 계산해 둔다.
//
// `@_exported import Foundation`: 애플에서 `import simd` 만 한 파일도 `sin`/`cos`/`tan` 을 쓴다
// (`Scene3DMath.swift` 가 그렇다). 애플 `simd` 오버레이가 Darwin 수학 함수를 끌고 오기 때문이다 —
// 리눅스에서 같은 자리를 메우려면 이 모듈이 Foundation 을 재수출해야 한다.
@_exported import Foundation

// MARK: - 성분별 min/max

/// 실제: `public func simd_min<T>(_ x: T, _ y: T) -> T` (성분별 최솟값)
public func simd_min(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(Swift.min(a.x, b.x), Swift.min(a.y, b.y))
}
public func simd_min(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
}
public func simd_min(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z), Swift.min(a.w, b.w))
}
/// 실제: `public func simd_max<T>(_ x: T, _ y: T) -> T` (성분별 최댓값)
public func simd_max(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
}
public func simd_max(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
}
public func simd_max(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z), Swift.max(a.w, b.w))
}

/// 실제: `simd_normalize` 는 모든 벡터 폭에 있다 — `simd.swift` 에는 SIMD3 판만 있다.
public func simd_normalize(_ v: SIMD2<Float>) -> SIMD2<Float> { v / simd_length(v) }

// MARK: - simd_float4x4 보강

public extension simd_float4x4 {
    /// 실제 macOS `simd_float4x4` 는 `init(columns: (SIMD4<Float>, ...))` 를 **public** 으로 준다.
    /// `simd.swift` 의 구조체는 멤버와이즈 init 이 internal 이라 모듈 밖에서 안 보인다.
    init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        self.init(columns.0, columns.1, columns.2, columns.3)
    }
    /// 실제: `public init(_ scalar: Float)` — **대각에 scalar 를 채운 행렬**이다(비대각은 0).
    /// `simd_float4x4(1)` 이 항등이 되는 이유가 이것이다(`SceneRendererFrameEncoder.swift:48` 등).
    init(_ scalar: Float) {
        self.init(SIMD4(scalar, 0, 0, 0), SIMD4(0, scalar, 0, 0),
                  SIMD4(0, 0, scalar, 0), SIMD4(0, 0, 0, scalar))
    }
}

/// 실제: `public func simd_transpose(_ x: simd_float4x4) -> simd_float4x4`
public func simd_transpose(_ m: simd_float4x4) -> simd_float4x4 {
    let c = m.columns
    return simd_float4x4(SIMD4(c.0.x, c.1.x, c.2.x, c.3.x),
                         SIMD4(c.0.y, c.1.y, c.2.y, c.3.y),
                         SIMD4(c.0.z, c.1.z, c.2.z, c.3.z),
                         SIMD4(c.0.w, c.1.w, c.2.w, c.3.w))
}
/// 실제: `public func simd_inverse(_ x: simd_float4x4) -> simd_float4x4`
public func simd_inverse(_ m: simd_float4x4) -> simd_float4x4 { m.inverse }
/// 실제: `public func simd_determinant(_ x: simd_float4x4) -> Float`
public func simd_determinant(_ m: simd_float4x4) -> Float { m.determinant }

// MARK: - simd_float3x3

/// 실제: `public struct simd_float3x3 { public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
///        public init(columns:); public init(_ c0:_ c1:_ c2:); public subscript(column: Int) -> SIMD3<Float>
///        public var inverse/determinant/transpose ... }`
/// **열 주도**다 — `m[0]` 은 첫 **열**이고 `m[0][1]` 은 (행 1, 열 0) 성분이다.
public struct simd_float3x3: Equatable, Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) { self.columns = columns }
    public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) { columns = (c0, c1, c2) }
    public init() { self.init(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)) }
    public init(diagonal d: SIMD3<Float>) {
        self.init(SIMD3(d.x, 0, 0), SIMD3(0, d.y, 0), SIMD3(0, 0, d.z))
    }
    /// 실제: `public init(_ scalar: Float)` — 대각 채움(4x4 와 같다).
    public init(_ scalar: Float) { self.init(diagonal: SIMD3(repeating: scalar)) }
    public static func == (a: simd_float3x3, b: simd_float3x3) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
    }
    public subscript(column: Int) -> SIMD3<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            default: return columns.2
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            default: columns.2 = newValue
            }
        }
    }
    public var determinant: Float {
        let c = columns
        return c.0.x * (c.1.y * c.2.z - c.2.y * c.1.z)
             - c.1.x * (c.0.y * c.2.z - c.2.y * c.0.z)
             + c.2.x * (c.0.y * c.1.z - c.1.y * c.0.z)
    }
    public var transpose: simd_float3x3 {
        let c = columns
        return simd_float3x3(SIMD3(c.0.x, c.1.x, c.2.x),
                             SIMD3(c.0.y, c.1.y, c.2.y),
                             SIMD3(c.0.z, c.1.z, c.2.z))
    }
    public var inverse: simd_float3x3 {
        let d = determinant
        guard d != 0 else { return simd_float3x3(SIMD3(.nan, .nan, .nan), SIMD3(.nan, .nan, .nan),
                                                 SIMD3(.nan, .nan, .nan)) }
        let c = columns, k = 1 / d
        // 수반행렬(여인수 행렬의 전치) × 1/det.
        let a = c.0.x, b = c.1.x, cc = c.2.x
        let dd = c.0.y, e = c.1.y, f = c.2.y
        let g = c.0.z, h = c.1.z, i = c.2.z
        return simd_float3x3(SIMD3((e * i - f * h) * k, -(dd * i - f * g) * k, (dd * h - e * g) * k),
                             SIMD3(-(b * i - cc * h) * k, (a * i - cc * g) * k, -(a * h - b * g) * k),
                             SIMD3((b * f - cc * e) * k, -(a * f - cc * dd) * k, (a * e - b * dd) * k))
    }
    public static func * (m: simd_float3x3, v: SIMD3<Float>) -> SIMD3<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z
    }
    public static func * (a: simd_float3x3, b: simd_float3x3) -> simd_float3x3 {
        simd_float3x3(a * b.columns.0, a * b.columns.1, a * b.columns.2)
    }
    public static func * (m: simd_float3x3, s: Float) -> simd_float3x3 {
        simd_float3x3(m.columns.0 * s, m.columns.1 * s, m.columns.2 * s)
    }
}

public func simd_transpose(_ m: simd_float3x3) -> simd_float3x3 { m.transpose }
public func simd_inverse(_ m: simd_float3x3) -> simd_float3x3 { m.inverse }
public func simd_determinant(_ m: simd_float3x3) -> Float { m.determinant }

// MARK: - simd_float2x2

/// 실제: `public struct simd_float2x2 { public var columns: (SIMD2<Float>, SIMD2<Float>)
///        public init(columns:); public init(_ c0:_ c1:); public var inverse/determinant ... }`
public struct simd_float2x2: Equatable, Sendable {
    public var columns: (SIMD2<Float>, SIMD2<Float>)
    public init(columns: (SIMD2<Float>, SIMD2<Float>)) { self.columns = columns }
    public init(_ c0: SIMD2<Float>, _ c1: SIMD2<Float>) { columns = (c0, c1) }
    public init() { self.init(SIMD2(1, 0), SIMD2(0, 1)) }
    /// 실제: `public init(_ scalar: Float)` — 대각 채움.
    public init(_ scalar: Float) { self.init(SIMD2(scalar, 0), SIMD2(0, scalar)) }
    public static func == (a: simd_float2x2, b: simd_float2x2) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1
    }
    public subscript(column: Int) -> SIMD2<Float> {
        get { column == 0 ? columns.0 : columns.1 }
        set { if column == 0 { columns.0 = newValue } else { columns.1 = newValue } }
    }
    public var determinant: Float { columns.0.x * columns.1.y - columns.1.x * columns.0.y }
    public var transpose: simd_float2x2 {
        simd_float2x2(SIMD2(columns.0.x, columns.1.x), SIMD2(columns.0.y, columns.1.y))
    }
    public var inverse: simd_float2x2 {
        let d = determinant
        guard d != 0 else { return simd_float2x2(SIMD2(.nan, .nan), SIMD2(.nan, .nan)) }
        let k = 1 / d
        return simd_float2x2(SIMD2(columns.1.y * k, -columns.0.y * k),
                             SIMD2(-columns.1.x * k, columns.0.x * k))
    }
    public static func * (m: simd_float2x2, v: SIMD2<Float>) -> SIMD2<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y
    }
    public static func * (a: simd_float2x2, b: simd_float2x2) -> simd_float2x2 {
        simd_float2x2(a * b.columns.0, a * b.columns.1)
    }
    public static func * (m: simd_float2x2, s: Float) -> simd_float2x2 {
        simd_float2x2(m.columns.0 * s, m.columns.1 * s)
    }
}

public func simd_transpose(_ m: simd_float2x2) -> simd_float2x2 { m.transpose }
public func simd_inverse(_ m: simd_float2x2) -> simd_float2x2 { m.inverse }
public func simd_determinant(_ m: simd_float2x2) -> Float { m.determinant }
