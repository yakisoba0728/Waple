# Waple Scene SP3b (scroll/opacity/tint effects) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add scroll, opacity, tint effects to the SP3a effect pipeline by generalizing effect uniforms (per-effect `[time]+params` float buffer) and capturing vector constantshadervalues (tint color, scroll vec).

**Architecture:** `EffectShaders` gains a generic contract — shared fullscreen vert + per-effect frag reading `constant float* P` (P[0]=time, P[1..]=params) — plus `params(for:constants:)` mapping constantshadervalues→ordered slots. `SceneEffect.constants` becomes `[String:[Float]]` (scalars+vectors). `SceneRenderer` passes the generic float buffer.

**Tech Stack:** Swift 5.9, Metal, XCTest. No new deps.

## Global Constraints
- Build on existing SP3a framework; no new targets/deps. tools 5.9, macOS 13+.
- Effect frag signature: `ef_main(EOut in, texture2d fb [[texture(0)]], texture2d mask [[texture(1)]], constant float* P [[buffer(0)]])`; `P[0]=g_Time` (seconds), `P[1..]`=effect params (documented order).
- WE-faithful (no effect-strength setting). tint = default (normal) blend only.
- Unsupported effect name → nil → skip (base only). Mask decode fail → white 1×1 fallback.
- Exact constantshadervalue keys mapped with sensible defaults; verified at the manual gate.

**전제:** main, `swift build`/`swift test` green (91 tests).

---

### Task 1: `SceneEffect.constants` → `[String:[Float]]` (벡터 지원)

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift`
- Modify: `Tests/WapleCoreTests/SceneDocumentTests.swift`

**Interfaces:**
- Produces: `SceneEffect.constants: [String: [Float]]` (scalar → [x]; "r g b" → [r,g,b])

- [ ] **Step 1: 기존 테스트 갱신(실패)**

`Tests/WapleCoreTests/SceneDocumentTests.swift` 의 `testParsesObjectEffects` 의 두 줄을 교체하고 색상 케이스 추가:
```swift
        XCTAssertEqual(eff.constants["speed"], [3.97])
        XCTAssertEqual(eff.constants["scale"], [34.66])
