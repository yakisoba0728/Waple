# 문서 색인

## 먼저 볼 것

| 문서 | 무엇 | 언제 읽나 |
| --- | --- | --- |
| [../README.md](../README.md) | 프로젝트 소개, 지원 범위 표, 설치 | 처음 왔을 때 |
| [../AGENTS.md](../AGENTS.md) | 모듈 지도, 빌드·테스트, 코퍼스, 함정, 관례 | **코드를 만지기 전에** |
| [../BACKLOG.md](../BACKLOG.md) | 트리거 기반 잔여 과제 | 무엇을 할지 찾을 때 |

## 현행 문서

| 문서 | 내용 |
| --- | --- |
| [RELEASING.md](RELEASING.md) | 태그 push → `release.yml` → `Waple.dmg` 자동 배포 절차, 서명·공증 현황 |
| [snapshot-regression.md](snapshot-regression.md) | 씬 170종 픽셀 스냅샷 회귀 게이트(`WapleCompat --capture`/`--compare`). 렌더러를 건드렸다면 이걸 돌린다 |
| [playback-architecture.html](playback-architecture.html) | 재생 정책·플레이리스트·렌더러 상태 전파를 보여 주는 대화형 구조도 |
| [dev/re-methodology.md](dev/re-methodology.md) | **RE 방법론** — 실제로 당한 함정 26개(바이너리 16 · 정본 5 · Swift/CI 4)와 검증 규율(격리 검증 · 빌드 락 · 무엇이 실제로 검사되는가 · 돌연변이). **WE 를 실측하기 전에 읽는다** |
| [dev/linux-typecheck.md](dev/linux-typecheck.md) | 리눅스에서 `WapleRender`/테스트/`WapleCompatCore` 를 타입체크하는 법과 그 커버·한계. 맥이 없을 때의 유일한 그물 |
| [../scripts/dev/macos-test-typecheck.sh](../scripts/dev/macos-test-typecheck.sh) | **Xcode 없는 맥**에서 테스트 타깃 7개를 타입체크한다(XCTest 대역 모듈). `swift test` 가 아예 안 도는 환경의 커밋 전 그물 — 스크립트 머리말에 커버·한계가 실측과 함께 적혀 있다 |
| [../spec/README.md](../spec/README.md) | **WE 2.8.42 정본** — 바이너리·코퍼스·포맷·엔진 심볼·에셋. 근거 필수, 재측정 스크립트 동반 |
| [../spec/golden/snapshot/README.md](../spec/golden/snapshot/README.md) | 커밋된 스냅샷 기준선과 읽을 때의 주의 3건 |
| [we-parity-2026-08-16.md](we-parity-2026-08-16.md) | **WE 실기 대비 파리티 첫 정량 측정** — 골든이 못 재는 축(Waple↔WE). 7종 중 1종만 구별불가 |
| [ui-redesign-2026-08-17.md](ui-redesign-2026-08-17.md) | **UI 전면 개편 청사진** — 사이드바 네비게이션 이관, 단위별 파일 소유(병렬 작업 기준), 접근성·현지화 규약, WAPLE_SMOKE 게이트 이관. UI 를 만지기 전에 읽는다 |

WE 엔진 이식 프로그램의 차터·스펙·계획은 [superpowers/](superpowers/) 에 있다.
정본 **데이터**는 리포 루트 [../spec/](../spec/) 이다.

## RE 산문 — [re/](re/)

**[2026-08-25] 이 절이 통째로 빠져 있었다.** `docs/re/` 는 33개 문서인데 색인에 한 줄도 없었고,
그동안 **소스와 테스트가 191곳에서 이 파일들을 인용**하고 있었다 — 즉 코드가 근거로 삼는 문서를
색인이 모르고 있었다. 방법론(`dev/re-methodology.md`)만 있고 **결과물**이 없던 셈이다.

`spec/` 이 기계가 읽는 정본(JSON)이라면 `re/` 는 **사람이 읽는 그 근거**다 — 원본 바이너리의
어느 주소에서 무엇을 읽었고, 어떤 해석을 버렸고, 무엇이 아직 [추정]인지가 적혀 있다.
소스 주석이 `docs/re/<파일>.md §N` 으로 가리키는 그 대상이다.

