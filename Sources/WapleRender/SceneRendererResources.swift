import AppKit
import MetalKit
import simd
import WapleCore

// SceneRenderer 리소스 빌더(갓클래스 3분할 ①, 2026-07-04 — 코드 이동 + private→internal 만, 로직 무변경):
// mount 시 GPU 리소스화 경로 — 에셋 로드(pkg → base-assets 폴백), 레이어/효과(손-포팅·GLSL 번역)/
// 파티클/텍스트 빌드, 텍스처·파이프라인 팩토리. per-frame 인코딩은 SceneRendererFrameEncoder.swift,
// 3D 서브시스템은 SceneRenderer3D.swift 참조.
extension SceneRenderer {
    private enum BaseAssetURLProbe {
        case url(URL)
        case missing
        case rejected
    }

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
        /// 슬롯별(0..7, texRes 와 동일 상한) 샘플러 어드레싱(F162/F163): 1=clamp/0=repeat.
        /// bind(fbo/previous, 자산 없음) 슬롯은 항상 clamp, aux(실 자산) 슬롯은 TexImage.clampUVs —
        /// buildPassBindings 가 빌드 시 1 회 계산(런타임 재계산 불요 — 자산 정체성은 패스 고정).
        let texWrap: [Float]
        /// 감사 V07: 슬롯별 샘플 필터(1=nearest/0=linear — TexImage.noInterpolation, WE tex Flags bit0).
        /// bind 슬롯은 선형(단, 체인 첫 이펙트의 previous=베이스 직결은 baseNoInterp — 손-포팅 fbNearest
        /// 의 V06 정합과 동일), aux 슬롯은 자산 플래그. texWrap 과 동일하게 빌드 시 1 회 계산.
        let texFilter: [Float]
        /// 상수 프로퍼티 스크립트(슬롯 → 엔진) — per-frame 평가로 material 갱신(컬러 사이클 등).
        var scripts: [(slot: Int, engine: TextScriptEngine)] = []
        /// F-X4: `_rt_FullFrameBuffer` 어노테이션/텍스처명을 가진 aux 슬롯 — 빌드 시점엔 흰색 1×1 로
        /// 채워두고(무회귀 폴백), 씬 컬러 스냅샷을 확보한 호출부(runFrameBufferLayer 등)만 draw 시점에
        /// applyEffect(fullFrameSnapshot:) 로 실제 배경을 덮어 바인드한다(godrays/shine COPYBG).
        let fullFrameSlots: [Int]
        /// X-②: command:"swap"(셰이더 없음, 실물 fluidsimulation velocity/dye 더블버퍼) — non-nil 이면
        /// draw 를 건너뛰고 fboTex.swapAt(source,target) 만 수행(무비용 핑퐁). pipeline 은 미사용 placeholder.
        let swapPair: (source: Int, target: Int)?
    }
    /// X-①: 이름 있는 FBO 1개의 할당 스펙 — scale(dst 비례) 또는 fixedWidth/fixedHeight(절대 픽셀,
    /// 실물 cursorripple fit:512·glitter width/height:256) 중 후자가 있으면 우선.
    struct FBOSpec { let scale: Int; let fixedWidth: Int?; let fixedHeight: Int? }
    enum EffectBind {
        case handPort(params: [Float], aux: [MTLTexture], audio: AudioParams?)
        case translated(passes: [TranslatedPass], fboSpecs: [FBOSpec])
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
        guard case .data(let data) = probeAssetData(name, package: package) else {
            return nil
        }
        return data
    }

    private func probeAssetData(_ name: String, package: ScenePackage) -> SharedAssetProbeResult {
        if let d = packageData(name, package: package) { return .data(d) }
        guard WallpaperPathSecurity.normalizedRelativePath(name) != nil else {
            NSLog("%@", "[Waple] rejected shared asset path: \(name)")
            return .rejected
        }
        if let base = assetBaseDir {
            switch baseAssetURLProbe(for: name, root: base) {
            case .url(let url):
                if let d = try? Data(contentsOf: url) {
                    NSLog("%@", "[Waple] asset from shared base: \(name)")
                    return .data(d)
                }
            case .rejected:
                NSLog("%@", "[Waple] rejected shared asset path: \(name)")
                return .rejected
            case .missing:
                break
            }
        }
        NSLog("%@", "[Waple] asset missing (pkg+shared): \(name)")
        return .missing
    }

    func resolveRequiredAsset<T>(
        _ candidates: [String],
        package: ScenePackage,
        decode: (Data) -> T?,
        alternate: () -> T? = { nil }
    ) -> T? {
        var foundBytes = false
        var rejected = false
        for candidate in candidates {
            switch probeAssetData(candidate, package: package) {
            case .data(let data):
                foundBytes = true
                if let value = decode(data) { return value }
            case .missing:
                break
            case .rejected:
                rejected = true
            }
        }
        if let value = alternate() { return value }
        guard !foundBytes,
              !rejected,
              !candidates.isEmpty,
              candidates.allSatisfy({ WallpaperPathSecurity.normalizedRelativePath($0) != nil }) else {
            return nil
        }
        markMissingRequiredSharedAsset()
        return nil
    }

    /// 레이어의 텍스처가 video-.tex 면 내장 MP4 를 추출(레이어별 고유 캐시키 — 한 씬 다중 video 대비)해
    /// SceneVideoLayer 공급자를 만든다. 비디오 아니거나 추출 실패(LZ4-mp4 등)면 nil → 호출부는 일반 이미지
    /// 경로로 폴백(video 페이로드는 TexDecoder.rgba 가 nil → 레이어 스킵, 형제 보존).
    func videoLayerProvider(_ layer: SceneLayer, package: ScenePackage, sceneID: String, index: Int) -> SceneVideoLayer? {
        guard let data = package.data(for: layer.textureEntryName),
              let tex = TexImage.parse(data), tex.payload == .video,
              let mp4 = VideoTextureExtractor.extractMP4(
                textureEntryName: layer.textureEntryName, package: package, sceneID: sceneID,
                cacheKey: "\(sceneID)_\(index)", cacheDir: VideoTextureExtractor.defaultCacheDir())
        else { return nil }
        return SceneVideoLayer(mp4URL: mp4)
    }

    /// 레이어/텍스트 공용 이펙트 체인 빌드(F741: buildLayers 루프에서 무수정 추출 — 정책 단일화).
    /// 디버그: WAPLE_EFFECT_SKIP=이름,이름 → 해당 효과 제외(파리티 이분용, WAPLE_MP_TRUNC 와 세트).
    /// baseNoInterp(감사 V06): 베이스 텍스처의 NoInterpolation — **체인 첫** 손-포팅 이펙트의 fb 만
    /// nearest(fb=베이스 직결은 첫 이펙트뿐, 2번째+ 는 FBO 출력이라 선형 유지가 WE 정합).
    func buildEffectChain(_ sceneEffects: [SceneEffect], package: ScenePackage, device: MTLDevice,
                          texW: Int, texH: Int, compositeImageTextures: [Int: String] = [:],
                          baseNoInterp: Bool = false) -> [EffectGPU] {
        var effects: [EffectGPU] = []
        let skipNames = Set((ProcessInfo.processInfo.environment["WAPLE_EFFECT_SKIP"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for eff in sceneEffects {
            // F201 후속: parseEffects 는 visible={value:false,script} 이펙트도 SceneEffect[] 에
            // 보존한다(데이터 무손실 — 향후 per-frame 런타임 토글 소비용). 그러나 그 소비(스크립트
            // 재평가로 켜고 끄는 경로)가 아직 배선되지 않아, 여기서 그대로 태우면 "항상 미적용"이던
            // 구 동작이 "항상 적용"으로 뒤집혀 실 코퍼스 17씬(예 2902406982·3113287126·3538758087)의
            // 이벤트-훅 이펙트가 잘못 켜진다(구 드롭 동작이 우연히 WE 정적 상태 OFF와 일치했었다).
            // 소비 배선 전까지는 initialVisible==false 인 이펙트를 여기서 게이트해 구 시각 거동을
            // 복원 — 파스 구조체엔 그대로 남아 있으니 향후 이 한 줄만 지우면 소비가 열린다.
            if !eff.initialVisible { continue }
            if skipNames.contains(eff.name) { continue }
            // 폴터 체인(Step 5, 2026-07-02 실물 검증 후 전환): **translated 우선** — pkg 동봉 GLSL 은
            // 실제 WE 셰이더라 손-포팅 근사보다 항상 정확(실측: 근사 shake 가 5중 체인에서 과대 팬).
            // GLSL 부재/번역·컴파일 실패 시 손-포팅(스톡 7종) 폴터 → 둘 다 실패 시 스킵+로그.
            if let translated = buildTranslatedEffect(eff, package: package, device: device,
                                                      texW: texW, texH: texH,
                                                      compositeImageTextures: compositeImageTextures,
                                                      // 감사 V07: 베이스 NoInterpolation 은 체인 첫 이펙트의
                                                      // previous(=베이스 직결)만 nearest(아래 fbNearest 와 동일 게이트).
                                                      baseNoInterp: baseNoInterp && effects.isEmpty) {
                effects.append(translated)
            } else if let handPort = buildHandPortEffect(eff, package: package, device: device,
                                                         fbNearest: baseNoInterp && effects.isEmpty) {
                effects.append(handPort)
            } else {
                NSLog("%@", "[Waple] effect skipped (no translatable GLSL, no hand-port): \(eff.name)")
            }
        }
        return effects
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice, sceneID: String) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        // attachment 자식들이 공유하는 부모 퍼펫 캐시(경로→파스 결과, 실패도 캐시 — 재파스 방지).
        var attachPuppets: [String: PuppetModel?] = [:]
        // F720: `_rt_imageLayerComposite_<id>` 정적 치환 맵(레이어 id → 베이스 이미지 텍스처) —
        // 3D 경로(SceneRenderer3D.build3D)와 동일 규약. 효과 슬롯 바인드(buildPassBindings)가 소비.
        let compositeImageTextures = doc.layers.reduce(into: [Int: String]()) { acc, layer in
            guard layer.id != 0, !layer.textureEntryName.isEmpty else { return }
            acc[layer.id] = layer.textureEntryName
        }
        for (uid, layer) in doc.layers.enumerated() {
            // 솔리드 마커(""): 무텍스처 flat 머티리얼 → 흰색 1x1 — 기존 tint 경로(color×brightness, alpha)가 필을 만든다.
            // 컴포지션(_rt_) 레이어: 텍스처는 런타임 스냅샷 — 여기선 placeholder + 효과 dims 를 프로젝션으로 근사
            // (효과 texRes 는 주로 텍셀 오프셋 용도; 화면 크기는 draw 시 결정 — 설계 §3).
            // 텍스처 + (스프라이트시트면) TEXS 프레임. effW/effH = 효과 dst 크기(스프라이트는 프레임 dims —
            // 효과는 시트가 아니라 프레임 1장에 적용, buildDisplayTextures 가 프레임 추출 후 체인).
            let mtl: MTLTexture
            let effW: Int, effH: Int
            var frames: [TexImage.TexFrame] = []
            var videoLayer: SceneVideoLayer? = nil   // 비디오-텍스처 레이어면 프레임 공급자(그 외 nil)
            if layer.textureEntryName.isEmpty {  // 솔리드/컴포지션 placeholder
                guard let t = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) else { continue }
                mtl = t
                // 컴포지션 효과 dims 는 화면 근사, 솔리드는 레이어 크기 — 1×1 이면 공간 가변 효과
                // (waterwaves/scroll 등) 체인 전체가 1픽셀 타깃으로 퇴화(단색화).
                // F530: 거대 size/projection 의 Int() 변환 트랩 방지 — safeFloatToInt(FrameEncoder) 경유.
                effW = layer.isFrameBuffer ? Self.safeFloatToInt(projW, floor: 1) : Self.safeFloatToInt(layer.size.x, floor: 1)
                effH = layer.isFrameBuffer ? Self.safeFloatToInt(projH, floor: 1) : Self.safeFloatToInt(layer.size.y, floor: 1)
            } else if let sv = videoLayerProvider(layer, package: package, sceneID: sceneID, index: uid),
                      let ph = makeTexture(Data([0, 0, 0, 0]), 1, 1, device) {
                // 비디오-텍스처 레이어: 씬을 통째로 VideoRenderer 로 스왑(형제 소실)하지 않고 일반 레이어로
                // 합성한다. mtl 은 1×1 clear placeholder — 실제 프레임은 buildDisplayTextures 가 프레임별
                // (라이브: AVPlayerItemVideoOutput / 헤드리스: AVAssetImageGenerator)로 공급. 디코드 실패 시
                // placeholder(투명)라 형제 레이어는 그대로 보존. rect/blend/opacity 는 아래 일반 경로가 존중.
                mtl = ph
                effW = Self.safeFloatToInt(layer.size.x, floor: 1)  // F530: Int() 트랩 가드
                effH = Self.safeFloatToInt(layer.size.y, floor: 1)
                videoLayer = sv
                hasVideoLayer = true
            } else if layer.spritesheet,
                      let sprite = resolveTextureWithFrames(layer.textureEntryName, package: package, device: device),
                      sprite.frames.count > 1 {
                // SPRITESHEET 콤보 + TEXS 다중 프레임 → gif 애니. resolveTextureWithFrames 가 아틀라스
                // (멀티페이지는 세로 스택 + frame.y 페이지 오프셋) + 프레임을 준다. 단일 프레임(count≤1)은
                // 정지 이미지와 동등 → 아래 일반 경로로(무-프레임, 상시 리드로 유발 안 함).
                mtl = sprite.texture
                frames = sprite.frames
                effW = Self.safeFloatToInt(sprite.frames[0].atlasWidth, floor: 1)  // F530: Int() 트랩 가드
                effH = Self.safeFloatToInt(sprite.frames[0].atlasHeight, floor: 1)
            } else if let loaded: (texture: MTLTexture, width: Int, height: Int) = resolveRequiredAsset(
                [layer.textureEntryName],
                package: package,
                decode: { data in
                    guard let tex = TexImage.parse(data),
                          let up = makeImageTexture(tex: tex, data: data, device: device) else {
                        return nil
                    }
                    return (up.texture, up.width, up.height)
                },
                alternate: {
                    guard let decoded = bitmapRGBAFile(layer.textureEntryName),
                          let texture = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else {
                        return nil
                    }
                    return (texture, decoded.width, decoded.height)
                }
            ) {
                mtl = loaded.texture
                effW = loaded.width
                effH = loaded.height
            } else {
                continue
            }
            // 스프라이트 프레임 있으면 상시 리드로 필요(gif 재생) — needsDisplay 정책은 shouldAnimate 로.
            if !frames.isEmpty { hasAnimations = true }
            let verts = Self.quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            // 이펙트 체인 빌드는 buildEffectChain 으로 추출(F741 — 텍스트 경로와 정책 공유, 동작 무수정).
            // 감사 V06+V07: 베이스 텍스처의 NoInterpolation — 손-포팅 체인 첫 이펙트 fb(V06)와 무효과
            // 베이스의 f_main nearest 변형(V07, GPULayer.noInterp) 양쪽이 소비하므로 상시 조회로 변경
            // (V06 는 이펙트 보유 시에만 조회했다).
            let noInterp = resolveTextureNoInterpolation(layer.textureEntryName, package: package)
            let effects = buildEffectChain(layer.effects, package: package, device: device,
                                           texW: effW, texH: effH,
                                           compositeImageTextures: compositeImageTextures,
                                           baseNoInterp: noInterp)
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
            // 레이어 프로퍼티 스크립트(visible/color/alpha/origin/scale/angles): 씬 공유 컨텍스트에서
            // per-frame 평가. visible 을 먼저 로드 — 실물 컨트롤러(3394601417 'bt')의 top-level shared
            // 초기화가 같은 오브젝트의 다른 스크립트보다 앞서도록. update 없는 스크립트(사이드이펙트
            // 전용)도 로드는 하되 연속 렌더(hasAnimations)는 유발하지 않는다.
            // origin/scale/angles(F331): 3D 빌보드 경로(SceneRenderer3D.Billboard3D)는 이미 동일
            // propertyScripts 를 소비 — 2D encodeLayer 도 동형으로 quadDirty→quadVertices 재계산.
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha", "origin", "scale", "angles"] {
                guard let src = layer.propertyScripts[key] else { continue }
                if key == "visible", Self.isVectorValuedVisibleScript(src) {
                    NSLog("%@", "[Waple] skipped vector-valued visible script")
                    continue
                }
                let ownerName = layer.name.isEmpty ? nil : layer.name
                // F743(S-34): currentLayerIndex = doc.layers 인덱스(디스크립터 순서 = doc.layers+doc.texts)
                // — 중복명/묘명 레이어의 thisLayer 오바인딩 해소.
                if let e = makeScriptEngine(src, layerName: ownerName, currentLayerIndex: uid,
                                            scriptPropsJSON: layer.propertyScriptProps[key]) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            // animationlayers blend/visible/rate 바인딩 스크립트(실물 rate 오디오 배속 2955378002/3448290956,
            // visible 토글 15씬): per-frame 재평가용 엔진. 정적 파스값은 초기값으로 유지(encodeLayer effLayers).
            var animLayerScripts: [(layerIndex: Int, key: String, engine: TextScriptEngine)] = []
            for (idx, al) in layer.animationLayers.enumerated() {
                for (key, src) in al.scripts {
                    if let e = makeScriptEngine(src, layerName: layer.name.isEmpty ? nil : layer.name,
                                                currentLayerIndex: uid) {  // F743(S-34): 디스크립터 인덱스 직결
                        animLayerScripts.append((idx, key, e))
                        if e.hasUpdate { hasAnimations = true }
                    }
                }
            }
            // material.constantshadervalue.scripted — PBR scalar per-frame evaluation (roughness/metallic/speculartint).
            var materialScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["roughness", "metallic", "speculartint"] {
                guard let src = layer.materialScripts[key] else { continue }
                if let e = makeScriptEngine(src, layerName: layer.name.isEmpty ? nil : layer.name,
                                            currentLayerIndex: uid,
                                            scriptPropsJSON: layer.materialScriptProps[key]) {
                    materialScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            // attachment(이름 본-슬롯 부착): 부모 레이어의 퍼펫 모델에서 부착점(MDAT)을 찾아 스펙 구성.
            // 부모/퍼펫/부착점 어느 하나라도 부재 → nil = 무부착 폴백(기존 베이크 위치 그대로 — 무회귀·무크래시).
            var attach: SceneRenderer.PuppetAttach? = nil
            if let attName = layer.attachment, let pid = layer.parent,
               let parentDef = doc.layers.first(where: { $0.id == pid }), let pp = parentDef.puppet {
                let pm: PuppetModel?
                if let cached = attachPuppets[pp] {
                    pm = cached
                } else {
                    pm = quietAssetData(pp, package: package).flatMap { PuppetModel.parse($0) }
                    attachPuppets[pp] = pm
                }
                if let pm, pm.attachments.contains(where: { $0.name == attName }) {
                    attach = SceneRenderer.PuppetAttach(
                        model: pm, name: attName,
                        parentOrigin: SIMD2(parentDef.origin.x, parentDef.origin.y),
                        parentScale: SIMD2(parentDef.scale.x, parentDef.scale.y),
                        parentAngle: parentDef.angleZ,
                        parentLayers: parentDef.animationLayers)
                    if !pm.animations.isEmpty { hasAnimations = true }  // 본 애니 추종 = 연속 리드로
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
            var gpuLayer = GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, uid: uid,
                                blendAdditive: layer.blendMode == "additive",
                                isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty
                                      && attach == nil) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                animLayerScripts: animLayerScripts,
                                materialScripts: materialScripts,
                                initialVisible: layer.initialVisible,
                                colorBlendMode: layer.colorBlendMode, frames: frames,
                                isLit: layerLit,
                                pbrMaterial: PBRMaterialUniforms(
                                    scalars: SIMD4(layer.roughness, layer.metallic, 0, 0),
                                    specularTint: SIMD4(layer.specularTint.x, layer.specularTint.y,
                                                        layer.specularTint.z, 0)),
                                litRect: lrect, video: videoLayer, attach: attach,
                                // F722: 비디오/프레임버퍼가 아닌 정적 이미지 레이어만 미디어 아트워크 대상
                                // (비디오는 프레임 공급자가 base 를 덮고, 컴포지션은 스냅샷 경로라 무의미).
                                mediaArtwork: (videoLayer == nil && !layer.isFrameBuffer)
                                    ? mediaArtworkKind(textureEntryName: layer.textureEntryName, package: package)
                                    : .none,
                                noInterp: noInterp)
            // H1: 커스텀 머티리얼 셰이더 파이프라인 빌드(실패 시 nil → QuadShaders 폴터).
            if layer.materialShader != nil {
                gpuLayer.customShader = buildCustomLayerShader(layer, texture: mtl, package: package,
                                                               device: device, pixelFormat: accPixelFormat)
                // 커스텀 셰이더 경로는 변환 행렬 산출에 def 가 필요 — 빌드 성공 시에만 유지.
                // materialShader 문자엧만으로는 판별 불가(genericimage4 같은 빌트인 이름도 잡히므로).
                if gpuLayer.customShader != nil, gpuLayer.def == nil {
                    gpuLayer.def = layer
                }
            }
            // H4: REFRACT — 노멀맵 로드 + refractAmount. 실패 시 refract 미설정 → identity 폴터(무크래시).
            if layer.refract, let normalName = layer.normalTextureName,
               let n = resolveRefractNormal(normalName, package: package, device: device) {
                gpuLayer.refract.enabled = true
                gpuLayer.refract.normalTexture = n.texture
                gpuLayer.refract.normalRG88 = n.rg88
                gpuLayer.refract.amount = layer.refractAmount
            }
            out.append(gpuLayer)
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
    /// fbNearest(감사 V06): 레이어 베이스 텍스처의 NoInterpolation — fb(texture(0)) 샘플만 nearest.
    func buildHandPortEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice,
                             fbNearest: Bool = false) -> EffectGPU? {
        guard let src = EffectShaders.source(for: eff.name, fbNearest: fbNearest),
              let params = EffectShaders.params(for: eff.name, constants: eff.constants, combos: eff.combos),
              let pipe = effectPipeline(source: src, device: device) else { return nil }
        let audio = audioParams(for: eff)
        if audio != nil { hasAudio = true }
        // slot0 은 framebuffer → aux 는 slot1.. 디코드. 디코드 실패는 흰색 1x1 폴백.
        // 레거시 frag(mask=texture(1)) 와 waterripple(normal=1, mask=2) 모두 위해
        // 최소 2개 슬롯을 흰색으로 채워 미바인드 텍스처를 방지한다.
        // F265 예외: shake 의 aux[0](slot1=flow map, WE 기본 util/noflow)은 흰색(=1.0)이면
        // flowMask=(1-0.498)*2≈1 로 상시 대각 드리프트가 생겨 "기본 flow=noflow → flowMask≈0"(F265 evidence)
        // 와 모순 — 명시 바인드가 없을 때만 중립 회색(byte 127≈0.498 → flowMask≈0)으로 대체.
        // F412 예외: waterripple 의 aux[0](slot1=노멀맵)도 흰색이면 언팩(rgb*2-1) 후 n=(1,1,1) 이라
        // 마스크 유효 영역 전체가 상시 대각 변위(정적 왜곡) — 중립 노멀 (128,128,255)(언팩 (0,0,1)=무왜곡)으로 대체.
        var aux: [MTLTexture] = []
        // slot0=framebuffer 라 aux 는 index i+1 로 바인드 — 126개 캡(Metal 텍스처 인자테이블 128 상한).
        let auxNames = eff.textureNames.count > 1 ? Array(eff.textureNames[1...].prefix(126)) : []
        for (i, name) in auxNames.enumerated() {
            if eff.name == "shake", i == 0, name == nil, let neutral = makeTexture(Data([127, 127, 0, 255]), 1, 1, device) {
                aux.append(neutral); continue
            }
            if eff.name == "waterripple", i == 0, name == nil, let neutral = makeTexture(Data([128, 128, 255, 255]), 1, 1, device) {
                aux.append(neutral); continue
            }
            // F830: pulse 의 aux[0](slot1=noise)은 WE 기본 "util/noise"(pulse.frag g_Texture1 default) —
            // 흰색 1x1 폴터면 noise=1×noiseAmount 상수 오프셋이 돼 시간 스크롤 노이즈가 사라진다.
            // noiseAmount=0(기본) 이면 결과 무관하나 noise>0 실씬에서 유효.
            if eff.name == "pulse", i == 0, name == nil,
               let t = resolveTexture("util/noise", package: package, device: device) {
                aux.append(t); continue
            }
            // F831: pulse 의 aux[1](slot2=opacity mask)은 MASK 콤보 ON 인데 미바인드면 WE
            // paintdefaultcolor "0 0 0 1"(블랙) = 전면 마스크아웃(효과 미적용). 흰색이면 반대로 전면 적용.
            if eff.name == "pulse", i == 1, name == nil, (eff.combos["MASK"] ?? 0) != 0,
               let black = makeTexture(Data([0, 0, 0, 255]), 1, 1, device) {
                aux.append(black); continue
            }
            guard let t = resolveTexture(name, package: package, device: device) else { continue }
            aux.append(t)
        }
        while aux.count < 2 {
            let isShakeFlowPad = eff.name == "shake" && aux.isEmpty
            let isWaterrippleNormalPad = eff.name == "waterripple" && aux.isEmpty  // F412
            // F830: textures 배열 자체가 짧은 pulse 도 slot1 기본은 util/noise(위 루프와 동일 계약).
            if eff.name == "pulse", aux.isEmpty,
               let t = resolveTexture("util/noise", package: package, device: device) {
                aux.append(t); continue
            }
            // F831: MASK 콤보 ON pulse 의 slot2 패드는 paintdefault 블랙(위 루프와 동일 계약).
            let isPulseMaskPad = eff.name == "pulse" && aux.count == 1 && (eff.combos["MASK"] ?? 0) != 0
            guard let tex = makeTexture(
                isShakeFlowPad ? Data([127, 127, 0, 255]) : isWaterrippleNormalPad ? Data([128, 128, 255, 255]) :
                isPulseMaskPad ? Data([0, 0, 0, 255]) : Data([255, 255, 255, 255]),
                1, 1, device) else { break }
            aux.append(tex)
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
                               texW: Int, texH: Int, compositeImageTextures: [Int: String] = [:],
                               // 감사 V07: 베이스 텍스처 NoInterpolation — previous bind(=효과 입력 src,
                               // 체인 첫 이펙트는 베이스 직결) 슬롯의 texFilter 를 nearest 로.
                               baseNoInterp: Bool = false) -> EffectGPU? {
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
            // X-②: command:"swap"(셰이더 없음, 실물 fluidsimulation velocity/dye 더블버퍼) — 무비용
            // 포인터 교환. 종전엔 이 분기가 없어 셰이더 패스로 오해석돼(material/shader 부재 →
            // "effects/<name>" 관례 조회 실패) 이펙트 전체가 드롭됐다.
            if mp.command == "swap" {
                guard let swap = makeSwapPass(mp, effName: eff.name, fboIndex: fboIndex, device: device) else { return nil }
                passes.append(swap)
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
                                               package: package, device: device,
                                               compositeImageTextures: compositeImageTextures,
                                               baseNoInterp: baseNoInterp) else { return nil }
            if t.usesAudio { anyAudio = true }
            passes.append(TranslatedPass(pipeline: pipe, material: material, aux: plan.aux,
                                         binds: plan.binds, target: plan.target, usesAudio: t.usesAudio,
                                         texRes: plan.texRes, texWrap: plan.texWrap, texFilter: plan.texFilter,
                                         scripts: passScripts, fullFrameSlots: plan.fullFrameSlots, swapPair: nil))
        }
        // 출력(타깃 없는 패스)이 하나도 없으면 화면에 아무것도 못 쓴다 → 폴백.
        guard passes.contains(where: { $0.target == nil }) else { return nil }
        if anyAudio { hasAudio = true }
        NSLog("%@", "[Waple] effect via GLSL→MSL translator: \(eff.name) (passes=\(passes.count) fbos=\(manifest.fbos.count) audio=\(anyAudio))")
        return EffectGPU(pipeline: passes[0].pipeline,
                         bind: .translated(passes: passes, fboSpecs: manifest.fbos.map {
                             FBOSpec(scale: $0.scale, fixedWidth: $0.fixedWidth, fixedHeight: $0.fixedHeight)
                         }))
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
        var wrap = [Float](repeating: 0, count: 8)
        wrap[0] = 1  // slot0 = fbo bind(자산 없음) → 항상 clamp.
        return TranslatedPass(pipeline: pipe, material: [], aux: [],
                              binds: [(0, srcIdx)], target: tgtIdx, usesAudio: false,
                              texRes: [SIMD4<Float>](repeating: dims, count: 8), texWrap: wrap,
                              texFilter: [Float](repeating: 0, count: 8),  // fbo→fbo 복사 — 자산 없음, 선형 고정
                              scripts: [], fullFrameSlots: [], swapPair: nil)
    }

    /// X-②: command:"swap"(셰이더 없음) — source/target fbo 이름을 인덱스로 해석해 포인터 교환만
    /// 예약(draw 없음, makeCopyPass 와 동일 미해석 정책 — 실패 시 효과 전체 폴백). pipeline 은
    /// applyEffect 가 swapPair 를 보고 즉시 continue 하므로 실제로 바인드·드로우되지 않는 placeholder.
    private func makeSwapPass(_ mp: EffectManifest.Pass, effName: String, fboIndex: [String: Int],
                              device: MTLDevice) -> TranslatedPass? {
        guard let srcName = mp.source, let srcIdx = fboIndex[srcName],
              let tgtName = mp.target, let tgtIdx = fboIndex[tgtName],
              let pipe = passthroughEffectPipeline(device: device) else {
            NSLog("%@", "[Waple] unresolved swap pass in \(effName)"); return nil
        }
        return TranslatedPass(pipeline: pipe, material: [], aux: [],
                              binds: [], target: nil, usesAudio: false,
                              texRes: [SIMD4<Float>](repeating: .zero, count: 8),
                              texWrap: [Float](repeating: 0, count: 8), texFilter: [Float](repeating: 0, count: 8),
                              scripts: [], fullFrameSlots: [], swapPair: (srcIdx, tgtIdx))
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
            if let src = scenePass.constantScripts[p.sceneKey],
               let engine = makeScriptEngine(src, scriptPropsJSON: scenePass.constantScriptProps[p.sceneKey]) {
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
                                   lw: Float, lh: Float, package: ScenePackage, device: MTLDevice,
                                   compositeImageTextures: [Int: String] = [:],
                                   baseNoInterp: Bool = false)
        -> (binds: [(slot: Int, source: Int)], texRes: [SIMD4<Float>], aux: [(slot: Int, tex: MTLTexture)],
            texWrap: [Float], texFilter: [Float], target: Int?, fullFrameSlots: [Int])? {
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
        // F162/F163: bind(fbo/previous) 슬롯은 TexImage 가 없는 파이프라인-내부 렌더타깃 — 항상 clamp
        // (콘텐츠 경계 밖 랩은 아티팩트, W4a 실측). aux(실 자산) 슬롯은 아래에서 TexImage.clampUVs 로 채운다.
        var texWrap = [Float](repeating: 0, count: 8)
        for (slot, source) in binds where slot < 8 && source >= 0 {
            let fbo = manifest.fbos[source]
            // X-①: fixedWidth/fixedHeight(fit·width/height) 가 있으면 dst 비례(scale) 대신 절대 크기.
            if let fw = fbo.fixedWidth, let fh = fbo.fixedHeight {
                texRes[slot] = SIMD4(Float(fw), Float(fh), Float(fw), Float(fh))
            } else {
                let s = Float(fbo.scale)
                texRes[slot] = SIMD4(lw / s, lh / s, lw / s, lh / s)
            }
        }
        for slot in bindSlots where slot < 8 { texWrap[slot] = 1 }
        // X-①: `uvs:"repeat"` FBO(실물 glitter `_rt_GlitterTiles` 타일 아틀라스)를 소스로 삼는 bind 슬롯은
        // 위의 기본 clamp 를 repeat 로 재정의.
        for (slot, source) in binds where slot < 8 && source >= 0 && manifest.fbos[source].uvsRepeat {
            texWrap[slot] = 0
        }
        // 감사 V07: 슬롯별 샘플 필터(1=nearest/0=linear — TexImage.noInterpolation, WE tex Flags bit0).
        // previous(bind -1) 슬롯은 baseNoInterp(체인 첫 이펙트의 베이스 직결 — applyEffect 가 previous 를
        // 항상 효과 입력 src 로 바인드)일 때만 nearest, fbo bind 슬롯은 선형(FBO 출력 — 손-포팅 fbNearest
        // 의 V06 정합과 동일). aux 슬롯은 아래에서 자산 플래그로 채운다.
        var texFilter = [Float](repeating: 0, count: 8)
        if baseNoInterp {
            for (slot, source) in binds where slot < 8 && source == -1 { texFilter[slot] = 1 }
        }
        var aux: [(slot: Int, tex: MTLTexture)] = []
        var fullFrameSlots: [Int] = []
        for slot in t.textureSlots where slot > 0 && slot < 128 && !bindSlots.contains(slot) {
            var name = slot < scenePass.textureNames.count ? scenePass.textureNames[slot] : nil
            if name == nil, slot < matTextures.count { name = matTextures[slot] }
            // F-X4: 씬/머티리얼 어느 쪽도 슬롯을 지정하지 않으면 셰이더 샘플러 주석의
            // `"default":"경로"`(WE 관례: util/noise, pattern/voronoi_local, _rt_FullFrameBuffer 등)로
            // 폴백 — 종전엔 이 어노테이션이 통째로 버려져 흰색 1×1 이 됐다(패턴/노이즈 기반 이펙트 왜곡).
            if name == nil { name = t.textureDefaults[slot] }
            // F720: `_rt_imageLayerComposite_<id>` = 참조 레이어의 런타임 컴포지트 RTT. 종전엔 `_rt_` 접두어
            // 슬롯을 continue 로 스킵해 해당 샘플러가 영구 미바인드(Metal 검증 실패/미정의 읽기 + blend/
            // clipping_mask 콘텐츠 소실). 3D 경로(SceneRenderer3D.loadMesh3DMaterial)와 동일한 정적 치환:
            // 참조 레이어의 베이스 이미지 텍스처로 대체하고, 해석 불가(id 미상/기타 _rt_)는 nil 로 둬
            // resolveTexture 의 흰색 1×1 폴터가 바인드를 보장하게 한다(미바인드 방지가 우선 — 오역보다 폴터).
            // F-X4: `_rt_FullFrameBuffer`(godrays/shine 의 COPYBG 콤보 등) 는 씬 컬러 스냅샷이 필요한
            // **동적** 슬롯이라 정적 치환 불가 — 슬롯 번호만 기록해 draw 시점(applyEffect) 에 실제 스냅샷을
            // 가진 호출부가 있으면 덮어쓴다. 빌드 시점엔 흰색 1×1 로 채워 무회귀 유지(폴백 없으면 백색 합성).
            if let n = name, n.hasPrefix("_rt_") {
                name = nil
                if n.hasPrefix("_rt_imageLayerComposite_") {
                    let digits = n.dropFirst("_rt_imageLayerComposite_".count).prefix { $0.isNumber }
                    if let layerID = Int(digits) { name = compositeImageTextures[layerID] }
                } else if n == "_rt_FullFrameBuffer" {
                    fullFrameSlots.append(slot)
                }
            }
            if let tex = resolveTexture(name, package: package, device: device) {
                aux.append((slot, tex))
                if slot < 8 {
                    let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                    texRes[slot] = SIMD4(w, h, w, h)
                    texWrap[slot] = resolveTextureClampUVs(name, package: package) ? 1 : 0
                    texFilter[slot] = resolveTextureNoInterpolation(name, package: package) ? 1 : 0  // 감사 V07
                }
            }
        }
        let target: Int? = mp.target.flatMap { fboIndex[$0] }
        if mp.target != nil && target == nil { NSLog("%@", "[Waple] unknown target in \(effName)"); return nil }
        return (binds, texRes, aux, texWrap, texFilter, target, fullFrameSlots)
    }

    /// F162/F163: 텍스처 자산의 ClampUVs 헤더 플래그(TexImage.swift:126, WE tex Flags bit0x2)만 저비용
    /// 조회 — 헤더만 재파스(디코드 없음, 씬 빌드 1 회성이라 무해). 실패/부재는 false(=repeat, WE 기본 어드레싱).
    private func resolveTextureClampUVs(_ name: String?, package: ScenePackage) -> Bool {
        guard let name else { return false }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates {
            if let d = quietAssetData(c, package: package), let tex = TexImage.parse(d) { return tex.clampUVs }
        }
        return false
    }

    /// 감사 V06: 텍스처 자산의 NoInterpolation 헤더 플래그(TexImage.swift:126, WE tex Flags bit0x1)만 저비용
    /// 조회 — 헤더만 재파스(resolveTextureClampUVs 와 동일 패턴). 실패/부재는 false(=linear, WE 기본 필터).
    private func resolveTextureNoInterpolation(_ name: String?, package: ScenePackage) -> Bool {
        guard let name else { return false }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates {
            if let d = quietAssetData(c, package: package), let tex = TexImage.parse(d) { return tex.noInterpolation }
        }
        return false
    }

    /// F722: 레이어의 머티리얼이 시스템 미디어 텍스처($mediaThumbnail/$mediaPreviousThumbnail)를 요청하는지
    /// 감지. 파서가 해석한 textureEntryName("materials/X.tex")과 같은 basename 의 머티리얼 json("materials/X.json")을
    /// 다시 읽어 passes[0].usertextures 의 시스템 키(문자열 또는 {name,type:"system"})를 찾는다 — 파스 계층이
    /// 시스템 키를 userProps 에서 조회해 실패로 끝난 뒤라(실측 12wp 의 Album Cover 머티리얼) 렌더 측 재판독이 필요.
    /// 감지 실패(무 json/무 usertextures)는 .none — 대부분의 레이어, 기존 정적 텍스처 그대로(무회귀).
    func mediaArtworkKind(textureEntryName: String, package: ScenePackage) -> SceneRenderer.MediaArtworkKind {
        guard textureEntryName.hasSuffix(".tex") else { return .none }
        let jsonName = String(textureEntryName.dropLast(4)) + ".json"
        guard let d = quietAssetData(jsonName, package: package),
              let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let passes = m["passes"] as? [Any],
              let p0 = passes.first as? [String: Any],
              let userTextures = p0["usertextures"] as? [Any] else { return .none }
        var found: SceneRenderer.MediaArtworkKind = .none
        for raw in userTextures {
            let key = (raw as? String) ?? ((raw as? [String: Any])?["name"] as? String)
            if key == "$mediaThumbnail" { found = .current }
            else if key == "$mediaPreviousThumbnail", found == .none { found = .previous }
        }
        return found
    }

    /// F722: 미디어 아트워크 원본 바이트(JPEG/PNG — MediaPoller 공급) → RGBA8 텍스처.
    /// 디코드 실패 시 nil(호출부는 이전 텍스처/placeholder 유지). bitmapRGBAFile 과 동일 디코드 규약.
    func decodeArtworkTexture(_ data: Data, device: MTLDevice) -> MTLTexture? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return makeTexture(Data(pixels), width, height, device)
    }

    /// assetData 의 조용한 버전: pkg→베이스에셋 조회하되 미스에 로그 없음(소스 프로브는 미스가 정상).
    func quietAssetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = packageData(name, package: package) { return d }
        if let base = assetBaseDir, let url = baseAssetURL(for: name, root: base) { return try? Data(contentsOf: url) }
        return nil
    }

    /// pkg 전용 에셋 조회(베이스 팩 폴터 없음) — 커스텀 셰이더 소스처럼 씬 번들만 인정해야 하는 프로브용.
    func packageData(_ name: String, package: ScenePackage) -> Data? {
        if let d = package.data(for: name) { return d }
        guard let e = package.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        return package.data(for: e.name)
    }

    private func baseAssetURL(for name: String, root: URL) -> URL? {
        guard case .url(let url) = baseAssetURLProbe(for: name, root: root) else { return nil }
        return url
    }

    private func baseAssetURLProbe(for name: String, root: URL) -> BaseAssetURLProbe {
        guard let path = WallpaperPathSecurity.normalizedRelativePath(name) else { return .rejected }
        let rootURL = root.standardizedFileURL
        let exactCandidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard WallpaperPathSecurity.contains(exactCandidate, in: rootURL) else { return .rejected }
        if FileManager.default.fileExists(atPath: exactCandidate.path) {
            guard let exact = WallpaperPathSecurity.containedFileURL(path, root: root) else {
                return .rejected
            }
            return .url(exact)
        }
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var current = rootURL
        for part in path.split(separator: "/").map(String.init) {
            guard let children = try? FileManager.default.contentsOfDirectory(at: current,
                                                                              includingPropertiesForKeys: nil),
                  let match = children.first(where: {
                      $0.lastPathComponent.caseInsensitiveCompare(part) == .orderedSame
                  }) else { return .missing }
            current = match.standardizedFileURL
            guard WallpaperPathSecurity.contains(current, in: rootURL) else { return .rejected }
            let realCurrent = current.resolvingSymlinksInPath().standardizedFileURL
            guard WallpaperPathSecurity.contains(realCurrent, in: realRoot) else { return .rejected }
        }
        guard FileManager.default.fileExists(atPath: current.path) else { return .missing }
        return .url(current)
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
            lib = try WapleProfiler.compile(msl) { try device.makeLibrary(source: msl, options: nil) }
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
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

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

    /// H1: 레이어 머티리얼 커스텀 셰이더 빌드. 성공 시 CustomLayerShader, 실패 시 nil(→ QuadShaders 폴터).
    /// buildTranslatedEffect 의 5책임 분해를 2D 레이어에 맞춰 단순화한 버전.
    /// 셰이더 소스(.vert/.frag)는 씬 패키지 안 것만 인정 — 베이스 에셋 팩의 WE 빌트인 셰이더
    /// (genericimage4 등)까지 이 경로로 빨려 들어오면 검증된 QuadShaders 경로를 불필요하게 우회한다
    /// (3394601417 주야 토글 회귀 실증). include(common.h 등)만 베이스 팩 폴터 허용.
    func buildCustomLayerShader(_ layer: SceneLayer, texture: MTLTexture, package: ScenePackage, device: MTLDevice,
                                pixelFormat: MTLPixelFormat) -> CustomLayerShader? {
        guard let shaderName = layer.materialShader else { return nil }
        let include: (String) -> String? = { header in
            for cand in ["shaders/\(header)", header] {
                if let d = self.quietAssetData(cand, package: package), let s = String(data: d, encoding: .utf8) { return s }
            }
            return BuiltinShaderIncludes.lookup(header)
        }
        guard let vData = packageData("shaders/\(shaderName).vert", package: package),
              let fData = packageData("shaders/\(shaderName).frag", package: package),
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

    /// 효과 보조 텍스처 슬롯 이름 → MTLTexture. 이름 nil/디코드 실패 → 흰색 1x1 폴백
    /// (마스크는 흰색=효과 전체 적용으로 정상. 노멀맵은 흰색≠중립 — 언팩 시 (1,1,1)=상시 대각
    /// 변위라 waterripple 은 buildHandPortEffect 에서 중립 (128,128,255)로 별도 처리, F412).
    /// "effects/X"/"masks/X" 같은 상대 이름은 "materials/<name>.tex" 로 해석, raw 이름도 시도.
    func resolveTexture(_ name: String?, package: ScenePackage, device: MTLDevice) -> MTLTexture? {
        resolveTextureWithFrames(name, package: package, device: device)?.texture
    }

    /// 텍스처 + 스프라이트시트 프레임(TEXS). 파티클이 프레임 UV 서브렉트에 사용(레이어는 texture 만).
    func resolveTextureWithFrames(_ name: String?, package: ScenePackage, device: MTLDevice)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        if let name {
            let candidates = name.hasSuffix(".tex")
                ? [name]
                : ["materials/\(name).tex", name]
            if let resolved: (texture: MTLTexture, frames: [TexImage.TexFrame]) = resolveRequiredAsset(
                candidates,
                package: package,
                decode: { d in
                    guard let tex = TexImage.parse(d) else { return nil }
                    let multipage = tex.imageCount > 1
                    if multipage, !tex.frames.isEmpty,
                       let stacked = stackedAtlas(tex: tex, data: d, device: device) {
                        return stacked
                    }
                    // 단일-이미지 다중프레임 시트는 아틀라스 전체 보존(imgW/imgH 크롭 시 frame≥1 소실 → 흑화).
                    // keepFullAtlas 는 makeImageTexture 가 full decode dims 로 상주(BC 면 네이티브, 비-BC 면 CPU rgba8) —
                    // spriteFrameTexture 가 f_spriteframe 샘플로 프레임을 뽑으므로 아틀라스가 BC 로 상주해도 무방.
                    if let dec = makeImageTexture(tex: tex, data: d, device: device,
                                                  keepFullAtlas: !multipage && tex.frames.count > 1) {
                        let texture = dec.texture
                        // 멀티페이지인데 stackedAtlas 실패(스택 높이>16384 등) → 프레임 좌표가 페이지-상대라 그대로
                        // 쓰면 imageId≥1 프레임이 page0 좌표를 읽는 **조용한 오프레임**. frames=[] 로 정지 폴백
                        // (page 0 표시)해 "틀린 애니" 대신 "정지"로 명예로운 실패(advisor). 단일 image 는 frames
                        // 정상(전부 id0, 오프셋 무관). 영향 실측 6씬(3379048027 7페이지/420프레임 sumH 52920,
                        // 3363252053·3448877775 7페이지, 3577990983 5페이지, 3000562427 day/night 3페이지).
                        // ponytail: 진짜 고침 = 페이지별 텍스처 또는 온디맨드 프레임 스트리밍(초대형 시트 ~1.7GB) — 재설계.
                        return (texture, multipage ? [] : tex.frames)
                    }
                    return nil
                }
            ) {
                return resolved
            }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map { ($0, []) }
    }

    /// REFRACT 노멀맵 아틀라스 + RG88 여부. 프레임 UV 는 알베도와 공유(동일 그리드 가정) → 전체 아틀라스만 필요.
    /// resolveTextureWithFrames 와 동일 디코드 경로(멀티페이지 스택/keepFullAtlas)로 알베도와 레이아웃 정합.
    /// rg88 플래그는 pf_refract 의 노멀 언팩 분기용(WE DecompressNormalWithMask 의 FORMAT_RG88 vs DXT).
    func resolveRefractNormal(_ name: String?, package: ScenePackage, device: MTLDevice)
        -> (texture: MTLTexture, rg88: Bool)? {
        guard let name else { return nil }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        return resolveRequiredAsset(candidates, package: package, decode: { d -> (texture: MTLTexture, rg88: Bool)? in
            guard let tex = TexImage.parse(d) else { return nil }
            let rg88 = tex.payload == .rg88
            let multipage = tex.imageCount > 1
            if multipage, !tex.frames.isEmpty, let stacked = stackedAtlas(tex: tex, data: d, device: device) {
                return (stacked.texture, rg88)
            }
            if let dec = makeImageTexture(tex: tex, data: d, device: device,
                                          keepFullAtlas: !multipage && tex.frames.count > 1) {
                return (dec.texture, rg88)
            }
            return nil
        })
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
            var g = GPUParticleSystem(
                sim: ParticleSimulator(def: def, seed: seed), def: def, seed: seed,
                texture: tex, blendAdditive: def.material?.blend == .additive,
                origin: SIMD2<Float>(sp.origin.x, sp.origin.y),
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y),
                texRatio: Float(tex.height) / Float(max(1, tex.width)), order: sp.order,
                isTrail: def.renderer.isTrail, childOf: childOf,
                frames: frames, mapSeqMirror: mirror)
            // F200: 마우스 시차 가중치(레이어 buildLayers 의 GPULayer.parallaxDepth 배선과 동형) — 2D 전용.
            g.parallaxDepth = SIMD2<Float>(sp.parallaxDepth.x, sp.parallaxDepth.y)
            // 3D 씬 배치(2D 는 위 origin/scale Vec2 만 사용 — 아래 필드 무시).
            g.parent3D = sp.parent
            g.origin3D = SIMD3<Float>(sp.origin3D.x, sp.origin3D.y, sp.origin3D.z)
            g.scale3D = SIMD3<Float>(sp.scale3D.x, sp.scale3D.y, sp.scale3D.z)
            g.angles3D = SIMD3<Float>(sp.angles3D.x, sp.angles3D.y, sp.angles3D.z)
            g.visible3D = sp.visible
            // REFRACT: 노멀맵(textures[1]) 로드 + refractAmount. 실패 시 refract 미설정 → identity 폴백(무크래시).
            if let mat = def.material, mat.refract, let normalName = mat.normalTextureName,
               let n = resolveRefractNormal(normalName, package: package, device: device) {
                g.refract = true
                g.normalTexture = n.texture
                g.normalRG88 = n.rg88
                g.refractAmount = mat.refractAmount
            }
            // 감사 V07: 알베도 NoInterpolation(TexImage flags bit0) — encodeParticle 이 nearest 변형
            // 파이프라인을 선택(레이어 buildLayers 의 GPULayer.noInterp 배선과 동형).
            g.noInterp = resolveTextureNoInterpolation(def.material?.textureName, package: package)
            return g
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
        // 이미터 오디오반응이 있으면 라이브 오디오 공급자 기동 대상(mount 의 hasAudio 게이트 → provider.start()).
        if out.contains(where: { $0.def.emitterAudio.contains { $0 != nil } }) { hasAudio = true }
        return out
    }

    /// 파티클 파이프라인. frag 가 premultiplied-alpha 출력 → src=one.
    /// additive: dst=one(가산), translucent: dst=oneMinusSrcAlpha(일반 over).
    /// nearest(감사 V07): 알베도 NoInterpolation 시스템 전용 — ParticleShaders.nearestSource(pf_main 샘플러만
    /// filter::nearest, 어드레스 모드 보존). false 면 기존 소스와 비트동일(무회귀).
    func particlePipeline(additive: Bool, nearest: Bool = false, device: MTLDevice) -> MTLRenderPipelineState? {
        let src = nearest ? ParticleShaders.nearestSource : ParticleShaders.source
        guard let lib = try? WapleProfiler.compile(src, { try device.makeLibrary(source: src, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat   // A2: acc 를 타깃으로 하므로 acc 포맷과 일치(HDR=float)
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// REFRACT 스프라이트 파이프라인. vert=pv_main 공유, frag=pf_refract(노멀 오프셋 씬 재샘플·곱).
    /// 블렌드는 translucent(over) — refract 코퍼스는 전부 translucent(additive-refract 미관측).
    func refractParticlePipelineBuild(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(ParticleShaders.source, { try device.makeLibrary(source: ParticleShaders.source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_refract")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// H4: REFRACT 이미지 레이어 파이프라인. vert=v_main 공유, frag=f_refract(노멀 오프셋 씬 재샘플·곱).
    /// 블렌드는 premultiplied-over(레이어 기본) — refract 코퍼스는 전부 translucent/additive 아님.
    func refractLayerPipelineBuild(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(QuadShaders.source, { try device.makeLibrary(source: QuadShaders.source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "v_main")
        pd.fragmentFunction = lib.makeFunction(name: "f_refract")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(source, { try device.makeLibrary(source: source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    func makeOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    /// A2 HDR: float(rgba16Float) 누적 타깃 — >1.0 합 보존(bgra8 하드클램프 백화 방지). 톤맵 패스 입력.
    func makeOffscreenHDR(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w,1), height: max(h,1), mipmapped: false)
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

    /// 네이티브 BC 업로드: LZ4 해제된 raw BC 블록을 `.bc1/2/3_rgba`(sRGB 아님 — rgba8Unorm 선형 파이프라인과
    /// 동일 취급)로 직접 올린다. bytesPerRow=소스 decode-dims stride 라 Metal 이 패딩 블록을 스킵(크롭 무비용,
    /// 부분 엣지 블록은 GPU 엣지 클램프 — 실측 검증). CPU DXT 디코드·RGBA 상주(≈12× 큼) 동시 회피.
    func makeBCTexture(_ bc: TexDecoder.NativeBCUpload, _ device: MTLDevice) -> MTLTexture? {
        let pf: MTLPixelFormat
        switch bc.format {
        case .bc1: pf = .bc1_rgba
        case .bc2: pf = .bc2_rgba
        case .bc3: pf = .bc3_rgba
        }
        guard bc.width > 0, bc.height > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: bc.width, height: bc.height, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        bc.blocks.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            t.replace(region: MTLRegionMake2D(0, 0, bc.width, bc.height), mipmapLevel: 0,
                      withBytes: base, bytesPerRow: bc.bytesPerRow)
        }
        return t
    }

    /// 씬 이미지 텍스처 1장 → MTLTexture(+dims). BC(DXT)면 네이티브 BC 업로드 시도(supportsBC 게이트 +
    /// WAPLE_BC_NATIVE!=0 킬스위치), 비-BC/멀티페이지/미지원이면 기존 CPU rgba()+makeTexture 폴백.
    /// 반환 dims 는 두 경로 동일(파리티). buildLayers·resolveTextureWithFrames·3D 빌보드 공용.
    /// keepFullAtlas(스프라이트 아틀라스)도 네이티브 BC 허용 — spriteFrameTexture 가 blit.copy 가 아닌
    /// f_spriteframe 샘플로 프레임을 뽑으므로 아틀라스가 BC 로 상주해도 무방(전 크롭 금지 위해 nativeBC 에 full dims 요청).
    func makeImageTexture(tex: TexImage, data: Data, device: MTLDevice, keepFullAtlas: Bool = false)
        -> (texture: MTLTexture, width: Int, height: Int)? {
        if ProcessInfo.processInfo.environment["WAPLE_BC_NATIVE"] != "0",
           device.supportsBCTextureCompression,
           let bc = TexDecoder.nativeBC(from: tex, data: data, properties: variantProperties, keepFullAtlas: keepFullAtlas),
           let t = makeBCTexture(bc, device) {
            return (t, bc.width, bc.height)
        }
        guard let dec = TexDecoder.rgba(from: tex, data: data, properties: variantProperties, keepFullAtlas: keepFullAtlas),
              let t = makeTexture(dec.pixels, dec.width, dec.height, device) else { return nil }
        return (t, dec.width, dec.height)
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
        // F741(S-13): 텍스트 이펙트의 _rt_imageLayerComposite 바인드용 치환 맵(buildLayers 와 동일 규약).
        let compositeImageTextures = doc.layers.reduce(into: [Int: String]()) { acc, layer in
            guard layer.id != 0, !layer.textureEntryName.isEmpty else { return }
            acc[layer.id] = layer.textureEntryName
        }
        for (uid, t) in doc.texts.enumerated() {
            let isSystem = t.font.hasPrefix("systemfont_") || t.font.isEmpty
            let fontData = isSystem ? nil : quietAssetData(t.font, package: package)
            if !isSystem && fontData == nil { NSLog("%@", "[Waple] text font missing (system fallback): \(t.font)") }
            // F743(S-34): JS 디스크립터 인덱스 = doc.layers.count + uid(sceneScriptLayers 의 이미지→텍스트 순서).
            let descriptorIndex = doc.layers.count + uid
            // 씬 공유 컨텍스트 로드(top-level 사이드이펙트 실행). update 없는 스크립트는 텍스트 갱신에
            // 못 쓰므로 엔진 nil 취급(정적 텍스트 유지) — 로드 자체는 shared 통신을 위해 수행.
            let loaded = t.script.flatMap { makeScriptEngine($0, layerName: t.name.isEmpty ? nil : t.name,
                                                             currentLayerIndex: descriptorIndex,
                                                             scriptPropsJSON: t.scriptProps) }
            if t.script != nil && loaded == nil { NSLog("%@", "[Waple] text script failed to load (empty text): \(t.script!.prefix(60))") }
            let engine = (loaded?.hasUpdate == true) ? loaded : nil
            let initial = engine != nil ? (engine!.evaluate(current: t.text) ?? "") : t.text
            // 프로퍼티 스크립트(origin/scale/alpha/color/angles/visible, F218/F219): 레이어 propScripts
            // 와 동일 규약(visible 먼저 로드 — top-level shared 사이드이펙트 순서).
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha", "origin", "scale", "angles"] {
                guard let src = t.propertyScripts[key] else { continue }
                let ownerName = t.name.isEmpty ? nil : t.name
                if let e = makeScriptEngine(src, layerName: ownerName, currentLayerIndex: descriptorIndex,
                                            scriptPropsJSON: t.propertyScriptProps[key]) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            var g = GPUText(texture: nil, vertexBuffer: nil,
                            tint: SIMD4(t.color.x, t.color.y, t.color.z, t.alpha),
                            order: t.order, engine: engine, lastText: initial,
                            fontData: fontData, systemFontName: isSystem ? t.font : nil, def: t,
                            uid: uid, initialVisible: t.initialVisible, propScripts: propScripts)
            rasterize(&g, device: device)
            // F741(S-13): 텍스트 effects[](F693 파스·보존)를 래스터 텍스처에 적용할 GPU 체인 —
            // 레이어와 동일 빌더(buildEffectChain). texRes 는 초기 래스터 dims 로 베이크(문자열이
            // 바뀌어 재래스터돼도 효과 해상도는 초기값 유지 — ponytail: 갱신 시 재빌드는 후속 과제).
            if !t.effects.isEmpty, g.texture != nil {
                g.effects = buildEffectChain(t.effects, package: package, device: device,
                                             texW: max(1, Int(g.rasterWidth)), texH: max(1, Int(g.rasterHeight)),
                                             compositeImageTextures: compositeImageTextures)
                if !g.effects.isEmpty { hasEffects = true }
            }
            if engine != nil { hasScriptedText = true }
            out.append(g)
        }
        return out
    }

    /// 텍스트 재래스터: lastText → 텍스처 + 앵커 정렬 쿼드. 빈 텍스트 → 텍스처 nil(드로우 스킵).
    /// rasterWidth/Height(비-스케일 글리프 픽셀 크기)를 저장 — encodeText 가 프로퍼티 스크립트로
    /// per-frame 지오메트리를 재계산할 때 재래스터 없이 재사용한다.
    func rasterize(_ g: inout GPUText, device: MTLDevice) {
        guard let r = TextRasterizer.render(text: g.lastText, fontData: g.fontData,
                                            systemFontName: g.systemFontName, pointSize: g.def.pointSize,
                                            maxWidth: g.def.maxWidth, maxRows: g.def.maxRows,
                                            ellipsis: g.def.overflowEllipsis, justify: g.def.justify,
                                            align: g.def.horizontalAlign) else {
            g.texture = nil; g.vertexBuffer = nil
            return
        }
        g.texture = makeTexture(r.rgba, r.width, r.height, device)
        g.rasterWidth = Float(r.width); g.rasterHeight = Float(r.height)
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
