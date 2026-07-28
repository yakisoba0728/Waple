# 씬 렌더 정합성 감사 — 문제점·해결책 종합 문서 (2026-07-26)

170개 씬 코퍼스 전수 실측 판정(Phase 1, 32에이전트) + 핵심 주장 코드/레퍼런스 대조 검증(6에이전트)의
통합 결과. 대상 HEAD: `82f3307`. 정답지: WE 공식 preview.* + RenderDoc 골든(씬 3397690043) +
WE 2.8.0.42 레퍼런스 문서군(`~/Downloads/wallpaper_dev/references/`, `re-audit-2026-07/`).

## 1. 방법과 산출물

- **Phase 0**: `WapleCompat --capture`로 HEAD 170씬 전체 캡처(전원 렌더 성공, 마운트 실패 0, 비결정 2씬).
- **Phase 1**: 32개 에이전트가 씬당 3-way 시각 대조(HEAD vs preview vs 구 베이스라인 95fad7a) +
  실패 씬 절연(고해상 재캡처, `WAPLE_LAYER_TRUNC`/`WAPLE_EFFECT_SKIP` 등 게이트, scene.json 분석).
- **검증**: 6개 에이전트가 수정 착수 대상 주장을 코드+권위 문서로 대조 — 확정/반박 판정.
- 산출물(휘발성, 재생성 가능):
  - `/tmp/waple-scene-audit/head-capture/head-82f3307/` — HEAD 캡처 + manifest
  - `/tmp/waple-scene-audit/verdicts/<id>.json` — 씬별 판정(170/170)
  - `/tmp/waple-scene-audit/shard-*/` — 고해상·절연 게이트 캡처, 크롭, 프로브
  - `/tmp/waple-scene-audit/shards/shard-*.txt` — 샤드 배정표

## 2. 판정 통계

| 판정 | 씬 수 |
|---|---|
| **ok** | **59 / 170 (34.7%)** |
| partial | 37 |
| flipped-v/h | 28 |
| geometry-wrong | 22 |
| garbled | 18 |
| black | 6 |
| **실패 합계** | **111 / 170 (65.3%)** |

HEAD 회귀(구 베이스라인 대비)는 2건 — 나머지는 전부 기존 결함(§7). (3563096027 은
2026-07-27 재검에서 실회귀 아님으로 재분류 — §6 참조)

---

## 3. 확정 클러스터와 해결책 (수정 준비 완료)

우선순위·영향 순. 각 항목: 루트코즈 / 해결책 / 회귀 위험.

### C1. 텍스트 래스터 상하반전 — 최다 영향 (40+ 씬)

- **루트코즈**: `Sources/WapleRender/TextRasterizer.swift:149-157`. CG 비트맵 row0을 "bottom"으로
  잘못 가정하고 행 뒤집기를 수행 — 실제로는 `:139`에서 이미 row0=top으로 그려지므로 **이중 플립**.
  하류(SceneRendererResources.rasterize 쿼드 UV, encodeText)에 재반전 없음을 확인.
- **증상**: 모든 텍스트 글리프가 상하반전("MONDAY"→"WOND∀Y", "21:00"→"ƧI:00").
  Phase 1의 "좌우반전(h-flip)" 보고 3건(3363473482, 3753921460, 3454792257)은 전부 v-flip의
  착시로 확인 — **별도 h-flip 결함은 존재하지 않음**.
- **해결책**: 플립 루프+`:149` 주석 삭제, `pixels` 그대로 반환. `:127` 주석 정정.
  **`Tests/WapleRenderTests/TextEngineTests.swift:621-643`이 버그를 정답으로 인코딩** — 스캔 범위를
  하단 절반으로 바꾸고 주석 삭제. 방향 회귀 테스트(비대칭 글리프 잉크 분포) 추가 권장.
- **회귀 위험**: 낮음(소비자 단일, 정상 텍스트 씬 실재 안 함 — 3353695150 "정상" 보고는 오독 확인).
- **영향**: flipped-v 판정 대부분 + partial/garbled 다수에 병존(40+ 씬).

### C2. 씬 좌표 Y축 규약 (origin.y) — 최대 파괴 범위 (20+ 씬)

- **판정**: WE는 **전 씬 y-up(좌하단 원점)** — RenderDoc 골든(scene.json 산술 대조), 코퍼스 파티클
  물리 부호(눈/비 하강=음의 y), 스키마 전수 조사 3자 일치. **결정자는 존재하지 않음**(씬별 분기
  플래그 없음). 반례로 제시된 3씬(2325500626, 3379996991, 3483456356)은 전부 판별력 없는
  관측으로 기각(중심 구성 씬은 어느 규약이든 정상으로 보임).
- **루트코즈**: `Sources/WapleRender/SceneRendererFrameEncoder.swift:369-371` `pxToNDC`
  (`1 - y/projH*2` — y-down 매핑). 파생 y-down 가정 전수: alignedCenter(:384-390, top/bottom 부호),
  quadVertices(:393-434), layerTransformMatrix ortho(:451-456), litRect(:483-490),
  파티클/리본 합성(:86,137,165), puppetVertices(:492-513), runOrtho3DMeshes(:675-684,
  sy=-2/H+와인딩), SceneRendererResources.swift:1396-1403(텍스트 앵커),
  SceneRenderer.swift:260-263, 695-702(포인터 역매핑).
- **해결책**: 전역 플립(조건 분기 아님). pxToNDC 부호 반전 + 파생 부호 조정(alignedCenter ay,
  파티클 합성 `−scale.y·`→`+`, ortho sy/ty+와인딩, 텍스트 span, 포인터). 회전은 자동 정합
  (y-flip이 회전을 켤레 → WE 양수=CCW와 일치). `QuadShaders`·이펙트·합성 패스 UV는 건드리지 않음.
- **회귀 위험**: 중심 구성 씬은 불변이라 무회귀. 주의 3종: ① 퍼펫 경로(puppetVertices는 이미
  "모델 y-up" 보정이 박혀 있어 세계관 반전 시 재검증 — 3463520581이 1차 게이트) ② 텍스트와의
  상호작용(C1과 순서 상관 재실측) ③ 칸 메라/포인터/라이브 isGeometryFlipped 이중 플립 여부.
- **검증 게이트 씬**: 3397690043(골든), 3373818743(ortho hybrid), 3644280276, 1412044563(2D),
  3463520581(퍼펫), 2325500626(무회귀 대조), 3483456356(신규 노출 확인).

### C4-(i). 파티클 alpharandom 기본값 (bokeh 백화 4씬 + 37씬 변화)

- **루트코즈**: `Sources/WapleCore/ParticleSystem.swift:401-402` — min/max 부재 시 `?? 1`로
  파싱 → `ParticleSimulator.swift:544`에서 알파 1.0 고정. **WE 실제 기본값은 0,0**
  (WE 프리뷰에 bokeh가 없는 것이 유일한 권위 증거; re-audit 문서는 "[추측]" 미확정).
  alpharandom 224건 중 67건이 min/max 누락인 코퍼스 관행 확인.
- **해결책**: `?? 1` 두 개를 `?? 0`으로. lifetime/size는 누락 0건이므로 무수정.
- **회귀 위험**: 37씬 출력 변화(전수 집계 완료) — 단변 누락 케이스(wind-blur, Rain2,
  rainperspective)는 어두워짐. WE 정합 방향이나 **골든 재승인 게이트 필수**. instanceoverride
  주입 경로·min/max 명시 157건은 비트동일.
- **영향 씬**: 3416122407, 3558034522, 3151551777, 2904908532(백화 소거) + 단변 누락 씬들.

### C4-(ii). 파티클 overbright 미구현 (60씬 잠재)

- **현황**: `Sources/` overbright grep 0건. WE 의미론 확정: `genericparticle.frag:12,119`
  (`color.rgb *= g_Overbright` — RGB만, 알파 제외, material 유니폼, default 1.0, range 0~5).
  170씬 중 60씬이 ≠1 머티리얼 보유(0.25~5).
- **주의**: 2904908532의 백화 원인은 이게 아니라 C4-(i)로 확정(재귀속됨). 독립 갭으로 처리.
- **해결책**: `ParticleMaterial.overbright: Float = 1` 추가(파스는 refract_amount 패턴 재사용),
  pf_main/pf_refract 출력 rgb에 곱. 기본값 1이면 기존 씬 비트동일.
- **회귀 위험**: 낮음(≠1인 60씬만 의도적 변화).

