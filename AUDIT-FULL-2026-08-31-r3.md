# 전체 감사 라운드 3 — 적대적 검증 (2026-08-31, Waple + Waple-wallpaper-source)

> **지시**: 두 리포 전체 확인 · **수정 금지 — 발견만 기록**
> **대상 트리**: Waple `b883386e`(main, 작업 트리 깨끗) · RE 저장소 `1fac2a0c` + **미커밋 14파일**
> **모드**: 워크플로 **37에이전트 · 4라운드** — 라운드 1(서브시스템 14레인) + 라운드 2(횡단 렌즈 14레인)
> → 중복 제거 **118건** → 라운드 3(적대적 검증기 8개) 판정 → 종합 1.
> **이 문서만 새로 추가됐다** — 이 라운드는 두 리포의 기존 파일을 한 줄도 고치지 않았다.
> **선행**: `AUDIT-FULL-2026-08-31.md`(라운드 1 감사, 3,571줄) · `AUDIT-FULL-2026-08-31-r2.md`(라운드 2 감사, 289줄) + `docs/audit-r2-lanes/` 16레인 원문.

## 0. 이 문서의 성격

직전 두 감사는 **찾는 일**을 했다. 이 라운드는 **거르는 일**을 했다.

28개 레인이 낸 것을 중복 제거해 118건으로 접은 뒤, **그 118건을 검증하는 것만이 임무인 에이전트 8개**에
넘겼다. 검증기는 각 발견의 좌표·재현·영향·기지 대조를 처음부터 다시 밟고 `confirmed` / `plausible` /
`duplicate` / `refuted` 중 하나를 냈다.

| 판정 | 건수 | 이 문서에서 |
| --- | --- | --- |
| `confirmed` | 95 | §2 색인 |
| `plausible`(기전 확정 · 도달 미확인) | 7 | §2 색인, `~` 표시 |
| `duplicate`(기지 발견) | 5 | §4.1 기각 표 |
| `refuted`(핵심 주장이 거짓) | 3 | §4.1 기각 표 |
| **미판정**(검증기가 판정에 도달하지 못함) | 8 | §4.3 — **확정으로 승격하지 않는다** |
| 합계 | **118** | |

통과율 86.4%(102/118)는 라운드 1·2 의 정확도를 말해 주는 수치가 아니다. 8건 중 5건이
**"기지 대조 0건" 이라고 스스로 적어 놓고 실제로는 기지**였고, 3건은 "작성 시점부터 틀렸다" 는
신규성 주장이 `git log -S` 한 번에 무너졌다. 두 유형 모두 **한 단계 더 판 것만으로** 갈렸다.
그래서 §4 의 기각 표가 이 문서에서 가장 오래 쓰일 부분이다 — 다음 감사가 같은 자리를 다시 파지 않게 한다.

## 1. 기반 실측

라운드 1·2 오케스트레이터가 잰 값을 그대로 인용한다. **이 라운드는 빌드·테스트를 돌리지 않았다**(§6).

| 항목 | 값 |
| --- | --- |
| Xcode / Swift | 27.0 Beta 5 / **6.4** |
| 실물 워크샵 코퍼스 | **없다** — 도달 도수는 전부 동봉 코퍼스 또는 설치본 기준 |
| `swift test` | 실패 **0** · 스킵 **63** · 실행 **4,016**(7번들 26+1221+74+54+2135+30+476) |
| 정적 개수(정본 레시피) | **4,016** = `ci.yml` 하한(**여유 0**) |
| Waple | HEAD `b883386e`, 작업 트리 깨끗 |
| RE 저장소 | HEAD `1fac2a0c` + **미커밋 14파일** |

> **모집단 규약.** 이 문서의 모든 도수는 세 모집단 중 하나를 명시한다 —
> **설치본**(`Waple-wallpaper-source/wallpaper_engine`, project.json 191 / .mdl 28 / .tex 440) ·
> **동봉 코퍼스**(`Sources/WapleRender/Resources/WEAssets`, project.json 170 · scene.json 171~172 ·
> json 1,698 · 셰이더 502) · **워크샵 코퍼스**(446 폴더 / 460 pkg — **이 머신에 없다**).
> 모집단이 없는 도수는 쓰지 않았다.

## 2. 발견 색인 — 검증 통과 102건

`~` 는 `plausible`(기전은 확정, 도달·도수 미확인)이다. 나머지 95건은 `confirmed`.

### 🔴 critical (1)

| id | 자리 | 요지 |
| --- | --- | --- |
| **C1** | `Sources/WapleRender/VideoTextureExtractor.swift:24` | `project.json` 의 `workshopid` 가 살균 없이 mp4 캐시 **파일 경로**가 된다 — 씬 하나로 캐시 밖 임의 경로에 쓰기·삭제. 형제 3자리는 같은 값을 전부 살균한다 |

### 🟠 high (5)

| id | 자리 | 요지 |
| --- | --- | --- |
| **H1** | `Sources/WapleRender/SceneAudioPlayer.swift:17` | F820 라이브 음량 경로가 씬 오디오를 빠뜨렸다 — 라이브 반영이 `as? VideoRenderer` 로만 좁혀져 있고 `settingVolume` 이 `let` |
| **H2** | `Sources/Waple/Shell/NowPlayingBar.swift:57` | 씬 음량 메뉴가 체크마크만 옮기고 실제 음량은 안 바꾼다 — 그 메뉴를 씬에 연 커밋이 리마운트 제거(F820)보다 **25일 뒤**라 처음부터 죽은 채 태어났다 |
| **H3** | `scripts/mac-session/rebaseline-golden.sh:64` | 골든 기준선 **설치 게이트**가 id 교집합만 대조 — 2차 캡처가 전건 실패해도 "상이 0종" 초록, 그대로 설치 |
| **H4** | `Sources/WapleRender/SceneRenderer.swift:1855` | 유저 속성 오버라이드는 `entry.id` 로 쓰고 렌더러는 `project.id` 로 읽는다 — 사용자 편집이 조용히 무효가 되고 다른 배경의 값이 대신 적용 |
| **H5** | `Sources/WapleRender/TextScriptEngine.swift:338` | 7번째 영속 저장소 `ScriptLocalStorage` 만 3분기 로드 규약 미준수 — 손상 파일이 백업 없이 `{}` 로 덮이고, `set()` 없이 마운트만 해도 전량 소실 |

### 🟡 medium (68)

