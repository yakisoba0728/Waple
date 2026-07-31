# Waple ↔ 외부 RE 자료 정적 대조 통합 보고서

> 작성일: 2026-07-25  
> 대상: `/Users/yakisoba/Documents/GitHub/Waple` (main 브랜치, dirty 48 files, HEAD `40643f6`)  
> 외부 자료: `/Users/yakisoba/Downloads/wallpaper_dev/re-audit-2026-07/`, `/Users/yakisoba/Downloads/wallpaper_dev/references/WallpaperEngine-macOS-analysis-reference-2.8.0.42/analysis/`, `/Users/yakisoba/Downloads/wallpaper_dev/references/WallpaperEngine_RenderDoc_capture/`, `/Users/yakisoba/Downloads/wallpaper_dev/references/wallpaper_engine_analysis_bundle/`, `/Users/yakisoba/Downloads/wallpaper_dev/waple-baselines/main-a4c678b/` (2026-07-26 Downloads 정리로 이동된 경로 반영)  
> 분석 방식: 90개 explore 서브에이전트 병렬 정적 대조(read-only), 총 출력 816,707자  
> **후속 상태(2026-07-26): §3 로드맵 H1–H6·H8·M1–M5·M7–M10 구현 완료 — [roadmap-h1-h8-closeout-2026-07-26.md](roadmap-h1-h8-closeout-2026-07-26.md) 참조. 잔여: H7·M6.**

---

## 1. 개요

외부 RE(Reverse Engineering) 참고 자료와 Waple 소스코드를 90개 explore 에이전트가 동시에 교차 검증한 결과를 통합한 보고서입니다. 각 에이전트는 scene/model JSON, particle system, shader dialect/uniform, render/color pipeline, 포맷(PKG/TEX/MDL/SHDV), audio, web/video, runtime/scenescript, 로드맵 H1-H7 등 특정 주제를 담당했습니다.

**핵심 결론**
- 2026-07-16 기준 외부 문서가 지적한 P0~P2.5 항목 대부분은 이미 구현되어 있어 **문서 스테일** 상태입니다. 특히 `instanceoverride`, `shape:quad` 이펙트-온리 레이어, camera 의사-오브젝트, `attachment`, `camerashake`, REFRACT 파티클, CSM, WEMath, SceneScript lifecycle, web hard pause 등은 코드상 완결되어 있습니다.
- **실제 사용자에게 영향을 주는 남은 갭**은 2D/3D 머티리얼 커스텀 셰이더 경로, `usershadervalues` 바인딩, `g_PointerState` 클릭 입력 배관, volumetric light shafts, HDR bloom 피라미드, 품질별 픽셀 포맷, 3D PBR normal map/pixel mask, sound spatialization, `composelayer config.passthrough`, `perspective:true` 등에 집중되어 있습니다.
- 외부 문서의 file:line 인용은 상당수 스테일하므로 후속 작업은 현재 HEAD 기준으로 재확인해야 합니다.

---

## 2. 방법론

- **에이전트 수**: 90개 explore 서브에이전트(AgentSwarm).
- **데이터 소스**: 외부 Markdown 문서, 셰이더 캐시, RenderDoc 캡처, 분석 번들, baseline manifest.
- **코드 대상**: `Sources/WapleCore/`, `Sources/WapleRender/` 및 기타 Waple 모듈.
- **출력 통합**: 각 에이전트가 `[일치]`, `[갭]`, `[의심]`, `[액션]` 4개 카테고리로 보고. 본 보고서는 이를 주제별로 재정렬하고 중복을 제거한 것입니다.
- **한계**: 정적 분석만 수행. 런타임 A/B, 골든 이미지 비교, 실기기 측정은 포함하지 않음.

---

## 3. 종합 요약: 우선순위별 갭

### 🔴 High — 시각적/기능적 차이가 큰 갭

