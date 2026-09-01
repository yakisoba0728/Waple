# AUDIT-VERIFIED-MASTER.md

## 0. 머리말

**검증 모드.** 3개 감사 문서(`AUDIT-FULL-2026-08-31-r2.md` · `AUDIT-FULL-2026-08-31-r3.md` · `docs/audit-r4-read/findings-detail.md`, 누적 214건)를 검증기 6개(Sonnet, 각 최대 72건 배정)가 적대적으로 재현하고, 본 종합 에이전트 1개가 그 결과를 하나의 마스터 목록으로 접었다. 검증은 브리핑 지시대로 **읽기·grep·git log -S·capstone 디스어셈블·python3 파싱**으로만 수행했고, `swift build`/`swift test`는 전혀 실행하지 않았다.

**대상 3문서**
- `AUDIT-FULL-2026-08-31-r2.md` (C1, H1–H20, §4.1–4.5 계통별 요약 34건)
- `AUDIT-FULL-2026-08-31-r3.md` (M1–M68, O1–O28)
- `docs/audit-r4-read/findings-detail.md` (44건, r4-01~r4-44)

**기반 실측.** Xcode 27.0 Beta 5 / Swift 6.4 · 실물 워크샵 코퍼스(446-)는 이 머신에 없음 · `swift test` 실패 0 / 스킵 63 / 실행 4,016 · `ci.yml` 하한 4,016(여유 0) · Waple HEAD `b883386e`, 작업 트리 깨끗 · RE 저장소(`Waple-wallpaper-source`) HEAD `1fac2a0c` + 미커밋 14파일.

**판정 분포**

| 판정 | 건수 | 비고 |
|---|---:|---|
| confirmed | 173 | |
| plausible (~) | 12 | 기전은 실증, 도수/전수/런타임 등 일부가 미확인 |
| refuted | 1 | 전제는 참이나 결론이 반증됨 |
| duplicate | 8 | 이 저장소의 더 이른 문서에 이미 같은 자리·기전으로 기록됨 |
| **합계** | **194** | |

살아남은 것(확정 목록 대상) = confirmed + plausible = **185건**. 기각된 것(기각 표 대상) = refuted + duplicate = **9건**.

심각도 표기는 각 원문서의 ID 접두 관례(C=critical🔴, H=high🟠, M=medium🟡, O=observation⚪ — 검증기 노트가 명시한 색상 체계와 일치)를 그대로 따랐다. r4 항목 중 `[confirmed/observation]`으로 명시 태깅된 것은 원문서 자신이 ⚪로 매긴 것이며 하향이 아니다.

---

## 1. 확정 목록 (185건, 심각도순 · 원 출처 = ID 접두)

표기: `~ID`는 plausible. 각 행 끝의 "→"는 무엇이 미확인인지.

### 1.1 Critical (1건)

| ID | 위치 | 요약 |
|---|---|---|
| `r2-C1` | ParticleSimulator.swift:1262 | 자식 파티클 CP 피드와 이미터 CP 평행이동이 겹쳐 부모 위치를 2회 가산 — thunderbolt.json 직파스로 재현 |

### 1.2 High (21건)

| ID | 위치 | 요약 |
|---|---|---|
| `r2-H1` | Scene3DLighting.swift:336 | WE 라이트 forward 팩커는 모델행렬 col0, Waple은 col2 — capstone 재디스어셈블로 주소·명령 일치 확인 |
| `r2-H2` | PuppetModel.swift:326 | MDLA 클립 flags 미해석 → flags&1의 0xC0 레코드 스킵 실패(도달 모집단은 이 머신에 없음) |
| `r2-H3` | AppDelegate.swift:997 | 부화면 재생목록 전진이 스테일 전역선택으로 매초 후보를 소진, 사용자 통지 0 |
| `r2-H4` | SceneRenderer.swift:1315 | `parallaxEnabled:false`면 `g_ParallaxPosition`이 영구 (0,0) → 셰이더가 최대 음의 편향으로 해석 |
| `r2-H5` | SceneRenderer.swift:1224 | `parallaxFocus` 마운트 기본이 (0,0) — '무이동'이 아니라 '최대 편향' |
| `r2-H6` | SceneRendererFrameEncoder.swift:1656 | orthographicScene 게이트가 마운트/프레임승격에서 비대칭 — 정적 레이어 영구 unhittable |
| `r2-H7` | ParticleSimulator.swift:1024 | 부모 사망 후 자식의 previousRuntimeControlPoints가 얼어붙어 낡은 선분 재적용(수치 재현은 미시행) |
| `r2-H8` | AppDelegate.swift:653 | F820 음량/배속 라이브반영이 videoFallback(WebRenderer) 경로 누락 |
| `r2-H9` | ci.yml:794 | CI 존재게이트 정규식이 skipped/started/passed/failed 미구분 → XCTSkip을 통과로 오분류 |
| `r2-H10` | ScenePerspectiveOverrideFovRenderTests.swift:226 | 빈 배열끼리 비교하는 신규 테스트 — 클램프 호출을 지워도 초록 |
| `r2-H11` | NOTICE:27 | 8bitOperatorPlus8-Regular.ttf가 목록에서 빠져 '11종 무근거'가 실제 12종 |
| `r2-H12` | SnapshotPipeline.swift:349 | 셀프체크 프로세스 분리 수정이 무효한 축(정본은 세션간, 프로세스간 아님) |
| `r2-H13` | SnapshotPipeline.swift:314 | 셀프체크 helper 실패시 조용히 lax 강등, exit 0 |
| `r2-H14` | SnapshotCompare.swift:132 | 베이스라인 entries가 비면 0종 비교 후 exit 0 — 90% 하한 무력화 |
| `r2-H15` | UIConventionTests.swift:145 | 접근성 게이트 2종이 `Button{}label:{}` 표기와 자식 오버레이 라벨로 면제 |
| `r2-H16` | WallpaperGridView.swift:182 | 순수 키보드(Tab) 사용자는 인스펙터 도달 불가(focusedId는 마우스 경로뿐) |
| `r2-H17` | WebInputProxyView.swift:79 | 한국어 리터럴이 NSString.draw 경로라 현지화 스캐너 4패턴 전부 회피 |
| `r2-H18` | package-app.sh:101 | `codesign --deep --identifier`가 중첩 saver 식별자를 덮어씀(macOS13+ 폐기 옵션) |
| `r2-H19` | ZipImporter.swift:41 | 압축폭탄/여유공간 상한 0건 — 방어는 300초 시간상한뿐 |
| `r2-H20` | MonitorAssignmentStore.swift:8 | `.corrupt-*` 백업 읽기/알림 코드 0건 — '복구 가능' 주석에 출구 없음 |
| `r2-4.5-assertion0` | SingleSceneProbeTests.swift:10 등 | 단언 0 테스트 추가 2건 발견, 영구 스킵 — 직전 감사의 '전수' 주장 반박(**medium→high 상향**, §5 참조) |

