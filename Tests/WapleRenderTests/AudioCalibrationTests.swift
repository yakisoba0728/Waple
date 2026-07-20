import XCTest
import Foundation
import simd
@testable import WapleCore
@testable import WapleRender

/// audio `/max` 캘리브 PART A 로컬 하네스 — 프로덕션 무변경, 후보 거동 특성화 전용.
/// 파이프라인(프로덕션 1:1): samples → magnitudes(512) → [후보 64빈 변환] → downsample16 → AudioResponse.compute.
/// 후보는 전부 테스트-로컬·동결 정의라 L5b FIX 가 AudioSpectrum.swift:26 의 /max 를 바꿔도 하네스는 생존한다.
/// - (A) 채널별 /max  : 현행 AudioSpectrum.spectrum(24-30행) 복제 — 진폭을 소거(불변) → 밸런스(#17)도 파괴.
/// - (B) raw          : AudioSpectrum.bin (정규화 없음) — 진폭 선형.
/// - (C) raw×G        : 원시×고정게인 — 진폭 단조 + 반응밴드 진입.
/// - (D) shared-max   : L/R 공유 max 정규화 — 진폭은 소거하나 밸런스는 보존.
final class AudioCalibrationTests: XCTestCase {
    private let sr: Float = 48000
    private let fftSize = 1024

    /// 풀스케일(A=1.0) 브로드밴드 화이트노이즈의 평균 64빈(=소비식에 실제로 들어가는 레벨)을
    /// 소비식 유효구간(코퍼스 최빈 bounds 0.5..1.0) 중앙 0.75 에 사상하는 시험 게인.
    /// A1 특성화 로그(noise mean64=32.2446)에서 역산: G = 0.75 / 32.2446. 순수 사인 피크(216.73)가 아니라
    /// 브로드밴드 평균으로 캘리브(A2 자극이 브로드밴드라 이게 밴드 진입을 결정).
    // ponytail: G는 L5b 회수 시 WE-정확값으로 핀.
    private static let G: Float = 0.75 / 32.2446   // = 0.023260; 레벨은 testA1 로그로 검증됨