| id | 자리 | 요지 |
| --- | --- | --- |
| M1 | `WapleCore/PropertyAnimation.swift:419` | `firedMarkers` 만 mode 를 대소문자 구분 비교 + 미지 모드를 clamp 로 — 같은 모듈 두 해석기와 어긋남 |
| M2 | `WapleCore/Model3D.swift:87` | "모든 .mdl 은 말미 단일 NUL(418/418)" 전칭이 같은 파일 :814-816·정본(EOF 8)에 반박됨 |
| M3 | `spec/formats/mdl-deep.json:565` | `indexWidth` 가 가리키는 `Model3D.swift:577` 은 빈 줄(실제 762) — `value` 안이라 evidence 게이트 밖 |
| M4 | `WapleCore/Model3D.swift:201` | 메시별 `materials` 에 **파일별** 분포 {1:450, 2:1} 을 모집단 표기 없이 부착(메시 모집단 986) |
| M5 | `WapleCore/ParticleSystem.swift:3476` | `mapSeqClampCP` 이 32비트로 판정하고 절단 안 한 원값 반환 — 08-26 감사가 실패 입력을 반대로 지목한 자리 |
| M6 | `WapleCore/ParticleSimulator.swift:553` | 담당 2파일의 주석 줄번호 인용 19자리 중 **신규 14자리 전건 무효** |
| M7 | `WapleCore/GLSLTranslator.swift:2134` | 헬퍼 캡처 파라미터 타입 사다리가 라이트 심볼군을 `float` 로 선언 — 호출부는 `float3`/`float4x4` 를 넘긴다 |
| M8 | `WapleCore/GLSLTypeAdapter.swift:568` | WE shim 인용 2건이 ±1 밀려 다른 매크로 — 같은 두 매크로를 `GLSLTranslator` 는 옳게 인용(자기모순) |
| M9 | `WapleCore/ScenePBRLighting.swift:301` | `generic3.frag:132/152` 가 루프 헤더·델타 대입문을 가리킴(실제 135/153) |
| M10 | `WapleCore/AudioResponse.swift:108` | "동봉 2건" 이 동봉 코퍼스에 0건 — 실제 도달은 설치본 3줄/2파일 |
| M11 | `WapleCore/AudioSpectrum.swift:40` | 48 kHz 밴드경계 이동값을 44.1 kHz 격자로 재 정성 결론이 뒤집힘(0.92빈 → 1.071빈) |
| M12 | `WapleRender/SceneRendererFrameEncoder.swift:399` | 이 파일군 도수 6자리가 모집단 미표기 · `:399` 의 "코퍼스 13씬" 은 동봉일 수 없음을 실측 반증 |
| M13 | `WapleRender/SceneVideoLayer.swift:32` | 트랙 방향 분류표가 미러+90/270 두 행에서 구현과 반대 순서 — 라이브가 헤드리스 대비 180° |
| M14 | `WapleRender/VideoFallbackHTML.swift:6` | `.videoFallback` 경로는 배속을 **한 번도** 적용하지 않는다(음량 축과 수정 범위가 다르다) |
| M15 | `WapleRender/FFmpegConverter.swift:175` | 실제 벽시계 상한은 timeout **2배 + 10초**(약 610초) — 선행 감사의 "최대 300초" 는 절반 |
| M16 | `scripts/spec/measure_script_api.py:1340` | 정본 `waple.coverage.WEColor`(확정)가 이미 닫힌 갭을 열린 것으로 — 생성기 하드코딩이라 재생성 무효 |
| M17 | `WapleRender/SceneAudioPlayer.swift:9` | 사운드 코퍼스 계수가 정본과 충돌하고 모집단명 "코퍼스 460종" 이 정본에 정의 없음 |
| M18 | `Waple/AppDelegate.swift:1830` | 주석의 파일:줄 인용 12자리 무효, 그중 11자리는 PR #8 부모에서 정확했다 — lane08 "드리프트 0" 판정 반증 |
| M19~ | `Waple/AppDelegate.swift:1894` | 트레이 "다음 배경" 비활성 가드가 no-op(NSMenu 자동 활성화) — 실기 확인 못 함 |
| M20 | `Waple/ScreenSaverController.swift:28` | 화면보호기 `videoPath` 만 `WallpaperPathSecurity` 봉쇄를 건너뜀 — 패키지 안 심링크로 패키지 밖 파일 재생 |
| M21 | `Waple/Shell/NowPlayingBar.swift:288` | 멀티모니터에서 씬의 음량 메뉴가 **다른 화면 동영상**의 음량을 바꾼다(노출 판정과 대상 선택의 소스가 다름) |
| M22 | `Waple/DesignSystem/Metrics.swift:71` | 설정 창 주석이 이미 고쳐진 결함을 현재형으로 적고, 근거로 든 전제 둘이 둘 다 거짓 |
| M23 | `Waple/Surfaces/Settings/SettingsView.swift:150` | 표시 라벨 중복의 근거 두 개가 모두 스테일(스캔 루트 · SettingsPresentation 미번역) |
| M24 | `Waple/LibraryFiltering.swift:47` | 폴더를 고르면 태그·나이등급 필터가 조용히 **무필터**로 무너진다(주석의 전제가 그 경로에서 거짓) |
| M25 | `Waple/DesignSystem/Metrics.swift:19` | 자기 실측 3개가 스테일이고 '공유 토큰' 예시 두 상수는 코드 참조 0 |
| M26 | `Waple/WallpaperGridView.swift:183` | 그리드 타일의 유형 배지가 보조기술에 전달되지 않음 — 형제 타일은 같은 기전을 알고 다시 엮는다 |
| M27 | `scripts/spec/measure_nondeterminism.py:263` | `nondeterminism.json` 확정 항목 둘의 근거 6자리가 전부 무관 코드 · 생성기 하드코딩 · 범위 안 드리프트는 게이트 사각 |
| M28 | `Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift:181` | F840(`CGContext(data: &px)` UB) 스윕이 Tests 5자리를 놓쳤고 하나가 골든 GT 픽셀 오라클의 luma 산출부 |
| M29 | `scripts/spec/check_int_narrowing.py:42` | selftest·모집단 하한 둘 다 없음 — 정규식이 죽으면 "0건" 으로 초록, spec.yml 이 근거로 든 음성 대조는 파일에 없다 |
| M30 | `scripts/mac-session/verify-plan-b12.sh:145` | §5 무회귀 게이트가 번들 수 == testTarget 수를 요구 — 기지 C1 의 툴체인 의존이 ci.yml 밖에 잔존 |
| M31 | `scripts/mac-session/verify-plan-b12.sh:155` | 기준값 2,300 을 찍는다 — AGENTS.md 가 인용을 명시 금지한 숫자(현재 4,016) |
| M32 | `scripts/ab-deviations/01-check-env.sh:7` | 존재하지 않는 브랜치를 요구해 항상 exit 1 — A/B 하네스 전체가 문서대로는 기동 불가 |
| M33 | `scripts/dev/linux-render-typecheck.sh:231` | 공유 락 설명 세 주장이 같은 파일 :90-96 과 형제 스크립트에 전건 반박됨 |
| M34 | `scripts/dev/linux-render-typecheck.sh:56` | 하네스·spec.yml 규모 인용이 전부 낡음 — 심 종수는 spec.yml 안에서 15 와 17 로 갈리고 실측 24 |
| M35 | `WapleRender/WallpaperSchemeHandler.swift:224` | 보안 주석이 "형제 규약(`.isSymbolicLinkKey` 동반)에 맞췄다" 는데 다음 줄이 그 키를 요청하지 않는다 |
| M36~ | `WapleRender/BaseAssetsSettings.swift:8` | **[R1반박]** 이 타입만 UserDefaults 주입 시임 없음 — lane12 §7 의 면제 근거("별도 프로세스")가 `.standard` 에 거짓 |
| M37 | `Waple/AppDelegate.swift:1578` | notify 미러가 **성공 메시지를 빨강**으로 그린다 — "사실상 실패 채널" 전제가 호출부 다수에서 거짓 |
| M38~ | `WapleRender/WebRenderer.swift:380` | 세 렌더러 중 WebRenderer 만 WebKit 실패 델리게이트 0건 — 로그도 통지도 복구도 없다 |
| M39 | `WapleRender/SceneRenderer3D.swift:2090` | **[R1반박]** lane06 의 "`cameraFrame.fov` 소비자 둘뿐" 이 거짓 — 세 번째(볼류메트릭)가 클램프를 건너뛴다 |
| M40 | `spec/engine/hdr-bloom.json:125` | 확정 항목의 "코퍼스 140/161" 이 같은 엔트리 실측 필드(169 / 146)와 모순 · 생성기 하드코딩 |
| M41 | `WapleCore/ParticleSimulator.swift:524` | 파티클 시계가 `Float` 누적 — 0.76일 −6.25%, 3.03일 +87.5%, 6.07일 정지(씬 시계는 매 프레임 재계산) |
| M42 | `Tests/WapleCoreTests/ParticleSceneFixRegressionTests.swift:61` | `testF620_SpeedMinOnlyIsFixedSpeed` 가 이름의 분기를 한 번도 안 탄다 · 인용 증인은 거울상 |
| M43 | `Tests/WapleRenderTests/MediaFixRegressionTests.swift:478` | "디헤드럴 8원소" 를 자칭하며 5행만 단언 — 어긋난 2행이 미단언 3행 안 · 라이브 대조 2건은 3초 벽시계로 스킵 |
| M44 | `.github/workflows/ci.yml:320` | 병렬 격리 게이트가 클래스당 `--filter` 라 자기가 인증하는 교차-클래스 경합을 원리적으로 못 본다 |
| M45 | `Tests/WapleCoreTests/SceneGeneralDefaultsWEParityTests.swift:66` | Swift 리터럴의 IEEE-754 성질만 단언하면서 "생성자가 기록하는 값" 을 잠근다고 적음(민감도 0) |
| M46 | `Tests/WapleRenderTests/SyntheticPixelGoldenTests.swift:193` | 합성 픽셀 골든이 케이스 목록 **축소**를 어느 단계에서도 못 잡는다(형제 오라클은 개수를 잠근다) |
| M47 | `scripts/spec/check_js_shim_baseclasses.py:147` | node 가 없으면 rc=0 으로 조용히 종료 — spec.yml 은 node 를 설치하지도 고정하지도 않는다 |
| M48 | `scripts/spec/check_particle_corpus_census.py:67` | **[R1반박]** 이쪽도 selftest·하한 둘 다 없음 — M29 의 "19게이트 중 유일하게" 전칭이 반증됨 |
| M49 | `.github/workflows/spec.yml:471` | "형제 게이트는 전부 하한을 둔다 … 마지막 자리였다" 가 거짓(0 모집단 초록 반례 확인 2건) |
| M50 | `BACKLOG.md:647` | 존재하지 않는 `baseline-f3a17da` 를 현행 골든 기준선으로 현재형 서술(현행은 `baseline-6f0bcf0`) |
| M51 | `spec/README.md:19` | AGENTS.md 가 "정본" 으로 지목한 자리가 기지 L14-2 와 똑같은 거짓 — AGENTS 만 고치면 정본이 거짓으로 남는다 |
| M52 | `docs/RELEASING.md:176` | `release.yml:187-190` 인용이 106줄 밀림 — 프리릴리즈 사고 경고의 근거 좌표이고 `docs/re/**` 면책 밖 |
| M53 | `spec/golden/snapshot/README.md:179` | 교란② 근거 인용 두 건이 드리프트 — "직접 읽어 확인했다" 고 적은 자리가 지금은 무관 코드 |
| M54 | `WapleCore/WallpaperCompatibilityAnalyzer.swift:548` | 소스 주석의 `파일.swift:줄` 인용 **131자리 중 77 무효**(58.8%), 그중 66자리 신규 · 20자리는 PR #8 자기 hunk 소산 |
| M55 | `WapleCore/ShaderPreprocessor.swift:515` | 세 자리가 독립적으로 `PropertyConditionEvaluator.swift:12` 를 판례로 인용 — 실제 :148·:152, 세 리비전 전부 불일치 |
| M56 | `WapleRender/SceneRendererResources.swift:1382` | `.tex` flags 규약 인용 3자리가 전부 `TexImage.swift:111`/`:126` — 그 두 줄은 VariantCondition 파서 |
| M57 | `spec/engine/deviations.json:14` | 정본의 Waple-측 코드 좌표 8자리 전건 무효(WE 원문 좌표는 전건 정확 — 비대칭) |
| M58 | `spec/engine/render-state.json:955` | 확정 항목이 "Waple 이 같은 VA 를 인용한다" 며 **다른 VA 를 적은 줄**을 가리킨다 |
| M59 | `spec/engine/linked-libraries.json:1210` | 생성기 하드코딩 소좌표 드리프트 4자리(linked-libraries · misc-schema · tex-deep · workshop-shaders) |
| M60 | `spec/engine/deviations.json:88` | 정본 두 파일이 WE 블렌드 이탈 목록에서 갈린다 — 모드 17 누락 · 모드 12 sqrt 가드는 항목 자체가 없음 |
| M61 | `WapleRender/EffectShaders.swift:136` | 손포팅 shake 진폭 기본 0.006 vs WE 선언 0.1(WE range 하한 0.01 미만) — 제곱 도입 때 재튜닝 누락, 배율 277.8배 |
| M62 | `WapleCore/SceneDocument.swift:98` | 실물 `lib.sceneScript.d.ts` 인용 4자리가 선언이 아니라 `*/`·`}` 를 가리킴(이웃 인용은 정확 = 버전 드리프트 아님) |
| M63 | `Waple-wallpaper-source/scripts/DecompileAll.java:97` | `xref-index.tsv` 의 `imported_apis` 66행 중 21행이 부분문자열 오탐 — 산문이 rtti_classes 대체로 권한 열 |
| M64 | `WapleLibrary/LibraryStore.swift:393` | `backfillMetadataIfNeeded` 가 **일시적** 북마크 해석 실패를 영구 마킹 — 태그·나이등급이 영영 빈 값 |
| M65 | `Waple/LibraryViewModel.swift:253` | 라이브러리 제거가 5개 스토어만 정리 — id 로 키를 잡는 UserDefaults 2종·script-storage 파일 잔존 |
| M66 | `BACKLOG.md:469` | PR #8 이 "접근성 해소" 로 닫은 근거 셋 중 둘이 **작성 시점에 이미 거짓**(하나는 17분 차) |
| M67 | `Waple/SelectionPanelView.swift:95` | GIF 프리뷰 3자리가 reduceMotion 을 한 번도 묻지 않는다 — 인스펙터 히어로는 상시 루프 |
| M68 | `Tests/WapleRenderTests/SceneRenderSettingsTests.swift:68` | "설정 창 Picker 가 그대로 쓰는 라벨" 이 실제로는 아무도 안 쓰는 미현지화 한국어 2개를 고정 |

### ⚪ observation (28)

