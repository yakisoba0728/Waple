# 전체 코드베이스 감사 리포트 — 2026-08-26

> **생성**: 2026-08-26 · 워크플로우 스웜(판독 16레인 + 회의적 검증자) + 인라인 실측 · **코드 미수정 — 발견 기록만**
> 방법: 서브시스템 16레인 병렬 정독(27 에이전트 · 도구호출 365 · 약 106만 토큰, 동시 실행) → medium 전부를
> 독립 회의적 검증자에게 재판정. 이 문서의 값은 결론과 함께 **각 발견의 근거 좌표**에 있다.
> 실행 여부는 [BACKLOG.md](../BACKLOG.md) 트리거 규약을 따른다 — "트리거가 오면 할 일"이다.

---

## 0. 기반 실측 — 모두 정상

| 항목 | 결과 |
| --- | --- |
| `swift build` | 통과 |
| 전수 테스트 | **3,708 실행 · 실패 0 · 스킵 63** — CI 래치(`ci.yml:513` 하한 3708)·정적 개수와 정확히 일치 |
| main ↔ origin/main | `7c68c8e8` 동기화, 최신 커밋 CI 그린(CI+spec 레인 포함) |
| spec 검증기 | 오류 0 (문서간 경고 1건 + 헤지 27건은 기록된 리뷰 대상) |
| 소스 내 `try!`/`as!` | 0건 (`Sources/**`) |
| TODO/FIXME | 3건 — 전부 의도적 YAGNI 기록(SceneDocument.swift:907·2706, ScenePackage.swift:171) |
| 작업 트리 §4 부산물 | 인계 문서 서술과 정확히 일치: 파스 배선 있음(`ProjectJSONParser.parsePlaybackProperties`), **파스 단위 테스트 0건**, 앱 계층 소비자 0건(P1 미착수) |
| 서브에이전트 인프라 | handoff §5 장애 해소 확인(27/27 생존, 에러 0) |

## 1. 레인 건강도 — critical/high 0건

**healthy 4**: core-shader · render-scene-renderer · render-media · render-passes-shaders
**attention 10**: core-scene · core-particle · core-model-puppet · core-fx · core-audio-fluid ·
render-3d · render-text-web · app-core · app-ui · support-modules

발견 총 51건(medium 12 · low 39). medium 12건 전부 검증 단계 통과: **확정 9 · 반증 3**
(ScenePackage 0바이트 .directory = WE 관측과 같은 의도적 삼중 근거,
LibraryStore 재가입 폴더 파괴 = 선행 방어 코드로 트리거 재현 불가,
render-3d 1건 = 에이전트 산출 자체가 placeholder).

## 2. 확정 medium 9건

### A. 실동작 영향

#### M1. MDLA 리싱크/이벤트 윈도우가 가변 꼬리 크기와 어긋남 — 클립 유실·이벤트 오귀속 가능
- **파일**: `Sources/WapleCore/Model3D.swift:961` (리싱크), :970 (윈도우), :1005-1011 (cap)
- **내용**: `parseAnimations`는 꼬리 길이를 계산하지 않고 "다음 유효 헤더 ≤256B" 리싱크(`while d <= 256`)와
  이벤트 스캔 윈도우(`to: next ?? min(o + 512, …)`)로 스킵한다. 그런데 포맷 주석(:30-47)이 보장하는 것은
  최소 35B 뿐이고 상한이 없다.
  - 시나리오 ①: 어떤 클립의 꼬리가 256B 를 넘으면 next 를 못 찾아 `guard let n = next else { break }` 로
    그 뒤 애니메이션 **전부 무음 유실**.
  - 시나리오 ②: `trailerEvents`의 내부 cap이 `bytes.count` 지 `to` 가 아니라(:1005),
    다른 클립/섹션 영역의 `{"frame"` 바이트가 현재 클립 events 로 **병합·중복**된다.
- **왜 아직 안 터졌나**: MDLA0006 게이트 경로는 파일 스스로 "재측정 전까지 미검증"(:57)이라고 인정하는 자리 +
  발화해도 크래시 없는 조용한 손실이라 회귀 핀이 없음.
- **검증**: 반증 실패 확정.

#### M2. bind/fbos/events 파스의 all-or-nothing 배열 캐스트 — 원소 1개 비객체에 배열 통째 소실
- **파일**: `Sources/WapleCore/EffectManifest.swift:541`(bind) · :563(fbos) ·
  `Sources/WapleCore/PropertyAnimation.swift:680`(events)
- **내용**: `(p["bind"] as? [[String: Any]]) ?? []` 는 Swift 조건 캐스트가 전원-아님(all-or-nothing)이라
  원소 하나만 NSNull 이어도 nil → 모든 bind/FBO/마커 소실. **같은 파일이 passes 에는 정확히 이 실패를
  기술하고 고쳐둔**(:532-537 "비객체는 빈 패스로 자리 보존") 자기모순. 헤더 계약 표(X-⑪/T09-D1/X-⑧)는
  원본이 **원소 단위 드롭**(bind 태그 검사 0x1401e7e8b 등)임을 명시.
