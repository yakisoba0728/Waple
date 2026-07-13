import AppKit
import MetalKit
import simd
import WapleCore

// SceneRenderer 리소스 빌더(갓클래스 3분할 ①, 2026-07-04 — 코드 이동 + private→internal 만, 로직 무변경):
// mount 시 GPU 리소스화 경로 — 에셋 로드(pkg → base-assets 폴백), 레이어/효과(손-포팅·GLSL 번역)/
// 파티클/텍스트 빌드, 텍스처·파이프라인 팩토리. per-frame 인코딩은 SceneRendererFrameEncoder.swift,
// 3D 서브시스템은 SceneRenderer3D.swift 참조.
extension SceneRenderer {
    struct AudioParams { let mode: Int; let freqMin: Float; let freqMax: Float; let bounds: SIMD2<Float>; let power: Float; let multiply: Float }
    /// 효과 바인딩: 손-포팅(기존 규약: float* P buffer(0) + aux texture(1+) + audioResp buffer(1))
    /// 또는 GLSL→MSL 변환본(reflection 규약: float4* p buffer(0) + EngineU buffer(1) + slot 텍스처 + audioL/R buffer(2/3)).
    /// 변환 효과의 1개 패스(멀티패스: effect.json passes[] — target=fbo 인덱스(nil=효과 출력),
    /// binds=(슬롯, 소스: -1=previous(효과 입력)|fbo 인덱스)).
    struct TranslatedPass {
        let pipeline: MTLRenderPipelineState
        let material: [SIMD4<Float>]
        let aux: [(slot: Int, tex: MTLTexture)]
        let binds: [(slot: Int, source: Int)]
        let target: Int?
        let usesAudio: Bool
        let texRes: [SIMD4<Float>]
        /// 상수 프로퍼티 스크립트(슬롯 → 엔진) — per-frame 평가로 material 갱신(컬러 사이클 등).
        var scripts: [(slot: Int, engine: TextScriptEngine)] = []
    }
    enum EffectBind {
        case handPort(params: [Float], aux: [MTLTexture], audio: AudioParams?)
        // fboScales: 이름 있는 FBO 의 해상도 나눗수(effect.json fbos[].scale) — 실행 시 dst 크기/scale 로 풀 할당.
        case translated(passes: [TranslatedPass], fboScales: [Int])
    }
    struct EffectGPU { let pipeline: MTLRenderPipelineState; let bind: EffectBind }

    func pkgURL(in folder: URL) -> URL? {
        for name in ["scene.pkg", "gifscene.pkg"] {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for expected in ["scene.pkg", "gifscene.pkg"] {
                if let actual = names.first(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
                    return folder.appendingPathComponent(actual)
                }
            }
        }
        return nil
    }