### C4-(iii). 파티클 REFRACT 경로 (3019043758 등)

- **판정 분리**:
  - **spritetrail REFRACT 배제 — 확정(주범)**: `SceneRendererFrameEncoder.swift:593`의 `!isTrail`
    가드가 trail을 refract 경로에서 제외 → 굴절 대신 identity 흰 드롭(rain_on_the_glass1).
  - **additive-refract 블렌드 하드코딩 — 확정(부범)**: `SceneRendererResources.swift:1187-1202`
    `refractParticlePipelineBuild`가 translucent 하드코딩 + "additive-refract 미관측" 주석이나
    실데이터 반박: additive+REFRACT 머티리얼 10씬(3019043758, 3047405322, 3174556087, 3302695207,
    3441873795, 3450697231, 3465215190, 3544823846, 3558034522, 3629379075).
  - sprite refract 자체는 실효함(청회색 streak은 additive-identity로 불가능 → 정접증거).
  - Rain_main은 `starttime: 10` > 캡처 t=6이라 판정 대상 아님(Phase 1 과오 귀속).
- **해결책**: 디스패치에서 `.spriteTrail`만 `!isTrail` 예외 허용(rope 계열 유지 배제) +
  `refractParticlePipelineBuild(additive:)` 변형. pf_refract 셰이더는 무수정(genericparticle.frag와 일치).
- **회귀 위험**: 낮음(해당 조합만 신경로). trail은 회전 쿼드라 탄젠트 근사 미세 차이 수용.

### C5. 텍스트 레이어 parent 합성 부재 (7+ 씬)

- **루트코즈**: `SceneTextLayer`에 `id`/`parent`/`angles` 필드 부재(`SceneDocument.swift:208-257`),
  parseText 미파스(:1304-1359), composeParentTransforms가 텍스트 제외(:1433-1492),
  encodeText가 `t.def.origin` 직용+정적 각도 무시(`SceneRendererFrameEncoder.swift:1206-1207`).
  레퍼런스 전수 조사상 텍스트의 75%가 parent 보유(`re-audit-2026-07/B-formats/dig-scene-obj.md:221-231`).
- **핵심 변종**: **부모가 텍스트인 케이스**(3701356561, 3516106265)는 이미지 자식(Solide H/V)도
  합성 실패 — 텍스트를 localT/parentOf 테이블에 "부모로서" 등록해야 완결.
- **해결책**: SceneDocument 1파일 + encodeText 2줄: ① SceneTextLayer에 id/parent/angleZ 추가
  ② parseText 파스 ③ composeParentTransforms에 texts 확장(레이어 우선, 텍스트 최하위; 2D 한정
  게이트 — 3D는 빌보드 경로가 별도 합성) ④ encodeText에 정적 angleZ 적용(3146703458의 178° 포함).
- **회귀 위험**: 낮음(parent 없는 텍스트는 합성 대상 아님).
- **영향 씬**: 3701356561, 3659877246, 3462491575, 3516106265, 3146703458, 3367988661, 3445534475.

### C8. 가시성 상속 (비가시 부모의 자식 미컬링, 2D 한정)

- **루트코즈**: initialVisible이 자기 `obj["visible"]`만 봄(`SceneDocument.swift:778-786`),
  부모 체인 조회 없음. 3D는 이미 구현(`Scene3DMath.worldMatrix:113-126`이 조상 AND) — **2D만 부재**.
  2D 파티클은 게이트 자체가 없음(SceneRendererResources.swift:1112 전량 빌드).
- **정확한 메커니즘**: "정적 false 부모"가 아니라 **user-조걶 바인딩이 스냅샷 false로 해소된 부모**
  (3299228616의 언어 그룹 6개) — 드롭 판정은 동일.
- **해결책**: 파스 말미 전파 패스 — 비가시(invNode) 조상 집합을 만들어, 자기 visibleScript 없는
  자식은 initialVisible=false로 **마킹**(드롭 아님 — JS 인덱스 정합 보존). imageLayerCompositeIDs
  제외(:794 carve-out과 동형). 2D 파티클 visible 게이트 추가. 3D는 변경 금지.
- **회귀 위험**: "숨김 부모 자식을 그려서 오히려 맞아 보이던" 케이스가 바뀔 수 있으나 그 상태가
  WE 불일치였던 것. 잔여 갭: 정적 false 부모+스크립트 자식 조합(런타임 부모 평가는 후속).
- **영향 씬**: 3299228616(확정). 3616389236은 **반박로 제외**(해당 오브젝트는 파스 타임 드롭이라
  렌더 불가 — 진짜 원인은 scale 스크립트 NaN/mediaThumbnail 계열).
- **구현 완료(W3-①, 커밋 90dbb2f)**: 파스-타임 전파 패스 착지. **코퍼스 블라스트 반경 실측**
  (`WapleCompat --vis-blast`, 170씬 파스 전수 — 렌더/캡처 아님): 46씬 영향, 831개 오브젝트
  신규 initialVisible=false(레이어 598/텍스트 160/파티클 73). 상위 5씬(2955378002=249,
  3299228616=43, 3565190341=35, 3538758087=31, 3463520581=29) 전건 단씬 hi-res A/B 캡처로
  육안 확인 — **전건 "숨어야 할 것이 숨음"**(디버그 부모/캐릭터/언어 변형 콤보의 미선택 분기
  중복 렌더 제거, over-marking 0건). 대조군(2325500626, 미영향 씬) 바이트동일 무회귀.
  세부: 2955378002(Persona5 위젯, 249=콤보 변형 249/765=33% — 스타/코멘트 마커 다수, 주 콘텐츠
  무변화), 3299228616(중복 시계 위젯 소실 + 부수적으로 이전엔 겹쳐 가려졌던 검은 고양이 본체
  노출), 3565190341(달 장식 자식 2 + 캐릭터 변형 33 억제, 겹친 텍스트 위젯 판독 가능해짐),
  3538758087(다국어 날짜 위젯 — 깨진 중첩 텍스트가 "1 JAN 2024" 로 정상화), 3463520581(퍼펫
  characterssize 콤보 "lil" 변형 29개 자식 억제 — 겹쳐 있던 두 캐릭터가 각각 또렷해짐).