- **재현**: `"bind": [{"name":"texture0","index":0}, null]` → binds=[] → 패스가 언바인드 렌더.
- **동봉 도달**: 263개 effect.json 미관측. 단 워크샵 JSON 은 이미 122개 중 27개가 엄격 파스 실패하는 관용 의존 코퍼스.
- **검증**: 독립 Swift 스크립트로 캐스트 실패 재현 확인. 반증 실패 확정.

#### M3. isFinderDesktopHost 가 주석 계약 위반 — 전체화면 Finder에서 가림 자동 일시정지 무음 실패
- **파일**: `Sources/Waple/DesktopVisibilityMonitor.swift:123`
- **내용**: 판별이 ownerName=="Finder" + 면적≥95% 뿐이라 화면을 채운 Finder 브라우저 창이 바로 그 조건으로
  예외 분류된다. 주석(:121-122)은 "대형 Finder 브라우저 창은 예외가 **아니다** — 실제로 데스크탑을 가린다"고
  못박았는데 코드는 그 반대.
- **실패**: ⌃⌘F 전체화면 Finder(예: 1440×876 = 97.3% ≥ 95%) → isBlocking=false → 불투명 창 밑에 데스크탑이
  완전히 가려져도 렌더러가 계속 재생(GPU·전력 낭비). 조용한 실패.
- **검증**: 반증 실패 확정.

#### M4. 씬 배경 음량 메뉴가 어떤 입력으로도 씬 음량을 바꿀 수 없음 + 혼합 구성에서 엉뚱 대상 변경
- **파일**: `Sources/Waple/Shell/NowPlayingBar.swift:57`(노출) · :288-293(적용), `AppDelegate.swift:532-534`·`:572-574`
- **내용**: `showsVolumeControl`은 scene 에도 스피커 메뉴를 열지만 (1) `applyToVideoTargets`는
  `videoTargetIds()`(.video 만 필터)에만 기록 — 씬만 재생 중이면 빈 배열로 guard 탈락, (2) 라이브 적용
  `applyLiveVideoSettings`는 `compactMap { $0 as? VideoRenderer }` — 씬 오디오에는 반영 경로 자체가 없음
  (SceneAudioPlayer는 마운트 시 1회 주입, `SceneRenderer.swift:2049`, 내부 불변).
- **실패 A**: 씬 BGM 중 50% 선택 → 저장도 변화도 안내도 없음. **실패 B**: 전역 선택이 씬인데 어느 모니터가
  동영상 → 하단 바가 표시하지 않는 '다른 모니터 동영상' id 에 기록(표시↔기록 대상 불일치).
- **검증**: 반증 실패 확정.

### B. 오디오 계약 드리프트

#### M5. scriptBuffers(_:) "소비단 완료값 그대로" 주석 vs 실제 경로는 평균 재접기
- **파일**: `Sources/WapleCore/AudioSpectrumProcessor.swift:176`, 소비처 `TextScriptEngine.swift:1749-1770`
- **내용**: `Output.scriptBuffers(_:)`는 "씬 스크립트가 MAX 축약 완료값(spec16/32/64)을 그대로 받는다"고
  문서화했으나 **프로덕션 호출부 0건**. 실제 경로(SceneRenderer.swift:2103 → `__setAudioData`)는 64밴드를
  받아 avg()로 left32=평균(×2)·left16=평균(×4)·average=좌우 평균 재접기.
- **효과**: 순음 저역에서 스크립트가 받는 값 ≈ X/2~X/4 (L=[1,0…],R=[0,1…] → 문서의 실물값 0.5 vs Waple 0.25).
  셰이더 유니폼 경로(setSpectrumBands)는 MAX 로 올바른데 스크립트 경로만 갈림.
- **검증**: 반증 실패 확정.

#### M6. registerAudioBuffers 해상도 계약(무인자=16, 무효=예외) vs JS 심(둘 다 64 침묵 대체)
- **파일**: `Sources/WapleCore/AudioSpectrumProcessor.swift:203`, 소비처 `TextScriptEngine.swift:1796-1803`
- **내용**: WapleCore 는 실측 계약(무인자=16 @0x181655221, 무효 해상도는 예외·폴백 없음)을 코드로 굳혀 두는데
  유일 구현체인 JS 심은 `var n = __num(res, 64); if (n !== 16 && n !== 32 && n !== 64) { n = 64; }`.
- **실패**: WE 용 스크립트가 무인자 호출 → 실물 16길이 vs Waple 64길이(res 길이 전제 루프 4배·인덱스 어긋남).
- **검증**: 반증 실패 확정.

### C. 문서 드리프트

#### M7. 파형 산식 주석 상호모순 — RemapOperation(실측) vs RemapTransform(구 [축정])
- **파일**: `Sources/WapleCore/RemapOperation.swift:66-95` vs `Sources/WapleCore/ParticleSystem.swift:903-916`,
  부산물 `ParticleSystem.swift:442-443`(oscillateAlpha 서사)
