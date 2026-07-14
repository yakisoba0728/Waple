# WE Particle Random Initializer Exponent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse and apply the optional particle `exponent` distribution curve for the six random initializer families that currently ignore it, without changing existing RNG topology or omitted-exponent output.

**Architecture:** Extend the six `Initializer` payloads with a source-compatible default exponent, pass the parsed value through `ParticleSystemDef`, and centralize the existing alpha-style `pow(raw, exponent)` behavior in private `ParticleSimulator` helpers. Preserve one shared color factor, independent vector-component factors, endpoint order, and RNG draw counts.

**Tech Stack:** Swift 6, SwiftPM, XCTest, WapleCore `ParticleSystemDef`/`ParticleSimulator`/`SplitMix64`.

## Global Constraints

- Support exactly `lifetimeRandom`, `sizeRandom`, `colorRandom`, `velocityRandom`, `rotationRandom`, and `angularVelocityRandom`; `alphaRandom` behavior is preserved and `turbulentVelocityRandom` is out of scope.
- Apply `pow(raw, max(0.0001, exponent))` to the uniform interpolation factor `t`, then compute `min + (max - min) * t`.
- Missing, nonnumeric, or nonfinite exponent falls back to `1`; `exponent == 1` bypasses `powf` to preserve existing arithmetic.
- Preserve endpoint order, including descending ranges, and keep rotation values in radians/radians per second.
- **[보존/추측]** `colorRandom` uses one shared factor; velocity/rotation/angular velocity use three independent component factors. Only later WE A/B evidence may revisit color.
- Preserve RNG draw counts even when min equals max: lifetime/size/color/alpha consume one each; velocity/rotation/angular velocity consume three each.
- Do not modify `SplitMix64`, renderers, operators, corpus baselines, or `.vscode/launch.json`.
- Do not run the full Swift test suite or render corpus. Run only the four exponent regression tests plus `ParticleSystemTests` and `ParticleSimulatorTests`.
- Per user instruction, do not perform task-by-task code reviews; perform one whole-branch final review after all implementation and focused verification are complete.

---

### Task 1: TDD parser-to-simulator exponent support

**Files:**
- Modify: `Tests/WapleCoreTests/ParticleSystemTests.swift:29-48`
- Modify: `Sources/WapleCore/ParticleSystem.swift:28-36,217-235`
- Modify: `Sources/WapleCore/ParticleSimulator.swift:405-426`
- Test: `Tests/WapleCoreTests/ParticleSystemTests.swift`
- Regression test: `Tests/WapleCoreTests/ParticleSimulatorTests.swift`

**Interfaces:**
- Consumes: `ParticleSystemDef.parse(_:material:)`, `ParticleSimulator.init(def:seed:)`, `ParticleSimulator.step(_:)`, `SplitMix64.nextFloat()`.
- Produces: six exponent-bearing `Initializer` cases, parser propagation with default `1`, and private `ParticleSimulator.randomFactor(exponent:)` / `randomRange(_:_:exponent:)` helpers.

- [ ] **Step 1: Add black-box seeded fixture and the two runtime tests**

Insert after `testRotationInitializersPreserveRadiansEndToEnd()` in `Tests/WapleCoreTests/ParticleSystemTests.swift`:

```swift
    private func randomInitializerParticle(exponent: Float?) throws -> Particle {
        let exp = exponent.map { ",\"exponent\":\($0)" } ?? ""
        let source = """
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
         "initializer":[
           {"name":"lifetimerandom","min":1,"max":2\(exp)},
           {"name":"sizerandom","min":0,"max":1\(exp)},
           {"name":"colorrandom","min":"0 0 0","max":"255 255 255"\(exp)},
           {"name":"alpharandom","min":0,"max":1\(exp)},
           {"name":"velocityrandom","min":"0 0 0","max":"1 1 1"\(exp)},
           {"name":"rotationrandom","min":"0 0 0","max":"1 1 1"\(exp)},
           {"name":"angularvelocityrandom","min":"0 0 0","max":"1 1 1"\(exp)}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        var simulator = ParticleSimulator(def: def, seed: 7)
        return try XCTUnwrap(simulator.step(0).first)
    }

    func testRandomInitializerExponentDefaultsToLinearSampling() throws {
        let p = try randomInitializerParticle(exponent: nil)

        XCTAssertEqual(p.lifetime, 1.5829303, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.45244187, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.46795297, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.32807672, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.13425827, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.41314137, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.10355991, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.95987403, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.91801953, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.87133175, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.86400765, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.54828739, accuracy: 1e-6)
    }

    func testRandomInitializerExponentCurvesSeededSamplingAndPreservesAlpha() throws {
        let p = try randomInitializerParticle(exponent: 2)

        XCTAssertEqual(p.lifetime, 1.3398077, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.20470364, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.21897998, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.10763434, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.01802528, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.17068580, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.01072466, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.92135817, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.84275985, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.75921905, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.74650919, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.30061907, accuracy: 1e-6)
    }
```

