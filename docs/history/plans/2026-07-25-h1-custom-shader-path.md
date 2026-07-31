# H1 2D Layer Custom Shader Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 2D layer material custom-shader path end-to-end: parse → model → pipeline build → encode → fallback.

**Architecture:** Extend the existing GLSL→MSL translation infrastructure (used for effects) to 2D image-layer materials. Parse the material `shader` field, build a translated pipeline with `premultiplyOutput` and `layerTint` support, and add a custom branch in `encodeLayer` that uses `EngineU.mvp` for the layer transform. Fall back to `QuadShaders` on any failure.

**Tech Stack:** Swift, Metal, XCTest, GLSLTranslator.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/WapleCore/SceneDocument.swift` | Parse material `shader`/`combos`/`constantshadervalues`/`textures` into `SceneLayer` |
| `Sources/WapleCore/GLSLTranslator.swift` | Add `premultiplyOutput` parameter and `layerTint` to `EngineU` |
| `Sources/WapleRender/SceneRenderer.swift` | Add `CustomLayerShader` struct and `GPULayer.customShader` field |
| `Sources/WapleRender/SceneRendererResources.swift` | Add `buildCustomLayerShader` and `translatedLayerPipeline` |
| `Sources/WapleRender/SceneRendererFrameEncoder.swift` | Update `engineUniform` for `layerTint`; add custom-shader branch in `encodeLayer` |
| `Tests/WapleCoreTests/SceneDocumentTests.swift` | Parsing tests |
| `Tests/WapleCoreTests/GLSLTranslatorTests.swift` | `premultiplyOutput` and `EngineU` tests |
| `Tests/WapleRenderTests/SceneRendererCustomShaderTests.swift` | Integration/fallback tests |

---

### Task 1: SceneLayer Material Shader Fields + Parsing

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift`
- Test: `Tests/WapleCoreTests/SceneDocumentTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/WapleCoreTests/SceneDocumentTests.swift`:

```swift
/// H1: 머티리얼 passes[0] 의 shader/combos/constantshadervalues/textures 파스 보존.
func testParsesMaterialCustomShaderFields() throws {
    let scene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
     "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                 "angles":"0 0 0","alpha":0.8,"color":"1 0.5 0.5","brightness":0.9,"visible":true}]}
    """
    let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    let material = #"{"passes":[{"shader":"genericimage2","textures":["pic",null,"mask"],"combos":{"LIGHTING":1,"SPRITESHEET":0},"constantshadervalues":{"roughness":0.5,"metallic":{"value":0.2},"color":{"script":"return [1,0,0];","value":"1 1 1","scriptproperties":{"foo":1}}}}]}"#
    let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
    let doc = try SceneDocument.parse(package: p)
    let layer = doc.layers[0]
    XCTAssertEqual(layer.materialShader, "genericimage2")
    XCTAssertEqual(layer.materialCombos["LIGHTING"], 1)
    XCTAssertEqual(layer.materialCombos["SPRITESHEET"], 0)
    XCTAssertEqual(layer.materialConstants["roughness"], [0.5])
    XCTAssertEqual(layer.materialConstants["metallic"], [0.2])
    XCTAssertEqual(layer.materialConstants["color"], [1, 1, 1])
    XCTAssertEqual(layer.materialConstantScripts["color"], "return [1,0,0];")
    XCTAssertNotNil(layer.materialConstantScriptProps["color"])
    XCTAssertEqual(layer.materialTextureNames, ["pic", nil, "mask"])
    // 기존 PBR 필드도 유지(폴터 경로).
    XCTAssertEqual(layer.roughness, 0.5)
    XCTAssertEqual(layer.metallic, 0.2)
}

/// H1: shader 필드 부재 시 nil — 기존 고정 경로(무회귀).
func testMaterialShaderAbsentLeavesNil() throws {
    let scene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
     "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                 "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
    """
    let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    let material = #"{"passes":[{"textures":["pic"]}]}"#
    let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
    let doc = try SceneDocument.parse(package: p)
    XCTAssertNil(doc.layers[0].materialShader)
    XCTAssertTrue(doc.layers[0].materialCombos.isEmpty)
    XCTAssertTrue(doc.layers[0].materialConstants.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SceneDocumentTests.testParsesMaterialCustomShaderFields`