```
그리고 새 테스트 추가(벡터/색상):
```swift
    func testParsesVectorEffectConstants() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true},
                     "effects":[{"file":"effects/tint/effect.json",
                       "passes":[{"constantshadervalues":{"color":"1 0 0","alpha":0.5}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let eff = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(eff.name, "tint")
        XCTAssertEqual(eff.constants["color"], [1, 0, 0])
        XCTAssertEqual(eff.constants["alpha"], [0.5])
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: 컴파일 에러/실패 (`constants` 타입 불일치).

- [ ] **Step 3: 구현**

`Sources/WapleCore/SceneDocument.swift`:
(a) `SceneEffect` 의 `constants` 타입을 교체:
```swift
    public let constants: [String: [Float]]
```
(b) `parseEffects` 의 constants 수집부를 교체:
```swift
                if let cs = pass0["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs {
                        if let d = v as? Double { constants[k] = [Float(d)] }
                        else if let i = v as? Int { constants[k] = [Float(i)] }
                        else if let s = v as? String {
                            let f = s.split(separator: " ").compactMap { Float($0) }
                            if !f.isEmpty { constants[k] = f }
                        }
                    }
                }
```
그리고 선언을 `var constants: [String: [Float]] = [:]` 로.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: PASS (기존 갱신 + 신규).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m "feat: capture vector/color effect constants ([String:[Float]])"
```

---

### Task 2: `EffectShaders` 일반화 + scroll/opacity/tint

**Files:**
- Modify: `Sources/WapleRender/EffectShaders.swift` (전체 교체)
- Test: `Tests/WapleRenderTests/EffectShadersTests.swift`

**Interfaces:**
- Consumes: `SceneEffect.constants` ([String:[Float]])
- Produces: `EffectShaders.source(for:) -> String?`, `EffectShaders.params(for: String, constants: [String:[Float]]) -> [Float]?`

- [ ] **Step 1: 실패 테스트 작성**

`Tests/WapleRenderTests/EffectShadersTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class EffectShadersTests: XCTestCase {
    func testUnknownEffect() {
        XCTAssertNil(EffectShaders.source(for: "nope"))
        XCTAssertNil(EffectShaders.params(for: "nope", constants: [:]))
    }
    func testOpacityParams() {
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: ["alpha": [0.5]]), [0.5])
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: [:]), [1])  // default
    }
    func testTintParams() {
        // order: r,g,b,blendAlpha
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["color": [1, 0, 0], "alpha": [0.5]]), [1, 0, 0, 0.5])
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:]), [1, 0, 0, 1])  // default red, alpha 1
    }
    func testScrollParams() {
        // order: scaleX, scaleY, speedX, speedY
        let p = EffectShaders.params(for: "scroll", constants: ["scale": [2, 3], "speed": [0.1, 0.2]])
        XCTAssertEqual(p, [2, 3, 0.1, 0.2])
        XCTAssertEqual(EffectShaders.params(for: "scroll", constants: [:])?.count, 4)
    }
    func testWaterwavesParamsCount() {
        // order: cos(dir), sin(dir), speed, scale, strength, perspective
        let p = EffectShaders.params(for: "waterwaves", constants: ["speed": [4], "scale": [34]])
        XCTAssertEqual(p?.count, 6)
        XCTAssertEqual(p?[2], 4); XCTAssertEqual(p?[3], 34)
    }
    func testSourcesExist() {
        for n in ["waterwaves", "scroll", "opacity", "tint"] {
            XCTAssertNotNil(EffectShaders.source(for: n))
            XCTAssertTrue(EffectShaders.source(for: n)!.contains("ef_main"))
        }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter EffectShadersTests`
Expected: 컴파일 에러 (`params` 없음).

- [ ] **Step 3: 구현 (전체 교체)**

`Sources/WapleRender/EffectShaders.swift`:
```swift
import Foundation

enum EffectShaders {
    /// 효과 이름 → MSL(공유 vert ev_main + 효과 frag ef_main).
    /// frag uniform: constant float* P (P[0]=time, P[1..]=params, 효과별 순서).
    static func source(for name: String) -> String? {
        guard let frag = frags[name] else { return nil }
        return header + vert + frag
    }

    /// constantshadervalues → 효과별 파라미터 슬롯(기본값 포함). 미지원 nil.
    static func params(for name: String, constants c: [String: [Float]]) -> [Float]? {
        func f(_ k: String, _ d: Float) -> Float { c[k]?.first ?? d }
        switch name {
        case "opacity":
            return [f("alpha", 1)]
        case "tint":
            let col = c["color"] ?? [1, 0, 0]
            let r = col.count > 0 ? col[0] : 1, g = col.count > 1 ? col[1] : 0, b = col.count > 2 ? col[2] : 0
            return [r, g, b, f("alpha", 1)]
        case "scroll":
            let sc = c["scale"] ?? [1, 1]
            let sp = c["speed"] ?? c["scrollspeed"] ?? [0.05, 0]
            let sx = sc.count > 0 ? sc[0] : 1, sy = sc.count > 1 ? sc[1] : sx
            let vx = sp.count > 0 ? sp[0] : 0.05, vy = sp.count > 1 ? sp[1] : 0
            return [sx, sy, vx, vy]
        case "waterwaves":
            let a = f("direction", 0) * .pi / 180
            return [cos(a), sin(a), f("speed", 5), f("scale", 200), f("strength", 0.1), f("perspective", 0)]
        default:
            return nil
        }
    }

    private static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct EOut { float4 pos [[position]]; float2 uv; };

    """
    private static let vert = """
    vertex EOut ev_main(uint vid [[vertex_id]], const device float2* verts [[buffer(0)]]) {
        float2 p = verts[vid];
        EOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5); return o;
    }

    """
    private static let frags: [String: String] = [
        "waterwaves": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 dir = float2(P[1], P[2]);
            float maskV = mask.sample(s, in.uv).r;
            float2 tc = in.uv;
            float pos = abs(dot(tc - 0.5, dir));
            float distance = P[0] * P[3] + dot(tc, dir) * (P[4] + P[6] * pos);
            float2 offset = float2(dir.y, -dir.x);
            float strength = P[5] * P[5] + P[6] * pos;
            tc += sin(distance) * offset * strength * maskV;
            return fb.sample(s, tc);
        }
        """,
        "opacity": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            c.a *= mask.sample(s, in.uv).r * P[1];
            return c;
        }
        """,
        "tint": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            float m = mask.sample(s, in.uv).r;
            float3 tint = float3(P[1], P[2], P[3]);
            c.rgb = mix(c.rgb, tint, P[4] * m);
            return c;
        }
        """,
        "scroll": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::repeat);
            float2 uv = fract((in.uv + P[0] * float2(P[3], P[4])) * float2(P[1], P[2]));
            return fb.sample(s, uv);
        }
        """,
    ]
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter EffectShadersTests`
Expected: PASS (6 tests). `swift build` 성공(아직 SceneRenderer가 옛 EUniforms 참조 시 실패할 수 있음 → Task 3에서 정리; 본 태스크는 EffectShadersTests만 통과 확인).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/EffectShaders.swift Tests/WapleRenderTests/EffectShadersTests.swift
git commit -m "feat: generic EffectShaders (params + scroll/opacity/tint frags)"
```

---

### Task 3: `SceneRenderer` 일반 유니폼 연동

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift`

**Interfaces:**
- Consumes: `EffectShaders.params`, `SceneEffect.constants`([String:[Float]])

- [ ] **Step 1: EffectGPU에 params, EffectUniforms 제거**

`Sources/WapleRender/SceneRenderer.swift`:
(a) 파일 상단 `private struct EffectUniforms { ... }` 줄 삭제.
(b) `EffectGPU` 를 교체:
```swift
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let mask: MTLTexture; let params: [Float] }
```

- [ ] **Step 2: buildLayers에서 params 계산**

`buildLayers` 의 effect 루프 `effects.append(EffectGPU(...))` 부분을 교체:
```swift
            for eff in layer.effects {
                guard let src = EffectShaders.source(for: eff.name),
                      let params = EffectShaders.params(for: eff.name, constants: eff.constants),
                      let mask = effectMask(eff.maskTextureName, package: package, device: device),
                      let pipe = effectPipeline(source: src, device: device) else { continue }
                effects.append(EffectGPU(pipeline: pipe, mask: mask, params: params))
            }
```

- [ ] **Step 3: applyEffect를 일반 float 버퍼로**

`applyEffect` 의 유니폼 설정부를 교체. `var u = effectUniforms(...)`/`setFragmentBytes(&u, ...)` 두 줄을:
```swift
        var buf = [time] + eff.params
        buf.withUnsafeBytes { ptr in
            enc.setFragmentBytes(ptr.baseAddress!, length: ptr.count, index: 0)
        }
```

- [ ] **Step 4: effectUniforms() 헬퍼 삭제**

`private func effectUniforms(_ c:..., time:...) -> EffectUniforms { ... }` 메서드 전체 삭제.

- [ ] **Step 5: 빌드 + 테스트**

Run: `swift build` → 성공. `swift test` → 전체 PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleRender/SceneRenderer.swift
git commit -m "refactor: SceneRenderer passes generic [time]+params effect uniform"
```

---

### Task 4: 시각 게이트 (자율/수동)

자동 테스트 불가. **수동/자율.**

**Files:** 없음(검증). 어긋나면 EffectShaders frag/params 조정.

- [ ] **Step 1: 임시 적용 진입점**

`Sources/Waple/AppDelegate.swift` 끝에 임시(커밋 금지):
```swift
        RendererFactory.experimentalSceneEnabled = true   // (없으면 무시; SP1.5에서 제거됨)
        apply(folderURL: URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2111201226", isDirectory: true))
```
(`experimentalSceneEnabled` 가 이미 제거됐다면 그 줄은 빼고 apply만.)

- [ ] **Step 2: 효과별 검증**

`swift build && swift run Waple` (데스크탑 보이게):
- **waterwaves on 풀-마스크 씬**: `2842323353`로 바꿔 물결이 뚜렷한가(마스크 정확성).
- **scroll**: scroll 효과 가진 씬에서 시간에 따라 흐르는가.
- **opacity**: 알파/마스크로 부분 투명한가.
- **tint**: 색 틴트가 마스크 영역에 입혀지는가.
관찰 후 어긋남(키 매핑/방향/스케일) 있으면 `EffectShaders.params`/frag 조정.

- [ ] **Step 3: 임시 제거 + 검증**

```bash
git checkout -- Sources/Waple/AppDelegate.swift
grep -rn "TEMP\|experimentalSceneEnabled" Sources/ || echo clean
swift build && swift test 2>&1 | grep -E "Test Suite '.*xctest' (passed|failed)"
```
조정이 있었으면 해당 파일만 커밋.

---

## Self-Review (작성자 체크리스트)
**1. 스펙 커버리지**: 유니폼 일반화(§3.1)→Task2/3; scroll/opacity/tint frag(§3.2)→Task2; 벡터 constants(tint color)→Task1; SceneRenderer 연동(§3.3)→Task3; 풀-마스크 검증(§7)→Task4. ✅
**2. 플레이스홀더**: 없음(키 매핑은 게이트 검증 명시). ✅
**3. 타입 일관성**: `SceneEffect.constants:[String:[Float]]`, `EffectShaders.source(for:)/params(for:constants:)`, `EffectGPU.params:[Float]`, frag `constant float* P`(P[0]=time), buildLayers/applyEffect 일치. ✅
**범위 밖**: waterripple/shake·블렌드모드·추가 텍스처 슬롯·효과강도 설정(SP3c+).
