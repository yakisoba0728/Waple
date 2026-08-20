# 이 리포에서 작업하는 방법

Wallpaper Engine 을 macOS 에 재구현한 프로젝트다. 사용자용 소개는 [README.md](README.md),
현재 할 일은 [BACKLOG.md](BACKLOG.md), 문서 색인은 [docs/README.md](docs/README.md).

이 문서는 **사람이든 AI 에이전트든 코드를 만지기 전에 읽어야 하는 것**만 담는다.

> **작업 환경을 옮기는 중이라면** — 윈도우↔맥 이관 절차와 현재 항목별 상태는
> [docs/mac-handoff-2026-08-01.md](docs/mac-handoff-2026-08-01.md).

## 모듈 지도

```
WapleCore ←── WapleLibrary ──┐
    ↑                        ├──→ Waple (앱 실행 타깃)
    └──── WapleRender ───────┘
    └──── WapleRender ───────→ WapleCompat (CLI) ←── WapleSnapshot
```

| 타깃 | 성격 | 의존 |
| --- | --- | --- |
| `WapleCore` | 순수 파서·시뮬레이터. **AppKit/Metal 없음** — 그래서 테스트가 쉽다 | 없음 |
| `WapleRender` | Metal 렌더러, 셰이더, 텍스처 디코드, 오디오·비디오·웹 | Core |
| `WapleLibrary` | 라이브러리 스캔·임포트·영속화 | Core |
| `Waple` | 메뉴바 앱 + SwiftUI 메인 윈도우 | Core, Library, Render |
| `WapleCompat` | 호환성 스캔·스냅샷 캡처/비교 CLI | Core, Render, Snapshot |
| `WapleSnapshot` | 스냅샷 매니페스트·diff. Foundation 전용 | 없음 |
| `WapleSaver` | 스크린세이버 `.saver` (Objective-C) | **SwiftPM 밖** — `scripts/package-app.sh` 가 직접 컴파일하므로 `swift test` 커버리지에 없다 |

외부 패키지 의존은 0이다. 새로 추가하지 마라.
`Package.swift` 는 `swift-tools-version:5.9` 지만 이건 매니페스트 API 버전일 뿐이고,
실제 빌드는 Swift 6.3+ 이다.

## UI 문자열(현지화)

키가 곧 **한국어 원문**이다. SwiftUI 의 `Text("한국어")` 리터럴은 `LocalizedStringKey` 로
해석되므로 호출부를 고칠 필요가 없고, 영어는 `Resources/en.lproj/Localizable.strings` 하나로 나온다.

- **새 UI 문자열을 추가하면 en.lproj 에도 넣어라.** 빼먹으면 영어 시스템에서 그 자리만
  한국어로 남는데 아무 것도 실패하지 않는다 — 그래서 `LocalizationCoverageTests` 가
  소스와 strings 파일의 차집합을 **양방향으로** 잡는다(누락 + 고아 번역).
- AppKit 경로(`NSMenuItem(title:)`, `window.title`)는 자동 해석이 없다 — `NSLocalizedString` 으로 감쌀 것.
- 문자열에 값이 끼면(`"\(x)분"`) 포맷 지정자 추론이 모호해진다. `String(format: NSLocalizedString("%lld분", …), x)` 로 명시할 것.
- `.lproj` 는 **앱 번들 `Contents/Resources`** 에 들어간다(`package-app.sh`). SPM 리소스 번들에
  두면 `Bundle.main` 조회가 실패한다 — 그래서 `swift run Waple` 개발 실행은 항상 한국어다.

## 빌드와 테스트

```bash
swift build --build-tests      # ~20초 (유휴 상태 Apple Silicon)
swift test                     # 2,369개(2026-08-20 정적 실측 — 코퍼스 유무와 무관)
swift run Waple                # 메뉴바 앱으로 실행
```

테스트 수 **2,369** 는 고정 기준값이다. 리팩토링으로 이 숫자가 변하면 무언가 잘못됐다.