| 갈래 | 문서 |
| --- | --- |
| 포맷 | [package-format.md](re/package-format.md) · [tex-format.md](re/tex-format.md) · [json-number-tags.md](re/json-number-tags.md) |
| 씬 모델 | [scene-object-model.md](re/scene-object-model.md) · [object-propagation.md](re/object-propagation.md) · [property-animation.md](re/property-animation.md) · [unimplemented-json-keys.md](re/unimplemented-json-keys.md) · [bundled-key-coverage.md](re/bundled-key-coverage.md) |
| 파티클 | [particle-operator-vm.md](re/particle-operator-vm.md) · [particle-control-points.md](re/particle-control-points.md) · [particle-emitter-controlpoint-binary-2026-08-31.md](re/particle-emitter-controlpoint-binary-2026-08-31.md) · [particle-world-basis.md](re/particle-world-basis.md) · [remap-operation.md](re/remap-operation.md) |
| 셰이더 | [shader-translation.md](re/shader-translation.md) · [shader-uniforms.md](re/shader-uniforms.md) · [shader-combos.md](re/shader-combos.md) · [material-blend.md](re/material-blend.md) |
| 렌더 | [scene-lighting.md](re/scene-lighting.md) · [scene-postprocessing.md](re/scene-postprocessing.md) · [tonemapping.md](re/tonemapping.md) · [volumetric-light.md](re/volumetric-light.md) · [camera-motion.md](re/camera-motion.md) · [camera-parallax-binary-2026-08-31.md](re/camera-parallax-binary-2026-08-31.md) · [next-engine-parity-2026-08-31.md](re/next-engine-parity-2026-08-31.md) · [sprite-occlusion.md](re/sprite-occlusion.md) · [fluid-simulation.md](re/fluid-simulation.md) |
| 3D·퍼펫 | [skeleton-animation.md](re/skeleton-animation.md) |
| 텍스트·색 | [text-layer.md](re/text-layer.md) · [scheme-color.md](re/scheme-color.md) |
| 미디어·오디오 | [media-playback.md](re/media-playback.md) · [audio-capture.md](re/audio-capture.md) · [playlist-transition.md](re/playlist-transition.md) |
| 입력·웹·스크립트 | [pointer-interaction.md](re/pointer-interaction.md) · [web-wallpaper-bridge.md](re/web-wallpaper-bridge.md) · [scene-script-api.md](re/scene-script-api.md) |
| 도구 | [compatibility-analyzer.md](re/compatibility-analyzer.md) |

### 규약 — `파일:줄` 인용은 **드리프트한다** (2026-08-28 선언)

`docs/re/**` 의 `SomeFile.swift:123` 꼴 인용은 **작성 시점의 값**이다. 소스가 바뀌면 문서는
따라가지 않는다. 이건 방치가 아니라 구조적 성질이다 — 인용이 수백 곳이고, 그것을 자동으로
갱신하는 게이트는 없다.

**얼마나 낡았나(2026-08-28 표본 조사): 두 독립 측정이 76~95% 드리프트로 수렴했다.**
대표 3건(이번에 실제 값으로 고쳤다):

| 문서 | 인용 | 실제 |
| --- | --- | --- |
| `re/material-blend.md` | `SceneRendererResources.swift:488` | **552** |
| `re/material-blend.md` | `SceneRenderer3D.swift:781` | **806** |
| `re/bundled-key-coverage.md` | `SceneDocument.swift:981` | **4052** |

`re/unimplemented-json-keys.md` 는 아예 본문에서 *"그 줄번호는 당시 값이다"* 라고 스스로 인정한다.

> **따라가는 법: 줄번호로 가지 마라. 인용문이 함께 적어 둔 식별자·문자열로 `grep` 해라.**
>
> ```
> # 나쁨 — 엉뚱한 줄을 읽는다
> sed -n '488p' Sources/WapleRender/SceneRendererResources.swift
>
> # 좋음 — 인용이 함께 적은 코드 조각으로 찾는다
> grep -n 'blendAdditive: layer.blendMode == "additive"' Sources/WapleRender/SceneRendererResources.swift
> ```
>
> 그래서 **인용할 때는 줄번호만 적지 말고 식별자나 코드 조각을 같이 적어라.** 줄번호는
> 썩지만 식별자는 안 썩는다. 이미 그렇게 적힌 인용(`SceneDocument.materialUserTextureKeepAspect
> 선언부` 같은 심볼 인용)이 이 리포에서 가장 오래 살아남은 형태다.

**줄번호 전수 갱신은 하지 않는다.** 한 번 고쳐도 다음 커밋에 다시 썩고, 그 작업이 문서의
사실관계를 개선하지도 않는다. 대신 위 규약으로 **읽는 쪽이 안전하게 따라가게** 한다.
바이너리 VA 인용(`0x1401…`)은 이 문제가 없다 — WE 2.8.42 는 고정 아티팩트다.

## 이력 — [history/](history/)

개발 당시의 계획서·설계서·감사 리포트 **71개**다. 참조 문서가 아니라 **기록**이다.
현재 코드와 다를 수 있으니 사실 확인은 코드나 위 현행 문서로 해라.

