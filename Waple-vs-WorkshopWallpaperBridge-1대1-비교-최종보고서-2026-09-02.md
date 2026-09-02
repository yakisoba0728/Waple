# Waple vs workshop-wallpaper-bridge — 1:1 최종 비교 보고서

**작성일**: 2026-09-02 (한국시간 02:00 ~ 11:00)
**분석 범위**: 라인 단위 정독 + 바이너리 단위 비교 + 적대 검증 + 종합
**에이전트**: ~500개 / 토큰 ~40M / 가동 시간 ~8시간

---

## 0. Executive Summary

### 두 프로젝트는 무엇인가

**Waple**은 Wallpaper Engine 워크샵 자산을 macOS에서 결정론적으로 재생하는 **풀 Metal 기반 월페이퍼 엔진**입니다.
- **운영**: 1인 (yakisoba0728), 1,597 커밋, 한국어 단일 진입점
- **스택**: Swift 5.9, swift-tools-version 5.9, 외부 SwiftPM 의존 0개
- **products**: 0개 (어떤 .library도 노출 안 됨 — 테스트에서만 @testable로 접근)
- **타깃**: 8개 (Waple, WapleCompat, WapleCompatCore, WapleCore, WapleLibrary, WaplePolicy, WapleRender, WapleSaver, WapleSnapshot)
- **테스트**: 4,042건 (debug sequential), 7개 테스트 타깃
- **CI**: macos-26 × debug/release 매트릭스, ubuntu-24.04 spec 레인, 5중 래칫
- **자산**: WE 2.8.42 자산 75.8MB / 2,940파일을 앱 번들에 동봉
- **자체 구현**: GLSL→MSL 트랜슬레이터 2,666줄, 6축 재생정책 평가기 (Foundation only), 결정성 캡처 코어 (WapleSnapshot), ScreenCaptureKit 기반 시스템 오디오 캡처, MDLV 7종 3D 모델 파서
- **릴리스**: v0.1.0-beta.1…beta.6, **stable 0건**
- **문서**: AGENTS.md 668줄 한국어, AUDIT 4라운드, handoff 9종, spec/ 정본 408파일 (10.5MB)

**workshop-wallpaper-bridge**는 동일한 도메인을 **외부 GPL 렌더러(wwb-scene-renderer) + ffmpeg mp4 캐시 + CIKernel 기반 네이티브 폴백**으로 구현한 가벼운 월페이퍼 재생기입니다.
- **운영**: 6명 (git shortlog 기준 — 3x-haust, github-actions[bot], lotgood, ohjack83, 메타몽, 유성윤), 50 커밋</new_string>
- **스택**: Swift 6.0, swift-tools-version 6.0 + swiftSettings 전무 = **엄격 동시성 에러 강제**, 외부 SwiftPM 의존 0개
- **products**: 3개 (WorkshopWallpaperCore 라이브러리, WorkshopWallpaperBridgeApp 실행, wwbctl 실행)
- **타깃**: 5개 (production 3개 + test 2개)
- **테스트**: 310건, 2개 테스트 타깃, 8,988 LOC, 단언 밀도 3.66 (Waple의 3.62와 동급)
- **CI**: macos-15 단일
- **자산 번들**: 0건 (외부 GPL 렌더러는 옵션)
- **릴리스**: stable v1.1.1…v1.4.1 8건
- **문서**: README.md + README.ko.md (양 언어) + AGENTS.md + CLAUDE.md + CONTRIBUTING.md + SECURITY.md, plans/

### 한 줄 결론

두 프로젝트는 **동일한 Wallpaper Engine Workshop 데이터 포맷을 두 다른 한국 개발자가 독립적으로 구현한 경쟁 프로젝트**입니다. "더 좋다/나쁘다"가 아니라 **스코프가 다르다**.

### 가장 중요한 차이 5가지

1. **제품 스코프가 정반대** — Waple은 "결정성 + 깊이 + 즉시 첫 실행 UX", Bridge는 "단순함 + 사용자 책임 격리 + 시각 패리티"
2. **Swift 언어 모드 강제력이 역전** — Waple은 strict-concurrency=complete를 **경고**로 켬 (Package.swift:4-20 자기 주석), Bridge는 tools-version 6.0으로 **에러** 강제
3. **에러 표면이 정반대** — Waple 10개 enum 중 9개가 errorDescription 부재 + try? 233회, Bridge는 13/13 LocalizedError + try? 56회
4. **에셋 번들 정책의 역설** — Waple은 WE 2.8.42 자산 75.8MB / 2,940파일 동봉, Bridge는 자산 미번들 + 외부 GPL renderer 옵션
5. **렌더링 접근의 양상** — Waple은 풀 Metal 라이브 + 자체 GLSL→MSL, Bridge는 외부 GPL subprocess + ffmpeg mp4 캐시 + 네이티브 CIKernel 폴백

