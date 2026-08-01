# 세션 간 비결정 측정 입력 — 전 코퍼스 캡처 7회의 매니페스트 (2026-08-01)

`scripts/spec/measure_nondeterminism.py` 의 입력이다. 썸네일은 뺐다 —
판정에 쓰는 것은 `entries[].hash`(캡처 픽셀의 fnv1a) 뿐이라 매니페스트만으로 재현된다.

## 무엇을 뜬 것인가

전부 macOS 같은 기계·같은 코퍼스(170종)·**렌더 동작이 동일한 코드**로 뜬 전 코퍼스 캡처다.
세션 A~D 는 캡처 시각으로 묶은 것이고, 한 세션 안의 캡처끼리는 별도 프로세스다.

| 디렉터리 | 세션 | 시각(KST) | 뜬 방법 |
| --- | --- | --- | --- |
| `A-mips` | A | 21:17–21:20 | `swift run -c release WapleCompat --capture … --label mips-82fcd08` (전 스위트 직후) |
| `B-head` | B | 21:26–21:29 | 같은 명령, 재빌드 후 |
| `C-runA` | C | 21:47–21:50 | `scripts/mac-session/probe-nondeterminism.sh` |
| `C-runB` | C | 21:50–21:53 | 같은 스크립트의 2회차 |
| `D-R1` | D | 23:11–23:14 | `scripts/mac-session/probe-session-nondeterminism.sh` |
| `D-R2` | D | 23:14–23:17 | 같은 스크립트 |
| `D-R3` | D | 23:2x | 같은 스크립트(부하 개입 실험의 중간 캡처) |

A·B 의 커밋은 `82fcd08`, C·D 는 `ab96c32`/`4ae27c6` 인데 그 사이 `Sources/` 변경은
**주석뿐**이다(`git diff 82fcd08..ab96c32 -- Sources/` = SnapshotPipeline.swift·ParticleSystem.swift
주석 27줄). C 와 D 는 **같은 바이너리 파일**로 떴다(sha256 `44b6017a…`, 재링크 없음).

## 매니페스트의 `gitSHA` 를 믿지 마라

`SnapshotPipeline.gitSHA()` 는 **프로세스의 작업 디렉터리**에서 `git rev-parse` 를 한다.
D 세션은 다른 리포 체크아웃에서 실행돼 `db0a526`(무관한 리포의 main)이 박혀 있다.
실제 소스 동일성 근거는 위 표의 바이너리 sha256 이다.
