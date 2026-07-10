# Waple — 3D 서브시스템(SP6 3D) 설계 문서

- 작성일: 2026-07-04
- 상태: **구현·병합됨** — 본 문서는 코드(주석 명세)에서 사후 정리한 설계 레퍼런스다(선(先)스펙 아님).
- 출처: `Sources/WapleCore/{Model3D,Model3DPose}.swift`, `Sources/WapleRender/{Scene3DMath,Mesh3DShaders,SceneRenderer}.swift` 의 실측-리버스 주석. 세부 수치/근거는 해당 파일이 정본.
- 선행: 2D 퍼펫(`2026-07-03-waple-puppet-design.md`, MDLV0013/MDLS0001/MDLA0001). 3D 는 그 포맷의 상위 판(멀티메시·법선/탄젠트·트리 스켈레톤·애니 트레일러 추가).
- 실측 코퍼스: `~/Downloads/wallpaper_dev/backgrounds` — 3737268876(젤다 OoT/MM, 100 .mdl), 3706286085(Sonic, 5), 3662790108(태양계, 69) = **174개 MDLV0023 전수**. 애니 모델은 그중 33개(MDLA0006 전수).

---

## 1. 목표 / 범위

Wallpaper Engine `type:"scene"` 중 **3D 모델 씬**(`.mdl` = MDLV0023)을 macOS 데스크탑에 렌더한다.
v1 은 **unlit**(텍스처 × 머티리얼 tint) — 라이팅/그림자/PBR 없음. 포함: 다중 서브메시, GPU 정점 스키닝,
애니메이션 재생, 트랜스폼 계층(부모 체인), 카메라 프로퍼티 스크립트, 3D 씬 안의 2D 이미지 빌보드.

---

## 2. Model3D — MDLV0023 / MDLS0004 / MDLA0006 실측 포맷

`Model3D.parse(_:) -> Model3D?`(WapleCore, 순수). 리틀엔디안. 잘못된 매직/범위 → nil(우아한 실패).
확정 근거: 174/174 파스; 단일메시 40개 전부 `maxIndex == vertexCount-1`; `vsize % stride == 0` 전수;
normal/tangent 단위길이 · weights 합 1.0(witness); 메시 사이 6바이트 구분자 전수 0.

### 2.1 헤더 + 서브메시
```
"MDLV0023" | u8 0 | u32 formatFlag | u32(=1, 미상 상수) | u32 meshCount
서브메시 × meshCount:
  cstring 머티리얼("materials/…json" 상대경로) | u32(=0) | AABB(min 3f, max 3f = 24B) |
  u32 formatFlag | u32 정점블롭크기 | 정점×N | u32 인덱스블롭크기 | u16 트라이앵글 인덱스
  [메시 사이 구분자 6×u8 0]
```
- 서브메시 1개 = 머티리얼 1개 = 드로우콜 1개(`Model3D.Mesh`).
- 인덱스는 u16 트라이앵글 리스트(count % 3 == 0).
- cstring 은 **UTF-8 디코드 필수**(실물 머티리얼 경로가 CJK 포함 — "materials/models/太空球/…"; Latin-1 해석은 mojibake → pkg 엔트리 조회 실패).

### 2.2 정점 포맷 (formatFlag 로 판별)
- `formatFlag & 0x0180_0000 != 0` → **스키닝**(본/웨이트 존재).
- 정적(stride 48): `pos 3f | normal 3f | tangent 4f | uv 2f`.
- 스키닝(stride 80): `pos 3f | normal 3f | tangent 4f | boneIndices 4×u32 | weights 4f | uv 2f`.
- `tangent.w` = handedness(실측 ±1). 정적 메시의 boneIndices/weights = (0,0,0,0).
- 2D 퍼펫(stride 52) 대비: 법선·탄젠트 신설, 멀티메시.

### 2.3 스켈레톤 (스키닝 모델) — "MDLS0004"
```
"MDLS0004" | u8 0 | u32 nextOff | u32 본수 |
본별: cstring 이름 | u32 flags | i32 부모(-1=루트) | u32 64 | float4x4 바인드(로컬 레스트) | cstring props
```
- `bind` = 부모상대 로컬 레스트 변환. 부모 체인 합성 → `bindWorld`(발밑↓/머리↑ 정상 구도).
- `props` 는 대개 "" — 일부 본은 리깅툴 IK 설정 JSON.
- 2D "MDLS0001" 대비: 매직 diff + 본 말미가 u8 0 대신 cstring props.