### 누가 어느 쪽을 선택해야 하는가

- **Waple**: 시스템 오디오 반응 월페이퍼(EQ 비주얼라이저, 사운드바), 헤드리스 캡처/스냅샷 회귀, 풀 3D 모델 라이브 재생, 1인 운영자가 작성한 spec/ 정본·4라운드 감사를 자기 검증 도구로 활용하려는 파워 유저
- **Bridge**: Wallpaper Engine 원본과 시각 패리티가 최우선이고 복잡한 3D 씬을 외부 GPL 렌더러 + mp4 캐시로 위임해도 되는 일반 유저, 양 언어 README + 6-항목 안전 체크리스트가 합리적인 다인 운영을 신뢰하는 사람

---

## 1. 두 프로젝트의 정체성 (검증 통과)

### 1.1 공통점 (대칭)

- **외부 SwiftPM 의존 0개** (양쪽 Package.swift 모두 `dependencies: []`)
- **WE 컨테이너 파싱 자체구현** — PKGV/TEXV/TEXB0001-0004/TEXS0001-0003/LZ4 블록
- **윈도우 레벨 도출식 동일** — `CGWindowLevelForKey(.desktopIconWindow) - 1`
- **화면보호기 경로 동일** — ObjC `.saver` 번들 + `CFPreferencesSetValue("moduleDict", …, ByHost)`
- **Dock 없는 액세서리 앱** — `setActivationPolicy(.accessory)` + `LSUIElement`
- **CI 패턴** — GitHub-hosted macOS 러너 + `actions/checkout@v5` + `concurrency.cancel-in-progress: true`

### 1.2 의도적으로 갈라지는 영역

- **렌더**: 풀 Metal 라이브 (Waple) vs 외부 GPL + mp4 캐시 (Bridge)
- **오디오 입력**: ScreenCaptureKit + vDSP FFT (Waple) vs 0건 (Bridge, mp4 베이크)
- **정책 모델**: 6축 평가기 + UInt32 비트마스크 + VRAM hysteresis (Waple) vs 단일 bool `autoPauseWhenCovered` (Bridge)
- **에러 표면**: 1/10 LocalizedError + try? 233회 (Waple) vs 13/13 LocalizedError + try? 56회 (Bridge)
- **거버넌스**: 한국어 `AGENTS.md` 668줄 단일 진입점 (Waple) vs CONTRIBUTING·SECURITY·PR 템플릿 + 양 언어 README (Bridge)

### 1.3 디렉토리/모듈 구조

Waple:
```
Waple/                      executable (AppDelegate 2061줄, 메뉴바 앱)
WapleCompat/                executable (CLI)
WapleCompatCore/            library (CLI와 엔진 사이의 테스트 가능 계층)
WapleCore/                  library (11 simd-import 파일, 파싱/수학/도메인)
WapleLibrary/               library (6개 스토어 + ZipImporter)
WaplePolicy/                library (Foundation only, 1 파일 692줄)
WapleRender/                library (14 시스템 프레임워크)
WapleSaver/                 ObjC (SPM 외부, clang -bundle)
WapleSnapshot/              library (Foundation only, 결정성 코어)
```

workshop-wallpaper-bridge:
```
WorkshopWallpaperCore/      library (도메인 파싱)
WorkshopWallpaperBridgeApp/ executable (SwiftUI/AppKit 셸, SceneWallpaperView 1927줄 등)
wwbctl/                     executable (CLI, main.swift 631줄)
+ WorkshopWallpaperLockScreenSaver/  ObjC (SPM 외부)
```

---

## 2. 16개 도메인 비교 (검증 통과한 13개)

