# Immediate-Ready Wave 1 Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 네 독립 기능 브랜치를 같은 기준점에서 병렬 구현하고, 영향 테스트와 전체 diff 최종 리뷰 한 번을 거쳐 `main`에 안전하게 병합한다.

**Architecture:** `main`에서 통합 worktree와 기능 worktree 네 개를 만들고 각 기능 계획을 독립 실행한다. 기능 브랜치를 Web → SceneScript → Base-assets → Bloom 순서로 통합한 뒤, 한 번의 통합 리뷰와 제한된 영향 테스트만 수행한다.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, WebKit, JavaScriptCore, Metal, XCTest, Git worktrees

## Global Constraints

- 추가 네이티브·코퍼스 조사를 하지 않는다.
- 전체 `swift test`와 렌더 코퍼스를 실행하지 않는다. 아래 filter의 영향 테스트만 실행한다.
- lane별 코드 리뷰를 하지 않는다. 네 lane 통합 후 전체 branch diff를 한 번만 리뷰한다.
- 사용자 소유 `.vscode/launch.json`을 수정·stage·commit하지 않는다.
- 각 lane은 테스트 실패 확인 → 최소 구현 → 영향 테스트 통과 → 커밋 순서를 지킨다.
- HDR/ACES, HDR bloom, `ccsimple`, fog, P2b, 3D particles, scene video composition은 변경하지 않는다.

---

## File Structure

- `.worktrees/immediate-ready-wave1`: 통합 전용 worktree, branch `codex/immediate-ready-wave1`.
- `.worktrees/web-hard-pause`: Web scheduler/audio/animation pause, branch `codex/web-hard-pause`.
- `.worktrees/scene-script-lifecycle`: SceneScript lifecycle/property delivery, branch `codex/scene-script-lifecycle`.
- `.worktrees/base-assets-warning`: required shared asset 진단과 앱 배너, branch `codex/base-assets-warning`.
- `.worktrees/ldr-bloom`: LDR bloom parser/Metal/finalizer, branch `codex/ldr-bloom`.
- `docs/superpowers/plans/2026-07-14-*.md`: lane별 실행 계약과 이 통합 계약.

### Task 1: Create Isolated Worktrees and Establish the Baseline

**Files:**
- Read: `.gitignore`
- Preserve: `.vscode/launch.json`

**Interfaces:**
- Consumes: approved design/plan commit at `main` HEAD.
- Produces: five branches and worktrees sharing the exact same base commit.

- [ ] **Step 1: Verify the only pre-existing user change**

Run:

```bash
git status --short
git check-ignore -q .worktrees
```

Expected: status contains only ` M .vscode/launch.json`; `git check-ignore` exits `0`.

- [ ] **Step 2: Create the integration and lane worktrees**

Run from the repository root:

```bash
git worktree add .worktrees/immediate-ready-wave1 -b codex/immediate-ready-wave1 main
git worktree add .worktrees/web-hard-pause -b codex/web-hard-pause main
git worktree add .worktrees/scene-script-lifecycle -b codex/scene-script-lifecycle main
git worktree add .worktrees/base-assets-warning -b codex/base-assets-warning main
git worktree add .worktrees/ldr-bloom -b codex/ldr-bloom main
git worktree list
```

Expected: all five new worktrees report the same starting commit and their named branches.

- [ ] **Step 3: Run the existing affected-test baseline once**

Run from `.worktrees/immediate-ready-wave1`:

```bash
swift test --filter 'WallpaperBridgeJSTests|WebPropertyDeliveryTests|WebRendererOcclusionTests|TextEngineTests|ConstantScriptTests|SceneEventHookTests|SceneSharedScriptTests|UserPropertyStoreTests|WallpaperPropertiesTests|SceneDocumentTests|HDRPostPassTests|SceneRendererPathFallbackTests|StatusBannerModelTests'
```

Expected: all selected existing tests pass. Do not replace this command with unfiltered `swift test`.

### Task 2: Execute Four Independent Lane Plans in Parallel

**Files:**
- Execute: `docs/superpowers/plans/2026-07-14-web-hard-pause.md`
- Execute: `docs/superpowers/plans/2026-07-14-scene-script-lifecycle.md`
- Execute: `docs/superpowers/plans/2026-07-14-base-assets-warning.md`
- Execute: `docs/superpowers/plans/2026-07-14-ldr-bloom.md`

**Interfaces:**
- Consumes: four isolated worktrees from Task 1.
- Produces: four clean feature branches whose HEAD commits contain implementation and focused tests.

- [ ] **Step 1: Dispatch one implementer per lane**

Give each implementer its absolute worktree path, its single plan path, and these exact constraints:

```text
Execute the assigned plan with TDD. Commit only files listed by that plan.
Do not run the full suite or render corpus. Do not review other lanes.
Finish with git status --short, affected test results, and the branch HEAD hash.
```

Expected: all four agents run concurrently and edit only their own worktrees.

- [ ] **Step 2: Verify every lane handoff is clean**

Run:

```bash
git -C .worktrees/web-hard-pause status --short
git -C .worktrees/scene-script-lifecycle status --short
git -C .worktrees/base-assets-warning status --short
git -C .worktrees/ldr-bloom status --short
```

Expected: no output from any command; each agent has reported its focused tests passing.

### Task 3: Merge the Lane Branches into the Integration Branch

