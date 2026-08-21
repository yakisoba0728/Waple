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
| [../spec/README.md](../spec/README.md) | **WE 2.8.42 정본** — 바이너리·코퍼스·포맷·엔진 심볼·에셋. 근거 필수, 재측정 스크립트 동반 |
| [../spec/golden/snapshot/README.md](../spec/golden/snapshot/README.md) | 커밋된 스냅샷 기준선과 읽을 때의 주의 3건 |
| [we-parity-2026-08-16.md](we-parity-2026-08-16.md) | **WE 실기 대비 파리티 첫 정량 측정** — 골든이 못 재는 축(Waple↔WE). 7종 중 1종만 구별불가 |
| [ui-redesign-2026-08-17.md](ui-redesign-2026-08-17.md) | **UI 전면 개편 청사진** — 사이드바 네비게이션 이관, 단위별 파일 소유(병렬 작업 기준), 접근성·현지화 규약, WAPLE_SMOKE 게이트 이관. UI 를 만지기 전에 읽는다 |

WE 엔진 이식 프로그램의 차터·스펙·계획은 [superpowers/](superpowers/) 에 있다.
정본 **데이터**는 리포 루트 [../spec/](../spec/) 이다.

## 이력 — [history/](history/)

개발 당시의 계획서·설계서·감사 리포트 **71개**다. 참조 문서가 아니라 **기록**이다.
현재 코드와 다를 수 있으니 사실 확인은 코드나 위 현행 문서로 해라.

지우지 않는 이유는 이것이 설계 근거이기 때문이다 — 무엇을 왜 그렇게 했고, 어떤 대안을
왜 버렸고, 어떤 결론을 나중에 뒤집었는지가 여기 남아 있다. 자세한 구성은
[history/README.md](history/README.md).

## 문서 밖에 있는 것

- [audit-fixplan-2026-08-20.md](audit-fixplan-2026-08-20.md) — **최신.** Opus 20병렬 전수 감사의
  수정 계획. 착지분·다음 대상·게이트 자체의 구멍·아직 재확인 안 한 보고를 갈라 놓았다.
  에이전트끼리 정반대로 갈린 지점(`xmm15` 지배 관계)의 판정 근거가 §0 에 있다.
- [handoff-2026-08-20.md](handoff-2026-08-20.md) — WE 파티클 오퍼레이터 VM 재현 라운드.
  바이트코드 구조와 함정 넷, 고친 발산 13건, **일부러 안 한 것**과 그 사유.
- [handoff-2026-08-19.md](handoff-2026-08-19.md) — 전수 리뷰 세션(결함 46건). 6.5일 가동 후
  렌더 스레드 무한 루프, 반사/굴절 할당자 뒤바뀜, Steam API 키 평문 캐시.
- [handoff-2026-08-17.md](handoff-2026-08-17.md) — 2026-08-17 중단 지점 인계. wip/ 브랜치 둘의 남은 완료 조건과 캡처 함정.
- **`waple-baselines/`** — 시각 회귀 골든 이미지. 리포 밖이라 `git ls-files` 에 없다.
  `WapleCompat --capture` 로 재생성한다.
- **실물 WE 코퍼스** — 저작권 때문에 리포에 없다. `WAPLE_REAL_PKGS`/`WAPLE_BASE_ASSETS`
  로 지정한다. 자세한 것은 [../AGENTS.md](../AGENTS.md) 의 코퍼스 절.
