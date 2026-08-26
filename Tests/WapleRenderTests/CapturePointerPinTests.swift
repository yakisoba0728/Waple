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
///
/// [2026-08-26] **핀이 프로세스 전역 `static` 에서 인스턴스 프로퍼티로 내려왔다.**
/// 그래서 이 파일의 단언들도 "전역을 걸고 아무 인스턴스나 본다" 에서 "이 인스턴스에 걸고
/// 이 인스턴스를 본다" 로 바뀌었다. 근거는 `SceneRenderer` 클래스 선언의 [2026-08-26 정정] 문단.
/// 같은 라운드에서 **없던 오라클 둘**을 더했다:
/// ① 캡처 인스턴스는 **클릭 모니터도** 안 켠다(종전 게이트는 포인터·미디어폴러 둘뿐이었다).
/// ② **남의 캡처가 진행 중이어도 라이브 인스턴스는 자기 포인터 모니터를 켠다** — 전역 핀 시절
///    라이브 씬이 남의 핀을 흡수해 커서 반응이 죽던 결함이고, **이걸 잡는 테스트가 없어서**
///    2026-08-25 라운드의 감사를 그대로 통과했다.
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

    /// `pin` 은 **인스턴스** 핀이다(2026-08-26 — 종전엔 호출부가 전역 static 을 걸었다).
    /// 캡처 하네스가 하는 것과 같은 순서로 건다: 생성 직후, `mount` 전.
    private func mountFixture(tag: String, pin: SIMD2<Float>?) throws -> SceneRenderer {
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
        r.capturePointerUV = pin
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        return r
    }

    /// 핀이 걸려 있으면 마운트가 라이브 커서를 **읽지 않는다**.
    /// 핀 값은 실제 커서로는 사실상 나올 수 없는 좌표라, 모니터가 켜지면 emit() 이 즉시 덮어써 실패한다
    /// (음성 대조: 이 테스트를 SceneRenderer 의 핀 분기를 지우고 돌리면 커서 위치 값으로 바뀌어 깨진다).
    func testPinnedPointerIsNotOverwrittenByLiveCursor() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let pinned = SIMD2<Float>(0.123, 0.456)

        let r = try mountFixture(tag: "pinned", pin: pinned)
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
        let r = try mountFixture(tag: "unpinned", pin: nil)
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertTrue((0...1).contains(r.pointerUV.x) && (0...1).contains(r.pointerUV.y),
                      "포인터 UV 는 0..1 정규화 범위여야")
    }

    /// 미디어 훅 보유 씬 — 컬러 스크립트가 mediaPlaybackChanged 를 export 해
    /// startMediaPollingIfNeeded 의 시작 조건(eventEngines 훅 검사 — SceneRenderer.swift:977)을
    /// 만족하게 한다(실물 ColorTinter 패턴 — SceneInteractionMediaE2ETests 와 같은 배선).
    private func mountMediaFixture(tag: String, pin: SIMD2<Float>?) throws -> SceneRenderer {
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
        r.capturePointerUV = pin
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
        let r = try mountMediaFixture(tag: "poller_pinned", pin: SIMD2<Float>(0.5, 0.5))
        defer { r.teardown() }
        XCTAssertNil(r.mediaPoller, "핀 걸린(캡처) 인스턴스는 미디어 폴러를 시작하지 않아야")
    }

    /// 음성 대조 — 같은 씬이라도 핀이 없으면 폴러가 실제로 켜진다. 이 대조가 없으면 위 테스트는
    /// 픽스처가 시작 조건을 아예 못 만나는 공집합 통과일 수 있다(음성 대조 규약은
    /// testPinnedPointerIsNotOverwrittenByLiveCursor 주석과 같다).
    func testUnpinnedMountStillStartsMediaPoller() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let r = try mountMediaFixture(tag: "poller_unpinned", pin: nil)
        defer { r.teardown() }
        XCTAssertTrue(r.mediaPoller?.isRunningForTesting == true,
                      "무핀 마운트는 종전대로 미디어 폴러를 켜야")
    }

    /// [2026-08-26] **캡처 인스턴스는 클릭 모니터도 켜지 않는다** — 이번 라운드가 메운 게이트.
    ///
    /// 2026-08-25 라운드는 포인터·미디어폴러 둘만 막고 `startClickMonitorIfNeeded`(SceneRenderer.swift:878)
    /// 를 빠뜨렸는데, 그 함수의 가드는 `clickMonitor == nil` 하나뿐이라 **캡처 인스턴스에도 무조건
    /// 설치됐다**. 콜백 `deliverGlobalMouse` 는 창 가드(`pointerSceneCoords()`)보다 **먼저**
    /// `pointerButton.setDown` 을 실행하므로, 캡처가 도는 동안의 물리 클릭이 `g_PointerState.z`
    /// 임펄스로 캡처 프레임에 구워질 수 있었다(BACKLOG "캡처 경로 잔여 갭 2건" ①).
    /// 골든 픽셀 방향은 **순감**이다 — 클릭이 없던 캡처는 종전과 같은 픽셀이고, 클릭이 있던 캡처만
    /// 오염이 사라진다.
    func testPinnedMountDoesNotStartClickMonitor() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let r = try mountFixture(tag: "click_pinned", pin: SIMD2<Float>(0.5, 0.5))
        defer { r.teardown() }
        XCTAssertNil(r.clickMonitor, "핀 걸린(캡처) 인스턴스는 전역 클릭 모니터를 설치하지 않아야")
    }

    /// 음성 대조 — 같은 씬이라도 핀이 없으면 클릭 모니터가 실제로 설치된다. 이게 없으면 위 테스트는
    /// "이 환경에서는 애초에 전역 모니터가 안 만들어진다" 로도 통과하는 공집합 단언이다.
    ///
    /// 그 공집합 가능성이 실재하므로 **환경을 먼저 재고 안 되면 원인을 말하며 스킵**한다
    /// (AGENTS.md 「함정」의 `skipUnlessAudioOutputCanPlay` 와 같은 방식 — 환경 결함을 코드 결함으로
    /// 오인시키지 않는다). `NSEvent.addGlobalMonitorForEvents` 는 만들 수 없으면 nil 을 돌려준다.
    func testUnpinnedMountStartsClickMonitor() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        guard let probe = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { _ in }) else {
            throw XCTSkip("이 환경은 전역 마우스 모니터를 만들지 못한다 — 음성 대조 불가")
        }
        NSEvent.removeMonitor(probe)

        let r = try mountFixture(tag: "click_unpinned", pin: nil)
        defer { r.teardown() }
        XCTAssertNotNil(r.clickMonitor, "무핀 마운트는 종전대로 전역 클릭 모니터를 설치해야")
    }

    /// [2026-08-26] **이 회귀에는 테스트가 없었다.** 그래서 2026-08-25 라운드가 "해소" 를 선언하고도
    /// 살아남았다.
    ///
    /// 핀이 프로세스 전역 `static` 이던 동안, 핀은 "이 인스턴스는 캡처다" 가 아니라 "이 **프로세스**가
    /// 캡처 중이다" 를 뜻했다. 캡처는 무거운 씬이면 수 초가 걸리고 그동안 마운트되는 **라이브** 씬은
    /// `!= nil` 을 보고 자기 포인터 모니터를 조용히 건너뛴다 — 그 배경의 커서 반응이 다음 재마운트까지
    /// 죽는다. `desktopStillSync` 가 적용마다 3초 뒤 캡처를 돌리므로 드문 경로가 아니었다.
    ///
    /// 관측점은 `parallax.onOffset` 이다 — `startPointerMonitor`(SceneRenderer.swift:2217)가 핀 게이트를
    /// 통과했을 때만 이 클로저를 대입한다. AppKit 전역 모니터 생성 가능 여부와 무관해서
    /// (`ParallaxController.start()` 는 모니터가 nil 이어도 그 앞에서 대입이 끝난다) 환경에 걸리지 않는다.
    func testLiveMountDuringAnotherInstanceCaptureKeepsItsPointerMonitor() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        // 캡처 인스턴스를 **살려 둔 채로** 라이브를 마운트한다 — teardown 을 미뤄 "캡처가 진행 중" 을 만든다.
        let capture = try mountFixture(tag: "concurrent_capture", pin: SIMD2<Float>(0.5, 0.5))
        defer { capture.teardown() }
        XCTAssertTrue(capture.parallax.onOffset == nil, "캡처 인스턴스는 포인터 모니터를 켜지 않아야(전제 확인)")

        let live = try mountFixture(tag: "concurrent_live", pin: nil)
        defer { live.teardown() }
        XCTAssertFalse(live.parallax.onOffset == nil,
                       "남의 캡처가 진행 중이어도 라이브 인스턴스는 자기 포인터 모니터를 켜야 "
                       + "(전역 핀 시절 이 자리에서 커서 반응이 죽었다)")
        XCTAssertTrue(live.capturePointerUV == nil, "라이브 인스턴스의 핀은 비어 있어야 — 핀은 인스턴스 소유다")
        XCTAssertEqual(capture.pointerUV.x, 0.5, accuracy: 1e-6,
                       "라이브 마운트가 캡처 인스턴스의 핀 포인터를 건드리면 안 된다")
        XCTAssertEqual(capture.pointerUV.y, 0.5, accuracy: 1e-6,
                       "라이브 마운트가 캡처 인스턴스의 핀 포인터를 건드리면 안 된다")
    }
}