- **내용**: RemapOperation 네 파형은 §10.4 실측 산식+VA 인용(sine=0.5−0.5·cos(πst), 주기 2/s). 반면
  RemapTransform 열거형 주석은 같은 핸들러(op 0x13→0x140244874)에 대해 "소비 VM 은 아직 못 뜯었다"+2π 기반
  구산식군([축정]) — sine 주기만 놓고 2배 차이. thunderbolt 계열 sine 4건이 실제로 이 경로를 탄다.
- **판정(마스터 수치 대조)**: **동작은 RemapValueMath 가 정본** — 시뮬(ParticleSimulator.swift:1953-1956)가
  직접 호출하고, 제 수치 대조에서 sine·square·triangle 전부 문서 §10.4 산식과 일치(오차 ≤5.6e-17).
  오라클 테스트(RemapOperationTests:65-95)도 새 산식 고정. 즉 배송 코드 버그가 아니라 **구버전 [축정] 주석의 폐기 누락**.
- **검증**: 반증 실패 확정.

#### M8. 공유 컨텍스트 "오염되지 않는다(IIFE 미실행)" 주석이 런타임 예외에선 거짓
- **파일**: `Sources/WapleRender/TextScriptEngine.swift:707`
- **내용**: SyntaxError(평가 자체 미실행)엔 참이지만, IIFE 본문이 실행된 뒤 런타임 예(TypeError 등)로 죽으면
  top-level 문들은 이미 커밋된 뒤. 폐기된 스크립트가 남긴 shared.* 변경이 나머지 전체 스크립트에 노출됨.
- **실패**: shared.mode='night' 대입 후 throw → 그 엔진만 폐기돼도 잔존 → 뒤따르던 분기 스크립트들이 밤 모드로
  동작. 마운트 순서만 바꿔도 결과가 달라 비결정적으로 보임.
- **검증**: 반증 실패 확정.

### D. 툴링

#### M9. `--profile` 이 언팩 코퍼스 전체에서 사용 불가 — 메타 파스가 여전히 .pkg 만 연다
- **파일**: `Sources/WapleCompatCore/ProfilePipeline.swift:254`
- **내용**: runProfile 의 메타 구간은 scene.pkg/gifscene.pkg 만 직접 연다. 같은 파일 mountPackage(:43)는
  [2026-08-25] 수정으로 `ScenePackage.resolveMountSource` 언팩 폴더까지 열게 됐는데 그 수정이 못 미친 자리.
  설치본은 188/188 언팩이고 .pkg 가 0개(DeepScan.swift:375-380 실측)라 `--profile <설치본_언팩_씬>` 은
  항상 exit 2 "[profile] meta parse failed". inventory/vis-blast 에 적용된 것과 동일 defect class 의 잔존.
- **검증**: 반증 실패 확정.

## 3. 인라인 발견 — 문서 드리프트 1건

- **README.md:151** — "Tests/ 7 targets, **3,693** tests". 현행 3,708(AGENTS.md:72·BACKLOG.md:3·ci.yml 래치는
  갱신됨). `fd62287d` 의 "문서 수치 셋 동기화" 커밋에서 README만 빠졌다. 한 줄 수정.

## 4. low 39건 — 주제별 군집

### 4a. all-or-nothing 배열/JSON 가족 (M2 와 동근)
- `TextScriptEngine.swift:277` — layersJSONArray 직렬화 가드가 전부-아니면-전무. 원소 하나의 NaN 이
  JS 씬 그래프 통째 소멸 → thisScene.layers 기본 롤백.
- `WallpaperGridView.swift:398` — 그리드 드롭 핸들러가 Data 형태 fileURL 만 처리. NSURL/String 프로바이더는
  드롭 커서 수용(handled=true) 후 조용히 유실, loadItem error 도 폐기.

### 4b. 신뢰경계 잔여
- `Model3D.swift:1245` — 공용 리더 readU32Array 의 마지막 강제언랩(!). 안전성이 산술 불변식 한 줄에 기생.
  파일 카운트 전부가 거치는 공용 진입점이라 후속 편집 하나가 크래시로 번질 수 있는 유일한 잔여.
- `SceneRenderer3D` 문자열→Float 파스 3곳(render-3d 레인) — safeFloat 의 isFinite 필터 우회로
  신뢰경계에서 NaN/Inf 가 유니폼까지 흐름.
- `ProjectJSONParser.swift:72` — G-E3-03 타입 추론이 PathSecurity 정규화 전 원문 file 로 판정.
  URL/절대경로 file 이 .scene 으로 승격되는데 fileName 은 nil → 분류-마운트 불일치(탈출은 아니고 봉쇄됨).

### 4c. 상태기계 비대칭 (미문서화)
- `ParticleSimulator.swift:476` — periodic 이미터가 EmitterWindow.duration 만료로 은퇴하면 주기 컨트롤러가
  영구 정지. duration 유한+periodic 조합은 미측정이라 기록조차 없음.
- `ParticleSimulator.swift:852` — always 트리거 자식이 외부 pause 중 전멸하면 영구 컬(재생성 경로가 init 에만).
- `TextScriptEngine.swift:2644` — destroyLayer 툼스톤 visible=false 를 __updateSceneLayers 가 매 프레임 되돌림.
- `WebRenderer.swift:216` — 재마운트 후 조작 창 재사용 분기가 죽은 WKWebView 프록시(target weak, nil)를 재가동.