| id | 자리 | 요지 |
| --- | --- | --- |
| O1~ | `WapleCore/WallpaperProperties.swift:73` | "워크샵 타입 상한 10" 주장과 짝 저장소 census(text 887 · label 6)의 모순 — 어느 쪽이 거짓인지 **미확정** |
| O2 | `WapleCore/CameraMotion.swift:320` | `effectivePathDuration` 이 갈리는 입력이 있고 잠금 테스트 3케이스가 전부 우연히 맞는 값 |
| O3 | `docs/audit-r2-lanes/lane05-render-core.md:208` | **[R1반박]** "세마포어 불균형 0건" 의 재현 grep 이 같은 트리에서 8행(문서 2행) — 결론은 유지, **근거만** 반증 |
| O4~ | `WapleCompatCore/SnapshotPipeline.swift:217` | 골든 캡처 셀프체크 helper 대기가 무상한(`Process()` 7자리 중 3자리 상한 0) |
| O5 | `WapleCore/PropertyAnimation.swift:680` | `options.events` 를 배열 통째로 캐스트 — 원소 하나가 비객체면 마커 전량 소멸(주석은 "항목만 드롭") |
| O6 | `WapleCore/SceneDocument.swift:3116` | 파티클/모델/스프라이트가 변환맵에 없어, 가시 파티클을 부모로 둔 자식이 로컬 좌표로 남는다 |
| O7 | `WapleCore/WallpaperProperties.swift:285` | localization 폴백이 `Dictionary.keys.first(where:)` — 같은 언어 지역표가 둘 이상이면 실행마다 다른 표 |
| O8 | `WapleCore/Model3DPose.swift:129` | 주석 한복판에 U+FFFD 대체문자(리포 전체 유일 1건) |
| O9 | `docs/re/package-format.md:141` | "최대 경로 깊이 6 성분" 이 실측(성분 7 · 6성분 0건)과 불일치 — 슬래시 기준으로만 6 |
| O10 | `WapleCore/ParticleSimulator.swift:1856` | `oscPositionOffset` 설명 doc 주석이 `applyBoids` 헤더로 붙어 있다(빈 줄 부재) |
| O11 | `WapleCore/EffectManifest.swift:541` | `bind`/`fbos` 배열 캐스트가 원소 하나로 전체 nil — 같은 파일이 `passes` 에 대해서만 고쳐 뒀다 |
| O12 | `WapleCore/AudioResponse.swift:252` | `smoothstep` 의 `max(1e-6, ·)` 가드가 실물 CPU 경로의 raw divss 와 역전 bounds 에서 갈림 |
| O13~ | `WapleRender/FFmpegConverter.swift:124` | 5초 프로브 타임아웃이 **유효한 변환 캐시를 삭제**하고 재인코딩 — 주석은 "재사용 불가" 까지만 |
| O14~ | `WapleRender/SceneVideoLayer.swift:185` | 루프 옵저버가 정지 상태를 안 본다(형제 렌더러 둘은 정지 플래그 보유) |
| O15 | `WapleRender/NowPlayingProvider.swift:65` | 주석의 "1000 초과 & Spotify" 조건이 코드에 없고 이력상 존재한 적도 없다 |
| O16 | `Waple/Surfaces/Displays/DisplaysView.swift:78` | 스냅샷 화면 목록과 라이브 `NSScreen.screens` 를 다시 **위치**로 짝짓는다(F840 이 지목한 부류 잔존) |
| O17 | `WapleCompatCore/SnapshotCompare.swift:142` | 렌더→무픽셀 대량 회귀를 회귀(1)가 아니라 "코퍼스 대량 누락" 환경 오류(2)로 오진단(메시지는 skip=0) |
| O18 | `scripts/spec/measure_decompilation_provenance.py:67` | `docs/` 에 새 주소 인용이 들어오면 census 게이트가 붉어지고 복구 경로가 CI 에서 실행 불가 — **지금 rc=1** |
| O19 | `scripts/dev/tests/test_workflow_contracts.py:145` | `-gt 25` 를 리터럴로 못 박아 ci.yml 이 지시하는 "상한을 함께 낮춰라" 를 스스로 막는다 |
| O20 | `WapleRender/BaseAssetsSettings.swift:17` | 게터/세터가 서로 역이 아니라, 다섯 자리의 save/restore 가 '자동 탐지' 를 명시 핀으로 승격 |
| O21 | `WapleRender/SceneVideoLayer.swift:202` | 회전 트랙 라이브 경로가 프레임마다 전량 재할당(identity 경로는 제로카피 + 3링) |
| O22 | `WapleRender/WallpaperSchemeHandler.swift:112` | 384줄 전체에 로그 0건 — 웹 배경의 404·경로 봉쇄 거부가 완전 무음 |
| O23 | `WapleRender/Scene3DMath.swift:42` | `perspective` 가 `nearz`/`farz` 를 한 줄도 검증하지 않음(형제 소비자는 명시 가드) |
| O24 | `BACKLOG.md:448` | 소스 링크 5건이 `path:N` 형식이라 렌더된 문서에서 404(같은 파일 2건은 `#LN` 로 옳게 적는다) |
| O25 | `WapleCore/SceneDocument.swift:164` | 파일명 없는 자기참조 `:N` 인용이 **82파일 416자리** — 표본 1건 무효 확인, **나머지 414 미검증** |
| O26 | `Waple-wallpaper-source/scripts/ghidra_decompile.py:115` | 생성기 3개가 같은 `manifest.json` 을 서로 다른 스키마로 덮어쓰는데 정본 표시가 없다 |
| O27 | `Waple/WallpaperGridView.swift:285` | 장식 썸네일 차폐 규약이 그리드 타일 gif 분기 한 자리에서만 빠짐(형제 3자리는 전부 감춘다) |
| O28 | `Waple/Shell/StatusBanner.swift:74` | 사용자 통지 24자리가 4초 자동 소멸 배너뿐이고 보조기술 알림 API 호출이 리포 전체 0건 |

### 계통 분류

색인 102건을 겹치지 않게 나눈 것이다(분류는 이 문서의 것이고, 소속 id 를 밝혀 검산할 수 있게 뒀다).

| 계통 | 건수 | 소속 |
| --- | --- | --- |
| **좌표 인용 무효** — 근거를 따라가면 다른 코드 | **16** | M3 M6 M8 M9 M18 M27 M52 M53 M54 M55 M56 M57 M58 M59 M62 O25 |
| **오라클·게이트가 잠그는 것이 없다 / 거짓 초록** | **15** | H3 M28 M29 M30 M42 M43 M44 M45 M46 M47 M48 M49 O17 O18 O19 |
| **도수·모집단 표기 결함** | **11** | M2 M4 M10 M11 M12 M17 M31 M34 M40 M63 O9 |
| **정본·주석이 사실과 다름**(좌표 아님) | **10** | M16 M22 M23 M33 M50 M51 M60 M66 M68 O15 |
| 실동작·잠복 결함, 개별 관찰 | **50** | 나머지 |

첫 두 계통이 31건으로 전체의 30%다. 이 리포의 결함은 **코드가 틀린 것보다 근거가 끊긴 것**이 많고,
그것은 이 리포가 주석·정본으로 논증하는 방식을 택했기 때문에 생기는 고유 부채다.

## 3. 심각도 상세

### 3.1 🔴 C1 — 살균되지 않은 `workshopid` 가 파일 경로가 된다

- **자리**: `Sources/WapleRender/VideoTextureExtractor.swift:24`
  (사슬: `WapleCore/ProjectJSONParser.swift:33` → `WapleRender/SceneRenderer.swift:2085`
  → `WapleRender/SceneRendererResources.swift:277` → 위 자리)
- **재현**: 사슬 4단을 전건 열었다.
  `ProjectJSONParser.swift:33 let id = workshopId ?? folderURL.lastPathComponent` 이고
  그 `workshopId` 는 `parseStringOrNumber`(:294)의 **원문**이다 — 공백뿐인 문자열만 nil 로 접고
  살균은 0. 그 값이 `sceneID: project.id`(SceneRenderer:2085) → `cacheKey: "\(sceneID)_\(index)"`
  (Resources:277) → `cacheDir.appendingPathComponent("\(cacheKey ?? sceneID).mp4")` 로 흐르고,
  그 URL 로 `:39 try? fm.removeItem(at: url)` · `:49 try mp4.write(to: url, options: [.atomic])` ·
  `:50` 사이드카 쓰기가 돈다.
  `appendingPathComponent` 가 `/`·`..` 를 통과시킨다는 것은 **이 리포 자신의 테스트**가 증명한다 —
  `Tests/WapleAppTests/SteamCmdDownloaderTests.swift:76-78` 의 기대값에 `steamapps/workshop/content/431960/999`
  가 슬래시째로 들어간다. 같은 사실을 `WorkshopAPI.swift:79-84`("같은 문자열이 … `../` 탈출이 된다")와
  `WallpaperPathSecurity.swift:63`(그래서 `..` 를 먼저 거부한다)이 명시한다.
- **비대칭이 결정적이다.** 같은 `project.id` 를 형제 3자리는 전부 살균한다 —
  `Waple/StillWallpaper.swift:43`(`safeName`, 영숫자만) · `WapleRender/TextScriptEngine.swift:334` ·
  `WapleLibrary/LibraryStore.swift:258`(`normalizedPathComponent`). `VideoTextureExtractor` 의
  `WallpaperPathSecurity|safeName|isLetter` 히트는 **0**. 더 좁히면 같은 파일 안에서 갈린다 —
  `SceneRendererResources.swift:215`·`:262` 는 패키지 엔트리 이름을 `normalizedRelativePath` 로
  살균하는데 62줄 아래 `:277` 은 살균되지 않은 `project.id` 를 파일 경로로 만든다.
- **영향**: 악성 씬 패키지 하나(`{"workshopid":"../../../../<dir>/x", "type":"scene"}` + video `.tex` 레이어)를
  임포트해 적용하면 캐시 밖 임의 **기존** 디렉터리에 공격자 바이트를 `<이름>_<N>.mp4` 로 쓰고,
  같은 경로에 파일이 있으면 먼저 지운다(데이터 손실). 앱에 App Sandbox 엔타이틀먼트가 없어
  (`scripts/package-app.sh:48-69` 는 Info.plist 만 쓰고 리포에 `*.entitlements` 0건) 사용자 권한 전체가
  사정거리다. 도달 경로 셋 — 라이브 마운트 · 스틸 생성(`AppDelegate.captureSceneStill`) ·
  `WapleCompat --capture`(`SnapshotPipeline:325-326`). **제약**은 대상 디렉터리가 이미 존재해야 한다는 것
  (`:43 createDirectory` 는 진짜 cacheDir 만 만든다)과 파일명 접미(`_N.mp4`, `.mp4.fp`)뿐이다.
- **모집단**: 워크샵 코퍼스 446 폴더 중 `workshopid` 선언 **271건**
  (짝 저장소 `corpus_scan/project-json-schema.md:23`). 동봉 코퍼스 170건·설치본 191건에는 **0건** —
  이 필드가 채워지는 모집단은 이 머신에 없다. **다만 악용은 코퍼스 도수와 무관하다**(공격자가 파일을 만든다).
  video `.tex` 레이어 도수는 재지 못했다.
- **기지 대조**: `AUDIT-FULL-2026-08-31.md:1927-1940` 이 같은 값(`id`/`workshopid`)의 F580 벡터를 시험했지만
  **LibraryStore 관리 폴더명 자리만** 보고 "전건 거부된다" 로 닫았다. r2 §0/§4 와
  `docs/audit-r2-lanes/lane07-media.md:110-113` 은 `VideoTextureExtractor` 를 캐시 evict 상한 축으로만 다룬다.
  `VideoTextureExtractor|workshopid|cacheKey|extractMP4` 를 두 감사 문서 + 16레인에 grep → **이 사슬 0건**.
  부수적으로 이 자리는 `AppDelegate.swift:1751-1753` 의 "외부 텍스트가 `WallpaperPathSecurity` 를 거치지 않고
  경로에 닿는 **유일한** 지점이었다" 는 전칭의 반례이기도 하다.

### 3.2 🟠 H1 · H2 — F820 이 씬 오디오를 통째로 빠뜨렸다

두 발견은 같은 결손의 두 얼굴이라 **병합 시 하나로 묶는 편이 낫다**(검증기도 그렇게 적었다).

- **자리**: `Sources/WapleRender/SceneAudioPlayer.swift:17`(죽은 근거 주석) ·
  `Sources/Waple/Shell/NowPlayingBar.swift:57`(메뉴 노출 조건)
- **재현**: 라이브 반영 경로는 `AppDelegate.swift:653`
  `renderers.compactMap { $0 as? VideoRenderer }.forEach { $0.applyLiveVideoSettings() }` 하나뿐이고,
  `applyLiveVideoSettings` 는 `VideoRenderer.swift:356` 에만 있다 — `WallpaperRenderer` 프로토콜(1-52)에
  그 요구사항이 없으므로 **SceneRenderer 는 절대 호출되지 않는다**. 씬은 마운트 시 1회
  `SceneRenderer.swift:2266 settingVolume: VideoSettings.volume(id: project.id)` 로 값을 받고,
  `SceneAudioPlayer.swift:176 private let settingVolume: Float` 라 세션 중 갱신 API 자체가 없다
  (`:224 setVolume` 은 `authorVolume` 만 바꾼다).
- **시간순이 이 건을 확정한다**: `23c8e277`(2026-07-24, F820)이 리마운트를 없앴고,
  음량 컨트롤을 씬에 연 `08f5a319`(2026-08-18, "씬 BGM 을 올릴 창구가 없었다")는 **25일 뒤**다.
  그 커밋의 `--stat` 은 `NowPlayingBar.swift` + `NowPlayingSubtitleTests.swift` 둘뿐 —
  AppDelegate·렌더러 무변경. 즉 **처음부터 죽은 채로 태어났다**.