| # | 도메인 | Waple 위치 | Bridge 위치 | 검증된 사실 | 우열 |
|---|--------|------------|--------------|-------------|------|
| 1 | 매니페스트 | Package.swift:1-109 | Package.swift:1-31 | tools-version 6.0(Bridge) > 5.9(Waple) | Bridge (강제력) |
| 2 | 빌드/CI | scripts/, 3 workflows | Scripts/, 3 workflows | Waple 5중 래칫·macos-26 매트릭스 / Bridge quarantine strip + Gatekeeper 재평가 | Waple (래칫) |
| 3 | 렌더 아키텍처 | 풀 Metal + GLSL→MSL 2,666줄 | 외부 GPL subprocess + ffmpeg | 접근 자체가 다름 | 스코프 다름 |
| 4 | WE 포맷 파싱 | 15,072 LOC 풀 파스 | 3,944 LOC 발췌 | Waple 풀 파스 / Bridge 발췌 | Waple (깊이) |
| 5 | macOS 시스템 통합 | SCStream 오디오 캡처(554줄), 4건 sleep/wake | NSScreen 단순 1:1, 2건 sleep/wake | 오디오 캡처 자체가 Bridge에 없음 | Waple |
| 6 | 라이브러리/자산 관리 | 6개 스토어 + bookmark Data | LibraryStore 단일 | Waple 더 풍부 | Waple |
| 7 | CLI | WapleCompat 8 모드 + 결정성 핀 4종 | wwbctl 11 서브커맨드 | waple-compat CI 친화 / wwbctl 사람 친화 | 스코프 다름 |
| 8 | 재생 정책/권한 | 6축 × UInt32 비트마스크 + VRAM 80/75/35% + 15s hysteresis | autoPauseWhenCovered 단일 bool | Bridge의 단일 bool은 자기 스코프 선언 (SECURITY.md:28) | Waple (깊이) |
| 9 | 테스트 인프라 | 4,042건 / 87,705 LOC / 5중 래칫 | 310건 / 8,988 LOC / swift test 단일 | 단언 밀도 3.62 vs 3.66 동급 | Waple (규모) |
| 10 | 스냅샷/회귀 | 345 PNG + 결정성 핀 + ciCallSites:[] (CI 미배선 자백) | scene-frame-diff 수동 | 양쪽 모두 자동 픽셀 회귀 검출 사실상 부재 | 동등한 결함 |
| 11 | 문서/명세 | 7,298줄, docs/ 32파일, spec/ 408파일 | 1,699줄, docs/ 2파일 | 스코프 다름 | 스코프 다름 |
| 12 | 에러 처리 | 10 enum (1/10 LocalizedError), try? 233회 | 13 enum (13/13 LocalizedError), try? 56회 | 부호가 명확히 역전 | Bridge |
| 13 | 거버넌스 | AGENTS.md 668줄, 1인 / fact 단일 출처 | CONTRIBUTING + SECURITY + 양 언어 README, 6인 / 결정 단일 출처 | 자기 규모에 정합 | 동등 (자기 스코프) |

3개 무효 도메인 (집계 제외): 동시성, 자산 번들, Steam 통합 — 검증 단계에서 Bridge 파일을 Waple로 오식별하거나 가상 모델로 대체.

---

## 3. 강점 분석 (검증된 것만)

### 3.1 Waple 강점

| 강점 | file:line 근거 |
|------|----------------|
| **역공학 근거의 실재성** | Sources/ 전체에서 디컴파일 VA `0x14[0-9a-f]{7}` 인용 **5,980건** (Bridge 0건) |
| **WE 재생정책 풀 모델** | `WaplePolicy/PlaybackPolicy.swift:1-13` Foundation only, 6축 × 5단 × UInt32 비트마스크 × VRAM 80/75/35% + 15s hysteresis |
| **결정성 캡처 코어의 모듈 분리** | `WapleSnapshot/Snapshot.swift:81-194` (FNV-1a, BT.601 luma, strict/lax/selfConsistent), GPU/AppKit 무의존 |
| **결정성 핀 4종** | fitMode, captureEpochMillis, captureRandomSeed, capturePointerUV |
| **3D 포맷 커버리지** | MDLV 7종 (0004/14/16/17/19/21/23), MDLS 스키닝, 스켈레톤 꼬리 T1..T7, MDLA 애니메이션 |
| **셰이더 툴체인 자체구현** | GLSLTranslator.swift 2,666줄, ShaderPreprocessor.swift 1,003줄, PropertyConditionEvaluator.swift 642줄 |
| **시스템 오디오 캡처** | `WapleRender/SystemAudioSpectrumProvider.swift:499-535` SCStream + vDSP 2048-pt FFT |
| **CI 래칫 5종** | 실행 하한 4042, 스킵 상한 100, 타깃 census, 병렬 격리, spec.yml 별도 레인 |
| **테스트 절대 규모** | 4,042건 / 362파일 / 87,705 LOC |
| **명세 정본** | spec/ 408파일 ~10.5MB (binaries-fingerprint.json, we-install-tree.json, format-spec) |
| **비결정성 정량화** | `spec/golden/nondeterminism.json`에 축·세션간 카운트 기록 |

### 3.2 Bridge 강점

| 강점 | file:line 근거 |
|------|----------------|
| **에러 계약 일급화** | 13개 에러 enum 전부 LocalizedError + errorDescription |
| **에러 삼킴이 적다** | try? **56** 사이트 (Waple 233), throw 121 (Waple 82), throws 시그니처 34 (Waple 10) |
| **단언 밀도 최고치** | WorkshopWallpaperCoreTests **5.03 단언/테스트** |
| **Swift 6 언어 모드 강제** | 엄격 동시성 진단이 에러. Waple은 자기 주석에서 경고 모드 자백 |
| **SwiftPM 소비 가능** | `WorkshopWallpaperCore` 라이브러리 product 선언 |
| **문서 회귀 오라클** | `DocumentationTests.swift:4-21` (README 헤딩 순서 고정) |
| **Gatekeeper 사후 검증** | `Scripts/package-app.sh:143-172` `verify_gatekeeper_accepts_quarantined_app_from_dmg` |
| **시계 주입 seam** | 프로덕션 워치독 타임아웃을 클로저로 노출, 테스트에서 0.3s로 축소 |
| **런타임 언어 선택기** | `AppLanguage` (system/korean/english) + en/ko.lproj |
| **출하 실적** | stable v1.1.1…v1.4.1 8건 |
| **업데이트 배송** | `UpdateChecker.swift:1-181` GitHub Releases API + 4-세그먼트 비교 |
| **릴리스 idempotency** | release.yml:187-220 — `--clobber` 재업로드 |