### 4d. 데드 코드 / 미배선 / 파스-보존 전용
- `ParticleSimulator.swift:2122` — valueNoise 3종(hashLattice/fade5/valueNoise3) 닫힌 사이클 데드 코드.
- `AudioSpectrum.swift:115` — engineWindowLength(sampleRate:) 호출부 0.
- `SystemAudioSpectrumProvider.swift:274` — magnitudes(from:) 인스턴스 버전, 유일 호출부가 자기 자신.
- `Metrics.swift:64` — searchFieldWidth·gap 소비자 0개. searchFieldWidth 주석은 이미 사라진 툴바 검색 필드를
  현행 용도로 서술.
- `WorkshopAPI.swift:44` — WorkshopItem.fileSize 파스·보존만 하고 소비자 없음.

### 4e. 주석 부정확 (동작은 옳음)
- `ParticleSystem.swift:3401` — mapSeqClampCP "음수도 7 로 접힘" 주석 vs 반환은 원값(-1 입력 시 -1 반환).
  동형 자리(positionOffsetRandom octaves)는 이미 고친 패턴의 미적용.
- `PuppetPose.swift:247` — "single 모드 음수 프레임=클램프와 값이 같다" 는 분수 위상에서 거짓(WE 는 key0 이전 외삽).
- `GLSLTranslator.swift:1806` — "이 다섯" 주석 vs 실제 unsupported 가드 8개.
- `GLSLTranslator.swift:1698` — g_LightAmbientColor 분기는 isEngine 선별로 도달 불가. F744 주석이 담당 위치와 어긋남.
- `SceneDocument.swift:3791` — spacing/padding '전건 nil' 서술이 현행 vec2 우선 경로와 과장.
- `hsvColorRandom`(ParticleSimulator.swift:1367) — divisor<=0 방어가 steps>=2 게이트 뒤 도달 불가.
  지금은 안전하지만 중복 정리 한 줄에 0 나눗셈이 열리는 사각.

### 4f. 희귀 플래그/코퍼스 도달 0 의 시각 차이
- `QuadShaders.swift`(render-passes-shaders) — nearestSource 치환이 주석 명시 집합(4 frag)보다 넓은 6곳에 적용.
  NoInterpolation 플래그 레이어가 premul/refract/3D포그 경로에서 노멀맵·프레임버퍼까지 nearest 샘플링.
- `VolumetricLightPass.swift` — isPointLight 프록시가 ldirectional 을 point 로 오분류(코드가 보고서 이관을 요청한 항목).
- `PropertyAnimation.swift:419` — firedMarkers mode 비교만 대소문자 구분("Loop"/"Mirror" 저작값에서 마커 평생 1회).
- `PlaylistTransition.swift:826` — daytimeEnd 센티넬 -1 이 (-1/1440, 0) 저작값 구간과 충돌.
- `CameraMotion.swift:311` — effectivePathDuration 이 beforeSegment 팔의 segmentEnd 공식(ts[i]+ts[i+1]) 미반영.

### 4g. 라이프사이클/리소스
- `SceneRenderer.swift:1548` — deinit 의 MediaPoller.stop() 가 임의 스레드에서 호출될 수 있음(MediaPoller 메인큐 계약).
  weak self 던 실害는 수 초 잉여 작업.
- `FFmpegConverter.swift:185` — ffmpeg 변환 캐시 evictOldest 가 F560 활성-보호 없이 재생 중 mp4 삭제.
  open-fd 로 재생은 끊기지 않으나 remount 시 불필요 재변환.
- `SceneLivePresentationFix.swift:47` — WAPLE_LIVE_FLIP_FIX 1회 캐시가 setenv 라이브 반영 원칙(SceneRenderer.debugFlag
  [정정 2026-08-19])과 불일치.
- `SceneRenderer.swift:753·786` — 애니 이벤트 마커 클록이 마운트 시점 rate 스냅샷/하드코드 1 — 스크립트 구동 rate 와 표류.
- `SceneRendererResources.swift:555` — GPULayer.def 프레디킷에 animLayerScripts 누락(스크립트-only 레이어 미평가 가능).

### 4h. 오류 전파/UX
- `LibraryStore.swift:215` — extractionTimedOut 이 try? 로 삼켜져 타임아웃이 "배경 없습니다" 메시지로 위장.
- `APIKeyGateView.swift:44` — statusMessage 다중 생산자 vs 게이트 뷰 '키 저장 실패' 단일 의미 해석.
  키 삭제 후 낡은 검색 실패 문구가 새 키 입력란 아래 잔류.
- `AppDelegate.swift:951` — 스틸 파이프라인이 project.id 전역 유일성 가정(폴더명 폴백 id 겹침 시 스틸 공유/덮어씀).
- `DeepScan.swift:809` — scanVideo 타임아웃 경로가 SemaphoreResultBox 직렬화 불변식을 깸(진단 집계 국소 플래핑).
- `ProfilePipeline` 외 support-modules: `LibraryStore.swift:273` 재가입 데이터 소설 경로는 **반증**(방어 코드 확인)됐음.