Expected: FAIL — `materialShader` property does not exist.

- [ ] **Step 3: Add fields to SceneLayer**

In `Sources/WapleCore/SceneDocument.swift`, add to `SceneLayer` (after `materialScriptProps`):

```swift
/// H1: 커스텀 머티리얼 셰이더(material passes[0].shader). nil = 고정 QuadShaders 경로.
public var materialShader: String? = nil
/// H1: 커스텀 머티리얼 콤보(material passes[0].combos).
public var materialCombos: [String: Int] = [:]
/// H1: 커스텀 머티리얼 상수(material passes[0].constantshadervalues).
public var materialConstants: [String: [Float]] = [:]
/// H1: 커스텀 머티리얼 상수 스크립트.
public var materialConstantScripts: [String: String] = [:]
public var materialConstantScriptProps: [String: String] = [:]
/// H1: 커스텀 머티리얼 텍스처 슬롯(material passes[0].textures).
public var materialTextureNames: [String?] = []
```

- [ ] **Step 4: Parse fields in parseLayer**

In `Sources/WapleCore/SceneDocument.swift`, inside the material JSON parsing block (after the existing `usershadervalues` block around line 999), add local variables and parsing:

```swift
var materialShader: String? = nil
var materialCombos: [String: Int] = [:]
var materialConstants: [String: [Float]] = [:]
var materialConstantScripts: [String: String] = [:]
var materialConstantScriptProps: [String: String] = [:]
var materialTextureNames: [String?] = []

// ... existing combos / constantshadervalues / usershadervalues parsing ...

// H1: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
if let shader = p0["shader"] as? String { materialShader = shader }
if let combos = p0["combos"] as? [String: Any] {
    for (k, v) in combos {
        if let i = intVal(v) { materialCombos[k] = i }
    }
}
if let csv = p0["constantshadervalues"] as? [String: Any] {
    for (k, v) in csv {
        if let dict = v as? [String: Any], let sc = dict["script"] as? String {
            materialConstantScripts[k] = sc
            if let sp = Self.scriptPropsJSON(dict["scriptproperties"]) { materialConstantScriptProps[k] = sp }
        }
        if let f = float(v) { materialConstants[k] = [f] }
        else if let s = v as? String {
            let f = floatList(s)
            if !f.isEmpty { materialConstants[k] = f }
        }
        else if let dict = v as? [String: Any] {
            if let f = float(dict["value"]) { materialConstants[k] = [f] }
            else if let sv = dict["value"] as? String {
                let f = floatList(sv)
                if !f.isEmpty { materialConstants[k] = f }
            }
        }
    }
}
if let texs = p0["textures"] as? [Any] {
    materialTextureNames = texs.map { $0 as? String }
}
```

Then assign to `layer` before `return layer`:

```swift
layer.materialShader = materialShader
layer.materialCombos = materialCombos
layer.materialConstants = materialConstants
layer.materialConstantScripts = materialConstantScripts
layer.materialConstantScriptProps = materialConstantScriptProps
layer.materialTextureNames = materialTextureNames
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter SceneDocumentTests.testParsesMaterialCustomShaderFields`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m "feat(H1): parse material custom shader fields in SceneLayer"
```

---

### Task 2: GLSLTranslator premultiplyOutput + layerTint

**Files:**
- Modify: `Sources/WapleCore/GLSLTranslator.swift`
- Test: `Tests/WapleCoreTests/GLSLTranslatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/WapleCoreTests/GLSLTranslatorTests.swift`:

```swift
func testPremultiplyOutputWrapsFragment() throws {
    let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: [:], premultiplyOutput: true))
    XCTAssertTrue(t.msl.contains("float4 layerTint;"), "EngineU must include layerTint")
    XCTAssertTrue(t.msl.contains("gl_FragColor.rgb *= eng.layerTint.rgb;"))
    XCTAssertTrue(t.msl.contains("gl_FragColor.a *= eng.layerTint.a;"))
    XCTAssertTrue(t.msl.contains("return float4(gl_FragColor.rgb * gl_FragColor.a, gl_FragColor.a);"))
    XCTAssertFalse(t.msl.contains("return gl_FragColor;"))
}

