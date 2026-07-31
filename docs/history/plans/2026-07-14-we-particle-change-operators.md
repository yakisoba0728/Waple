# WE Particle Change Operators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sizechange`, `colorchange`, and `alphachange` match Wallpaper Engine's normalized-lifetime timing, native defaults, and authored-order multiplicative composition.

**Architecture:** Extend the size/color operator payloads so all three change families carry start/end intervals, then parse the native `0/1/1/0` defaults. Replace the simulator's three first-only caches with authored-order arrays and evaluate every factor from `age/lifetime` through one signed-span progress helper on each display snapshot.

**Tech Stack:** Swift 5.9 package manifest, SwiftPM, XCTest, WapleCore `ParticleSystemDef` and `ParticleSimulator`.

## Global Constraints

- The authoritative behavior is jointly established by Wallpaper Engine's operator documentation and the WE 2.8 `wallpaper64.exe` parser/evaluator.
- For all three operators, use `n = age / lifetime`; clamp only the computed progress, never `startTime` or `endTime`.
- Use `span = endTime - startTime`; `span == 0` is a step at `startTime`, while a negative span performs the native end-value-to-start-value reverse interpolation.
- Preserve `endTime > 1` as authored so the change can remain incomplete at particle death.
- Missing fields default to `startTime=0`, `endTime=1`, `startValue=1`, and `endValue=0`; vector defaults are component-wise equivalents.
- Preserve every same-type operator in JSON order and multiply its scalar/RGB factor into the current display value.
- Do not add a clamp to individual change factors. Preserve the existing terminal alpha `[0,1]` clamp because it is shared by alphaRandom, alphaFade, and oscillateAlpha and is outside this task.
- Do not modify other first-wins operators, RNG, emitters, initializers, renderers, shaders, corpus baselines, or `.vscode/launch.json`.
- Do not run the full Swift test suite, render corpus, or GT snapshots. Run only `ParticleSystemTests`, `ParticleSimulatorTests`, and `ParticleStageATests`.
- Per user instruction, perform no task-by-task code review. Perform one whole-branch final review after implementation and focused verification.
- The four source analysis documents and their COMPLETE mirror live outside the Waple Git repository; update them with `apply_patch`, but do not claim they are part of a Waple commit.

---

### Task 1: Operator payloads, end-time parsing, and native defaults

**Files:**
- Modify: `Tests/WapleCoreTests/ParticleSystemTests.swift`
- Modify: `Sources/WapleCore/ParticleSystem.swift:59-82,275-280,325-328`
- Modify: `Sources/WapleCore/ParticleSimulator.swift:111-112` (enum arity compatibility only; Task 2 consumes `endTime`)

**Interfaces:**
- Consumes: `ParticleSystemDef.parse(_:material:)`, `ParticleOperator`, existing `pfloat(_:)` and `pvec3(_:)` finite-number parsing.
- Produces: `.sizeChange(startTime:startValue:endValue:endTime:)`, `.colorChange(startTime:startValue:endValue:endTime:)`, native defaults shared with `.alphaChange`, and compiling four-value simulator pattern matches that intentionally ignore `endTime` until Task 2.

- [ ] **Step 1: Add explicit-interval and native-default parser tests**

Insert after `testRotationInitializersPreserveRadiansEndToEnd()` in `Tests/WapleCoreTests/ParticleSystemTests.swift`:

```swift
    func testChangeOperatorsParseExplicitIntervals() {
        let def = ParticleSystemDef.parse([
            "operator": [
                ["name": "sizechange", "starttime": 0.2, "endtime": 0.6,
                 "startvalue": 0.4, "endvalue": 0.8],
                ["name": "colorchange", "starttime": 0.25, "endtime": 0.75,
                 "startvalue": "1 0.5 0.25", "endvalue": "0.2 1 0.75"],
                ["name": "alphachange", "starttime": 0.1, "endtime": 0.9,
                 "startvalue": 0.8, "endvalue": 0.3],
            ],
        ], material: nil)

        XCTAssertEqual(def.operators, [
            .sizeChange(startTime: 0.2, startValue: 0.4, endValue: 0.8, endTime: 0.6),
            .colorChange(startTime: 0.25,
                         startValue: Vec3(x: 1, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.2, y: 1, z: 0.75),
                         endTime: 0.75),
            .alphaChange(startTime: 0.1, endTime: 0.9, startValue: 0.8, endValue: 0.3),
        ])
    }

    func testChangeOperatorsUseNativeDefaults() {
        let def = ParticleSystemDef.parse([
            "operator": [
                ["name": "sizechange"],
                ["name": "colorchange"],
                ["name": "alphachange"],
            ],
        ], material: nil)

        XCTAssertEqual(def.operators, [
            .sizeChange(startTime: 0, startValue: 1, endValue: 0, endTime: 1),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0, y: 0, z: 0),
                         endTime: 1),
            .alphaChange(startTime: 0, endTime: 1, startValue: 1, endValue: 0),
        ])
    }
```