### 1.3 Medium (약 125건)

#### r2 §4.1–4.5 (인용 드리프트·정본 불일치, 28건)

| ID | 위치 | 요약 |
|---|---|---|
| `r2-4.1-lane4` | GLSLTranslator.swift:1527 | 자기 diff 줄번호 드리프트 — engineReplacement 인용 4건 전부 어긋남 |
| `r2-4.1-lane5` + `r4-02` (병합, §3 참조) | SceneRenderSettings.swift:58 | fitMode 소비처 5곳 중 4곳 인용 무효 / 확장하면 버킷1 cross-file 인용 17건 중 12건 무효 |
| `r2-4.1-lane2` | TexImage.swift:64 | 교차파일 인용 2건 드리프트 |
| `r2-4.1-lane1` | SceneRendererResources.swift:363 | SceneDocument.swift 인용 드리프트 + 원 주장 자체가 PR#8로 반증됨 |
| `r2-4.1-lane3` | ParticleSimulator.swift:911 | 4건 인용 중 2건 재현(드리프트) |
| `r2-4.1-lane11` | main.swift:168 | --deep 0건 가드 인용 드리프트(자기 +11줄) |
| `r2-4.1-lane14` | BACKLOG.md:448 | 파일:줄 인용 28건 중 21건(75%) 무효(표본 3/3) |
| `r2-M25` | docs/re/shader-uniforms.md:820 | 폐기된 g_Bones VA 잔존 |
| `r2-M22` | SceneDocument.swift:4072 | 11로 고침, 짝저장소 scene-json-schema.md는 여전히 13 |
| `r2-M19` | corpus_scan/mdl-format.md:284 | v23 morph/mask 정정이 미커밋 트리에만, 형제문서 3자리 잔존 |
| `r2-oscillate-44of61` | ParticleSimulator.swift:1303 | oscillate 도수 61건 주장은 17건 과장, 실제 44건 |
| `r2-M21-M16` | measure_workshop_shaders.py:83 | 자기 인용 pre-image 줄번호 3곳 |
| `r2-4.3-ciyml` | ci.yml:295 | 낡은 Metal census(77/324) 재인용, 실측 82/364 |
| `r2-4.3-docsreadme` | docs/README.md:61 | '실제값으로 고쳤다' 표 3/3 다시 틀림 |
| `r2-4.3-agentsmd` | AGENTS.md:617 | FUN_140261950 인용, Sources 0건 주장은 부분무효(메타설명 2건 존재)(연관: `r3-M51`, §3) |
| `r2-4.3-readmehdr` | README.md:46 | HDR bloom ±0.5 서술이 b19db5b1 수정 후 미갱신 |
| `r2-4.3-fingerprint` | spec/binaries-fingerprint.json:87 | 246/341→245/340 미재생성 |
| `r2-4.3-readme999` | README.md:37 | '~99.9% 컴파일' 근거 0건 |
| `r2-4.3-backlog0ref` | BACKLOG.md:1 | AUDIT-FULL-2026-08-31 0회 참조 |
| `r2-4.3-shader2` | SceneRenderer3D.swift:950 | 인용 2건이 범위 안이나 1줄 밀림 |
| `r2-4.4-parsepe` | analysis/parse_pe.py:238 | IMAGE_TLS_DIRECTORY64에 없는 7번째 필드를 읽음(회귀) |
| `r2-4.4-delayload` | analysis/pe-structure.md:165 | delay-load '4개'가 널종결자 포함(실제 3개) |
| `r2-4.4-tlscoords` | analysis/pe-structure.md:225 | TLS 좌표가 바이너리·형제JSON과 어긋남 |
| `r2-4.4-vmrange` | WE-ENGINE-ANALYSIS-2026-07-27.md:781 | 오퍼레이터 VM 범위가 정본보다 874B 짧음 |
| `r2-4.4-texcount` | corpus_scan/chunk-type-census.md:30 | .tex 전수 4,679/4,991/5,120 세 값 혼재 |
| `r2-4.4-fboaudio` | measure_effect_fbo_audio.py:513 | 입력 0에서 rc=0으로 정본 재작성(형제 다수는 rc=1·미쓰기) |
| `r2-4.5-concurrency` | ci.yml:153 | 동시성 진단 census 상한만 있고 하한·패턴생존 확인 없음 |
| `r2-4.5-saverlifecycle` | test_waple_saver_lifecycle.py:46 | 소스 문자열 grep — 게이트를 뒤집어도 통과 |

#### r3 M-series (64건, M1/M7/M20/M21은 중복으로 제외)

