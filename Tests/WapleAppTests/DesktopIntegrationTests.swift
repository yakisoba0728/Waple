import XCTest
import AppKit
@testable import Waple
import WapleCore
import WapleRender

/// 데스크탑 통합 4건의 순수 로직 검증(창 레벨 / 가림 판정 / 정지 배경 소스·경로).
/// AppDelegate·DesktopWindow 가 이 함수들을 실제로 호출한다(병렬 사본 아님).
final class DesktopIntegrationTests: XCTestCase {

    // MARK: - 작업 1: 창 레벨

    func testDesktopWallpaperLevel_isJustBelowDesktopIcons() {
        let level = WallpaperWindowLevel.desktopWallpaper.rawValue
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        XCTAssertEqual(level, iconLevel - 1, "배경 창은 아이콘 레벨 바로 아래 — 아이콘이 배경 위에 렌더")
    }

    // MARK: - 작업 2: 데스크탑 가림 판정

    private func snap(owner: String = "Google Chrome", pid: Int = 999, layer: Int = 0,
                      alpha: Double = 1, w: Double = 800, h: Double = 600)
        -> DesktopVisibilityMonitor.WindowSnapshot {
        .init(ownerName: owner, processId: pid, layer: layer, alpha: alpha,
              bounds: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func visible(_ windows: [DesktopVisibilityMonitor.WindowSnapshot],
                         screens: [CGRect] = []) -> Bool {
        DesktopVisibilityMonitor.isDesktopVisible(windows: windows, currentProcessId: 1, screenFrames: screens)
    }

    func testOcclusion_bigOpaqueWindowHidesDesktop() {
        XCTAssertFalse(visible([snap()]), "큰 불투명 레이어0 창 → 데스크탑 가림")
    }

    func testOcclusion_ownProcessDoesNotCount() {
        XCTAssertTrue(visible([snap(pid: 1)]), "자기 자신(월페이퍼 창)은 가림 아님")
    }

    func testOcclusion_nonZeroLayerIgnored() {
        XCTAssertTrue(visible([snap(layer: 25)]), "레이어0 아님 → 가림 아님")
    }

    func testOcclusion_nearlyTransparentIgnored() {
        XCTAssertTrue(visible([snap(alpha: 0.02)]), "거의 투명 → 가림 아님")
    }

    func testOcclusion_tinyAreaIgnored() {
        XCTAssertTrue(visible([snap(w: 100, h: 100)]), "면적<=12000 → 가림 아님")
    }

    func testOcclusion_systemUIIgnored() {
        XCTAssertTrue(visible([snap(owner: "Dock")]), "시스템 UI(Dock) → 가림 아님")
    }

    func testOcclusion_smallOverlayIgnored() {
        XCTAssertTrue(visible([snap(w: 240, h: 200)]), "소형 오버레이(최대변<=240) → 가림 아님")
    }

    func testOcclusion_finderDesktopHostIgnored_butBrowserBlocks() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // 디스플레이 전체를 덮는 Finder 창 = 데스크탑 호스트 → 가림 아님.
        XCTAssertTrue(visible([snap(owner: "Finder", w: 1920, h: 1080)], screens: [screen]))
        // 대형이지만 전체보다 작은 Finder 브라우저 창 → 실제로 가린다.
        XCTAssertFalse(visible([snap(owner: "Finder", w: 1000, h: 700)], screens: [screen]))
    }

    // MARK: - 작업 3: 정지 배경 소스·경로

    private func proj(_ type: WallpaperType, file: String? = nil, preview: String? = nil,
                      folder: String = "/lib/x") -> WallpaperProject {
        WallpaperProject(id: "wp1", type: type, fileName: file, previewName: preview,
                         title: "t", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: folder))
    }

    func testStillSource_video_extractsFrame() {
        XCTAssertEqual(StillWallpaper.source(for: proj(.video, file: "a.mp4")),
                       .videoFrame(URL(fileURLWithPath: "/lib/x/a.mp4")))
    }

    func testStillSource_unsupportedVideo_fallsBackToPreview() {
        XCTAssertEqual(StillWallpaper.source(for: proj(.video, file: "a.webm", preview: "preview.gif")),
                       .previewImage(URL(fileURLWithPath: "/lib/x/preview.gif")))
    }

    func testStillSource_scene_capture() {
        XCTAssertEqual(StillWallpaper.source(for: proj(.scene)), .sceneCapture)
    }

    func testStillSource_web_usesPreview() {
        XCTAssertEqual(StillWallpaper.source(for: proj(.web, preview: "preview.jpg")),
                       .previewImage(URL(fileURLWithPath: "/lib/x/preview.jpg")))
    }

    func testStillSource_webNoPreview_nil() {
        XCTAssertNil(StillWallpaper.source(for: proj(.web)), "preview 없는 웹 → 소스 없음")
    }

    func testStillOutputURL_sanitizesId() {
        let out = StillWallpaper.outputURL(projectId: "abc 123!", stillDir: URL(fileURLWithPath: "/s"))
        XCTAssertEqual(out, URL(fileURLWithPath: "/s/abc-123.png"))
    }
}
