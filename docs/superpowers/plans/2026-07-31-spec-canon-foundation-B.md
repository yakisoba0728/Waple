# 정본 기반 구축 B — Swift 측 반영과 오라클 강화

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 계획 A 가 착지시킨 정본과 동봉 에셋을 Swift 측이 실제로 소비하게 하고, 정본 대조로 확인된 이탈을 교정하며, 픽셀 회귀 오라클을 실제로 작동하게 만든다.

**Architecture:** 에셋 해석을 3단에서 4단 폴백으로 확장해 동봉본을 마지막 바닥으로 둔다(사용자 설치본이 항상 우선). 하드 오라클은 커밋된 기준선(`spec/golden/snapshot/baseline-81098bb/manifest.json`)의 per-scene `hash`/`meanLuma` 를 기준으로 삼아 "검은 프레임도 통과"를 끝낸다. 이탈 교정은 오라클이 작동한 **뒤에** 한다 — 순서가 뒤바뀌면 무엇이 바뀌었는지 판정할 수 없다.

**Tech Stack:** Swift 6.3+, SwiftPM 리소스(`.copy`), Metal, XCTest.

## Global Constraints

- **이 계획은 전부 macOS 에서만 검증된다.** Windows 에는 Swift 툴체인이 없다. 각 태스크의 테스트는 Mac 세션에서 돌린다.
- **픽셀을 바꾸는 변경(Task 4~7)은 Task 2 의 오라클 강화가 끝난 뒤에만 한다.**
- 외부 패키지 의존은 **0**이다(`AGENTS.md`). 새로 추가하지 마라.
- 리팩토링은 **순수 추출만**. 조건식·연산 순서·기본값을 바꾸지 마라. early return 이 든 블록을 함수로 빼지 마라.
- **타입체커 폭발** 이력이 4회 있다. 식은 쪼개는 방향으로만 바꾸고, 추출한 함수의 파라미터·반환 타입을 명시하라.
- 커밋 메시지는 **한국어 서술형**, 접두사 없음. 성격이 다른 변경은 커밋을 나눈다.
- 골든 기준선 재생성은 **`-c release`** 로 한다(debug 는 2.8배 걸린다).
- GPU 작업은 **`launchctl asuser $(id -u)`** 로 감싼다. SSH 만으로는 Metal 이 조용히 스킵된다.

## 선행 조건

계획 A 완료 상태여야 한다:
- `spec/` 정본 7문서 (`python scripts/spec/validate.py` 오류 0)
- `Sources/WapleRender/Resources/WEAssets/` 2,940파일 동봉
- `spec/golden/snapshot/baseline-81098bb/` 커밋된 기준선

> ⚠️ **전면 분해(`we-deep-teardown`) 결과가 이 계획을 바꿀 수 있다.** Task 5·6 은
> `g_TexelSize`/`texRes` 의미론에 의존하는데, 분해가 그걸 더 정확히 밝히면 정본이 갱신된다.
> **Task 5·6 착수 전에 `spec/engine/uniform-feed.json` 을 확인하라.**

---

## File Structure

```
Package.swift                                       리소스 선언 추가
Sources/WapleRender/BaseAssetsSettings.swift        4단 폴백(동봉본 추가)
Sources/WapleRender/SceneRenderer.swift             sharedAssetProbe 다중 루트
Sources/WapleCore/GLSLTranslator.swift              g_TexelSize 이원 규약 제거, ambient 배선
Sources/WapleRender/SceneRendererFrameEncoder.swift texRes 4성분
Sources/WapleCore/ScenePBRLighting.swift            GGX 바닥값 결정 반영
Sources/WapleRender/Mesh3DShaders.swift             GGX 바닥값 결정 반영(MSL)
Sources/Waple/AppDelegate.swift                     온보딩 게이트(에셋 항상 존재)
Tests/WapleRenderTests/GoldenBaselineOracleTests.swift   신설 — 기준선 대비 오라클
Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift 하드 오라클 강화
Tests/WapleRenderTests/BundledAssetsTests.swift     신설 — 동봉 에셋 접근
AGENTS.md · BACKLOG.md · README.md                  갱신
```

---

### Task 1: 동봉 에셋을 Swift 가 실제로 읽게 한다

에셋을 넣기만 하고 코드가 안 읽으면 76MB 를 리포에 얹은 의미가 없다.

**Files:**
- Modify: `Package.swift:19` (WapleRender 타깃)
- Modify: `Sources/WapleRender/BaseAssetsSettings.swift`
- Modify: `Sources/WapleRender/SceneRenderer.swift:932-948`, `:1093-1095`
- Test: `Tests/WapleRenderTests/BundledAssetsTests.swift` (신설)

**Interfaces:**
- Produces:
  - `BaseAssetsSettings.bundledAssetsDirectory: URL?`
  - `BaseAssetsSettings.searchRoots: [URL]` — 우선순위 순
  - `SceneRenderer.sharedAssetProbe(_ name: String, roots: [URL]) -> SharedAssetProbeResult`
- Consumes: 기존 `SharedAssetProbeResult` (`.data`/`.missing`/`.rejected`)

- [ ] **Step 1: 실패하는 테스트를 먼저 쓴다**

`Tests/WapleRenderTests/BundledAssetsTests.swift`:

