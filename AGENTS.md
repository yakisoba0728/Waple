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
swift test                     # 2,149개(2026-08-16 macOS 실측 — 코퍼스 유무와 무관)
swift run Waple                # 메뉴바 앱으로 실행
```

테스트 수 **2,149** 는 고정 기준값이다. 리팩토링으로 이 숫자가 변하면 무언가 잘못됐다.
번들 합으로 세야 한다 — 클래스 단위 소계까지 더하면 6,000대로 부풀어 무의미해진다.
`실행` 은 스킵을 포함하므로 **이 값은 코퍼스 유무와 무관하다**(아래 표에서 다섯 구성이 모두 2,149).
종전 기준값 2,143 은 2026-08-01 실측이었고 2026-08-16 재측정으로 2,149 로 갱신됐다 —
그 사이 테스트가 6개 늘었을 뿐 회귀가 아니다.

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
| 코퍼스 있음(전량 460) | 2,149 | 2 | ~30분 | 실행수는 **추론**(정적 개수 = 축소 실측과 동일), 스킵 2 는 2026-08-01 실측 |
| 코퍼스 있음(축소 38, release) | 2,149 | 9 | **162초** | 2026-08-16 실측 — `verify-plan-b12.sh` §5 (`swift test -c release`, 순차) |
| 코퍼스 있음(축소 38, debug) | 2,149 | 9 | ~4.6분 | 2026-08-16 실측 (`--parallel --num-workers 6`, 아래 레시피) |
| 코퍼스 없음 | 2,149 | 40 | ~110초 | 2026-08-16 macOS 실측 (`WAPLE_REAL_PKGS=/nonexistent/path swift test`, 2회 동일) |
| CI (코퍼스 없음) | 2,149 | 47 | ~170초 | 2026-08-16 확인 — CI run `30934767197`(main @`4b2e1dd`, macos-26, 성공) 로그 |

모든 구성 **실패 0**. `실행` 은 XCTest 의 `Executed N tests` 이고 **스킵을 포함한다** —
그래서 스킵이 40/47/9 로 갈려도 다섯 구성이 전부 똑같이 2,149 를 낸다. 위 `~110초`는 증분 빌드까지
포함한 명령 전체 벽시계이고 번들 실행 시간 합은 ~97초, CI 의 `~170초`는 로그의
`in 170.403 seconds`(빌드 별도) 다.

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

⚠️ **`--parallel` 은 개수 세기 전용이다 — 통과/실패 판정에 쓰지 마라.** 2026-08-16 실측:
`SceneRenderSettingsTests`(UserDefaults 전역 상태)와 `SceneCompositeConventionTests` 가
**병렬 3/3 실패, 순차 3/3 통과**로 갈린다. 클래스를 단독 필터해도 병렬이면 실패하므로 클래스 간
오염이 아니라 워커 프로세스의 defaults 도메인 차이로 보인다(원인 미확정). 초록/빨강을 봐야 하면
`swift test -c release` 를 순차로 돌려라 — release 순차가 162초로 debug 병렬(275초)보다 빠르기도 하다.

**이 레시피로 확정되는 것과 안 되는 것을 구분할 것.**
- **확정**: `실행` 수. 테스트 메서드는 정적으로 결정되므로 코퍼스 크기가 개수를 못 바꾼다.
- **확정 안 됨**: 스킵 수와 **커버리지**. 축소 코퍼스에선 특정 패키지를 못 찾아 스킵이 9로 늘었다
  (그중 2건 `WAPLE_PROBE_ID`·`WAPLE_3DV3` 는 코퍼스와 무관한 옵트인이라 전량에서도 스킵 —
  나머지 7건이 전량에선 풀려 2026-08-01 실측치 `스킵 2` 로 수렴한다).
  **렌더러를 만졌으면 이 레시피로 갈음하지 마라.** 개수 확인용이지 검증용이 아니다.
- **CI 가 로컬보다 7개 더 스킵하는 이유**(스킵 집합 대조, 로컬 집합은 CI 의 부분집합):
  `ffmpeg not installed` 5건 + 기본 에셋 부재 1건(`TexDecoderTests.testDecodesRealEmbeddedImages`,
  `WAPLE_BASE_ASSETS`) + 웹 타이밍 전제 불성립 1건(`WebHardPauseTests`). 로컬 측정은
  `WAPLE_BASE_ASSETS` 를 기본값(`~/Downloads/wallpaper_dev/assets`, **이 머신엔 실재**)으로 두고 돌렸다.
- GPU 스킵은 없었다 — Metal 은 로컬(로그인 세션)·CI 양쪽에서 잡혔다.

번들별(2026-08-16, 코퍼스 있음/축소 38): WapleRenderTests 995(스킵 7) · WapleCoreTests 786(스킵 2) · WapleAppTests 292 · WapleLibraryTests 51 · WapleSnapshotTests 25.
번들별(2026-08-01, 코퍼스 있음/전량): WapleRenderTests 992(스킵 2) · WapleCoreTests 786 · WapleAppTests 289 · WapleLibraryTests 51 · WapleSnapshotTests 25.
번들별(2026-08-16, 코퍼스 없음): WapleRenderTests 995(스킵 26) · WapleCoreTests 786(스킵 14) · WapleAppTests 292 · WapleLibraryTests 51 · WapleSnapshotTests 25.
(CI 는 번들을 `WaplePackageTests.xctest` 하나로 합쳐 2,149 한 줄로 낸다.)

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

`branches: [main]` 제한은 `e46e69d`(2026-08-02)에서 없앴다 — PR 없이 오래 사는 기능 브랜치
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