- [ ] **Step 2: Run the parser tests and confirm RED**

Run:

```bash
swift test --filter 'ParticleSystemTests/testChangeOperators'
```

Expected before production changes: compilation fails because size/color do not accept `endTime`; if the compiler reaches runtime assertions, the existing size/color end defaults and alpha start/end defaults also differ.

- [ ] **Step 3: Commit the RED parser tests**

```bash
git add Tests/WapleCoreTests/ParticleSystemTests.swift
git diff --cached --check
git commit -m "테스트(particle): change operator 파서 오라클 추가"
```

Expected: only `ParticleSystemTests.swift` is committed.

- [ ] **Step 4: Extend size/color payloads and correct the alpha comment**

Replace the three change cases in `ParticleOperator` with:

```swift
    /// 수명 비율 구간에서 factor를 보간해 현재 크기에 곱한다.
    case sizeChange(startTime: Float, startValue: Float, endValue: Float, endTime: Float = 1)
    /// 수명 비율 구간에서 RGB factor를 성분별 보간해 현재 색에 곱한다.
    case colorChange(startTime: Float, startValue: Vec3, endValue: Vec3, endTime: Float = 1)
```

Keep unrelated cases in their existing positions. Replace the `alphaChange` comment and declaration with:

```swift
    /// 수명 비율 구간에서 alpha factor를 보간해 현재 알파에 곱한다.
    case alphaChange(startTime: Float, endTime: Float, startValue: Float, endValue: Float)
```

- [ ] **Step 5: Parse all native defaults and size/color end times**

Replace the size/color parser branches with:

```swift
            case "sizechange":
                ops.append(.sizeChange(startTime: pfloat(o["starttime"]) ?? 0,
                                       startValue: pfloat(o["startvalue"]) ?? 1,
                                       endValue: pfloat(o["endvalue"]) ?? 0,
                                       endTime: pfloat(o["endtime"]) ?? 1))
            case "colorchange":
                ops.append(.colorChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        startValue: pvec3(o["startvalue"]) ?? Vec3(x: 1, y: 1, z: 1),
                                        endValue: pvec3(o["endvalue"]) ?? Vec3(x: 0, y: 0, z: 0),
                                        endTime: pfloat(o["endtime"]) ?? 1))
```

Replace the alpha parser branch with:

```swift
            case "alphachange":
                ops.append(.alphaChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        endTime: pfloat(o["endtime"]) ?? 1,
                                        startValue: pfloat(o["startvalue"]) ?? 1,
                                        endValue: pfloat(o["endvalue"]) ?? 0))
```

Do not add a new numeric parser: `pfloat` already rejects nonfinite values and preserves finite values outside `[0,1]`.

Because the associated-value arity changes immediately, replace the two simulator switch patterns with compile-only compatibility matches:

```swift
            case let .sizeChange(st, sv, ev, _): if sc == nil { sc = (st, sv, ev) }
            case let .colorChange(st, sv, ev, _): if cc == nil { cc = (st, s3(sv), s3(ev)) }
```

Task 2 replaces these temporary first-only matches with authored-order arrays and consumes the fourth value.

- [ ] **Step 6: Turn the parser tests GREEN and run the affected parser class**

Run:

```bash
swift test --filter 'ParticleSystemTests/testChangeOperators'
swift test --filter ParticleSystemTests
```

Expected: 2 targeted tests pass; the full class executes 20 tests with 0 failures.