| ID | 위치 | 요약 |
|---|---|---|
| `r3-M2` | Model3D.swift:87 | '전건 단일NUL' 전칭이 같은 파일 안에서 자기반박(v0004 8/8 예외 자인) |
| `r3-M3` | mdl-deep.json:565 | indexWidth 인용 드리프트(주장 :577→실제 :762) |
| `r3-M4` | Model3D.swift:201 | 메시별 materials 주석에 파일모집단(451)을 메시모집단(986) 혼동 표기 |
| `r3-M5` | ParticleSystem.swift:3476 | mapSeqClampCP 32비트 판정, 절단 안 된 원값 반환 + 선행 감사의 반례 방향 정정 |
| `~r3-M6` | ParticleSimulator.swift:553 | 인용 19자리 중 14 무효 주장 — 1표본만 재현, 전건 도수 미확인 |
| `r3-M8` | GLSLTypeAdapter.swift:568 | WE shim 인용 2건이 ±1 밀리며 상호 모순 |
| `r3-M9` | ScenePBRLighting.swift:301 | generic3.frag 루프헤더/델타대입줄을 가리키는 인용 |
| `r3-M10` | AudioResponse.swift:108 | '동봉 2건' 주석 — 실제 설치본 3줄/2파일(모집단 혼동) |
| `~r3-M11` | AudioSpectrum.swift:40 | 48kHz→44.1kHz 재환산시 결론 반전 주장 — Δt 산술 재계산 미완 |
| `r3-M12` | SceneRendererFrameEncoder.swift:399 | 도수 6자리 모집단 미표기(§4.2 재측정치 승계) |
| `r3-M13` | SceneVideoLayer.swift:32 | 트랙방향 분류표 두 행이 180° 반대 |
| `r3-M14` | VideoFallbackHTML.swift:6 | videoFallback 경로는 배속을 한 번도 적용 안 함 |
| `r3-M15` | FFmpegConverter.swift:175 | 벽시계 상한 실제 ≈610초(timeout×2+10) |
| `r3-M16` | measure_script_api.py:1340 | WEColor 커버리지 이미 확정인데 생성기가 갭으로 표시 |
| `r3-M17` | SceneAudioPlayer.swift:9 | '코퍼스 460종' 모집단명 정본 미정의 + 정본 충돌 |
| `r3-M18` | AppDelegate.swift:1830 | 인용 12자리 무효, 부모 커밋에선 11자리 정확 — lane08 '드리프트 0' 반증 |
| `~r3-M19` | AppDelegate.swift:1894 | 트레이 비활성가드가 NSMenu 자동활성화로 무효화 — 런타임 미검증 |
| `r3-M22` | Metrics.swift:71 | 설정창 리사이즈불가+height고정 전제 둘 다 코드로 거짓 |
| `r3-M23` | SettingsView.swift:150 | 표시 라벨 중복의 근거 두 개 모두 스테일 |
| `r3-M24` | LibraryFiltering.swift:47 | 폴더 선택시 태그·나이등급 필터가 무필터로 붕괴 |
| `r3-M25` | Metrics.swift:19 | 자기 실측 스테일(28≠20) + '공유 토큰' 예시 중 참조 0건 존재 |
| `r3-M26` | WallpaperGridView.swift:183 | 그리드 타일 유형배지가 접근성 값에 미전달 |
| `r3-M27` | measure_nondeterminism.py:263 | 확정 항목 근거가 무관 코드/생성기 하드코딩(§4.2 좁힌 프레이밍 승계) |
| `r3-M28` | RealPackagesGroundTruthTests.swift:181 | F840 스윕이 Tests 5자리 놓침(golden GT 픽셀 오라클 포함) |
| `r3-M29` | check_int_narrowing.py:42 | selftest·하한 둘 다 없음(전칭은 M48로 반증) |
| `~r3-M30` | verify-plan-b12.sh:145 | §5 게이트 툴체인의존 프레이밍 — 존재는 확인, 원인 규명은 미검증 |
| `r3-M31` | verify-plan-b12.sh:155 | AGENTS.md가 인용금지한 숫자(2,300)를 기준값으로 사용 |
| `r3-M32` | 01-check-env.sh:7 | 존재하지 않는 브랜치를 요구해 항상 exit 1 |
| `r3-M33` | linux-render-typecheck.sh:231 | 공유락 설명 세 주장이 같은 파일:90-96·형제스크립트에 반박됨 |
| `r3-M34` | linux-render-typecheck.sh:56 | 하네스 심 종수가 spec.yml 안에서 15/17로 갈리고 실측 24 |
| `r3-M35` | WallpaperSchemeHandler.swift:224 | 보안주석이 형제규약과 다르게 isSymbolicLinkKey 미요청 |
| `r3-M36` | BaseAssetsSettings.swift:8 | UserDefaults 주입점 없음(lane12 clean 판정 반박) |
| `r3-M37` | AppDelegate.swift:1578 | notify() 미러가 정지배경 성공 메시지도 빨강으로 그림 |
| `r3-M38` | WebRenderer.swift:380 | WKNavigationDelegate 실패 콜백 미구현(형제 VideoRenderer는 있음) |
| `r3-M39` | SceneRenderer3D.swift:2090 | volumetricLightPass 소비자가 fov 클램프 건너뜀(lane06 전칭 반박) |
| `r3-M40` | hdr-bloom.json:125 | '코퍼스 140/161' 서술이 같은 항목 실측필드(169/146)와 충돌 |
| `r3-M41` | ParticleSimulator.swift:524 | time 누산 Float32라 6.07일 벽에서 애니메이션 정지 |
| `r3-M42` | ParticleSceneFixRegressionTests.swift:61 | 테스트가 실제로는 speedmax 부재 폴백 분기를 안 탐 |
| `r3-M44` | ci.yml:320 | 병렬 격리 게이트가 클래스별 --filter라 교차클래스 경합 원리적으로 못 봄 |
| `r3-M45` | SceneGeneralDefaultsWEParityTests.swift:66 | IEEE754 비트동일 테스트가 리터럴 자기자신만 비교(민감도 0) |
| `r3-M46` | SyntheticPixelGoldenTests.swift:193 | cases() 축소를 잡을 카운트 단언 없음(형제 오라클과 대비) |
| `r3-M47` | check_js_shim_baseclasses.py:147 | node 부재시 rc=0, spec.yml이 node 미고정 |
| `r3-M48` | check_particle_corpus_census.py:67 | selftest·하한 둘 다 없음(M29 전칭 반증) |
| `r3-M49` | spec.yml:471 | 낡은 spec 게이트 방어인용 '다섯 자리' 전칭이 실제 2건만 확인(축소정정 승계) |
| `r3-M50` | BACKLOG.md:647 | 존재하지 않는 baseline-f3a17da를 현행 기준선으로 현재형 서술 |
| `r3-M51` | spec/README.md:19 | 이미 고쳐진 FUN_140261950 인용을 정본으로 반복(연관: `r2-4.3-agentsmd`) |
| `r3-M52` | docs/RELEASING.md:176 | release.yml 인용이 실제 자리에서 106줄 밀림 |
| `r3-M53` | golden/snapshot/README.md:179 | 근거 인용 두 건이 실제로는 무관한 코드를 가리킴 |
| `~r3-M54` | WallpaperCompatibilityAnalyzer.swift:548 | 파일:줄 인용 다수 무효 — 기전 실증, 131자리 전수 재계산 미완 |
| `r3-M55` | ShaderPreprocessor.swift:515 | 세 자리가 독립적으로 :12를 인용, 실제 로직은 :148/:152 |
| `r3-M56` | SceneRendererResources.swift:1382 | tex flags 규약 인용 3자리가 전부 VariantCondition 파서를 가리킴 |
| `~r3-M57` | deviations.json:14 | D1 항목 좌표 두 자리 13·23줄 밀림 — 8자리 전건 무효 주장은 미검증 |
| `r3-M58` | render-state.json:955 | 확정 항목이 다른 VA를 적은 줄을 '같은 VA 인용'이라 가리킴 |
| `~r3-M59` | linked-libraries.json:1210 | 생성기 하드코딩 소좌표 드리프트 4자리 — 개별 좌표 미검증 |
| `r3-M60` | deviations.json:88 | BlendMSL.swift 인용 줄번호가 실제보다 앞섬(핵심 주장은 유지) |
| `r3-M61` | EffectShaders.swift:136 | 손포팅 shake 진폭 기본값이 WE 대비 277.8배 작음 |
| `r3-M62` | SceneDocument.swift:98 | d.ts 인용 4자리가 선언 아닌 `*/`·`}` 가리킴(전수 80건은 낙관적 정정) |
| `r3-M63` | DecompileAll.java:97 | imported_apis 판정이 부분문자열 매칭(D3D11축 주장은 과장, 정정됨) |
| `r3-M64` | LibraryStore.swift:393 | 일시적 북마크 해석 실패를 tags=[]로 영구 마킹 |
| `r3-M65` | LibraryViewModel.swift:253 | 라이브러리 제거가 5개 스토어만 정리, UserPropertyStore·script-storage 잔존(시나리오 좁게 정정) |
| `r3-M66` | BACKLOG.md:469 | PR#8 '접근성 해소' 근거 중 최소 하나(타입배지)가 같은 커밋 안에서 이미 거짓 |
| `r3-M67` | SelectionPanelView.swift:95 | GIF 프리뷰 3자리가 reduceMotion 한 번도 확인 안 함 |
| `r3-M68` | SceneRenderSettingsTests.swift:68 | '설정창이 쓰는 라벨' 주장이 거짓 — 아무도 안 쓰는 미현지화 라벨을 잠금 |