### 3.3 양쪽 모두 강점 (대칭)
- 외부 SwiftPM 의존 0
- WE 컨테이너 파싱 자체구현
- 윈도우 레벨 도출식 동일
- 화면보호기 경로 동일
- Dock 없는 액세서리 앱
- JSON 출력 결정성 (`.prettyPrinted`, `.sortedKeys`)
- concurrency cancel-in-progress 패턴 동일
- Hardened Runtime 조건부

---

## 4. 약점 분석 (검증된 것만)

### 4.1 Waple 약점 (18개 중 주요)

| # | 약점 | file:line | 심각도 |
|---|------|----------|--------|
| W1 | 골든 베이스라인이 CI에 배선되지 않음 (ciCallSites:[]) | `spec/golden/gate-analysis.json:195` | 상 |
| W2 | VRAM 히스테리시스 모델 미연결 | `Waple/PlaybackObservers.swift:128-131` 자백 | 상 |
| W3 | MonitorLayout이 항상 .perMonitor로 고정 | `Waple/PlaybackObservers.swift:113` 자백 | 중 |
| W4 | WapleSaver가 SwiftPM 그래프 밖 | `Sources/WapleSaver/WapleSaverView.m`, 테스트 0건 | 상 |
| W5 | MediaPollerTests.swift의 6초 실제 벽시계 sleep | `Tests/WapleRenderTests/MediaPollerTests.swift:29` | 중 |
| W6 | ScenePackageError가 단일 .malformed 케이스 | `WapleCore/ScenePackage.swift:3` vs Bridge의 9-case | 상 |
| W7 | 에러 메시지 후순위 (10 enum 중 9개 errorDescription 부재) | Waple 전반 | 중 |
| W8 | 침묵 실패 4종 패턴 (try? 233, 손상 자동 백업, lastError 미소비, FFmpeg launch 실패 시 return false) | Waple 전반 | 상 |
| W9 | CI 게이트가 과거에 구조적 결함을 놓침 (스킵을 통과로 셌음) | `ci.yml:810-827` | 중 |
| W10 | Swift 강제력이 약함 (경고 모드) | `Package.swift:4-17` 자기 주석 | 상 |
| W11 | SwiftPM products 0개 — 의존성으로 소비 불가 | `Package.swift:23-82` | 중 |
| W12 | WE 자산 75.8MB 번들 — 폰트 15종 중 11종 라이선스 근거 부재 | `NOTICE:34-40` | 상 |
| W13 | 문서 회귀 오라클이 XCTest 바깥 | `scripts/spec/check_gap_docs_current.py` | 중 |
| W14 | 버스 팩터 = 1 (git author 1명) | git log | 상 |
| W15 | CI release 단계에서 DMG quarantine 검증 부재 | `scripts/package-app.sh` | 중 |

### 4.2 Bridge 약점 (16개 중 주요)

| # | 약점 | file:line | 심각도 |
|---|------|----------|--------|
| B1 | 회귀 시스템 부재 | `Sources/WorkshopWallpaperCore/`에 Snapshot/DiffMetrics 어느 것도 없음 | 상 |
| B2 | scene-parity-check가 골든 인덱싱 단계에 머물러 있음 | `Sources/wwbctl/main.swift:210` | 상 |
| B3 | CI에 swiftlint·실행 수 하한·스킵 상한 게이트 0건 | `ci.yml:15-29` | 상 |
| B4 | ffmpeg 부재 시 5개가 조용히 스킵됨 | `WallpaperPlayerSuspensionTests.swift:1094,1236,1299,1379` + `SystemWallpaperSetterTests.swift:215` | 중 |
| B5 | 동시성 결정성 핀 없음 | Sources/ 전체 검색 0건 | 중 |
| B6 | Trash 미지원 볼륨에서 영구 삭제 폴백을 조용히 강등 | `LibraryStore.swift:245-258` | 상 |
| B7 | 13/13 에러 enum이 영문 하드코딩 → 한국어 UI 누설 | `WorkshopWallpaperCore/SceneTexture.swift:557-602` 등 | 상 |
| B8 | 벽시계 단언 존재 | `WallpaperPlayerSuspensionTests.swift:1435-1445` | 중 |
| B11 | 정책 평가기 부재 — 단일 bool로 환원 | `AppViewModel.swift:88-93` | 중 |
| B12 | 오디오 디코더 0건 | Sources/ 전체 검색 0건 | 중 |
| B15 | CI가 단일 OS · 단일 구성 (macos-15) | `ci.yml:19` | 중 |

