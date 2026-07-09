import Foundation

/// Vorbis 역 MDCT. 명세/stb_vorbis(퍼블릭 도메인) IMDCT 정의:
///   y[i] = Σ_{k=0}^{N/2-1} X[k]·cos( (π/2N)·(2i+1+N/2)·(2k+1) ),  i∈0..<N
/// (정규화 없음 — 이후 윈도/오버랩이 스케일을 맞춘다.)
///
/// 두 구현:
/// - `naive`: 정의 직역(O(N²)). 느리지만 자명 → fast 검증 기준 및 파이프라인 초기 검증.
/// - `fast` : z = DCT-IV(X, L=N/2)(2L점 복소 FFT); stb TDAC unfold. naive 와 동치(유닛테스트로 고정).
enum VorbisImdct {

    /// 정의 직역 IMDCT(기준). X: N/2 계수 → N 샘플.
    static func naive(_ X: [Float], _ n: Int) -> [Float] {
        let n2 = n / 2
        var y = [Float](repeating: 0, count: n)
        let scale = Double.pi / Double(2 * n)
        for i in 0..<n {
            let a = Double(2 * i + 1 + n2)
            var acc = 0.0
            for k in 0..<n2 { acc += Double(X[k]) * cos(scale * a * Double(2 * k + 1)) }
            y[i] = Float(acc)
        }
        return y
    }

    /// 빠른 IMDCT: z = DCT-IV(X, L=N/2); stb TDAC unfold(inverse_mdct_slow):
    ///   y[i] =  z[i+N/4]          (0 ≤ i < N/4)
    ///   y[i] = -z[3N/4-1-i]       (N/4 ≤ i < 3N/4)
    ///   y[i] = -z[i-3N/4]         (3N/4 ≤ i < N)
    static func fast(_ X: [Float], _ n: Int, _ plan: FFTPlan) -> [Float] {
        let n4 = n / 4, n34 = n - n4
        let z = dctIV(X, n / 2, plan)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n4 { y[i] = z[i + n4] }
        for i in n4..<n34 { y[i] = -z[n34 - 1 - i] }
        for i in n34..<n { y[i] = -z[i - n34] }
        return y
    }

    /// 표준 DCT-IV(길이 L): z[m] = Σ_{k=0}^{L-1} X[k]·cos((π/L)(k+½)(m+½)).
    /// 2L 점 복소 FFT 로: g[k]=X[k]·exp(iπk/2L); S[m]=Σ g[k]·exp(i2πkm/2L)=2L·IFFT_{2L}(g)[m];
    /// z[m]=Re{ exp(i(πm/2L+π/4L))·S[m] }. (plan 크기 = 2L)
    static func dctIV(_ X: [Float], _ L: Int, _ plan: FFTPlan) -> [Float] {
        let N2 = 2 * L
        var re = [Double](repeating: 0, count: N2)
        var im = [Double](repeating: 0, count: N2)
        let pre = Double.pi / Double(2 * L)
        for k in 0..<L {
            let ang = pre * Double(k)                    // exp(+iπk/2L)
            re[k] = Double(X[k]) * cos(ang)
            im[k] = Double(X[k]) * sin(ang)
        }
        plan.transform(&re, &im, inverse: true)          // (1/2L)·Σ g·exp(+i2πkm/2L)
        var z = [Float](repeating: 0, count: L)
        let scale = Double(N2)
        let post = Double.pi / Double(4 * L)
        for m in 0..<L {
            let sr = re[m] * scale, si = im[m] * scale    // S[m]
            let ang = pre * Double(m) + post              // πm/2L + π/4L
            z[m] = Float(sr * cos(ang) - si * sin(ang))
        }
        return z
    }
}

/// 라딕스-2 반복 복소 FFT(길이 = 2^k). in-place. naive DFT 와 동치(테스트로 고정).
/// vDSP 대신 순수 Swift — 의존성 0, N≤2048 라 성능 충분.
final class FFTPlan {
    let n: Int
    private let logn: Int
    private let cosT: [Double]
    private let sinT: [Double]
    private let rev: [Int]

    init(_ n: Int) {
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT length must be power of two")
        self.n = n
        var lg = 0; var t = n; while t > 1 { t >>= 1; lg += 1 }
        self.logn = lg
        var c = [Double](repeating: 0, count: n / 2)
        var s = [Double](repeating: 0, count: n / 2)
        for i in 0..<(n / 2) {
            let ang = -2.0 * Double.pi * Double(i) / Double(n)
            c[i] = cos(ang); s[i] = sin(ang)
        }
        cosT = c; sinT = s
        var r = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var x = i, y = 0
            for _ in 0..<lg { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = y
        }
        rev = r
    }

    /// in-place FFT. inverse=true 면 켤레·1/n 정규화(표준 IFFT).
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let sign = inverse ? -1.0 : 1.0
        for i in 0..<n {
            let j = rev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var i = 0
            while i < n {
                var k = 0
                for j in i..<(i + half) {
                    let wr = cosT[k]
                    let wi = sign * sinT[k]
                    let tr = wr * re[j + half] - wi * im[j + half]
                    let ti = wr * im[j + half] + wi * re[j + half]
                    re[j + half] = re[j] - tr
                    im[j + half] = im[j] - ti
                    re[j] += tr
                    im[j] += ti
                    k += step
                }
                i += len
            }
            len <<= 1
        }
        if inverse {
            let inv = 1.0 / Double(n)
            for i in 0..<n { re[i] *= inv; im[i] *= inv }
        }
    }
}