### 4i. 성능/기타
- `SceneDocument.swift:1994` — referencedImageLayerCompositeIDs 가 파스마다 패키지 전 JSON 전량 디코드·정규식 스캔
  (0.66GiB 패키지에서 마운트당 전액, 캐시 없음의 근거 서술 부재).
- `SceneDocument.swift:3291` — resolveLayerTexture 후보 존재 확인만 sharedAssetProbe 를 안 봄
  (probe-only 주입 시 존재하지 않는 이름 반환 가능).
- `AudioSpectrum.swift:496` — idleSilenceTimeoutMilliseconds 규약('1초 무패킷 → 128 float 영전송') 미구현.
  시스템 오디오 끊겨도 마지막 스펙트럼이 계속 표시.

## 5. 레인 요약 (원문)

<details>
<summary>펼치기</summary>

### core-scene — attention
- 판독량: 약 5673 줄
- 배정 10파일 전체(5,673줄)를 줄단위로 판독했고, 계약 참조 대상(JSONNumerics/AssetJSON/EffectManifest.comboValue/SceneRenderer.mount 호출부)도 교차 검증했다. 신뢰경계 강제언랩·OOB·오버플로우·retain cycle·@MainActor 위반은 실물 결함으로는 발견되지 않았다: 정수 좁힘은 전부 safeInt/blendModeVal 게이트를 타고, 재귀 합성 4곳은 depth<32 가드, ScenePackage.parse 는 전 구간 덧셈-오버플로우 없는 경계검사(i32 throw형), weBool 의 CFBoolean 판별과 first-wins claimObjectID vs last-wins 패키지 색인의 대비는 주석 계약과 코드가 정확히 일치한다. 발견은 (1) data(for:) 의 size>0 게이트가 .blob 백엔드에만 적용되고 .directory 는 0바이트 파일을 성공으로 돌려주는 백엔드 간 비대칭(medium, 도달 0), (2) G-E3-03 타입 추론이 PathSecurity 정규화 전 원문 file 로 판정되어 URL/절대경로 file 이 .scene/.web 으로 승격되는데 fileName 은 nil 이 되는 분류-마운트 불일치(low), (3) resolveLayerTexture 의 텍스처 후보 존재 확인만 sharedAssetProbe 를 빠뜨려 probe-only 호출부에서 존재하지 않는 이름이 반환될 수 있는 것(low), (4)(5) 문서화된 저위험 항목. 나머지 의심 지점(패키지 last-wins, 버전 게이트, ortho 전부-아니면-전무, lightconfig 절단, id 중복 first-wins)은 전부 주석의 WE 실측 근거와 구현이 일치했고 계약 드리프트로 판정되지 않았다.

### core-particle — attention
- 배정 5파일(약 6,600행) 전수 판독 완료. 실행 급 결함(critical/high)은 없다: 강제 언랩·인덱스 OOB·retain cycle·리소스 누수는 없었고, 신뢰경계(JSON) 수치 파싱은 saturatedCount/numericInt/octaves 상한으로 과거 트랩이 전부 메워져 있다. 다만 (1) RemapOperation.swift 의 파형 넷이 실측 문서를 달고 있는데 같은 저장소의 구현(ParticleSimulator.remapEval 경로)과 제곱근 수준에서 어긋나며 — 오라클 테스트가 새 쪽을 못박아 실제 동작은 구현 쪽이 정본 — 같은 파일의 옛 [축정] 블록이 "소비 VM 미해독" 이라 주장하는 것이 그 반증 사례가 되는 1급 계약 드리프트, (2) hsvColorRandom 의 divisor>0 조건이 steps>=2 단락평가 뒤에 가려진 사각(제거 시 즉시 0 나눗셈 트랩) 잠재 함정, (3) 종전 노이즈 커널 교체 후 소비처가 사라진 valueNoise3/hashLattice/fade5 데드 코드, (4) mapSeqClampCP 의 클램프 주석이 약속하는 음수→7 접기가 실제 반환값(raw)과 어긋난 부정확성, (5) 주기 방출 이미터가 EmitterWindow.duration 만료로 영구 은퇴하면 주기 컨트롤러가 갱신 불능으로 얼어붙는 미문서화 상태비대칭, (6) always 자식이 외부 pause 중 전멸하면 영구 컬돼 복귀 경로가 없는 상태기계 비대칭 — 을 확인했다. 전부 행동 가능한 크기이며 우선순위 1번(문서 모순 정리)이 가장 비용 대비 효과가 크다.

