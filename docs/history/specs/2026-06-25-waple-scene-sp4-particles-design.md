# Waple — Scene SP4: 파티클 시스템 (sprite) 설계 문서

- 작성일: 2026-06-25
- 상태: 설계 확정(자율 진행 — "끝까지 해" + "계속 자율(코드 검증만)" 지침)
- 선행: SP3a–d(효과 레이어) main 병합.
- 범위: WE **sprite 파티클** MVP — 흔한 emitter/initializer/operator + 단일 텍스처 + additive/translucent 블렌딩. 씬에 합성.

---

## 상태(2026-07-04) — 파티클 z-순서 인터리브로 개선됨

SP4 본체(파싱·시뮬레이터·헤드리스 PNG 하니스·렌더 통합)는 구현·병합됨. 갱신 요점:

- **파티클 z-순서 [완료/변경]**: §3.3·§5 는 파티클을 "이미지 레이어 위, present 전"에 그린다고 명시(= 항상 최상단). 이후 `2026-07-02-…glsl-stage2-design.md` §"파티클 z-순서"에서 **씬 오브젝트 순서를 보존해 레이어·파티클을 인터리브 드로우**하도록 수정됨(SceneDocument 가 오브젝트 순서 보존, 렌더러가 order 로 정렬). 이제 전경 레이어가 파티클을 가릴 수 있다. 따라서 §3.3/§5 의 "파티클이 항상 이미지 레이어 위" 서술은 폐기.
- **실측 GT 경로**: §1 의 `~/Downloads/assets` 는 현재 `~/Downloads/wallpaper_dev/assets`(공유 에셋 팩). 씬 코퍼스는 `~/Downloads/wallpaper_dev/backgrounds`.
- 후속 operator(turbulence 등)·spritetrail/rope 는 별도 사이클에서 진행.

---

## 0. 핵심 발견: 데스크탑 없이 시각 자체검증 가능
오프스크린 `MTLTexture`에 렌더 → `getBytes` → `NSBitmapImageRep`로 PNG 인코드 → `/tmp/*.png` → Read 도구로 확인.
라이브 데스크탑을 건드리지 않으므로 가림 여부와 무관. **이 헤드리스 렌더 하니스를 Task 1로 먼저 구축**하고, 이후 모든 단계에서 "눈사람이 아래로 떨어지나" 같은 실제 시각 확인을 **에이전트가 직접** 수행한다(사용자 개입 불필요). t≈0 은 비어 있으므로 t≈2/5/10s 덤프.

## 1. 정찰 결과 (실제 데이터, /Users/yakisoba/Downloads/assets) [경로 갱신 2026-07-04: 현 공유 에셋 `~/Downloads/wallpaper_dev/assets`]
- 씬 오브젝트(파티클): `{name, particle:"particles/X.json", origin, scale, id, instanceoverride}` — `image` 대신 `particle` 키.
- 파티클 JSON: `{emitter:[…], initializer:[…], operator:[…], renderer:[…], material:"materials/…json", maxcount, starttime, controlpoint:[…]}`.
- 빈도 census(presets 전체):
  - **emitter**: sphererandom(213), boxrandom(23).
  - **initializer**: lifetimerandom(232), sizerandom(230), colorrandom(204), velocityrandom(103), rotationrandom(93), alpharandom(52), turbulentvelocityrandom(48), angularvelocityrandom(45), 그 외≤10.
  - **operator**: movement(207), alphafade(204), sizechange(110), angularmovement(45), oscillatealpha(35), controlpointattract(29), colorchange(28), turbulence(18), oscillateposition(15), 그 외≤11.
  - **renderer**: sprite(144), spritetrail(39), rope(24), ropetrail(17).
- material: `{passes:[{shader:"genericparticle", blending:"additive"|"translucent", textures:["particle/snow"]}]}` → 텍스처 `materials/particle/snow.tex`.
- 단위 ground-truth(`shaders/common_particles.h::ComputeParticlePosition`):
  `pos.xyz + size*right*(u-0.5) - size*up*(v-0.5)*texRatio`. 즉 **size = 스프라이트 전체 폭**(half=size/2), 세로=size×(texH/texW). 빌보드는 월드축 정렬 + z회전. MVP가 월드→클립 변환.