| # | 갭 | 영향 씬/빈도 | 근거 파일:라인 | 제안 액션 |
|---|-----|--------------|----------------|-----------|
| H1 | **2D/3D 머티리얼 커스텀 셰이더 경로 부재** | eagleflag, dna_fragment, fantasticcar 등 | `SceneDocument.swift:917-934`, `SceneRenderer.swift:179-375`, `SceneRenderer3D.swift:490-574` | `parseLayer`/`loadMesh3DMaterial`에서 `shader` 필드 읽고 `GLSLTranslator.translate`로 파이프라인 빌드 |
| H2 | **`usershadervalues` 전혀 미구현** | eagleflag(flagcolor→tint), dna_fragment, 일반 머티리얼 | 전체 코드베이스 `usershadervalues` 0건 | `SceneLayer`/`Mesh3DMaterial`/`ParticleMaterial`에 `usershadervalues` 파싱 및 `userProps` 룩업 후 셰이더 상수 주입 |
| H3 | **`g_PointerState` 클릭 입력 JS 훅에 게이팅** | cursor ripple 8씬 | `SceneRenderer.swift:463-470`, `:485-494` | 셰이더에 `g_PointerState`가 있으면 전역 마우스 모니터 항상 설치 |
| H4 | **REFRACT 이미지/3D 머티리얼 경로 미구현** | 74씬 중 파티클 외 | `SceneDocument.swift:917-935`, `SceneRenderer3D.swift:490-572` | 이미지/3D 머티리얼용 `refractPipeline` 추가 |
| H5 | **Volumetric light shafts / god rays 미소비** | 10~12씬 | `SceneDocument.swift:1193-1213` 파싱됨, `SceneRenderer3D.swift` 미소비 | `castvolumetrics`/`density`/`volumetricsexponent`를 소비하는 볼륨라이트 패스 추가 |
| H6 | **HDR bloom 8단 피라미드 미구현** | Ultra HDR 8씬 | `HDRBloomPass.swift:43-53`, `SceneDocument.swift:609-611` | `bloomHDRIterations`/`bloomHDRScatter` 기반 듀얼-필터 피라미드 구현 |
| H7 | **C03 Ultra EOTF `pow(2.4)` / color grading 미이식** | Ultra HDR | `HDRPostPass.swift:62-71`, `SceneDocument.swift` color grading 키 부재 | sRGB EOTF 및 brightness/contrast/channel 수식 추가 |
| H8 | **`material.constantshadervalue.scripted`(2D PBR scalars) 미캡처** | PBR 애니 | `SceneDocument.swift:930-934` | `SceneLayer`에 `roughnessScript`/`metallicScript` 등 추가 후 per-frame 평가 |

### 🟡 Medium — 범위가 명확하거나 부분 구현

| # | 갭 | 근거 | 제안 액션 |
|---|-----|------|-----------|
| M1 | **품질별 픽셀 포맷 분기 없음**(`hdr` 플래그 단일 결정자) | `SceneRenderer.swift:605`, `:1210` | WE 품질 설정에 따라 `bgra8Unorm`/`rgba16Float` 분기 |
| M2 | **`g_LightAmbientColor` 엔진 중립값 누락** | `GLSLTranslator.swift:1129-1132`, `:1201-1208` | `isEngine`/`engineNeutralDefault`에 등록 |
| M3 | **3D PBR normal map / per-pixel roughness·metallic mask** | `Model3D.swift:50`, `Mesh3DShaders.swift` | TBN 생성 후 normal map 샘플링, mask 텍스처 바인딩 |
| M4 | **`perspective:true` + `perspectiveoverridefov` 렌더 미소비** | `SceneDocument.swift:631-633`, `:975-976` | 2D draw 경로에 원근 투영 행렬 적용 |
| M5 | **`composelayer config.passthrough` 미독** | 27씬 | `SceneDocument.swift`에 `config.passthrough` 파싱, RTT 체인 연동 |
| M6 | **Sound 3D spatialization 미지원** | `SceneSound`/`SceneAudioPlayer` 전역 2D | `spatialization`/`mindistance`/`attenuation` 파싱 및 AVAudioEngine 3D 믹싱 |
| M7 | **Object-level render flags 미독**(`disablepropagation`, `copybackground`, `clampuvs`, `spacing`, `nointerpolation`) | `SceneDocument.swift:922-923` 일부만 | 오브젝트 루프에서 파싱 및 렌더 전달 |
| M8 | **`maxcount` 상한 부재** | `ParticleSystem.swift:628` | `min(65536, max(0, ...))` 클램프 |
| M9 | **Camera 의사-오브젝트 `path`/`queuemode` 미소비** | `SceneDocument.swift:1081-1102` | `SceneCameraObject`에 필드 추가, 3D 칩에 path 애니 적용 |
| M10 | **HDR 최종 샘플러 `filter::nearest`** | `HDRPostPass.swift:65` | WE가 `linear` 요구 시 변경 |

