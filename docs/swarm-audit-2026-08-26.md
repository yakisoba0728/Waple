# 스웜 감사 종합 — 2026-08-26 (27 워크플로우)

> **생성**: 2026-08-26 · 27개 워크플로우 × (판독 8레인 → 검증 → 종합) · **코드 미수정 — 조사·차이 확인만**
> 완주 레인 **199/224**. 미완 25레인은 추론 게이트웨이 503(`no upstream API key`) 장애로 사망 — 결함이 아니라 인프라 문제다.
> 총 발견 **1,058건**: critical 12 · high 87 · medium 325 · low 634.
> 선행 문서 [full-audit-2026-08-26.md](full-audit-2026-08-26.md) 의 후속·확장이다.

---

## 0. 워크플로우별 완주 현황

| WF | 대상 | 완주 레인 | 사망 | critical | high | medium | low |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **초기 전수감사** | Waple 소스 16레인 | 14/16 ⚠️ | 0 | 0 | 0 | 12 | 39 |
| **A** | Waple 소스 정독 8레인 | 8/8 | 0 | 0 | 1 | 5 | 26 |
| **B** | 테스트·스펙·문서 | 7/8 ⚠️ | 10 | 0 | 2 | 10 | 34 |
| **C** | WE 워크스페이스 1차 | 6/8 ⚠️ | 11 | 3 | 9 | 20 | 30 |
| **D** | 교차 대조 1파 | 7/8 ⚠️ | 11 | 0 | 0 | 18 | 43 |
| **E** | 앱 계층 | 8/8 | 0 | 0 | 1 | 9 | 27 |
| **F** | 지원 모듈·툴체인 | 8/8 | 0 | 0 | 4 | 12 | 24 |
| **G** | WE 워크스페이스 2차 | 6/8 ⚠️ | 6 | 5 | 11 | 20 | 37 |
| **H** | 교차 대조 2파 | 7/8 ⚠️ | 3 | 1 | 6 | 10 | 42 |
| **I** | CoreTests 오라클 | 8/8 | 2 | 0 | 1 | 8 | 16 |
| **J** | Render/App/Lib 테스트 | 7/8 ⚠️ | 2 | 0 | 1 | 8 | 16 |
| **K** | RE 문서 심층 | 2/8 ⚠️ | 19 | 0 | 0 | 1 | 6 |
| **L** | P2 미결질문 판명 | 6/8 ⚠️ | 5 | 2 | 4 | 9 | 14 |
| **M** | 렌더 2차 통과 | 8/8 | 1 | 0 | 2 | 11 | 14 |
| **N** | json-keys 전수 스윕 | 8/8 | 5 | 0 | 0 | 11 | 44 |
| **O** | UI 서피스 | 8/8 | 1 | 0 | 4 | 11 | 24 |
| **P** | WE 설치트리 의미론 | 8/8 | 0 | 0 | 9 | 29 | 36 |
| **Q** | 교차 대조 3파 | 7/8 ⚠️ | 3 | 0 | 3 | 13 | 18 |
| **R** | 이력문서 진실성 | 7/8 ⚠️ | 3 | 0 | 1 | 3 | 13 |
| **S** | WE 바이너리 앱계층 | 5/8 ⚠️ | 15 | 1 | 6 | 14 | 17 |
| **T** | 패키징·에셋 | 8/8 | 0 | 0 | 2 | 8 | 18 |
| **U** | WE 코퍼스 심층 | 7/8 ⚠️ | 2 | 0 | 4 | 15 | 27 |
| **V** | Swift6 준비도·위생 | 8/8 | 2 | 0 | 2 | 13 | 14 |
| **W** | 셰이더·유니폼 표면 | 7/8 ⚠️ | 3 | 0 | 2 | 12 | 7 |
| **X** | 골든·회귀 인프라 | 8/8 | 0 | 0 | 1 | 16 | 17 |
| **Y** | 오류처리·피드백 | 8/8 | 0 | 0 | 2 | 14 | 18 |
| **Z** | 횡단 통합 E2E | 8/8 | 0 | 0 | 9 | 13 | 13 |

⚠️ = 게이트웨이 장애로 일부 레인 미완주. 완주분 결과는 유효하다.

## 1. critical 12건

전부 **WE 역공학 워크스페이스(짝 저장소)** 의 근거 인프라 결함이다 — Waple 배송 코드 결함이 아니다.
그러나 Waple 소스 주석 191곳이 이 근거를 인용하므로 파급이 크다.

