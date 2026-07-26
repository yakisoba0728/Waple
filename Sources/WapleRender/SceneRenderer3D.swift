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
        let rimLighting: Bool        // combos.RIMLIGHTING==1(F274) — g_RimAmount/g_RimExponent 림 부스트
        let shadingGradient: Bool    // combos.SHADINGGRADIENT==1(F274) — g_Texture4 툰 그래디언트 룩업
        let rimAmount: Float
        let rimExponent: Float
        let gradientTexture: MTLTexture?   // shadingGradient 일 때만 non-nil(항상 "gradient/gradient_toon_smooth")
        let foggy: Bool              // F662: combos.FOG!=0(기본 1) — scene fog 참여(FOG:0 명시 머티리얼만 제외)
        /// F661: 로컬 AABB(정점 min/max, 바인드 포즈) — directional 오소 섀도우 피팅 입력.
        let boundsMin: SIMD3<Float>
        let boundsMax: SIMD3<Float>
        /// H1 Phase 2: 커스텀 머티리얼 셰이더 파이프라인 — nil = Mesh3DShaders 고정 경로.
        var customPipeline: MTLRenderPipelineState? = nil
        /// H1 스키닝: 커스텀 셰이더 메시용 CPU 프리스킨 8f 정점 링(스톡 GPU 본 스키닝 대신 rigid 계약).
        var customSkinRing: DynamicVertexBuffer? = nil
        /// CPU 프리스킨 입력 소스 — Model3D.meshes 인덱스(커스텀+스키닝 메시만 ≥0).
        var modelMeshIndex: Int = -1
        /// M3: PBR 노멀맵/마스크 텍스처 — nil = 미사용.
        var normalTexture: MTLTexture? = nil
        var maskTexture: MTLTexture? = nil
        /// H4: REFRACT 콤보(스크린 굴절) — true 면 acc 스냅샷을 노멀 오프셋 재샘플·곱(mf_refract).
        /// 노멀맵 로드 실패/스키닝/커스텀 셰이더 시 미적용(기존 파이프라인 폴터, 무크래시).
        var refract: Bool = false
        var refractAmount: Float = 0.05
        var refractNormal: MTLTexture? = nil   // textures[1] 노멀맵(resolveRefractNormal — rg88 플래그 동반)
        var refractRG88: Bool = false
    }
    /// MSL `MeshU`와 레이아웃 일치(3×float4x4 + 4×float4 = 256B).
    struct MeshUniform {
        var mvp: simd_float4x4
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var tint: SIMD4<Float>
        /// x=roughness, y=metallic, z=alphaCutoff, w=0 unlit / 1 mesh hemisphere / 2 image flat.
        var material: SIMD4<Float>
        var specularTint: SIMD4<Float>
        /// x=g_RimAmount, y=g_RimExponent, z=RIMLIGHTING on/off, w=SHADINGGRADIENT on/off(F274).
        var rim: SIMD4<Float>
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
        /// F811: doc.layers 인덱스(= JS thisScene.layers 인덱스 — sceneScriptLayers 의 이미지 선행 순서).
        /// 빌보드 배열은 로드 실패 레이어를 걸러 인덱스가 어긋나므로 디스크립터 정합 키를 별도 보관한다.
        let layerIndex: Int
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
             roughness: Float, metallic: Float, specularTint: SIMD3<Float>, layerIndex: Int = 0) {
            self.texture = texture; self.size = size; self.parent = parent; self.order = order
            self.additive = additive
            self.depthTest = depthTest; self.depthWrite = depthWrite; self.effects = effects
            self.texWidth = texWidth; self.texHeight = texHeight; self.isFrameBuffer = isFrameBuffer
            baseOrigin = origin; baseScale = scale; baseAngleZ = angleZ; baseTint = tint; baseVisible = visible
            self.lighting = lighting; self.roughness = roughness; self.metallic = metallic
            self.specularTint = specularTint
            self.origin = origin; self.scale = scale; self.angleZ = angleZ; self.tint = tint; self.visible = visible
            self.layerIndex = layerIndex
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

    /// F662: 패키지 scene.json 의 general 딕셔너리에서 scene fog 를 읽는다(SceneDocument 미파스 필드).
    /// scene.json 부재/파스 실패/general 부재 시 fog 비활성(기본값) — 어떤 입력에도 throw 없음.
    static func parseScene3DFog(package: ScenePackage) -> Scene3DFog {
        guard let data = package.data(for: "scene.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let general = json["general"] as? [String: Any] else { return Scene3DFog() }
        return Scene3DFog.parse(general: general)
    }

    /// .mdl 로드 → 서브메시별 버퍼/텍스처 → MeshRenderable, 2D 이미지 레이어 → Billboard3D,
    /// 그룹/모델 → Node3D(변환 계층). 프로퍼티 스크립트 엔진은 **씬 order** 로 로드(컨트롤러 top-level
    /// 사이드이펙트가 이를 읽는 스크립트보다 먼저) 후 per-frame 평가. 실패 오브젝트는 스킵+로그.
    func build3D(doc: SceneDocument, package: ScenePackage, device: MTLDevice) {
        guard let lib = try? WapleProfiler.compile(Mesh3DShaders.source, { try device.makeLibrary(source: Mesh3DShaders.source, options: nil) }) else {
            NSLog("%@", "[Waple] 3D: mesh shader compile failed")
            return
        }
        scene3DLights = doc.lights3D
        scene3DAmbient = SIMD3(doc.ambientColor.x, doc.ambientColor.y, doc.ambientColor.z)
        scene3DSkylight = SIMD3(doc.skylightColor.x, doc.skylightColor.y, doc.skylightColor.z)
        // F662(S-45): scene fog(general.fogdistance*/fogheight*) — SceneDocument 미파스 필드라
        // 패키지 scene.json 을 여기서 직독(Scene3DFog.parse). 읽기 실패/필드 부재 시 .disabled(fog 없음).
        scene3DFog = Self.parseScene3DFog(package: package)  // F745: 정식 저장 프로퍼티(F662 주석 참조)
        meshPipelineOver = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: false, device: device)
        meshPipelineAdditive = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: true, device: device)
        meshPipelineSkin = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: false, device: device)
        meshPipelineSkinAdditive = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: true, device: device)
        // M3: PBR 노멀맵/마스크 파이프라인(정적 메시 한정 — 스키닝은 탄젠트 부재로 미지원).
        meshPipelineNormal = mesh3DNormalPipeline(lib: lib, vertex: "mv_main", additive: false, device: device)
        meshPipelineNormalAdditive = mesh3DNormalPipeline(lib: lib, vertex: "mv_main", additive: true, device: device)
        // H4: REFRACT 메시 파이프라인(정적 메시 한정 — M3 와 동일 제약).
        meshPipelineRefract = mesh3DRefractPipeline(lib: lib, vertex: "mv_main", additive: false, device: device)
        meshPipelineRefractAdditive = mesh3DRefractPipeline(lib: lib, vertex: "mv_main", additive: true, device: device)
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
            for (modelMeshIdx, mesh) in model.meshes.enumerated() {
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
                // F661: 로컬 AABB(정점 min/max) — directional 오소 섀도우의 씬 바운드 피팅 입력.
                // MDL 헤더 AABB(V0017+)와 동치이나 V0016 은 헤더에 없어 정점에서 일괄 산출한다.
                var bMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
                var bMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
                for v in mesh.vertices {
                    bMin = simd_min(bMin, v.position)
                    bMax = simd_max(bMax, v.position)
                }
                var gpuMesh = GPU3DMesh(vbuf: vbuf, ibuf: ibuf, indexCount: mesh.indices.count,
                                        texture: mat.texture, tint: mat.tint,
                                        roughness: mat.roughness, metallic: mat.metallic,
                                        specularTint: mat.specularTint, alphaCutoff: mat.alphaCutoff,
                                        shadowEligible: mat.shadowEligible, unlit: mat.unlit,
                                        cullBack: mat.cullBack, additive: mat.additive,
                                        depthTest: mat.depthTest, depthWrite: mat.depthWrite, skinned: skinned,
                                        rimLighting: mat.rimLighting, shadingGradient: mat.shadingGradient,
                                        rimAmount: mat.rimAmount, rimExponent: mat.rimExponent,
                                        gradientTexture: mat.gradientTexture, foggy: mat.foggy,
                                        boundsMin: bMin, boundsMax: bMax)
                // H1 Phase 2: 커스텀 머티리얼 셰이더 파이프라인 빌드(실패 시 nil → Mesh3DShaders 폴터).
                // 스키닝 메시는 CPU 프리스킨(8f, prepare3DCustomSkinBuffers)으로 rigid 입력 계약을 맞춘다.
                if mat.customShader != nil {
                    gpuMesh.customPipeline = buildCustomMeshShader(mat, package: package, device: device)
                    if skinned && gpuMesh.customPipeline != nil {
                        gpuMesh.customSkinRing = DynamicVertexBuffer()
                        gpuMesh.modelMeshIndex = modelMeshIdx
                    }
                }
                // M3: PBR 노멀맵/마스크 텍스처 로드.
                if let normalName = mat.normalTextureName {
                    gpuMesh.normalTexture = resolveTexture(normalName, package: package, device: device)
                }
                if let maskName = mat.maskTextureName {
                    gpuMesh.maskTexture = resolveTexture(maskName, package: package, device: device)
                }
                // H4: REFRACT — 노멀맵(textures[1])을 resolveRefractNormal 로 로드(rg88 언팩 플래그 동반).
                // 콤보 꺼짐/노멀맵 부재/로드 실패 시 refract 미적용 → 기존 파이프라인 폴터(무크래시).
                if mat.refract, let normalName = mat.normalTextureName,
                   let n = resolveRefractNormal(normalName, package: package, device: device) {
                    gpuMesh.refract = true
                    gpuMesh.refractAmount = mat.refractAmount
                    gpuMesh.refractNormal = n.texture
                    gpuMesh.refractRG88 = n.rg88
                }
                meshes.append(gpuMesh)
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
        // 감사 V06(F721): ortho 하이브리드는 mount 가 빌보드/3D 텍스트를 전량 폐기하고 2D buildLayers/buildTexts
        // 가 같은 자산·스크립트를 재로드한다 — 이중 빌드(텍스처 디코드/효과 컴파일/스크립트 top-level 2회 실행)라
        // 빌보드/텍스트 빌드를 건 뛴다. 판정은 mount 의 하이브리드 진입 조건(:1098)과 동일하게 둔다
        // (objects3D 부재 씬의 build3D 직접 호출 — 테스트 하네스 — 은 종전대로 빌보드 빌드).
        // 노드/메시 스크립트는 2D 대응물이 없어 종전대로.
        let orthoHybrid = doc.camera3D == nil && !doc.objects3D.isEmpty
        for (bbLayerIndex, layer) in doc.layers.enumerated() where !orthoHybrid {   // bbLayerIndex = JS layers 인덱스(F811)
            // 빌보드 텍스처도 2D 와 동일 공유 경로(makeImageTexture): BC 는 네이티브 업로드, 그 외 CPU 폴백.
            let mtl: MTLTexture, texW: Int, texH: Int
            if layer.textureEntryName.isEmpty {
                guard let t = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) else { bbSkipped += 1; continue }
                mtl = t; texW = 1; texH = 1
            } else {
                guard let up: (texture: MTLTexture, width: Int, height: Int) = resolveRequiredAsset(
                    [layer.textureEntryName],
                    package: package,
                    decode: { data in
                        guard let tex = TexImage.parse(data) else { return nil }
                        return makeImageTexture(tex: tex, data: data, device: device)
                    }
                ) else {
                    bbSkipped += 1
                    continue
                }
                mtl = up.texture; texW = up.width; texH = up.height
            }
            let effW = layer.isFrameBuffer ? Int(max(1, projW)) : texW
            let effH = layer.isFrameBuffer ? Int(max(1, projH)) : texH
            var effects: [EffectGPU] = []
            for eff in layer.effects {
                // F733(S-5 잔여): compositeImageTextures 전달 — 2D 경로(F720, SceneRendererResources:235)와
                // 동형. 생략 시 기본 인자 [:] 로 `_rt_imageLayerComposite_<id>` 슬롯이 베이스 텍스처 치환 없이
                // 흰색 1×1 폴터로 바인드돼 blend/clipping_mask 계열 콘텐츠가 소실된다.
                if let translated = buildTranslatedEffect(eff, package: package, device: device,
                                                          texW: effW, texH: effH,
                                                          compositeImageTextures: compositeImageTextures) {
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
                                 specularTint: SIMD3(layer.specularTint.x, layer.specularTint.y, layer.specularTint.z),
                                 layerIndex: bbLayerIndex)
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
        // 3D 씬 text 컨트롤러 로드: 2D buildTexts(shared 통신용 엔진 로드)의 3D 대응. text 스크립트의
        // top-level + update 사이드이펙트(shared.vvv 등)가 3D 지오메트리 스크립트를 구동한다(미실행 시 NaN).
        // 픽셀 렌더는 미배선(3D 텍스트 스크린 오버레이 위치/크기 규약 미확정) — 사이드이펙트만 실행.
        for t in doc.texts where !orthoHybrid {   // 감사 V06: ortho 하이브리드는 미빌드(2D buildTexts 가 담당)
            guard let src = t.script, let e = makeScriptEngine(src, layerName: t.name.isEmpty ? nil : t.name,
                                                               scriptPropsJSON: t.scriptProps) else { continue }
            // makeScriptEngine 생성 시 top-level 실행(shared 초기화) — update 보유분만 per-frame 재평가 대상.
            if e.hasUpdate { text3DControllers.append((engine: e, last: t.text)) }
        }
        // 카메라 스크립트 또는 활성 애니(스키닝) 가 있으면 연속 렌더 필요.
        let hasSkinAnim = meshRenderables.contains { $0.animIndex >= 0 }
        has3DScripts = !eval3DOrder.isEmpty || !cameraScripts.isEmpty || hasSkinAnim || !text3DControllers.isEmpty

        // F309: mount 직후 1회 프라이밍 패스. encode3D 는 매 프레임 text3DControllers(:717-722 상당)를
        // eval3DOrder 보다 항상 먼저 평가한다 — 순서를 뒤집으면(eval3DOrder→text) 이번엔 text(배열
        // 후반)→mesh(배열 선두) 역전이 재도입돼(이 선행 평가 자체의 도입 사유) mesh 가 NaN을 물려받는다.
        // 매 프레임 2패스도 기각(누적 스크립트 value.x+=... 가 프레임당 2회 적분되어 속도가 2배로 깨짐).
        // 채택안(w3-architecture 판정): 현행 순서 그대로 build3D 직후 1회 예비 평가. 노드→text 의 유일한
        // 역전이 이 1회로 흡수되어 shared(예: 3470948192 id=56→181→115 체인의 shared.xx/vvv)가 실호출
        // 이전에 정착값을 갖는다 — 첫 캡처/라이브 프레임부터 유한값(라이브의 1프레임 지연은 정상 거동으로
        // 보존, 캡처는 항상 프레시 마운트라 두 프로덕션 호출부 무수정으로 함께 해결).
        evaluate3DScripts(time: 0)

        NSLog("%@", "[Waple] 3D scene: \(loaded) meshes (\(skipped) skipped), \(bbLoaded) billboards (\(bbSkipped) skipped), " +
              "\(nodes3D.count) nodes, \(eval3DOrder.count) scripted, lights=\(doc.lights3D.count)")
    }

    /// text 컨트롤러(shared 생산/소비) → eval3DOrder(노드/빌보드 트랜스폼) 순서로 1회 평가. build3D 말미의
    /// 프라이밍 호출과 encode3D 의 매 프레임 호출이 이 구현을 공유한다(F309 — 두 호출부가 갈라지면 프라이밍이
    /// 실호출과 다른 걸 평가해 무의미해진다).
    func evaluate3DScripts(time: Float) {
        for i in text3DControllers.indices {
            text3DControllers[i].engine.setRuntime(Double(time))
            if let s = text3DControllers[i].engine.evaluate(current: text3DControllers[i].last) {
                text3DControllers[i].last = s
            }
        }
        for e in eval3DOrder {
            if e.bb {
                let bb = billboards[e.idx]
                bb.evaluateScripts(time: time)
                // F811(S-35 잔여): 3D 빌보드도 라이브 채널에 기록 — 2D encodeLayer/encodeText(F743)와
                // 동일하게 프레임 말 pushLiveSceneLayers 가 JS thisScene.layers 를 제자리 갱신해, 다음
                // 프레임 getLayer()/thisLayer 독해가 스크립트로 움직인 현재값을 본다(궤도 미러 등).
                // 스크립트 보유 빌보드만(eval3DOrder) — 정적 빌보드는 base 디스크립터와 항상 동일.
                liveLayerStates[bb.layerIndex] = ScriptLayerReadBack(
                    visible: bb.visible, alpha: bb.tint.w,
                    origin: bb.origin,
                    scale: SIMD3(bb.scale.x, bb.scale.y, 1),
                    angles: SIMD3(0, 0, bb.angleZ))
            }
            else { nodes3D[e.idx].evaluateScripts(time: time) }
        }
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
        let rimLighting: Bool
        let shadingGradient: Bool
        let rimAmount: Float
        let rimExponent: Float
        let gradientTexture: MTLTexture?
        let foggy: Bool
        /// H1 Phase 2: 커스텀 머티리얼 셰이더(material passes[0].shader). nil = Mesh3DShaders 고정 경로.
        let customShader: String?
        let customCombos: [String: Int]
        let customConstants: [String: [Float]]
        let customTextures: [String?]
        /// M3: PBR 노멀맵/마스크 텍스처 이름(textures[1]/textures[2]). nil = 미사용.
        let normalTextureName: String?
        let maskTextureName: String?
        /// H4: REFRACT 콤보 + refractAmount(기본 0.05 — 2D SceneDocument:999 와 동일 기본값).
        /// 노멀맵(textures[1])은 normalTextureName 재사용; refract && 노멀맵 로드 성공 시에만 굴절 적용.
        let refract: Bool
        let refractAmount: Float
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
        var rimLighting = false
        var shadingGradient = false
        var foggy = true   // F662: FOG 콤보 기본 1(WE 선언) — 명시 0 만 scene fog 제외(3706286085 sky/boost)
        // H1 Phase 2: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
        var customShader: String? = nil
        var customCombos: [String: Int] = [:]
        var customConstants: [String: [Float]] = [:]
        var customTextures: [String?] = []
        // M3: PBR 노멀맵/마스크 텍스처 이름(textures[1]/textures[2]).
        var normalTextureName: String? = nil
        var maskTextureName: String? = nil
        // H4: REFRACT 콤보 + refractAmount(노멀맵 없으면 미적용 — build3D 게이트).
        var refract = false
        var refractAmount: Float = 0.05
        func fvec(_ any: Any?) -> [Float]? {
            if let s = any as? String { return s.split(separator: " ").compactMap { Float($0) } }
            if let n = any as? Double { return [Float(n)] }
            if let i = any as? Int { return [Float(i)] }
            if let d = any as? [String: Any] { return fvec(d["value"]) }
            return nil
        }
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
            if let combos = p0["combos"] as? [String: Any] {
                if let v = combos.first(where: { $0.key.lowercased() == "lighting" })?.value {
                    unlit = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 1) == 0
                }
                // F274(폐기 취소 — 실코퍼스 3470948192/3706286085 발화 확정): RIMLIGHTING/SHADINGGRADIENT
                // 콤보 게이트. 둘 다 기본 0(WE 콤보 선언 default:0), require LIGHTING:1 이나 그 요건은
                // generic4.frag 콤보 자체가 강제하므로 여기선 단순 플래그만 뽑는다(unlit 이면 셰이더가
                // 라이팅 루프 전체를 스킵해 자연히 무효과).
                if let v = combos.first(where: { $0.key.lowercased() == "rimlighting" })?.value {
                    rimLighting = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 0) != 0
                }
                if let v = combos.first(where: { $0.key.lowercased() == "shadinggradient" })?.value {
                    shadingGradient = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 0) != 0
                }
                if let v = combos.first(where: { $0.key.lowercased() == "fog" })?.value {
                    foggy = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 1) != 0
                }
                // H4: REFRACT 콤보(2D SceneDocument:1083 과 동일 게이트 — 콤보 1 + textures[1] 노멀맵).
                if let v = combos.first(where: { $0.key.lowercased() == "refract" })?.value {
                    refract = ((v as? Int) ?? (v as? Double).map { Int($0) } ?? 0) != 0
                }
            }
            if let csv = p0["constantshadervalues"] as? [String: Any] {
                pbr = Scene3DMaterialValues.parse(csv)
                if let c = fvec(csv["Color"] ?? csv["color"]), c.count >= 3 { color = SIMD3(c[0], c[1], c[2]) }
                if let a = fvec(csv["Alpha"] ?? csv["alpha"])?.first { alpha = a }
                // H4: g_RefractAmount 상수(2D SceneDocument:1085 와 동일 키 — ui_editor_properties_refract_amount).
                if let r = fvec(csv["ui_editor_properties_refract_amount"])?.first { refractAmount = r }
            }
            // H1 Phase 2: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
            if let shader = p0["shader"] as? String { customShader = shader }
            if let combos = p0["combos"] as? [String: Any] {
                for (k, v) in combos {
                    if let i = v as? Int { customCombos[k] = i }
                    else if let d = v as? Double { customCombos[k] = Int(d) }
                }
            }
            if let csv = p0["constantshadervalues"] as? [String: Any] {
                for (k, v) in csv {
                    if let f = fvec(v) { customConstants[k] = f }
                }
            }
            if let texs = p0["textures"] as? [Any] {
                customTextures = texs.map { $0 as? String }
                // M3: textures[1] = 노멀맵, textures[2] = 마스크(roughness/metallic).
                if customTextures.count > 1 { normalTextureName = customTextures[1] }
                if customTextures.count > 2 { maskTextureName = customTextures[2] }
            }
        } else {
            NSLog("%@", "[Waple] 3D: material json missing: \(path)")
        }
        // SHADINGGRADIENT 의 g_Texture4 는 코퍼스 전건이 재질 textures[] 로 오버라이드하지 않고 셰이더
        // 유니폼 기본값("gradient/gradient_toon_smooth")에 상시 의존한다(F274 실측) — 그 고정 자산만 로드.
        let gradientTexture = shadingGradient
            ? resolveTexture("gradient/gradient_toon_smooth", package: package, device: device)
            : nil
        if let name = texName, let id = imageLayerCompositeID(name) {
            texName = compositeImageTextures[id]
            if texName == nil {
                return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map {
                    Mesh3DMaterialInfo(texture: $0, tint: SIMD4(color.x, color.y, color.z, alpha),
                                       roughness: pbr.roughness, metallic: pbr.metallic,
                                       specularTint: pbr.specularTint,
                                       alphaCutoff: alphaCutoff, shadowEligible: shadowEligible,
                                       unlit: unlit, cullBack: cullBack, additive: additive,
                                       depthTest: depthTest, depthWrite: depthWrite,
                                       rimLighting: rimLighting, shadingGradient: shadingGradient,
                                       rimAmount: pbr.rimAmount, rimExponent: pbr.rimExponent,
                                       gradientTexture: gradientTexture, foggy: foggy,
                                       customShader: customShader, customCombos: customCombos,
                                       customConstants: customConstants, customTextures: customTextures,
                                       normalTextureName: normalTextureName, maskTextureName: maskTextureName,
                                       refract: refract, refractAmount: refractAmount)
                }
            }
        }
        guard let tex = resolveTexture(texName, package: package, device: device) else { return nil }
        return Mesh3DMaterialInfo(texture: tex, tint: SIMD4(color.x, color.y, color.z, alpha),
                                  roughness: pbr.roughness, metallic: pbr.metallic,
                                  specularTint: pbr.specularTint,
                                  alphaCutoff: alphaCutoff, shadowEligible: shadowEligible,
                                  unlit: unlit, cullBack: cullBack, additive: additive,
                                  depthTest: depthTest, depthWrite: depthWrite,
                                  rimLighting: rimLighting, shadingGradient: shadingGradient,
                                  rimAmount: pbr.rimAmount, rimExponent: pbr.rimExponent,
                                  gradientTexture: gradientTexture, foggy: foggy,
                                  customShader: customShader, customCombos: customCombos,
                                  customConstants: customConstants, customTextures: customTextures,
                                  normalTextureName: normalTextureName, maskTextureName: maskTextureName,
                                  refract: refract, refractAmount: refractAmount)
    }

    private func imageLayerCompositeID(_ name: String) -> Int? {
        guard name.hasPrefix("_rt_imageLayerComposite_") else { return nil }
        let rest = name.dropFirst("_rt_imageLayerComposite_".count)
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 메시 파이프라인(accPixelFormat + depth32Float). 프래그먼트가 premultiplied 출력 → src=one,
    /// over: dst=1-srcAlpha, additive: dst=one(가산). vertex = "mv_main"(정적) | "mv_skin"(GPU 스키닝).
    /// HDR 씬은 acc 가 float(rgba16Float)라 컬러 어태치먼트도 float 로 일치시켜야 한다(불일치=Metal 미정의).
    func mesh3DPipeline(lib: MTLLibrary, vertex: String, additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: vertex)
        pd.fragmentFunction = lib.makeFunction(name: "mf_main")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// M3: PBR 노멀맵/마스크 지원 파이프라인. frag=mf_normal(노멀맵+마스크 샘플).
    /// 노멀맵 texture(3), 마스크 texture(4) — 파이프라인 빌드 시점에 바인딩 인덱스 고정.
    func mesh3DNormalPipeline(lib: MTLLibrary, vertex: String, additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: vertex)
        pd.fragmentFunction = lib.makeFunction(name: "mf_normal")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// H4: REFRACT 메시 파이프라인. frag=mf_refract(노멀 오프셋 씬 재샘플·곱) — 정적 메시 한정(M3 와 동일).
    /// 노멀맵 texture(3), 씬 스냅샷 texture(4), refractParams buffer(5). 블렌드는 mesh3DPipeline 과 동치.
    func mesh3DRefractPipeline(lib: MTLLibrary, vertex: String, additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: vertex)
        pd.fragmentFunction = lib.makeFunction(name: "mf_refract")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// 3D 파티클 원근 빌보드 파이프라인. 메시 패스와 동일 타깃(accPixelFormat+depth32). frag=pf_main(premult α),
    /// 블렌드는 2D 파티클(particlePipeline)과 동치: additive dst=one / translucent dst=1-srcα.
    func particle3DPipeline(additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(ParticleShaders.source, { try device.makeLibrary(source: ParticleShaders.source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv3d_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// H1 Phase 2: 커스텀 머티리얼 셰이더 파이프라인 빌드. 성공 시 파이프라인, 실패 시 nil(→ Mesh3DShaders 폴터).
    /// 메시 정점(pos3+normal3+uv2, 8f)을 GLSLTranslator VIn(a_Position/a_TexCoord)에 어댑트하는 버텍스 디스크립터.
    /// 스키닝 메시는 CPU 프리스킨(prepare3DCustomSkinBuffers)으로 같은 8f 레이아웃을 맞춘 뒤 이 파이프라인을 탄다
    /// (GLSLTranslator VIn 에 본 attribute/본 유니폼 배열을 꿰는 대수술 대신 최소 충실안 — 셰이더가 스스로
    ///  a_BlendIndices 같은 미지원 attribute 를 선언하면 MSL 컴파일 실패 → 스톡 mv_skin 폴터).
    /// 셰이더 소스(.vert/.frag)는 씬 패키지 안 것만 인정(2D 경로와 동일 규칙 — 베이스 팩의 WE 빌트인
    /// 셰이더까지 이 경로로 빨려 들어오는 것을 차단). include(common.h 등)만 베이스 팩 폴터 허용.
    func buildCustomMeshShader(_ mat: Mesh3DMaterialInfo, package: ScenePackage, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let shaderName = mat.customShader else { return nil }
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
            NSLog("%@", "[Waple] custom mesh shader source missing: \(shaderName)")
            return nil
        }
        var combos = mat.customCombos
        for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
            let bound = slot < mat.customTextures.count && mat.customTextures[slot] != nil
            if bound { combos[comboName] = 1 }
        }
        guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos,
                                               include: include, premultiplyOutput: false) else {
            NSLog("%@", "[Waple] custom mesh GLSL translate failed: \(shaderName)")
            return nil
        }
        let lib: MTLLibrary
        do {
            lib = try WapleProfiler.compile(t.msl, { try device.makeLibrary(source: t.msl, options: nil) })
        } catch {
            let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
            NSLog("%@", "[Waple] custom mesh MSL compile error: \(first)")
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        let vd = MTLVertexDescriptor()
        // 메시 정점 레이아웃 pos3+normal3+uv2(8f = 32B): a_Position=float3@0, a_TexCoord=float2@24.
        // (H1 Phase 2 초기의 stride 20/uv@12 는 2D 쿼드 레이아웃 잘못 옮긴 값 — 8f 메시와 불일치하는
        //  잠재 결함. 스키닝 메시도 CPU 프리스킨 후 동일 8f 라 같은 디스크립터를 쓴다.)
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 24; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 32
        pd.vertexDescriptor = vd
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = mat.additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = mat.additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    func shadow3DPipeline(lib: MTLLibrary, vertex: String, cutout: Bool,
                         device: MTLDevice) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = lib.makeFunction(name: vertex)
        descriptor.fragmentFunction = cutout ? lib.makeFunction(name: "sf_cutout") : nil
        descriptor.depthAttachmentPixelFormat = .depth32Float
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
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
        // 감사 V06: 같은 time 의 재호출은 직전 결과 재사용(ortho 하이브리드는 drawPlan 인터리브로
        // runOrtho3DMeshes 가 프레임당 2+회 호출 — 호출마다 3슬롯 링을 전진시키면 GPU in-flight 슬롯 덮어씀).
        if let memo = skinBuffersFrameMemo, memo.time == time { return memo.buffers }
        var result: [Int: MTLBuffer] = [:]
        for (index, renderable) in meshRenderables.enumerated() {
            guard let model = renderable.model, let ring = renderable.boneRing, !model.bones.isEmpty else { continue }
            let matrices = Model3DPose.skinMatrices(
                model: model, animation: renderable.animIndex, time: time, rate: renderable.animRate)
            guard !matrices.isEmpty, let buffer = ring.load(matrices, device: device) else { continue }
            result[index] = buffer
        }
        skinBuffersFrameMemo = (time, result)
        return result
    }

    /// 커스텀 셰이더 스키닝 메시용 CPU 프리스킨 8f 정점 버퍼 — prepare3DSkinBuffers 와 같은 프레임 메모 규약
    /// (skin 행렬은 (model, anim, time, rate) 순수 함수라 같은 time 재호출은 재사용; ortho 하이브리드 다중 호출 대비).
    /// 반환: meshRenderables 인덱스 → meshes 인덱스 → 프리스킨 정점 버퍼. 실패 메시는 누락 → 스톡 GPU 스키닝 폴터.
    func prepare3DCustomSkinBuffers(time: Float, device: MTLDevice) -> [Int: [Int: MTLBuffer]] {
        if let memo = customSkinFrameMemo, memo.time == time { return memo.buffers }
        var result: [Int: [Int: MTLBuffer]] = [:]
        for (index, renderable) in meshRenderables.enumerated() {
            guard let model = renderable.model else { continue }
            var matrices: [simd_float4x4]? = nil
            for (mi, mesh) in renderable.meshes.enumerated() {
                guard let ring = mesh.customSkinRing,
                      mesh.modelMeshIndex >= 0, mesh.modelMeshIndex < model.meshes.count else { continue }
                if matrices == nil {
                    let m = Model3DPose.skinMatrices(
                        model: model, animation: renderable.animIndex, time: time, rate: renderable.animRate)
                    guard !m.isEmpty else { break }
                    matrices = m
                }
                guard let m = matrices else { break }
                let packed = Model3DPose.cpuSkinnedPacked(mesh: model.meshes[mesh.modelMeshIndex], matrices: m)
                guard let buffer = ring.load(packed, device: device) else { continue }
                result[index, default: [:]][mi] = buffer
            }
        }
        customSkinFrameMemo = (time, result)
        return result
    }

    /// `castShadow` point 의 6면을 2×3 viewport에, directional(F661)은 단일 오소를 슬라이스 전체에,
    /// F780 CSM directional 은 캐스케이드 3장을 셀 0..2 에 렌더한다.
    /// 실패 시 해당 프레임 shadow metadata를 끈다.
    func encodePointShadows(resolvedLights: [Scene3DResolvedLight],
                            lights: inout [Scene3DLightUniform],
                            nodes: [Int: Scene3DMath.Node],
                            skinBuffers: [Int: MTLBuffer],
                            commandBuffer: MTLCommandBuffer,
                            device: MTLDevice,
                            camera: DirectionalShadowMath.ShadowCamera) -> (texture: MTLTexture?, matrices: [simd_float4x4]) {
        var matrices = [simd_float4x4](repeating: matrix_identity_float4x4,
                                       count: Scene3DLighting.maximumLights * 6)
        let sliceCount = Scene3DLighting.shadowSliceCount(lights)
        guard sliceCount > 0 else { return (nil, matrices) }

        func disableShadows() {
            // slice/VP(x/y)만 끈다 — kind/cone(z/w)·axis 는 directional/spot 셰이딩에 필요.
            for index in lights.indices { lights[index].shadow.x = -1; lights[index].shadow.y = -1 }
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

        // F661: directional 오소 피팅용 씬 월드 AABB — 첫 directional 캐스터에서 1회 계산(lazy).
        // 캐스터만 재면 리시버가 상자 밖으로 빠져 섀도우가 걸리지 않는다(광자는 캐스터를 먼저 때리고
        // 리시버에 도달 — 상자는 수신 영역 전체를 덮어야 함). 모든 가시 메시(캐스터+리시버)를 포함.
        var worldBoundsCache: (min: SIMD3<Float>, max: SIMD3<Float>)?? = nil
        func sceneShadowWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            if let cached = worldBoundsCache { return cached }
            var lo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            var any = false
            for renderable in meshRenderables {
                guard let world = Scene3DMath.worldMatrix(id: renderable.id, nodes: nodes), world.visible else { continue }
                for mesh in renderable.meshes {
                    // 로컬 AABB 8코너 → 월드(정점 산출 AABB 라 유효성은 build3D 가 보장).
                    for cx in [mesh.boundsMin.x, mesh.boundsMax.x] {
                        for cy in [mesh.boundsMin.y, mesh.boundsMax.y] {
                            for cz in [mesh.boundsMin.z, mesh.boundsMax.z] {
                                let p = world.matrix * SIMD4<Float>(cx, cy, cz, 1)
                                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                            }
                        }
                    }
                    any = true
                }
            }
            let result = any ? (lo, hi) : nil
            worldBoundsCache = .some(result)
            return result
        }

        for (lightIndex, light) in resolvedLights.enumerated() where lightIndex < lights.count {
            let sliceValue = lights[lightIndex].shadow.x
            guard sliceValue >= 0 else { continue }
            let slice = Int(sliceValue)
            let isDirectional = light.kind == .directional
            let faceMatrices: [simd_float4x4]
            if isDirectional {
                // F780: 유효 cascadeDistances 면 CSM 3-스플릿(셀 0..2), 아니면 F661 단일 오소 폴터.
                // CSM 산출 실패(퇴화 카메라/바운드)로 단일 오소에 낮출 땐 유니폼의 cascades 도 지워
                // 셰이더 경로(w>2.5=CSM)와 뎁스 맵 레이아웃이 어긋나지 않게 한다.
                guard let bounds = sceneShadowWorldBounds() else {
                    Scene3DLighting.disableShadow(at: lightIndex, in: &lights)
                    continue
                }
                if let distances = light.cascadeDistances,
                   let cascades = DirectionalShadowMath.cascadeViewProjections(
                        forward: light.forward, camera: camera, distances: distances,
                        minBound: bounds.min, maxBound: bounds.max) {
                    faceMatrices = cascades
                } else if let vp = DirectionalShadowMath.viewProjection(
                        forward: light.forward, minBound: bounds.min, maxBound: bounds.max) {
                    lights[lightIndex].cascades = .zero
                    faceMatrices = [vp]
                } else {
                    // 캐스터 AABB/VP 퇴화 — 이 라이트 섀도우만 끈다.
                    Scene3DLighting.disableShadow(at: lightIndex, in: &lights)
                    continue
                }
            } else {
                let cube = PointShadowMath.faceViewProjections(
                    position: light.position, radius: light.colorRadius.w)
                guard cube.count == 6 else {
                    Scene3DLighting.disableShadow(at: lightIndex, in: &lights)
                    continue
                }
                faceMatrices = cube
            }
            for (face, m) in faceMatrices.enumerated() { matrices[slice * 6 + face] = m }

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

            for face in 0..<faceMatrices.count {
                if isDirectional && faceMatrices.count == 1 {
                    // F661 단일 오소: 슬라이스 전체(셀 분할 없음) — scissor 없이 풀 뷰포트.
                    encoder.setViewport(MTLViewport(
                        originX: 0, originY: 0,
                        width: Double(atlas.width), height: Double(atlas.height), znear: 0, zfar: 1))
                } else {
                    // point 6면 / F780 CSM 3캐스케이드: 2×3 셀 배치의 셀 face 에 기록.
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
                }

                for (renderableIndex, renderable) in meshRenderables.enumerated() where renderable.castShadow {
                    guard let world = Scene3DMath.worldMatrix(id: renderable.id, nodes: nodes), world.visible else { continue }
                    var uniform = MeshUniform(
                        mvp: faceMatrices[face] * world.matrix,
                        model: world.matrix,
                        normalMatrix: Scene3DMath.normalMatrix4x4(world.matrix),
                        tint: SIMD4(1, 1, 1, 1),
                        material: SIMD4(0.7, 0, 0, 1),
                        specularTint: SIMD4(1, 1, 1, 0),
                        rim: .zero)  // 섀도우 패스(sf_cutout/sv_*)는 rim 유니폼 미소비 — 자리만 채움
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
    func encode3D(into target: MTLTexture, cb: MTLCommandBuffer, device: MTLDevice, time: Float,
                  particleDelta: Float?) -> Bool {
        guard let cam = camera3D, let over = meshPipelineOver,
              let depthTex = pooledDepth(target.width, target.height, device) else { return false }
        // text 컨트롤러(shared 사이드이펙트) → eval3DOrder(노드/빌보드 트랜스폼) 순서로 평가. 씬 order 로는
        // 소비자(예: Hollow Cylinder order 5)가 생산자(text id=181 order 24)보다 앞서 라이브만 1프레임
        // 지연 후 정착하지만(정상 거동), build3D 말미의 1회 프라이밍(F309)이 이 첫 역전을 흡수해 두므로
        // 이 첫 real 호출부터 이미 정착값이다 — 단일 프레임 캡처도 결정적. evaluate3DScripts 문서 참조.
        evaluate3DScripts(time: time)
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
                // F532: 인코드 실패 시 미기록 next 대신 마지막 유효 텍스처 유지.
                guard applyEffect(eff, src: current, dst: next, time: time, cb: cb) else { break }
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
        var viewProj = proj * view
        // camerashake 3D: 전역 지터를 clip-space 병진으로 viewProj 에 좌승 → 메시/빌보드/파티클 전역 동병진
        // (depth 무관). 미보유/비활성 씬은 frameShakeOffset=.zero → clipTranslation=항등 → 비트동일 가드.
        // shadow VP(광원공간)는 viewProj 미참조 → 월드 지오메트리·섀도우 불변, 화면만 흔들림.
        if frameShakeOffset != .zero { viewProj = Scene3DMath.clipTranslation(frameShakeOffset) * viewProj }
        // 빌보드 카메라-페이싱 축(월드): right/up(lookAt 과 동일 규약).
        let fwd = simd_normalize(ctr - eye)
        // F533: 퇴화 up(영/평행)은 lookAt 과 같은 기준축 폴백 — 뷰행렬과 빌보드 축 정합 유지 + NaN 방어.
        let bbUp = Scene3DMath.upReference(forward: fwd, up: upv)
        let right = simd_normalize(simd_cross(fwd, bbUp))
        let camUp = simd_cross(right, fwd)
        let resolvedLights = Scene3DLighting.resolveLights(scene3DLights, nodes: nmap)
        var frameUniform = Scene3DFrameUniform(
            cameraEye: SIMD4(eye.x, eye.y, eye.z, 1),
            ambient: SIMD4(scene3DAmbient.x, scene3DAmbient.y, scene3DAmbient.z, 0),
            skylight: SIMD4(scene3DSkylight.x, scene3DSkylight.y, scene3DSkylight.z, 0),
            meta: SIMD4(Float(resolvedLights.count), 0, 0, 0))
        // F662: scene fog 유니폼 팩(build3D 에서 파스·저장). 비활성 씬은 w=0 이라 셰이더 무연산(무회귀).
        let sceneFog = scene3DFog
        if sceneFog.distanceEnabled {
            frameUniform.fogDistanceColor = SIMD4(sceneFog.distanceColor.x, sceneFog.distanceColor.y,
                                                  sceneFog.distanceColor.z, 1)
            frameUniform.fogDistanceParams = sceneFog.distanceParams
        }
        if sceneFog.heightEnabled {
            frameUniform.fogHeightColor = SIMD4(sceneFog.heightColor.x, sceneFog.heightColor.y,
                                                sceneFog.heightColor.z, 1)
            frameUniform.fogHeightParams = sceneFog.heightParams
        }
        var lightUniforms = Scene3DLighting.packLights(resolvedLights)
        let skinBuffers = prepare3DSkinBuffers(time: time, device: device)
        let customSkinBuffers = prepare3DCustomSkinBuffers(time: time, device: device)
        // F780: CSM 프러스텀 슬라이스 입력 — 위에서 per-frame 스크립트까지 해석된 카메라 값과 동일 출처.
        let shadowCamera = DirectionalShadowMath.ShadowCamera(
            eye: eye, forward: fwd, right: right, up: camUp,
            tanHalfFovY: tan(fov * .pi / 360), aspect: aspect, nearZ: cam.nearZ)
        let shadowResult = encodePointShadows(
            resolvedLights: resolvedLights, lights: &lightUniforms, nodes: nmap,
            skinBuffers: skinBuffers, commandBuffer: cb, device: device, camera: shadowCamera)
        if let shadowTexture = shadowResult.texture {
            frameUniform.meta.y = 1 / Float(shadowTexture.width)
            frameUniform.meta.z = 1 / Float(shadowTexture.height)
            // [Waple stability policy] receiver depth-space bias; native CPU/Metal 상수는 미확정.
            frameUniform.meta.w = 0.001
        }
        // H4: refract 메시도 인코더 분할(아래 드로 루프의 H4 분기)이 생기므로 프레임버퍼 빌보드와 같은 이유로
        // 뎁스 .store 게이트에 포함(분할 전 패스가 dontCare 면 재개 패스의 뎁스가 미정의 — F311 주석 참조).
        let needsDepthStore = billboards.contains { $0.isFrameBuffer }
            || meshRenderables.contains { $0.meshes.contains { $0.refract && $0.refractNormal != nil } }
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
                    // F311: encodeBillboard(:929 이하)와 대칭인 visible/부모 가시성 가드. 가드를 분기
                    // 진입 전에 둬서 draw 뿐 아니라 endEncoding+풀타깃 blit+이펙트 체인 비용까지 함께
                    // 회피한다(비가시 fullscreenlayer 는 씬 전체를 재합성할 이유가 없다).
                    let parentVisible = bb.parent.map { Scene3DMath.worldMatrix(id: $0, nodes: nmap)?.visible ?? false } ?? true
                    if bb.visible && parentVisible {
                        enc.endEncoding()
                        var srcTex: MTLTexture? = nil
                        if let snap = pooledOffscreen(target.width, target.height, device, bgra: true),
                           let blit = cb.makeBlitCommandEncoder() {
                            blit.copy(from: target, to: snap)
                            blit.endEncoding()
                            var current: MTLTexture = snap
                            for eff in bb.effects {
                                guard let next = pooledOffscreen(target.width, target.height, device) else { break }
                                // F532: 인코드 실패 시 미기록 next 대신 마지막 유효 텍스처 유지.
                                // F-X4: 2D runFrameBufferLayer 와 동형 — snap 을 COPYBG aux 슬롯에도 재사용.
                                guard applyEffect(eff, src: current, dst: next, time: time, cb: cb, fullFrameSnapshot: snap) else { break }
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
                            // 프레임버퍼 후처리(fullscreenlayer)는 스크린공간 풀스크린 합성 — 카메라 프로젝션 우회.
                            encodeFullscreenComposite(bb, texture: srcTex, into: enc, device: device, over: over)
                        }
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
                    specularTint: SIMD4(1, 1, 1, 0),
                    rim: SIMD4(2, 4, 0, 0))
                let boneBuf = skinBuffers[item.idx]
                let customSkins = customSkinBuffers[item.idx]
                for (meshIdx, mesh) in mr.meshes.enumerated() {
                    // 스키닝 메시(16f 패킹)는 반드시 스키닝 파이프라인 필요 — 본버퍼 미준비면 스킵(8f 셰이더로 오독 방지).
                    if mesh.skinned && boneBuf == nil { continue }
                    u.tint = mesh.tint
                    u.material = SIMD4(mesh.roughness, mesh.metallic, mesh.alphaCutoff, mesh.unlit ? 0 : 1)
                    // F662: specularTint.w = fog 모드(0 비적용/1 rgb/2 rgb+alpha additive). scene fog 활성 +
                    // 머티리얼 FOG!=0 일 때만. fullscreen composite(unlit, 스크린공간)는 0 유지(별도 경로).
                    let fogMode: Float = (sceneFog.enabled && mesh.foggy) ? (mesh.additive ? 2 : 1) : 0
                    u.specularTint = SIMD4(mesh.specularTint.x, mesh.specularTint.y, mesh.specularTint.z, fogMode)
                    // F274: RIMLIGHTING/SHADINGGRADIENT 콤보 유니폼 + 게이트 플래그.
                    u.rim = SIMD4(mesh.rimAmount, mesh.rimExponent, mesh.rimLighting ? 1 : 0, mesh.shadingGradient ? 1 : 0)
                    let useSkin = mesh.skinned && boneBuf != nil
                    let customSkinBuf = customSkins?[meshIdx]
                    // H4: REFRACT 메시(정적·비커스텀 한정 — 커스텀 셰이더/스키닝은 기존 경로 폴터): 여기까지의
                    // target(acc)을 스냅샷(blit — 진행 중 타깃은 샘플 불가) 떠 노멀 오프셋 재샘플·곱. 인코더
                    // 분할은 runRefractLayer(2D)/F311 프레임버퍼 빌보드와 동일 패턴 — 분할 전 뎁스 .store 는
                    // needsDepthStore 게이트가 보장. 스냅샷 실패 시 아래 일반 경로로 폴터(무크래시).
                    if mesh.refract, let refractNormal = mesh.refractNormal, !useSkin, mesh.customPipeline == nil,
                       let refractPipe = mesh.additive ? (meshPipelineRefractAdditive ?? meshPipelineRefract)
                                                       : meshPipelineRefract {
                        enc.endEncoding()
                        var snap: MTLTexture? = nil
                        if let s = pooledOffscreen(target.width, target.height, device, bgra: true),
                           let blit = cb.makeBlitCommandEncoder() {
                            blit.copy(from: target, to: s); blit.endEncoding(); snap = s
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
                        if let snap {
                            enc.setRenderPipelineState(refractPipe)
                            if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                                enc.setDepthStencilState(ds)
                            }
                            enc.setCullMode(mesh.cullBack ? .back : .none)
                            enc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                            enc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                            enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                            enc.setFragmentTexture(mesh.texture, index: 0)
                            // gradientTex 인자 자리 채움(아래 mesh 루프와 동일 관례 — rim.w==0 이면 미샘플).
                            enc.setFragmentTexture(mesh.gradientTexture ?? mesh.texture, index: 2)
                            enc.setFragmentTexture(refractNormal, index: 3)   // 노멀맵(g_Texture1)
                            enc.setFragmentTexture(snap, index: 4)            // 씬 컬러 스냅샷(_rt_FullFrameBuffer)
                            var rp = SIMD4<Float>(mesh.refractAmount, mesh.refractRG88 ? 1 : 0, 0, 0)
                            enc.setFragmentBytes(&rp, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
                            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                                      indexType: .uint16, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                            continue
                        }
                        // 스냅샷 확보 실패 — 재개한 enc 에서 일반 파이프라인으로 identity 폴터.
                    }
                    let pipe: MTLRenderPipelineState
                    var meshVBuf = mesh.vbuf
                    var usedCustom = false
                    // H1 Phase 2: 커스텀 셰이더 파이프라인 우선. 스키닝 메시는 CPU 프리스킨(8f) 버퍼로
                    // rigid 입력 계약을 맞춘다(프리스킨 실패 시 스톡 GPU 스키닝 mv_skin 폴터).
                    if let custom = mesh.customPipeline, !mesh.skinned || customSkinBuf != nil {
                        pipe = custom
                        usedCustom = true
                        if let customSkinBuf { meshVBuf = customSkinBuf }
                    } else if (mesh.normalTexture != nil || mesh.maskTexture != nil), !useSkin,
                              let normalPipe = mesh.additive ? meshPipelineNormalAdditive : meshPipelineNormal {
                        // M3: PBR 노멀맵/마스크 파이프라인(정적 메시 한정).
                        pipe = normalPipe
                    } else if useSkin {
                        // F541(F-73): 스킨 파이프라인 nil 시 8f 셰이더(over/mv_main)로 16f 패킹 메시를
                        // 오렌더해 지오메트리 붕괴 — :937 주석과 같은 스킵으로 통일(skinAdditive→skin 폴백은
                        // 동일 16f 셰이더라 유지, over 폴백만 제거).
                        let skinPipe = mesh.additive ? (meshPipelineSkinAdditive ?? meshPipelineSkin) : meshPipelineSkin
                        guard let p = skinPipe else { continue }
                        pipe = p
                    }
                    else { pipe = mesh.additive ? (meshPipelineAdditive ?? over) : over }
                    enc.setRenderPipelineState(pipe)
                    if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                        enc.setDepthStencilState(ds)
                    }
                    enc.setCullMode(mesh.cullBack ? .back : .none)
                    enc.setVertexBuffer(meshVBuf, offset: 0, index: 0)
                    // 커스텀 버텍스는 mul(v, mvp)=v·mvp 계약(GLSLTranslator 번역) — stock 의 mvp·v 와 동치가
                    // 되도록 mvp 만 전치해 바인딩(사본 — u.mvp 는 렌더어블 공용이라 제자리 전치 금지).
                    var bu = u
                    if usedCustom { bu.mvp = bu.mvp.transpose }
                    enc.setVertexBytes(&bu, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    // 커스텀 파이프라인(CPU 프리스킨)은 본 버퍼 불요 — 스톡 GPU 스키닝 경로만 buffer(2) 바인딩.
                    if useSkin, !usedCustom, let boneBuf { enc.setVertexBuffer(boneBuf, offset: 0, index: 2) }
                    enc.setFragmentBytes(&bu, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    enc.setFragmentTexture(mesh.texture, index: 0)
                    // gradientTex 는 mf_main 이 항상 선언하는 인자 — shadingGradient 가 꺼져 있으면 절대
                    // 샘플되지 않으므로(u.rim.w==0) 자기 텍스처를 채워 넣어 바인딩 부재를 피한다.
                    enc.setFragmentTexture(mesh.gradientTexture ?? mesh.texture, index: 2)
                    // M3: PBR 노멀맵/마스크 텍스처 바인딩(mf_normal 전용 슬롯).
                    if pipe === meshPipelineNormal || pipe === meshPipelineNormalAdditive {
                        if let normal = mesh.normalTexture { enc.setFragmentTexture(normal, index: 3) }
                        if let mask = mesh.maskTexture { enc.setFragmentTexture(mask, index: 4) }
                    }
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint16, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                }
            }
        }
        // 파티클: 불투명 메시/빌보드 뒤에 원근 빌보드로(뎁스 read-only). enc 는 프레임버퍼 빌보드 경로에서
        // 재할당됐을 수 있으므로 현재 enc 를 사용(같은 depthTex 바인딩 유지).
        if hasParticles { encode3DParticles(time: time, liveDelta: particleDelta, viewProj: viewProj, right: right, up: camUp, nmap: nmap, into: enc, device: device) }
        enc.endEncoding()
        // H5: 볼륨 라이트 샤프트 — castVolumetrics 라이트를 additive로 합성(3D 씬 렌더 후).
        if let volumetricLightPass {
            for light in scene3DLights where light.castVolumetrics {
                _ = volumetricLightPass.encode(
                    commandBuffer: cb,
                    destination: target,
                    cameraEye: eye,
                    cameraFwd: fwd,
                    cameraRight: right,
                    cameraUp: camUp,
                    fovY: fov,
                    aspect: aspect,
                    nearZ: cam.nearZ,
                    farZ: cam.farZ,
                    light: VolumetricLightParameters(
                        color: SIMD3(light.color.x, light.color.y, light.color.z),
                        position: SIMD3(light.origin.x, light.origin.y, light.origin.z),
                        direction: SIMD3(light.angles.x, light.angles.y, light.angles.z),
                        density: light.density,
                        exponent: light.volumetricsExponent,
                        intensity: light.intensity,
                        innerCone: light.innerCone,
                        outerCone: light.outerCone))
            }
        }
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
            // F662: 빌보드(genericimage4)도 scene fog 대상(WE FOG 콤보 기본 1 — 이미지 레이어의 FOG:0
            // 명시 오브아웃은 SceneLayer 미파스라 미지원, 코퍼스 해당 0건). w = fog 모드.
            specularTint: SIMD4(bb.specularTint.x, bb.specularTint.y, bb.specularTint.z,
                                scene3DFog.enabled
                                    ? (bb.additive ? 2 : 1) : 0),
            rim: .zero)  // 빌보드(2D 이미지 레이어)는 RIMLIGHTING/SHADINGGRADIENT 콤보 대상 아님(F274 — 콤보는
                         // .mdl 메시 재질에만 실존, 코퍼스 460 전건 billboard 레이어에 0건)
        // 머티리얼 blending=additive → 가산 파이프라인(플레어/글로우 광량 복원). 그 외 premult-over.
        enc.setRenderPipelineState(bb.additive ? (meshPipelineAdditive ?? over) : over)
        if let ds = meshDepthState(test: bb.depthTest, write: bb.depthWrite, device: device) { enc.setDepthStencilState(ds) }
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        let billboardTexture = overrideTexture ?? bb.texture
        enc.setFragmentTexture(billboardTexture, index: 0)
        // rim.w(shadingGradient)==0 이라 mf_main 이 gradientTex 를 절대 샘플하지 않는다 — 그래도 mf_main 이
        // 선언하는 인자라 무언가는 바인딩해야 하므로 자기 텍스처를 채운다(F274, mesh draw 루프와 동일 관례).
        enc.setFragmentTexture(billboardTexture, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// F315(자매 커밋 bloom·camerashake 는 각각 XCTAssert 기하 테스트를 남겼는데 fullscreenlayer 신설
    /// 커밋(3b10c73)만 없었던 커버리지 격차 — encodeFullscreenComposite 에서 뽑아 전용 테스트가 직접
    /// 호출/단언 가능하게 함, 인코딩 로직 자체는 무변경). GPU3DMesh 정점 레이아웃과 동일 8-float
    /// 스트라이드(pos3+normal3+uv2) 6정점(삼각형 2개) — 화면정렬 -1..1 NDC 풀스크린 쿼드.
    /// UV 상단 원점(v=0=상단) — encodeBillboard 규약과 동일(프레임버퍼 비플립).
    static func fullscreenCompositeVertices() -> [Float] {
        func vtx(_ x: Float, _ y: Float, _ uu: Float, _ vv: Float) -> [Float] {
            [x, y, 0, 0, 0, 1, uu, vv]
        }
        var verts: [Float] = []
        verts += vtx(-1, 1, 0, 0); verts += vtx(1, 1, 1, 0); verts += vtx(1, -1, 1, 1)
        verts += vtx(-1, 1, 0, 0); verts += vtx(1, -1, 1, 1); verts += vtx(-1, -1, 0, 1)
        return verts
    }

    /// isFrameBuffer(fullscreenlayer/composelayer) 빌보드 합성: 후처리 결과(srcTex)를 **화면정렬 풀스크린
    /// NDC 쿼드**로 그린다. 종전엔 encodeBillboard 가 프로젝션 픽셀 origin/size(예: 960,540 / 1920,1080)를
    /// 월드 좌표로 배치해 오프스크린에 떨어졌다(godrays 워프필드 전량 소실). 프레임버퍼 후처리는 본디
    /// 스크린공간이라 카메라 프로젝션을 우회한다. 블렌드/틴트/파이프라인은 encodeBillboard 와 동일(over/additive).
    func encodeFullscreenComposite(_ bb: Billboard3D, texture: MTLTexture,
                                   into enc: MTLRenderCommandEncoder, device: MTLDevice,
                                   over: MTLRenderPipelineState) {
        guard let vbuf = bb.scratchQuad.load(Self.fullscreenCompositeVertices(), device: device) else { return }
        var u2 = MeshUniform(
            mvp: matrix_identity_float4x4, model: matrix_identity_float4x4,
            normalMatrix: matrix_identity_float4x4, tint: bb.tint,
            material: SIMD4(bb.roughness, bb.metallic, 0, 0),   // w=0 = unlit(프레임버퍼는 라이팅 미대상)
            specularTint: SIMD4(bb.specularTint.x, bb.specularTint.y, bb.specularTint.z, 0),
            rim: .zero)  // unlit 이라 mf_main 이 라이팅 루프 전체를 스킵 — rim/gradient 무관(F274)
        enc.setRenderPipelineState(bb.additive ? (meshPipelineAdditive ?? over) : over)
        // 프레임버퍼 합성은 깊이 무관(스크린공간) — 항상 그리되 깊이 미기록.
        if let ds = meshDepthState(test: false, write: false, device: device) { enc.setDepthStencilState(ds) }
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        // gradientTex 인자 자리만 채움(unlit 이라 mf_main 이 절대 샘플하지 않음) — mesh 루프와 동일 관례.
        enc.setFragmentTexture(texture, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// 3D 파티클 시뮬을 진행해 시스템별 스냅샷을 낸다(드로우/Metal 과 분리 — 유닛 테스트·캡처 재현 공용).
    /// - liveDelta 지정(라이브): 클램프된 프레임 dt 로 **이어가기**. draw() 가 dt 를 ≤0.05 로 클램프하므로
    ///   가림/절전 갭 후에도 프레임당 유한 스텝(서브스텝 상한 dtCap)만 밟는다 — time-clock 무제한 캐치업 금지(감사 C1).
    /// - liveDelta=nil(캡처): particle3DClock(프레시 마운트/캡처 시작=0) → time 까지 전량 서브스텝 = 0→t 결정적
    ///   리플레이(2D 캡처 입도와 동일 — 방출/이동 반영). captureFrames 가 라이브 sim 을 프레시로 리셋해 재현 보장(I1).
    /// 루트만 스텝, 자식은 부모 sim.childDisplay. 밟은 서브스텝 수를 particle3DLastStepCount 에 기록(테스트 관측).
    func stepParticleSnapshots(time: Float, liveDelta: Float?) -> [[Particle]] {
        let dtCap: Float = 1.0 / 30.0
        var snaps = [[Particle]](repeating: [], count: particleSystems.count)
        let rootIdxs = particleSystems.indices.filter { particleSystems[$0].childOf == nil }
        // 라이브(liveDelta 지정)=클램프 dt 이어가기(유한), 캡처(nil)=clock→time 리플레이. clock 은 캡처만 전진.
        var acc = max(0, liveDelta ?? (time - particle3DClock))
        // 라이브(liveDelta≠nil)만 오디오반응 주입 — 캡처(nil)는 프레시 sim 무음 재현 → A/B 비트동일.
        if liveDelta != nil, hasAudio { for i in rootIdxs { particleSystems[i].sim.currentAudio = currentSpectrum } }
        var steps = 0
        if acc > 1e-5 {
            while acc > 1e-5 { let s = min(dtCap, acc); for i in rootIdxs { snaps[i] = particleSystems[i].sim.step(s) }; acc -= s; steps += 1 }
            if liveDelta == nil { particle3DClock = time }
        } else {
            for i in rootIdxs { snaps[i] = particleSystems[i].sim.step(0) }   // 정지/재드로 — 현재 스냅샷 재방출.
        }
        for i in particleSystems.indices {
            if let c = particleSystems[i].childOf { snaps[i] = particleSystems[c.parent].sim.childDisplay(c.link) }
        }
        particle3DLastStepCount = steps
        return snaps
    }

    /// 3D 씬 파티클을 원근 카메라-페이싱 빌보드로 드로우한다(encode3D 의 메시/빌보드 패스 뒤, 같은 인코더).
    /// - 시뮬: stepParticleSnapshots(time:liveDelta:) 로 진행(라이브 = 클램프 dt 이어가기, 캡처 = clock→time 리플레이).
    /// - 배치: 월드행렬 M = 부모월드(nmap, 서브트리 가시성 존중) · modelMatrix(origin3D,angles3D,scale3D).
    ///   부모 서브트리 비가시 또는 정적 visible=false 면 시스템 전체 스킵(WE 가시성 시맨틱 — 예: 3737268876
    ///   횃불은 부모 "Torches" 정적 비가시라 드롭이 정답).
    /// - 렌더: 파티클 로컬 pos 를 M 으로 월드 변환 → 카메라 right/up 으로 쿼드 전개 → viewProj. 뎁스는
    ///   read-only(메시에 가려짐, 미기록 — WE 투명 관례). 블렌드는 머티리얼(additive/translucent) 재사용.
    func encode3DParticles(time: Float, liveDelta: Float?, viewProj: simd_float4x4,
                           right: SIMD3<Float>, up: SIMD3<Float>,
                           nmap: [Int: Scene3DMath.Node],
                           into enc: MTLRenderCommandEncoder, device: MTLDevice) {
        guard !particleSystems.isEmpty else { return }
        let snaps = stepParticleSnapshots(time: time, liveDelta: liveDelta)
        // ── 드로우(씬 order 오름차순 — 뎁스가 메시 가림 처리, 파티클 간 정렬은 미적용: WE depth-sort 근거 없음). ──
        guard let dstate = meshDepthState(test: true, write: false, device: device) else { return }
        var vp = viewProj
        let dbg = Self.debugFlag("WAPLE_PARTICLE3D_DEBUG")
        var drawn = 0, skipInvis = 0, skipParent = 0, skipEmpty = 0
        for idx in particleSystems.indices.sorted(by: { particleSystems[$0].order < particleSystems[$1].order }) {
            let sys = particleSystems[idx]
            guard sys.visible3D else { skipInvis += 1; continue }  // 정적 visible=false(스크립트 미평가 — ponytail).
            var pWorld = matrix_identity_float4x4
            if let pid = sys.parent3D {
                guard let pw = Scene3DMath.worldMatrix(id: pid, nodes: nmap), pw.visible else { skipParent += 1; continue }
                pWorld = pw.matrix
            }
            let m = pWorld * Scene3DMath.modelMatrix(origin: sys.origin3D, angles: sys.angles3D, scale: sys.scale3D)
            let snapshot = snaps[idx]
            guard !snapshot.isEmpty else { skipEmpty += 1; continue }
            drawn += 1
            let verts = particle3DVertices(snapshot, sys, m: m, right: right, up: up)
            let vertexCount = verts.count / 9
            guard vertexCount > 0, let vbuf = sys.scratch.load(verts, device: device) else { continue }
            guard let pipe = sys.blendAdditive ? particle3DAdditive : particle3DTranslucent else { continue }
            enc.setRenderPipelineState(pipe)
            enc.setDepthStencilState(dstate)
            enc.setCullMode(.none)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setFragmentTexture(sys.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        if dbg { NSLog("%@", "[Particle3D] t=\(time) drawn=\(drawn) skipInvis=\(skipInvis) skipParent=\(skipParent) skipEmpty=\(skipEmpty) of \(particleSystems.count)") }
    }

    /// 파티클 스냅샷 → 월드공간 카메라-페이싱 쿼드 정점(정점당 9 float: world.xyz, uv, rgba).
    /// 월드 중심 = m · 파티클 로컬 pos(F731: def.flags worldspace 시 m 우회 직결). 반경 = 0.5·size·(m 열0 길이)
    /// — in-plane 스케일만 크기에 반영, z 스케일(예: speedline 0.6)은 위치에 이미 m 으로 반영됨.
    /// 세로 = 반경·texRatio(WE ComputeParticlePosition). 쿼드 배향 = def.orientation(F732).
    /// ponytail: 트레일(spritetrail/rope)은 3D 리본 미구현 — 헤드 위치 쿼드로 폴백(파티클 등장은 보장,
    /// 리본 연결 없음). 실물 필요 시 appendRibbon 을 월드공간으로 이식.
    func particle3DVertices(_ snapshot: [Particle], _ sys: GPUParticleSystem,
                            m: simd_float4x4, right: SIMD3<Float>, up: SIMD3<Float>) -> [Float] {
        var verts: [Float] = []
        verts.reserveCapacity(snapshot.count * 54)
        // F731(S-23): def.flags bit1(worldspace) — 파티클 pos 가 이미 월드 좌표라 오브젝트 변환 m 을
        // 우회해 직결한다(크기도 월드 단위 → colScale=1). bit4(perspective)는 3D 경로가 viewProj 원근
        // 투영을 내재해(멀수록 작아짐이 자동) 추가 z-스케일이면 이중 원근 — 여기선 의도적으로 미적용
        // (실소비처는 직교 2D 경로, 오역보다 폴터).
        let worldspace = (sys.def.flags & 1) != 0
        let colScale = worldspace ? Float(1) : simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        // F732(S-26): def.orientation — screen(기본)은 전달된 right/up 그대로(기존 폴터 비트동일).
        // upright/fixed(axis) 는 축 고정 빌보드: 쿼드 up 을 축에 고정하고 시선에 수직인 right 로 전개
        // (upright = 축 (0,1,0) 특례). viewDir = cross(up, right) — right=cross(fwd,refUp)·up=cross(right,fwd)
        // 의 삼중곱 정리로 fwd 복원. 시선∥축 퇴화 시 screen 폴터(NaN 방지 — 오역보다 폴터).
        var axisRight = right, axisUp = up
        let lockAxis: SIMD3<Float>?
        switch sys.def.orientation {
        case .screen: lockAxis = nil
        case .upright: lockAxis = SIMD3(0, 1, 0)
        case .fixed(let a): lockAxis = SIMD3(a.x, a.y, a.z)
        }
        if let ax = lockAxis, simd_length_squared(ax) > 1e-12 {
            let an = simd_normalize(ax)
            let r = simd_cross(simd_cross(up, right), an)
            if simd_length_squared(r) > 1e-8 { axisRight = simd_normalize(r); axisUp = an }
        }
        for p in snapshot {
            let center: SIMD3<Float>
            if worldspace { center = p.pos }
            else {
                let wp = m * SIMD4<Float>(p.pos.x, p.pos.y, p.pos.z, 1)
                center = SIMD3(wp.x, wp.y, wp.z)
            }
            // UV + 종횡비: 스프라이트시트면 현재 프레임 서브렉트(2D appendQuad 미러), 아니면 전체 텍스처.
            var uv: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
            var ratio = sys.texRatio
            if !sys.frames.isEmpty {
                let fc = sys.frames.count
                let fi: Int
                if p.frame >= 0 { fi = sheetFrameIndex(sequence: p.frame, frameCount: fc, mirror: sys.mapSeqMirror) }
                else if sys.def.animationMode == .sequence {
                    // F730(S-22): animationmode=sequence — 수명에 걸쳐 시트 전체 순차 재생 ×sequencemultiplier
                    // (3=수명 내 3회전, 0.5=절반까지). 수명 진행률 t×fc×rate 를 sheetFrameIndex 로 루프 폴드
                    // (sequence 의 폴드는 순환 — mapsequence 전용 mirror 와 무관). 비유한 rate/수명은 0/ε 폴터.
                    let t = p.age / max(1e-4, p.lifetime)
                    let rate = sys.def.sequenceMultiplier.isFinite ? max(0, sys.def.sequenceMultiplier) : 0
                    fi = sheetFrameIndex(sequence: t * Float(fc) * rate, frameCount: fc, mirror: false)
                }
                else { fi = Int(p.age / max(0.016, sys.frames[0].time)) % fc }
                let fr = sys.frames[max(0, min(fc - 1, fi))]
                let tw = Float(max(1, sys.texture.width)), th = Float(max(1, sys.texture.height))
                let u0 = fr.atlasX / tw, v0 = fr.atlasY / th
                let u1 = min(1, (fr.atlasX + fr.atlasWidth) / tw), v1 = min(1, (fr.atlasY + fr.atlasHeight) / th)
                let corners = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
                let q = fr.rotationQuarters
                uv = (0..<4).map { corners[($0 + q) % 4] }
                let upW = q % 2 == 0 ? fr.atlasWidth : fr.atlasHeight
                let upH = q % 2 == 0 ? fr.atlasHeight : fr.atlasWidth
                ratio = upH / max(1, upW)
            }
            let hw = p.size * colScale * 0.5
            let hh = hw * ratio
            guard hw > 0, hw.isFinite, hh.isFinite else { continue }
            // 파티클 롤(rotation.z)을 배향 축에 적용(encodeBillboard angleZ 규약). UV 상단원점: 상단=+up.
            // F732: screen 은 전달 축(right/up)과 동치라 비트동일, upright/fixed 는 축 고정 평면에서 롤.
            let ca = cos(p.rotation.z), sa = sin(p.rotation.z)
            let rRight = axisRight * ca + axisUp * sa
            let rUp = -axisRight * sa + axisUp * ca
            let r = rRight * hw, u = rUp * hh
            let tl = center - r + u, tr = center + r + u, br = center + r - u, bl = center - r - u
            let cr = p.color.x, cg = p.color.y, cb = p.color.z, al = p.alpha
            func v(_ pt: SIMD3<Float>, _ uu: (Float, Float)) {
                verts.append(contentsOf: [pt.x, pt.y, pt.z, uu.0, uu.1, cr, cg, cb, al])
            }
            v(tl, uv[0]); v(tr, uv[1]); v(br, uv[2])
            v(tl, uv[0]); v(br, uv[2]); v(bl, uv[3])
        }
        return verts
    }
}
