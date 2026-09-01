# 레인 11 — 호환성 CLI · 스냅샷 회귀 하네스 (HEAD b883386e, 읽기 전용 감사)

PR #8 이 이 레인에서 실제로 건드린 것은 **셋뿐**이다:
`Sources/WapleCompatCore/SnapshotPipeline.swift ±113` · `Sources/WapleCompat/main.swift +11` ·
`Tests/WapleCompatCoreTests/SnapshotProcessIsolationTests.swift +46`(신규) · `docs/snapshot-regression.md ±32`.
`DeepScan.swift` · `DeepReport.swift` · `ProfilePipeline.swift` · `SnapshotCompare.swift` ·
`Snapshot.swift` · `spec/golden/**` 은 **한 줄도 안 바뀌었다**.
재현: `git show --stat b883386e -- Sources/WapleCompatCore/ Sources/WapleCompat/ Tests/ spec/golden/`

변경의 내용: 결정성 셀프체크의 2차 캡처를 **같은 프로세스 재마운트 → 별도 helper 프로세스**로 옮겼다
(신설 내부 플래그 `--snapshot-self-check-pass <root> <outDir>`).

---

### [🟠] PR #8 이 고쳤다고 주장하는 결함(29종 오분류)은 **이 저장소 자신의 실측으로 안 고쳐진다** — 축이 프로세스가 아니라 세션이다
- 자리: `Sources/WapleCompatCore/SnapshotPipeline.swift:299-300, 349-352`
  (vs `spec/golden/gate-analysis.json:314-345` `oracle.gate.selfCheckIsIntraProcess` ·
  `spec/golden/nondeterminism.json` `oracle.nondet.axisIsCrossSession`)
- 근거/재현:
  ```bash
  sed -n '295,355p' Sources/WapleCompatCore/SnapshotPipeline.swift
  python3 -c "import json;g=json.load(open('spec/golden/gate-analysis.json'));
  print([e['value']['empiricalClaimResolved'] for e in g['entries'] if e['id']=='oracle.gate.selfCheckIsIntraProcess'])"
  ```
  새 주석(:349-352)은 "이제 프로세스별 RNG/해시 시드와 정적 캐시도 공유하지 않아 `deterministic`이
  실행 간 재현성을 답한다. 실측으로 기존 프로세스 내 재마운트는 실행 간 다른 29종을 전부
  deterministic=true/selfMaxDiff=0으로 오분류했다" 고 적는다.
  그런데 정본이 그 29종의 축을 이미 확정해 뒀다 — `gate-analysis.json` 의
  `empiricalClaimResolved.controlledProbe`: "같은 날 probe-nondeterminism.sh 로 **별도 프로세스 2회
  캡처**(runA/runB, 각 170종) → **차이 0종**", `status`: "축이 '실행 간' 이 아니라 **'세션 간'**
  이다 — 같은 세션 안에서는 **프로세스를 갈라도 전 코퍼스가 비트동일하고**, 세션이 갈리면 29종이 갈린다."
  새 helper 는 부모와 **같은 세션 안에서 수 초 뒤** 뜬다. 즉 정본의 통제 프로브가 이미 잰
  조건 그대로이고, 예측되는 결과는 다시 "차이 0종" = 29종 전원 `deterministic=true`.
- 왜 문제인가: `gate-analysis.json:336 fixDirection` 은 두 갈래를 적었다 —
  ① 별도 프로세스 ② 매니페스트에 "교차 실행 재현성" 별도 필드. PR #8 은 ①만 구현했는데,
  같은 문서의 실측이 ①은 이 결함에 무효임을 이미 보였다. **결함이 닫혔다는 서술만 생기고
  29종은 다음 재베이스라인에서도 그대로 strict 로 샌다.** 게이트 판정은 지금 당장 바뀌지 않는다
  (`baseline-6f0bcf0` 은 이 변경 이전 캡처라 변경 자체가 휴면 상태다).