- [ ] **Step 7: Commit the model and parser implementation**

```bash
git add Sources/WapleCore/ParticleSystem.swift Sources/WapleCore/ParticleSimulator.swift
git diff --cached --check
git commit -m "수정(particle): change operator 구간과 기본값 파싱"
```

Expected: `ParticleSystem.swift` contains the model/parser behavior and `ParticleSimulator.swift` contains only the required arity-compatibility pattern update.

---

### Task 2: Normalized timing, signed-span edges, and multiple-factor composition

**Files:**
- Modify: `Tests/WapleCoreTests/ParticleSimulatorTests.swift`
- Modify: `Tests/WapleCoreTests/ParticleStageATests.swift`
- Modify: `Sources/WapleCore/ParticleSimulator.swift:47-56,94-146,475-500,599-603`

**Interfaces:**
- Consumes: the Task 1 four-value size/color cases, `ParticleSimulator.step(_:)`, `Particle.initialSize`, `initialColor`, and `initialAlpha`.
- Produces: `sizeChanges`, `colorChanges`, and `alphaChanges` authored-order caches plus `changeProgress(_:_:_:) -> Float`.

- [ ] **Step 1: Replace the stale alpha-seconds tests with lifetime-ratio tests**

In `Tests/WapleCoreTests/ParticleStageATests.swift`, change the class description and MARK from “초 단위” to “수명 비율”. Replace the two alpha tests with:

```swift
    func testAlphaChange_lifetimeRatio_holdsAfterEnd() {
        // lifetime 10, et=0.2 → age2에서 완료. age1은 t=0.5.
        let op = ParticleOperator.alphaChange(startTime: 0, endTime: 0.2, startValue: 1, endValue: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 10, operators: [op]), seed: 12)
        let a = sim.step(1.0)
        XCTAssertEqual(a[0].alpha, 0.5, accuracy: 0.01)
        let b = sim.step(1.0)
        XCTAssertEqual(b[0].alpha, 0, accuracy: 0.01)
        let c = sim.step(1.0)
        XCTAssertEqual(c[0].alpha, 0, accuracy: 0.01)
    }

    func testAlphaChange_beforeStartHoldsStartValue() {
        let op = ParticleOperator.alphaChange(startTime: 0.2, endTime: 0.4, startValue: 0.8, endValue: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 10, operators: [op]), seed: 13)
        let a = sim.step(1.0)
        XCTAssertEqual(a[0].alpha, 0.8, accuracy: 0.01)
    }
```

In `testParse_stageAOperatorsAndBurst`, keep JSON `endtime: 2` unchanged and replace the alpha assertion with:

```swift
        XCTAssertTrue(def.operators.contains {
            // 비율 2를 원문 그대로 보존하고 누락 값은 네이티브 기본 fade-out 1→0.
            if case .alphaChange(0, 2, 1, 0) = $0 { return true }; return false
        })
```

- [ ] **Step 2: Add five simulator behavior tests**

Insert after the existing `testSizeChange()` in `Tests/WapleCoreTests/ParticleSimulatorTests.swift`:

