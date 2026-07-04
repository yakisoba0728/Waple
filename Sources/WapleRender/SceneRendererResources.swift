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
        return nil
    }

    /// 텍스처/에셋 바이트 로드: 패키지 우선, 없으면 공유 기본 에셋 디렉터리에서 폴백.
    /// 공유에서 찾거나 둘 다 없을 때만 로그(in-pkg 일반 경로는 조용히).
    func assetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = package.data(for: name) { return d }
        if let base = assetBaseDir {
            let u = base.appendingPathComponent(name)
            if let d = try? Data(contentsOf: u) {
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
            let decoded: (pixels: Data, width: Int, height: Int)
            if layer.textureEntryName.isEmpty {  // 솔리드/컴포지션 placeholder
                decoded = (Data([255, 255, 255, 255]), 1, 1)
            } else if let texData = assetData(layer.textureEntryName, package: package),
                      let tex = TexImage.parse(texData),
                      let d = TexDecoder.rgba(from: tex, data: texData) {
                decoded = d
            } else { continue }
            guard let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { continue }
            // 컴포지션 레이어의 효과 dims 는 화면(프로젝션) 근사 — 실제 src 는 draw 시 스냅샷.
            let effW = layer.isFrameBuffer ? Int(max(1, projW)) : decoded.width
            let effH = layer.isFrameBuffer ? Int(max(1, projH)) : decoded.height
            let verts = quadVertices(layer: layer, projW: w, projH: h)
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
            // 퍼펫(.mdl): 스키닝 메시 — 로드 실패 시 정지 쿼드 폴백(로그).
            var puppetModel: PuppetModel? = nil
            if let pp = layer.puppet {
                if let bytes = assetData(pp, package: package), let pm = PuppetModel.parse(bytes) {
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
                if let e = makeScriptEngine(src) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, uid: uid, isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                initialVisible: layer.initialVisible))
        }
        return out
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
        let auxNames = eff.textureNames.count > 1 ? Array(eff.textureNames[1...]) : []
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
        for slot in t.textureSlots where slot > 0 && !bindSlots.contains(slot) {
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
        if let d = package.data(for: name) { return d }
        if let base = assetBaseDir { return try? Data(contentsOf: base.appendingPathComponent(name)) }
        return nil
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
        if let name {
            let cand = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if let d = assetData(cand, package: package) ?? assetData(name, package: package),
               let tex = TexImage.parse(d), let dec = TexDecoder.rgba(from: tex, data: d),
               let m = makeTexture(dec.pixels, dec.width, dec.height, device) { return m }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
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
    func buildParticles(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUParticleSystem] {
        var out: [GPUParticleSystem] = []
        for (i, sp) in doc.particles.enumerated() {
            let tex = resolveTexture(sp.def.material?.textureName, package: package, device: device)
                ?? makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
            guard let tex else { continue }
            let ratio = Float(tex.height) / Float(max(1, tex.width))
            let seed = UInt64(0x9E37_79B9_7F4A_7C15 &+ UInt64(i))
            out.append(GPUParticleSystem(
                sim: ParticleSimulator(def: sp.def, seed: seed), def: sp.def, seed: seed,
                texture: tex, blendAdditive: sp.def.material?.blend == .additive,
                origin: SIMD2<Float>(sp.origin.x, sp.origin.y),
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y), texRatio: ratio, order: sp.order,
                isTrail: sp.def.renderer.isTrail))
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

    /// 텍스트 오브젝트 준비: 폰트 바이트(pkg→base-assets) + 스크립트 엔진 + 초기 텍스트 래스터.
    func buildTexts(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUText] {
        var out: [GPUText] = []
        for t in doc.texts {
            let isSystem = t.font.hasPrefix("systemfont_") || t.font.isEmpty
            let fontData = isSystem ? nil : quietAssetData(t.font, package: package)
            if !isSystem && fontData == nil { NSLog("%@", "[Waple] text font missing (system fallback): \(t.font)") }
            // 씬 공유 컨텍스트 로드(top-level 사이드이펙트 실행). update 없는 스크립트는 텍스트 갱신에
            // 못 쓰므로 엔진 nil 취급(정적 텍스트 유지) — 로드 자체는 shared 통신을 위해 수행.
            let loaded = t.script.flatMap { makeScriptEngine($0) }
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