- **영향**: 씬 배경에서 음량을 조작하면 UserDefaults 와 체크마크만 바뀌고 출력은 한 톨도 안 바뀐다.
  기본값이 0(음소거)이라 씬 BGM 은 그 세션 내내 무음이다. 악화 조건: 전역 선택 없이 모니터 할당만으로
  씬을 띄우면 `VideoSettingsTarget.projectIds`(`AppLogic.swift:125-130`)가 빈 배열이라
  (`activeVideoProjectIds` 는 `type == .video` 만, `AppDelegate.swift:777-779`) 저장조차 되지 않는다.
  더해서 `SceneAudioPlayer.swift:17-19` 가 "메뉴 변경 시 AppDelegate 가 배경을 재-mount → start 가
  최신 설정을 재독" 이라고 적어 **다음 세션이 이 경로를 정상으로 오독하게 만든다**.
- **모집단**: 워크샵 코퍼스(`spec/corpus/scene-schema.json` `scene.objects.keysByType.sound`) —
  sound 오브젝트 378 / 사운드 보유 123씬, 그중 자동재생(`startsilent=false`) 154.
  설치본·실물 pkg 는 이 머신에 없어 실행 확인 못 함.
- **기지 대조**: r2 **H8** · `lane07-media.md` L7-1 과 **같은 호출부**(`AppDelegate.swift:653`)지만 그 둘은
  `.videoFallback`(WebRenderer, ffmpeg 미설치 + webm 이라는 환경 게이트)만 지목했다. 씬 경로는 두 감사
  어디에도 없고, `SceneAudioPlayer.swift` 는 `lane07-media.md:184` 가 **"이 라운드에서 보지 않은 레인 파일"**
  로 명시 제외했다. 씬 경로는 환경 조건 없이 상시 도달한다.
- **연결**: `M21`(멀티모니터 대상 오선택)과 `M14`(배속 축 미적용)이 같은 배관의 다른 결손이다.
  세 건을 함께 고쳐야 "하단 바 음량/배속 메뉴" 가 실제로 동작한다.

### 3.3 🟠 H3 — 골든 기준선 **설치** 게이트가 모집단 0 에서 초록을 낸다

- **자리**: `scripts/mac-session/rebaseline-golden.sh:64`
- **재현**: 스크립트는 실물 코퍼스 + `swift build -c release` 를 요구해 실행할 수 없으므로,
  판정부(:58-72)를 python 으로 **축자 이식**해 합성 매니페스트 2케이스를 돌렸다 —
  `a=170 / b=110`(2차에서 60종 마운트 실패) → 교집합 110 · 상이 0 → "상이 0종" → **설치 분기**,
  `a=170 / b=0`(2차 전건 실패) → 교집합 0 · 상이 0 → **설치 분기**.
- **세 겹이다.** ① `:64 diff = sorted(i for i in a if i in b and ...)` 에 `len(a)==len(b)` 단언이 없다.
  ② `:71-72` 는 `m1["failures"]`(1차)만 보고 **verify 캡처의 failures/empties 는 어디서도 안 본다** —
  `b` 는 `:63` 의 `man()` 과 `:64` 에서만 쓰인다. ③ `cap()`(:41-46)이
  `"$BIN" --capture … | tail -4` 로 파이프해 종료코드를 버리는데 스크립트 머리(:11)는
  `set -uo pipefail` 로 **`-e` 가 없다** — pipefail 이 상태를 계산해도 아무도 읽지 않는다.
  전건 마운트 실패여도 `runCapture` 는 `entries:[]` 매니페스트를 먼저 디스크에 쓰므로
  (`SnapshotPipeline.swift:374-383`, `:396 return failures.isEmpty ? 0 : 1`) `man()` 이 성공하고 `b={}` 가 된다.
- **영향**: 이 스크립트 머리말(:4-7)이 스스로 "형식적 절차가 아니라 실제로 깨졌던 것을 막는 게이트" 라고
  선언한 자리가, 2차 캡처 부분/전건 실패에서 **축소 모집단 또는 0 모집단**에서 초록을 내고 1차 캡처를
  `spec/golden/snapshot/baseline-<sha>/` 로 설치한다(:95-100). 설치 뒤 `golden-gate.sh` 를 돌려도
  **새 기준선 자신과** 비교하므로 잡히지 않는다(스크립트 :81-84 가 같은 논리를 다른 검사에 대해 이미 적었다).
  하류 독립 그물도 없다 — `GoldenBaselineOracleTests:53-54` 의 `gitSHA`/`entries.count 170` 은 사람이
  라벨을 갱신할 때 같이 고치는 리터럴이다.
- **기지 대조**: `lane11-compat.md:64` 는 같은 파일의 `:85-86`(내부모순 검사)만 다뤘고 교집합 대조·미검사
  종료코드는 없다. r2 **H13/H14** 는 `--capture`/`--compare` **내부**이고 이쪽은 **설치** 게이트다.
  도입 커밋은 `6e756443`(2026-08-02) — 게이트를 만든 그 커밋이고, PR #8 은 `scripts/mac-session/` 을 안 건드렸다.

### 3.4 🟠 H4 — 오버라이드는 `entry.id` 로 쓰고 렌더러는 `project.id` 로 읽는다

- **자리**: `Sources/WapleRender/SceneRenderer.swift:1855`(읽는 쪽) ↔
  `Sources/Waple/LibraryViewModel.swift:515·524·529`(쓰는 쪽)
- **재현**: 리포 전체의 `UserPropertyStore` 프로덕션 소비처는 6자리가 전부다 —
  쓰는 쪽 `LibraryViewModel` 3자리는 **전부 `entry.id`**, 읽는 쪽 `SceneRenderer.swift:1841`·`:1855` ·
  `WebRenderer.swift:143` 은 **전부 `project.id`**. 키는 `UserPropertyStore.swift:6 waple.userprops.\(id)`
  라 id 가 곧 네임스페이스다. `project.id` 의 출처는 `ProjectJSONParser.swift:33` 이고, 마운트 경로
  `AppDelegate.swift:555 projectForMount(folderURL:)` 는 **폴더 URL 만 받는다** — `entry.id` 를 렌더러에
  넘길 통로 자체가 없다.
- **분열은 코드만으로 성립한다**: `LibraryStore.swift:100-120` 이 id 충돌 + `sameFolder=false` 에서
  `uniqueEntryId` 로 `X-2` 를 발급하고, `:104-106` 의 F586 주석이 **기존 엔트리의 북마크 해석 실패도
  같은 분기로 간다**고 명시한다. 그 엔트리의 폴더를 파싱하면 `project.id` 는 여전히 `X` 다.
  (2차 축 — 임포트 뒤 폴더명 변경 — 은 `lane10-library-saver.md` 의 bmprobe 실측이 근거이나 이 라운드에서
  다시 재지 않았다.)
- **영향**: (a) 속성 편집기가 보여 주고 저장하는 값을 **어떤 렌더러도 읽지 않고**,
  (b) 렌더러는 대신 같은 `project.id` 를 갖는 **다른 배경**의 오버라이드를 적용한다. UI 는 저장 성공으로
  보이므로 통지도 없다. `SceneRenderer.swift:1853` 의 "LibraryViewModel 유효값 계산과 **동형**" 주석은
  키가 다르므로 거짓이고, `AppDelegate.swift:1861` 의 F480 주석("파서 id 폴백을 섞지 않는다(같은 불일치 재발)")은
  같은 분열을 **최근 배경 메뉴 한 소비처에서만** 고쳤다는 자백이다.
- **모집단**: 설치본 191 — `ProjectJSONParser.swift:288-289` 가 "설치본 191건 도달 0(`workshopid` 키 자체가 0건)"
  을 정본으로 잠근다. 즉 이 모집단 전건이 폴더명 폴백 id 라 폴더명이 분열의 축이 된다.
