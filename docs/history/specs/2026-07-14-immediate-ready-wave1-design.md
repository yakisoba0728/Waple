# Immediate-Ready Wave 1 Parallel Delivery Design

**Date:** 2026-07-14
**Status:** Approved

## Goal

추가 네이티브 조사 없이 구현 가능한 네 작업을 독립 worktree에서 병렬 개발하고, 하나의 통합
브랜치에서 합친 뒤 전체 변경을 한 번만 리뷰·검증해 `main`에 병합한다.

## Work Lanes

| Lane | Branch | Design |
|---|---|---|
| Web hard pause | `codex/web-hard-pause` | `2026-07-14-web-hard-pause-design.md` |
| SceneScript lifecycle | `codex/scene-script-lifecycle` | `2026-07-14-scene-script-lifecycle-design.md` |
| LDR bloom | `codex/ldr-bloom` | `2026-07-14-ldr-bloom-design.md` |
| Base-assets diagnostics | `codex/base-assets-warning` | `2026-07-14-base-assets-warning-design.md` |

`codex/immediate-ready-wave1` 통합 브랜치는 위 네 브랜치와 같은 `main` 커밋에서 시작한다.
각 lane은 테스트를 먼저 실패시킨 뒤 최소 구현·영향 테스트·커밋까지 담당한다. 코드 리뷰는 lane별로
반복하지 않고 네 작업을 통합한 뒤 전체 diff에 대해 한 번만 수행한다.

## Integration

통합 순서는 Web → SceneScript → Base-assets → Bloom으로 고정한다. Web은 파일군이 독립적이고,
나머지 세 작업은 `SceneRenderer.swift`의 서로 다른 영역을 좁게 수정한다. 각 lane은 새 책임을 가능한
한 별도 파일에 두어 통합 충돌을 줄인다.

통합 후 다음만 수행한다.

1. 네 lane의 명명·수명주기·fallback 상호작용 확인
2. 각 lane의 명시된 영향 테스트를 한 명령군으로 실행
3. `git diff --check`
4. 전체 branch diff 최종 리뷰 한 번
5. Critical/Important 지적을 한 번에 보강한 뒤 같은 영향 테스트 재실행
6. 로컬 `main` 병합과 worktree/branch 정리

사용자 소유 `.vscode/launch.json`은 읽기 외 수정·stage·commit하지 않는다. 전체 Swift 테스트와
렌더 코퍼스는 실행하지 않는다.

## Deferred Wave

3D 파티클, Scene 내부 비디오 합성, HDR/ACES, HDR bloom, `ccsimple`, fog, P2b 및 오디오 절대
magnitude 보정은 이 wave에 포함하지 않는다. 특히 HDR 정책과 P2b는 추가 실행 근거 전까지 보류한다.