```swift
import XCTest
@testable import WapleRender

/// 동봉된 WE 공유 에셋이 실제로 번들에서 읽히는지. 이게 안 되면 76MB 를 넣은 의미가 없다.
final class BundledAssetsTests: XCTestCase {

    func testBundledAssetsDirectoryExists() {
        let dir = BaseAssetsSettings.bundledAssetsDirectory
        XCTAssertNotNil(dir, "동봉 에셋 디렉터리를 번들에서 못 찾았다 — Package.swift 리소스 선언 확인")
    }

    func testBundledPackIsValid() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        XCTAssertTrue(BaseAssetsSettings.isValidBaseAssetsPack(dir),
                      "동봉본이 유효한 팩이 아니다(shaders/common.h + materials/ 필요)")
    }

    /// 워크샵 pkg 는 common_*.h 를 하나도 담지 않는다(코퍼스 162개 전수 0건).
    /// 그래서 이 6종이 동봉본에 반드시 있어야 한다.
    func testSharedHeadersArePresent() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        for name in ["common.h", "common_blending.h", "common_perspective.h",
                     "common_blur.h", "common_fragment.h", "common_composite.h",
                     "common_vertex.h"] {
            let url = dir.appendingPathComponent("shaders/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "누락: shaders/\(name)")
        }
    }

    func testSearchRootsPutsBundledLast() {
        let roots = BaseAssetsSettings.searchRoots
        XCTAssertFalse(roots.isEmpty, "검색 루트가 비었다")
        XCTAssertEqual(roots.last, BaseAssetsSettings.bundledAssetsDirectory,
                       "동봉본은 마지막 폴백이어야 한다 — 사용자 설치본이 항상 우선")
    }

    /// 동봉본만으로 공유 에셋이 해석돼야 한다(사용자 설치본 없이).
    func testProbeResolvesFromBundleAlone() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("shaders/common.h", roots: [dir])
        guard case .data(let d) = r else {
            return XCTFail("동봉본에서 common.h 를 못 읽었다: \(r)")
        }
        XCTAssertGreaterThan(d.count, 100)
    }

    /// 경로 이탈은 다음 루트로 흘러가면 안 된다 — 보안 판정이지 미스가 아니다.
    func testTraversalIsRejectedNotFallenThrough() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("../../../etc/passwd", roots: [dir, dir])
        guard case .rejected = r else {
            return XCTFail("경로 이탈이 거부되지 않았다: \(r)")
        }
    }

    /// 앞 루트에 없으면 뒤 루트로 넘어가야 한다.
    func testFallsThroughToLaterRoot() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waple-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("shaders/common.h", roots: [empty, dir])
        guard case .data = r else {
            return XCTFail("뒤 루트로 폴백하지 않았다: \(r)")
        }
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
launchctl asuser $(id -u) swift test --filter BundledAssetsTests
```
Expected: 컴파일 실패 — `bundledAssetsDirectory`/`searchRoots` 없음, `sharedAssetProbe(_:roots:)` 없음

- [ ] **Step 3: `Package.swift` 에 리소스 선언**

`Package.swift:19` 의 `.target(name: "WapleRender", dependencies: ["WapleCore"]),` 를 다음으로 바꾼다:

```swift
        .target(
            name: "WapleRender",
            dependencies: ["WapleCore"],
            // WE 2.8.42 공유 에셋 동봉. 워크샵 pkg 가 common_*.h 를 하나도 담지 않아
            // (코퍼스 162개 전수 0건) 이게 없으면 대부분의 씬이 불완전하게 그려진다.
            // 출처·해시는 spec/assets/manifest.json 참조.
            resources: [.copy("Resources/WEAssets")]
        ),
```

`.copy` 를 쓰는 이유: `.process` 는 SwiftPM 이 파일을 변형·평탄화할 수 있는데, 여기서는
**디렉터리 구조와 바이트가 그대로 보존돼야 한다**(경로 규약이 곧 계약이고 해시로 검증한다).

- [ ] **Step 4: `BaseAssetsSettings` 에 동봉본과 검색 루트 추가**

`Sources/WapleRender/BaseAssetsSettings.swift` 의 `logAutoDetectedOnce` 앞에 추가:

```swift
    /// 앱 번들에 동봉된 WE 2.8.42 공유 에셋. 해석 순서상 **마지막 폴백**이다.
    /// 사용자가 최신·수정된 WE 설치본을 갖고 있으면 그쪽이 이긴다.
    public static var bundledAssetsDirectory: URL? {
        guard let url = Bundle.module.resourceURL?
            .appendingPathComponent("WEAssets", isDirectory: true) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    /// 공유 에셋 검색 루트 — **우선순위 순**.
    /// 1) 사용자 지정 / 자동 탐지 (기존 `baseAssetsDirectory`)
    /// 2) 앱 동봉본
    ///
    /// 동봉본을 마지막에 두는 이유: 사용자 설치본이 더 새롭거나 수정돼 있을 수 있고,
    /// 그 의도를 앱이 덮어쓰면 안 된다. 동봉본은 "없을 때의 바닥"이다.
    public static var searchRoots: [URL] {
        var roots: [URL] = []
        if let user = baseAssetsDirectory { roots.append(user) }
        if let bundled = bundledAssetsDirectory,
           !roots.contains(where: { $0.standardizedFileURL == bundled.standardizedFileURL }) {
            roots.append(bundled)
        }
        return roots
    }
```

- [ ] **Step 5: `sharedAssetProbe` 를 다중 루트로**

`Sources/WapleRender/SceneRenderer.swift:932` 의 기존 단일 루트 함수는 **그대로 두고**(기존
호출부·테스트 호환), 그 아래에 다중 루트 오버로드를 추가한다:

```swift
    /// 여러 루트를 우선순위대로 훑는다. 첫 `.data` 를 반환.
    ///
    /// `.rejected`(경로 이탈)는 **즉시 반환한다** — 이건 보안 판정이지 "이 루트에 없음"이
    /// 아니다. 다음 루트로 흘려보내면 이탈 경로가 다른 루트에서 성공할 수 있다.
    static func sharedAssetProbe(_ name: String, roots: [URL]) -> SharedAssetProbeResult {
        for root in roots {
            switch sharedAssetProbe(name, root: root) {
            case .data(let d): return .data(d)
            case .rejected: return .rejected
            case .missing: continue
            }
        }
        return .missing
    }
```

- [ ] **Step 6: 마운트 경로를 다중 루트로 전환**

`Sources/WapleRender/SceneRenderer.swift:1093-1095` 의

```swift
                try SceneDocument.parse(package: package, sharedAssetProbe: { name in
                    Self.sharedAssetProbe(name, root: BaseAssetsSettings.baseAssetsDirectory)
                }, onMissingRequiredAsset: { [weak self] in
```

를 다음으로 바꾼다:

```swift
                let assetRoots = BaseAssetsSettings.searchRoots
                try SceneDocument.parse(package: package, sharedAssetProbe: { name in
                    Self.sharedAssetProbe(name, roots: assetRoots)
                }, onMissingRequiredAsset: { [weak self] in
```

루트를 클로저 밖에서 한 번만 계산하는 이유: `searchRoots` 는 `UserDefaults` 를 읽고
파일 존재를 검사한다. 에셋 하나마다 다시 계산하면 마운트당 수백 회가 된다.

- [ ] **Step 7: 테스트 통과 확인**

```bash
launchctl asuser $(id -u) swift test --filter BundledAssetsTests
```
Expected: 7 tests PASS

- [ ] **Step 8: 기존 스위트 무회귀 확인**

```bash
launchctl asuser $(id -u) swift test 2>&1 | tail -20
```
Expected: 실패 0. 테스트 수는 신규분(7)만큼 증가.

- [ ] **Step 9: 커밋**

```bash
git add Package.swift Sources/WapleRender/BaseAssetsSettings.swift \
        Sources/WapleRender/SceneRenderer.swift Tests/WapleRenderTests/BundledAssetsTests.swift
git commit -m "동봉 에셋을 마지막 폴백으로 배선(설정→자동탐지→동봉 순, 경로 이탈은 즉시 거부)"
```

