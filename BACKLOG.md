# Waple 백로그

> 2026-07-10 확정: 코퍼스(실물 460종) 기준 기능 완성 — scene 170/170 마운트, 시각 회귀 게이트
> 그린, 전 스위트 통과. 이 시점부터 **유지보수 모드**. 아래는 "해야 할 일"이 아니라
> **트리거가 오면 할 일**이다. 트리거 전에는 하지 않는다. 상세 근거는 [AUDIT.md](AUDIT.md)(감사
> 리포트, 2026-07-06)와 각 파일 위치 참조.

## UI 네이티브 재구축 (2026-07-12~13, 명시 요청으로 수행) — **완료·트랙 마감**

SP1′~5′ **전부 완료·판정 통과**: 통합 툴바 셸·그리드·상세 패널·Now Playing 바 / 필터 사이드바 +
즐겨찾기·폴더·평점·제거·메타 백필 / 디스플레이 화면(썸네일 모니터 박스) / 검색 탭(디스커버 레일
4종) + 창작마당 탭(무한 스크롤·다운로드 진행 UI·타일 평점, 레거시 WorkshopView 제거) / 설정 창
(grouped Form 5섹션) + 트레이 6항목 축소(일시정지 신설). 부수 수정: 액세서리 앱 mainMenu 부재로
전 텍스트 필드 ⌘V 불가 → 최소 편집 메뉴 장착. SP4′ 실데이터는 사용자 키 입력 후 실사용 확인.
macOS 최소 **14** 상향(`sceneBridgingOptions` 요구).
스펙: [2026-07-12-native-ui-redesign](docs/superpowers/specs/2026-07-12-native-ui-redesign.md),
플랜: [SP4′](docs/superpowers/plans/2026-07-13-sp4-discover-workshop.md) ·
[SP5′](docs/superpowers/plans/2026-07-13-sp5-settings-tray.md).

잔여 소항목 — 트리거: 해당 기능 사용 중 체감 시:
- "이미 설치됨" 배지(창작마당 타일) — publishedfileid ≠ project.json id 라 대조 키 부재로 스코프아웃. 필요 시 다운로드 시점 매핑 저장부터.
- 설정 창이 열려 있는 동안 적용 전환으로 바뀐 동영상 대상은 미러링하지 않음(재오픈 시 refresh) — 표시 문제, 체감 시.
- [PropertyEditorView.swift:55](Sources/Waple/PropertyEditorView.swift:55) deprecated 1-파라미터 `onChange` 1건(재구축 이전부터 존재) — 기회 시.

## 시각 충실도 — 트리거: 해당 씬을 실제 배경으로 쓸 때

| 항목 | 영향 | 메모 |
| --- | --- | --- |
| ~~3D 메시 라이팅~~ | **완료(P3/P4)** | 3D 메시·`LIGHTING` 원근 빌보드 Cook–Torrance PBR, 최대 4 `lpoint`, 6면 point-shadow atlas + 9-tap PCF 완료([Scene3DLighting.swift](Sources/WapleRender/Scene3DLighting.swift), [SceneRenderer3D.swift](Sources/WapleRender/SceneRenderer3D.swift)); 비-LIGHTING 빌보드는 기존 unlit 유지 |
| HDR/톤맵 | 대부분 해소 | **2D 씬 HDR ACES 톤맵 완료**(2026-07-13 Wave3, [HDRPostPass.swift](Sources/WapleRender/HDRPostPass.swift)) — 백화 해소(2802·2899 실측 정상). 잔여: ①이펙트-헤비 씬 빨강(2881, 아래) ②블룸 확산 refinement(F004: 소비 자체는 완료, 아래 참조) ③3D 씬 HDR(이후 `cb9b80c` 로 해소) ④라이트 intensity>1(실측 9.84) |
| 원근 태양계 라이팅·노멀맵 1건·스팟 콘 | 각 1씬 내외 | 2D 라이팅 SP 잔여 목록 |
| 파리티 상위 각개 진단 | 2902406982(0.37) 등 | 방법: rank.py 랭킹 → drawPlan prefix 이분 → SKIP 노브 |

