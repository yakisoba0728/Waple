import XCTest
import Foundation
import simd
@testable import WapleCore

/// `remapvalue` **배선** 회귀 — `RemapSpec.flags` 파스와 `ParticleSimulator.remapEval` 이
/// `RemapValueMath` 를 실제로 부르는지.
///
/// 형제 클래스 `RemapOperationMathTests` 는 **산술**(순수 함수)을 잠근다. 이 클래스는 그
/// 산술이 시뮬레이터까지 **닿는지**를 잠근다 — 종전에 갈라져 있던 자리가 정확히 그 사이였다.
/// `RemapValueMath` 가 커밋된 뒤에도 `remapEval` 은 옛 식을 그대로 쓰고 있었고, 어떤 테스트도
/// 그 사실을 잡지 못했다(주입 ≠ 소비).
///
/// 근거 VA 는 전부 이 라운드에 `.pdata` 함수 시작(`0x14023fbc0` 오퍼레이터 VM /
/// `0x1401c5490` 파서 / `0x14023b340` 이니셜라이저 VM)에서 **선형으로** 다시 뜬 것이다.
final class ParticleRemapFlagsWiringTests: XCTestCase {

    // MARK: - 공용 하네스

    /// 오퍼레이터 하나짜리 최소 def. 수명을 고정해 `n = age/lifetime` 을 반환 파티클에서
    /// 그대로 읽을 수 있게 한다(반환 배열은 `display(p)` 사본이라 `age`/`lifetime` 이 살아 있다).
    private func defWith(_ spec: RemapSpec, lifetime: Float = 4) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                            distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime)],
            operators: [.remapValueEx(spec: spec)],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
    }

    /// `output` 채널을 `size` 로, 산술을 `remap`(=Assign) 으로 고정한 스펙 조립기.
    /// `size` 를 고르는 이유는 **표시 경로에서 클램프가 없는 유일한 채널**이라
    /// (`d.size = remapCombine(...)`, `opacity` 는 Waple 규약으로 `[0,1]` 에 갇힌다)
    /// `flags & 2` 가 붙었는지 값으로 볼 수 있기 때문이다.
    private func sizeSpec(input: RemapInput?,
                          transform: RemapTransform?,
                          inputScale: Float = 1,
                          flags: Int = RemapValueMath.InjectedDefault.flags,
                          inMin: Float = 0, inMax: Float = 1,
                          outMin: Float = 0, outMax: Float = 1) -> RemapSpec {
        RemapSpec(outputChannel: .size, operation: .remap,
                  input: input, transform: transform, octaves: 3, inputScale: inputScale,
                  flags: flags,
                  outMin: Vec3(x: outMin, y: outMin, z: outMin),
                  outMax: Vec3(x: outMax, y: outMax, z: outMax),
                  blendInStart: 0, blendInEnd: 0, blendOutStart: 1, blendOutEnd: 1,
                  inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1,
                  inMin: Vec3(x: inMin, y: inMin, z: inMin),
                  inMax: Vec3(x: inMax, y: inMax, z: inMax))
    }

    /// `(수명비율 n, 표시 size)` 표본을 모은다.
    private func samples(_ spec: RemapSpec, steps: Int = 60, dt: Float = 0.05,
                         lifetime: Float = 4) -> [(n: Float, size: Float)] {
        var sim = ParticleSimulator(def: defWith(spec, lifetime: lifetime), seed: 0x5EED)
        var out: [(Float, Float)] = []
        for _ in 0..<steps {
            guard let p = sim.step(dt).first else { continue }
            out.append((p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1, p.size))
        }
        return out
    }

    /// 두 스펙이 표시 size 를 **한 스텝도** 다르게 내지 않는지.
    private func sizesAreIdentical(_ a: RemapSpec, _ b: RemapSpec,
                                   steps: Int = 60, dt: Float = 0.05) -> Bool {
        let sa = samples(a, steps: steps, dt: dt), sb = samples(b, steps: steps, dt: dt)
        guard sa.count == sb.count, !sa.isEmpty else { return false }
        return zip(sa, sb).allSatisfy { $0.size.bitPattern == $1.size.bitPattern }
    }

    // MARK: - ① 파스: `flags` 는 부재 기본 int 1 이고 `asInt` 직독이다

    private func parsedRemapSpec(_ entry: [String: Any]) -> RemapSpec? {
        var e = entry
        e["name"] = "remapvalue"
        let json: [String: Any] = [
            "emitter": [["name": "boxrandom", "rate": 10]],
            "renderer": [["name": "sprite"]],
            "operator": [e],
        ]
        let def = ParticleSystemDef.parse(json, material: nil)
        for op in def.operators { if case let .remapValueEx(s) = op { return s } }
        return nil
    }

    /// 부재 기본 = **int 1**. 주입기 `0x1401bfbb0` 의 키 목록에 `flags` 가 없고, 꼬리에서
    /// 공유 주입기로 `jmp 0x1401d8040`(@`0x1401c001a`; 짝 @`0x1401bc91a`)한다. 이미지 전체에서
    /// 그 함수로 오는 `call`/`jmp` 는 그 둘뿐이고, 함수는 `find("flags")`(`0x1401d8057`)가
    /// 없을 때만 태그 1(int, `0x1401d8071`)에 값 1(`0x1401d809d`)을 심는다.
    func testFlagsAbsentInjectsIntOne() throws {
        let s = try XCTUnwrap(parsedRemapSpec(["output": "color", "operation": "remap"]))
        XCTAssertEqual(s.flags, 1)
        XCTAssertEqual(s.flags, RemapValueMath.InjectedDefault.flags)
    }

    /// 명시값은 그대로. 동봉 자산이 실제로 쓰는 값은 `0`(thunderbolt)과 `3`(rain fbmnoise)뿐이다.
    func testFlagsExplicitValuesSurvive() throws {
        for v in [0, 1, 2, 3, 7] {
            let s = try XCTUnwrap(parsedRemapSpec(["output": "color", "operation": "remap", "flags": v]))
            XCTAssertEqual(s.flags, v, "flags:\(v)")
        }
    }

    /// **불리언은 숫자다**(브리프 함정 18). 리더는 `operator[]`(`0x140087640` @`0x1401ce829`) 뒤의
    /// `asUInt`(`0x140085f70`) **직독**이고 `isNumeric`(`0x140088880`) 게이트가 앞에 **없다** —
    /// `asInt` 는 태그 5 를 `cmp byte [rcx],al; setne al`(`0x140085f95`)로 1/0 을 낸다.
    /// 그 경로를 재현하려면 **반드시 `JSONSerialization` 을 거쳐야 한다**(순수 Swift `Bool` 은
    /// `NSNumber` 브리지가 없다 — `JSONNumerics.isJSONNumeric` 주석의 같은 함정).
    func testFlagsAcceptsJSONBooleanAsOneOrZero() throws {
        func parseFromJSONText(_ flagsLiteral: String) throws -> RemapSpec {
            let text = """
            {"emitter":[{"name":"boxrandom","rate":10}],
             "renderer":[{"name":"sprite"}],
             "operator":[{"name":"remapvalue","output":"color","operation":"remap","flags":\(flagsLiteral)}]}
            """
            let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
            let dict = try XCTUnwrap(obj as? [String: Any])
            let def = ParticleSystemDef.parse(dict, material: nil)
            for op in def.operators { if case let .remapValueEx(s) = op { return s } }
            throw XCTSkip("remapvalue 가 Ex 경로로 안 갔다")
        }
        XCTAssertEqual(try parseFromJSONText("true").flags, 1, "asInt 는 태그 5 를 1 로 받는다")
        XCTAssertEqual(try parseFromJSONText("false").flags, 0)
        XCTAssertEqual(try parseFromJSONText("3").flags, 3)
    }

    /// 문자열은 **부재가 아니다** — 주입기는 `find` 로 노드를 찾으므로 기본값 1 로 승격되지 않는다.
    /// 실물 `asInt` 는 태그 4 에서 abort 하는데(문자열 `0x140478868`) Waple 은 죽을 수 없어
    /// 파티클 규약(`strictInt`, 문자열 거부) 그대로 **0** 으로 떨어진다. 도달 0건.
    func testFlagsStringIsNotPromotedToTheInjectedDefault() throws {
        let s = try XCTUnwrap(parsedRemapSpec(["output": "color", "operation": "remap", "flags": "3"]))
        XCTAssertEqual(s.flags, 0, "키가 있으면 주입 대상이 아니다 — 1 로 승격되면 안 된다")
    }

    // MARK: - ② `transformfunction: none` 은 `transforminputscale` 을 곱하지 않는다 (D1)

    /// `dec`+`cmp eax,5`+`ja`(`0x140245137`–`0x14024513c`)가 0(none)과 센티넬 ≥7 을
    /// `0x140245928` 로 보내고, 그 자리는 `movaps xmm12,[1.0]` 한 줄 뒤 곧장 출력 매핑
    /// (`0x140245779`)으로 뛴다 — `xmm7`(=t)을 건드리지 않으므로 **스케일이 곱해질 자리가 없다**.
    ///
    /// 종전 Waple 은 정규화 직후에 `* spec.inputScale` 을 걸었다. 그래서 `inputScale` 을 바꾸면
    /// `none` 램프의 기울기가 바뀌었다 — 아래는 **바뀌지 않아야 한다**를 잠근다.
    func testNoneTransformIgnoresInputScaleThroughTheSimulator() {
        let a = sizeSpec(input: .lifetimeFraction, transform: nil, inputScale: 1)
        for s in [Float(2), 6, 10, 0.25] {
            let b = sizeSpec(input: .lifetimeFraction, transform: nil, inputScale: s)
            XCTAssertTrue(sizesAreIdentical(a, b), "none 이 transforminputscale=\(s) 를 먹었다")
        }
    }

    /// 같은 사실의 값 판 — 동봉 프리뷰 씬(`inputrangemin:150`/`inputrangemax:200`,
    /// `transforminputscale` 부재 → 주입 기본 **2.0**)의 중점.
    /// 실물은 `raw=175` 에서 정확히 0.5, 종전 Waple 은 `0.5·2=1` 로 이미 포화였다.
    func testNoneTransformRampMidpointIsHalfNotSaturated() {
        let spec = sizeSpec(input: .lifetimeFraction, transform: nil,
                            inputScale: RemapValueMath.InjectedDefault.transformInputScale,
                            inMin: 0, inMax: 1)
        for (n, size) in samples(spec) {
            XCTAssertEqual(size, RemapValueMath.clamp01(n), accuracy: 1e-6,
                           "none 은 v = clamp01(t) 그대로여야 한다(n=\(n))")
        }
    }

    // MARK: - ③ sine 주기는 `t` 기준 `2/s` 다 (D2)

    /// `mulps xmm7, xmm9`(`0x140245164`)의 `xmm9` 는 `transforminputscale · π` 다 —
    /// `movups xmm8,[r14+0x100]`(`0x14024497e`) 뒤 `mulps xmm9,[0x1404836d0]`(`0x14024498e`),
    /// 그 상수가 `3.14159274f` 다. 이어 `subps xmm7,[0x1404836c0]`(`0x140245168`, `1.5707964f`).
    /// 곧 `sin(π·s·t − π/2)` = `−cos(π·s·t)` 이고 마지막 `mulps/addps xmm15`(0.5,
    /// `0x140245245`/`0x140245249`)가 `[0,1]` 로 접는다. **`2π` 가 아니다.**
    func testSineWiringUsesPiNotTwoPi() {
        let spec = sizeSpec(input: .lifetimeFraction, transform: .sine, inputScale: 6, flags: 0)
        for (n, size) in samples(spec, steps: 70, dt: 0.05) {
            XCTAssertEqual(size, RemapValueMath.sine(n, inputScale: 6), accuracy: 1e-5,
                           "n=\(n)")
            // 종전 식(2π·frac(s·t))과 실제로 갈리는지 — 같은 값이면 이 테스트가 무의미하다.
            let old = 0.5 - 0.5 * cosf(2 * .pi * (6 * n - (6 * n).rounded(.down)))
            if abs(size - old) > 1e-3 { return }
        }
        XCTFail("종전 2π 식과 한 표본도 안 갈렸다 — 표본이 주기를 못 덮은 것이다")
    }

    /// 주기를 **개수**로 못박는다: 수명 `[0,1]` 에 봉우리가 `s/2` 개다(s=6 → 3개).
    /// 종전 식이면 6개가 나온다.
    func testSineHasThreePeaksOverTheLifetimeAtScaleSix() {
        let spec = sizeSpec(input: .lifetimeFraction, transform: .sine, inputScale: 6, flags: 0)
        let s = samples(spec, steps: 370, dt: 0.01, lifetime: 4)
        var upward = 0
        for i in 1..<s.count where s[i - 1].size < 0.5 && s[i].size >= 0.5 { upward += 1 }
        XCTAssertEqual(upward, 3, "s=6 이면 주기가 2/6 이라 상향 교차 3회 — 종전 식은 6회다")
    }

    // MARK: - ④ 두 클램프는 **서로 다른 비트**다 (D3)

    /// 실측: bit0 은 `and r9b,1`(`0x1402449a0`) → `test r9b,r9b`(`0x140245105`) →
    /// `minps` 1.0(`0x14024510a`)·`maxps` 0(`0x140245117`) — **정규화 직후의 t**.
    /// bit1 은 `shr ecx,1`(`0x140244a21`) + `and cl,1`(`0x140244a2a`) →
    /// `test cl,cl`(`0x140245791`) → `minps` 1.0(`0x140245799`)·`maxps` 0(`0x1402457a0`) —
    /// **출력 매핑 직후**. 두 자리 사이에 파형이 있다.
    ///
    /// 갈라 보이려고 조건을 둘로 나눈다:
    ///  · 배치 A — `t` 만 범위를 벗어난다(`inputrange` 0..0.5 → `t = 2n ∈ [0,2]`,
    ///    `outputrange` 0..0.5 → `out = 0.5·t ∈ [0,1]` 이라 **출력은 절대 범위를 안 벗어난다**).
    ///    → **bit0 만** 값을 바꾼다. flags 0≡2, 1≡3.
    ///  · 배치 B — `t` 는 범위 안이고 **출력**만 벗어난다(`inputrange` 0..1,
    ///    `outputrange` −1..3). → **bit1 만** 값을 바꾼다. flags 0≡1, 2≡3.
    /// 한 비트가 다른 비트의 일을 하면 두 배치 중 하나가 반드시 깨진다.
    func testTheTwoClampBitsAreOrthogonal() {
        func specA(_ f: Int) -> RemapSpec {
            sizeSpec(input: .lifetimeFraction, transform: nil, flags: f,
                     inMin: 0, inMax: 0.5, outMin: 0, outMax: 0.5)
        }
        func specB(_ f: Int) -> RemapSpec {
            sizeSpec(input: .lifetimeFraction, transform: nil, flags: f,
                     inMin: 0, inMax: 1, outMin: -1, outMax: 3)
        }
        // A: bit0 만 산다.
        XCTAssertTrue(sizesAreIdentical(specA(0), specA(2)), "A 에서 bit1 이 값을 바꿨다")
        XCTAssertTrue(sizesAreIdentical(specA(1), specA(3)), "A 에서 bit1 이 값을 바꿨다")
        XCTAssertFalse(sizesAreIdentical(specA(0), specA(1)), "A 에서 bit0 이 아무 일도 안 했다")
        // B: bit1 만 산다.
        XCTAssertTrue(sizesAreIdentical(specB(0), specB(1)), "B 에서 bit0 이 값을 바꿨다")
        XCTAssertTrue(sizesAreIdentical(specB(2), specB(3)), "B 에서 bit0 이 값을 바꿨다")
        XCTAssertFalse(sizesAreIdentical(specB(0), specB(2)), "B 에서 bit1 이 아무 일도 안 했다")
    }

    /// 값으로도 한 번 — 배치 B 는 `out = −1 + 4n` 이고 bit1 이 그것을 `[0,1]` 로 접는다.
    func testBitOneClampsTheMappedOutputComponentwise() {
        let raw = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 0,
                           inMin: 0, inMax: 1, outMin: -1, outMax: 3)
        let clamped = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 2,
                               inMin: 0, inMax: 1, outMin: -1, outMax: 3)
        for (n, size) in samples(raw) {
            XCTAssertEqual(size, -1 + 4 * n, accuracy: 1e-5, "flags:0 은 안 자른다(n=\(n))")
        }
        for (n, size) in samples(clamped) {
            XCTAssertEqual(size, RemapValueMath.clamp01(-1 + 4 * n), accuracy: 1e-5, "n=\(n)")
        }
    }

    /// `bit2` 이상은 **죽어 있다** — 오퍼레이터 VM 전체(`0x14023fbc0`–`0x14024be38`)에서
    /// `[r14+0x2c]` 를 읽는 자리는 넷뿐이고(`0x140244986`·`0x140244996` opid 19 /
    /// `0x140246fc9`·`0x140246fd9` opid 39) 그 넷이 뽑는 것은 bit0·bit1 뿐이다.
    func testHigherFlagBitsAreDead() {
        let base = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 3,
                            inMin: 0, inMax: 0.5, outMin: -1, outMax: 3)
        for extra in [4, 8, 0x7F_FF_FF_F8] {
            let withNoise = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 3 | extra,
                                     inMin: 0, inMax: 0.5, outMin: -1, outMax: 3)
            XCTAssertTrue(sizesAreIdentical(base, withNoise), "상위 비트 \(extra) 가 살아 있다")
        }
    }

    // MARK: - ⑤ `input` 부재의 bit0 카브아웃 (의도적 이탈)

    /// 실물 `input` 부재 기본은 `lifetimefraction`(주입기 `0x1401bfbdf`)이라 raw ∈ [0,1] 이고
    /// bit0 이 무해하다. Waple 은 종전 노이즈 경로 비트동일 때문에 `input: nil` 에
    /// **유계가 아닌** 레거시 클록((remapPhase+age)·0.1)을 넣으므로, 거기에 bit0 을 걸면
    /// 파형이 얼어붙는다. 그래서 `input == nil` 에서는 걸지 않는다 — 그 규약을 잠근다.
    func testLegacyClockInputIsNotGatedByBitZero() {
        let off = sizeSpec(input: nil, transform: .simplexnoise, inputScale: 10, flags: 0)
        let on = sizeSpec(input: nil, transform: .simplexnoise, inputScale: 10, flags: 1)
        XCTAssertTrue(sizesAreIdentical(off, on),
                      "input 부재(레거시 클록)에 bit0 을 걸면 동봉 rain 6건이 얼어붙는다")
    }

    /// 반대쪽 대조 — `input` 이 실물 신호면 bit0 이 **실제로** 산다.
    /// (이게 없으면 위 테스트가 "bit0 을 아예 안 건다" 로도 통과한다.)
    func testRealInputSignalIsGatedByBitZero() {
        let off = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 0, inMin: 0, inMax: 0.5)
        let on = sizeSpec(input: .lifetimeFraction, transform: nil, flags: 1, inMin: 0, inMax: 0.5)
        XCTAssertFalse(sizesAreIdentical(off, on), "실물 신호에서는 bit0 이 살아야 한다")
    }

    // MARK: - ⑥ 동봉 자산 도달표 (범위 라벨: 동봉 `WEAssets` 트리)

    private static func bundledAssetsRoot() -> URL? {
        bundledWEAssetsRoot()
    }

    private func parsedDef(_ rel: String, root: URL) -> ParticleSystemDef? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent(rel)),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return nil }
        return ParticleSystemDef.parse(j, material: nil)
    }

    /// 동봉 `operator[].remapvalue` **12건 / 8파일**의 `flags` 실측 — 그리고 그중 몇 건이
    /// 실제로 `remapEval` 까지 **닿는지**. 닿지 않는 3건(레거시 `.remapValue(.speed)` 경로)이
    /// 이 라운드의 **[미해결]** 이고, 넘길 패치안은 `docs/re/remap-operation.md` §11.4 다.
    func testBundledFlagsReachTable() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        // (파일, 기대 Ex flags 목록, 기대 레거시 remapValue 건수)
        let table: [(String, [Int], Int)] = [
            ("scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json", [1], 0),
            ("presets/lightning/particles/presets/thunderbolt.json", [0], 0),
            ("presets/lightning/previewthunderbolt/particles/presets/thunderbolt.json", [0], 0),
            // simplexnoise/velocity 는 `operation` 명시라 Ex, fbmnoise/speed 는 확장 키가 없어 레거시.
            ("presets/rain/particles/presets/rain_screen.json", [1], 1),
            ("presets/rain/particles/presets/rain_screen_4k.json", [1], 1),
            ("presets/rain/previewrainscreen/particles/presets/rain_screen.json", [1], 1),
            ("presets/rain/particles/presets/rain_screen_fast.json", [1], 0),
            ("presets/rain/particles/presets/rain_screen_fast_4k.json", [1], 0),
            ("presets/rain/previewrainscreen/particles/presets/rain_screen_fast.json", [1], 0),
        ]
        var exTotal = 0, legacyTotal = 0
        for (rel, exFlags, legacyCount) in table {
            let def = try XCTUnwrap(parsedDef(rel, root: root), "파스 실패: \(rel)")
            var ex: [Int] = [], legacy = 0
            for op in def.operators {
                if case let .remapValueEx(s) = op { ex.append(s.flags) }
                if case .remapValue = op { legacy += 1 }
            }
            XCTAssertEqual(ex, exFlags, "Ex flags 가 다르다: \(rel)")
            XCTAssertEqual(legacy, legacyCount, "레거시 건수가 다르다: \(rel)")
            exTotal += ex.count; legacyTotal += legacy
        }
        XCTAssertEqual(exTotal + legacyTotal, 12, "동봉 remapvalue all 12")
        XCTAssertEqual(legacyTotal, 3, "`flags:3` 3건이 아직 레거시 경로다 — [미해결]")
    }

    /// `flags:3` 을 쓰는 3건이 어떤 것인지 **JSON 쪽에서도** 못박는다 — 파스가 그 키를 잃으면
    /// 위 표만으로는 "원래 flags 가 없었다" 와 구분이 안 된다.
    func testBundledFlagsThreeIsOnTheSpeedEntries() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot())
        var seen: [String: Int] = [:]
        for rel in ["presets/rain/particles/presets/rain_screen.json",
                    "presets/rain/particles/presets/rain_screen_4k.json",
                    "presets/rain/previewrainscreen/particles/presets/rain_screen.json"] {
            let d = try Data(contentsOf: root.appendingPathComponent(rel))
            let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
            for e in (j["operator"] as? [Any] ?? []) {
                guard let o = e as? [String: Any], o["name"] as? String == "remapvalue",
                      let f = o["flags"] as? Int else { continue }
                seen["\(o["output"] as? String ?? "?")/\(f)", default: 0] += 1
            }
        }
        XCTAssertEqual(seen, ["speed/3": 3], "flags:3 은 speed 3건에만 있다")
    }
}
