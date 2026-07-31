# Scene SP4 — 파티클 시스템 구현 계획

> **For agentic workers:** TDD, frequent commits. 체크박스(`- [ ]`)로 추적.

**Goal:** WE sprite 파티클(흔한 emitter/init/operator + 단일 텍스처 + additive/translucent)을 씬에 합성.

**Architecture:** 파싱·시뮬은 WapleCore(순수, Metal/벽시계 無), 렌더는 WapleRender(Metal). 헤드리스 PNG 하니스로 단위/Y부호/size 를 이미지로 실측 고정.

**Tech Stack:** Swift, Metal/MetalKit, AppKit(NSBitmapImageRep PNG), XCTest.

## Global Constraints
- swift-tools 5.9, Swift 5 모드. macOS 13+.
- 미지원 요소는 스킵하되 **`NSLog("%@", …)`로 드롭 로그**(포맷스트링 안전).
- 결정적 RNG(SplitMix64) — 테스트 재현성.
- 좌표: 씬 px 좌상단 Y-down, NDC `x/projW*2-1`, `1-y/projH*2`. 파티클 size = 전체 폭(half=size/2).

---

### Task 1: 헤드리스 PNG 렌더 하니스
**Files:** Create `Sources/WapleRender/OffscreenCapture.swift`; Test `Tests/WapleRenderTests/OffscreenCaptureTests.swift`

**Interfaces:**
- Produces: `enum OffscreenCapture { static func png(rgba: [UInt8], width: Int, height: Int) -> Data? }` (RGBA8 → PNG Data via NSBitmapImageRep). 추후 SceneRenderer 가 오프스크린 텍스처 readback 에 사용.

- [ ] Step 1: 실패 테스트 — 4×1 RGBA(빨강,초록,파랑,흰) → png(Data) non-nil 이고 `NSBitmapImageRep(data:)` 로 다시 읽어 픽셀[0]=빨강 확인.
- [ ] Step 2: 컴파일/실패 확인 (`swift test --filter OffscreenCaptureTests`).
- [ ] Step 3: 구현 — `NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:w, pixelsHigh:h, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:w*4, bitsPerPixel:32)` → memcpy rgba → `representation(using:.png)`.
- [ ] Step 4: 테스트 통과.
- [ ] Step 5: 커밋 `feat(sp4): offscreen RGBA→PNG capture util`.

### Task 2: SplitMix64 결정적 RNG
**Files:** Create `Sources/WapleCore/SplitMix64.swift`; Test `Tests/WapleCoreTests/SplitMix64Tests.swift`

**Interfaces:**
- Produces: `struct SplitMix64 { init(seed: UInt64); mutating func nextUInt() -> UInt64; mutating func nextFloat() -> Float /*[0,1)*/; mutating func range(_ lo: Float, _ hi: Float) -> Float }`

- [ ] Step 1: 실패 테스트 — 동일 시드 두 인스턴스가 동일 시퀀스; `nextFloat()` ∈ [0,1); `range(2,5)` ∈ [2,5).
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — 표준 SplitMix64(z = (seed += 0x9E3779B97F4A7C15); z=(z^(z>>30))*0xBF58476D1CE4E5B9; z=(z^(z>>27))*0x94D049BB133111EB; z^(z>>31)). nextFloat = Float(next >> 40) * (1/16777216).
- [ ] Step 4: 통과.
- [ ] Step 5: 커밋 `feat(sp4): deterministic SplitMix64 RNG`.

### Task 3: ParticleSystemDef + 파싱 (emitter/initializer/operator/renderer/material)
**Files:** Create `Sources/WapleCore/ParticleSystem.swift`; Test `Tests/WapleCoreTests/ParticleSystemTests.swift`

**Interfaces:**
- Produces: `enum Emitter`, `enum Initializer`, `enum ParticleOperator`, `enum RendererKind { case sprite, unsupported(String) }`, `struct ParticleMaterial { let textureName: String?; let blend: BlendKind }`, `enum BlendKind { case additive, translucent }`, `struct ParticleSystemDef: Equatable { …; static func parse(_ json: [String: Any], material: ParticleMaterial?) -> ParticleSystemDef }`.