#### r4 (32건, r4-02는 위에서 병합, r4-35는 중복 제외, observation 태깅 11건은 §1.4로 이동)

| ID | 위치 | 요약 |
|---|---|---|
| `r4-01` | SceneDocument.swift:2549 | effectQuadLayer가 키프레임 애니를 통째로 버림(출생시부터) |
| `r4-03` | SceneDocument.swift:884 | originb는 WE에 없는 키인데 SceneLight3D 주석이 '실측'이라 단언(자기모순) |
| `r4-04` | SceneDocument.swift:567 | depthtest 'enabled 1394건' 모집단 미표기, 정본 1391과 3 차이 |
| `r4-05` | PropertyAnimation.swift:358 | wrapLooped Note가 backEnabled 게이트 주장, 같은 파일 100줄 위가 반대 서술 |
| `r4-06` | ShaderPreprocessor.swift:147 | parseComboDefaults 호출부 주장 2곳 중 1곳 이미 안 부름 |
| `r4-07` | ParticleSystem.swift:2391 | clampControlPoint이 형제 clampIndex와 다른 CP를 고름 |
| `r4-08` | SettingsView.swift:21 | 설정창 높이 주석 '6개 섹션' vs 실제 7개 |
| `r4-09` | ParticleSystem.swift:2707 | 확장자 없는 File:줄 교차파일 인용 4곳 전부 무효 |
| `r4-10` | VolumetricLightPass.swift:269 | radius 경고의 '배선하라'는 인자가 같은 커밋에서 이미 배선됨 |
| `r4-11` | DeepScan.swift:549 | 손포팅 7종을 번역 시도 없이 건너뜀 |
| `r4-12` | DeepScan.swift:911 | '이 파일이 WIRED 표에 없다' 주석을 같은 커밋이 넣고도 실제론 있음 |
| `r4-13` | SceneRendererFrameEncoder.swift:403 | lane05의 좌표 드리프트 열거가 불완전(미열거 5자리) |
| `r4-15` | Mesh3DShaders.swift:599 | '형제' 열거가 존재하지 않는 mf_skinned를 가리키고 mf_refract/mf_reflect 누락 |
| `r4-16` | VideoRenderer.swift:259 | 가림 옵저버 rate!=0 가드가 F840 절전 게이트를 뚫음 |
| `r4-17` | TexDecoder.swift:258 | r8 도수 '60개 중 56개'가 실측 164개 중 51개(서로 다른 census 행 혼동) |
| `r4-18` | SceneRenderer3D.swift:17 | GPU3DMesh 독트링 'ibuf는 u16' — 실제 u32 |
| `r4-19` | SceneRenderer3D.swift:1180 | whitelist 주석이 존재하지 않는 shimmering_particles의 a_Normal 수혜를 오기재 |
| `r4-20` | EffectManifest.swift:503 | 동봉 effect.json 모집단을 128·122·101 세 값(라벨 없이)으로 적음 |
| `r4-21` | WebCompatPatch.swift:151 | '소문자 전건·needle≤63바이트' 근거 진술 둘 다 동봉 자산에 반증됨 |
| `r4-22` | BaseAssetsSettings.swift:6 | 헤더 '동봉 안 함' vs 같은 파일의 동봉 폴백 구현 |
| `r4-23` | SceneRendererResources.swift:848 | 출력 패스 가드를 command:swap 패스가 무력화(형제 라우터는 명시 제외) |
| `r4-24` | LibrarySection.swift:43 | '쓰기 주체가 둘' 근거가 UI 개편으로 거짓, nil 분기 3개 프로덕션 도달불가 |
| `r4-25` | WorkshopTabView.swift:27 | loadMore 실패 인용이 실제론 search()의 catch 블록 |
| `r4-26` | GLSLTranslator.swift:174 | '정확일치 조회 자리 둘' 주장이 실제로는 넷 — 접기 수정이 1/3에만 적용 |
| `r4-28` | PlaylistStore.swift:20 | intervalMinutes 세터만 클램프, 디코드 경로엔 클램프 없음 |
| `r4-30` | ParticleSystem.swift:3140 | 파일명 없는 자기참조 :N 인용 8자리 전부 무효(두 파일) |
| `r4-33` | DeepScan.swift:208 | F681 ogg 예산 doc 주석이 assetLoadTimeoutSeconds에 오부착 |
| `r4-34` | SceneRendererFrameEncoder.swift:450 | copyBackground:false 컴포지션 dst가 acc 스냅샷 아닌 투명 클리어(r3 미판정을 확정) |
| `r4-39` | TextScriptEngine.swift:2285 | 자기참조 :N 인용 2건이 출생시점부터 무효 |
| `r4-42` | SceneGeometry.swift:130 | cameraparallaxdelay 도수 176/175가 두 파일서 전치(176은 파일수, 175는 값=0.1 개수) |
| `~r4-38` | Badges.swift:13 | '42건 중 40건' 모집단 미표기, 42의 근거 불명 |