### 2.4 애니메이션 — "MDLA0006" (2026-07-04 헥스 리버스, 33개 전수)
```
"MDLA0006" | u8 0 | u32 nextOff(=EOF-1) | u32 animCount | u32 baseId | u32 0 |
애니 × N:
  cstring 이름("Link Adult_arm|idle_bone") | cstring 모드(loop/single/mirror/clamp) |
  f32 fps | u32 길이(프레임) | u32 0 | u32 본수(=스켈레톤 본수) | u32 0 |
  본별: u32 트랙크기 | 키 × 36B(pos 3f, 오일러각 3f 라디안, 스케일 3f) | u32 블롭2크기 | 블롭2 |
  트레일러(가변 32~39B): u16 0 | AABB 6f | u32 0 | u16 id(=baseId+1+i, 마지막 애니는 생략)
```
- **헤더 count 불신**: link_adult 는 `animCount=8` 인데 실제 4개 → 카운트를 믿지 않고 **리싱크로 종료 판정**(다음 애니 헤더를 ≤256B 앞에서 재동기해 스킵).
- 키 = 프레임당 1키, 트랙 인덱스 = 본 인덱스, 본수 == 스켈레톤 본수(전수 검증).
- (일부 모델은 MDLA0006 앞에 "MDAT0001" 어태치먼트 선행.)
- 2D "MDLA0001" 대비: 애니 트레일러(AABB+id) 신설. 키 포맷/트랙 구조는 동일.

`Model3D` 필드: `meshes`, `bones`, `hasAnimation`(매직 탐지 마커), `animations`(파일 순서).

---

## 3. Scene3DMath — 카메라/변환 규약 (WapleRender, 순수 TDD)

Metal NDC(z 0..1). 실측 확정(3662790108 태양계 / 3737268876 젤다 렌더 vs preview 판정).

- **좌표계**: 우수(RH), 카메라 전방 = 뷰 -Z. `lookAt(eye,center,up)` = gluLookAt 동형.
- **투영**: `perspective(fovYDegrees, aspect, near, far)` — **fov 는 세로(Y)축** 화각. 뷰 z=-near→ndc 0, z=-far→ndc 1.
- **와인딩**: **CCW front-facing**(렌더러 `enc.setFrontFacing(.counterClockwise)`; 머티리얼별 `cullBack` 이면 `.back` 컬).
- **UV 원점 = 상단**(V 플립 없음). `.tex` 디코더 행 순서(top-down, 2D GT 검증)와 모델 UV 가 동일 규약 — 플립 시 젤다 담쟁이/이끼가 벽 상단에 붙는 것으로 실측 판정.
- **모델행렬** = `T(origin) · Rz(z)·Ry(y)·Rx(x) · S(scale)`, angles 라디안. 오일러 순서 **ZYX**(X 먼저 적용). 채택 근거: 실물 회전의 절대다수가 단축 yaw → 순서 무관; 유일 판정점(젤다 짐벌 표현 (π,θ,-π))이 순수 yaw 와 동치이고 ZYX 가 이를 만족 + 젤다/소닉 전 배치가 preview 구도와 일치. 다축 혼합(moon)은 코퍼스 카메라 밖이라 미판정 — 반례 실물 발견 시 `modelMatrix` 하나만 교체.
- **계층 합성**: `worldMatrix(id, nodes)` = 부모 체인 합성 월드행렬 + 유효 가시성(조상 중 하나라도 false → false). 사이클/미지 부모 안전 종단. 모델 오브젝트도 다른 모델의 부모가 될 수 있음(Sonic BoostModel → RioSonic; 빈 그룹 노드 SceneNode3D 경유 계층이 다수).

---

## 4. 렌더 파이프라인 (SceneRenderer, WapleRender)

씬 mount 시: `.mdl` 로드 → 서브메시별 정점/인덱스 버퍼 + 텍스처 → `MeshRenderable`; 3D 씬 안의 2D 이미지 레이어 → `Billboard3D`.
그리기 순서는 메시+빌보드를 `order`(scene.json objects[] 순서) 오름차순 인터리브.

### 4.1 메시 셰이더 (`Mesh3DShaders`, MSL — v1 unlit)
정점은 `[[stage_in]]` 대신 buffer(0) 수동 페치(CPU 재패킹).
- **정적**(`mv_main`): CPU 에서 `pos3+normal3+uv2 = 8 float(32B)` 재패킹. `pos = mvp · float4(p,1)`.
- **스키닝**(`mv_skin`, v3): `pos3+normal3+uv2+boneIdx4+weight4 = 16 float(64B)` 재패킹 + 본행렬 버퍼(buffer(2)).
  `p' = Σ (wᵏ/Σw) · bones[idxᵏ] · p`. Σw=0 → 원위치(정적). idx 는 CPU clamp.
- **프래그(`mf_main`)**: `tex.sample(uv) × tint`; `misc.x>0 && a<misc.x → discard`(alphatocoverage 컷아웃 근사).
  **premultiplied 출력**(`float4(c.rgb*c.a, c.a)`) — 합성 규약(파이프라인 블렌드 src=one)과 동일.