### core-shader — healthy
- 판독량: 약 4263 줄
- 4개 파일 4,263줄 전수 판독. 신뢰경계 입력에서 트랩/강제언랩 0, 재귀 파서 전면 깊이 캡, 메모이즈 캐시 락·키 정합, CRLF 규약 일관. 확정 결함은 latent/저심각 3건뿐: (1) engineNeutralDefault 의 g_LightAmbientColor 분기가 isEngine 선별로 도달 불가한 죽은 코드+낡은 주석, (2) Forward+ 라이트 심볼(g_LPoint_*/g_LSpot_*/g_LTube_*/g_LDirectional_*/g_LFeature_Shadow*)의 헬퍼 캡처에서 captureParamDecl 은 float 로, captureCallArg 는 float4/float4x4 를 방출해 파일 내부의 타입 쌍 계약이 깨짐(현재 코퍼스 도달 0건의 latent — 도달 시 MSL 컴파일 실패→셰이더 통째 폴백), (3) translateBody 의 "이 다섯" 주석이 실제 unsupported 가드 8개와 어긋난 문서 드리프트.

### core-model-puppet — attention
- 판독량: 약 3652 줄
- 배정 7개 파일(Model3D/Model3DPose/Model3DFormat/TexImage/PuppetModel/PuppetPose/JSONNumerics, 참고로 BinaryReading.swift 도 전수 판독)을 줄단위로 읽었다. 파서 전반은 방어 수준이 매우 높다(뺄셈형 경계검사, 폭주 캡, graceful degradation, 툼스톤 문화). 그럼에도 1건의 실질 결함군(MDLA 리싱크/이벤트 윈도우가 가변 꼬리 크기 규약과 어긋남 — 클립 유실·이벤트 오귀속 가능, medium)과 2건의 저강도(신뢰경계 마지막 잔류 강제 언랩 1건, single 모드 음수 프레임 클램프 동치 주석의 부정확성 1건)를 확인했다. 치명적 OOB·오버플로우·retain cycle·@MainActor 위반·리소스 누수는 없었고, ponytail/실측 주석이 붙은 단순화들(skeletonTail·uv1 파스·보존 전용, weights 정규화 발산, 0.016→1/60 폴백 등)은 주석과 코드가 일치하는 문서화된 의사결정이어서 결함으로 세지 않았다.

### core-fx — attention
- 배정 9개 파일(~5,400행)을 줄단위로 판독했다. 전반 건강도는 높다: 강제 언랩·try!·정수 변환 트랩·OOB·retain cycle·타이머 누수는 한 건도 없고, 무작위 추출한 주석↔코드 쌍(progress NaN 규약, hermite 항등식, fov NaN→179.9, levelCount floor(log2(min)), blur13 가중치 합, wraploop 덮기 경로, blendParams 패킹)은 전부 실제로 일치했으며, 수상해 보이는 지점 대부분은 ponytail/실측 주석이 붙은 의도적 결정으로 확인됐다. 다만 effect.json/애니 바인딩 파스에서 "배열 원소 하나가 객체가 아니면 배열 통째가 소실" 되는 신뢰경계 견결성 갭 한 건(medium — 같은 파일이 passes 에는 자기 고침을 적용해 놓고 bind/fbos/events 에는 미적용)과, 저작 mode 문자열 대소문자 불일치·daytimeEnd 센티넬 충돌·진단 함수 간 불일치 등 저도수 계약 드리프트 세 건을 확인했다. 코퍼스 도달 0 인 자리들이라 증상 노출 폭은 좁지만, 워크샵 JSON 의 관용 파스 필요율(27/122)을 고려하면 attention 로 판정한다.

### core-audio-fluid — attention
- 판독량: 약 4200 줄
- 배정 13파일 전부 줄단위 판독 완료. 치명적 크래시/OOB/누수는 없었고 수치 코드(binary16 RTNE, Jacobi/발산/경사 제거, simplex 커널, WebCompatPatch 바이트 치환, AssetJSON 관용 파서)는 주석의 산식·근거와 구현이 일치했다. 대신 오디오 소비단에서 계약 드리프트 2건이 확인됐다: (1) AudioSpectrumProcessor.Output.scriptBuffers(_:) 는 "씬 스크립트가 소비단의 MAX 축약 완료값을 그대로 받는다"고 문서화돼 있으나 호출부가 0건이고, 실제 씬 스크립트 경로(SceneRenderer:2103 → TextScriptEngine.__setAudioData)는 64밴드를 받아 평균(×2/×4)으로 재접고 average 도 좌우 평균으로 만들어 순음 저역에서 최대 2~4배 레벨이 갈린다. (2) 같은 파일의 ScriptResolution 이 실측 계약(무인자=16, 무효 해상도는 예외)을 encode 하는데 유일한 소비처인 JS 심은 무인자·무효 모두 64 로 침묵 대체한다. 그 외 저강도 2건(idleSilenceTimeout 규약 미구현, engineWindowLength 미배선). FluidSimulationPrecision.stallBand 의 ν 비교 문구는 테스트와 정합이라 결함 아님.

### render-scene-renderer — healthy
- 배정 6파일(5,733줄) 전수 판독 완료. 1급 결함(crash/누수/데이터레이스/OOB/강제언랩) 없음. 기존 감사 태그(V06/V07/F-series)의 방어 코드가 외부 의존성 교차검증에서도 성립. 저등급 4건: ① 애니메이션 이벤트 마커 타임라인이 마운트 시점 rate를 스냅샷해 스크립트 구동 rate와 장기 표류, ② deinit 경유 MediaPoller.stop()의 메인큐 계약 위반 가능, ③ animationlayers 바인딩 스크립트만 있는 레이어에서 def 프레디킷 누락으로 스크립트가 소비되지 않는 조건부 미배선, ④ WAPLE_LIVE_FLIP_FIX 환경변수 캐싱이 코드베이스 자체 정정 원칙(setenv 라이브 반영)과 불일치.