> **[2026-08-20] 2,300 → 2,369 — 이 증가는 정당하다.** 이번 라운드가 오라클을 59개 늘렸다:
> FBO `format`/`unique`/`clear` 10(`f1ba768`) · 이펙트-로컬 자산 루트 6(`e6cfbfb`) ·
> FBO 규약 정정 4(`77ec33a`) · 오디오 스펙트럼 파이프라인 14(`a84cc9f`) · 자산 조회 순서 3(`83d110c`) ·
> 파서 결함 1(`de95007`) · 오디오 소비단 스테이지 11(`46db843`) · `conditions` 평가기 10(`4785c0d`).
> `conditions` 좌변 타입 규약 2(`7517953`) · 절대 레벨 오라클 1(`7b09975`) ·
> `.mdl` MDLV0004/0014 4 · 파티클 기본값 주입기 3(순증 3, 개명 2건 포함).
> 이 값은 **정적 개수**다(`grep -rE 'func test' Tests/ --include=*.swift | wc -l`). 마지막 CI 실측
> 2,300 은 `b8efa2d` 시점이었고 **그때 정적 개수도 정확히 2,300** 이었다 — 두 세는 법이 어긋나지
> 않는다는 근거다. 그래도 다음 CI 실행에서 `Executed N tests` 로 재확인할 것.

> **[2026-08-19] 2,301 → 2,300 — 이 감소는 정당하다.** `SceneCompositeConventionTests` 의
> 캡처 fit/fill 테스트 둘이 프로세스 전역 `fitMode` 를 서로 덮어 병렬에서 경합했다.
> 하나로 합쳐 fit → fill 을 순차로 검사한다 — **단언은 그대로 남았고 커버리지는 줄지 않았다.**
> 이 트립와이어가 그 감소를 잡아 준 것이 정상 동작이다(합칠 때 실수로 단언을 흘렸다면
> 여기서 걸렸을 것이다).
번들 합으로 세야 한다 — 클래스 단위 소계까지 더하면 6,000대로 부풀어 무의미해진다.
`실행` 은 스킵을 포함하므로 **이 값은 코퍼스 유무와 무관하다**(아래 표에서 다섯 구성이 모두 같은 수).
종전 기준값 2,143 은 2026-08-01 실측이었고 2026-08-16 재측정으로 2,149, 같은 날 결함 수정에 붙은 신규 테스트로 2,180,
2026-08-17 하루에 다섯이 붙어 2,270 이 됐다 — mul 전치 회귀 3 · UI 규약 오라클 3 · g_Brightness 14 ·
공유 컴포넌트 7 · 셸 개편(스모크 순수화 11 + 네비 12) 23 · 가시성 전파 10 ·
Phase 2 UI 개편 22(라이브러리 18 + 설정·디스플레이 4) · shape 저작 size 1 · 씬 음량 노출 1 · translucent depthwrite 1 · 보조 모니터 스펙트럼 1 · generic4 color 키 1 · 리본 규약 1 · 파티클 3축 회전 2(3D·2D).
2026-08-19 에 스물이 더 붙어 2,292 가 됐다 — 합성 픽셀 골든 게이트 1 · 그 게이트의 음성 대조 1
(`SyntheticPixelGoldenTests`) · 블렌드 32종 커버리지 2(`BlendModeCoverageTests`) ·
공용 바이너리 리더 경계 11(`BinaryReadingTests` — 종전 테스트 참조 0건이던 파일이다) ·
신뢰 경계 밖 정수 좁힘 2(`SceneDocumentTests` colorBlendMode 범위 밖 · `SceneIntegrationFixTests`
파티클 프레임 유한 거대값 — F530-sweep 13곳 수정의 감시자) · 중복 키 트랩 3(`ShaderPreprocessorTests`
함수형 매크로 중복 파라미터 + 정상 매크로 대조군 · `EffectManifestTests` 중복 fbo 이름) ·
localStorage 상한 1 · 재임포트 평점 유지 1 · 골든 판정 분기 1(`SnapshotTests` — 종전엔 판정
수식을 베껴 자기 산수를 단언했다. `WapleSnapshot.goldenVerdict` 로 올려 프로덕션 심볼을 직접 부른다) ·
`WapleCompatCoreTests` 6(**새 타깃** — `WapleCompat` 이 실행파일이라 종전엔 어떤 테스트도
의존할 수 없었고 1,799줄이 무테스트였다. 라이브러리로 분리하며 순수 로직부터 걸었다) ·
`SceneRenderSettingsTests` 2(주입 저장소 격리 + fitMode 왕복 — 병렬 실패 원인 수정과 한 쌍).
회귀가 아니라 오라클이 늘어난 것이다. **주의**: 2026-08-17 에 병렬 단위 둘이 각자 2,180+3 을 계산해
**둘 다 2,183 이라 적었다** — 서로의 3 을 모르고 있었다. 병렬로 오라클을 늘릴 때는 기준값을
각자 갱신하지 말고 합류 후 한 번 재측정할 것.