- **런타임 토글 한계**: 없음(확인 완료). 이 마킹은 파스-타임 정적 스냅샷이지만
  `LibraryViewModel.setProperty → reapplyIfCurrent → onApply → SceneRenderer.mount` 가 매번
  `SceneDocument.parse` 를 새 userProps 스냅샷으로 재실행(remount = 전체 재파스, in-place 패치
  경로 없음) — 유저가 라이브로 옵션을 켜면 다음 파스에서 마킹도 갱신된다("옵션을 켜도 자식이
  계속 숨는" 고착 없음, `SceneComboVisibleTests.testVisibilityInheritanceRespondsToUserPropsSnapshot`).
  진단용 `WAPLE_VIS_INHERIT=0` 게이트로 코퍼스 스캔/A-B 재현 가능(기본은 항상 켜짐).

### C6-(iii). project.json 유저 프로퍼티 기본값 미주입 (위젯 중앙 배치)

- **루트코즈**: `SceneRenderer.swift:991-994` — userProps에 `UserPropertyStore.rawOverrides`
  (UserDefaults+preset)만 전달. resolveUserBindings(SceneDocument.swift:1901-1919)는 키가 있을
  때만 치환 → 미변경 프로퍼티는 scene.json 스냅샷(0.5=중앙) 유지. 레퍼런스: `value`는 직렬화
  스냅샷, `user`가 실바인딩, 미변경 시 project.json 기본값이 유효값(WE-2.8-COMPLETE-KR.md:1203).
- **해결책**(~30라인): mount에서 WallpaperProperties.parse + applying(overrides:)로 기본값+오버라이드
  effective 맵을 parse 이전에 만들어 전달(기존 :1004-1010 계산 재사용).
- **회귀 위험**: **중요** — 퍼블리시 스냅샷이 기본값과 다른 전 씬의 거동 변화(콤보 가시성 포함).
  적용 후 전량 재감사 필수.
- **영향 씬**: 3302695207, 3461168300 + 잠재 다수.

**재판정(F4-polish④, 2026-07-28, main `093dd91`)**: **해소 확인** — 이 문서가 처방한 해결책과
정확히 일치하는 형태로 이미 착지됨(`fda60df`, "fix(C①): {user,value} 바인딩 기본값 시딩", 2026-07-27,
82f3307..093dd91 구간의 "수정 배치 C" 병합 `5ab171c`에 포함). 코드 대조: `SceneRenderer.swift:1075`
`mount()`가 `WallpaperProperties.parse(folderURL:)`로 project.json 기본값(`baseProps`)을 doc 파스
**이전**에 확보해 `UserPropertyStore.rawOverrides(id:projectDefaults:presetOverrides:presetResourceRoot:)`
(신규 4-인자 오버로드, `UserPropertyStore.swift:29-36`)로 `SceneDocument.parse(..., userProps:)` 에
defaults < preset < user 우선순위로 합성해 전달 — 처방된 "parse 이전에 effective 맵을 만들어 전달"과
동형. `resolveUserBindings`(현재 `SceneDocument.swift:2225`, 위 루트코즈가 인용한 `:1901-1919`는
82f3307 당시 라인으로 이후 드리프트) 자체 코드·주석 재확인 결과 "userProps 에 키가 있을 때만 갱신,
없으면 저작 스냅샷 유지" 계약은 그대로이고 — 이제 project.json 기본값이 파스 시점 userProps 에 이미
합류돼 있어 종전엔 "미변경(키 없음)"이던 프로퍼티가 "있음(기본값)"으로 바뀌어 그대로 픽업된다.
**회귀 위험 각주("적용 후 전량 재감사 필수")는 이미 충족**됨 — 이 기본값 시딩이 포함된 상태로 이후
y-up 전역 전환(W1)·C1~C8 나머지 배치까지 거친 170씬 전수가 재캡처돼 본 라운드 베이스라인
(`waple-baselines/main-093dd91`, empty 0)으로 굳었다(별도 전량 재감사를 다시 돌릴 필요 없음 — 이미
그 결과 위에서 이번 F4-polish 라운드가 출발함). 근거는 위 코드 대조가 전부이며 씬별 전/후 A/B 재캡처는
하지 않았다(3302695207 단발 재캡처를 시도했으나 사전 baseline 부재로 판별력 없는 관측이라 §3-C2
반례 기각과 동일 기준으로 제외 — 3461168300 도 동일 사유로 미시도). 문서 갱신만, 코드 변경 없음.

### C6-(i). 스크립트 칸 메라 shared.camera 소비자 부재 (3737268876)

- **루트코즈**: JS 제공(`TextScriptEngine.swift:1497-1505,1659,1841`)은 있으나 네이티브 readback
  0건 — 끊긴 지점은 `SceneRenderer3D.evaluate3DScripts`(:474)와 칸 메라 합성(:1160-1183) 사이.
  심에 mode/current*/isDragging/mouseInput 필드도 없음(스크립트 자체 로직도 깨짐).
- **해결책**(네이티브 150-250라인 + JS ~30라인): 심 필드 추가(dirty 플래그) + evaluate3DScripts
  말미 readback → target* 변경 시에만 칸 메라 오버라이드 + current* 역기록.
- **회귀 위험**: 칸 메라 스크립트 없는 3D 씬은 dirty 게이트로 정적 유지(필수 조건).
- **정정(W3-② 조사, 착수 보류)**: 위 "심 필드 추가+readback" 처방만으로는 **불충분/위험**함을
  3737268876 실물 스크립트 역추적으로 확인. 근거 4가지: (1) 스크립트 `init()`이 `shared.camera`
  를 통째로 재할당해 시드값이 무의미해진다. (2) 실제 렌더 채널은 `shared.camera` 가 아니라
  `thisScene.setCameraTransforms(camera)` — 네이티브 브리지 자체가 없다(브리지 없이 필드만
  추가하면 아무 효과 없음). (3) `__makeCameraTransforms()`가 저작 camera.eye/center/up 과 무관한
  하드코드 스텁((0,0,0)/(0,0,-1))이라 readback 만 배선하면 카메라가 원점으로 튄다. (4) 무마우스
  (헤드리스) 상태에서 스크립트가 매프레임 `shared.camera.targetPosition=null` 을 쓰고 mixValue 의
  frameNormalizer(`engine.frametime*(1/engine.frametime)`)가 frametime=0 프레임에서 NaN 이 되는
  파괴적 경로가 실증됨. **올바른 범위**는 (a) transforms 를 저작 카메라로 시딩 (b)
  setCameraTransforms 내부 명시적 dirty 플래그 (c) NaN/Infinity 가드 (d) 무마우스 상태 A/B 검증까지
  포함하는 더 큰 작업 — 이번 웨이브에서 억지 구현하지 않고 다음 웨이브로 이관.

---

## 4. 추가 조사 필요 (미확정 — 수정 착수 전 조사)

### D2. 레이어별 콘텐츠 v-플립 (원인 미상, 신규 클러스터)

- **증상**: 위치는 정상인데 레이어 "내용"만 상하반전. 2842323353, 3573378561(퍼펫 데이터 없음),
  3189665546(퍼펫 있으나 수학 정상 — 오프라인 재현=정방향).
- **소거 완료**: 이펙트 체인, 커스텀 머티리얼, compose 레이어, 텍스처 디코드, EXIF, 음수 스케일,
  퍼펫 경로 — 전부 무죄. `WAPLE_DISABLE_TRANSLATED`·`EFFECT_SKIP` 불변.
- **다음 조치**: 런타임 이분 전용 조사(WAPLE_MP_TRUNC 레이어별 + displayTexture 덤프 게이트).
  최우선 용의: 헤드리스 캡처 경로의 `pooledOffscreen` 텍스처 재사용 규약, autosize 대형 스프라이트.
- **3384019940** "ok" 판정은 오판 의심(얼굴/베일 위치 미러) — vflip A/B 재검 대상.

### generic4 등 WE 빌트인 셰이더를 custom으로 참조하는 메시 (4+ 씬)

- `SceneRenderer3D.swift:768-783` buildCustomMeshShader가 pkg 내 소스만 인정해 베이스 에셋의
  generic4를 거부 → 스톡 폴터(에미시브 상실 등). 3470948192(블랙홀), 3589454154(토성 백화),
  3662790108, 3477054430, 3509243656.
- **조치**: generic4.vert가 표준 WE 셰이더인지 확인 후 빌트인 화이트리스트 허용 여부 결정.
  3662790108은 이 이슈로 재정의됨(C6-(ii) 반박 — globalsize TypeError는 텍스트 스크립트
  1프레임 일시 오류일 뿐 버스 단절 아님).

### 3D/칸 메라/투영 잔여

- ~~3D 씬 텍스트 미배선~~ **해소(W-①, `08058c9`)**: build3D 가 doc.texts → TextRasterizer(2D buildTexts 와
  동일 경로) → Billboard3D 로 배선(origin/scale/angles/visible; alpha/color 프로퍼티 스크립트와 텍스트
  '내용' 동적 재래스터는 의도적 미부착 — BACKLOG 등재). 3509243656 텍스트 수 정정: "40+" → 실측 53개.
  블라스트 반경 검증(2026-07-27, B3-3d-video 보수 라운드): 코퍼스 진성 3D 씬(camera3D≠nil) 7개 중 텍스트
  보유 6개 — 3470948192(17)·3477054430(1)·3589454154(17)·3662790108(76)·3737268876(4)·3509243656(53).
  나머지 5씬을 main-6526db1(배선 전) 대비 1920×1080 A/B 캡처(`WapleCompat --capture`/`--compare`,
  전 씬 결정적 self-check 통과) — 3662790108·3477054430·3737268876 은 byte-identical(frac=0.0000, 새
  빌보드가 이 캡처 시점엔 비가시 — visible 스크립트/인터랙션 게이트 추정, 무해)·3589454154(frac=0.0010)·
  3470948192(frac=0.0039) 는 소폭 변화로 이전엔 없던 정보 텍스트(위성/시계·물리식 UI 패널)가 신규 노출되는
  개선 확인(기존 형상 왜곡·오클루전 없음). 3470948192 는 새 텍스트 래스터가 기존 정적 그래픽(√ 기호로 추정되는
  선분 메시/빌보드)과 완전히는 정렬되지 않아 근소한 이중선 아티팩트가 남음(경미, 별도 조사 트리거 아님).
- **칸 메라 프레이밍 불일치**: 3477054430(달 프러스텀 밖 — 5:1 광폭에선 보임, fov/종횡 해석). 후속 조사
  (2026-07-27, B3-3d-video): doc.camera3D 는 scene.json 최상위 camera{eye,center,up} 만 파싱 —
  object id=34('camera':'default', camera_paths_34.json)는 별도 SceneCameraObject 로 파스되나 시야
  행렬에 미반영. 그러나 camera_paths_34.json 실제 내용은 `{"paths":[]}`(빈 배열)이라 **"카메라 경로
  애니메이션 미구현" 가설은 기각**(구현해도 이 씬엔 데이터가 없어 무의미). 달(id=44) origin vs 카메라
  eye/center 직접 각도 계산 시 forward 벡터와 약 **55.8° 이격**(FOV 42.4°의 절반 21.2°를 크게 초과) —
  정적 eye/center 스냅샷 자체가 수학적으로 달을 프레임 밖에 둠(cameraparallax=false·eye/center/up 프로퍼티
  스크립트 없음 확인, y-up 부호 문제 아님). Waple 버그인지 원저작 씬의 의도인지 미확정 — 위 "5:1 광폭에선
  보임/fov·종횡 해석" 단서와 이어 붙여 재개할 것(다음 라운드가 카메라 경로 애니 구현으로 헛돌지 않게
  하는 반증으로 활용).