    /// 텍스처/에셋 바이트 로드: 패키지 우선, 없으면 공유 기본 에셋 디렉터리에서 폴백.
    /// 공유에서 찾거나 둘 다 없을 때만 로그(in-pkg 일반 경로는 조용히).
    func assetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = packageData(name, package: package) { return d }
        if let base = assetBaseDir {
            guard WallpaperPathSecurity.normalizedRelativePath(name) != nil else {
                NSLog("%@", "[Waple] rejected shared asset path: \(name)")
                return nil
            }
            if let u = baseAssetURL(for: name, root: base),
               let d = try? Data(contentsOf: u) {
                NSLog("%@", "[Waple] asset from shared base: \(name)")
                return d
            }
        }
        NSLog("%@", "[Waple] asset missing (pkg+shared): \(name)")
        return nil
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        for (uid, layer) in doc.layers.enumerated() {
            // 솔리드 마커(""): 무텍스처 flat 머티리얼 → 흰색 1x1 — 기존 tint 경로(color×brightness, alpha)가 필을 만든다.
            // 컴포지션(_rt_) 레이어: 텍스처는 런타임 스냅샷 — 여기선 placeholder + 효과 dims 를 프로젝션으로 근사
            // (효과 texRes 는 주로 텍셀 오프셋 용도; 화면 크기는 draw 시 결정 — 설계 §3).
            // 텍스처 + (스프라이트시트면) TEXS 프레임. effW/effH = 효과 dst 크기(스프라이트는 프레임 dims —
            // 효과는 시트가 아니라 프레임 1장에 적용, buildDisplayTextures 가 프레임 추출 후 체인).
            let mtl: MTLTexture
            let effW: Int, effH: Int
            var frames: [TexImage.TexFrame] = []
            if layer.textureEntryName.isEmpty {  // 솔리드/컴포지션 placeholder
                guard let t = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) else { continue }
                mtl = t
                // 컴포지션 효과 dims 는 화면 근사, 솔리드는 레이어 크기 — 1×1 이면 공간 가변 효과
                // (waterwaves/scroll 등) 체인 전체가 1픽셀 타깃으로 퇴화(단색화).
                effW = layer.isFrameBuffer ? Int(max(1, projW)) : max(1, Int(layer.size.x.rounded()))
                effH = layer.isFrameBuffer ? Int(max(1, projH)) : max(1, Int(layer.size.y.rounded()))
            } else if layer.spritesheet,
                      let sprite = resolveTextureWithFrames(layer.textureEntryName, package: package, device: device),
                      sprite.frames.count > 1 {
                // SPRITESHEET 콤보 + TEXS 다중 프레임 → gif 애니. resolveTextureWithFrames 가 아틀라스
                // (멀티페이지는 세로 스택 + frame.y 페이지 오프셋) + 프레임을 준다. 단일 프레임(count≤1)은
                // 정지 이미지와 동등 → 아래 일반 경로로(무-프레임, 상시 리드로 유발 안 함).
                mtl = sprite.texture
                frames = sprite.frames
                effW = max(1, Int(sprite.frames[0].atlasWidth.rounded()))
                effH = max(1, Int(sprite.frames[0].atlasHeight.rounded()))
            } else if let texData = assetData(layer.textureEntryName, package: package),
                      let tex = TexImage.parse(texData),
                      let d = TexDecoder.rgba(from: tex, data: texData, properties: variantProperties) {
                guard let t = makeTexture(d.pixels, d.width, d.height, device) else { continue }
                mtl = t; effW = d.width; effH = d.height
            } else if let d = bitmapRGBAFile(layer.textureEntryName) {
                guard let t = makeTexture(d.pixels, d.width, d.height, device) else { continue }
                mtl = t; effW = d.width; effH = d.height
            } else { continue }
            // 스프라이트 프레임 있으면 상시 리드로 필요(gif 재생) — needsDisplay 정책은 shouldAnimate 로.
            if !frames.isEmpty { hasAnimations = true }
            let verts = Self.quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            var effects: [EffectGPU] = []
            // 디버그: WAPLE_EFFECT_SKIP=이름,이름 → 해당 효과 제외(파리티 이분용, WAPLE_MP_TRUNC 와 세트).
            let skipNames = Set((ProcessInfo.processInfo.environment["WAPLE_EFFECT_SKIP"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            for eff in layer.effects {
                if skipNames.contains(eff.name) { continue }
                // 폴백 체인(Step 5, 2026-07-02 실물 검증 후 전환): **translated 우선** — pkg 동봉 GLSL 은
                // 실제 WE 셰이더라 손-포팅 근사보다 항상 정확(실측: 근사 shake 가 5중 체인에서 과대 팬).
                // GLSL 부재/번역·컴파일 실패 시 손-포팅(스톡 7종) 폴백 → 둘 다 실패 시 스킵+로그.
                if let translated = buildTranslatedEffect(eff, package: package, device: device,
                                                          texW: effW, texH: effH) {
                    effects.append(translated)
                } else if let handPort = buildHandPortEffect(eff, package: package, device: device) {
                    effects.append(handPort)
                } else {
                    NSLog("%@", "[Waple] effect skipped (no translatable GLSL, no hand-port): \(eff.name)")
                }
            }
            if !effects.isEmpty { hasEffects = true }
            if !layer.animations.isEmpty { hasAnimations = true }
            // 퍼펫(.mdl): 스키닝 메시. WE 규약(changelog: "Only load puppet ref if file exists on
            // global file system") — ref 부재는 정상(기본 models/1x1.json 의 미베이크 puppet 등, 실측
            // 2955378002 에서만 50 레이어)이라 조용히 일반 쿼드. 다른 선택적 에셋과 동일하게 quietAssetData
            // 로 로드하고, **바이트는 있으나 파싱 실패**한 실결함만 로그(과침묵 방지).
            var puppetModel: PuppetModel? = nil
            if let pp = layer.puppet, let bytes = quietAssetData(pp, package: package) {
                if let pm = PuppetModel.parse(bytes) {
                    puppetModel = pm
                    if !pm.animations.isEmpty { hasAnimations = true }
                } else {
                    NSLog("%@", "[Waple] puppet mdl load failed (static quad fallback): \(pp)")
                }
            }
            // 레이어 프로퍼티 스크립트(visible/color/alpha): 씬 공유 컨텍스트에서 per-frame 평가.
            // visible 을 먼저 로드 — 실물 컨트롤러(3394601417 'bt')의 top-level shared 초기화가
            // 같은 오브젝트의 다른 스크립트보다 앞서도록. update 없는 스크립트(사이드이펙트 전용)도
            // 로드는 하되 연속 렌더(hasAnimations)는 유발하지 않는다.
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha"] {
                guard let src = layer.propertyScripts[key] else { continue }
                if key == "visible", Self.isVectorValuedVisibleScript(src) {
                    NSLog("%@", "[Waple] skipped vector-valued visible script")
                    continue
                }
                let ownerName = layer.name.isEmpty ? nil : layer.name
                if let e = makeScriptEngine(src, layerName: ownerName) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            // 포워드 라이팅 대상 게이트(좁게): 씬 라이트(forwardLit) + LIGHTING:1 콤보 + 일반 이미지
            // 레이어만(퍼펫/컴포지션/colorBlend 는 별도 특수 경로라 제외 → 무회귀). base litRect 산출,
            // 애니 레이어는 encodeLayer 가 per-frame 재계산.
            let layerLit = forwardLit && layer.lighting && !layer.isFrameBuffer
                && puppetModel == nil && layer.colorBlendMode == 0
            let lrect = layerLit
                ? Self.litRect(origin: layer.origin, size: layer.size, scale: layer.scale,
                          angleZ: layer.angleZ, alignment: layer.alignment, originZ: layer.originZ)
                : (SIMD4<Float>.zero, SIMD4<Float>.zero)
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, uid: uid, isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                initialVisible: layer.initialVisible,
                                colorBlendMode: layer.colorBlendMode, frames: frames,
                                isLit: layerLit, litRect: lrect))
        }
        return out
    }

    static func isVectorValuedVisibleScript(_ source: String) -> Bool {
        let compact = source.replacingOccurrences(of: "\r", with: "\n")
        let valueMutationPatterns = ["value.x =", "value.y =", "value.z =", "value.x=", "value.y=", "value.z="]
        if valueMutationPatterns.contains(where: { compact.contains($0) }) { return true }
        if compact.range(of: #"return\s+new\s+Vec[234]?\b"#, options: .regularExpression) != nil { return true }
        if compact.range(of: #"value\s*=\s*new\s+Vec[234]?\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 손-포팅 효과(검증된 스톡 7종) 빌드. 미지원 이름이면 nil(→ 변환 경로 시도).
    func buildHandPortEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice) -> EffectGPU? {
        guard let src = EffectShaders.source(for: eff.name),
              let params = EffectShaders.params(for: eff.name, constants: eff.constants, combos: eff.combos),
              let pipe = effectPipeline(source: src, device: device) else { return nil }
        let audio = audioParams(for: eff)
        if audio != nil { hasAudio = true }
        // slot0 은 framebuffer → aux 는 slot1.. 디코드. 디코드 실패는 흰색 1x1 폴백.
        // 레거시 frag(mask=texture(1)) 와 waterripple(normal=1, mask=2) 모두 위해
        // 최소 2개 슬롯을 흰색으로 채워 미바인드 텍스처를 방지한다.
        var aux: [MTLTexture] = []
        // slot0=framebuffer 라 aux 는 index i+1 로 바인드 — 126개 캡(Metal 텍스처 인자테이블 128 상한).
        let auxNames = eff.textureNames.count > 1 ? Array(eff.textureNames[1...].prefix(126)) : []
        for name in auxNames {
            guard let t = resolveTexture(name, package: package, device: device) else { continue }
            aux.append(t)
        }
        while aux.count < 2, let white = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) {
            aux.append(white)
        }
        return EffectGPU(pipeline: pipe, bind: .handPort(params: params, aux: aux, audio: audio))
    }

    /// GLSL→MSL 변환 효과 빌드(멀티패스): effect.json 매니페스트(passes/fbos) → 패스별 셰이더 로드 →
    /// translate → 파이프라인 → 바인드 플랜. 어느 단계든 실패하면 nil(→ 손-포팅 폴백 → 스킵). 무회귀.
    /// 5책임 분해(2026-07-04, 동작 불변): ① 매니페스트 로드(loadEffectManifest) ② copy 명령 패스
    /// 합성(makeCopyPass) ③ 셰이더/머티리얼 메타 해석(resolvePassShaderMeta) ④ 콤보 해석
    /// (resolvePassCombos) ⑤ 머티리얼 상수/스크립트(buildPassMaterial) + 바인드·texRes·aux·target
    /// 플랜(buildPassBindings).
    func buildTranslatedEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice,
                               texW: Int, texH: Int) -> EffectGPU? {
        // 디버그 바이섹션 스위치: 실물 씬에서 번역 효과만 끄고 A/B 비교(시각 아티팩트 책임 분리).
        if ProcessInfo.processInfo.environment["WAPLE_DISABLE_TRANSLATED"] == "1" { return nil }
        // #include 리졸버: pkg→베이스에셋→내장(확정-의미 서브셋, common_blending.h) 순.
        let include: (String) -> String? = { header in
            for cand in ["shaders/\(header)", header] {
                if let d = self.quietAssetData(cand, package: package), let s = String(data: d, encoding: .utf8) { return s }
            }
            return BuiltinShaderIncludes.lookup(header)
        }
        let manifest = loadEffectManifest(eff, package: package)
        let fboIndex = Dictionary(uniqueKeysWithValues: manifest.fbos.enumerated().map { ($1.name, $0) })
        let lw = Float(max(1, texW)), lh = Float(max(1, texH))
        var passes: [TranslatedPass] = []
        var anyAudio = false
        for (i, mp) in manifest.passes.enumerated() {
            if mp.command == "copy" {
                guard let copy = makeCopyPass(mp, effName: eff.name, fboIndex: fboIndex,
                                              lw: lw, lh: lh, device: device) else { return nil }
                passes.append(copy)
                continue
            }
            let meta = resolvePassShaderMeta(mp, eff: eff, package: package)
            guard let vData = quietAssetData("shaders/\(meta.base).vert", package: package),
                  let fData = quietAssetData("shaders/\(meta.base).frag", package: package),
                  let vert = String(data: vData, encoding: .utf8),
                  let frag = String(data: fData, encoding: .utf8) else { return nil }
            let scenePass = i < eff.passList.count ? eff.passList[i] : SceneEffectPass()
            let combos = resolvePassCombos(frag: frag, scenePass: scenePass,
                                           matCombos: meta.matCombos, matTextures: meta.matTextures)
            guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos, include: include) else {
                NSLog("%@", "[Waple] GLSL translate failed: \(eff.name) pass \(i)")
                return nil
            }
            guard let pipe = translatedPipeline(msl: t.msl, device: device) else {
                NSLog("%@", "[Waple] translated MSL compile failed: \(eff.name) pass \(i)")
                return nil
            }
            let (material, passScripts) = buildPassMaterial(t, scenePass: scenePass)
            guard let plan = buildPassBindings(mp, effName: eff.name, translation: t, scenePass: scenePass,
                                               matTextures: meta.matTextures, manifest: manifest,
                                               fboIndex: fboIndex, lw: lw, lh: lh,
                                               package: package, device: device) else { return nil }
            if t.usesAudio { anyAudio = true }
            passes.append(TranslatedPass(pipeline: pipe, material: material, aux: plan.aux,
                                         binds: plan.binds, target: plan.target, usesAudio: t.usesAudio,
                                         texRes: plan.texRes, scripts: passScripts))
        }
        // 출력(타깃 없는 패스)이 하나도 없으면 화면에 아무것도 못 쓴다 → 폴백.
        guard passes.contains(where: { $0.target == nil }) else { return nil }
        if anyAudio { hasAudio = true }
        NSLog("%@", "[Waple] effect via GLSL→MSL translator: \(eff.name) (passes=\(passes.count) fbos=\(manifest.fbos.count) audio=\(anyAudio))")
        return EffectGPU(pipeline: passes[0].pipeline,
                         bind: .translated(passes: passes, fboScales: manifest.fbos.map { $0.scale }))
    }

    /// ① 매니페스트 로드: effect.json 이 없으면 관례 단일 패스("effects/<name>" 셰이더).
    private func loadEffectManifest(_ eff: SceneEffect, package: ScenePackage) -> EffectManifest {
        let effectJSONPath = eff.file.isEmpty ? "effects/\(eff.name)/effect.json" : eff.file
        if let d = quietAssetData(effectJSONPath, package: package), let m = EffectManifest.parse(d) {
            return m
        }
        return EffectManifest(passes: [.init(material: nil, shader: nil, target: nil, binds: [])], fbos: [])
    }

    /// ② 명령 패스(셰이더 없음): "copy" = source fbo → target fbo 지속(실물 motionblur 의 누적 버퍼).
    /// 통과(passthrough) 파이프라인으로 합성해 기존 멀티패스 실행 경로를 그대로 재사용(루프 무변경).
    /// 미해석 이름/파이프라인 실패 → nil(효과 전체 폴백).
    private func makeCopyPass(_ mp: EffectManifest.Pass, effName: String, fboIndex: [String: Int],
                              lw: Float, lh: Float, device: MTLDevice) -> TranslatedPass? {
        guard let srcName = mp.source, let srcIdx = fboIndex[srcName],
              let tgtName = mp.target, let tgtIdx = fboIndex[tgtName],
              let pipe = passthroughEffectPipeline(device: device) else {
            NSLog("%@", "[Waple] unresolved copy pass in \(effName)"); return nil
        }
        let dims = SIMD4<Float>(lw, lh, lw, lh)
        return TranslatedPass(pipeline: pipe, material: [], aux: [],
                              binds: [(0, srcIdx)], target: tgtIdx, usesAudio: false,
                              texRes: [SIMD4<Float>](repeating: dims, count: 8), scripts: [])
    }

    /// ③ 셰이더 이름 + 머티리얼 메타(combos/textures) 해석 — 패스에 shader 가 없으면 material JSON
    /// (passes[0])에서, 그마저 없으면 관례 "effects/<name>".
    private func resolvePassShaderMeta(_ mp: EffectManifest.Pass, eff: SceneEffect, package: ScenePackage)
        -> (base: String, matCombos: [String: Int], matTextures: [String?]) {
        var shaderName = mp.shader
        var matCombos: [String: Int] = [:]
        var matTextures: [String?] = []
        if shaderName == nil, let matPath = mp.material,
           let mData = quietAssetData(matPath, package: package),
           let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any],
           let mp0 = (mjson["passes"] as? [Any])?.first as? [String: Any] {
            shaderName = mp0["shader"] as? String
            for (k, v) in (mp0["combos"] as? [String: Any]) ?? [:] {
                if let n = v as? Int { matCombos[k] = n }
                else if let d = v as? Double { matCombos[k] = Int(d) }
            }
            if let texs = mp0["textures"] as? [Any] { matTextures = texs.map { $0 as? String } }
        }
        return (shaderName ?? "effects/\(eff.name)", matCombos, matTextures)
    }

    /// ④ 콤보 해석. 우선순위: 머티리얼 기본 < scene 패스 지정.
    /// WE 규약: 샘플러 주석의 "combo":"X" 는 그 슬롯에 텍스처가 바인딩되면 자동 활성
    /// (실물 reflection/waterwaves/shake 의 페인트 마스크 — 미적용 시 마스크 무시 = 전화면 적용 사고).
    private func resolvePassCombos(frag: String, scenePass: SceneEffectPass,
                                   matCombos: [String: Int], matTextures: [String?]) -> [String: Int] {
        var combos = matCombos
        for (k, v) in scenePass.combos { combos[k] = v }
        for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
            let sceneBound = slot < scenePass.textureNames.count && scenePass.textureNames[slot] != nil
            let matBound = slot < matTextures.count && matTextures[slot] != nil
            if sceneBound || matBound { combos[comboName] = 1 }
        }
        return combos
    }

    /// ⑤a 머티리얼 상수 벡터 + 상수 프로퍼티 스크립트 엔진(시간 함수 → 연속 렌더 필요 마킹).
    private func buildPassMaterial(_ t: TranslatedShader, scenePass: SceneEffectPass)
        -> (material: [SIMD4<Float>], scripts: [(slot: Int, engine: TextScriptEngine)]) {
        let constants = scenePass.constants
        let material: [SIMD4<Float>] = t.materialParams.map { p in
            let v = constants[p.sceneKey] ?? p.defaultValue
            return SIMD4<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0,
                                v.count > 2 ? v[2] : 0, v.count > 3 ? v[3] : 0)
        }
        var passScripts: [(slot: Int, engine: TextScriptEngine)] = []
        for (slot, p) in t.materialParams.enumerated() {
            if let src = scenePass.constantScripts[p.sceneKey], let engine = makeScriptEngine(src) {
                passScripts.append((slot, engine))
                if engine.hasUpdate { hasAnimations = true }  // 스크립트 상수는 시간 함수 — 연속 렌더 필요
            }
        }
        return (material, passScripts)
    }

    /// ⑤b 바인드/texRes/aux/target 플랜. 미지 바인드·타깃 이름 → nil(효과 전체 폴백).
    /// 바인드: previous → -1, 이름 → fbo 인덱스. 부재 시 관례 previous@0.
    /// texRes + 정적 aux: 바인드 슬롯은 소스 dims(fbo = 레이어/scale), 그 외 선언 슬롯은 텍스처 해석.
    /// WE 규약: g_TextureXResolution = (paddedW, paddedH, imageW, imageH) — .zw 는 역수가 아니라 실치수
    /// (gaussian 등이 g_Scale/…Resolution.z 로 텍셀 오프셋 계산; 역수면 오프셋 폭주 → 화면 백화).
    private func buildPassBindings(_ mp: EffectManifest.Pass, effName: String, translation t: TranslatedShader,
                                   scenePass: SceneEffectPass, matTextures: [String?],
                                   manifest: EffectManifest, fboIndex: [String: Int],
                                   lw: Float, lh: Float, package: ScenePackage, device: MTLDevice)
        -> (binds: [(slot: Int, source: Int)], texRes: [SIMD4<Float>], aux: [(slot: Int, tex: MTLTexture)], target: Int?)? {
        var binds: [(slot: Int, source: Int)] = []
        for b in mp.binds {
            // 신뢰불가 effect.json index — Metal frag 텍스처 인자테이블 상한(macOS 128) 밖이면
            // setFragmentTexture assertion 크래시. 미지 바인드와 동일하게 효과 전체 폴백.
            guard (0..<128).contains(b.index) else {
                NSLog("%@", "[Waple] bind index oob \(b.index) in \(effName)"); return nil
            }
            if b.name == "previous" { binds.append((b.index, -1)) }
            else if let idx = fboIndex[b.name] { binds.append((b.index, idx)) }
            else { NSLog("%@", "[Waple] unknown bind '\(b.name)' in \(effName)"); return nil }
        }
        if binds.isEmpty { binds = [(0, -1)] }
        let bindSlots = Set(binds.map { $0.slot })
        var texRes = [SIMD4<Float>](repeating: SIMD4(lw, lh, lw, lh), count: 8)
        for (slot, source) in binds where slot < 8 && source >= 0 {
            let s = Float(manifest.fbos[source].scale)
            texRes[slot] = SIMD4(lw / s, lh / s, lw / s, lh / s)
        }
        var aux: [(slot: Int, tex: MTLTexture)] = []
        for slot in t.textureSlots where slot > 0 && slot < 128 && !bindSlots.contains(slot) {
            var name = slot < scenePass.textureNames.count ? scenePass.textureNames[slot] : nil
            if name == nil, slot < matTextures.count { name = matTextures[slot] }
            if let n = name, n.hasPrefix("_rt_") { continue }
            if let tex = resolveTexture(name, package: package, device: device) {
                aux.append((slot, tex))
                if slot < 8 {
                    let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                    texRes[slot] = SIMD4(w, h, w, h)
                }
            }
        }
        let target: Int? = mp.target.flatMap { fboIndex[$0] }
        if mp.target != nil && target == nil { NSLog("%@", "[Waple] unknown target in \(effName)"); return nil }
        return (binds, texRes, aux, target)
    }

    /// assetData 의 조용한 버전: pkg→베이스에셋 조회하되 미스에 로그 없음(소스 프로브는 미스가 정상).
    func quietAssetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = packageData(name, package: package) { return d }
        if let base = assetBaseDir, let url = baseAssetURL(for: name, root: base) { return try? Data(contentsOf: url) }
        return nil
    }

    private func packageData(_ name: String, package: ScenePackage) -> Data? {
        if let d = package.data(for: name) { return d }
        guard let e = package.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        return package.data(for: e.name)
    }

    private func baseAssetURL(for name: String, root: URL) -> URL? {
        guard let path = WallpaperPathSecurity.normalizedRelativePath(name) else { return nil }
        if let exact = WallpaperPathSecurity.containedFileURL(path, root: root),
           FileManager.default.fileExists(atPath: exact.path) {
            return exact
        }
        let rootURL = root.standardizedFileURL
        var current = rootURL
        for part in path.split(separator: "/").map(String.init) {
            guard let children = try? FileManager.default.contentsOfDirectory(at: current,
                                                                              includingPropertiesForKeys: nil),
                  let match = children.first(where: {
                      $0.lastPathComponent.caseInsensitiveCompare(part) == .orderedSame
                  }) else { return nil }
            current = match.standardizedFileURL
            guard WallpaperPathSecurity.contains(current, in: rootURL) else { return nil }
        }
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let realCurrent = current.resolvingSymlinksInPath().standardizedFileURL
        guard WallpaperPathSecurity.contains(realCurrent, in: realRoot) else { return nil }
        return current
    }

    /// 변환 효과 파이프라인. 정점 디스크립터: a_Position float3@0, a_TexCoord float2@12, stride 20,
    /// 버퍼 인덱스 4(p=buffer0 / eng=buffer1 와 충돌 회피 — 스파이크 증명 규약).
    /// command=copy 패스용 통과 파이프라인(g_Texture0 을 그대로 target 에 기록). translated 실행 규약과
    /// 동일한 버텍스 디스크립터/버퍼 인덱스를 쓰도록 GLSL 통과 셰이더를 번역해 캐시.

    func passthroughEffectPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        if let p = _passthroughPipeline { return p }
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
        guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]),
              let p = translatedPipeline(msl: t.msl, device: device) else { return nil }
        _passthroughPipeline = p
        return p
    }

    func translatedPipeline(msl: String, device: MTLDevice) -> MTLRenderPipelineState? {
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: msl, options: nil)
        } catch {
            // 실패 원인 진단용: 첫 에러 줄만(대개 undefined identifier = common.h 함수 부재).
            let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
            NSLog("%@", "[Waple] translated MSL compile error: \(first)")
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
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    /// 효과 보조 텍스처 슬롯 이름 → MTLTexture. 이름 nil/디코드 실패 → 흰색 1x1 폴백
    /// (마스크는 흰색=효과 전체 적용, 노멀맵은 흰색=무왜곡에 가까움).
    /// "effects/X"/"masks/X" 같은 상대 이름은 "materials/<name>.tex" 로 해석, raw 이름도 시도.
    func resolveTexture(_ name: String?, package: ScenePackage, device: MTLDevice) -> MTLTexture? {
        resolveTextureWithFrames(name, package: package, device: device)?.texture
    }

    /// 텍스처 + 스프라이트시트 프레임(TEXS). 파티클이 프레임 UV 서브렉트에 사용(레이어는 texture 만).
    func resolveTextureWithFrames(_ name: String?, package: ScenePackage, device: MTLDevice)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        if let name {
            let cand = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if let d = assetData(cand, package: package) ?? assetData(name, package: package),
               let tex = TexImage.parse(d) {
                // 다중 image = 아틀라스 페이지: 세로로 이어붙인 단일 텍스처 + frame.y 페이지 오프셋(아래 헬퍼).
                let multipage = tex.imageCount > 1
                if multipage, !tex.frames.isEmpty,
                   let stacked = stackedAtlas(tex: tex, data: d, device: device) { return stacked }
                // 조건 변형(예 3D 모델 튜닉색): variantProperties 로 mip 선택. 비-변형은 기존 경로 그대로.
                if let dec = TexDecoder.rgba(from: tex, data: d, properties: variantProperties),
                   let m = makeTexture(dec.pixels, dec.width, dec.height, device) {
                    // 멀티페이지인데 stackedAtlas 실패(스택 높이>16384 등) → 프레임 좌표가 페이지-상대라 그대로
                    // 쓰면 imageId≥1 프레임이 page0 좌표를 읽는 **조용한 오프레임**. frames=[] 로 정지 폴백
                    // (page 0 표시)해 "틀린 애니" 대신 "정지"로 명예로운 실패(advisor). 단일 image 는 frames
                    // 정상(전부 id0, 오프셋 무관). 영향 실측 6씬(3379048027 7페이지/420프레임 sumH 52920,
                    // 3363252053·3448877775 7페이지, 3577990983 5페이지, 3000562427 day/night 3페이지).
                    // ponytail: 진짜 고침 = 페이지별 텍스처 또는 온디맨드 프레임 스트리밍(초대형 시트 ~1.7GB) — 재설계.
                    return (m, multipage ? [] : tex.frames)
                }
            }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map { ($0, []) }
    }

    /// 다중 image 아틀라스 페이지를 **세로로 이어붙인 단일 텍스처**로 합치고 frame.y 에 페이지별 누적
    /// y-오프셋을 더한다(frame.imageId = 페이지). GPUParticleSystem/GPULayer.texture 단일 유지 → 프레임
    /// 인코더/blit 무변경. 실측(2026-07-10, 코퍼스 멀티페이지 7종): 페이지 dims 가 **불균일**하다(예
    /// 鸟_00020: page0 7680×7920, page1 5760×2880) — 종전 same-dims 가드는 여기서 nil 폴백해 page1
    /// 프레임을 오프셋 없이(atlasY=0) 렌더했다(조용한 오프레임 — advisor #1). 이제 max-width × sum-height
    /// 로 패딩 스택하고 각 페이지를 (0, 누적y)에 행-복사한다. **균일 페이지는 종전과 byte-identical 배치**
    /// (maxW=pw, 누적y=page*ph) → 파티클 무회귀. 스택 높이/폭이 Metal 한계(16384) 초과면 nil → 호출자가
    /// 정지 폴백(frames=[], 조용한 오프레임 대신 명예로운 정지). **디코드 전 조기 거부**: 패딩 decodeHeight
    /// 합으로 먼저 검사해 초대형 시트(7페이지 sumH 52920 등, 1.7GB)의 무의미한 전-페이지 디코드를 회피.
    /// 레이어/파티클 공용(resolveTextureWithFrames). ponytail: 텍스처 배열 대신 패딩 세로 스택(폭 작은
    /// 페이지 우측 패딩은 UV 밖이라 무해). 16384 초과 시트의 진짜 고침 = 페이지별 텍스처/온디맨드 스트리밍(재설계).
    private func stackedAtlas(tex: TexImage, data: Data, device: MTLDevice)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        // 조기 거부(디코드 전): 패딩 decodeHeight 합 = 스택 높이 상한(실제 크롭 후는 ≤). 초과면 초대형
        // 디코드 착수 전 nil. decodeWidth/Height 는 무경계 UInt32 유래라 오버플로도 함께 차단.
        let padH = tex.mips.reduce(0) { $0 + $1.decodeHeight }
        let padW = tex.mips.map { $0.decodeWidth }.max() ?? 0
        guard padW > 0, padH > 0, padW <= 16384, padH <= 16384 else { return nil }
        var pages: [(pixels: Data, width: Int, height: Int)] = []
        for i in 0..<tex.imageCount {
            guard let p = TexDecoder.rgba(from: tex, data: data, imageIndex: i) else { return nil }
            pages.append(p)
        }
        guard !pages.isEmpty else { return nil }
        let maxW = pages.map { $0.width }.max() ?? 0
        let totalH = pages.map { $0.height }.reduce(0, +)
        guard maxW > 0, totalH > 0, maxW <= 16384, totalH <= 16384 else { return nil }  // 실제 크롭 후 재확인(방어)
        var yOff: [Int] = []; var cy = 0                     // 페이지별 누적 y(균일이면 page*ph)
        for p in pages { yOff.append(cy); cy += p.height }
        var stacked = Data(count: maxW * totalH * 4)          // 제로 버퍼(폭 작은 페이지 우측은 0 잔존)
        stacked.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress else { return }
            for (i, p) in pages.enumerated() {
                p.pixels.withUnsafeBytes { srcRaw in
                    guard let src = srcRaw.baseAddress else { return }
                    let rowBytes = p.width * 4
                    for row in 0..<p.height {                  // 행 단위 복사(불균일 폭 → dst stride=maxW)
                        memcpy(dst + ((yOff[i] + row) * maxW) * 4, src + row * rowBytes, rowBytes)
                    }
                }
            }
        }
        let adjusted = tex.frames.map { fr -> TexImage.TexFrame in
            let page = max(0, min(pages.count - 1, fr.imageId))   // imageId = 페이지 인덱스(범위 클램프)
            return TexImage.TexFrame(imageId: fr.imageId, time: fr.time, x: fr.x, y: fr.y + Float(yOff[page]),
                                     width: fr.width, height: fr.height, widthY: fr.widthY, heightX: fr.heightX)
        }
        guard let m = makeTexture(stacked, maxW, totalH, device) else { return nil }
        return (m, adjusted)
    }

    /// 효과의 AUDIOPROCESSING 콤보 + 오디오 상수 → AudioParams(없으면 nil). draw 시 audioResponse 계산에 사용.
    func audioParams(for eff: SceneEffect) -> AudioParams? {
        let mode = eff.audioMode
        guard mode >= 1, mode <= 3 else { return nil }
        let c = eff.constants
        let bounds = c["audiobounds"] ?? [0.5, 1.0]
        return AudioParams(
            mode: mode,
            freqMin: c["frequencymin"]?.first ?? 0,
            freqMax: c["frequencymax"]?.first ?? 15,
            bounds: SIMD2<Float>(bounds.count > 0 ? bounds[0] : 0.5, bounds.count > 1 ? bounds[1] : 1.0),
            power: c["audioexponent"]?.first ?? 1,
            multiply: c["audioamount"]?.first ?? 1)
    }

    /// 파티클 시스템별 텍스처/시뮬/블렌드 준비. 텍스처는 material 의 첫 텍스처(없으면 흰색 폴백).
    /// 자식 링크는 부모 직후에 자체 머티리얼의 GPU 시스템으로 추가(드로우는 부모 sim.childDisplay).
    func buildParticles(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUParticleSystem] {
        var out: [GPUParticleSystem] = []
        func makeSystem(def: ParticleSystemDef, seed: UInt64, sp: SceneParticle,
                        childOf: (parent: Int, link: Int)? = nil) -> GPUParticleSystem? {
            guard let (tex, frames) = resolveTextureWithFrames(def.material?.textureName,
                                                               package: package, device: device) else { return nil }
            let mirror = def.initializers.contains {
                if case .mapSequence(_, true, _) = $0 { return true }; return false
            }
            return GPUParticleSystem(
                sim: ParticleSimulator(def: def, seed: seed), def: def, seed: seed,
                texture: tex, blendAdditive: def.material?.blend == .additive,
                origin: SIMD2<Float>(sp.origin.x, sp.origin.y),
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y),
                texRatio: Float(tex.height) / Float(max(1, tex.width)), order: sp.order,
                isTrail: def.renderer.isTrail, childOf: childOf,
                frames: frames, mapSeqMirror: mirror)
        }
        for (i, sp) in doc.particles.enumerated() {
            let seed = UInt64(0x9E37_79B9_7F4A_7C15 &+ UInt64(i))
            guard let parent = makeSystem(def: sp.def, seed: seed, sp: sp) else { continue }
            let parentIdx = out.count
            out.append(parent)
            for (li, link) in sp.def.children.enumerated() {
                if let child = makeSystem(def: link.def, seed: seed &+ UInt64(li) &+ 1, sp: sp,
                                          childOf: (parent: parentIdx, link: li)) {
                    out.append(child)
                }
            }
        }
        return out
    }

    /// 파티클 파이프라인. frag 가 premultiplied-alpha 출력 → src=one.
    /// additive: dst=one(가산), translucent: dst=oneMinusSrcAlpha(일반 over).
    func particlePipeline(additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: ParticleShaders.source, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    func makeOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    /// 헤드리스 캡처용 bgra8 타겟(라이브 파이프라인과 동일 포맷, getBytes 가능하도록 .shared).
    func makeOffscreenBGRA(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    func makeTexture(_ rgba: Data, _ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { ptr in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }

    private func bitmapRGBAFile(_ path: String) -> (pixels: Data, width: Int, height: Int)? {
        guard path.hasPrefix("/"),
              let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (Data(pixels), width, height)
    }

    /// 텍스트 오브젝트 준비: 폰트 바이트(pkg→base-assets) + 스크립트 엔진 + 초기 텍스트 래스터.
    func buildTexts(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUText] {
        var out: [GPUText] = []
        for t in doc.texts {
            let isSystem = t.font.hasPrefix("systemfont_") || t.font.isEmpty
            let fontData = isSystem ? nil : quietAssetData(t.font, package: package)
            if !isSystem && fontData == nil { NSLog("%@", "[Waple] text font missing (system fallback): \(t.font)") }
            // 씬 공유 컨텍스트 로드(top-level 사이드이펙트 실행). update 없는 스크립트는 텍스트 갱신에
            // 못 쓰므로 엔진 nil 취급(정적 텍스트 유지) — 로드 자체는 shared 통신을 위해 수행.
            let loaded = t.script.flatMap { makeScriptEngine($0, layerName: t.name.isEmpty ? nil : t.name) }
            if t.script != nil && loaded == nil { NSLog("%@", "[Waple] text script failed to load (empty text): \(t.script!.prefix(60))") }
            let engine = (loaded?.hasUpdate == true) ? loaded : nil
            let initial = engine != nil ? (engine!.evaluate(current: t.text) ?? "") : t.text
            var g = GPUText(texture: nil, vertexBuffer: nil,
                            tint: SIMD4(t.color.x, t.color.y, t.color.z, t.alpha),
                            order: t.order, engine: engine, lastText: initial,
                            fontData: fontData, systemFontName: isSystem ? t.font : nil, def: t)
            rasterize(&g, device: device)
            if engine != nil { hasScriptedText = true }
            out.append(g)
        }
        return out
    }

    /// 텍스트 재래스터: lastText → 텍스처 + 앵커 정렬 쿼드. 빈 텍스트 → 텍스처 nil(드로우 스킵).
    func rasterize(_ g: inout GPUText, device: MTLDevice) {
        guard let r = TextRasterizer.render(text: g.lastText, fontData: g.fontData,
                                            systemFontName: g.systemFontName, pointSize: g.def.pointSize) else {
            g.texture = nil; g.vertexBuffer = nil
            return
        }
        g.texture = makeTexture(r.rgba, r.width, r.height, device)
        let w = Float(r.width) * g.def.scale.x, h = Float(r.height) * g.def.scale.y
        let x0: Float
        switch g.def.horizontalAlign {
        case "left": x0 = g.def.origin.x
        case "right": x0 = g.def.origin.x - w
        default: x0 = g.def.origin.x - w / 2
        }
        let y0: Float
        switch g.def.verticalAlign {
        case "top": y0 = g.def.origin.y
        case "bottom": y0 = g.def.origin.y - h
        default: y0 = g.def.origin.y - h / 2
        }
        let tl = sceneToNDC(x0, y0), tr = sceneToNDC(x0 + w, y0)
        let br = sceneToNDC(x0 + w, y0 + h), bl = sceneToNDC(x0, y0 + h)
        let verts: [SIMD4<Float>] = [
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(tr.x, tr.y, 1, 0), SIMD4(br.x, br.y, 1, 1),
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(br.x, br.y, 1, 1), SIMD4(bl.x, bl.y, 0, 1),
        ]
        g.vertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count)
    }
}