- [ ] Step 1: 실패 테스트 — snow JSON(딕셔너리 리터럴 또는 실제 `presets/snow/.../snowperspective.json` 로드)을 parse → emitters[0] == .sphere(rate:25, distanceMin:10, distanceMax:1000, …); initializers 에 lifetimeRandom(8,20)/sizeRandom(2,30)/velocityRandom/colorRandom; operators 에 movement/oscillatePosition/alphaFade; renderer == .sprite; maxCount==360; startTime==15. ember JSON → turbulentVelocityRandom(speedMin:0,speedMax:50,scale:0.3,offset:-0.1)/alphaRandom(0.1,0.2,exp2). 미지원 op(예 controlpointattract) → 무시(파싱 생존).
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — 각 배열 순회, `name` 으로 분기, 벡터는 "a b c" split→Vec3, 스칼라는 Double/Int. 미지원 name → skip + NSLog. 머티리얼은 인자로 주입.
- [ ] Step 4: 통과.
- [ ] Step 5: 커밋 `feat(sp4): parse particle system definition`.

### Task 4: ParticleMaterial 파싱 + SceneDocument.particles
**Files:** Modify `Sources/WapleCore/SceneDocument.swift`; Test `Tests/WapleCoreTests/SceneParticleTests.swift`

**Interfaces:**
- Produces: `struct SceneParticle: Equatable { let def: ParticleSystemDef; let origin: Vec2; let scale: Vec2 }`; `SceneDocument.particles: [SceneParticle]`; `ParticleMaterial.parse(_ json:[String:Any]) -> ParticleMaterial`.

- [ ] Step 1: 실패 테스트 — material JSON `{passes:[{blending:"additive", textures:["particle/snow"]}]}` → textureName=="particle/snow", blend==.additive; "translucent"→.translucent, 기본(없음)→.translucent. 가짜 ScenePackage(emitter 포함 particles/X.json + materials/X.json + scene.json with particle object) → SceneDocument.particles.count==1, origin/scale 일치.
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — SceneDocument.parse 의 objects 루프에서 `obj["particle"]` 처리: package.data(for: pPath) → JSON → material 경로 로드 → ParticleMaterial.parse → ParticleSystemDef.parse → SceneParticle(origin/scale). visible=false 스킵 동일 적용.
- [ ] Step 4: 통과.
- [ ] Step 5: 커밋 `feat(sp4): parse scene particle objects + material`.

### Task 5: ParticleSimulator (순수, 시드)
**Files:** Create `Sources/WapleCore/ParticleSimulator.swift`; Test `Tests/WapleCoreTests/ParticleSimulatorTests.swift`

**Interfaces:**
- Produces: `struct Particle { var pos, vel, color, rotation, angularVel: Vec3; var size, alpha, age, lifetime, initialSize, initialAlpha: Float }`; `struct ParticleSimulator { init(def: ParticleSystemDef, seed: UInt64); mutating func step(dt: Float) -> [Particle] }`.

- [ ] Step 1: 실패 테스트:
  - movement 궤적: def(emitter rate 매우 큼, lifetime 큼, velocity 고정 [10,0,0], gravity 0, maxCount 1) → step(1.0) 후 1개, pos.x ≈ origin.x+10 (±eps). 두 번째 step(1.0) → pos.x ≈ +20.
  - maxCount 캡: rate=1000, maxCount=5 → 여러 step 후 `count <= 5`.
  - 컬: lifetime=1, step(0.6) 1개, step(0.6) → age>1 제거(0개, 단 신규 방출 0 이도록 rate 0 또는 starttime 큼).
  - alphaFade(fadeInTime=1): age=0.5 → alpha≈initialAlpha*0.5; age≥1 → ≈initialAlpha.
  - 결정성: 동일 seed 두 시뮬 동일 결과.
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — 방출 누적자, initializer 적용(SplitMix64), operator 업데이트, 컬. starttime 이전 방출 억제.
- [ ] Step 4: 통과.
- [ ] Step 5: 커밋 `feat(sp4): pure seeded particle simulator`.

### Task 6: ParticleShaders (MSL) + 컴파일 테스트
**Files:** Create `Sources/WapleRender/ParticleShaders.swift`; Test `Tests/WapleRenderTests/ParticleShadersTests.swift`

**Interfaces:**
- Produces: `enum ParticleShaders { static let source: String }` — vert `pv_main`(in: float2 posNDC, float2 uv, float4 color; uniforms camOffset/aspectScale buffer1/2), frag `pf_main`(texture0 × color).