**Scene Wave3 티어1 후속** (2026-07-13, 명시요청 수행 — B1 텍스트·A2 HDR톤맵·E1 composelayer·A4 유니폼 완료·main 머지). 잔여:
- ~~2881 이펙트-헤비 HDR 빨강~~ **해소** — 원인은 이펙트가 아니라 `f_compose` 파이프라인 포맷 불일치(bgra8 하드코딩 vs float acc)였고 SceneRenderer.swift 의 `accPixelFormat` 대입부(F003 정정: `715aaa6` 당시 674행이었으나 이후 커밋으로 하향 이동 — 2026-07-18 기준 [SceneRenderer.swift:964](Sources/WapleRender/SceneRenderer.swift:964), 라인은 향후도 드리프트 가능하니 `accPixelFormat` 으로 grep 권장)으로 수정(2026-07-13 리뷰 Critical). 11개 hdr+compose 씬(2881·2902 등)의 빨강/분홍 아티팩트 제거. 잔여 충실도만: 2881 오디오무입력 캡처 어두움·이펙트, 2902 삼각마스크(아래 항목)
- **E1 composelayer 삼각마스크 미재현** — 2902406982: 회색덩어리는 해소(화면좌표 f_compose), 그러나 三角模块N `_rt_imageLayerComposite_<id>` 그룹 자식 RT + clipping_mask 레이어간 샘플링 미구현
- ~~A2 블룸 확산 패스~~ **F004 정정(2026-07-18): "파싱만(미소비)"는 역-스테일 — LDR/HDR 블룸 모두 추출→블러→가산으로 구현·소비됨**([LDRBloomPass.swift](Sources/WapleRender/LDRBloomPass.swift)/[HDRBloomPass.swift](Sources/WapleRender/HDRBloomPass.swift), `SceneRenderer.swift` `sceneWantsLDRBloom`/`sceneWantsHDRBloom`, 커밋 24cee5f·a3d2afb·8be4b89·cb9b80c·c1584da). 잔여는 refinement 뿐: 피라미드 완전확산(현재 2단 ÷4/÷8 근사, WE 는 8단) · strength CPU 변환규칙 미결 · 3D-HDR 골든 완전 파리티 미달(선재 3D 콘텐츠 갭, 위 참조)
- **B1 텍스트 잔여** — 4.17× DPI로 8192px 래스터 가드 강화 → 긴 미줄바꿈 텍스트 소실(조용) 가능; 워드랩·MSDF·per-line 정렬·크기/위치 미세조정
- **A4 g_Color1~4 계열** — 그라디언트/파티클 다중색 유니폼(중립값 비단순), exact-name 스코프서 제외됨. 필요시 검토

## 잠재 결함 — 트리거: 실제 파일/사용에서 물릴 때