[2026-08-19] 이 숫자는 이제 **CI 가 지킨다**. `.github/workflows/ci.yml` 의
`Skip / execution census` 가 실행 하한 2,300 과 스킵 상한 100 을 건다. 손으로 세어 적는
단계는 끝났고, 값을 바꾸려면 워크플로도 함께 고쳐야 한다. **단 이건 하한이라 아래로만 막는다** —
위 [2026-08-20] 주석처럼 개수가 늘면 CI 는 통과하므로, 늘린 사람이 이 하한을 같이 올려야
트립와이어가 새 기준값을 지킨다(지금 워크플로 값은 아직 `2300` 이다).
스킵 상한을 두는 이유는 따로 있다: `XCTSkip("no Metal")` 아래 테스트가 561개라
GPU 없는 환경에서 돌면 **전부 스킵된 채 초록**이 뜬다. 실행 수만 봐서는 못 잡는다
(실측 정상치는 스킵 46~47).

## 코퍼스 — 이걸 모르면 검증했다고 착각한다

테스트는 두 갈래다. 합성 테스트는 어디서나 돌고, **실물 WE 코퍼스를 요구하는 테스트는
코퍼스가 없으면 스스로 스킵한다.** 스킵은 실패로 보고되지 않으므로, 코퍼스 없이
"전부 통과"를 보고 검증이 끝났다고 믿는 것이 이 리포에서 가장 쉬운 착각이다.

```bash
export WAPLE_REAL_PKGS=/path/to/backgrounds    # 미설정 시 ~/Downloads/wallpaper_dev/backgrounds
export WAPLE_BASE_ASSETS=/path/to/assets       # 미설정 시 ~/Downloads/wallpaper_dev/assets
```

| 구성 | 실행 | 스킵 | 시간 | 출처 |
| --- | --- | --- | --- | --- |
| 코퍼스 있음(전량 460) | 2,300 | 2 | ~30분 | 실행수는 **추론**(정적 개수 = 축소 실측과 동일), 스킵 2 는 2026-08-01 실측 |
| 코퍼스 있음(축소 38, release) | 2,300 | 9 | **162초** | 시간·스킵은 2026-08-16 실측(`verify-plan-b12.sh` §5, `swift test -c release`, 순차). 실행수는 그 2,180 에 2026-08-17 신규 20 을 더한 **정적 추론** |
| 코퍼스 있음(축소 38, debug) | 2,300 | 9 | ~4.6분 | 시간·스킵은 2026-08-16 실측(`--parallel --num-workers 6`, 아래 레시피). 실행수는 위와 같은 **정적 추론** |
| 코퍼스 없음 | 2,300 | 40 | ~110초 | 2026-08-17 macOS 실측 (`WAPLE_REAL_PKGS=/nonexistent/path swift test`, 순차 — 번들별 25+1044+51+802+348) |
| CI (코퍼스 없음) | 2,300 | 46 | ~195초 | **전부 실측**(2026-08-19 CI run `32258859021`, macos-26). 종전 행은 실행수가 정적 추론이었고 "다음 CI 로 재확인할 것" 이라 적혀 있었다 — 그 재확인이 run `32222689131`(2,285/47)이었고, 이 행은 F530-sweep 이후 재측정이다. debug·release 두 레인이 실행·스킵·실패까지 동일했다 |

모든 구성 **실패 0**. `실행` 은 XCTest 의 `Executed N tests` 이고 **스킵을 포함한다** —
그래서 스킵이 40/46/9 로 갈려도 다섯 구성이 전부 똑같이 2,300 을 낸다. 위 `~110초`는 증분 빌드까지
포함한 명령 전체 벽시계이고 번들 실행 시간 합은 ~97초, CI 의 `~162초`는 로그의
`in 154.420 seconds`(빌드 별도, 2026-08-19 run `32238272072`) 다.

### 코퍼스 스위트를 30분 → 5분 안에 돌리는 레시피 (2026-08-16 확립)

