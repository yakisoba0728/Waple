# 이 리포에서 작업하는 방법

Wallpaper Engine 을 macOS 에 재구현한 프로젝트다. 사용자용 소개는 [README.md](README.md),
현재 할 일은 [BACKLOG.md](BACKLOG.md), 문서 색인은 [docs/README.md](docs/README.md).

이 문서는 **사람이든 AI 에이전트든 코드를 만지기 전에 읽어야 하는 것**만 담는다.

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

## 빌드와 테스트

```bash
swift build --build-tests      # ~20초 (유휴 상태 Apple Silicon)
swift test                     # 2,125개
swift run Waple                # 메뉴바 앱으로 실행
```

테스트 수 **2,125** 는 고정 기준값이다. 리팩토링으로 이 숫자가 변하면 무언가 잘못됐다.

## 코퍼스 — 이걸 모르면 검증했다고 착각한다

테스트는 두 갈래다. 합성 테스트는 어디서나 돌고, **실물 WE 코퍼스를 요구하는 테스트는
코퍼스가 없으면 스스로 스킵한다.** 스킵은 실패로 보고되지 않으므로, 코퍼스 없이
"전부 통과"를 보고 검증이 끝났다고 믿는 것이 이 리포에서 가장 쉬운 착각이다.

```bash
export WAPLE_REAL_PKGS=/path/to/backgrounds    # 미설정 시 ~/Downloads/wallpaper_dev/backgrounds
export WAPLE_BASE_ASSETS=/path/to/assets       # 미설정 시 ~/Downloads/wallpaper_dev/assets
```

| 구성 | 실행 | 스킵 | 시간 |
| --- | --- | --- | --- |
| 코퍼스 있음 | 2,125 | 2 | ~30분 |
| 코퍼스 없음 | 2,125 | 41 | ~95초 |
| CI (코퍼스 없음) | 2,125 | 46 | ~150초 |

코퍼스가 사주는 39개가 실패키지 mount+capture, 실영상·웹 로딩, 실제 `.mdl` 파싱,
TEX 디코드·밉체인, 실셰이더 GLSL→MSL 번역이다. **렌더러를 건드렸다면 이걸 돌려야 한다.**
30분 중 `RealTexMipChainProbeTests` 하나가 688초인데, 460개 패키지의 스칼라 BC1 디코드라
줄일 수 없는 비용이다.

주의할 점 셋:

- `--filter` 는 **클래스 이름**에 매칭된다. 파일 이름을 쓰면 같은 파일에 든 다른 클래스가
  조용히 빠진다 — `Model3DTests.swift` 안에 `Model3DRealFileTests` 가 따로 있어서
  `--filter Model3DTests` 로는 실파일 파싱 검증이 실행되지 않는다. `Model3D.*Tests` 를 써라.
- Metal 은 **로그인 세션**에서만 잡힌다. SSH 로 실행하면 GPU 테스트가 조용히 스킵된다.
- 코퍼스가 실제로 잡혔는지는 센티넬로 확인해라. `PuppetBlendRealSceneTests`(2개)와
  `TexVariantDecodeCorpusTests`(1개)가 스킵되면 코퍼스를 못 찾은 것이다.

## CI

`macos-26` 러너, 타임아웃 40분. `main` 푸시 · PR · `workflow_dispatch` 에서 돈다.
문서만 바뀐 변경은 `paths-ignore` 로 스킵되지만, 코드가 하나라도 섞이면 정상 실행된다.

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