## 2. 좌표/단위 규약
- 파티클 로컬 시뮬 좌표: WE 월드(원점 중심 가정, **Y-up**). velocity/gravity px/s. emitter origin 로컬 px.
- 씬 픽셀 좌표(기존 레이어): 좌상단 Y-down, 중심=(projW/2, projH/2). NDC: `x/projW*2-1`, `1 - y/projH*2`.
- 합성: `world_px = object.origin + object.scale ⊙ local`. 로컬 Y-up→픽셀 Y-down 부호는 **PNG로 실측 고정**(눈은 아래로 떨어져야 함; 반대면 부호 반전). size_px = `particle.size * object.scale.x`.

## 3. 설계

### 3.1 파싱 (WapleCore, 순수)
- `ParticleSystemDef`(Equatable): `emitters:[Emitter]`, `initializers:[Initializer]`, `operators:[ParticleOperator]`, `renderer: RendererKind`, `maxCount:Int`, `startTime:Float`, `material: ParticleMaterial?`.
  - `Emitter`: `.sphere(origin:Vec3, directions:Vec3, sign:Vec3, distanceMin/Max:Float, rate:Float)`, `.box(origin, directions, distanceMin/Max:Vec3-ish, rate)`. (box distancemin/max 는 벡터일 수 있음 → Vec3.)
  - `Initializer`(enum): lifetimeRandom(min,max), sizeRandom(min,max), colorRandom(min:Vec3,max:Vec3 0..255), alphaRandom(min,max,exponent), velocityRandom(min:Vec3,max:Vec3), rotationRandom(min:Vec3,max:Vec3 deg), angularVelocityRandom(min:Vec3,max:Vec3), turbulentVelocityRandom(speedMin,speedMax,scale,offset).
  - `ParticleOperator`(enum): movement(gravity:Vec3, drag:Float?), alphaFade(fadeInTime,fadeOutTime?), sizeChange(start?,end?)→비율, colorChange, angularMovement, oscillateAlpha(freq,scale,phase), oscillatePosition(freqMin/Max,scaleMin/Max,phaseMin/Max,mask:Vec3).
  - 미지원 emitter/op/init/renderer → 무시하되 **`NSLog`로 드롭 로그**(특히 controlpointattract/vortex/boids/turbulence/spritetrail/rope/ropetrail).
- `ParticleMaterial`: `textureName:String?`, `blend: .additive | .translucent`.
- `SceneParticle`(SceneDocument 신규 필드 `particles:[SceneParticle]`): `def: ParticleSystemDef`, `origin: Vec2`, `scale: Vec2`.
  - 파싱: scene object 의 `particle` 값 → package entry `particles/X.json` 로드 → ParticleSystemDef.parse. material 경로 로드 → ParticleMaterial.

### 3.2 시뮬레이터 (WapleCore, 순수 — Metal/벽시계 無)
- `struct Particle { var pos:Vec3; var vel:Vec3; var size:Float; var color:Vec3; var alpha:Float; var rotation:Vec3; var angularVel:Vec3; var age:Float; var lifetime:Float; var initialSize:Float; var initialAlpha:Float }`.
- `struct ParticleSimulator`: `init(def:, seed:UInt64)`; `mutating func step(dt:Float) -> [Particle]`(살아있는 것만 반환).
  - 방출: rate 누적자(`acc += rate*dt`), 정수개 스폰, `count <= maxCount` 캡. starttime 이전엔 시간만 누적.
  - 초기화: 각 initializer 를 신규 파티클에 적용(시드 RNG; sphere=랜덤단위벡터×rand(distMin,distMax), box=축별 rand).
  - 업데이트: 각 operator. movement: `vel += gravity*dt; pos += vel*dt`. alphaFade: fadeIn 램프(+옵션 fadeOut). sizeChange/colorChange: age/lifetime 보간. oscillatePosition: `pos += mask*scale*sin(2π*freq*age+phase)`(프레임 누적 아닌 절대식). angularMovement: `rotation += angularVel*dt`.
  - 컬: `age > lifetime` 제거.
- 결정적 RNG: 내부 SplitMix64 struct(시드 가능). 테스트 재현성 + 파티클별 변주.