### 1.4 Observation (38건)

#### r3 O-series (27건, O2는 중복 제외)

| ID | 위치 | 요약 |
|---|---|---|
| `~r3-O1` | WallpaperProperties.swift:73 | 워크샵 타입 상한 10 vs text887/label6 모순 — 대조 대상 원문서 미발견 |
| `r3-O3` | lane05-render-core.md:208 | 세마포어 재현 grep 8행 vs 문서 기재 2행(결론 자체는 유지) |
| `r3-O4` | SnapshotPipeline.swift:217 | 셀프체크 Process() 7자리 중 3자리 타임아웃 무상한 |
| `r3-O5` | PropertyAnimation.swift:680 | events 배열 통째 캐스트 — 항목 하나로 마커 전량 소멸 |
| `r3-O6` | SceneDocument.swift:3116 | 파티클/모델/스프라이트가 변환맵에 없음(§4.2 정정: model/sprite는 가시성맵에도 없음) |
| `r3-O7` | WallpaperProperties.swift:285 | localization 폴백이 Dictionary.keys.first(where:) — 비결정적 |
| `r3-O8` | Model3DPose.swift:129 | 주석 한복판 U+FFFD, 리포 전체 유일 1건 |
| `~r3-O9` | package-format.md:141 | 최대 경로 깊이 6성분 vs 실측 7성분 — 원 데이터 미접근 |
| `r3-O10` | ParticleSimulator.swift:1856 | oscPositionOffset doc이 applyBoids 헤더로 붙음(빈 줄 부재) |
| `r3-O11` | EffectManifest.swift:541 | bind/fbos 배열 캐스트가 원소 하나로 전체 nil, passes만 고쳐짐 |
| `~r3-O12` | AudioResponse.swift:252 | smoothstep 가드 vs 실물 divss 역전 bounds — 디스어셈블 재현 미완 |
| `r3-O13` | FFmpegConverter.swift:124 | 5초 프로브 타임아웃이 유효 캐시를 삭제 |
| `r3-O14` | SceneVideoLayer.swift:185 | 루프 옵저버가 정지 상태를 안 봄 |
| `r3-O15` | NowPlayingProvider.swift:65 | '1000 초과 & Spotify' 조건이 코드/이력 어디에도 없음(무조건 분기) |
| `r3-O16` | DisplaysView.swift:78 | 스냅샷 화면 목록과 라이브 NSScreen을 위치로 재짝짓기 |
| `r3-O17` | SnapshotCompare.swift:142 | 렌더→무픽셀 회귀를 환경오류로 오진단 — §4.2가 좁힌 범위로 확정(**하향, §5 참조**) |
| `r3-O18` | measure_decompilation_provenance.py:67 | 인용 census 게이트가 지금 rc=1(직접 재현) |
| `r3-O19` | test_workflow_contracts.py:145 | `-gt 25` 리터럴 하드코딩이 상한 인하를 스스로 막음 |
| `r3-O20` | BaseAssetsSettings.swift:17 | 게터/세터 비대칭 — save/restore 5자리가 자동탐지를 핀으로 승격 |
| `r3-O21` | SceneVideoLayer.swift:202 | 회전 트랙 라이브 경로가 프레임마다 전량 재할당 |
| `r3-O22` | WallpaperSchemeHandler.swift:112 | 384줄에 로그 0건 |
| `r3-O23` | Scene3DMath.swift:42 | perspective가 nearZ/farZ 미검증(형제는 가드 보유) |
| `r3-O24` | BACKLOG.md:448 | 소스 링크 5건 path:N 형식(404), 2건 #LN 정확 |
| `~r3-O25` | SceneDocument.swift:164 | 82파일 416자리 자기참조 인용 — 모집단 규모 미재계수(표본 1건 확인, r4-30/39가 추가 뒷받침) |
| `r3-O26` | ghidra_decompile.py:115 | 자리 표기 정정 — 짝저장소 scripts/ghidra_decompile.py |
| `r3-O27` | WallpaperGridView.swift:285 | 장식 썸네일 차폐 규약이 그리드 gif 분기 한 자리만 빠짐 |
| `r3-O28` | StatusBanner.swift:74 | 사용자 통지가 4초 배너뿐 — 보조기술 API 호출 0건 |

#### r4 observation-tagged (11건)

| ID | 위치 | 요약 |
|---|---|---|
| `r4-14` | AudioSpectrum.swift:295 | binCount 수정 후에도 옛값 B=940을 현재형으로 유지(같은 파일 20줄 위와 모순) |
| `r4-27` | ZipImporter.swift:62 | terminationHandler를 run() 이후 설치 — 레이스로 타임아웃 오탐 가능 |
| `r4-29` | VorbisCodebook.swift:102 | F840 패킷크기 게이트가 multiplicands만 덮고 lookup_type1 vqFlat은 무관(총량 캡으로 무한폭발은 아님) |
| `r4-31` | SceneRenderer.swift:2739 | captureFrames save/restore가 실제 변이 상태보다 좁음(현재 도달 0) |
| `r4-32` | ScenePBRLighting.swift:704 | 반경감쇠 GPU/CPU 두 벌 중 GPU만 exponent 클램프(소비처는 테스트 전용) |
| `r4-36` | RemapOperation.swift:39 | 주석 '정확한 나눗셈' vs 실제 역수 곱(26% 1ulp 차) |
| `r4-37` | DesktopVisibilityMonitor.swift:163 | 기본값 주석 방향이 alpha에 대해서만 반대 |
| `r4-40` | Model3D.swift:1252 | inferStride가 인덱스폭 u16 고정 — 본경로는 gateWord&1로 이미 전환 |
| `r4-41` | ParticleSimulator.swift:1352 | applyAttract 헤더가 step*=w 블렌드항 주장, 구현에 없음 |
| `r4-43` | SceneRenderer3D.swift:1286 | albedoName이 '첫 non-null' 구규약 유지, 같은 파일이 결함으로 지목·수정한 뒤에도 |
| `r4-44` | PointerHit.swift:314 | g_PointerState 소비처 인용이 preview 사본 둘에서 게인·줄번호 어긋남 |