```swift
    func testChangeIntervalsUseNormalizedLifetime() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0.2, startValue: 0.2, endValue: 0.8, endTime: 0.6),
            .colorChange(startTime: 0.2,
                         startValue: Vec3(x: 1, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.2, y: 1, z: 0.75),
                         endTime: 0.6),
            .alphaChange(startTime: 0.2, endTime: 0.6, startValue: 1, endValue: 0),
        ]
        var short = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                      lifetime: 10, operators: operators), seed: 7)
        var long = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                     lifetime: 20, operators: operators), seed: 7)

        let a = short.step(4)[0]
        let b = long.step(8)[0]
        for p in [a, b] {
            XCTAssertEqual(p.size, 2.5, accuracy: 1e-5)
            XCTAssertEqual(p.color.x, 0.6, accuracy: 1e-5)
            XCTAssertEqual(p.color.y, 0.75, accuracy: 1e-5)
            XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-5)
            XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-5)
        }
    }

    func testChangeEndTimeBeyondLifetimeRemainsIncompleteAtDeath() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0, startValue: 1, endValue: 0, endTime: 2),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0, y: 0, z: 0),
                         endTime: 2),
            .alphaChange(startTime: 0, endTime: 2, startValue: 1, endValue: 0),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 8)

        let p = sim.step(10)[0]
        XCTAssertEqual(p.size, 2.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-5)
    }

    func testChangeZeroLengthIntervalStepsAtStart() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0.5, startValue: 1, endValue: 0.2, endTime: 0.5),
            .colorChange(startTime: 0.5,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0.2, y: 0.3, z: 0.4),
                         endTime: 0.5),
            .alphaChange(startTime: 0.5, endTime: 0.5, startValue: 1, endValue: 0.25),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 9)

        let before = sim.step(4)[0]
        XCTAssertEqual(before.size, 5, accuracy: 1e-5)
        XCTAssertEqual(before.color.x, 1, accuracy: 1e-5)
        XCTAssertEqual(before.alpha, 1, accuracy: 1e-5)

        let at = sim.step(1)[0]
        XCTAssertEqual(at.size, 1, accuracy: 1e-5)
        XCTAssertEqual(at.color.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(at.color.y, 0.3, accuracy: 1e-5)
        XCTAssertEqual(at.color.z, 0.4, accuracy: 1e-5)
        XCTAssertEqual(at.alpha, 0.25, accuracy: 1e-5)
    }

    func testChangeReverseIntervalUsesSignedSpan() {
        let op = ParticleOperator.sizeChange(startTime: 0.8, startValue: 1, endValue: 0, endTime: 0.2)
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: [op]), seed: 10)

        XCTAssertEqual(sim.step(1)[0].size, 0, accuracy: 1e-5)
        XCTAssertEqual(sim.step(4)[0].size, 2.5, accuracy: 1e-5)
        XCTAssertEqual(sim.step(3)[0].size, 5, accuracy: 1e-5)
    }

    func testMultipleChangeOperatorsMultiplyAllFactors() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0, startValue: 0.5, endValue: 0.5),
            .sizeChange(startTime: 0, startValue: 0.4, endValue: 0.4),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 0.5, y: 0.8, z: 0.6),
                         endValue: Vec3(x: 0.5, y: 0.8, z: 0.6)),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 0.4, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.4, y: 0.5, z: 0.25)),
            .alphaChange(startTime: 0, endTime: 1, startValue: 0.5, endValue: 0.5),
            .alphaChange(startTime: 0, endTime: 1, startValue: 0.4, endValue: 0.4),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 11)

        let p = sim.step(0.01)[0]
        XCTAssertEqual(p.size, 1, accuracy: 1e-5)
        XCTAssertEqual(p.color.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(p.color.y, 0.4, accuracy: 1e-5)
        XCTAssertEqual(p.color.z, 0.15, accuracy: 1e-5)
        XCTAssertEqual(p.alpha, 0.2, accuracy: 1e-5)
    }
```

- [ ] **Step 3: Run the semantic tests and confirm RED**

Run:

```bash
swift test --filter 'ParticleSimulatorTests/testChange'
swift test --filter 'ParticleSimulatorTests/testMultipleChangeOperatorsMultiplyAllFactors'
swift test --filter 'ParticleStageATests/testAlphaChange'
swift test --filter 'ParticleStageATests/testParse_stageAOperatorsAndBurst'
```

Expected before simulator changes: normalized interval, end>1, zero-span, reverse-span, and multiple-factor assertions fail; the corrected alpha parser assertion may already pass from Task 1.

- [ ] **Step 4: Commit all RED semantic tests together**

```bash
git add Tests/WapleCoreTests/ParticleSimulatorTests.swift Tests/WapleCoreTests/ParticleStageATests.swift
git diff --cached --check
git commit -m "테스트(particle): change operator 시간과 다중 합성 오라클 추가"
```

- [ ] **Step 5: Replace the first-only caches with authored-order arrays**

Replace the three change cache properties with:

```swift
    private let sizeChanges: [(st: Float, et: Float, sv: Float, ev: Float)]
    private let colorChanges: [(st: Float, et: Float, sv: SIMD3<Float>, ev: SIMD3<Float>)]
    private let alphaChanges: [(st: Float, et: Float, sv: Float, ev: Float)]
```

In `ParticleSimulator.init`, replace the three optional locals with:

