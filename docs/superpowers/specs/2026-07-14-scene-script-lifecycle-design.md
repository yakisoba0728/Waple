# SceneScript Lifecycle Design

**Date:** 2026-07-14
**Status:** Draft complete; written review pending

## Goal

SceneScript의 `applyUserProperties`와 `init`을 mount마다 결정적인 순서로 한 번 발화하고, 기존 property
`update` 평가와 공유 JavaScriptCore context를 깨지 않는다.

## Current Boundary

`TextScriptEngine`은 두 함수를 발견해 저장하지만, renderer는 어느 lifecycle도 명시적으로 발화하지
않는다. `init`은 `update` 직전에만 lazy 호출되므로 init-only script는 실행되지 않는다. `init`은 generic
hook에도 중복 보관되므로 `callHook("init", ...)`를 사용하면 첫 update에서 두 번 실행될 수 있다.

## Lifecycle Contract

`TextScriptEngine`에 기존 `didCallInit` gate를 공유하는 전용 초기화 진입점과 별도
`applyUserProperties` 진입점을 추가한다. 두 lifecycle 함수는 generic `hookFns`에 저장하지 않으며,
`callHook`으로 gate를 우회할 수 없게 한다.

- update-bearing property script는 기존처럼 첫 `update(currentValue)` 직전에 `init(currentValue)`를 한 번
  실행한다.
- init-only SceneScript는 load 직후 전용 진입점으로 인자 없이 한 번 실행한다.
- `applyUserProperties`는 engine마다 mount 중 한 번 실행한다.
- 결정 순서는 top-level evaluation → `applyUserProperties(effectiveProps)` → `init` → `update`다.
- hook 부재는 no-op, 예외는 engine별로 로그하고 다른 engine을 계속 실행한다. delivered/init gate는 호출
  전에 세워 실패한 hook을 자동 재시도하지 않는다.

## Property Data Flow

`SceneRenderer.mount`가 이미 계산하는 project defaults + preset/user overrides의 effective
`WallpaperProperty` 목록을 `WallpaperProperties.weUserPropertiesJSON`으로 한 번 직렬화한다. 각
`makeScriptEngine` 성공 직후 이 JSON을 전달하므로 build 중 바로 평가되는 text/property script와 늦게
생성되는 animation-layer engine 모두 같은 snapshot을 받는다. 속성이 없으면 `{}`를 전달한다.

Waple의 property 편집은 renderer remount이므로 in-place 변경 stream은 추가하지 않는다. 직접 remount가
오래된 event engine을 재사용하지 않도록 mount 시작 시 lifecycle/event collection을 초기화하거나 기존
teardown 선행조건을 코드로 강제한다.

## No-op Truthiness

JavaScript object/Proxy는 `Symbol.toPrimitive`와 무관하게 항상 truthy다. 따라서 임의 chaining을 안전하게
받는 generic no-op Proxy를 보편적으로 falsy하게 만드는 구현은 하지 않는다. boolean 의미가 확정된
`engine.isWallpaper()`/`isDesktopDevice()`는 `true`, `isMobileDevice()`/`isScreensaver()`/
`isRunningInEditor()`는 `false`, `isPortrait()`는 `height > width`, `isLandscape()`는 `width >= height`를
반환한다.
알 수 없는 member는 기존 chain-safe Proxy를 유지하고 가짜 `valueOf=false`를 추가하지 않는다.

이번 wave는 lifecycle이 `shared`와 기존 `update` 반환값에 미치는 효과만 native renderer에 반영한다.
script가 JS snapshot `thisScene`/`thisLayer`를 임의 변경한 내용을 GPU 객체로 역동기화하는 기능은 별도다.

## Tests

- 두 번 update해도 `applyUserProperties → init → update → update` 순서와 exactly-once가 유지됨
- init-only engine이 한 번 실행되어 `shared` 상태를 노출함
- payload가 `false`, `0`, 빈 문자열, preset/user 우선순위와 빈 `{}`를 보존함
- throwing lifecycle hook이 재시도되지 않고 다른 engine/context를 오염하지 않음
- 자동 lifecycle 발화 뒤 generic `callHook`을 시도해도 init/apply가 다시 실행되지 않음
- remount 후 새 engine만 payload를 받고 stale engine은 호출되지 않음
- generic Proxy가 여전히 truthy임을 고정하고 위 7개 concrete boolean capability 값을 검증함

영향 테스트는 `TextEngineTests`, `SceneEventHookTests`, `SceneSharedScriptTests`, 관련 user-property
renderer 테스트로 제한한다.