전량 460개는 ~30분이고 그중 `RealTexMipChainProbeTests` 하나가 688초다. 그런데 **코퍼스를
요구하는 20개 파일 중 최소 개수를 단언하는 테스트가 하나도 없고**, 콕 집어 요구하는 패키지는
27개뿐이다(`grep -rhoE '"[0-9]{9,10}"' $(grep -rl WAPLE_REAL_PKGS Tests/)`). 스윕 테스트는
디렉터리를 훑을 뿐이라 코퍼스를 줄이면 선형으로 빨라진다.

```bash
# 1) 콕 집어 요구하는 27개 + 타입별 대표(video 6·web 3·other 2) = 38개로 축소 코퍼스를 만든다.
#    ⚠️ 심링크는 안 된다 — WallpaperCompatibilityAnalyzer 의 .isDirectoryKey 필터가 걸러내
#    totalProjects=0 이 되고 testRealWallpaperDevCorpusCanBeSummarizedWhenAvailable 가 실패한다.
#    APFS 클론(cp -Rc)이면 즉시 + 디스크 추가소비 0 이다.
cp -Rc ~/Downloads/wallpaper_dev/backgrounds/<id> /tmp/corpus-mini/<id>   # × 38

# 2) 병렬 실행. debug 순차 8.5분 → 4.6분 (WapleRenderTests 486초가 병목이라 여기서 벌린다)
env WAPLE_REAL_PKGS=/tmp/corpus-mini swift test --skip-build --parallel --num-workers 6
```

**release 가 debug 보다 빠르다** — 축소 코퍼스는 BC1 디코드·캡처가 지배적이라 최적화가 그대로
먹는다. 순차 release 가 162초로 debug 병렬(275초)보다 낫다. 빌드가 이미 release 로 warm 하면
`--parallel` 없이 `swift test -c release` 만 써도 된다. `verify-plan-b12.sh` 를 통째로 돌릴
때는 이 방식이 자동으로 적용된다(§5 가 release 다).

```bash
# 검증 스크립트 전체를 축소 코퍼스로 돌리는 법 — WAPLE_DEV_ROOT 하나만 갈아끼우면 된다.
# (스크립트가 $ROOT/backgrounds·$ROOT/assets 를 export 하므로 그 레이아웃만 맞추면 된다)
WAPLE_DEV_ROOT=/tmp/dev-root WAPLE_VERIFY_OUT=/tmp/verify-out bash scripts/mac-session/verify-plan-b12.sh
```

✅ **`--parallel` 은 이제 판정에 써도 된다** — 종전 경고("개수 세기 전용")는 2026-08-19 에
원인이 규명돼 해소됐다. CI 의 `Parallel isolation gate` 가 매 푸시마다 두 클래스를
`--num-frontend-workers 6` 상당(`--num-workers 6`)으로 **3회씩** 돌려 회귀를 막는다.

<details><summary>무엇이 문제였고 어떻게 밝혀졌나 (2026-08-16 → 08-19)</summary>

종전 서술: "`SceneRenderSettingsTests`(UserDefaults 전역 상태)와 `SceneCompositeConventionTests`
가 **병렬 3/3 실패, 순차 3/3 통과**로 갈린다 … 워커 프로세스의 defaults 도메인 차이로 보인다
(원인 미확정)."

**원인은 둘이었고 서로 달랐다. 도메인 차이는 둘 다 아니었다.**

| 클래스 | 진짜 원인 | 수정 |
| --- | --- | --- |
| `SceneRenderSettingsTests` | `UserDefaults.standard` 는 프로세스가 아니라 **사용자** 단위라 워커 여럿이 같은 키를 공유한다 | `SceneRenderSettings.defaults` 주입점 + 테스트마다 고유 suite |
| `SceneCompositeConventionTests` | 두 캡처 테스트가 프로세스 전역 `SceneRenderSettings.fitMode` 를 서로 덮었다 | 한 테스트로 합쳐 fit → fill 순차 검사 |

**밝혀진 방식이 결론보다 중요하다.** 세 번의 CI 왕복이 필요했고 매번 다른 것을 배웠다:

1. 1차 — 게이트가 `--skip-build` 때문에 테스트를 하나도 안 돌리고 exit 1. **검사가 아무것도
   검사하지 않았다.**
2. 2차 — 로그로 판정하다 오판. `--parallel` 은 전부 통과하면 XCTest 의 `Executed N tests` 줄을
   찍지 않는데 그 부재를 "필터 0건 매치" 로 읽어, **이미 고쳐진 클래스를 실패로 보고**했다.
   판정을 `--xunit-output` XML 로 바꿨다(기계가 쓰는 형식이라 추측이 끼어들지 않는다).