---

## 2. 문서 간 중복 제거

세 문서(r2/r3/r4) 자신이 같은 결함을 다른 id로 적은 자리를 찾아 접었다. 전수 페어와이즈 대조는 예산상 수행하지 못했고, 아래는 이번 종합 과정에서 실제로 확인된 것이다.

1. **병합 확정 — `r2-4.1-lane5` + `r4-02` (SceneRenderSettings.swift:58)**: 둘 다 같은 파일·같은 줄의 소비처 인용 드리프트를 다룬다. lane5는 `fitMode` 소비처만 좁혀 5곳 중 4곳 무효라 했고, r4-02는 그 주석 블록 전체(버킷1) 17건 중 12건 무효라고 넓게 쟀다 — 후자가 전자를 포함하는 상위 집합. §1.3 표에서 한 행으로 접었다.
2. **r2 내부 중복 — `r2-H6` = `r2-M13`**: r2 문서 자신이 §2(H6)와 §4.2(M13) 두 자리에 같은 SceneRenderer.swift:1165 코퍼스=8 잔존을 적어 두었다. H6를 원본으로 유지하고 M13은 §4 기각 표로 뺐다.
3. **연관(병합 아님) — `r2-4.3-agentsmd`(AGENTS.md:617) ↔ `r3-M51`(spec/README.md:19)**: 둘 다 이미 정정된 FUN_140261950 주소 인용이 다른 문서에 잔존하는 같은 패턴이지만, 파일이 다르고(AGENTS.md vs spec/README.md) r3-M51 자신이 "기지 L14-2 재발"이라 명시해 재발임을 자백한다. 앵커가 달라 한 행으로 접지 않고 별도 유지, 상호 참조만 표기했다.
4. **상류에서 이미 접힌 사례(참고)**: r3는 자신의 감사 과정에서 g_ParallaxPosition 관련 발견 하나를 "이미 r2 H4/H5에 있다"며 스스로 접어 별도 id를 발급하지 않았다 — 이번 194건 풀에는 애초에 등장하지 않는다. r2-H4/H5는 그대로 confirmed로 유지했다.

**한계**: 185건 전체에 대한 체계적 페어와이즈 유사도 검사는 하지 않았다. 특히 r3 M-series(64건)와 r4(32건) 사이, 같은 파일을 다루는 항목들(예: ParticleSimulator.swift를 건드리는 `r3-M41`/`r3-M5`/`r4-07`/`r4-09`/`r4-30`/`r4-41` 등)은 서로 다른 구체적 결함(각기 다른 함수·다른 메커니즘)임을 개별 확인했으나, 이는 표본 확인이지 전수 대조는 아니다.

---

## 3. 기각 표 (9건 — refuted 1, duplicate 8)

| 판정 | ID | 자리 | 기각 이유 |
|---|---|---|---|
| refuted | `r2-4.3-backlogwindow` | BACKLOG.md:461 | 전제('새로 넣은 라벨')는 참(git log -S 확인)이나, 결론('이미 해소된 것')은 과장 — UNUserNotification 미구현은 그대로이고 pendingNotice 메커니즘으로 부분 완화됐을 뿐 |
| duplicate | `r2-M13` | SceneRenderer.swift:1165 | r2 문서 자신의 §2 H6와 동일 결함(내부 중복, §2-2 참조) |
| duplicate | `r2-4.4-rtti` | analysis/rtti-references.json:13 | `docs/swarm-audit-2026-08-26.md:261`이 같은 파일의 같은 '유일 레코드 무효' 결함을 5일 앞서 기록 |
| duplicate | `r3-M1` | PropertyAnimation.swift:419 | `docs/full-audit-2026-08-26.md:180`이 동일 자리·동일 문구로 5일 앞서 기록 |
| duplicate | `r3-M7` | GLSLTranslator.swift:2134 | `docs/full-audit-2026-08-26.md:224`가 동일 함수(captureParamDecl)의 동일 기전을 5일 앞서 기록 |
| duplicate | `r3-M20` | ScreenSaverController.swift:28 | `docs/swarm-audit-2026-08-26.md:208`이 동일 파일:줄·동일 결함을 5일 앞서 기록 |
| duplicate | `r3-M21` | NowPlayingBar.swift:288 | `docs/swarm-audit-2026-08-26.md:207` 및 `docs/full-audit-2026-08-26.md:72`가 동일 기전을 5일 앞서 기록 |
| duplicate | `r3-O2` | CameraMotion.swift:320 | `docs/full-audit-2026-08-26.md:182`가 동일 결함(effectivePathDuration beforeSegment 공식)을 이미 기록 |
| duplicate | `r4-35` | LibraryStore.swift:218 | `docs/full-audit-2026-08-26.md:195`가 동일 자리(당시 :215)를 이미 기록 — 증분(손상zip=로그0건)은 서술 수준이라 별도 승격 안 함 |

**패턴 관찰**: 8건의 duplicate 중 6건이 `docs/full-audit-2026-08-26.md` 또는 `docs/swarm-audit-2026-08-26.md`(둘 다 2026-08-26, r3보다 5일 앞섬)에 이미 있었다. r3 자신이 §4.1에서 "기지 대조 8건 중 5건이 실제로는 기지였다"고 자백했는데, 이번 검증이 M1-M34 34건만 훑어도 같은 패턴이 추가로 나왔다 — **다음 감사 라운드는 반드시 이 두 08-26 문서를 전체 색인에 대해 재대조해야 한다.**

