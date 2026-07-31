# H1–H8 / M1–M10 로드맵 마감 + 트레이드오프 기록 (2026-07-26)

> 대상 로드맵: [swarm-audit-synthesis-2026-07-25.md](swarm-audit-synthesis-2026-07-25.md) §3 (128개 스웜 감사 종합).
> 이 문서는 2026-07-25~26 작업 라운드의 **상태 확정과 설계 트레이드오프**를 기록한다.
> 검증: 전 타겟 `swift test` 0 failures (2026-07-26, main `4f2779a`).

## 1. 상태 확정

### High (§3.🔴)

| # | 항목 | 상태 | 근거 |
|---|------|------|------|
| H1 | 2D/3D 머티리얼 커스텀 셰이더 경로 | ✅ 완료 | 2D(07-25) + 3D 메시(`39bee53`) + 스키닝(`cd27127`) + mvp 전치(`47bd076`, `4f2779a`) + pkg 전용 규칙(`b85f8c1`, `f6830d1`) |
| H2 | `usershadervalues` | ✅ 완료 | 07-25 라운드 |
| H3 | `g_PointerState` 클릭 게이팅 | ✅ 완료 | 07-25 라운드(기존 구현 검증) |
| H4 | REFRACT 이미지/3D 머티리얼 | ✅ 완료 | 2D(07-25) + 3D 메시 `mf_refract`(`3c113e8`) |
| H5 | Volumetric light shafts | ✅ 완료 | 07-25 라운드 |
| H6 | HDR bloom 8단 피라미드 | ✅ 완료 | `c74b362` (3→8레벨, mip 클램프) |
| H7 | **C03 Ultra EOTF `pow(2.4)` / color grading 미이식** | ❌ **미착수 — 유일한 잔여 High** | `HDRPostPass.swift:62-71` |
| H8 | `constantshadervalue.scripted`(2D PBR scalars) | ✅ 완료 | `SceneRendererResources.swift:320` 파싱 + `SceneRendererFrameEncoder.swift:942` per-frame 평가 |

### Medium (§3.🟡)

| # | 항목 | 상태 | 근거 |
|---|------|------|------|
| M1 | 품질별 픽셀 포맷 분기 | ✅ 완료 | 07-25(당시 "H7"로 mislabel). 후속 실측: **실물 169씬 `general.quality` 키 0건** → ultra 기본값 경로만 발동, 무회귀 확인(2026-07-26) |
| M2 | `g_LightAmbientColor` 중립값 | ✅ 완료 | 07-25(기존 구현 확인) |
| M3 | 3D PBR 노멀맵/마스크 | ✅ 완료 | `0f5e277` |
| M4 | `perspective:true`+`perspectiveoverridefov` | ✅ 완료 | `433d8be` |
| M5 | composelayer `config.passthrough` | ✅ 완료 | `1148e2e` |
| M6 | **Sound 3D spatialization** | ❌ 미착수 | `SceneSound`/`SceneAudioPlayer` |
| M7 | 오브젝트 렌더 플래그 | ✅ 완료 | `1148e2e` |
| M8 | `maxcount` 상한 | ✅ 완료 | `ParticleSystem.swift:640` `min(65536,…)` |
| M9 | Camera `path`/`queuemode` | ✅ 완료 | `1148e2e` |
| M10 | HDR 최종 샘플러 linear | ✅ 완료 | `HDRPostPass.swift:65` (`filter::linear`) |

### Low (§3.🟢)

L5(스테일 MDAT 주석)·L6(스테일 REFRACT 주석) 해소(`e1a1795`). L1–L4·L7·L8 은 트리거형 유지(실피해 없음 확인된 항목들).

## 2. 트레이드오프 / 설계 결정 기록

### 2.1 커스텀 셰이더 소스는 씬 패키지 안 것만 인정 (`b85f8c1`, `f6830d1`)

- **결정**: `buildCustomLayerShader`/`buildCustomMeshShader`의 `.vert/.frag` 해석을 pkg 전용(`packageData`)으로. 베이스 에셋 팩의 WE 빌트인 셰이더(`genericimage4` 등)는 검증된 고정 경로(QuadShaders/Mesh3DShaders)가 담당. include(`common.h`)만 베이스 팩 폴터 허용.
- **배경**: `materialShader != nil` + 베이스 팩 폴터가 만나 3394601417의 사실상 전 레이어가 실험적 번역 경로로 빨려 들어가 주야 토글 회귀(픽셀 바이트 단위 재현).
- **수용한 트레이드오프**: 베이스 팩 셰이더를 커스텀 상수/콤보와 함께 쓰는 씬이 있으면 WE 대비 충실도 손실 가능. 코퍼스에서 미관측 + 고정 경로가 검증된 거동이라 보수적 선택. 실씬 이상 관측 시 재검토.