- ~~PuppetModel 2D cstring Latin-1 3곳~~ → **해소(F007 정정, 2026-07-18 확인)** — 공용 [BinaryReading.swift](Sources/WapleCore/BinaryReading.swift):readCString 이 이미 `String(decoding:as: UTF8.self)` 로 전면 통합돼 있고 [PuppetModel.swift](Sources/WapleCore/PuppetModel.swift) 의 머티리얼명·본 이름·애니메이션 name/mode 3곳 전부 이 헬퍼만 경유(직접 Latin-1 디코드 없음). CJK 경로(`materials/models/太空球/…`) mojibake 방지가 목적이며 이미 반영됨
- **combo Picker 값-타입 불일치** → 편집기 무선택 표시 ([WallpaperProperties.swift:67](Sources/WapleCore/WallpaperProperties.swift:67) — 옵션만 `type:""` 파싱)
- **GLSL vert/frag 공용 헬퍼의 스테이지별 하위 헬퍼 호출 리네임 누락** ([GLSLTranslator.swift:155](Sources/WapleCore/GLSLTranslator.swift:155)) — 2026-07-11 리뷰 #11, 추정 단계(재현 셰이더 미확보). 공용 헬퍼가 radial_blur식 스테이지별 computeUV 를 부르는 셰이더에서 frag 가 vert 버전을 받으면 조용한 오렌더 — 실물에서 관찰되면 착수
- **셰이더 멀티라인 매크로 "호출" 미확장** ([ShaderPreprocessor.swift](Sources/WapleCore/ShaderPreprocessor.swift) `spliceDefineContinuations` ponytail 주석) — `#define` 줄연속은 2026-07-11 해소, 인자가 여러 줄에 걸친 호출은 실입력 미확인이라 유보
- **FFmpeg `converted/` 캐시 무한 증가** ([FFmpegConverter.swift](Sources/WapleRender/FFmpegConverter.swift)) → 디스크가 차면 `VideoTextureExtractor.evictOldest` 재사용
- **볼륨/배속 변경 = 렌더러 전체 재장착**(재생 리셋) — F005 정정: 위치 참조가 스테일했음(`AppDelegate.swift` 에 setVideoVolume/Rate 는 존재한 적 없음, 네이티브 UI 재구축 때부터 [SettingsViewModel.swift](Sources/Waple/Surfaces/Settings/SettingsViewModel.swift) setVolume/setRate + [VideoSettings.swift](Sources/WapleRender/VideoSettings.swift) 가 배관 — 동작 설명 자체는 정확) → mkv/webm 실사용에서 거슬리면 `queue.volume`/`defaultRate` 라이브 반영으로
- ~~LibraryStore.remove 부재~~ → **해소(2026-07-12 SP2′)** — `remove(id:)` + 재생목록/모니터/즐겨찾기/폴더 orphan 정리
- 기타 low 항목은 [AUDIT.md](AUDIT.md) §1–3 참조 (inferStride 재검증, 리싱크 오인, LE 리더/cstring 중복 등)

## 제품화 — 트리거: 배포 결심

1. ~~notify() NSLog-only~~ → **부분 해소(2026-07-12 SP1′)**: 메인창 열림 시 창 내 배너(StatusBanner)로 표시. 잔여: 창 닫힘 상태의 오류는 여전히 NSLog only → UNUserNotification 승격은 배포 결심 시
2. 최초 실행 온보딩 + base-assets/ffmpeg 미설정 안내 → **F008 정정(2026-07-18): 온보딩·ffmpeg 안내 둘 다 해소** — 커밋 fb093cd/f214cc8/156740c(병합)로 최초 실행 1회 온보딩 시트가 완전히 구현·배선됨([OnboardingView.swift](Sources/Waple/Shell/OnboardingView.swift), `waple.onboardingCompleted` 플래그, 배경/공유에셋/ffmpeg 3항목 체크리스트 — ffmpeg 항목이 미설정 안내를 겸함). base-assets 조용한 저하도 부분 해소: 실제 필수 공유 에셋 miss 때 설정 경로를 StatusBanner로 앱 세션·설정 fingerprint당 1회 안내. 잔여: 메인창 닫힘 상태의 base-assets NSLog-only 안내뿐
3. CI 구축 — 현재 저장소에 CI 자체가 없음(`.github/workflows` 부재). `.saver`(WapleSaverView.m) clang 컴파일 스텝 포함(현재 `swift test` 커버리지 밖). **F400 실측(2026-07-18)**: 전체 1233 테스트 중 GPU(Metal 부재) 스킵 ~116사이트(32파일)·실물 코퍼스 부재 스킵 ~22사이트(14파일) — 렌더-출력/GT 계층(합성·블렌드·HDR/LDR 블룸·3D PBR·텍스트·스프라이트시트)이 사실상 전부 이 게이트 뒤라, CI 없이는 헤드리스/신규 체크아웃에서 "전건 green"이 이 개발자 1대 머신 상태에만 의존
4. LICENSE 결정 (README "미정") — **F016 IP 위생 잔여 3점**(개인배포는 저위험, 공개/상용 전환 시 검토): ①MIT 고지 미보존(RePKG 포맷 규약을 TexImage.swift 등이 인용하나 NOTICE/LICENSE 파일 없음 — 필드는 비저작 사실이라 실질 저위험) ②GPL(OWE/WaifuX) 개념 인용 주석 3곳의 소스 접근 페이퍼트레일 ③WE 독점 포맷 리버스엔지니어링 + UI 내 "Wallpaper Engine" 명목적 사용
5. 코드사인/공증, GUI 스모크, 워크샵 E2E
6. 접근성(그리드 타일 VoiceOver/키보드), 현지화(하드코딩 한국어 40+) — [AUDIT.md](AUDIT.md) §4–5