---

### Task 2: 하드 오라클 강화 — "검은 프레임도 통과"를 끝낸다

**픽셀을 바꾸는 Task 4~7 전에 반드시 끝내야 한다.** 지금 GT 테스트의 단언은
`RealPackagesGroundTruthTests.swift:106-108` 의 세 줄뿐이다:

```swift
XCTAssertGreaterThan(mounted, 0, "실측 씬이 하나도 마운트되지 않음")
XCTAssertEqual(failed.count, 0, "mount 실패: \(failed)")
XCTAssertEqual(captured, mounted, "캡처 누락: \(missingCapture)")
```

픽셀 내용을 전혀 보지 않는다. 커밋된 기준선이 생겼으니 그걸 기준으로 삼는다.

**Files:**
- Create: `Tests/WapleRenderTests/GoldenBaselineOracleTests.swift`
- Modify: `Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift:106-108`

**Interfaces:**
- Consumes: `spec/golden/snapshot/baseline-81098bb/manifest.json` (필드: `entries[].id`, `.hash`, `.meanLuma`, `.deterministic`, `.selfMaxDiff`)
- Produces: `GoldenBaseline.load(label:) -> GoldenBaseline?`, `GoldenBaseline.entry(id:) -> Entry?`

- [ ] **Step 1: 테스트를 먼저 쓴다**

`Tests/WapleRenderTests/GoldenBaselineOracleTests.swift`:

```swift
import XCTest
@testable import WapleRender

/// 커밋된 스냅샷 기준선을 읽어 오라클로 쓴다.
///
/// 지금까지 하드 오라클이 "마운트 무크래시 + PNG 존재" 뿐이라 완전히 검은 프레임도
/// 통과했다(BACKLOG F402/F403). 기준선이 커밋됐으니 그걸 기준으로 삼는다.
struct GoldenBaseline: Decodable {
    struct Entry: Decodable {
        let id: String
        let hash: String
        let meanLuma: Double
        let deterministic: Bool
        let selfMaxDiff: Int
    }
    let label: String
    let gitSHA: String
    let captureTime: Double
    let entries: [Entry]

    /// 리포 루트 기준 `spec/golden/snapshot/<label>/manifest.json`.
    static func load(label: String = "baseline-81098bb") -> GoldenBaseline? {
        // 테스트 바이너리는 .build 안에 있으므로 소스 파일 위치에서 리포 루트를 거슬러 올라간다.
        var dir = URL(fileURLWithPath: #filePath)      // Tests/WapleRenderTests/...
            .deletingLastPathComponent()                // WapleRenderTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // repo root
        dir = dir.appendingPathComponent("spec/golden/snapshot/\(label)/manifest.json")
        guard let data = try? Data(contentsOf: dir) else { return nil }
        return try? JSONDecoder().decode(GoldenBaseline.self, from: data)
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }
}

final class GoldenBaselineOracleTests: XCTestCase {

    func testBaselineIsCommittedAndLoadable() throws {
        let b = try XCTUnwrap(GoldenBaseline.load(),
                              "커밋된 기준선을 못 읽었다 — spec/golden/snapshot/ 확인")
        XCTAssertEqual(b.gitSHA, "81098bb")
        XCTAssertEqual(b.entries.count, 170)
    }

    /// 기준선 자체에 검은 프레임이 없어야 한다. 있으면 기준선이 오염된 것이다.
    func testBaselineHasNoBlackFrames() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let black = b.entries.filter { $0.meanLuma <= 0.0 }
        XCTAssertTrue(black.isEmpty, "기준선에 검은 프레임: \(black.map(\.id))")
    }

    /// 비결정 씬은 회귀 판정에서 제외해야 하므로, 몇 개인지 고정해 둔다.
    /// 늘어나면 렌더러에 새 비결정성이 생긴 것이다.
    func testNonDeterministicSceneCountIsPinned() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let nd = b.entries.filter { !$0.deterministic }.map(\.id).sorted()
        XCTAssertEqual(nd, ["3363252053"],
                       "비결정 씬 목록이 바뀌었다 — 새 비결정성이 생겼는지 확인")
    }

    func testDeterministicScenesHaveZeroSelfDiff() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let bad = b.entries.filter { $0.deterministic && $0.selfMaxDiff != 0 }
        XCTAssertTrue(bad.isEmpty,
                      "결정으로 표시됐는데 self-diff 가 0 이 아니다: \(bad.map(\.id))")
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
launchctl asuser $(id -u) swift test --filter GoldenBaselineOracleTests
```
Expected: 컴파일은 되지만 `testBaselineIsCommittedAndLoadable` 이 경로에 따라 실패할 수 있다.
실패하면 `#filePath` 기준 경로 계산을 실제 구조에 맞게 고친다.

- [ ] **Step 3: 통과 확인**

```bash
launchctl asuser $(id -u) swift test --filter GoldenBaselineOracleTests
```
Expected: 4 tests PASS

- [ ] **Step 3b: `SnapshotCompare` 가 기록해둔 필드를 실제로 쓰게 한다**

> **실측으로 드러난 것(`spec/golden/gate-analysis.json`):** 게이트가 매니페스트의
> `hash`·`meanLuma`·`selfMaxDiff` 를 **한 번도 읽지 않는다**(`SnapshotCompare.swift:81-82` 는
> `deterministic` 만 쓴다). 그리고 `strict` 임계가 **절대 단위**(`meanAbsDiff 1.5/255`)라
> 어두운 씬일수록 느슨해진다 — **전면 검정으로 바꿔도 통과하는 씬이 3종**이다
> (`3444535389` 0.00208 · `1612750231` 0.00322 · `3662790108` 0.00342).
>
> 고칠 게 많지 않다. **이미 기록 중인 값을 읽기만 해도 즉시 강해진다.**

`Sources/WapleCompat/SnapshotCompare.swift` 의 판정부(`:80-82`)를 다음으로 바꾼다:

