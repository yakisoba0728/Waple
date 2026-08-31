# 전체 감사 — Waple + Waple-wallpaper-source (2026-08-31)

> **모드**: ultracode · **지시**: 두 리포 전체(내부 엔진 포함) 확인 · **수정 금지 — 발견만 기록**
> 이 문서는 감사가 진행되는 동안 **계속 갱신된다**. 아래 §0 이 현재 진행 상태다.

> **[후속 2026-08-31]** 본문의 발견·심각도·재현은 **수정 전 작업 트리 스냅샷**으로
> 보존한다. 같은 PR의 후속 수정으로 C1의 번들 합산기와 H2의 인용 census 게이트·정본
> 재생성을 반영했다. 따라서 아래의 “현재 결함” 표현은 발견 시점을 뜻하며,
> 병합 판정은 현행 코드·게이트와 PR CI를 정본으로 삼는다. PR #8의 PR/push 실행
> `33377467569`·`33377406808`에서 debug·release 네 잡이 모두 4,016건 · 실패 0으로 끝났다.

## 0. 진행 상태

| 단계 | 상태 |
| --- | --- |
| 기반 실측(빌드·테스트·툴체인·게이트 19종) | **완료** — §1 |
| 오라클 품질 전수 조사 + 돌연변이 검증 | **완료** — §2.1 |
| Waple 커밋되지 않은 변경 45파일 정독 | **완료** — 45/45 전건 확인(내 손 + 16레인 병렬) |
| RE 리포 커밋되지 않은 변경 13파일 | **완료** — §5 (결함 0, 수정 3건 실행 검증) |
| 원본 바이너리 대조 재검증 | **완료** — §4 (전건 일치) |
| 엔진 서브시스템 교차 대조(11레인) | 진행 중(적대적 검증 108판정 반영 중) |
| 정본 암호학적 검증 | **완료** — 3,090 해시 · 1,778 VA · 불일치 0 |
| 파티클·MDL·셰이더 census 재현 | **완료** — 전건 일치 |
| 보안 경로(경로 격리·살균기·Range 헤더) | **완료** — 적대적 입력 14종 전건 차단 |
| 셰이더 인용 전수 스윕(634건) | **완료** — 범위 이탈 3건(M5) |
| 재측정 스크립트 40개 무코퍼스 거동 | **완료** — 18건 트레이스백(M4), 정본 파괴는 없음 |
| 정본 검증 커버리지·골든 기준선 무결성 | **완료** — 구멍 없음 |
| 제품화 표 3항목 재확인 | **완료** — 2항목이 낡았다(M6) |

**확정 발견 요약**: 🟠 9 · 🟡 25 (M14 는 검증 중 **철회**했다 — 아래 참조). (초기에 C1 을 🔴 로 봤으나, CI 실측 이력을 대조해
**툴체인 의존 + 근거 없는 하한**으로 재판정했다 — 아래 C1 참조.) 전건 실행으로 재현했다.
가장 급한 것은 **C1** — 테스트 개수 게이트가 로컬과 CI 에서 **다른 값을 읽고**,
그 하한(3875)은 어느 초록 실행에서도 측정된 적이 없다.

**커밋되지 않은 변경에 대한 판정**: 45파일 중 실동작을 바꾸는 코드 변경은 6건이고
**6건 전부 옳다**(각각 실행·바이트·정본으로 검증 — §5 및 아래 ✅ 항목). 문제는
변경 자체가 아니라 **그 변경이 남긴 부수효과 3건**이다:
C1(하한 3875 를 잘못된 추출로 올림) · H2(인용 4건 추가 후 census 미갱신) ·
M2(정본은 고쳤는데 인용 주석 5자리 미추적).

**돌연변이 검증 결과**: 새 오라클을 심은 5개 자리 전부 되돌리면 빨개진다
(UI 규약 1 · 모니터 인덱스 3 · 버전 게이트 2 · 스키닝 3 · 탭 지시문 A/B 6케이스).
즉 이 라운드가 얹은 오라클은 실제로 이빨이 있다.

### 발견 색인 (심각도순)

| id | 심각도 | 요지 | 재현 |
| --- | --- | --- | --- |
| C1 | 🟠 | 테스트 개수 게이트가 **툴체인 의존**이다 — 로컬은 마지막 번들만 세어 462(하한 3875 → 거짓 실패), CI 이력은 합계. 게다가 하한 3875 는 초록 실행에서 잰 값이 아니다 | 게이트 원문 재생 + CI 이력 대조 |
| H2 | 🟠 | 정본 인용 census 62 vs 실측 66. 잡는 게이트는 추적·배선 둘 다 안 됨 | 게이트 19종 실행 |
| H3 | 🟠 | `alphafade.fadeouttime` 을 지속시간으로 오해(WE 는 시작점) — 250 중 **110건** 오렌더 | 디스어셈블 + 수치 |
| H4 | 🟠 | oscillate 3종이 진폭의 파티클별 난수 누락 — **61건 전건** | 디스어셈블 |
| H5 | 🟠 | Swift 6 전환 잔여 진단 32자리(25가 `SceneRenderer.swift`), 26건은 Swift 6 에서 에러 | 깨끗한 빌드 |
| H6 | 🟠 | `PuppetModel` 이 게이트 없는 MDLA 이벤트 블록을 건너뛰지 않아 이후 클립이 오파싱(형제 `Model3D` 는 처리) | 디스어셈블 |
| H7 | 🟠 | `particle-fields.json` 미재생성 — 생성기는 `:2406`, 정본은 `:2183`(빈 `///` 줄) | 생성기 직접 호출 |
| H8 | 🟠 | `parseLight` 기본값 6/6 이 자기 RE 문서와 불일치 — `exponent` 1 vs 2.0 이 라이트 5/6 에서 최대 10× 밝게 | 문서·코퍼스·MSL 대조 |
| H1 | 🟠 | 단언 0개인 임시 파일이 테스트 타깃에서 실행되고 하한에 집계됨 | 전수 스캔 |

| M2 | 🟡 | 폐기된 이중계수 `358` 이 소스 4파일·RE 문서 12곳에 생존 | 코퍼스 계수 |
| M3 | 🟡 | JSON 숫자 `0`/`1` 이 `bool` 로 오타입(combo Picker 무선택) | 파서 실행 |
| M4 | 🟡 | 재측정 스크립트 40 중 **18** 이 코퍼스 부재에서 트레이스백(정본 파괴는 없음) | 40개 전수 실행 |
| M5 | 🟡 | README 셰이더 인용이 선언 줄을 코드 줄로 가리킴(전수 634 중 3건 범위 이탈) | 전수 스윕 |
| M6 | 🟡 | BACKLOG 제품화 표 3항목 중 **2항목이 이미 해소됨**(현지화·접근성) | 테스트 실행 |
| M7 | 🟡 | 디컴파일 실패 3건 중 2건이 파티클 핵심(인용 2,278건). 산문 미기록 | 7,748 전수 |
| M8 | 🟡 | 화면보호기가 `startAnimation` 마다 플레이어 재생성(커버리지 0 타깃) | 코드 읽기 — 증상 미실측 |
| M9 | 🟡 | 묘비 주석이 `perspectiveOverrideFov` 을 "실렌더 소비처 있음" 으로 분류 — 실제 호출부는 테스트뿐 | 참조 전수 |
| M10 | 🟡 | 새 주석이 **자기 diff 가 밀어낸** 같은 파일 줄 번호를 인용(6/6 무효) | HEAD A/B |
| M11 | 🟡 | 정본 근거 **661/1,211(55%)이 검증 생략**, 그중 349건은 짝 저장소에 실재 | `repo_ref_path` 직접 호출 |
| M12 | 🟡 | `CAST3X3` 도달 열거표가 두 모집단을 섞고 `g_Bones` 를 40(실제 48)으로 적는다 | 양쪽 코퍼스 계수 |
| M13 | 🟡 | `HDRBloomPass.swift:5` 의 "코퍼스 8" 이 어느 모집단에서도 안 나온다(정본·테스트·실측 전부 3) | 3개 모집단 계수 |
| M15 | 🟡 | `AGENTS.md:538` 이 "단언 15건" 을 거짓 불변성으로 방어(원래 14 → 15 로 변했다) | git 이력 계수 |
| M16 | 🟡 | `measure_workshop_shaders.py` 가 `:12`("툴체인 없다")와 `:1280`(그건 거짓) 로 자기모순. 포트는 Swift 와 대조된 적 없다 | 두 줄 + 툴체인 실측 |
| M17 | 🟡 | 새 Schlick 오라클 정규식이 우측 미앵커 — 원문에 항이 붙어도 통과 | 정규식 실행 |
| M18 | 🟡 | BACKLOG 가 항목을 "좌표가 애초에 죽어 있었다" 로 닫았지만 그 인용은 당시 정확했다 | git 이력 |
| M19 | 🟡 | RE 문서가 v≥23 레코드를 "bone-binding·UNRESOLVED" 로 두는데 Waple 은 모프/마스크로 확정 | 양쪽 문서 대조 |
| M20 | 🟡 | `AudioSpectrum.swift` 구조체 오프셋 인용 6곳이 −8 밀림(정본이 옳다) | 생성자 4줄 디스어셈블 |
| M21 | 🟡 | `measure_material_schema.py` 가 "줄 번호 금지" 를 선언하며 evidence ref 5건을 줄 번호로 남김(2건 드리프트, 게이트는 범위만 봄) | ref 5건 추적 |
| M22 | 🟡 | 비둘기집 하한이 version 부재 3씬을 안 뺐다(33/16/4/14 → 30/13/1/11). 정본에도 복제 | 산식 재계산 |
| M23 | 🟡 | Python 포트의 `MAX_DEPTH=256` 도달 불가 — 깊이 ~120 에서 `RecursionError`(Swift 는 0 반환) | 양쪽 실행 |
| M24 | 🟡 | typecheck 주석의 "프론트엔드 진단 전부 매치 ≥1" 이 3/4 다(잘못된 트리플은 매치 0) | 4종 주입 실행 |
| M25 | 🟡 | `uniforms.json` 17/144 행이 이름 대신 배열 선언 조각을 `va` 로 가리킨다(맨 이름 VA 는 따로 실재) | 144행 전수 대조 |
| M26 | 🟡 | `pdataCoverage 52.4%` 의 분자가 분모의 부분집합이 아니다(실제 46.1%, 924개가 `.pdata` 시작 아님) | 내 앞선 실측으로 검산 |
| ~~M14~~ | — | **철회** — `161/161` 은 워크샵 코퍼스 실측이고 정본이 기록한다. 내가 설치본과 대조한 오판이었다 | 정본 재확인 |
| (M21 후속) | — | 전 정본 33 ref 스윕에서 5건을 의심했다가 **전건 거짓 양성**으로 판정(범위 인용이었다). 실제 드리프트는 M21 의 2건뿐 | 범위 인용 재확인 |
| M1 | 🟡 | 추적되지 않은 문서·게이트가 리포 루트·`scripts/spec` 에 방치 | `git status` |

**수정 우선순위 제안**(지시대로 수정은 하지 않았다): C1 → H2 는 **커밋 전에** 처리해야 한다
(전자는 CI 를 붉히고, 후자는 이 라운드의 변경이 만든 부수효과다). H3·H4 는 실제 픽셀이
틀리므로 트리거 규약상 "해당 씬을 쓸 때" 가 아니라 **지금 고칠 값어치가 있다**(도달 110·61건).
H1·M1 은 1분이면 끝난다. H5 는 별도 트랙이다.

## 1. 기반 실측 (2026-08-31)

| 항목 | 결과 |
| --- | --- |
| `swift --version` | Apple Swift **6.4** (swiftlang-6.4.0.30.4), arm64-apple-macosx27.0.0 |
| Xcode | **27.0** Beta 5 (27A5237l) — `swift test` 실행 가능 |
| python3 | 3.14.7 (homebrew) |
| `swift build --build-tests` | **통과** — 증분 3.64초 · 깨끗한 빌드도 `EXIT=0`(error 0) |
| 깨끗한 빌드의 warning | **100건**(동시성 계열 70) — 고유 자리 47(Sources 32 · Tests 15) → **H5**. 증분 빌드에서는 0 으로 보인다(캐시) |
| 정적 테스트 개수(AGENTS.md 정본 레시피) | **3,886** |
| `ci.yml` census 하한 | **3,875** (`ci.yml:754`) — 정적 개수가 11 만큼 위. 통과 여유 있음 |
| `swift test` 전수 | **통과 — 실패 0 · 스킵 63 · 실행 3,886** (7번들 합산, 2분 40초). 감사 종료 후 재실행도 **동일**(3,886/0/63) |
| 스킵 63건의 성격 | **전부 환경 부재** — 실물 코퍼스(`no real pkgs dir`) · ffmpeg 미설치 · GPU/캡처. **오디오 게이트는 열려 있다**(`skipUnlessAudioOutputCanPlay` 로 인한 스킵 0건) — 즉 숨은 실패가 아니다 |
| `python3 scripts/spec/validate.py` | **오류 0 · 문서간 경고 0 · 헤지 27** (상태 분포: 확정 488 / 보고 24 / 추정 12) |
| `Sources/**` 의 `try!`/`as!` | **0건** |
| `@unchecked Sendable`·`nonisolated(unsafe)` | 전건 근거 주석 동반 — 방치 아님 |
| Swift 6 준비도 | 언어 모드는 여전히 5 (`tools-version:5.9`). 전환을 막는 진단 32자리 → **H5** |
| TODO/FIXME | 3건, 전부 의도적 YAGNI 기록 |

### 1.1 작업 트리가 더럽다 — 이 감사의 핵심 위험

`main` 이 `70a8a708` 인데 **커밋되지 않은 변경이 45파일 · +3,267/-540** 이다.
추적되지 않은 파일 4개도 있다.

**이 변경은 CI 를 한 번도 통과한 적이 없다.** 이 리포의 정본 규약(`AGENTS.md`)은
"정적 개수로 하한 통과를 미리 계산한다"인데, 그 계산의 대상이 되는 코드가 아직
어떤 그린도 받지 못한 상태다. 따라서 아래 감사는 **HEAD 가 아니라 작업 트리**를 대상으로 한다.

추적되지 않은 파일:

| 파일 | 성격 | 문제 |
| --- | --- | --- |
| `Tests/WapleRenderTests/ZZTempSqrtVerify.swift` | 테스트 | 이름이 `ZZTemp` — 임시 검증 파일이 테스트 타깃에 남아 있다. 정적 개수·CI 하한에 **집계된다** |
| `WAPLE-ANALYSIS-SUMMARY-2026-08-27.md` | 문서 | 자기 §1.1 이 "이 파일은 추적되지 않았고 리뷰를 거친 적이 없다"고 스스로 적는다 |
| `docs/playback-architecture.html` | 문서 | 47KB. 색인 미등재 + 어디서도 참조되지 않음(실측 grep 0건) → M1 |
| `scripts/spec/check_cited_address_census.py` | 게이트 | 정본 검사기가 추적되지 않음 → CI 에서 돌지 않는다 |

## 2. 규모

| 대상 | 파일 | 줄 |
| --- | --- | --- |
| `Sources/WapleCore` | 51 | 30,742 |
| `Sources/WapleRender` | 55 | 25,914 |
| `Sources/Waple` | 52 | 10,308 |
| `Sources/WapleCompatCore` | 5 | 2,073 |
| `Sources/WapleRender` 외 소계 | — | 71,030 |
| `Tests/**` | 350 | 82,687 |
| wallpaper-source 디컴파일 C | 7,751 | — |

## 2.1 오라클 품질 — 전수 조사 결과 매우 양호

감사에서 흔히 나오는 "통과할 수밖에 없는 테스트" 를 전수로 찾았다. **거의 없다.**

| 검사 | 결과 |
| --- | --- |
| 단언이 전무한 `func test*` | **1건** (`ZZTempSqrtVerify` — 추적되지 않은 임시 파일, H1) / 3,886 |
| 항진 단언(`XCTAssertTrue(true)` · `XCTAssertEqual(x, x)`) | **0건** (주석 제외 전수 스캔) |
| `Sources/**` 의 `try!` · `as!` | **0건** |
| `@unchecked Sendable` · `nonisolated(unsafe)` | 전건 근거 주석 동반 |

### 돌연변이 검증 — UI 규약 게이트는 실제로 이빨이 있다

커밋되지 않은 변경 중 가장 큰 테스트 변경은 `UIConventionTests.swift` (+358/−28)인데
**테스트 개수는 4 그대로**다 — 늘어난 것은 전부 파서 인프라(`contextMenuItems` ·
`accessibilityActionLabels` · `tapGestureSites` · `builderBody` 등)다. 소스를 문자열로
파싱해 규약을 검사하는 종류라, 파서가 조용히 아무것도 못 잡게 되는 것이 최대 위험이다.
그래서 **돌연변이를 주입해 실제로 빨개지는지 확인했다.**

실제 UI 소스(`Sources/Waple/Surfaces/Displays/DisplaysView.swift`)에 금지 패턴
`.spring(` 을 한 줄 심고 게이트를 돌렸다:

```
Test Case '-[WapleAppTests.UIConventionTests testAnimationsComeFromMotionTokens]' started.
UIConventionTests.swift:92: error: XCTAssertTrue failed -
  모션은 Motion 토큰으로만 만든다(reduceMotion 분기가 토큰 안에 있다).
  새 위반 1건:
Test Case ... failed (0.272 seconds)
```