The zero-width box intentionally still consumes RNG draws 1–3. Initializers consume draws 4–16 in the listed order. Do not optimize away zero-width draws or fixed ranges.

- [ ] **Step 2: Verify omitted exponent is already a passing preservation baseline**

Run:

```bash
swift test --filter 'ParticleSystemTests/testRandomInitializerExponentDefaultsToLinearSampling'
```

Expected: 1 test executed, 0 failures. This is the pre-change compatibility baseline.

- [ ] **Step 3: Verify explicit exponent 2 is RED only for the six missing families**

Run:

```bash
swift test --filter 'ParticleSystemTests/testRandomInitializerExponentCurvesSeededSamplingAndPreservesAlpha'
```

Expected: exit 1. Lifetime, size, three color channels, three velocity components, three rotation components, and three angular-velocity components report linear-versus-squared mismatches. The alpha assertion already matches `0.21897998`, proving its existing curve remains the control.

- [ ] **Step 4: Commit the RED/preservation tests separately**

```bash
git add Tests/WapleCoreTests/ParticleSystemTests.swift
git diff --cached --check
git commit -m "테스트(particle): random initializer exponent 오라클 추가"
```

Expected: exactly one test file is committed. `.vscode/launch.json` is not staged.

- [ ] **Step 5: Extend the six initializer payloads with default exponent 1**

Replace the first eight cases in `Initializer` in `Sources/WapleCore/ParticleSystem.swift` with:

```swift
public enum Initializer: Equatable {
    case lifetimeRandom(min: Float, max: Float, exponent: Float = 1)
    case sizeRandom(min: Float, max: Float, exponent: Float = 1)
    /// 0..255. [보존/추측] 한 t 로 min↔max 색 라인을 보간; WE RGB 축별 draw 반증 시 color만 재검토.
    case colorRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case alphaRandom(min: Float, max: Float, exponent: Float)
    /// [보존/추측] 방향/회전 스프레드 보존을 위해 성분별 독립 t를 사용한다.
    case velocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case rotationRandom(min: Vec3, max: Vec3, exponent: Float = 1)          // radians
    case angularVelocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)   // radians/s
    case turbulentVelocityRandom(speedMin: Float, speedMax: Float, scale: Float, offset: Float)
```

Leave `colorList` and `mapSequence` unchanged.

- [ ] **Step 6: Parse exponent for all seven cases without changing existing endpoint defaults**

Replace the random initializer parser branches at `Sources/WapleCore/ParticleSystem.swift:220-235` with:

```swift
            case "lifetimerandom":
                inits.append(.lifetimeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "sizerandom":
                inits.append(.sizeRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                         exponent: pexponent(i["exponent"]) ?? 1))
            case "colorrandom":
                inits.append(.colorRandom(min: pvec3(i["min"]) ?? Vec3(x: 255, y: 255, z: 255),
                                          max: pvec3(i["max"]) ?? Vec3(x: 255, y: 255, z: 255),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "alpharandom":
                inits.append(.alphaRandom(min: pfloat(i["min"]) ?? 1, max: pfloat(i["max"]) ?? 1,
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "velocityrandom":
                inits.append(.velocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "rotationrandom":
                inits.append(.rotationRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "angularvelocityrandom":
                inits.append(.angularVelocityRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                    max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                    exponent: pexponent(i["exponent"]) ?? 1))
```

Add an exponent-specific scalar helper next to `pfloat` so JSON booleans do not bridge to `0`/`1` as numbers:

```swift
private func pexponent(_ v: Any?) -> Float? {
    if let number = v as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    return pfloat(v)
}
```