- 기지 목록 대조: 해당 없음. 직전 감사는 "셀프체크가 프로세스 내부만 잰다"를 결함으로 적었고,
  이 항목은 **PR #8 의 수정이 그 결함을 반만 닫았다**는 최고가치 부류다.

### [🟠] 셀프체크 helper 가 못 뜨거나 도중에 죽으면 기준선 전체가 조용히 `lax` 버킷으로 내려간다 (exit 0)
- 자리: `Sources/WapleCompatCore/SnapshotPipeline.swift:304-317, 356-364, 396`
- 근거/재현:
  ```bash
  sed -n '304,317p;355,364p;394,397p' Sources/WapleCompatCore/SnapshotPipeline.swift
  ```
  helperPath = `env WAPLE_SNAPSHOT_HELPER ?? CommandLine.arguments[0]`. `process.run()` 이 던지면
  catch 는 stderr 경고만 찍고 계속한다(:314-317). 그러면 씬마다 `selfCheckDir/<id>.png` 가 없어
  :362-364 이 전건 `deterministic = false`, `selfMaxDiff = -1`, note="cross-process capture unavailable"
  를 기록하고, `runCapture` 는 마운트 실패가 없는 한 :396 에서 **exit 0** 을 낸다.
  helper 가 중간에 죽는 경우(부분 산출)도 같다 — :311-313 이 "산출된 프레임만 판정에 사용합니다" 로
  명시 수용한다.
- 왜 문제인가: `goldenVerdict` 는 `deterministic ? .strict : .lax`(`Snapshot.swift:204`)라
  전건 비결정 = 전건 lax. 상대차 항(`relDiff ≤ 0.05`)이 상한을 `12.75·luma` 로 묶어 주지만,
  결정→비결정 전환은 **`meanAbsDiff` 허용을 `min(1.5, 12.75·luma)` → `12.75·luma`
  (luma>0.118 인 씬에서 실질 완화, 밝은 씬 최대 8.5×)** 와 **`fracExceeding` 0.004 → 0.20 (50×)** 을
  **함께** 푼다.
  주석 :315 은 이 경로를 "결정적이라고 낙관하지 않는 보수적 방향" 이라 부르는데,
  **분류로서는 보수적이고 게이트로서는 정반대**다.
  완화재 2개는 실재한다: ① stdout 요약이 `비결정 N` 을 찍는다(:391) ②
  `GoldenBaselineOracleTests.testNonDeterministicSceneCountIsPinned`(:80-84)가 `nd == []` 를 못 박아
  이런 기준선이 **커밋되면** 잡는다. 다만 설치 게이트인
  `scripts/mac-session/rebaseline-golden.sh:85-86` 의 내부모순 검사는
  `deterministic==true && selfMaxDiff!=0` 만 보므로 이 경우(전건 false/-1)를 **통과시킨다**.
