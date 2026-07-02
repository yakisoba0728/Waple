# 웹 배경 100% (재생 의미론) — 설계

날짜: 2026-07-02. 브랜치 `feat/web-100`. 실측: 웹 타입 1개(3115349801 — 유저 속성 다수 사용).

## 현황 (이미 됨)

스킴 핸들러(로컬 에셋), 유저 속성 기본값 주입(applyUserProperties/applyGeneralProperties),
오디오 브리지 wallpaperRegisterAudioListener — **WE 포맷 128(64L+64R) 이미 정확**, setPaused,
미디어 리스너 no-op, webm 비디오 폴백 겸용.

## 갭 → 변경

1. **늦은 리스너 등록 유실**: didFinish 시점 직접 호출이라, 문서 로드 후(async) 리스너를 정의하는
   배경은 속성을 영영 못 받음. → 브리지에 `defineProperty(window,'wallpaperPropertyListener')`
   세터 훅 + pending 저장/flush(`__wapleApplyProps(props, general)`). WE 의미론(등록 즉시 전달)과 일치.
2. **가림 시 정지**: 씬/동영상과 동일 — didChangeOcclusionState 관찰 → setPaused(true/false) JS +
   오디오 provider stop/start(수동 pause 우선 플래그).
3. **마우스 전달**: WE 는 커서 위치를 웹 배경에 전달(반응형 배경 다수). 전역 mouseMoved 모니터
   (마우스 이동은 접근성 권한 불요) → 뷰 좌표 변환 → JS `mousemove` MouseEvent 디스패치, ~30Hz 스로틀.

미포함(별도 앱 SP — 전 타입 공통): 유저 속성 편집 UI(현재는 project.json 기본값 주입이 WE 초기 상태와 동일).

## 검증

- 단위(WKWebView 비동기): **늦게 등록한 리스너**가 속성을 받는지(RED: 현 구현 유실).
- 실물 GT(env-guarded): 3115349801 mount → 브리지 함수 존재 + 속성 전달 플래그 + body 렌더 확인
  + takeSnapshot PNG 육안. 스위트/릴리스 그린, ff-merge.
