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
| 파티클 | [particle-operator-vm.md](re/particle-operator-vm.md) · [particle-control-points.md](re/particle-control-points.md) · [particle-world-basis.md](re/particle-world-basis.md) · [remap-operation.md](re/remap-operation.md) |
| 셰이더 | [shader-translation.md](re/shader-translation.md) · [shader-uniforms.md](re/shader-uniforms.md) · [shader-combos.md](re/shader-combos.md) · [material-blend.md](re/material-blend.md) |
| 렌더 | [scene-lighting.md](re/scene-lighting.md) · [scene-postprocessing.md](re/scene-postprocessing.md) · [tonemapping.md](re/tonemapping.md) · [volumetric-light.md](re/volumetric-light.md) · [camera-motion.md](re/camera-motion.md) · [sprite-occlusion.md](re/sprite-occlusion.md) · [fluid-simulation.md](re/fluid-simulation.md) |
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

- [swarm-audit-2026-08-26.md](swarm-audit-2026-08-26.md) — **최신.** 27 워크플로우 스웜 감사(코드 미수정).
  완주 199/224 레인 · 발견 1,058건(critical 12 · high 87). 교차 확정 핵심 5건(전역 캡처 핀 · 재생정책 미배선 ·
  전환 모델 데드코드 · RE 좌표 +0xD0 시프트 · 수치 진실성)과 P2 미결 4항목 판명.
- [full-audit-2026-08-26.md](full-audit-2026-08-26.md) — 16레인 전수 감사(코드 미수정). critical/high 0건,
  확정 medium 9건 + low 39건 군집. 위 스웜 감사의 선행 라운드다.
- [audit-fixplan-2026-08-20.md](audit-fixplan-2026-08-20.md) — Opus 20병렬 전수 감사의
  수정 계획. 착지분·다음 대상·게이트 자체의 구멍·아직 재확인 안 한 보고를 갈라 놓았다.
  에이전트끼리 정반대로 갈린 지점(`xmm15` 지배 관계)의 판정 근거가 §0 에 있다.
- [handoff-2026-08-25.md](handoff-2026-08-25.md) — **최신.** 전수 감사 + 수정 14커밋.
  main 이 354커밋 뒤처져 있던 상태의 해소, strict-concurrency 100→32, 그리고 **검증 환경에
  두 번 속은 기록**(Xcode 유무가 세션 중 바뀜 · 오디오 장치 사망). 남은 일과 그 위험도.
- [handoff-2026-08-20.md](handoff-2026-08-20.md) — WE 파티클 오퍼레이터 VM 재현 라운드.
  바이트코드 구조와 함정 넷, 고친 발산 13건, **일부러 안 한 것**과 그 사유.
- [handoff-2026-08-19.md](handoff-2026-08-19.md) — 전수 리뷰 세션(결함 46건). 6.5일 가동 후
  렌더 스레드 무한 루프, 반사/굴절 할당자 뒤바뀜, Steam API 키 평문 캐시.
- [handoff-2026-08-17.md](handoff-2026-08-17.md) — 2026-08-17 중단 지점 인계. wip/ 브랜치 둘의 남은 완료 조건과 캡처 함정.
- **`waple-baselines/`** — 시각 회귀 골든 이미지. 리포 밖이라 `git ls-files` 에 없다.
  `WapleCompat --capture` 로 재생성한다.
- **실물 WE 코퍼스** — 저작권 때문에 리포에 없다. `WAPLE_REAL_PKGS`/`WAPLE_BASE_ASSETS`
  로 지정한다. 자세한 것은 [../AGENTS.md](../AGENTS.md) 의 코퍼스 절.