```swift
        var sc: [(st: Float, et: Float, sv: Float, ev: Float)] = []
        var cc: [(st: Float, et: Float, sv: SIMD3<Float>, ev: SIMD3<Float>)] = []
        var ac: [(st: Float, et: Float, sv: Float, ev: Float)] = []
```

Replace the three switch cases with:

```swift
            case let .sizeChange(st, sv, ev, et):
                sc.append((st: st, et: et, sv: sv, ev: ev))
            case let .colorChange(st, sv, ev, et):
                cc.append((st: st, et: et, sv: s3(sv), ev: s3(ev)))
            case let .alphaChange(st, et, sv, ev):
                ac.append((st: st, et: et, sv: sv, ev: ev))
```

Replace the three final cache assignments with:

```swift
        sizeChanges = sc
        colorChanges = cc
        alphaChanges = ac
```

Do not pre-multiply factors during initialization because their values vary with normalized age.

- [ ] **Step 6: Evaluate every factor from initial display state**

Replace the size/color/alpha change portions of `display(_:)` with:

```swift
        // size
        d.size = p.initialSize
        for op in sizeChanges {
            d.size *= lerp(op.sv, op.ev, changeProgress(n, op.st, op.et))
        }
        if let os = oscSizeOp {
            let osc01 = 0.5 * (1 + sin(2 * .pi * p.oscSizeFreq * p.age + p.oscSizePhase))
            d.size *= lerp(os.smin, os.smax, osc01)
        }
        // color
        d.color = p.initialColor
        for op in colorChanges {
            let t = changeProgress(n, op.st, op.et)
            d.color *= op.sv + (op.ev - op.sv) * t
        }
        // alpha
        var a = p.initialAlpha
        if let af = alphaFade { a *= fadeFactor(n, af.fin, af.fout) }
        for op in alphaChanges {
            a *= lerp(op.sv, op.ev, changeProgress(n, op.st, op.et))
        }
        if p.oscAlphaScale > 0 {
            let osc = 0.5 * (1 + sin(2 * .pi * p.oscAlphaFreq * p.age + p.oscAlphaPhase))
            a *= max(0, 1 - p.oscAlphaScale * osc)
        }
        d.alpha = max(0, min(1, a))
```

This preserves the existing cross-family order: size changes before oscillateSize, alphaFade before alpha changes, and oscillateAlpha afterward.

- [ ] **Step 7: Replace the start-to-death helper with signed-span progress**

Replace `progress(_:_:)` with:

```swift
private func changeProgress(_ n: Float, _ st: Float, _ et: Float) -> Float {
    let span = et - st
    if span == 0 { return n >= st ? 1 : 0 }
    return max(0, min(1, (n - st) / span))
}
```

Use exact zero comparison. Do not use an epsilon, `abs(span)`, endpoint sorting, or `max(0.0001, span)`, because each would change a valid short or reverse interval.

- [ ] **Step 8: Turn all semantic tests GREEN and run only the three approved classes**

