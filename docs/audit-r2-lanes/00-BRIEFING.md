# 감사 라운드 브리핑 (2026-08-31 r2) — 전 레인 공통

## 대상
- `/Users/yakisoba0728/Documents/GitHub/Waple` (main, HEAD=`b883386e`, 작업 트리 깨끗)
- `/Users/yakisoba0728/Documents/GitHub/Waple-wallpaper-source` (RE 짝 저장소)

## 이 라운드의 전제 — 매우 중요
직전 전수 감사(`AUDIT-FULL-2026-08-31.md`, 3,571줄)가 **오늘** 끝났고, 그 발견을 고친
**PR #8(`b883386e`)이 방금 병합됐다.** PR #8 은 작은 수정이 아니다 —
`ParticleSimulator.swift +586` · `SceneRenderer.swift ±676` · `SceneRendererFrameEncoder.swift +785` ·
`SceneDocument.swift ±298` · `AppDelegate.swift ±356` · `ci.yml ±288` 등 대규모다.

**따라서 이 라운드의 최우선 가치는 "PR #8 이 새로 심은 결함"이다.**
직전 감사가 이미 훑은 자리를 같은 방식으로 다시 훑는 것은 가치가 낮다.
`git show b883386e -- <네 담당 파일>` 로 **무엇이 바뀌었는지 먼저 보고**, 그 변경이
① 실제로 주장한 결함을 고쳤는지 ② 새 결함·회귀·모순 주석을 남기지 않았는지 를 봐라.

## 기반 실측 (이미 잰 값 — 다시 재지 마라)
| 항목 | 값 |
| --- | --- |
| Xcode | 27.0 Beta 5 · Swift 6.4 (`swift test` 실행 가능) |
| 실물 코퍼스 | **없다** (`~/Downloads/wallpaper_dev/backgrounds` 부재, `WAPLE_REAL_PKGS` 미설정) |
| 정적 테스트 개수(정본 레시피) | **4,016** — `ci.yml` census 하한도 4,016 (여유 0) |
| 언어 모드 | 여전히 Swift 5 (`tools-version:5.9`) + `-strict-concurrency=complete` 경고 |

## 금지 사항
- **어떤 파일도 수정하지 마라.** 편집·생성·git 명령(add/commit/stash) 전부 금지. 읽기 전용이다.
  (`/tmp` 스크래치패드에 네 메모를 쓰는 것은 허용)
- **`swift build` · `swift test` 를 돌리지 마라.** 기준 실행은 오케스트레이터가 이미 돌리고 있다.
  16개 레인이 동시에 빌드하면 머신이 죽는다. grep·읽기·`git show`·`python3` 단발 스크립트만 써라.
- RE 저장소에서 `wallpaper_engine/`(1.1GB) · `ghidra_proj/`(492MB) · `binaries/`(55MB) 를
  통째로 훑지 마라. 특정 파일을 콕 집어 읽는 것은 가능(예: `wallpaper_engine/ui/dist/...` 한 파일).

## 발견 보고 규약 (이 리포의 문화 — 지키지 않으면 병합 단계에서 잘린다)
1. 모든 발견에 **`파일:줄`** 과 **재현 수단**(grep 명령 · `git show` · 계산식)을 붙여라.
   "…일 수 있다" 는 발견이 아니다. 확인 못 한 것은 **의심**으로 분류해 따로 적어라.
2. **직전 감사가 이미 잡은 것을 새 발견으로 올리지 마라.** 아래 기지(旣知) 목록 참조.
   단 "PR #8 이 그걸 고쳤다고 하는데 실제로는 안 고쳐졌다/반만 고쳤다" 는 **최고가치 발견**이다.
3. 심각도: 🔴 실동작 파손·데이터 손실 / 🟠 실동작 오류 또는 게이트 무력화 /
   🟡 정본·문서 거짓, 낡은 수치, 유지보수 위험 / ⚪ 관찰.
4. **거짓 양성을 스스로 걸러라.** 이 리포는 의도적 단순화를 `ponytail:`·`실측` 주석으로
   정당화한다. 주석을 먼저 읽고, 그 근거가 실제로 성립하는지 확인한 뒤에 올려라.
