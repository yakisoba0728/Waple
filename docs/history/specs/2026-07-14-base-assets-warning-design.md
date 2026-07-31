# Base-Assets Missing Diagnostic Design

**Date:** 2026-07-14
**Status:** Approved

## Goal

base-assets 설정이 비어 있다는 이유만으로 경고하지 않고, Scene이 실제 필수 공유 에셋을 찾지 못해
저하된 경우에만 설정 경로를 안내하는 비차단 StatusBanner를 앱 세션당 중복 없이 표시한다.

## Detection

`SceneRenderer`는 mount별 `hasMissingRequiredSharedAssets` 진단을 보유한다. 저수준 `assetData`와 개별
candidate probe는 진단을 바꾸지 않는다. required loader가 package 후보, shared 후보, raw/대체 경로를
모두 시도한 뒤 최종 실패했을 때만 진단을 세운다. `SceneDocument.parse`의 required shared resolver도
전체 해석 실패 경계에서 같은 진단을 세운다.

- 성공한 package/base fallback은 진단하지 않는다.
- 첫 candidate가 실패해도 후속 raw/package fallback이 성공하면 진단하지 않는다.
- 탐색 실패가 정상인 `quietAssetData`는 진단하지 않는다.
- path traversal 또는 invalid relative path 거부는 보안 오류이며 base-assets 경고로 바꾸지 않는다.
- 잘못되거나 삭제된 저장 경로도 실제 miss로 검출한다. 단순 `baseAssetsDirectory == nil` 검사는 사용하지
  않는다.

개별 누락 파일명은 기존 NSLog 진단에만 남기고 public 진단은 boolean으로 제한한다.

## App Warning Policy

성공적인 renderer swap 뒤 새 `SceneRenderer`들을 합산해 하나라도 진단됐을 때 한 문구만 표시한다.

> 공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요.

warning gate는 현재 base-assets 설정 fingerprint별로 배너 1회/앱 세션을 허용한다. 메인창이 닫혀
`notify`가 NSLog만 남긴 경우 dedupe를 소비하지 않는다. 사용자가 다른 base-assets 폴더를 선택해
fingerprint가 바뀔 때만 gate를 초기화하고 현재 선택을 재적용한다. 여러 monitor나 여러 파일 miss는 한
배너로 합친다.

renderer mount 실패 자체, web/video wallpaper, self-contained Scene에는 이 안내를 표시하지 않는다.

## Tests

- required shared asset 성공은 false, 실제 miss는 true
- candidate miss 뒤 raw/package fallback 성공은 false
- 반복 miss는 boolean 진단 하나로 유지됨
- quiet miss와 traversal 거부는 false
- self-contained Scene, web/video는 무경고
- multi-monitor/multi-miss는 배너 한 번
- 같은 설정 재적용은 억제하고 폴더 변경 뒤 새 실제 miss는 다시 경고
- 숨은 main window는 dedupe를 소비하지 않음

기존 `StatusBannerModelTests`는 유지하고 path fallback, warning gate, renderer-swap 경계의 영향 테스트만
실행한다.

## Documentation

`BACKLOG.md`의 3D mesh unlit 항목을 P3/P4 완료로 현행화한다. 제품화 항목은 base-assets의 조용한 저하가
이 경고로 부분 해소됐음을 기록하되, 최초 실행 onboarding과 창 닫힘 상태의 NSLog-only 안내는 잔여로
남긴다.

## Exclusions

벤더 base-assets 번들링, built-in header 확대, blocking alert, 설정 창 자동 열기, 최초 실행 onboarding은
이번 범위가 아니다.
