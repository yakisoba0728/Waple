# Web Hard Pause Design

**Date:** 2026-07-14
**Status:** Approved

## Goal

Web 배경이 수동 정지되거나 가려졌을 때 협조적 `setPaused` 콜백뿐 아니라 rAF, timer,
WebAudio, CSS/WAAPI 애니메이션의 실제 실행도 정지하고, 두 정지 원인이 모두 풀린 경우에만 정확히
한 번 재개한다.

## Current Boundary

`WallpaperBridgeJS`는 모든 frame의 document start에 주입된다. 현재 `__wapleSetPaused`는 상태를
dedupe하고 `wallpaperPropertyListener.setPaused`, background/foreground callback, 자식 frame 전파만
수행한다. `WebRenderer`는 manual/occlusion 상태를 별도로 보유하지만 일부 resume/audio 경로가 manual
상태만 확인한다.

## Architecture

새 `WebHardPauseJS`를 기존 bridge보다 먼저, `forMainFrameOnly: false`로 주입한다. controller는 원본
브라우저 API를 bound 함수로 보존하고 virtual ID 기반 wrapper를 설치한다. 기존 bridge는
`__wapleSetPaused` 전이 때 controller를 먼저 호출한 뒤 현재 협조적 callback 순서를 유지한다.

`WebRenderer`는 `pausedManually || pausedByOcclusion`을 유일한 effective 상태로 계산한다. 모든 manual,
occlusion, navigation replay, audio listener, media poller 분기는 한 transition helper를 사용한다. 따라서
manual resume가 호출돼도 창이 아직 가려져 있으면 JS·오디오·poller는 재개되지 않는다.

## Scheduler Contract

- rAF 요청은 virtual ID를 반환한다. pause 시 native handle만 취소하고 callback record는 유지하며,
  pause 중 요청도 queue에 둔다. resume 시 각 record를 한 번만 다시 arm한다.
- timeout/interval은 callback, arguments, kind, deadline, remaining delay를 기록한다. pause 시 native
  handle을 취소한다. timeout은 잔여시간을 보존하고, interval은 다음 발화까지의 잔여시간으로 첫 발화를
  재개한 뒤 원래 주기로 반복한다. 두 clear 함수는 공통 virtual ID를 취소할 수 있다.
- 문자열 timer handler는 fire 시 indirect global evaluation을 사용한다. CSP 등 page 정책으로 실패하면
  page 오류로 표면화하며 controller가 조용히 삼키지 않는다.
- `performance.now`, `Date`, page time source는 변경하지 않는다. 정지 후 첫 callback timestamp가 건너뛰는
  것은 이번 범위의 명시적 경계다.

## Audio and Animation Contract

`AudioContext`와 `webkitAudioContext` constructor를 호환 wrapper로 감싸 instance를 추적한다. pause 직전
running이던 context만 suspend하고, Waple이 suspend한 context만 resume한다. pause 중 생성·resume된
context는 즉시 다시 suspend한다. context마다 desired state, transition generation, 직렬 Promise chain을
보유한다. 각 비동기 완료는 최신 generation과 desired state를 다시 확인해 stale suspend/resume 완료가
최종 상태를 뒤집지 못하게 한다. closed context는 제거하고 Promise rejection은 controller 진단으로만
처리한다.

WAAPI는 `document.getAnimations()`의 running/pending 항목만 기록해 pause하고 기록된 항목만 play한다.
pause 중 추가되는 animation은 observer와 animation/transition event로 포착한다. document root의 pause
class와 `animation-play-state: paused !important` style을 pseudo-element fallback으로 함께 사용한다.

## Frames and Navigation

hard-pause controller는 bridge의 origin gate 바깥에서 모든 주입 frame에 설치한다. main/child controller는
versioned `postMessage`로 현재 상태를 요청·전파해, pause 뒤 생성된 same-origin 및 허용된 `data:` frame도
정지 상태를 상속한다. 기존 property/frame propagation은 유지한다.

navigation 완료 시 property JSON 유무보다 먼저 effective pause 상태를 replay한다. JS 평가 실패는 로그로
남기되 native audio/poller 정지를 되돌리지 않는다. controller 내부 오류도 cooperative lifecycle callback
호출을 막지 않는다.

## Tests

- 실제 WKWebView에서 rAF, timeout, interval이 pause 중 증가하지 않고 resume 후 정확히 재개됨
- pause 중 생성·취소된 scheduler ID 동작과 timeout 잔여시간
- interval이 재개 후 남은 phase에서 첫 발화하고 그 뒤 원래 주기로 반복함
- manual pause + occlusion + manual resume + visible 순서에서 마지막 전이 전에는 재개되지 않음
- pause 후 동적 iframe, `data:` iframe, reload가 상태를 상속함
- fake AudioContext로 Waple이 멈춘 running context만 재개함
- fake AudioContext의 빠른 pause→resume 및 resume→pause에서 늦은 Promise 완료가 최신 상태를 뒤집지 않음
- WAAPI currentTime이 pause 중 고정되고 기존 lifecycle/dedupe 테스트가 유지됨

전체 web/Swift suite는 실행하지 않고 `WallpaperBridgeJSTests`, `WebPropertyDeliveryTests`,
`WebRendererOcclusionTests` 및 신규 hard-pause 테스트만 실행한다.

## Exclusions

HTML media element 자동 pause, service worker, network request 중단, page clock 가상화, cross-origin remote
frame 지원은 포함하지 않는다.