### [C WE] 플래그십 보고서의 "조작 증거 폐기" 선언 자체가 거짓 — rapidjson·FFTS·D:\dev 소스경로 19건이 UTF-16LE로 실존
- **좌표**: `Waple-wallpaper-source/analysis/reports/subsystems-identified.md`:7
- subsystems-identified.md 전체의 신뢰를 받치는 서두 고지("이전 보고의 증거 주장은 조작이며 바이너리에 존재하지 않는다")가 스스로 검증 오류다. 실제 바이너리(md5 일치 확인, /Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source/wallpaper_engine/wallpaper64.exe = 438cb215f20a8f6c38f57fbc3d9da588)에는 UTF-16LE로 D:\dev\we\windows\src\... 경로 19종이 있다: rapidjson 헤더 7(document.h@0x4881d0, rea

### [C WE] 디컴파일 코퍼스에 오퍼레이터 VM·파서 영역이 통째로 누락되어 있다 (할당 영역 정독 불가)
- **좌표**: `Waple-wallpaper-source/analysis/decompiled/all/`
- wallpaper64.exe 의 .pdata 를 직접 파싱하면 유효 RUNTIME_FUNCTION 14,788개(엔트리 정렬 오프셋 +4, 첫 엔트리 RVA 0x1000)가 나오고, 오퍼레이터 VM 0x14023fbc0–0x14023fccd·0x14023fccd–0x14024bace, 파서 팩토리 0x1401c5490–0x1401d152c 가 모두 존재한다. 그러나 analysis/decompiled/all/ 의 11,252개 파일 중 그 주소대에는 FUN_14023fc90 하나(39바이트, func_0x0001402ed390 호출 1줄짜리 stub)만 있고 manifest.json 

### [C WE] Waple RE 문서의 핸들러 VA 가 전부 '점프테이블 raw 값'이고 실제 실행 VA = 인용값 + 0xD0
- **좌표**: `Waple/docs/re/remap-operation.md (+ docs/re/particle-operator-vm.md, Sources/WapleCore/ParticleSimulator.swift 주석)`
- 모든 간접점프는 테이블 raw 값에 lea reg,[0x1400000D0] 를 더한다. opid 디스패치: 0x14023fe40 lea r9,[0x1400000d0], 0x14023fe8c mov eax,[r9+rcx*4+0x24bb58]. 변환 디스패치: 0x140245200 lea rdx,[0x1400000d0], 0x140245214 mov ecx,[rdx+rax*4+0x24bc9c], 0x14024521b add rcx,rdx, 0x14024521e jmp rcx. 검증된 교정 쌍(문서→실측): opid19 진입 0x140244874→0x140244944(경계 명령 mov ec

### [G WE2] decompiled 코퍼스 전체 주소가 진짜 VA+0xD0 로 어긋남 (inject_rich_header.py 결함)
- **좌표**: `Waple-wallpaper-source/scripts/inject_rich_header.py`:63
- binaries/wallpaper64.exe 는 inject_rich_header.py 가 donor DOS-stub+Rich block(0xD0 bytes)을 PE 앞에 끼워 넣으면서 section header 의 raw_ptr 을 갱신하지 않았다. 헤더는 .text raw=0x400 을 가리키지만 실제 본문은 +0xD0 밀려 0x4D0 에서 시작한다. Ghidra가 이 파일을 로드해 생긴 analysis/decompiled/all/ 의 11,252개 함수 주소는 전부 진짜 VA+0xD0. 검증: (a) corpus FUN_140001150 본문(mov ecx,0x50; call)은

### [G WE2] 감사 문서가 strings 덤프의 파일 오프셋을 VA 로 인용 (+0x1200 오류)
- **좌표**: `Waple-wallpaper-source/WE-ENGINE-ANALYSIS-2026-07-27.md`:178
- analysis/strings/*.txt 의 column 2 는 명백히 'column 2: file offset' 라고 자체 서술했음에도(파일 헤더 확인), 감사 문서는 이를 VA 처럼 '@0x488040', '@0x476eb8', '@0x473e98', '@0x485748' 등으로 인용한다. 예: 'DXGI device lost in render loop.' 은 file off 0x488040 → 실제 VA 0x140489240; PLPV0005 file 0x476EB8 → VA 0x1404780B8. 문자열 자체의 존재와 subsystem 판정은 유효하나 좌표 인용이 모두 틀렸다.

### [G WE2] "11,252 함수 디컴파일"은 실질 커버리지의 약 3배 과대 표기
- **좌표**: `Waple-wallpaper-source/scripts/DecompileAll.java`:52
- DecompileAll.java가 섹션 필터 없이 FunctionManager 전수를 카운트. 매니페스트 11,252개 중 7,626개가 .text 밖(.rdata/.data, 예: VA 0x140490000-0x1404d8000)의 1바이트 유사함수이고 7,035개 디컴파일이 halt_baddata 포함. .text 실함수 3,625(실질 몸체 3,614). WE-ENGINE-ANALYSIS §TL;DR/§0/§8의 "11,252 functions decompiled (45 MB)"는 논리 18.3MB를 NTFS 클러스터 할분(~46MB)으로 표기한 것이며 개수도 과대.

### [G WE2] Rich 헤더 주입이 PE 본문을 +0xD0 변위시켰고 섹션 raw_ptr은 갱신되지 않아, Ghidra 디컴파일 코퍼스 전체(11,252 함수)의 주소가 로드시 진값+0xD0로 어긋남
- **좌표**: `Waple-wallpaper-source/binaries/wallpaper64.exe`
- commit된 wallpaper64.exe와 wallpaper64_rich.exe는 MD5 동일(263677f0891626089b3553dcf52018ac)이며 둘 다 e_lfanew=0x110(원본 0x40), 크기 5360320(원본 5360112, +208). inject_rich_header.py는 본문 앞에 0xD0 스텁을 끼워 넣으면서 섹션 raw_ptr/SizeOfHeaders를 갱신하지 않았다. 증거: (a) .pdata 첫 RUNTIME_FUNCTION은 raw_ptr(0x4e1c00)에서 전부 0이고 raw+0xD0에서만 정상 파싱(StartRVA=0x1000); (

### [G WE2] 전임 리포트의 '조작 증거 정정' 자체가 오류 — RapidJSON·소스경로·FFTS 문자열은 모두 실재한다
- **좌표**: `Waple-wallpaper-source/analysis/reports/subsystems-identified.md`
- subsystems-identified.md 서두는 이전 세션 리포트가 "D:\dev\we\windows\src 소스경로 누출, RapidJSON 귀속, FFTS 라이브러리"를 조작했다며 철회했다. 그러나 바이너리 직접 스캔(wallpaper64.exe, UTF-16LE 'D:\dev' 검색)에서 정확히 19개의 소스경로 문자열이 확인됐다: rapidjson 헤더 7종(reader.h VA 0x140477230, document.h 0x1404772d0, allocators.h 0x1404775c0, stream.h 0x140477670, internal/stack.h 0x140477

### [H교차2] 전환 효과 파이프라인(27종+특수값 3)이 앱 계층에 전무 — 모든 벽지 교체가 즉시 컷
- **좌표**: `Waple/Sources/Waple/AppDelegate.swift`:557
- WE 는 재생목록 전진마다 오버레이 창을 띄워 dx11playlisttransition.{vert,geom,frag} 를 FADEEFFECT 콤보로 컴파일해 이전 벽지 위에 다음 벽지를 애니메이션한다(전환 시작 0x140068fc0–0x140069bac, 렌더 스레드 0x140058770–0x14005a884). 특수값 -1(none, 캡처조차 안 함 0x14006904a), -2(reduce flicker, 마지막 프레임 홀드 sub_14005aaf0), -3(random, 풀 추첨 0x1400691a4) 포함 총 30종. Waple 은 WapleCore/PlaylistTransit

### [L미결] subsystems 보고의 'FFT 라이브러리 문자열 없음=UNKNOWN' 판정은 오보 — ffts_static.c 문자열이 UTF-16LE로 존재하고 코드가 참조한다
- **좌표**: `Waple-wallpaper-source/analysis/reports/subsystems-identified.md`:211
- subsystems-identified.md §8(및 요약표 257행)이 "FFT/ffts 문자열 0건 — FFTS 주장은 조작"이라 결론 내렸다. 이는 ASCII 검색만 돌린 결과다. UTF-16LE 전수 스캔에서 `D:\dev\we\windows\src\ffts\src\ffts_static.c`(VA 0x14048b310, 파일 오프셋 0x48a110)와 어서션 식 `N == 32`(VA 0x14048b370)이 실재하며, 둘 다 .text 코드가 rip-relative lea로 직접 참조한다 — 문자열뿐 아니라 xref까지 있다. WE-ENGINE-ANALYSIS-2026-07-

### [L미결] TEX 포맷→GPU 포맷 매핑표 정적 복원 (P2 미결 항목 해소)
- **좌표**: `Waple-wallpaper-source/binaries/wallpaper32.exe`
- 디스패처: `cmp ecx,0x1b | ja 0x4a967f(default) | jmp dword ptr [ecx*4+0x4a9688]`. 입력 ecx = WE 텍스처 포맷 enum(TEXI 헤더 offset 0x12 값), 출력 eax = CreateTexture2D desc.Format 에 들어가는 DXGI 상수. 점프테이블 28엔트리와 스텁 즉시값: case 0/1/2/3→28, 4→77, 5→28, 6→74, 7→71, 8→49, 9→61, 10→34, 11→54, 12→98, 13→24, 14/15→10, 16→41, 17/18→11, 19/20→13, 21→28, 22→55

### [S바이너리] webwallpaper64.exe는 libcef.dll을 직접 정적 임포트하는 전용 CEF 호스트 — wallpaper64.exe 본체와 구조가 다름
- **좌표**: `binaries/webwallpaper64.exe`:1
- pefile 임포트 파싱: webwallpaper64.exe는 KERNEL32(131)/USER32(34)/ole32(1)/ADVAPI32(5)/libcef.dll(49) 정적 임포트. libcef 함수 목록은 cef_execute_process/cef_initialize/cef_browser_host_create_browser/cef_process_message_create/cef_v8_* 생성 API 등 브라우저+렌더러 양쪽 역할 전부 포함. 반면 wallpaper64.exe는 IMAGE_IMPORT_DESCRIPTOR 영역이 전부 0으로 클리어됨(RVA 0x4d8c20 size 

## 2. high 87건 — 주제별

### 기타 (36건)
- **[Z E2E]** 캡처 경로가 클릭 전역 모니터를 여전히 설치·오프메인 해제한다 — 포인터/폴러 게이트 수정이 3중 1개를 빠뜨렸다 — `SceneRenderer.swift:2060`
- **[Z E2E]** 온보딩 '가져오기…' 체크 갱신 계약이 F582 임포트 비동기화로 파함 — 성공해도 시트가 회색 원으로 남는다 — `AppDelegate.swift:330`
- **[Z E2E]** 변환 캐시 evict 가 재생 중인 VideoRenderer 출력물을 삭제할 수 있다 — 씬 경로(F560)와 달리 활성 등록이 없다 — `FFmpegConverter.swift:185`
- **[Z E2E]** BACKLOG 갭① 재확인 — 캡처 창 안에서 물리 클릭이 g_PointerState.z 임펄스로 스틸에 구워짐(프레임 꼬리 부재) — `AppDelegate.swift:1072`
- **[F지원]** --profile 메타 파스가 여전히 .pkg 만 연다 — 언팩 코퍼스 전체에서 사용 불가 (선행 감사 M9 미수정) — `ProfilePipeline.swift:254`
- **[T패키징]** 같은 PID 의 복수 창에서 최전면 창을 무조건 선택 — '메인창' 계약 및 --bounds 목적(3행)과 어긋남 — `window-id.swift:49`
- **[T패키징]** 안내 텍스트 계약이 실제로는 성립하지 않음 — layoutContent가 매 애니메이션 틱마다 messageLayer를 0×0으로 삼킴 — `WapleSaverView.m:134`
- **[Y피드백]** 배포 Info.plist 에 NSAppleEventsUsageDescription 부재 — NowPlayingProvider 의 TCC 계약이 배포물에서 성립 불가 — `package-app.sh:48`
- **[P설치트리]** Wapl 미대응 지도 확정 — 설치/갱신/시스템통합/하드웨어 RGB 전체가 Wapl 범위 밖 — `Sources`
- **[M렌더2]** WF-A 재검증: 경로 보안 우회는 probeAssetData가 아니라 resolveRequiredAsset의 alternate(bitmapRGBAFile) 분기로 실재한다 — `SceneRendererResources.swift:422`
- **[M렌더2]** 씬 오디오(및 웹 폴백)는 VideoSettings 라이브 반영 경로가 없다 — 씬 배경 음량 슬라이더가 리마운트까지 무음 — `AppDelegate.swift:533`
- **[V Swift6]** --profile 메타 파스가 resolveMountSource/mountPackage 를 우회해 언팩 코퍼스에서 전멸 — 같은 파일의 [2026-08-25] 수정 선언과 모순 — `ProfilePipeline.swift:254`
- **[O UI]** 드롭 타깃 링 바인딩의 비대칭 해제 — 다른 모니터로 드래그가 넘어가도 하이라이트가 안 지워진다 — `DisplaysView.swift:136`
- **[O UI]** Now Playing 음량 컨트롤: 노출 조건과 쓰기 대상이 서로 다른 정의를 따라 크로스 타깃 오기록·무효 조작이 난다 — `NowPlayingBar.swift:289`
- **[O UI]** ScreenSaverLogic.videoPath 가 project.json fileName 을 WallpaperPathSecurity 없이 소비 — `ScreenSaverController.swift:28`
- **[C WE]** operation 어휘·기본값 근거가 바이너리와 불일치 — 'remap/multiply/add/subtract' 문자열은 이 빌드에 참조가 0건 — `remap-operation.md §3–§6`
- **[C WE]** [미해결 해소] transformnoise 커널 입력 위상 확정 — 좌표=(t·scale, 파티클 난수, 0), 레인별 XOR 솔트, octaves>12 면 변환 생략 — `(신규 발견) wallpaper64.exe 0x1402456fa–0x14024583a(simplex), 0x14024587d–0x1402459f8(fbm)`
- **[C WE]** [근거 오류 + 신규 발견] operation 부재 기본 주입 리터럴은 "layertime" 이다 — "multiply" 인용 셀 0x140484f28 은 미참조·끊긴 포인터 — `remap-operation.md:456`
- **[D교차1]** 재생 정책 6축 중 5축(focus/maximized/fullscreen/audio/battery)이 앱에 배선돼 있지 않다 — `AppDelegate.swift:281`
- **[G WE2]** 검증 스크립트·증거 덤프로 인용한 파일이 저장소에 없다 — `subsystems-identified.md:7`
- **[G WE2]** §9-4 'evidence-index.tsv 로 defect cluster 추적' 지시가 산출물 현실과 어긋난다 — `WE-ENGINE-ANALYSIS-2026-07-27.md:280`
- **[G WE2]** 미기록: 재진입 분기마다 IsDebuggerPresent→DebugBreak 안티디버그 가드 (entry-point.md 의 'anti-debug 없음' 서술과 모순) — `0000000140021f20__FUN_140021f20.c:439`
- **[G WE2]** Ghidra 함수 집합과 .pdata 집합의 시작점 교집합이 85/14,788 (0.6%) — 92.6%의 언와인드 등록 함수가 미커버 — `manifest.json:1`
- **[G WE2]** evidence-index.tsv rtti_classes 칼럼 전면 오염 — §9.4 '클래스명→함수' 워크플로 작동 불가 — `BuildEvidenceIndex.java:72`
- **[G WE2]** 스왑체인 생성 파라미터(buffer count·format·resize)는 동적 로그 어디에도 없음 — 레인 목표 데이터의 근거 공백 확정 — `d3d_identify2.log:4`
- **[G WE2]** JSON 파서는 jsoncpp 단독이 아니라 jsoncpp + RapidJSON 병용이다 — `000000014004af80__FUN_14004af80.c`
- **[H교차2]** 경과시간 영속(playliststatetime.bin)과 모니터별 재생목록 상태 분리 부재 — `playliststatetime.bin:1`
- **[H교차2]** camerashake 산식이 실물과 다른 근사 — 속도→주파수 법칙(제곱 vs 선형)과 파형·단위가 갈림 — `SceneRenderer.swift:1281`
- **[J테스트]** bundledWEAssetsRoot 오버라이드 분기가 '못 찾으면 막는다'는 자기 계약을 위반한다 — 깨진 WAPLE_WE_ASSETS 가 조용히 리포 트리로 폴백한다 — `TestSupport.swift:359`
- **[L미결]** P2 미결 'mapsequence 산식' 중 around(opid 13) 속도 혼합 대수식 완정복 — 축별 결합 순서까지 확정 — `wallpaper64.exe`
- **[L미결]** [판명] WE 실물 씬 리더에 version 게이트 분기가 존재하지 않는다 — c2d8ecc1 게이트는 코퍼스 재현이 아니라 '엔진과 반대' 의도 이탈로 재분류해야 한다 — `SceneDocument.swift:3989`
- **[L미결]** G-C4-01 thisObject≠thisLayer 재검증 — 서로 다른 per-script 스택 실측 확정 — `TextScriptEngine.swift:556`
- **[Q교차3]** [A] screenKey가 세션 유수값 CGDirectDisplayID를 영구 저장 키로 사용 — 재부팅·도킹 후 조용한 오배정 — `DesktopWindow.swift:11`
- **[R이력]** §7·§9: "2,538개 함수가 클래스명 문자열을 참조" — evidence-index의 실제 내용과 다름 (greppable 경로 부재) — `WE-ENGINE-ANALYSIS-2026-07-27.md:217`
- **[S바이너리]** 32비트 전용 경로는 WoW64 감지·헬퍼 비트니스 디스패치뿐 — 실질 기능 격차 없음 — `wallpaper32.exe`
- **[S바이너리]** binaries/wallpaper64.exe는 원본이 아니라 주입 산출물 — 파일명과 실체 불일치 — `wallpaper64.exe`

### 캡처 핀·결정성 (8건)
- **[A소스]** 캡처 핀 게이트가 전역 클릭 모니터를 막지 못한다 — 툼스톤이 '해소'라고 선언한 불변식의 잔여 구멍 — `SceneRenderer.swift:2060`
- **[E앱]** 캡처 경로의 전역 capturePointerUV 핀이 살아있는 씬 렌더러와 데이터레이스 — 파라랙스 스냅·영구 모니터 상실 — `AppDelegate.swift:1066`
- **[Z E2E]** 캡처 핀(capturePointerUV)이 프로세스 전역 정적인데 라이브 마운트가 경합으로 이를 흡수해 인터랙션이 죽은 렌더러가 태어난다 — `SceneRenderer.swift:2151`
- **[Z E2E]** 신규 — 전역 정적 핀 capturePointerUV 의 비직렬화 동시 진입: defer 복원 교차 시 핀이 영구 잔존해 라이브 시차·커서 반응 전면 사망 — `AppDelegate.swift:1065`
- **[Y피드백]** 전역 캡처 포인터 핀이 동시 마운트되는 '라이브' 렌더러를 영구 동결시키고 캡처 비결정성 구멍도 남는다 — `AppDelegate.swift:1065`
- **[X골든]** 클릭 모니터만 캡처 핀 게이트가 없다 — "핀 = 라이브 모니터 0개" 계약이 코드와 어긋난다 (WF-A 재판정: 구멍은 실재, 단 좁다) — `SceneRenderer.swift:849`
- **[V Swift6]** 전역 포인터 핀이 캡처 동안 살아있는 커서 반응 씬을 통째로 얼리고, 겹친 캡처 경로의 save/restore 교차로 핀이 조기 해제된다 — `AppDelegate.swift:1065`
- **[B문서]** oracle.nondet.rootCause 의 확정 서술·근거 좌표가 현행 코드와 정반대 — "포인터는 핀하지 않는다" 는 이제 거짓 — `nondeterminism.json:292`

### 포맷·스키마 문서 (8건)
- **[C WE]** tex-format.md TEXI table invents a phantom 'field7' and misreads previewColor as 'field6/mip count' — `tex-format.md:52`
- **[C WE]** tex-format.md TEXB '+0x00 flags/mode 0x00000100 / +0x04 0xFFFFFF00' are misalignment artifacts of not skipping the section-name NUL — `tex-format.md:96`
- **[C WE]** tex-format.md pixel-format enum is wrong for fmt 0, 6 and 8 — `tex-format.md:78`
- **[C WE]** mdl-format.md header table is shifted one byte; 'vertex_format lo/hi u16 pair' and 'count_A/count_B' do not exist — `mdl-format.md:38`
- **[H교차2]** scene.camera.paths 경로 재생이 파스·소비 모두 미구현 — 3D 대표 4씬의 카메라가 고정 구도로 정지 — `SceneDocument.swift:684`
- **[U코퍼스]** schema 문서가 모르는 실물 채널 scene.camera.paths — Wapl 도 파스하지 않는다 (설치본 4/12 씬) — `scene-json-schema.md`
- **[U코퍼스]** scene-json-schema.md objects[] 절에 light·sprite 레이어 타입과 null-형제 관례가 빠져 있다 — `scene-json-schema.md:91`
- **[U코퍼스]** camera.paths — 스키마 문서 관측 범위 밖의 제4 키가 설치 코퍼스 6/16 씬에 실존하고 Wapl 은 파스하지 않는다 — `scene-json-schema.md:24`

### WE 설치·플러그인 (7건)
- **[P설치트리]** 25회 반복된 Uncaught TypeError getFrame(line 11, col 20) — scenescript64.dll(V8) 사용자 스크립트의 결정적 null 역참조 — `log.txt:7`
- **[P설치트리]** DXGI device-lost 3단계 복구 프로토콜 — 다중 렌더러가 동시 회복, JS 상태는 생존하지 않음 — `log.txt:37`
- **[P설치트리]** plugins/ 는 단일 플러그인 시스템 — WPExt 계약: 2 익스포트 + 버전 문자열 "pluginAlphaDev0007" — `ledextensions64.dll`
- **[P설치트리]** 주변기기 연동 표면은 정확히 2개 벤더 SDK — iCUE는 정적 임포트 11함수, Razer는 동적 로드 + 서명 고정 — `ledextensions64.dll`
- **[P설치트리]** 스크립팅 API 선언 JSON — 전역객체 cue 7함수 + 플러그인 객체 led 1함수, imageData 기반 색 전송 — `ledextensions64.dll`
- **[P설치트리]** installer.exe 정체 — ShellExecuteW 하나인 초소형 재실행 스텁 — `launcher.exe`
- **[U코퍼스]** config.json wproperties — 배경별 속성 오버라이드의 실물 위치는 <pkg 절대경로>→{모니터}→{속성} 3층 구조다 (스캔 문서 미관측) — `config.json`

### RE 근거 좌표 (7건)
- **[C WE]** RTTI 산출물 2건이 실패 상태 — rtti-vtables.json 은 빈 배열, rtti-references.json 11키 중 10키 빈 배열 + 유일 레코드는 무의미 좌표 — `rtti-references.json:13`
- **[C WE]** [근거 오류] RemapOperation InjectedDefault int 0/1 의 네 인용 VA 는 명령어 중간 바이트다 — `RemapOperation.swift:137`
- **[G WE2]** §4/§9/§10 MDL 디코더 주소가 Ghidra 주입본 기준 — 원본 바이너리 RVA와 +0xD0 어긋남, 문서 무기재 — `WE-ENGINE-ANALYSIS-2026-07-27.md:163`
- **[G WE2]** 미기록: wallpaper64 메인 프로시저의 WM_USER IPC 전체 맵 (점프표 RVA 0x2E690) — `0000000140021f20__FUN_140021f20.c:1456`
- **[G WE2]** '조작 철회' 보고서 자체의 오검출: FFTS·RapidJSON·소스경로 누출은 원본에 UTF-16LE로 실존 — `subsystems-identified.md:211`
- **[G WE2]** FFT 미확정('FFT UNKNOWN') 해소 — FFTS가 정적으로 링크되어 있다 — `0000000140147580__FUN_140147580.c:1775`
- **[L미결]** WE 오디오 FFT = 정적 링크 FFTS — 2^n이면 radix 커널 직행, 아니면 Bluestein(chirp-z): 'mixed-radix 재판정'의 실측 답 — `wallpaper64.exe`

### 임포트·라이브러리 (5건)
- **[Z E2E]** Task 홉이 progress→completion 순서 계약을 소멸시켜 .failed 최종 상태가 늦은 진행 이벤트에 덮여 타일이 영구 '가져오는 중' 에 갇힌다 — `WorkshopViewModel.swift:229`
- **[F지원]** hasStableId 가 살균 실패한 workshopid 를 '안정적 재임포트'로 오판 — 동명 관리 폴더를 백업 없이 통째로 교체 — `LibraryStore.swift:254`
- **[F지원]** zip 재가져오기의 교체 시퀀스(removeItem → moveItem → 등록)가 백업 없는 비원자 교체 — 중간 실패 시 유일 사본 소실 — `LibraryStore.swift:273`
- **[O UI]** 재시도로 대체된 낡은 다운로드 완료 콜백이 새 실행의 상태를 덮어쓰고 F492 신호를 지운다 — `WorkshopViewModel.swift:220`
- **[S바이너리]** wallpaper64.exe import directory가 소실/비표준 상태 — pefile 파싱 불가, 수동 재구성 필요 — `wallpaper64.exe`

### 재생정책 미배선 (5건)
- **[Z E2E]** playbackProperties 의 E2E 소비자가 0개 — 파스만 되고 끝나는 데이터이며 첫 단추는 매니페스트 수준이다 — `WallpaperProject.swift:59`
- **[F지원]** 절전 래치 판정이 muted 를 무조건 false 로 되쓴다 — 실물은 절전 중에도 소비된 음소거 플래그(bit6|bit7)를 계속 적용한다 — `PlaybackPolicy.swift:532`
- **[D교차1]** 재생정책 사슬 전체가 미배선 — 파서·평가기에 런타임 소비자가 없다 — `PlaybackPolicy.swift:415`
- **[D교차1]** 6축 재생정책 평가면이 앱 런타임에 배선되지 않았다 — 모델은 완전한데 소비자가 0개 — `AppLogic.swift:316`
- **[Q교차3]** (A) 6축 재생정책(focus/maximized/fullscreen/audio/battery/sleep)+pausevram — 평가기는 포팅됐으나 앱 배선이 전무해 실물 메커니즘 자체가 꺼져 있다 — `AppDelegate.swift:428`

### WE 프로세스·브릿지 (5건)
- **[P설치트리]** config.json 은 이중 작성자 문서 — 엔진은 일부 섹션만 소비, browser 섹션은 CEF UI 소유 — `config_2026-08-09.json:13`
- **[P설치트리]** 웹 월페이퍼 CEF는 --disable-web-security + 사이트 격리 해제, 단 파일 접근은 프로젝트 디렉터리 화이트리스트 — `webwallpaper64.exe`
- **[S바이너리]** 브릿지 프로세스 메시지 이름 17종 확정 — cef_process_message_create 기반 — `webwallpaper64.exe:72024`
- **[S바이너리]** [Waple 핵심] zcompat 웹 호환 패치 시스템 — 빌드 431960 프로젝트를 소스 레벨에서 자동 개조 — `webwallpaper64.exe:803880`
- **[S바이너리]** 네임드 파이프 IPC 구조 확정 — \\.\pipe\<name>Client 이중 핸들 + 부모 생존 감시 — `webwallpaper64.exe:1168088`

### 플레이리스트·전환 (4건)
- **[Z E2E]** 플레이리스트 전진이 교차페이드 없이 이전 렌더러를 먼저 해체한다 — 포팅된 전환 모델은 데드 코드 — `AppDelegate.swift:710`
- **[H교차2]** transitiontime·browsetransition 스키마와 'project.json playlist.settings vs config.json 전역' 2중 스코프 부재 — `config.json:1`
- **[H교차2]** daytime 모드와 항목별 daytimeend 매칭 — 코어엔 구현, 스토어/앱엔 부재 — `PlaylistTransition.swift:808`
- **[H교차2]** 나머지 4개 모드(logon/dayofweek/never)와 videosequence/updateonpause/beginfirst/playintro 플래그 부재 — `PlaylistStore.swift:5`

### 셰이더·렌더 (4건)
- **[I코어테스트]** 심볼 린트 2종(undeclaredIdentifiers·undefinedStructMembers→findings)이 구현돼 있으나 호출부가 0개 — 죽은 코드이자 헤더 계약과의 드리프트 — `GLSLBundledShaderRegressionTests.swift`
- **[Q교차3]** [missing-in-waple] 3D 메시 머티리얼이 usershadervalues(schemecolor→색 토큰 바인딩)를 전혀 읽지 않는다 — `SceneRenderer3D.swift:761`
- **[W셰이더]** RG88 노멀맵 언팩 축이 mf_normal 과 pf_refract/mf_refract 에서 정반대 — 같은 텍스처를 두 경로가 x/y 교차 해석 — `Mesh3DShaders.swift:671`
- **[W셰이더]** 커스텀 2D 레이어·3D 메시 경로에서 오디오 버퍼 무바인딩 — usesAudio 플래그가 빌드 시점에 폐기됨 — `SceneRendererFrameEncoder.swift:1464`

### 수치·게이트 진실성 (1건)
- **[B문서]** 레포 정본 셈법(grep)이 CI 실측 3708 과 어긋나 3699 — '11연속 일치' 주장과 하한 사전계산 워크플로가 깨졌다 — `AGENTS.md:87`

## 3. 교차 확정된 핵심 결함

서로 다른 워크플로우가 **독립적으로 같은 결함에 도달**한 것 — 신뢰도가 가장 높다.

### ① 전역 캡처 핀 `capturePointerUV` (7개 WF 교차: A·E·V·X·Y·Z·M)
2026-08-25 커밋 `a328d339` 가 도입한 `nonisolated(unsafe) static var` 핀이 세 층위에서 깨진다:
- **데이터레이스**: 백그라운드 큐가 쓰고 메인 액터(`startPointerMonitor`·`updateParallax`)가 잠금 없이 읽음
- **라이브 오염**: 캡처 창(수 초) 중 새 씬이 마운트되면 모니터 없이 태어나 커서 반응이 다음 재마운트까지 영구 사망
- **잔여 구멍**: 포인터·미디어폴러 두 갈래만 게이트, **클릭 모니터(`:849`)는 무게이트** → 클릭 임펄스가 골든 캡처에 구워짐
- **핀 영구 잔존**: 동시 캡처 2건의 `defer` 복원이 교차하면 핀이 안 풀림

### ② 재생정책 사슬 전면 미배선 (5개 WF 교차: D·Q·Z·T·X)
`WaplePolicy` 모델·평가기는 완성됐고 WE 실물과 7계약 전부 일치(P 레인이 사원 수렴으로 확정)하나:
- 앱 타깃이 `WaplePolicy` 에 **의존조차 하지 않음**(`Package.swift:49`)
- `playbackProperties` 파스는 착지했으나 **소비자 0개**
- 파서 주석이 약속한 "앱 측 감시 테스트" 는 **존재하지 않고, 현 타깃 그래프로는 만들 수도 없음**
- `PresetResolver.resolve` 가 프로젝트 재구성 시 `playbackProperties` 를 **드롭** → 배선 착지 즉시 발화할 잠복 결함

### ③ 플레이리스트 전환 모델 데드 코드 (H·Z 교차)
`PlaylistTransition.swift` 849행(WE 전환효과 27종 포팅 완료)이 앱 런타임에 연결되지 않음 → 모든 배경 교체가 hard-cut.
`daytime` 모드·경과시간 영속(`playliststatetime.bin`)·모니터별 상태 분리도 부재.

### ④ RE 근거 좌표의 +0xD0 시프트 (C·G·L 교차, critical)
`inject_rich_header.py` 가 PE 본문을 +0xD0 밀면서 섹션 raw_ptr 을 갱신하지 않아, **디컴파일 코퍼스 11,252 함수 전체의 주소가 어긋남**.
Waple 소스 주석의 핸들러 VA 인용 20여 개가 이 규칙으로 교정 필요.
추가로 `.pdata` 기준 실제 함수는 14,788개인데 코퍼스는 11,252개(교집합 0.6%) — **오퍼레이터 VM·파서 영역이 통째로 누락**.

### ⑤ 문서 수치 진실성 (B·F·X·R 교차)
- CI 래치 `3708` vs 리포 정본 grep 명령 결과 `3699` — `@MainActor func test` 9건이 패턴 사각지대
- "11연속 정적=실측 일치" 주장과 푸시 전 사전계산 워크플로가 **현재 깨진 상태**
- `README.md:151` 은 아직 3,693(선행 감사에서도 지적)

## 4. 이번 라운드가 판명한 미결 항목 (L·C·G 레인 성과)

| 기존 상태 | 판명 결과 |
| --- | --- |
| P2 "FFT mixed-radix 재판정" | **해소** — FFTS 정적 링크 확정(2^n 은 radix 커널, 그 외 Bluestein) |
| P2 "mapsequence 산식" | **해소** — around(opid 13) 속도 혼합 대수식 완정복, Waple `MapSequenceBetweenSolver` 와 일치 |
| P2 "TEX CreateTexture2D 포찍" | **해소** — TEX→GPU 포맷 매핑표 정적 복원 |
| `transformnoise` 커널 입력 위상 [미해결] | **해소** — 좌표=(t·scale, 파티클 난수, 0), 레인별 XOR 솔트, octaves>12 면 변환 생략 |
| `remapinitialvalue` operation 부재 기본 | **정정** — "multiply" 아님, 실제 주입 리터럴은 `layertime`; 기존 인용 VA 4건은 명령어 중간 바이트 |
| 씬 루트 `version` 게이트(`c2d8ecc1`) | **재분류 필요** — WE 실물 리더에 version 분기가 **없음**. 코퍼스 재현이 아니라 의도적 이탈 |
| "subsystems 보고의 조작 증거 철회" | **철회가 오류** — RapidJSON·FFTS·`D:\dev` 경로가 UTF-16LE 로 실존(ASCII-only 검색 실수) |

## 5. 반증된 기존 주장

- AUDIT "모든 성공/실패가 NSLog 로만, GUI 비가시" → notify() 가 배너·설정미러·트레이·툴팁 4싱크 보유
- AUDIT/BACKLOG "하드코딩 한국어 40+, 현지화 인프라 전무" → **272키 양방향 차집합 0**, 테스트 3건이 규약 강제 중
- BACKLOG "설정 창 동영상 미러링 결함" → 그 미러가 `d5d69216`(2026-07-19) 에서 삭제돼 결함 자체가 소멸
- BACKLOG "볼륨/배속 = 전체 재장착" → F820 으로 VideoRenderer 한정 해소(단 씬 오디오는 여전히 리마운트 필요)
- 초기 감사의 심볼릭 링크 탈출 주장 → 로컬 실험으로 `isRegularFile==false` 가드 실증, 기각
- 초기 감사의 호버 시차 보정식 누락 → 대수적으로 선형 성분 상쇄 증명, 기각
- 동봉 WEAssets 2,940파일 → sha256 전수 재계산, 누락·미등록·불일치 **0**

## 6. 방법론 비고

- 각 워크플로우는 P1 판독 8레인 → P2 회의적 검증(medium+ 상위 8건) → P3 종합 구조. 재시도 로직(최대 2회) 내장.
- 게이트웨이 503 장애로 P2 검증자·P3 종합자가 다수 사망 — 그 경우 종합자가 원시 코드 재대조로 보완했거나, 발견이 `unverified` 로 남았다.
- 따라서 **high 이하는 검증 강도가 균일하지 않다**. 실행 전 개별 재확인 권장.
- WE 워크스페이스 레인(C·G·L·S)은 r2·pefile 로 바이너리를 직접 재측정했다 — 이 라운드에서 가장 높은 신뢰도의 산출.