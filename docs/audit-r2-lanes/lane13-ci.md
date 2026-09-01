# 레인 13 — CI 워크플로 · 게이트 · 개발 스크립트

대상: `.github/workflows/{ci,release,spec}.yml` · `scripts/dev/**` · `scripts/spec/` 게이트
기준: HEAD `b883386e` (PR #8), 작업 트리 깨끗(`git status --porcelain` 무출력으로 전후 확인).
빌드/`swift test` 미실행(브리핑 규약). 모든 실측은 grep·python3·`git show`·합성 로그.

---

## 0. 기지 C1 수정 검증 — **통과. 다섯 양상 전부 올바르다**

`scripts/dev/xctest-census.py:16-37` 을 정독하고 합성 로그로 검산했다
(합성 로그: `/private/tmp/.../scratchpad/census/{agg,multi,failed,swifttesting}.log`).

| 요구된 양상 | 스크립트 동작 | 실측 |
| --- | --- | --- |
| 클래스 소계 중복 합산 | `line.startswith("Test Suite '")` 가 `pending=None` 으로 리셋 | `agg.log`(클래스 3+5, 번들 8, All tests 8) → **8** (24 아님) |
| `All tests` 중첩 요약 | `BUNDLE` 정규식이 `…\.xctest` 만 받음 → `'All tests'` 는 리셋 경로 | 위와 동일, 16 아님 |
| 0건 번들 | 합산에 0 이 들어갈 뿐 | `multi.log` 두 번째 번들 0건 → 총 **10** |
| 필터 실행(마지막 번들이 0건) | 합산이라 마지막 번들에 좌우되지 않음 | `multi.log` census **10** vs 종전 `tail -1` **0** — C1 재현·수정 확인 |
| 툴체인이 번들을 하나로 합침 | 그 하나만 합산 | `agg.log` 단일 번들 **8** |
| 실패한 번들 | `(?:passed\|failed)` 로 둘 다 받음 | `failed.log` → **10** |
| 번들 요약 0개 | rc=1 + 진단(도장 방지) | `swifttesting.log` → rc=1 |

**결정적 검산 — 실물 전체 로그로 확인했다.** 오케스트레이터가 남긴 `…/scratchpad/test-full.log`
(1,135,096B, 2026-08-31 20:23, 전체 실행)에서:
```
grep -nE "^Test Suite '[^']+\.xctest' (passed|failed) at" test-full.log   -> 7건
  WapleSnapshot:61 · WapleRender:3595 · WaplePolicy:3806 · WapleLibrary:3978 ·
  WapleCore:9044 · WapleCompatCore:9146 · WapleApp:10247
python3 scripts/dev/xctest-census.py test-full.log      -> 4016   (정적 개수와 정확히 일치)
grep "Executed" test-full.log | tail -1                 -> "Executed 476"   ← 종전 C1 레시피
grep -c "' skipped (" test-full.log                     -> 63     (ci.yml:682 의 63/64 와 일치)
```
즉 이 툴체인(Swift 6.4)은 **타깃별 7번들** 양상이라 종전 `tail -1` 은 476 을 냈다 — 하한 3,875
아래다. CI 러너가 그동안 초록이었던 것은 그쪽 툴체인이 **단일 집계 번들** 양상이었기 때문이고,
지금 수정은 그 두 양상 어디서도 같은 수를 내게 만든다. C1 이 잡은 결함이 실물이었음과
수정이 실물임이 이 한 로그에서 동시에 확인된다.

배선도 fail-closed 다. `ci.yml:769` 은 `EXECUTED=$(python3 …)` 이고 Actions 기본 셸이 `bash -e`
라 스크립트 rc=1 이 스텝 실패가 된다. 계약 테스트도 있다(`scripts/dev/tests/test_workflow_contracts.py:39-58`,
`:137-140` — `tail -1` 재도입을 금지). 실제 CI 로그와의 대조는 tail 80줄뿐이라 부분만 가능했다:
`baseline-test.log` 의 `Test Suite 'WapleAppTests.xctest' passed … Executed 476` 이
`Tests/WapleAppTests` 정적 개수 476 과 일치하고, 7타깃 합 476+30+2135+54+74+1221+26 = **4,016**.

---

## 🟠 F1 — 타깃 하나를 통째로 `XCTSkip` 하면 세 게이트가 전부 초록이다 (존재 게이트가 스킵에 눈이 멀었다)

- 자리: `.github/workflows/ci.yml:776-779`(상한 100) · `:782-785`(하한 4016) · `:790-849`(타깃 존재 게이트, 특히 `:793-794` 의 `ran` 수집)
- 근거/재현:
  1. 하한은 스킵을 포함한다 — ci.yml 자신이 그렇게 적었다(`:628-629`, `:677-678`). 그래서 전부 스킵돼도 `executed` 는 안 변한다.
  2. 존재 게이트의 `ran` 은 `Test Suite '<Class>'` 와 `Test Case '-[M.C …'` 로 모은다(`ci.yml:793-794`). **XCTest 는 스킵된 테스트에도 이 두 줄을 찍는다** — 같은 파일 `:365` 가 `' skipped ('` 를 순차 로그에서 세는 것이 그 증거다(`Test Case '-[M.C testX]' skipped (…)`). 즉 스킵과 통과를 구별하지 못한다.
  3. 남은 방어는 상한 100 뿐인데 PR #8 실측 기준선이 63/64(`ci.yml:682`)라 **여유가 36** 이다. 실측 타깃 크기: `WapleSnapshotTests 26` · `WapleCompatCoreTests 30` — 둘 다 여유 안에 들어간다.
  4. 실증(합성 로그 + ci.yml 의 게이트 파이썬을 **그대로 추출**해 실행):
     ```
     # WapleSnapshotTests 26건을 전부 skipped 로 찍은 test-output.log 를 합성
     python3 scripts/dev/xctest-census.py fake-skipped.log   -> 4016   (하한 4016 통과)
     skipped = 63(기준선) + 26 = 89                                     (상한 100 통과)
     python3 existence_gate.py    # ci.yml:790-849 verbatim
       …
       WapleSnapshotTests: 선언 2 · 로그에서 확인 2
       타깃 존재 게이트 통과 — 선언 7개 · 검사 7개 타깃 전부 실행 로그에 나타난다.   rc=0
     ```
     (추출 스크립트 `…/scratchpad/existence_gate.py`, 합성 로그 `…/scratchpad/fake-skipped.log`,
      실행 디렉터리 `…/scratchpad/gaterun/` 에 `Tests`·`Package.swift` 심링크)
- 왜 문제인가: 타깃 하나의 오라클 26~30건이 **전부** 무력화돼도 세 게이트가 초록이다. 게다가 `Tests/WapleSnapshotTests` 와 `Tests/WapleCompatCoreTests` 는 지금 `XCTSkip` 사이트가 **0개**라(실측) 정상 상태와 무력화 상태를 개수로도 구별할 수 없다.
- 기지 목록 대조: **부분만 기록돼 있고, 기록된 문장은 오히려 반대를 단언한다.** `ci.yml:630` 은 "타깃이 통째로 빠지는 양상은 이제 개수가 아니라 아래 존재 게이트가 잡는다", `:722-724` 는 "개수가 아니라 **존재**를 본다" 고 적는다 — 스킵된 타깃은 '존재' 하므로 이 주장이 성립하지 않는다. `:294-300` 의 XCTSkip 탈출 분석은 병렬 격리 게이트의 **두 클래스(16건)** 에만 적용된 것이고, `:601-602` 는 여유 36 을 적었으나 그것을 "타깃 하나가 통째로 들어간다" 로 연결하지 않았다. 제안: 존재 게이트를 `Test Case '…' passed` 로 좁히거나, 타깃별 스킵 비율 상한을 추가.

---

## 🟡 F2 — PR #8 이 **새로 쓴** 주석이 낡은 Metal census(575)를 재인용했다 — 실측 627

- 자리: `.github/workflows/ci.yml:295` (PR #8 이 신규 추가한 줄) · 세는 법 원본은 `:420-431` · 같은 값의 또 다른 재인용은 `:595`
- 근거/재현: `:420-424` 가 세는 법을 직접 적어 뒀다(`:420` 이 "**세는 법을 함께 적는다. 값만 적으면 반드시 썩는다.**"). 그 세 레시피를 HEAD 에서 그대로 돌리면:
  ```
  grep -rlE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | wc -l          -> 82   (주석 77)
  grep -rcE 'XCTSkip[^(]*\([^)]*no Metal' Tests/ --include='*.swift' | awk -F: '{s+=$2}END{print s}'  -> 364  (주석 324)
  위 파일 목록 × 정본 레시피(func test)                                                -> 627  (주석 575)
  ```
- 왜 문제인가: `:295` 는 PR #8 이 **2026-08-31 에 새로 쓴** 줄인데(`git show b883386e -- .github/workflows/ci.yml` 의 `+` 헝크에 있다)("Metal 가드가 걸린 파일에 거주하는 테스트가 575건이라") 같은 커밋의 트리에서 그 값은 627 이다. 상한 100 의 정당화 근거가 낡은 숫자다(결론은 뒤집히지 않는다 — 627 도 100 을 훨씬 넘는다). 이 문단이 스스로 경고한 부류의 결함을 문단 자신이 앓는다.
- 기지 목록 대조: 해당 없음(M13/M20 과 같은 부류이나 자리는 신규).

## 🟡 F3 — 타깃별 개수 인용이 낡았고, 같은 주석 블록 안에서 자기모순이다

- 자리: `.github/workflows/ci.yml:701-702` 와 `:719-720`
- 근거/재현: 정본 레시피로 타깃별 실측(HEAD `b883386e`):
  `WapleAppTests 476 · WapleCoreTests 2135 · WapleRenderTests 1221 · WaplePolicyTests 74 · WapleLibraryTests 54 · WapleCompatCoreTests 30 · WapleSnapshotTests 26`
  ```
  ci.yml:701-702  "WaplePolicyTests 74 · WapleLibraryTests 52 · WapleCompatCoreTests 28 · WapleSnapshotTests 26"
  ci.yml:719-720  "WapleCompatCoreTests 25 · WapleSnapshotTests 26 · WapleLibraryTests 52 · WaplePolicyTests 74"
  ```
  `WapleCompatCoreTests` 가 같은 파일 안에서 **28 과 25 로 갈리고**, 실측은 **30** 이다. `WapleLibraryTests` 는 양쪽 52, 실측 **54**. (`70a8a708` 에서는 28·52 가 맞았다 — PR #8 이 +141 을 얹으면서 이 두 값을 갱신하지 않았다: `git ls-tree -r 70a8a708` 기준 CompatCore 28 → 30, Library 52 → 54.)
- 왜 문제인가: 이 숫자들은 "타깃 넷이 전부 여유보다 작아 타깃 하나가 통째로 죽어도 이 게이트는 통과한다" 는 **게이트 설계 논증의 입력값**이다. F1 에서 실제로 그 논증이 지금도 성립하는지 판단할 때 잘못된 숫자를 쓰게 된다.
- 기지 목록 대조: 해당 없음.

## 🟡 F4 — 동시성 진단 census 는 상한만 있고 "그물이 살아 있는가" 를 확인하지 않는다 (0 = 초록)

- 자리: `.github/workflows/ci.yml:135`(`TOTAL`) · `:136-137`(`SOURCE_WARNINGS`) · `:158-161`(판정)
- 근거/재현: 판정이 `if [ "${SOURCE_WARNINGS:-0}" -gt 25 ]` 하나다. `SOURCE_WARNINGS` 는
  `grep -E '(^|/)Sources/.*:[0-9]+:[0-9]+: warning:'` 가 0건이면 그대로 0 이고, `0 -gt 25` 는 거짓이라 **통과**한다. 러너 경로 레이아웃이나 스위프트 진단 형식이 바뀌면 게이트가 조용히 무효가 된다. 바로 위 `:135` 가 `TOTAL=$(grep -c "warning:" …)` 로 총 경고 수를 이미 계산해 요약에 찍지만 **판정에는 한 번도 쓰지 않는다** — `TOTAL>0 && SOURCE_WARNINGS==0` 이면 패턴이 깨진 것인데 그 대조가 없다.
- 왜 문제인가: 이 리포가 반복해 물린 "모집단 0 인데 초록" 이다. 형제 게이트들은 전부 하한을 둔다 — `spec.yml:466-472` 가 그 관례를 명시하고(`check_canon_entry_refs` MIN_SCANNED=40 · `check_effect_texture_resolution` MIN_REFS=3 · `verify_rosetta.py` MIN_PAIRS=16), PR #8 자신도 `spec.yml:477-482` 에 `WEAssets` 하한 2900 을 새로 달았다. 같은 PR 이 새로 만든 이 게이트만 그 관례 밖이다.
- 기지 목록 대조: 해당 없음(게이트 자체가 PR #8 신규).

---

## ⚪ 관찰

**O1 — swift-testing 실행은 census 가 통째로 못 본다.** `baseline-test.log` 끝에
`✔ Test run with 0 tests in 0 suites passed` 가 **7번**(타깃 수만큼) 찍힌다. `xctest-census.py` 는
`*.xctest` 번들 요약만 합산하므로 이 채널은 0 기여다. 반면 정본 정적 레시피(`func test`)는
`@Test func testFoo()` 를 센다. 오라클 하나라도 swift-testing 으로 옮기면 "두 세는 법이
어긋나지 않는다"(ci.yml:633-635 등 열두 번 반복되는 주장)가 깨지고 하한이 거짓 실패한다.

**O2 — `test-output.log` 부재 시 census 스텝 전체가 `exit 0`.** `ci.yml:761-764`. 존재 게이트도
같은 스텝 안이라 함께 건너뛴다. 지금은 빌드 실패가 잡을 이미 붉히므로 실동작 구멍은 아니고
주석(`:759-760`)이 그 근거를 적었다 — 다만 `Test` 스텝이 `tee` 로 파일을 만드는 데 의존하는
암묵 계약이라 스텝 순서를 바꾸면 세 게이트가 한꺼번에 침묵한다.

**O3 — 하한 4,016 은 계약 테스트가 없다.** `test_workflow_contracts.py` 는 census 배선(`:137-140`)과
동시성 상한(`:142-146`)은 고정하지만 "하한 ≤ 현재 정적 개수" 는 검사하지 않는다. 래칫이 다시
밀리는 것(ci.yml:692-705 이 기록한 여유 101 사태)은 지금도 무음이다.

**O4 — PR #8 이 고친 `macos-test-typecheck.sh` 의 fail-open 은 CI 가 한 번도 실행하지 않는다.**
`grep -rn "macos-test-typecheck" .github/` 는 0건이다 — 이 도구는 어떤 워크플로에도 배선돼 있지
않다. 수정(`:130-142`, 드라이버 rc 를 버리지 않음)은 실물이지만 이를 지키는 것은
`test_workflow_contracts.py:207-212` 의 **소스 문자열 대조**뿐이라, 로직이 같은 결함으로
다시 굴러가도(예: 다른 파이프라인으로 rc 를 또 잃는 형태) 문자열만 남으면 초록이다.
같은 파일의 `linux-core-tests.sh` 는 다르다 — `test_linux_core_tests_safety.py:46-86` 이
스크립트를 **실제로 실행**해 sentinel 트리 생존과 마커 멱등성을 확인한다.
(`test_waple_saver_lifecycle.py` 는 `.m` 문자열 대조뿐이지만, WapleSaver 가 SPM 밖 ObjC 라
 리눅스 레인에서는 그 이상이 불가능하다 — 정당한 한계.)

**O5 — `scripts/dev/xctest-shim/XCTest.swift` 는 PR #8 미변경이다.**
`git log -1 -- scripts/dev/xctest-shim/` → `f8bc9571`(PR #8 이전), PR #8 diffstat 에도 없다.
소비자는 `macos-test-typecheck.sh:98-99` 하나뿐이고 그 도구가 위 O4 대로 CI 밖이므로,
이 라운드(“PR #8 이 새로 심은 결함”)의 범위 밖으로 판단해 내용 감사는 하지 않았다.

---

## 의심 (확인 못 함 — 발견으로 올리지 않는다)

**S1 — 문서 전용 커밋에 태그를 붙이면 release 가 20분 대기 후 실패할 수 있다.**
`ci.yml:17-21` 은 `paths-ignore: ["**.md", "docs/**", …]` 를 push 에 건다. `release.yml:76-99` 의
preflight 는 **정확히 그 SHA** 의 `ci.yml` 실행이 `completed/success` 여야 하고, 없으면
`check-release-ci.py:39-41` 이 `CI=missing`(rc=2) → 60회 폴링 후 `exit 1` 이다. 태그 push 에
GitHub 이 paths 필터를 적용하는지 1차 자료로 확인하지 못해 의심으로 남긴다. 방향은 fail-closed
(릴리스가 막힘)이지 fail-open 이 아니다.

**S2 — `Concurrency diagnostics census` 의 상한 25.** ci.yml:128-130 은 "Sources 고유 진단 25자리
(전부 SceneRenderer)" 라 적는데 기지 H5 는 32자리(25가 SceneRenderer)를 말한다. 빌드 금지라
직접 못 쟀다. PR #8 의 CI 가 초록이었다면(ci.yml:681-682 의 run id) 그 커밋에서는 25 이하였다는
뜻이므로 모순은 아닐 수 있다.

---

## 확인했지만 문제없던 것 (다음 라운드의 시간을 아끼기 위해)

1. **C1 수정은 진짜다** — 위 §0 표의 다섯 양상 + 실패 번들 + 0번들 전부 올바르고, 계약 테스트가 `tail -1` 재도입을 막는다.
2. **하한 4,016 = 정적 개수 4,016** (정본 레시피, 7타깃 합산으로 재확인). 여유 0 은 의도대로다.
3. **+141 의 파일별 귀속이 정확하다.** `70a8a708 ↔ b883386e` 로 실측: 변동 파일 37개, ci.yml:686-690 이 이름 붙인 7파일 합 +80(16+15+14+11+10+8+6), 나머지 29파일 +63, `CameraShakeTests` −2 → 합 141. 주석과 한 건도 어긋나지 않는다.
4. **기지 H2 해소.** `scripts/spec/check_cited_address_census.py` 는 git 추적되고 `spec.yml:176-177` 에 배선됐으며, 실행하면 `selftest 5건 통과 / 인용 고유 주소 95개 · 대조 24건 / 통과`(rc=0). `MIN_CITED=20` 과 `checked<5` 하한으로 0모집단 초록을 막는다. 계약 테스트도 있다(`test_workflow_contracts.py:191-192`).
5. **기지 M4 해소.** `scripts/spec/measure_*.py` **40개 전부**를 무코퍼스(존재하지 않는 `WE_ROOT`/`WE_WORKSHOP`/`WE_BIN`/`WAPLE_REAL_PKGS`)로, 리포 루트 사본에서 실행 → **트레이스백 0건**(종전 18건). 35개는 진단 후 rc≠0, 5개(`measure_effect_fbo_audio`·`measure_mul_convention`·`measure_nondeterminism`·`measure_oracle_gate`·`measure_particle_corpus`)는 코퍼스 없이도 정상 완료하며 재기록한 정본 5개가 **바이트 동일**(diff 무출력)이라 근거 소실 없음.
6. **워크플로 `run:` 블록 크기** — `python3 scripts/ci/check-run-block-size.py` → 최대 6,973B / 한도 21,000B, 위반 없음. PR #8 의 +288줄이 대부분 YAML 주석이라 한도에 안 들어간다.
7. **`macos-test-typecheck.sh` 의 rc 수복은 실효가 있다** — 종전 `swiftc … | grep ': error:'` 는 드라이버 rc 를 잃었고, 지금은 `raw=$(…); rc=$?` 뒤 `rc≠0 && n==0` 를 하드 실패로 다룬다(`:130-142`). 계약 테스트가 그 분기를 문자열로 고정한다(`test_workflow_contracts.py:207-212`).
8. **`linux-render-typecheck.sh --list` 커버 55/55 · 제외 0** — `find Sources/WapleRender -name '*.swift' | wc -l` = 55 와 일치(spec.yml:555 · :580 주석 그대로).
9. **`release.yml` 개선 전부 실물이다** — `spctl` 의 `|| true` 제거, 서명 secrets 4→6 전수 검사, `Require successful CI and spec` preflight(fail-closed: rc 1=즉시 거부·2=최대 20분 대기 후 실패), `Require distribution approval`. 판정 로직은 `check-release-ci.py` 로 분리돼 단위 테스트 7건이 rerun/최신 id/정확한 workflow path 계약을 잠근다.
10. **`spec.yml` 신규 게이트 두 개가 fail-closed** — `Screensaver principal class parity` 는 양쪽 리터럴이 정확히 1개인지 먼저 보고, `WEAssets EOL attributes` 는 추적 파일 하한 2900(실측 2940)을 새로 건다.
11. **병렬 격리 게이트의 전제가 지금도 성립** — `SceneRenderSettingsTests`(1클래스/1파일, func test 5, XCTSkip 0) · `SceneCompositeConventionTests`(1클래스/1파일, func test 16, XCTSkip 16). ci.yml:380-381 의 "둘 다 1클래스 1파일" 실측이 유효하다.
12. **`ci-status.py` 의 `HIDDEN` 딕셔너리에 set 을 추가한 변경은 안전** — 종료코드 판정이 `HIDDEN["no_runs"]`·`["ci_missing_for_head"]`·`["test_failures"]` 로 키를 명시해 읽고(`:340`·`:371`·`:374`), 값 전체 truthiness 를 보는 자리는 없다.
13. **`scripts/dev/tests` 4개 모듈 전부 CI 배선 + 로컬 통과** — `python3 -m unittest scripts.dev.tests.test_workflow_contracts` → 17 tests OK.
14. **`scripts/spec/validate.py`(+131) 의 신규 WE_ROOT 존재 검사가 실물이고 통과한다.** 짝 저장소(`../Waple-wallpaper-source/wallpaper_engine`)가 있는 이 맥에서 실행 → `오류 0 건 · 문서간 경고 0건`, `근거 경로: 리포 550건 존재 검사 · WE/짝 저장소 **399건 존재 검사** · 비정형/외부 261건 (합계 1210)`. **이 코드 경로는 CI(ubuntu, 짝 저장소 없음)에서는 절대 안 도는 자리라 이 실행이 유일한 실측이다.** 미검증 ref 가 기지 M11 의 661 에서 261 로 줄었다. 보고 문구도 정직하다 — `validate.py:494` 가 `WE_ROOT` 부재 시 "경로 매핑만 검사(WE_ROOT 부재)" 로 갈라 적어, CI 로그가 안 한 검사를 했다고 말하지 않는다.
15. **나머지 자체검사 전부 로컬 통과** — `python3 -m unittest scripts.dev.tests.{test_ci_status,test_linux_core_tests_safety,test_waple_saver_lifecycle}` → 16 tests OK · `python3 scripts/spec/tests/test_validate.py` → 56 tests OK · `python3 scripts/spec/check_cited_address_census.py` → rc=0.