3. 3차 — 6/6 통과. 그리고 `fitMode` 경합의 서명이 드러났다: **회차마다 지는 쪽이 바뀌었다**
   (1회 fit, 2회 fill, 3회 fit).

교훈 둘. **"고쳤다" 와 "통과한다" 는 다른 명제다** — 실행하지 않았으면 한쪽은 고쳤는데 못
고쳤다고, 다른 쪽은 안 고쳤는데 고쳤다고 적었을 것이다. 그리고 **부재를 신호로 쓰지 마라** —
"로그에 X 가 없다" 는 "X 가 일어나지 않았다" 가 아니다. 이 리포가 반복해서 당한
"검사하는 척하는 검사" 가 바로 그 형태다.

</details>

초록/빨강을 순차로 보고 싶으면 `swift test -c release` 를 쓴다 — release 순차가 162초로
debug 병렬(275초)보다 빠르다.

**이 레시피로 확정되는 것과 안 되는 것을 구분할 것.**
- **확정**: `실행` 수. 테스트 메서드는 정적으로 결정되므로 코퍼스 크기가 개수를 못 바꾼다.
- **확정 안 됨**: 스킵 수와 **커버리지**. 축소 코퍼스에선 특정 패키지를 못 찾아 스킵이 9로 늘었다
  (그중 2건 `WAPLE_PROBE_ID`·`WAPLE_3DV3` 는 코퍼스와 무관한 옵트인이라 전량에서도 스킵 —
  나머지 7건이 전량에선 풀려 2026-08-01 실측치 `스킵 2` 로 수렴한다).
  **렌더러를 만졌으면 이 레시피로 갈음하지 마라.** 개수 확인용이지 검증용이 아니다.
- **CI 가 로컬보다 6~7개 더 스킵하는 이유**(스킵 집합 대조, 로컬 집합은 CI 의 부분집합).
  아래 내역은 CI 스킵 47(2026-08-16) 기준이다. 2026-08-19 재측정에서 debug 46 / release 47 로
  갈렸는데 어느 항목이 debug 에서 풀렸는지는 **확인하지 않았다** — 내역을 쓸 일이 생기면
  집합을 다시 대조할 것:
  `ffmpeg not installed` 5건 + 기본 에셋 부재 1건(`TexDecoderTests.testDecodesRealEmbeddedImages`,
  `WAPLE_BASE_ASSETS`) + 웹 타이밍 전제 불성립 1건(`WebHardPauseTests`). 로컬 측정은
  `WAPLE_BASE_ASSETS` 를 기본값(`~/Downloads/wallpaper_dev/assets`, **이 머신엔 실재**)으로 두고 돌렸다.
- GPU 스킵은 없었다 — Metal 은 로컬(로그인 세션)·CI 양쪽에서 잡혔다.

번들별(2026-08-17, 코퍼스 없음): WapleRenderTests 1044(스킵 26) · WapleCoreTests 802(스킵 14) · WapleAppTests 348 · WapleLibraryTests 51 · WapleSnapshotTests 25.
번들별(2026-08-16, 코퍼스 있음/축소 38): WapleRenderTests 995(스킵 7) · WapleCoreTests 786(스킵 2) · WapleAppTests 292 · WapleLibraryTests 51 · WapleSnapshotTests 25.
번들별(2026-08-01, 코퍼스 있음/전량): WapleRenderTests 992(스킵 2) · WapleCoreTests 786 · WapleAppTests 289 · WapleLibraryTests 51 · WapleSnapshotTests 25.
번들별(2026-08-16, 코퍼스 없음): WapleRenderTests 995(스킵 26) · WapleCoreTests 786(스킵 14) · WapleAppTests 292 · WapleLibraryTests 51 · WapleSnapshotTests 25.
(CI 는 번들을 `WaplePackageTests.xctest` 하나로 합쳐 2,300 한 줄로 낸다.)