Run:

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
swift test --filter ParticleStageATests
```

Expected: 20 + 28 + 11 = 59 tests, 0 failures.

- [ ] **Step 9: Commit the simulator implementation**

```bash
git add Sources/WapleCore/ParticleSimulator.swift
git diff --cached --check
git commit -m "수정(particle): change operator 네이티브 합성 적용"
```

Expected: exactly one production file is committed.

---

### Task 3: Correct the external WE analysis records

**Files:**
- Modify outside Git: `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/WE-2.8-FINAL-KR.md`
- Modify outside Git: `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/build/WE-2.8-fidelity-KR.md`
- Modify outside Git: `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/WE-2.8-TRADEOFFS-KR.md`
- Modify outside Git: `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/build/F4-particle-sim-exact.md`
- Modify outside Git: `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/WE-2.8-COMPLETE-KR.md`

**Interfaces:**
- Consumes: official documentation, native normalizers/evaluators, and Tasks 1–2 implementation semantics.
- Produces: mutually consistent FINAL, fidelity, TRADEOFFS, F4, and COMPLETE records with the erroneous seconds framing removed.

- [ ] **Step 1: Correct FINAL M4, fidelity X5, and the TRADEOFFS particle row**

Use `apply_patch` to set FINAL M4 to:

```markdown
| M4 | **파티클 exponent 소비**(6/7 initializer) + **change operator 3종 정합화** — `size/colorChange endtime` 파싱, `alphaChange` 절대초 계산 교정; `n=age/lifetime`, 계산된 진행도만 clamp하고 st/et는 무클램프(`endtime>1`=사망 시 미완성), `start==end`=step·`start>end`=역보간, 공통 기본값 st=0/et=1/sv=1/ev=0, 동일 타입 전부 JSON 순서대로 곱셈 | `ParticleSystem.swift`·`ParticleSimulator.swift` |
```

Set fidelity X5 to:

```markdown
| X5 | **파티클 change operator 3종 정합화** — `size/colorChange`의 `endtime` 파싱, `alphaChange` 절대초 계산 교정. `n=age/lifetime`; `span==0`이면 step, 아니면 `t=clamp((n−st)/span,0..1)`로 signed span을 유지한다. st/et는 무클램프(`endtime>1`=사망 시 미완성, `start>end`=역보간), 누락 기본값은 st=0/et=1/sv=1/ev=0, 동일 타입은 전부 JSON 순서대로 현재 size/RGB/alpha에 곱한다. | 공식 문서 + F4 네이티브 실행부 | `ParticleSystem.swift`·`ParticleSimulator.swift` |
```

Set the TRADEOFFS particle-accuracy row to:

```markdown
| **파티클 정확도** | 비트정확(입자 위치 동일) ↔ 시각 근사 | **RNG는 시각 근사 수용**(WE RNG 미상=비트정확 불가 확정). 단 change operator 3종은 공식 문서+네이티브 실행부로 확정: 수명 비율 시간, 기본값 st0/et1/sv1/ev0, raw st/et 보존(`end>1` 미완성·`start>end` 역보간), 동일 타입 JSON 순서 곱셈. 이 부분은 `[추측]`이 아니다. |
```

- [ ] **Step 2: Replace F4's contradictory seconds analysis with the confirmed model**

Add this correction notice near the F4 header:

```markdown
> **정정(2026-07-14):** 초판은 `endtime` 비율값과 `lifetime` 초값을 같은 단위로 비교해 세 change operator를 “절대 초”로 오판했고, 다중 합성을 `[추측]`으로 남겼다. 공식 문서와 `wallpaper64.exe` 파서·실행부 재확인 결과, 세 operator 모두 `age/lifetime`을 사용하며 기본값은 st=0/et=1/sv=1/ev=0, 동일 타입 전부를 JSON 순서대로 현재 값에 곱한다. `endtime>1`은 클램프되지 않아 사망 시 미완성으로 남는다.
```

Record the native evidence beside the correction: binary SHA-256 `40e2ce021e9352324fadb3b8f72b8ba2a7ee95b71cc571d5b9f84be75cd993b0`, scalar normalizer `0x1401bcfe0`, color normalizer `0x1401bd2a0`, size/color/alpha evaluators `0x14024033a`/`0x1402403a2`/`0x140240457`, and authored-order record loop `0x140240279–0x140240298`.

Replace the old absolute-seconds formula with:

```text
n = age / lifetime
span = endtime - starttime

if span == 0:
    t = n >= starttime ? 1 : 0
else:
    t = clamp((n - starttime) / span, 0, 1)