### render-3d — attention
- 4파일 5,928줄 전수 판독 결과 크래시급 결함(OOB·트랩·언랩·누수)은 없었다. 정점/인덱스 버퍼 경계, 본 인덱스 clamp, 3슬롯 링과 in-flight 프레임 산수, depth bias 단위(D3D10 규약), 섀도우 슬라이스 상한(48), 인코더 분할 후 재개 실패 계약, 시트 프레임 조정 체인은 모두 검증을 통과했다. 남은 것은 (a) 문자열→Float 파스 3곳이 코드베이스 자체 규약(safeFloat 의 isFinite 필터)을 우회해 신뢰경계에서 NaN/Inf 가 유니폼까지 흐르는 결함군, (b) 카메라 fov/nearz/farz 가 어떤 교차검증도 없이 perspective 에 직행하는 빈틈, (c) 3D 텍스트 빌보드의 liveLayerStates[-1] 데드라이트(F811 채널이 3D 텍스트에만 무음 누락), (d) 커스텀 메시 셰이더의 slot-0 샘플러 메타데이터가 ③ 슬롯 규약과 모순되는 잠재 불일치, (e) ortho 메시 경로가 F662 주석이 선언한 씬 포그 참여 규칙을 구현하지 않는 스코프 갭이다. 전부 시각 왜곡/기능 누락 클래스라 건강도는 attention 이다.

### render-text-web — attention
- 배정 7파일(5,497행) 전부 줄단위 판독 완료. 치명적 결함(OOB·강제언랩·retain cycle·누수·@MainActor 위반)은 없다. TextRasterizer/WebHardPauseJS/WallpaperBridgeJS/WallpaperSchemeHandler 는 실결함 미발견(스킴 핸들러의 stop-경합 창 F-28, 하드포즈의 pause 중 rAF 큐잉 등은 코드 내 문서화된 수용 리스크 그대로). TextScriptEngine 에서 계약 드리프트 1건(medium: 공유 컨텍스트 "오염 없음" 주석이 런타임 예외 경로에선 거짓)과 low 4건(console 심 빈약·layersJSONArray 전부-아니면-전무 가드·destroyLayer 툼스톤 가시성 부활·리마운트 후 조작 창 스테일 타깃). TextScriptEngine 의 단위 경계(rad/deg 3경계), F475 오버라이드 스냅샷 복원(세 호출 경로 모두 적용 확인), F810 저장소 상한·락 규율, Range 파서의 end+1 오버플로 분기, 래스터 재귀 축소의 short-circuit(h*4 트랩 없음)은 모두 구현-주석 일치를 확인했다. 발견 수를 채우지 않았다 — 위 5건이 전부다.

### render-media — healthy
- 판독량: 약 3851 줄
- 배정 17개 파일(3,851줄) 전부 정독 및 소비자 교차검증 완료. 계약 어긋남 1급 결함 없음. 신뢰경계(Ogg/Vorbis 비트·코드북 파서의 DoS 가드·OOB 방어, 세마포어 박스의 타임아웃 시 미읽기 규약, Process SIGKILL 에스컬레이션, ffmpeg 캐시 지문 검증)가 일관되게 방어되어 있고, 주석 산식(DCT-IV 위상 항등식, IMDCT TDAC unfold, 빈 폭 Hz 환산, 오버랩-add 인덱스 클램프)도 구현과 정합이었다. 남은 발견은 저강도 2건: (1) 도달 불가 인스턴스 메서드 잔존, (2) ffmpeg 변환 캐시 evict 가 재생 중 파일에 활성-보호(F560) 없이 작동하는 정책 갭 — 후자는 AVPlayer 의 open-fd 로 실害가 흡수되는 완화된 갭이다.

### render-passes-shaders — healthy
- 판독량: 약 4529 줄
- 배정 21파일(4,529행)을 줄단위로 판독했고, 의심 지점마다 호출부/산술 정본(WapleCore HDRBloomMath·SceneWEVolumetricMath·forwardSpotConeCosines·TexImage 파서·SceneRenderer3D/Finalizer/FrameEncoder 배선)을 교차검증했다. 이 레인은 RE 근거 주석 밀도가 매우 높아 견본 조사한 거의 모든 수상 구조가 측정 기반 의도 결정으로 소명됐다: VolumetricLightPass 의 fov 도→라디안 변환은 도 단위 호출부(cam.fov)와 정합(재변환 아님), lz4() 의 baseAddress! 는 파서의 comp>0 가드로 안전, DXT 디코더 인덱스는 bx*by*16 상한검사로 묶임, shadowVP 버퍼 48개는 셰이더 최대 인덱스 47 과 정합, BlendMSL case 31/32 는 자신의 표와 수식 일치, HDRBloomMath 산식은 인용 디스어셈블과 일치. 1급 결함(신뢰경계 크래시·OOM·retain cycle·상태기계 비대칭)은 발견되지 않았다. 남은 것은 low 2건 — ① nearestSource 문자열 전역 치환이 주석이 명시한 프래그먼트 집합(QuadShaders 4개/ParticleShaders 2개)보다 넓은 6개/3개 선언에 적용돼 NoInterprecation 플래그 레이어가 premul·refract·3D포그 경로에서 노멀맵/프레임버퍼까지 nearest 샘플링되는 계약 드리프트, ② 볼류메트릭 isPointLight 프록시의 ldirectional 오분류(코드가 보고서 이관을 명시적으로 요청한 미배선 항목). 둘 다 시각 차이·희귀 플래그 도달이라 즉착 필요성은 낮다.

