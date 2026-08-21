import Foundation

/// `fluidsimulation` 의 **압력 투영 파이프라인**(발산 → Jacobi ×N → 경사 제거)을 격자 위에서
/// 그대로 돌린다. `docs/re/fluid-simulation.md` §2.13 의 수치 실험을 코드로 옮긴 것이다.
///
/// 왜 WapleCore 인가
/// -----------------
/// §2.13 은 지금까지 세션 스크래치의 파이썬 스크립트로만 존재했다(부록 A ⑦: "스크립트는 세션
/// 스크래치에 두었다"). 컨테이너는 휘발성이라 그 스크립트는 이미 없다 — 즉 문서의 표를
/// **재현할 수단이 리포에 없었다.** 여기로 옮기면 리눅스 레인에서 회귀로 돈다.
///
/// 격자 규약(§2.1 · §2.4 · §2.6 · §2.7)
/// ------------------------------------
/// * 인덱스: `index = y * width + x`. **`+y` 가 UV 의 "Top"** 이다(`vT = (u.x, u.y + hy)`).
/// * 도메인 밖 이웃은 **가장자리 복제**(샘플러 clamp) — 아홉 장 전건이 `uvs` 를 선언하지
///   않으므로 어드레싱 인자가 기본값 2 = clamp 다(§2.4a).
/// * 그 위에 divergence 패스만 최외곽 한 줄에서 **법선 성분을 반사**한다(`if` 4개).
/// * `subtractGradient` 에는 **0.5 가 없다**(§2.7 — 2배 과이완). `gradientCoefficient` 로
///   갈아 끼울 수 있게 열어 두지만 실물 값은 `1.0` 이다.
public enum FluidSimulationGrid {

    /// 버퍼 저장 정밀도. 실물은 속도 `rg16f` · 압력/발산 `r16f` 라 전건 `.binary16` 이다.
    public enum Precision {
        case float64
        case binary16

        @inlinable
        public func quantize(_ x: Double) -> Double {
            switch self {
            case .float64: return x
            case .binary16: return FluidSimulationPrecision.binary16Quantize(x)
            }
        }
    }

    /// 실물 `gradientsubtract.frag` 의 계수. `velocity.xy -= vec2(R - L, T - B);`
    public static let originalGradientCoefficient: Double = 1.0

    // MARK: - 샘플링

