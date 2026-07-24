# 씬 구현 심층 감사·수정 기록 (2026-07-21)

> 대상: 씬(Scene) 구현 전반 — WapleCore 파스/파티클/번역기, WapleRender 씬 렌더러/3D/텍스트/컬러
> 방법: 실물 코퍼스(~/Downloads/wallpaper_dev, 460 프로젝트) 정적 분석 → 발견 → 워크트리 병렬 수정 → 통합 → 전수 검증
> 상태: 완료 (최종 검증 결과는 §5)

## 1. 개요

유지보수 모드 진입(2026-07-10) 이후 씬 구현을 대상으로 한 가장 큰 규모의 감사·수정 라운드.
2026-07-16 RE 캠페인 로드맵(P0~P2.5)이 이미 흡수된 상태에서, **현재 코드 기준의 신규 정적 분석**을 수행했다:

- 1차 스웜(10 에이전트): WapleCompat --deep 기계 스캔(460 전수 실파스/디코드/번역/컴파일) + 코퍼스 센서스 4분할 + WE 참조 문서 대조 시맨틱 검토 5축
- 발견 **109건**(high 13 / medium 37 / low 59) → `/tmp/scene_deep_findings.md`(휘발)
- 2차 스웜(9 그룹) + 통합 스웜(3 그룹) + 회귀 수정 1건으로 전량 처리

## 2. 수정 내역 (영역별, F번호)

### 비디오
- **F600** hev1(hvcC 없는 HEVC) mp4 재생 불가 감지 — 로드한 `isPlayable` 실사용으로 F550 ffmpeg 회복 발동(종전: 검은 화면+오디오 정지, 3448728208)

### 번역기 (F610~F618)
- F610 `#if` 양분기 바이트 동일 시 관용(uniform 멤버 비교 실물 대응) · F611 `#if/#elif` 후행 `;` 절단 · F612 삼항 스칼라:벡터 스플랫(무개입) · F613 g_Color4 중립값 · F614 g_Screen 분류/치환 · F615 isIntLiteral 부호 허용 · F616 본문 배열 생성자 brace-init · F617 텍스처 슬롯 숫자부 한정 · F618 g_PointerState sizeEnv

### 파티클 (F620~F631)
- **F620** 이미터 speedmin/speedmax 파스+스폰 초기속도(35씬 물발화 해소 — fireworks/벚꽃) · **F621** burst+rate 병행(9씬 연속 방출 소실 해소) · F622 randomframe 스폰 시 프레임 확정 + sequence/multiplier 파스 · F623 flags 파스 · F624 vortex 오디오반응 · F625 trailSampleCount 24→240 · F626 orientation 파스 · F627 boxrandom distancemin AABB · F628 다중 turbulence 누적 · F629 rope subdivision→샘플 수 · F630 mapsequence axis 회전 평면 · F631 vortex_v2 → vortex 근사 매핑

### 씬 문서/포맷 (F690~F697)
- **F690** TEXS frametime==0 프레임 허용(종전 시트 전체 폐기 → 파티클 찌그러짐, 2씬) · F691 2D 포워드 라이트 parent 변환 합성 · F692 perspective:true/overridefov 파스·보존 · F693 텍스트 effects[] 파스·보존(113건/16wp) · F694 대입 삼항 조건식 truthy 근사(토글 은닉 해소) · F695 general.zoom 파스 · F696 dependencies 파스 · F697 이펙트 패스 usertextures 필드

### 텍스트 스크립트 엔진 (F700~F713)
- **F700** engine.frametime 실델타화(83/169씬 2배 지연 해소) · **F701** localStorage 실심(31씬 init 사망 해소) · **F702** applyUserProperties 원시값 계약(58씬 비교 NaN 해소) · F703 input 실심(cursorWorldPosition 등) · F704 getTransformMatrix · F705 getAnimationLayerCount · F706 thisLayer 인덱스 바인딩 · F707 updateSceneLayers 라이브 갱신 · F708 getParent 체인 · F709 init 반환값 캐시/init-only 서빙 · F710 engine.timeOfDay · F711 setTimeout/setInterval 취소 관용구 · F712 Vec3 normalize/reflect · F713 WEVector 실심(angleVector2 도 단위)

### 씬 렌더러 (F720~F724)
- **F720** 2D `_rt_imageLayerComposite_*` 샘플러 바인드(종전 미바인드 Metal 검증 실패+콘텐츠 소실, 8wp) · **F721** ortho 씬 3D 메시 하이브리드 적재(.mdl 드롭 해소, 3354366708) · F722 $mediaThumbnail/$mediaPreviousThumbnail GPU 바인드(라이브 앨범아트) · F723 thisLayer 대입 read-back(드래그 컨트롤러, 23~28씬) · F724 텍스트 콘텐츠 스크립트 매 프레임 재평가(1Hz 게이트 제거)

