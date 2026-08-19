# 합성 씬 픽셀 골든

`Tests/WapleRenderTests/SyntheticPixelGoldenTests.swift` 가 쓰는 기준선이다.
**CI 에서 도는 유일한 픽셀 회귀 게이트**다 — 형제인 `../snapshot/` 은 실물 코퍼스가
있어야 뜨고 비교가 로컬 맥 수동 스크립트뿐이라 CI 에 배선돼 있지 않다
(`../gate-analysis.json` → `oracle.gate.compareWiring.ciCallSites` 가 `[]`).

## 기준선 넷 (128×72, 캡처 시각 0.1s)

| 파일 | 지나가는 경로 | 확인된 값 |
| --- | --- | --- |
| `alpha-red-over-white.png` | 알파 합성 | 중앙 `(255,128,128)` — 50% 빨강 위 흰색 |
| `blend-multiply.png` | `colorBlendMode` 2 | 중앙 `(255,0,0)` — 흰×빨강 |
| `blend-difference.png` | `colorBlendMode` 18 | 중앙 `(0,0,0)` — 흰 vs 흰 |
| `gradient-vertical.png` | 텍스처 샘플링·보간 | 상 `(254,32,33)` 하 `(33,32,254)` 중앙 `(141,32,145)` |

`blend-difference` 의 순수 검정이 이 넷 중 가장 강한 증거다. 일반 알파 합성이면
흰색이 남으므로, 검정이 나온다는 것은 `common_blending.h` 의 18번이 실제로
구동됐다는 뜻이다. 반대로 `blend-multiply` 는 **단독으로는 약하다** — 미구현이어도
같은 답이 나올 수 있어 difference 와 쌍으로 봐야 의미가 있다.

`gradient-vertical` 이 유일하게 단색이 아니다. 단색만 있으면 샘플러나 보간이
깨져도 평균이 그대로라 통과하기 때문에 일부러 넣었다.

흰 테두리는 결함이 아니다 — 배경 레이어가 1920×1080, 오버레이가 1440×810 이라
오버레이가 안쪽으로 들어간다.

## 다시 뜨기

```
WAPLE_GOLDEN_BOOTSTRAP=1 swift test --filter SyntheticPixelGolden
```
또는 GitHub Actions 의 CI 워크플로를 `golden_bootstrap` 입력을 켜고 수동 실행하면
`synthetic-golden-baseline` 아티팩트로 나온다.

**뜬 것을 눈으로 확인하기 전에는 커밋하지 마라.** 이 게이트는 "다시 뜨면 초록" 이
되므로, 확인 없는 재기준선은 회귀를 정본으로 만드는 일이다. 위 표의 값이
그 확인의 기준이다.

기준선이 없을 때 이 테스트는 **스킵이 아니라 실패**한다. 없으면 조용히 만들고
통과하는 설계는 이 리포가 이미 당했다 — `RealPackagesGroundTruthTests` 의
`/tmp/waple_gt/luma_baseline.json` 은 새 머신에서 영원히 실패할 수 없다.

## 출처

2026-08-19, CI run 32220868700 (macos-26, debug, Metal 사용 가능).
합성 씬이라 실물 코퍼스나 WE 설치본에 의존하지 않는다.