**Files:**
- Modify only on conflict: files already named by the four lane plans.
- Preserve: `.vscode/launch.json`

**Interfaces:**
- Consumes: `codex/web-hard-pause`, `codex/scene-script-lifecycle`, `codex/base-assets-warning`, `codex/ldr-bloom`.
- Produces: `codex/immediate-ready-wave1` containing all four histories.

- [ ] **Step 1: Merge in the approved order**

Run from `.worktrees/immediate-ready-wave1`:

```bash
git merge --no-ff codex/web-hard-pause -m '병합: Web hard pause 구현'
git merge --no-ff codex/scene-script-lifecycle -m '병합: SceneScript lifecycle 구현'
git merge --no-ff codex/base-assets-warning -m '병합: base-assets 누락 안내 구현'
git merge --no-ff codex/ldr-bloom -m '병합: LDR bloom 구현'
```

Expected: Web merges without overlap; any later conflict is limited to the same `SceneRenderer` regions named by the plans.

- [ ] **Step 2: Resolve conflicts by preserving both lane contracts**

For each conflict, retain lifecycle/property state, required-asset diagnostics, and the shared LDR finalizer as separate responsibilities. Then run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and no unmerged paths. If conflict resolution changed tracked files, commit once with `병합: Wave 1 충돌 해소`.

### Task 4: Run the Combined Affected Verification

**Files:**
- Test only: lane test files named by the four plans.

**Interfaces:**
- Consumes: fully merged integration branch.
- Produces: one evidence set covering all changed behavior without a full-suite run.

- [ ] **Step 1: Run the combined focused filter**

Run from `.worktrees/immediate-ready-wave1`:

```bash
swift test --filter 'WallpaperBridgeJSTests|WebPropertyDeliveryTests|WebRendererOcclusionTests|WebHardPauseTests|TextEngineTests|ConstantScriptTests|SceneEventHookTests|SceneSharedScriptTests|SceneScriptMountLifecycleTests|UserPropertyStoreTests|WallpaperPropertiesTests|SceneDocumentTests|LDRBloomPassTests|SceneFinalizerTests|LDRBloomRendererTests|HDRPostPassTests|SceneRendererPathFallbackTests|BaseAssetsWarningGateTests|StatusBannerModelTests'
```

Expected: every selected test passes; no unfiltered test or render-corpus command is run.

- [ ] **Step 2: Verify branch hygiene**

Run:

```bash
git diff --check main...HEAD
git status --short
git log --oneline --decorate main..HEAD
```

Expected: no diff-check errors, clean integration worktree, and all four merge commits visible.

### Task 5: Perform One Final Review, Correct, and Merge to Main

**Files:**
- Review: every file in `git diff --name-only main...codex/immediate-ready-wave1`.
- Modify only if needed: files implicated by Critical/Important findings.

**Interfaces:**
- Consumes: passing integration branch.
- Produces: reviewed `main` merge and removed temporary worktrees/branches.

- [ ] **Step 1: Request exactly one whole-diff review**

Provide the reviewer the approved five design documents, five plans, `main...HEAD` diff, and focused test evidence. Require findings to be labeled Critical, Important, or Minor; do not request per-lane reviews.

Expected: one consolidated review report.

- [ ] **Step 2: Apply Critical/Important corrections in one pass**

Implement only validated Critical/Important findings, add or adjust the closest focused regression test, and commit:

```bash
git status --short
git add -A
git diff --cached --check
git commit -m '수정: Wave 1 최종 리뷰 반영'
```

Expected: either one correction commit, or no commit when the review has no Critical/Important findings. Minor findings remain documented and do not expand scope.

- [ ] **Step 3: Re-run the same combined filter**

Run:

```bash
swift test --filter 'WallpaperBridgeJSTests|WebPropertyDeliveryTests|WebRendererOcclusionTests|WebHardPauseTests|TextEngineTests|ConstantScriptTests|SceneEventHookTests|SceneSharedScriptTests|SceneScriptMountLifecycleTests|UserPropertyStoreTests|WallpaperPropertiesTests|SceneDocumentTests|LDRBloomPassTests|SceneFinalizerTests|LDRBloomRendererTests|HDRPostPassTests|SceneRendererPathFallbackTests|BaseAssetsWarningGateTests|StatusBannerModelTests'
```

Expected: every selected test passes after the review correction pass.

- [ ] **Step 4: Merge locally to `main` without touching the user change**

Run from the repository root:

```bash
git status --short
git merge --no-ff codex/immediate-ready-wave1 -m '병합: 즉시 구현 Wave 1 완료'
git status --short
```

Expected: before and after the merge, `.vscode/launch.json` remains the sole unstaged user change.

- [ ] **Step 5: Remove temporary worktrees and merged branches**

Run from the repository root:

```bash
git worktree remove .worktrees/web-hard-pause
git worktree remove .worktrees/scene-script-lifecycle
git worktree remove .worktrees/base-assets-warning
git worktree remove .worktrees/ldr-bloom
git worktree remove .worktrees/immediate-ready-wave1
git branch -d codex/web-hard-pause codex/scene-script-lifecycle codex/base-assets-warning codex/ldr-bloom codex/immediate-ready-wave1
git worktree list
```

Expected: only the primary worktree remains for this wave and all five temporary branches are deleted.