지우지 않는 이유는 이것이 설계 근거이기 때문이다 — 무엇을 왜 그렇게 했고, 어떤 대안을
왜 버렸고, 어떤 결론을 나중에 뒤집었는지가 여기 남아 있다. 자세한 구성은
[history/README.md](history/README.md).

## 문서 밖에 있는 것

> **[정정 2026-08-30] 이 절이 추적 문서 8개를 빠뜨리고, 서로 다른 두 파일을 `최신` 으로 표시했다.**
> `docs/` 의 추적 top-level 문서는 20개인데 이 색인은 12개만 실었다. 빠진 것:
> `cross-analysis-2026-08-25.html` · `handoff-2026-08-26.md` · `-08-26b` · `-08-27` · `-08-27b` ·
> `-08-27c` · `mac-handoff-2026-08-01.md` · `sweep-2026-08-19.md`.
> 여덟 전건 `docs/history/README.md` 에도 없으므로 **이력으로 옮겨진 것이 아니라 그냥 누락**이었다.
> 세는 법:
> ```bash
> git ls-files docs | grep '^docs/[^/]*$' | while read f; do
>   b=$(basename "$f"); [ "$b" = README.md ] && continue
>   grep -q "$b" docs/README.md || echo "MISSING $b"
> done
> ```
> **[후속 2026-08-31]** 아래 “`swarm-audit` 가 최신 감사”라는 판정은 그 때는
> 맞았지만, 루트 `AUDIT-FULL-2026-08-31.md`가 추가되며 이제는 역사 설명이 됐다.
> `full-audit-2026-08-26.md` 가 `swarm-audit`의 선행 라운드이고 `audit-fixplan`은 08-20이라는
> 관계는 그대로다.
> 거짓이었던 것은 `handoff-2026-08-25.md` 쪽이다 — 그보다 새 인계가 다섯 개 있는데 전부 미색인이었다.
> 진짜 결함은 **서로 다른 두 최상급에 수식 없는 `최신` 을 쓴 것**이라, 지우지 않고
> `최신 감사` / `최신 인계` 로 갈랐다. 이 절은 감사(위)와 인계(아래) 두 갈래가 소제목 없이
> 섞여 있어 그렇게 읽혔다.
>
> 이 결함은 이 파일이 [2026-08-25] 툼스톤(위 `re/` 절)으로 이미 자기 목소리로 기록한 부류다.
> 실측한 원인: 여덟 파일 전건에 대해 **파일을 추가한 커밋이 이 색인을 건드리지 않았다.**
> 날짜 붙은 인계는 세션마다 쌓이므로, `최신 인계` 를 손으로 유지하지 말고 위 명령으로
> **파일명 날짜가 가장 늦은 것**을 확인하는 편이 안전하다.

### 감사

- [../AUDIT-FULL-2026-08-31.md](../AUDIT-FULL-2026-08-31.md) — **최신 감사.** Waple과
  `Waple-wallpaper-source` 전체를 다시 재현한 수정 전 스냅샷. 머리말의 2026-08-31
  후속 정정을 함께 읽어라.
- [../WAPLE-ANALYSIS-SUMMARY-2026-08-27.md](../WAPLE-ANALYSIS-SUMMARY-2026-08-27.md) — 2026-08-27
  양 리포 딥 분석 요약. 수치는 §1.1 정정을 정본으로 삼는다.
- [swarm-audit-2026-08-26.md](swarm-audit-2026-08-26.md) — 27 워크플로우 스웜 감사(코드 미수정).
  완주 199/224 레인 · 발견 1,058건(critical 12 · high 87). 교차 확정 핵심 5건(전역 캡처 핀 · 재생정책 미배선 ·
  전환 모델 데드코드 · RE 좌표 +0xD0 시프트 · 수치 진실성)과 P2 미결 4항목 판명.
- [full-audit-2026-08-26.md](full-audit-2026-08-26.md) — 16레인 전수 감사(코드 미수정). critical/high 0건,
  확정 medium 9건 + low 39건 군집. 위 스웜 감사의 선행 라운드다.
- [sweep-2026-08-19.md](sweep-2026-08-19.md) — 전수 스윕 보고서(에이전트 27개 × 6단계). **수정 전
  시점의 스냅샷**임을 스스로 선언한다 — 본문 수치는 지금과 다르다. 값어치는 결함 목록이 아니라
  §5(파고들었으나 결함이 아니었던 것)와 §6(버그가 생기는 방식)이다.
  (동명의 `docs/history/parity-sweep-2026-08-19.md` 와 **다른 문서다** — 정본·스크립트가 인용하는
  쪽은 그 history 파일이다.)