    // ── 합성 신호 ──────────────────────────────────────────────
    private func sine(_ amp: Float, _ freqHz: Float, _ n: Int) -> [Float] {
        (0..<n).map { amp * sin(2 * .pi * freqHz * Float($0) / sr) }
    }
    /// 고정시드 화이트노이즈(±amp 균등, RMS≈amp/√3). LCG 라 플랫폼 무관 결정적.
    private func noise(_ amp: Float, _ n: Int, seed: UInt64 = 0xA11CE5EED) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return amp * (2 * Float(s >> 33) / Float(1 << 31) - 1)
        }
    }
    private func mags(_ samples: [Float]) -> [Float] {
        SystemAudioSpectrumProvider.magnitudes(from: samples, fftSize: fftSize) ?? []
    }

    // ── 후보 64빈 변환(동결) ───────────────────────────────────
    private func binMax(_ m: [Float]) -> [Float] {           // (A) 현행 채널별 /max 복제
        var b = AudioSpectrum.bin(m, binCount: 64)
        if let mx = b.max(), mx > 0 { for i in b.indices { b[i] /= mx } }
        return b
    }
    private func sharedMax(_ l: [Float], _ r: [Float]) -> ([Float], [Float]) {   // (D)
        var lb = l, rb = r
        let mx = max(lb.max() ?? 0, rb.max() ?? 0)
        if mx > 0 { for i in lb.indices { lb[i] /= mx }; for i in rb.indices { rb[i] /= mx } }
        return (lb, rb)
    }
    private typealias Cand = (name: String, xf: ([Float], [Float]) -> ([Float], [Float]))
    private var candidates: [Cand] {
        [ ("A/max",   { (self.binMax($0), self.binMax($1)) }),
          ("B raw",   { (AudioSpectrum.bin($0, binCount: 64), AudioSpectrum.bin($1, binCount: 64)) }),
          ("C rawxG", { (AudioSpectrum.bin($0, binCount: 64).map { $0 * Self.G },
                         AudioSpectrum.bin($1, binCount: 64).map { $0 * Self.G }) }),
          ("D shmax", { self.sharedMax(AudioSpectrum.bin($0, binCount: 64), AudioSpectrum.bin($1, binCount: 64)) }) ]
    }

    // ── 실저작 audioprocessing 설정(코퍼스 460종 하베스트 상위 10 co-occurring 튜플, 전부 mode 3) ──
    private struct Cfg { let bounds: SIMD2<Float>; let power, mul, fmin, fmax: Float; let weight: Int }
    private let configs: [Cfg] = [
        Cfg(bounds: [0.5, 1.0], power: 1.0, mul: 1.0,  fmin: 0,   fmax: 1,  weight: 60),
        Cfg(bounds: [0.0, 1.0], power: 1.0, mul: 1.0,  fmin: 0,   fmax: 1,  weight: 7),
        Cfg(bounds: [0.8, 1.0], power: 1.0, mul: 1.0,  fmin: 1,   fmax: 2,  weight: 6),
        Cfg(bounds: [0.8, 1.0], power: 1.0, mul: 0.2,  fmin: 0,   fmax: 1,  weight: 6),
        Cfg(bounds: [0.0, 1.0], power: 3.5, mul: 0.4,  fmin: 0,   fmax: 1,  weight: 4),
        Cfg(bounds: [0.5, 1.0], power: 1.0, mul: 0.5,  fmin: 0,   fmax: 1,  weight: 4),
        Cfg(bounds: [0.0, 1.2], power: 1.0, mul: 1.0,  fmin: 0,   fmax: 1,  weight: 4),
        Cfg(bounds: [0.5, 1.0], power: 0.32, mul: 1.0, fmin: 0,   fmax: 15, weight: 2),
        Cfg(bounds: [0.5, 1.0], power: 1.0, mul: 0.34, fmin: 0.5, fmax: 5,  weight: 2),
        Cfg(bounds: [0.4, 1.5], power: 0.5, mul: 0.5,  fmin: 0,   fmax: 1,  weight: 2),
    ]
    private func respond(_ l64: [Float], _ r64: [Float], _ c: Cfg) -> Float {
        AudioResponse.compute(left: AudioSpectrum16.downsample16(l64), right: AudioSpectrum16.downsample16(r64),
                              mode: 3, freqMin: c.fmin, freqMax: c.fmax,
                              bounds: c.bounds, power: c.power, multiply: c.mul)
    }

    // ── A1: 스케일 특성화(원시 빈은 진폭 선형인가) ─────────────
    func testA1_rawBinsAreAmplitudeLinear() {
        let amps: [Float] = [1.0, 0.5, 0.25]
        NSLog("%@", "[A1] === raw 64-bin 진폭 선형성 (1kHz 사인, 48k/1024) ===")
        var full: Float = 0
        for (i, a) in amps.enumerated() {
            let b = AudioSpectrum.bin(mags(sine(a, 1000, fftSize)), binCount: 64)
            let peak = b.max() ?? 0
            if i == 0 { full = peak }
            let ratio = full > 0 ? peak / full : 0
            NSLog("%@", "[A1] sine A=\(a)  peak64=\(peak)  peak/full=\(ratio)  (기대 \(a))")
            XCTAssertEqual(ratio, a, accuracy: 0.03, "원시 빈은 진폭 선형이어야(=A). /max 는 이를 소거함")
        }
        NSLog("%@", "[A1] fullScaleSinePeak64=\(full)  → 시험게인 G=0.75/peak=\(0.75 / full)")
        // 화이트노이즈 기지 RMS 행(브로드밴드 레벨 참고 — G 캘리브/A2 자극 검증용).
        let nb = AudioSpectrum.bin(mags(noise(1.0, fftSize)), binCount: 64)
        let nmean = nb.reduce(0, +) / Float(nb.count)
        NSLog("%@", "[A1] noise A=1.0  mean64=\(nmean)  peak64=\(nb.max() ?? 0)  (RMS≈0.577)")
        XCTAssertGreaterThan(nb.max() ?? 0, 0, "브로드밴드 노이즈는 비영 스펙트럼")
    }

    // ── A2: 후보 A/B — (A) 진폭 불변 vs (C) 진폭 단조 ───────────
    func testA2_candidateResponseAcrossAmplitude() {
        let amps: [Float] = [1.0, 0.5, 0.25]
        var reachedBand = [String: Int]()   // 후보별: 진폭에 응답이 실제로 변한 설정 수(반응밴드 진입 증거)
        for (ci, c) in configs.enumerated() {
            NSLog("%@", "[A2] cfg#\(ci) bounds=\(c.bounds) pow=\(c.power) mul=\(c.mul) freq=\(c.fmin)..\(c.fmax) w=\(c.weight)")
            for cand in candidates {
                let resp = amps.map { a -> Float in
                    let m = mags(noise(a, fftSize))
                    let (l, r) = cand.xf(m, m)
                    return respond(l, r, c)
                }
                NSLog("%@", "[A2]   \(cand.name)  A1.0=\(resp[0])  A0.5=\(resp[1])  A0.25=\(resp[2])")
                // (A)/(D): 진폭 정규화 → 스윕 전반 응답 불변(#17 원인).
                if cand.name == "A/max" || cand.name == "D shmax" {
                    XCTAssertEqual(resp[0], resp[2], accuracy: 1e-4, "\(cand.name)는 진폭 불변이어야(정규화가 진폭 소거)")
                }
                // (B)/(C): 원시 진폭 보존 → 단조 비감소.
                if cand.name == "B raw" || cand.name == "C rawxG" {
                    XCTAssertGreaterThanOrEqual(resp[0], resp[1] - 1e-6, "\(cand.name) 단조(A1.0≥A0.5)")
                    XCTAssertGreaterThanOrEqual(resp[1], resp[2] - 1e-6, "\(cand.name) 단조(A0.5≥A0.25)")
                }
                if resp[0] - resp[2] > 1e-3 { reachedBand[cand.name, default: 0] += 1 }
            }
        }
        NSLog("%@", "[A2] === 진폭에 응답이 변한 설정 수(=반응밴드 유지, /\(configs.count)) ===")
        for cand in candidates { NSLog("%@", "[A2]   \(cand.name): \(reachedBand[cand.name] ?? 0)") }
        // 특성화 핵심 단정: /max(A)는 어떤 설정에서도 진폭에 반응 못 함; raw×G(C)는 다수 설정에서 반응.
        XCTAssertEqual(reachedBand["A/max"] ?? 0, 0, "(A) /max 는 진폭에 전혀 반응 못 함(밴드 소실)")
        XCTAssertGreaterThan(reachedBand["C rawxG"] ?? 0, 0, "(C) raw×G 는 반응밴드를 유지")
    }

    // ── A2b: 채널 밸런스(#17) — 채널별 /max 가 L/R 비율을 파괴함 ──
    func testA2b_perChannelMaxDestroysStereoBalance() {
        let l = noise(1.0, fftSize)
        let r = l.map { $0 * 0.2512 }             // R = L −12dB (동일 형상, 레벨만)
        let ml = mags(l), mr = mags(r)
        func peakRatio(_ xf: ([Float], [Float]) -> ([Float], [Float])) -> Float {
            let (lb, rb) = xf(ml, mr); return (rb.max() ?? 0) / max(1e-9, lb.max() ?? 0)
        }
        let aRatio = peakRatio(candidates[0].xf)  // A /max
        let bRatio = peakRatio(candidates[1].xf)  // B raw
        let dRatio = peakRatio(candidates[3].xf)  // D shmax
        NSLog("%@", "[A2b] R/L 피크비  진짜=0.2512  A/max=\(aRatio)  B raw=\(bRatio)  D shmax=\(dRatio)")
        XCTAssertEqual(aRatio, 1.0, accuracy: 0.02, "(A) 채널별 /max → R/L=1 (밸런스 파괴, #17)")
        XCTAssertEqual(bRatio, 0.2512, accuracy: 0.01, "(B) raw → 진짜 비율 보존")
        XCTAssertEqual(dRatio, 0.2512, accuracy: 0.01, "(D) 공유 max → 진짜 비율 보존")
    }

    // ── 퇴행 가드: loud vs quiet 사인 → 라우드니스 민감도 스펙(FIX 후에도 생존) ──
    func testRegressionGuard_loudnessSensitivity() {
        let guardCfg = Cfg(bounds: [0.0, 1.0], power: 1.0, mul: 1.0, fmin: 0, fmax: 1, weight: 0)
        let loud = mags(sine(1.0, 1000, fftSize))          // 0 dBFS
        let quiet = mags(sine(0.1259, 1000, fftSize))      // −18 dB
        // (C) 진폭 보존 경로 = FIX 목표 거동. 라우드니스에 단조 반응해야.
        func respC(_ m: [Float]) -> Float { let (l, r) = candidates[2].xf(m, m); return respond(l, r, guardCfg) }
        let rc = (respC(loud), respC(quiet))
        NSLog("%@", "[GUARD] (C) 목표경로  loud=\(rc.0)  quiet=\(rc.1)")
        XCTAssertGreaterThan(rc.0, rc.1 + 1e-3, "loud 응답 > quiet (라우드니스 민감)")
        XCTAssertTrue(rc.0 > 0 && rc.0 < 1, "loud 은 (0,1) 개구간")
        XCTAssertTrue(rc.1 > 0 && rc.1 < 1, "quiet 은 (0,1) 개구간")
        // 현행 /max(A) 거동 문서화: 동일 형상 사인이라 loud≈quiet (라우드니스 소실 = FIX 필요 근거).
        func respA(_ m: [Float]) -> Float { let (l, r) = candidates[0].xf(m, m); return respond(l, r, guardCfg) }
        NSLog("%@", "[GUARD] (A) 현행 /max  loud=\(respA(loud))  quiet=\(respA(quiet))  (≈동일 = 버그)")
    }

    // ── 프로덕션 경로 직접 검증(FIX 착지 후): 실제 AudioSpectrum.spectrum() 이 (C) 거동인지 ──
    // 가드는 (C) 로컬 정의를 쓰지만 이건 프로덕션 spectrum() 을 직접 호출해 회귀를 잡는다.
    func testProductionSpectrumLoudnessSensitive() {
        let guardCfg = Cfg(bounds: [0.0, 1.0], power: 1.0, mul: 1.0, fmin: 0, fmax: 1, weight: 0)
        func respProd(_ m: [Float]) -> Float {
            let s = AudioSpectrum.spectrum(fromMagnitudes: m, binCount: 64)   // 프로덕션 경로
            return respond(s, s, guardCfg)
        }
        let loud = respProd(mags(sine(1.0, 1000, fftSize)))        // 0 dBFS
        let quiet = respProd(mags(sine(0.1259, 1000, fftSize)))    // −18 dB
        NSLog("%@", "[PROD] AudioSpectrum.spectrum()  loud=\(loud)  quiet=\(quiet)")
        XCTAssertGreaterThan(loud, quiet + 1e-3, "프로덕션 경로: loud 응답 > quiet (라우드니스 민감)")
        XCTAssertTrue(loud > 0 && loud < 1, "loud 은 (0,1) 개구간")
        XCTAssertTrue(quiet > 0 && quiet < 1, "quiet 은 (0,1) 개구간")
    }

    // ── A3: 렌더 비회귀(GPU, 마지막) — (C) 스펙트럼 주입 시 진폭↑ → luma 단조 ──
    func testA3_candidateCRenderLumaMonotone() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); c.rgb *= g_AudioSpectrum64Left[6]; gl_FragColor = c; }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/a3/effect.json","passes":[{}]}]}]}
        """
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/a3.vert", vert.data(using: .utf8)!),
            ("shaders/effects/a3.frag", frag.data(using: .utf8)!),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_a3cal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "a3cal", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "a3cal", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_a3cal")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // 후보 (C) 로 두 진폭의 64빈을 만들어 주입 — 진폭 보존이라 A↑ → bin[6]↑ → luma↑.
        func inject(_ a: Float) -> [Float] { AudioSpectrum.bin(mags(noise(a, fftSize)), binCount: 64).map { $0 * Self.G } }
        r.setSpectrum64(left: inject(0.25), right: inject(0.25))
        let lo = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first))
        r.setSpectrum64(left: inject(1.0), right: inject(1.0))
        let hi = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.2], toDir: out).first))
        NSLog("%@", "[A3] (C) 렌더 luma  A0.25=\(lo)  A1.0=\(hi)")
        XCTAssertGreaterThan(hi, lo + 0.02, "(C) 진폭 보존 → 큰 진폭이 더 밝아야(단조)")
    }
}