func testDefaultNoPremultiplyKeepsStraightAlpha() throws {
    let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: [:]))
    XCTAssertTrue(t.msl.contains("return gl_FragColor;"))
    XCTAssertFalse(t.msl.contains("gl_FragColor.rgb *= eng.layerTint.rgb;"))
    XCTAssertTrue(t.msl.contains("float4 layerTint;"), "EngineU always includes layerTint")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GLSLTranslatorTests.testPremultiplyOutputWrapsFragment`
Expected: FAIL — `premultiplyOutput` parameter does not exist.

- [ ] **Step 3: Add premultiplyOutput parameter**

In `Sources/WapleCore/GLSLTranslator.swift`:

1. Update `MemoKey` to include `premultiply`:

```swift
private struct MemoKey: Hashable {
    let vRaw: String
    let fRaw: String
    let vInlined: String
    let fInlined: String
    let combos: String
    let premultiply: Bool
}
```

2. Update `translate` signature:

```swift
public static func translate(vertex: String, fragment: String, combos: [String: Int],
                             include: (String) -> String? = { _ in nil },
                             premultiplyOutput: Bool = false) -> TranslatedShader? {
    guard WapleProfiler.enabled else {
        return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include, premultiplyOutput: premultiplyOutput)
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    defer { WapleProfiler.recordTranslate(seconds: CFAbsoluteTimeGetCurrent() - t0) }
    return _memoizedTranslate(vertex: vertex, fragment: fragment, combos: combos, include: include, premultiplyOutput: premultiplyOutput)
}
```

3. Update `_memoizedTranslate` signature and pass through:

```swift
private static func _memoizedTranslate(vertex: String, fragment: String, combos: [String: Int],
                                       include: (String) -> String?, premultiplyOutput: Bool) -> TranslatedShader? {
    let key = MemoKey(vRaw: vertex, fRaw: fragment,
                      vInlined: ShaderPreprocessor.inlinedSource(vertex, include: include),
                      fInlined: ShaderPreprocessor.inlinedSource(fragment, include: include),
                      combos: combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                      premultiply: premultiplyOutput)
    memoLock.lock()
    if let cached = memoCache[key] { memoLock.unlock(); return cached }
    memoLock.unlock()
    let result = _translate(vertex: vertex, fragment: fragment, combos: combos, include: include, premultiplyOutput: premultiplyOutput)
    memoLock.lock()
    memoCache[key] = result
    memoComputeCount += 1
    memoLock.unlock()
    return result
}
```

4. Update `_translate` signature and pass to `assemble`:

```swift
private static func _translate(vertex: String, fragment: String, combos: [String: Int],
                               include: (String) -> String?, premultiplyOutput: Bool) -> TranslatedShader? {
    // ... existing code ...
    let msl = assemble(varyings: varyings, textures: textures, materialCount: materials.count,
                       vertAudioNames: audioBufferNames.filter { vertIds.contains($0.name) },
                       fragAudioNames: audioBufferNames.filter { fragIds.contains($0.name) },
                       consts: consts, helperProtos: helperProtos, helperDefs: helperDefs,
                       vertBody: vertBody, fragBody: fragBody, structs: structBlock,
                       premultiplyOutput: premultiplyOutput)
    return TranslatedShader(msl: msl, materialParams: materials, textureSlots: textures, usesAudio: usesAudio)
}
```

5. Update `assemble` to add `layerTint` to `EngineU` and wrap fragment output:

```swift
private static func assemble(varyings: [(type: GLSLType, name: String)], textures: [Int],
                             materialCount: Int,
                             vertAudioNames: [(name: String, buffer: Int)] = [],
                             fragAudioNames: [(name: String, buffer: Int)] = [],
                             consts: [String] = [],
                             helperProtos: [String] = [], helperDefs: [String] = [],
                             vertBody: String, fragBody: String, structs: String = "",
                             premultiplyOutput: Bool = false) -> String {
    // ... existing vary/vin code ...
    let eng = "struct EngineU { float4x4 mvp; float4 timeAndPad; float4 pointerLastAndPad; float4 texRes[8]; float4 texWrap[2]; float4 texFilter[2]; float4 layerTint; };\n"
    // ... existing uvHelpers code ...

    var fragBody = fragBody
    if premultiplyOutput {
        fragBody = fragBody.replacingOccurrences(
            of: "return gl_FragColor;",
            with: """
            gl_FragColor.rgb *= eng.layerTint.rgb;
            gl_FragColor.a *= eng.layerTint.a;
            return float4(gl_FragColor.rgb * gl_FragColor.a, gl_FragColor.a);
            """)
    }

    let fragSig = """
    fragment float4 ef_main(Vary in [[stage_in]]\(pFrag), constant EngineU& eng [[buffer(1)]]\(fragTex)\(audioFrag)) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        constexpr sampler smpRepeat(filter::linear, address::repeat);
        constexpr sampler smpNearest(filter::nearest, address::clamp_to_edge);
        constexpr sampler smpRepeatNearest(filter::nearest, address::repeat);
    \(indent(fragBody))
    }
    """
    // ... rest of existing code ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GLSLTranslatorTests.testPremultiplyOutputWrapsFragment`
Expected: PASS

- [ ] **Step 5: Run all GLSLTranslator tests**

Run: `swift test --filter GLSLTranslatorTests`
Expected: All pass (existing tests unaffected).

- [ ] **Step 6: Commit**

```bash
git add Sources/WapleCore/GLSLTranslator.swift Tests/WapleCoreTests/GLSLTranslatorTests.swift
git commit -m "feat(H1): add premultiplyOutput and layerTint to GLSLTranslator"
```

---

### Task 3: CustomLayerShader Struct + Pipeline Build

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift`
- Modify: `Sources/WapleRender/SceneRendererResources.swift`

- [ ] **Step 1: Add CustomLayerShader struct**

In `Sources/WapleRender/SceneRenderer.swift`, add near `EffectGPU`:

```swift
/// H1: 2D 레이어 커스텀 머티리얼 셰이더 파이프라인 + 바인드 플랜.
struct CustomLayerShader {
    let pipeline: MTLRenderPipelineState
    let material: [SIMD4<Float>]                 // materialParams slot values
    let aux: [(slot: Int, tex: MTLTexture)]     // material texture slots > 0
    let texRes: [SIMD4<Float>]                   // 8 slots; slot 0 = layer texture
    let texWrap: [Float]                         // 8 × 1=clamp / 0=repeat
    let texFilter: [Float]                       // 8 × 1=nearest / 0=linear
    var scripts: [(slot: Int, engine: TextScriptEngine)]  // constant scripts
}
```

Add to `GPULayer`:

```swift
var customShader: CustomLayerShader? = nil   // H1: 커스텀 머티리얼 셰이더 — nil = QuadShaders 경로
```

- [ ] **Step 2: Add translatedLayerPipeline**

In `Sources/WapleRender/SceneRendererResources.swift`, add:

```swift
/// H1: 레이어 커스텀 셰이더 파이프라인. 정점 디스크립터는 translatedPipeline 과 동일(a_Position float3@0,
/// a_TexCoord float2@12, stride 20, buffer 4). 색상 어태치먼트는 레이어 블렌드 모드에 맞춘다.
func translatedLayerPipeline(msl: String, device: MTLDevice, pixelFormat: MTLPixelFormat, additive: Bool) -> MTLRenderPipelineState? {
    let lib: MTLLibrary
    do {
        lib = try WapleProfiler.compile(msl) { try device.makeLibrary(source: msl, options: nil) }
    } catch {
        let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
        NSLog("%@", "[Waple] custom layer MSL compile error: \(first)")
        return nil
    }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = lib.makeFunction(name: "ev_main")
    pd.fragmentFunction = lib.makeFunction(name: "ef_main")
    let vd = MTLVertexDescriptor()
    vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 4
    vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 4
    vd.layouts[4].stride = 20
    pd.vertexDescriptor = vd
    let att = pd.colorAttachments[0]!
    att.pixelFormat = pixelFormat
    att.isBlendingEnabled = true
    att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
    att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
    if additive {
        att.destinationRGBBlendFactor = .one
        att.destinationAlphaBlendFactor = .one
    } else {
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
}
```

- [ ] **Step 3: Add buildCustomLayerShader**

In `Sources/WapleRender/SceneRendererResources.swift`, add:

```swift
/// H1: 레이어 머티리얼 커스텀 셰이더 빌드. 성공 시 CustomLayerShader, 실패 시 nil(→ QuadShaders 폴터).
/// buildTranslatedEffect 의 5책임 분해를 2D 레이어에 맞춰 단순화한 버전.
func buildCustomLayerShader(_ layer: SceneLayer, texture: MTLTexture, package: ScenePackage, device: MTLDevice,
                            pixelFormat: MTLPixelFormat) -> CustomLayerShader? {
    guard let shaderName = layer.materialShader else { return nil }
    let include: (String) -> String? = { header in
        for cand in ["shaders/\(header)", header] {
            if let d = self.quietAssetData(cand, package: package), let s = String(data: d, encoding: .utf8) { return s }
        }
        return BuiltinShaderIncludes.lookup(header)
    }
    guard let vData = quietAssetData("shaders/\(shaderName).vert", package: package),
          let fData = quietAssetData("shaders/\(shaderName).frag", package: package),
          let vert = String(data: vData, encoding: .utf8),
          let frag = String(data: fData, encoding: .utf8) else {
        NSLog("%@", "[Waple] custom layer shader source missing: \(shaderName)")
        return nil
    }
    var combos = layer.materialCombos
    for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
        let bound = slot < layer.materialTextureNames.count && layer.materialTextureNames[slot] != nil
        if bound { combos[comboName] = 1 }
    }
    guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos,
                                           include: include, premultiplyOutput: true) else {
        NSLog("%@", "[Waple] custom layer GLSL translate failed: \(shaderName)")
        return nil
    }
    let additive = layer.blendMode == "additive"
    guard let pipe = translatedLayerPipeline(msl: t.msl, device: device,
                                             pixelFormat: pixelFormat, additive: additive) else {
        NSLog("%@", "[Waple] custom layer pipeline compile failed: \(shaderName)")
        return nil
    }
    let material: [SIMD4<Float>] = t.materialParams.map { p in
        let v = layer.materialConstants[p.sceneKey] ?? p.defaultValue
        return SIMD4<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0,
                            v.count > 2 ? v[2] : 0, v.count > 3 ? v[3] : 0)
    }
    var scripts: [(slot: Int, engine: TextScriptEngine)] = []
    for (slot, p) in t.materialParams.enumerated() {
        if let src = layer.materialConstantScripts[p.sceneKey],
           let engine = makeScriptEngine(src, scriptPropsJSON: layer.materialConstantScriptProps[p.sceneKey]) {
            scripts.append((slot, engine))
            if engine.hasUpdate { hasAnimations = true }
        }
    }
    let lw = Float(max(1, texture.width)), lh = Float(max(1, texture.height))
    var texRes = [SIMD4<Float>](repeating: SIMD4(lw, lh, lw, lh), count: 8)
    var texWrap = [Float](repeating: 0, count: 8)
    var texFilter = [Float](repeating: 0, count: 8)
    texRes[0] = SIMD4(lw, lh, lw, lh)
    texWrap[0] = resolveTextureClampUVs(layer.textureEntryName, package: package) ? 1 : 0
    texFilter[0] = resolveTextureNoInterpolation(layer.textureEntryName, package: package) ? 1 : 0
    var aux: [(slot: Int, tex: MTLTexture)] = []
    for slot in t.textureSlots where slot > 0 && slot < 128 {
        let name = slot < layer.materialTextureNames.count ? layer.materialTextureNames[slot] : nil
        if let tex = resolveTexture(name, package: package, device: device) {
            aux.append((slot, tex))
            if slot < 8 {
                let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                texRes[slot] = SIMD4(w, h, w, h)
                texWrap[slot] = resolveTextureClampUVs(name, package: package) ? 1 : 0
                texFilter[slot] = resolveTextureNoInterpolation(name, package: package) ? 1 : 0
            }
        }
    }
    return CustomLayerShader(pipeline: pipe, material: material, aux: aux,
                             texRes: texRes, texWrap: texWrap, texFilter: texFilter,
                             scripts: scripts)
}
```

- [ ] **Step 4: Wire into buildLayers**

In `Sources/WapleRender/SceneRendererResources.swift`, find where `GPULayer` is constructed in `buildLayers` and add after the layer is fully initialized:

```swift
// H1: 커스텀 머티리얼 셰이더 파이프라인 빌드(실패 시 nil → QuadShaders 폴터).
if let def = layer.def, def.materialShader != nil, let tex = displayTextures[i] {
    layer.customShader = buildCustomLayerShader(def, texture: tex, package: package, device: device,
                                                pixelFormat: accPixelFormat)
}
```

Note: exact placement depends on `buildLayers` structure; ensure it runs after the layer texture is available.

- [ ] **Step 5: Commit**

```bash
git add Sources/WapleRender/SceneRenderer.swift Sources/WapleRender/SceneRendererResources.swift
git commit -m "feat(H1): add CustomLayerShader and buildCustomLayerShader"
```

---

### Task 4: engineUniform layerTint

**Files:**
- Modify: `Sources/WapleRender/SceneRendererFrameEncoder.swift`

- [ ] **Step 1: Update engineUniform**

In `Sources/WapleRender/SceneRendererFrameEncoder.swift`, update `engineUniform`:

```swift
func engineUniform(time: Float, texRes: [SIMD4<Float>], texWrap: [Float] = [], texFilter: [Float] = [],
                   layerTint: SIMD4<Float> = SIMD4(1, 1, 1, 1)) -> [Float] {
    var e = [Float](repeating: 0, count: 16 + 8 + 32 + 8 + 8 + 4)
    e[0] = 1; e[5] = 1; e[10] = 1; e[15] = 1   // identity mvp
    e[16] = time; e[17] = pointerUV.x; e[18] = pointerUV.y
    e[19] = frameDT
    e[20] = pointerUVLast.x; e[21] = pointerUVLast.y
    e[22] = pointerDown ? 1 : 0
    for n in 0..<8 {
        let r = n < texRes.count ? texRes[n] : SIMD4<Float>(1, 1, 1, 1)
        let o = 24 + n * 4
        e[o] = r.x; e[o + 1] = r.y; e[o + 2] = r.z; e[o + 3] = r.w
    }
    for n in 0..<8 where n < texWrap.count { e[56 + n] = texWrap[n] }
    for n in 0..<8 where n < texFilter.count { e[64 + n] = texFilter[n] }
    e[72] = layerTint.x; e[73] = layerTint.y; e[74] = layerTint.z; e[75] = layerTint.w
    return e
}
```

- [ ] **Step 2: Run existing effect tests**

Run: `swift test --filter SceneRenderer`
Expected: All pass (layerTint defaults to white).

- [ ] **Step 3: Commit**

```bash
git add Sources/WapleRender/SceneRendererFrameEncoder.swift
git commit -m "feat(H1): add layerTint to engineUniform"
```

---

### Task 5: encodeLayer Custom Shader Branch

**Files:**
- Modify: `Sources/WapleRender/SceneRendererFrameEncoder.swift`

- [ ] **Step 1: Add layer transform matrix helper**

In `Sources/WapleRender/SceneRendererFrameEncoder.swift`, add:

```swift
/// H1: 커스텀 셰이더 레이어의 로컬 쿼드(-1…1) → NDC 변환 행렬.
/// quadVertices + v_main 의 기존 동작을 행렬로 재현.
func layerTransformMatrix(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float, alignment: String,
                          parallaxDepth: Vec2, camOffset: SIMD2<Float>, shakeOffset: SIMD2<Float>,
                          aspectScale: SIMD2<Float>) -> simd_float4x4 {
    let aligned = Self.alignedOrigin(origin: origin, size: size, scale: scale, angleZ: angleZ, alignment: alignment)
    let hw = size.x * scale.x * 0.5
    let hh = size.y * scale.y * 0.5
    let ca = cos(angleZ), sa = sin(angleZ)
    // model: translate(aligned) * rotateZ(angleZ) * scale(hw, hh)
    var model = simd_float4x4(1)
    model.columns.0 = SIMD4(ca * hw, sa * hw, 0, 0)
    model.columns.1 = SIMD4(-sa * hh, ca * hh, 0, 0)
    model.columns.2 = SIMD4(0, 0, 1, 0)
    model.columns.3 = SIMD4(aligned.x, aligned.y, 0, 1)
    // ortho: pixel → NDC (Y-flip, same as sceneToNDC)
    var ortho = simd_float4x4(1)
    ortho.columns.0 = SIMD4(2 / projW, 0, 0, 0)
    ortho.columns.1 = SIMD4(0, -2 / projH, 0, 0)
    ortho.columns.2 = SIMD4(0, 0, 1, 0)
    ortho.columns.3 = SIMD4(-1, 1, 0, 1)
    // camera/shake translation
    let camX = camOffset.x * parallaxDepth.x + shakeOffset.x
    let camY = camOffset.y * parallaxDepth.y + shakeOffset.y
    var cam = simd_float4x4(1)
    cam.columns.3 = SIMD4(camX, camY, 0, 1)
    // aspect scale
    var aspect = simd_float4x4(1)
    aspect.columns.0 = SIMD4(aspectScale.x, 0, 0, 0)
    aspect.columns.1 = SIMD4(0, aspectScale.y, 0, 0)
    return aspect * cam * ortho * model
}
```

- [ ] **Step 2: Capture effective transform in encodeLayer**

In `Sources/WapleRender/SceneRendererFrameEncoder.swift`, add at the top of `encodeLayer` (after `var tint = layer.tint`):

```swift
// H1: 커스텀 셰이더용 유효 변환(애니/스크립트/attachment 반영 후).
var effectiveTransform: (origin: Vec2, scale: Vec2, angle: Float)? = nil
```

Then, inside the animation block (after `quadDirty` is computed and all origin/scale/angle updates are done), add:

```swift
if layer.customShader != nil {
    effectiveTransform = (origin, scale, angle)
}
```

This makes the animated transform available outside the `if let def = layer.def, let device` block.

- [ ] **Step 3: Add custom shader branch in encodeLayer**

In `Sources/WapleRender/SceneRendererFrameEncoder.swift`, replace the existing pipeline selection block (around `let near = layer.noInterp && layer.effects.isEmpty`) with:

```swift
// H1: 커스텀 머티리얼 셰이더 경로 — QuadShaders 대체.
if let custom = layer.customShader, let def = layer.def, let device {
    let t = effectiveTransform ?? (origin: def.origin, scale: def.scale, angle: def.angleZ)
    let m = layerTransformMatrix(origin: t.origin, size: def.size, scale: t.scale,
                                 angleZ: t.angle, alignment: def.alignment,
                                 parallaxDepth: layer.parallaxDepth,
                                 camOffset: camOffset, shakeOffset: frameShakeOffset,
                                 aspectScale: aspectScale)
    enc.setRenderPipelineState(custom.pipeline)
    enc.setVertexBuffer(effectQuadInterleaved, offset: 0, index: 4)
    var mat = custom.material
    for sc in custom.scripts {
        sc.engine.setRuntime(Double(time))
        let cur = mat[sc.slot]
        if let v = sc.engine.evaluateVec(current: [cur.x, cur.y, cur.z]) {
            if v.count >= 3 { mat[sc.slot] = SIMD4(v[0], v[1], v[2], cur.w) }
            else if v.count == 1 { mat[sc.slot] = SIMD4(v[0], cur.y, cur.z, cur.w) }
        }
    }
    if !mat.isEmpty {
        mat.withUnsafeBytes {
            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
    }
    let eng = engineUniform(time: time, texRes: custom.texRes, texWrap: custom.texWrap,
                            texFilter: custom.texFilter, layerTint: tint)
    eng.withUnsafeBytes {
        enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
        enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
    }
    enc.setFragmentTexture(texture, index: 0)
    for (slot, tex) in custom.aux { enc.setFragmentTexture(tex, index: slot) }
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    return
}

// 기존 파이프라인 선택(커스텀 셰이더 없는 레이어).
let near = layer.noInterp && layer.effects.isEmpty
if layer.isLit, let litPipeline {
    // ... existing code ...
```

Note: `tint` here is the final tint after animations and property scripts have been evaluated (the existing `var tint = layer.tint` at the top of `encodeLayer` plus all updates). The custom shader branch uses that same `tint` variable.

- [ ] **Step 4: Commit**

```bash
git add Sources/WapleRender/SceneRendererFrameEncoder.swift
git commit -m "feat(H1): add custom shader branch in encodeLayer"
```

---

### Task 6: Integration Tests

**Files:**
- Create: `Tests/WapleRenderTests/SceneRendererCustomShaderTests.swift`

- [ ] **Step 1: Write integration tests**

```swift
import XCTest
@testable import WapleCore
@testable import WapleRender

final class SceneRendererCustomShaderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ScenePackageTests.makePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                title: id, tags: [], contentRating: nil, workshopId: nil,
                                dependency: nil, folderURL: dir)
    }

    private let scene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
     "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                 "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
    """
    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#

    func testCustomShaderLayerBuildsPipeline() throws {
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("shaders/genericimage2.vert", vert.data(using: .utf8)!),
            ("shaders/genericimage2.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try project(files: files, id: "custom"))
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertNotNil(r.layers[0].customShader)
    }

    func testCustomShaderFallbackOnMissingShader() throws {
        let material = #"{"passes":[{"shader":"missing_shader","textures":["pic"]}]}"#
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try project(files: files, id: "fallback"))
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertNil(r.layers[0].customShader, "missing shader must fall back to QuadShaders")
    }
}
```

- [ ] **Step 2: Run integration tests**

Run: `swift test --filter SceneRendererCustomShaderTests`
Expected: PASS (or skip if Metal unavailable).

- [ ] **Step 3: Commit**

```bash
git add Tests/WapleRenderTests/SceneRendererCustomShaderTests.swift
git commit -m "test(H1): add custom shader integration tests"
```

---

### Task 7: Full Regression

**Files:**
- All test suites

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All suites pass (`WapleCoreTests`, `WapleRenderTests`, `WapleAppTests`, `WapleLibraryTests`, `WapleSnapshotTests`).

- [ ] **Step 2: Fix any regressions**

If existing tests fail, diagnose whether the failure is caused by the EngineU layout change or the new parsing. Adjust defaults or add compatibility shims as needed.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat(H1): 2D layer custom shader path complete"
```

---

## Self-Review

**1. Spec coverage:**
- ✅ Parse `shader`/`combos`/`constantshadervalues`/`textures` → Task 1
- ✅ `SceneLayer` fields → Task 1
- ✅ `premultiplyOutput` + `layerTint` → Task 2
- ✅ `CustomLayerShader` + `buildCustomLayerShader` → Task 3
- ✅ `engineUniform` `layerTint` → Task 4
- ✅ `encodeLayer` branch → Task 5
- ✅ Fallback rules → Task 3 (build returns nil) + Task 6 (test)
- ✅ Integration tests → Task 6
- ✅ Full regression → Task 7

**2. Placeholder scan:** No TBD/TODO. All steps have concrete code or commands.

**3. Type consistency:**
- `SceneLayer.materialShader` is `String?` everywhere.
- `CustomLayerShader` fields match `buildCustomLayerShader` return value.
- `engineUniform` signature matches `EngineU` layout (72 + 4 = 76 floats).
- `premultiplyOutput` parameter name is consistent across `translate`, `_memoizedTranslate`, `_translate`, and `assemble`.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-25-h1-custom-shader-path.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
