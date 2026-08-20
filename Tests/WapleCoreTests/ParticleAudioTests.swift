import XCTest
import simd
@testable import WapleCore

/// 파티클 이미터 오디오반응(WE audioprocessing*) — 파스 + rate 변조 + 무음 폴백 가드.
/// 코퍼스 13씬(audioprocessingmode) 대상. 무신호(캡처 무음/공급자 부재) 시 기존 경로와 비트동일이어야 한다.
final class ParticleAudioTests: XCTestCase {

    // MARK: - 파스 (실측 스키마)

    /// 실측 magic_pulse(sphererandom: mode3/freqend10/exponent5, bounds 부재) +
    /// Stars(boxrandom: bounds "0.5 1"/mode3) → 이미터 병렬 emitterAudio.
    func testAudioProcessingEmitterParse() throws {
        let source = """
        {"emitter":[
           {"name":"sphererandom","rate":1,"audioprocessingmode":3,"audioprocessingfrequencyend":10,"audioprocessingexponent":5},
           {"name":"boxrandom","distancemax":"1000 500 0","rate":40,"audioprocessingbounds":"0.5 1","audioprocessingmode":3}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        XCTAssertEqual(def.emitterAudio.count, def.emitters.count)  // 병렬 정렬 유지

        let a0 = try XCTUnwrap(def.emitterAudio[0])
        XCTAssertEqual(a0.mode, 3)
        XCTAssertEqual(a0.freqEnd, 10)
        XCTAssertEqual(a0.exponent, 5)
        XCTAssertEqual(a0.freqStart, 0)          // 부재 기본
        // bounds 부재 기본 [0.8,1.0] — 문자열 `"0.8 1.0"`@0x14048f3b8(RVA 0x48f3b8, len 7, 태그 4),
        // 주입 0x1401c1ffc. 종전 인용 `@0x48e1b8` 은 파일 오프셋이었고(RVA 는 +0x1200),
        // "귀속 추정" 표기도 과소였다 — 태그·길이·주입 지점으로 확정된다.
        XCTAssertEqual(a0.bounds.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(a0.bounds.y, 1)
        // exponent 부재 기본은 **2.0** 이다(`movabs rcx, 0x4000000000000000` @0x1401c1f77).
        // 종전 1 은 셰이더 경로에서 유추한 값이었다 — 파티클 경로는 자체 주입기를 가진다.

        let a1 = try XCTUnwrap(def.emitterAudio[1])
        XCTAssertEqual(a1.mode, 3)
        XCTAssertEqual(a1.bounds.x, 0.5)         // "0.5 1" 파스
        XCTAssertEqual(a1.bounds.y, 1)
        // **[2026-08-20 정정] freqEnd 부재 기본은 15 가 아니라 1 이다** —
        // `mov r8d, 1` @0x1401c212e → `H_INT` @0x1401c213e. 15 는 23.4Hz–14.7kHz 를 한 덩어리로
        // 뭉개고, 1 은 23.4–187.5Hz 두 밴드만 고른다. 저역 반응이 통째로 달라진다.
        XCTAssertEqual(a1.freqEnd, 1)
        XCTAssertEqual(a1.exponent, 2, "0x1401c1f77 — 종전 1 은 셰이더 경로 유추였다")
        XCTAssertEqual(a1.freqStart, 0, "0x1401c20eb — 이건 종전 값이 맞았다")
    }

    /// mode 0(off, 실측 5건) 및 audioprocessing 전부 부재 → nil(무반응 = 기존 rate).
    func testAudioProcessingModeZeroOrAbsentIsNil() {
        let source = """
        {"emitter":[
           {"name":"sphererandom","rate":1,"audioprocessingmode":0,"audioprocessingbounds":"0.8 1"},
           {"name":"boxrandom","distancemax":"1 1 1","rate":5}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        XCTAssertEqual(def.emitterAudio.count, 2)
        XCTAssertNil(def.emitterAudio[0])  // mode 0 = off
        XCTAssertNil(def.emitterAudio[1])  // 전부 부재
    }

    // MARK: - rate 변조 (오디오 값 주입 → 방출 변화)

    private func audioRateDef(rate: Float) -> ParticleSystemDef {
        var def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: rate, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], renderer: .sprite, maxCount: 100000, startTime: 0, material: nil)
        def.emitterAudio = [AudioProcessing(mode: 3, freqStart: 0, freqEnd: 15,
                                            bounds: SIMD2(0, 1), exponent: 1)]
        return def
    }