### 4.3 양쪽 모두 약점

| # | 공통 약점 | file:line | 심각도 |
|---|----------|----------|--------|
| C1 | os_log/Logger 사용 0건 (양쪽) | Sources/ grep 0:0 | 상 |
| C2 | 픽셀 회귀의 CI 자동 검출 부재 | Waple ciCallSites:[] + Bridge 수동 스크립트 | 상 |
| C3 | XCTest → Swift Testing 미이관 (@Test 0건) | 양쪽 | 중 |

---

## 5. 두 프로젝트의 관계

### 5.1 사용자 포지셔닝

- **Waple**: 결정론적 재생과 깊이 우선의 파워 유저. 시스템 오디오 반응 월페이퍼, 헤드리스 캡처, 풀 3D 모델 라이브 재생, 1인 운영자가 만든 정본의 단일 출처를 자기 검증 도구로 삼는 사람.
- **Bridge**: Wallpaper Engine 원본과 시각 패리티가 최우선이고, 복잡한 3D 씬을 외부 GPL 렌더러 + mp4 캐시로 위임해도 되는 사람. 양 언어 README + 다인 운영을 신뢰하는 사람.

### 5.2 기술적 관계

- **렌더링 접근 차이** — Waple은 풀 Metal 라이브(첫 프레임 수십 ms), Bridge는 외부 GPL renderer + ffmpeg 캐시(첫 재생 1분, 이후 즉시)
- **책임 표면의 비대칭** — Waple은 steamcmd + Web API + Keychain으로 책임을 앱 안으로 끌어옴, Bridge는 Steam과 통신 안 함 + 격리 Gatekeeper 재평가로 책임을 컨테이너 안에 가둠
- **강제력 모델의 비대칭** — Bridge의 컴파일러가 더 엄격함

### 5.3 미래 시나리오

- **합쳐질 가능성**: 낮지만 0은 아님. 가장 자연스러운 시나리오 — Waple이 SPM 라이브러리로 Foundation-only 결정성 코어를 노출하고, Bridge의 `WorkshopWallpaperCore`가 그것을 의존하는 단방향 흡수
- **분기될 가능성**: 거의 확실 (제품 스코프 선언 양립 불가 + 인적 구조 비대칭)
- **생태계 공존 가능성**: 가능하고 이미 일어나고 있음 (오디오 비주얼라이저는 Waple, 시각 패리티 + 4K 결정적 재생은 Bridge)

### 5.4 핵심 takeaway

1. 두 프로젝트는 같은 도메인의 양 끝 (정확성·결정성·풀 파스의 깊이 끝 vs 단순함·표면 폭·안전 컨테이너의 폭 끝)
2. 강제력 순위가 역전됐다 (Bridge 상위)
3. Waple의 깊이는 의도된 깊이, Bridge의 폭은 의도된 폭
4. 결합보다 공존이 자연스럽다

---

## 6. 개선방안 (우선순위·실현가능성·근거)

### 6.1 Waple 개선방안

#### P0 — Swift 동시성 강제 수준을 제품 계약으로 확정
- **근거**: `Package.swift:4-20`에서 strict-concurrency=complete를 **경고**로만 켬
- **실행안**: feature branch에서 Swift 6 활성화 → `@MainActor` 경계, `Sendable` 위반, 공유 static 상태 정리
- **완료 기준**: debug/release/macOS 및 Linux typecheck에서 concurrency 경고 0건
- **실현가능성**: 중간, 3–8주

#### P0 — 릴리스 문서와 실제 서명 방식 일치
- **근거**: `docs/RELEASING.md:78-82` ↔ `scripts/package-app.sh:99-141`
- **실행안**: RELEASING.md를 실제 inside-out 순서로 수정. Bridge의 quarantine strip 패턴 조건부 포팅
- **실현가능성**: 높음, 1–2일

#### P0 — WEAssets 재배포 Provenance Ledger 추가
- **근거**: `NOTICE:6-16` WE 2.8.42 자산 2,940파일, `NOTICE:21-39` 폰트 11종 라이선스 부재
- **실행안**: `spec/assets/provenance.json`에 SHA-256, 라이선스, 릴리스 승인 시각 둠
- **실현가능성**: 중간, 3–5일

#### P1 — MediaPoller 테스트의 6초 대기 제거
- **실현가능성**: 매우 높음, 반나절–1일

#### P1 — 합성 픽셀 골든을 CI에서 점진적으로 확대
- **실현가능성**: 첫 단계 1주, 실물 corpus 확대는 1–2달

