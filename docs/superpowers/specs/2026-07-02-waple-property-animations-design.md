# 프로퍼티 애니메이션 재생 — 설계

날짜: 2026-07-02. 브랜치 `feat/property-animations`. 실측(31씬 전수): 애니메이션 24건 —
origin 13, alpha 6, scale 3, (text)maxwidth 2. 모드 single 20 / loop 4. relative true 13 / 부재(절대) 11.
키프레임: {frame, value, front/back 베지어 핸들(enabled,x,y), lockangle/locklength(에디터용 — 재생 무관)}.
options: {fps(30), length(frames), mode, wraploop}.

## 모델/평가기 (WapleCore, 순수, TDD)

`PropertyKeyframe{frame,value,front/back(enabled,x,y)}`, `PropertyAnimation{tracks[c0..c2], fps, length,
mode, relative}` + `value(component:atTime:base:)`:
- frame = t×fps; single → clamp[0,length], loop → fmod.
- 구간 밖: 첫/끝 키프레임 값 유지. 구간 내: 큐빅 베지어 P0=(k1.f,k1.v), P1=P0+front, P3=(k2.f,k2.v),
  P2=P3+back(x 음수). 핸들 disabled → 해당 컨트롤포인트 = 끝점(양쪽 disabled = 선형과 동치).
  x→t̂ 는 이분법(단조), y 평가. relative → base+v.

## 배선

- SceneLayer/SceneTextLayer 에 `animations: [String: PropertyAnimation]`(origin/scale/alpha/angles 등
  키 일반화; maxwidth 는 v1 스킵). 파스: 기존 바인딩 언랩 지점에서 animation 딕셔너리 캡처.
- 렌더러: 애니메이션 있는 레이어만 GPULayer 에 def(SceneLayer) 보존 + hasAnimations 플래그(루프 활성).
  draw/captureFrames 의 .layer 케이스에서 time 으로 origin/scale/alpha 평가 → 쿼드 버텍스 재계산
  (per-frame makeBuffer — 파티클과 동일 패턴) + tint 알파 오버라이드. encodeLayer 에 오버라이드 파라미터.

## 검증

단위: 파스(키프레임/옵션/relative), 평가기(선형 중점, 클램프, 루프 랩, relative, 대칭 베지어 중점=평균 &
단조성). 렌더 PNG: alpha 1→0(2s single) t=0/1/2 luma 1/≈0.5/0; origin 이동 t0/tEnd 픽셀 프로브.
실측 GT + 3147346398(origin 애니) 육안. 스위트/릴리스 그린, ff-merge.