## 감사 2026-07-11 잔여 — 트리거: 해당 씬 사용/체감 시 (수정 26건은 완료·머지됨)

> 병렬 감사(12에이전트 리뷰 + 적대 검증 36건 판정)에서 CONFIRMED 26건은 수정 완료(git log
> "감사" 참조). 아래는 검증 후 **의도적으로 남긴** 것들.

| 항목 | 영향(실측) | 메모 |
| --- | --- | --- |
| 씬 스크립트 no-op API 주입 (`engine.audio`/`canvasSize`/`setTimeout`/`input.cursor`) | 63/54/39/29씬 | TextScriptEngine 국소 — audio 버퍼는 `currentSpectrum` 재사용, canvasSize는 실해상도, setTimeout은 runtime 만기 큐 |
| general `bloom`/`hdr` 후처리 | ON 26씬/17씬 | 파스 + threshold→blur→add 패스 1개 |
| `instanceoverride` 파티클 오버레이 | 133씬 | parseParticle에서 def 값 치환 1단계 |
| ApplyBlending 14–29 모드(내장 include) | 92종/141씬 | **BlendMSL.swift에 전 모드 MSL 이미 존재** → GLSL 내장 include로 이식만 |
| systemfont 별칭·검증 (`consolas`/`comicsans`/`sansserif`) | ~211인스턴스 | TextRasterizer 별칭 테이블 + PostScript명 검증 |
| REFRACT 파티클 굴절 | 129건/35씬 | 대형(배경 샘플 패스) — 씬 체감 시 |
| wind/gravity 파티클 외력, vortex_v2, scriptproperties 주입 | 110씬/1씬/130씬 | 파스+배선 |
| 번역기 폴백 강등 3건(`#if<TAB>` 정규화·`%=`·무공백 const) | 저빈도 | 검증 결과 컴파일실패→안전폴백(REFUTED) — 픽셀 무해, 폴백 회피용 |
| 성능: 비가시 레이어 효과체인 스킵, acc+blit 생략(스냅샷 1회 확인 필요), TexImage 스캔 할당, ScenePackage 무복사 파스, DXT 블록 할당 | — | 감사 계획서 3계층 성능표 참조 |
| 정리: 본체인 fold 6회·DXT 3벌·Process 헬퍼 3벌·JS 리터럴 4중·효과체인 루프 4중복·~~죽은 코드(resolveProjects, bitsRemaining, 미발행 이슈코드 8종, CLI 도움말)~~ **이슈코드 8종·CLI 도움말은 해소(F232/F235/F149, 2026-07-18)** | — | 기회 시(resolveProjects/bitsRemaining/fold/Process헬퍼/JS리터럴/효과체인루프 잔여) |

## 하네스 — 트리거: 게이트 오탐/소요가 거슬릴 때

