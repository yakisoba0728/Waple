# Waple 백로그

**현재 상태** (2026-07-31): 유지보수 모드. 테스트 2,125개 · 실패 0 · CI 그린(`macos-26`).
아래 항목은 "해야 할 일"이 아니라 **트리거가 오면 할 일**이다. 트리거 전에는 하지 않는다.

이 문서는 **날짜순 기록**이다. `>` 인용 블록과 취소선(~~항목~~)은 그 시점의 사실이며 이후
해소된 것도 근거 보존을 위해 남겨둔다. 지금 열려 있는 것만 보려면 아래 표에서 섹션으로 가라.

| 섹션 | 트리거 | 주요 잔여 |
| --- | --- | --- |
| [시각 충실도](#시각-충실도) | 해당 씬을 실제 배경으로 쓸 때 | H7 Ultra EOTF · E1 삼각마스크 · 텍스트 워드랩 · LDR 블룸 피라미드화 · g_Color1~4 |
| [잠재 결함](#잠재-결함) | 실제 파일·사용에서 물릴 때 | combo Picker 값-타입 · ffmpeg 캐시 증가 · 볼륨/배속 라이브 반영 |
| [제품화](#제품화) | 배포 결심 | Developer ID 공증 · 접근성 · 현지화(하드코딩 한국어 40+) |
| [감사 2026-07-11 잔여](#감사-2026-07-11-잔여) | 해당 씬 사용·체감 시 | REFRACT 파티클 · wind/gravity 외력 · M6 사운드 3D |
| [copybackground 후속](#copybackgroundfalse-후속) | 3D 컴포지션 레이어 사용 시 | 3D 경로 비대칭 · 파스·보존 전용 필드 소비 |
| [하네스](#하네스) | 게이트 오탐·소요가 거슬릴 때 | F402/F403 골든 미커밋 · F398 벽시계 결합 33사이트 · F144 임계 고정 |

상세 근거는 [AUDIT.md](AUDIT.md)(감사 리포트, 2026-07-06 — 이력)와 [docs/README.md](docs/README.md) 참조.

---

> 2026-07-10 확정: 코퍼스(실물 460종) 기준 기능 완성 — scene 170/170 마운트, 시각 회귀 게이트
> 그린, 전 스위트 통과. 이 시점부터 **유지보수 모드**. 아래는 "해야 할 일"이 아니라
> **트리거가 오면 할 일**이다. 트리거 전에는 하지 않는다. 상세 근거는 [AUDIT.md](AUDIT.md)(감사
> 리포트, 2026-07-06)와 각 파일 위치 참조.

> 2026-07-21~22: 씬 구현 심층 감사·수정 라운드(명시 요청으로 수행) — 코퍼스 정적 분석으로
> 109건 발견, 영역별 워크트리 스웜으로 전량 처리. 전 스위트 1,677개 그린·GT 170/170.
> 수정·개선 내역과 잔여 후속 과제는 [docs/scene-deep-fix-2026-07-21.md](docs/history/scene-deep-fix-2026-07-21.md) 참조.

> 2026-07-25~26: 스웜 감사 로드맵(H1–H8/M1–M10) 마감 라운드 — H1–H6·H8·M1–M5·M7–M10 전량
> 구현·검증(워크트리 스웜 3개 병렬: H6 bloom 8레벨·H4 3D REFRACT·H1 스키닝 커스텀 셰이더).
> 잔여는 H7(Ultra EOTF/color grading)·M6(사운드 3D) 뿐. 상태 확정·트레이드오프·실씬 A/B
> 게이트는 [docs/roadmap-h1-h8-closeout-2026-07-26.md](docs/history/roadmap-h1-h8-closeout-2026-07-26.md) 참조.
> 전 타겟 스위트 0 failures(main `4f2779a`).

## UI 네이티브 재구축 (2026-07-12~13, 명시 요청으로 수행) — **완료·트랙 마감**

SP1′~5′ **전부 완료·판정 통과**: 통합 툴바 셸·그리드·상세 패널·Now Playing 바 / 필터 사이드바 +
즐겨찾기·폴더·평점·제거·메타 백필 / 디스플레이 화면(썸네일 모니터 박스) / 검색 탭(디스커버 레일
4종) + 창작마당 탭(무한 스크롤·다운로드 진행 UI·타일 평점, 레거시 WorkshopView 제거) / 설정 창
(grouped Form 5섹션) + 트레이 6항목 축소(일시정지 신설). 부수 수정: 액세서리 앱 mainMenu 부재로
전 텍스트 필드 ⌘V 불가 → 최소 편집 메뉴 장착. SP4′ 실데이터는 사용자 키 입력 후 실사용 확인.
macOS 최소 **14** 상향(`sceneBridgingOptions` 요구).
스펙: [2026-07-12-native-ui-redesign](docs/history/specs/2026-07-12-native-ui-redesign.md),
플랜: [SP4′](docs/history/plans/2026-07-13-sp4-discover-workshop.md) ·
[SP5′](docs/history/plans/2026-07-13-sp5-settings-tray.md).

잔여 소항목 — 트리거: 해당 기능 사용 중 체감 시:
- "이미 설치됨" 배지(창작마당 타일) — publishedfileid ≠ project.json id 라 대조 키 부재로 스코프아웃. 필요 시 다운로드 시점 매핑 저장부터.
- 설정 창이 열려 있는 동안 적용 전환으로 바뀐 동영상 대상은 미러링하지 않음(재오픈 시 refresh) — 표시 문제, 체감 시.
- [PropertyEditorView.swift:55](Sources/Waple/PropertyEditorView.swift:55) deprecated 1-파라미터 `onChange` 1건(재구축 이전부터 존재) — 기회 시.

## 시각 충실도

*트리거: 해당 씬을 실제 배경으로 쓸 때.*

| 항목 | 영향 | 메모 |
| --- | --- | --- |
| ~~3D 메시 라이팅~~ | **완료(P3/P4)** | 3D 메시·`LIGHTING` 원근 빌보드 Cook–Torrance PBR, 최대 4 `lpoint`, 6면 point-shadow atlas + 9-tap PCF 완료([Scene3DLighting.swift](Sources/WapleRender/Scene3DLighting.swift), [SceneRenderer3D.swift](Sources/WapleRender/SceneRenderer3D.swift)); 비-LIGHTING 빌보드는 기존 unlit 유지 |
| HDR/톤맵 | 대부분 해소 | **2D 씬 HDR ACES 톤맵 완료**(2026-07-13 Wave3, [HDRPostPass.swift](Sources/WapleRender/HDRPostPass.swift)) — 백화 해소(2802·2899 실측 정상). 잔여: ①이펙트-헤비 씬 빨강(2881, 아래) ②블룸 확산 refinement(F004: 소비 자체는 완료, 아래 참조) ③3D 씬 HDR(이후 `cb9b80c` 로 해소) ④라이트 intensity>1(실측 9.84) |
| 원근 태양계 라이팅·노멀맵 1건·스팟 콘 | 각 1씬 내외 | 2D 라이팅 SP 잔여 목록 |
| 파리티 상위 각개 진단 | 2902406982(0.37) 등 | 방법: rank.py 랭킹 → drawPlan prefix 이분 → SKIP 노브 |
| **X-⑤ g_TexelSize = 이펙트 dst 기준(채택안)** | bokeh_blur 12씬 블러 폭 | WE gaussian.vert `ratio = g_TexelSize * g_Texture0Resolution` 를 근거로 삼았으나 이 근거는 판별력 0(ratio 가 ratio.y/ratio.x 로만 소비돼 구(1/tex0)·신(1/dst) 해석 모두 값 1) — "실측으로 확정" 아니라 채택된 정본. 레이어 커스텀 셰이더 경로는 여전히 구 tex0 근사(규약 이원화, 무회귀 우선으로 스코프 밖 유지). 라이브 A/B 판독 항목: bokeh_blur 사용 12씬에서 블러 폭이 옛 tex0 근사(4× 과대) 대비 실제로 좁아졌는지 육안 확인. 코드 근거는 [GLSLTranslator.swift](Sources/WapleCore/GLSLTranslator.swift) g_TexelSize 치환부·[SceneRendererFrameEncoder.swift](Sources/WapleRender/SceneRendererFrameEncoder.swift) targetRes 관련 주석 |

**Scene Wave3 티어1 후속** (2026-07-13, 명시요청 수행 — B1 텍스트·A2 HDR톤맵·E1 composelayer·A4 유니폼 완료·main 머지). 잔여:
- ~~2881 이펙트-헤비 HDR 빨강~~ **해소** — 원인은 이펙트가 아니라 `f_compose` 파이프라인 포맷 불일치(bgra8 하드코딩 vs float acc)였고 SceneRenderer.swift 의 `accPixelFormat` 대입부(F003 정정: `715aaa6` 당시 674행이었으나 이후 커밋으로 하향 이동 — 2026-07-18 기준 [SceneRenderer.swift:964](Sources/WapleRender/SceneRenderer.swift:964), 라인은 향후도 드리프트 가능하니 `accPixelFormat` 으로 grep 권장)으로 수정(2026-07-13 리뷰 Critical). 11개 hdr+compose 씬(2881·2902 등)의 빨강/분홍 아티팩트 제거. 잔여 충실도만: 2881 오디오무입력 캡처 어두움·이펙트, 2902 삼각마스크(아래 항목)
- **E1 composelayer 삼각마스크 미재현** — 2902406982: 회색덩어리는 해소(화면좌표 f_compose), 그러나 三角模块N `_rt_imageLayerComposite_<id>` 그룹 자식 RT + clipping_mask 레이어간 샘플링 미구현
- ~~A2 블룸 확산 패스~~ **F004 정정(2026-07-18): "파싱만(미소비)"는 역-스테일 — LDR/HDR 블룸 모두 추출→블러→가산으로 구현·소비됨**([LDRBloomPass.swift](Sources/WapleRender/LDRBloomPass.swift)/[HDRBloomPass.swift](Sources/WapleRender/HDRBloomPass.swift), `SceneRenderer.swift` `sceneWantsLDRBloom`/`sceneWantsHDRBloom`, 커밋 24cee5f·a3d2afb·8be4b89·cb9b80c·c1584da). 잔여는 refinement 뿐: **HDR 피라미드는 H6(2026-07-25~26)에서 8레벨로 완료**됐으므로 "2단 ÷4/÷8 근사" 표기는 무효 — 현재 `bloomhdriterations` 를 받아 `min(8, 허용 mip 수)` 로 클램프하고 2단 미만이면 단일레벨로 폴백한다([HDRBloomPyramidPass.swift](Sources/WapleRender/HDRBloomPyramidPass.swift) `levels` 기본값 8). 실제 잔여는 ①LDR 경로는 아직 피라미드가 아니라 3-패스([LDRBloomPass.swift](Sources/WapleRender/LDRBloomPass.swift)) ②피라미드 upsample blend state 미결(`HDRBloomPass.swift:46`) ③strength CPU 변환규칙 미결 ④3D-HDR 골든 완전 파리티 미달(선재 3D 콘텐츠 갭, 위 참조)
- **B1 텍스트 잔여** — 4.17× DPI로 8192px 래스터 가드 강화 → 긴 미줄바꿈 텍스트 소실(조용) 가능; 워드랩·MSDF·per-line 정렬·크기/위치 미세조정
- **W-① 3D 씬 텍스트 빌보드 잔여**(2026-07-27, `08058c9`로 world-placement 배선 완료 — [SceneRenderer3D.swift](Sources/WapleRender/SceneRenderer3D.swift)) — origin/scale/angles/visible 만 attachScripts, 아래 2건은 의도적 미부착·미구현:
  (a) **alpha/color 프로퍼티 스크립트 미부착** — 실측 3509243656 UI 패널이 dd/yp/num 얽힌 shared 상태머신이라 부착 시 무관 이미지 빌보드(id=449)가 잘못된 타이밍에 오노출되고 캡처 셀프체크가 비결정(frac 0.0176~0.025, 재현 가능)이 됨. 필요 시 캡처-세이프 격리(예: alpha 스크립트 보유 text 는 빌보드 자체를 만들지 않는 draw-gate) 부터 검토.
  (b) **텍스트 '내용' 동적 재래스터 미지원** — F309 프라이밍이 확정한 1회 평가값(controllerOf[uid].last)만 래스터, update() 가 이후 콘텐츠를 바꿔도 화면엔 반영 안 됨(위치/스케일/회전/가시성만 매프레임 애니). 코퍼스 5씬(3470948192·3477054430·3589454154·3662790108·3737268876) A/B 캡처(1920×1080, main-6526db1 대비)로 블라스트 반경 확인 완료 — 3662790108(76텍스트)·3477054430(1)·3737268876(4) 는 byte-identical(새 빌보드가 캡처 시점 비가시), 3589454154·3470948192 는 소폭 개선(정보 텍스트 신규 노출, 왜곡 없음). 상세: [docs/scene-render-audit-2026-07-26.md](docs/history/scene-render-audit-2026-07-26.md) "3D/칸 메라/투영 잔여" 참조.
- **A4 g_Color1~4 계열** — 그라디언트/파티클 다중색 유니폼(중립값 비단순), exact-name 스코프서 제외됨. 필요시 검토
- **F4-polish① 텍스트 anchor/padding/backgroundbrightness 렌더 소비** (2026-07-28 파스 착지) — `SceneTextLayer.anchor`/`padding`/`backgroundBrightness` 3필드 파스·보존 완료([SceneDocument.swift](Sources/WapleCore/SceneDocument.swift) parseText). anchor 비-none 70건(코퍼스 1642 오브젝트 중)·padding 전건·backgroundbrightness 1474건은 값이 있지만 opaqueBackground 와 동형으로 **렌더 소비는 아직 없음**(배경박스 최소구현 정책 유지 — outline 만 TextRasterizer 가 그림). 배경박스 자체를 그리는 후속이 착수되면 이 3필드로 앵커 오프셋·패딩 여백·밝기 배율을 함께 적용할 것.
- **F4-polish② Forward+ 라이팅 유니폼 인덱스 배열 피드** (2026-07-28 인식-전용 착지) — `g_LPoint_*`/`g_LSpot_*`/`g_LTube_*`/`g_LDirectional_*`/`g_LFeature_Shadow*` 를 `GLSLTranslator.isEngine` 에 등재해 머티리얼 오분류(g_TexelSize 동형 사고)만 차단([GLSLTranslator.swift](Sources/WapleCore/GLSLTranslator.swift) isEngine/engineReplacement). WE 실선언은 배열(`g_LPoint_Color[LIGHTS_POINT]`)·사용부는 `[l].rgb` 인덱스 접근인데, 이번 등재의 대체값(0 벡터/항등)은 비-배열 스칼라라 인덱스 구독엔 컴파일 안전하지 않음 — 로컬 코퍼스 460씬이 `LIGHTS_POINT/SPOT/TUBE/DIRECTIONAL` 콤보를 전혀 참조하지 않아(`ShaderPreprocessor.swift:38-40`) 이 블록이 항상 전처리로 제거되므로 오늘 시점 도달 0건. 콤보 지원이 실제로 켜지는 씬이 나타나면 인덱스 가능한 constant 배열 피드로 교체할 것(네이티브 Scene3DLighting 은 이미 구현돼 있어 스코프는 커스텀 셰이더 경로 한정).

## 잠재 결함

*트리거: 실제 파일·사용에서 물릴 때.*

- ~~PuppetModel 2D cstring Latin-1 3곳~~ → **해소(F007 정정, 2026-07-18 확인)** — 공용 [BinaryReading.swift](Sources/WapleCore/BinaryReading.swift):readCString 이 이미 `String(decoding:as: UTF8.self)` 로 전면 통합돼 있고 [PuppetModel.swift](Sources/WapleCore/PuppetModel.swift) 의 머티리얼명·본 이름·애니메이션 name/mode 3곳 전부 이 헬퍼만 경유(직접 Latin-1 디코드 없음). CJK 경로(`materials/models/太空球/…`) mojibake 방지가 목적이며 이미 반영됨
- **combo Picker 값-타입 불일치** → 편집기 무선택 표시 ([WallpaperProperties.swift:67](Sources/WapleCore/WallpaperProperties.swift:67) — 옵션만 `type:""` 파싱)
- **GLSL vert/frag 공용 헬퍼의 스테이지별 하위 헬퍼 호출 리네임 누락** ([GLSLTranslator.swift:155](Sources/WapleCore/GLSLTranslator.swift:155)) — 2026-07-11 리뷰 #11, 추정 단계(재현 셰이더 미확보). 공용 헬퍼가 radial_blur식 스테이지별 computeUV 를 부르는 셰이더에서 frag 가 vert 버전을 받으면 조용한 오렌더 — 실물에서 관찰되면 착수
- **셰이더 멀티라인 매크로 "호출" 미확장** ([ShaderPreprocessor.swift](Sources/WapleCore/ShaderPreprocessor.swift) `spliceDefineContinuations` ponytail 주석) — `#define` 줄연속은 2026-07-11 해소, 인자가 여러 줄에 걸친 호출은 실입력 미확인이라 유보
- **FFmpeg `converted/` 캐시 무한 증가** ([FFmpegConverter.swift](Sources/WapleRender/FFmpegConverter.swift)) → 디스크가 차면 `VideoTextureExtractor.evictOldest` 재사용
- **볼륨/배속 변경 = 렌더러 전체 재장착**(재생 리셋) — F005 정정: 위치 참조가 스테일했음(`AppDelegate.swift` 에 setVideoVolume/Rate 는 존재한 적 없음, 네이티브 UI 재구축 때부터 [SettingsViewModel.swift](Sources/Waple/Surfaces/Settings/SettingsViewModel.swift) setVolume/setRate + [VideoSettings.swift](Sources/WapleRender/VideoSettings.swift) 가 배관 — 동작 설명 자체는 정확) → mkv/webm 실사용에서 거슬리면 `queue.volume`/`defaultRate` 라이브 반영으로
- ~~LibraryStore.remove 부재~~ → **해소(2026-07-12 SP2′)** — `remove(id:)` + 재생목록/모니터/즐겨찾기/폴더 orphan 정리
- 기타 low 항목은 [AUDIT.md](AUDIT.md) §1–3 참조 (inferStride 재검증, 리싱크 오인, LE 리더/cstring 중복 등)

## 제품화

*트리거: 배포 결심.*

1. ~~notify() NSLog-only~~ → **부분 해소(2026-07-12 SP1′)**: 메인창 열림 시 창 내 배너(StatusBanner)로 표시. 잔여: 창 닫힘 상태의 오류는 여전히 NSLog only → UNUserNotification 승격은 배포 결심 시
2. 최초 실행 온보딩 + base-assets/ffmpeg 미설정 안내 → **F008 정정(2026-07-18): 온보딩·ffmpeg 안내 둘 다 해소** — 커밋 fb093cd/f214cc8/156740c(병합)로 최초 실행 1회 온보딩 시트가 완전히 구현·배선됨([OnboardingView.swift](Sources/Waple/Shell/OnboardingView.swift), `waple.onboardingCompleted` 플래그, 배경/공유에셋/ffmpeg 3항목 체크리스트 — ffmpeg 항목이 미설정 안내를 겸함). base-assets 조용한 저하도 부분 해소: 실제 필수 공유 에셋 miss 때 설정 경로를 StatusBanner로 앱 세션·설정 fingerprint당 1회 안내. 잔여: 메인창 닫힘 상태의 base-assets NSLog-only 안내뿐
3. ~~CI 구축~~ → **해소(2026-07-28)**: `.github/workflows/ci.yml` 추가(GitHub Actions — `swift build` + `swift test` + `.saver`(WapleSaverView.m) clang 번들 컴파일 스텝 포함). 첫 푸시 후 활성화. 잔여: 실물 코퍼스 부재 스킵(F400, ~22사이트)은 CI 에서도 동일 — 실물 시각 회귀 골든은 계속 수동 파이프라인(F402/F403 참조)
   - **2026-07-30 갱신(CI 그린화 + 시간 절감)**: macos-14 는 deprecated 이고 이미지 최신 Xcode 가 16.2(Swift 6.0.3) — 테스트 타깃의 바이트 연결 `+` 체인이 "unable to type-check this expression in reasonable time" 로 CI 전용 컴파일 실패(런 30537582675, Test 스텝 6m55s 전량 컴파일). 조치 ①러너 macos-26(Xcode 26.x, 로컬 Swift 6.4 와 정합) ②원인식 구조 제거: `bytes(_:)`/`tag(_:)`/`i32b(_:)` 가변인자 헬퍼로 Tex 픽스처 60여 곳 치환(바이트 동일) + 최신 툴체인에서도 1.2초/1.3초를 태우던 `Model3D.swift` 폴백 스트라이드·`NativeBCUploadTests` 혼합 Data/[UInt8] 체인 해소 ③워크플로: 문서 전용 푸시 `paths-ignore`, `swift build --build-tests` + `swift test --skip-build` 분리(컴파일/실행 시간 분리 계측), `workflow_dispatch`, timeout 90→40, 실패 요약 grep 을 실제 실패 단언 우선으로(종전 "failed" 패턴은 정상 진단문에 파묻혔다). **.build 캐시 제거**(단 "무용" 은 실측되지 않았다 — 측정 불능이 정확: Build 적중 53s vs 미적중 57·59·77·119s 로 동일 조건 변동폭 62s 가 캐시 차이를 압도. 제거 근거는 zero-dep·mtime 무효화라는 이론 + 동일 키 재저장의 오해 소지 로그 + 135MB 비용이고, 판단하려면 조건별 5런 중앙값 필요)
   - **결과**: 잡 7m48s(테스트 0개 실행) → **4m5s 그린**(러너 macOS 26.4·3코어·7GB·Swift 6.3.2 / Build 53~59s + .saver 4s + Test 140~164s, 2125 테스트·46 스킵). CI 가 잡아낸 테스트 결함 2건(ffmpeg 부재 분기의 F556 이전 낡은 단언, 3코어에서만 깨지는 WebHardPause 타이밍 창)은 커밋 3863411 에서 수정 — 프로덕션 무변경. 다음 지렛대는 `swift test --parallel`(Test 스텝 ~160s 단축)이나 3코어·타이밍 테스트 다수라 플레이크 위험이 커 미적용
4. ~~LICENSE 결정 (README "미정")~~ → **해소(2026-07-28)**: MIT 로 결정 — LICENSE 신설 + README 라이선스 섹션 갱신. F016 잔여 3점도 해소: ①NOTICE 신설로 RePKG(MIT, © 2019 notscuffed) 고지 보존·인용 위치 명기 ②GPL(OWE/WaifuX) 인용 주석 3곳 전수 개념/관행 참조 판정(코드 이식 없음) — NOTICE 에 페이퍼트레일 기재 ③WE 상표 명목적 사용·상호운용성 목적 리버스엔지니어링 고지 NOTICE 명기(README 상단 비공식/상표 고지는 기존 유지)
5. 코드사인/공증, GUI 스모크, 워크샵 E2E
   - **릴리스 파이프라인 macos-26 실검증 완료(2026-07-30, 태그 `v0.1.0-beta.2` / 런 30547526365, 3m15s)**: `package-app.sh` 전 구간(plist·`.saver` clang·중첩 포함 ad-hoc `codesign --deep`·`hdiutil` UDZO) 통과, 태그→버전 규약 확인(`v0.1.0-beta.2` → plist `0.1.0`, CFBundleVersion=런번호), `-` 포함 태그는 즉시 prerelease. 산출물 직접 검증: sha256 노트값 일치·DMG 마운트·`Waple.saver`/`Waple.icns` 동봉·app·saver 모두 arm64·`codesign --verify --deep --strict` 통과. 릴리스 노트는 영어 + ad-hoc 일 때만 Gatekeeper 절. 잔여는 Developer ID/공증(유료 계정 = 배포 스코프C)뿐이며, 그때 `.p12` 키체인 임포트 스텝을 워크플로에 추가해야 한다. **주의: `workflow_dispatch` 로 release.yml 을 시험할 수 없다**(`GITHUB_REF_NAME`=main → 버전 추출 붕괴) — 버릴 프리릴리즈 태그를 쓸 것
6. 접근성(그리드 타일 VoiceOver/키보드), 현지화(하드코딩 한국어 40+) — [AUDIT.md](AUDIT.md) §4–5

## 감사 2026-07-11 잔여

*트리거: 해당 씬 사용·체감 시. CONFIRMED 26건은 이미 수정·머지됨.*

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
| wind/gravity 파티클 외력, vortex_v2, scriptproperties 주입 | 110씬/1씬/130씬 | 파스+배선. S1-formats③ 재실측(2026-07-27): `gravitystrength` 필드 110/169씬(65%, 거의 전부 1.0·방향(0,-1,0)), `windenabled=true` 활성 1/169 — 적용 공식 미확정이라 포맷대조 레인 스코프 밖 보류, 착수 시 이 비율을 우선순위 근거로 사용 |
| 번역기 폴백 강등 3건(`#if<TAB>` 정규화·`%=`·무공백 const) | 저빈도 | 검증 결과 컴파일실패→안전폴백(REFUTED) — 픽셀 무해, 폴백 회피용 |
| 성능: 비가시 레이어 효과체인 스킵, acc+blit 생략(스냅샷 1회 확인 필요), TexImage 스캔 할당, ScenePackage 무복사 파스, DXT 블록 할당 | — | 감사 계획서 3계층 성능표 참조 |
| 정리: 본체인 fold 6회·DXT 3벌·Process 헬퍼 3벌·JS 리터럴 4중·효과체인 루프 4중복·~~죽은 코드(resolveProjects, bitsRemaining, 미발행 이슈코드 8종, CLI 도움말)~~ **이슈코드 8종·CLI 도움말은 해소(F232/F235/F149, 2026-07-18)** | — | 기회 시(resolveProjects/bitsRemaining/fold/Process헬퍼/JS리터럴/효과체인루프 잔여) |

## copybackground:false 후속

*트리거: 3D 컴포지션 레이어 사용, 또는 파티클·텍스트의 copyBackground 소비 착수 시.*

- **3D 경로 비대칭**: `SceneRenderer3D` 의 isFrameBuffer 빌보드 합성(`:1435`/`:1839` 부근)은 `copyBackground` 필드를
  전혀 읽지 않는다 — 2D `runFrameBufferLayer` 는 이번에 acc 블릿/투명 클리어 분기 + `_rt_FullFrameBuffer` aux
  슬롯 분리(fullFrame)를 소비하도록 고쳤지만, 3D 씬의 `copybackground:false` 컴포지션 레이어는 여전히 종전
  (항상 acc 합성) 거동이다. 회귀는 아니다(2D 만 고쳤으므로 3D 는 그대로) — 다만 동일 결함이 3D 에 남아있다는
  사실 기록. 3D 씬에서 실제로 체감되면 2D 와 동형 분기(fullFrame 분리 포함)를 이식할 것.
- **SceneParticle/SceneTextLayer 의 copyBackground 기본값도 함께 true 로 뒤집혔으나 아직 미소비**(둘 다
  `isFrameBuffer` 자체가 없어 렌더러가 이 필드를 읽는 지점이 없다 — 파스·보존 전용). 향후 이 두 타입에
  프레임버퍼/컴포지션 소비부가 추가되면 "기본 true" 전제를 반드시 재검토할 것(레이어와 동일 근거 — WE shim
  기본값·코퍼스 실측 255×true vs 56×false — 를 재확인 없이 그대로 가정하지 말 것).
- **생성형(오디오) 이펙트 콘텐츠 손실 가능성 — 코퍼스 실측으로 게이트 미도입 결정**: 코퍼스(169씬) 전수
  스캔 결과 `copyBackground:false` + `isFrameBuffer` 조합·이펙트 보유 22개 오브젝트/15씬 중, 활성 상태로
  실제 렌더되는 `Simple_Audio_Bars`/`enhanced_simple_audio_bars` 인스턴스는 3건뿐(3351179520·3543159422·
  3517818807) — 셋 다 `TRANSPARENCY` 콤보 미지정으로 셰이더 기본값(`REPLACE`=1, `alpha = bar * u_BarOpacity`
  — 입력 알파와 무관하게 자기결정)이라 투명 입력에도 콘텐츠 손실이 없다(shader-math 확정 + `WapleCompat
  --compare` 베이스라인 main-6526db1 대비 캡처로 재확인). **정정**: 애초 "3299228616 'Bar 3'가
  TRANSPARENCY==INTERSECT 로 콘텐츠를 잃는다" 는 주장으로 `GPULayer.usesAudio` 기반 좁은 게이트를 구현했다가
  같은 라운드에서 재검증 중 오귀속임이 드러나 되돌렸다 — 실제로는 (a) 그 TRANSPARENCY:4/INTERSECT 콤보는
  "Bar 3"(id 387)가 아니라 인접한 별개 오브젝트 "Bar 2"(id 678)의 것이었고, (b) "Bar 2"·"Bar 3" 양쪽 모두
  해당 Simple_Audio_Bars 패스는 `visible:{user:{condition,name:"barstyle"},value:false}` 로 이 배포본에서
  정적으로 꺼져 있어(파스 시점에 `SceneDocument.parseEffects` 가 드롭) 애초에 렌더되지 않는다. 즉 현재
  코퍼스엔 이 문제를 촉발하는 실제 씬이 없다 — "트리거 전엔 하지 않는다" 원칙에 따라 코드 게이트는
  두지 않음. **다만 구조적 위험 자체는 실재**: `TRANSPARENCY==INTERSECT`(4)/`SUBTRACT`(3)/`PRESERVE`(0)
  콤보를 쓰는 오디오 생성형 이펙트가 향후 코퍼스에 authored 되면 투명 입력에서 콘텐츠(alpha)가 소실될
  수 있다(수식: INTERSECT는 `alpha = scene.a * bar`, SUBTRACT는 `alpha = max(0, scene.a - bar*opacity)` —
  둘 다 scene.a=0 이면 항상 0). 그런 씬이 실제로 나타나면 트리거 — 해당 compose 레이어만 acc 블릿 유지로
  좁게 예외 처리할 것(전역 게이트가 아니라 씬별 처리 권장 — 이번에 시도한 "오디오 유니폼 참조" 휴리스틱은
  근거였던 사례가 오귀속으로 무효화됐으므로 재도입 시 반드시 실제 유발 씬으로 재검증할 것).
  3521337568(earth composition)·3565190341(shake) 는 별개로 shader-math(tint BLENDMODE==0 이
  albedo.rgb/a 를 무조건 재설정해 체인 전체가 입력과 무관) + 실캡처로 콘텐츠 손실 0(픽셀 동일, frac=0) 확인 완료.
- **①②③ 재조사 기록**(외부 `waple-scene-audit-2026-07/NEXT-WAVE-PLAN.md`·`gate-visual-adjudication.result.json`
  §4 "기지결함" 목록 대조, 리포 밖이라 여기 요약만 남김): ③ waterwaves(2947302287) "TIMEOFFSET 마스크
  오바인드로 파도 변위 미구현" 표기는 y-up 전역 전환(`0ce3e2c`) 이후 더 이상 재현되지 않음(`f1e7f7c` 가드
  테스트 + 실측 A/B 36% 픽셀 차) — 신규 가드 2건을 실물 waterwaves.frag MASK/TIMEOFFSET 콤보로 보강해
  해당 텍스처 바인딩 회귀도 감지하도록 확장(`SceneTranslatedEffectRenderTests.testWaterwavesMaskComboGatesDisplacement`/
  `testWaterwavesTimeOffsetComboShiftsPhase`). ①(3250755486 opacity 마스크)·②(3276911872 colorkey 과다
  키잉)은 이번 라운드에서 코드 변경 없이 재확인만(반증이 아니라 "미재현" — ②는 60프레임 애니 텍스처
  전수 미스캔이 명시적 한계).

## 하네스

*트리거: 게이트 오탐·소요가 거슬릴 때.*

- **벽시계(Date) 오염** — 씬 스크립트 JS `Date`가 미스텁이라 시계 텍스트 씬(회귀 FAIL 58 중 45건 보유)의 diff에 캡처 시각차가 섞임(실측: 3047405322 mean 13.05가 전부 시계였음, 2026-07-11 판독). 같은-분 셀프체크는 "결정"으로 오분류. 수정 방향: 캡처 경로에서 shims에 Date 고정 주입 또는 시계 스크립트 보유 씬을 lax 버킷으로
- 스냅샷 드리프트 2씬(3000562427, 3448290956) 부하 내성 — 순정에서도 요동하는 크로스-프로세스 비결정, 현재는 판독 시 제외 규약
- GT 인-테스트(debug, ~35분 추정)를 release `WapleCompat --capture/--compare` 게이트(6분)로 이관하고 debug GT 슬림화 검토
- 초대형 멀티페이지 스프라이트 스트리밍(6씬 정지 폴백 해제), scriptproperties 주입(중국 2패키지), TEXS 회전 실물 검증(코퍼스 0건)
- **F144: SnapshotCompare 의 결정/비결정 임계 선택이 베이스라인 캡처 시점 1회 기록에 영구 고정** — 매 `--compare` 마다 현재 빌드 자기일관성을 재확인하지 않아 (a) 원래 결정적이던 씬이 회귀로 비결정이 돼도 별도 신호 없음 (b) 캡처 당시 살짝 넘겨 비결정 분류된 씬은 그 뒤 영원히 관대한 임계만 적용받음. 수정 방향: `--compare` 도 씬마다 2회 캡처해 자기-diff 재확인(임계 재분류) — 단 비교 소요가 2× 증가하므로 트리거(오탐 체감) 대기
- **F146: 골든 베이스라인 `3470948192.png` 가 NaN-퇴화 렌더를 봉인**했던 근본원인(text3DControllers/eval3DOrder 순서 — 비가시 노드 shared 생산이 소비보다 늦게 평가)은 배치6(`7014b20`, 프라이밍 패스)에서 해소됨. 잔여는 순수 아티팩트 재생성뿐 — `waple-baselines/`(리포 밖) 골든을 `WapleCompat --capture` 로 재생성하면 워프 지오메트리가 복원된 최신본으로 갱신됨(코드 변경 불필요)
- **F402/F403: RealPackagesGroundTruthTests 의 luma 기준선이 처분성 `/tmp/waple_gt`에 저장되고(리포 밖·비커밋·머신별) 드리프트는 NSLog 경고뿐**(하드 fail 아님, 의도적 선택 — 씬은 시간 함수라 오탐 위험) — 하드 오라클은 "마운트 무크래시+PNG 존재"뿐이라 완전 검정/깨진 프레임도 통과한다. `git ls-files`상 커밋된 골든이 0건이라 실물 코퍼스 시각 회귀는 사람이 수동 파이프라인(`WapleCompat --capture/--compare`)을 돌리거나 아무도 안 읽는 로그로만 감지됨. 수정 방향: luma_baseline.json 을 리포에 커밋(또는 waple-baselines/ 로 이관)하고 CI(위 3번 항목)와 묶어 자동 시각-회귀 게이트로 승격
- **F398: 벽시계 결합 타이밍 패턴이 스위트에 산재** — 고정시간 `RunLoop.run(until:)` fire-then-assert 33사이트(Web/Video/Media 비동기) + `MediaPollerTests`의 `Thread.sleep(6s)`+`run(until:5.4s)`(단일 테스트 ~5.4s 소요, 폴 간격·sleep·run 상호의존)가 고부하/느린 머신에서 오탐 위험. 대조로 견고한 폴-until 패턴(`RealVideosGroundTruthTests` deadline 폴, `WebHardPauseTests` waitUntil)도 이미 공존 — 팀이 견고 패턴을 알면서 일부만 적용한 상태. 수정 방향: 33사이트를 견고 폴 패턴으로 일괄 전환(대규모 — 개별 파일 접촉 다수, 전수 재실행 검증 필요해 이 배치 범위 밖)
- **F399: REFRACT 파티클 셰이더(2D pf_refract)가 MSL 컴파일 여부만 테스트되고 실제 굴절 픽셀 출력 회귀가 없음** — `ParticleShadersTests.testCompilesMSL` 1건뿐, `SceneParticleRenderTests`/`Scene3DParticleTests` 어디에도 refract 매칭 0건. 수정 방향: F406 과 동일 캡처 패턴(배경 텍스처 위 굴절 파티클 픽셀 오프셋 확인)으로 신규 유닛 — 대형(배경 샘플 패스 셋업) 이라 씬 체감 시 착수
- **캡처 시각-씬 트리거 경계 결합(단발 프레임타임 점프)** — `SnapshotPipeline.captureEpochMillis`(2024-01-01T12:00:00Z = KST 21:00:00 정각)이 시간대별 크로스페이드 씬(예: 3563096027 — 정적 야간 레이어 1개(id 25) + `hours>=21&&hours<24`
등 시각 조건 alpha 스크립트를 가진 레이어 4개(id 134/211/149/126))의 트리거 경계에 초 단위 여유 없이 정확히 얹혀 있다. 게다가 `captureFrames`는 프레임 단위 재생 없이 마운트 직후(`runtime=0`)부터 목표 시각(`captureT=6.0`)까지 프로퍼티 스크립트를 **단 한 번** 평가하므로 `engine.frametime`이 실제로는 `t − 직전 t = 6.0`이라는 거대한 단발 점프가 된다(F700, `TextScriptEngine.swift` `__setRuntime`). `fadeValue += engine.frametime` 류의 축적형 스크립트는 실제 WE(수백 프레임에 걸쳐 조금씩 누적)와 최종 수렴값은 같더라도 **경계 바로 위/아래에서 결과가 급변**할 수 있어(§6 3563096027 재검 참조), captureEpochMillis 를 조금만 옮겨도(또는 향후 다른 시각 조건 스크립트를 가진 씬이 추가되면) 판정이 뒤집힐 수 있는 구조적 하네스 취약점이다. 트리거: 새 시각-조건 씬에서 유사 오탐/오분류가 재발할 때. 수정 방향(스코프 밖, 고비용): (a) `captureEpochMillis`를 정시(:00)에서 몇 분 비켜 재설정 — 170씬 전수 재베이스라인 필요, 또는 (b) `captureFrames`가 목표 시각까지 실제 프레임 스텝(예 30fps)으로 재생해 스크립트를 여러 번 평가하도록 변경 — 결정성/캡처 소요 트레이드오프 재검 필요
- **F406 잔여: 3D 렌더 픽셀 커버리지 홀 — text3D 글리프·spritesheet 프레임·RIM/SHADINGGRADIENT 셰이딩** — colorBlendMode(additive/normal, 2026-07-18 착지) 외 나머지는 이 배치 범위 밖(스코프 지시: 1~2개만). 패턴은 이미 확립됨(`Scene3DRenderCorrectnessTests.captureBlendModeCenterPixel`/`captureFullscreenCompositeCenterPixel` — 씬을 디스크에 마운트해 `captureFrames`+`colorAt` 로 픽셀 확인)
- **세션 간 캡처 비결정 29종 — 원인 미상(측정은 끝)** (2026-08-01). 같은 세션 안에서는 전 코퍼스 캡처가 프로세스를 갈라도 비트동일한데, 세션이 갈리면 고정된 29종이 갈린다(네 세션 중 17종은 네 값 전부 다름). 전부 임베디드-mip 수정 영향권(123종) 안, 정렬 인덱스 49 이상. 배제된 것: 바이너리 동일성·부하 개입·단건 대 순차·TZ·CWD·디스크 입력·절전/재부팅. 정본·씬 목록은 [`spec/golden/nondeterminism.json`](spec/golden/nondeterminism.json), 재측정은 `scripts/spec/measure_nondeterminism.py`(커밋된 매니페스트 8개)와 `scripts/mac-session/probe-session-nondeterminism.sh`(~12분). 위 "스냅샷 드리프트 2씬" 항목이 말하던 것의 정체가 이것이다(3448290956 이 그 29종 안에 있다). **트리거: 세션 간 대조가 필요한 작업(커밋된 기준선 대조, 릴리스 게이트)에서 이 잡음이 판독을 막을 때.** 다음 판별: 상태가 바뀐 세션에서 `WAPLE_CAPTURE_TIME=0,0.1,1,6` 으로 다시 떠 t=0 부터 대조 — t=0 이 이미 다르면 마운트/로드 발산, t 가 커지며 갈리면 프레임 누적 상태. 실무 회피책: **구현 전후 캡처를 한 세션 안에서 둘 다 뜬다.**
- **↑ 위 항목 원인 규명(2026-08-02): 캡처가 실제 마우스 커서 위치를 픽셀에 굽는다.** `SceneRenderer.mount` 가 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜고(SceneRenderer.swift:1421) 그 콜백이 `pointerUV` = 이펙트 유니폼 `g_PointerPosition` 을 라이브 커서로 채우는데(:1535, SceneRendererFrameEncoder.swift:53), `SnapshotPipeline.pinRenderSettings`(:249) 의 핀 목록에 포인터가 없다. 커서만 옮겨 가며 같은 씬을 뜨면 위치마다 다른 해시가 나오고 같은 위치로 돌아오면 그 값이 재현된다(1포인트 차이도 바뀐다) — `scripts/mac-session/probe-pointer-uniform.sh`. 정본 `oracle.nondet.rootCause`(확정). 게이트 매트릭스에서 `WAPLE_DISABLE_TRANSLATED=1` 만 상태 간 동일했던 것이 이 경로를 지목했고, Metal 셰이더 캐시·mip 수정·부하는 전부 배제됐다. **수정 방향(사용자 결정 필요)**: 헤드리스 캡처에서 마우스 모니터를 켜지 않거나 `pointerUV` 를 (0.5,0.5)로 핀한다 — **포인터 반응 씬의 골든 재베이스라인이 따라온다**. GT 하네스(`RealPackagesGroundTruthTests`)가 같은 구멍인지도 함께 볼 것.
- **↑ 포인터 핀 착지 + 골든 재베이스라인 완료(2026-08-02, `f3a17da`).** `SceneRenderer.capturePointerUV` 로 캡처 하네스(스냅샷 파이프라인·GT)가 포인터를 중앙 고정한다 — 마우스 모니터를 **켜지 않는다**(pause 로 멈추면 이미 들어온 값이 남는다). 기동 지점이 셋이라 한 곳만 막았을 때는 그대로 샜다(새던 곳=mount 의 cursorMove·호버 게이트) → `startPointerMonitor()` 공용화 + `updateParallax` 이중 안전망. 회귀 `CapturePointerPinTests`(핀 분기 제거 시 깨지는 것까지 확인). 현행 기준선 `spec/golden/snapshot/baseline-f3a17da/`(release, 170/0/0, 셀프체크 비결정 0종) — 설치 게이트는 **두 캡처 사이에 커서를 옮기고 비트동일할 때만**(`scripts/mac-session/rebaseline-golden.sh`, 이번 설치 상이 0종). `GoldenBaseline.currentLabel` 이 이 기준선을 보며, 이걸로 **BACKLOG/인계의 `3394601417` GT 재베이스라인 항목도 해소**(기준선 0.0600 → 0.01162, GT 640×360 캡처는 그 2.5배라 structureLoss 통과). 남은 것: GT 하네스가 스냅샷 파이프라인과 **해상도·핀 규약이 여전히 다르다**(640×360 vs 256×144 — `oracle.gate.knownBandGap`).
- **HDR 블룸 필터 체인을 WE 평문 구조로 교체(2026-08-02).** `hdr_downsample.frag` 하나를 콤보로 3역할에 쓰는 듀얼 필터 그대로 — 4탭 ±0.5 소스 텍셀 · **가우시안 패스 제거** · 4탭 additive 업샘플 · `combine_hdr` 의 ±텍셀 4탭 합성 · 피라미드 시작 1/4 → **1/2**. 정본 `engine.bloom.hdr.filterShapeDeviations`(확정, preSwap 5+1건 해소) + A/B 9씬(luma 0.95~1.10, 최대 평균차 2.84). **미해결**: 업샘플 가중을 셰이더 문면(`평균 × g_BloomScatter`)대로 두면 scatter=1.619 가 레벨마다 곱해져 발산한다(실측 백화) — 저작값이 셰이더 상수로 그대로 가는지 미확인이라 종전 캘리브 `0.25 × scatter` 유지, `engine.bloom.hdr.upsampleWeightUnknown`(추정)에 닫는 방법(exe 정적 분석 또는 윈도우 동일 씬 캡처)까지 적어 뒀다. **LDR 블룸은 그대로 3패스** — WE 평문에 `blur_h_bloom`/`downsample_quarter_bloom` 이 있으나 LDR 경로 조합의 정본이 없어 착수 전 대조가 선행이다.
- **공개 배포 준비 착수(2026-08-02).** ①**공증 배선 완결**: release.yml 이 임시 키체인 생성 → `.p12` 임포트 → `set-key-partition-list`(이게 없으면 codesign 이 GUI 프롬프트에서 잡을 세운다) → `notarytool submit --wait`(앱 암호 방식 — 러너엔 저장된 notary 프로파일이 없다) → `stapler staple` + `stapler validate`/`spctl` 검증 → `if: always()` 키체인 삭제까지 수행한다. secrets 6종이 하나라도 없으면 종전대로 ad-hoc 폴백(릴리스는 안 멈춤). 필요한 secrets 표는 [docs/RELEASING.md](docs/RELEASING.md). **남은 것은 유료 계정 발급뿐.** ②**영어 UI**: 키=한국어 원문 규약으로 `Resources/en.lproj/Localizable.strings` 122키 신설, 보간 8곳은 `String(format: NSLocalizedString(...))` 로 명시, AppKit 8곳은 `NSLocalizedString` 로 감쌈. `.lproj` 는 앱 번들 `Contents/Resources` 에 들어간다(SPM 리소스 번들이면 `Bundle.main` 조회 실패 — `swift run` 개발 실행이 늘 한국어인 이유). 패키징한 `.app` 에서 실동작 확인(en→"Settings", ko→원문 폴백, 포맷 문자열 "Interval: 5 min"). `LocalizationCoverageTests` 가 누락·고아·ko 오염을 양방향으로 잡는다(실제로 누락 1건을 잡아냈다). **잔여 배포 항목**: 접근성(그리드 VoiceOver/키보드) · 창 닫힘 상태 오류 알림 UNUserNotification 승격 · 유료 계정.
- **CI 플레이크 1건 수정(2026-08-02)**: `DevToolsSceneFixRegressionTests.testVisibilitySpoofFollowsPauseState` 의 **첫 대기**(WKWebView 콜드 스타트 + 브리지 주입)가 3초 상한이라 3코어 러너 부하 구간에서 넘겼다(run 30748362460 실패 / 같은 커밋이 30746196170 에서는 통과 — 타이밍 창). 그 대기만 15초로 올렸다(반응 지연을 재는 pause/resume 전이 대기는 3초 유지). 게이트는 안 약해진다 — 브리지가 끝내 안 뜨면 여전히 실패한다. 같은 계열의 남은 위험은 F398(고정시간 `RunLoop.run(until:)` 33사이트)로 이미 기록돼 있다.
- **CI 플레이크 2번째(2026-08-02): `WebHardPauseTests.testPausedCreationCrossClearAndRemainingDelay`.** 정지 시점에 타이머가 이미 만료돼(실측 남은 지연 **-12ms**) "정지 중 발화 금지" 전제 자체가 깨졌다(run 30748596484). 지연 상수만 키우면 정지 관측 창이 원래 마감을 못 넘어 단언이 무의미해지므로, **창을 남은 지연에서 계산**하도록 고쳤다(keepDelayMS 280→1500, 창=remaining+200ms, 재개 대기=remaining+3s). 전제가 깨지면 그렇게 말하는 단언도 추가(`남은 지연 …ms — 전제가 깨졌다`). 음성 대조로 게이트 유효성 확인 — `setPaused(true)` 를 생략하니 정확히 그 자리에서 실패한다. F398(고정시간 대기 33사이트)의 같은 계열이며, 이번 두 건 모두 **3코어 러너에서만** 드러났다.
- **★배포 산출물이 실행 즉시 죽고 있었다(2026-08-02 발견·수정).** `package-app.sh` 가 SwiftPM 리소스 번들(`Waple_WapleRender.bundle`, WE 에셋 85MB)을 `.app` 에 **한 번도 복사하지 않았다**. `Bundle.module` 은 못 찾으면 경고가 아니라 **fatalError** 라 앱이 실행 즉시 `unable to find bundle named Waple_WapleRender` 로 죽는다. 실측: 고치기 전 DMG **2.9MB**·app 7.6MB, 고친 뒤 DMG **70MB**·app 94MB. **v0.1.0-beta.1/2/3 전부 같은 상태로 공개됐을 것**(그때까지 릴리스 검증은 DMG 마운트·plist·arm64·codesign 뿐 — **앱을 실행해 본 적이 없다**). 조치: 번들 전량 복사 + 게이트 2종(`.build/*.bundle` 이 앱에 다 있는지 구조 확인 · 패키징된 앱 6초 실행 스모크, `WAPLE_SKIP_SMOKE=1` 로 해제 가능). 음성 대조로 게이트 확인 — 복사를 생략하면 정확히 그 자리에서 종료코드 1. 교훈: **"산출물이 만들어졌다" 는 "산출물이 동작한다" 가 아니다** — 이 리포의 반복 실패형(안전망이 조용히 무력)의 배포판.