### 4.2 스키닝 (`Model3DPose.skinMatrices`, WapleCore 순수)
- `bind` → `bindWorld`(부모 체인). 애니 키 로컬 = pos + 오일러각(ZYX 라디안) + scale, 프레임당 1키(트랙=본).
- **skin_i = world_i(t) × bindWorld_i⁻¹** (메시 정점은 bindWorld 레스트 포즈에서 저작).
- 2D 와 달리 **키0 ≠ bind 인 캐릭터가 흔함**(바인드=T포즈, idle=이완포즈) — t=0 항등 가정은 버리되 위 식은 그대로 정답.
- CPU 는 프레임당 본행렬만 계산 → GPU 정점 스키닝. `animation` 인덱스 범위 밖 → 전부 항등(= 정지 바인드 포즈).
- `PuppetPose.frame(time·rate, fps, length, mode)` 로 loop/single/mirror/clamp 재생.

### 4.3 애니메이션 선택 (animationlayers)
- 파스(`SceneDocument`): objects 의 `animationlayers` 에서 **숫자 blend ≥ 0.5 & visible 인 베이스 레이어**를 골라 `AnimationSelection{name, rate}`. nil = 정지(바인드 포즈).
- 매칭(`Model3DPose.resolveAnimation`): 레이어 이름(예 "Idle")을 모델 애니 이름에 **소문자 서브스트링 매칭**(→ "..._arm|idle_bone") → 폴백 "idle" → 폴백 인덱스 0. 애니 없음 → -1.
- 게이트: 환경변수 `WAPLE_3D_BINDPOSE=1` → 애니 무시(skin=항등) — 스키닝 배선 정합 확인용.

### 4.4 빌보드 (3D 씬 안의 2D 이미지)
- `encodeBillboard`: 오브젝트 월드행렬의 위치를 중심으로 카메라 right/up 축에 정렬한 쿼드(size, z회전) → 카메라를 향한 스프라이트.
- 머티리얼 `blending=additive` → **가산 파이프라인(dst=one)**(플레어/글로우 광량 복원), 그 외 premult-over. `setCullMode(.none)`.

### 4.5 카메라 프로퍼티 스크립트
- scene.json 카메라의 `eye`/`center`/`up`/`fov` 프로퍼티에 JS 스크립트가 있으면(`doc.cameraScripts`) **per-frame 재평가**로 카메라 애니(젤다 fov 변화, 태양계 궤도 시점 등). 무스크립트면 base 값 고정.
- 오브젝트/그룹의 `propertyScripts`(origin/angles/scale/visible)도 per-frame 평가 — 태양계 planet 은 부모 그룹 origin 스크립트가 궤도를 그린다.

---

## 5. 알려진 한계 (v1)

- **unlit 전용**: 라이팅/그림자/노멀맵/PBR 없음(정점 법선·탄젠트는 파스만, 셰이딩 미사용). light 노드 무시.
- **오일러 다축 혼합 미검증**: ZYX 는 단축 yaw + 젤다 짐벌 케이스로만 게이트됨. 다축 혼합 회전(예 moon)은 코퍼스 카메라 밖 — 반례 발견 시 `Scene3DMath.modelMatrix` 교체 필요.
- **MDLA0006 헤더 count 불신**: 애니 개수를 리싱크로 판정 — 극단적 트레일러 변형에서 오종단 위험(현 코퍼스 33개는 0 실패).
- **bindWorld/오일러 순서**는 렌더 실측으로 게이트(형식 증명 아님). 부모 인덱스가 자신 이후인 비정상 순서는 항등 처리.
- **컷아웃은 discard 근사**(MSAA alphatocoverage 없음) — 경계 앨리어싱 가능.
- **머티리얼 서브셋**: genericmesh 계열 unlit 만. 커스텀 3D 머티리얼 셰이더(반사/굴절/emissive 콤보)는 미지원.
- **애니 블렌딩 미구현**: animationlayers 는 단일 베이스 애니만 선택(레이어 가중 블렌드/트랜지션 없음).

---

## 6. 검증

- **TDD(WapleCore)**: `Model3D.parse`(합성 MDLV0023/MDLS0004/MDLA0006 바이트 + 실물 174 전수 파스 스모크, env-guarded), `Model3DPose.skinMatrices`/`resolveAnimation`(손계산·서브스트링 매칭), `Scene3DMath`(lookAt/perspective/modelMatrix/worldMatrix 순수 단위).
- **MSL 컴파일**: `Mesh3DShaders`(mv_main/mv_skin/mf_main) 런타임 컴파일.
- **PNG/실측 게이트**: 젤다/소닉/태양계 씬을 오프스크린 렌더 → preview 구도 대조(좌표/UV/오일러/스키닝 시각 고정).