```swift
                    let m = diffRGBA(cur, base)
                    let thr: DiffThreshold = entry.deterministic ? .strict : .lax
                    // ① 해시 동일이면 픽셀이 완전히 같다 — diff 를 볼 것도 없이 통과.
                    //    (지금까지 이 필드를 기록만 하고 안 읽었다.)
                    let identical = m.maxAbsDiff == 0
                    // ② 절대 임계는 어두운 씬에서 무력하다. 기준선 meanLuma 로 정규화한
                    //    상대 지표를 함께 본다 — 둘 중 하나라도 넘으면 FAIL.
                    //    분모를 0.02(=luma 5/255)로 하한 클램프하는 이유: 그보다 어두우면
                    //    상대비가 발산해 오탐이 된다. 그 구간은 아래 ③ 이 맡는다.
                    let relDiff = m.meanAbsDiff / (max(entry.meanLuma, 0.02) * 255.0)
                    // ③ 아주 어두운 씬(기준선 meanLuma < 0.02)은 절대·상대 모두 둔하다.
                    //    "구조가 사라졌는가" 로 본다 — 비검정 픽셀 비율의 급락.
                    let structureLoss = entry.meanLuma < 0.02
                        && m.meanAbsDiff > entry.meanLuma * 255.0 * 0.5
                    let pass = identical
                        || (passes(m, thr) && relDiff <= Self.relativeTolerance && !structureLoss)
                    rows.append(CompareRow(id: entry.id, metrics: m,
                                           deterministic: entry.deterministic, pass: pass))
```

그리고 클래스에 상수를 추가한다:

```swift
    /// 기준선 밝기로 정규화한 허용 편차. 절대 임계(strict 1.5/255)가 어두운 씬에서
    /// 무력한 것을 보완한다 — spec/golden/gate-analysis.json 참조.
    static let relativeTolerance: Double = 0.05
```

`SnapshotManifest.Entry` 에 `meanLuma` 가 디코드되는지 확인하고, 없으면 추가한다
(`Sources/WapleSnapshot/Snapshot.swift`). **기록은 이미 하고 있으므로 스키마 변경이 아니다.**

- [ ] **Step 3c: 게이트가 실제로 잡는지 합성 검증**

`Tests/WapleSnapshotTests/` 에 순수 유닛을 추가한다(코퍼스·GPU 불필요, CI 에서 돈다):

```swift
    /// 어두운 씬을 전면 검정으로 바꾸면 잡혀야 한다.
    /// 종전 절대 임계만으로는 3종이 통과했다(spec/golden/gate-analysis.json).
    func testBlackoutOfDarkSceneIsCaught() {
        // 기준선 meanLuma 0.0034 인 씬을 전면 검정으로: 평균 절대차 ≈ 0.87
        let m = DiffMetrics(meanAbsDiff: 0.87, maxAbsDiff: 3, fracExceeding: 0.0)
        XCTAssertTrue(passes(m, .strict), "절대 임계만으로는 통과한다(종전 동작)")
        let rel = 0.87 / (max(0.0034, 0.02) * 255.0)
        let structureLoss = 0.0034 < 0.02 && 0.87 > 0.0034 * 255.0 * 0.5
        XCTAssertTrue(structureLoss, "구조 소실 판정이 이걸 잡아야 한다")
        _ = rel
    }

    /// 밝은 씬의 미세 인코딩 노이즈는 통과해야 한다(오탐 방지).
    func testMinorNoiseOnBrightSceneStillPasses() {
        let m = DiffMetrics(meanAbsDiff: 0.4, maxAbsDiff: 3, fracExceeding: 0.0005)
        let rel = 0.4 / (max(0.39, 0.02) * 255.0)   // median 밝기 씬
        XCTAssertTrue(passes(m, .strict))
        XCTAssertLessThanOrEqual(rel, 0.05)
    }
```

`DiffMetrics` 의 실제 이니셜라이저 시그니처를 먼저 확인하고 맞출 것.

- [ ] **Step 4: GT 하드 오라클에 픽셀 단언 추가**

`Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift:106-108` 의 세 줄 **뒤에** 추가한다
(기존 세 줄은 그대로 둔다 — 약화가 아니라 강화다):

```swift
        // F402/F403: 종전 단언은 "마운트 무크래시 + PNG 존재" 뿐이라 완전히 검은 프레임도
        // 통과했다. 커밋된 기준선(spec/golden/snapshot/)이 생겼으므로 픽셀 내용을 본다.
        if let baseline = GoldenBaseline.load() {
            var blackFrames: [String] = []
            var lumaDrift: [String] = []
            for (sceneId, luma) in lumas {
                // ① 완전 검정 거부 — 기준선에 검은 프레임이 하나도 없으므로 새로 생기면 결함이다.
                if luma <= 0.0 { blackFrames.append(sceneId) }
                // ② 기준선 대비 luma 드리프트. 비결정 씬은 제외한다.
                guard let ref = baseline.entry(id: sceneId), ref.deterministic else { continue }
                if abs(Double(luma) - ref.meanLuma) > Self.lumaDriftTolerance {
                    lumaDrift.append("\(sceneId): \(ref.meanLuma) -> \(luma)")
                }
            }
            XCTAssertTrue(blackFrames.isEmpty, "완전 검정 프레임: \(blackFrames)")
            if !lumaDrift.isEmpty {
                // 드리프트는 의도적 변경일 수 있으므로 실패시키지 않고 크게 남긴다.
                // 의도된 변경이면 기준선을 재생성하고 라벨을 갱신할 것.
                NSLog("%@", "[WapleGT] 기준선 대비 luma 드리프트 \(lumaDrift.count)건: \(lumaDrift.prefix(20))")
            }
        } else {
            NSLog("%@", "[WapleGT] 커밋된 기준선을 못 읽었다 — 픽셀 오라클 미적용")
        }
```

그리고 클래스에 상수를 추가한다:

```swift
    /// 기준선 대비 평균 luma 허용 편차. 캡처 환경(GPU·드라이버) 차이를 흡수하되
    /// 눈에 보이는 밝기 변화는 잡는 폭. 0.02 는 8비트로 약 5단계다.
    static let lumaDriftTolerance: Double = 0.02
```

- [ ] **Step 5: 오라클이 실제로 검은 프레임을 잡는지 확인**

일부러 깨뜨려 본다. `SceneRenderer.swift` 의 `clearColor` 대입부를 임시로
`MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)` 고정으로 바꾸고 씬 몇 개만 돌린다.

```bash
launchctl asuser $(id -u) swift test --filter RealPackagesGroundTruth 2>&1 | tail -30
```
Expected: **검정 프레임 단언이 실패해야 한다.** 실패하지 않으면 오라클이 여전히 안 잡는 것이다.

확인 후 **반드시 되돌린다**: `git checkout Sources/WapleRender/SceneRenderer.swift`

- [ ] **Step 6: 되돌린 뒤 통과 확인**

```bash
git status --short   # 비어야 한다(테스트 파일 제외)
launchctl asuser $(id -u) swift test --filter RealPackagesGroundTruth 2>&1 | tail -10
```
Expected: PASS

- [ ] **Step 7: 커밋**