    /// 스펙트럼 진폭이 방출률을 구동: 강신호→rate 유지, 약신호→감소, 무신호→0 방출은 아니고(스킵) 별 테스트.
    func testAudioSpectrumDrivesEmissionRate() {
        let def = audioRateDef(rate: 100)
        func emit(_ level: Float) -> Int {
            var sim = ParticleSimulator(def: def, seed: 1)
            sim.currentAudio = AudioSpectrum16(left: Array(repeating: level, count: 16),
                                               right: Array(repeating: level, count: 16))
            return sim.step(1.0).count
        }
        let loud = emit(1.0)    // smoothstep(0,1,1)=1 → rate≈100
        let quiet = emit(0.1)   // smoothstep(0,1,0.1)≈0.028 → rate≈2.8
        XCTAssertGreaterThan(loud, 50, "강신호는 rate 를 살려야 한다")
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertLessThan(quiet, loud, "신호가 작을수록 방출률이 낮아야 한다")
    }

    // MARK: - 무음 폴백 가드 (A/B 핵심)

    /// audioprocessing 이미터라도 무신호(nil/silent)면 오디오 무시 경로와 **비트동일**.
    func testSilentAudioMatchesNoAudioBitExact() {
        var audioDef = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 50, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .velocityRandom(min: Vec3(x: 5, y: 0, z: 0), max: Vec3(x: 5, y: 0, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: -1, z: 0), drag: 0)],
            renderer: .sprite, maxCount: 1000, startTime: 0, material: nil)
        audioDef.emitterAudio = [AudioProcessing(mode: 3, freqStart: 0, freqEnd: 15,
                                                 bounds: SIMD2(0, 1), exponent: 1)]
        var plainDef = audioDef
        plainDef.emitterAudio = []  // 오디오 파스 이전과 동등한 기준(무반응)

        var withNil = ParticleSimulator(def: audioDef, seed: 7)          // currentAudio = nil
        var withSilent = ParticleSimulator(def: audioDef, seed: 7)
        withSilent.currentAudio = .silent                               // 전0 스펙트럼
        var plain = ParticleSimulator(def: plainDef, seed: 7)           // 오디오 무필드 기준

        for _ in 0..<25 {
            let pn = withNil.step(0.1)
            let ps = withSilent.step(0.1)
            let pp = plain.step(0.1)
            XCTAssertEqual(pn.count, pp.count)
            XCTAssertEqual(ps.count, pp.count)
            for (x, y) in zip(pn, pp) {
                XCTAssertEqual(x.pos, y.pos)
                XCTAssertEqual(x.uid, y.uid)
            }
            for (x, y) in zip(ps, pp) { XCTAssertEqual(x.pos, y.pos) }
        }
    }

    /// AudioSpectrum16.isSilent: 전0만 무신호, 어떤 빈이라도 비0이면 신호.
    func testSpectrumIsSilent() {
        XCTAssertTrue(AudioSpectrum16.silent.isSilent)
        XCTAssertTrue(AudioSpectrum16(left: [Float](repeating: 0, count: 16),
                                      right: [Float](repeating: 0, count: 16)).isSilent)
        var one = [Float](repeating: 0, count: 16); one[7] = 0.01
        XCTAssertFalse(AudioSpectrum16(left: one, right: [Float](repeating: 0, count: 16)).isSilent)
    }
}