### 2.2 스키닝 커스텀 셰이더 = CPU 프리스킨 (`cd27127`)

- **결정**: 본 행렬(CPU, `Model3DPose.skinMatrices`)로 정점을 CPU 스키닝(`cpuSkinnedPacked`, `mv_skin`과 동일 수학)해 8f로 패킹 → rigid 커스텀 파이프라인 입력.
- **트레이드오프**: 메시당 프레임 CPU 비용. 대안(번역기에 블렌드 attribute + 본 유니폼 배열 지원)은 GLSLTranslator 대수술이라 기각. 스톡 경로는 GPU 스키닝(`mv_skin`) 유지. WE 네이티브 스키닝 셰이더(`a_BlendIndices` 직접 선언)는 MSL 컴파일 실패 → 스톡 폴터로 자연 복귀.

### 2.3 mvp 전치 규약 (`47bd076`, `4f2779a`)

- **문제**: 번역 셰이더 계약은 HLSL `mul(v, M)`=행벡터 v·M(번역기가 순서보존 `(a*b)`로 옮김). 스톡 유니폼은 M·v 규약이라 무전치 바인딩 시 Dᵀ 회전+스케일 혼합.
- **잠복 조건**: 무회전·축정렬 스케일은 D=Dᵀ 라 픽셀 동일 — 2D/3D 테스트가 전부 무회전이라 장기 미검출. 90° 회전 레이어 회귀 테스트(`testCustomShaderRotatedLayerTransform`)로 red-green 확정.
- **수정**: 커스텀 경로 드로에 한해 전치 사본 바인딩(2D/3D 동일). 스톡 경로 변경 없음.

### 2.4 3D REFRACT (`3c113e8`)

- **결정**: 2D `runRefractLayer`/F311 과 동일한 인코더 분할 + acc blit 스냅샷을 노멀 오프셋으로 재샘플·곱. refract 존재 시에만 분할 전 뎁스 `.store` 게이트 확장(refract 없는 씬은 비트 동일).
- **수용한 편차**: ①정적·비커스텀 메시 한정(스키닝/커스텀은 스톡 폴터) ②탄젠트공간→스크린공간 변환(`v_ScreenTangents`)은 2D와 같은 최소 근사 — 회전/경사 메시에서 굴절 방향이 WE와 어긋날 수 있음 ③bg 곱 위치(라이팅 전 알베도)는 WE 소스 미확정 추정 ④ortho 하이브리드(`runOrtho3DMeshes`)는 refract+custom 메시 over 폴터(경로 기존 관례).

### 2.5 HDR bloom 8레벨 (`c74b362`)

- **결정**: N레벨 일반화 + `min(요청 8, halving 가능 수)` 클램프. Metal 셰이더 소스 변경 없음, n=3 과 수학 동치. 기존 read-write 피드백(Metal UB)도 별도 합성 타깃으로 제거.
- **미수행**: strength 재캘리브(`strengthScale` 주석상 "피라미드 승격 시 재캘리브 필수"). 골든 스냅샷 17/17 통과로 회귀 없음을 확인했으나, **실씬 밝기 과부족은 A/B 대조 트리거**.

### 2.6 기타 확정 사항

- M1 후속: 실물 169씬 `general.quality` 0건 — 품질 분기 코드는 유지하되 실측상 ultra 기본값만 발동(무회귀).
- 3D 커스텀 셰이더 잠재 결함 2건 수정(버텍스 디스크립터 stride 20→32, mvp 전치) — `47bd076` 커밋 메시지 참조.

## 3. 잔여 항목

| 항목 | 심각도 | 트리거 |
|------|--------|--------|
| H7: C03 Ultra EOTF `pow(2.4)` / color grading 이식 | High(유일) | Ultra HDR 씬의 WE 대비 색/톤 차이 확인 시 |
| M6: Sound 3D spatialization | Medium | spatialized 사운드 씬 사용 시 |
| 실씬 A/B 게이트 | — | ①H6 bloom 밝기 ②H4 굴절 방향(회전/경사 메시) ③H1 스키닝 커스텀 셰이더 실물 씬(eagleflag·dna_fragment·fantasticcar — 로컬 코퍼스 부재로 합성 검증만 됨) |
| L1–L4·L7·L8 | Low | 기존 트리거 유지 |