```bash
git add Tests/WapleRenderTests/GoldenBaselineOracleTests.swift \
        Tests/WapleRenderTests/RealPackagesGroundTruthTests.swift
git commit -m "하드 오라클에 픽셀 단언 추가(검정 프레임 거부 + 기준선 luma 드리프트 — F402/F403)"
```

---

### Task 3: 에셋 결손이 실제로 0 이 됐는지 측정

동봉했으니 결손이 사라져야 한다. **사라졌다고 가정하지 말고 센다.**

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift` (결손 카운터 노출)
- Test: `Tests/WapleRenderTests/BundledAssetsTests.swift` (추가)

**Interfaces:**
- Produces: `SceneRenderer.missingSharedAssetNames: [String]` (마운트당 리셋, 테스트 관측용)

- [ ] **Step 1: 테스트 추가**

`Tests/WapleRenderTests/BundledAssetsTests.swift` 에 추가:

```swift
    /// 동봉 후에는 공유 에셋 결손이 0 이어야 한다.
    /// 코퍼스가 없으면 스킵한다(합성 CI 에서는 검증 불가).
    func testNoMissingSharedAssetsAcrossCorpus() throws {
        guard let corpus = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"] else {
            throw XCTSkip("WAPLE_REAL_PKGS 미설정 — 코퍼스 필요")
        }
        let root = URL(fileURLWithPath: corpus, isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: nil)) ?? []

        var offenders: [String: [String]] = [:]
        for dir in dirs {
            let pkg = dir.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: pkg.path),
                  let data = try? Data(contentsOf: pkg),
                  let package = try? ScenePackage.parse(data) else { continue }

            var missing: [String] = []
            let roots = BaseAssetsSettings.searchRoots
            _ = try? SceneDocument.parse(package: package, sharedAssetProbe: { name in
                let r = SceneRenderer.sharedAssetProbe(name, roots: roots)
                if case .missing = r { missing.append(name) }
                return r
            })
            if !missing.isEmpty { offenders[dir.lastPathComponent] = Array(Set(missing)).sorted() }
        }

        if !offenders.isEmpty {
            let sample = offenders.prefix(10).map { "\($0.key): \($0.value.prefix(5))" }
            XCTFail("공유 에셋 결손 \(offenders.count)씬 — \(sample)")
        }
    }
```

`import WapleCore` 를 파일 상단에 추가한다(`ScenePackage`/`SceneDocument` 사용).

- [ ] **Step 2: 실행**

```bash
export WAPLE_REAL_PKGS=~/Downloads/wallpaper_dev/backgrounds
launchctl asuser $(id -u) env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
  swift test --filter testNoMissingSharedAssetsAcrossCorpus 2>&1 | tail -20