---

## 4. 심각도 정정 표

| ID | 원 등급 | 정정 등급 | 근거 |
|---|---|---|---|
| `r2-4.5-assertion0` | 🟡 medium | 🟠 **high (상향)** | 직전 감사가 "단언 0 테스트는 3,886개 중 1건뿐"이라 전수를 주장했으나, 이번 검증이 grep으로 정식 추적 파일 2건(SingleSceneProbeTests·ThreeDV3CaptureTests)을 추가로 확인 — CI가 요구 env를 어디서도 설정하지 않아 영구 스킵. 게이트 신뢰성 자체에 대한 영향이 커 상향 |
| `r3-O17` | (상위 등급, 원문 표기대로) | ⚪ **observation (하향)** | 원 서술은 "사람을 반대 방향으로 보낸다"는 강한 주장이었으나, §4.2 재검증에서 stdout이 렌더→무픽셀 회귀=N과 id 목록을 먼저 찍음을 확인 — 오진단은 종료코드·stderr 한 줄에 국한되는 좁은 결함으로 축소 |

그 외 항목(`r3-M29`, `r3-M44`, `r3-M48`, `r3-M49`, `r3-M54`, `r3-M57`, `r3-M59` 등)은 검증기가 원 등급을 재확인만 하고 변경하지 않았다 — 명시적으로 "correctedSeverity 원 등급 유지"라 기록됐다.

---

## 5. 라운드별 정확도

검증은 6개 배정 단위(검증기별)로 수행됐고, 배정 경계가 항상 라운드 경계와 일치하지는 않는다(마지막 배정은 r3-O계열과 r4를 함께 받았다). 확인 가능한 단위 그대로 보고한다.

| 배정 | 대상 | 건수 | confirmed | plausible | duplicate | refuted | confirmed 비율 |
|---|---|---:|---:|---:|---:|---:|---:|
| 검증기 A | r2 C1+H1~H20 | 21 | 21 | 0 | 0 | 0 | **100%** |
| 검증기 B | r2 §4.1~4.5(계통별 🟡 요약) | 33 | 30 | 0 | 2 | 1 | **90.9%** |
| 검증기 C | r3 M1~M34 | 34 | 27 | 3 | 4 | 0 | **79.4%** |
| 검증기 D | r3 M35~M68 | 34 | 30 | 4 | 0 | 0 | **88.2%** |
| 검증기 E | r3 O1~O28 + r4 44건(72건, 혼합) | 72 | 60 | 6 | 3 | 0 | (원문 그대로 인용, 69/72 판정) |

**라운드 롤업(명확히 분리 가능한 범위만)**

- **r2** (검증기 A+B, 54건): confirmed 51 / plausible 0 / duplicate 2 / refuted 1 → **confirmed 비율 94.4%**. 두 배치 모두 90%를 넘겨 **세 라운드 중 가장 신뢰할 만했다** — C1/H1-H20 배치는 capstone 디스어셈블·정본 대조까지 동원한 깊은 재현이 21/21 전원 생존한 결과다.
- **r3 M-series** (검증기 C+D, 68건): confirmed 57 / plausible 7 / duplicate 4 / refuted 0 → **confirmed 비율 83.8%**. duplicate 4건이 전부 M-series에서 나왔다는 점이 특징 — 08-26 문서 대조가 부실했던 흔적.
- **r3 O-series + r4**: 검증기 E가 두 출처를 한 배정으로 묶어 보고해 개별 분리된 pass rate가 소스에 없다. 다만 named 사례를 보면 duplicate 3건 중 2건이 명시적으로 각각 r3-O(1건: O2)와 r4(1건: 35)에 귀속되고, plausible 6건 중 5건이 named되어 r3-O 4건(O1,O9,O12,O25)·r4 1건(38)로 갈린다 — r3-O 쪽이 plausible 비중이 다소 높게 나타나는 경향은 있으나 엄밀한 두 라운드 개별 pass rate로 단정하지 않는다.

**정직한 결론**: r2가 세 라운드 중 가장 신뢰할 만했다(94.4%, 특히 H-tier는 100%). r3는 M-series 기준 83.8%로 중간이며, duplicate 누락(08-26 문서 미대조)이 주된 감점 요인이다. r4는 독립적으로 분리된 pass rate를 소스가 제공하지 않아 정량 비교는 유보하지만, 정성적으로는(git log -S 출생시점 검증을 광범위하게 동원한 점, refuted 0건, duplicate 1건뿐) r3보다 방법론이 견고해 보인다 — 다만 이는 추정이지 확정된 수치는 아니다.

---

## 6. 수정 권고 순서 (confirmed만, 영향 × 비용)

실동작(런타임 사용자 경험)에 영향이 있고 수정 비용이 상대적으로 낮은 것부터, confirmed 등급 위주로 정리했다. plausible은 제외했다.