### app-core — attention
- 판독량: 약 3727 줄
- 배정 14개 파일(약 3,700행)을 줄단위로 판독했다. critical/high 결함은 없다. 메인 액터 규율(assumeIsolated 단언·스냅샷-후-큐 인계), PauseGate 사유 합성, RendererSwap 롤백, 스틸 파이프라인의 정리 경로(defer LIFO 가 mount 실패 조기반환까지 커버), steamcmd 타임아웃 에스컬레이션과 UTF-8 분할 안전성, PathSecurity 경계는 전부 실제로 성립했고 주석-코드 일치도 높았다. 남은 것은 1건의 중간 등급 계약 드리프트(Finder 호스트 예외가 "대형 브라우저 창은 예외 아니다" 주석과 어긋나 옵트인 기능의 무음 실패를 낳는다)와 2건의 저등급(스틸 id 키 비유일 가정, 파스 전용 필드)이다.

### app-ui — attention
- 판독량: 약 5530 줄
- 34개 파일 전수 정독 완료. 실측 주석 기반의 결정들이 표본 검증에서 대체로 코드와 일치하고 강제 언랩·retain cycle·@MainActor 위반 후보는 없었다. 다만 1건의 실질 기능 결함(씬 배경 음량 메뉴가 어떤 입력으로도 씬 음량을 바꿀 수 없음 — 기록 대상 목록과 라이브 적용 경로가 모두 동영상 전용)과 저강도 3건(Data 전용 드롭 복원, 소비자 없는 죽은 토큰 2개와 그 stale 주석, statusMessage 다중 생산자와 게이트 뷰 단일 의미 해석의 불일치)을 확인했다.

### support-modules — attention
- 판독량: 약 3702 줄
- 14개 파일 전수 줄단위 판독 완료(~3,700줄). 스토어 코어(LibraryStore/PlaylistStore/MonitorAssignmentStore/FolderStore/FavoritesStore)의 손상 백업·loadFailed 게이트 규약은 일관되고, PlaybackPolicy/Snapshot 순수 수학은 주석·정본과 일치했다. 그러나 (1) --profile 이 메타 파스에서 여전히 .pkg 만 열어 설치본 코퍼스(188/188 언팩) 전체에서 exit 2 로 사용 불가 — 같은 파일의 [2026-08-25] 수정(inventory/vis-blast)이 막은 것과 동일 defect class 의 잔존, (2) zip 재가져오기에서 등록 실패 시 기존 배경의 관리 폴더가 백업 없이 파괴될 수 있는 데이터 소실 경로, (3) extractionTimedOut 타입 오류가 전 프로덕션 경로에서 삼켜져 타임아웃이 '배경 없음' 메시지로 위장, (4) DeepScan.scanVideo 타임아웃 경로의 무동기화 접근(국소 플래핑) 을 확인했다. 나머지 의심 지점(setenv/ProcessInfo 캐싱, Dictionary nil-subscript, FNV/diff 산식, 마스크 비트접기, hand-port 이름 집합)은 실측·교차검증으로 기각했다.

</details>

## 6. 방법론 비고

- 판독 레인 16개는 배정 파일 전수 줄단위 판독 + 호출부 교차검증을 수행했다. 각 레인은 "발견 수를 채우지 말라"
  지시를 받았고 healthy 레인 4개는 그 지시대로 2~5건만 보고했다.
- medium 전부(12건)를 독립 회의적 검증자(기본 자세: 반증)에게 재판정해 3건이 기각됐다. 기각 근거:
  ScenePackage 0바이트 .directory 는 WE 폴더 마운트 관측과 같은 의도(주석 삼중 근거),
  LibraryStore 재가입은 project.json 사전 파스(hasStableId) 방어로 트리거 재현 불가,
  render-3d 1건은 에이전트 산출 자체가 placeholder(실제 파일 앵커 Scene3DLighting.swift:766 floatValue 는
  String 파스에 isFinite 필터가 있어 무해).
- 검증자 사망 0 · 레인 사망 0. handoff §5 의 게이트웨이 장애는 재현되지 않았다(단, 동시성 2 제한 운용 중에는
  재현 여부를 알 수 없다 — 재개판은 전체 동시 실행이었다).