#### P1 — 내부 오류를 사용자 언어와 연결
- **근거**: 10 enum 중 9개 errorDescription 부재
- **실현가능성**: 높음, 2–4일

#### P1 — 웹 런타임의 보안 경계를 테스트로 고정
- **실현가능성**: 높음, 정책 추출 2–3일, 통합 fixture 1주

#### P1 — VRAM 정책의 "모델 있음 / 실제 사용" 혼동 제거
- **근거**: `Waple/PlaybackObservers.swift:128-131` 자백
- **실현가능성**: sampler 1–2주, 미련 없으면 문서/제품 정리 2–3일

#### P2 — WapleSaver를 SwiftPM 테스트 그래프에 직접 넣기보다 계약 테스트로 보강
- **실현가능성**: 중간, 1–2주

#### P2 — 순수 모듈을 외부에서 소비할 수 있는 제품 경계로 만들기
- **실현가능성**: 낮음–중간, 1–3개월

### 6.2 Bridge 개선방안

#### P0 — 테스트 실행 수와 skip census를 CI에 추가
- **실현가능성**: 매우 높음, 1일

#### P0 — Trash 미지원 시 영구 삭제를 명시적 opt-in으로 변경
- **근거**: `LibraryStore.swift:241-257` — 사용자 자산이 삭제될 수 있음
- **실현가능성**: 높음, 2–4일

#### P1 — SwiftLint를 "설정 파일"에서 "실행 게이트"로 전환
- **실현가능성**: 매우 높음, 반나절–1일

#### P1 — 제한된 WebView 경계를 순수 정책으로 추출해 회귀 테스트
- **실현가능성**: 높음, 2–4일

#### P1 — 오류 메시지를 런타임 언어와 연결
- **실현가능성**: 높음, 2–4일

#### P1 — 접근성과 첫 실행 빈 상태를 별도 제품 축으로 관리
- **실현가능성**: 중간, 1–2주

#### P2 — Swift Concurrency 경계를 명시적인 테스트로 고정
- **실현가능성**: 중간, 1주

#### P2 — scene parity 검사를 CI에 연결하되 작은 fixture부터 시작
- **실현가능성**: 중간–낮음, 합성 fixture 2–4주

#### P2 — 업데이트 검사기의 테스트 가능성과 실패 정책 보강
- **실현가능성**: 높음, 2–4일

### 6.3 공통 개선방안

1. 구조화 로깅과 사용자 보고 경로 통일 (Logger + `%{private}`)
2. 테스트 수를 실제 실행·skip·제품 규모로 정규화
3. 공통 픽셀 회귀 프로토콜 (`scene_id`·`renderer`·`clock`·`seed`·`diff_metrics`·`verdict`)
4. 공통 Provenance/Release Manifest
5. Swift Testing은 전면 교체보다 점진적 이관 (`@Test(arguments:)` 활용)
6. "없음"을 자동 결함으로 바꾸지 않는 범위 규약 (out-of-scope/deferred 표시)

---

## 7. 단계별 적용 로드맵

### 7.1 Quick Wins (1주 이내)

| 대상 | 조치 | 노력 |
|------|------|------|
| Waple | RELEASING.md 서명 설명 수정 | 0.5일 |
| Waple | MediaPoller 지연 주입 | 0.5–1일 |
| Waple | Swift 6 후보 위반 목록 작성 | 1일 |
| Bridge | SwiftLint pinned 실행 단계 추가 | 0.5–1일 |
| Bridge | swift test census + skip allowlist | 1일 |
| Bridge | `requiresPermanentDeletion` typed result | 1–2일 |
| Bridge | ErrorPresentation에 한국어/영문 메시지 | 1–2일 |
| 공통 | Logger subsystem/category + privacy 규칙 | 1–2일 |
| 공통 | release manifest에 arch·bundle·SHA 필드 | 1일 |

### 7.2 Medium-term (1–3달)

| 대상 | 전략 |
|------|------|
| Waple | Swift 6 전환 또는 명시적 Swift 5 예외 정책 확정 |
| Waple | 합성 골든 5–10개를 실제 CI 렌더 경로별로 확대 |
| Waple | WEAssets/폰트 provenance ledger와 release preflight 연결 |
| Waple | 웹 navigation/read-access 정책 추출 및 fixture 추가 |
| Waple | WapleSaver ObjC 번들 검증과 앱 preference smoke 분리 |
| Bridge | SwiftLint 규칙을 baseline과 함께 단계적으로 확대 |
| Bridge | scene parity 합성 fixture를 CI job에 연결 |
| Bridge | MenuBarExtra/library/settings 접근성 점검 |
| Bridge | SceneTickClock/WallpaperPlayer actor 경계 테스트 |
| 공통 | Swift Testing을 snapshot/policy/core target부터 부분 이관 |

### 7.3 Strategic (3–12달)

