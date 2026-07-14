import AppKit
import MetalKit
import simd
import WapleCore

// SceneRenderer 3D 서브시스템(갓클래스 3분할 ③, 2026-07-04 — 코드 이동 + private→internal 만, 로직 무변경):
// camera3D + .mdl 메시 씬 — Node3D/Billboard3D/MeshRenderable 타입, build3D 리소스화,
// encode3D/encodeBillboard 패스(뎁스·스키닝·카메라 스크립트), 메시 파이프라인/뎁스 상태 캐시.
extension SceneRenderer {
    /// 서브메시 1개 = 드로우콜 1개. vbuf 는 pos3+normal3+uv2 인터리브(8 float/정점), ibuf 는 u16.
    struct GPU3DMesh {
        let vbuf: MTLBuffer
        let ibuf: MTLBuffer
        let indexCount: Int
        let texture: MTLTexture
        let tint: SIMD4<Float>       // 머티리얼 Color × Alpha
        let roughness: Float
        let metallic: Float
        let specularTint: SIMD3<Float>
        let alphaCutoff: Float       // alphatocoverage → 0.5 (컷아웃 discard 근사), 그 외 0
        let shadowEligible: Bool     // opaque/alphatocoverage만 P4 caster 대상
        let unlit: Bool              // combos.LIGHTING==0 → 풀브라이트 albedo(라이팅 스킵, mode.w=0)
        let cullBack: Bool           // cullmode "normal" → 백페이스 컬, "nocull" → 양면
        let additive: Bool
        let depthTest: Bool
        let depthWrite: Bool
        let skinned: Bool            // true → 16f 스트라이드 + mv_skin(본행렬 버퍼)
    }
    /// MSL `MeshU`와 레이아웃 일치(3×float4x4 + 3×float4 = 240B).
    struct MeshUniform {
        var mvp: simd_float4x4
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var tint: SIMD4<Float>
        /// x=roughness, y=metallic, z=alphaCutoff, w=0 unlit / 1 mesh hemisphere / 2 image flat.
        var material: SIMD4<Float>
        var specularTint: SIMD4<Float>
    }
    struct Script3D { let key: String; let engine: TextScriptEngine }

    /// 3D 변환 계층의 한 노드(그룹 or 모델 오브젝트) — per-frame 스크립트 평가로 로컬 변환/가시성 갱신.
    /// id 로 부모 체인 합성(Scene3DMath.worldMatrix). 모델 오브젝트는 MeshRenderable 이 동일 id 로 지오메트리 참조.
    final class Node3D {
        let id: Int
        let parent: Int?
        let baseOrigin, baseAngles, baseScale: SIMD3<Float>
        let baseVisible: Bool
        let order: Int
        var scripts: [Script3D] = []
        // per-frame 현재값(스크립트 없으면 base 고정)
        var origin, angles, scale: SIMD3<Float>
        var visible: Bool
        init(id: Int, parent: Int?, origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>, visible: Bool, order: Int) {
            self.id = id; self.parent = parent; self.order = order
            baseOrigin = origin; baseAngles = angles; baseScale = scale; baseVisible = visible
            self.origin = origin; self.angles = angles; self.scale = scale; self.visible = visible
        }
        /// 변환은 매 프레임 base 에서 재계산(스크립트가 일부 성분만 덮어써도 결정적), visible 은 이전값을 이어 평가.
        func evaluateScripts(time: Float) {
            var o = baseOrigin, a = baseAngles, s = baseScale
            for sc in scripts {
                sc.engine.setRuntime(Double(time))
                switch sc.key {
                case "origin": if let v = sc.engine.evaluateVec(current: [o.x, o.y, o.z]), v.count >= 3 { o = SIMD3(v[0], v[1], v[2]) }
                case "angles": if let v = sc.engine.evaluateVec(current: [a.x, a.y, a.z]), v.count >= 3 { a = SIMD3(v[0], v[1], v[2]) }
                case "scale":  if let v = sc.engine.evaluateVec(current: [s.x, s.y, s.z]), v.count >= 3 { s = SIMD3(v[0], v[1], v[2]) }
                case "visible": visible = sc.engine.evaluateBool(current: visible) ?? visible
                default: break
                }
            }
            origin = o; angles = a; scale = s
        }
    }

    /// 렌더 가능한 3D 메시(모델) — 변환은 동일 id 의 Node3D 에서.
    /// 스키닝 모델은 model(본+애니) + animIndex(활성 애니, -1=바인드포즈) + boneBuffer(프레임당 갱신) 보유.
    struct MeshRenderable {
        let id: Int
        let meshes: [GPU3DMesh]
        let order: Int
        let name: String
        let model: Model3D?          // 스키닝: 본/애니 소스(정적 모델은 nil)
        let animIndex: Int           // -1 = 정지(바인드 포즈)
        let animRate: Float
        let boneRing: DynamicVertexBuffer?   // 3슬롯 링: skin=world×bindWorld⁻¹, 프레임마다 다음 슬롯에 적재(경합 회피)
        let castShadow: Bool
    }