**주입 → 빨강, 복원 → 초록**(복원은 바이트 동일로 확인, 작업 트리 무변경 45파일 유지).
즉 이 게이트는 살아 있다. 설계도 견고하다 — `assertConvention`(`:56-71`)이
① 모집단 하한(`XCTAssertGreaterThan(sources.count, 20)`)으로 **수집 실패 자체를** 잡고,
② `pending` 허용 목록의 **스테일 항목**을 잡아("안 지우면 그 파일의 다음 위반을 조용히
덮어준다") 허용 목록이 조용히 자라는 것을 막는다. 이 리포가 다른 곳에서 반복해 물린
"모집단이 0 인데 초록" 함정을 이 자리에서는 선제적으로 막고 있다.

리포는 과거 이 부류를 스스로 적발한 이력을 남긴다 —
`SceneRendererMeshCustomShaderTests.swift:16-20` 이 *"마지막 줄이 리터럴
`XCTAssertTrue(true)` 였다. 무엇이 깨져도 초록인 테스트였다"* 를 정정 기록으로 보존한다.
그 규율이 현재 트리에서 실제로 유지되고 있음을 확인했다.

## 3. 발견

심각도는 **실동작 영향**과 **게이트 무력화**를 기준으로 매긴다. 각 항목은 재현 명령을 동반한다.

---

### 🟠 C1 — 테스트 개수 게이트가 **툴체인에 따라 다른 값을 읽는다**(로컬 462 vs CI 합계), 그리고 하한 3875 는 초록 실행에서 잰 값이 아니다

- **자리**: `.github/workflows/ci.yml:740` (추출), `:754` (판정). 둘 다 **커밋되지 않은 변경** 안에 있다.
- **성격**: 게이트 자체의 결함 + 곧 실패할 CI. 이 리포에서 가장 비싼 종류다 —
  트립와이어가 자기가 지켜야 할 값을 못 읽고 있다.

**게이트 코드**:

```bash
EXECUTED=$(grep -oE "Executed [0-9]+ test" test-output.log | tail -1 | grep -oE "[0-9]+" || echo 0)
...
if [ "${EXECUTED:-0}" -lt 3875 ]; then   # ← 커밋 안 된 변경이 3774 → 3875 로 올렸다
```

**실측 — 이 맥에서 `swift test` 를 실제로 돌리고 게이트를 그대로 재생했다**:

```
$ swift test            # 실패 0 · 스킵 63
$ grep -A1 "Test Suite '.*\.xctest' passed" test.log | grep -oE "Executed [0-9]+ tests"
Executed 26 tests      ← WapleSnapshotTests
Executed 1166 tests    ← WapleRenderTests
Executed 74 tests      ← WaplePolicyTests
Executed 52 tests      ← WapleLibraryTests
Executed 2078 tests    ← WapleCoreTests
Executed 28 tests      ← WapleCompatCoreTests
Executed 462 tests     ← WapleAppTests  ← 로그의 **마지막** 번들
                       합계 = 3,886

$ grep -oE "Executed [0-9]+ test" test.log | tail -1     # 게이트가 읽는 값
Executed 462 test
```

게이트를 한 줄도 바꾸지 않고 그대로 실행한 결과:

```
executed=462 skipped=63
GATE: FLOOR FIRES -> CI WOULD FAIL (executed 462 < 3875)
```

**왜 이런가**: `swift test` 는 테스트 타깃 7개를 **각각 별도 xctest 번들로** 실행하고
번들마다 `Test Suite 'All tests' … Executed N tests` 를 따로 낸다(이 로그에 `All tests`
줄이 **14개** = 번들 7 × (시작·종료)). `tail -1` 은 그중 **마지막 번들 하나**만 집는다.
정본이 세려던 값은 7개의 **합**이다.

**이 결함이 하한 갱신 근거 안에 이미 적혀 있다** — `ci.yml` 의 새 주석은
번들별 실측을 나열하고 손으로 더한다:

> `번들별 실측 26·1166·74·52·2076·28·461 = 3,883`

즉 **작성자는 합을 손으로 계산했고, 게이트는 마지막 항만 읽는다.** 같은 주석이
스스로 미완료임을 인정한다: *"`executed=3875` 이상을 확인하면 여기에 런 id 를 덧붙여
근거를 규약대로 마감해라"* — 즉 **이 하한은 초록 실행에서 잰 값이 아니다.**
이 리포의 자기 규약(*"하한은 초록 실행이 실제로 잰 값에서만 올린다(추정 금지)"*)을
그 규약을 적은 줄 바로 아래에서 위반한 셈이다.

**개수 자체는 정직하다** — 틀린 것은 추출뿐이다. 세 값이 정확히 맞물린다:

| 세는 법 | 값 |
| --- | --- |
| HEAD 커밋 파일만, 정본 레시피 | **3,875** ← 새 하한과 일치 |
| 작업 트리, 정본 레시피 | **3,886** |
| 실제 실행 합계 | **3,886** ← 정적 개수와 일치 |
| `swift test --list-tests` | **3,886** |

**왜 지금까지 안 터졌나 — 답을 찾았다. CI 러너의 로그 형태가 이 맥과 다르다.**
`ci.yml` 주석이 보존한 **실제 CI 실측치**를 전수로 뽑으면 전부 **전체 합계 크기**다:

```
executed=3596 skipped=65     executed=3686 skipped=64/65
executed=3693 skipped=63/64  executed=3708 skipped=63/64
executed=3723 skipped=63     executed=3774 skipped=64
```

`462` 같은 **단일 번들 크기가 한 번도 나온 적이 없다.** 즉 `macos-26` 러너에서는
`tail -1` 이 잡는 마지막 `Executed N test` 가 **전체 합계**다 — SwiftPM 이 거기서는
단일 번들(`WaplePackageTests.xctest`)로 합쳐 실행하거나, 마지막에 총계 줄을 한 번 더 내기
때문으로 보인다(러너 로그를 직접 보지 못했으므로 기전은 [추정]이다).

**그래서 C1 의 성격이 이렇게 확정된다**:

| | 이 맥 (Xcode 27 / Swift 6.4) | CI (`macos-26`) |
| --- | --- | --- |
| `swift test` 로그 | 번들 7개가 각각 `Executed N` 을 냄 | 합계 한 줄이 마지막에 옴(실측 이력) |
| 게이트가 읽는 값 | **462** | 3596~3774 (합계) |
| 하한 3875 판정 | **실패** | 통과했을 것 |

즉 **CI 는 아마 초록일 것이고, 결함은 두 가지로 남는다**:
① **게이트가 툴체인 의존이다** — 같은 트리·같은 명령이 로컬에서는 실패하고 CI 에서는
통과한다. `AGENTS.md` 가 규약으로 세운 "커밋 전에 정적 개수로 하한 통과를 미리 계산한다" 가
**로컬에서 검산 불가**라는 뜻이다(그 규약의 목적 자체가 무력화된다).
② **하한 3875 는 여전히 초록 실행에서 잰 값이 아니다** — 주석 자신이
*"`executed=3875` 이상을 확인하면 여기에 런 id 를 덧붙여 근거를 규약대로 마감해라"* 로
미완을 인정한다. 이 리포의 래칫 규약("하한은 초록 실행이 실제로 잰 값에서만 올린다(추정 금지)")
위반이 그대로 남는다.

**추출이 구조적으로 취약하다는 추가 증거 — `tail -1` 은 번들 순서에 달려 있다.**
같은 명령에 `--filter` 만 붙여 실행하면 마지막 `Executed` 줄이 **0** 이 된다:

```
$ swift test --filter 'SceneVersionFeatureGate'
  Test Suite 'WapleCoreTests.xctest' passed …   Executed 4 tests    ← 실제로 돈 것
  Test Suite 'WapleCompatCoreTests.xctest' …    Executed 0 tests
  Test Suite 'WapleAppTests.xctest' …           Executed 0 tests    ← tail -1 이 집는 값
$ … | grep -oE "Executed [0-9]+ test" | tail -1
Executed 0 test
```

즉 **비어 있는 번들이 마지막에 오면 게이트는 0 을 읽는다.** `tail -1` 은 "총계" 를 뽑는
표현이 아니라 **"로그에 마지막으로 찍힌 번들"** 을 뽑는 표현이고, 그 순서는 SwiftPM·툴체인·
필터·번들 구성에 따라 바뀐다. CI 에서 지금까지 맞았던 것은 **운이 좋았던 것**이다.

**심각도 재판정**: "지금 푸시하면 CI 가 붉어진다" 는 **약해진다**(CI 는 통과할 것으로 보인다).
그러나 **게이트가 로컬에서 거짓 실패를 내고, 하한의 근거가 없다**는 두 결함은 유효하다.
합산 추출로 바꾸면 양쪽이 같은 값을 보게 되어 둘 다 해소된다.

**고칠 방향(수정 금지 지시에 따라 적기만 한다)**: `tail -1` 대신 전 번들 합산.
```bash
EXECUTED=$(grep -oE "Executed [0-9]+ tests?, with" test-output.log \
  | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
```
단 이 형태는 **중첩 스위트도 함께 더한다**(클래스별 `Executed` 도 같은 문법이다) —
`Test Suite '<...>.xctest'` 직후 줄만 골라야 한다. 재현 명령은 위 실측 블록에 있다.

---

### 🟠 H1 — 임시 검증 파일 `ZZTempSqrtVerify.swift` 가 테스트 타깃에 남아 실행된다

- **자리**: `Tests/WapleRenderTests/ZZTempSqrtVerify.swift` — **추적되지 않은 파일**(`git status` `??`).
- **실측**: 이 실행에서 **실제로 돌았다**(로그에 4회 등장). 즉 정적 개수·실행 개수에 모두 집계된다.
- **문제 세 가지**:
  1. 이름이 `ZZTemp` — 알파벳 정렬로 마지막에 오게 만든 **임시 파일**이고, 그 의도가 이름에 적혀 있다.
  2. **단언이 하나도 없다.** 전부 `print("SQRTV …")` 다. `XCTAssert` 계열 0개 —
     **전수 조사로 확인했다: 테스트 3,886개 중 단언이 전무한 것은 이 하나뿐이다.**
     (`Tests/**` 의 모든 `func test*` 본문을 파싱해 `XCTAssert*`/`XCTFail`/`XCTUnwrap`/`XCTSkip`,
     커스텀 헬퍼(`assert*`/`expect*`/`verify*`/`require*`/`check*`), `try` 호출(예외가 곧 오라클)
     중 **어느 것도 없는** 것을 셌다. 결과 1건 = 이 파일.)
     즉 이 리포의 오라클 규율은 실제로 매우 엄격하고, 이 파일만 예외다 —
     `ShaderPreprocessor` 가 `M_PI_2`/`SQRT_2`/`SQRT_3` 를 흘리든 말든 **항상 통과한다**.
     오라클이 아니라 로그 출력기다.
  3. 그런데도 **하한 계산에는 +1 로 들어간다** — 즉 트립와이어의 분모를 채우면서
     아무것도 지키지 않는다. 하한 여유가 0 인 지금(위 C1) 이 1건이 그대로 게이트 값에 섞인다.
- **추가 — 그 파일이 열어 둔 질문을 내가 실행으로 닫았다. 결론: 결함 아님.**
  `ZZTemp` 가 조사하던 것은 "`SQRT_2`/`SQRT_3` 가 치환되는가" 였고, 실제로
  `GLSLTranslator.typeAndMacroRenames()` 의 매크로 표에는 **`M_PI`·`M_PI_HALF`·`M_PI_2` 만
  있고 `SQRT_2`/`SQRT_3` 는 없다**(실측). 그러나 실물 경로에서는 문제가 되지 않는다 —
  실제 번역기를 불러 확인했다(프로브는 측정 후 삭제):

  ```
  include 있음:  SQRT_2 잔존? false   SQRT_3 잔존? false   → 1.41421356237 치환됨 ✅
  include 없음:  SQRT_2 잔존? true    SQRT_3 잔존? true    → 미해결 식별자로 누출
                 M_PI_2 잔존? false  → 6.28318530718 (매크로 표가 처리)
  ```

  즉 두 상수는 **매크로 표가 아니라 `#include "common.h"` 텍스트로** 해결된다.
  그리고 그 `common.h` 는 **항상 존재한다**: WE 원본 `common.h` 가
  `Sources/WapleRender/Resources/WEAssets/shaders/common.h` 로 동봉돼 있고
  `Package.swift:34` 가 `.copy("Resources/WEAssets")` 로 **번들 리소스로 싣는다**.
  `BaseAssetsSettings.searchRoots`(`:91-99`)는 사용자 지정 팩 다음에 **항상 동봉본을
  덧붙이므로** 해석 실패 경로가 없다. 따라서 매크로 표의 누락은 실동작 영향 0 이다.

  **부수 확인 — `M_PI_2 = 6.28318530718`(2π)은 옳다.** C 관례(π/2)와 반대라 오타처럼
  보이지만, WE 실물 `common.h` 를 직접 읽어 확인했다:
  `#define M_PI_2 6.28318530718` · `#define M_PI_HALF 1.57079632679`.
  즉 WE 가 비표준 관례를 쓰는 것이고 코드 주석("WE 관용: M_PI_2 = 2π … π/2 는 M_PI_HALF
  담당")이 **정확하다**. 이 자리는 손대면 오히려 깨진다.

---

### 🟠 H2 — 정본 인용 census 가 어긋나 있다(62 vs 66). 그것을 잡는 게이트는 **추적되지 않아 CI 에서 못 돈다**

두 결함이 겹쳐 있다. 하나는 데이터 불일치, 하나는 그것을 잡을 그물이 CI 밖이라는 것.

**(a) 게이트 19개 중 유일한 실패 — 실측**:

```
$ for f in scripts/spec/check_*.py; do python3 "$f"; echo "rc=$?"; done
check_cited_address_census.py    rc=1   ← 19개 중 유일한 실패
  X total: 정본 62 vs 실측 66 — 인용 전수가 정본의 census 와 어긋난다
나머지 18개                       rc=0
```

**(b) 원인을 끝까지 추적했다 — 커밋되지 않은 `Model3D.swift` 가 인용 4건을 새로 만들었다.**

`decomp.citedAddressClassification` 은 리포가 인용하는 `FUN_140xxxxxx` 주소 **전수**의
census 다. 그 모집단은 `grep -rhoE "FUN_140[0-9a-f]{6}" Sources spec docs` 로 정해진다.
HEAD 와 작업 트리에서 같은 레시피를 돌려 비교했다:

```
HEAD cited unique:      62      ← 정본의 total 62 와 정확히 일치. 정본은 HEAD 기준으로 옳다
worktree cited unique:  66
NEW in worktree:  FUN_14009c500 · FUN_14009c5c0 · FUN_1400d7f90 · FUN_140261680
GONE from HEAD:   (없음)
```

네 주소 전건이 **`Sources/WapleCore/Model3D.swift` 의 커밋되지 않은 변경**에서 나왔고,
전건이 같은 성격이다 — `[정정 2026-08-30]` 이라 적으며 **−0xD0 보정을 적용한 새 이름**이다:

| 자리 | 정정 |
| --- | --- |
| `Model3D.swift:223`·`:1056` | ~~`FUN_14009c5d0`~~ → **`FUN_14009c500`** (−0xD0, manifest 확인) |
| `Model3D.swift:211` | ~~`FUN_14009c690`~~ → **`FUN_14009c5c0`** (−0xD0) |
| `Model3D.swift:657` | ~~`FUN_1400d8060.c:81-96`~~ → **`FUN_1400d7f90`** (−0xD0, manifest 확인) |
| `Model3D.swift:898` | `FUN_140261680(…+0x38)` |

**중요 — 그 정정 자체는 옳다. 원본 바이너리의 디컴파일 manifest 로 직접 검증했다**
(`Waple-wallpaper-source/analysis/decompiled/manifest.json`, program `wallpaper64_rich.exe`,
함수 7,748개):

| 옛 이름(취소선 처리됨) | manifest 에 있나 | 새 이름 | manifest 에 있나 | 차 |
| --- | --- | --- | --- | --- |
| `FUN_14009c5d0` | **없다** | `FUN_14009c500` | **있다** | `0xd0` |
| `FUN_14009c690` | **없다** | `FUN_14009c5c0` | **있다** | `0xd0` |
| `FUN_1400d8060` | **없다** | `FUN_1400d7f90` | **있다** | `0xd0` |
| `FUN_140261750` | **없다** | `FUN_140261680` | **있다** | `0xd0` |

네 쌍 전건이 정확히 `−0xD0` 이고, **옛 이름은 하나도 manifest 에 없고 새 이름은 전건 있다.**
즉 이 커밋되지 않은 변경의 주소 정정은 **실물로 확인된 옳은 수정**이다 —
문제는 정정 자체가 아니라 **그 부수효과(census 모집단 +4)가 정본에 반영되지 않은 것**뿐이다.

**즉 이 변경은 정본 규율을 절반만 이행했다.** 취소선으로 옛 이름을 보존하는 이 리포의
관례를 지켰기 때문에 **옛 이름도 여전히 grep 에 걸리고**, 새 이름이 순증 4가 됐다.
그런데 census 는 재생성되지 않았다. 정본의 내부 산술은 자기 안에서는 맞다
(`42 + 17 + 3 = 62`) — 모집단만 낡았다.

**(b-2) 같은 항목의 자리별 도수 하나가 틀렸다 — `Sources 8건` 은 실측 7 이다.**
그 정정문은 자기 세는 법을 명시한다(*"실측(`grep -rl FUN_<va> Tests` · 같은 것을 Sources 로)"*)
— 그래서 그대로 돌렸다. `needsMinus0xD0List` 17건 각각을 확인한 결과:

| 주장 | 실측 | 판정 |
| --- | --- | --- |
| Tests **5**건 | **5** | ✅ |
| Sources **8**건 | **7** | ❌ (1 과다) |
| 둘의 합집합 **9**건 | **9** | ✅ |
| docs 에만 **8**건 | **8** | ✅ |

`Sources` 에 있는 7건: `0x140046ff0` · `0x140086eb0` · `0x14009c5d0` · `0x14009c630` ·
`0x14009c690` · `0x1400d8060` · `0x140261950`. 합집합 9 와 Tests 5 가 맞는데 Sources 만
어긋나므로 **단순 계수 착오**로 보인다(합집합이 맞는 것은 겹침 3건이 우연히 상쇄한 결과다:
7 + 5 − 3 = 9, 8 + 5 − 4 = 9 도 9 라서 합집합만으로는 이 오류가 드러나지 않는다).
**영향은 서술 정확성뿐** — 어느 판정도 이 수에 의존하지 않는다.

**(c) 그 게이트가 추적되지 않고, `spec.yml` 에도 배선되지 않았다 — 게이트 19개 중 유일하다.**
디스크의 게이트와 `spec.yml` 이 부르는 게이트를 집합으로 비교했다:

```
EXIST but NOT WIRED into spec.yml:   check_cited_address_census.py   ← 유일
WIRED but missing on disk:           (없음)
```

즉 **18/19 는 배선돼 있고 딱 이것만 빠졌다.** 게다가 `git status` 에서 `??` 다 —
추적되지 않은 게이트는 CI 체크아웃에 존재하지 않으므로 배선을 고쳐도 파일이 없다.
두 겹으로 막혀 있다: **추적 안 됨 + 배선 안 됨.** 로컬에서만 도는 검사는 게이트가 아니다.

**이 게이트는 잘 만들어져 있다** — 없애면 안 되는 쪽이다. 머리말이 스스로 왜 필요한지
적는다: 이 도수는 다른 게이트 셋(생성기 값·키·축소 가드) 전부의 사각지대다.
`check_canon_generator_values.py` 는 리터럴만 보고 이 값은 동적이라 안 보이고,
키 검사는 도수를 안 보고, 축소 가드는 `양수 → 0` 만 잡아 `62 → 66` 을 못 본다.
재생성은 원본 바이너리(`WE_BINARY`)와 재생성 코퍼스를 요구하는데 그것은 짝 저장소에만
있으므로 **CI 에서는 영영 돌지 않는다.** 그래서 이 게이트는 "세는 절반"(모집단 크기)만
검사해 CI 에서 돌 수 있도록 설계돼 있다 — 정확히 지금의 결함을 잡도록 만들어졌고,
실제로 잡았다. 다만 **추적되지 않아 CI 에서는 못 잡는다.**

- **동류**: `docs/playback-architecture.html` 도 추적되지 않는다 → M1 참조.

---

### 🟡 M1 — `WAPLE-ANALYSIS-SUMMARY-2026-08-27.md` 가 추적되지 않은 채 리포 루트에 있다

- **자리**: 리포 루트, 21,921바이트.
- **문제**: 문서 스스로 §1.1 에서 *"이 파일은 추적되지 않은 문서이고 리뷰를 거친 적이 없다.
  정량 수치를 인용하기 전에 §1.1 을 읽어라"* 라고 적는다. 즉 **자기 신뢰성을 스스로 부정하는
  문서가 리포에서 가장 눈에 띄는 자리(루트)에 있다.** 루트에 있는 `*.md` 는 새로 온 사람이
  가장 먼저 읽는 것이라 위험이 크다 — `AGENTS.md`·`README.md`·`BACKLOG.md` 와 같은 층에 있다.
- **부수 발견(경미)**: 루트에 `Ox` 라는 **0바이트 파일**이 있다. 오타로 생긴 리다이렉트
  산출물로 보인다. **추적되지 않으므로 리포 결함은 아니다** — 확인 결과
  `check_stray_artifacts.py` 는 *추적 중인* 파일만 검사하고(설계상 의도: 커밋된 잔재를
  시끄럽게 잡는 것이 목적), `Ox` 는 로컬 노이즈다. 지우면 끝이다.
- **확인 결과 정정**: `docs/playback-architecture.html` 은 `docs/README.md` 색인에
  **등재되어 있지 않다**(grep 0건). 따라서 "깨진 링크" 위험은 없다 — 대신 **색인에 없는
  47KB 문서**라는 다른 문제다. 이 리포는 색인 누락을 결함으로 다룬 이력이 있다
  (`docs/README.md` 의 "[2026-08-25] 이 절이 통째로 빠져 있었다" — `docs/re/` 33개 문서가
  색인에 없던 건). 같은 양상이 재발한 것이다.

---

### 🟠 H3 — `alphafade` 의 `fadeouttime` 을 **지속시간**으로 다룬다. WE 는 **시작점**이다 — 코퍼스 250건 중 110건이 어긋난다

- **자리**: `Sources/WapleCore/ParticleSimulator.swift:2162-2167` (`fadeFactor`)
- **성격**: 실동작 결함(오렌더). 게이트도 오라클도 못 잡는다 — 기본값에서만 일치하기 때문이다.

**Waple 의 현재 산술**:

```swift
private func fadeFactor(_ n: Float, _ fin: Float, _ fout: Float) -> Float {
    let i = fin  > 0 ? max(0, min(1, n / fin))       : 1
    let o = fout > 0 ? max(0, min(1, (1 - n) / fout)) : 1   // ← fout 을 "말미 비율"(지속시간)로 읽는다
    return i * o
}
```

**WE 의 실제 산술 — 원본 바이너리를 직접 디스어셈블해 확인했다**(`binaries/wallpaper64.exe`,
핸들러 `0x14024029d`~). 세 갈래 select 이고 `fadeouttime` 은 **페이드아웃이 시작하는 시점**이다:

```
0x14024029d  movaps xmm12, [rip+0x24339b]   ; xmm12 = 1.0  (실측: 0x140483640 = 1.0,1.0,1.0,1.0)
0x1402402af  subps  xmm0, [r14+0x20]        ; xmm0  = 1 - fadeouttime
0x1402402b4  rcpps  xmm5, [r14+0x10]        ; xmm5  = 1 / fadeintime
0x1402402c7  rcpps  xmm6, xmm0              ; xmm6  = 1 / (1 - fadeouttime)   ← 결정적 증거
0x1402402e5  movups xmm2, [r14+0x20]
0x1402402ef  cmpltps xmm2, xmm4             ; xmm2 = (fadeouttime < t)
0x1402402f9  cmpltps xmm1, [r14+0x10]       ; xmm1 = (t < fadeintime)
0x1402402ff  mulps  xmm0, xmm5              ;  t / fadeintime
0x140240313  subps  xmm1, xmm4              ;  1 - t
0x140240316  mulps  xmm1, xmm6              ; (1-t) / (1-fadeouttime)
0x140240308  andnps xmm3, xmm12             ; 두 조건 모두 거짓 → 1.0
```

즉 `f = (t < fin) ? t/fin : (fout < t) ? (1-t)/(1-fout) : 1` 이다.
`1/(1-fout)` 을 계산한다는 것이 **`fout` 이 시작점이라는 증거**다 — 지속시간이면
`1/fout` 이어야 한다. 그리고 `[r14+0x20]` 이라는 **같은 슬롯**이 `rcpps` 의 입력과
`cmpltps` 의 비교 대상 양쪽에 쓰인다(임계값 겸 기울기).

**수치 비교 — 기본값에서만 일치한다**:

| `fadeouttime` | `max|WE − Waple|` | |
| --- | --- | --- |
| **0.5**(기본값) | **0.0000** | 완전 일치 — 그래서 아무 테스트도 못 잡았다 |
| 0.3 | **0.5714** | 어긋남 |
| 0.8 | **0.7500** | 어긋남 |

`fin=0.2, fout=0.8` 표본(수명 비율 t):

| t | WE | Waple |
| --- | --- | --- |
| 0.50 | 1.000 | 0.625 |
| 0.70 | 1.000 | 0.375 |
| 0.90 | 0.500 | 0.125 |

즉 WE 는 수명 80% 까지 **완전 불투명**으로 유지한 뒤 꺼지는데, Waple 은 처음부터
계속 흐려진다. 파티클이 **전반적으로 너무 투명하게** 보인다.

**도달 범위 — 동봉 코퍼스에서 직접 셌다**:

```
alphafade 인스턴스 250건
  fadeouttime 명시 != 0.5 :  110건   ← 이만큼이 지금 틀리게 렌더된다
  값 분포: 미지정 138 · 0.9 (25) · 0.1 (25) · 0.89999998 (13) · 0.8 (12) · 0.3 (8) · 1.0 (8) …
```

영향 파일 예: `presets/lightshafts/…/dust_motes_0.json` ·
`presets/smoke/previewvapor1/…/vapor1_child.json` · `presets/magic/…/magic_glyphs_0.json` ·
`presets/water/…/water_impact.json`.

**독립 확인**: 이 감사의 교차대조 워크플로가 **별개 경로로 같은 결론에 도달했다** —
`fadeouttime` 파서를 `0x1401cb94b` 로 찾고 키 문자열을 `0x14048f8f0`
(`lea rdx,[rip+0x2c3fd5]` @ `0x1401cb914`)으로 해소해 레코드 슬롯 `+0x10` 을 확정한 뒤,
같은 슬롯이 `rcpps`(기울기)와 `cmpltps`(임계값) 양쪽에 쓰인다는 점을 근거로 삼았다.
또 하나를 덧붙인다: **Ghidra 산출물
`analysis/decompiled/all/000000014023fbc0__FUN_14023fbc0.c` 의 본문이 비어 있다**(디컴파일
실패) — 그래서 이 결함은 디컴파일 C 만 읽으면 보이지 않고 **직접 디스어셈블해야** 보인다.

**가장 아픈 점 — 정본은 이미 옳은 식을 갖고 있다.**
`docs/re/particle-operator-vm.md:513,550` 이 3분기 식을 정확히 적는다.
**문서가 옳고 코드가 안 따라온 것**이다 — 이 리포가 반복해 물린 "정본 거짓" 의 **반대
방향**이라 기존 게이트 어느 것도 잡을 수 없다(게이트는 전부 문서 ↔ 정본 JSON 대조이고,
문서 ↔ 코드 산술을 대조하는 게이트는 없다).

---

### 🟠 H4 — oscillate 계열 3종이 **진폭에서 파티클별 난수를 빼먹는다** — 61건 전건 영향

- **자리**: `Sources/WapleCore/ParticleSimulator.swift` 의 oscillate alpha/size/position
- **WE 실측** — 이 세션에서 직접 디스어셈블해 확인했다(`oscillatesize`, `0x14024123a`~`0x140241381`):

  ```
  0x14024123a  movups xmm9, [r14+0x60]      ; xmm9 = scale span (scalemax - scalemin)
  0x140241245  mov    r9,  [rsi+0x338]      ; r9  = 파티클별 난수 배열의 베이스
  0x140241253  mulps  xmm9, xmm15           ; xmm9 = span * 0.5
  0x140241270  movups xmm8, [r9+rcx*4]      ; xmm8 = r  (이 파티클의 난수)
  0x140241287  mulps  xmm8, xmm9            ; xmm8 = r * span * 0.5      ← 난수가 진폭에 들어간다
        …  (0x1402412a0–0x140241370: sin 다항식, xmm6 = sin(...))
  0x140241370  addps  xmm6, xmm12           ; xmm6 = 1 + sin(...)        (xmm12 = 1.0 실측)
  0x140241374  mulps  xmm6, xmm8            ; xmm6 = (1+sin) * r * span * 0.5
  0x140241378  addps  xmm6, [r14+0x50]      ; xmm6 += scalemin
  0x14024137d  mulps  xmm6, [rdx+rcx*4]     ; 기존 크기에 곱해 적용
  ```

  즉 `factor = scalemin + r · (scalemax − scalemin) · 0.5 · (1 + sin(...))` 이다.
  **`mulps xmm6, xmm8` 한 줄이 결정적 증거**다 — 난수가 진동 진폭 자체를 스케일한다.
- **Waple**: `lerp(smin, smax, osc01)` — 난수 `r` 이 **주파수·위상에만** 쓰이고 진폭에는 안 들어간다.
- **결과**: WE 에서는 파티클마다 진동 **크기가 다르다**(r 이 진폭을 스케일). Waple 에서는
  전 파티클이 같은 진폭으로 진동해 **집단이 한 몸처럼 맥동한다**.
- **도달**: oscillate 계열 **61 인스턴스 전건**(기본값 여부와 무관 — 난수 항이 아예 없으므로).
  동봉 코퍼스에서 직접 셌다: `oscillatealpha` **36** · `oscillateposition` **17** ·
  `oscillatesize` **8** = **61**. H3 과 달리 "기본값에서는 일치" 하는 구간이 없다 —
  난수 항 자체가 빠져 있으므로 **모든 인스턴스가 항상 어긋난다.**

> **검증 상태**: H3 · H4 **둘 다 이 세션에서 원본 바이너리 디스어셈블로 직접 확인했다**
> (H3 은 수치비교 + 코퍼스 계수 250/110 까지, H4 는 `0x14024123a`–`0x140241381` 전 구간).
> `alpha`·`position` 변종은 같은 구조의 형제 핸들러로, `size` 만 명령 단위로 떴다.

---

### ~~🟡 M14~~ — **철회한다.** `161/161` 은 **워크샵 코퍼스** 실측이고 정본이 그것을 기록한다

- **자리**: `Sources/WapleRender/SceneRenderer.swift:1140` vs `Sources/WapleCore/SceneDocument.swift:3728-3731`

**[철회 2026-08-31] 내가 모집단을 잘못 짚었다.** 아래 서술은 근거 보존을 위해 남기지만
**결함이 아니다** — `spec/corpus/scene-schema.json` `scene.general.keys` 가
`clearenabled: {n: 162, values: {True: 161}}` 을 적는다. 즉 **워크샵 코퍼스 162 중 저작 161,
전건 `true`** 이고 `SceneRenderer.swift:1140` 의 "코퍼스 161/161 전건 true" 는 **정확한 인용**이다.
내가 대조한 141/96/45 는 **설치본** 모집단이라 애초에 다른 수다.

두 주석은 서로 다른 모집단을 적고 있었을 뿐이다:

| 자리 | 문면 |
| --- | --- |
| `SceneRenderer.swift:1140` | "기본 true(무회귀 — **코퍼스 161/161 전건 true**)" |
| `SceneDocument.swift:3729-3730` | "유일한 비-불리언은 `general.clearenabled: null`(**설치본 씬 141 중 45**, **동봉 136 중 44**)" |

**직접 세어 판정했다**:

| 모집단 | `clearenabled` 존재 | `true` | `null` |
| --- | --- | --- | --- |
| 설치본 `assets/`+`projects/` | **141** | **96** | **45** |
| 동봉 `WEAssets` | **136** | 92 | **44** |

**둘 다 맞다.** `SceneDocument`(설치본 141/45 · 동봉 136/44)는 내 실측과 전건 일치하고,
`SceneRenderer`(워크샵 162 중 161 전건 true)는 정본과 전건 일치한다.
**내 오판의 원인**: 두 주석 중 하나만 모집단 이름을 적었다 — `SceneRenderer` 쪽은
"코퍼스" 라고만 해서 내가 설치본으로 읽었다. **그것이 유일한 개선점이고 결함은 아니다.**

**남는 관찰(결함 아님)**: 설치본에는 `clearenabled: null` 이 45건 있고 그것이
`weBoolOpt` 가 태그 0 을 `nil` 로 돌리는 설계의 존재 이유다(`null` → 기본값 `true`).
워크샵 코퍼스에는 `null` 이 없어(161 전건 `true`) 두 모집단의 성질이 다르다 —
**모집단 이름을 적으면 이 차이가 정보가 되고, 안 적으면 모순처럼 보인다.**

---

### 🟠 H6 — `PuppetModel` 의 MDLA 클립 루프가 **버전 게이트 없는 이벤트 블록을 건너뛰지 않는다** — 이벤트가 있으면 그 뒤 모든 클립이 오파싱된다

- **자리**: `Sources/WapleCore/PuppetModel.swift:306-352`
- 발견 경로: 병렬 워크플로(교차대조 레인)가 지목했고, **내가 원본 바이너리 디스어셈블로 확인했다.**

**주석의 전제**: `:306` — *"MDLA0001 은 버전 1 이라 v≥2..v≥6 게이트 블록이 전부 꺼져 있다(§6)
— **본 트랙 뒤가 곧 다음 클립이다**."* 그래서 본 트랙(`boneCount × tSize`)을 읽은 직후
곧바로 다음 클립으로 넘어가고 `events: []` 를 넣는다(`:348`).

**바이트가 그 전제를 반박한다.** 엔진의 클립 루프에서 이벤트 블록은 **버전 게이트 밖**이다 —
디스어셈블로 확인했다:

```
0x14026536d  mov  r13d, dword ptr [rsi]     ; u32 eventCount 를 읽는다
0x140265370  add  rsi, 4
0x140265379  test r13d, r13d
0x14026537c  jle  0x140265494               ; count==0 이면 건너뛴다 (버전이 아니라 count 로 갈린다)
0x1402653bd  movss xmm0, dword ptr [rsi]    ; f32 seconds
0x1402653c1  add  rsi, 4
0x1402653e0  cmp  byte ptr [rsi], 0         ; NUL 종단 cstring(JSON) 스캔
```

**분기 조건이 `test r13d,r13d`(= eventCount)뿐이고 버전 비교가 없다.** 즉 MDLA0001 에서도
클립마다 `u32 count + count × (f32 seconds | cstring JSON)` 이 존재하며, count 가 0 이면
길이 0 으로 지나간다.

**결과**: 이벤트를 가진 퍼펫 클립이 하나라도 있으면 `PuppetModel` 의 오프셋이 그만큼
어긋나고, **그 뒤 모든 클립의 이름·fps·본 트랙이 엉뚱한 바이트에서 읽힌다**
(`guard ok` 가 걸리면 이후 클립이 통째로 드롭되고, 안 걸리면 조용히 잘못된 애니메이션이 된다).

**형제 경로는 이미 처리한다** — `Model3D`(MDLV0023 컨테이너 퍼펫)는 `trailerEvents(...)` 로
이벤트를 파싱해 `anims[i].events` 에 넣는다(`Model3D.swift:1000-1014`). 즉 **같은 리포 안에서
한쪽은 읽고 한쪽은 없는 것으로 가정**한다.

**도달 범위는 미측정** — 네이티브 `MDLV0013` 퍼펫 파일이 **짝 저장소에 0건**이라
(내 실측: `.mdl` 28개가 `MDLV0014` 15 · `0004` 8 · `0023` 4 · `0017` 1) 이벤트를 가진
실물 표본을 이 맥에서 만들 수 없다. **그래서 "지금 깨진다" 가 아니라 "표본이 오면 깨진다"** 다.
`PuppetModel.swift:83` 이 "코퍼스 attachment 28씬 전수가 컨테이너형" 이라 적는 것과 정합한다 —
네이티브 퍼펫 경로 자체가 실물 미확인 영역이다.

---

### 🟠 H7 — `spec/engine/particle-fields.json` 이 **재생성되지 않았다** — 생성기는 `:2406` 을 산출하는데 정본은 `:2183`(223줄 드리프트, 무의미한 줄)

- **자리**: `spec/engine/particle-fields.json:199`(`consumeSite`) · `:219`(evidence `ref`)
  vs 생성기 `scripts/spec/measure_particle_fields.py:58-76`(`flags_consume_site`)
- 발견 경로: 병렬 워크플로가 지목, **내가 생성기를 직접 호출해 확인했다.**

이 라운드가 생성기를 **줄 번호 손박기 → 조건식 되짚기**로 고쳤다. 그 함수의 문서화가
이유를 적는다: *"이 자리는 같은 축으로 **두 번** 드리프트했다 — `:2050`(무관한 `MeshUniform`
조립부) → 2026-08-20 에 `:2183` 로 고쳤는데 **그 :2183 도 HEAD 에선 빈 문서주석 줄(`///`)**이다."*
그리고 세 번째를 막는 법까지 적는다 — *"손으로 다시 박지 않는 것이다."*

**그런데 정본 JSON 이 갱신되지 않았다.** 생성기를 실제로 import 해 돌렸다:

```
$ python3 -c "import measure_particle_fields as m; print(m._flags_consume_lineno())"
2406                     ← 생성기가 되짚은 실제 조건식 줄
$ grep -n 'let worldspace = (sys.def.flags & 1)' Sources/WapleRender/SceneRenderer3D.swift
2406:        let worldspace = (sys.def.flags & 1) != 0     ← 실물 확인

정본 particle-fields.json:199  "…SceneRenderer3D.swift:2183 — (sys.def.flags & 1)"
정본 particle-fields.json:219  "ref": "…SceneRenderer3D.swift:2183"
→ 223줄 드리프트, 그리고 :2183 은 빈 `///` 줄이다
```

**즉 수선은 코드에만 들어가고 산출물에는 반영되지 않았다.** 생성기가 옳은 값을 만들 수 있는
상태인데 정본이 옛 값을 들고 있으므로, **다음 재생성이 이것을 고칠 것**이지만 지금 커밋되면
"고쳤다" 는 기록과 함께 **틀린 값이 남는다.**

**게이트가 못 잡는 이유도 그 함수가 적어 뒀다** — `validate.py` 의 줄 실재 검사는
**파일 길이 초과만** 본다: *"2,540줄 파일 안의 아무 줄이나 통과한다 — 근거가 그럴듯한 다른
줄을 가리키는 부류는 자동 검사에 안 걸린다."* 내가 M21 에서 독립적으로 확인한 것과 같은 한계다.

**high 로 두는 이유**: 이것은 서술 오류가 아니라 **정본과 생성기의 불일치**다 —
`check_canon_generator_values.py` 가 리터럴만 대조하므로 동적 값인 이 자리를 보지 못하고,
"재생성으로만 잡힌다" 는 그 게이트의 자기 한계 서술이 정확히 여기서 실현됐다.

---

### 🟠 H8 — `parseLight` 의 기본값 6개가 **Waple 자신의 RE 문서와 전부 어긋난다** — `exponent` 는 설치본 라이트 6개 중 **5개**에 적용되고 픽셀을 바꾼다

- **자리**: `Sources/WapleCore/SceneDocument.swift:2691-2696` (`parseLight` 폴백)
  vs `docs/re/scene-lighting.md:75-80`(WE 라이트 생성자 기본값 표, 좌표 2개씩 동반)
- 발견 경로: 병렬 워크플로가 지목, 내가 문서·코드·코퍼스·셰이더를 대조해 확인했다.

`docs/re/scene-lighting.md` 는 WE 라이트 멤버의 오프셋·타입·**기본값**·두 좌표를 표로 적는다.
`parseLight` 의 폴백과 나란히 놓으면 **6/6 이 다르다**:

| 키 | 오프셋 | WE 기본값(RE 문서) | Waple 폴백 | 일치 |
| --- | --- | --- | --- | --- |
| `color` | `+0x2cc` | `0 0 0` | `1 1 1` | ❌ |
| `intensity` | `+0x2e4` | `0` | `1` | ❌ |
| `radius` | `+0x2e8` | `1.0` | `0` | ❌ |
| **`exponent`** | `+0x2ec` | **`2.0`** | **`1`** | ❌ |
| `innercone` | `+0x2f0` | `20.0`(도) | `0` | ❌ |
| `outercone` | `+0x2f4` | `30.0`(도) | `0` | ❌ |

**도달 범위를 코퍼스로 쟀다 — 라이트 오브젝트 6개(전부 point 계열)**:

| 키 | 폴백이 실제로 쓰이는 라이트 수 |
| --- | --- |
| `color` · `intensity` · `radius` | **0 / 6** (전건 저작됨 → 무해) |
| **`exponent`** | **5 / 6** ← 실동작 영향 |
| `innercone` · `outercone` | 6 / 6 이 폴백을 쓰지만 **spot 라이트가 두 코퍼스에 0건**이라 도달 0 (동봉 `WEAssets` 라이트 3개도 전부 `lpoint`) |

**`exponent` 만 픽셀을 바꾼다.** WE 식은 `radiance = lightColor * pow(falloff + flt_min, exponent)`
(`docs/re/scene-lighting.md:261`)이고 Waple 의 라이브 MSL 도 같은 형태다
(`Mesh3DShaders.swift:162` `pow(falloff + 1.17549435e-38, exponent)`). 지수 1 vs 2.0 의 차:

| falloff | exponent=1(Waple) | exponent=2(WE) | 비 |
| --- | --- | --- | --- |
| 0.9 | 0.900 | 0.810 | 1.11× 밝다 |
| 0.5 | 0.500 | 0.250 | **2×** 밝다 |
| 0.25 | 0.250 | 0.063 | **4×** 밝다 |
| 0.1 | 0.100 | 0.010 | **10×** 밝다 |

즉 `exponent` 미저작 라이트는 **거리에 따라 최대 수 배 밝게** 렌더된다.
그리고 그 5개 중 하나(`collisionmodel`)는 **명시적으로 `2.0` 을 저작한다** — 저작자가 2.0 을
쓴다는 것 자체가 그것이 엔진 기본값과 같음을 시사한다.

**요약하면 도달하는 결함은 `exponent` 하나다** — `color`/`intensity`/`radius` 는 전건 저작되고,
`innercone`/`outercone` 은 spot 라이트가 실물에 없다(설치본 6 + 동봉 3 = **9개 전부 point 계열**).
다만 **워크샵 코퍼스(446)에 spot 이 있으면 콘 기본값도 즉시 도달하고, 그 결과는 더 나쁘다.**
수치로 확인했다 — 셰이더는 `cone = clamp((cosAngle − cosOuter) / max(cosInner − cosOuter, 1e-4), 0, 1)` 이고
Waple 은 도(degree)를 `cos` 로 실어 보낸다:

| inner/outer | cosInner / cosOuter | 축상(0°) | 5° | 10° | 20° |
| --- | --- | --- | --- | --- | --- |
| **0 / 0**(Waple 폴백) | 1.000000 / 1.000000 | **0.000** | **0.000** | **0.000** | **0.000** |
| 20 / 30(WE 기본) | 0.984808 / 0.965926 | 1.000 | 1.000 | 1.000 | 0.000 |

즉 **콘이 완전히 닫혀 spot 라이트가 축 중심에서도 0 이 된다 — 라이트가 통째로 사라진다.**
현재 코퍼스에서 안 보이는 것이지 안전한 것이 아니다(설치본 6 + 동봉 3 = 9개가 전부 point 계열이라
지금은 도달 0).

**오라클이 없다** — 테스트가 `exponent: 1` 을 **입력으로 넘기는** 자리는 여럿이지만
(`Scene3DLightingTests:326` · `TubeLightCSMandMipTests:183`) **파서 폴백이 무엇이어야 하는지를
단언하는 테스트는 0건**이다. 즉 값을 바꿔도 빨개지지 않는다.

**바이트로 확정했다 — 생성자의 기본값 초기화 블록을 직접 디코드했다.**
RE 문서 표의 두 번째 좌표(`0x14019049e` 계열)가 가리키는 자리는 `mov dword [rdi+off], imm32`
연쇄이고, 그 imm32 를 f32 로 읽으면 **표의 기본값과 7/7 일치한다**:

```
mov dword [rdi+0x2e8], 0x3f800000  =   1.0   ← radius              (문서 1.0)   ✅
mov dword [rdi+0x2ec], 0x40000000  =   2.0   ← exponent            (문서 2.0)   ✅
mov dword [rdi+0x2f0], 0x41a00000  =  20.0   ← innercone           (문서 20.0)  ✅
mov dword [rdi+0x2f4], 0x41f00000  =  30.0   ← outercone           (문서 30.0)  ✅
mov dword [rdi+0x2f8], 0x40000000  =   2.0   ← density             (문서 2.0)   ✅
mov dword [rdi+0x2fc], 0x3f800000  =   1.0   ← volumetricsexponent (문서 1.0)   ✅
mov dword [rdi+0x300], 0x40400000  =   3.0   ← cascadedistance0    (문서 3.0)   ✅
```

키 문자열(`b'exponent'`)과 오프셋(`mov dword [rbx+0x34], 0x2ec`)도 별도로 확인했다.
**즉 이 발견의 근거는 문서가 아니라 실물 바이트다** — WE 의 `exponent` 기본값은 확실히 **2.0**
이고 Waple 의 폴백 `1` 은 그것과 다르다. (`+0x304 = 10.0` · `+0x308 = 100.0` 도 같은 블록에서 나왔고 **문서 표에 있다** —
`scene-lighting.md:85-86` 이 `cascadedistance1` 10.0 · `cascadedistance2` 100.0 로 적는다.
내 첫 추출 창이 표를 다 못 읽은 것이었다. 즉 **문서 표는 9/9 완전하고 전건 바이트와 맞는다** —
`radius` · `exponent` · `innercone` · `outercone` · `density` · `volumetricsexponent` ·
`cascadedistance0/1/2`.)

**이 대비가 이 발견의 핵심이다**: 같은 리포의 **RE 문서는 9/9 정확한데** 그것을 소비하는
**파서 폴백은 6/6 어긋난다.** 문서가 없어서 생긴 결함이 아니라, **있는 문서를 파서가 따르지
않은** 것이다 — 이 감사가 본 "정본 거짓"(문서가 낡음)과 정반대 방향이고, M20(`AudioSpectrum`
오프셋)과 같은 계열이다.

---

### 🟡 M26 — `pdataCoverage: 7748 / 14792 = 52.4%` 의 **분자가 분모의 부분집합이 아니다** — 실제 커버리지는 46.1%

- **자리**: `spec/engine/decompilation-provenance.json` `decomp.citedAddressClassification.pdataCoverage`
  (status **확정**) · 생성기 `scripts/spec/measure_decompilation_provenance.py`
- 발견 경로: 병렬 워크플로가 지목, 내가 앞서 측정한 값으로 검산했다.

문면: *"`7748 / 14792 = **52.4%**`. 디컴파일 산출물은 `.pdata` 함수 시작의 **절반쯤만 덮는다** —
'산출물에 없다' 가 '함수가 아니다' 를 뜻하지 않는 두 번째 이유다."*

**분자와 분모가 같은 모집단이 아니다.** 나는 이 감사 앞부분에서 이미 실측했다
(§4 독립 검증): manifest 의 7,748개 주소 중 **`.pdata` 함수 시작과 일치하는 것은 6,824개**이고
**924개는 `.pdata` 시작이 아니다**. 즉 7,748 은 "`.pdata` 시작 중 덮인 것" 이 아니라
"산출물 파일 수" 다.

| 세는 법 | 값 |
| --- | --- |
| 정본의 비 `7748 / 14792` | **52.4%** |
| 실제 `.pdata` 시작 커버리지 `6824 / 14792` | **46.1%** |
| 분모에 없는 분자 원소 | **924** |

**결론(교훈)은 그대로 유효하다** — "산출물에 없다고 함수가 아닌 것은 아니다" 는 참이고,
오히려 **더 강해진다**(덮인 비율이 절반보다 작다). 틀린 것은 비율과 "절반쯤" 이라는 표현이다.

**같은 항목이 이미 두 번 정정된 자리다** — `note` 가 *"종전 11205 는 폐기된 1세대 코퍼스
수치라 낡았다"*(2026-08-28)와 *"값은 맞았지만 **세는 법이 그 값을 내지 못했다**"*(2026-08-30)를
기록한다. 즉 값과 레시피를 두 차례 맞췄는데 **분자·분모의 모집단 일치**는 아직 안 맞았다.

---

### 🟡 M25 — `spec/engine/uniforms.json` 의 배열 유니폼 17행이 **선언 조각 문자열**을 `va` 로 가리킨다(127/144 는 정확하다)

- **자리**: `spec/engine/uniforms.json` `engine.uniforms`(status **확정**) — 17행
- 발견 경로: 병렬 워크플로가 지목, 내가 144행 전수를 바이너리와 대조해 범위를 확정했다.

그 항목의 evidence 는 *"wallpaper64.exe **문자열 전수 스캔**(PE 섹션 매핑 포함)"* 이므로
각 `va` 는 그 유니폼 **이름 문자열**의 주소여야 한다. 144행을 전수 검증했다:

| | 개수 |
| --- | --- |
| `va` 의 문자열이 **이름과 정확히 일치** | **127** ✅ |
| 이름이 아니라 **다른 문자열**을 가리킴 | **17** |
| `va` 가 섹션에 매핑되지 않음 | 0 |

17행의 정체는 전부 **배열 선언 조각**이다:

```
g_LPoint_Origin          0x140487665 -> "g_LPoint_Origin["
g_LDirectional_Direction 0x1404877ad -> "g_LDirectional_Direction["
g_LSpot_Exponent         0x1404876dd -> "g_LSpot_Exponent["
g_Bones                  0x1404875f3 -> "g_Bones["
g_Texture                0x14048d120 -> "g_Texture([\\d]+)"      ← 정규식 문자열
… (g_LPoint_Color · g_LSpot_* 4 · g_LTube_* 3 · g_LFeature_* 4 · g_LDirectional_Color)
```

**변호할 여지가 있다** — 이들은 실제로 **배열 유니폼**이고(`g_LPoint_Origin[0]` 꼴),
`g_Texture` 는 엔진이 정규식으로 번호를 뽑는 자리다. 즉 "그 유니폼을 가리키는 문자열" 로서는
틀리지 않다. **다만 나머지 127행과 규칙이 다르고**, 더 정확한 좌표가 실재한다 —
`.rdata` 에 **맨 이름 문자열이 따로 있다**(내가 찾았다):

```
g_Bones                  0x14048daf8      g_LPoint_Origin   0x14048db70
g_LDirectional_Direction 0x14048dcc8      g_LSpot_Exponent  0x14048dbc0
g_LTube_OriginA          0x14048dc38      g_Texture         (맨 이름 없음 — 정규식만)
```

**영향**: 낮다. 그러나 이 표는 "이 유니폼이 실물에 존재한다" 의 근거이고, 같은 표 안에서
**두 종류의 좌표가 섞여 있으면** 다음 사람이 `0x140487665` 를 떠 보고 "이름이 왜 `[` 로
끝나지?" 를 다시 조사한다. 규칙을 한 줄 적으면(배열 유니폼은 선언 조각을 가리킨다) 사라진다.

---

### 🟡 M24 — typecheck 수정의 주석이 "프론트엔드 진단은 전부 매치 ≥1" 이라 적지만 **넷 중 하나가 반례**다

- **자리**: `scripts/dev/macos-test-typecheck.sh` — 새 `rc != 0 && n == 0` 분기의 정당화 주석
- **상세**: 위 §"✅ `macos-test-typecheck.sh` …" 항목의 정정 블록에 실측 표가 있다.
- 요지: `-swift-version 9` · 없는 `-sdk` · 없는 입력 파일은 `': error:'` 를 내지만
  **잘못된 트리플은 `error: unknown target 'bogus-triple'`(접두사 없음)으로 매치 0** 이다.
- **영향**: 없음 — 오히려 **수정의 필요성을 강화**한다. 새 분기가 그 한 건을 잡는 유일한 그물이다.
  기록하는 이유는 "전부" 라는 전칭이 다음 사람에게 *"드라이버 오류만 조심하면 된다"* 로 읽히기 때문이다.
  (이 리포가 `docs/re/` 규약으로 세운 "전칭은 반례 하나로 무너진다" 를 그대로 적용한 결과다.)

---

### 🟡 M23 — Python 포트의 `MAX_DEPTH = 256` 가 **도달 불가**하다 — 깊은 괄호에서 `RecursionError` 로 측정 전체가 중단된다(Swift 원본은 우아하게 0 을 낸다)

- **자리**: `scripts/spec/measure_workshop_shaders.py:204`(`MAX_DEPTH = 256`) · `:244`(검사)
  vs 원본 `Sources/WapleCore/ShaderPreprocessor.swift:762`(`maxDepth = 256`) · `:769`
- 발견 경로: 병렬 워크플로가 지목, **내가 양쪽을 실행해 확인했다.**

**Python 포트 실측** — `eval_checked` 에 중첩 괄호를 먹였다:

```
depth  50: returned 1
depth 120: **RecursionError** (uncaught) — maximum recursion depth exceeded
depth 200: **RecursionError**
depth 400: **RecursionError**
```

**Swift 원본 실측** — 같은 입력을 `ShaderPreprocessor.preprocess` 에 먹였다:

```
depth  50: kept=true    depth 120: kept=true    depth 200: kept=true
depth 400: kept=false, dropped=false     ← 캡 초과를 0(거짓)으로 처리, 크래시 없음
```

**원본이 의도를 명시한다** — `ShaderPreprocessor.swift:769`:
`guard depth <= maxDepth else { return 0 }   // 캡 초과 — 그레이스풀 0(미정의 취급), 크래시 대신`.
즉 **Swift 는 "크래시 대신 0" 을 설계로 못박았고, 포트는 그 지점에 도달하기 전에
CPython 기본 재귀 한도(~1000 프레임)에 먼저 걸려 죽는다.** 파서가 프레임을 여러 개 쓰므로
괄호 깊이 ~120 에서 이미 터진다 — `MAX_DEPTH = 256` 은 **영원히 평가되지 않는 코드**다.

**영향**: 이 스크립트는 워크샵 코퍼스 4,991 셰이더를 훑는 생성기다. 그런 셰이더가 하나라도
있으면 **측정 런 전체가 예외로 중단**된다(`RecursionError` 를 잡는 자리는 `:1571` 의
`except Exception` 하나뿐이고 그것은 다른 경로다). 다만 **워크샵 코퍼스가 이 맥에 없어
실제로 그런 셰이더가 있는지는 확인 불가**이므로 medium 으로 둔다.

**포트 충실성 축과 맞물린다** — M16 이 지적한 대로 이 포트는 **Swift 와 대조된 적이 없다**
(`--selftest` 가 Swift 를 부르지 않는다). 이것이 그 미대조가 낳은 구체적 갈림의 첫 사례다:
같은 상수(256)를 적어 두고 **한쪽만 그 상수에 도달한다.**

---

### 🟡 M22 — 비둘기집 하한 산수가 **version 부재 3씬을 빼지 않았다** — 33/16/4/14 는 30/13/1/11 이어야 한다(정본에도 복제됨)

- **자리**: `Sources/WapleCore/SceneDocument.swift:3994-3998`(묘비 주석) ·
  `spec/corpus/scene-schema.json`(같은 수치가 `why` 필드에 복제)
- 발견 경로: 병렬 워크플로가 지적, 내가 재계산해 확인했다. **내가 앞서 "전건 일치" 로
  판정한 자리이므로 그 판정을 좁힌다.**

주석이 세는 법을 명시한다: *"`n − (v≥임계 씬수)` 를 뺀다."* 그런데 삭제된 게이트는
**version 이 없으면 아무것도 지우지 않았다**:

```swift
guard let v = schemaVersion else { return general }   // version 누락/비정수 → 무게이트
```

즉 `version: None` 3씬은 **게이트를 통과한** 쪽이므로 "게이트에 걸렸는데 키를 저작한" 하한
계산에서 **제외해야 한다**. 모집단은 `{5:63, 1:33, 4:32, 3:31, None:3}` = 162 이고:

| 키 | n | 주석 | 올바른 값 |
| --- | --- | --- | --- |
| `hdr` · `zoom` | 159 | 33 | **30** (159 − (126+3)) |
| `bloomtint` | 142 | 16 | **13** |
| `perspectiveoverridefov` | 130 | 4 | **1** |
| wind/gravity 5키 | 109 | 14 | **11** (109 − (95+3)) |

**게이트 철회 판정은 흔들리지 않는다** — 네 하한이 전부 양수라 반례 존재는 확정이다.
특히 `perspectiveoverridefov` 는 4 → **1** 로 줄지만 0 이 아니다.

**같은 수치가 정본에 복제돼 있다** — `spec/corpus/scene-schema.json` 의 `why` 필드가
*"비둘기집으로 **최소 33씬이 v3 미만인데 `hdr` 을, 최소 14씬이 v4 미만인데 wind 를 저작한다**"*
로 적는다. 즉 주석만의 문제가 아니라 **status 확정 정본의 서술**이다.

**성격**: M2·M12·M13 과 달리 이것은 **모집단 오독이 아니라 산식 오류**다 — 세는 법을
적었는데 그 세는 법 자체가 경계 사례(version 부재)를 빼먹었다. 이 리포의 규약("수는 세는
법과 함께 적는다")을 지켰기 때문에 **내가 그 산식을 읽고 반증할 수 있었다** — 규약이
작동한 사례이면서 동시에 규약만으로는 부족하다는 사례다.

---

### 🟡 M21 — `measure_material_schema.py` 가 산문에서 "줄 번호로 걸지 않는다" 를 선언하면서 **자기 evidence ref 는 줄 번호로 남겨 뒀다** — 그중 둘은 이미 드리프트했다

- **자리**: `scripts/spec/measure_material_schema.py` — 산문 툼스톤 `:1135`·`:1154`·`:1192`·`:1209`·`:1249`
  vs evidence ref `:1140`·`:1160`·`:1180`·`:1196`·`:1214`
- 발견 경로: 병렬 워크플로가 지목, 내가 각 ref 를 따라가 확인했다.

이 라운드가 그 파일의 산문 `위치` 필드를 **심볼 앵커로 바꾸고** 툼스톤 다섯 개를 달며
선언한다: *"…그것을 알 수 있었던 것은 근거를 따라가는 길뿐이었다. **앞으로도 줄 번호로
걸지 않는다.**"* 그런데 **같은 함수의 `specfmt.ev("file", …)` 근거는 줄 번호 그대로**다:

| evidence ref | 그 줄의 실제 내용 | 판정 |
| --- | --- | --- |
| `SceneRendererResources.swift:1422` | `return found` | ❌ 무의미한 자리 |
| `SceneDocument.swift:2324` | `}` (닫는 괄호) | ❌ 무의미한 자리 |
| `SceneRendererFrameEncoder.swift:1847` | 크로스페이드 게이트 주석 | ✅ 관련 있음 |
| `EffectManifest.swift:47` | `objects[].dependencies` 주석 | ✅ 관련 있음 |
| `SceneRendererResources.swift:754` | 오버라이드 주석 | ✅ 관련 있음 |

**5건 중 2건이 이미 드리프트했다**(HEAD 에서도 같으므로 이번 diff 가 만든 것은 아니다).

**게이트가 이것을 구조적으로 못 잡는다** — `validate.py:173-186` 의 검사는
`ref_max_line` 으로 **줄 번호가 파일 길이를 넘는지만** 본다:
*"파일이 존재하는데 그 줄이 없으면 그것도 근거를 따라갈 수 없는 정본이다"*.
즉 **범위 안이면 내용이 무엇이든 통과**한다. `return found` 나 `}` 를 가리키는 ref 는
영원히 조용하다.

**전 정본으로 넓혀 봤더니 이 파일 특유의 문제였다.** 줄 번호가 붙은 정본 evidence ref
**33건** 전수를 훑어 "가리키는 줄이 구조적으로 무의미한가" 를 셌다:

| | 개수 |
| --- | --- |
| 줄 번호가 붙고 범위 안인 evidence ref | **33** |
| 그중 무의미한 줄을 가리키는 것으로 **처음** 판정된 것 | 5 |
| 재검토 후 **거짓 양성**(실은 범위 인용 `:22-151`·`:18-25`·`:34-37` 등이고 내가 최대값만 봤다) | **5** |
| **실제 드리프트** | **2** — 둘 다 `measure_material_schema.py` 의 단일 줄 ref |

즉 `oracle.gate.*` 와 `deviation.D1/D2` 의 다섯 건은 **범위 인용이라 정상**이다
(`common_pbr.h:18-25` 는 `Distribution_GGX` 함수 전체, `:34-37` 은 `GeoSmith` 전체 —
닫는 `}` 가 범위의 끝일 뿐이다). **범위로 적은 인용은 드리프트에 강하다**는 것이
여기서 드러난다 — 이 리포가 권한 "식별자를 같이 적어라" 와 같은 효과다.

**M10 과의 차이**: M10 은 주석의 줄 번호가 밀린 것이고, 이것은 **정본의 `evidence` 필드**다 —
`spec/README.md` 규약 1번("모든 항목에 근거 필수")이 세운 신뢰의 근거 자체가 두 자리에서 끊겼다.
그리고 **같은 파일이 그 문제를 알고 산문은 고쳤는데 기계가 읽는 필드는 안 고쳤다**.

---

### 🟡 M20 — `AudioSpectrum.swift` 의 구조체 오프셋 인용 6곳이 **한 슬롯(−8) 밀려 있다**(정본이 옳고 소스가 틀렸다)

- **자리**: `Sources/WapleCore/AudioSpectrum.swift:59` · `:64` · `:69`(2건) · `:170` · `:214` · `:220`
- 발견 경로: 내가 정본의 명령 바이트를 검증하다 소스와 어긋나는 것을 발견했다.

같은 명령을 두 곳이 다르게 귀속한다. **바이트가 정본 편이다** — 생성자 네 줄을 직접 떴다:

```
0x1400c0d59  mov dword ptr [rdi + 0xec], 0x3e800000   ; exponent   0.25
0x1400c0d63  mov dword ptr [rdi + 0xf0], 0x3f004189   ; tiltC      0.5009999871253967
0x1400c0d6d  mov dword ptr [rdi + 0xf4], 0x41f00000   ; fftLength  30.0
0x1400c0d77  mov qword ptr [rdi + 0xf8], 0x41200000   ; binCount   10.0
```

| 상수 | 실제 오프셋(바이트) | 정본 | `AudioSpectrum.swift` |
| --- | --- | --- | --- |
| exponent | **+0xEC** | +0xEC ✅ | `:59` **+0xE4** ❌ |
| tiltC | **+0xF0** | +0xF0 ✅ | `:64` **+0xE8** ❌ |
| fftLengthFactor | **+0xF4** | +0xF4 ✅ | `:69`·`:214` **+0xEC** ❌ |
| binCountFactor | **+0xF8** | +0xF8 ✅ | `:69`·`:220` **+0xF0** ❌ |
| (묶음 시작) | — | — | `:170` **+0xE4** ❌ |

**전부 정확히 −8(한 슬롯) 밀렸다.** 명령 주소 인용(`0x1400c0d59` 등)은 **맞으므로**
값 자체는 옳게 이식됐다 — 실제로 `exponent = 0.25` · `tiltC = 0.50099998712539673` ·
`referenceFFTLength = 1920`(= 30 × 64) 이 전건 바이트와 일치한다(내가 float 디코드로 확인).

**영향**: 실동작 0(주석). 그러나 이 오프셋들은 **런타임 구조체를 디버거로 들여다볼 때의
좌표**이고, `:170` 은 *"같은 호출이 넘기는 `rcx=0x1404e568c` 가 정확히 `AP+0xE4`(상수 4개 묶음)다"*
라며 **교차 확인 근거로** 쓴다 — 그 교차 확인이 −8 로 맞춰져 있으면 다음 사람이
`0x1404e568c` 를 잘못된 필드에 대응시킨다.

**값 이식은 완전하다(확인함)** — 오프셋만 틀렸고 산술은 전건 맞는다:

```
0x1404928e4 = 64.0 (실측 f32)   →  N = 30.0 × 64 = 1920 ✅ (referenceFFTLength = 1920)
                                  B = 10.0 × 64 =  640 ✅ (주석의 "B = int(10 × 64) = 640 고정")
10.0 / 30.0 = 0.3333333…        ✅ (`divss xmm10, xmm12` 주석과 일치)
```

즉 `AudioSpectrum` 은 **옳은 상수로 옳은 값을 만든다.** 틀린 것은 그 상수가 구조체
어느 필드에 사는지의 표기뿐이다.

**M20 이 M15·M16 과 다른 점**: 이것은 도수가 아니라 **좌표**이고, 정본이 옳고 소스가 틀린
**반대 방향**이다(보통은 정본이 낡는다). 즉 `spec/` → 소스 방향의 동기화도 빠질 수 있다.

---

### 🟡 M19 — RE 리포의 `corpus_scan/mdl-format.md` 가 v≥23 레코드를 아직 "bone-binding · **[UNRESOLVED]**" 로 적는다 — Waple 쪽은 이미 **모프/마스크**로 확정했다

- **자리**: `Waple-wallpaper-source/corpus_scan/mdl-format.md:72`(스트림 서술) · `:89`(게이트 표) ·
  `:284-287`(Open question 7)
- 발견 경로: 병렬 워크플로가 지목, 내가 양쪽 문서를 대조해 확인했다.

**RE 리포 쪽**(실측 인용):

```
:72   u32 n -> n × bone-binding record       only if version >= 23
:89   | v23 bone-binding records | version >= 23 | decompiled :345 |
:286  7. **[UNRESOLVED]** The v23 bone-binding record body: the framing
      {u64; cstr; u32; u32 k -> k×u32; u32 m -> m×u32} makes all 28 files land exactly
      on EOF, but the record count is 0 in every one of them, so the body has never
      actually been exercised.
```

**Waple 쪽은 같은 구조를 이미 해소했다** — `Model3D.swift:219-225`:

> *"v≥23 **모프/마스크** 레코드 — 스트림: `u64 id | cstring name | u32 flags | u32 n1 | n1×u32 |
> u32 n2 | n2×u32`(어셈블리 `0x140261be0-0x140262013`) … 실물 12파일: name 은 전부
> `"masks/clipping_mask_*"`. 모프 렌더 소비는 범위 밖 — 파스·보존."*

**프레이밍이 글자 그대로 같다**(`u64; cstr; u32; u32 k→k×u32; u32 m→m×u32`)
— 즉 RE 문서의 Open question 7 은 **형제 리포에서 이미 답이 나와 있다.**
이름도 "bone-binding" 이 아니라 모프/마스크가 맞다(실물 name 이 `masks/clipping_mask_*`).

**두 문서가 모순은 아니다 — 모집단이 다르다(확인함)**: RE 문서의 "28 files 전건 count 0" 은
**설치본** `.mdl` 28개 기준이고, Waple 의 "실물 12파일" 은 **워크샵 코퍼스** 기준이다.
내가 설치본 28개를 훑으니 `masks/clipping_mask` 문자열이 **0건**이라 양쪽이 정합한다.
즉 RE 문서는 "우리 표본에서는 안 쓰인다" 로 옳고, **Waple 이 다른 표본에서 답을 찾은 것을
반영하지 못한 것**이 결함이다.

**영향**: 낮다(문서). 그러나 `[UNRESOLVED]` 는 다음 사람이 **같은 조사를 다시 하게** 만들고,
"bone-binding" 이라는 잘못된 이름은 그 조사를 엉뚱한 방향(스키닝)으로 보낸다.
M7(디컴파일 실패 3건 미기록)과 같은 계열 — **한쪽 리포의 진전이 다른 쪽에 반영되지 않는다.**

---

### 🟡 M18 — BACKLOG 가 어떤 항목을 **틀린 이유로** 닫았다("좌표가 애초에 죽어 있었다" → 실제로는 정확했다)

- **자리**: `BACKLOG.md:87-97` (커밋되지 않은 변경이 이 항목을 닫는다)
- 발견 경로: 병렬 워크플로가 지목, 내가 git 이력으로 확인했다.

닫는 근거로 이렇게 적는다: *"이 항목은 **좌표와 대상이 둘 다 죽어 있었다.**
`:55` 는 `CommitDebouncer.cancel()` 의 닫는 `}` 이고(**애초에** view struct 밖이다)"*.

**git 이력이 반박한다.** 그 항목이 쓰인 시점(`70b64631`·`e6803028`, 둘 다 2026-07-13)의
`Sources/Waple/PropertyEditorView.swift:55` 를 꺼내 보면:

```swift
55:        .onChange(of: focusedText) { newValue in        ← 1-파라미터 deprecated 형태
```

**정확히 그 항목이 지목한 대상이다.** "애초에 view struct 밖" 이 아니었다 —
`:55` 가 `CommitDebouncer.cancel()` 의 닫는 `}` 이 된 것은 **그 뒤 파일이 바뀌어서**다
(현재 `:55` 는 `}` 다 — 확인).

**닫는 판정 자체는 옳다** — `0280ab6a` 가 실제로 그 줄을 고쳤다:

```
-        .onChange(of: focusedText) { newValue in
+        // F501: 1-파라미터 onChange(of:perform:) 는 macOS 14 에서 deprecated — 2-파라미터 신형으로.
+        .onChange(of: focusedText) { _, newValue in
```

즉 **결함은 실재했고 해소됐다.** 틀린 것은 *닫는 이유*다 — "인용이 애초에 무효였다"(따라서
과제 자체가 허깨비였다)와 "인용이 옳았고 그 결함을 고쳤다"(따라서 과제가 완료됐다)는
전혀 다른 기록이다. 전자는 **다음 사람에게 그 항목이 존재한 적 없다고 가르친다.**

**뿌리는 M10 과 같다** — 줄 번호가 드리프트한 뒤 그것을 "원래 틀렸다" 로 해석한 것이다.
`docs/README.md` 가 세운 규약("인용은 드리프트한다 — 식별자로 grep 해라")을 적용하면
`onChange(of: focusedText)` 로 찾아 옛 위치를 복원할 수 있었다.

---

### 🟡 M17 — 새 Schlick 오라클의 정규식이 **우측 미앵커**라, WE 헤더에 항이 붙어도 통과한다

- **자리**: `Tests/WapleCoreTests/SceneWELightMathTests.swift:200-207` (`schlickKMapping`)
- 발견 경로: 병렬 워크플로가 지목, 내가 정규식을 실행해 확인했다.
- **맥락**: 이 오라클은 이 라운드가 **개선한** 자리다(자기 구현끼리 비교 → WE 원문 헤더 파싱).
  방향은 옳고, 남은 것은 그 파싱의 엄격성이다.

두 정규식이 **오른쪽 경계를 잡지 않는다**(`;` 도 `$` 도 없다):

```
kPattern    : \broughnessScaled\s*=\s*\(?\s*(\w+)\s*\*\s*\1\s*\)?\s*/\s*([0-9.]+)
basePattern : \broughnessBase\s*=\s*roughness\s*\+\s*([0-9.]+)
```

**실행으로 확인했다** — 원문을 변조해 항을 덧붙여도 같은 값을 뽑는다:

| 입력 | 추출된 `divisor` / `addend` | 매치 |
| --- | --- | --- |
| 원문 `(rb*rb) / 8.0;` | 8.0 / 1.0 | ✅ |
| `… / 8.0 **+ 99.0**;` | **8.0 / 1.0**(동일) | ✅ 통과 |
| `roughness + 1.0 ***  7.0**;` | **8.0 / 1.0**(동일) | ✅ 통과 |

즉 **WE 가 헤더 식을 바꿔 항을 추가하면 이 오라클은 그것을 못 본다.** 지금은
`ScenePBRLighting` 과 원문이 실제로 일치하므로(내가 §에서 확인) **거짓 초록은 아니지만**,
이 오라클의 존재 목적("WE 판올림으로 식이 바뀌면 잡는다")이 **부분적으로만 달성**된다.

**영향**: 낮다. 다만 이 자리는 "자기 구현끼리 비교하던 것을 원문 대조로 바꾼" 개선의
마지막 한 걸음이 남은 곳이다 — 우측에 `\s*;` 나 줄 끝 앵커를 붙이면 닫힌다.

---

### 🟡 M16 — `measure_workshop_shaders.py` 가 **한 파일 안에서 자기 전제를 반박한다**(":12 툴체인 없다" ↔ ":1280 그건 거짓이다")

- **자리**: `scripts/spec/measure_workshop_shaders.py:12`(머리말) vs 같은 파일 `:1280`(정정문)
- 발견 경로: 병렬 워크플로가 지목, 내가 두 줄과 실제 툴체인으로 확인했다.

머리말 「왜 포트인가」가 이 스크립트의 존재 이유를 이렇게 적는다:

> `:12` — *"**이 머신엔 Swift 툴체인이 없어** Waple 을 실행할 수 없다. 그래서 거부 판정 경로만
> (`ShaderPreprocessor.preprocessStrict` + `ExprEval.evalChecked`) Python 으로 1:1 포팅하고…"*

같은 파일 `:1280` 이 그 문장을 **취소선으로 부정한다**:

> *"**[정정 2026-08-30]** … ① ~~"이 머신엔 Swift 툴체인이 없다"~~ — 이 값이 기록된 2026-08-01
> 시점에는 맞았지만 **지금은 아니다**(`xcode-select -p` = Xcode 27.0 Beta 5,
> `swift --version` = 6.4)."*

**실측으로 확인**: 툴체인은 실재한다(Xcode 27.0 Beta 5 · Swift 6.4 — 이 감사가 3,886개
테스트를 실제로 돌린 그 툴체인이다). 그리고 `:12` 는 **HEAD 와 바이트 동일**이라
이번 diff 가 쓴 문장이 아니다 — 즉 **정정은 새로 넣었는데 정정 대상 문장은 그대로 남겼다.**

**같은 정정문이 더 무거운 것도 적는다**: ②
*"~~Swift 회귀테스트의 기대값으로 포트를 검증했다~~ — `--selftest` 는 Swift 를 **한 번도
부르지 않았고**, 이식본을 자기 자신이 적어 둔 기대값과 대조했을 뿐이다."*
즉 이 Python 포트는 **Swift 원본과 대조된 적이 없다.** 툴체인이 이제 있으므로
그 대조는 **지금 가능하다** — 그것이 이 항목의 실질적 가치다.

**영향**: 스크립트 동작에는 영향 없다(주석). 그러나 ① 머리말은 파일을 여는 사람이 가장 먼저
읽는 자리이고, ② "툴체인이 없으니 포팅이 불가피하다" 는 **설계 정당화**가 이제 성립하지
않으므로 그 판단을 다시 볼 근거가 된다. M15 와 같은 계열(같은 리포 안 자기모순)이다.

---

### 🟡 M15 — `AGENTS.md` 가 "단언 15건" 을 **거짓 불변성 논거**로 방어한다(그 값은 14 에서 15 로 이미 변했다)

- **자리**: `AGENTS.md:538-541`
- 발견 경로: 병렬 워크플로가 지목했고, 내가 git 이력으로 확인했다.
  **내가 앞서 "이 절의 수치 전건 정확" 으로 판정한 자리이므로 그 판정을 좁힌다.**

문면: *"그 셋의 `XCTAssertTrue(…isPlaying…)` 단언은 **15건**이고 … 즉 **"단언 15건" 은 지금도
맞다**(우연이 아니라, 늘어난 넷이 `XCTAssertFalse` 쪽 단언을 가진 테스트라서 그렇다)."*

**git 이력으로 검증했다** — 그 문단이 이름을 대는 커밋 `fb5a913f`(2026-08-25)에서 세면:

| | `fb5a913f` | 현재 | 변화 |
| --- | --- | --- | --- |
| 게이트 사이트 | **12** | **16** | +4 |
| `XCTAssertTrue(…isPlaying…)`(게이트 3파일) | **14** | **15** | **+1** |
| ├ `SceneAudioPlayerTests` | 11 | 12 | +1 |
| ├ `SceneEventHookTests` | 2 | 2 | ±0 |
| └ `SceneInteractionMediaE2ETests` | 1 | 1 | ±0 |

**두 가지가 틀렸다**:
1. **"15 는 지금도 맞다"** — 원래 값은 **14** 였다. 15 는 *변한 뒤의* 값이므로 "여전히 맞다"
   가 성립하지 않는다(값이 유지된 것이 아니라 한 번 올랐다).
2. **제시된 기전** — "늘어난 넷이 `XCTAssertFalse` 쪽이라서 15 가 유지됐다" 는 설명은
   사이트 +4 와 단언 +1 을 동시에 설명하지 못한다. 실제로는 `SceneAudioPlayerTests` 에서
   `XCTAssertTrue(…isPlaying…)` 이 **1건 늘었다.**

**아이러니가 이 항목의 핵심이다.** 같은 문단이 그 위에서 이렇게 선언한다 —
*"**그래서 값을 다시 박지 않는다 — 세는 법을 적는다**(이 파일이 테스트 개수에 대해 이미 채택한
규약과 같다 … \"기준값을 여기 적었더니 또 썩었다\")."* 그 규약을 선언한 **바로 다음 문단이
값을 박고**, 그것을 불변이라고 방어했다. `grep` 레시피를 함께 적어 둔 덕분에 내가 검산할 수
있었다는 점에서 규약의 절반은 작동했다.

**영향**: 낮다(도수 서술이며 게이트가 아니다). 그러나 이 파일은 "코드 만지기 전 필독" 이고,
"이 수는 변하지 않는다" 는 서술은 다음 사람이 재측정을 건너뛰게 만든다 —
`ci.yml` 의 테스트 개수 하한이 **정확히 그 이유로** 트립와이어로 재설계된 이력이 있다.

---

### 🟡 M13 — `HDRBloomPass.swift:5` 의 "`hdr && bloom` 씬(코퍼스 **8**)" 은 **어느 모집단으로도 나오지 않는 수**다

- **자리**: `Sources/WapleRender/HDRBloomPass.swift:5` (파일 머리말 — 이 패스의 존재 이유를 적는 줄)
- 발견 경로: 병렬 워크플로가 지목, 내가 세 모집단으로 재현 시도해 확인했다.

그 줄은 이 패스가 언제 쓰이는지를 규정한다:
`/// HDR bloom(#22) 파라미터 — hdr && bloom 씬(코퍼스 8) 전용.`

**세 가지 세는 법으로 다 세어 봤다 — 8 은 없다**:

| 모집단 | 씬 수 | `hdr && bloom` |
| --- | --- | --- |
| 설치본 `assets/` + `projects/` (정본의 단일 모집단) | 186 | **3** |
| 동봉 `WEAssets` 만 | 172 | **1** |
| 동봉 + 설치본 (폐기된 이중계수) | 358 | **4** |

**어느 쪽도 8 이 아니다.** 정본은 3 을 못박고(`tonemapping.json` `corpusReach`
= `{HDR + bloom on: 3}` · `hdrScenesNote` = "고유 HDR 씬은 3개"),
`ToneMappingCanonTests` 가 기계로 그것을 잠근다. `docs/re/scene-postprocessing.md:87` 은
**4**(폐기된 358 기준)로 적는다.

**워크샵 모집단도 확인했다 — 거기서도 8 이 아니다.** `spec/corpus/scene-schema.json` 은
워크샵 162 중 `hdr` 저작 159(`True` **16**) · `bloom` 162(`True` **24**) 로 적는데,
**결합 도수(`hdr && bloom`)를 기록하지 않는다.** 16 과 24 의 교집합이 8 일 가능성은
논리적으로 남지만 **어느 정본·문서도 그 수를 적지 않으므로 근거가 없다** —
그리고 이 주석의 문맥(`HDRBloomPass` = 이 패스가 쓰이는 씬)은 실제 렌더 대상이므로
워크샵이 아니라 실측 가능한 모집단(3)이어야 자연스럽다.

즉 **정본·테스트·내 실측이 3, 문서가 4(폐기 기준), 이 주석만 8** 이다.

**영향**: 픽셀에는 영향 없다(도수 서술일 뿐, 패스 동작은 씬별 플래그로 갈린다).
그러나 이 줄은 **"이 패스가 3개 씬에만 쓰인다"** 는 우선순위 판단의 근거이고,
8 이면 실제보다 2.7배 중요해 보인다. **8 은 이중계수로도, 워크샵 기록으로도 설명되지 않아
출처가 불명이다** — 더 이른 시점의 모집단이거나 단순 착오로 보인다.
**심각도는 낮다**(도수 서술이고 픽셀 영향 없음). 기록하는 이유는 M14 를 철회하게 만든 것과
같은 교훈이다 — **"코퍼스" 라고만 적으면 어느 수도 검산할 수 없다.**

---

### 🟡 M12 — `CAST3X3` 도달 열거표가 **두 모집단을 한 표에 섞고**, 동봉만으로도 `g_Bones` 도수가 틀렸다

- **자리**: `Sources/WapleCore/GLSLTranslator.swift:2237-2242` (커밋되지 않은 변경이 추가한 주석)
- 발견 경로: 병렬 워크플로 2레인이 독립적으로 지목했고(`core-glsl-2` · `core-glsl-3`), 내가 계수로 확인했다.
- **상세와 실측 표는 위 §"✅ `CAST3X3` 이탈 기록이 모범적이다" 항목의 인용 블록에 있다.**

요지: 범위를 "동봉 WEAssets 502 셰이더 **+ 형제 코퍼스**" 라 선언했는데
행렬 인자 도수(`14 · 40 · 5 · 3 · 1`)는 **동봉만** 센 값이고, 같은 표의 스칼라 1건은
**형제에만** 존재한다. 게다가 동봉만으로도 `g_Bones[…]` 는 **48**(주석 40)이다.

**결론(도달 0 · 값 유지)은 영향받지 않는다** — 스칼라 인자가 전 코퍼스 1건이고 그것이
동봉되지 않았다는 사실은 내가 따로 확인했다. 틀린 것은 **검산용 도수표**이고,
그래서 다음 사람이 그 grep 을 돌리면 어떤 범위로도 표를 재현할 수 없다.

**뿌리는 M2 와 같다** — 동봉 `WEAssets` 가 설치본 `assets/` 의 사본(경로집합 2,940 동일,
내용 동일 — 내가 파일 단위로 증명)이라, 두 트리를 합쳐 세면 모든 도수가 정확히 2배가 된다.
이 라운드가 M2 에서 그 함정을 적발하면서 같은 주석 블록에서 다시 밟았다.

---

### 🟡 M11 — 정본 근거의 **55%(661/1,211)가 검증 범위 밖**이고, 그중 349건은 짝 저장소에 **실재하는데도** 검사되지 않는다

- **성격**: 게이트 커버리지의 구조적 구멍. 개별 값이 틀렸다는 발견이 아니라
  **"근거 필수" 규약이 절반만 집행된다**는 발견이다.

`spec/README.md` 규약 1번은 "모든 항목에 근거 필수 — 없으면 검증기가 거부한다" 다.
검증기가 실제로 무엇을 거부하는지 세어 봤다(`validate.py` 의 `repo_ref_path` 를 직접 호출):

| 분류 | 개수 |
| --- | --- |
| 리포 상대경로 → `os.path.exists` 로 **실제 검사됨** | **550** |
| 리포 밖을 가리켜 **`None` 반환 → 검사 생략** | **661** |
| 합계 | 1,211 |

`repo_ref_path` 는 `REPO_PREFIXES` 로 시작하지 않는 ref 에 `None` 을 돌려주고(`:81-82`),
호출부는 `rel is not None` 일 때만 존재를 확인한다(`:165`). **즉 55% 는 문자열로만 존재한다.**

**그중 349건은 짝 저장소에서 실제로 열린다** — 즉 검증 불가가 아니라 **검증하지 않는 것**이다:

| 짝 저장소에 실재하는 대상 | 그것을 근거로 삼는 ref 수 |
| --- | --- |
| `wallpaper64.exe` | **236** |
| `bin/scenescript64.dll` | 25 |
| `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` | 20 |
| `bin/wallpaperui.exe` | 14 |
| `assets/scripts/jsclasses/baseclasses.js` | 8 |
| `bin/resourcecompiler64.exe` · `resourceutil64.dll` · `webwallpaper64.exe` 등 | 17 |

나머지 310건은 실제로 검증 불가한 부류다(산문 · 저자 Windows 경로 · VA 좌표만 · 워크샵 코퍼스).

**왜 이것이 위험한가**: 이 감사에서 **정본 밖 인용이 낡은 사례를 이미 4건 찾았다** —
H2(모집단 62 vs 66) · M2(폐기된 358) · M5(README 셰이더 줄) · M10(같은 파일 줄 드리프트).
그리고 `spec/engine/mul-convention.json` `mul.shim`(status **확정**)의 evidence 하나는
`wallpaper_dev/references/…/analysis/deep/lanes/A4-headers-blending-fog.md §1.4` 를 가리키는데
**그 경로는 어디에도 없다**(짝 저장소·이 리포·`~/Downloads` 전부 확인). 검증기는 이 ref 가
리포 밖이라 `None` 으로 넘기므로 **영구히 조용하다.**

**정황 참작**: `spec/README.md` 는 "`spec/` 의 evidence 중 `analysis/`·`corpus_scan/` 을
가리키는 것은 **0건**" 이라고 적고, 그 주장은 **접두사 기준으로는 맞다**(위 ref 는
`wallpaper_dev/…` 로 시작한다). 즉 규약을 우회할 의도는 없어 보이고, **접두사로만 판정하는
것의 한계**가 드러난 것이다.

**중요 — 검증되지 않는다고 틀린 것은 아니다. 표본으로 증명했다.**
그 236건 중 30건은 **함수 본문 SHA256[:16] 지문**을 함께 적는다(WE 판올림 감지용).
하나를 골라 원본 바이너리에서 재계산했다 — `spec/engine/render-state.json` 의
`renderState.blend.*` 4항목이 공유하는 `wallpaper64.exe FUN_140099f60 @ 0x140099f60
(본문 SHA256[:16]=c90ef09b71f93e3b)`:

```
.pdata 를 파싱해 인접 청크를 병합(생성기 measure_render_state.py:89-97 과 같은 규칙):
  FUN_140099f60 병합 범위 0x140099f60–0x14009a358  len=1016
  sha256[:16] = c90ef09b71f93e3b
  정본 주장   = c90ef09b71f93e3b     → 완전 일치 ✅
```

**병합 없이는 재현되지 않는다** — 병합 전 `.pdata` 첫 청크는 18바이트뿐이고
SHA 가 `c933f7e9a46f9652` 로 어긋난다. 즉 이 지문은 **생성기의 정확한 레시피를 따라야만**
재현되고, 따라 하면 **바이트 단위로 맞는다.** 정본의 이 근거는 진짜다.

**전수로도 확인했다 — 정본이 인용하는 바이너리 주소 1,778개 중 어긋난 것은 0 이다.**
정본 JSON 전체에서 `0x140xxxxxx` 꼴 VA 를 뽑아 실물 PE 섹션 범위와 대조했다:

| | 개수 |
| --- | --- |
| 정본이 인용하는 고유 VA | **1,778** |
| `wallpaper64.exe` 이미지 안에 든다 | **1,768** |
| 그 밖 | 10 |
| (안에 드는 것 중 `.pdata` 함수 시작과 정확히 일치) | 170 |

**그 10건도 오류가 아니다** — 전부 **다른 바이너리**를 가리킨다.
`spec/formats/pkg.json` 이 그것을 명시한다("`wallpaperui.exe 0x14020a660`" ·
"`wallpaperui.exe 0x1408e72b0`" 등). `binaries/wallpaperui.exe`(12,742,640 B)로 다시
대조하니 **8/8 이 그 이미지 안에 든다**(나머지 2건은 **내 정규식의 문제였다**: `0x140000000` 은
`spec/binaries-fingerprint.json` 이 선언하는 **이미지 베이스 자체**이고, `0x14049262` 는
실제 인용이 9자리 `0x14049262c` 인데 내 패턴이 8자리에서 끊은 것이다 — 그 전체 주소는
`.rdata` 안에 정상적으로 든다).

**즉 정본이 인용하는 바이너리 좌표 1,778건 중 실제 오류는 0 건이다.**

즉 **정본의 바이너리 좌표는 전수로 실물과 정합한다.** SHA 지문 4건도 전건 일치(위).

**따라서 M11 은 "근거가 틀렸다" 가 아니라 "근거가 검사되지 않는다" 다.** 위험은
지금 값이 아니라 **WE 판올림·재생성 때 조용히 썩는 것**이고, 실제로 그 부류가 이번에 4건
나왔다(H2·M2·M5·M10). 지문이 있는 30건은 특히 아깝다 — 검사 코드 한 줄이면 판올림을 잡는다.

**고칠 방향(적기만 한다)**: 짝 저장소 경로에 환경변수(`WE_SIBLING` 등)를 주고
349건을 검사 대상에 넣으면, 실재 파일에 대한 근거만으로도 커버리지가 550 → 899(74%)로 오른다.
바이너리 오프셋·VA 인용은 `check_address_ranges.py`·`check_cited_address_census.py` 가
이미 다루는 축이므로 중복이 아니다.

---

### 🟡 M10 — 새로 추가된 주석들이 **자기 diff 가 밀어낸 줄 번호**를 인용한다(같은 파일 안, 기계적 오류)

- **성격**: 정본 거짓의 가장 사소하지만 가장 재현성 높은 형태. 커밋 전에 기계적으로 잡을 수 있다.
- 발견 경로: 병렬 워크플로가 3레인에서 독립적으로 지목했고(`core-glsl-1` · `core-scene-3` ·
  `spec-json-3`), 내가 A/B 로 확인했다.

`ShaderPreprocessor.swift` 의 새 주석(H1 탭 지시문 정정)은 인식 검사 6자리를 줄 번호로 인용한다.
**그 번호들은 HEAD 에서는 정확했고, 같은 diff 가 그 위에 26줄을 넣어 전부 무효가 됐다**:

| 주석의 인용 | HEAD 에서 그 줄 | 작업 트리에서 그 줄 | 실제 현재 위치 |
| --- | --- | --- | --- |
| `:282` `#if `/`#ifdef `/`#ifndef ` | ✅ `hasPrefix("#if ") \| hasPrefix("#ifdef ")…` | ❌ `guard let n = rest.dropFirst…` | **305** |
| `:308` `#elif ` | ✅ `} else if t.hasPrefix("#elif ")` | ❌ `if t.hasPrefix("#if ") \| …` | **334** |
| `:326` `#else ` | ✅ `} else if t == "#else" …` | ❌ 주석 줄 | **352** |
| `:333` `#endif ` | ✅ `} else if t == "#endif" …` | ❌ `stack.append(Frame(…))` | **359** |
| `:386` `#undef ` | ✅ `} else if t.hasPrefix("#undef ")` | ❌ 다른 주석 | **416** |
| `:396` `#define ` | ✅ `} else if t.hasPrefix("#define "), emitting()` | ❌ 다른 주석 | **426** |

**6/6 이 HEAD 기준이고 6/6 이 현재 틀리다.** 편차는 +23~+30 으로, diff 가 삽입한 주석 줄 수와 일치한다.

**같은 양상이 다른 파일에도 있다**(워크플로 지목): `GLSLTranslator.swift` 의 새 인용 3건,
`SceneDocument.swift` 의 새 H1 주석 블록. 반면 **다른 파일을 가리키는 인용은 멀쩡하다** —
`SceneDocument:4006` 의 `SceneRenderer.swift:1739/1747/1759/1865/2439` 는 전건 정확했다(확인).
즉 이 오류는 **"같은 파일 안에서 자기 위에 줄을 넣었을 때" 만** 난다.

**이 리포는 이 함정을 이미 알고 규약을 세웠다** — `docs/README.md`:
*"인용할 때는 줄번호만 적지 말고 식별자나 코드 조각을 같이 적어라. 줄번호는 썩지만
식별자는 안 썩는다."* 이 주석들은 **식별자를 같이 적었기 때문에**(`#if `/`#elif ` 리터럴)
내가 실제 위치를 즉시 찾을 수 있었다 — 규약이 절반은 작동한 셈이다.
남은 절반(줄번호를 아예 빼거나 커밋 직전에 갱신)이 안 지켜졌다.

**고칠 방향**: 커밋 직전에 같은 파일 인용을 재계산하는 것이 유일하게 확실하다.
이 부류를 잡는 게이트는 없다(`check_address_ranges.py` 는 **바이너리 VA** 인용만 본다).

---

### 🟡 M9 — 버전 게이트 철회 주석이 `perspectiveOverrideFov` 을 "실렌더 소비처가 있다" 에 넣었다 — 그 소비처는 **프로덕션에서 호출되지 않는다**

- **자리**: `Sources/WapleCore/SceneDocument.swift:4005-4010`(커밋되지 않은 변경의 묘비 주석)
- 발견 경로: 이 감사의 병렬 워크플로가 먼저 지목했고, 내가 실측으로 확인했다.

주석은 게이트 철회의 심각도 근거로 **v3+ 아홉 키에 실렌더 소비처가 있다**고 열거한다:

| 인용 | 실측 | 판정 |
| --- | --- | --- |
| `SceneRenderer.swift:1739` `doc.hdr` → `HDRPostPass` | `if doc.hdr, let post = HDRPostPass(...)` | ✅ 살아 있다 |
| `:1747` `sceneWantsLDRBloom = doc.bloom && !doc.hdr` | 그대로 | ✅ |
| `:1759` `sceneWantsHDRBloom = doc.hdr && doc.bloom` | 그대로 | ✅ |
| `:1865` `sceneZoom` | `sceneZoom = doc.zoom` | ✅ |
| `:2439` `sceneZoom` 사용부 | `general.zoom 씬 전역 프레이밍` | ✅ |
| **`CameraMotion.swift:370-371` `perspectiveOverrideFov`** | 줄 번호는 정확하지만 **호출부가 테스트뿐** | ❌ |

`CameraMotion.effectiveFovDegrees(orthographic:fov:perspectiveOverrideFov:)` 의 참조를
전수 조사하면:

```
Sources/WapleCore/CameraMotion.swift:369   선언
Tests/WapleCoreTests/CameraMotionTests.swift:134,136   호출 2건
→ Sources/** 안의 호출 0건
```

즉 **프로덕션 렌더 경로가 이 함수를 부르지 않는다.** `perspectiveOverrideFov` 는
`SceneDocument:4062` 에서 파싱돼 저장되지만(`:1526` 기본값 95) 그 값을 픽셀로 옮기는
경로가 없다 — wind/gravity 다섯 키와 **같은 부류**(파스·보존 전용)인데 주석은 그것을
"실렌더 소비처가 있는" 쪽에 넣었다.

**영향**: 게이트 철회의 **결론은 바뀌지 않는다** — `hdr`·`zoom` 만으로도 실렌더 영향이
확정되고(위 5건 확인), 비둘기집 산수도 옳다(§검증 통과 항목). 틀린 것은 **아홉 키 중 하나의
분류**이고, 그 결과 "이 키가 배선돼 있다" 고 믿는 다음 사람이 헛발질한다.
`orthographic` 분기(`0x140189286 test r9b,8`)를 실제로 배선할 때 이 주석이 "이미 됐다" 로 읽힌다.

---

### 🟡 M8 — 화면보호기가 `startAnimation` 마다 플레이어를 **통째로 재생성**한다(커버리지 0 인 타깃, 증상은 미실측)

- **자리**: `Sources/WapleSaver/WapleSaverView.m` — `startAnimation`(`loadContent` 무조건 호출)
- **성격**: 실동작 결함. `WapleSaver` 는 **SwiftPM 밖**이라 `swift test` 커버리지가 **0** 이고
  (`AGENTS.md` 모듈 지도가 그렇게 적는다), CI 도 컴파일만 한다. 즉 이 결함을 잡을 그물이 없다.

```objc
- (instancetype)initWithFrame:… { … [self loadContent]; }      // ① 생성 시 로드

- (void)startAnimation {
    [super startAnimation];
    [self loadContent];   // ② 시작 시 **또** 로드 — tearDownContent 로 플레이어를 버리고 새로 만든다
    [self.player play];
}
```

`loadContent` 의 첫 줄이 `[self tearDownContent]` 다 — 옵서버 해제 · `player` nil ·
`playerLayer` 제거. 즉 **① 에서 만든 플레이어를 ② 가 즉시 버린다.**

**증상 두 가지**:
1. **되감김** — 화면보호기가 멈췄다 다시 시작할 때마다(`stopAnimation` → `startAnimation`,
   예: 미리보기↔전체화면 전환, 시스템이 세션을 재개할 때) 재생 위치가 **0 으로 돌아간다.**
   `stopAnimation` 은 `pause` 만 하므로 위치가 보존되는데, `startAnimation` 이 그것을 버린다.
2. **불필요한 재생성 비용** — `AVPlayerItem`·`AVPlayer`·`AVPlayerLayer` 를 매번 새로 만들고
   `NSNotificationCenter` 옵서버를 다시 등록한다. 디코더 재초기화라 첫 프레임이 늦는다.

**주석은 의도를 적는다** — *"시작 시 재로드 — 앱에서 배경을 바꿨어도 최신 경로를 반영"*.
의도는 타당하지만 **경로가 안 바뀌었을 때도 재생성한다.** 최소 수정은 현재 경로와
비교해 같으면 `loadContent` 를 건너뛰는 것이다(수정 금지 지시에 따라 적기만 한다).

**정직한 검증 경계 — 두 층이 다 막혔다.**

① **화면보호기 자체를 못 돌린다**: `.saver` 번들 설치 + 실제 화면보호기 기동이 필요하다.

② **AVPlayer 거동만 따로 재려고 시도했고, 그것도 실패했다.** 코퍼스에 `mp4`/`mov` 가
**0건**이라(있는 것은 `webm` 165개 — AVFoundation 이 안 읽는다) `AVAssetWriter` 로 3초
H.264 mp4 를 합성해서 프로브를 돌렸다. 결과:

```
PROBE asset duration = 3.0                 ← 파일은 정상이다
PROBE item.status=0 after 5.05s            ← readyToPlay(1) 에 끝내 도달하지 않는다
PROBE t_after_play=0.000 t_after_pause=0.000 t_after_resume=0.000
→ 판정: inconclusive
```

`AVPlayerItem` 이 헤드리스 CLI(런루프 없음)에서 `readyToPlay` 로 가지 않아 **재생 자체가
시작되지 않았다.** 그래서 "`pause` 는 위치를 보존하는데 `loadContent` 가 그것을 버린다" 는
증상의 **후반부를 실측으로 확인하지 못했다.**

**따라서 이 항목의 근거는 제어흐름 독해 하나다** — 그건 명확하다(`loadContent` 첫 줄이
`tearDownContent`, `startAnimation` 이 그것을 무조건 호출, `stopAnimation` 은 `pause` 만 함).
그러나 `ScreenSaverView` 의 실제 `start/stop` 호출 순서와 시점이 macOS 판본마다 다를 여지가
있고, `AVPlayer` 가 새 아이템에서 어느 위치부터 시작하는지도 재지 못했다.
**그래서 high 가 아니라 medium 으로 둔다** — 제어흐름 이상은 명확하지만 사용자가 보는
증상(되감김·첫 프레임 지연)을 재현하지 못했으므로, 확정 등급을 올릴 근거가 없다.
이 리포의 규약("부정·긍정 결론 모두 표본이 그것을 보여줄 수 있는지 먼저 검사한다")을 그대로 적용한 결과다.

**의도 쪽 배경(확인함)**: 앱이 `ScreenSaverController.syncVideoPath(...)` 로
`kr.yaki.waple.saver` 도메인의 `videoPath` 를 갱신한다(`AppDelegate.swift:647`).
즉 "시작 시 최신 경로 반영" 이라는 주석의 의도는 실재하는 배선에 근거한다 —
문제는 **경로가 그대로일 때도 재생성한다**는 것뿐이다.

---

### 🟡 M2 — 폐기된 이중계수 모집단 `358` 이 소스 4파일·RE 문서에 아직 살아 있다 (커밋되지 않은 diff 가 스스로 지목한다)

- **성격**: 정본 거짓. 이 리포가 가장 자주 물리는 종류다 — 정본은 고쳤는데 그것을 인용하는
  주석이 안 따라온 경우.

**배경**: `5d6cba8b`·`83da9851`(2026-08-28)이 씬 모집단 `358` 을 **이중계수로 판정**했다.
동봉 `Sources/WapleRender/Resources/WEAssets/` 가 설치본 `assets/` 의 **사본**이라 172 씬을
두 번 센 값이었다(`358 = 172 + 186`). **직접 세어 확인했다**:

```
$ find Sources/WapleRender/Resources/WEAssets \( -name 'scene.json' -o -name 'gifscene.json' \) | wc -l
172        ← 사본. 이만큼이 중복 계수였다
```

**"사본" 이라는 전제 자체를 파일 단위로 증명했다** — 두 트리를 전수 비교했다:

```
동봉 WEAssets 파일 2,940   ·   설치본 assets 파일 2,940
공통 상대경로 2,940  ·  동봉에만 있음 0  ·  설치본에만 있음 0
표본 200개 내용 SHA256: 동일 200 / 다름 0
```

**경로 집합이 완전히 같고 내용도 같다.** 즉 `WEAssets` 는 `assets/` 의 사본이라는 판정이
정확하고, 두 트리를 합쳐 세면 **모든 항목이 정확히 2배**가 된다 — `.tex` 도 그렇다
(동봉 311 = 설치본 assets 311). 이중계수 판정의 근거가 파일 층에서 확정된다.

정본은 이미 고쳐져 있고 테스트가 못박는다:

| 정본 | 값 |
| --- | --- |
| `spec/engine/tonemapping.json` `corpusScenes` | **186** |
| 같은 곳 `corpusReach` | `{LDR+bloom off: 178, LDR+bloom on: 5, HDR+bloom on: 3, HDR+bloom off: 0}` (합 186) |
| 같은 곳 `hdrScenesNote` | 고유 HDR 씬은 **3개**. 종전 4는 `previewthunderbolt` 를 두 경로로 두 번 실은 것 |
| `Tests/WapleCoreTests/ToneMappingCanonTests.swift:264`·`:274` | `XCTAssertEqual(corpusScenes, 186)` · 도달 표 합 186 |

**아직 낡은 자리 — 전수 grep 으로 확인**:

| 자리 | 살아 있는 문면 | 정본 값 |
| --- | --- | --- |
| `Sources/WapleRender/HDRPostPass.swift:21` | "**358** 씬 중 **354** 씬은 `combine.frag`" | 186 중 183 |
| `Sources/WapleRender/LDRBloomPass.swift:33` | "동봉+설치본 **358** 씬 중 **354**" | 186 중 183 |
| `Sources/WapleRender/VolumetricLightPass.swift:41` | "동봉 172 + 설치본 186 = **358 씬에서 0건**" | 186 씬에서 0건 |
| `Sources/WapleCore/LDRBloomMath.swift:74` | "**358** 씬 중 저작 **154**건이 전건 `\"1 1 1\"`" | 186 중 **77** |
| `Sources/WapleRender/Mesh3DShaders.swift:610-611` | "동봉 172 + 설치본 186 씬 전수에서 `hdr:true` **4건**" | **3건** |
| `docs/re/tonemapping.md` | `358` **12곳** | 186 |

**전수로 세면 diff 의 자기 지목보다 훨씬 넓다 — 22자리다.**
"동봉 172 + 설치본 186 = 358" 형태의 **모집단 주장**만 골라(정정·취소선 문맥 제외,
무관한 358 제외 — `package-format.md` 의 `.json` 확장자 census 와 `material-schema` 의
`rgba_backbuffer` FBO 도수는 다른 수다) 셌다:

| 파일 | 자리 |
| --- | --- |
| `docs/re/tonemapping.md` | **7** |
| `docs/re/scene-postprocessing.md` | **6** |
| `Sources/WapleRender/HDRBloomPass.swift` | 2 (자기 정정 블록 안의 인용) |
| `docs/re/scene-lighting.md` | 2 |
| `Sources/WapleRender/VolumetricLightPass.swift` · `LDRBloomPass.swift` · `HDRPostPass.swift` · `Sources/WapleCore/LDRBloomMath.swift` | 각 1 |
| `spec/schema.json` | 1 (예시 문구) |
| **합계** | **22** |

diff 가 스스로 지목한 것은 5자리(+`docs/re/tonemapping.md` "~11곳")였는데,
**`docs/re/scene-postprocessing.md` 6자리와 `scene-lighting.md` 2자리는 목록에 없다.**
특히 `scene-postprocessing.md` 는 히스토그램 표 전체가 358 기준이다
(`bloom` 358 100.0% · `clearcolor` 358 100.0% · `bloom:true` 10/358 · `hdr:true` 4/358) —
즉 **비율까지 잘못된 분모로 계산돼 있다**. 크기가 작지 않다 — 분모가 거의 2배이므로
비율은 거의 절반으로 적혀 있다:

**올바른 값을 직접 쟀다**(설치본 `assets/` + `projects/` 의 `{scene,gifscene}.json` 단일 모집단):

```
씬 186 · bloom 키 존재 186/186 · clearcolor 186/186 · hdr 키 존재 90
bloom:true = 8      hdr:true = 3
```

| 문서의 표기 | 실측(단일 모집단) | 차 |
| --- | --- | --- |
| 씬 **358** | **186** | 172 과다 |
| `bloom` 존재 **358** (100.0%) | **186** (100.0%) | 비율은 우연히 같다 |
| `bloom:true` **10 / 358 = 2.8%** | **8 / 186 = 4.3%** | 도수도 비율도 틀림 |
| `hdr:true` **4 / 358 = 1.1%** | **3 / 186 = 1.6%** | 정본의 "고유 HDR 3씬" 과 일치 |

즉 **도수 자체도 이중계수돼 있었다**(`bloom:true` 10 은 8 + 사본 2, `hdr:true` 4 는 3 + 사본 1).
정본(`tonemapping.json` `hdrScenesNote` = "고유 HDR 씬은 **3개**")과 내 실측이 일치하고,
`docs/re/**` 의 히스토그램만 낡았다.

"블룸을 켜는 씬이 2.8% 뿐" 과 "5.4%" 는 우선순위 판단을 바꿀 수 있는 차이다 —
이 리포가 트리거 규약("해당 씬을 실제로 쓸 때 착수")으로 일을 고르기 때문에 특히 그렇다.

**주의 — 커밋되지 않은 diff 의 자기 지목 목록에 경로 오류가 하나 있다.**
`HDRBloomPass.swift:67` 은 그 자리를 `LDRBloomMath.swift` 로 적으면서 문맥상
`Sources/WapleRender/` 아래로 열거하는데, **실제 파일은 `Sources/WapleCore/LDRBloomMath.swift`** 다
(`WapleRender` 에는 그 이름의 파일이 없다). 나머지 지목은 전건 실재를 확인했다.
`VolumetricLightPass.swift` 는 `172 + 186 = 358` 이라 **이중계수의 산술 자체를 본문에 적고 있어**
가장 명시적으로 틀린 자리다.

**대체값을 직접 쟀다 — 참고표**(설치본 단일 모집단 186 vs 동봉만 172 vs 합산 358):

| `general` 키 | 설치본(정본 기준) | 동봉만 | 합산(폐기) |
| --- | --- | --- | --- |
| `bloom` | **186** | 172 | 358 |
| `hdr` | 90 | 87 | 177 |
| `zoom` | 92 | 89 | 181 |
| `bloomtint` | **77** | 77 | 154 |
| `perspectiveoverridefov` | **77** | 77 | 154 |
| `windenabled` · `gravitystrength` | 69 | 69 | 138 |
| `camerashake` | 173 | 168 | 341 |
| `orthogonalprojection` | 182 | 171 | 353 |
| `castvolumetrics` | **0** | 0 | 0 |

`LDRBloomMath.swift:74` 의 "154" 가 정확히 **77 + 77**(사본 이중계수)이고, 정본이 적은
"186 중 **77**" 과 내 실측이 일치한다. `VolumetricLightPass.swift:41` 의 "358 씬에서 0건" 도
**결론은 맞다**(어느 모집단에서도 `castvolumetrics` 는 0) — 모집단 수만 낡았다.

**왜 게이트가 못 잡나**: 이 수치들은 전부 **주석 산문**이다. `check_canon_generator_values.py` 는
정본 JSON 의 리터럴만 대조하고, 주석 안의 숫자를 정본과 맞추는 게이트는 없다.
`ToneMappingCanonTests` 는 정본 JSON 을 잠그지만 그 정본을 **인용하는 주석**은 잠그지 않는다.
`docs/README.md` 가 선언한 규약("인용은 드리프트한다 — 줄번호로 가지 마라")의 **수치 버전**이
필요한 자리다.

---

### ✅ 검증 통과 — `version` 기능 게이트 철회는 옳다(비둘기집 산수 재현)

커밋되지 않은 변경 중 **유일하게 실동작을 바꾸는 코드 변경**이다(나머지는 대부분 주석·정본).
`SceneDocument.parse()` 에서 `versionGatedGeneral(_:schemaVersion:)` 을 **삭제**했다 —
종전에는 최상위 `scene.version` 이 낮으면 `general` 사본에서 키 14개를 지워 소비를 막았다
(v<3: `hdr`·`zoom`·`bloomhdr*` 5종·`bloomtint`·`perspectiveoverridefov` = 9개,
v<4: `wind*` 3종·`gravity*` 2종 = 5개).

**이 리포 자신의 정본으로 산수를 재현했다 — 전건 일치**(`spec/corpus/scene-schema.json`):

```
version 분포 = {5:63, 1:33, 4:32, 3:31, None:3}
  총 162 씬 (주장 162) ✅     v>=3 = 126 (주장 126) ✅     v>=4 = 95 (주장 95) ✅
```

| 키 | 저작 씬 수 `n` | `n − (v≥임계 씬수)` | 뜻 |
| --- | --- | --- | --- |
| `hdr` · `zoom` | 159 | **33** | 최소 33씬이 v<3 인데 저작한다 |
| `bloomtint` | 142 | **16** | 최소 16씬이 v<3 인데 저작한다 |
| `perspectiveoverridefov` | 130 | **4** | 최소 4씬이 v<3 인데 저작한다 |
| `windenabled` 외 4종 | 109 | **14** | 최소 14씬이 v<4 인데 저작한다 |

주석이 적은 33 · 16 · 4 · 14 와 내 첫 계산이 일치했다. **그러나 그 산수 자체가 느슨하다 —
병렬 워크플로가 지적하고 내가 확인했다(→ M22).** 하한은 `n − (v≥임계)` 가 아니라
`n − (v≥임계 + version 부재 3)` 이어야 한다: version 이 없는 씬은 삭제된 게이트가
**통과시켰기 때문**이다(`guard let v = schemaVersion else { return general }`).

| 키 | n | 주석의 하한 `n−(v≥thr)` | 올바른 하한 `n−(v≥thr+3)` |
| --- | --- | --- | --- |
| `hdr`/`zoom` | 159 | 33 | **30** |
| `bloomtint` | 142 | 16 | **13** |
| `perspectiveoverridefov` | 130 | 4 | **1** |
| wind/gravity | 109 | 14 | **11** |

**결론은 그대로 유효하다** — 네 하한이 전부 **여전히 양수**이므로 반례의 존재는 확정적이고,
**게이트의 전제는 어느 방향으로도 성립할 수 없다.** 틀린 것은 하한의 크기뿐이다.

게이트의 유일한 근거였던 짝 저장소 문서 한 줄이 실제로 철회됐는지도 확인했다 —
`Waple-wallpaper-source/corpus_scan/scene-json-schema.md` 의 해당 자리에
`**[CORRECTED 2026-08-28 — the corpus refutes this, and a consumer was built on it.]**
`version` does **not** gate those keys.` 가 실재하고, 그 정정문이 소비자로
`SceneDocument.swift` 를 명시한다. 즉 **짝 저장소가 근거를 철회했고 이 변경이 그 소비자를
따라 걷어낸 것** — 방향이 옳다.

**새 오라클이 돌연변이를 잡는다.** 테스트 4개가 이름까지 반전됐다
(`testSameKeysIgnoredAtV1ButConsumedAtA5` → `testAuthoredKeysSurviveAtEveryVersion` 등).
빈 껍데기가 아닌지 확인하려고 **게이트를 부분 복원**해 봤다(`v<3` 에서 `hdr` 만 제거):

```
testAuthoredKeysSurviveAtEveryVersion   FAILED
  XCTAssertTrue failed - version 1: 저작된 hdr 이 게이트로 떨어졌다
testV1AndV5ProduceIdenticalGeneralDocuments  FAILED
  XCTAssertEqual failed: ("false") is not equal to ("true")
testCoreBloomKeysStillConsumedAtV1      passed
testMissingVersionConsumesAuthoredAndDefaultsUnauthored  passed
```

**4개 중 2개가 정확히 빨개졌다**(복원 후 전건 초록). `testAuthoredKeysSurviveAtEveryVersion`
은 14키 × 4버전(1·3·4·5)을 전수 단언하므로 어느 키를 되돌려도 걸린다 — 강한 오라클이다.

**남는 위험(기록만)**: 게이트를 걷어내면 v<3 씬도 `hdr` 을 소비하게 된다. 그 씬들이
실제로 어떻게 보이는지는 **픽셀로 확인되지 않았다** — 스냅샷 회귀 게이트
(`WapleCompat --compare`)는 이 맥에서 돌리지 않았다(코퍼스 부재). 정본·산수는 옳지만
"걷어낸 뒤 170씬 픽셀이 그대로인가" 는 이 감사의 검증 경계 밖이다.

### ✅ 검증 통과 — 모니터 인덱스 스큐 수정은 옳고, 새 오라클 3개가 돌연변이를 잡는다

커밋되지 않은 변경의 **두 번째 실동작 코드 변경**이다. `PlaybackPolicyComposition.decideAll`
이 **배열 위치를 모니터 인덱스로 쓰던** 것을 호출자가 실제 인덱스를 넘기도록 시그니처로 바꿨다
(`[WallpaperProject]` → `[(monitorIndex: Int, project: WallpaperProject)]`).

**버그가 실재했음을 확인했다.** 종전 주석은 "`renderers` 가 `screenViews` 와 같은 순서라
배열 위치 = 모니터 인덱스" 라고 적었는데, 실제로는 `screenProjects` 를 **`compactMap` 으로
nil 슬롯을 떨어뜨린** 순서다. 마스크 쪽은 `NSScreen.screens` 위치로 만들어지므로,
앞에 빈 슬롯이 하나라도 있으면 **그 뒤 모든 화면이 다른 화면의 pause 결정을 받았다.**

**전제조건 서술까지 검증했다** — 스큐는 `global == nil` 일 때만 난다는 주장을 위해
`AppLogic.resolveProjectSlots`(`:39-53`)를 직접 읽었다:

```swift
return screenKeys.map { key in
    guard let folder = assignedFolder(key) else { return global }   // ← global
    if let cached = cache[folder] { return cached }
    guard let parsed = parse(folder) else { return global }         // ← global
    cache[folder] = parsed
    return parsed
}
```

**모든 실패 경로가 `global` 을 반환한다** — 그래서 `global` 이 non-nil 이면 nil 슬롯이
나올 수 없고 `compactMap` 이 아무것도 떨어뜨리지 않아 두 인덱스가 일치한다.
주석의 좁은 전제조건 서술이 정확하다("넓게 적으면 그것이 다음 세션의 거짓이 된다" 는
그 파일의 자기 규율도 지켜졌다).

**돌연변이 검증 — 새 오라클 3개가 옛 버그를 정확히 잡는다.** 수정을 되돌려
(`projects.enumerated()` + `monitorIndex: idx`) 돌렸더니:

```
testPerProjectDecideAllUsesRealMonitorIndexNotArrayPosition  FAILED
  ("[false]") != ("[true]") - 빈 슬롯으로 재인덱싱된 배열 위치(0)가 아니라 실제 화면 인덱스(1)로 판정해야 한다
testPerProjectDecideAllDoesNotInheritAnotherScreensPauseBit  FAILED
  ("[true]") != ("[false]") - 화면 1의 렌더러가 남의 비트로 멈추면 안 된다
testPerProjectDecideAllRespectsGivenIndicesRegardlessOfOrder FAILED
  ("[false, false]") != ("[true, false]")
```

**3/3 이 빨개졌다**(복원 후 초록, 작업 트리 45파일 유지). 진단 문면이 실패 시나리오를
그대로 설명한다 — 이 리포가 요구하는 오라클 품질에 부합한다.

### ✅ 검증 통과 — `g_LightAmbientColor` 죽은 분기 삭제의 "도달 불가" 주장이 맞다

`GLSLTranslator.engineNeutralDefault` 에서 `g_LightAmbientColor` case 를 지운 변경이
"도달 불가한 죽은 분기 + 거짓 근거" 라고 주장한다. **실행으로 확인했다** — 실제 번역기에
bare 선언을 두 형태로 먹여 봤다(프로브는 측정 후 삭제):

| 선언 | 출력에 `g_LightAmbientColor` 남는가 | 엔진 대체(흰색 `float3`) 적용 |
| --- | --- | --- |
| `uniform vec3 g_LightAmbientColor;` | **아니오** | 예 |
| `uniform vec4 g_LightAmbientColor;` | **아니오** | 예 |

두 형태 모두 `isEngine` 이 먼저 claim 해 머티리얼 분류에 도달하지 못한다 —
즉 `engineNeutralDefault` 의 그 case 는 **호출될 수 없었다.** 삭제의 동작 변화 0 이 맞다.

**삭제 이유가 더 중요하고, 그것도 정본과 맞다.** 지운 근거는 "죽었으니 치운다" 가 아니라
**그 죽은 분기의 주석이 미래의 배선자를 잘못 이끈다**는 것이다:
`spec/engine/uniform-feed.json` `engine.uniformFeed.wapleGaps`(status 확정)를 직접 읽어
확인했다 — WE 는 `"씬 authoring 값. 키가 없으면 (0,0,0) — 검정."` 이고 우리 상수 주입을
`"폴백 방향이 반대다."` 로 판정한다. 즉 죽은 분기가 "흰색 안전망이 있다" 고 읽히면
**정본이 말하는 올바른 폴백(검정)과 반대 방향으로** 배선하게 된다. 위험 방향 판단이 옳다.

### ✅ 검증 통과 — MDL 스킨 판정에서 `l.uv != nil` 제거는 실동작 버그 수정이다

`Model3D.readVertices` 의 `skinFieldsFit` 판정에서 `l.uv != nil` 을 뺐다. 주장은
"본/웨이트 유무는 idx5·idx6 비트가 정하고 TEXCOORD0 과 독립인데, 그 조건 때문에
TEXCOORD0 없는 스킨 메시가 스키닝을 통째로 잃었다" 이고, 실측으로 플래그
`0x01800003`·stride 56 을 든다. **정본 표로 그 산수를 재현했다**
(`spec/formats/mdl-deep.json` `format.mdl.formatFlagBits` — 출처는 `wallpaper64.exe`
`.rdata` 병렬 배열 4개 × 26엔트리):

```
flag = 0x01800003
  0x00000001  idx0  a_Position      float3 POSITION0      12B
  0x00000002  idx3  a_Normal        float3 NORMAL0        12B
  0x00800000  idx5  a_BlendIndices  uint4  BLENDINDICES0  16B
  0x01000000  idx6  a_BlendWeights  float4 BLENDWEIGHT0   16B
                                             stride 합 = 56   (주장 56) ✅
```

그리고 **TEXCOORD 계열 18개 비트가 전부 clear** 다(idx7‥idx24 전건 확인).
즉 이 플래그는 "본과 웨이트는 있는데 UV 는 없는" 정당한 스킨 메시이고,
종전 조건은 `l.uv != nil` 이 거짓이라 `skinned=false` 로 떨어뜨려
`boneIndices=(0,0,0,0)`·`weights=(0,0,0,0)` 을 만들었다 — **스키닝이 사라져 메시가
바인드 포즈로 굳는다.** 수정은 UV 를 별도로 게이팅해 부재 시 `(0,0)` 으로만 처리한다.
비트 배정이 독립이라는 근거가 정본 표에 그대로 있으므로 판단이 옳다.

**새 오라클 4개가 돌연변이를 잡는다.** `l.uv != nil` 을 되돌리자
`testSkinnedFlagWithoutTexCoordKeepsSkinning` 이 단언 3개로 빨개졌다:

```
XCTAssertTrue failed                                   (mesh.skinned)
boneIndices: ("SIMD4<UInt32>(0,0,0,0)") != ("(7,8,9,10)")  - 종전엔 (0,0,0,0) — 스키닝이 통째로 사라졌다
weights:     ("SIMD4<Float>(0,0,0,0)")  != ("(0.5,0.25,0.125,0.125)")
```

플래그로 정확히 `0x0180_0003` 을 쓴다 — 내가 정본 표로 stride 56 을 검증한 그 값이다.
`testNoTexCoordFlagYieldsZeroUV` · `testNoTexCoordWithTangentYieldsZeroUV` ·
`testInferredStridePathKeepsTailUVFallback` 는 UV 부재 시 `(0,0)` 폴백과 추론 경로를 각각 잠근다.
(복원 후 전 스위트 재실행: **3,886 실행 · 실패 0 · 스킵 63** — 기준선과 동일.)

> **도달 범위 — 측정했고, 0 이다.** 짝 저장소 `.mdl` **28개 전수**를 u32 로 훑어
> "블렌드 비트 둘 다 set + TEXCOORD 18비트 전부 clear + 위치 비트 있음" 을 만족하는
> 포맷 플래그를 찾았다. **후보 0건.** 즉 **지금 이 코퍼스에서 굳어 있던 모델은 없다** —
> 이 수정은 관측된 파손을 고친 것이 아니라 **예방적 수정**이다.
> (`l.uv != nil` 이 붙어 있어도 이 코퍼스에서는 증상이 안 났다는 뜻이고, 그래서
> 어떤 테스트도 잡지 못한 것과 정합한다. 워크샵 코퍼스 446 폴더는 이 맥에 없어
> 그쪽 도달은 여전히 미확인이다 — F400.)

### ✅ 검증 통과 — 탭 구분 지시문 수정은 실제 버그를 고친다(A/B 실행으로 증명)

`ShaderPreprocessor` 가 `#` 와 키워드 **사이**의 탭만 접고 키워드 **뒤**의 탭은 접지 않아,
`#define\tMODE 2` 같은 줄이 지시문으로 인식되지 않고 본문으로 흘렀다는 주장이다.
**HEAD 와 작업 트리를 같은 입력으로 A/B 실행했다**(프로브는 측정 후 삭제, 파일 복원 확인):

| 입력 | HEAD (수정 전) | 작업 트리 (수정 후) |
| --- | --- | --- |
| `#define\tMODE 2` + `#if MODE == 2` | `#define	MODE 2` \| **`FALSE_BRANCH`** | **`TRUE_BRANCH`** ✅ |
| `#define MODE 2`(공백, 대조군) | `TRUE_BRANCH` | `TRUE_BRANCH` |
| `#if 0`/`DEAD`/`#endif\tx`/`EVERYTHING_AFTER` | **`[]` (전부 소실)** | `EVERYTHING_AFTER MORE` ✅ |
| `#endif x`(공백, 대조군) | `EVERYTHING_AFTER MORE` | `EVERYTHING_AFTER MORE` |
| `#undef\tK` 뒤 `K` | **`#undef	1` \| `1`** | `K` ✅ |
| `#undef K`(공백, 대조군) | `K` | `K` |

**세 증상 전건이 재현됐고 수정 후 공백형과 동일해졌다.** 특히 `#endif\tx` 는
**출력이 통째로 비었다** — `#if` 프레임이 닫히지 않아 그 뒤 셰이더 전체가 조용히 사라진다.
`#undef\tK` 는 본문으로 흘러 매크로 치환까지 먹어 `#undef	1` 이 됐다(주석 서술과 일치).

**실물 근거도 맞다**: WE 의 줄 인식 정규식 `^\s*#\s*([a-z]+)\b\s*(.*)` 의 `\b\s*` 는
키워드 뒤 임의 공백을 받으므로 탭 거부가 실물과의 이탈이다. 9종 중 `#require` 만
원래부터 `hasPrefix("#require\t")` 로 탭을 다뤘다는 점이 이것이 판단이 아니라 **빠뜨림**
이라는 증거라는 서술도 코드에서 확인했다.

**자산 영향 0 도 확인 가능하다**: 주석이 제시한 세는 명령을 그대로 돌리면 동봉·형제
코퍼스에서 탭형 도달 **0건**이다 — 즉 이 수정은 **워크샵 셰이더 대비 잠복 게이트**이고
현재 자산의 번역 결과는 불변이다.

### ✅ 검증 통과 — PBR Schlick k 가 WE 원문 헤더와 문자 그대로 일치한다

`SceneWELightMathTests` 의 커밋되지 않은 변경은 오라클의 **근거를 바꿨다**: 종전에는
Swift 구현끼리 비교했는데(`testSchlickRoughnessKMatchesScenePBRMath` — 자기 자신과의 비교라
둘이 함께 틀리면 못 잡는다), 이제 **WE 원문 헤더 텍스트를 파싱해** 그 식과 비교한다
(`testSchlickRoughnessKMatchesWECanonHeader` 외 2건). 오라클 설계가 개선된 방향이다.

**원문(ground truth)** — `wallpaper_engine/assets/shaders/common_pbr.h:27-32`
(`common_pbr_2.h` 도 바이트 동일):

```glsl
float Schlick_GGX(float NV, float roughness)
{
    float roughnessBase = roughness + 1.0;
    float roughnessScaled = (roughnessBase * roughnessBase) / 8.0;
    return NV / (NV * (1.0 - roughnessScaled) + roughnessScaled);
}
float GeoSmith(vec3 N, vec3 V, vec3 L, float roughness)
{ return Schlick_GGX(max(dot(N,V), 0.001), roughness) * Schlick_GGX(max(dot(N,L), 0.001), roughness); }
```

**Waple** — `Sources/WapleCore/ScenePBRLighting.swift:50-62`:

```swift
static func schlickGGX(_ nd: Float, roughness: Float) -> Float {
    let r = roughness + 1
    let k = r * r / 8
    return nd / (nd * (1 - k) + k)
}
... let nv = max(simd_dot(normal, view), 0.001)
    let nl = max(simd_dot(normal, light), 0.001)
```

**완전 일치** — `(r+1)²/8` 매핑, 분모 형태 `nd·(1−k)+k`, `GeoSmith` 의 두 `0.001` 클램프까지
같다. 이 자리는 이탈이 없다.

> **[중요 보강 2026-08-31] 그 일치는 *CPU 미러*의 일치다 — 화면에 닿는 코드가 아니다.**
> `spec/engine/deviations.json` `deviation.finding.scenePBRMathIsDead`(확정)가
> `ScenePBRMath` 를 **데드코드**로 판정하고, 내가 참조를 세어 확인했다(같은 파일의 다른 네
> 타입은 `Sources` 에서 1~5회 참조되는데 `ScenePBRMath` 만 **0회**). 라이브 PBR 은
> `Sources/WapleRender/Mesh3DShaders.swift` 의 MSL 이다.
>
> 즉 **"Schlick k 가 WE 와 같다" 는 결론은 참이지만 적용 대상이 CPU 사본**이고,
> 라이브 MSL 이 같은 식인지는 **별도 축**이다. 정본이 그 위험을 명시한다 —
> *"두 구현이 갈라져도 테스트가 CPU 쪽만 보므로 드리프트를 못 잡는다."*
> **이 라운드가 그 축을 실제로 메웠다(확인함)** — 새 오라클
> `testLiveMSLLanesUseTheSameSchlickKAsTheCanonHeader` 는 **라이브 MSL 두 레인**을
> 원문 헤더와 대조한다(주석: *"두 레인 둘 다 본다 — 한 쪽만 보면 다른 쪽이 조용히 표류한다"*).
> 그리고 **그 두 레인이 실제로 일치한다** — 내가 직접 읽었다:
>
> ```
> Sources/WapleRender/Mesh3DShaders.swift:189-190   float base = roughness + 1.0;  float k = base * base / 8.0;
> Sources/WapleRender/QuadShaders.swift:147-148     float r    = roughness + 1.0;  float k = r * r / 8.0;
> WE 원문 common_pbr.h:29-30                        roughnessBase = roughness + 1.0; (rb*rb)/8.0
> ```
>
> 즉 **CPU 미러도 라이브 MSL 도 WE 와 같다** — 이 자리에는 실제 이탈이 없고, 데드코드 위험은
> 새 오라클이 덮었다. 남은 것은 M17(그 오라클의 정규식이 우측 미앵커)뿐이다.

### ✅ 보안 검증 통과 — 웹 벽지 파일 서빙의 경로 격리가 적대적 입력 10종을 전부 막는다

`WallpaperSchemeHandler` 는 **페이지 JS 가 요청 경로를 제어할 수 있는** 자리다
(웹 벽지가 `wallpaper://` 로 로컬 파일을 읽는다). 즉 컨테인먼트가 뚫리면 임의 파일 읽기가 된다.
격리 함수(`WallpaperPathSecurity.containedFileURL`)에 **적대적 입력을 직접 먹여 봤다** —
루트 밖에 비밀 파일, 접두사가 같은 형제 디렉터리(`wallpaperX`), 루트 안에서 밖을 가리키는
심링크를 만들어 두고 시험했다(프로브는 측정 후 삭제):

| 요청 경로 | 결과 |
| --- | --- |
| `/index.html` (정상) | 허용, 루트 내부 ✅ |
| `/../secret.txt` | **거부(nil)** |
| `/..%2Fsecret.txt` (퍼센트 인코딩) | **거부** |
| `/%2e%2e%2fsecret.txt` (전체 인코딩) | **거부** |
| `/subdir/../../secret.txt` (중첩 상승) | **거부** |
| `/escape` (루트 안 → 밖 심링크) | **거부** |
| `//secret.txt` (이중 슬래시) | **거부** |
| `/\0../secret.txt` (NUL 주입) | **거부** |
| `/./index.html` | 허용, 루트 내부 ✅ |
| `/....//secret.txt` | 허용하지만 **루트 내부**로 해석 — 아래 확인 |

마지막 벡터만 nil 이 아니라 따로 확인했다: `....` 를 **문자 그대로 디렉터리 이름**으로 보아
`<root>/..../secret.txt` 로 해석한다. 실측 — 루트 접두사 일치 `true`, 파일 존재 `false`,
비밀 유출 `false`. **탈출이 아니다**(POSIX 에서 `....` 는 특수 이름이 아니므로 올바른 해석).

**zip 임포트의 F580 벡터도 시험했다 — 막힌다.** `LibraryStore` 는 `project.json` 이 선언한
`id`/`workshopid`(= **아카이브가 제어하는 문자열**)를 관리 폴더명으로 쓰는데, 그 자리에서
`removeItem`/`moveItem` 이 돈다. 즉 탈출하면 **임의 디렉터리 파괴**다. 살균기를 통과시켜 봤다:

```
"../../evil" -> nil    ".." -> nil    "../imported" -> nil
"/etc" -> nil          "a/b" -> nil   "....//x" -> nil     "ok_name" -> "ok_name"
```

전건 거부되고, `nil` 이면 임시 해제 위치의 루트 폴더명으로 폴백한다(구조상 단일 컴포넌트).
같은 자리에 **데이터 손실 방어**도 있다: `workshopid` 로 정체성이 확정될 때만 기존 관리
폴더를 덮어쓰고, 확정 불가면 유일화한다 — 서로 다른 배경이 같은 폴더명을 주장할 때
조용히 하나를 지우지 않는다.

**공유 살균기(`WallpaperPathSecurity`)도 직접 시험했다** — 2026-08-21 에 고쳤다고 기록된
미묘한 자리(심링크 아래의 **아직 없는 이름**)가 지금도 막혀 있는지가 핵심이다.
루트 안에 밖을 가리키는 디렉터리 심링크를 만들어 두고:

| 입력 | 결과 |
| --- | --- |
| `link` | **BLOCKED** |
| `link/secret.txt` | **BLOCKED** |
| `link/missing.txt` | **BLOCKED** ← 종전에 루트 밖 경로를 돌려줬다던 그 자리 |
| `link/a/b/c.txt` (더 깊은 부재 경로) | **BLOCKED** |

`normalizedPathComponent` 살균기(`project.json` 의 `id`/`workshopid` 처럼 **아카이브가
제어하는 문자열**에 쓰인다):

```
"../../etc/passwd" -> nil    ".." -> nil    "a/b" -> nil
"/abs" -> nil    "file:///x" -> nil    "" -> nil    "ok-name" -> "ok-name"
```

전부 의도대로다. 즉 그 정정이 **현재 트리에서도 유효**하고, 회귀하지 않았다.

**부수 확인**: `parseRangeHeader` 도 페이지 JS 가 제어하는 입력인데
`end = Int64.max` 에서 `end+1` 산술 오버플로 트랩을 **덧셈 없는 분기로** 막고 있다
(`:F570` 주석 + 코드 일치 확인). 이 파일의 기존 오라클
(`testRejectsPathTraversal` · `testRejectsPercentEncodedTraversal` · `testRejectsSymlinkEscape` ·
`testRejectsSiblingPrefix` 등)이 이미 같은 축을 지키고 있고 전건 통과한다.

### ✅ 검증 통과 — "Darwin 은 트레일링 콤마를 거부한다" 는 **추정을 실측으로 뒤집은 정정**이 맞다

`AssetJSONLenientTests` 의 종전 주석은 *"Darwin `NSJSONSerialization` 은 RFC 엄격이라
31건 전부 실패한다고 알려져 있으나 이 세션에서 macOS 를 돌릴 수단이 없다(**추정**)"* 였다.
커밋되지 않은 변경이 이것을 **추정 → 실측**으로 바꾸며 두 가지를 정정한다.
**나도 이 맥(macOS 27 / Swift 6.4)에서 직접 쟀다 — 정정이 맞다**:

| 입력 | Apple Foundation 엄격 파스 (내 실측) |
| --- | --- |
| `{"a":1,}` | **통과**(받는다) |
| `[1,2,]` | **통과** |
| `{"a":[1,2,],"b":{"c":1,},}` | **통과** |
| `{"a": 1 // c\n}` | 실패 |

즉 **Apple Foundation 도 트레일링 콤마를 받는다** — 종전 "추정" 이 틀렸고, 엄격 파스가
실패하는 것은 리눅스와 마찬가지로 **줄 주석뿐**이다. 두 플랫폼이 이 축에서 갈리지 않는다.

동봉 트리 전수 스윕도 재현했다: **`total 1698` · `line 27` · `trail 4`** — 정정문의
`total 1698 line 27 block 0 trail 4 … strictFails 27` 과 핵심 수치가 일치한다.
트레일링 콤마만 가진 4건도 파일 이름까지 같다:

```
presets/water/preset.json
presets/water/previewwaterfaucet/presets/water/preset.json
effects/fluidsimulation/effect.json
effects/fluidsimulation/preview/effects/fluidsimulation/effect.json
```

> **작은 차이(결함 아님)**: 내 파이썬 스윕은 `block 6` · `jsonc 37` 로 정정문의 `block 0` 과
> 다르게 나온다. 파이썬 `json` 은 트레일링 콤마를 **거부**하고 `/*` 를 문자열 안에서도 세는
> 조잡한 heuristic 을 내가 썼기 때문이다 — 두 세는 법의 차이이고, 정정문이 인용하는
> Swift 실측(`strictFails 27`)과 내 Apple Foundation 직접 측정이 일치하므로 결론은 같다.

**의미**: 이 리포의 규율("추정은 추정이라 적고, 잴 수단이 생기면 재라")이 실제로 작동한 사례다.
게다가 정정문은 **왜 재지 못했다고 착각했는지**도 적는다 — 필수 macOS CI 레인이 있으므로
"수단이 없다" 는 전제 자체가 틀렸다는 것. 같은 파일의 중복 키 테스트는 이미 macOS 실측을
인용하고 있었다.

---

### 🟠 H5 — Swift 6 언어 모드 전환을 막는 진단이 **32자리 남아 있고 25자리가 한 파일에 몰려 있다**(그중 26건은 Swift 6 에서 에러)

- **성격**: 계획된 부채이지만 **현재 규모가 어디에도 기록돼 있지 않다.** 위험은 부채 자체가
  아니라 "얼마 남았는지 아무도 세지 않는다" 는 것이다.

`Package.swift:4-20` 은 2026-08-19 에 `-strict-concurrency=complete` 를 **경고로** 켰고,
계획을 이렇게 적는다: *"먼저 진단만 켠다 … CI 로그가 고쳐야 할 목록 전부를 뱉는다.
**그 목록을 소진한 뒤에 모드를 올린다**"*, 그리고 `:83` — *"테스트 타깃에는 아직 걸지 않는다.
**진단 목록을 먼저 소스에서 소진하고**, 그다음 테스트로 넓힌다."*

**깨끗한 빌드로 목록을 실제로 셌다**(별도 scratch-path 로 전체 재컴파일 — `.build` 는 보존):

```
$ swift build --build-tests --scratch-path /tmp/…/scratch
EXIT=0   총 warning 100   그중 동시성 계열 70   error 0
→ 중복·다중행 진단 문맥을 제거한 고유 자리: 47 (Sources 32 · Tests 15)
```

**`Sources` 32자리의 분포 — 25자리가 한 파일이다**:

| 파일 | 자리 |
| --- | --- |
| `WapleRender/SceneRenderer.swift` | **25** |
| `WapleRender/WallpaperSchemeHandler.swift` | 4 |
| `VideoRenderer.swift` · `WebRenderer.swift` · `SceneVideoLayer.swift` | 각 1 |

**진단 종류(Sources)**:

| 건수 | 진단 | Swift 6 에서 |
| ---: | --- | --- |
| 13 | main actor-isolated property … can not be **mutated** from a nonisolated context | 에러 |
| 8 | 같은 것의 **referenced** 판 | 에러 |
| 3 | conformance … **crosses into main actor-isolated code and can cause data races** | **명시적으로 "this is an error in the Swift 6 language mode"** |
| 3 | call to main actor-isolated instance method in a synchronous nonisolated context | 에러 |
| 2 | **sending 'X' risks causing data races** | 명시적 에러 예고 |
| 1+1+1 | initializer 호출 · 클로저 전달 · non-Sendable 캡처 | 에러 |

`conformance … crosses into main actor` 3건은 **렌더러 3종 전부**다 —
`SceneRenderer:71` · `VideoRenderer:32` · `WebRenderer:27` 가 모두 `WallpaperRenderer` 프로토콜
적합성에서 같은 진단을 낸다. 즉 이것은 개별 실수가 아니라 **프로토콜 자체의 격리 설계** 문제다.

**주의 — 증분 빌드로는 이 목록이 보이지 않는다.** 내가 처음 `swift build` 를 돌렸을 때
warning 이 **0** 이었다. 모듈이 캐시돼 재컴파일이 없었기 때문이다. 깨끗한 빌드에서만
100건이 나온다. **CI 는 이것을 옳게 다룬다** — `ci.yml:125-150` 의
`Concurrency diagnostics census` 스텝이 빌드 로그에서 warning 을 세어 잡 요약에
파일별·종류별 표로 남긴다. 문제는 그 표가 **게이트가 아니고**(하한·상한 없음)
어느 문서도 현재 수치를 적지 않는다는 것이다.

**정본 거짓은 아니다** — 어떤 문서도 "소진됐다" 고 주장하지 않는다. 다만 계획이 있고
측정 인프라도 있는데 **현재 값이 기록되지 않아** 진척을 알 수 없는 상태다.
이 리포가 테스트 개수에 쓴 것과 같은 **아래로만 막는 트립와이어**(warning 수 상한 래칫)가
없다는 뜻이기도 하다 — 새 위반이 들어와도 초록이다.

---

### 🟡 M6 — BACKLOG 의 "현지화(하드코딩 한국어 40+)" 는 **이미 해소된 과제**다(정본 거짓, 반대 방향)

- **자리**: `BACKLOG.md:22`(현재 과제 요약표) · `BACKLOG.md:441`
- **문면**: 제품화 트랙의 잔여로 *"접근성 · 현지화(**하드코딩 한국어 40+**)"* 를 적고
  근거로 `AUDIT.md §4–5` 를 인용한다.

**실측 — 그 과제는 끝났다**:

| 검사 | 결과 |
| --- | --- |
| `Resources/en.lproj/Localizable.strings` 항목 수 | **285** 개 |
| AppKit 경로(`NSMenuItem(title:)`·`window.title`)의 미현지화 한국어 | **0건** |
| **예외 — `Sources/WapleSaver`** | 화면보호기 안내문 1건이 한국어 하드코딩. 아래 H6 참조 |
| `LocalizationCoverageTests` 3종 | **전건 통과** |

그리고 그 3종이 **양방향으로** 잠근다 — `testEveryKoreanUIStringHasEnglishTranslation`
(소스 − 영어 = 누락 0), `testNoOrphanTranslations`(영어 − 소스 = 고아 0),
`testKoreanCatalogStaysEmpty`. 게다가 모집단 하한 가드(`XCTAssertGreaterThan(source.count, 80)`)
로 **추출 실패 자체를** 잡는다. 즉 "하드코딩 한국어" 가 새로 들어오면 CI 가 빨개지는 구조다.

**단 하나의 예외는 리포가 이미 정직하게 적어 둔 자리다** —
`LocalizationCoverageTests.swift:69-71`: *"**`Sources/WapleSaver` 는 여전히 사각지대다** —
Objective-C(`.m`)라 이 스캐너가 안 읽고, 애초에 `.saver` 번들에 `.lproj` 자체가 없어
`NSLocalizedString` 으로 해결되지도 않는다."* 실제로 그 파일의 안내문
("재생할 동영상이 없습니다 — …")은 `en.lproj` 에 없다(확인). 즉 **"40+" 는 낡았지만
"0" 도 아니다 — 정확히 1건이고, 그 1건은 번들 구조 문제로 별도 트랙이다.**

**왜 낡았나**: 인용된 `AUDIT.md` 는 머리말이 스스로 *"⚠️ **이력 문서다.** 2026-07-06 시점의
감사 결과이며 이후 상당수가 해소됐다. **현재 잔여 과제는 BACKLOG.md 를 봐라**"* 라고 적는다.
즉 **BACKLOG 가 "현재 잔여" 로서 이력 문서를 인용하고, 그 이력 문서는 현재를 알려면
BACKLOG 를 보라고 되돌린다** — 순환이고, 그 사이에서 값이 두 달 낡았다.

**성격**: 이 리포가 추적하는 "정본 거짓" 의 **반대 방향**이다. 보통은 문서가 실제보다
좋게 적어서 문제가 되는데, 이 자리는 **실제보다 나쁘게** 적혀 있다. 위험은 낮지만
같은 표의 다른 항목(`Developer ID 공증` · `접근성`)의 신뢰도까지 함께 떨어뜨린다 —
요약표는 리포에서 두 번째로 많이 읽히는 자리다.

**같은 표의 "접근성(그리드 타일 VoiceOver/키보드)" 도 확인했다 — 이것도 사실상 해소됐다.**

전용 인프라가 있다: `Sources/Waple/DesignSystem/TileAccessibility.swift` 의
`tileAccessibility(label:value:isSelected:onActivate:)` 모디파이어가 네 가지를 한 벌로 붙인다 —
`accessibilityElement(children: .combine)` · `accessibilityLabel` · `accessibilityValue` ·
`isButton`/`isSelected` 트레잇 + **키보드 포커스와 Return 활성화**. 즉 BACKLOG 가 적은
"그리드 타일 VoiceOver/키보드" 가 정확히 이것이다.

실제로 쓰인다(실측): `WallpaperGridView.swift:183` · `RemoteTile.swift:101` ·
`DisplaysView.swift:128`·`:258` — 타일 4종 전부. 그리고 그 파일이 스스로 남긴 갭
("`contextMenu` 전용 동작은 보조기술로 도달 불가 — 각 타일이 `.accessibilityAction(named:)` 을
추가로 붙여야 한다")도 메워져 있다: `WallpaperGridView.swift` 에 `accessibilityAction(named:)`
**9건** · `SidebarView.swift` 2건. 그것을 CI 가 강제한다 —
`testContextMenusHaveAccessibilityCounterpart` 가 `.contextMenu` 항목마다 짝 액션을 요구하고,
**모집단 하한 가드 2개**(소스 20개 초과 · `.contextMenu` 보유 파일 0건이면 실패)로
"스캔이 깨져서 초록" 을 막는다.

> **남는 것 하나**: `Developer ID 공증`. 서명·공증은 이 맥에서 확인할 수단이 없다
> (`docs/RELEASING.md` 가 현황을 적는다). 즉 제품화 표 3항목 중 **2항목이 낡았고**
> 1항목만 유효하다.

---

### 🟡 M5 — README 의 셰이더 인용이 **선언 줄을 코드 줄로** 가리킨다(정본은 옳고 README 만 틀렸다)

- **자리**: `README.md:46` (HDR/bloom 행)
- **문면**: *"WE's own `hdr_downsample.frag:61` reads `albedo *= 0.25 * g_BloomScatter`"*
- **실물**(`wallpaper_engine/assets/shaders/hdr_downsample.frag`, 95줄):

```
61:  uniform float g_BloomScatter; // {"material":"scatter","default":1}   ← 61 은 선언이다
78:      albedo *= 0.25 * g_BloomScatter;                                  ← 코드는 78
80:      albedo *= 0.25;
```

즉 `:61` 은 **유니폼 선언**이고 인용된 코드는 **`:78`** 이다.

**정본과 RE 문서는 옳다** — 이 오류는 README 에만 있다:

| 자리 | 문면 | 판정 |
| --- | --- | --- |
| `spec/engine/hdr-bloom.json` `engine.bloom.hdr.upsampleWeight` | "`:61` `uniform float g_BloomScatter;…` · **본문** `albedo *= 0.25 * g_BloomScatter`" | ✅ 선언과 본문을 구분한다 |
| `docs/re/scene-postprocessing.md:719` | "`hdr_downsample.frag:61,78`" | ✅ 두 줄을 함께 적는다 |
| `Sources/WapleRender/HDRBloomPyramidPass.swift:73`·`:417` | "업샘플 전용(`g_BloomScatter`, hdr_downsample.frag:61)" | ✅ 선언을 가리키는 맥락이라 맞다 |
| **`README.md:46`** | "`hdr_downsample.frag:61` **reads** `albedo *= 0.25 * …`" | ❌ 선언 줄로 코드를 가리킨다 |

**같은 부류를 전수 스윕했다 — 634건 중 3건이 범위를 벗어난다.**
`README.md` · `docs/**` · `spec/**` · `Sources/**` 에서 `<name>.frag|vert|h:<N>` 꼴 인용을
모두 뽑아 실물 셰이더의 줄 수와 대조했다:

| 인용 자리 | 인용 | 실물 |
| --- | --- | --- |
| `docs/re/fluid-simulation.md:953` | `combine.vert:32` | 그 파일은 **10줄**이다 |
| `docs/re/fluid-simulation.md:1916` | `combine.frag:116` | 그 파일은 **16줄**이다 |
| `docs/re/scene-postprocessing.md:631` | `blur_k3.vert:27` | 그 파일은 **14줄**이다 |

**다른 사본을 가리키는 것이 아님을 확인했다** — WE 트리 전체에 `combine.frag` 는 **1개**뿐이고
(16줄), `combine.vert` 1개(10줄), `blur_k3.vert` 1개(14줄)다. `fluidsimulation` 이펙트가
자기 사본을 갖고 있지도 않다(검색 0건). 즉 세 인용 모두 **해결 불가**다.
문맥상 fluidsim 패스 17 의 셰이더를 말하는데, 그 파일은 이 코퍼스에 없다
(에디터가 런타임에 생성하는 쪽이거나 다른 버전의 줄 번호로 보인다).

**나머지 631건은 범위 안이다** — 즉 이 리포의 셰이더 인용 규율은 대체로 지켜지고 있고,
`docs/README.md` 가 선언한 "인용은 드리프트한다" 규약의 실제 드리프트율이 **3/634 ≈ 0.5%** 다
(그 문서가 소스 `파일:줄` 인용의 드리프트를 76~95% 로 측정한 것과 대비된다 — 셰이더 인용은
대상 파일이 거의 안 바뀌기 때문이다).

**영향은 작다** — 결론(0.25 는 4탭 평균, scatter 는 별도 인자)은 **옳고** 실물이 뒷받침한다.
독자가 `:61` 로 갔을 때 인용된 코드가 없어 근거 추적이 한 번 끊기는 것이 전부다.
`docs/README.md` 가 선언한 규약("인용할 때는 줄번호만 적지 말고 식별자나 코드 조각을
같이 적어라")을 README 도 따르면 사라지는 부류다 — 실제로 정본은 그 규약을 지켜서 옳게 남았다.

**부수 검증(같은 행의 다른 주장은 전건 사실이다)**: *"no ACES or filmic tone curve —
WE 2.8's final step is a plain `saturate` clamp"* 를 원문으로 확인했다.
`combine_hdr.frag` 의 최종 두 줄은 `gl_FragColor = vec4(saturate(albedo), 1.0);` 와
`vec4(saturate(lin(albedo)) * g_RenderVar0.x, 1.0);` 이고, `pow` 는 sRGB 전달함수(`lin()`,
지수 2.4 · 무릎 0.055/12.92)에만 쓰인다 — **톤 커브가 없다.** `combine.frag` 에는
`saturate`·`pow` 조차 없다(LDR 경로는 가산뿐). 주장이 정확하다.

---

### 🟡 M4 — 재측정 스크립트 40개 중 **18개가 코퍼스 부재에서 트레이스백으로 죽는다**(판정을 내지 않는다)

- **성격**: 도구 위생. 실동작·정본 영향은 없지만, 이 리포가 방금 짝 저장소에서 고친 결함과
  **같은 부류**이고 그 교훈이 여기엔 적용되지 않았다.

`spec/` 정본을 만드는 `measure_*.py` 40개를 **코퍼스 없이 전부 돌려** 분류했다:

| 부류 | 개수 | 예 |
| --- | --- | --- |
| **트레이스백으로 죽는다** | **18** | `measure_corpus.py` · `measure_workshop_shaders.py` · `measure_material_schema.py` · `measure_hdr_bloom.py` · `measure_scene_schema.py` … |
| 판정을 내고 rc≠0 | 17 | `measure_mdl_deep.py` · `measure_tonemapping.py` · `measure_playback_policy.py` … |
| rc=0 | 5 | (코퍼스 불필요) |

죽는 쪽의 전형:

```
$ python3 scripts/spec/measure_workshop_shaders.py
Traceback (most recent call last):
  File ".../measure_workshop_shaders.py", line 1559, in load_corpus
    for wid in sorted(os.listdir(WS)):
FileNotFoundError: [Errno 2] No such file or directory: 'Z:\SteamLibrary\...\431960'
```

판정을 내는 쪽의 전형(`measure_mdl_deep.py`) — **이것이 옳은 모양이다**:

```
WE_WORKSHOP 으로 코퍼스 루트를 지정하라 — 설치본만으로 돌리면
스킨/gateWord 분포에서 키가 사라져 근거만 지워진다.
```

**환경변수 지원은 문제가 아니다** — 40개 중 36개가 이미 `WE_WORKSHOP`/`WE_ROOT` 를 읽는다
(`measure_workshop_shaders.py:38` 포함). 빠진 것은 **부재를 판정으로 바꾸는 한 줄**이다.

**중요 — 정본을 파괴하지는 않는다(확인했다).** 40개를 전부 돌린 뒤
`git status --porcelain spec/` 이 **여전히 9파일**(감사 시작 시점의 기준선과 동일)이다.
즉 죽는 스크립트들은 **쓰기 전에** 죽는다. 짝 저장소 `pkgv_census.py` 가 실제로 당했던
"입력 0 인데 산출물을 헤더만 남기고 덮으며 rc=0" 사고는 여기서 **재현되지 않았다.**
그래서 심각도를 medium 이 아니라 낮게 둔다 — 위험이 아니라 **일관성 결여**다.

**왜 기록하나**: ① 짝 저장소가 2026-08-30 에 정확히 이 부류를 고쳤고
(`pkgv_census.py` — 산출물 열기 **전** 입력 검사 + rc=2), 그 커밋의 주석이
*"돌릴 수 없는 생성기는 그 산출물이 정본이 되는 순간 검증 밖에 놓인다"* 를 인용한다.
같은 라운드가 이 리포의 18개에는 손대지 않았다. ② `check_spec_shrink_guard.py` 가
존재하는 이유 자체가 과거 이 부류로 정본을 지운 사고(`measure_binaries.py` entries 32→0 ·
`measure_mdl_deep.py` 451/986→0/0 · `measure_render_pass.py` 9키→빔)다 — 즉 이 리포는
**이미 한 번 당했고** 그때 가드를 세웠다. 남은 18개는 그 가드가 잡아 주기를 기대하는 상태다.

### ✅ 검증 통과 — README 의 "32종 blend mode 전부 구현" 주장이 사실이다

사용자가 가장 먼저 읽는 문서의 기능 주장은 과대 서술 위험이 큰 자리다. 대조했다:

| 출처 | 값 |
| --- | --- |
| `spec/engine/blend-modes.json` `blend.editorDropdown` | **33** 종 (`0`=normal ‥ `32`) |
| `Sources/WapleRender/BlendMSL.swift` 의 숫자 `case` | **32** 개 (`1` ‥ `32`) |
| 차집합 | canon 에만 있는 것 = `{0}` · impl 에만 = 없음 |

**모드 0 은 누락이 아니다** — `BlendMSL.swift:254` 의 `default: r = B; break; // 0 = Normal`
이 담당한다. 즉 **33종 전건이 처리되고**, README 의 "all 32 `colorBlendMode` values" 는
0(normal, 합성 없음)을 뺀 수를 말한 것이라 정확하다.

게다가 이 축을 지키는 전용 오라클이 있다 — `BlendModeCoverageTests.swift` 는 자기 머리말에
*"README 는 32종 전부 구현이라고 적고 `BlendMSL.applyBlending` 도 32개 case 를 갖고 있지만,
**실제로 픽셀까지 도달하는지** 본다"* 고 적고, 32종 출력이 서로 충분히 갈리는지까지 검사한다
(전부 알파 합성으로 붕괴하면 실패). 문서 주장 ↔ 구현 ↔ 픽셀 3단 대조가 갖춰진 자리다.

### ✅ 검증 통과 — 스냅샷 골든 기준선 2종이 온전하다(BACKLOG 의 F402/F403 정정과 정합)

시각 회귀의 유일한 안전망이므로 실체를 확인했다. BACKLOG 가 2026-08-30 에
"인용 기준선이 HEAD 에 없다" 를 정정한 자리이기도 하다.

| | `baseline-6f0bcf0` (현행 판정) | `baseline-81098bb` (이력) |
| --- | --- | --- |
| 디스크 존재 | ✅ | ✅ |
| `manifest.label` | `baseline-6f0bcf0` | `baseline-81098bb` |
| `entries` | **170** | **170** |
| `thumbs` 실파일 수 | **170** (일치) | **170** (일치) |
| `failures` · `empties` · `activeDebugGates` | 전부 `[]` | 전부 `[]` |

판정 라벨의 단일 출처(`GoldenBaseline.currentLabel` = `"baseline-6f0bcf0"`)가 디스크와 맞고,
BACKLOG 가 "HEAD 에 없다" 고 정정한 `baseline-7075b74` 는 실제로 없다(정정이 옳다).
골든 오라클 5개 전건 통과 — `testBaselineIsCommittedAndLoadable` ·
`testBaselineHasNoBlackFrames` · `testDeterministicScenesHaveZeroSelfDiff` ·
`testNonDeterministicSceneCountIsPinned` · `testHistoricalBaselineStillLoads`.

즉 **매니페스트 항목 수 = 썸네일 실파일 수 = 170** 이고 실패 기록이 0 이다 —
"기준선이 있다고 적혀 있는데 실은 비어 있다" 부류의 결함은 없다.

### ✅ 검증 통과 — 정본 검증 커버리지에 구멍이 없다(58 중 45 검사, 13 제외는 의도적)

"검증기가 도는데 정작 어떤 정본 파일을 안 보고 있다" 는 부류를 찾았다. **없다.**

`spec/**/*.json` 58개 중 `validate.py` 가 검사하는 것은 45개다. 나머지 13개를 전수 확인했다:

| 제외 대상 | 성격 |
| --- | --- |
| `golden/snapshot/baseline-6f0bcf0/manifest.json` 외 9건 | 스냅샷 **캡처 산출물**(데이터) — 정본 항목 스키마가 아니다 |
| `golden/snapshot/nondet-2026-08-01/tsweep/{D,E}.json` | 비결정성 실험 산출물 |
| `spec/schema.json` | 검증기 자신의 **스키마** |

전건 정당하다. 그리고 **제외가 우연이 아니다** — `validate.py:345` 이 `is_canon_path(p)` 로
명시적으로 걸러내고, 몇 개를 건너뛰었는지 **출력에 찍는다**:

```
(정본 아님으로 건너뜀 13개 — golden/snapshot/ 캡처 산출물, schema.json)
```

즉 조용히 빠뜨리는 것이 아니라 **선언하고 빠뜨린다.** 이 리포가 다른 곳에서 반복해 물린
"모집단이 조용히 줄었는데 초록" 함정을 이 자리에서는 구조적으로 막고 있다.
(스냅샷 매니페스트는 검증기 대신 `GoldenBaselineOracleTests` 5개가 지킨다 — 위 항목 참조.)

**참고 — `spec/README.md` 는 파일 색인이 아니다.** 58개 중 이름이 나오는 것은 1개뿐이지만
이것은 결함이 아니다: 그 문서는 **규약 문서**(근거 필수 · 상태 3종 · 부정 결론의 표본 설계 ·
`weVersion` 고정)이고, 파일 열거는 `validate.py` 의 glob 이 담당한다. 색인 누락으로 오판하지 않도록 적어 둔다.

### ✅ 검증 통과 — 변경된 정본 8파일이 규약을 지킨다(근거 누락 0 · 교차검사 통과)

커밋되지 않은 변경이 정본 JSON 8개를 건드린다. `spec/README.md` 의 규약 1번이
"모든 항목에 `evidence` 필수" 이므로 전수 확인했다:

| 파일 | 항목 | 상태 분포 | 근거 누락 |
| --- | --- | --- | --- |
| `assets/material-schema.json` | 49 | 확정 46 · 추정 2 · 보고 1 | **0** |
| `corpus/workshop-shaders.json` | 17 | 확정 17 | **0** |
| `corpus/scene-schema.json` | 17 | 확정 16 · 보고 1 | **0** |
| `engine/uniform-feed.json` | 16 | 확정 12 · 보고 3 · 추정 1 | **0** |
| `formats/tex-deep.json` | 15 | 확정 11 · 추정 2 · 보고 2 | **0** |
| `engine/shape-quad.json` | 12 | 확정 12 | **0** |
| `engine/hdr-bloom.json` | 6 | 확정 6 | **0** |
| `engine/composite-refs.json` | 4 | 확정 3 · 추정 1 | **0** |

교차검사도 전부 통과한다(변경 후 상태에서 실행):

```
check_canon_generator_values.py : 생성기 40개 · 리터럴 대조 1,248건 · 불일치 0
check_canon_generator_keys.py   : 대조 333건 · 불일치 0
scripts/spec/tests/test_validate.py : Ran 47 tests … OK
validate.py                     : 오류 0 · 문서간 경고 0
```

즉 **정본 쪽 변경은 형식·교차일관성 면에서 깨끗하다.** H2 가 잡은 것은 이 축이 아니라
**모집단 크기가 실물보다 4 작다**는 축이고, 그것은 위 게이트들이 구조적으로 못 보는
사각지대다(그래서 `check_cited_address_census.py` 가 따로 존재한다).

### ✅ 검증 통과 — `AGENTS.md` 의 오디오 게이트 정정 수치가 전건 정확하다

커밋되지 않은 `AGENTS.md` 변경이 낡은 세 값을 정정하며 **자기 검증 명령을 함께 적는다**.
그 명령을 그대로 돌렸다:

| 주장 | 내 실측 | 판정 |
| --- | --- | --- |
| `skipUnlessAudioOutputCanPlay()` 사이트 **16** | **16** | ✅ |
| 서로 다른 테스트 함수 **16**(사이트당 1개, 중복 없음) | **16** (함수 본문 파싱으로 확인) | ✅ |
| 파일별 분포 `SceneAudioPlayerTests` **13** · `SceneEventHookTests` **2** · `SceneInteractionMediaE2ETests` **1** | **13 · 2 · 1** | ✅ |
| 그 셋의 `XCTAssertTrue(…isPlaying…)` 단언 **15** | **15** | ✅ |
| 베이스라인 스킵 **63** | **63**(전수 실행 실측) | ✅ |

즉 스킵 점프 예측 "63~64 → **79~80**"(63 + 16)도 산술이 맞는다.

> **[정정 2026-08-31 — 이 항목의 판정을 좁힌다.]** 위 표의 다섯 수치는 전부 맞지만,
> 같은 문단이 그 15 를 **"지금도 맞다"** 로 방어하는 논거는 **틀렸다** — 아래 **M15**.
> 즉 *현재 값*은 정확하고 *불변성 주장*이 거짓이다.

> **내가 처음 센 값은 16 이었고 그것이 틀렸다** — `grep -c 'isPlaying'` 이
> `PlaybackPolicyWiringTests.swift` 의 `XCTAssertTrue(code.contains("isPlayingAudio"))` 를
> 부분문자열로 잡았기 때문이다. 그건 **소스 텍스트 검사**이지 오디오 트랜스포트 단언이 아니고,
> 애초에 게이트가 걸린 세 파일 밖에 있다. 세 파일로 한정하면 정확히 15 다.
> 문서가 "그 셋의" 라고 범위를 명시해 둔 덕분에 판정이 갈리지 않았다 —
> 이 리포가 "수는 세는 법과 함께 적는다" 를 규약으로 삼는 이유가 여기서 그대로 드러난다.

### ✅ 검증 통과 — `validate.py` 변경은 **거짓 양성 1건을 없앤** 것이고 게이트를 약화하지 않는다

정본 검증기를 고치는 변경은 "게이트를 느슨하게 만든 것" 일 수 있어 A/B 로 확인했다.
HEAD 판본과 작업 트리 판본을 같은 트리에 돌렸다:

| 판본 | 결과 |
| --- | --- |
| HEAD | 오류 **0** · 문서간 경고 **1** · 헤지 27 |
| 작업 트리 | 오류 **0** · 문서간 경고 **0** · 헤지 27 |

없어진 경고 1건의 정체:

```
misc-schema.json:misc.corpusSharedAssetReferences: crossRef 가 없는 id 를 가리킨다 —
  'materials/util 상세 카탈로그는 spec/assets/material-schema.json 의 material.util.* 가
   정본이다. 여기서는 models/util 대조용으로만 같이 센다'
```

`crossRef` 값이 **산문 한 문단**인데 종전 파서가 그 문장 전체를 항목 id 로 보고 "그런 id 는
없다" 고 경고했다. 새 판본은 산문에서 id 패턴을 추출하고(`ID_IN_PROSE`), 공백이 든 문자열은
id 후보에서 제외한다(`not any(c.isspace() for c in t)`). **즉 거짓 양성을 없앤 것이고,
실제 끊긴 참조를 못 보게 만드는 변경이 아니다** — `check_canon_entry_refs.py` 가
독립적으로 "항목 간 참조 100건 · 끊긴 참조 0건" 을 보고하는 것과도 정합한다.

> **내 첫 측정이 틀렸다는 기록**: 처음에 HEAD 판본을 `/tmp` 에서 돌려 **오류 594건**을 봤고
> 잠깐 "게이트가 약화됐나" 로 의심했다. 원인은 판본 차이가 아니라 **작업 디렉터리**였다 —
> 그 검증기는 `evidence.ref` 와 `generatedBy` 를 **리포 상대경로**로 확인하므로 리포 밖에서
> 돌리면 전건 "근거를 따라갈 수 없다" 로 실패한다. 리포 안에서 돌리면 0 이다.
> (이 검증기의 그 성질 자체는 옳다 — 근거가 실재하는지 보는 것이 목적이다.)

### ✅ 검증 통과 — `CAST3X3` 이탈 기록이 모범적이다(이탈을 인정하고, 도달 0 을 증명하고, 값은 안 바꿨다)

커밋되지 않은 `GLSLTranslator.swift` 변경이 `we_cast3x3(float s)` 의 **근거가 틀렸다**고
스스로 정정한다. 종전 주석은 `// mat3(scalar)=대각(GLSL 단일 스칼라)` 였는데,
`CAST3X3` 은 GLSL 생성자가 아니라 **WE 컴파일러의 shim 매크로**라는 것이다.
**바이너리에서 직접 확인했다**:

```
$ python3 -c "b=open('binaries/wallpaper64.exe','rb').read(); print(b[0x486bf6:...])"
#define CASTI(x) ((int)(x))      #define CASTU(x) ((uint)(x))
#define CASTF(x) ((float)(x))    #define CAST2(x) ((float2)(x))
#define CAST3(x) ((float3)(x))   #define CAST4U(x) ((uint4)(x))
#define CAST4(x) ((float4)(x))   #define CAST3X3(x) ((float3x3)(x))   ← 오프셋 0x486cc9
```

파일 크기도 주석이 적은 **5,360,112 B** 와 일치하고, 인용한 오프셋 `0x486bf6` 이 정확히
그 shim 블록의 시작이다. 즉 **HLSL 캐스트**이므로 적용 규칙은 HLSL 의
Scalar→Matrix(replicate: 9성분 전부 s)이고, Waple 의 `float3x3(s)`(대각만)와 **다르다** —
정정의 판정이 옳다.

**결론(도달 0)은 옳다** — 스칼라 인자는 전 코퍼스에서 **정확히 1건**이고
(`shimmering_particles/shaders/particle.vert:98` `mRotation = CAST3X3(1.0);`),
그 파일은 **Waple 에 동봉되지 않았으며**(동봉 코퍼스에 `CAST3X3(1.0)` 0건 — 확인)
WE 안에서도 이중으로 죽어 있다(콤보 `TRAILRENDERER` 미정의 + 소비처 인자 개수 불일치).
행렬 인자는 다른 두 오버로드가 받는다. **그래서 값을 바꾸지 않은 결정은 옳다.**

> **다만 그 도달 열거의 도수 표는 틀렸다 — 병렬 워크플로가 지목했고 내가 확인했다(M12).**
> 주석은 범위를 "**동봉 WEAssets 502 셰이더 + 형제 코퍼스**" 라 적고 도수를
> `g_ModelMatrix 14 · g_Bones[…] 40 · g_ViewProjectionMatrix 5 · g_ModelMatrixInverse 3 ·
> g_EffectTextureProjectionMatrixInverse 1 · 스칼라 1` 로 적는데, 실측은 이렇다:
>
> | 인자 | 주석 | 동봉만 | 두 코퍼스 |
> | --- | --- | --- | --- |
> | `g_ModelMatrix` | 14 | **14** | 32 |
> | `g_Bones[…]` 합 | 40 | **48** | 96 |
> | `g_ViewProjectionMatrix` | 5 | **5** | 10 |
> | `g_ModelMatrixInverse` | 3 | **3** | 6 |
> | `g_EffectTextureProjectionMatrixInverse` | 1 | **1** | 2 |
> | 스칼라 `1.0` | 1 | **0** | **1** |
>
> **범위가 자기모순이다**: 행렬 도수는 **동봉만** 센 값인데, 스칼라 1건은 **형제에만** 있다.
> 즉 한 표 안에서 두 모집단을 섞었다. 게다가 동봉만으로도 `g_Bones` 는 40 이 아니라 **48** 이다
> (`a_BlendIndices.xyzw` 10×4 + `blendIndices.xyzw` 2×4). **결론은 흔들리지 않지만
> 검산이 불가능한 표**다 — 이 리포가 M2 에서 물린 것과 같은 뿌리(동봉 = 사본)다.

**이것이 이 리포가 이탈을 다루는 옳은 형태다** — ① 실물과 다르다는 것을 명시,
② 왜 안 고치는지(도달 0 · 소비처 없는 동작 변경) 를 수치로, ③ 되돌릴 조건과 짝 오라클
부재까지 기록. 감사에서 "결함" 으로 셀 자리가 아니다.

### ✅ 검증 통과 — `BACKLOG.md` 의 F402/F403 기준선 정정과 블룸 항목 갱신이 정확하다

`BACKLOG.md` 변경(+142)의 핵심 주장 세 개를 확인했다:

| 주장 | 실측 | 판정 |
| --- | --- | --- |
| 인용돼 있던 `baseline-7075b74` 는 **HEAD 에 없다**(하루만 존재) | `f96a59c6` 가 추가 → `0fa886c7` 가 삭제. 현재 디스크에 없음 | ✅ |
| F402/F403 을 닫은 산출물은 `baseline-81098bb` 다 | `git show --name-only c8734e5b` → `spec/golden/snapshot/baseline-81098bb/manifest.json` | ✅ |
| HDR 피라미드는 8레벨이고 `min(8, 허용 mip)` 로 클램프한다 | `HDRBloomPyramidPass.swift:31` `levels: Int = 8` · `:47` "n = min(parameters.levels, 소스 허용 mip 수, 배열 길이), n ≥ 2 필요" | ✅ |

즉 **"인용 기준선이 존재하지 않는다" 를 스스로 적발하고 실재하는 라벨로 고친 것**이고,
그 과정에서 판정 라벨의 단일 출처(`GoldenBaseline.currentLabel`)를 따로 명시한 것도 옳다
(내가 §골든 항목에서 독립 확인했다 — `baseline-6f0bcf0`, 매니페스트 170 = 썸네일 170).

**주목할 점 — 이 정정은 "해소" 를 과장하지 않는다.** 블룸 항목 ③(`strength CPU 변환규칙`)을
"통째로 해소" 로 적지 않고 **"피라미드 경로만 해소"** 로 절반만 닫으며 그 이유를 적는다.
이 리포에서 가장 자주 나는 실패(과대 해소 표기)를 저자가 스스로 피한 자리다.

### ✅ 검증 통과 — `docs/snapshot-regression.md` 의 "현행" 라벨 정정이 옳고, 중복을 되살리지 않았다

그 문서는 표 마지막 행을 `baseline-31fecaa (2026-08-02, 현행)` 으로 적고 있었다.
**`현행` 은 기준선 문서에서 절대 낡아서는 안 되는 단어**이므로 확인했다:

```
$ ls -d spec/golden/snapshot/*
  baseline-6f0bcf0   baseline-81098bb   nondet-2026-08-01   README.md
→ 31fecaa 는 없다.
$ grep -n 31fecaa spec/golden/snapshot/README.md
  :22  그 밖의 라벨(1eabf13 · 7075b74 · 618d16f · 31fecaa · f3a17da)은 …[HEAD 에 없다]
```

즉 **존재하지 않는 디렉터리를 "현행" 으로 가리키고 있었다**(문서 내부 모순도 있었다 —
같은 문서가 "HEAD 에는 현행 + 이식 전 이력 둘만 둔다" 고 적는다). 정정은 그것을
`이력` 으로 고쳤다.

**고친 방식이 특히 옳다 — 값을 다시 적지 않았다.** 정정문은 *"라벨 값을 여기 다시 적지
않는다 — 중복이 썩은 원인이다"* 라며 단일 출처(`GoldenBaseline.currentLabel`)와 그것을
읽는 `grep` 명령만 남긴다. 확인 결과 그 문서에서 `baseline-6f0bcf0` 이 나오는 자리는
**"실재하는 것은 …" 목록 1곳뿐**이고, "현행 = X" 형태의 중복은 되살아나지 않았다.
드리프트의 **원인**(같은 값을 두 곳에 적는 것)을 제거한 형태다.

## 4. 독립 검증 — RE 리포의 핵심 주장을 원본 바이너리 바이트에서 재확인했다 (전건 일치)

수정 대상이 아니라 **신뢰도 평가**다. `Waple-wallpaper-source` 의 핵심 수치는 Waple 소스
주석 수백 곳이 근거로 삼는 값이므로, 그것이 참인지 직접 쟀다. 원본 PE 를 파싱해 확인한 결과
**어긋난 값이 하나도 없었다.**

| 주장 | 출처 | 내 실측 | 판정 |
| --- | --- | --- | --- |
| 리치헤더 주입은 VA 를 밀지 않는다 | `spec/engine/decompilation-provenance.json` `decomp.richHeaderShift` 신호② | `.pdata` 함수 시작 **14,792개가 두 파일에서 비트동일**(`a == r` True). 8개 섹션의 VA·VSize 전건 동일 | ✅ 일치 |
| `e_lfanew` 는 0x40 → **0x240**(+512B), '208B 선행' 이 아니다 | 같은 항목 신호③ | 원본 `e_lfanew=0x40` · 주입본 `e_lfanew=0x240`. 차 **512B** | ✅ 일치 — 종전 208 근거 문장이 틀렸다는 정정이 옳다 |
| 산출물 7,748 중 **6,824** 가 보정 없이 `.pdata` 함수 시작과 일치 | 같은 항목 신호① | manifest 7,748개 중 `.pdata` 시작과 일치 **6,824** · 불일치 924 | ✅ **정확히 일치** |
| `.pdata` 엔트리 14,792개 | 여러 자리 | 12바이트 RUNTIME_FUNCTION × **14,792** | ✅ 일치 |
| 디컴파일 대상은 `wallpaper64_rich.exe` | `manifest.json` `program` | `program: wallpaper64_rich.exe`, `total: 7748` | ✅ 일치 |
| FileAlignment 0x200 / SectionAlignment 0x1000 | `analysis/pe-structure.md` | 두 파일 모두 `0x200` / `0x1000` | ✅ 일치 |

**의미**: "모든 주소가 +0xD0 밀린다" 는 전칭을 폐기하고 **개별 인용 17건 한정**으로 좁힌
2026-08-28~30 의 정정은 **바이트로 뒷받침된다.** 섹션 VA 가 비트동일한데 파일 오프셋만
0x200 씩 밀린 것(`.text` PtrRaw `0x400` → `0x600`)이 그 증거다 — 즉 변위는 리치헤더 주입이
아니라 폐기된 1세대 손상 코퍼스에서 온 것이라는 서술과 정확히 부합한다.

**따라서 H2 의 성격이 확정된다**: 정본의 *분류*는 옳고 *모집단 크기*만 4 만큼 낡았다.

---

### 🟡 M3 — 숫자 `0`/`1` 값을 가진 프로퍼티가 **`bool` 로 오타입**된다 (BACKLOG 의 combo 항목보다 넓고, 기전이 다르다)

BACKLOG 「잠재 결함」의 *"combo Picker 값-타입 불일치 → 편집기 무선택 표시"* 항목을
실행으로 재현했다. **증상은 실재하지만 BACKLOG 가 적은 원인은 틀렸다.**

- BACKLOG 서술: `WallpaperProperties.swift:67` — "옵션만 `type:""` 파싱"
- **실제 자리**: `Sources/WapleCore/WallpaperProperties.swift:198-202`, `parseValue` 의
  `default` 분기 **줄 순서**. (`:67` 은 주석 산문이고 코드가 아니다 — 인용이 드리프트했다.)

**재현 — 실제 파서를 `@testable import` 로 불러 실행했다**(프로브는 측정 후 삭제, 트리 무변경):

```
value 리터럴  1    -> bool(true)     ← 숫자인데 bool 이 됐다
value 리터럴  0    -> bool(false)    ← 같음
value 리터럴  2    -> number(2.0)    ← 2 는 정상
value 리터럴  1.5  -> number(1.5)    ← 정상
value 리터럴 "1"   -> string("1")    ← 정상
```

**기전** — Foundation 의 `NSNumber` 브리징이다:

```
JSON 1 을 파싱한 raw:  as? Bool = Optional(true)   as? Double = Optional(1.0)
JSON 2 을 파싱한 raw:  as? Bool = nil              as? Double = Optional(2.0)
```

`parseValue` 의 `default` 분기는 `as? String` → **`as? Bool`** → `parseNumber` 순서다.
`0`/`1` 은 `as? Bool` 에서 걸려 `parseNumber` 에 도달하지 못한다. 같은 파일의
`parseNumber` 는 이 함정을 **알고 있고** `CFGetTypeID(n) == CFBooleanGetTypeID()` 로
막지만, `default` 분기는 `parseNumber` 를 부르기 **전에** `as? Bool` 을 먼저 쓴다 —
즉 방어가 있는데 그 앞에서 새는 구조다. 같은 파일 `:193-194` 주석이 `slider` 경로에서
정확히 이 브리징 함정을 **문서화하고 회피**한다("NSNumber(bool) 이 Swift 에서 `as? Double`
로도 브리지되어 … parseNumber 의 CFBoolean 배제를 무력화한다"). `default` 분기에는
그 교훈이 적용되지 않았다.

**combo 에서의 결과**: 옵션 `value` 는 실물에서 전건 문자열(`"0"`/`"1"`)이므로,
프로퍼티 `value` 가 숫자 `1` 이면 `bool(true)` vs `string("1")` 이 되어 **어느 옵션과도
일치하지 않는다** — Picker 무선택. 실행으로 확인:

```
key=modeStr value=string("1")  options=[string("0"), string("1")]  -> 일치 true
key=modeNum value=bool(true)   options=[string("0"), string("1")]  -> 일치 false
```

**영향 범위 — 정직하게 좁다. 실물 코퍼스에서는 발화하지 않는다.**
설치본 21 `project.json` 을 직접 세어 확인했고, 이 파일 자신의 census 주석과 일치한다:

| 타입 | value 의 JSON 타입 (내 실측) | 파일 주석의 census |
| --- | --- | --- |
| `color` | str 42 | 전건 문자열 |
| `slider` | int 15 · float 1 · str 1 | {int 15, float 1, 문자열 1} |
| `combo` | **str 14 (전건)** | **combo 전건 문자열** |
| `bool` | bool 6 · str 1 | {bool 6, 문자열 1} |

즉 **설치본 combo 14건은 전부 문자열이라 지금 이 버그를 밟지 않는다.**
`slider` 의 int 15건도 `"slider"` 분기가 `parseNumber` 를 먼저 부르므로 안전하다.
발화 조건은 **`default` 분기로 들어오는 타입(combo·textinput·file·…)의 `value` 가
JSON 숫자 0 또는 1 인 경우**이고, 그것은 워크샵 코퍼스(446 폴더, 이 맥에 없음 — F400)에서만
나올 수 있다. 그래서 심각도를 medium 으로 둔다: **BACKLOG 의 트리거 규약("실제 파일·사용에서
물릴 때") 그대로가 맞다.**

**BACKLOG 서술에 대한 정정 2건**:
1. 원인 위치가 `:67`(주석) → 실제는 `:198-202`(`parseValue` default 분기 순서).
2. "옵션만 `type:""` 파싱" 은 원인이 아니다. 옵션에 `type: ""` 을 주는 것(`:161`)은
   **옵션 값을 문자열로 보존하므로 오히려 올바른 쪽**이다 — 옵션 `value` 는 실물이
   문자열이고 `default` 분기가 `as? String` 을 가장 먼저 보기 때문이다. 깨지는 쪽은
   **프로퍼티 본체의 `value`** 다(`:166`, `type: type` 을 넘기지만 `combo` 는 `default` 로 떨어진다).
   즉 고칠 자리는 옵션이 아니라 `default` 분기의 `as? Bool` 위치다.

---

### ✅ 검증 통과 — WE 설치본 정본이 **암호학적으로** 정확하다(트리 다이제스트 재현)

`spec/we-install-tree.json` 은 WE 2.8.42 설치본의 서브트리 4개를 파일 수·총 바이트·
**SHA256 트리 다이제스트**로 고정한다. 삭제 예정이던 리포의 트리를 나중에 대조하기 위한
지문이므로, 그것이 실제로 맞는지가 이 정본의 존재 이유다. **전건 재현했다**:

| 서브트리 | 파일 수 (정본) | 실측 | 총 바이트 (정본) | 실측 |
| --- | --- | --- | --- | --- |
| `ui` | 1,548 | **1,548** ✅ | 330,788,306 | **330,788,306** ✅ |
| `locale` | 75 | **75** ✅ | 8,170,689 | **8,170,689** ✅ |
| `projects` | 999 | **999** ✅ | 149,381,680 | **149,381,680** ✅ |
| `assets` | 2,940 | **2,940** ✅ | 79,515,997 | **79,515,997** ✅ |

합계 **5,562 파일 · 567,856,672 B 가 정확히 일치**한다.

그리고 트리 다이제스트를 생성기의 레시피
(`measure_we_install_tree.py:76-80` — 정렬된 `(상대경로\0크기\0sha256\n)` 연쇄의 SHA256)로
직접 계산했다:

```
locale : 88cfd222b2ef8ceecb6a18e72db454f1c57169b16b224bb22861a108bd247779   = 정본 ✅
assets : 2a0ec17ebc6d26a32984fe3db685f083617f5a53f20741ca447abdc6eb04ac95   = 정본 ✅
```

**바이너리·동봉에셋 지문도 전건 일치한다**:

| 정본 | 대상 | 결과 |
| --- | --- | --- |
| `spec/binaries-fingerprint.json` | WE 바이너리 **8종** (SHA256 + 파일 크기) | **8/8 일치**, 불일치 0 |
| `spec/assets/manifest.json` | 동봉 `WEAssets` 파일 **2,940개** | **2,940/2,940 일치**, 불일치 0 · 부재 0 |

**3,015개 파일의 내용 해시가 전부 맞아야만 나오는 값이다** — 즉 짝 저장소의 설치본은
정본이 측정한 바로 그 트리이고, 그 사이 한 바이트도 바뀌지 않았다. 이 정본의 목적
("삭제 후에도 다시 구한 2.8.42 가 같은 것인지 대조할 수 있다")이 실제로 달성돼 있다.

## 5. wallpaper-source (RE 리포) — 커밋되지 않은 변경 검증

`Waple-wallpaper-source` 도 작업 트리가 더럽다: **13파일 · +940/-99**, 추적되지 않은 파일 0.
Waple 쪽과 달리 **여기서는 결함을 찾지 못했다** — 오히려 커밋되지 않은 변경이
기존 결함을 고치고 있고, **그 수정이 실제로 동작하는지 실행으로 확인했다.**

### ✅ 검증 통과 — `scripts/inject_rich_header.py` 의 변위 탐지 강화가 실제로 작동한다

이 스크립트는 RE 파이프라인의 **신뢰 기반**이다. Ghidra 가 MSVC 를 인식하도록 리치헤더를
주입하는데, 주입이 섹션을 밀면 **디컴파일 산출물 7,748개의 이름이 전부 틀어진다**
(2026-08-26 에 실제로 일어났고, 그것이 H2 의 −0xD0 인용들이 남은 이유다).

커밋되지 않은 변경은 "`.pdata` 에 의존하지 않는 변위 교차검사" 를 추가하면서, 종전에는
`.pdata` 없는 PE32 가 밀려도 **초록으로 통과했다**고 적는다. **그 주장을 직접 재현했다** —
`wallpaper_engine/wallpaper32.exe`(PE32 · 6섹션 · `.pdata` 없음)의 모든
`PointerToRawData` 에 `+0x200` 을 더한 사본을 만들어 판정기를 돌렸다:

| 대상 | `.text` 첫 바이트 | 판정 | 종료코드 |
| --- | --- | --- | --- |
| 원본(대조군) | `6a 38 e8 c9 a1 20 00 83` ← 진짜 코드 | `[ok]` | **0** |
| `+0x200` 변위 사본 | `07 00 00 00 c7 05 fc 96` ← 명령 중간 | `[!] .reloc block chain is inconsistent … section file offsets are displaced` | **1** |

**세 가지가 확인된다**:
1. 변위본의 첫 바이트가 diff 가 인용한 값(`07 00 00 00 c7 05 fc 96`)과 **정확히 일치**한다 —
   즉 그 주석의 실측 기록이 정직하다.
2. `[ok] 6/6 sections aligned to FileAlignment 0x200` 이 **변위본에서도 초록**이다 —
   0x200 배수 변위라 정렬 검사로는 못 잡는다는 서술이 맞다. 새 `.reloc` 검사만이 잡는다.
3. 새 검사가 **종료코드 1** 을 낸다 — 판정기가 실제로 빨강을 낸다.

또한 실제 주입본 `binaries/wallpaper64_rich.exe` 에 대해 전건 초록임을 확인했다:
`.pdata 14792/14792 (100.00%)` · `.reloc 60 blocks tile 0x2e2c bytes exactly` ·
`8/8 sections aligned`. 즉 **강화가 오경보를 만들지 않는다**(원본·주입본 둘 다 초록,
변위본만 빨강).

### ✅ 검증 통과 (Waple 쪽) — `macos-test-typecheck.sh` 의 "초록인데 아무것도 안 한" 결함 수정이 옳다

C1 과 **같은 부류**의 결함을 커밋되지 않은 변경이 고치고 있다: 판정이 도구의 종료코드가
아니라 로그 매치 수에만 걸려 있어, 도구가 아예 안 돌아도 초록이 나오는 구조.

종전 코드는 `swiftc -typecheck … 2>&1 | grep ': error:'` 로 **파이프해서 `swiftc` 의
종료코드를 통째로 잃었다.** 판정은 매치 줄 수 `n == 0` 하나였다.
**주장을 직접 재현했다**(Swift 6.4 / arm64, 이 맥):

```
$ swiftc -typecheck -module-name Probe --bogus-flag-xyz -sdk "$SDK" /dev/null; echo rc=$?
error: unknown argument: '--bogus-flag-xyz'
rc=1
$ ... | grep -c ': error:'
0            ← 매치 0건
```

**핵심**: 드라이버의 인자 파서가 내는 진단은 `error: unknown argument…` 로
**`: error:` 접두사가 없다**(`<unknown>:0:` 도 `file:line:col:` 도 붙지 않는다).
그래서 `grep ': error:'` 가 못 잡는다. 두 로직을 같은 입력에 적용하면:

| 로직 | 판정 |
| --- | --- |
| 종전 (`n == 0` → 통과) | **✓ 통과** ← 틀렸다. rc=1 이고 타입체크는 한 건도 안 했다 |
| 수정본 (`rc != 0 && n == 0` → 하드 실패) | **✗ 정확히 잡는다** |

즉 이 스크립트는 "Xcode 없는 맥에서의 유일한 커밋 전 그물"(`docs/README.md` 의 표현)인데,
드라이버 인자가 하나만 낡아도 **7개 타깃 전부 `✓` 를 찍고 rc=0** 으로 끝나는 상태였다.
수정은 `raw` 를 먼저 받고 `rc` 를 별도로 보존한다 — 파이프를 쓰면 통과 케이스에서
`$?` 가 grep 의 no-match rc=1 이 되어 거짓 실패한다는 것까지 주석에 적혀 있고, 그 서술도 옳다.

**C1 과의 관계**: 같은 라운드가 **이 부류를 한 곳에서는 고치고(typecheck) 다른 곳에서는
새로 만들었다(census 하한 3875)**. 두 결함의 형태가 동일하다 — *판정 신호를 로그에서
뽑는데 그 뽑는 법이 실제 출력 형태와 어긋나 있다.*

> **[정정 2026-08-31] 그 수정의 주석 한 문장은 틀렸다 — 넷 중 하나가 반례다(→ M24).**
> 주석은 *"프론트엔드가 내는 진단은 접두사가 붙어 원래도 잡혔다(`-swift-version 9` ·
> 없는 `-sdk` · 잘못된 트리플 · 없는 입력 파일 = **전부 매치 ≥1**)"* 라고 적는다.
> 실제 Swift 파일로 넷을 각각 돌렸다:
>
> | 주입 | rc | `': error:'` 매치 | 첫 줄 |
> | --- | --- | --- | --- |
> | `-swift-version 9` | 1 | **1** ✅ | `<unknown>:0: error: invalid value '9'…` |
> | 없는 `-sdk` | 1 | **1** ✅ | (warning + 후속 error) |
> | **잘못된 트리플** | 1 | **0** ❌ | `error: unknown target 'bogus-triple'` — 접두사 없음 |
> | 없는 입력 파일 | 1 | **1** ✅ | `<unknown>:0: error: error opening input file…` |
>
> 즉 **"전부" 가 아니라 3/4** 다. 잘못된 트리플은 드라이버가 맨 `error: ` 로 내므로
> 새로 추가된 `rc != 0 && n == 0` 분기가 **바로 그것을 잡는 유일한 그물**이다 —
> **수정 자체는 오히려 주석보다 더 필요했다.** 서술만 과장됐다.

### ✅ 검증 통과 — TEXS 디스패치 정정을 **원본 바이너리 디스어셈블로** 전건 확인했다

`WE-ENGINE-ANALYSIS-2026-07-27.md` 의 커밋되지 않은 변경 중 가장 중요한 것은
"`TEXS0003` 이 루프를 끝낸다" 는 종전 판독을 **정반대로 정정**한 것이다. 이 문서가
그 폐기된 판독의 **마지막 생존 사본**이었다고 적는다(형제 산출물 2개는 2026-08-28 에 정정됨).

정정문이 바이트를 인용하므로, `binaries/wallpaper64.exe`(**주입 안 된 원본**)에서
섹션 테이블로 VA→파일오프셋을 매핑해 직접 읽었다. **전건 일치**:

| VA | 문서가 주장한 바이트 | 원본에서 읽은 값 | 판정 |
| --- | --- | --- | --- |
| `0x14015e7e0` | `41 b8 04 00 00 00` | `41 b8 04 00 00 00` | ✅ (`mov r8d, 4`) |
| `0x14015e7e6` | `48 8d 15 f3 d0 32 00` | `48 8d 15 f3 d0 32 00` | ✅ (`lea rdx,[rip+0x32d0f3]`) |
| `0x14015e7f9` | `75 70` | `75 70` | ✅ (`jnz`) |
| `0x14015e811` | `e8 ba f9 ff ff` | `e8 ba f9 ff ff` | ✅ (`call`) |

분기·참조 대상을 직접 계산해도 전건 맞는다:

```
lea  대상 VA = 0x14048b8e0   (주장 0x14048B8E0)  ✅
  그 자리의 문자열 = b'TEXS0003\x00\x00\x00\x00'   ← 태그 실물 확인
call 대상 VA = 0x14015e1d0   (주장 0x14015e1d0)  ✅
jnz  대상 VA = 0x14015e86b   (주장 0x14015e86b)  ✅
```

**논리도 맞다**: `_strnicmp` 는 일치 시 0 을 반환하므로 `jnz` 가 **취해지는** 쪽이
불일치 팔이고, 그 팔이 루프를 떠난다. `0x14015e1d0`(스프라이트시트/프레임테이블 파서)은
**일치할 때만** 도달한다. 즉 `TEXS0003` 은 루프를 끝내지 않고 **파싱된다** — 정정이 옳다.

**영향**: 문서 전용 결함이다(`No shipping code was wrong`). 그 주장도 확인했다 —
`Sources/WapleCore/TexImage.swift:859-880` 이 세 분기(`TEXI0001`→`0x14015c760` ·
`TEXB0004`→`0x14015c8d0` · `TEXS0003`→`0x14015e1d0`)를 내가 위에서 검증한 VA 그대로
적고 구현한다. 종전 판독대로 구현했다면 애니메이션 TEX 전건이 정지 1프레임으로 떨어진다 —
문서 결함을 코드에 새기기 전에 잡은 사례다.

**그 파일의 코퍼스 실측도 독립 재현했다 — 전건 일치**:

| `TexImage.swift` 주석의 주장 | 내 실측 (설치본 `.tex` 전수 워크) |
| --- | --- |
| 동봉 311 + 설치 129 = **440건 전수** | `.tex` **440** 개 발견 |
| TEXS 를 가진 **61건** | `b"TEXS000"` 포함 **61** 건 |
| TEXS 없는 **379건**에서 우연 일치 **0건** | 미포함 **379** 건 |

역방향 스캔의 안전성(그 파일이 엔진과 의도적으로 이탈하는 지점)도 검증했다:
**`TEXS000` 이 2회 이상 나오는 파일 0건**, **첫 출현 ≠ 마지막 출현인 파일 0건**.
즉 이 코퍼스에서 역방향 스캔과 순차 파스는 **결과가 증명적으로 같다**.
그리고 그 주석은 한계도 정직하게 적는다 — *"오탐이 불가능하다는 증명은 아니다"*,
조건 변형(`TEXB0004 variantCount>0`) 표본이 이 코퍼스에 0건이고 워크샵 8건은 확인 불가.
**그 한계 서술까지 맞다**(전 440건 `variantCount==0` 이라 꼬리가 항상 TEXS 다).

### ✅ 검증 통과 — `evidence-index.tsv` 의 `rtti_classes` 열 폐기 판정이 정확하다

같은 문서가 자기 산출물의 한 열을 "**작동하지 않는다 — 비어 있는 것으로 읽어라**" 로
폐기한다. 자기 도구를 부정하는 주장이라 특히 검증할 값어치가 있다. **전건 재현했다**:

| 주장 | 내 실측 (`analysis/decompiled/evidence-index.tsv`, 7,748행) |
| --- | --- |
| `rtti_classes` 비어 있지 않은 행 **5,584** | **5,584** ✅ |
| 그중 **4,735** 가 자기 행의 Ghidra 라벨을 담는다 | `rtti_classes == name` 인 행 **4,735** ✅ |
| WE 엔진 클래스명이 **하나도 없다** | `FUN_` 이 아닌 값 612건이 전부 `DLL` 또는 `DLL;FUN_…` 꼴 — 엔진 클래스명 0건 ✅ |
| `format_magics` 14 · `api_calls` 44 · `key_strings` 33 은 건전하다 | 각각 **14 · 44 · 33** ✅ |

즉 그 열은 "함수가 참조하는 RTTI 클래스" 를 담기로 했는데 실제로는 **자기 이름을 되쓰고
있었다**(생성기 버그). 이 감사의 좌표들이 실제로 의존하는 열(`format_magics`·`api_calls`·
`key_strings`)의 도수는 정확하다. **문서가 자기 도구의 결함을 정확한 수치와 함께 스스로
폐기한 것이고, 그 수치가 전부 맞다.**

### ✅ 검증 통과 (일부 수치 정밀도 지적) — 링커 버전 정정과 RTTI 부재 결론

**(a) 링커 버전 정정이 맞다.** `analysis/pe-structure.md` 가 `14.0` → **`14.51`** 로 고쳤다.
`binaries/wallpaper64.exe` 의 옵셔널 헤더에서 직접 읽었다:

```
MajorLinkerVersion = 14
MinorLinkerVersion = 51      →  14.51   ✅ (폐기된 14.0 아님)
```

**(b) RTTI 부재 결론이 맞다 — 다만 "11개" 라는 수치는 부정확하다.**
§7 은 *"Only 11 standard TypeDescriptors exist … referenced 0 times"* 로 적고,
`analysis/rtti-vtables.json` 의 빈 `{}` 가 결함이 아니라 **확인된 결과**라고 주장한다.
바이너리에서 MSVC TypeDescriptor 이름(`.?AV`/`.?AU` … `@@`)을 전수 추출했다:

| 분류 | 개수 |
| --- | --- |
| 고유 TypeDescriptor 이름 | **106** |
| 그중 람다·템플릿 클로저(`_Binder`·`?$` 등) | 61 |
| 비템플릿("standard") | **45** |

**결론은 그대로 유지된다** — 45개 전건이 CRT/STL(`bad_alloc` · `runtime_error` ·
`ios_base` · `locale` …), DirectWrite/D2D(`IDWriteFontFileLoader` · `ID2D1Simplified…`),
COM(`IUnknown`), `type_info` 다. **WE 엔진 클래스(`SceneWallpaper` · `VideoWallpaper` 등)의
TypeDescriptor 는 0개**다. 즉 "`/GR-` 로 빌드돼 자체 폴리모픽 클래스의 RTTI 가 없다" 는
판정과 `rtti-vtables.json = {}` 이 **정당하다.**

> **지적(경미)**: 그 "11" 은 재현되지 않는다 — 세는 기준을 적지 않았기 때문이다
> (비템플릿 45 · `IUnknown`+IDWrite 계열만 6 · `type_info` 1 …). 이 리포의 규약이
> "수는 세는 법과 함께 적는다" 이므로, 이 자리도 같은 규약을 적용하면 좋겠다.
> **결론에는 영향 없다**(어느 기준으로 세도 엔진 클래스는 0개).

### 🟡 M7 — 디컴파일 실패 3건이 `manifest.json` 에만 기록되고 **산문 문서에는 없다** — 그중 하나가 파티클 오퍼레이터 VM 이다

- **성격**: RE 산출물의 한계 미기록. 결함은 아니지만 **다음 사람이 헛발질하는 자리**다.

`analysis/decompiled/all/` 7,748개를 전수 훑어 **본문이 없는(헤더 주석만) 파일**을 셌다:

| 파일 | 크기 | manifest 의 `size` | manifest 의 `decompiled` |
| --- | --- | --- | --- |
| `000000014023fbc0__FUN_14023fbc0.c` | 66B | 542 | **false** |
| `0000000140300680__FUN_140300680.c` | 66B | 422 | **false** |
| `00000001401c5490__FUN_1401c5490.c` | 68B | **49,248** | **false** |

**`manifest.json` 은 정직하다** — 세 건 전부 `decompiled: false` 로 표시돼 있고,
7,748 중 3건이라 성공률 99.96% 다. 그 자체로는 흠이 아니다.

**문제는 그중 `FUN_14023fbc0` 이 파티클 오퍼레이터 VM 이라는 것이다.**
이 감사의 H3·H4(실동작 결함 2건)가 전부 그 함수 안에 있다. 즉 **가장 결함이 많이 나온
함수가 디컴파일되지 않은 3건 중 하나**이고, 디컴파일 C 만 읽는 사람에게는 이 코드가
존재하지 않는 것처럼 보인다. 실제로 H3 은 `docs/re/particle-operator-vm.md` 가 옳은 식을
갖고 있는데도 코드가 6개월간 틀린 채였다 — 검증하려면 직접 디스어셈블해야 하기 때문이다.

**어느 산문 문서도 이 사실을 적지 않는다**(`WE-ENGINE-ANALYSIS` · `analysis/reports/**` 전수 grep 0건).
`WE-ENGINE-ANALYSIS` §8 의 산출물 색인은 "7,748 함수" 를 성공 수처럼 제시하고,
§7 이 RTTI 한계를 적는 것과 달리 **디컴파일 실패 목록은 어디에도 없다.**

**규모를 쟀다 — 이것이 이 항목을 medium 으로 올리는 이유다.**
세 번째 실패건 `FUN_1401c5490`(49,248B)은 **파티클 시스템 JSON 파서 팩토리**다
(`spec/engine/render-state.json:942` 가 "0x1401c5490(파티클 시스템 JSON 파서)" 로 명명).
즉 **디컴파일되지 않은 3건 중 2건이 파티클 서브시스템의 심장**이다 —
오퍼레이터 VM(`0x14023fbc0`–`0x14024bace`)과 파서 팩토리(`0x1401c5490`–`0x1401d152c`).

두 범위 안으로 떨어지는 Waple 쪽 주소 인용을 전수로 셌다:

| 대상 범위 | Waple 의 인용 수 | 인용하는 파일 수 |
| --- | --- | --- |
| 오퍼레이터 VM | **1,001** | 28 |
| 파서 팩토리 | **1,277** | 38 |
| 합계 | **2,278** | 66 (중복 제외) |

**즉 이 포트가 가장 많이 근거로 삼는 두 함수가, 디컴파일 C 로는 한 줄도 확인할 수 없다.**
`Sources/WapleCore/ParticleSimulator.swift` · `ParticleSystem.swift` · `RemapOperation.swift` ·
`ParticleControlPointFrame.swift` 와 그 테스트들이 전부 여기 의존한다.

**선행 기록이 하나 있다** — `docs/swarm-audit-2026-08-26.md:55` 가 이미 같은 사실을 관찰했다:
*"오퍼레이터 VM 0x14023fbc0–…, 파서 팩토리 0x1401c5490–… 가 모두 존재한다. 그러나
`analysis/decompiled/all/` … 그 주소대에는 `FUN_14023fc90` 하나(39바이트 stub)만 있고"*.
그 관찰이 **RE 리포의 산문 문서로 이관되지 않았다** — `WE-ENGINE-ANALYSIS` §8 의 산출물
색인은 여전히 "7,748 함수" 를 성공 수처럼 제시한다.

**중요 — 그 2,278건이 틀렸다는 뜻은 아니다. 표본으로 검증했고 정확했다.**
`spec/engine/render-state.json:942` 가 파서 팩토리 안의 호출부를 **11곳** 열거한다
(`0x1401cb884` · `0x1401cc43c` · `0x1401cc7da` · `0x1401cc9be` · `0x1401ccf66` ·
`0x1401cd194` · `0x1401cd407` · `0x1401ce3d6` · `0x1401ce64b` · `0x1401cf11c` · `0x1401cf1dc`).
디스어셈블로 전건 확인했다:

```
11/11 이 `call 0x1401c2a40` 이다 — 하나도 어긋나지 않았다.
(주변 명령까지 동형: `mov r8, r1x` / `mov rdx, rdi` / `call`)
```

즉 **디컴파일이 실패한 구간의 인용도 실제로는 정확하다** — 저자가 디스어셈블로 확인했다는
뜻이다. 이 항목의 위험은 "인용이 틀렸다" 가 아니라 **"검증 경로가 문서화되지 않았다"** 다:
다음 사람이 `analysis/decompiled/all/` 에서 그 함수를 찾으면 빈 파일을 보고 근거가
사라졌다고 오판한다(그리고 H3 처럼 6개월간 코드가 문서와 갈린 채 남는다).

**기록해야 할 것**(수정 금지 지시에 따라 적기만 한다): ① 3건의 주소와 그중 2건이 파티클
서브시스템의 핵심이라는 사실, ② 그 함수를 볼 때는 **디스어셈블이 유일한 경로**라는 것,
③ 재현 도구가 있다는 것(`capstone` + `pefile` — 이 세션에서 H3·H4 를 실제로 그렇게 확인했다.
`imagebase 0x140000000`, VA→파일오프셋은 섹션 테이블로 매핑), ④ `manifest.json` 의
`decompiled: false` 플래그가 이미 정직하게 표시하고 있으므로 **산문은 그것을 인용하면 된다.**

### ✅ 검증 통과 (관찰 1건 첨부) — 두 리포에 이중으로 존재하는 정본 `playback-policy.json` 이 현재 완전히 일치한다

`spec/engine/playback-policy.json` 은 **두 리포 모두에 있다**(RE 리포의 유일한 정본 파일이다).
같은 값을 두 곳에 두는 형태는 이 감사에서 이미 드리프트 원인으로 확인된 패턴이므로
(M5 · `docs/snapshot-regression.md` 의 "현행" 라벨) 대조했다:

```
Waple 항목 12  ·  RE 리포 항목 12
한쪽에만 있는 id: 없음
공유 id 중 value 가 완전히 동일: 12 / 12   (차이 0)
```

**현재는 어긋나지 않았다.** Waple 쪽 `check_playback_policy.py` 도 통과한다
(정본 12항목 ↔ `Sources/WaplePolicy/PlaybackPolicy.swift` 대조).

> **관찰(결함 아님)**: 그 게이트는 **Waple 안의 정본 ↔ Swift 구현**만 본다 —
> 짝 저장소 사본과의 일치는 **아무도 검사하지 않는다**(`check_playback_policy.py` 에
> 짝 저장소 경로 언급 0건). 지금 12/12 로 맞는 것은 유지된 결과이지 보장이 아니다.
> 한쪽만 갱신되면 조용히 갈린다 — M11 이 지적한 "리포 밖 근거는 검사되지 않는다" 와 같은 축이다.

### ✅ 검증 통과 — `subsystems-identified.md` 의 "이름은 맞고 좌표가 틀렸다" 정정이 정확하다

이 정정은 미묘한 구별을 한다: `Texture::ReadTextureData` 라는 **이름은 철회하지 않고**,
그것에 붙어 있던 좌표 `0x4e02d3` 이 **코드 주소가 아니라 디스크립터 이름 텍스트의 파일
오프셋**(xref 0건)이라고 재판정한다. 세 좌표를 원본 바이너리에서 직접 읽어 확인했다:

| 정정문의 주장 | 실물 바이트 | 판정 |
| --- | --- | --- |
| `0x4e02d3` 은 디스크립터 **이름 텍스트**다(코드 아님) | `…??ReadTextureData@Texture@@IEAAPEAV?$Ref…` — **망글된 심볼 문자열** | ✅ |
| TEX 태그 4종이 `0x48a6e0`–`0x48a710` 에 있다 | `TEXS0003`·`TEXB0004`·`TEXI0001`·`TEXV0005` 가 16B 간격으로 연속 | ✅ |
| `LZ4 error.` @ `0x4851f8` | `b'LZ4 error.\n\x00…'` | ✅ |

즉 그 자리는 **RTTI/코드가 아니라 문자열 테이블**이고, "컨테이너 워커는 `0x14015e580`(VA)" 로
좌표를 옮긴 재판정이 옳다. 파일 오프셋과 VA 를 섞어 쓰던 것을 정리한 것이며,
**내 첫 해석 정정**: 그 덤프의 `TEXV0005` 를 "네 번째 섹션 태그" 로 읽었는데 **틀렸다** —
`TEXV0005` 는 **파일 매직**이고 Waple 이 정확히 그것으로 파일을 판정한다
(`TexImage.swift:558` `b[0..<8].elementsEqual("TEXV0005")`). 섹션 태그는 TEXI/TEXB/TEXS 셋이다.
그 파일은 `TEXV0004` 도 엔진이 받는다는 것까지 적고(memcmp `0x14015e8c5`), **의도적으로
거부**한다 — 근거가 정직하다: *"동봉 311/311 · 설치 projects 129/129 · 워크샵 4,991/4,991 이
전부 0005 라 실물 표본이 없고, 표본 없이 두 번째 레이아웃을 쓰면 검증할 수 없는 코드가 된다."*
(그 셋 중 앞의 두 수는 내가 독립적으로 확인했다: 동봉 `WEAssets` **311** · 설치본
`projects` **129** = 440. 그리고 설치본 `assets` 도 **311** 이라 동봉본이 그 사본임을
다시 확인한다 — M2 가 다루는 이중계수(`172 = assets 씬 사본`)와 **같은 뿌리**다.)

### 관찰 — `corpus_scan/pkgv_census.py` 의 "입력 0 이면 산출물 파괴" 수정도 같은 성격

종전에는 하드코딩된 `Z:\SteamLibrary\...` 경로가 없는 머신에서 돌리면 **산출물 4개를
헤더만 남기고 덮으며 종료코드 0** 을 냈다(즉 커밋된 근거를 파괴하면서 성공 보고).
커밋되지 않은 변경이 `WE_WORKSHOP` 환경변수화 + **산출물을 열기 전** 입력 검사 +
종료코드 2 로 고쳤다. 이 방향은 형제 리포의 규약(`measure_*.py` 의 `WE_WORKSHOP`/`WE_ROOT`)과
일치한다. **다만 워크샵 코퍼스가 이 맥에 없어 실행 검증은 못 했다** — 스크립트 자신이
그 사실을 주석에 적는다(`.pkg` 0건, `.pak` 446개는 CEF 리소스로 무관).

### ✅ 검증 통과 — Frida 훅의 D3D11 서명·vtable 슬롯 정정이 1차 자료·실행 로그와 일치한다

`scripts/hook_d3d11_quick.js` 의 커밋되지 않은 변경은 두 부류를 고친다. **양쪽 다
독립적으로 확인했다.**

**(a) `D3D11CreateDevice` 인자 인덱스** — 종전 코드는 `args[5]`/`args[6]`/`args[7]` 을
읽었고, 주석이 12인자 서명(`const D3D11_LAYER_DESC*` 를 끼운 것)을 전제했다.
그 서명은 **존재하지 않는다**. 실제는 10인자다:

```
[0] pAdapter  [1] DriverType  [2] Software  [3] Flags  [4] pFeatureLevels
[5] FeatureLevels  [6] SDKVersion  [7] ppDevice  [8] pFeatureLevel  [9] ppImmediateContext
```

- **리포 내부 교차확인**: `scripts/hook_d3d11_v17.js:24-27` 이 **처음부터 이 표를 정확히
  적고 있다**(직접 읽어 확인). 즉 같은 리포 안에 옳은 판본과 틀린 판본이 공존했고,
  이번 변경이 틀린 쪽을 옳은 쪽에 맞춘 것이다.
- **1차 자료 확인**: Microsoft 공식 문서의 `D3D11CreateDevice` 매개변수 순서가
  `pAdapter · DriverType · Software · Flags · pFeatureLevels · FeatureLevels · SDKVersion ·
  ppDevice · pFeatureLevel · ppImmediateContext` 로 위 표와 일치한다.
  종전 코드의 `Flags=args[7]` 은 실제로는 `ppDevice` 를 플래그로 인쇄하고 있었다.

**(b) `ID3D11Device` vtable 슬롯** — 종전 표는 4자리가 틀렸다
(`5:CreateBuffer` · `8:CreateTexture2D` · `9:CreateTexture3D` · `47/48:VS/PSSetShader`).
`47`/`48` 은 애초에 `ID3D11DeviceContext` 의 메서드이고, `ID3D11Device` vtable 은
43항목(0..42)뿐이라 **표 끝을 넘어 인접 힙을 읽는 좌표**였다.

**이 정정은 그 리포 자신의 실행 로그가 증명한다** — `analysis/d3d_scan.log:297-298` 을
직접 읽었다. 실제 WE 프로세스에 Frida 를 붙여 vtable 을 스캔한 기록이다:

```
*** HOOKING REAL DEVICE vtable @ 0x63a41000 ***
[+] hooked CreateBuffer (vt[3] @ 0x63a8f730)
[+] hooked CreateTexture2D (vt[5] @ 0x63a71770)
[+] hooked CreateVertexShader (vt[12] @ 0x63b20af0)
[+] hooked CreatePixelShader (vt[15] @ 0x63a6b460)
```

`vt[3]=CreateBuffer` · `vt[5]=CreateTexture2D` — **정정된 값과 정확히 일치**하고,
종전 값(`5=CreateBuffer`·`8=CreateTexture2D`)과는 어긋난다. `scripts/hook_d3d11_validate.js:150`
도 `{3:'CreateBuffer', 5:'CreateTexture2D', 12:'CreateVertexShader', 15:'CreatePixelShader'}`
를 처음부터 갖고 있다. 즉 **런타임 실측 · 형제 스크립트 2개 · 정정본이 모두 같은 표**이고,
틀린 것은 `hook_d3d11_quick.js` 하나였다.

**정직한 한계**: 이 훅들은 Windows 호스트에서만 실행되므로 **내가 직접 돌려본 것은 아니다.**
내가 확인한 것은 ① 리포 안 3개 독립 출처가 일치한다는 것, ② 공식 문서의 인자 순서가
정정본과 일치한다는 것, ③ 커밋된 실행 로그가 정정본의 슬롯을 기록한다는 것이다.
그 로그를 만든 실행 자체를 재현할 수는 없다(§10 이 요구하는 Windows 호스트 부재).


---

### ✅ 검증 통과 — 테스트 타깃 존재 게이트의 전제가 모두 성립한다

C1 이 개수 게이트의 결함이므로, 그 옆의 **타깃 존재 게이트**(`ci.yml:759-800`)가 실제로
무엇을 지키는지 확인했다. 그 게이트는 개수 하한이 못 잡는 "타깃이 통째로 빠지는" 양상을
담당한다. 전제를 전수 확인했다:

| 검사 | 결과 |
| --- | --- |
| `Package.swift` 의 `.testTarget` 선언 | **7** (게이트 하한 7) |
| `.build` 에 실제로 빌드된 `.xctest` 번들 | **7** — 선언과 **완전 일치**(stale·누락 0) |
| 선언된 타깃마다 `XCTestCase` 클래스가 1개 이상 | 전건 충족 |

타깃별 클래스 수: `WapleRenderTests` 173 · `WapleCoreTests` 144 · `WapleAppTests` 41 ·
`WapleLibraryTests` 8 · `WaplePolicyTests` 6 · `WapleCompatCoreTests` 2 ·
`WapleSnapshotTests` 2 = **376 클래스**.

즉 "선언됐는데 디렉터리가 없다" · "타깃이 `XCTestCase` 를 0개 낸다" 같은 사고는 현재 없고,
게이트의 하한 7 도 정확히 현재 값이다. **C1 이 지적한 것은 개수 추출 한 곳이고,
그 옆의 구조 게이트는 건강하다.**

### ✅ 검증 통과 — 합성 픽셀 골든 5종이 실체가 있고 서로 구별된다(게이트 자기검사 포함)

`spec/golden/synthetic/` 는 실물 코퍼스 없이도 도는 픽셀 오라클이다(코퍼스가 없는 이 맥에서
유일하게 픽셀을 지키는 자리). "골든이 있다고 적혀 있는데 실은 빈 이미지" 부류를 확인했다:

| 파일 | 실체 |
| --- | --- |
| `alpha-red-over-white.png` | 128×72 RGBA8 |
| `blend-difference.png` | 128×72 RGBA8 |
| `blend-multiply.png` | 128×72 RGBA8 |
| `gradient-horizontal.png` | 128×72 RGBA8 |
| `gradient-vertical.png` | 128×72 RGBA8 |

**5개 파일의 SHA256 이 전부 다르다**(중복 골든 0) — 즉 같은 이미지를 다섯 번 커밋해 놓고
다섯 씬을 검사하는 척하는 상태가 아니다. IDAT 를 풀어 보면 픽셀 값도 균일하지 않다.

그리고 **게이트가 자기 자신을 검사한다** — `SyntheticPixelGoldenTests` 는
`testSyntheticScenesMatchCommittedGolden`(골든 일치) 옆에
**`testGateActuallyCatchesADifference`**(일부러 차이를 넣으면 빨개지는지)를 둔다.
둘 다 통과한다. 이 리포가 반복해 물린 "통과할 수밖에 없는 게이트" 를 이 자리에서는
오라클 자신이 막고 있다.

### ✅ 검증 통과 — `WapleCompat` CLI 의 문서화된 플래그가 전부 실재한다

`docs/snapshot-regression.md` 는 렌더러를 만졌을 때 돌리라고 지시하는 문서이므로,
그 명령이 실제로 존재하는지가 중요하다. CLI 를 빌드해 `--help` 를 받아 대조했다.

CLI 가 받는 플래그 15종: `--capture` · `--compare` · `--decode-ogg` · `--deep` ·
`--frame-res` · `--help` · `--inventory` · `--json` · `--label` · `--naive` · `--only` ·
`--profile` · `--remount` · `--strict` · `--vis-blast`.

**문서가 지시하는데 CLI 에 없는 플래그: 0건.** 모드 플래그가 상호배타이고 우선순위와
"먼저 준 것이 이기고 나머지는 경고와 함께 무시된다" 까지 `--help` 가 스스로 적는다.
(이 감사는 실제 캡처를 돌리지 않았다 — 코퍼스 부재. §검증 경계 참조.)

### ✅ 검증 통과 — 파티클 코퍼스 census 가 두 세는 법 모두에서 정확하다

`spec/assets/particle-corpus.json`(status 확정)은 오퍼레이터·이니셜라이저·이미터별로
`all`(인스턴스 전수)과 `unique`(**파일 내용 sha256 중복 제거** 후)를 나눠 적는다.
H3·H4 의 도달 범위가 이 census 에 걸려 있으므로 재현했다:

| 오퍼레이터 | canon `all` | 내 실측 | canon `unique` | 내 실측(파일 dedup) |
| --- | --- | --- | --- | --- |
| `alphafade` | 250 | **250** ✅ | 178 | **178** ✅ |
| `oscillatealpha` | 36 | **36** ✅ | 24 | **24** ✅ |
| `oscillateposition` | 17 | **17** ✅ | 15 | **15** ✅ |
| `oscillatesize` | 8 | **8** ✅ | 5 | **5** ✅ |
| `turbulence` | 22 | **22** ✅ | 18 | **18** ✅ |
| `boids` | 5 | **5** ✅ | 3 | **3** ✅ |

키 부재 도수도 맞는다 — `alphafade.fadeouttime` 부재 `all` **138** · `unique` **94**,
`fadeintime` 부재 `all` **29**: 전건 일치.

> **내 첫 `unique` 계산이 달랐던 이유(정본 결함 아님)**: 나는 오퍼레이터 객체 내용으로
> 중복 제거해 45 를 얻었는데, 정본의 정의는 **파일 단위** sha256 dedup 이다
> (`measure_particle_corpus.py:19` — *"`unique` — 파일 **내용 sha256** 중복 제거"*).
> 그 정의대로 다시 세면 178 로 정확히 맞는다. **정의가 생성기에 적혀 있어서** 내가
> 스스로 판정을 바로잡을 수 있었다 — 이 리포의 "세는 법을 함께 적는다" 규약이
> 세 번째로 유용했던 자리다(앞선 둘: `AGENTS.md` 오디오 게이트 15건, `HDRBloomPass` 의 172 계수).

**의미**: H3 의 "250 중 110" 과 H4 의 "61 전건" 은 이 census 와 같은 모집단에서 나온 값이고,
그 census 가 정확하므로 두 발견의 도달 범위도 신뢰할 수 있다.

### ✅ 검증 통과 — 셰이더 인벤토리 정본이 파일 단위로 정확하다(예외까지 명시돼 있다)

`spec/engine/shaders.json` `shaders.inventory`(확정)를 실제 트리와 대조했다:

| | 정본 | 내 실측 |
| --- | --- | --- |
| 최상위 `.frag` / `.vert` / `.h` / `.geom` | 54 / 54 / 12 / 3 | **54 / 54 / 12 / 3** ✅ |
| 서브디렉터리 포함 | 59 / 59 / 14 / 4 | **59 / 59 / 14 / 4** ✅ |
| 서브디렉터리 목록 | `HLSL` · `base` · `editor` | **동일** ✅ |
| `totalScanned` | 136 | 59+59+14+4 = **136** ✅ |

디렉터리의 실제 파일 수는 **137** 인데 정본은 136 이다 — **그 1건도 정본이 적어 둔다**:
`"nonShaderFile": "declarations.json (임포터 프리셋 — 셰이더 아님)"`. 실제로 그 파일이 존재하고
셰이더가 아니다. **차이가 아니라 문서화된 예외**다.

**파일별 지문도 전건 일치한다** — `shaders.files` 의 `sha256_16` + `bytes`:
**136/136 일치 · 불일치 0 · 부재 0.**

즉 "합이 안 맞는데 조용한" 부류가 아니라, **모집단과 예외를 함께 적어 검산 가능하게** 만든
자리다. 이 감사가 M2·M5·M10 에서 지적한 낡은 수치들과 대비되는 좋은 사례로 기록한다.

### ⚠️ 주의 — 이 리포에는 **세 개의 서로 다른 씬 모집단**이 있다(오판 방지용 기록)

감사 중에 내가 한 번 잘못 대조했고, 같은 함정이 M2·M12·M13·M14 의 뿌리이므로 명시한다.

| 모집단 | 씬 수 | 어디에 있나 | 어느 정본이 쓰나 |
| --- | --- | --- | --- |
| **워크샵 코퍼스** | **162** | **두 리포 어디에도 없다**(F400) | `spec/corpus/scene-schema.json`(`scene.general.keys` n=162 · version 분포 {5:63,1:33,4:32,3:31,None:3}) |
| **설치본** `assets/`+`projects/` | **186** | 짝 저장소 `wallpaper_engine/` | `spec/engine/tonemapping.json`(`corpusScenes` 186 · `corpusReach` 합 186) |
| **동봉** `WEAssets` | **172** | Waple 안(설치본 `assets/` 의 사본) | 단독으로는 정본이 쓰지 않는다 |
| ~~동봉 + 설치본~~ | ~~358~~ | — | **폐기**(2026-08-28 이중계수 판정) → M2 |

**내가 한 오판**: `scene.general.keys`(n=162)를 설치본 186 과 대조해 "50개 키 전부 불일치" 를
봤다. 실제로는 **다른 모집단**이라 당연히 다르다 — 정본이 틀린 것이 아니다.
(`scene.corpus.population` 이 `scenes: 162` 를 명시하고 `corpus/inventory.json` 과 일치한다고 적는다.)

**따라서 M2 의 비둘기집 산수는 워크샵 162 기준이고, 그대로 옳다**(v≥3 = 126 · v≥4 = 95).
반면 M13(`코퍼스 8`)·M14(`161/161`)는 **세 모집단 어느 것으로도 재현되지 않는다** — 그것이
그 둘을 결함으로 판정한 근거다.

> **교훈**: 이 리포에서 코퍼스 도수를 인용할 때 **모집단 이름을 함께 적지 않으면
> 검산이 불가능하다.** 실제로 정확했던 자리들은 전부 그것을 적었다
> (`SceneDocument.swift:3729` "설치본 씬 141 중 45, 동봉 136 중 44" ·
> `tonemapping.json` `corpusPopulation` "설치본 assets/ + projects/, 이름 글롭 …").

**그 렌즈로 `Sources` 전체를 훑었더니 규약은 대체로 지켜져 있다** — 도수를 인용하면서
모집단을 (같은 줄 또는 바로 위 줄에서) 밝히지 않은 자리는 **6곳뿐**이다:

| 자리 | 문면(발췌) |
| --- | --- |
| `HDRPostPass.swift:21` | "**358** 씬 중 354 씬은 `combine.frag`" ← M2 대상 |
| `SceneRendererResources.swift:150` | "코퍼스 도달은 lightshafts 41패스/**23씬** 전건" |
| `TexImage.swift:289` | "SPRITESHEET **37씬** 전수" |
| `PuppetModel.swift:83` | "코퍼스 attachment **28씬** 전수" |
| `ParticleSystem.swift:1265` | "additive+REFRACT **10씬** 중" |
| `ParticleSystem.swift:1400` | "**60씬** 중 값이 다른 씬만" |

이 중 M2·M13 이 이미 잡은 것을 빼면 남는 것은 **네 자리**이고, 넷 다 이 맥에서 검산할 수
없는 값이다(워크샵 코퍼스 의존 가능성). **결함으로 올리지 않는다** — 다만
"코퍼스" 라는 말이 세 모집단 중 어느 것인지 밝히면 다음 감사가 이 네 자리를 검산할 수 있다.

### ✅ 검증 통과 — MDL 버전 표가 실물 도수와 전건 일치하고 **모집단을 분리해 적는다**

`Sources/WapleCore/Model3DFormat.swift:46-58` 의 버전 표는 이 감사가 칭찬할 형태의 대표 사례다.
짝 저장소 `.mdl` 28개의 매직을 전수로 읽어 대조했다:

| 버전 | 표의 "실물 도수" | 내 실측(설치본) | 판정 |
| --- | --- | --- | --- |
| `MDLV0004` | 설치본 **8** | **8** | ✅ |
| `MDLV0014` | 설치본 **15** | **15** | ✅ |
| `MDLV0017` | 설치본 **1** + 코퍼스 2 | **1** | ✅ |
| `MDLV0023` | 설치본 **4** + 코퍼스 378 | **4** | ✅ |
| `MDLV0016` · `0019` · `0021` | **코퍼스만**(8 · 18 · 17) | 설치본에 0건 | ✅ 일관 |
| 합계(설치본) | 8+15+1+4 = **28** | **28** | ✅ |

**세 가지가 모범적이다**: ① 설치본과 워크샵 코퍼스 도수를 **열마다 분리**해 적었다
(그래서 내가 설치본만으로 검산할 수 있었다) ② 버전별로 AABB·per-mesh flag·트레일러 유무를
표로 고정해 파서 분기의 근거가 된다 ③ 미목격 버전(`0015`·`0018`·`0020`·`0022`)을 **명시적으로
거부**하며 이유를 적는다 — *"레이아웃을 모르는 채 추측 파스로 이상 렌더를 만드느니 스킵이 낫다."*

`supportedVersions = [4, 14, 16, 17, 19, 21, 23]` 가 그 표와 정확히 일치한다.

**그리고 실제로 파싱된다 — 28개 전건을 파서에 먹여 봤다**(`Model3D.parse` 를
`@testable import` 로 직접 호출):

```
PROBE total parsed=28 failed=0
PROBE   MDLV0004: parsed 8,  failed 0
PROBE   MDLV0014: parsed 15, failed 0
PROBE   MDLV0017: parsed 1,  failed 0
PROBE   MDLV0023: parsed 4,  failed 0
```

**실물 28/28 이 nil 없이 파싱된다.** 즉 이 표는 서술만 맞는 것이 아니라 코드가 그 서술대로
동작한다 — 이 감사에서 **문서·정본·구현·실행이 4단으로 일치한 유일한 자리**다.

> **부수 확인**: `PuppetModel.swift:83` 의 "코퍼스 attachment 28씬" 은 이 28 과 **다른 수**로
> 보인다(퍼펫 `MDLV0013` 은 짝 저장소에 **0건**이다). 이 맥에서는 검산 불가 —
> 위 "모집단 미기재 6곳" 목록에 든 자리다.

### ✅ 검증 통과 — MDL 스켈레톤 트레일러 T1 블록의 레이아웃 서술이 어셈블리와 일치한다

`Model3D.swift:1113` 은 T1 태그 레코드를
`u16 C1 | C1 × (cstring | u32 | u32 | 64B)` 로 적고 어셈블리 범위
`0x1402625d0-0x140262709` 을 인용한다. 그 구간을 직접 떠서 대조했다:

```
0x1402625d5  call 0x140261680            ; u16 count → movzx r12d, ax        ← u16 C1 ✅
0x1402625f2  jae  0x140262709            ; count 만큼 도는 루프
0x140262610  call 0x14009c500            ; cstring 읽기(= 정정된 −0xD0 주소!)  ← cstring ✅
0x14026264b  mov  eax, [rsi]; add rsi,4  ; u32 → [rdi+0x60]                  ← u32 ① ✅
0x14026266c  mov  eax, [rsi]; add rsi,4  ; u32 → [rdi+0x64]                  ← u32 ② ✅
0x14026269e  movups ×4 (rsi → rdi+0x20..0x50); add rsi, 0x40                 ← 64B 행렬 ✅
```

**네 필드가 순서·크기까지 정확히 일치한다.** 게다가 cstring 읽기가
`0x14009c500` 호출인데, 이것은 이 감사의 H2 에서 확인한 **−0xD0 정정 주소**다
(폐기된 이름은 `FUN_14009c5d0`) — 즉 그 정정이 이 실행 경로에서도 옳다는 교차 증거다.

> **혼동하기 쉬운 자리 기록**: 루프 선두의 `shl rdi, 7`(=128B stride)은 **엔진 내부 구조체
> 배열의 stride** 이고 파일 레이아웃이 아니다(파일 쪽은 `rsi` 가 cstring→4→4→0x40 만큼 전진한다).
> 128 을 파일 레코드 크기로 읽으면 파서를 잘못 고치게 된다.

**T2 블록도 확인했다 — Waple 의 프레이밍이 엔진과 일치한다.**
워크플로 한 레인이 T2 프레이밍 이탈을 주장했으므로 그 구간을 직접 떴다:

```
0x14026273b  movzx eax, byte ptr [rsi]; inc rsi      ; u8 게이트 읽기        ← Waple 과 동일
0x140262741  test al, al; je 0x14026284c             ; 0 이면 블록 건너뜀     ← 동일
0x140262776  test r9d, r9d  (r9d = [rsp+0x5c])       ; 레코드 수
0x140262790  shl rcx, 6                              ; ×64 (목적지 stride)
0x1402627b1  movups ×4 (rsi→dst); add rsi, 0x40      ; 64B 행렬 읽고 전진    ← 동일
```

그 반복 횟수 `[rsp+0x5c]` 의 출처까지 추적했다 — `0x1402624f4 call 0x14009c560` 이
**스트림에서 읽은 u32 본 수**이고 `0x140262501 cmp eax, 0x80` + `int 0x29`(≤128 초과 시 trap)로
상한이 걸린다. Waple 은 `parseSkeletonTail(…, boneCount:)` 에 **본 배열 파싱에 쓴 그 수**를
그대로 넘긴다(`Model3D.swift:867-868`). 즉 **u8 게이트 → boneCount × 64B 라는 서술이 맞다.**
(주석이 적은 "엔진 자체는 본수 상한 0x80 만 강제" 도 `cmp eax,0x80` 으로 확인된다.)

> **다만 이 영역은 정본 커버리지 밖이다** — `spec/formats/mdl-deep.json` 에 스켈레톤 트레일러
> T1~T4 블록 항목이 **0건**이다(검색 확인). 즉 이 파서의 구조 근거는 **소스 주석과
> 어셈블리 인용뿐**이고, 정본 JSON 이 잠그지 않는다. M11(근거 55% 미검사)과 같은 축의
> 사각지대이며, 워크플로가 이 근처에서 지적한 다른 건들(T2 프레이밍 등)도 같은 이유로
> 게이트에 걸리지 않는다.

### ✅ 실행 검증 — `--deep` 을 실물 설치본에 돌렸다(19 프로젝트, 스캐너가 정직하게 보고한다)

이 감사는 워크샵 코퍼스가 없어 픽셀 회귀를 못 돌렸지만, **짝 저장소의 설치본
`projects/defaultprojects` 는 실물 코퍼스**다. `WapleCompat --deep` 을 거기에 돌렸다:

```
projects scanned: 19 · wall clock 6.5s
| type        | total | supported | rate  |
| application |     1 |         0 |   0.0% |
| scene       |    16 |        16 | 100.0% |
| web         |     2 |         2 | 100.0% |
| **ALL**     |  **19** |    **18** | **94.7%** |

project.json parsed 19/19 · display conditions evaluable 16/16
MDLV0023 3/3 (100%) · Particles parsed 7/7 · ParticleSimulator built 7/7
scene audio referenced files present 2/2 · Web index present 2/2
Property types: bool=7, color=42, combo=14, slider=17
```

**세 가지가 확인된다**:
1. **실물 19 프로젝트가 파싱된다** — `application` 1건만 미지원이고 그것은 설계상
   마운트 불가 타입이다(`RendererFactory` 가 `application/unknown/preset` 을 지원하지 않는다).
2. **속성 타입 census 가 내 독립 측정과 일치한다** — `combo=14` · `color=42` · `slider=17` ·
   `bool=7`. 내가 §M3 에서 직접 센 값과 **정확히 같다**(그 표가 M3 의 도달 범위 근거였다).
3. **리포트가 자기 한계를 먼저 적는다** — *"이 열은 '렌더 정확도'가 아니라 '파싱 가능성'의
   상한입니다"*, 그리고 ffmpeg 부재 시 *"non-native 0건은 이 머신에서 실제로는 재생 불가
   (위 헤드라인엔 supported 로 집계됨)"* 라는 ⚠️ 경고를 스스로 낸다.
   **"supported" 를 과대 해석하지 못하게 막는 구조**다 — 이 감사가 M2·M13 에서 지적한
   과대 서술의 반대 사례다.

**base assets 를 붙여 다시 돌렸다 — 해석 실패가 0 이 되고 셰이더 파이프라인이 전부 통과한다.**
`AGENTS.md` 가 규정한 개발 루트 레이아웃(`$ROOT/assets` + `$ROOT/backgrounds`)을 구성해
재실행했다(설치본 `assets` 심링크 + `defaultprojects` 19개를 APFS 클론):

```
base assets: /tmp/…/devroot/assets      ← 이제 해석된다
projects scanned: 19 · wall clock 7.1s (translate+decode 6.9s, compile 0.2s)

## Effect shaders (GLSL -> Metal)
- effect instances referenced by scenes: 24 · resolved via hand-port stock effect: 22
- shader files missing (skipped): 0
- **GLSL translate: 6/6 (100.0%)** · **Metal compile (unique MSL): 6/6 (100.0%)**

## Models (.mdl)  parsed 26/26 (100%)
| MDLV0004 8/8 | MDLV0014 15/15 | MDLV0023 3/3 |

## Particles  parsed 7/7 · ParticleSimulator built 7/7
image layer texture resolve failed: **0건**
```

**이것이 이 감사에서 실행한 가장 넓은 실물 파이프라인 검증이다** —
JSON 파싱 → 텍스처 디코드 → MDL 파싱 → 파티클 시뮬레이터 구성 → **GLSL→MSL 번역 →
Metal 컴파일**까지 실제 GPU 드라이버로 통과한다. 워크샵 코퍼스(446)는 없지만
설치본 19 프로젝트에 대해서는 파이프라인이 끝까지 동작함을 확인했다.

> **관찰**: 앞선 실행에서 `base assets: none` 일 때는
> `image layer texture resolve failed: models/util/fullscreenlayer.json` 이 2회 로그됐다.
> 즉 **공유 에셋 부재가 조용한 실패가 아니라 로그로 드러난다** — README 가 말한 설계 방향과 정합한다.
> (`DeepScan.run` 은 `root/assets` 와 `root/../assets` 두 자리만 보므로 루트를
> `projects/defaultprojects` 로 주면 못 찾는다. `projects/` 를 루트로 주면 프로젝트 0개로
> **종료코드 2 + 진단 메시지**를 낸다 — 조용히 0건 리포트를 내지 않는다.)

### ✅ 검증 통과 — `scene.object.idStoreFirstWins` 정본의 **네 주장이 전건 바이트와 맞는다**

위 §5.7 에서 이 항목에 대한 "정본이 거짓" 주장을 기각했으므로, 같은 항목의 나머지 주장도
전부 확인했다(`spec/engine/scene-objects.json`, status **확정**):

| 정본 주장 | 바이트 | 판정 |
| --- | --- | --- |
| 헬퍼는 `0x1401a38f0` | 함수 선두 `push rbx; push r14; sub rsp,0x48` 로 시작하는 실함수 | ✅ |
| `find("id")` 는 `0x1401a3922` | `0x1401a3922 call 0x140087490` 이고 직전 `lea rdx` 대상이 문자열 **`"id"`**(VA `0x14048e5bc`) | ✅ |
| 태그 1..3 만 받는다(`0x1401a3935` dec/cmp 2/ja) | `0x1401a3931 movzx eax,[rax+8]` → `0x1401a3935 dec eax` → `cmp eax,2` → `ja` 탈출 | ✅ |
| `asUInt64` 는 `0x140086000` | `0x1401a395f call 0x140086000` | ✅ |
| **`id0`: 0 이면 저장 건너뜀** (`0x1401a3964 test/je`) | `0x1401a3964 test rax,rax` → `0x1401a3967 je 0x1401a39b8`(저장부 우회) | ✅ |
| 저장은 `[obj+8]`(`0x1401a399e`) | `0x1401a399e mov qword ptr [r14], rax` | ✅ (베이스 `r14` = 전달된 포인터) |
| 집합삽입 `sub_140078250` — 기존 키면 **덮지 않고** `inserted=false` | `0x14007831f xor al,al` → `mov [r12], rdi`(기존 노드) → `mov [r12+8], al`(=false) | ✅ |

**일곱 좌표 전건이 맞는다.** 세 번째 `find` 가 다시 `"id"` 를 읽는 것(같은 VA `0x14048e5bc`)까지
확인해, `id` 를 두 번 조회하는 구조(태그 검사용 · 값 추출용)도 정본 서술과 정합한다.

**그리고 그 정본을 소비하는 오라클도 정확하다** — `Tests/WapleCoreTests/SceneObjectIDDedupTests.swift:148-166`
는 내가 위에서 검증한 좌표(`0x1401a3964`)를 인용하며 **의도적 이탈**을 기록한다:
WE 는 `[obj+8]` ctor 기본값이 0 이라 **`id` 키가 없는 오브젝트도 id 0** 이므로 `parent:0` 이
"앞쪽의 id 0 오브젝트" 에 붙을 수 있다(로드 순서 의존). Waple 은 그것을 흉내 내지 않고
"부모 없음" 으로 고정한다. 그 판단의 근거로 **도달 0** 을 든다 —
*"설치본 186 씬 전수에서 `parent` 값은 `24` 2건뿐이고 `parent:0` · `id:0` 은 0건"*.

**그 도달 주장을 직접 셌다 — 전건 일치**:

```
설치본 씬 186 · objects[].parent 값 분포 = {24: 2}  ← "24 2건뿐" 정확
objects[].id == 0 출현 = 0건                       ← "id:0 0건" 정확
(참고: 서로 다른 id 값 97종)
```

즉 **정본(바이트) → 오라클(좌표 인용) → 도달 근거(코퍼스 계수)** 세 층이 모두 맞고,
오라클 11개가 통과한다. 이 감사에서 **이탈을 기록하는 형태의 모범 사례**로 남긴다
(§`CAST3X3` 항목과 같은 형태 — 다르다는 것을 알고, 왜 안 고치는지 수치로 적는다).

**이 항목이 중요한 이유**: `id:0` 과 `id` 키 부재가 구분되지 않는다는 것은 **씬 오브젝트
식별의 근본 성질**이고, Waple 의 `SceneDocument.parse` 가 `intVal(obj["id"])` 로 같은 자리를
읽는다. 정본이 여기서 정확하다는 것은 그 파싱 결정의 근거가 튼튼하다는 뜻이다.

### ✅ 검증 통과 — 오디오 스펙트럼 파이프라인이 실물 명령과 정합한다(밴드 축약 = MAX)

M20 이 오프셋 표기 오류를 잡았으므로, **그 상수를 쓰는 산술 자체**는 맞는지 끝까지 확인했다.

**정본 전체의 명령 바이트 앵커를 구조적으로 훑어 전건 검증했다 — 52/52 일치, 불일치 0**:

| 정본 파일 | 바이트 앵커 수 | 결과 |
| --- | --- | --- |
| `engine/effect-fbo-audio.json` | **24** | 전건 일치 |
| `engine/media.json` | **28** | 전건 일치 |
| 합계 | **52** | **MATCH 52 / MISMATCH 0** |

즉 정본이 *"이 주소에 이 바이트가 있고 그 뜻은 이것이다"* 라고 적은 **모든** 자리가
실물과 맞는다. 아래는 그중 오디오 14건의 상세다.

**정본의 명령 앵커 14건이 바이트 단위로 전건 일치한다**(`engine.audio.instructionAnchors`) —
`maxss`(`f3 0f 5f`) · `and ecx,0x2000` · `divss`/`mulss`/`subss`/`cvttss2si` ·
상수 스토어 4건 · 패딩 2건. 그 중 float immediate 도 전건 디코드 확인:

| 상수 | 인코딩 | 디코드 | 정본 주장 |
| --- | --- | --- | --- |
| exponent | `0x3E800000` | **0.25** | 0.25 ✅ |
| tiltC | `0x3F004189` | **0.5009999871253967** | 동일 ✅ |
| fftLengthFactor | `0x41F00000` | **30.0** | 30.0 ✅ |
| binCountFactor | `0x41200000` | **10.0** | 10.0 ✅ |
| 패딩 실수부 | `0x42FE0000` | **127.0** | 127.0 ✅ |
| 패딩 허수부 | `0x3C010204` | **0.007874015…** | 1/127 ✅ |
| 공통 배수 | `0x1404928e4` | **64.0** | 64.0 ✅ |

파생값도 맞는다: `N = 30 × 64 = 1920` · `B = 10 × 64 = 640` · `10/30 = 0.3333…`.

**밴드 축약이 실제로 MAX 다** — `0x1400d1d04` 의 `maxss` 를 Waple 이 이렇게 이식했다
(`AudioSpectrum.swift:373`): `if b >= 0, b < bandCount, v > out[b] { out[b] = v }`.
매 프레임 0 으로 시작(원본 memset)하므로 실질 `max(0, …)` 이고, `Inf/NaN` 빈은 건너뛴다
(`0x1400d1c62` 인용과 정합). 게인은 맨 마지막에 일괄 곱한다 — 주석의 파이프라인 순서와 같다.

> **혼동 주의(내가 한 번 착각했다)**: 같은 파일 `:382` 의 `bin(_:binCount:)` 는 **평균**을 낸다.
> 그것은 WE 경로가 아니라 *"일반 비닝 프리미티브(다른 소비처 호환용)"* 이고 주석이 그렇게
> 명시하며 *"스펙트럼 경로는 `spectrum(normalizedMagnitudes:)` 를 쓴다"* 고 가리킨다.
> **평균 함수가 있다는 것 자체는 결함이 아니다** — 용도가 적혀 있어서 내가 즉시 구분할 수 있었다.
> (`TextEngineTests` · `AudioCalibrationTests` 가 "평균→MAX 전환" 을 오라클로 잠근다.)

### ✅ 검증 통과 — 비디오 컨테이너 허용목록이 **포인터 테이블까지** 실물과 일치하고, 이탈이 정직하게 기록돼 있다

`spec/engine/media.json` `engine.media.video.containerAllowlist`(확정)는 WE 가
`.mp4 .wmv .avi .m4v .mov .webm .mkv` **7개**를 고정한다고 적는다.
그리고 `ProjectJSONParser.swift:54` 가 그 테이블 주소를 `0x140483810` 로 인용한다.
**포인터 테이블을 직접 읽어 확인했다**:

```
0x140483810 (파일 0x482610) 의 8바이트 포인터 배열:
  [0] 0x14048a800 -> ".mp4"     [1] 0x14048a7f8 -> ".wmv"
  [2] 0x14048a830 -> ".avi"     [3] 0x14048a828 -> ".m4v"
  [4] 0x14048a820 -> ".mov"     [5] 0x140488af8 -> ".webm"
  [6] 0x14048a818 -> ".mkv"     [7] 0x5 (= enum 값, 테이블 끝)
```

**7개가 정본이 적은 순서 그대로다.** 문자열 리터럴도 바이너리에서 **각각 정확히 1회**만
나오고 여섯 개가 56바이트 연속 블록(`0x4895f8`–`0x489630`)에 모여 있다 —
단일 static 집합 초기화와 정합한다.

**같은 주석이 인용하는 6번 표(`0x1404837e0`)도 확인했다** — 5개 이미지 확장자가
인용 순서 그대로다:

```
[0] ".png"  [1] ".bmp"  [2] ".jpeg"  [3] ".jpg"  [4] ".jfif"  [5] NULL(끝)
```

그 주석은 이 표에 대해서도 이탈을 적는다 — *"enum 값 5 로 가는데 **WE 자신도** 5 를 캐논
문자열로 옮기지 못해 `Unknown` 으로 출력한다(`0x14011e864`→`0x14011e2e9`)"*.
**두 좌표를 따라가 문자열까지 확인했다**:

```
0x14011e864  mov  ebx, 5            ; 이미지 확장자 → enum 5
0x14011e869  jmp  0x14011e802
   …
0x14011e2e9  lea  rdx, [rip+0x36c500]   → VA 0x14048a7f0 = "Unknown"   ← 실제 문자열
0x14011e2e0  lea  rdx, [rip+0x36c4fd]   → VA 0x14048a7e4 = "Scene"     (대조군)
```

**`"Unknown"` 리터럴이 정확히 그 자리에 있다.** 즉 "WE 자신도 enum 5 를 이름으로 못 옮긴다"
는 주장이 바이트로 확인된다 — **원본의 결함을 흉내 내지 않는 쪽을 택했고 그 근거를 남겼다.**

**이탈이 있고, 그것이 `[미해결]` 로 명시돼 있다** — Waple 의 분류용 집합
`VideoFormats.nativeExtensions` 는 **3개**(`mp4 m4v mov`)다. 그 주석이 왜 넓히지 않는지 적는다:
*"넓히면 분류 축과 재생 축이 섞인다 — AVFoundation 이 못 여는 `wmv`/`mkv` 를 `.video` 로
분류해 VideoRenderer 로 보내는 셈이고, 실패 지점만 뒤로 밀린다."* 그리고 도달 0 을 근거로 든다
(설치본+동봉 361건의 `file` 확장자는 `.json` 358 · `.html` 2 · `.exe` 1 뿐).

**재생 축은 7개를 다 다룬다(확인함)** — `VideoRenderer.unsupportedExtensions` 가
`webm mkv avi wmv flv ogv mpg mpeg` 를 담아 ffmpeg 변환 경로로 보내고,
`FFmpegConverterTests` · `MediaFixRegressionTests` · `VideoRendererLifecycleTests` ·
`RendererFactoryTests` 네 곳이 `wmv` 를 포함해 오라클로 잠근다.
즉 **README 의 "native 3 + 변환 3" 서술과 실제 구현이 정합하고**, WE 의 7개 중 README 가
언급하지 않는 `.wmv` 도 코드·테스트에서는 다뤄진다.

### ✅ 검증 통과 (목록 1건 누락 지적) — `ScenePBRMath` 데드코드 판정이 맞다

`spec/engine/deviations.json` `deviation.finding.scenePBRMathIsDead`(확정)는
`ScenePBRMath`(= `Sources/WapleCore/ScenePBRLighting.swift`)가 **데드코드**이고
`sourcesReferences: 0` 이라고 적는다. 같은 파일의 다른 타입들과 비교해 확인했다:

| 같은 파일의 최상위 타입 | 다른 `Sources` 파일에서의 참조 |
| --- | --- |
| `SceneLightSlotBudget` | **5** (`SceneRenderer` · `HDRBloomPyramidPass` · `Scene3DLighting` · `QuadShaders` …) |
| `SceneWELightMath` | **3** (`Mesh3DShaders` · `Scene3DLighting` · `SceneDocument`) |
| `SceneWEVolumetricMath` | 1 (`VolumetricLightPass`) |
| `SceneLightSlotKind` | 1 (`Scene3DLighting`) |
| **`ScenePBRMath`** | **0** ✅ 정본과 일치 |

**즉 한 파일 안에서 네 타입은 살아 있고 이것만 죽어 있다** — 파일 단위가 아니라 타입 단위로
정확히 판정한 것이다. 그 결과("라이브 PBR 은 전부 `Mesh3DShaders.swift` 의 MSL 이다.
CPU 미러를 고쳐도 화면은 안 바뀐다")도 `SceneWELightMath` 가 `Mesh3DShaders` 에서 참조되는 것과 정합한다.

**이것이 M17(Schlick 정규식)·§Schlick 검증과 맞물린다** — 내가 앞서 "`ScenePBRLighting` 의
Schlick k 가 WE 원문과 완전 일치한다" 고 확인했는데, **그 코드는 화면에 닿지 않는다.**
정본이 적은 위험이 정확히 그것이다: *"두 구현이 갈라져도 테스트가 CPU 쪽만 보므로 드리프트를
못 잡는다."* 즉 그 일치는 **CPU 미러의 일치**이고, 라이브 MSL 과의 일치는 별도 축이다.

> **지적(경미)**: `testReferences` 가 두 파일(`SceneForwardLightingTests` ·
> `TubeLightCSMandMipTests`)만 적는데, **`Tests/WapleCoreTests/SceneWELightMathTests.swift` 도
> `ScenePBRMath` 를 실제로 호출한다**(HEAD 에서 5회, 현재 4회 — 주석이 아닌 실호출).
> 그 파일은 HEAD 에 이미 있었으므로 이번 diff 가 만든 누락이 아니다.
> 목록이 소비처를 다 담지 않으면 "이 데드코드를 지워도 되는가" 판단이 어긋난다.

## 5.5 정본 신뢰도 종합 — 기계적으로 검증 가능한 것은 **전부 맞다**

이 감사에서 가장 중요한 긍정 결론이다. 정본이 **기계로 대조할 수 있는 형태로** 적어 둔
값들을 전수 또는 대표 표본으로 재현했고, **어긋난 것이 하나도 없다**:

| 축 | 대상 | 결과 |
| --- | --- | --- |
| 바이너리 좌표 | `spec/**` 이 인용하는 고유 VA **1,778** | **오류 0** (1,768 = wallpaper64 · 8 = wallpaperui(명시됨) · 2 = 내 정규식 문제) |
| 함수 본문 지문 | SHA256[:16] **4**건 | **4/4 일치** (생성기의 `.pdata` 청크 병합 규칙 재현 필요) |
| 명령 바이트 앵커 | **52**건(`effect-fbo-audio` 24 · `media` 28) | **52/52 일치** |
| WE 설치본 트리 | 서브트리 4개 · **5,562 파일 · 567,856,672 B** | 파일 수·바이트 **전건 일치** |
| 트리 다이제스트 | `locale`(75) · `assets`(2,940) SHA256 | **2/2 비트 일치** |
| WE 바이너리 지문 | **8** 종 SHA256 + 크기 | **8/8 일치** |
| 동봉 에셋 지문 | **2,940** 파일 SHA256 | **2,940/2,940 일치** |
| 셰이더 지문 | **136** 파일 SHA256[:16] + 크기 | **136/136 일치** |
| 셰이더 인벤토리 | 확장자별 도수 · 서브디렉터리 · 비셰이더 예외 1건 | 전건 일치 |
| 파티클 코퍼스 census | `all`·`unique` 두 세는 법 × 오퍼레이터 6종 + 키부재 3종 | 전건 일치 |
| PE 구조 실측 | `.pdata` 14,792 · `e_lfanew` · 링커 14.51 · 섹션 VA 비트동일 | 전건 일치 |
| 코퍼스 계수 | `.tex` 440/61/379 · alphafade 250/110 · oscillate 61 · 씬 162/126/95 · JSON 1698/27/4 · MDL 28 | 전건 일치 |

**암호학적 검사 합계: 3,090건 · 불일치 0**
(에셋 2,940 + 셰이더 136 + 바이너리 8 + 함수본문 SHA 4 + 트리 다이제스트 2).
여기에 **명령 바이트 앵커 52건**(전건 일치) · 좌표 대조 1,778건 · 코퍼스 계수 수십 건이 더해진다.

### 반대로, 낡는 자리는 한 종류다 — **소스 주석의 코퍼스 도수**

이 감사가 찾은 정본/문서 결함 9건(H2 · M2 · M5 · M9 · M10 · M11 · M12 · M13 · M14)을
같은 축으로 늘어놓으면 하나의 양상이 된다:

| 발견 | 자리 | 낡은 것 |
| --- | --- | --- |
| M2 | 소스 4파일 + `docs/re/**` 22자리 | 폐기된 모집단 358(도수·비율까지) |
| M12 | `GLSLTranslator.swift:2237` | 두 모집단을 섞은 도달표(`g_Bones` 40 ≠ 48) |
| M13 | `HDRBloomPass.swift:5` | "코퍼스 8" — 어느 모집단에도 없음 |
| M14 | `SceneRenderer.swift:1140` | "161/161 전건 true" — 실측 141·96·null 45 |
| M9 | `SceneDocument.swift:4006` | 소비처 분류 1건(호출부 0) |
| M10 | `ShaderPreprocessor.swift` 외 | 자기 diff 가 밀어낸 같은 파일 줄번호 6자리 |
| M5 | `README.md:46` | 셰이더 선언 줄을 코드 줄로 |
| H2 | `spec/engine/decompilation-provenance.json` | census 모집단 62(실측 66) · `Sources 8`(실측 7) |
| M11 | `validate.py` 커버리지 | 근거 55%가 검사 밖 |

**아홉 건 중 여덟이 "도수 또는 좌표를 사람이 손으로 적은 자리"** 이고,
**기계가 생성·대조하는 값(지문·트리 다이제스트·정본 JSON 리터럴)에서는 결함이 0** 이다.
그리고 정확했던 자리들의 공통점도 뚜렷하다 — `SceneDocument.swift:3729`(141/45·136/44),
`AGENTS.md` 오디오 게이트(16/16/15/63), `shaders.inventory`(136 = 59+59+14+4 + 예외 1건),
파티클 census(`all`·`unique` 양쪽) 는 **전부 세는 법과 모집단을 함께 적었다.**

즉 이 리포의 규약("수는 세는 법과 함께 적는다")은 **지켜진 곳에서 예외 없이 작동했고,
빠진 곳에서만 썩었다.** 그것이 이 감사의 가장 재현성 있는 결론이다.

**해석**: 이 리포의 정본은 **숫자와 지문 층에서 신뢰할 수 있다.** 이번 감사가 찾은
정본 결함(H2 · M2 · M5 · M9 · M10 · M11)은 예외 없이 **산문·주석·모집단 크기·게이트 커버리지**
층에 있다 — 즉 *기계가 대조하는 값은 맞고, 사람이 손으로 적는 서술이 뒤처진다.*
그것이 이 리포가 "수는 세는 법과 함께 적는다"·"인용에 식별자를 같이 적는다" 를 규약으로
세운 이유와 정확히 일치하고, 규약이 지켜진 자리에서는 실제로 드리프트가 없었다.

## 5.7 내가 기각한 워크플로 발견 — 기록

병렬 워크플로가 올린 발견 중 **내가 바이트로 확인해 기각한 것**도 남긴다. 기각 근거가
다음 감사의 시간을 아끼기 때문이다.

| 워크플로 주장 | 내 판정 | 근거 |
| --- | --- | --- |
| `Model3D` T2 프레이밍이 엔진과 어긋난다 | **기각** | `0x14026273b` u8 게이트 · `0x1402627b1` 64B×N · 반복수 `[rsp+0x5c]` = 스트림 u32 본수(`0x14009c560`, 상한 `cmp eax,0x80`). Waple 이 같은 `boneCount` 를 넘긴다 — 일치 |
| `SceneRenderer.swift:1140` "161/161" 이 근거 없다 | **기각(내 발견이었다 — M14 철회)** | 정본이 워크샵 코퍼스로 `clearenabled {n:162, True:161}` 을 기록한다 |
| `CAST3X3` 이탈로 값을 고쳐야 한다 | **부분 기각** | 도달 0(스칼라 인자 전 코퍼스 1건, 미동봉) — 값 유지가 옳다. 다만 도수표는 틀렸다(**M12** 로 좁혔다) |
| 라이트 forward 가 **col2(+Z)** 인 것이 이탈이다 — WE V1 팩커는 **col0 을 음수화**한다(**critical**) | **판정 보류 → 기각 쪽으로 기운다** | Waple 의 근거는 **WE 1차 자료**다: `wallpaper_engine/ui/dist/monaco/autocomplete/lib.sceneScript.d.ts:608-610` 이 `forward(): Vec3` 를 **"(Blue axis)"** 로, `:598-600` 이 `right()` 를 "(Red axis)" 로 문서화한다 — 내가 그 파일을 직접 읽어 확인했다. 즉 "forward = blue(+Z, col2)" 는 WE 자신의 API 문서와 일치한다. 반면 "V1 팩커가 col0 을 음수화한다" 는 주장은 **정본·`docs/re/scene-lighting.md` 어디에도 기록이 없고**(grep 0건) 워크플로가 제시한 좌표를 이 세션에서 확인하지 못했다. **기각한다** — WE 셰이더 원문에서 그 슬롯이 `L`(표면→광원)임을 확정했고(`common_pbr_2.h:317` +
스니펫 `0x14048ce50`), Waple 은 `forward`(=`-L`)를 넣고 셰이더에서 부호를 되돌리므로 최종 `L` 이 같다. 열 인덱스 자체는 미확인으로 남긴다(§6 참조) |
| 텍스트에 블렌드 테이블을 적용하는 것이 이탈이다 — WE 엔 텍스트 블렌드 셰이더 경로가 없다(high) | **기각** | `font.frag` 에 `common_blending`/`ApplyBlending` 참조가 **0건**인 것은 사실이지만, WE 가 텍스트 `colorBlendMode` 를 **소비하지 않는다는 결론은 틀렸다.** `docs/re/text-layer.md` 가 바이트로 두 소비 경로를 기록한다: ① `0x14025834c cmp dword [rbx+0x32c], 0x1f` — `colorBlendMode == 31` 이면 **블렌드 슬롯 2, 아니면 1** ② `0x1401e6f74`–`0x1401e6fa2` — `colorBlendMode ∉ {0, 31}` 이면 `or dword [rsi+0x304], 0x10`(**오프스크린 합성 필요** 플래그). 즉 텍스트 블렌드는 **프래그먼트 셰이더가 아니라 파이프라인 블렌드 상태·합성 경로**로 구현된다 — 셰이더에 없는 것이 곧 기능이 없는 것이 아니다 |
| `ci.yml` 래칫의 +101 출처 3커밋 귀속이 거짓이다(high) | **전건 정확하다 → 기각** | 커밋별 정적 개수를 직접 셌다: `49719565` **3,774** → `a9f271b` **3,807**(+33) → `6a0e389` **3,813**(+6) → `4c58826` **3,875**(+62). 합 **+101** 이고 HEAD(`70a8a708`)도 **3,875** 다. 주석의 세 커밋·세 증분·최종값이 모두 맞다 |
| 정본이 "`id:0` 은 저장을 건너뛴다" 를 거짓으로 적었다(high) | **기각 — 정본이 옳다** | `0x1401a38f0` 을 함수 선두부터 정렬해 떴다: `0x1401a395f call 0x140086000`(asUInt64) → **`0x1401a3964 test rax,rax` / `0x1401a3967 je 0x1401a39b8`** = 0 이면 저장부(`0x1401a399e mov [r14], rax`)를 건너뛴다. 정본 문면과 바이트가 정확히 일치한다 |

> **기각 방법 기록**: 그 주장을 검증하려고 `0x1401a3950` 부터 떴을 때는 **명령 경계가 어긋나
> 전혀 다른 디스어셈블**(`out dx, al` · `enter` 등)이 나왔다. 함수 선두 `0x1401a38f0` 에서
> 정렬해 다시 뜨자 구조가 드러났다. 이것이 `waple-particle-audit` 메모가 적은 함정
> ("항상 참 명령 경계에서 디스어셈블하라 — 중간에서 읽으면 조용히 쓰레기가 나온다")의
> 실례이고, **이 감사에서 오판을 만든 유일한 기술적 원인**이다(M14 철회 = 모집단 오판,
> 이 건 = 정렬 오판).

**기각률**: 워크플로가 올린 고·중 심각도 주장 중 내가 독립 확인한 것은 전건 성립했고,
**프레이밍·모집단 해석에서만** 위 세 건이 갈렸다. 즉 워크플로의 **바이트 인용은 신뢰할 만하고,
해석 층에서 교차검증이 필요하다.**

## 6. 검증 경계 — 이 감사가 **확인하지 못한** 것

발견보다 이 절이 더 중요할 수 있다. "안 나왔다" 와 "볼 수 없었다" 는 다르다.

### 실행으로 확인한 것 (신뢰도 높음)

| 축 | 방법 |
| --- | --- |
| 빌드·전수 테스트 | `swift build` · `swift test` 2회(감사 전후) — 3,886 실행 · 실패 0 · 스킵 63 |
| 정본 게이트 19종 | 전부 실행 — 18 통과 · 1 실패(H2) |
| 재측정 스크립트 40종 | 전부 실행(무코퍼스 거동 분류 — M4) |
| CI 게이트 로직 | `ci.yml` 의 census 판정을 **원문 그대로 재생** → C1 확정 |
| 돌연변이 5자리 | UI 규약 · 모니터 인덱스 · 버전 게이트 · 스키닝 · 탭 지시문 — 전부 주입→빨강, 복원→초록 |
| 원본 PE 바이트 | 섹션 테이블 · `.pdata` 14,792 · `e_lfanew` · 링커 14.51 · TypeDescriptor 106 |
| 디스어셈블 | H3(`0x1402402d0`~) · H4(`0x14024123a`~`0x140241381`) · 파서 팩토리 호출부 11/11 |
| 코퍼스 계수 | `.tex` 440/61/379 · alphafade 250/110 · oscillate 61 · 씬 162/126/95 · JSON 1698/27/4 |
| 적대적 입력 | 경로 격리 14종 · 살균기 7종 — 전건 차단 |
| 셰이더 인용 | 634건 범위 대조 → 3건 이탈(M5) |

### 미결로 남긴 것 (판정하지 못했다)

**라이트 forward 축(critical 주장) — 추적 끝에 기각 쪽으로 결론했다. 다만 열 인덱스 자체는 미확인.**
워크플로 주장: "Waple 은 모델행렬 col2(+Z)를 쓰는데 WE V1 팩커는 **col0 을 음수화**한다 →
모든 directional/spot 방향이 틀어진다."

**추적한 것**:
1. **Waple 의 근거는 WE 1차 자료다(확인)** — `lib.sceneScript.d.ts:608-610`
   `forward(): Vec3` = **"(Blue axis)"**, `:598-600` `right()` = "(Red axis)".
2. **WE 셰이더가 그 유니폼을 어떻게 쓰는지 찾았다** — `.rdata` 의 조립 스니펫
   `0x14048ce50`·`0x14048cf10`:
   `light += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz, viewVector, …)`.
3. **그 함수의 2번째 인자 의미를 원문에서 확정했다** — `common_pbr_2.h:317-327`:
   `ComputePBRLightShadowInfinite(vec3 N, vec3 L, …)` 이고 본문이
   `H = normalize(V + L)` · `dNL = dot(N, L)` 를 쓴다. 즉 **그 슬롯은 `L`(표면→광원 방향)** 이고
   광자 진행 방향이 아니다.
4. **두 규약이 화해한다** — Waple 은 슬롯에 `forward`(광자 진행 = `-L`)를 넣고 셰이더에서
   `float3 L = normalizedOr(-light.axis.xyz, …)`(`Mesh3DShaders.swift:297`)로 부호를 되돌린다.
   WE 는 슬롯에 `L` 을 직접 넣는다. **최종 `L` 은 같다** — 부호 규약이 한 단계 다를 뿐이다.

**따라서 "방향이 틀어진다" 는 결론은 성립하지 않는다.** 남은 미확인은 **열 인덱스 하나**다:
WE 가 `L` 을 만들 때 모델행렬의 어느 열을 쓰는지 기록이 없다(정본·`docs/re` 에 0건). 내가
`g_LDirectional_Direction` 바레 이름의 `.text` 참조를 추적하니 **1곳뿐**(`0x14016f8ac`)이고
그 자리는 **이름 등록 헬퍼**(`xorps`→`movups [rcx]`→`mov r8d,0x18`→`call 0x140017480`)이지
행렬 팩커가 아니다. 다음 라운드가 팩커를 특정하려면 **셰이더 상수버퍼 기록 자리**를 찾아야 한다.

### 볼 수 없었던 것 (미확인 — 결함 부재의 증거가 아니다)

1. **CI 실행 자체.** `macos-26` 러너에서 이 트리가 실제로 어떻게 되는지는 못 봤다.
   C1 은 **이 맥에서 게이트 로직을 재생한 결과**다. 러너의 SwiftPM 이 번들을 하나로 합쳐
   실행하면 `tail -1` 이 우연히 합계를 집을 가능성이 남는다 — 그래도 **하한 3875 가
   "초록 실행에서 잰 값" 이 아니라는 사실은 변하지 않는다**(주석 자신이 인정한다).
2. **워크샵 코퍼스 446 폴더.** 두 리포 어디에도 없다(F400). 그래서 M3(숫자 combo)·
   MDL 스킨 플래그·`measure_workshop_shaders.py` 의 재측정은 **도달 범위를 못 쟀다**.
3. **픽셀 회귀.** `WapleCompat --capture`/`--compare` 를 돌리지 않았다. 즉 버전 게이트 철회와
   H3·H4 수정이 170씬 골든에 어떤 diff 를 내는지는 미확인이다. (기준선 2종의 **무결성**은
   확인했다 — 매니페스트 170 = 썸네일 170.)
4. **화면보호기 실동작.** M8 은 제어흐름 독해뿐이다. `AVPlayer` 프로브는 헤드리스 CLI 에서
   `readyToPlay` 에 도달하지 않아 실패했다(과정을 M8 에 적었다).
5. **Windows 호스트 동적 분석.** Frida 훅 3종은 실행 불가. 검증은 리포 내 3개 독립 출처
   일치 + 공식 문서 대조 + 커밋된 실행 로그로 대체했다.
6. **서명·공증.** `Developer ID` 트랙은 확인 수단이 없다.
7. **Swift 6 언어 모드 전환.** H5 는 진단을 **셌을 뿐**이고, 모드를 올려 실제로 몇 개가
   에러가 되는지는 시도하지 않았다(빌드가 멎을 수 있어 수정 금지 지시에 저촉된다).

### 이 감사가 손대지 않은 것

- **코드·정본·문서 수정 0건.** 작업 트리는 시작과 같다(수정 45파일 · 추적되지 않음 4건,
  거기에 이 문서만 추가). 돌연변이 검증에 쓴 파일은 전부 **바이트 동일로 복원**했고
  전 스위트 재실행으로 확인했다.
- **커밋·푸시·스태시 0건.**
- `/tmp` 밖의 임시 파일 0건(프로브 테스트는 측정 직후 삭제, `git status` 로 확인).