5. 이 리포에서 가장 생산적인 결함 부류는 **"문서·주석·정본이 코드와 어긋난 것"** 이다
   (낡은 도수, 밀린 줄 번호 인용, 자기모순 주석). 코드 결함만큼 비중을 둬라.

## 기지 발견 (직전 라운드 — 재보고 금지, 단 "미해결/재발" 확인은 환영)
🟠 C1 CI census `tail -1` 오추출(→`scripts/dev/xctest-census.py` 로 수정됨) ·
H1 `ZZTempSqrtVerify.swift` 단언 0 임시 테스트 · H2 정본 인용 census 62 vs 66 게이트 미추적 ·
H3 `alphafade.fadeouttime` 을 지속시간으로 오해(WE 는 시작점, 110/250건) ·
H4 oscillate 3종 진폭의 파티클별 난수 누락(61건) · H5 Swift 6 전환 진단 32자리(25가 SceneRenderer) ·
H6 `PuppetModel` MDLA 이벤트 블록 미스킵 · H7 `particle-fields.json` 미재생성 ·
H8 `parseLight` 기본값 6/6 이 RE 문서와 불일치(`exponent` 1 vs 2.0)
🟡 M1 미추적 문서 · M2 폐기된 계수 `358` 잔존 · M3 JSON `0`/`1` → `bool` 오타입 ·
M4 재측정 스크립트 40 중 18 이 무코퍼스에서 트레이스백 · M5 README 셰이더 인용 3건 범위 이탈 ·
M6 BACKLOG 제품화 표 2항목 이미 해소 · M7 디컴파일 실패 3건 산문 미기록 ·
M8 화면보호기 `startAnimation` 마다 플레이어 재생성 · M9 `perspectiveOverrideFov` 묘비 오분류 ·
M10 주석이 자기 diff 가 밀어낸 줄 번호 인용 · M11 정본 근거 661/1,211 검증 생략 ·
M12 `CAST3X3` 도달표가 두 모집단 혼합·`g_Bones` 40 vs 48 · M13 `HDRBloomPass.swift:5` "코퍼스 8" ·
M15 `AGENTS.md` "단언 15건" 거짓 불변성 · M16 `measure_workshop_shaders.py` 자기모순 ·
M17 Schlick 오라클 정규식 우측 미앵커 · M18 BACKLOG 항목을 틀린 이유로 닫음 ·
M19 `corpus_scan/mdl-format.md` v≥23 UNRESOLVED · M20 `AudioSpectrum.swift` 오프셋 인용 −8 밀림 ·
M21 `measure_material_schema.py` evidence ref 줄번호 드리프트 · M22 비둘기집 하한 산수 ·
M23 Python 포트 `MAX_DEPTH=256` 도달 불가 · M24 typecheck 주석 3/4 · M25 `uniforms.json` 17/144 행 ·
M26 `pdataCoverage` 분자⊄분모(46.1%)
(M14 는 **철회**됨 — `161/161` 은 워크샵 코퍼스 실측으로 정본이 옳다)

## 직전 감사가 **확인하지 못한** 것 — 여기에 닿을 수 있다면 고가치
1. WE 가 라이트 `L` 을 만들 때 모델행렬의 **어느 열**을 쓰는지(팩커 미특정, 정본 기록 0건)
2. 워크샵 코퍼스 446 폴더 부재 → 도달 범위 미측정
3. 픽셀 회귀(`WapleCompat --capture/--compare`) 미실행
4. 화면보호기 실동작 · Windows 동적 분석 · 서명/공증 · Swift 6 모드 실제 전환

## 출력 형식
발견마다:
```
### [심각도] <한 줄 요지>
- 자리: `파일:줄`
- 근거/재현: <명령 또는 계산>
- 왜 문제인가: <실동작 영향 1~3줄>
- 기지 목록 대조: <해당 없음 | C1 의 재발 | …>
```
마지막에 **"확인했지만 문제없던 것"** 을 3~8줄로 요약해라(다음 라운드의 시간을 아낀다).
발견이 0건이면 0건이라고 정직하게 보고해라 — 억지로 채우지 마라.