### 🟢 Low / 문서화 / 의심

| # | 항목 | 비고 |
|---|------|------|
| L1 | **PKGV 라이터 부재** | reader만 존재. writer는 editor 범위이나 필요 시 `encoded()` 추가 |
| L2 | **`ccsimple` 미구현** | color grading/3D LUT 경로. BACKLOG 항목 |
| L3 | **`_rt_Reflection` / `_rt_MipMappedFrameBuffer` 미구현** | WE RT 레지스트리 확장 필요 |
| L4 | **MDAT count `u16` vs `u8+padding`** | `Model3D.swift:336`, count<256일 때는 무해 |
| L5 | **`Model3D.swift:37` MDAT0001 "미필독" 주석 스테일** | 주석 갱신 필요 |
| L6 | **`TexDecoder.swift:163` REFRACT 주석 스테일** | "파티클은 구현, 이미지 레이어는 미구현"으로 정정 |
| L7 | **파티클 op 롱테일 17종(boids, collision 등)** | 코퍼스 0건, 실피해 없음 |
| L8 | **IComponent 훅 `destroy`/`resizeScreen`/`applyGeneralSettings` 미수집** | 스펙 완결성 갭, 실사용 낮음 |

---

## 4. 주제별 상세 대조 결과

### 4.1 Scene 파싱 / Scene Graph

**[일치]**
- `scene.json`/`gifscene.json` 루트 구조, 3계층 참조 사슬(project→scene→model→material) 일치 (`SceneDocument.swift:656`, `:1418-1424`).
- 오브젝트 타입 분기(`sound`/`image`/`particle`/`text`/`model`/`light`/`camera`)가 콘텐츠키 존재로 판별 (`SceneDocument.swift:700-781`).
- `visible`/`blend`/`rate`/`alpha`/`parallaxDepth` 등 필드 매핑 일치.
- `user` 키를 `project.json` 프로퍼티로 치환 (`resolveUserBindings`, `SceneDocument.swift:660-662`, `:1666-1689`).
- `instanceoverride` 파싱·적용 완료 (`SceneDocument.swift:1486-1571`, `ParticleSystem.swift:434-487`).
- `shape:"quad"` effects 캐리어 승격 완료 (`SceneDocument.swift:1047-1079`).
- camera 의사-오브젝트(`zoom`/`origin`/`fov`) 파싱 및 2D 줌/오리진 팬 소비 완료 (`SceneDocument.swift:1083-1102`, `SceneRenderer.swift:707-729`).
- `attachment` 이름 본-슬롯 부착 완료 (`SceneDocument.swift:972`, `SceneRendererFrameEncoder.swift:719-748`).
- `solid_instance` `instance` 블록 텍스처 치환 완료 (`SceneDocument.swift:1440-1458`).
- `camerashake`, `cascadedistance`, `fogdistance`/`fogheight` 파싱 및 소비 완료.

**[갭]**
- `perspective:true` + `perspectiveoverridefov`: 파싱·보존은 되나 2D 렌더 경로에서 원근 투영 미소비.
- `composelayer config.passthrough`: 27씬에 사용되나 코드 전체에 파싱/처리 없음.
- Object-level render flags(`disablepropagation`, `copybackground`, `clampuvs`, `spacing`, `nointerpolation`): 대부분 무시.
- Camera 의사-오브젝트 `path`/`queuemode`: 1씬 실 애니 드롭.
- `animationlayers` 키프레임 값 구동: `blend`/`visible`/`rate` 스크립트는 재평가되나 키프레임 자체는 미반영.
- Bone sway `aniLayer.setFrame`: JS 낸부 frame만 갱신, Swift 렌더러가 읽지 않음.