| 순위 | ID | 영향 | 수정 비용(추정) |
|---:|---|---|---|
| 1 | `r2-H9` | CI 존재게이트가 스킵을 통과로 오분류 — 테스트 인프라 신뢰성 전체가 걸림 | 낮음 (정규식에 상태 캡처 추가) |
| 2 | `r2-4.5-assertion0` | 영구 스킵 테스트 2건이 '전수' 게이트 신뢰를 깨뜨림 | 낮음 (CI env 배선 또는 skip 사유 명시) |
| 3 | `r2-H4` / `r2-H5` | parallax 기본값이 '무이동'이 아니라 '최대 편향' — cameraparallax:false 씬 전체가 영향받음 | 낮음 (기본값을 (0.5,0.5)로 정정) |
| 4 | `r2-H16` | 순수 키보드 사용자가 인스펙터에 영구 도달 불가(접근성) | 중간 (Tab 포커스 경로에 focusedId 배선) |
| 5 | `r3-M37` | 성공 메시지가 항상 빨강으로 표시됨(사용자 오인) | 낮음 (색상 role 분기 추가) |
| 6 | `r2-H8` | F820 음량/배속이 WebRenderer(videoFallback) 경로에서 무효 | 중간~높음 (WebRenderer에 라이브 갱신 훅 추가) |
| 7 | `r4-16` | VideoRenderer 가림 절전 게이트가 rate!=0 가드로 뚫림 | 낮음 (별도 상태 플래그로 전환, 형제 WebRenderer 패턴 재사용) |
| 8 | `r2-H3` | 부화면 재생목록 전진이 스테일 선택으로 매초 후보 소진, 통지 0 | 중간 (실패 경로에 알림 추가 + 후보 재계산 로직 수정) |
| 9 | `r3-M13` | 비디오 회전/미러 조합표 두 행이 180° 반대(렌더링 오류) | 낮음 (해당 두 행 스왑) |
| 10 | `r2-H6` | orthographicScene 게이트 비대칭 — 정적 레이어 영구 unhittable | 중간 (encodeLayer 승격 로직에 orthographicScene 검사 추가) |
| 11 | `r3-M24` | 폴더 선택시 태그/나이등급 필터가 무필터로 붕괴 | 중간 (allTags/allRatings을 전체 entries 기준으로 유도) |
| 12 | `r2-C1` | 파티클 자식 CP 피드 이중가산(시각 결함) | 중간 (평행이동 중복 경로 하나 제거, 회귀 테스트 필요) |
| 13 | `r2-H1` | WE 대비 반대 컬럼 사용 — 3D 씬 라이트 방향 오류 | 중간 (col0/col2 수정 + 골든 스냅샷 재검증) |
| 14 | `r3-M64` | 일시적 마운트 실패로 태그가 영구 소실(데이터 손실) | 중간 (재시도 조건을 nil-or-empty로 완화) |
| 15 | `r2-H19` | 압축폭탄/디스크 여유공간 무방비(보안/안정성) | 중간~높음 (사전 용량 검사 추가) |
| 16 | `r2-H14` | SnapshotCompare 빈 베이스라인에서 90% 하한이 무력화(게이트 자체 결함) | 낮음 (entries 빈 경우를 명시적 오류로 처리) |
| 17 | `r2-H12`/`r2-H13` | 스냅샷 셀프체크가 잘못된 축(프로세스간) 수리 + helper 실패시 조용한 강등 | 중간 (세션간 축으로 재설계) |
| 18 | `r2-H20` | 손상 데이터 백업이 사용자에게 전혀 노출되지 않음 | 중간 (복구 UI 또는 최소 알림 추가) |
| 19 | `r2-H18` | codesign --deep이 중첩 saver 서명을 덮어씀(배포 리스크) | 낮음 (--deep 제거, 개별 서명으로 전환) |
| 20 | `r2-H11` | NOTICE 라이선스 목록 누락(법적 리스크) | 낮음 (누락 폰트 1건 추가) |

이 아래로는 문서/주석 드리프트(§1.3의 상당수), 테스트 자체의 구조적 결함(단언이 실제로 아무것도 안 잠그는 부류: `r3-M45`, `r3-M46`, `r3-M68`, `r2-H10`), 스크립트 게이트 결함(`r3-M29/M47/M48`)이 이어진다 — 실동작에는 즉시 영향이 없으나 회귀를 조용히 통과시키는 부류라 우선순위는 낮지만 방치 비용이 누적된다.

---

## 7. 검증의 한계

- **배정량이 컸다**: 검증기 1개당 최대 72건(검증기 E). 이 배정은 필연적으로 얕아졌다 — r3-O1/O9/O12/O25, r4-38이 모두 이 배정에서 plausible로 남았고, 사유는 "원본 데이터/디스어셈블/git archive 재현을 세션 예산 안에서 완결하지 못함"이었다.
- **명시적으로 얕게 처리된 항목**:
  - `r2-H7`(파티클 낡은 선분 재적용): 기전은 코드로 확정했으나 ~280px/s 수치 시뮬레이션은 재현하지 않음.
  - `r2-H2`(PuppetModel MDLA flags): 도달 모집단(워크샵 코퍼스) 자체가 이 머신에 없어 실물 도달 여부 미측정.
  - `r3-M6`(19자리 인용 중 14 무효): 1개 표본만 재현, 전건 도수는 미확인.
  - `r3-M19`(NSMenu 자동활성화로 트레이 가드 무효화): 정적 코드로는 검증 불가한 AppKit 런타임 동작 — 실기 미확인.
  - `r3-M30`(verify-plan-b12.sh 툴체인 의존): 게이트 존재는 확인했으나 "툴체인 의존"이라는 원인 프레이밍 자체는 미검증(grep 게이트는 사실 결정적일 수 있음).
  - `r3-M54`/`r3-M57`/`r3-M59`: 전수 재계산이 필요한 인용 드리프트(각 131/8/4자리) — 표본 1~2개만 확인, 전체 도수는 미검증.
  - `r3-O12`(AudioResponse smoothstep): capstone 디스어셈블이 필요했으나 함수 선두 정렬 재현을 이 세션에서 완결하지 못함.
  - `r3-O9`(경로 깊이 6 vs 7): 원본 생성 산출물(tsv)에 접근하지 못해 독립 재현 불가.
  - `r4-38`(Badges.swift '42건 중 40건'): git archive로 작성시점 트리를 열어 42의 출처를 확인하는 절차를 생략.
  - `r3-O25`(82파일 416자리 자기참조 인용): 모집단 규모 자체를 재계수하지 못함 — 다만 `r4-30`·`r4-39`가 같은 모집단 내 표본 10건을 독립 검증해 모집단의 실재성은 뒷받침됨.
- **문서 간 중복 제거가 전수는 아니다**(§2 끝의 한계 문단 참조) — 185건에 대한 체계적 페어와이즈 검사는 수행하지 않았다.
- **빌드/테스트 미실행**: 브리핑 지시대로 `swift build`/`swift test`를 전혀 돌리지 않았다 — 모든 검증은 정적 코드 읽기, grep, git log -S, capstone 디스어셈블, python3 JSON/헤더 파싱으로만 이루어졌다. 런타임 전용 결함(AppKit 자동활성화, GUI 상호작용 등)은 원천적으로 이 방법론의 사각지대다.
- **모집단 표기 규율**: 이 문서에 등장하는 구체 도수는 전부 위 항목 원문에 이미 있던 것만 인용했다. 모집단이 불명확한 것(예: `r2-4.4-fboaudio`의 '형제 18개'가 근사치임)은 원문 그대로 "근사"로 남겼다.