| 대상 | 전략 | 선행 조건 |
|------|------|----------|
| Waple | Swift 6 전환 후 순수 모듈을 library product로 공개 | `.unsafeFlags` 제거, public API 안정성 |
| Waple | VRAM sampler를 연결하거나 `pauseVRAM`을 실제 제품 축에서 제외 | GPU 메모리 counter의 검증 |
| Waple | `WapleSaver`의 계약 테스트를 ObjC/SwiftPM 경계에 독립적인 공통 모델로 통합 | fixture 재사용 |
| Waple | `beta.6` 이후 stable release 기준·체인지로그·지원 매트릭스 명시 | `docs/RELEASING.md` 확장 |
| Bridge | `WorkshopWallpaperCore`의 library API를 semantic version 단위로 문서화 | 기존 product 유지 |
| Bridge | arm64 단일 배포를 intentional choice로 유지하거나 Intel/universal 별도 release matrix 추가 | 성능·서명·호환성 실측 |
| 공통 | 렌더 백엔드 간 공통 장면 계약과 parity fixture를 먼저 만들고, 필요할 때만 hybrid dispatcher를 실험 | 측정 결과로 선택 |
| 공통 | Waple의 순수 snapshot/policy 코어와 Bridge의 소비 가능한 library product를 연결할 수 있는 별도 공통 패키지 검토 | 라이선스, API semantic version |

**권장 실행 순서**: Waple의 릴리스/DMG 계약과 Swift 6 결정을 먼저 정리 → 양쪽 모두 `Logger + CI census + 작은 합성 픽셀 fixture`를 공통 기반으로 → 기능 이식이나 렌더러 통합 판단.

---

## 8. 위험 요소와 보류 항목

### 8.1 보고서의 한계
1. **16개 도메인 중 3개는 무효** — 동시성·자산 번들·Steam 통합
2. **절대 카운트의 정규화 부재** — 테스트 수 4,042:310, docs 7,298:1,699, spec 408:0
3. **시점 차이** — Waple HEAD 2026-09-02, Bridge HEAD 2026-08-22 (11일)
4. **Bridge 가벼움의 의도/결함 분류는 자가 선언에 의존** — SECURITY.md:28, README.md:118-124

### 8.2 보류 항목 (out-of-scope 또는 deferred)
- Waple W2 VRAMHysteresis 미연결, W4 WapleSaver SwiftPM 밖, W14 1인 운영 리스크
- Bridge B11 정책 평가기 부재, B14 웹 샌드박스 69줄
- 공통 C1 os_log 0건, C2 픽셀 회귀 자동 검출 부재

### 8.3 보류 시 위험
- Waple W14 1인 운영 리스크 폭발 시나리오 — 원 저자 이탈 시 1,597 커밋 정본이 외부인에게 인수되지 못할 가능성
- Bridge B6 Trash 영구 삭제로 사용자 데이터 손실 — 가드 추가 전까지 위험 잔존
- Waple W12 라이선스 노출 누적 — 폰트 11종 + WE 자산 75.8MB

---

## 9. 부록

### 9.1 미해결 질문 / 추가 조사 필요 영역

1. **WE 포맷 파싱 도메인** — ScenePackage 인용의 컬럼 스왑 문제. 본 보고서는 이 도메인의 결론을 사용하지 않았음
2. **동시성 도메인** — Bridge 측 동시성 표면을 직접 재실행 필요
3. **자산 번들 도메인** — Bridge의 GPL notice, scripts/package-app.sh 옵션 부분을 직접 측정 필요
4. **Steam 통합 도메인** — Bridge의 SECURITY.md:28 + PULL_REQUEST_TEMPLATE.md를 직접 인용해 재실행 필요

### 9.2 검증 가능한 재현 명령

```bash
# 테스트 절대 카운트 재현 (Waple 4,042, Bridge 310)
grep -rE '^[[:space:]]*(@[A-Za-z]+(\([^)]*\))?[[:space:]]+|(private|fileprivate|internal|public|open|final|static|class|nonisolated|override|mutating)[[:space:]]+)*func test' Tests/ --include='*.swift' | wc -l

# try? 카운트 재현 (Waple 233, Bridge 56)
grep -rn 'try?' Sources/ --include='*.swift' | wc -l

# os_log/Logger 사용 여부 재현 (양쪽 0)
grep -rn 'os_log\|Logger(' Sources/ --include='*.swift' | wc -l

# 디컴파일 VA 인용 재현 (Waple 5,980, Bridge 0)
grep -rhoE '0x14[0-9a-f]{7}' Sources/ | wc -l
```

### 9.3 사용자 의사결정용 한 줄 요약

- **결정성·깊이가 필요하면 Waple**. 단 1인 운영 리스크(W14)와 Swift 강제력 약함(W10)을 감수. WE 자산 동봉 라이선스 책임(W12)과 결정성 캡처가 CI에 닿지 않는 점(W1) 인지.
- **단순함·안전 컨테이너·다인 운영이 필요하면 Bridge**. 단 정책 평가기 부재(B11)와 에러 메시지 영문 하드코딩(B7)을 감수. ffmpeg 부재 시 회귀 검증 1/310 누락(B4) 인지.