### 4.2 Particle System / Simulator

**[일치]**
- 48 컴포넌트 분류 구조(emitter 3 / initializer 16 / operator 25 / renderer 4) 일치.
- Renderer 4종(`sprite`, `spritetrail`, `rope`, `ropetrail`), change operator 3종, exponent 분포 `pow(rand, exponent)`, `start==end` step, `start>end` 역보간, `endtime>1` 미완성 사망 규약 모두 일치.
- `maxcount` = 동시 생존 상한, `controlpoint` 8슬롯, emitter 오디오반응, `vortex_v2` 근사 매핑, REFRACT 파티클 구현 완료.

**[갭]**
- operator 롱테일 17종(`boids`, `collision:*`, `maintain distance`, `reduce movement near control point`, `hsvcolorrandom` 등) 미구현. 코퍼스 0건.
- `maxcount` 상한 클램프 부재(하한 0만 있음).
- `remap` operator의 input source/transformfunction/operation 다양성 부분 구현.
- 머티리얼 `combos`/`usershadervalues` 미구현.

### 4.3 Shader / Uniform / GLSL Translation

**[일치]**
- GLSL→MSL 번역기, combo 조합별 별도 MTLLibrary, `mul(v,M)` 인자순서 보존, `texSample2D`, `CAST3X3`, `#include` 인라인, `// [COMBO]` 마커 파싱 등 구현.
- EngineU 레이아웃(`g_Frametime`, `g_PointerPositionLast`, `g_ParallaxPosition`, `g_TextureNTexel`, `g_Screen` 등) 및 `engineNeutralDefault`(`g_Color4`, `g_TextureReductionScale`) 등록.
- `g_TexelSize` → `1.0 / eng.texRes[0].xy` 번역.

**[갭]**
- `g_LightAmbientColor`가 `isEngine`/`engineNeutralDefault`에 없어 bare uniform 선언 시 0 폭백.
- 3D 메시 머티리얼/셰이더에는 `GLSLTranslator` 미사용(고정 `Mesh3DShaders`).
- `texSample3D`/3D LUT, `ccsimple` 매핑 없음.
- `g_TexelSize`가 실제 렌더 타깃 dims가 아닌 `texRes[0]` 근사.
- 2D 레이어 커스텀 머티리얼 셰이더 번역 경로 없음.

### 4.4 Render / Color Pipeline

**[일치]**
- HDR 시 `rgba16Float` 중간 누적, LDR 시 `bgra8Unorm`, 최종 톤맵 = `saturate` 클램프(ACES 없음), LDR bloom `base + bloom` 합성 일치.
- shadow atlas → scene draw 순서, BGRA8 최종 출력, premultiplied alpha 규약 일치.
- 2D `f_lit` point/directional/spot 분기, 3D spot/PBR/CSM, RIMLIGHTING/SHADINGGRADIENT/FOG 콤보 구현.

**[갭]**
- HDR bloom이 8단 듀얼-필터 피라미드가 아닌 단일 레벨 근사.
- `bloomHDRScatter` 파싱만 되고 소비되지 않음.
- C03 Ultra EOTF `pow(2.4)` 및 씬 전역 color grading(brightness/contrast/channel ×2) 미구현.
- 2× MSAA 및 float resolve 미구현.
- Volumetric light shafts/god rays 미구현(필드만 파싱).
- 품질별 픽셀 포맷 분기 없음(`hdr` 플래그 단일 결정자).

### 4.5 Format / Asset (PKG / TEX / MDL / SHDV)

**[일치]**
- PKGV 레이아웃(magic 길이→`PKGVxxxx`→entryCount→entries→연접 blob) 일치.
- TEXV0005 헤더 7정수, Format enum, LZ4 raw mip, IsVideoTexture(0x20), sprite sheet(TEXS), 조건 변형(TEXB0004) 일치.
- MDLV0023, MDLS/MDAT/MDLA 서브블록, PuppetModel 라우팅 일치.