### 3.3 렌더 (WapleRender, Metal)
- `ParticleShaders`(MSL): vert `pv_main`(per-vertex: posNDCpx, uv, rgba; camOffset/aspectScale 유니폼 — 기존 패턴), frag `pf_main`(albedo×color, alpha). 별도 라이브러리.
- `SceneRenderer` 통합: `struct GPUParticleSystem { var sim:ParticleSimulator; let texture:MTLTexture; let blendAdditive:Bool; let origin:SIMD2<Float>; let scale:SIMD2<Float> }`.
  - 매 프레임: `sim.step(dt)` → 살아있는 파티클을 CPU에서 쿼드 6버텍스로 전개(billboard: half=size_px/2, 세로 half=size_px*texRatio/2, z회전), 씬 px→NDC, rgba 포함 → 동적 vertex buffer. additive/translucent 파이프라인으로 그림(이미지 레이어 위, present 전). [폐기 2026-07-04: 씬 순서로 레이어·파티클 인터리브 드로우로 변경 — glsl-stage2 참조]
  - 파티클 존재 시 `hasParticles=true` → 뷰 unpause(effects 와 동일 경로). dt 는 프레임 간 실시간 델타(상한 클램프).
- 블렌딩: additive(`src=one, dst=one`), translucent(`src=srcAlpha, dst=oneMinusSrcAlpha`).

### 3.4 헤드리스 렌더 하니스 (테스트/검증 백본)
- `SceneRenderer`에 `func renderOffscreenPNG(width:height:atTimes:[Float], to dir:URL) -> [URL]` 또는 테스트 전용 헬퍼. 씬+파티클을 오프스크린 텍스처에 그려 PNG 저장. 시뮬은 dt 누적으로 t 까지 진행 후 캡처.
- 검증: 기존 프리셋/씬을 PNG로 덤프 후 Read 로 육안 확인(에이전트). 단위/Y부호/size 를 이미지로 고정.

## 4. 컴포넌트 / 검증
| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| 헤드리스 PNG 하니스 | WapleRender | 기존 씬 1개 PNG→Read(동작 확인) |
| `ParticleSystemDef`/`Emitter`/`Initializer`/`ParticleOperator`/`ParticleMaterial`/parse | WapleCore | **TDD**(실제 snow/ember JSON 파싱) |
| `SceneDocument.particles` + 파싱 | WapleCore | **TDD** |
| `SplitMix64` + `ParticleSimulator` | WapleCore | **TDD**(궤적/카운트/컬/페이드 정확값) |
| `ParticleShaders` MSL | WapleRender | **MSL 런타임 컴파일 테스트** |
| `SceneRenderer` 파티클 통합 | WapleRender | 빌드 + **스모크** + **PNG 시각확인**(snow 낙하/ember 발광) |

## 5. 데이터 흐름
scene.pkg → SceneDocument(layers + particles) → mount: 이미지 레이어 GPU화 + 파티클별 텍스처/시뮬/파이프라인 준비 → draw: 레이어 합성 → 각 파티클 sim.step → 쿼드 전개 → 블렌드 그리기 → present.

## 6. 에러/강등 (loudly)
- 파티클 JSON/머티리얼/텍스처 디코드 실패 → 해당 시스템 스킵 + `NSLog`. 텍스처 없으면 흰색 1×1.
- 미지원 renderer(spritetrail/rope/ropetrail) → sprite 로 그리되 `NSLog` 경고. 미지원 op/init/emitter → 스킵 + `NSLog`(controlpointattract 가 가장 흔한 보류 항목, 29회).
- 무크래시. 파티클 0개여도 정상(빈 시스템).

## 7. 테스트
- **TDD**: def 파싱(snow=sphere/lifetime/size/velocity/color/oscillateposition/movement/alphafade/sprite; ember=turbulentvelocityrandom/alpharandom), 시뮬(시드 고정 → step N: pos=origin+vel·t, alphafade 곡선, maxcount 캡, age>lifetime 컬), RNG 결정성, 머티리얼 블렌드 파싱.
- **MSL 컴파일**: pv_main/pf_main.
- **PNG 시각**(자율 게이트): snow/ember/rain 프리셋을 합성씬에 넣어 t=2/5/10 덤프 → Read 확인.

## 8. 범위 밖 (이후 SP)
- spritetrail/rope/ropetrail 렌더러, controlpoint 계열 op(attract/vortex/boids/maintaindistance), turbulence 필드(노이즈), mapsequence/hsv/remap initializer, 스프라이트시트 애니, lighting/refract/fog 콤보, children/서브이미터, 3D perspective emitter, instanceoverride. SP5 오디오반응, SP6 퍼펫/3D.
