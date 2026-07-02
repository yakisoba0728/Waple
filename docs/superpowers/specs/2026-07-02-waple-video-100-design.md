# 동영상 배경 100% (재생 의미론) — 설계

날짜: 2026-07-02. 브랜치 `feat/video-100`. 사용자 승인: A안(네이티브 완성).

## 정의

"100%" = 워크샵에 실존하는 동영상 배경(mp4/webm)이 WE 와 동일한 재생 동작을 하는 것:
무결절 루프 · 화면 맞춤 · **배경별 음량/음소거** · **배경별 재생 속도** · **가림 시 정지(절전)** ·
멀티모니터 · HW 디코드. 예외(문서화): mkv 는 AVFoundation/WKWebView 모두 불가 — ffmpeg 의존성
결정(라이선스/배포) 전까지 명시 로그 + 미지원. 실물 9개 조사: 전부 mp4, 콘텐츠 측 속성은
schemecolor(UI 색, 렌더링 무관)뿐.

## 구성

1. **VideoSettings(WapleRender)** — 배경 id 별 영속(UserDefaults):
   `volume(id:) Float` 기본 0(음소거 — WE 와 달리 보수적 기본, 사용자 결정), `rate(id:) Float` 기본 1.
2. **VideoRenderer** — mount 시 설정 적용: `player.volume`/`isMuted(volume<=0)`,
   `defaultRate`(macOS13+, 루프에도 배속 유지) + `audioTimePitchAlgorithm`.
   **가림 정지**: NSWindow.didChangeOcclusionStateNotification 관찰 → 컨테이너 창이 비가시화면
   pause, 재가시화면 play(창 없음(테스트)·수동 pause 와 충돌 없게 상태 플래그).
   테스트 가시성: player 를 internal private(set) 으로.
3. **메뉴(AppDelegate)** — "동영상 설정" 서브메뉴: 음소거 토글 + 음량(25/50/75/100%) + 배속
   (0.5/1.0/1.5/2.0). 현재 배경 id 에 저장 후 기존 fit-mode 패턴대로 재적용(apply(folderURL)).
   현재 배경이 동영상일 때만 유효(아니면 no-op — 메뉴는 항상 표시, 단순성).

## 검증

- 단위: VideoSettings 영속/기본값; VideoRenderer 가 설정을 player 에 반영(@testable).
- **실물 GT(env-guarded)**: ~/Downloads/backgrounds 의 video 타입 전수(지원 컨테이너) —
  headless mount → RunLoop 스핀 → item readyToPlay && rate>0 어서션(진짜 디코드·재생 확인).
- 스위트/릴리스 그린, ff-merge.