**[갭]**
- PKGV 매직/버전 검증 부재.
- PKGV 라이터(binary encoder) 부재.
- `.tex` `Flags & 0x40` depth 플래그 미처리 → depth/volume 텍스처 파싱 실패 가능.
- `MDMP`(morph target) 서브블록 미파싱.
- `SHDV0069` 셰이더 캐시 포맷 파서 전무.
- `PuppetModel`이 `Bone.properties`(IK JSON) 버림.
- MDAT count를 `u16`이 아닌 `u8+padding`로 읽어야 할 가능성.

### 4.6 Audio

**[일치]**
- SCStream 기반 시스템 오디오 캡처, 128 bin(64L+64R), Hann window, `/max` 정규화 제거, 고정 게인(`0.023260`) 적용.
- `g_AudioSpectrum16Left/Right` 셰이더 바인딩.

**[갭]**
- Sound 3D spatialization(`spatialization`/`mindistance`/`attenuation`) 미지원.
- Audio 절대 스케일 캘리브레이션 미확정(WE 실측치 필요).

### 4.7 Web / Video

**[일치]**
- Web hard pause(rAF/setTimeout/AudioContext/CSS/WAAPI/HTMLMediaElement), ServiceWorker shim, `document.hidden` 스푸핑, bridge parity 구현.
- HEVC 우선, webm ffmpeg 폭백, `m4v` import, 씬-임베디드 MP4 디스크 캐시.

**[갭]**
- `localStorage`/`IndexedDB` nonPersistent(정책 의도).
- `userDirectoryFilesRemoved` 브리지 미구현.
- 웹 데스크탑 실입력(클릭/휠/키) 미전달.
- edge/wpctx/mute 브리지 미이식.

### 4.8 Runtime / SceneScript

**[일치]**
- SceneScript `init`/`applyUserProperties` 발화, `engine.userProperties` 교차 읽기, `cursor*` 6훅, `media` 5훅, `WEMath`/`WEVector` 실심, `timeOfDay`, `input.cursorWorldPosition` 등 구현.

**[갭]**
- IComponent 17훅 중 `destroy`/`resizeScreen`/`applyGeneralSettings`/`cursorHitTest` 미수집.
- `engine.isScreensaver()` 동적 주입 부재(현재 WapleSaver는 동영상 전용이라 무해).
- Runtime callback cadence(update/cursorMove/media polling)가 WE 실제와 일치하는지 미확인.

### 4.9 Roadmap H1-H7 / Synthesis

**[일치]**
- H1 sphere emitter `sign` 축별 반구 강제 구현.
- H3 `HDRPostPass` 최종 `saturate` 클램프.
- H5 `EffectManifest` + GLSL 번역 경로.
- H6 pointer/audio uniform 주입.

**[갭]**
- H2 `SceneObject3D.dependencies` 파싱은 되나 3D 렌더 순서 보정에 미사용.
- H4 3D 메시는 `GLSLTranslator` 미사용(손-포팅 MSL).
- H7 매핑 정보 없음.

---

## 5. 수정 우선순위 및 실행 계획

### 5.1 Phase 1 — High Impact, Narrow Scope (1~2일 예상)

1. **`usershadervalues` 파싱/주입**
   - `SceneDocument.swift:917-935`, `SceneRenderer3D.swift:535-546`, `ParticleSystem.swift:196-209`에서 파싱.
   - `userProps` 룩업 후 셰이더 상수로 주입.
2. **`g_PointerState` 클릭 모니터 게이팅 제거/확장**
   - `SceneRenderer.swift:463-470` 조건에 `hasPointerStateShader` 플래그 추가.
3. **`material.constantshadervalue.scripted` 2D PBR scalars**
   - `SceneLayer`에 script 필드 추가, `SceneRendererFrameEncoder`에서 per-frame 평가.
4. **`g_LightAmbientColor` 엔진 중립값 추가**
   - `GLSLTranslator.swift:1129-1132`, `:1201-1208`.