- 기지 목록 대조: 해당 없음(PR #8 이 새로 만든 경로).

### [🟠] 베이스라인 `entries` 가 비면 `--compare` 는 아무것도 비교하지 않고 exit 0 — 90% 하한이 산술적으로 죽는다
- 자리: `Sources/WapleCompatCore/SnapshotCompare.swift:141-151`
- 근거/재현: 조건이 `if !baseline.entries.isEmpty, rows.count * 100 < baseline.entries.count * 90`.
  `entries == []` 이면 첫 절이 거짓이라 가드를 건너뛰고, 설령 통과시켜도 `0 < 0` 은 거짓이다.
  이어 `rows/detFail/regressedToEmpty` 가 모두 비어 :150-151 이 `return 0`.
  도달 경로 둘:
  ```bash
  # (a) 전건 마운트 실패 캡처는 entries=[] 매니페스트를 디스크에 쓴다
  sed -n '318,328p;368,384p' Sources/WapleCompatCore/SnapshotPipeline.swift
  # (b) golden-gate.sh 의 축소 모드
  WAPLE_GOLDEN_SCENES="," scripts/mac-session/golden-gate.sh
  #   golden-gate.sh:71  ids = [s for s in ",".split(",") if s.strip()] == []
  #   :73-76  keep=[] , missing=∅ → 에러 없이 :77-80 이 entries=[] 매니페스트를 쓴다
  #   → --compare exit 0 → :138 이 초록 "OK 골든 무회귀" 를 찍는다
  ```
  (b) 는 :86 이 "축소 모드 — 배선 확인 전용, 무회귀를 주장하지 마라" 배너를 함께 찍으므로 반론 여지가 있다.
  결함을 세우는 것은 (a) 와 산술 자체이고, (b) 는 그 산술이 실제 호출자에서 초록으로 나오는 예시다.
- 왜 문제인가: 브리핑이 지목한 "모집단 0 → 통과" 그 자체다. `golden-gate.sh` 는 `$?` 와
  `[snap compare]` 문자열 유무만 보므로(:105, :137-142) 0종 비교와 170종 무회귀를 구분하지 못한다.
  90% 하한 옆 주석(:125-140)이 **정확히 이 부류를 막으려고** 쓰였는데 `compared==0` 한 점을
  막고서 `entries==0` 한 점을 새로 열었다.
- 기지 목록 대조: 해당 없음. (2026-08-19 수정 주석이 적은 "완전일치일 때만 걸린다" 결함의 잔여 극점.)

### [🟡] PR #8 이 자기 diff 로 밀어낸 줄 번호 인용을 안 고쳤다 — `--deep(:142)` 는 PR #8 직전까지 정확했다
- 자리: `Sources/WapleCompat/main.swift:167-169`
- 근거/재현:
  ```bash
  git show b883386e~1:Sources/WapleCompat/main.swift | sed -n '142p'   # guard projectsFound … exit(2)  ← 정확했다
  grep -n 'guard projectsFound' Sources/WapleCompat/main.swift          # 153  ← PR #8 이 위에 11줄을 넣었다
  grep -n '씬 0개 — root 가' Sources/WapleCompatCore/SnapshotPipeline.swift   # 295 (주석은 215)
  ```
  main.swift:167-169 의 6개 인용 중:
  `--deep(:142)`→**153**(PR #8 이 깼다) · `--capture(SnapshotPipeline:215)`→**294**(기존 10줄 드리프트 +
  PR #8 의 79줄) · `--compare(SnapshotCompare:142)` ✅ · `--inventory(ProfilePipeline:86)` ✅ ·
  `--vis-blast(:136)` ✅ · `--profile(:241)` ✅.
- 왜 문제인가: 이 주석은 "7개 모드 중 이 기본 스캔만 0건 가드가 없었다" 를 증명하려고 형제 여섯의
  좌표를 나열한다 — 좌표가 틀리면 증명이 무효다. 밀린 두 개 중 하나는 **PR #8 자신의 +11 줄**이 원인이다.
- 기지 목록 대조: **M10 의 재발**(직전 라운드가 잡은 "주석이 자기 diff 가 밀어낸 줄 번호 인용"과 같은 부류).
  (참고: `scripts/mac-session/golden-gate.sh:31` 의 `SnapshotPipeline.swift:266`→현재 431 은
  PR #8 이전부터 밀려 있던 기존 드리프트다 — 새 발견으로 세지 마라.)

### [🟡] 정본 `oracle.gate.selfCheckIsIntraProcess` 가 `status: 확정` 인 채로 코드와 어긋났다 — 코드 인용 좌표도 이제 딴 함수를 가리킨다
- 자리: `spec/golden/gate-analysis.json:314-345`(특히 `value.code` 와 `evidence[0].ref`) ·
  생성기 `scripts/spec/measure_oracle_gate.py:555-616`
- 근거/재현:
  ```bash
  python3 -c "import json;g=json.load(open('spec/golden/gate-analysis.json'));
  e=[x for x in g['entries'] if x['id']=='oracle.gate.selfCheckIsIntraProcess'][0];
  print(e['value']['code']); print(e['evidence'][0])"
  sed -n '187,198p' Sources/WapleCompatCore/SnapshotPipeline.swift   # 지금 여기는 pngToRGBA 의 F840 주석/CGContext
  git show --stat b883386e -- spec/golden/                            # 0 files
  ```
  정본은 `"code": "SnapshotPipeline.swift:191 — 2차 캡처가 같은 프로세스 안에서 captureFrame 재호출"`,
  `evidence: {ref: "Sources/WapleCompatCore/SnapshotPipeline.swift:187-198", note: "2차 캡처가 같은 프로세스"}`
  라고 적는데, HEAD 의 187-198 은 **`pngToRGBA` 의 F840/CGContext 블록**이다.
  `measure_oracle_gate.py:557` 이 이 문자열을 **하드코딩**하므로 정본을 재생성해도 안 고쳐진다.
  같은 서술이 살아 있는 곳: `spec/golden/nondeterminism.json:75-76,93` ·
  `spec/golden/gate-analysis.json:220` · `scripts/mac-session/golden-gate.sh:112-115` ·
  `scripts/mac-session/rebaseline-golden.sh:81-84` ·
  `Tests/WapleRenderTests/GoldenBaselineOracleTests.swift:77-79` · `docs/snapshot-regression.md:161`.
- 왜 문제인가: PR #8 이 이 항목의 `fixDirection` 을 실행하면서 **`spec/golden/` 은 한 파일도 안 건드렸다.**
  결과가 반반이다 — 서술된 **원인**("프로세스 내부만 잰다")은 코드에서 거짓이 됐고,
  서술된 **결과**("29종이 deterministic=true 로 실려 strict 로 샌다")는 위 🟠 첫 항목 때문에
  여전히 참이다. 원인·결과가 갈린 채 `확정` 으로 남아 있어 다음 독자가 어느 쪽을 믿어도 틀린다.
- 기지 목록 대조: 해당 없음(PR #8 이 만든 정본-코드 괴리).

### [🟡] `docs/snapshot-regression.md` 의 결정성 절이 PR #8 이전 메커니즘을 그대로 서술한다
- 자리: `docs/snapshot-regression.md:83-85`, `:161-162`
- 근거/재현: `sed -n '83,85p;160,162p' docs/snapshot-regression.md`
  - :83-85 "`--capture` 는 프레임을 낸 씬을 **독립 재마운트로 2회 캡처**해 self-diff 를 잰다. …
    **empty/실패 씬은 1×**(자기 diff 무의미)."
    → 지금은 재마운트가 아니라 별도 프로세스이고, helper 는 `sceneFolders` 전건을 순회하므로
    (`SnapshotPipeline.swift:243, 251-268`) **empty/실패 씬도 2× 캡처된다.**
    helper 는 empty 를 실패로 세어 exit 1 을 내고(:221-223, :272) 부모는 경고만 찍는다(:311-313).
  - :161-162 "그 필드는 같은 프로세스 안 2회 캡처만 재므로" → 코드상 거짓(단, `baseline-6f0bcf0`
    데이터에 대해서는 여전히 참 — 그 기준선이 변경 이전 캡처이기 때문).
  - 신설 플래그 `--snapshot-self-check-pass` 는 문서·`printUsage` 어디에도 없다(아래 ⚪ 참조).
- 왜 문제인가: 이 문서가 재베이스라인 절차의 1차 근거다. "empty 는 1×" 를 믿고 소요를 추정하면
  비디오-백드가 섞인 코퍼스에서 어긋난다(현행 170/0-empty 코퍼스에서는 캡처 횟수 자체는 2×170 로 불변).
- 기지 목록 대조: 해당 없음(PR #8 이 :23-27 과 :77-79 는 갱신했으면서 :83-85·:161 은 남겼다).

### [⚪] `printUsage` 의 "전 옵션(11개 + --help)" 은 이제 14/15 다 — 신설 플래그가 목록 밖이다
- 자리: `Sources/WapleCompat/main.swift:205-206`(주석) vs `:31-74`(파서) vs `:208-240`(사용법)
- 근거/재현: `grep -o 'case "--[a-z-]*"' Sources/WapleCompat/main.swift` (16건 = 15옵션 + --help) — 파서가 처리하는 옵션은
  `--json --strict --deep --only --decode-ogg --naive --capture --compare --label --profile
  --inventory --vis-blast --remount --frame-res --snapshot-self-check-pass` = **15종**,
  `printUsage` 가 적는 것은 **14종**. 주석은 "11개" 라고 적고 "실제로 처리하는 **전** 옵션을
  나열한다" 고 약속한다.
- 왜 문제인가: F149 주석의 약속(전수 나열)이 깨졌고 도수도 낡았다. 실동작 영향은 없다 —
  `--snapshot-self-check-pass` 는 `run()` 최상단에서 즉시 분기해 exit 하므로 다른 모드를 오염시키지 않는다.
  다만 `SnapshotPipeline.swift:207-208` 이 "공개 CLI 표면이 아니라" 고 적는데, 실제로는 공개
  인자 파서가 받는다(`warnIgnoredFlagCombinations` 도 건너뛴다 — main.swift:109-116).
- 기지 목록 대조: 해당 없음(M1/M15 와 같은 "정본 도수 거짓" 부류).

### [⚪] `DiffThreshold.lax.meanAbsDiff = 14.0` 은 도달 불가 — 문서 임계표가 실효 없는 값을 광고한다
- 자리: `Sources/WapleSnapshot/Snapshot.swift:117, 200-206` · `docs/snapshot-regression.md:104`
- 근거/재현(계산): `goldenVerdict` 의 pass 는 `passes(m, threshold) && relDiff <= 0.05 && …` 이고
  `relDiff = meanAbsDiff / (max(luma, 0.02) * 255)`. 따라서 어떤 씬이든
  `meanAbsDiff <= 0.05 * 255 * luma = 12.75 * luma <= 12.75 < 14.0`.
  즉 `lax` 의 **상수 14.0 은 결코 결정항이 되지 못한다** — 비결정 버킷의 실효 mean 상한은
  언제나 relDiff 가 주는 `12.75·luma` 다. (버킷 전환이 mean 축을 푸는 것 자체는 맞다 — 위 🟠 참조.)
- 왜 문제인가: 문서 임계표(:101-105)와 `gate-analysis.json:61` 이 "lax = 평균차 14 까지 허용" 으로
  읽히지만 실효 상한은 `12.75·luma` 다. 판정 자체는 안전한 방향(더 엄격)이라 실동작 파손은 없다.
- 기지 목록 대조: 해당 없음. **의심 아님 — 순수 산술로 확정**.

---

## 의심(확인 못 함 — 실행 필요)

1. **helper 경로 해석**: `CommandLine.arguments[0]` 이 상대/PATH-이름일 때
   `URL(fileURLWithPath:).standardizedFileURL` 이 cwd 기준으로 풀린다.
   현행 호출부는 전부 `swift run -c release` 또는 `"$BIN"` 절대경로라
   (`scripts/mac-session/golden-gate.sh:96`, `probe-*.sh`, `scripts/ab-deviations/02-capture-ab.sh:128`)
   실무 도달은 없어 보인다. 하지만 `WAPLE_SNAPSHOT_HELPER` 미설정 + PATH 설치본 실행이면
   위 🟠 두 번째 항목의 "전건 lax" 경로로 떨어진다. 코퍼스 없이는 확인 불가.
2. **helper 의 세션/커서 조건**: 부모가 캡처를 시작하기 **전에** helper 를 통째로 돌리므로
   두 패스 사이에 사람이 마우스를 움직이면 포인터 핀(중앙 고정) 밖 요인은 없더라도
   `rebaseline-golden.sh` 의 커서-이동 게이트와 셀프체크가 이제 같은 축을 두 번 재는 셈이다.
   중복인지 상호보완인지는 실행해 봐야 한다.
3. 실물 코퍼스 부재로 `--capture`/`--compare` 를 한 번도 돌리지 못했다(브리핑 「확인 못 한 것」 3번 그대로).

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약)

- **① 판정 임계가 프로덕션 심볼을 부른다.** `SnapshotCompare.swift:86` 과
  `Tests/WapleSnapshotTests/SnapshotTests.swift:101,110,118-147` 이 **같은** `goldenVerdict`
  (`Snapshot.swift:194`)를 호출한다. 과거의 "수식 베끼기" 는 실제로 해소됐고,
  `testGoldenVerdictBranches` 가 relDiff·structureLoss·deterministic·identical 네 항을 개별로 못 박는다.
  `Tests/WapleCompatCoreTests/CompatCoreParityTests.swift`(500줄)·`DeepScanHelpersTests.swift` 도
  전부 프로덕션 심볼 호출이고 리터럴 재구현이 없다.
- **③ `GoldenBaseline.currentLabel = "baseline-6f0bcf0"`**(`GoldenBaselineOracleTests.swift:29`)이
  가리키는 `spec/golden/snapshot/baseline-6f0bcf0/` 이 HEAD 에 실재한다. `manifest.json` 의
  `gitSHA=6f0bcf0`, `entries=170` 이 테스트 단언(:53-54)과 일치. 이력 라벨 `baseline-81098bb` 도
  `81098bb`/170 로 일치(:61-62). `golden-gate.sh:43` 도 상수 대신 코드에서 라벨을 읽는다.
- **④ 매니페스트 ↔ 실제 파일 수 일치.** 두 기준선 모두 entries 170 · thumbs/*.png 170 ·
  id↔파일명 **완전일치**(누락 0, 잉여 0, 중복 id 0). `git ls-files spec/golden/snapshot | wc -l` = 355
  (= 170+170+manifest 2+README+81098bb/sentinel.log+nondet 하위). 이미지 바이트는 열지 않았다.
- **무코퍼스 거동**: 7개 모드 전부 exit 2 로 떨어진다 — 기본 스캔(`main.swift:179-188`) ·
  `--deep`(:153) · `--capture`(`SnapshotPipeline.swift:294`) · `--compare`(코퍼스 부재면
  전건 skip → 90% 하한 `0*100 < 170*90` → `SnapshotCompare.swift:142-149`) ·
  `--inventory`(`ProfilePipeline.swift:86`) · `--vis-blast`(:136) · `--profile`(:241).
  "0개 처리 후 성공" 은 위 🟠 세 번째 항목의 `entries==[]` 한 점만 남았다.
- **정본 인용 중 살아 있는 것**: `gate-analysis.json:330`/`:67` 의 `Snapshot.swift:204`
  (`deterministic ? .strict : .lax`)는 HEAD 에서 정확히 204 행이다.
- **helper 프로세스 위생**: 환경 상속(따라서 `WAPLE_THUMB_W/H`·`WAPLE_CAPTURE_TIME`·
  `WAPLE_BASE_ASSETS` 가 두 패스에서 동일), tmp 의 PID 스코프(`waple_snap_self_<pid>` /
  `waple_snap_cap_<pid>`), 재귀 방지(`run()` 최상단 분기 → 즉시 exit) 전부 정상.
  `SnapshotProcessIsolationTests.swift:12-45` 는 진짜 새 PID 와 인자 축자 전달(공백 포함 경로)을
  가짜 helper 스크립트로 검증한다 — 자기 산수가 아니다.
- **PR #8 이 남긴 낡은 내부 근거 1건(참고)**: `SnapshotPipeline.swift:329-330, 337-338` 이
  아직 "셀프체크가 png1 을 덮어쓰면" / "셀프체크(2차 캡처)가 tmp 를 덮어쓰기 전에" 로
  복사 순서를 정당화한다. 2차 캡처는 이제 부모 tmp 에 쓰지 않으므로 근거는 소멸했다(동작은 무해).
- `DeepScan.swift` · `DeepReport.swift` · `ProfilePipeline.swift` 는 PR #8 이 안 건드렸다
  (마지막 변경 `970f5886`/`f1406b27`/`1816e09b`, 전부 직전 감사 범위 안) — 이번 라운드 재탐색 생략.