코퍼스가 사주는 38개(2026-08-16 실측 — 무코퍼스 스킵 40 중 옵트인 2건을 뺀 38 이 코퍼스로 풀린다.
축소 38개로도 31건이 풀렸고 나머지 7건은 그 서브셋에 없는 패키지를 요구한 것이다. 종전 표기 39개는
무코퍼스 스킵이 41 이던 시절 값이라 갱신)가 실패키지 mount+capture, 실영상·웹 로딩, 실제 `.mdl` 파싱,
TEX 디코드·밉체인, 실셰이더 GLSL→MSL 번역이다. **렌더러를 건드렸다면 이걸 돌려야 한다** —
그때는 위 축소 레시피가 아니라 전량이다.
30분 중 `RealTexMipChainProbeTests` 하나가 688초인데, 460개 패키지의 스칼라 BC1 디코드라
패키지당 ~1.5초로 선형이다. 즉 **전량에서는 줄일 수 없는 비용**이고, 코퍼스를 줄이면 그만큼
선형으로 준다(축소 38개에서 이 클래스 포함 WapleRenderTests 전체가 486초).

주의할 점 셋:

- `--filter` 는 **클래스 이름**에 매칭된다. 파일 이름을 쓰면 같은 파일에 든 다른 클래스가
  조용히 빠진다 — `Model3DTests.swift` 안에 `Model3DRealFileTests` 가 따로 있어서
  `--filter Model3DTests` 로는 실파일 파싱 검증이 실행되지 않는다. `Model3D.*Tests` 를 써라.
- Metal 은 **로그인 세션**에서만 잡힌다. SSH 로 실행하면 GPU 테스트가 조용히 스킵된다.
- 코퍼스가 실제로 잡혔는지는 센티넬로 확인해라. `PuppetBlendRealSceneTests`(2개)와
  `TexVariantDecodeCorpusTests`(1개)가 스킵되면 코퍼스를 못 찾은 것이다.

## CI

`macos-26` 러너, 타임아웃 40분. **모든 브랜치의 푸시** · PR · `workflow_dispatch` 에서 돈다.
문서만 바뀐 변경은 `paths-ignore` 로 스킵되지만, 코드가 하나라도 섞이면 정상 실행된다.

`branches: [main]` 제한은 `509781d`(2026-08-02)에서 없앴다 — PR 없이 오래 사는 기능 브랜치
(`feat/we-engine-port-design`)에 8커밋을 푸시하는 동안 CI 가 **조용히 한 번도 안 돌았고**,
실패한 게 아니라 트리거 자체가 없어서 알려주는 신호도 없었다. 대신 concurrency 를
`head_ref || ref` 로 묶어 PR 브랜치가 push·pull_request 두 이벤트로 두 번 타지 않게 한다.

**로컬 통과 ≠ CI 통과.** CI 는 로컬과 다른 Xcode 를 쓰고, 이 리포에는 로컬에서는 통과하고
CI 에서만 터진 실패 이력이 있다(`db90fc2` 타입체커 폭발, `14dcf72` Float 리터럴 추론,
`bdba331` 러너 Xcode 고정). 큰 변경은 PR 을 올려 CI 를 한 번 통과시켜라.

## 함정

**타입체커 폭발.** 긴 식을 합치면 `unable to type-check this expression in reasonable time`
이 난다. 이건 이 리포에서 실제로 4번 일어났다. 식은 **쪼개는 방향으로만** 바꿔라.
추출한 함수의 파라미터·반환 타입은 명시적으로 적어라. SwiftUI 뷰 빌더는 특히 취약하다.

**주석은 설명이 아니라 설계 근거다.** 이 코드베이스의 주석에는 실측 수치, 버린 대안의 이유,
이전 결론을 뒤집은 기록이 들어 있다. 예를 들어 `HDRPostPass.swift` 는 ACES 톤커브를
왜 제거했는지를 적어두었고(WE 2.8 의 최종 처리가 `saturate` 뿐이라는 확증), `ScenePackage.swift`
는 코퍼스 실측 분포로 앞선 결론을 철회한 이력을 남겨두었다. **지우지 마라.** 함수를 쪼갤 때는
근거 주석을 해당 코드와 함께 옮겨라. 삭제해도 되는 건 코드와 모순이 된 문장뿐이다.

**보존 필드는 데드코드가 아니다.** `파스·보존 전용`, `소비 보류`, `YAGNI` 로 표시된 필드는
"파싱은 하지만 아직 쓰지 않는다"는 의도적 결정이고 근거가 주석에 있다. 미사용처럼 보여도
지우지 마라.

