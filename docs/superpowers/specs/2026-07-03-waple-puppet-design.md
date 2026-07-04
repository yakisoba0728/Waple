# SP6 슬라이스 1: 2D 퍼펫(.mdl) — 설계

날짜: 2026-07-03. 브랜치 `feat/puppet-phase1`. 실물: 2809885105(퍼펫 모델 2개) — 실측 리버스 결과:

## 상태(2026-07-04) — Phase 2·3 완료

이 문서는 3단계 계획 중 Phase 1 착수 시점 설계다. Phase 2·3 모두 구현됨:

- **Phase 1 [완료]**: `PuppetModel.parse`(WapleCore) — 헤더/머티리얼/정점/인덱스. 실물 스모크 + 합성 TDD.
- **Phase 2 [완료]**: MDLS0001 스켈레톤(본 트리/바인드) 파스 + GPU 스키닝. `Sources/WapleCore/PuppetModel.swift`(MDLS0001 섹션 파스 → `bones`) + `PuppetPose.skinMatrices`. SceneRenderer 가 퍼펫을 정지 메시가 아니라 **스킨된 메시**로 렌더(`SceneRenderer.swift`: `PuppetPose.skinMatrices(model: pm, animation: 0, time:)`).
- **Phase 3 [완료]**: MDLA0001 애니메이션 트랙 파스 + 재생. `PuppetModel.parse`(MDLA0001 섹션 → `animations`) + `PuppetPose.frame`(loop/single/mirror/clamp). 따라서 아래 Phase 1 항목의 "**정지 메시**(본 무시, 바인드 포즈)로 렌더" 서술은 폐기 — 실제로는 애니 스키닝까지 개통됨.
- 후속: 3D 모델(MDLV0023/MDLA0006)은 별도 문서 `2026-07-04-waple-3d-design.md` 참조.



## MDLV0013 포맷(실측, sample.mdl 111,914B)

```
"MDLV0013" | 13B 헤더(플래그/카운트 추정) | cstring 머티리얼 경로 | u32(0 — 용도 미상)
u32 정점블롭크기 | 정점×N (stride 52 = pos 3f | 본인덱스 4×u32 | 웨이트 4f | uv 2f)   ← 73112/52=1406 정확
u32 인덱스블롭크기 | u16 인덱스 (15852/2=7926 = 2642 tri, 값 유효)
"MDLS0001" 스켈레톤 섹션 | ... | (애니메이션 섹션 추정 후속)
```

## 단계

- **Phase 1(이번)**: `PuppetModel.parse`(WapleCore 순수) — 헤더/머티리얼/정점/인덱스. 미지 필드는
  관용 스캔(정점블롭 후보 = %52==0 && 크기 유효) + 로그. 실물 2개 파스 스모크(env-guarded) +
  합성 바이트 TDD. 씬 통합: puppet 모델 감지 시 **정지 메시**(본 무시, 바인드 포즈)로 렌더 —
  현 플레인 쿼드와 시각 동일하나 메시 파이프라인 개통. [폐기 2026-07-04: Phase 2·3 완료로 스킨/애니까지 렌더]
- Phase 2: MDLS 스켈레톤(본 트리/바인드) 파스 + 스키닝 정점 셰이더.
- Phase 3: 애니메이션 트랙 파스 + 재생(기존 PropertyAnimation 평가기 패턴).

## 검증

합성 MDL 바이트 TDD(라운드트립), 실물 2개 파스(정점/인덱스 수 어서션), 씬 렌더 무회귀(PNG).