    static func clampedIndex(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Int {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        return cy * width + cx
    }

    // MARK: - 패스 2 : 발산 (§2.4)

    /// 네 개의 반사 `if` 를 포함한 발산장.
    public static func divergenceField(velocityX: [Double], velocityY: [Double],
                                       width: Int, height: Int,
                                       precision: Precision = .float64) -> [Double] {
        precondition(velocityX.count == width * height && velocityY.count == width * height)
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let center = FluidSimulation.Vec2(velocityX[y * width + x], velocityY[y * width + x])
                let l = velocityX[clampedIndex(x - 1, y, width, height)]
                let r = velocityX[clampedIndex(x + 1, y, width, height)]
                let t = velocityY[clampedIndex(x, y + 1, width, height)]
                let b = velocityY[clampedIndex(x, y - 1, width, height)]
                // 프래그먼트 중심이 (i+0.5)/N 이라 이웃 좌표가 도메인을 벗어나는 것은
                // 최외곽 한 줄뿐이다 — 격자에서는 곧 x==0 / x==W-1 / y==H-1 / y==0 이다.
                let d = FluidSimulation.divergence(
                    velocityXLeft: l, velocityXRight: r,
                    velocityYTop: t, velocityYBottom: b,
                    center: center,
                    neighborLeftU: x == 0 ? -1 : 0.5,
                    neighborRightU: x == width - 1 ? 2 : 0.5,
                    neighborTopV: y == height - 1 ? 2 : 0.5,
                    neighborBottomV: y == 0 ? -1 : 0.5)
                out[y * width + x] = precision.quantize(d)
            }
        }
        return out
    }

    // MARK: - 패스 4–12 : Jacobi (§2.6)

    /// `iterations` 번의 Jacobi 스윕. 실물 한 프레임은 `iterations = 9` 다.
    public static func jacobi(pressure: [Double], divergence: [Double],
                              width: Int, height: Int, iterations: Int,
                              precision: Precision = .float64) -> [Double] {
        var current = pressure.map { precision.quantize($0) }
        var next = current
        for _ in 0..<iterations {
            for y in 0..<height {
                for x in 0..<width {
                    let l = current[clampedIndex(x - 1, y, width, height)]
                    let r = current[clampedIndex(x + 1, y, width, height)]
                    let t = current[clampedIndex(x, y + 1, width, height)]
                    let b = current[clampedIndex(x, y - 1, width, height)]
                    next[y * width + x] = precision.quantize(
                        FluidSimulation.jacobiPressure(left: l, right: r, top: t, bottom: b,
                                                       divergence: divergence[y * width + x]))
                }
            }
            swap(&current, &next)
        }
        return current
    }

    // MARK: - 패스 13 : 경사 제거 (§2.7)

    public static func subtractGradient(velocityX: [Double], velocityY: [Double],
                                        pressure: [Double], width: Int, height: Int,
                                        coefficient: Double = originalGradientCoefficient,
                                        precision: Precision = .float64)
        -> (velocityX: [Double], velocityY: [Double]) {
        var vx = velocityX, vy = velocityY
        for y in 0..<height {
            for x in 0..<width {
                let l = pressure[clampedIndex(x - 1, y, width, height)]
                let r = pressure[clampedIndex(x + 1, y, width, height)]
                let t = pressure[clampedIndex(x, y + 1, width, height)]
                let b = pressure[clampedIndex(x, y - 1, width, height)]
                let i = y * width + x
                vx[i] = precision.quantize(velocityX[i] - coefficient * (r - l))
                vy[i] = precision.quantize(velocityY[i] - coefficient * (t - b))
            }
        }
        return (vx, vy)
    }

    // MARK: - 지표

    public static func meanAbsolute(_ field: [Double]) -> Double {
        guard !field.isEmpty else { return 0 }
        return field.reduce(0) { $0 + abs($1) } / Double(field.count)
    }

    /// **잔존 발산 비율(%)** — §2.13(b) 의 지표. 투영 뒤 `mean|div|` 를 투영 전으로 나눈 것.
    /// 100 % 면 투영이 아무것도 안 지웠다는 뜻이고, 100 % 를 넘으면 **발산했다**는 뜻이다
    /// (계수 1.0 + 반복 과다에서 실제로 일어난다 — §2.13(c)).
    public static func projectionResidualPercent(velocityX: [Double], velocityY: [Double],
                                                 width: Int, height: Int,
                                                 iterations: Int,
                                                 coefficient: Double = originalGradientCoefficient,
                                                 precision: Precision = .float64) -> Double {
        let vx = velocityX.map { precision.quantize($0) }
        let vy = velocityY.map { precision.quantize($0) }
        let before = divergenceField(velocityX: vx, velocityY: vy, width: width, height: height,
                                     precision: precision)
        let pressure = jacobi(pressure: [Double](repeating: 0, count: width * height),
                              divergence: before, width: width, height: height,
                              iterations: iterations, precision: precision)
        let projected = subtractGradient(velocityX: vx, velocityY: vy, pressure: pressure,
                                         width: width, height: height,
                                         coefficient: coefficient, precision: precision)
        let after = divergenceField(velocityX: projected.velocityX, velocityY: projected.velocityY,
                                    width: width, height: height, precision: precision)
        let base = meanAbsolute(before)
        guard base > 0 else { return 0 }
        return meanAbsolute(after) / base * 100
    }

    /// **따뜻한 시작의 정상상태 Jacobi 잔차(%)** — §2.13(d) 의 지표.
    ///
    /// 매 프레임 `p *= u_Pressure^(60·Δt)`(패스 3) 후 Jacobi 를 `iterationsPerFrame` 번 돌린다.
    /// 반환값은 `mean|∇²p − div|` 를 초기 `mean|div|` 로 나눈 것 — "압력 방정식이 얼마나
    /// 풀렸는가" 만 본다(§2.13(b) 의 잔존 발산과는 다른 지표다).
    ///
    /// 이 지표가 `r16f` 한계를 드러내는 **유일한** 자리다: `u_Pressure` 가 1.0 이면 압력이
    /// 프레임을 넘어 무한히 누적되는데, 누적이 커질수록 한 번의 Jacobi 갱신이
    /// `binary16SmallestResolvableRelativeStep` 아래로 내려가 그대로 사라진다.
    public static func warmStartResidualPercent(divergence: [Double],
                                                width: Int, height: Int,
                                                frames: Int,
                                                iterationsPerFrame: Int = FluidSimulation.pressureIterationCount,
                                                pressureDecay: Double = 1.0,
                                                precision: Precision = .float64) -> Double {
        let div = divergence.map { precision.quantize($0) }
        let base = meanAbsolute(div)
        var pressure = [Double](repeating: 0, count: width * height)
        for _ in 0..<frames {
            if pressureDecay != 1.0 {
                for i in pressure.indices { pressure[i] = precision.quantize(pressure[i] * pressureDecay) }
            }
            pressure = jacobi(pressure: pressure, divergence: div, width: width, height: height,
                              iterations: iterationsPerFrame, precision: precision)
        }
        var residual = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let l = pressure[clampedIndex(x - 1, y, width, height)]
                let r = pressure[clampedIndex(x + 1, y, width, height)]
                let t = pressure[clampedIndex(x, y + 1, width, height)]
                let b = pressure[clampedIndex(x, y - 1, width, height)]
                let i = y * width + x
                residual[i] = (l + r + t + b - 4 * pressure[i]) - div[i]
            }
        }
        guard base > 0 else { return 0 }
        return meanAbsolute(residual) / base * 100
    }

    // MARK: - 시험용 속도장

    /// 중심 가우시안의 x 성분만 있는 속도장. `sigma` 는 텍셀 단위다 —
    /// 에미터 규모 ≈ 13텍셀(`emitterSize 0.05`), 커서 규모 ≈ 4텍셀(`cursorinfluence 1`).
    public static func gaussianVelocityField(width: Int, height: Int,
                                             sigma: Double, amplitude: Double)
        -> (velocityX: [Double], velocityY: [Double]) {
        var vx = [Double](repeating: 0, count: width * height)
        let vy = [Double](repeating: 0, count: width * height)
        let cx = Double(width) * 0.5, cy = Double(height) * 0.5
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                vx[y * width + x] = amplitude * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            }
        }
        return (vx, vy)
    }
}