factor = lerp(startvalue, endvalue, t)
size      *= factor
color.rgb *= factor.rgb
alpha     *= factor
```

Rewrite F4 §B.2 so it states all of the following without retaining the old alternatives:

- Before the fix, size/color omit `endtime` and use the wrong end default `1`/white.
- Before the fix, alpha parses the interval but treats it as seconds and uses the reversed `0→1` defaults.
- All three use first-only optional caches in Waple, while native records append and multiply in authored order.
- `torch.json` uses a 20%-of-lifetime first interval; the second operator's omitted defaults mean factor `1→0.5` over normalized `0.2→1`, multiplied after the pop-in.
- Missing `endtime` is the explicit default `1`, not an optional lifetime sentinel.
- `endtime>1` remains incomplete at death, `starttime>endtime` reverse-interpolates, and equality alone is a step.

Replace F4 C.1 row 2 with:

```markdown
| 2 | `sizeChange`/`colorChange`/`alphaChange` | size/color `endTime` 파싱 + 세 타입 수명비율 진행도 + 네이티브 기본값 + first-wins를 JSON 순서 다중 곱셈으로 교정 | `ParticleSystem.swift` / `ParticleSimulator.swift` |
```

Replace the obsolete final verdict rows with:

```markdown
| change operator 3종 시간 = `age/lifetime` 수명 비율 | **확정(정정)** | 공식 문서 + 네이티브 evaluator |
| 기본값 st0/et1/sv1/ev0·동일 타입 JSON 순서 곱셈 | **확정** | 네이티브 normalizer·record 실행부 |
| 수정 전 Waple: size/color endtime 누락·alpha 절대초·잘못된 기본값·세 타입 first-wins | **확정(코드 직접)** | `ParticleSystem.swift`·`ParticleSimulator.swift` |
```

Change the reproduction-script description to:

```markdown
(3) sizechange/colorchange endtime 명시율·값 분포 조사(단위 판정 근거로는 사용하지 않음; >1은 수명 내 미완성으로 재해석)
```

When editing, remove or rewrite every remaining F4 claim that says these three operators use absolute seconds, that alpha's seconds implementation is correct, that missing endtime needs an optional lifetime sentinel, or that multiple composition remains speculative.

- [ ] **Step 3: Synchronize the derived COMPLETE mirror**

In `WE-2.8-COMPLETE-KR.md`, synchronize these embedded source blocks from their corrected originals:

- FINAL M4 at the current early roadmap block.
- fidelity X5 inside the block introduced by `> 📄 **원본 파일:** build/WE-2.8-fidelity-KR.md`.
- The full F4 block introduced by `> 📄 **원본 파일:** build/F4-particle-sim-exact.md` through the next `═══` source separator.

TRADEOFFS is not embedded in COMPLETE, so do not insert a new unrelated block there.

- [ ] **Step 4: Verify the documentation no longer contradicts itself**

Run:

```bash
rg -n '절대 초|초 단위|et<=st|endtime.*수명비율 아님|덮어쓰기 vs 누적|optional sentinel' \
  analysis/WE-2.8-FINAL-KR.md \
  analysis/build/WE-2.8-fidelity-KR.md \
  analysis/WE-2.8-TRADEOFFS-KR.md \
  analysis/build/F4-particle-sim-exact.md \
  analysis/WE-2.8-COMPLETE-KR.md
```

Run from `/Users/yakisoba/Downloads/WallpaperEngine-macOS-analysis-reference-2.8.0.42`. Expected: any remaining hits describe the corrected Waple bug or historical error explicitly; no hit asserts absolute seconds as the correct WE behavior.

Also run:

```bash
rg -n 'age/lifetime|start>end|역보간|JSON 순서.*곱' \
  analysis/WE-2.8-FINAL-KR.md \
  analysis/build/WE-2.8-fidelity-KR.md \
  analysis/WE-2.8-TRADEOFFS-KR.md \
  analysis/build/F4-particle-sim-exact.md \
  analysis/WE-2.8-COMPLETE-KR.md
```

Expected: the corrected behavior is present in each relevant source and in the COMPLETE mirror.

---

## Final Review and Focused Verification

After Tasks 1–3, perform exactly one whole-branch review against the approved design and native evidence. Review enum compatibility, parser defaults, tuple field order, source-order append behavior, per-frame recomputation from initial values, normalized timing, zero/reverse spans, `endTime > 1`, terminal alpha clamping, tests, comments, and external-document consistency.

Fix all Critical/Important findings in one fix wave. Commit code/test fixes separately from any Waple documentation amendment. The external analysis directory is not a Git repository and remains an explicitly reported external artifact.

Rerun only:

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
swift test --filter ParticleStageATests
```

Expected final result: 59 tests, 0 failures. Do not run `swift test` without a filter and do not run any render/corpus command.

Before merge, run:

```bash
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: only the planned Waple source/tests/docs are committed in the feature branch, and `.vscode/launch.json` remains solely in the user's main checkout. Merge the feature branch into `main` only after this final review and focused verification pass, then remove the worktree and feature branch.
