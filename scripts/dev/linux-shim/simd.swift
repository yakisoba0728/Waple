// 리눅스에서 `WapleCoreTests` 를 돌리기 위한 **`simd` 모듈 대역**.
//
// 왜 있는가
// ---------
// `WapleCore` 는 `import simd` 를 쓰는데 그 모듈은 애플 플랫폼 전용이다. 그래서 리눅스에서는
// 코어 테스트를 한 건도 못 돌리고 macOS CI 왕복(10분)만이 유일한 검증 수단이었다 —
// 실제로 이 브랜치에서 그 왕복으로만 잡힌 실패가 여러 번 있었다. 이 파일 + `corefoundation.swift`
// + `scripts/dev/linux-core-tests.sh` 로 같은 946개 테스트가 리눅스에서 **약 9초** 에 돈다.
//
// 규약: **값이 아니라 의미가 맞아야 한다.** 코어 테스트가 실제로 수치를 단언하므로 길이·내적·
// 외적 같은 것은 정확히 계산한다. macOS `simd` 와 부동소수 비트동일까지 보장하지는 않는다
// (그 판정은 CI 의 몫이다).

public struct simd_float4x4: Equatable, Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) { columns = (c0,c1,c2,c3) }
    public init() { self.init(SIMD4<Float>(1,0,0,0), SIMD4<Float>(0,1,0,0), SIMD4<Float>(0,0,1,0), SIMD4<Float>(0,0,0,1)) }
    public static func == (a: simd_float4x4, b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3 }
}

// 리눅스 타입체크용 최소 자유함수 — 값이 아니라 **시그니처**만 맞추면 된다.
import Foundation
public func simd_length(_ v: SIMD3<Float>) -> Float { (v.x*v.x + v.y*v.y + v.z*v.z).squareRoot() }
public func simd_length(_ v: SIMD2<Float>) -> Float { (v.x*v.x + v.y*v.y).squareRoot() }
public func simd_length_squared(_ v: SIMD3<Float>) -> Float { v.x*v.x + v.y*v.y + v.z*v.z }
public func simd_length_squared(_ v: SIMD2<Float>) -> Float { v.x*v.x + v.y*v.y }
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x*b.x + a.y*b.y }
public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) }
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / simd_length(v) }
public func simd_abs(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3<Float>(abs(v.x), abs(v.y), abs(v.z)) }
public func simd_abs(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2<Float>(abs(v.x), abs(v.y)) }
public func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(a - b) }
public func simd_mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * t }
public func simd_clamp(_ v: SIMD3<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(min(max(v.x, lo.x), hi.x), min(max(v.y, lo.y), hi.y), min(max(v.z, lo.z), hi.z)) }
public let matrix_identity_float4x4 = simd_float4x4()

public extension simd_float4x4 {
    static func * (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3) }
    static func * (a: simd_float4x4, v: SIMD4<Float>) -> SIMD4<Float> {
        a.columns.0 * v.x + a.columns.1 * v.y + a.columns.2 * v.z + a.columns.3 * v.w }
    static func * (a: simd_float4x4, s: Float) -> simd_float4x4 {
        simd_float4x4(a.columns.0 * s, a.columns.1 * s, a.columns.2 * s, a.columns.3 * s) }
    static func + (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(a.columns.0 + b.columns.0, a.columns.1 + b.columns.1,
                      a.columns.2 + b.columns.2, a.columns.3 + b.columns.3) }
}

// Linux 검증용 스텁 — Waple 은 프로파일러가 꺼져 있으면 이 값을 읽지 않는다(WapleProfiler.enabled).

// 4x4 여인수 전개 — Linux 타입체크·드라이버 전용(정확도 요구는 낮다).
public extension simd_float4x4 {
    private var m: [Float] {
        let c = columns
        return [c.0.x, c.0.y, c.0.z, c.0.w, c.1.x, c.1.y, c.1.z, c.1.w,
                c.2.x, c.2.y, c.2.z, c.2.w, c.3.x, c.3.y, c.3.z, c.3.w]
    }
    private var adjugateAndDet: ([Float], Float) {
        let a = m
        func mi(_ r: Int, _ c: Int) -> Float { a[c * 4 + r] }
        func cof(_ r: Int, _ c: Int) -> Float {
            let rs = [0, 1, 2, 3].filter { $0 != r }, cs = [0, 1, 2, 3].filter { $0 != c }
            let d = mi(rs[0], cs[0]) * (mi(rs[1], cs[1]) * mi(rs[2], cs[2]) - mi(rs[1], cs[2]) * mi(rs[2], cs[1]))
                  - mi(rs[0], cs[1]) * (mi(rs[1], cs[0]) * mi(rs[2], cs[2]) - mi(rs[1], cs[2]) * mi(rs[2], cs[0]))
                  + mi(rs[0], cs[2]) * (mi(rs[1], cs[0]) * mi(rs[2], cs[1]) - mi(rs[1], cs[1]) * mi(rs[2], cs[0]))
            return ((r + c) % 2 == 0 ? 1 : -1) * d
        }
        var adj = [Float](repeating: 0, count: 16)
        for r in 0..<4 { for c in 0..<4 { adj[r * 4 + c] = cof(r, c) } }   // 전치된 여인수 = 수반행렬
        let det = (0..<4).reduce(Float(0)) { $0 + mi(0, $1) * cof(0, $1) }
        return (adj, det)
    }
    var determinant: Float { adjugateAndDet.1 }
    var inverse: simd_float4x4 {
        let (adj, det) = adjugateAndDet
        let k = det == 0 ? 0 : 1 / det
        func col(_ c: Int) -> SIMD4<Float> {
            SIMD4(adj[c * 4 + 0] * k, adj[c * 4 + 1] * k, adj[c * 4 + 2] * k, adj[c * 4 + 3] * k)
        }
        return simd_float4x4(col(0), col(1), col(2), col(3))
    }
}

public extension simd_float4x4 {
    init(diagonal d: SIMD4<Float>) {
        self.init(SIMD4(d.x, 0, 0, 0), SIMD4(0, d.y, 0, 0), SIMD4(0, 0, d.z, 0), SIMD4(0, 0, 0, d.w))
    }
}

// 리눅스 로컬 테스트용: macOS simd 의 열 서브스크립트.
public extension simd_float4x4 {
    subscript(column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: return columns.3
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: columns.3 = newValue
            }
        }
    }
}

// macOS simd 가 제공하는 SIMD 성분별 abs — 없으면 `abs(a - b)` 가 오버로드 해석에 실패한다.
public func abs(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(Swift.abs(v.x), Swift.abs(v.y)) }
public func abs(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z)) }
public func abs(_ v: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z), Swift.abs(v.w))
}
