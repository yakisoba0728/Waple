# 컴포지션 레이어(_rt_FullFrameBuffer) — 설계

날짜: 2026-07-02. 브랜치 `feat/composition-layers`. 실측: 31씬에서 36 레이어 게이트
(composelayer 25, fullscreenlayer 9, projectlayer 2). 대표 증상: 2881558311 "거의 빈 화면".

## 의미론 (assets 실측)

fullscreen/compose/project 레이어의 머티리얼 텍스처가 `_rt_FullFrameBuffer` = **그 시점까지 합성된
프레임버퍼**. 레이어에 붙은 효과 체인이 "화면 전체"를 입력으로 처리한 뒤 자기 지오메트리
(fullscreen 은 전체 화면)로 다시 그린다. passthrough(무효과)면 사실상 화면 복사.

## 구현

1. **파스**: `_rt_*` 텍스처 → 스킵 대신 `SceneLayer.isFrameBuffer = true` (textureEntryName "").
   모델 `fullscreen`/`autosize` 플래그 또는 오브젝트 size 부재 시 → size=프로젝션 전체, origin=중앙.
2. **렌더러 — 누적(acc) 합성**: draw/captureFrames 가 드로어블 대신 **오프스크린 acc(bgra8, RT|read)**
   에 씬 순서대로 합성. `_rt_` 레이어를 만나면:
   encoder 종료 → acc 를 스냅샷으로 **blit 복사**(진행 중 타깃은 샘플 불가) → 레이어 효과 체인을
   스냅샷을 src 로 실행(기존 applyEffect 재사용; rgba8 풀 타깃) → 새 encoder(load)로 결과를
   레이어 지오메트리 쿼드로 acc 에 드로우 → 계속. 마지막에 live 는 acc→drawable blit,
   captureFrames 는 acc 에서 readback.
3. **효과 dims**: `_rt_` 레이어의 효과 타깃/texRes 는 빌드 시점에 화면 크기를 모름 → 프로젝션
   dims 로 빌드(주로 텍셀 오프셋 용도 — 근사 허용, 후속 보정 여지 기록).
4. **알파 에지(기록)**: acc 는 premultiplied 누적이라 스냅샷도 premult — 효과 규약(straight 입력)과
   달라 alpha<1 영역에서 미세 오차 가능. 배경이 불투명한 일반 씬에선 동일. v1 수용.

## 검증

- 단위: 파스(_rt_ → isFrameBuffer, fullscreen 사이징).
- 렌더 오라클: 빨강 솔리드 bg + fullscreen `_rt_` 레이어에 opacity(0.5) 효과 → luma 절반
  (미지원이면 스킵 → 풀 레드). passthrough(무효과) → 원본과 동일 픽셀.
- 실측 GT: 게이트 36 소멸, 2881558311 PNG 육안(빈 화면 → 콘텐츠). 스위트/릴리스 그린.