    /// 3D 씬의 2D 이미지 레이어를 카메라-페이싱 쿼드로(빌보드). 로컬 변환 + 부모 계층 + per-frame 스크립트.
    final class Billboard3D {
        let texture: MTLTexture
        let size: SIMD2<Float>           // 씬 픽셀 크기(월드 반경 = size×scale×부모스케일)
        let parent: Int?
        let order: Int
        let additive: Bool               // 머티리얼 blending=additive → 가산 파이프라인(플레어/글로우)
        let depthTest: Bool
        let depthWrite: Bool
        let effects: [EffectGPU]
        let texWidth: Int
        let texHeight: Int
        let isFrameBuffer: Bool
        let baseOrigin: SIMD3<Float>
        let baseScale: SIMD2<Float>
        let baseAngleZ: Float
        let baseTint: SIMD4<Float>
        let baseVisible: Bool
        let lighting: Bool
        let roughness: Float
        let metallic: Float
        let specularTint: SIMD3<Float>
        var scripts: [Script3D] = []
        /// per-frame 정점 재사용(3슬롯 링 — 레이어/파티클/본과 동일 패턴, 매프레임 makeBuffer 방지).
        let scratchQuad = DynamicVertexBuffer()
        // per-frame
        var origin: SIMD3<Float>
        var scale: SIMD2<Float>
        var angleZ: Float
        var tint: SIMD4<Float>
        var visible: Bool
        init(texture: MTLTexture, size: SIMD2<Float>, parent: Int?, order: Int, additive: Bool,
             depthTest: Bool, depthWrite: Bool, effects: [EffectGPU], texWidth: Int, texHeight: Int,
             isFrameBuffer: Bool, origin: SIMD3<Float>, scale: SIMD2<Float>, angleZ: Float,
             tint: SIMD4<Float>, visible: Bool, lighting: Bool,
             roughness: Float, metallic: Float, specularTint: SIMD3<Float>) {
            self.texture = texture; self.size = size; self.parent = parent; self.order = order
            self.additive = additive
            self.depthTest = depthTest; self.depthWrite = depthWrite; self.effects = effects
            self.texWidth = texWidth; self.texHeight = texHeight; self.isFrameBuffer = isFrameBuffer
            baseOrigin = origin; baseScale = scale; baseAngleZ = angleZ; baseTint = tint; baseVisible = visible
            self.lighting = lighting; self.roughness = roughness; self.metallic = metallic
            self.specularTint = specularTint
            self.origin = origin; self.scale = scale; self.angleZ = angleZ; self.tint = tint; self.visible = visible
        }
        func evaluateScripts(time: Float) {
            var o = baseOrigin, s = baseScale, a = baseAngleZ, t = baseTint
            for sc in scripts {
                sc.engine.setRuntime(Double(time))
                switch sc.key {
                case "origin": if let v = sc.engine.evaluateVec(current: [o.x, o.y, o.z]), v.count >= 3 { o = SIMD3(v[0], v[1], v[2]) }
                case "angles": if let v = sc.engine.evaluateVec(current: [0, 0, a]), v.count >= 3 { a = v[2] }
                case "scale":  if let v = sc.engine.evaluateVec(current: [s.x, s.y, 1]), v.count >= 2 { s = SIMD2(v[0], v[1]) }
                case "color":  if let v = sc.engine.evaluateVec(current: [t.x, t.y, t.z]), v.count >= 3 { t = SIMD4(v[0], v[1], v[2], t.w) }
                case "alpha":  if let v = sc.engine.evaluateVec(current: [t.w]), let a = v.first { t.w = a }
                case "visible": visible = sc.engine.evaluateBool(current: visible) ?? visible
                default: break
                }
            }
            origin = o; scale = s; angleZ = a; tint = t
        }
    }

    // ── 3D 씬(메시) 경로 ─────────────────────────────────────────────────────────

