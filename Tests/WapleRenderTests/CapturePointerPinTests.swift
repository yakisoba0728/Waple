import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 캡처 포인터 핀 회귀(2026-08-02 — spec/golden/nondeterminism.json → oracle.nondet.rootCause).
///
/// `mount` 는 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜는데, `ParallaxController.start()`
/// 는 곧바로 `emit()` 해서 **그 순간의 실제 커서 위치**(NSEvent.mouseLocation)를 `pointerUV` =
/// 이펙트 유니폼 `g_PointerPosition` 으로 밀어 넣는다. 캡처 하네스는 시각·오디오·난수·fitMode 는
/// 핀하면서 포인터만 안 핀했고, 그래서 전 코퍼스 170종 중 **29종이 세션마다 다른 픽셀**을 냈다
/// (커서가 이전 위치로 돌아오면 이전 값이 통째로 재현됐다). `pause()` 는 모니터를 멈추지만 이미
/// 들어온 값은 되돌리지 않으므로, 고칠 곳은 "멈추기" 가 아니라 "켜지 않기" 다.
final class CapturePointerPinTests: XCTestCase {
    private let model = #"{"width":100,"height":100,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"textures":["pic"]}]}"#
    /// 이펙트 보유 씬 — hasEffects 가 참이라야 마운트가 마우스 모니터 경로를 탄다.
    private let scene = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
       "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
         "constantshadervalues":{"color":"1 0 0","alpha":1}}]}]}]}
    """

    private func mountFixture(tag: String) throws -> SceneRenderer {
        let pkgData = encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(model.utf8)),
            ("materials/m.json", Data(material.utf8)),
            ("materials/pic.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_ptrpin_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkgData.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        return r
    }

    /// 핀이 걸려 있으면 마운트가 라이브 커서를 **읽지 않는다**.
    /// 핀 값은 실제 커서로는 사실상 나올 수 없는 좌표라, 모니터가 켜지면 emit() 이 즉시 덮어써 실패한다
    /// (음성 대조: 이 테스트를 SceneRenderer 의 핀 분기를 지우고 돌리면 커서 위치 값으로 바뀌어 깨진다).
    func testPinnedPointerIsNotOverwrittenByLiveCursor() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let old = SceneRenderer.capturePointerUV
        defer { SceneRenderer.capturePointerUV = old }
        let pinned = SIMD2<Float>(0.123, 0.456)
        SceneRenderer.capturePointerUV = pinned

        let r = try mountFixture(tag: "pinned")
        defer { r.teardown() }
        XCTAssertEqual(r.pointerUV.x, pinned.x, accuracy: 1e-6, "마운트가 핀 포인터를 덮어썼다")
        XCTAssertEqual(r.pointerUV.y, pinned.y, accuracy: 1e-6, "마운트가 핀 포인터를 덮어썼다")
        XCTAssertEqual(r.pointerUVLast.x, pinned.x, accuracy: 1e-6, "직전 프레임 포인터도 핀 값이어야")
        XCTAssertEqual(r.pointerUVLast.y, pinned.y, accuracy: 1e-6, "직전 프레임 포인터도 핀 값이어야")
    }

    /// 핀이 없으면 종전 동작(라이브 커서 배선) — 마운트 경로가 깨지지 않는지만 확인한다.
    /// 실제 좌표는 기계의 커서 위치라 단언하지 않는다(그 값이 캡처에 새는 것이 바로 이 항목의 결함).
    func testUnpinnedMountStillWires() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let old = SceneRenderer.capturePointerUV
        defer { SceneRenderer.capturePointerUV = old }
        SceneRenderer.capturePointerUV = nil

        let r = try mountFixture(tag: "unpinned")
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertTrue((0...1).contains(r.pointerUV.x) && (0...1).contains(r.pointerUV.y),
                      "포인터 UV 는 0..1 정규화 범위여야")
    }

    /// 미디어 훅 보유 씬 — 컬러 스크립트가 mediaPlaybackChanged 를 export 해
    /// startMediaPollingIfNeeded 의 시작 조건(eventEngines 훅 검사 — SceneRenderer.swift:917)을
    /// 만족하게 한다(실물 ColorTinter 패턴 — SceneInteractionMediaE2ETests 와 같은 배선).
    private func mountMediaFixture(tag: String) throws -> SceneRenderer {
        let js = "'use strict';\\nexport function update(){ return new Vec3(1,1,1); }\\nexport function mediaPlaybackChanged(event){}\\n"
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "color":{"value":"1 1 1","script":"\(js)"}}]}
        """
        let pkgData = encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(model.utf8)),
            ("materials/m.json", Data(material.utf8)),
            ("materials/pic.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_ptrpin_media_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkgData.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        // 실물 AppleScriptNowPlayingProvider 대신 항상 nil 프로바이더(SnapshotPipeline.StoppedNowPlaying
        // 과 동일 역할 — CompatCore 전용 타입이라 테스트에서 재정의) — 폴러가 켜져도 osascript 기동이 없다.
        r.nowPlayingProvider = StoppedProvider()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        return r
    }

    private struct StoppedProvider: NowPlayingProvider {
        func fetch() -> NowPlayingInfo? { nil }
    }

    /// [2026-08-25] 스틸 캡처 경로용 검증(렌더러 측 절반) — **핀이 걸린 마운트는 미디어 폴러도
    /// 시작하지 않는다.** AppDelegate.captureSceneStill 자체는 앱 타깃 private 라 여기서 직접 부를 수
    /// 없어(구조상 한계), 그 경로가 쓰는 계약 "핀 = 라이브 모니터 0개" 을 렌더러 수준에서 검증한다.
    /// 시차 모니터 쪽 절반은 위 testPinnedPointerIsNotOverwrittenByLiveCursor 가 담당한다.
    /// 근거: MediaPoller.start() 는 등록 직후 t.fire() 로 즉시 첫 폴을 돌리므로(MediaPoller.swift:40)
    /// "5초 주기라 캡처 동안 안 불린다" 는 방어는 성립하지 않았다(BACKLOG 잠재 결함).
    func testPinnedMountDoesNotStartMediaPoller() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let old = SceneRenderer.capturePointerUV
        defer { SceneRenderer.capturePointerUV = old }
        SceneRenderer.capturePointerUV = SIMD2<Float>(0.5, 0.5)

        let r = try mountMediaFixture(tag: "poller_pinned")
        defer { r.teardown() }
        XCTAssertNil(r.mediaPoller, "핀 걸린(캡처) 인스턴스는 미디어 폴러를 시작하지 않아야")
    }

    /// 음성 대조 — 같은 씬이라도 핀이 없으면 폴러가 실제로 켜진다. 이 대조가 없으면 위 테스트는
    /// 픽스처가 시작 조건을 아예 못 만나는 공집합 통과일 수 있다(음성 대조 규약은
    /// testPinnedPointerIsNotOverwrittenByLiveCursor 주석과 같다).
    func testUnpinnedMountStillStartsMediaPoller() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let old = SceneRenderer.capturePointerUV
        defer { SceneRenderer.capturePointerUV = old }
        SceneRenderer.capturePointerUV = nil

        let r = try mountMediaFixture(tag: "poller_unpinned")
        defer { r.teardown() }
        XCTAssertTrue(r.mediaPoller?.isRunningForTesting == true,
                      "무핀 마운트는 종전대로 미디어 폴러를 켜야")
    }
}