- [audit-fixplan-2026-08-20.md](audit-fixplan-2026-08-20.md) — Opus 20병렬 전수 감사의
  수정 계획. 착지분·다음 대상·게이트 자체의 구멍·아직 재확인 안 한 보고를 갈라 놓았다.
  에이전트끼리 정반대로 갈린 지점(`xmm15` 지배 관계)의 판정 근거가 §0 에 있다.
- [cross-analysis-2026-08-25.html](cross-analysis-2026-08-25.html) — Waple × WE 교차 분석
  (HTML, 브라우저로 열 것). `handoff-2026-08-26.md` 가 인용한다.

### 인계

- [handoff-2026-08-27c.md](handoff-2026-08-27c.md) — **가장 최근에 기록된 인계(커밋 `2093b50` 시점 스냅샷; 현재 HEAD 상태표가 아님).** 에이전트 라운드 — §5 원장 소진.
  §2 가 **BACKLOG 산문이 실측으로 틀렸던 사례 셋**을 기록한다("캡처 갭 ②는 과대평가였다 …
  도달 불가다"). §5 는 **한 번도 실행된 적 없는 수정**의 유일한 원장이고, 어떤 게이트도 보지
  않는 축을 적는다 — **행동에 옮기기 전에 원장 산문을 재측정하라**는 이 문서의 교훈이 여기 있다.
- [handoff-2026-08-27b.md](handoff-2026-08-27b.md) — 디컴파일 코퍼스 재생성 라운드(짝 저장소).
  `.pdata` 1차 함수 6,824/6,824 일치로 시프트가 필요 없어졌고, 이 항목이 막고 있던 RE 작업이 열렸다.
- [handoff-2026-08-27.md](handoff-2026-08-27.md) — 재생정책 2단계. 프로덕션 배선까지 갔으나
  **그 동작이 세션 중 한 번도 실행되지 않았다**는 것이 §3 의 본체다.
- [handoff-2026-08-26b.md](handoff-2026-08-26b.md) — 위 조사 라운드의 P1 원장을 실제로 고친 라운드.
  P1 지시 중 하나(RE 좌표)는 실측으로 뒤집혀 반대로 처리했다. **커밋 SHA 는 이후 리라이트로
  전부 갈렸다**(문서 안 값은 새 SHA 로 갱신돼 있다).
- [handoff-2026-08-26.md](handoff-2026-08-26.md) — 조사 전용 라운드(사용자 지시로 코드 미수정).
  스웜 감사 1,058건 중 교차 확정 5건과 그중 ①②가 다음 세션 본체라는 판정.
- [handoff-2026-08-25.md](handoff-2026-08-25.md) — 전수 감사 + 수정 14커밋.
  main 이 354커밋 뒤처져 있던 상태의 해소, strict-concurrency 100→32, 그리고 **검증 환경에
  두 번 속은 기록**(Xcode 유무가 세션 중 바뀜 · 오디오 장치 사망). 남은 일과 그 위험도.
- [handoff-2026-08-20.md](handoff-2026-08-20.md) — WE 파티클 오퍼레이터 VM 재현 라운드.
  바이트코드 구조와 함정 넷, 고친 발산 13건, **일부러 안 한 것**과 그 사유.
- [handoff-2026-08-19.md](handoff-2026-08-19.md) — 전수 리뷰 세션(결함 46건). 6.5일 가동 후
  렌더 스레드 무한 루프, 반사/굴절 할당자 뒤바뀜, Steam API 키 평문 캐시.
- [handoff-2026-08-17.md](handoff-2026-08-17.md) — 2026-08-17 중단 지점 인계. wip/ 브랜치 둘의 남은 완료 조건과 캡처 함정.
- [mac-handoff-2026-08-01.md](mac-handoff-2026-08-01.md) — 윈도우 → macOS 이관 절차.
  [../AGENTS.md](../AGENTS.md) 머리말이 "작업 환경을 옮기는 중이라면" 으로 가리키는 그 문서다.
  본문은 2026-08-01 시점 기록이고 뒤집힌 것은 `[갱신]` 표기로 덧붙어 있다.

### 리포 밖

- **`waple-baselines/`** — 시각 회귀 골든 이미지. 리포 밖이라 `git ls-files` 에 없다.
  `WapleCompat --capture` 로 재생성한다.
- **실물 WE 코퍼스** — 저작권 때문에 리포에 없다. `WAPLE_REAL_PKGS`/`WAPLE_BASE_ASSETS`
  로 지정한다. 자세한 것은 [../AGENTS.md](../AGENTS.md) 의 코퍼스 절.