    /// .mdl 로드 → 서브메시별 버퍼/텍스처 → MeshRenderable, 2D 이미지 레이어 → Billboard3D,
    /// 그룹/모델 → Node3D(변환 계층). 프로퍼티 스크립트 엔진은 **씬 order** 로 로드(컨트롤러 top-level
    /// 사이드이펙트가 이를 읽는 스크립트보다 먼저) 후 per-frame 평가. 실패 오브젝트는 스킵+로그.
    func build3D(doc: SceneDocument, package: ScenePackage, device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: Mesh3DShaders.source, options: nil) else {
            NSLog("%@", "[Waple] 3D: mesh shader compile failed")
            return
        }
        scene3DLights = doc.lights3D
        scene3DAmbient = SIMD3(doc.ambientColor.x, doc.ambientColor.y, doc.ambientColor.z)
        scene3DSkylight = SIMD3(doc.skylightColor.x, doc.skylightColor.y, doc.skylightColor.z)
        meshPipelineOver = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: false, device: device)
        meshPipelineAdditive = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: true, device: device)
        meshPipelineSkin = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: false, device: device)
        meshPipelineSkinAdditive = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: true, device: device)
        shadowPipelineStaticOpaque = shadow3DPipeline(lib: lib, vertex: "sv_main", cutout: false, device: device)
        shadowPipelineStaticCutout = shadow3DPipeline(lib: lib, vertex: "sv_main", cutout: true, device: device)
        shadowPipelineSkinOpaque = shadow3DPipeline(lib: lib, vertex: "sv_skin", cutout: false, device: device)
        shadowPipelineSkinCutout = shadow3DPipeline(lib: lib, vertex: "sv_skin", cutout: true, device: device)
        let shadowDepth = MTLDepthStencilDescriptor()
        shadowDepth.depthCompareFunction = .less
        shadowDepth.isDepthWriteEnabled = true
        pointShadowDepthState = device.makeDepthStencilState(descriptor: shadowDepth)
        guard meshPipelineOver != nil else { return }

        // 카메라 프로퍼티 스크립트(eye/center/up/fov) 로드 — per-frame 재평가로 카메라 애니(젤다 fov 등).
        for key in ["eye", "center", "up", "fov"] {
            guard let src = doc.cameraScripts[key], let e = makeScriptEngine(src) else { continue }
            cameraScripts.append(Script3D(key: key, engine: e))
        }

        // ── 변환 계층 노드(그룹 + 모델 오브젝트). 모델도 다른 모델/빌보드의 부모가 될 수 있다. ──
        for g in doc.nodes3D {
            let n = Node3D(id: g.id, parent: g.parent,
                           origin: SIMD3(g.origin.x, g.origin.y, g.origin.z),
                           angles: SIMD3(g.angles.x, g.angles.y, g.angles.z),
                           scale: SIMD3(g.scale.x, g.scale.y, g.scale.z),
                           visible: g.visible, order: 0)
            attachScripts(n, sources: g.propertyScripts)
            nodes3D.append(n)
        }
        for o in doc.objects3D {
            let n = Node3D(id: o.id, parent: o.parent,
                           origin: SIMD3(o.origin.x, o.origin.y, o.origin.z),
                           angles: SIMD3(o.angles.x, o.angles.y, o.angles.z),
                           scale: SIMD3(o.scale.x, o.scale.y, o.scale.z),
                           visible: true, order: o.order)
            attachScripts(n, sources: o.propertyScripts)
            nodes3D.append(n)
        }

        // ── 메시 지오메트리(모델). 정적 비가시(조상 그룹) 판정은 base 트랜스폼 기준으로 프리컬 — 스크립트로
        //    다시 켜지는 서브트리는 드묾(젤다 link_adult 는 그룹 visible=false 고정). ──
        let compositeImageTextures = doc.layers.reduce(into: [Int: String]()) { acc, layer in
            guard layer.id != 0, !layer.textureEntryName.isEmpty else { return }
            acc[layer.id] = layer.textureEntryName
        }
        var loaded = 0, skipped = 0
        for obj in doc.objects3D {
            guard let model: Model3D = resolveRequiredAsset(
                [obj.model], package: package, decode: { Model3D.parse($0) }
            ) else {
                NSLog("%@", "[Waple] 3D: mdl load failed: \(obj.model)")
                skipped += 1
                continue
            }
            let boneCount = model.bones.count
            var meshes: [GPU3DMesh] = []
            var anySkinned = false
            for mesh in model.meshes {
                guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else { continue }
                // 스키닝 메시(v3): pos3+normal3+uv2+boneIdx4+weight4(16f) — GPU 정점 스키닝(mv_skin).
                // 정적 메시: pos3+normal3+uv2(8f). 본 인덱스는 boneCount-1 로 clamp(셰이더 OOB 방지).
                let skinned = mesh.skinned && boneCount > 0
                var packed = [Float]()
                packed.reserveCapacity(mesh.vertices.count * (skinned ? 16 : 8))
                for v in mesh.vertices {
                    packed.append(contentsOf: [v.position.x, v.position.y, v.position.z,
                                               v.normal.x, v.normal.y, v.normal.z,
                                               v.uv.x, v.uv.y])
                    if skinned {
                        let mx = UInt32(max(0, boneCount - 1))
                        packed.append(contentsOf: [Float(min(v.boneIndices.x, mx)), Float(min(v.boneIndices.y, mx)),
                                                   Float(min(v.boneIndices.z, mx)), Float(min(v.boneIndices.w, mx)),
                                                   v.weights.x, v.weights.y, v.weights.z, v.weights.w])
                    }
                }
                guard let vbuf = device.makeBuffer(bytes: packed, length: MemoryLayout<Float>.stride * packed.count),
                      let ibuf = mesh.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
                      let mat = loadMesh3DMaterial(mesh.material, package: package, device: device,
                                                   compositeImageTextures: compositeImageTextures)
                else { continue }
                if skinned { anySkinned = true }
                meshes.append(GPU3DMesh(vbuf: vbuf, ibuf: ibuf, indexCount: mesh.indices.count,
                                        texture: mat.texture, tint: mat.tint,
                                        roughness: mat.roughness, metallic: mat.metallic,
                                        specularTint: mat.specularTint, alphaCutoff: mat.alphaCutoff,
                                        shadowEligible: mat.shadowEligible, unlit: mat.unlit,
                                        cullBack: mat.cullBack, additive: mat.additive,
                                        depthTest: mat.depthTest, depthWrite: mat.depthWrite, skinned: skinned))
            }
            guard !meshes.isEmpty else { skipped += 1; continue }
            // 활성 애니(animationlayers) → 인덱스. 스키닝 모델만 bone 버퍼/모델 참조 보유.
            var animIndex = -1
            var boneRing: DynamicVertexBuffer? = nil
            var keepModel: Model3D? = nil
            if anySkinned {
                keepModel = model
                // 단일 공유 버퍼를 매 프레임 memcpy 하면 in-flight GPU 프레임(최대 3장)이 읽는 도중 CPU 가
                // 덮어써 본행렬이 찢긴다. 3슬롯 링(DynamicVertexBuffer)으로 슬롯을 로테이션해 경합을 회피.
                boneRing = DynamicVertexBuffer()
                // WAPLE_3D_BINDPOSE=1 → 애니 무시(skin=항등, 바인드 포즈)
                // — 스키닝 배선 정합 게이트(v2 정적과 비교).
                let bindPoseOnly = Self.debugFlag("WAPLE_3D_BINDPOSE")
                animIndex = (!bindPoseOnly && obj.animation != nil)
                    ? Model3DPose.resolveAnimation(model: model, layerName: obj.animation?.name)
                    : -1
            }
            meshRenderables.append(MeshRenderable(id: obj.id, meshes: meshes, order: obj.order, name: obj.name,
                                                  model: keepModel, animIndex: animIndex,
                                                  animRate: obj.animation?.rate ?? 1, boneRing: boneRing,
                                                  castShadow: obj.castShadow))
            loaded += 1
        }

        // ── 빌보드(2D 이미지 레이어). 텍스처 로딩은 2D 경로와 동일(assetData→TexImage→TexDecoder). ──
        var bbLoaded = 0, bbSkipped = 0
        for layer in doc.layers {
            let decoded: (pixels: Data, width: Int, height: Int)
            if layer.textureEntryName.isEmpty {
                decoded = (Data([255, 255, 255, 255]), 1, 1)
            } else {
                guard let resolved: (pixels: Data, width: Int, height: Int) = resolveRequiredAsset(
                    [layer.textureEntryName],
                    package: package,
                    decode: { data in
                        guard let tex = TexImage.parse(data) else { return nil }
                        return TexDecoder.rgba(from: tex, data: data, properties: variantProperties)
                    }
                ) else {
                    bbSkipped += 1
                    continue
                }
                decoded = resolved
            }
            guard let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else {
                bbSkipped += 1
                continue
            }
            let effW = layer.isFrameBuffer ? Int(max(1, projW)) : decoded.width
            let effH = layer.isFrameBuffer ? Int(max(1, projH)) : decoded.height
            var effects: [EffectGPU] = []
            for eff in layer.effects {
                if let translated = buildTranslatedEffect(eff, package: package, device: device,
                                                          texW: effW, texH: effH) {
                    effects.append(translated)
                } else if let handPort = buildHandPortEffect(eff, package: package, device: device) {
                    effects.append(handPort)
                } else {
                    NSLog("%@", "[Waple] 3D billboard effect skipped: \(eff.name)")
                }
            }
            if !effects.isEmpty { hasEffects = true }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            let bb = Billboard3D(texture: mtl, size: SIMD2(layer.size.x, layer.size.y),
                                 parent: layer.parent, order: layer.order,
                                 additive: layer.blendMode == "additive",
                                 depthTest: layer.depthTest, depthWrite: layer.depthWrite,
                                 effects: effects, texWidth: effW, texHeight: effH,
                                 isFrameBuffer: layer.isFrameBuffer,
                                 origin: SIMD3(layer.origin.x, layer.origin.y, layer.originZ),
                                 scale: SIMD2(layer.scale.x, layer.scale.y), angleZ: layer.angleZ,
                                 tint: tint,
                                 visible: layer.initialVisible,
                                 lighting: layer.lighting,
                                 roughness: layer.roughness,
                                 metallic: layer.metallic,
                                 specularTint: SIMD3(layer.specularTint.x, layer.specularTint.y, layer.specularTint.z))
            attachScripts(bb, sources: layer.propertyScripts)
            billboards.append(bb)
            billboardDefs.append(layer)   // 록스텝(이벤트 마커 결속 — buildAnimationEventTargets)
            bbLoaded += 1
        }

        // ── per-frame 평가/그리기 순서(씬 order). 평가는 스크립트 보유 노드/빌보드만. ──
        var evalItems: [(order: Int, bb: Bool, idx: Int)] = []
        for (i, n) in nodes3D.enumerated() where !n.scripts.isEmpty { evalItems.append((n.order, false, i)) }
        for (i, b) in billboards.enumerated() where !b.scripts.isEmpty { evalItems.append((b.order, true, i)) }
        // 안정 정렬(order, 삽입순) — 2D 경로와 동일 규약. 동률 order 의 상대 순서 고정.
        eval3DOrder = evalItems.enumerated().sorted { ($0.1.order, $0.0) < ($1.1.order, $1.0) }.map { $0.1 }
        var drawItems: [(order: Int, bb: Bool, idx: Int)] = []
        for (i, m) in meshRenderables.enumerated() { drawItems.append((m.order, false, i)) }
        for (i, b) in billboards.enumerated() { drawItems.append((b.order, true, i)) }
        draw3DOrder = drawItems.enumerated().sorted { ($0.1.order, $0.0) < ($1.1.order, $1.0) }.map { $0.1 }
        // 카메라 스크립트 또는 활성 애니(스키닝) 가 있으면 연속 렌더 필요.
        let hasSkinAnim = meshRenderables.contains { $0.animIndex >= 0 }
        has3DScripts = !eval3DOrder.isEmpty || !cameraScripts.isEmpty || hasSkinAnim

        NSLog("%@", "[Waple] 3D scene: \(loaded) meshes (\(skipped) skipped), \(bbLoaded) billboards (\(bbSkipped) skipped), " +
              "\(nodes3D.count) nodes, \(eval3DOrder.count) scripted, lights=\(doc.lights3D.count)")
    }

    /// 노드/빌보드에 프로퍼티 스크립트 엔진 부착(씬 공유 컨텍스트 — top-level 사이드이펙트가 로드 시점에 실행).
    func attachScripts(_ n: Node3D, sources: [String: String]) {
        for key in ["visible", "origin", "angles", "scale"] {
            guard let src = sources[key], let e = makeScriptEngine(src) else { continue }
            n.scripts.append(Script3D(key: key, engine: e))
        }
    }
    func attachScripts(_ b: Billboard3D, sources: [String: String]) {
        for key in ["visible", "origin", "angles", "scale", "color", "alpha"] {
            guard let src = sources[key], let e = makeScriptEngine(src) else { continue }
            b.scripts.append(Script3D(key: key, engine: e))
        }
    }

    struct Mesh3DMaterialInfo {
        let texture: MTLTexture
        let tint: SIMD4<Float>
        let roughness: Float
        let metallic: Float
        let specularTint: SIMD3<Float>
        let alphaCutoff: Float
        let shadowEligible: Bool
        let unlit: Bool
        let cullBack: Bool
        let additive: Bool
        let depthTest: Bool
        let depthWrite: Bool
    }

    /// 머티리얼 JSON(passes[0]) → 텍스처/블렌드/컬/뎁스 플래그. 로드 실패 → 흰 텍스처 + 기본 플래그.
    /// 규약: textures[] 첫 non-null 이름 → "materials/<이름>.tex"(resolveTexture 폴백 포함).
    /// nil = 디바이스 텍스처 생성 실패(흰색 1x1 폴백조차 불가)뿐 — 호출자는 서브메시 스킵.
    func loadMesh3DMaterial(_ path: String, package: ScenePackage, device: MTLDevice,
                            compositeImageTextures: [Int: String] = [:]) -> Mesh3DMaterialInfo? {
        var texName: String? = nil
        var color = SIMD3<Float>(1, 1, 1)
        var alpha: Float = 1
        var cullBack = true
        var additive = false
        var alphaCutoff: Float = 0
        var depthTest = true, depthWrite = true
        var pbr = Scene3DMaterialValues()
        var shadowEligible = true
        var unlit = false
        if let d = quietAssetData(path, package: package),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let p0 = (j["passes"] as? [Any])?.first as? [String: Any] {
            texName = (p0["textures"] as? [Any])?.compactMap { $0 as? String }.first { !$0.isEmpty }
            cullBack = (p0["cullmode"] as? String) != "nocull"
            let blend = (p0["blending"] as? String) ?? "normal"
            additive = blend == "additive"
            if blend == "alphatocoverage" { alphaCutoff = 0.5 }  // MSAA 없는 컷아웃 근사(discard)
            shadowEligible = blend == "normal" || blend == "alphatocoverage"
            depthTest = (p0["depthtest"] as? String) != "disabled"
            depthWrite = (p0["depthwrite"] as? String) != "disabled"
            // combos.LIGHTING==0 → unlit(풀브라이트 albedo, generic4.frag:124-125). WE 기본 LIGHTING=1(lit). 키 대소문자 무시(2D SceneDocument:646 규약).
            if let combos = p0["combos"] as? [String: Any],
               let v = combos.first(where: { $0.key.lowercased() == "lighting" })?.value {
                unlit = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 1) == 0
            }
            if let csv = p0["constantshadervalues"] as? [String: Any] {
                pbr = Scene3DMaterialValues.parse(csv)
                func fvec(_ any: Any?) -> [Float]? {
                    if let s = any as? String { return s.split(separator: " ").compactMap { Float($0) } }
                    if let n = any as? Double { return [Float(n)] }
                    if let i = any as? Int { return [Float(i)] }
                    if let d = any as? [String: Any] { return fvec(d["value"]) }  // 스크립트 바인딩 → 초기값
                    return nil
                }
                if let c = fvec(csv["Color"] ?? csv["color"]), c.count >= 3 { color = SIMD3(c[0], c[1], c[2]) }
                if let a = fvec(csv["Alpha"] ?? csv["alpha"])?.first { alpha = a }
            }
        } else {
            NSLog("%@", "[Waple] 3D: material json missing: \(path)")
        }
        if let name = texName, let id = imageLayerCompositeID(name) {
            texName = compositeImageTextures[id]
            if texName == nil {
                return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map {
                    Mesh3DMaterialInfo(texture: $0, tint: SIMD4(color.x, color.y, color.z, alpha),
                                       roughness: pbr.roughness, metallic: pbr.metallic,
                                       specularTint: pbr.specularTint,
                                       alphaCutoff: alphaCutoff, shadowEligible: shadowEligible,
                                       unlit: unlit, cullBack: cullBack, additive: additive,
                                       depthTest: depthTest, depthWrite: depthWrite)
                }
            }
        }
        guard let tex = resolveTexture(texName, package: package, device: device) else { return nil }
        return Mesh3DMaterialInfo(texture: tex, tint: SIMD4(color.x, color.y, color.z, alpha),
                                  roughness: pbr.roughness, metallic: pbr.metallic,
                                  specularTint: pbr.specularTint,
                                  alphaCutoff: alphaCutoff, shadowEligible: shadowEligible,
                                  unlit: unlit, cullBack: cullBack, additive: additive,
                                  depthTest: depthTest, depthWrite: depthWrite)
    }

    private func imageLayerCompositeID(_ name: String) -> Int? {
        guard name.hasPrefix("_rt_imageLayerComposite_") else { return nil }
        let rest = name.dropFirst("_rt_imageLayerComposite_".count)
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 메시 파이프라인(bgra8 + depth32Float). 프래그먼트가 premultiplied 출력 → src=one,
    /// over: dst=1-srcAlpha, additive: dst=one(가산). vertex = "mv_main"(정적) | "mv_skin"(GPU 스키닝).
    func mesh3DPipeline(lib: MTLLibrary, vertex: String, additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: vertex)
        pd.fragmentFunction = lib.makeFunction(name: "mf_main")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    func shadow3DPipeline(lib: MTLLibrary, vertex: String, cutout: Bool,
                         device: MTLDevice) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = lib.makeFunction(name: vertex)
        descriptor.fragmentFunction = cutout ? lib.makeFunction(name: "sf_cutout") : nil
        descriptor.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func meshDepthState(test: Bool, write: Bool, device: MTLDevice) -> MTLDepthStencilState? {
        let key = "\(test)-\(write)"
        if let s = meshDepthStates[key] { return s }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = test ? .less : .always
        d.isDepthWriteEnabled = write
        guard let s = device.makeDepthStencilState(descriptor: d) else { return nil }
        meshDepthStates[key] = s
        return s
    }

    /// 뎁스 텍스처(크기별 캐시). 메시 패스 전용 — 컬러 풀(pooledOffscreen)과 분리.
    func pooledDepth(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let key = "\(max(w, 1))x\(max(h, 1))"
        if let t = depthTextures[key] { return t }
        // 크기 변경(리사이즈/캡처) 시 이전 크기 evict — 뎁스는 패스 내 일시 자원(storeAction .dontCare)
        // 이라 프레임 간 내용 지속이 없고, 한 시점엔 한 타깃 크기만 쓴다.
        depthTextures.removeAll()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                         width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        depthTextures[key] = t
        return t
    }

    /// point 하나당 native 2×3 face atlas 한 slice. drawable 크기와 무관하게 씬 동안 유지한다.
    func pointShadowTexture(sliceCount: Int, device: MTLDevice) -> MTLTexture? {
        guard sliceCount > 0 else { return nil }
        if pointShadowAtlasSlices == sliceCount, let pointShadowAtlas { return pointShadowAtlas }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .depth32Float
        descriptor.width = PointShadowMath.faceResolution * PointShadowMath.atlasColumns
        descriptor.height = PointShadowMath.faceResolution * PointShadowMath.atlasRows
        descriptor.arrayLength = sliceCount
        descriptor.mipmapLevelCount = 1
        descriptor.sampleCount = 1
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            pointShadowAtlas = nil; pointShadowAtlasSlices = 0
            return nil
        }
        pointShadowAtlas = texture
        pointShadowAtlasSlices = sliceCount
        return texture
    }

    /// 스키닝 본 버퍼를 그림자 6면/메인 패스가 공유하도록 프레임당 정확히 한 번 적재한다.
    func prepare3DSkinBuffers(time: Float, device: MTLDevice) -> [Int: MTLBuffer] {
        var result: [Int: MTLBuffer] = [:]
        for (index, renderable) in meshRenderables.enumerated() {
            guard let model = renderable.model, let ring = renderable.boneRing, !model.bones.isEmpty else { continue }
            let matrices = Model3DPose.skinMatrices(
                model: model, animation: renderable.animIndex, time: time, rate: renderable.animRate)
            guard !matrices.isEmpty, let buffer = ring.load(matrices, device: device) else { continue }
            result[index] = buffer
        }
        return result
    }

    /// `castShadow` point의 6면을 2×3 viewport에 렌더한다. 실패 시 해당 프레임 shadow metadata를 끈다.
    func encodePointShadows(resolvedLights: [Scene3DResolvedLight],
                            lights: inout [Scene3DLightUniform],
                            nodes: [Int: Scene3DMath.Node],
                            skinBuffers: [Int: MTLBuffer],
                            commandBuffer: MTLCommandBuffer,
                            device: MTLDevice) -> (texture: MTLTexture?, matrices: [simd_float4x4]) {
        var matrices = [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)
        let sliceCount = Scene3DLighting.shadowSliceCount(lights)
        guard sliceCount > 0 else { return (nil, matrices) }

        func disableShadows() {
            for index in lights.indices { lights[index].shadow = SIMD4(-1, -1, 0, 0) }
        }
        guard let atlas = pointShadowTexture(sliceCount: sliceCount, device: device),
              let depthState = pointShadowDepthState,
              shadowPipelineStaticOpaque != nil,
              shadowPipelineStaticCutout != nil,
              shadowPipelineSkinOpaque != nil,
              shadowPipelineSkinCutout != nil else {
            disableShadows()
            return (nil, matrices)
        }

        for (lightIndex, light) in resolvedLights.enumerated() where lightIndex < lights.count {
            let sliceValue = lights[lightIndex].shadow.x
            guard sliceValue >= 0 else { continue }
            let slice = Int(sliceValue)
            let faceMatrices = PointShadowMath.faceViewProjections(
                position: light.position, radius: light.colorRadius.w)
            guard faceMatrices.count == 6 else {
                Scene3DLighting.disableShadow(at: lightIndex, in: &lights)
                continue
            }
            for face in 0..<6 { matrices[slice * 6 + face] = faceMatrices[face] }

            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = atlas
            pass.depthAttachment.slice = slice
            pass.depthAttachment.level = 0
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                Scene3DLighting.disableShadow(at: lightIndex, in: &lights)
                continue
            }
            encoder.setFrontFacing(.counterClockwise)
            encoder.setDepthStencilState(depthState)
            // [Waple stability policy] native Metal raster bias 상수는 미확정. acne만 억제하는 최소 정책값.
            encoder.setDepthBias(1, slopeScale: 1.5, clamp: 0)

            for face in 0..<6 {
                let cell = PointShadowMath.atlasCell(face)
                let originX = cell.x * PointShadowMath.faceResolution
                let originY = cell.y * PointShadowMath.faceResolution
                encoder.setViewport(MTLViewport(
                    originX: Double(originX), originY: Double(originY),
                    width: Double(PointShadowMath.faceResolution),
                    height: Double(PointShadowMath.faceResolution), znear: 0, zfar: 1))
                encoder.setScissorRect(MTLScissorRect(
                    x: originX, y: originY,
                    width: PointShadowMath.faceResolution, height: PointShadowMath.faceResolution))

                for (renderableIndex, renderable) in meshRenderables.enumerated() where renderable.castShadow {
                    guard let world = Scene3DMath.worldMatrix(id: renderable.id, nodes: nodes), world.visible else { continue }
                    var uniform = MeshUniform(
                        mvp: faceMatrices[face] * world.matrix,
                        model: world.matrix,
                        normalMatrix: Scene3DMath.normalMatrix4x4(world.matrix),
                        tint: SIMD4(1, 1, 1, 1),
                        material: SIMD4(0.7, 0, 0, 1),
                        specularTint: SIMD4(1, 1, 1, 0))
                    for mesh in renderable.meshes where mesh.shadowEligible {
                        let skinBuffer = skinBuffers[renderableIndex]
                        if mesh.skinned && skinBuffer == nil { continue }
                        let cutout = mesh.alphaCutoff > 0
                        let pipeline: MTLRenderPipelineState?
                        if mesh.skinned {
                            pipeline = cutout ? shadowPipelineSkinCutout : shadowPipelineSkinOpaque
                        } else {
                            pipeline = cutout ? shadowPipelineStaticCutout : shadowPipelineStaticOpaque
                        }
                        guard let pipeline else { continue }
                        uniform.tint = mesh.tint
                        uniform.material.z = mesh.alphaCutoff
                        encoder.setRenderPipelineState(pipeline)
                        encoder.setCullMode(mesh.cullBack ? .back : .none)
                        encoder.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                        encoder.setVertexBytes(&uniform, length: MemoryLayout<MeshUniform>.stride, index: 1)
                        if let skinBuffer { encoder.setVertexBuffer(skinBuffer, offset: 0, index: 2) }
                        if cutout {
                            encoder.setFragmentBytes(&uniform, length: MemoryLayout<MeshUniform>.stride, index: 1)
                            encoder.setFragmentTexture(mesh.texture, index: 0)
                        }
                        encoder.drawIndexedPrimitives(
                            type: .triangle, indexCount: mesh.indexCount, indexType: .uint16,
                            indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                    }
                }
            }
            encoder.endEncoding()
        }
        return (atlas, matrices)
    }

    /// Metal encoder는 framebuffer billboard에서 재생성되므로 scene-wide PBR 상수를 한 곳에서 재바인드한다.
    func bindScene3DLighting(frame: inout Scene3DFrameUniform,
                            lights: [Scene3DLightUniform],
                            shadowMatrices: [simd_float4x4],
                            shadowTexture: MTLTexture?,
                            into encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Scene3DFrameUniform>.stride, index: 2)
        lights.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setFragmentBytes(base, length: bytes.count, index: 3)
        }
        shadowMatrices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setFragmentBytes(base, length: bytes.count, index: 4)
        }
        encoder.setFragmentTexture(shadowTexture, index: 1)
    }

    /// 3D 메시 패스: target 에 clearColor 로 클리어 + 뎁스(.less) 붙여 씬 순서대로 드로우.
    /// 실측 확정 규약(3737268876/3662790108/3706286085 A/B 캡처 vs preview, 2026-07-03):
    ///   • 와인딩: front = CCW — 우수(RH) lookAt/proj 아래 CW 는 젤다 회랑이 인사이드아웃
    ///     (근접 벽 컬링 → 뒤 외벽 노출), CCW 는 벽/바닥/아치가 preview 와 일치
    ///   • UV 원점: 상단(v 플립 없음) — 플립 시 담쟁이/이끼가 벽 상단으로 감(Mesh3DShaders 주석)
    ///   • fov: 세로축 — 젤다 회랑 상하 구도가 정합(가로 해석은 세로 화각 29° 로 좁아져 아치 잘림).
    ///     코퍼스 3씬 전부 fov 50 이라 축 구분 실물 반례는 없음(표준 규약 채택)
    ///   • 오일러: Rz·Ry·Rx (Scene3DMath.modelMatrix 주석 — 짐벌 동치 실측)
    func encode3D(into target: MTLTexture, cb: MTLCommandBuffer, device: MTLDevice, time: Float) -> Bool {
        guard let cam = camera3D, let over = meshPipelineOver,
              let depthTex = pooledDepth(target.width, target.height, device) else { return false }
        // per-frame 스크립트 평가(씬 order — 컨트롤러가 이를 읽는 스크립트보다 먼저) → 현재 로컬 변환/가시성.
        for e in eval3DOrder {
            if e.bb { billboards[e.idx].evaluateScripts(time: time) }
            else { nodes3D[e.idx].evaluateScripts(time: time) }
        }
        // 현재 로컬 변환으로 계층 노드 맵 재구성(월드행렬 합성 입력).
        var nmap: [Int: Scene3DMath.Node] = [:]
        nmap.reserveCapacity(nodes3D.count)
        for n in nodes3D {
            nmap[n.id] = Scene3DMath.Node(origin: n.origin, angles: n.angles, scale: n.scale,
                                          parent: n.parent, visible: n.visible)
        }
        var billboardTextures: [Int: MTLTexture] = [:]
        for (i, bb) in billboards.enumerated() where !bb.effects.isEmpty && !bb.isFrameBuffer {
            var current = bb.texture
            for eff in bb.effects {
                guard let next = pooledOffscreen(bb.texWidth, bb.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, time: time, cb: cb)
                current = next
            }
            billboardTextures[i] = current
        }
        let aspect = Float(target.width) / Float(max(1, target.height))
        // 카메라 프로퍼티 스크립트 per-frame 재평가(eye/center/up → Vec3, fov → 스칼라). 무스크립트면 base 고정.
        var eye = SIMD3(cam.eye.x, cam.eye.y, cam.eye.z)
        var ctr = SIMD3(cam.center.x, cam.center.y, cam.center.z)
        var upv = SIMD3(cam.up.x, cam.up.y, cam.up.z)
        var fov = cam.fov
        for sc in cameraScripts {
            sc.engine.setRuntime(Double(time))
            switch sc.key {
            case "eye":    if let v = sc.engine.evaluateVec(current: [eye.x, eye.y, eye.z]), v.count >= 3 { eye = SIMD3(v[0], v[1], v[2]) }
            case "center": if let v = sc.engine.evaluateVec(current: [ctr.x, ctr.y, ctr.z]), v.count >= 3 { ctr = SIMD3(v[0], v[1], v[2]) }
            case "up":     if let v = sc.engine.evaluateVec(current: [upv.x, upv.y, upv.z]), v.count >= 3 { upv = SIMD3(v[0], v[1], v[2]) }
            case "fov":    if let v = sc.engine.evaluateVec(current: [fov]), let f = v.first, f > 0 { fov = f }
            default: break
            }
        }
        // eye/center 는 fov(f > 0)처럼 개별검증할 수 없다 — 둘 다 유효한 유한값이어도 조합(eye==center)이
        // 퇴화할 수 있어 루프 종료 후 합쳐서 검사. 퇴화/비유한 시 lookAt 이 영벡터를 정규화해 NaN 이
        // viewProj 전체로 전파(빈 프레임, 감사 C2) — 그 프레임만 스크립트 적용 전 베이스 카메라로 폴백.
        let lookLen = simd_length(ctr - eye)
        if !lookLen.isFinite || lookLen < 1e-4 {
            eye = SIMD3(cam.eye.x, cam.eye.y, cam.eye.z)
            ctr = SIMD3(cam.center.x, cam.center.y, cam.center.z)
        }
        let view = Scene3DMath.lookAt(eye: eye, center: ctr, up: upv)
        let proj = Scene3DMath.perspective(fovYDegrees: fov, aspect: aspect,
                                           nearZ: cam.nearZ, farZ: cam.farZ)
        let viewProj = proj * view
        // 빌보드 카메라-페이싱 축(월드): right/up(lookAt 과 동일 규약).
        let fwd = simd_normalize(ctr - eye)
        let right = simd_normalize(simd_cross(fwd, upv))
        let camUp = simd_cross(right, fwd)
        let resolvedLights = Scene3DLighting.resolvePointLights(scene3DLights, nodes: nmap)
        var frameUniform = Scene3DFrameUniform(
            cameraEye: SIMD4(eye.x, eye.y, eye.z, 1),
            ambient: SIMD4(scene3DAmbient.x, scene3DAmbient.y, scene3DAmbient.z, 0),
            skylight: SIMD4(scene3DSkylight.x, scene3DSkylight.y, scene3DSkylight.z, 0),
            meta: SIMD4(Float(resolvedLights.count), 0, 0, 0))
        var lightUniforms = Scene3DLighting.packLights(resolvedLights)
        let skinBuffers = prepare3DSkinBuffers(time: time, device: device)
        let shadowResult = encodePointShadows(
            resolvedLights: resolvedLights, lights: &lightUniforms, nodes: nmap,
            skinBuffers: skinBuffers, commandBuffer: cb, device: device)
        if let shadowTexture = shadowResult.texture {
            frameUniform.meta.y = 1 / Float(shadowTexture.width)
            frameUniform.meta.z = 1 / Float(shadowTexture.height)
            // [Waple stability policy] receiver depth-space bias; native CPU/Metal 상수는 미확정.
            frameUniform.meta.w = 0.001
        }
        let needsDepthStore = billboards.contains { $0.isFrameBuffer }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = needsDepthStore ? .store : .dontCare
        guard var enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        // 와인딩: front = CCW(A/B 실측 — CW 는 젤다 회랑이 인사이드아웃: 근접 벽이 컬링되어
        // 뒤쪽 외벽이 보임). cullmode "normal" 메시가 CCW-front 백페이스 컬에서 preview 와 일치.
        enc.setFrontFacing(.counterClockwise)
        bindScene3DLighting(frame: &frameUniform, lights: lightUniforms,
                            shadowMatrices: shadowResult.matrices, shadowTexture: shadowResult.texture,
                            into: enc)
        let debug3D = Self.debugFlag("WAPLE_3D_DEBUG")
        for item in draw3DOrder {
            if item.bb {
                let bb = billboards[item.idx]
                if bb.isFrameBuffer {
                    enc.endEncoding()
                    var srcTex: MTLTexture? = nil
                    if let snap = pooledOffscreen(target.width, target.height, device, bgra: true),
                       let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: target, to: snap)
                        blit.endEncoding()
                        var current: MTLTexture = snap
                        for eff in bb.effects {
                            guard let next = pooledOffscreen(target.width, target.height, device) else { break }
                            applyEffect(eff, src: current, dst: next, time: time, cb: cb)
                            current = next
                        }
                        srcTex = current
                    }
                    let nextRPD = MTLRenderPassDescriptor()
                    nextRPD.colorAttachments[0].texture = target
                    nextRPD.colorAttachments[0].loadAction = .load
                    nextRPD.depthAttachment.texture = depthTex
                    nextRPD.depthAttachment.loadAction = .load
                    nextRPD.depthAttachment.storeAction = needsDepthStore ? .store : .dontCare
                    guard let nextEnc = cb.makeRenderCommandEncoder(descriptor: nextRPD) else { return false }
                    enc = nextEnc
                    enc.setFrontFacing(.counterClockwise)
                    bindScene3DLighting(frame: &frameUniform, lights: lightUniforms,
                                        shadowMatrices: shadowResult.matrices,
                                        shadowTexture: shadowResult.texture, into: enc)
                    if let srcTex {
                        encodeBillboard(bb, overrideTexture: srcTex, viewProj: viewProj, eye: eye,
                                        right: right, up: camUp,
                                        nmap: nmap, into: enc, device: device, over: over)
                    }
                } else {
                    encodeBillboard(bb, overrideTexture: billboardTextures[item.idx], viewProj: viewProj, eye: eye,
                                    right: right, up: camUp,
                                    nmap: nmap, into: enc, device: device, over: over)
                }
            } else {
                let mr = meshRenderables[item.idx]
                guard let w = Scene3DMath.worldMatrix(id: mr.id, nodes: nmap), w.visible else { continue }
                if debug3D {
                    let c = viewProj * w.matrix * SIMD4<Float>(0, 0, 0, 1)
                    NSLog("%@", "[Waple3D] draw '\(mr.name)' ndc=\(c.w != 0 ? SIMD3(c.x, c.y, c.z) / c.w : .zero) w=\(c.w)")
                }
                var u = MeshUniform(
                    mvp: viewProj * w.matrix,
                    model: w.matrix,
                    normalMatrix: Scene3DMath.normalMatrix4x4(w.matrix),
                    tint: SIMD4(1, 1, 1, 1),
                    material: SIMD4(0.7, 0, 0, 1),
                    specularTint: SIMD4(1, 1, 1, 0))
                let boneBuf = skinBuffers[item.idx]
                for mesh in mr.meshes {
                    // 스키닝 메시(16f 패킹)는 반드시 스키닝 파이프라인 필요 — 본버퍼 미준비면 스킵(8f 셰이더로 오독 방지).
                    if mesh.skinned && boneBuf == nil { continue }
                    u.tint = mesh.tint
                    u.material = SIMD4(mesh.roughness, mesh.metallic, mesh.alphaCutoff, mesh.unlit ? 0 : 1)
                    u.specularTint = SIMD4(mesh.specularTint.x, mesh.specularTint.y, mesh.specularTint.z, 0)
                    let useSkin = mesh.skinned && boneBuf != nil
                    let pipe: MTLRenderPipelineState
                    if useSkin { pipe = mesh.additive ? (meshPipelineSkinAdditive ?? meshPipelineSkin ?? over) : (meshPipelineSkin ?? over) }
                    else { pipe = mesh.additive ? (meshPipelineAdditive ?? over) : over }
                    enc.setRenderPipelineState(pipe)
                    if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                        enc.setDepthStencilState(ds)
                    }
                    enc.setCullMode(mesh.cullBack ? .back : .none)
                    enc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    if useSkin, let boneBuf { enc.setVertexBuffer(boneBuf, offset: 0, index: 2) }
                    enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    enc.setFragmentTexture(mesh.texture, index: 0)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint16, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                }
            }
        }
        enc.endEncoding()
        return true
    }

    /// 카메라-페이싱 빌보드 1장: 월드 위치 = (부모월드 · 로컬변환) 원점, 반경 = size/2 × 합성 스케일.
    /// 쿼드 4코너를 카메라 right/up 축으로 전개(월드 좌표) → mvp=viewProj. 뎁스 테스트 유지·미기록(투명),
    /// 양면, over(premult) 블렌드. 부모 서브트리 비가시/자기 비가시면 스킵.
    func encodeBillboard(_ bb: Billboard3D, overrideTexture: MTLTexture? = nil, viewProj: simd_float4x4,
                                 eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                                 nmap: [Int: Scene3DMath.Node],
                                 into enc: MTLRenderCommandEncoder, device: MTLDevice, over: MTLRenderPipelineState) {
        var pWorld = matrix_identity_float4x4
        if let pid = bb.parent {
            guard let pw = Scene3DMath.worldMatrix(id: pid, nodes: nmap), pw.visible else { return }
            pWorld = pw.matrix
        }
        if !bb.visible { return }
        // 로컬: 이동(origin) + 스케일(빌보드는 카메라-페이싱이라 로컬 회전은 무시). 부모월드가 나머지 계층 폴드.
        let local = Scene3DMath.modelMatrix(origin: bb.origin, angles: SIMD3<Float>(0, 0, 0),
                                            scale: SIMD3(bb.scale.x, bb.scale.y, 1))
        let m = pWorld * local
        let center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // 합성 스케일 크기(부모 스케일 포함) — 열 벡터 길이가 회전 무관하게 축별 배율을 준다.
        let sx = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let hw = bb.size.x * 0.5 * sx
        let hh = bb.size.y * 0.5 * sy
        guard hw > 0, hh > 0, hw.isFinite, hh.isFinite else { return }
        let ca = cos(bb.angleZ), sa = sin(bb.angleZ)
        let rollRight = right * ca + up * sa
        let rollUp = -right * sa + up * ca
        let r = rollRight * hw, u = rollUp * hh
        let receiverNormal: SIMD3<Float>
        let toEye = eye - center
        if simd_length_squared(toEye) > 1e-12 { receiverNormal = simd_normalize(toEye) }
        else { receiverNormal = -simd_normalize(simd_cross(rollRight, rollUp)) }
        // UV 상단 원점: 상단 = +up. TL(0,0) TR(1,0) BR(1,1) BL(0,1).
        let tl = center - r + u, tr = center + r + u, br = center + r - u, bl = center - r - u
        func vtx(_ p: SIMD3<Float>, _ uu: Float, _ vv: Float) -> [Float] {
            [p.x, p.y, p.z, receiverNormal.x, receiverNormal.y, receiverNormal.z, uu, vv]
        }
        var verts: [Float] = []
        verts.reserveCapacity(48)
        verts += vtx(tl, 0, 0); verts += vtx(tr, 1, 0); verts += vtx(br, 1, 1)
        verts += vtx(tl, 0, 0); verts += vtx(br, 1, 1); verts += vtx(bl, 0, 1)
        guard let vbuf = bb.scratchQuad.load(verts, device: device) else { return }
        var u2 = MeshUniform(
            mvp: viewProj,
            model: matrix_identity_float4x4,
            normalMatrix: matrix_identity_float4x4,
            tint: bb.tint,
            material: SIMD4(bb.roughness, bb.metallic, 0, bb.lighting ? 2 : 0),
            specularTint: SIMD4(bb.specularTint.x, bb.specularTint.y, bb.specularTint.z, 0))
        // 머티리얼 blending=additive → 가산 파이프라인(플레어/글로우 광량 복원). 그 외 premult-over.
        enc.setRenderPipelineState(bb.additive ? (meshPipelineAdditive ?? over) : over)
        if let ds = meshDepthState(test: bb.depthTest, write: bb.depthWrite, device: device) { enc.setDepthStencilState(ds) }
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentTexture(overrideTexture ?? bb.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