### 3D/라이팅 (F660~F662, F730~F733, F750)
- F660 라이트 캡 4→8(젤다 태양+Navi) · F661 directional 단일 오소 섀도우(캐스터+리시버 AABB 타이트핏) · F662 scene fog + FOG 콤보(common_fog.h 정합, per-mesh FOG:0 오브아웃)
- F730 3D 파티클 sequence/배속 소비 · F731 worldspace 우회(bit1) · F732 upright/fixed 축 빌보드 · F733 3D 빌보드 `_rt_` 바인드
- F750 CSM/볼류메트릭 필드(cascadedistance0-2/castvolumetrics/exponent/density) 파스·보존

### 컬러/블룸 (F670~F676)
- F670 LDR 추출 탭 ±1.5→±1.0텍셀(WE downsample_quarter 정합 — 고휘도 쉬머 해소) · F671 첫 블러 스트라이드 2 quarter-texel(σ 21% 좁던 글로우) · F672 tint 폴터 기본 BLENDMODE 30 · F673 HDR 추출 탭 ±1.0 · F674 pulse 위상 radian 직결 · F675 HDR 최종 알파 1.0 · F676 we_rgb2hsl saturate(HDR 잠복 봉인)

### 개발 도구/웹 (F680~F682, F760)
- F680 inventory/profile 공유 에셋 리졸버(layers=0 오집계 해소) · F681 deep-scan ogg 시간 예산(WAPLE_DEEP_OGG_BUDGET) · F682 웹 visibility 스푸핑(pause↔hidden+visibilitychange)
- F760 마운트 라이프사이클 픽스처를 원시값 계약으로 정합화(회귀 수정 — 프로덕션 물결함 확인)

## 3. 기각/유보 (사유 있는 미수정)

- S-9 2D spot/directional: 설계 문서상 angles 규약 미확정으로 의도적 보류(레시피를 QuadShaders.swift:109-119 주석에 인계)
- S-44 REFLECTION SSR: mipmapped 프레임버퍼 필요+3씬은 2D 경로 소유권 블록 — 충실도 낮은 근사 거부
- S-20 cropoffset: F751로 **의미 확정 후 파스**(크롭 중심 오프셋, 0.5 배수 정량화) — 런타임 적용은 실렌더 A/B 후속
- S-27 tvr 기본 speed: 코퍼스 전건 turbulence 병존 실측 반증
- S-25 spritetrail 정식 의미(속도-신장 렌더): 별도 렌더 경로 필요로 후속
- S-72 oscillateposition 단위: F184 확정 경로와 상충, 재측정 필요
- localStorage 디스크 영속: ~~현재 인메모리~~ → **F810(2026-07-23) 해결** — 라이브 마운트 한정 Application Support/Waple/script-storage/<씬 id>.json 영속(디바운스+teardown flush)
- S-11 원근 렌더 적용: 현 코퍼스 x/y angles 전부 0이라 실피해 0 — 파스만

## 4. 잔여 후속 과제 (트리거 시)

- F750 소비: 단일 오소 → cascadeDistances 기반 3-스플릿 CSM, 볼류메트릭 라이트샤프트
- 텍스트 이펙트 texRes 초기 래스터 dims 베이크(동적 길이 텍스트)
- updateSceneLayers 1프레임 지연(같은 프레임 내 교차 읽기 극단)
- 3D 빌보드 변환의 라이브 채널 미기록(2D만): **F811(2026-07-23) 해결** — evaluate3DScripts 가 빌보드 상태를 liveLayerStates 에 기록, is3D 라이브/캡처 경로 모두 pushLiveSceneLayers 소비
- pulse noise/MASK 셰이더 계약 확정 후 Resources 바인딩
- F751 cropoffset 런타임 적용 여부 실렌더 A/B
- 3706286085(소닉) 균일-16 평탄 렌더 — 별도 조사(침침/지오메트리 계열 기존 이슈)

## 5. 검증

- **전체 테스트 스위트**: 1,677개 실행, **0 실패**(2 스킵은 env 게이트 정상) — WapleRenderTests 749 · WapleCoreTests 595 · WapleAppTests 271 · WapleLibraryTests 45 · WapleSnapshotTests 17
- **실물 코퍼스 GT**(RealPackagesGroundTruthTests): mounted=**170/170**, captured=170, failed=[] · luma drift 0
- **번역 거부 오발 0**: "translated MSL compile error" 0건(라운드 도중 신규 7건이 노출된 잠재 결함 2개를 F770/F771로 수습)
- **회귀 수습 3건**: F760(스크립트 픽스처 구 계약 고착 — 프로덕션 물결함), F770/F771(F741이 노출한 잠재 번역 결함: 스칼라 distance MSL 모호, 어댑터 엔진 크기 환경 누락), F772(VideoBackedSceneCaptureTests 벽시계 분 경계 오탐)
- 머지 히스토리: fix/s1~s9 → fix/i1~i3 → fix/script-regress → fix/render-regress (전부 main 병합 후 브랜치·워크트리 정리)