- [ ] Step 1: 실패 테스트 — `MTLCreateSystemDefaultDevice()` 있으면 `makeLibrary(source:)` 후 `pv_main`/`pf_main` non-nil(없으면 XCTSkip).
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — per-vertex struct{float2 pos; float2 uv; float4 color}, vert 가 aspectScale/camOffset 적용해 clip 좌표 산출(기존 QuadShaders 패턴), frag `tex.sample(s,uv)*color`.
- [ ] Step 4: 통과.
- [ ] Step 5: 커밋 `feat(sp4): particle MSL shaders + compile test`.

### Task 7: SceneRenderer 통합 + 오프스크린 PNG 캡처 API
**Files:** Modify `Sources/WapleRender/SceneRenderer.swift`; Test `Tests/WapleRenderTests/SceneParticleRenderTests.swift`(스모크)

**Interfaces:**
- Consumes: SceneParticle, ParticleSimulator, ParticleShaders, OffscreenCapture.
- Produces: `GPUParticleSystem` 내부 구조; 매 프레임 step+전개+블렌드 그리기; `hasParticles` unpause; `func captureFrames(width:Int,height:Int,times:[Float], toDir:URL) -> [URL]`(헤드리스, 테스트/검증용 — 오프스크린 타겟에 레이어+파티클 렌더 후 readback→PNG).

- [ ] Step 1: 스모크 테스트 — 합성 ScenePackage(snow 파티클 1개)로 mount 가 throw 없이 동작, teardown OK. captureFrames 가 파일 URL 반환(파일 존재, >100바이트).
- [ ] Step 2: 실패 확인.
- [ ] Step 3: 구현 — buildParticles(doc,package,device): 텍스처/시뮬/블렌드 파이프라인 준비. draw 루프 끝(레이어 후)에 각 시스템 step→쿼드전개(billboard half=size_px/2, 세로 half=size_px*texRatio/2, z회전, 씬px→NDC, rgba)→동적 vbuf→additive/translucent 파이프라인 그리기. dt=실시간 델타(0.05 클램프). captureFrames: 오프스크린 rgba8 타겟에 동일 렌더(시뮬 dt 누적으로 각 time 까지 진행)→readback→OffscreenCapture.png.
- [ ] Step 4: 통과(빌드+스모크).
- [ ] Step 5: 커밋 `feat(sp4): render particles in SceneRenderer + headless capture`.

### Task 8: 단위/Y부호/size 실측 고정 (PNG 시각 검증)
**Files:** (검증 전용 — 임시 스크립트/테스트로 PNG 생성 후 Read)

- [ ] Step 1: snow/ember/rain 프리셋(또는 합성 씬)을 captureFrames(t=2,5,10) 로 PNG 덤프(어두운 배경 위).
- [ ] Step 2: Read 로 PNG 확인 — 눈은 위→아래 낙하, ember 은 부드러운 발광점 다수, size 가 합리적(1px도 화면덮기도 아님).
- [ ] Step 3: 어긋나면 systematic-debugging — Y 부호/size 스케일/origin 합성 수정(셰이더 ground-truth 기준).
- [ ] Step 4: 재덤프→재확인 루프. OK 면 커밋 `fix(sp4): pin particle units/orientation via PNG` (수정 있을 때만).

### Task 9: 빌드/테스트 게이트 + 병합
- [ ] `swift build` clean, `swift test` 전부 통과(MSL/시뮬/파싱 포함).
- [ ] feature 브랜치 → main ff-merge, 브랜치 삭제.
- [ ] 메모리(waple-autonomous-mandate) SP4 done 갱신.

## Self-Review
- 스펙 커버리지: emitter(sphere/box)✓Task3, init 8종✓Task3/5, op 7종✓Task3/5, sprite renderer✓Task6/7, material 블렌드✓Task4, 합성✓Task7, 시각검증✓Task1/8, 강등로그✓Task3. 
- 타입 일관성: Vec3 는 WapleCore SceneGeometry 기존 타입 재사용. Particle.size/alpha Float, color Vec3(0..1 정규화 — colorrandom 0..255 를 /255). BlendKind/RendererKind enum 일관.
- 플레이스홀더 없음.