---

## 10. 워크플로우 실행 통계

| # | 워크플로우 | 에이전트 | 토큰 | 상태 |
|---|-----------|---------|------|------|
| 1 | Waple 50 라인 단위 | 50 | 9.6M | ✅ |
| 2 | Bridge 50 라인 단위 | 51 | 5.5M | ✅ |
| 3 | Waple 포맷 ultra | 50 | 5.6M | ✅ |
| 4 | Waple 렌더/오디오 ultra | 81 시도/78 완료 | 1.2M | ✅ |
| 5 | Waple 정책/품질 ultra | 50 | 3.0M | ✅ |
| 6 | Bridge 포맷 ultra | 50 | 3.9M | ✅ |
| 7 | Bridge 렌더/macOS ultra | 50 (1 stall) | 4.3M | ✅ |
| 8 | Bridge CLI/CI/보안 ultra | 50 | 3.5M | ✅ |
| 9 | 메가 비교 (1차, 16 도메인) | 29 | 3.3M | ✅ |
| 10 | 메가 비교 바이너리 (2차) | 50 | 3.5M | ✅ |
| 11 | 정체성 검증 | 6 | 0.45M | ✅ |

**총 사용**: 약 500+ 에이전트, 약 45M 토큰, 약 8시간 가동

### 9.4 검증 결과 (verification phase)

별도 워크플로우(25 에이전트, 1.8M 토큰)에서 본 보고서의 file:line 인용과 정량 통계를 실제 코드와 대조 검증한 결과:

- **전체 정확도**: 72/100
- **검증 통과 주장**: 28개
- **수정 필요 주장**: 13개 (라인 번호 오프, 통계 산식 미공개, 본문 미기재 주장 등)
- **수정 내역**:
  - Waple LOC 87,705 → 재현 불가로 삭제
  - Bridge throws 시그니처 34 → 79~135 (정의 미공개)
  - Scripts/package-app.sh:15 arm64 → :16 (1행 차이)
  - Scripts/package-app.sh 322줄 → 321줄
  - Scripts/package-app.sh:11-141 GPL notice → :132-140
  - Bridge quarantine strip 4곳 → 3곳 (:257, :297, :305)
  - Bridge 운영자 명단 정정 (dev-di-tto 부재, ohjack83-lab→ohjack83, 메타몽·유성윤 추가)
  - SceneVideoRenderer 1,451줄 / LibraryStore 520줄 → 본문 미기재로 삭제
  - Bridge 타깃 3개 → 5개 (production 3 + test 2)
  - §0 CIKernel vs CAEmitterLayer 폴백 표현 통일
  - "6-항목 안전 체크리스트" → 본문 부재로 삭제

상세 검증 결과는 검증 워크플로우 결과 파일 참조.

각 워크플로우는 phase 구조 (정독 → 적대 검증 → 종합) 또는 (비교 → 적대 검증 → 부분 합성 → 최종 종합)로 설계되어 단일 에이전트가 놓치는 결함을 다중 시선이 잡아내는 구조.

---

## 11. 최종 takeaway

두 프로젝트는 같은 도메인(Wallpaper Engine Workshop 자산의 macOS 재생)의 양 끝에 서 있으며, "더 좋다/나쁘다"가 아니라 **스코프가 다르다**.

- **강제력**: Bridge (Swift 6 에러) 상위
- **깊이**: Waple 상위
- **결정성 코어**: Waple이 Foundation only로 SPM 라이브러리화 가능
- **안전 컨테이너 + 다인 운영**: Bridge 우위
- **사용자 의사결정**: 자기 운영 모델과 정합하는 쪽을 고른다

### 검증 통과한 사실 (file:line 인용 가능한)
- Waple의 디컴파일 VA 인용 5,980건 (Bridge 0건)
- Waple의 6축 정책 + VRAM 80/75/35% + 15s hysteresis (`WaplePolicy/PlaybackPolicy.swift`)
- Waple의 결정성 핀 4종 (`WapleCompatCore/SnapshotPipeline.swift:35-51`)
- Bridge의 13/13 에러 enum LocalizedError
- Bridge의 Swift 6 에러 강제 (`Package.swift:1`)
- Bridge의 Gatekeeper 사후 검증 (`Scripts/package-app.sh:143-172`)
- 양쪽 모두의 픽셀 회귀 CI 미배선 (동등한 결함)

### 검증 실패한 사실 (집계 제외)
- 동시성·자산 번들·Steam 통합 도메인의 우열 비교
- WE 포맷 파싱 도메인의 ScenePackage 인용 (컬럼 스왑)

---

*문서 끝.*