- **ortho 3D hybrid**: C2 전역 플립과 함께 검증(3373818743 — sy=-2/H+와인딩 지정됨).
- **32:9 초광폭**: 3351179520, 3441006668 — C2 플립 후 재평가(전용 결함 여부 미확정).

### 이펙트 개별 결함 목록 (각 1~2씬)

| 이펙트 | 씬 | 증상 |
|---|---|---|
| water_caustics + cursorripple | 3706286085 | 전화면 흑화(3D 포스트 체인 — EFFECT_SKIP 게이트가 3D에 미적용) |
| vhs | 3665954520 | 네거티브화 |
| depthparallax | 3388330010 | 과대 줌(스케일/오프셋) |
| opacity(마스크) | 3250755486 | 마스크 0 영역이 불투명 검정(알파 손실) |
| colorkey | 3276911872 | 과다 키잉(은발이 키 색 오인) |
| waterwaves | 2947302287 | TIMEOFFSET 마스크 오바인드로 변위 감쇠+위상 미구현 |
| clipping_mask | 2902406982 | 클리핑 의미론 미구현(마스크가 그대로 렌더) |
| lightshafts(DIRECTDRAW) | 3460973721 | 이미지리스 프로시저럴 레이어 미드로우 |
| blur 계열(visible=false 누수) | 3544152633, 3629379075 | 숨김 이펙트가 풀프레임 블러 |
| 오디오 바(idle) | 3233141951, 3713073223, 3287715210 | 무신호에서 풀높이/상단 매달림 |
| clouds | 3171024295 | 흰 블롭 |
| tint(BLENDMODE 12) | 3563096027 | R 채널 누수(**회귀**) |
| 텍스처 오바인드 | 3492627662 | 파트/노이즈 밴드 |
| foliagesway 3연 체인 | 3544823846 | 레이어 통째 드롭 |
| 스프라이트시트 NPOT .tex | 3407317466 | 디코드 실패(RGB 스트라이프) — **정정 2026-07-27, 아래 주석 참조** |
| composelayer 오프스크린 | 3521337568 | 불투명 합성/검은 타원 |
| 外 레이어 스케일 | 3517818807 | 소형이 화면 절반 워시로 |

- **정정(2026-07-27, B3-3d-video "하늘 회색 블롭" 조사, 위 3407317466 행)**: 같은 씬의 "하늘 회색
  블롭/글리치" 증상은 main-6526db1·본 라운드 재캡처 모두에서 재현 실패(하늘이 정상 그라디언트로
  렌더, 다른 웨이브에서 이미 해소된 것으로 추정) — **단 위 행이 서술하는 NPOT 스프라이트시트 디코드
  실패 자체는 재검증하지 않았다**(별도 증상일 가능성 있음, 기각 아님). 머지 시 B4 갱신 문서와
  대조해 정리 필요.

**재판정(B4-①, 2026-07-27, main 6526db1)**: 3565190341 은 위 목록에서 **제외** — C2(y-up) 착지
후 고해상 재캡처(960×540)로 재확인한 결과 composelayer 8건(月/指针/刻刻帝/狂三/白の女王/狂三-对决版/
白の女王-对决版/音乐, 전부 `models/util/composelayer.json`) 전건이 정상 온스크린 렌더 — 시계 원형
문양·두 실루엣 캐릭터·하단 미니 뮤직플레이어(스킵/재생/볼륨/루프 아이콘) 모두 WE 프리뷰와 합치.
main-95fad7a 베이스라인의 "화면 중앙 불투명 검은 띠 + 뭉개진 흰 원"(`waple-baselines/main-95fad7a/
thumbs/3565190341.png`) 대비 A/B 확정 개선 — 이 아티팩트는 C2 이전 상태의 증상이었고 y-up 전환으로
해소됨. 뮤직플레이어 그룹(오브젝트 1587, "音乐")의 origin 은 project.json 유저 프로퍼티
`newproperty26`/`newproperty32`(기본 4000/600, 스크립트 스냅샷 3982.37/505.58 근사)로 화면
우하단에 안착 — WE 공식 preview.gif 는 192×192 정사각 크롭이라 우하단 모서리가 원본에서부터
잘려나가 있어 이 위젯의 배치 정오 판정 오라클로 쓸 수 없음(별도 검증 불필요, 참고용 기록).
검은 원 UI 아이콘 증상도 미관측. 코드 변경 없음(재판정 전용, 문서만 갱신).

**재판정(B4-②, 2026-07-27, main 6526db1)**: 3413921910 도 위 목록에서 **제외** — C2 착지 후
고해상 재캡처 결과 지배 결함(Y축 반전)뿐 아니라 이 문서가 별도 2차 증상으로 지목했던 "잔디 텍스처
오버바인드로 인한 상단 40% 보라/흰색 노이즈 밴드"도 재발 없음. 상단 노을 하늘 그라데이션·전신주
실루엣·"MONDAY" 텍스트 위젯 전부 정상. 노이즈 밴드 영역(상단 40%, 960×540 재캡처 기준 216행)
실측: 행별 평균 밝기 64.3~119.6(단조로운 노을 그라데이션 범위 내), 행별 표준편차 23.3~44.0(밴드 특유의
국소 급증 없이 완만) — 밴드 경계에서의 스파이크 없음. main-6526db1 표준 베이스라인 썸네일과 일치.
코드 변경 없음(재판정 전용, 문서만 갱신).