5. **`maxcount` 상한 클램프**
   - `ParticleSystem.swift:628` → `min(65536, max(0, ...))`.
6. **PKGV 매직 검증 + MDAT count u8 수정 + 스테일 주석 정정**
   - `ScenePackage.swift:47-49`, `Model3D.swift:336`, `Model3D.swift:37`, `TexDecoder.swift:163`.

### 5.2 Phase 2 — Medium Impact, Architecture Touch (2~4일 예상)

1. **2D 레이어 커스텀 머티리얼 셰이더 경로**
   - `parseLayer`에서 `shader`/`combos`/`constantshadervalues`/`textures` 전체 보존.
   - `SceneRenderer.buildLayers`에서 `GLSLTranslator.translate`로 파이프라인 빌드.
   - `SceneRendererFrameEncoder.encodeLayer`에 EngineU 기반 커스텀 레이어 분기.
2. **3D 메시 커스텀 머티리얼 셰이더 경로**
   - `SceneRenderer3D.loadMesh3DMaterial`에서 `shader` 필드 읽고 번역 시도, 실패 시 `Mesh3DShaders` 폭백.
3. **REFRACT 이미지/3D 레이어 확장**
   - 파티클 REFRACT 구조(`pf_refract`)를 재사용해 이미지/3D 레이어용 `refractPipeline` 추가.
4. **`perspective:true` / `composelayer passthrough` 렌더 소비**
5. **HDR bloom 피라미드 승격**
   - `bloomHDRIterations`/`bloomHDRScatter`를 실제 듀얼-필터 geometry에 연결.

### 5.3 Phase 3 — Large Features / Validation Required

1. Volumetric light shafts ray-march 패스.
2. C03 Ultra EOTF + color grading.
3. 3D PBR normal map / per-pixel mask.
4. Sound 3D spatialization.
5. 2× MSAA + float resolve.
6. `ccsimple`/3D LUT.
7. PKGV 라이터 / SHDV 파서.

---

## 6. 권장 즉시 조치 (Next Action)

1. 위 Phase 1 항목 6개를 먼저 구현/검증.
2. 각 수정 후 `swift test` 및 `WapleCompat --deep` 또는 골든 스냅샷 비교 실행.
3. Phase 2는 설계 리뷰 후 순차 적용.
4. 외부 문서 갱신: `re-audit-2026-07` 문서 중 이미 구현된 항목에 "스테일" 표기.

---

## 7. 부록: 에이전트별 주요 발견 인덱스

| 에이전트 | 주제 | 핵심 판정 |
|----------|------|-----------|
| agent-29 | L1 scene/model JSON ↔ SceneDocument | 구조 일치, 일부 필드 파싱-소비 불일치 |
| agent-34 | ParticleSystem operators/initializers | 48 enum 구조 일치, 18개 토큰 미지원 |
| agent-37 | Material system / passes / combos | `usershadervalues` 미구현, base-assets 의존 효과 스킵 |
| agent-41 | Engine uniform whitelist | `g_LightAmbientColor` 등 잠재적 누락 |
| agent-43 | Tonemap / color pipeline | ACES 없음, 품질별 포맷/Ultra EOTF 갭 |
| agent-44 | Bloom | 8단 피라미드 미구현 |
| agent-65 | Corpus rendering gaps | perspective/passthrough A-tier 갭 |
| agent-70 | G-prevalence synthesis | `g_PointerState` 배관, REFRACT 확장 갭 |
| agent-79 | WE-2.8-FINAL H1-H7 | H2/H4 갭 |
| agent-90 | SYNTHESIS-D corpus | 11개 S/A-tier 잔여 갭 |
| agent-92 | SYNTHESIS-F-MASTER §2 | volumetric shafts, 품질별 포맷, `g_LightAmbientColor` |
| agent-95 | Windows-Any AUDIT-SUMMARY | EOTF, 8단 bloom, color grading 갭 |

---

*본 보고서는 정적 분석 결과이며, 실제 렌더링 검증(A/B, 골든 비교)은 별도로 수행해야 합니다.*