**조용히 틀리는 것보다 실패하는 쪽을 택한 곳이 있다.** `ShaderPreprocessor` 는 지원하지 않는
`#if` 식(모듈로·비트·삼항·시프트·16진)을 통과시키지 않고 거부한다. 오역된 셰이더가 조용히
그려지는 것보다 낫다는 판단이다. 이 거부 경로를 관용적으로 바꾸면 버그가 눈에 안 보이게 된다.

**순서와 키가 계약인 곳.** `PuppetPose` 의 행렬 곱 순서(`Rz·Ry·Rx·S`, `T·R·S`)는 비가환이라
"수학적으로 같아 보이는" 재배열도 안 된다. `GLSLTranslator` 의 프로세스 전역 메모이즈 캐시는
키 구성이 어긋나면 잘못된 캐시 히트로 다른 셰이더를 내놓는다. `SplitMix64` 호출 순서는
결정론적 재현의 근거다. MDLV 버전별 정점 stride(static 48B / skinned 80B / puppet 52B)는
버전마다 실제로 바이트 레이아웃이 다르다.

**장황함이 곧 개선 대상은 아니다.** 32개 블렌드 모드, 파티클 오퍼레이터 열거, MDLV 버전 분기는
WE 호환을 위한 의도적 전수 처리다. 인식하지 못한 토큰을 로그만 남기고 버리는 것도 설계다.
줄여서 정합성을 잃지 마라.

## 정본(spec/)

WE 동작에 대한 사실은 코드 주석이 아니라 [spec/](spec/) 에 둔다. 이전에 역공학
산출물(`analysis/`)이 통째로 사라져 근거가 주석에만 남은 적이 있다 — 지금 코드가
인용하는 `analysis/decompiled/all/...` 은 리포에 없다.

- 모든 항목에 **근거가 필수**다. 없으면 `scripts/spec/validate.py` 가 거부한다.
- 상태는 `확정`(직접 측정 + 재현 스크립트) / `보고`(정찰, 미재현) / `추정` 셋뿐이고,
  **`확정` 만 테스트를 생성한다.**
- WE 설치본이 있으면 `python scripts/spec/measure_*.py` 로 전부 재생성된다.
  **재생성 후 `git status` 가 비어야 정상이다** — 안 비면 측정에 비결정성이 있거나
  WE 가 업데이트된 것이다.
- 도구는 Python **stdlib 전용**이다. 외부 의존 0 원칙을 도구에도 적용한다
  (`pefile` 대신 `struct` 로 PE 를 직접 읽는다).

```bash
python scripts/spec/validate.py                  # 정본 검증
python scripts/spec/tests/test_validate.py       # 검증기 자체 테스트
python scripts/spec/tests/test_rosetta.py        # 로제타석 검증기 테스트
python scripts/spec/verify_rosetta.py            # .obj ↔ .mdl 실물 대조
```

**공유 에셋이 동봉돼 있다.** `Sources/WapleRender/Resources/WEAssets/`(2,940파일 75.8MB).
워크샵 pkg 가 `common_*.h` 를 하나도 담지 않아서(162개 전수 0건) 없으면 씬이 불완전하게
그려진다. WE 가 업데이트되면 `spec/assets/manifest.json` 의 해시가 어긋나 드리프트가 드러난다.

**커밋된 스냅샷 기준선이 있다.** `spec/golden/snapshot/`. 읽기 전에 그 README 를 볼 것 —
비디오-백드 24종은 머신 간 재현이 안 되고(strict 불일치는 회귀가 아니다), 비결정 씬이 1종 있다.

## 관례

**커밋 메시지**는 한국어 서술형이다. `feat:` 같은 접두사를 쓰지 않는다. 근거를 괄호에 담는
방식이 자주 쓰인다 — 예: `README 과대주장 3곳 정정(근거 대조)`.

**성격이 다른 변경은 커밋을 나눈다.** 리팩토링과 버그 수정을 같은 커밋에 섞지 마라.
그래야 회귀가 났을 때 이분 탐색이 된다. 병합도 squash 대신 rebase 를 써서 이 분리를 유지한다.

**리팩토링은 순수 추출만.** 조건식·연산 순서·기본값을 바꾸지 마라. 특히
**early return 이 든 블록을 함수로 빼면 바깥 흐름이 조용히 바뀐다** — 값을 반환하는 순수
계산만 빼라.

**테스트를 고쳐야 하는 리팩토링은 틀린 리팩토링이다.** 되돌리고 다시 생각해라.