- [ ] **Step 7: Centralize biased factors and apply them without changing draw topology**

Insert immediately before `apply(_:to:)` in `Sources/WapleCore/ParticleSimulator.swift`:

```swift
    /// Particle initializer 분포 성형. exponent==1은 종전 raw 산술과 RNG 시퀀스를 보존한다.
    private mutating func randomFactor(exponent: Float) -> Float {
        let raw = rng.nextFloat()
        return exponent == 1 ? raw : powf(raw, max(0.0001, exponent))
    }

    private mutating func randomRange(_ min: Float, _ max: Float, exponent: Float) -> Float {
        min + (max - min) * randomFactor(exponent: exponent)
    }
```

Then replace the seven random cases at the start of `apply(_:to:)` with:

```swift
        case let .lifetimeRandom(mn, mx, exp):
            p.lifetime = max(0.0001, randomRange(mn, mx, exponent: exp))
        case let .sizeRandom(mn, mx, exp):
            p.initialSize = randomRange(mn, mx, exponent: exp); p.size = p.initialSize
        case let .colorRandom(mn, mx, exp):
            // [보존/추측] 공유 t 로 min↔max 색 라인을 유지. WE RGB 박스형 분산이 실측되면 color만 A/B 재검토.
            let t = randomFactor(exponent: exp)
            let c = SIMD3(mn.x + (mx.x - mn.x) * t,
                          mn.y + (mx.y - mn.y) * t,
                          mn.z + (mx.z - mn.z) * t) / 255
            p.initialColor = c; p.color = c
        case let .alphaRandom(mn, mx, exp):
            let f = randomFactor(exponent: exp)
            p.initialAlpha = mn + (mx - mn) * f; p.alpha = p.initialAlpha
        case let .velocityRandom(mn, mx, exp):
            // [보존/추측] vector 스프레드와 기존 draw 수를 보존하는 성분별 독립 t.
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            p.vel = SIMD3(x, y, z)
        case let .rotationRandom(mn, mx, exp):
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            p.rotation = SIMD3(x, y, z)
        case let .angularVelocityRandom(mn, mx, exp):
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            p.angularVel = SIMD3(x, y, z)
```

Keep `turbulentVelocityRandom` and all later cases unchanged. Do not skip any helper call when endpoints are equal.

- [ ] **Step 8: Verify the RED test turns GREEN and the default test stays GREEN**

Run both commands:

```bash
swift test --filter 'ParticleSystemTests/testRandomInitializerExponentCurvesSeededSamplingAndPreservesAlpha'
swift test --filter 'ParticleSystemTests/testRandomInitializerExponentDefaultsToLinearSampling'
```

Expected: each command executes 1 test with 0 failures.

- [ ] **Step 9: Run only the two affected unit-test classes**

Run:

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
```

Expected after the final review fix wave: `ParticleSystemTests` executes 18 tests and `ParticleSimulatorTests` executes 23 tests; 41 total, 0 failures. Do not run any broader suite or corpus command.

- [ ] **Step 10: Verify boundaries and commit production changes**

Run:

```bash
git diff --check
git status --short
git diff -- Sources/WapleCore/ParticleSystem.swift Sources/WapleCore/ParticleSimulator.swift
```

Expected before staging: only the two production files are modified after the separate test commit; `.vscode/launch.json` remains the user's unrelated unstaged change in the main checkout and is absent in the isolated worktree.

Commit only production files:

```bash
git add Sources/WapleCore/ParticleSystem.swift Sources/WapleCore/ParticleSimulator.swift
git diff --cached --check
git commit -m "수정(particle): random initializer exponent 분포 적용"
```

Expected: exactly the two production files are committed. The test and production commits remain separate.

---

## Final Review and Verification

After Task 1 is fully implemented, perform exactly one whole-branch code review covering the design, tests, parser model, sampling helpers, RNG topology, comments, and compatibility constraints. Fix all Critical/Important findings in one fix wave, then rerun only the affected tests.

The final review fix wave adds two compact `ParticleSystemTests`: one proves JSON boolean/string/nonfinite exponent values fall back to `1` for all seven families, and one proves a fixed-width initializer still consumes its draw before a seeded sentinel.

Before merging, independently rerun:

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
```

Expected: 41 total tests, 0 failures. Do not run the full suite or corpus.