- **벽시계(Date) 오염** — 씬 스크립트 JS `Date`가 미스텁이라 시계 텍스트 씬(회귀 FAIL 58 중 45건 보유)의 diff에 캡처 시각차가 섞임(실측: 3047405322 mean 13.05가 전부 시계였음, 2026-07-11 판독). 같은-분 셀프체크는 "결정"으로 오분류. 수정 방향: 캡처 경로에서 shims에 Date 고정 주입 또는 시계 스크립트 보유 씬을 lax 버킷으로
- 스냅샷 드리프트 2씬(3000562427, 3448290956) 부하 내성 — 순정에서도 요동하는 크로스-프로세스 비결정, 현재는 판독 시 제외 규약
- GT 인-테스트(debug, ~35분 추정)를 release `WapleCompat --capture/--compare` 게이트(6분)로 이관하고 debug GT 슬림화 검토
- 초대형 멀티페이지 스프라이트 스트리밍(6씬 정지 폴백 해제), scriptproperties 주입(중국 2패키지), TEXS 회전 실물 검증(코퍼스 0건)
- **F144: SnapshotCompare 의 결정/비결정 임계 선택이 베이스라인 캡처 시점 1회 기록에 영구 고정** — 매 `--compare` 마다 현재 빌드 자기일관성을 재확인하지 않아 (a) 원래 결정적이던 씬이 회귀로 비결정이 돼도 별도 신호 없음 (b) 캡처 당시 살짝 넘겨 비결정 분류된 씬은 그 뒤 영원히 관대한 임계만 적용받음. 수정 방향: `--compare` 도 씬마다 2회 캡처해 자기-diff 재확인(임계 재분류) — 단 비교 소요가 2× 증가하므로 트리거(오탐 체감) 대기
- **F146: 골든 베이스라인 `3470948192.png` 가 NaN-퇴화 렌더를 봉인**했던 근본원인(text3DControllers/eval3DOrder 순서 — 비가시 노드 shared 생산이 소비보다 늦게 평가)은 배치6(`7014b20`, 프라이밍 패스)에서 해소됨. 잔여는 순수 아티팩트 재생성뿐 — `waple-baselines/`(리포 밖) 골든을 `WapleCompat --capture` 로 재생성하면 워프 지오메트리가 복원된 최신본으로 갱신됨(코드 변경 불필요)
- **F402/F403: RealPackagesGroundTruthTests 의 luma 기준선이 처분성 `/tmp/waple_gt`에 저장되고(리포 밖·비커밋·머신별) 드리프트는 NSLog 경고뿐**(하드 fail 아님, 의도적 선택 — 씬은 시간 함수라 오탐 위험) — 하드 오라클은 "마운트 무크래시+PNG 존재"뿐이라 완전 검정/깨진 프레임도 통과한다. `git ls-files`상 커밋된 골든이 0건이라 실물 코퍼스 시각 회귀는 사람이 수동 파이프라인(`WapleCompat --capture/--compare`)을 돌리거나 아무도 안 읽는 로그로만 감지됨. 수정 방향: luma_baseline.json 을 리포에 커밋(또는 waple-baselines/ 로 이관)하고 CI(위 3번 항목)와 묶어 자동 시각-회귀 게이트로 승격
- **F398: 벽시계 결합 타이밍 패턴이 스위트에 산재** — 고정시간 `RunLoop.run(until:)` fire-then-assert 33사이트(Web/Video/Media 비동기) + `MediaPollerTests`의 `Thread.sleep(6s)`+`run(until:5.4s)`(단일 테스트 ~5.4s 소요, 폴 간격·sleep·run 상호의존)가 고부하/느린 머신에서 오탐 위험. 대조로 견고한 폴-until 패턴(`RealVideosGroundTruthTests` deadline 폴, `WebHardPauseTests` waitUntil)도 이미 공존 — 팀이 견고 패턴을 알면서 일부만 적용한 상태. 수정 방향: 33사이트를 견고 폴 패턴으로 일괄 전환(대규모 — 개별 파일 접촉 다수, 전수 재실행 검증 필요해 이 배치 범위 밖)
- **F399: REFRACT 파티클 셰이더(2D pf_refract)가 MSL 컴파일 여부만 테스트되고 실제 굴절 픽셀 출력 회귀가 없음** — `ParticleShadersTests.testCompilesMSL` 1건뿐, `SceneParticleRenderTests`/`Scene3DParticleTests` 어디에도 refract 매칭 0건. 수정 방향: F406 과 동일 캡처 패턴(배경 텍스처 위 굴절 파티클 픽셀 오프셋 확인)으로 신규 유닛 — 대형(배경 샘플 패스 셋업) 이라 씬 체감 시 착수
- **F406 잔여: 3D 렌더 픽셀 커버리지 홀 — text3D 글리프·spritesheet 프레임·RIM/SHADINGGRADIENT 셰이딩** — colorBlendMode(additive/normal, 2026-07-18 착지) 외 나머지는 이 배치 범위 밖(스코프 지시: 1~2개만). 패턴은 이미 확립됨(`Scene3DRenderCorrectnessTests.captureBlendModeCenterPixel`/`captureFullscreenCompositeCenterPixel` — 씬을 디스크에 마운트해 `captureFrames`+`colorAt` 로 픽셀 확인)
