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

- [handoff-2026-08-17.md](handoff-2026-08-17.md) — 2026-08-17 중단 지점 인계. wip/ 브랜치 둘의 남은 완료 조건과 캡처 함정.
- **`waple-baselines/`** — 시각 회귀 골든 이미지. 리포 밖이라 `git ls-files` 에 없다.
  `WapleCompat --capture` 로 재생성한다.
- **실물 WE 코퍼스** — 저작권 때문에 리포에 없다. `WAPLE_REAL_PKGS`/`WAPLE_BASE_ASSETS`
  로 지정한다. 자세한 것은 [../AGENTS.md](../AGENTS.md) 의 코퍼스 절.
