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
| 3D 메시 라이팅 | 코퍼스 5씬 | 2D 포워드 라이팅(`f_lit`)은 완료. 3D 메시는 unlit(Mesh3DShaders). 실물 규약 유니폼 팩(SceneLight3D.packUniforms)은 이미 있음 |
| HDR/톤맵 | 라이트 씬 일부 | intensity>1(실측 최대 9.84) LDR 클램프 백화. 2D 라이팅 커밋에 한계 기록 |
| 원근 태양계 라이팅·노멀맵 1건·스팟 콘 | 각 1씬 내외 | 2D 라이팅 SP 잔여 목록 |
| 파리티 상위 각개 진단 | 2902406982(0.37) 등 | 방법: rank.py 랭킹 → drawPlan prefix 이분 → SKIP 노브 |

## 잠재 결함 — 트리거: 실제 파일/사용에서 물릴 때

- **PuppetModel 2D cstring Latin-1 3곳** → CJK 머티리얼 경로 mojibake·흑화면 ([PuppetModel.swift](Sources/WapleCore/PuppetModel.swift):110,162,190). `String(decoding:as: UTF8.self)` 통합으로 해소. 코퍼스 현재 0건
- **combo Picker 값-타입 불일치** → 편집기 무선택 표시 ([WallpaperProperties.swift:67](Sources/WapleCore/WallpaperProperties.swift:67) — 옵션만 `type:""` 파싱)
- **GLSL vert/frag 공용 헬퍼의 스테이지별 하위 헬퍼 호출 리네임 누락** ([GLSLTranslator.swift:155](Sources/WapleCore/GLSLTranslator.swift:155)) — 2026-07-11 리뷰 #11, 추정 단계(재현 셰이더 미확보). 공용 헬퍼가 radial_blur식 스테이지별 computeUV 를 부르는 셰이더에서 frag 가 vert 버전을 받으면 조용한 오렌더 — 실물에서 관찰되면 착수
- **셰이더 멀티라인 매크로 "호출" 미확장** ([ShaderPreprocessor.swift](Sources/WapleCore/ShaderPreprocessor.swift) `spliceDefineContinuations` ponytail 주석) — `#define` 줄연속은 2026-07-11 해소, 인자가 여러 줄에 걸친 호출은 실입력 미확인이라 유보
- **FFmpeg `converted/` 캐시 무한 증가** ([FFmpegConverter.swift](Sources/WapleRender/FFmpegConverter.swift)) → 디스크가 차면 `VideoTextureExtractor.evictOldest` 재사용
- **볼륨/배속 변경 = 렌더러 전체 재장착**(재생 리셋) ([AppDelegate.swift](Sources/Waple/AppDelegate.swift) setVideoVolume/Rate) → mkv/webm 실사용에서 거슬리면 `queue.volume`/`defaultRate` 라이브 반영으로
- ~~LibraryStore.remove 부재~~ → **해소(2026-07-12 SP2′)** — `remove(id:)` + 재생목록/모니터/즐겨찾기/폴더 orphan 정리
- 기타 low 항목은 [AUDIT.md](AUDIT.md) §1–3 참조 (inferStride 재검증, 리싱크 오인, LE 리더/cstring 중복 등)

## 제품화 — 트리거: 배포 결심

1. ~~notify() NSLog-only~~ → **부분 해소(2026-07-12 SP1′)**: 메인창 열림 시 창 내 배너(StatusBanner)로 표시. 잔여: 창 닫힘 상태의 오류는 여전히 NSLog only → UNUserNotification 승격은 배포 결심 시
2. 최초 실행 온보딩 + base-assets/ffmpeg 미설정 안내 (현재 조용한 저하)
3. CI 구축 — 현재 저장소에 CI 자체가 없음. `.saver`(WapleSaverView.m) clang 컴파일 스텝 포함(현재 `swift test` 커버리지 밖)
4. LICENSE 결정 (README "미정")
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
| 정리: 본체인 fold 6회·DXT 3벌·Process 헬퍼 3벌·JS 리터럴 4중·효과체인 루프 4중복·죽은 코드(resolveProjects, bitsRemaining, 미발행 이슈코드 8종, CLI 도움말) | — | 기회 시 |

## 하네스 — 트리거: 게이트 오탐/소요가 거슬릴 때

- **벽시계(Date) 오염** — 씬 스크립트 JS `Date`가 미스텁이라 시계 텍스트 씬(회귀 FAIL 58 중 45건 보유)의 diff에 캡처 시각차가 섞임(실측: 3047405322 mean 13.05가 전부 시계였음, 2026-07-11 판독). 같은-분 셀프체크는 "결정"으로 오분류. 수정 방향: 캡처 경로에서 shims에 Date 고정 주입 또는 시계 스크립트 보유 씬을 lax 버킷으로
- 스냅샷 드리프트 2씬(3000562427, 3448290956) 부하 내성 — 순정에서도 요동하는 크로스-프로세스 비결정, 현재는 판독 시 제외 규약
- GT 인-테스트(debug, ~35분 추정)를 release `WapleCompat --capture/--compare` 게이트(6분)로 이관하고 debug GT 슬림화 검토
- 초대형 멀티페이지 스프라이트 스트리밍(6씬 정지 폴백 해제), scriptproperties 주입(중국 2패키지), TEXS 회전 실물 검증(코퍼스 0건)