```
Expected: PASS. **실패하면 그 목록이 곧 다음 작업 항목이다** — 무엇이 아직 부족한지 알려준다.

- [ ] **Step 3: 결손이 남으면 원인 분류**

실패 목록을 보고 판단한다:
- `models/util/*.json` 류 → 동봉본에 있는데 경로 규약이 다른 것. 폴백 경로를 고친다.
- `effects/workshop/<id>/...` → 패키지 내부 경로. 공유 에셋이 아니다. 테스트에서 제외한다.
- 그 외 → `spec/assets/inventory.json` 에 없는 파일. WE 설치본에도 없는 것이므로 기록만.

- [ ] **Step 4: 커밋**

```bash
git add Tests/WapleRenderTests/BundledAssetsTests.swift
git commit -m "코퍼스 전수 공유 에셋 결손 0건 검증(동봉이 실제로 작동하는지 측정)"
```

---

### Task 4: 온보딩 게이트 정리

에셋이 항상 존재하게 됐으므로 "기본 에셋을 지정하세요" 안내가 거짓이 된다.

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift:232`

- [ ] **Step 1: 현재 조건 확인**

```bash
sed -n '225,240p' Sources/Waple/AppDelegate.swift
```

`baseAssets: BaseAssetsSettings.baseAssetsDirectory != nil` 이 온보딩 준비 항목에 쓰인다.

- [ ] **Step 2: 동봉본을 포함하도록 수정**

`baseAssetsDirectory != nil` 을 `!BaseAssetsSettings.searchRoots.isEmpty` 로 바꾼다.

- [ ] **Step 3: 관련 테스트 확인**

```bash
launchctl asuser $(id -u) swift test --filter Onboarding 2>&1 | tail -10
```
Expected: PASS. 실패하면 테스트가 "에셋 미지정" 상태를 전제하고 있는 것이므로,
그 전제를 동봉 이후 현실에 맞게 갱신한다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Waple/AppDelegate.swift Tests/WapleAppTests/OnboardingTests.swift
git commit -m "온보딩 에셋 항목을 동봉본 포함으로 판정(이제 항상 충족된다)"
```

---

### Task 5: `g_TexelSize` 이원 규약 제거

> ⚠️ **착수 전 `spec/engine/uniform-feed.json` 을 확인하라.** 전면 분해가 이 유니폼의
> 피드 방식을 더 정확히 밝혔을 수 있다. 정본이 아래와 다르면 **정본을 따른다.**

`BACKLOG.md` 의 X-⑤ 는 스스로 "판별력 0 인 근거로 채택한 정본"이라 적어 뒀다.
판별력 있는 증거가 나왔다 — `blur_h_bloom` 이 tex0 로 1/8 해상도 RT 를 바인드하는데
vert 는 `g_TexelSize.y * 8.0` 을 쓴다. **"dst(출력 렌더타깃) 고정" 확정.**

**Files:**
- Modify: `Sources/WapleCore/GLSLTranslator.swift:1254-1255`
- Modify: 레이어 커스텀 셰이더 경로의 tex0 근사(위치는 `g_TexelSize` grep 으로 찾는다)
- Test: `Tests/WapleCoreTests/GLSLTranslatorTests.swift` (추가)

- [ ] **Step 1: 현재 이원 규약을 찾는다**

```bash
grep -rn "g_TexelSize\|targetRes" Sources/ --include=*.swift
```

현재 `GLSLTranslator.swift:1254` 는 `"(1.0 / eng.targetRes.xy)"` 로 dst 기준이다.
레이어 커스텀 경로가 tex0 기준으로 다르게 주는 곳이 있으면 그게 제거 대상이다.

- [ ] **Step 2: 테스트로 규약을 고정한다**

`Tests/WapleCoreTests/GLSLTranslatorTests.swift` 에 추가:

```swift
    /// g_TexelSize 는 출력 렌더타깃(dst) 기준 1텍셀이다. tex0 기준이 아니다.
    ///
    /// 판별 근거(spec/engine/uniforms.json): blur_h_bloom 이 tex0 로 1/8 해상도 RT 를
    /// 바인드하는데 vert 는 g_TexelSize.y * 8.0 을 쓴다. tex0 기준이면 8배가 설명되지 않는다.
    func testTexelSizeIsTargetRelativeNotTexture0() throws {
        let src = """
        uniform vec4 g_TexelSize;
        void main() { gl_FragColor = vec4(g_TexelSize.xy, 0.0, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: "void main(){}", fragment: src, combos: [:]))
        XCTAssertTrue(t.msl.contains("targetRes"),
                      "g_TexelSize 가 targetRes 기준으로 방출되지 않았다")
        XCTAssertFalse(t.msl.contains("texRes[0]"),
                      "g_TexelSize 에 tex0 기준 잔재가 남아 있다(이원 규약)")
    }
```

- [ ] **Step 3: 실행해 현재 상태 확인**

```bash
launchctl asuser $(id -u) swift test --filter testTexelSizeIsTargetRelativeNotTexture0
```
현재 통과하면 이원 규약이 이미 없는 것이다 — 그러면 코드 변경 없이 Step 5 로 간다.
실패하면 tex0 잔재를 제거한다.

- [ ] **Step 4: 잔재가 있으면 제거**

레이어 커스텀 셰이더 경로가 `g_TexelSize` 를 tex0 기준으로 주는 곳을 찾아
`eng.targetRes` 기준으로 통일한다. **주석에 근거를 남긴다** — 이 리포는 주석이 설계 근거다:

```swift
// spec/engine/uniforms.json: g_TexelSize 는 출력 렌더타깃 기준 1텍셀로 확정됐다.
// (blur_h_bloom 이 1/8 RT 를 tex0 로 바인드하면서 g_TexelSize.y * 8.0 을 쓴다 —
//  tex0 기준이면 그 8배가 설명되지 않는다.) 종전 레이어 경로의 tex0 근사는 WE 에
//  대응물이 없는 이원 규약이라 제거했다. BACKLOG X-⑤ 종결.
```

- [ ] **Step 5: 픽셀 영향 확인**

```bash
export WAPLE_REAL_PKGS=~/Downloads/wallpaper_dev/backgrounds
export WAPLE_BASE_ASSETS=~/Downloads/wallpaper_dev/assets
launchctl asuser $(id -u) env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
  swift run -c release WapleCompat --compare spec/golden/snapshot/baseline-81098bb 2>&1 | tail -40
```

`bokeh_blur` 를 쓰는 씬의 블러 폭이 바뀌면 **의도된 변경**이다(정본이 그렇게 말한다).
바뀐 씬 목록을 커밋 메시지에 남긴다.

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleCore/GLSLTranslator.swift Tests/WapleCoreTests/GLSLTranslatorTests.swift
git commit -m "g_TexelSize 이원 규약 제거(dst 고정으로 통일 — BACKLOG X-⑤ 종결)"
```

- [ ] **Step 7: `BACKLOG.md` 의 X-⑤ 항목을 종결로 표시**

해당 행을 취소선 처리하고 근거를 적는다(리포 관례: 이력을 지우지 않고 남긴다).

---

### Task 6: `texRes` 4성분 실전달

> ⚠️ **착수 전 `spec/engine/uniform-feed.json` 과 `spec/formats/tex-deep.json` 을 확인하라.**

**현재** `Sources/WapleRender/SceneRendererFrameEncoder.swift:74`:

```swift
            texRes[slot] = SIMD4(w, h, w, h)
```

**정본** `(할당폭, 할당높이, 실이미지폭, 실이미지높이)`. `.zw/.xy` 비율이 NPOT 패딩 보정
UV 스케일이다. `*Resolution` 참조 셰이더 324개 중 194개(60%)가 `.z/.w` 를 쓴다.

**Files:**
- Modify: `Sources/WapleRender/SceneRendererFrameEncoder.swift:69-86`
- Test: `Tests/WapleRenderTests/` (신설 또는 기존에 추가)

- [ ] **Step 1: 실제 이미지 크기를 어디서 얻는지 확인**

```bash
grep -n "imageWidth\|imageHeight\|decodeWidth\|decodeHeight" Sources/WapleCore/TexImage.swift | head
```

`TexImage.CompressedMip` 에 `decodeWidth/decodeHeight`(패딩 포함)와
`imageWidth/imageHeight`(실제)가 있다. `MTLTexture` 는 크롭 업로드 후 크기만 알므로,
**빌드 시점에 실이미지 크기를 함께 보관해야 한다.**

- [ ] **Step 2: 테스트를 먼저 쓴다**

```swift
    /// g_TextureNResolution 은 (할당w, 할당h, 실이미지w, 실이미지h)다.
    /// (w,h,w,h) 로 접으면 NPOT 패딩 보정을 쓰는 셰이더가 어긋난다 — 코퍼스 60%가 .z/.w 를 쓴다.
    func testTexResCarriesAllocatedAndImageDims() {
        let r = SceneRenderer.texResComponents(allocated: (128, 64), image: (100, 50))
        XCTAssertEqual(r.x, 128); XCTAssertEqual(r.y, 64)
        XCTAssertEqual(r.z, 100); XCTAssertEqual(r.w, 50)
    }

    /// 크롭 업로드로 할당==이미지인 경우는 종전과 같은 값이어야 한다(무회귀).
    func testTexResIsUnchangedWhenNoPadding() {
        let r = SceneRenderer.texResComponents(allocated: (256, 256), image: (256, 256))
        XCTAssertEqual(r, SIMD4<Float>(256, 256, 256, 256))
    }
```

- [ ] **Step 3: 순수 함수를 추출한다**

`Sources/WapleRender/SceneRendererFrameEncoder.swift` 에 추가:

```swift
    /// g_TextureNResolution 성분 구성 — (할당w, 할당h, 실이미지w, 실이미지h).
    ///
    /// spec/engine/uniforms.json: `.zw/.xy` 비율이 NPOT 패딩 보정 UV 스케일이다.
    /// 종전 (w,h,w,h) 규약은 Waple 이 텍스처를 크롭 업로드하는 한 자기정합적이었으나,
    /// keepFullAtlas 스프라이트 아틀라스에서 불변식이 깨진다.
    static func texResComponents(allocated: (Int, Int), image: (Int, Int)) -> SIMD4<Float> {
        SIMD4(Float(max(1, allocated.0)), Float(max(1, allocated.1)),
              Float(max(1, image.0)), Float(max(1, image.1)))
    }
```

- [ ] **Step 4: 호출부를 전환**

`runtimeTexRes` 의 `set(_:_:)` 를 실이미지 크기까지 받도록 바꾼다. 실이미지 크기를
모르는 슬롯(FBO 등)은 할당 크기와 같게 둔다 — 그건 패딩이 없는 렌더타깃이므로 정확하다.

- [ ] **Step 5: 테스트 + 픽셀 영향 확인**

```bash
launchctl asuser $(id -u) swift test --filter texRes
launchctl asuser $(id -u) env WAPLE_REAL_PKGS=... WAPLE_BASE_ASSETS=... \
  swift run -c release WapleCompat --compare spec/golden/snapshot/baseline-81098bb 2>&1 | tail -40
```

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleRender/SceneRendererFrameEncoder.swift Tests/WapleRenderTests/
git commit -m "g_TextureNResolution 4성분 실전달(NPOT 패딩 보정 — 코퍼스 셰이더 60%가 .zw 사용)"
```

---

### Task 7: `g_LightAmbientColor` 실제 배선

**현재** `Sources/WapleCore/GLSLTranslator.swift:1256-1257`:

```swift
        // F744: g_LightAmbientColor 는 엔진 상수로 승격. 실제 scene ambientColor 연동 전 흰색 중립값.
        if name == "g_LightAmbientColor" { return "float4(1.0, 1.0, 1.0, 1.0)" }
```

주석이 스스로 임시값임을 인정한다. **정본**: 씬 기본값은 **0.3**이고
모델 경로는 반구 보간 `mix(skylight, ambient, dot(N, up)*0.5+0.5)` 다.

- [ ] **Step 1: 블라스트 반경을 먼저 측정한다**

워크샵 셰이더 중 `g_LightAmbientColor` 선언은 **0건**이다. 이 폴백이 발화하는 건
베이스 에셋 `genericimage4`/`fluidsim` 을 번역해 쓰는 경로뿐이다. **몇 씬이 그 경로를 타는가?**

`GLSLTranslator` 의 해당 분기에 임시 로그를 넣고 코퍼스 전수 마운트를 돌려 센다:

```swift
        if name == "g_LightAmbientColor" {
            NSLog("%@", "[BLAST] g_LightAmbientColor 폴백 발화")
            return "float4(1.0, 1.0, 1.0, 1.0)"
        }
```

```bash
launchctl asuser $(id -u) env WAPLE_REAL_PKGS=... WAPLE_BASE_ASSETS=... \
  swift test --filter RealPackagesGroundTruth 2>&1 | grep -c "\[BLAST\]"
```

**반경이 0 이면** 값만 고치고 넘어간다(위험 없음).
**반경이 크면** 별도 A/B 캡처 라운드를 붙인다.

측정 후 임시 로그를 **반드시 제거**한다.

- [ ] **Step 2: 씬 ambient 를 엔진 유니폼으로 배선**

`SceneDocument` 는 이미 `ambientColor`/`skylightColor` 를 파싱해 갖고 있다
(`SceneDocument.swift:757-761`). 이걸 엔진 유니폼 버퍼에 실어 셰이더가 읽게 한다.

`engineUniform` 의 레이아웃에 2슬롯(각 vec4)을 추가하고, `GLSLTranslator` 의
`engineReplacement` 를 상수 대신 그 슬롯 참조로 바꾼다.

> **주의:** `SceneRendererFrameEncoder.swift:38-39` 주석이 명시한다 —
> "레이아웃은 GLSLTranslator.assemble 의 EngineU 구조체 방출과 **동기 필수**".
> 한쪽만 고치면 조용히 어긋난 값을 읽는다. 두 곳을 함께 바꾸고 테스트로 고정한다.

- [ ] **Step 3: 테스트**

```swift
    /// g_LightAmbientColor 는 씬 값을 받는다. 흰색 상수가 아니다.
    /// 씬 기본값은 0.3 이고(코퍼스 ambientcolor "0.3 0.3 0.3" 113건),
    /// 흰색 폴백은 해당 경로를 3.33배 밝게 만들었다.
    func testAmbientColorComesFromScene() throws {
        let src = "uniform vec4 g_LightAmbientColor;\nvoid main(){ gl_FragColor = g_LightAmbientColor; }"
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: "void main(){}", fragment: src, combos: [:]))
        XCTAssertFalse(t.msl.contains("float4(1.0, 1.0, 1.0, 1.0)"),
                       "흰색 상수 폴백이 남아 있다")
        XCTAssertTrue(t.msl.contains("eng."), "엔진 유니폼 참조로 방출되지 않았다")
    }
```

- [ ] **Step 4: 픽셀 영향 확인 + 커밋**

```bash
launchctl asuser $(id -u) env WAPLE_REAL_PKGS=... WAPLE_BASE_ASSETS=... \
  swift run -c release WapleCompat --compare spec/golden/snapshot/baseline-81098bb 2>&1 | tail -40
git add Sources/WapleCore/GLSLTranslator.swift Sources/WapleRender/SceneRendererFrameEncoder.swift Tests/
git commit -m "g_LightAmbientColor 를 씬 값으로 배선(흰색 임시 폴백 제거 — 해당 경로가 3.33배 밝았다)"
```

---

### ~~Task 8: 의도적 이탈 3건~~ — **완료 (2026-08-01)**

이 태스크는 계획 B 착수 전에 끝났다. WE 원문 대조 + macOS A/B 캡처(release)로 결정했다.

| # | 판정 | 근거 |
| --- | --- | --- |
| D1 GGX 분모 바닥값 | **유지** | 실재하는 이탈. 갈리는 지점이 `roughness=0·N·H=1` 하나뿐이고 거기서 WE 는 `0/0 = NaN`, Waple 은 `0`. NaN 이 픽셀을 오염시키므로 Waple 쪽이 낫다. A/B 화면 영향 **0** |
| D2 `nl`/`nv` 하한 | **이탈 아님** | WE `common_pbr.h:36` 과 바이트 단위 동일. `0.001` 은 WE 자신의 값이다 |
| D3 블렌드 가드 범위 | **유지** | 실재. A/B 영향 **0**. 단 `[0,1]` 밖 입력을 만드는 표본이 HDR 1종뿐이라 근거가 얇다 |

결정과 근거는 `spec/engine/deviations.json`(`deviation.decision`)에 있고,
소스 주석 3곳이 그 정본을 가리킨다 — **재발굴 방지**가 목적이다.

> **이 라운드가 남긴 방법론 교훈 셋** — 이후 A/B 에서 반복하지 말 것:
> 1. **`ScenePBRMath` 는 데드코드다**(`Sources/` 참조 0, 테스트 2개만). 라이브 PBR 은
>    전부 `Mesh3DShaders.swift` 의 MSL 이다. 첫 A/B 패치가 이걸 몰라 D2 를 데드코드에만
>    적용해 **측정 자체가 안 됐다.** 패치 대상이 라이브 경로인지 먼저 확인하라.
> 2. **debug 와 release 는 픽셀이 다르다.** 대조군 26종이 바뀐 것처럼 보였는데
>    `A(debug)` vs `A'(release,무패치)` 대조로 전부 빌드 효과였다. **A/B 는 같은 빌드
>    구성끼리만 비교한다.** 부수로 release 에서는 `3363252053` 도 결정이 된다(170/170).
> 3. **도달 산정에 라이트 조건이 빠져 있었다.** `objects[].model` 만 세면 안 된다 —
>    PBR 루프는 라이트가 있어야 돈다.

---

### Task 9: 기준선 재생성과 문서 정리

변경이 끝났으니 **새 기준선**을 뜨고, 무엇이 왜 바뀌었는지 남긴다.

- [ ] **Step 1: release 로 새 기준선 캡처**

```bash
export WAPLE_REAL_PKGS=~/Downloads/wallpaper_dev/backgrounds
export WAPLE_BASE_ASSETS=~/Downloads/wallpaper_dev/assets
LABEL="baseline-$(git rev-parse --short HEAD)"
launchctl asuser $(id -u) env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
  swift run -c release WapleCompat --capture ~/Downloads/waple-baselines --label "$LABEL" \
  ~/Downloads/wallpaper_dev
```

**`-c release` 를 빠뜨리지 마라** — debug 는 2.8배 걸린다.

- [ ] **Step 2: 이전 기준선과 diff 를 정리**

바뀐 씬 목록과 각각의 사유(어느 태스크 때문인지)를 표로 만든다.
**사유를 못 대는 변화가 있으면 그건 회귀다.** 원인을 찾을 때까지 진행하지 않는다.

- [ ] **Step 3: 새 기준선을 커밋하고 이전 것을 이력으로 남긴다**

```bash
cp -R ~/Downloads/waple-baselines/$LABEL spec/golden/snapshot/
git add spec/golden/snapshot/$LABEL
```

`spec/golden/snapshot/README.md` 에 새 기준선 절을 추가하고, 이전 기준선은
**지우지 않는다**(리포 관례: 이력을 남긴다). 어느 것이 현행인지 명시한다.

- [ ] **Step 4: `AGENTS.md` 테스트 기준값 갱신**

"테스트 수 **2,125** 는 고정 기준값이다" 를 새 숫자로 갱신하고,
이 계획에서 몇 개가 늘었는지 적는다.

- [ ] **Step 5: `BACKLOG.md` 정리**

- X-⑤ `g_TexelSize` → **종결**(Task 5)
- F402/F403 골든 미커밋 → **해소**(계획 A + Task 2)
- `SHDV0069` 셰이더 캐시 → **우선순위 강등**(코퍼스 수요 0건)
- ACES 제거 판단 → **확증 완료**
- 새로 드러난 것 추가: `type` 대소문자 혼용, `MDLV0004/0014` 미지원, `.mdl` 레이아웃 변형

- [ ] **Step 6: `README.md` 갱신**

"Shared base assets" 절이 "사용자가 공급해야 한다"고 말하는데 이제 동봉된다.
동봉 사실과 사용자 설치본이 여전히 우선한다는 것을 적는다.

- [ ] **Step 7: 커밋**

```bash
git add spec/golden/snapshot/ AGENTS.md BACKLOG.md README.md docs/
git commit -m "변경 후 기준선 재생성과 문서 정리(바뀐 씬과 사유를 표로 남김)"
```

---

## Self-Review

**1. 스펙 커버리지** — `docs/superpowers/specs/2026-07-31-spec-00-canon-foundation.md` 대비:

| 스펙 항목 | 계획 | 상태 |
| --- | --- | --- |
| §4-3 4단 폴백 | B Task 1 | ✅ |
| §4-4 결손 0건 확인 | B Task 3 | ✅ |
| §6-1 `g_LightAmbientColor` | B Task 7 | ✅ (블라스트 반경 선측정 포함) |
| §6-2 `texRes` 4성분 | B Task 6 | ✅ |
| §6-3 이탈 3건 결정 | B Task 8 | ✅ |
| §7 BACKLOG 정리 | B Task 9 | ✅ |
| §8-2 L3 오라클 강화 | B Task 2 | ✅ |
| §10 1단계 골든 확보 | **계획 A 에서 완료** | ✅ |
| §3 `spec/` 개설 | **계획 A 에서 완료** | ✅ |
| §4-1·4-2 에셋 동봉 | **계획 A 에서 완료** | ✅ |
| §5 텍스처 오라클 | 분해 워크플로로 이관 | 조사 중 |

**2. 플레이스홀더 스캔** — Task 6 Step 4(호출부 전환)와 Task 7 Step 2(유니폼 배선)는
정확한 줄 번호 대신 방법을 적었다. 두 곳 모두 **현재 코드를 읽어야 정확한 위치가 나오는
구조**(`runtimeTexRes` 의 내부 클로저, `engineUniform` 의 배열 오프셋)라, 대신 **무엇을
바꾸고 무엇을 동기해야 하는지**를 명시했다(EngineU 레이아웃 동기 필수 경고 포함).
실행 시 첫 단계로 해당 파일을 읽을 것.

**3. 타입 정합성**
- `BaseAssetsSettings.bundledAssetsDirectory: URL?` — Task 1 정의, Task 3·4 에서 사용 ✅
- `BaseAssetsSettings.searchRoots: [URL]` — Task 1 정의, Task 3(테스트)·4(온보딩) 사용 ✅
- `SceneRenderer.sharedAssetProbe(_:roots:)` — Task 1 정의, Task 3 사용 ✅
- `GoldenBaseline.load(label:)` / `.entry(id:)` — Task 2 정의, Task 2 Step 4 사용 ✅
- `SceneRenderer.texResComponents(allocated:image:)` — Task 6 정의·사용 ✅

**4. 순서 의존** — Task 2(오라클)가 Task 5~7(픽셀 변경)보다 먼저다. 계획 서두와
Global Constraints 에 명시했다.

---

## 실행 조건

**이 계획은 macOS 세션에서만 실행 가능하다.** Windows 에서는 한 줄도 검증되지 않는다.

Mac 세션 1회에 묶어서 처리할 것을 권한다 — Task 1~3(에셋 배선과 오라클)이 한 덩어리고,
Task 5~7(픽셀 변경)이 다음 덩어리다. Task 8 은 사이에 사람의 결정이 필요하다.