**재판정(B4-③, 2026-07-27, main 6526db1)**: 3353695150 검정 블록도 위 목록에서 **제외** —
직전 라운드에서 solidlayer(오브젝트 409/769/595/611, size 16~64·scale 최대 10) 자체의 size/color
산술은 무죄로 실증되고 원인이 "Jake 캐릭터 몸통(오브젝트 30, `models/jake1.json` →
`materials/jake1.json`, shader=genericimage4, combo SPRITESHEET:1)"으로 재귀속됐었다. C2(y-up)
착지 후 고해상(960×540 + 1920×1080) 재캡처 결과 검정 블록·올리브색 왜곡·수직 노이즈 줄무늬 전부
소멸 — Jake는 정상 주황색, 헤드폰·재생기 소품까지 WE preview.gif와 합치. 근거: 씬 전체 프레임
meanLuma가 main-6526db1 표준 베이스라인과 일치(0.2792 vs 0.2792, 95fad7a 구 베이스라인의 0.1939
대비 명확한 밝아짐 — 검정 블록 소멸과 정합. 개별 solidlayer 4건 각각의 픽셀 통계는 별도로
분리 측정하지 않음, 씬 전체 값으로만 확인). **genericimage4 QuadShaders 고정 경로 자체는 무죄로
확인**: `SceneRendererResources.buildCustomLayerShader`(:1032-1036 주석)가 씬 패키지 밖 빌트인
셰이더(genericimage4 등)를 의도적으로 배제하고 QuadShaders 폴백을 taken하는 설계인데, Jake의
실제 머티리얼은 `LIGHTING`/`REFLECTION`/`BLENDMODE` 콤보가 전부 0(SPRITESHEET만 1)이라
genericimage4.frag의 분기 대부분이 no-op으로 축약되고(§120-199) — 순수 `texture0 × g_Color4`
+ translucent 블렌드 + 스프라이트시트 프레임 전진만 필요하다. 유일한 활성 콤보(SPRITESHEET)는
구조적 주장(주석)이 아니라 **기능 검증**으로 확인했다: `jake1.tex-json`이 실제 7프레임/1초 시퀀스를
저작(정지 이미지 아님, t=6 단일 캡처로는 애니 여부를 판별할 수 없다는 자체 한계 인지)하고, 프레임
전진 게이트(`SceneDocument.spritesheet`)는 `SceneRendererResources.swift:277-286`에서 셰이더
이름과 무관하게 텍스처 바인딩 단계(`resolveTextureWithFrames`)에서 결정된다 — 즉 genericimage4든
QuadShaders든 동일 프레임을 받는다. 이 정확한 경로(제네릭 이미지 레이어 + 씬 패키지 밖 빌트인
셰이더 + SPRITESHEET 콤보)를 `Tests/WapleRenderTests/SpriteSheetLayerRenderTests.swift`의
`testSpriteComboLayerAdvancesFrames`(합성 genericimage2 씬, 로그로 "custom layer shader source
missing: genericimage2" 확인 — genericimage4와 동일 폴백 경로)·`testRealEffectSpriteLayerAdvances`
가 실동 mount+렌더+캡처로 시간에 따른 프레임 전진을 확정(둘 다 green, 재확인). 즉 이 씬에서
QuadShaders 폴백이 실제로 "놓치는 의미"는 없음 — 검정 블록의 진짜 원인은 셰이더 콤보 갭이 아니라
C2 이전의 solidlayer/Jake 좌표 배치(y-down 오독) 자체였다. 코드 변경 없음(재판정 전용, 문서만
갱신), 위 스프라이트시트 테스트 7건 green 재확인.

### 소수 클러스터

- **solidlayer size 무시**: 3640755971(纯色 박스).
- **비디오 레이어 헤드리스 무출력**: 3605722997(추출 성공·프레임 공급 nil 추정).
- **블룸 과다**: 3509243656(NO_BLOOM A/B 확정, bloomstrength 4.0).
- **스크립트 평가 NaN**: 3616389236(scale=script 버텍스 소멸) — **정정(W3-③ 조사)**:
  `resolved-as-no-op`(evaluateVec/floatArray NaN 필터는 착지했으나 이 씬 자체는 못 고침). 진짜
  원인은 필터 부재가 아니라 **스크립트 수명주기 순서** — `applyUserProperties` 가 `init()` 보다
  먼저 실행돼 `initScale` 참조가 undefined 로 throw, `speed` 가 영구 미할당으로 남고 update() 의
  `WEMath.mix(a,b,undefined)` 결과 NaN 이 Vec2/Vec3 shim 생성자의 `x || 0` 관용(NaN 은 falsy)으로
  이미 (0,0,0) 에 조용히 세탁된 뒤 evaluateVec 에 도달 — 필터가 보는 시점엔 이미 유한값(0)이라
  거부할 대상이 없다. 코퍼스 6씬 공유 스크립트(__workshopId 3489089062)로 확인, 근본 수정은
  차기 웨이브 이관(수명주기 순서 자체를 고쳐야 함). NaN 필터 자체는 다른 실물 경로(스칼라 반환 등,
  Vec shim 을 안 거치는 경로)에 유효한 방어선이라 유지.
- **미디어 위젯 무신호 숨김 안 함**: 3713073223, 3385540784, 3367988661 — **정정(W3-④ 조사):
  오진**. project.json+scene.json 역추적 결과 세 씬 전부 동일 워크샵 템플릿(workshopId
  3219510589, 'Media Info' 위젯)이고 `general.properties.mediainfo.value=false` +
  루트 오브젝트 `visible.value=false` 가 **일치** — 저작 시점부터 명시적으로 꺼진 옵트인 위젯이다
  (무신호 숨김 미구현이 아니라 애초에 항상 숨김이 정상 동작). 별도 위젯-숨김 휴리스틱 불필요.
- **퍼펫 포즈 미적용**: 3444535389(cat_puppet.mdl, 플랫 쿼드 렌더) — **정정(2026-07-27, B3-3d-video 조사)**:
  런타임 계측 결과 버그 미확인, 오히려 정상 동작 확인. MDLV0023 컨테이너 → PuppetModel.fromModel3D 경유
  로드된 cat_puppet.mdl(bones=3, 클립 'ear' 210프레임 루프)의 PuppetPose.skinMatrices/skinnedPositions
  를 5프레임 간격으로 전체 210프레임 스캔: t=0/3.5s 표본만으로는 정점 최대변위 2.33(작음, "포즈 항등"처럼
  보임)이었으나 t=2.0s(프레임60)에서 정점 최대변위 53.35(모델 스케일 ~300 대비 유의미), angle.z 진폭도
  track별 최대 0.3~0.39rad(17~22°)로 실질적 — 스킨/애니메이션 파이프라인은 컨테이너 경유 퍼펫에서도
  정상 작동. "포즈가 항등으로 남는다"는 가설은 반증됨(단일 프레임 캡처가 우연히 사이클 저진폭 구간을
  포착한 것으로 추정 — 정적 스냅샷의 본질적 한계이지 결함 아님). 코드 변경 불필요.
- **파츠 조립/합성 어긋남**: 3543159422, 3257043844, 3461168300(composeParentTransforms 계열 용의).
- **스크립트 visible 상태기계 미수렴**: 3429479356(engine.frametime 누적 모델).
- **파티클 시트 프레임 고정**: 3396722575, 3462491575(sequence 모드가 단일 글리프).
- **스크립트 팔레트 미해석**: 3300031038(WEColor 공유값).

---

## 5. 기각된 주장 — 건드리면 안 되는 것

| 주장 | 판정 | 근거 |
|---|---|---|
| `puppetVertices` y-flip이 퍼펫 반전 원인 | **반박** | 오프라인 재현=정방향. 2842323353/3573378561은 퍼펫 데이터 자체 부재. **제거 시 정상 씬 3+(2809885105, 3598808038, 3113287126) 깨짐 — 현 캠페인 최대 회귀 위험** |
| cropoffset 소비(F751/S-20)가 배치 오류 | **반박** | 베이크 관계 재확정(2827816001 6조각). 소비 시 정상 씬 파열. 유지가 정답 |
| 텍스트 h-flip 전용 결함 존재 | **반박** | 전부 C1 v-flip 착시("21:00"→"ƧI:00")로 설명됨 |
| globalsize shared 버스 단절(3662790108) | **반박** | TypeError는 텍스트 스크립트 1프레임 일시, 생산자 정상, NaN 경로 부재(TextScriptEngine.swift:590-608는 nil 반환) |
| 3616389236 가시성 미컬링 | **반박** | 해당 오브젝트는 파스 타임 드롭 — 렌더 리스트 진입 불가 |
| Rain_main refract 실효 안 함(3019043758) | 과오 귀속 | `starttime: 10` > 캡처 t=6 — 판정 대상 아님 |
| y-down 결정자 존재(씬별 분기) | **반박** | 스키마 전수 조사에 분기 키 없음 — 전 씬 y-up |

## 6. HEAD 회귀 목록 (구 베이스라인 95fad7a 대비)

| 씬 | 내용 |
|---|---|
| 3563096027 | **재분류(2026-07-27 재검): 실회귀 아님 — 표 아래 각주 참조** |

**재판정(B4-④, 2026-07-27, main 6526db1)**: 3489263099·3465215190 둘 다 위 목록에서 **제외**.
루트코즈 수정(2e09d84, W0b-H3 — spriteTrailStretch가 length 부재 시 곱 항등 1로 폴백해 전형적
속도가 그대로 [minlength,maxlength]에 밀려 들어가 항상 maxlength로 포화되던 버그를 "length 부재
모집단만 신장 자체를 정의하지 않고 항등 1 반환"으로 교정)이 W2-①(alpharandom 기본값 재원복)·
C2(y-up) 위에 이미 병합돼 있었고, 해당 커밋이 스스로 명시한 잔여 재확인 항목("W2① 착지 후
3465215190·3489263099 재캡처로 H3 판정 재확인 필요")이 이번 라운드까지 누락돼 있었다. 960×540
재캡처 + 240×136 동일 해상도 페어 비교(구 베이스라인 95fad7a 대비 업/다운샘플 아티팩트 배제) 결과:
3489263099는 창밖 도시 건물·창문 조명·달·별이 또렷이 보이는 가는 빗줄기(구 HEAD 회귀의 "불투명
흰 블롭"이 도시를 가리던 증상 소멸), 3465215190는 우산·인물·계단 난간·출구 표지판이 성긴 빗줄기
사이로 온전히 보임(구 베이스라인의 촘촘한 격자형 스트라이프 대비 개선 — NEAREST 4배 확대 비교에서
드러난 스트라이프는 240×136 원본 자체의 저해상 앤티에일리어싱 아티팩트였음, 동일 해상도 페어
비교로 정정). 표준 baseline manifest 실측 meanLuma(참고용, 방향성 보조지표 — "블롭이 가림→값이
크다" 식 직접 등가는 아님): 3489263099 0.2297(95fad7a)→0.1030(6526db1), 3465215190
0.4320(95fad7a)→0.1970(6526db1) — 둘 다 어두워짐, 두 씬 모두 흰 스트릭이 화면을 뒤덮던 구간이
줄고 성긴 개별 줄기로 바뀐 육안 관찰과 같은 방향. 1차 근거는 위 육안 크롭 대조이며 meanLuma는
보조 정합 확인. WE preview.gif(정적 프레임)와도 스타일 합치. 코드 변경 없음(재판정 전용, 문서만
갱신 — 실 수정은 2e09d84에 이미 존재).

> **3563096027 재검 각주**: 최초 판정("tint R 채널 누수: (74,21,74) vs 베이스라인 (20,19,74),
> BLENDMODE 12 용의")은 "고정 캡처 시각이 이 씬의 저녁 트리거 창(21시)과 우연히 겹쳐 알파가
> 과다 적용됐다"는 하네스-타임존 가설로 종결 시도됐으나 반증됨 — 캡처 시각 고정 커밋
> `4c8debb`가 베이스라인 95fad7a·HEAD 양쪽의 공통 조상이라(`git merge-base` 확인) 두 캡처의
> `Date`는 동일(둘 다 KST 21:00)이고, 스크립트도 `fadeValue += engine.frametime` 1회 호출로
> 포화되는 구조라 "램프 속도 차이"로는 델타를 설명 못 한다.
>
> 검증해야 할 가설은 "베이스라인에서 이 레이어/스크립트가 비활성이었고 HEAD에서 활성화됐다"
> (C8 가시성 상속 또는 `visible.user.condition` 게이트 변경)였다 — 둘 다 기각됨. **C8**(비가시
> 조상 자식 컬링, 커밋 `90dbb2f`)은 id=25/134/211/149/126 이 scene.json 상 `parent` 필드 없는
> 최상위 오브젝트라 적용 대상이 아니고, 설사 적용됐어도 방향이 반대(비가시화 쪽)라 "활성화"를
> 설명 못 한다. **`visible.user.condition`**(콤보 `background`, 조건 `'5'`="FULL CYCLE")은
> project.json `general.properties.background.value`가 애초부터 `"5"`(저작 기본값, C①
> 적용 전후 무관)라 이 5개 레이어의 정적 가시성은 베이스라인·HEAD 양쪽 다 `true`로 동일 —
> 플립 없음. 즉 가시성 경로가 아니라 **알파 스크립트의 수치 결과**(아래)가 원인이었다.
>
> 실제 원인은 렌더 결함이 아니라 **베이스라인 쪽의 선행 버그가 HEAD에서 고쳐진 것**이다.
> id=134 `'Фото Фон вечер'`(저녁 배경, tint 이펙트 BLENDMODE 12 자홍 `0.502/0/0.502`) 레이어의
> `alpha` 프로퍼티 스크립트는 `hours>=21 && hours<24` 조건에서 `fadeValue`를
> `engine.frametime`만큼씩 누적해 0→1로 페이드인한다(`update()`의 반환값이 그대로 레이어
> alpha에 바인딩됨 — 스크립트 자체의 `thisLayer.opacity = …` 대입은 WE `ILayer`에 `opacity`
> 프로퍼티가 없어 무효과, 각주 대상 아님). `WapleCompat`의 `captureFrames`는 씬을 프레임 단위로
> 재생하지 않고 마운트 직후(`runtime=0`) 목표 시각(`captureT=6.0`)에 대해 프로퍼티 스크립트를
> **단 한 번** 평가한다(`SnapshotPipeline.swift` `captureFrames(..., times: [captureT], ...)` —
> 단일원소 배열, 확인 완료). `engine.frametime`을 실델타(`t − 직전 t`)로 갱신하는 F700
> (`TextScriptEngine.swift` `__setRuntime`, 커밋 `9af7704`) 적용 이전(베이스라인)에는
> `frametime`이 초기값 `0.016`에 고정돼 있어 이 단발 평가가
> `fadeValue`를 겨우 `0.016`(1.6%)만 올렸다 — 저녁 레이어가 사실상 미발화한 채로 야간
> 레이어(id=25, 스크립트 없이 항상 on, 청색 tint)만 지배적으로 남아 "청색" 결과가 나왔다.
> F700 적용 이후(HEAD)에는 같은 단발 평가에서 `frametime = 6.0 − 0 = 6.0`이 되어
> `fadeValue`가 즉시 1.0으로 포화 → 저녁 레이어가 완전히 페이드인해 "자홍" 결과가 된다.
>
> WE 공식 타입 선언(`d.ts:2492`, `frametime`="Last frametime in seconds")과 대조하면 F700의
> 실델타 갱신이 WE 계약에 맞는 쪽이고, 실제 라이브 WE에서도 21:00를 넘겨 6초 이상 지속
> 재생됐다면(60fps 기준 frametime≈0.016을 수백 회 누적) 이 저녁 레이어는 동일하게 완전
> 포화된다 — 즉 **HEAD(자홍)가 WE 정합, 베이스라인(청색)이 F700 이전 프레임타임 버그의
> 부산물**이었다. 코드 수정 없음(문서 재분류만) — 하네스 자체의 구조적 취약점(캡처 시각이
> 씬 트리거 경계에 얹혀 정확히 이 지점에서만 관측됨)은 [BACKLOG.md](../BACKLOG.md) "하네스"
> 절에 별도 등재.

## 7. 수정 로드맵

1. **1차 스웜 (저위험·고효과)**: C1 텍스트 플립 + C4-(i) 알파 기본값 + C5 텍스트 parent + C8 가시성 상속 — 50+ 씬 개선 예상
2. **2차 스웜 (대형)**: C2 Y축 전역 플립 — 전수 부호 목록·검증 게이트 7씬 지정됨(§3-C2)
3. **3차**: C4-(iii) REFRACT + C4-(ii) overbright + C6-(i) shared.camera + C6-(iii) 프로퍼티 기본값(전량 재감사 동반)
4. **별도 조사 트랙**: D2 콘텐츠 v-플립(런타임 이분), generic4 빌트인 정책, 이펙트 개별 결함군, 3D/소수 클러스터
5. 각 수정은 회귀 테스트(TDD) + 해당 씬 재캡처 before/after로 검증. 최종: 전체 170씬 재캡처 → 신규 베이스라인 + 최종 리포트

## 8. 검증 게이트 씬 (수정 검증용 고정 세트)

| 씬 | 용도 |
|---|---|
| 3397690043 | RenderDoc 골든 — 유일한 실물 WE 프레임 대조 (C2 최우선) |
| 3373818743 | ortho 3D hybrid |
| 3644280276, 1412044563 | 2D y-up 대표 |
| 3463520581 | 퍼펫 회귀 게이트 |
| 2325500626 | 무회귀 대조(중심 구성) |
| 3483456356 | 바이닐 위젯 신규 노출 확인 |
| 3448877775 / 3367988661 | C1 텍스트 플립 (독립 프로브 보유) |
| 3416122407 / 2904908532 | C4-(i) bokeh 백화 |
| 3659877246 / 3701356561 | C5 텍스트 parent (후자는 부모=텍스트 변종) |
| 3299228616 | C8 가시성 상속 |
| 3019043758 | C4-(iii) REFRACT |
| 3302695207 | C6-(iii) 프로퍼티 기본값 |
| 3737268876 | C6-(i) shared.camera |

---

## 9. 씬별 실패 색인 (111씬 — Phase 1 verdict 요약)

| 씬 | 판정 | 신뢰도 | 1차 원인(Phase 1 귀속 — §5 기각분은 §3/§4 재분류 참조) |
|---|---|---|---|
| 1412044563 | geometry-wrong | high | SceneRenderer 레이어 변환(씬 좌표 Y축 규약 — WE y-up origin을 y-down으로 해석) |
| 2111201226 | flipped-v | high | text-render (TextRasterizer → 텍스트 쿼드 샘플링 V 규약 / 텍스트 각도 처리) |
| 2593802559 | flipped-v | high | SceneRenderer 2D 투영/변환(Y축 규약) + TextRasterizer(글리프 V플립) |
| 2809885105 | partial | high | text-rendering (TextRasterizer 텍스처 row 규약) |
| 2842323353 | flipped-v | high | puppet 렌더 경로 (SceneRendererFrameEncoder.puppetVertices) |
| 2867182492 | flipped-v | high | scene-render 2D 좌표계(Y축 규약) + text-render V 규약 |
| 2881558311 | black | medium | media/audio-script 런타임(미디어 썸네일·오디오 버퍼·미디어 메타데이터) + 스크립트 텍스트 |
| 2885492021 | geometry-wrong | high | 씬 레이어 배치 — origin.y 좌표계(WE 데이터=하단 원점 y-up, 렌더러=상단 원점 y-down 해석) + 텍스트 h-flip(부결함) |
| 2902406982 | partial | high | effect pipeline (translated shader — clipping_mask 클리핑 의미론 미구현/사일런트 실패) |
| 2904908532 | color-wrong | high | particle (genericparticle 머티리얼 상수) |
| 2947302287 | partial | high | WapleRender hand-port effect texture binding (SceneRendererResources.buildHandPortEffect + |
| 2981249186 | flipped-v | high | TextRasterizer/텍스트 쿼드 V 규약 |
| 3000562427 | black | high | layer placement (quadVertices/alignedCenter — non-center 앵커/원점 y 해석) |
| 3019043758 | partial | high | WapleRender 파티클 REFRACT 경로 (ParticleShaders.pf_refract / encodeDrawPlan refract 게이트) |
| 3047405322 | flipped-v | high | 텍스트 래스터/쿼드 Y 규약(TextRasterizer row0=top 출력과 쿼드 UV 샘플링 불일치 추정) + 레이어 origin Y 미러(1412044563 |
| 3113287126 | flipped-v | high | SceneRenderer 2D 레이어 Y축 변환 (씬 좌표계 v-flip) |
| 3146703458 | partial | high | text layer 렌더 (WapleCore SceneTextLayer / WapleRender encodeText) |
| 3147346398 | geometry-wrong | high | WapleRender scene transform + text rasterization |
| 3151551777 | garbled | high | 파티클 렌더러(주범) + 텍스트 래스터 V방향(부범) |
| 3171024295 | garbled | high | effect (GLSL→MSL translated shader) |
| 3174556087 | flipped-v | high | TextRasterizer/텍스트 텍스처 V 규약 |
| 3189665546 | flipped-v | high | puppet 렌더 경로 (puppetVertices의 y 부호 반전 가정) — 2842323353과 동일 근본 추정 |
| 3195212886 | flipped-v | high | SceneRenderer 2D 레이어 Y축 변환 (씬 좌표계 v-flip) |
| 3233141951 | partial | medium | 오디오-반응 이펙트(번역 GLSL)의 무신호(idle) 앰플리튜드 처리 — 진폭 0에서 바가 0높이로 붕괴하지 않고 풀 렌더 |
| 3250755486 | partial | high | 이펙트 합성 (opacity mask 패스의 알파 채널 손실) |
| 3257043844 | geometry-wrong | high | 모델(퍼펫) 레이어 변환 — WapleCore PuppetModel/PuppetPose + WapleRender 모델 레이어 경로 |
| 3276911872 | partial | high | effect (GLSL→MSL translated) |
| 3287715210 | partial | high | ① text-rendering v-플립(공통) ② compose/effect 패스 V 규약 또는 composelayer 회전 미적용 |
| 3292508781 | flipped-v | high | text rasterization/UV (텍스트 텍스처 상하반전) |
| 3299228616 | partial | high | WapleCore SceneDocument/WapleRender 레이어 가시성(parent 상속) + 텍스트 레이어 렌더링 |
| 3300031038 | garbled | medium | 스크립트 바인딩 프로퍼티 정적 기본값 사용(WEColor 팔레트 공유값 미해석) + 텍스트 렌더러 V-플립 |
| 3302695207 | partial | medium | 프로퍼티/스크립트 시스템 (user-property 바인딩 해석) |
| 3351163962 | flipped-v | high | TextRasterizer/텍스트 텍스처 V 규약 |
| 3351179520 | garbled | high | WapleRender ortho(2D) 레이어 배치/텍스처 V축 처리 — 초광폭(5120x1440, 32:9) 씬. 기반 배경(背景, refraction 이펙트  |
| 3352517853 | partial | high | 텍스트 렌더 파이프라인(TextRasterizer → encodeText 쿼드 V 방향) |
| 3353695150 | partial | high | 솔리드 레이어 크기/불투명도 처리 — WapleRender 레이어 렌더러의 solidlayer(models/util/solidlayer.json) size/sca |
| 3354366708 | color-wrong | medium | 레이어 텍스처/블렌드 파이프라인(알파·프리멀티 또는 밝기 누적 의심) + TextRasterizer V 규약(텍스트) |
| 3363252053 | flipped-v | medium | 씬 좌표 Y축 규약(레이어 origin/배치 y-up↔y-down — 1412044563·3047405322와 동일 계열) + 텍스트 래스터 Y 규약 |
| 3363473482 | flipped-h | high | 텍스트 래스터/쿼드 경로(TextRasterizer → SceneRendererResources.rasterize → encodeText) |
| 3367988661 | flipped-v | high | 텍스트 래스터라이저 (Sources/WapleRender/TextRasterizer.swift:149-157) |
| 3373818743 | flipped-v | high | WapleRender F721 ortho 3D hybrid 투영 경로 (orthogonalprojection 2D 씬 + .mdl 모델 오브젝트) |
| 3379048027 | flipped-v | medium | 텍스트 레이어 스케일/반전 평가 (TextScriptEngine miText 패밀리 스크립트 또는 TextRasterizer 방향) |
| 3385540784 | partial | high | 텍스트 렌더러(래스터 좌표계) — glyph 상하반전 |
| 3388330010 | geometry-wrong | high | depthparallax 이펙트(번역 셰이더)의 스케일/오프셋 계산 |
| 3394601417 | partial | medium | 후처리/글로우 체인(godrays·fullscreen 후처리층) + 스크립트 구동 애니메이션 상태 |
| 3395777145 | flipped-v | medium | TextRasterizer/텍스트 쿼드 V 규약(2981249186과 동일 전역 버그) |
| 3396722575 | partial | medium | particle renderer (sprite-sheet frame selection) + text content script 미실행 |
| 3397690043 | geometry-wrong | high | 2D 씬 y축 매핑(quadVertices/pxToNDC 의 y-down 가정) + TextRasterizer 글리프 행 순서 |
| 3400879974 | flipped-v | high | 텍스트 래스터/렌더 파이프(TextRasterizer → GPUText rasterize/vbuf)의 수직 방향 컨벤션 — 글리프가 상하 반전되어 출력(이미지 레 |
| 3407317466 | partial | high | texture decode / spritesheet (.tex TEXS) |
| 3413921910 | flipped-v+garbled | high | SceneRenderer 2D ortho 레이어 Y축 매핑 (씬 픽셀 y-down 가정) + 개별 레이어 텍스처 샘플링 |
| 3416122407 | garbled | high | 파티클 렌더(ParticleSimulator 알파 해석 + additive 합성) |
| 3417957645 | partial | high | 텍스트 레이어 렌더링 — TextRasterizer 출력 텍스처/쿼드의 수평 반전 처리(WapleRender 텍스트 경로) |
| 3429479356 | partial | medium | (a) 텍스트 프로퍼티 스크립트 사이드이펙트/시간 모델: visible 스크립트가 engine.frametime 누적 타이머+thisLayer.alpha 대입으로 |
| 3441006668 | flipped-v | high | WapleRender ortho(2D) 씬 레이어 origin Y 매핑(씬 픽셀→NDC 배치) — 이 씬 데이터는 WE가 y-up(projH-y)으로 배치하는 것 |
| 3444535389 | geometry-wrong | high | WapleRender puppet/model pose (SceneRenderer puppet cascade) 또는 cropoffset-포함 모델 배치 |
| 3445534475 | garbled | high | 텍스트 렌더러 (글리프 쿼드 v-flip) + 스크립트 구동 부모(组件) 변환 체인 (스케일/위치) |
| 3448290956 | geometry-wrong | high | 2D 레이어 배치/트랜스폼 (SceneDocument.parseLayer 원시 origin 사용 + composeParentTransforms 부모체인 합성 +  |
| 3448877775 | garbled | high | WapleRender 텍스트 래스터 — TextRasterizer.render 의 상하반전(flip) 패스 (Sources/WapleRender/TextRaste |
| 3450697231 | geometry-wrong | high | WapleRender scene transform (layer origin Y-convention) |
| 3454792257 | partial | high | 텍스트 레이어 렌더링 수평 미러 — TextRasterizer/텍스트 쿼드 변환 경로(WapleRender 텍스트 서브시스템) |
| 3460973721 | partial | high | effect-layer / text-layer rendering |
| 3461168300 | partial | medium | 텍스트 래스터/쿼드 Y방향(TextRasterizer/encodeText) + Puppet 스키닝 + user-property fallback |
| 3462491575 | partial | high | WapleCore SceneDocument — SceneTextLayer 에 parent 필드 부재 |
| 3463520581 | geometry-wrong | high | WapleCore SceneDocument 변환 베이크(origin/cropOffset) 및 WapleRender 쿼드 배치의 씬 Y축 처리 + 퍼펫 어태치먼트  |
| 3465215190 | geometry-wrong+regressed | medium | particle system (빗줄기 스프라이트 스케일/불투명도 또는 블렌딩) |
| 3470948192 | black | high | 3D 메시 커스텀 머티리얼 셰이더(번역 경로) + 스크립트 구동 노드 |
| 3477054430 | partial | medium | 3D camera framing (eye/center/fov interpretation) + generic4 mesh shader fallback (emissiv |
| 3478434536 | partial | medium | WapleRender compositing/blend of scripted container group + text raster Y-flip |
| 3486806915 | garbled | medium | text layer (TextRasterizer + 스크립트 바인딩 origin/scale 평가) |
| 3489263099 | regressed+garbled | high | particle |
| 3492627662 | partial | medium | 텍스처/머티리얼 바인드(WapleRender texture resolve 또는 model-material 해석) — 머리 파트 레이어 |
| 3509243656 | partial | high | 1) 블룸(LDRBloomPass/HDRBloomPyramidPass) 과다 적용 2) 3D 메시 파이프라인(SceneRenderer3D) — WE 빌트인 gen |
| 3510729512 | garbled | high | 텍스트 렌더(TextRasterizer — 커스텀 폰트 fonts/2.ttf 글리프) + 스크립트 컨테이너 스케일 합성 |
| 3516106265 | geometry-wrong | medium | text-rendering (TextRasterizer 상하반전 규약) + 텍스트 레이어 부모 트랜스폼 미합성 |
| 3516174947 | flipped-v | medium | text rasterization/UV (텍스트 텍스처 상하반전) |
| 3517818807 | partial | high | 2D image layer transform/blend (genericimage4 머티리얼) |
| 3521337568 | flipped-v | high | 씬 좌표 Y축 규약(레이어 origin y-up↔y-down — 같은 샤드의 1412044563/3047405322/3363252053와 동일 계열) + comp |
| 3526096300 | geometry-wrong | high | WapleRender scene transform Y-convention + text raster flip |
| 3538758087 | partial | high | 스크립트 엔진 + 텍스트 레이아웃/위젯 상태 평가 (부모 미러 scale -1, 스크립트 scale/origin/visible, NSL 타임라인) |
| 3543159422 | garbled | high | WapleCore/WapleRender 2D 퍼펫-컷아웃 부모-자식 레이어 합성 (composeParentTransforms) 및/또는 parented autos |
| 3544152633 | garbled | high | translated-GLSL effect chain on music-player compose/solid layers (effect visibility gatin |
| 3544823846 | partial | high | ① 레이어 이펙트 체인 (foliagesway 버텍스 이펙트 3연 체인 — 레이어 통째 드롭 추정) ② 파티클 렌더러 (Bokeh/Lens Flare 계열 크기· |
| 3550590706 | geometry-wrong | high | WapleCore 모델 cropoffset/레이어 배치(SceneDocument.swift:161-172, F751(S-20): '쿼드 배치는 cropOffset |
| 3558034522 | garbled | medium | 파티클 렌더러 — additive 블렌딩/알파페이드 미적용(스프라이트 파티클이 불투명으로 출력) |
| 3563056203 | partial | high | WapleRender 퍼펫(.mdl 스키닝) 파이프라인 + TextRasterizer(글리프 V플립) |
| 3563096027 | partial | medium | 이펙트 렌더러 — tint 이펙트 BLENDMODE 12(색상 채널/블렌드 처리), 회귀 의심 |
| 3565190341 | flipped-v | high | SceneRenderer Y축 변환 (v-flip) + composelayer 오프스크린 합성 (그룹 콘텐츠 플립/불투명) + 레이어 컬러/합성 모드 |
| 3573378561 | flipped-v | high | puppet 렌더 경로(캐릭터) + 텍스트 레이어 미러링(별개 증상) |
| 3589454154 | garbled | high | WapleRender 3D 메시 파이프라인(mdl 로드/메시 셰이더) |
| 3602673806 | geometry-wrong | high | WapleCore/WapleRender 씬 Y축 배치(top-level) + 퍼펫/부모 상대 자식 변환 |
| 3605722997 | black | high | video texture headless pipeline (SceneVideoLayer/VideoTextureExtractor → buildDisplayTextu |
| 3616389236 | partial | medium | script-bound property evaluation (TextScriptEngine) + user-prop conditional visibility |
| 3629379075 | garbled | high | 커스텀 이펙트 번역 경로의 blurprecise — 레이어 로컬이 아닌 풀프레임 블러로 적용(WapleRender 이펙트/GLSL 번역 서브시스템) |
| 3640755971 | partial | medium | 솔리드(纯色) 레이어 + 커스텀 이펙트 체인(texture_override/auto_sway/워크숍 3221939295) 미적용 — 'flat' 레이어 셰이더 소 |
| 3641860575 | garbled | high | 텍스트 레이어 이펙트 체인(F741) + 텍스트 쿼드 지오메트리 + visible=false 무시 |
| 3644280276 | geometry-wrong | high | 씬 레이어 배치 — origin.y 좌표계(WE 데이터=하단 원점 y-up, 렌더러=상단 원점 y-down 해석) |
| 3659877246 | partial | high | WapleCore SceneDocument — SceneTextLayer parent 미파스(트랜스폼 계층 드롭) |
| 3660962877 | black | high | WapleRender layer transform: alignment anchor sign inversion (SceneRendererFrameEncoder.al |
| 3662790108 | garbled | high | 스크립트 shared 버스(3D 씬 스크립트 평가) — 1차; 커스텀 메시 셰이더 경로 — 2차 |
| 3663810817 | geometry-wrong | high | 씬 레이어 배치 — origin.y 좌표계(y-up 데이터를 y-down으로 해석) + 텍스트 h-flip |
| 3665954520 | color-wrong | high | effect-chain (GLSL→MSL 번역 셰이더) |
| 3687818927 | flipped-v | high | scene-render 2D 스프라이트 배치(Y축 규약) — 레이어별 반전 불일치 |
| 3690417937 | geometry-wrong | high | 2D 씬 y축 매핑(quadVertices/pxToNDC 의 y-down 가정) — 3397690043 과 동일 근본 원인 |
| 3691570025 | geometry-wrong | high | WapleRender scene transform Y-convention (+ text raster flip) |
| 3696323523 | flipped-v | high | text rasterization (TextRasterizer) — 상하 반전 처리 |
| 3701356561 | partial | high | WapleCore parent 체인 합성(composeParentTransforms) + 텍스트 h-flip |
| 3706286085 | black | high | GLSL→MSL 번역 이펙트(3D 풀스크린 포스트 체인) |
| 3713073223 | partial | high | 미디어 상태 스크립트(alpha 바인딩) + 오디오-반응 이펙트 무신호 처리 + 커스텀 폰트 텍스트 래스터 |
| 3737268876 | geometry-wrong | high | 스크립트 침하라(WapleRender TextScriptEngine/SceneRenderer — shared.camera 쓰기 미소비) |
| 3753921460 | geometry-wrong | high | text raster/draw path |