- **기지 대조**: `project.id|entry.id|uniqueEntryId` 를 두 감사 + 16레인에 grep → 4히트 전부 무관
  (lane07:21 · lane09:148 · lane09:272 · AUDIT:1938). lane09 항목 5("PropertyEditorView 의 유실 경로는
  닫혀 있다")와도 다르다 — 그쪽은 dirty 편집의 **커밋 타이밍**, 이것은 커밋이 정상적으로 끝난 뒤
  **어느 키에 들어가는가**다.

### 3.5 🟠 H5 — 7번째 저장소만 3분기 로드 규약을 안 지킨다

- **자리**: `Sources/WapleRender/TextScriptEngine.swift:338`
- **재현**: `if let data = try? Data(contentsOf: fileURL), let dict = (try? JSONSerialization…) as? [String: String]`
  — **파일 없음 / 읽기 실패 / 디코드 실패** 세 갈래가 전부 `values = [:]` 라는 한 결과로 붕괴한다.
  loadFailed 상당 플래그도, corrupt 상당 플래그도, 백업도 없다. `[String: String]` 캐스트라 값 하나만
  문자열이 아니어도 전 키가 사라진다. `flush()`(:431-440)는 조건 없이 현재 dict 를 `.atomic` 으로 전량
  재기록하고, `SceneRenderer.swift:3011`(teardown)과 `TextScriptEngine.swift:354`(deinit)이 그것을 무조건
  호출한다 — **`set()` 없이 마운트→해제만으로 `{}` 가 원자적으로 덮인다.**
- **대조군이 같은 리포에 있다**: `WapleLibrary/MonitorAssignmentStore.swift:5-19`
  (`backupCorruptStoreFile` — 손상 원본을 `.corrupt-<ms>` 로 rename 한 뒤에만 덮어쓴다, F252) ·
  `:23-35`(`readStoreFile` 3분기: 파일없음=정상 / 읽기실패=일시적 / 디코드실패=진짜 손상).
  그 주석은 "비어있는 메모리 상태로 멀쩡한 원본을 덮어쓰는 걸 막아야 한다" 를 스스로 적는다.
  `Package.swift:29-30` 의 `WapleRender → ["WapleCore"]` 의존은 헬퍼 재사용 불가의 **설명**이지 면책이 아니다.
- **영향**: `script-storage/<씬 id>.json` 이 한 번 판독 불가가 되면 그 씬의 스크립트 저장 상태
  (F810 이 지키려던 `miDragable` 드래그 위치 등 사용자가 손으로 만든 배치)가 **다음 마운트 한 번**에
  영구 소실된다. `.corrupt-*` 백업도, 통지도, 재시도도 없어 복구 경로가 0이다.
  저장소는 `mountWindow != nil`(`SceneRenderer.swift:2019`) 즉 라이브 데스크탑 경로에서만 생성되므로
  헤드리스 캡처 면책이 아니다. `Tests/WapleRenderTests/ScriptPersistenceLiveChannelTests.swift` 에
  손상 로드 케이스 0건.
- **기지 대조**: `ScriptLocalStorage|script-storage|localStorage` 를 두 감사 + 16레인에 grep → **0건**.
  기지 **H20**(`.corrupt-*` 를 읽는 코드 0건)과도 다르다 — H20 은 백업이 **만들어진 뒤** 출구가 없다는 것이고,
  이것은 애초에 백업이 만들어지지 않으면서 능동적으로 `{}` 를 쓰는 저장소다.

### 3.6 🟡 중 실동작이 걸린 것 — 여섯 자리

색인의 68건을 다 펼치지 않는다. 픽셀·소리·사용자 데이터가 실제로 움직이는 것만 짧게 남긴다.

- **M20 `ScreenSaverController.swift:28`** — `containedFileURL` 전수 19자리 중 **이 파일만 0건**.
  `ProjectJSONParser.swift:87` 의 `normalizedRelativePath` 는 **어휘적** 봉쇄라 심링크 탈출을 못 막고,
  `WallpaperPathSecurity.swift:31-56` 이 그 사실을 스스로 적는다. 토글 경로
  (`AppDelegate.swift:1598` → `:1400 resolvedScreenProjectSlots`(MonitorMapping 파스만) → `enable` →
  `:152 CFPreferencesSetValue("videoPath", …)`)는 **마운트 성공을 요구하지 않는다** — 마운트가 거부되는
  배경도 세이버 plist 에 절대경로를 영속시키고, `syncVideoPath` 는 "아니면 기존 값 유지" 라 그 값이 남는다.
  심링크가 라이브러리에 실재할 수 있다는 전제는 `lane10-library-saver.md:139-152` 의 `ditto` 실측 인용이다.
- **M24 `LibraryFiltering.swift:47`** — 팝오버가 나열하는 목록은 **전체 entries**에서 유도하는데
  (`LibraryViewModel.swift:86-90`), 필터 내부의 `allTags`/`allRatings` 는 **폴더 스코프된 입력**에서 유도한다
  (`:80-81`). `:68`·`:71` 의 `criteria.tags.isSuperset(of: allTags)` 가 참이 되면 그 축이 **통째로 건너뛰어진다**.
  그 사이에도 `isActive` 는 참이라 툴바 아이콘은 켜져 있고 무결과 안내도 안 뜬다.
- **M64 `LibraryStore.swift:393`** — 폴더 해석 실패를 `tags = []` 로 **영구** 마킹한다.
  `[]` 는 다시 `nil` 이 아니므로 `:389` 의 재시도 조건에 영영 안 걸리고, 되돌리는 대입이 리포에 0건이다.
  `init` 이 무조건 부르므로(`:34-35`) 볼륨이 안 붙은 채 뜬 한 번의 로그인 기동으로
  그 엔트리들의 태그가 영영 빈 값, `contentRating` 이 nil 로 못박히고 `LibraryFiltering.swift:72` 에서
  등급 필터에 통째로 사라진다. **모집단은 구버전 인덱스(tags==nil) 엔트리 한정**이고, 실제 `library.json` 이
  이 머신에 없어 도수는 재지 못했다. 트리거(볼륨 미마운트 기동)도 추론이다.
- **M41 `ParticleSimulator.swift:524`** — `time += dt` 의 `Float` 누적. IEEE binary32 왕복 시뮬로
  0.76일 → 비율 0.9375, 3.03일 → 1.8750, **6.07일 → 0.0000(정지)**. 같은 프레임의 씬 시계는
  `Float(now - startTime)` 로 매번 재계산이라 안 얼어붙는다 — 두 애니메이션이 서로 미끄러진다.
  라이브 draw 경로에 리셋이 없다(리셋은 마운트/캡처/재로드뿐). **활성 재생** 6일이지 벽시계 6일이 아니다.
- **M13 `SceneVideoLayer.swift:32`** — 표(:29-34) 8행 중 **6행이 한 순서, 2행이 반대 순서**다.
  테스트가 고정한 두 앵커(`MediaFixRegressionTests.swift:480`·`:486`)로 R·M 을 정하고 8원소 디헤드럴군을
  재계산하면 (q=1,mir) 과 (q=3,mir) 이 정확히 뒤바뀌어 있고 차이는 R²(180°)다. 어느 쪽을 정본으로 봐도
  다른 쪽이 틀린 것은 확정이며, 그 두 행이 하필 **M43 의 미단언 3행 안**이다. 도달 도수는 미측정
  (씬 비디오 코퍼스가 세 모집단 어디에도 없다).
- **M61 `EffectShaders.swift:136`** — 손포팅 shake 진폭 기본 `0.006` vs WE 선언 `0.1`
  (`effects/shake/shaders/effects/shake.frag:17`, range 하한 0.01 — **WE 에서는 저작조차 불가능한 값**).
  양쪽 다 제곱이므로 도달 시 변위가 (0.1/0.006)² = **277.8배** 부족하다. `478e7af0` 의 최초 구현이
  **선형**이었고 F265 가 실물에 맞춰 제곱을 넣으면서 재튜닝하지 않은 것 — 같은 블록의 F-X8 주석은
  **바로 윗줄** `g_Speed` 를 실물에서 읽어 고쳤는데 진폭은 건너뛰었다. 형제 6이펙트의 기본값은 전건 일치.
  도달은 GLSL→MSL 번역이 먼저 실패해야 하는 **손포팅 폴백** 경로 한정이다.

## 4. 기각·정정·미판정 — 이 문서의 본전

### 4.1 기각된 발견 (8건)

| 원 발견 | 원 주장 | 판정 | 기각 사유 |
| --- | --- | --- | --- |
| WE Scene 생성자가 `g_ParallaxPosition` 을 `cameraparallax` 와 **무관하게** (0.5,0.5)로 프라임 (`SceneRenderer.swift:1227`) | high | **duplicate** | 결함·자리·기전이 r2 **H4/H5** 와 `lane05-render-core.md:67-125` 에 이미 있다(같은 좌표 1224·1227·1314-1315, 같은 `depthparallax.vert:44` 소비까지). 주장된 신규 사실 셋 중 둘이 거짓 — 리셋 자리(capture 2751-2756 · teardown 2987)는 lane05 가 이미 열거했고, "골든 캡처에 그대로 구워진다" 는 `advanceCaptureCameraParallax`(:1335-1352)가 수렴 후 샘플링하므로 과장. **디스어셈블 증거는 유효하니 H4/H5 에 귀속해 병합할 것** — lane05 의 "생성자 값이 얼마인지 정본에 없다" 는 판단 유보를 실제로 닫는다 |
| `AUDIT-FULL-2026-08-31.md:588` 의 "alpha·position 은 같은 구조의 형제" 가 position 에 대해 거짓 | medium | **duplicate** | `lane03-particles.md:130-140`(F3)이 같은 자리를 같은 VA 두 개(`0x140240595`·`0x140240775`)까지 인용해 이미 짚었다. 다만 **모순의 판정**(position arm 은 1차 차분 누적이고 ×0.5·(1+sin) 이 없다 — 즉 Waple 구현이 옳고 정본 문장이 틀렸다)은 이 라운드가 디스어셈블로 확정했으니 F3 에 붙일 것 |
| `verify-plan-b12.sh:107` §4 가 `Executed 0 tests` 를 통과로 읽는다 | observation | **duplicate** | `docs/sweep-2026-08-19.md:391`(D-04 / P3-07)이 **같은 좌표·같은 결론·같은 미확인 고리**까지 이미 적어 뒀다. 원 발견의 기지 대조가 AUDIT-FULL 2종만 훑어 리포 안의 선행 스윕 문서를 놓쳤다. "실질적으로 아무것도 판정하지 않는다" 도 과장 — `:10 set -uo pipefail` 이 실제로 게이팅한다 |
| `DeepScan.swift:805` 의 F840 형제 좌표가 **작성 시점부터** 무효였다 | observation | **refuted** | 현행 좌표가 어긋난 것은 사실이나 "출생 시 오류" 가 거짓이다. 원 발견은 파일의 마지막 수정 커밋(`970f5886`)을 작성 커밋으로 오인했다. 주석 문자열로 다시 뜨면 출생은 `f1406b27`(2026-08-19)이고 **그 트리에서 109·209·156 이 전부 정확한 `sem.wait` 줄**이었다. 남는 것은 평범한 사후 드리프트 = 기지 M10 부류 |
| `NowPlayingProvider.swift:198` 의 `SemaphoreResultBox` 인용이 **애초부터** 틀렸다 | observation | **refuted** | 인용 도입 커밋 `dd4f6e43`(2026-08-19) 시점의 `:58` 은 그 박스의 **근거 주석 블록 첫 줄**이었다(클래스 선언은 3줄 아래 :61). 원 발견이 대조한 두 리비전은 둘 다 그 커밋 **이후**라 도입 시점을 못 본다. "리포 내부 모순" 규정도 무너지고 기지 M10 계통의 한 자리로 남는다 |
| `ShaderPreprocessor.swift:80` 의 −0xD0 대조군이 **그 규약을 쓰지 않는 파일**을 가리킨다 | observation | **refuted** | 출생 커밋 `cb463399`(2026-08-19) 트리에서 `SystemAudioSpectrumProvider.swift:92` 는 정확히 `⚠️ … 0x1400d02b0(−0xD0)` 줄이었고 `Model3D.swift:54·320` 도 정확했다. 그 뒤 `badbe68f`(08-21)가 그 주석을 지우면서 대조군이 사라진 것이다 — 사후 드리프트 |
| steamcmd argv 의 `username` 슬롯이 무검증 | observation | **duplicate** | `lane08-app.md:146-150` 이 **세 좌표 전부·논증·완화 서술까지 동일하게** 이미 적었다. 원 발견의 "두 선행 감사와 전수에 0건" 이 거짓. 승격 근거로 든 "동일 사용자 프로세스가 UserDefaults 를 쓰면 주입" 은 이미 코드 실행 권한을 전제하므로 근거가 못 된다 |
| 낡은 Metal census(77/324/575)가 **ci.yml 한 자리가 아니라** 7자리 | observation | **duplicate** | 헤드라인의 전제가 거짓이다 — `lane12-tests.md:83-115`(F2)가 `ci.yml:295`·`:421-431`(세는 법 정의 블록 전체)·`:595` 를 이미 열거하고 82/364/627 을 실행 재현했으며 +5 파일의 출처까지 특정했다. 진짜 증분은 **`AGENTS.md:324-325` 한 자리**뿐이고, 원 발견 자신의 census 도 어긋난다("5자리" 라 쓰고 6개 나열, `:422` 누락) |

**패턴이 하나 있다.** 8건 중 5건이 `duplicate` 이고, 그 5건 전부 **자기 기지 대조에서 "0건" 을 선언**했다.
실패 원인은 두 가지로 갈린다 — (a) 대조 범위를 `AUDIT-FULL-*.md` 두 문서로만 잡아
`docs/audit-r2-lanes/`(3,890줄)와 `docs/sweep-2026-08-19.md` 를 안 봤다, (b) 레인 문서가 결함을 **범위 표기**
(`:421-431`)로 적어 개별 줄 grep 에 안 걸렸다. 다음 라운드의 기지 대조는 **범위 표기까지 펼쳐서**
`docs/` 전체를 대상으로 해야 한다.

`refuted` 3건은 전부 같은 형태다 — **"밀린 것이 아니라 애초부터 틀렸다"** 는 신규성 주장이
`git log -S '<주석 문자열>'` 로 출생 커밋을 특정하자 무너졌다. 세 건 모두 파일의 **마지막 수정 커밋**이나
임의의 과거 리비전을 출생으로 오인했다. **주석의 출생은 파일 이력이 아니라 문자열 pickaxe 로 잡아야 한다.**

### 4.2 살아남았지만 본문을 고쳐야 하는 것

검증기가 결론은 유지하면서 근거·수치·프레이밍을 깎은 것이다. **병합 시 원문을 그대로 옮기면 안 된다.**

| id | 고칠 것 |
| --- | --- |
| M3 | "리포 전체에서 spec→담당 파일 줄 인용은 이 1건뿐" 이 거짓 — 같은 줄의 grep 이 **44건**을 낸다. 결함 실체는 유효 |
| M6 | `ParticleSystem:151`·`:2002` 4자리가 **M54 와 내부 중복** — 한쪽으로 접을 것 |
| M11 | Hz/빈 쌍은 확정이나 **Δt 문장은 검증되지 않았다**(포팅 결과가 ±1~3밴드 어긋난다). Δt 축을 검증했다고 적지 말 것 |
| M12 | 원 재현이 **엉뚱한 필드**(`objects[].image`)를 쟀다. 모델을 해석해 다시 재면 `_rt_` 보유 8씬 / colorBlendMode 동반 5씬 / 값≠0 **0씬** — 결론(13은 동봉이 아니다)은 유지. "전수 grep" 도 과소계상(같은 grep 이 21행) |
| M14 | "기지 H8/L7-1 의 판정이 틀렸다" 는 과장 — L7-1 은 배속 축에 대해 F820 회귀를 **주장한 적이 없다**. 실질 값어치는 **수정 범위**(라이브 훅만으로는 배속이 여전히 죽는다) |
| M17 | "세 수가 동시에 참일 수 없다" 는 절대적 산술 모순이 아니다. 확정 근거는 **정의되지 않은 모집단명 + 정본 충돌 + 157 의 전파** |
| M25 | 세 번째 수("11개는 사용처가 하나")는 미확정. 확정은 28≠20 과 참조 0건 넷 |
| M27 | `validate.py` 는 완전 무시가 아니다(`:253-265` 가 **EOF 초과**는 잡는다 — 범위 안 드리프트만 사각). 모집단은 20 이 아니라 **14건** 중 6건 |
| M28 | 분모가 5/13 이 아니라 **5/18** — 분자는 맞다 |
| M29 | "19게이트 중 **유일하게**" 전칭이 **M48 로 반증**됨(둘 다 selftest·하한 없음) |
| M43 | "R1 이 프로덕션 결함을 올렸다" 는 전제를 확인하지 못했다 — 오히려 그 프로덕션 결함(M13)도 두 선행 감사에 0건이라 **신규성이 더 강해진다** |
| M44 | "그 사이 4개 더 생겼다" 는 절반만 참(둘은 게이트 도입보다 먼저). "전량 `--parallel` 에서 회차마다 빨개진다" 는 **CI 얘기가 아니다**(ci.yml:215 에 `--parallel` 없음) — 노출되는 것은 AGENTS.md:394 를 믿고 로컬에서 병렬 판정하는 사람 |
| M49 | "다섯 자리" 중 이 라운드가 확인한 반례는 **2건**(`check_swift_escapes` · `check_swift_enum_patterns`, 둘 다 cwd 상대). 전칭이 거짓이라는 골자만 유지 |
| M54 | 77/131 **전건 재계산은 하지 않았다** — 재현은 모집단 정의(123 인용 / 119줄) · 대표 4건 · 빈 줄 착지 13건 · 무작위 8표본이다 |
| M60 | 인용한 `BlendMSL.swift` 줄번호(:130·:136)가 틀렸다 — 실제 `:171`(`we_colordodge`) · `:176`(`we_hardmix`) |
| M62 | "80 정확" 은 낙관적이다 — 86건 전수 자동 대조에서 주석·괄호 착지가 12건(추가 8건은 doc-주석 텍스트를 일부러 인용한 것으로 보인다). 선언 시그니처를 함께 적고도 어긋난 것은 지목된 4건 |
| M63 | 제목의 "D3D11 축 진양성 0" 은 과장 — `D3D11CreateDevice` 4행은 **전건 진짜**다. 참인 것은 "디바이스 컨텍스트 메서드 축(Map/Unmap + 0행 11종)에 진양성 0" |
| M65 | 물려받기 시나리오가 좁다 — zip 임포트는 `LibraryStore.swift:266-269` 의 `uniqueManagedName` 이 막는다. 성립하는 것은 고아 폴더를 지웠거나 관리 폴더 **밖**에서 같은 basename 을 넣는 경우. 누적 누수는 그대로 |
| M66 | 실질 내용은 r2 **H15/H16/H17** 의 **정본 쪽 대응물**이다 — 재발견이 아니라 "고쳤다고 적힌 문서가 거짓" 으로 병합할 것 |
| O2 | 제시된 재현표 4행(`ts=[2,5] dur=6 → sim 7.001`)이 **틀렸다** — 실제 5.001 로 helper 와 일치한다. 다중 transform 은 이 결함의 사례가 아니다. 같은 기전이 `docs/full-audit-2026-08-26.md:182` 에 이미 열린 항목으로 있다 |
| O6 | 제목 전제가 model/sprite 에 대해 거짓 — 그 둘은 가시성 맵에도 **없다**(파티클만 있다). 결론은 세 타입 모두에 유효 |
| O17 | "사람을 반대 방향으로 보낸다" 는 과장 — stdout 이 바로 위에서 `렌더→무픽셀 회귀=N` 과 id 목록을 먼저 찍는다. 오진단은 종료코드와 stderr 한 줄에 한정 |
| O26 | 자리 표기 정정 — `re/scripts/` 디렉터리는 없다. 짝 저장소의 `scripts/ghidra_decompile.py:115` |

### 4.3 미판정 (8건 → 6건) — **확정으로 승격하지 말 것**

> **[갱신 2026-09-01]** 오케스트레이터가 이 표의 2건을 직접 판정했다 — 하나는 기각, 하나는 확정. 표 안에 표시했다.

검증기가 판정에 도달하지 못한 것이다. 기각도 통과도 아니다.

| 자리 | 주장 | 미판정 사유 |
| --- | --- | --- |
| `Waple-wallpaper-source/scripts/TraceRttiVtables2.py:72` | **high** — RTTI 트레이서 둘이 x64 COL 레이아웃을 4바이트 밀려 적어 어떤 입력에서도 "COL 0 · vtable 0" 을 낸다. `rtti-vtables.json` 의 "확인된 결과" 와 산문 §7 의 "Verified" 가 그 버그의 출력이라는 주장(무손상 PE 실측: TD 132 / 스크립트 레이아웃 COL 0 / 실제 x64 레이아웃 COL 75) | 이 라운드에서 검증기가 판정을 내지 못했다. **주장이 참이면 두 리포의 08-30 "재현했다" 판정이 함께 뒤집힌다** — 다음 라운드 최우선 미결 |
| `WapleRender/SceneRendererFrameEncoder.swift:450` | `copyBackground:false` 일 때 `colorBlendMode` 의 dst 로 acc 스냅샷 대신 **투명 클리어** 텍스처를 넘긴다(자기 주석과 다르다). 동봉 도달 0 | 미판정. 같은 라운드의 다른 레인 초안이 독립 검출했다는 표기가 있어 **내부 중복 여부도 미확인** |
| `README.md:50` | "완전히 무음으로 스킵" 의 예시 둘이 **둘 다 이미 고쳐진 것**(하나는 그 문장이 쓰이기 17분 전) | 미판정 |
| `WapleLibrary/LibraryStore.swift:218` | zip 해제 타임아웃/실패가 `try?` 로 원인이 지워지고 사용자에게 **다른 원인**을 가리키는 안내가 뜬다. 손상 zip 은 로그 0건 | 미판정 |
| `spec/corpus/scene-schema.json:5288` | evidence 가 **2026-08-30 에 삭제된 코드**를 반증 근거로 들고, 같은 파일 `:5265` 는 정반대를 적는다(정본 자기모순) | 미판정 |
| `spec/corpus/scene-schema.json:5132` | `waple.textParallaxScope`(확정)·`waple.gapImpact` 코드 좌표 7자리 무효, 하나는 **파일에 존재하지 않는 심볼**을 근거로 든다 | 미판정 |
| ~~`scripts/spec/measure_decompilation_provenance.py:87`~~ | ~~`pdataCoverage` 분모가 아직 다른 모집단(6,824 vs 14,792)~~ | **기각 — 오케스트레이터 확인(2026-09-01)**. 정본 `spec/engine/decompilation-provenance.json:134` 는 이미 `6824 / 14792 = **46.1%**` 이고 분자·분모의 모집단 관계까지 명시한다("분자는 … 그중 `.pdata` 함수 시작과 일치하는 교집합"). **6,824 는 분모가 아니라 분자다** — 원 발견이 정본을 반대로 읽었다. M26 은 온전히 닫혔다 |
| `scripts/spec/measure_decompilation_provenance.py:37` | 머리말이 `binaries/wallpaper64.exe` 를 주입본이라 적는데 그 파일이 곧 무손상 원본이다 | **확정 — 오케스트레이터 재현(2026-09-01)**: `shasum -a 256 binaries/wallpaper64.exe` = `40e2ce02…93b0` 이고 정본 `spec/binaries-fingerprint.json:9` 의 sha256 과 **바이트 일치**. 심각도 `medium`(정본 근거 거짓) |

미판정 8건 중 6건이 **정본·RE 도구 축**이다. 이 축은 검증에 원본 PE·Ghidra 산출물·워크샵 코퍼스가
필요해서 read-only 검증기가 닫기 가장 어려운 자리다 — §6 의 경계와 같은 원인이다.

### 3.7 오케스트레이터 독립 재현 (2026-09-01)

병합 전에 상위 발견을 직접 밟았다. 아래는 **레인 보고를 믿지 않고 다시 잰 것**이다.

| 발견 | 재현 | 결과 |
| --- | --- | --- |
| **C1** | `ProjectJSONParser.swift:32-33`(`workshopid` 원문 → `project.id`) → `SceneRenderer.swift:2085`(`sceneID: project.id`) → `SceneRendererResources.swift:277`(`cacheKey: "\(sceneID)_\(index)"`) → `VideoTextureExtractor.swift:24`(`appendingPathComponent("\(cacheKey).mp4")`) 전 경로를 이었다 | **확정.** 쓰기(`:49 mp4.write`)와 삭제(`:38 removeItem`) 둘 다 탈출 경로에서 일어난다. `appendingPathComponent` 는 `../` 를 표준화하지 않는다. 형제 `LibraryStore.swift:258-262` 는 같은 값에 `normalizedPathComponent` 를 걸며 *"살균되지 않은 원문이라 `../../` 같은 경로 탈출 벡터"* 라고 **명시**한다 |
| **H3** | `rebaseline-golden.sh:64` 의 판정식 `diff = sorted(i for i in a if i in b and …)` | **확정.** `i in b` 교집합만 본다 — 2차 캡처가 전건 실패해 `b` 가 비면 `diff` 는 `[]` 이고 "상이 0종" 으로 통과한다. 그 아래 `m1["failures"]` 검사는 1차(`baseline-`)만 본다 |
| **H4** | `LibraryViewModel.swift:524·529`(쓰기 `entry.id`) vs `SceneRenderer.swift:1855`(읽기 `project.id`). `LibraryStore.swift:119` 가 `uniqueEntryId(basedOn:)` 로 `id-2` 접미를 붙인다 | **확정.** `workshopid` 없는 배경 둘이 같은 폴더명이면 — `LibraryStore.swift:98-99` 가 주석에 적은 바로 그 시나리오 — 두 번째 배경의 속성 편집이 무효가 되고 첫 번째의 값이 대신 적용된다 |
| **M13 · M43** | `SceneVideoLayer.swift:29-34` 의 8행 표를 행벡터 규약으로 손계산하고, `MediaFixRegressionTests.swift:481-487` 의 단언 행을 셌다 | **둘 다 확정, 그리고 서로를 보강한다.** 표의 미러 행은 **회전→미러**(`R*M`) 순서와 일치하는데 독트링(`:16·:19`)은 **미러→회전**을 규정한다. 두 순서는 `q=0·2` 에서 같고 **`q=1·3` 에서만 갈리는데**, 테스트가 단언하는 4행이 `(1,f)·(2,f)·(3,f)·(0,t)` 라 **갈리는 두 행이 정확히 미단언 구간**이다 |
| 미판정 2건 | §4.3 참조 — `shasum` 1회와 정본 `:134` 재독 | 1건 **확정**(sha256 바이트 일치), 1건 **기각**(6,824 는 분모가 아니라 분자) |

**대조 실패 1건을 자백한다.** 이 라운드의 기각 8건 중 5건이 "기지인데 0건 선언" 이었는데,
오케스트레이터의 재현도 같은 함정을 한 번 밟을 뻔했다 — C1 의 형제 살균 자리를 찾을 때
`grep workshopid` 만으로는 `VideoTextureExtractor` 가 **그 문자열을 쓰지 않아** 걸리지 않는다.
`project.id` 로 데이터 흐름을 이어야 나온다. **문자열 grep 은 데이터 흐름 추적을 대신하지 못한다.**

### 3.8 보충 레인 (2026-09-01) — 실패한 두 레인을 메웠다

라운드 1 의 `R1:render-3d` · `R1:app-external` 이 스톨로 산출 0건이었다(문서 말미 한계 참조).
두 담당 영역을 별도 레인으로 다시 돌렸고, **본문 색인에는 없는 신규 발견 10건**이 나왔다.
아래는 그중 오케스트레이터가 직접 재현한 것이다.

#### 🟠 S1 — `hasStableId` 가 **살균 전** id 로 계산돼 관리 폴더명(**살균 후**)과 갈린다

- 자리: `Sources/WapleLibrary/LibraryStore.swift:257`(판정) ↔ `:258`(폴더명) ↔ `:269`(유일화 가드)
- 재현(코드만으로 결정된다):
  `ProjectJSONParser.parseStringOrNumber`(`:294-297`)는 **빈 문자열만** 거른다 —
  `"."` · `".."` · `"a/b"` · `"/1"` 은 전부 non-nil 로 통과해 `hasStableId = true` 가 된다.
  그런데 `WallpaperPathSecurity.normalizedRelativePath`(`:4-24`)는 그 넷을 전부 `nil` 로 거부한다
  (`.` → `parts` 비움 · `..` → 명시적 `return nil` · `a/b` → `contains("/")` · `/1` → `hasPrefix("/")`).
  그래서 `name` 은 **래퍼 폴더명으로 폴백**하고(`:258`), `:269` 의 유일화 가드는 `!hasStableId` 조건이라 **꺼진다.**
  결과: WE export 관례상 비유일한 래퍼명(`Wallpaper/`)을 쓰는 **서로 다른 두 배경이 무통지로 서로를 덮어쓴다.**
- 왜 최고가치인가 — **선행 감사의 기각 근거를 무너뜨린다.**
  `docs/full-audit-2026-08-26.md:274` 가 형제 발견을 이렇게 기각했다:
  *"LibraryStore 재가입은 project.json 사전 파스(**hasStableId**) 방어로 트리거 재현 불가"*.
  그 방어가 바로 이 자리이고, 살균 전 값으로 계산되므로 **기각 근거 자체가 무효**다.
- 그리고 **`parseStringOrNumber` 의 독트링이 이 손실 시나리오를 정확히 서술하면서 빈 문자열 칸 하나만 닫았다.**
  같은 문단이 *"`normalizedPathComponent("")` 가 nil 을 내 이미 폴더명으로 폴백하지만, 그 폴백이 오히려
  '빈 id + 비유일 폴더명' 조합을 만든다"* 라고 적어 놓고, 같은 논리가 `"."` 에도 성립함을 놓쳤다.
  **이 리포의 "반만 고친 수정" 계통 중 가장 명확한 사례다.**
- 모집단: **설치본 191 도달 0**(`workshopid` 키 자체가 0건). 손편집·악성 zip 한정이라 🔴 이 아닌 🟠.
- 기지 대조: `grep -rn hasStableId` → AUDIT 3종·BACKLOG **0건**(이 문서의 이 절이 유일).

#### 🟡 S2 — `waterripple` 손포팅이 `animationspeed` 를 제곱하지 않는다

- 자리: `Sources/WapleRender/EffectShaders.swift:212`
- 같은 파일 `:93` 주석이 WE 식을 **직접 인용**한다 — *"`v_TexCoordRipple = coords + g_Time*g_AnimationSpeed²`"*.
  그런데 `:212` 는 `P[0] * P[3]`(제곱 없음)이다. 바로 아래 `:214` 의 자매 항 `strength` 는
  `(P[1] * P[1])` 로 **제곱이 들어가 있고**, `:210` 주석이 그 제곱의 근거까지 적는다.
  즉 **같은 hunk 에서 한 항은 제곱하고 다른 항은 빠뜨렸다.** 기본값 0.15 에서 **6.667배 빠르다**.
- 도달: 동봉 2씬 · 설치본 2씬(손포팅 폴백 한정). 모집단 명시.

#### 나머지 (레인 원문에 상세)

`r3-recover-render3d.md` · `r3-recover-appext.md` 참조.
🟡 `waterwaves` 가 WE 에 없는 유령 키 `perspective` 를 읽고 실재 키 `exponent` 를 안 읽는다(두 모집단 저작 0건 → 잠복) ·
🟡 PR #8 의 `[동기화 2026-08-31]` 목록이 `Mesh3DShaders.swift:610` 을 반만 고쳐 **자기모순 문장**을 남겼고
`Scene3DLighting.swift:170·230` 은 아예 목록에 없다(센서스가 `= 358` 형태만 grep) — **F6-2 와 같은 부류의 세 자리** ·
🟡 PR #8 세이버 게이트가 안내 텍스트를 `contentsScale` 1.0 에 영구 고정(신규 회귀) ·
🟡 `WorkshopAPI`/`LibraryStore` 주석 좌표 4건 중 3건 무효(pickaxe 로 **출생 시점엔 정확** 확인 — M10 계통) ·
⚪ `combine_hdr` 두 벌 구현 중 폴백만 1탭(피라미드는 WE 대로 4탭) 외 3건.

**보충 레인이 닫은 것도 있다** — lane06 이 "의심" 으로 남긴 **포인트 섀도 아틀라스 인덱싱은 WE 와 행 대 행 일치**다
(`common_pbr_2.h:167-235` vs `Mesh3DShaders.swift:355-369`, 9탭 PCF 커널 탭 순서까지 동일). 다음 라운드는 이 축을 건너뛰어도 된다.
**여전히 열림**: 볼류메트릭 패커 방향 열(`0x140196ce0`) — 디스어셈블 미착수.

## 5. 두 축 분할이 값을 했는가 — 정직한 판정

**했다. 다만 대가가 있었고, 그 대가가 기각 8건의 대부분이다.**

### 5.1 값을 한 증거

**(a) 라운드 2 렌즈가 라운드 1 서브시스템이 소유한 파일에서 라운드 1이 못 본 축을 잡았다.**
같은 자리, 다른 질문이다.

| 라운드 1(서브시스템)이 본 것 | 라운드 2(렌즈)가 그 위에서 본 것 |
| --- | --- |
| M13 — `SceneVideoLayer.swift:32` 분류표 2행이 구현과 반대다(정확성) | M43 — **왜 4,016개 오라클이 그것을 못 잡았나**: 독트링은 8원소를 자칭하는데 5행만 단언하고, 어긋난 2행이 미단언 3행 안이며, 라이브 대조 2건은 3초 벽시계로 스킵된다 |
| M26 — 그리드 타일의 유형 배지가 combine 에 흡수돼 **전달돼야 할 것이 안 들린다** | O27 — 같은 타일에서 **감춰야 할 장식이 안 감춰진다**(형제 3자리는 전부 `accessibilityHidden`) |
| M23 — `SettingsView` 가 라벨을 중복해 드는 **근거 주석 두 개가 스테일** | M68 — 그 중복이 반대편에 남긴 **죽은 미현지화 라벨 2개**와, 그것을 "현행 UI 라벨" 로 잘못 서술하며 잠그는 테스트 주석 |
| M24 — 폴더 스코프에서 태그 필터가 **무필터로 무너진다**(필터 조합 로직) | M64 — 그 태그가 애초에 **영구 소실되는 경로**(backfill 이 일시 실패를 영구 마킹) |
| M8·M9·M18 — 인트리 파일 인용 드리프트 3자리 | M54(131자리 전수 · 77 무효) · M62(짝 저장소 `d.ts` 외부 인용 4자리) · O25(맨 `:N` 형태 **416자리** 규모 계수) — **개별 자리에서 부류의 규모로** 올라갔다 |

특히 마지막 행이 렌즈 축의 고유 산출이다. 서브시스템 레인은 자기 파일의 인용 몇 개를 고칠 수 있지만,
"이 부류가 131자리 중 77이고 게이트가 0건" 이라는 **판단**은 파일 경계를 넘는 렌즈에서만 나온다.

**(b) 라운드 2가 clean 판정 4건을 뒤집었다.** 이것이 두 축 분할의 가장 비싼 산출이다.

- **M36** — `lane12-tests.md:203-208` 이 `BaseAssetsSettings` 를 clean 으로 닫은 근거
  ("macOS `swift test --parallel` 은 클래스마다 별도 프로세스라 클래스 간 경합은 아니다")가
  `setenv` 에는 참이고 `UserDefaults.standard` 에는 **거짓**이다 — 같은 리포의
  `SceneRenderSettings.swift:45` 가 "`.standard` 는 프로세스가 아니라 **사용자** 단위" 라고 정면으로 적는다.
- **M39** — `lane06-3d-bloom.md:196-198` 의 "`cameraFrame.fov` 소비자 둘뿐" 이 거짓
  (세 번째가 `SceneRenderer3D.swift:2090` 에 실재하고 클램프를 건너뛴다). lane06 은 NaN 축만 봤는데
  실제 구멍은 **범위**였다.
- **O3** — `lane05-render-core.md:208` 의 "세마포어 불균형 0건" 판정은 결론은 옳지만
  **기록된 재현 grep 이 이 트리에서 8행(문서는 2행)** 이라, 6자리를 본 적 없는 grep 위에 서 있었다.
- **M48** — 라운드 1(M29)이 낸 "19게이트 중 **유일하게**" 라는 전칭을 라운드 2가 반증했다.
  **같은 감사 안에서 두 축이 서로를 교정한 유일한 사례**다.

**(c) 검증 라운드가 실제로 걸렀다.** §4.1 의 8건은 두 축 어느 쪽도 스스로 걸러내지 못했다 —
전부 자기 기지 대조에서 "0건" 또는 "작성 시점부터 틀렸다" 를 선언했고, 3라운드가 각각
`docs/` 전수 grep 과 `git log -S` 한 번으로 뒤집었다. 검증 없이 병합했다면 **118건 중 8건(6.8%)이
거짓 신규 발견으로 문서에 남았을 것**이고, 그중 5건은 이미 고쳐야 할 목록에 있는 항목의 재발행이었다.

### 5.2 대가

**(a) 같은 부류를 두 축이 나눠 가지면서 병합 비용이 생겼다.** 인용 무효 계통 16건은 서로 겹치는
모집단을 각각 셌다 — M6(담당 2파일 19자리)의 `ParticleSystem:151`·`:2002` 는 M54(131자리 전수)에
그대로 들어 있고, 검증기가 **내부 중복**으로 확정했다. O25(416자리)는 M54(131자리)와 형태만 다른
같은 부류이고 둘 다 "나머지는 미검증" 으로 끝난다. 이 세 건은 병합 시 **한 항목 + 세 모집단 표**로
접어야 한다.

**(b) 기각 8건 중 5건이 "다른 축·다른 라운드가 이미 적은 것" 이었다.** 두 축을 나누면 각 레인이
**28레인 전체의 산출물 + 직전 감사 3,890줄**을 대조해야 하는데, 실제로는 대부분
`AUDIT-FULL-*.md` 두 문서만 훑었다. 축이 늘수록 이 대조 부담이 제곱으로 는다.

**(c) 라운드 귀속이 남지 않았다.** 병합 시점에 각 발견이 어느 축의 산출인지는 발견 본문의
상호 참조(`[R1반박]`, "R1 재보고 금지 목록에도 없다", "R1 의 …와 다른 자리")로만 복원할 수 있었고,
그 표지가 없는 발견은 귀속을 **재구성하지 못했다**. §5.1 의 쌍 목록은 그 상호 참조가 명시된 것만 실었다 —
전수 귀속표는 이 문서에 없다.

### 5.3 결론

**두 축 분할은 값을 했다.** 근거는 §5.1 (a)의 5쌍과 (b)의 clean 판정 4건 전복이다.
두 축 중 하나만 돌렸다면 그 9건은 나오지 않았을 것이고, 그중 M64·M39·M43 은 실동작이나 오라클이 걸린다.

**다만 세 번째 축은 권하지 않는다.** 이번 라운드의 실패는 전부 **탐색 부족이 아니라 대조 부족**이었고
(기각 8건 중 5건이 기지, 3건이 이력 오독), 그 부담은 축을 늘릴수록 커진다.
다음 감사는 **축을 늘리는 대신 대조를 기계화하는 편**이 싸다 —
`docs/` 전체를 대상으로 한 기지 대조 스크립트와, 주석 출생을 `git log -S` 로 강제하는 규약이면
이번에 기각된 8건이 레인 안에서 걸러졌다.

## 6. 검증 경계 — 이 라운드가 확인하지 못한 것

선행 두 문서의 해당 절(`AUDIT-FULL-2026-08-31.md` §6 · `-r2.md` §7)을 읽고 갱신했다.

### 6.1 선행 문서에서 **닫힌** 것

| 선행 미결 | 상태 |
| --- | --- |
| r1 §6 "WE 가 `L` 을 만들 때 모델행렬의 어느 열을 쓰는지 기록이 없다" | ✅ r2 **H1** 이 팩커를 특정해 닫았다 |
| `lane05` 판단 유보 — "생성자가 심는 `g_ParallaxPosition` 값이 얼마인지는 정본에 없다. (0,0)이 옳다는 근거도 (0.5,0.5)가 옳다는 근거도 이 리포 안에는 없다" | ✅ **이 라운드가 닫았다** — 씬 생성자(`0x140186c90`)가 `cameraparallax` 게이트 **밖**에서 무조건 0.5 를 심는 것을 함수 선두 정렬 디스어셈블로 확인했다. 발견 자체는 §4.1 에서 duplicate 로 기각됐지만 **증거는 r2 H4/H5 에 귀속해 유효**하다 |
| `lane03 §3` S1 — 이미터 CP 프레임 게이트가 실물과 같은가 | ✅ 이미터 tick(`0x1402378a0`) 정렬 디스어셈으로 동일 확인 — `ParticleSimulator.swift:1191` 의 `simulatesInWorldSpace \|\| slot != 0` 이 실물 게이트와 같다 |
| `lane12` 의심 — `ParticleRemapFlagsWiringTests.swift:121` 의 XCTSkip | ✅ **도달 불가**로 확정(실패 회피형 스킵이 아니라 죽은 분기) |

### 6.2 여전히 열려 있는 것 (선행과 동일)

1. **워크샵 코퍼스 446 폴더 / 460 pkg.** 두 리포 어디에도 없다. C1 의 271건, H1/H2 의 sound 378,
   M60 의 이탈 도달, O1 의 887/6 — 전부 짝 저장소 census 문서 인용이고 **재현하지 못했다**.
2. **픽셀 회귀.** `WapleCompat --capture`/`--compare` 를 이번에도 돌리지 않았다.
   M13(180°) · M39(볼류메트릭 fov) · M61(shake 277.8배) 이 170씬 골든에 내는 diff 는 미확인이다.
3. **CI 실행.** `macos-26` 러너 실측 없음. M30 · M44 · M47 은 전부 게이트 로직을 이 맥에서 재생하거나
   합성 입력으로 이식한 결과다.
4. **Windows 동적 분석 · 서명/공증.** 미판정 표의 RTTI 건이 여기 걸린다.
5. **Swift 6 언어 모드 전환.** 수정 금지 지시에 저촉돼 시도하지 않았다.

### 6.3 이 라운드가 **새로 연** 것

1. **빌드·테스트를 한 번도 돌리지 않았다.** §1 의 기반 실측은 라운드 1·2 오케스트레이터의 값을 인용한 것이다.
   3라운드 검증기 전원이 read-only 였고, 실행한 것은 python 이식·grep·`git show`·`sed`·정본 게이트
   19종(§4 O18 의 rc=1 확인 포함)뿐이다.
2. **앱을 한 번도 띄우지 않았다.** 다음 7건은 코드 경로·문서 계약 추론이며 실기 관측이 없다 —
   M19(NSMenu 자동 활성화가 실제로 `isEnabled` 를 덮는지) · M38(WebContent 종료 후 백지) ·
   M20(심링크 패키지로 세이버 실행) · O13(5초 프로브 타임아웃 유발) · O14(옵저버 경합 창) ·
   O16(디스플레이 착탈) · M64(볼륨 미마운트 기동). **`plausible` 7건이 대체로 여기 모여 있다.**
3. **부분 검증으로 남긴 모집단이 둘 있다.** M54 는 131자리 중 **전건 재계산을 하지 않았고**
   (모집단 정의 + 대표 4건 + 빈 줄 착지 13건 + 무작위 8표본으로 규모만 확인), O25 는 416자리 중
   **414자리가 미검증**이다(계수만 했다). 두 수치를 "무효율" 로 인용하지 마라.
4. **RE 도구 축이 가장 얇다.** §4.3 미판정 8건 중 6건이 정본·RE 도구이고, 그중 RTTI 건은 **high 주장**이다.
   이 축의 검증에는 원본 PE + Ghidra 재생성이 필요한데 이 라운드는 PE 읽기까지만 했다.
5. **인용 census 게이트가 지금 rc=1 이다**(O18). 원인은 직전 감사 산출물(`docs/audit-r2-lanes/`)의
   미추적 인용 9주소이고, `docs/` 가 `CITATION_ROOTS` 에 들어 있어 **감사 문서를 성실히 쓸수록 붉어진다**.
   그래서 **이 문서는 `FUN_140…` 접두 토큰을 한 번도 쓰지 않았다** — 주소는 전부 순수 `0x140…` 표기다.
   이 문서와 라운드 2 산출물을 커밋할 때 그 게이트를 함께 처리할 것.
6. **두 리포의 상호 인용을 전수 대조하지 않았다.** M51(`spec/README.md` ↔ `AGENTS.md`)과
   미판정 2건(`measure_decompilation_provenance.py` ↔ 짝 저장소 `pe-structure.md`)이 같은 부류인데,
   "두 리포가 같은 사실에 대해 다른 답을 적는" 자리를 계통적으로 세지는 않았다.

## 7. 권고 순서

1. **C1** — 유일한 🔴. 한 줄짜리 수정이다(`project.id` 에 형제 3자리와 같은 살균을 걸고,
   `VideoTextureExtractor` 에 `WallpaperPathSecurity` 를 배선). **M20**(세이버 `videoPath`)과
   **M35**(스킴 핸들러의 거짓 봉쇄 주석)를 같은 PR 로 묶어라 — 셋 다 "봉쇄 규율에서 빠진 자리" 다.
2. **H1 + H2 + M21 + M14** — 하나의 결손이다. 하단 바 음량/배속 배관을 렌더러 종류와 대상 선택
   양쪽에서 다시 세우고, `SceneAudioPlayer.swift:17-19` 의 죽은 근거 주석을 지워라.
   그 주석을 그대로 두면 다음 세션이 같은 오독을 한다.
3. **H4 + M65 + M64** — 사용자 데이터가 조용히 사라지는 셋. H4 는 키 네임스페이스 통일,
   M65 는 제거 경로에 세 표면 추가, M64 는 실패 사유를 영구/일시로 가르는 것.
   **H5** 도 같은 성격이지만 수정 모양이 다르다(`readStoreFile` 3분기를 `WapleRender` 에서 재사용 가능하게).
4. **H3 + M46 + M44 + M29/M48 + M47** — 게이트가 거짓 초록을 낸다.
   **다음 라운드의 판정 근거 전체가 여기 걸려 있다.** H3 은 기준선을 잘못 **설치**하므로 가장 급하다.
   M29/M48 은 함께 고칠 것 — 하나만 고치면 `spec.yml:471` 의 전칭(M49)이 또 거짓이 된다.
5. **M13 + M43** — 프로덕션 결함과 그것을 놓친 오라클을 같이. 표를 고치면 미단언 3행도 함께 잠글 것.
6. **인용 계통 16건 + O25** — 개별 수정보다 r2 §9-5 가 이미 권한
   **"줄 번호 인용을 심볼명으로 바꾸는 규약"** 을 세우는 편이 싸다. 이번 라운드가 그 근거를 더 준다 —
   같은 부류가 세 감사 연속으로, 두 축에서 독립적으로, 131+416자리 규모로 나왔고
   **이것을 보는 게이트는 리포에 0건**이다(`validate.py` 는 EOF 초과만 본다).
7. **정본 하드코딩 산문 5자리**(M16 · M27 · M40 · M57 · M59) — 전부 생성기 리터럴이라
   **재생성이 해결책이 아니다**. `check_canon_entry_refs.py` 독스트링이 스스로 적은
   "id 가 맞는데 내용이 다른 곳을 가리키는 것은 사람의 몫이다" 가 지금 5자리에서 실현돼 있다.
8. **M51 → `AGENTS.md:617-620`** — 기지 L14-2 를 고칠 때 **정본으로 지목된 쪽을 같이 고쳐라.**
   한쪽만 고치면 독자가 안내받는 쪽에 거짓이 남는다. 이번 감사가 찾은 **"반만 고쳐질 자리"** 중
   가장 확실한 것이다.
9. **미판정 8건** — RTTI 건(§4.3 첫 행)부터. 주장이 참이면 두 리포의 08-30 "재현했다" 판정이 함께
   뒤집히므로, 다음 라운드는 이것을 **첫 과제**로 두는 편이 낫다.
10. **RE 저장소 미커밋 14파일** — r2 §9-6 이후에도 그대로다. 나흘째 백업도 CI 도 없다.

## 8. 이 감사가 손대지 않은 것

- **두 리포 모두 기존 파일 수정 0건.** 검증기 8개가 종료한 뒤 재확인했다 —
  Waple 은 미추적 추가분(직전 라운드 산출물 + 이 문서)뿐이고 추적 파일 변경 0건,
  RE 저장소는 감사 **이전과 정확히 같은 14파일**이다.
- **커밋·푸시·스태시 0건.**
- 검증 과정의 실행 산출물(python 이식 스크립트, 합성 매니페스트, 합성 로그)은 전부 스크래치패드에 뒀다.
  게이트 19종 실행 뒤 `git status --porcelain` 이 실행 전과 동일함을 확인했다
  (`scripts/spec/__pycache__/*.pyc` 는 gitignore 대상).
- **이 문서는 `FUN_140…` 토큰을 쓰지 않는다** — §6.3-5 의 이유이고, 의도적이다.

---

**구성**: 라운드 1 서브시스템 14레인 + 라운드 2 횡단 렌즈 14레인 + 중복 제거(118건) +
라운드 3 적대적 검증기 8개 + 종합 1 = **37에이전트 4라운드**.

> **[한계 — 라운드 1 은 12/14 레인만 돌았다]** `R1:render-3d`(WapleRender 3D·라이팅·포스트프로세스)와
> `R1:app-external`(외부연동·라이브러리 영속화·`WapleSaver`) 두 레인이 **스톨로 실패**해 산출 0건이다.
> 그 두 담당 영역은 이 문서에서 **라운드 2 렌즈가 지나간 만큼만** 덮였다 — 서브시스템 축의 정독은 없었다.
> (라운드 2 는 14/14 전부 완주했다.) 두 영역의 직전 라운드 원문은
> `docs/audit-r2-lanes/lane06-3d-bloom.md` 와 `lane10-library-saver.md` 에 있고,
> 이 문서 작성 후 보충 레인 2개를 따로 돌렸고 **그 결과는 §3.8 에 반영했다**(신규 10건).
검증기는 각 발견의 좌표·재현·영향·기지 대조를 처음부터 다시 밟았고, 상위 발견은
디스어셈블·python 이식·바이너리 덤프·`git log -S` 로 재현했다. 코드 변경 0건.