import XCTest
@testable import Waple
import WapleCore

/// 화면보호기 순수 결정 로직 검증 — moduleDict 조립 / 설치 경로 / 대상 동영상 결정.
/// 부수효과(설치/CFPreferences)는 ScreenSaverController 로 분리되어 있어 여기서는 다루지 않는다.
final class ScreenSaverLogicTests: XCTestCase {

    private func project(type: WallpaperType, fileName: String?) -> WallpaperProject {
        WallpaperProject(id: "p1", type: type, fileName: fileName, previewName: nil,
                         title: "t", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/wp"))
    }

    // MARK: - moduleDict 조립(com.apple.screensaver 가 요구하는 형태)

    func testModuleDict_assembly() {
        let d = ScreenSaverLogic.moduleDict(installedPath: "/Users/u/Library/Screen Savers/Waple.saver")
        XCTAssertEqual(d["moduleName"] as? String, "Waple")
        XCTAssertEqual(d["path"] as? String, "/Users/u/Library/Screen Savers/Waple.saver")
        XCTAssertEqual(d["type"] as? Int, 0)
        XCTAssertEqual(d.count, 3, "moduleDict 는 정확히 moduleName/path/type 3개 키")
    }

    // MARK: - 설치 경로

    func testInstallDestination_appendsWapleSaver() {
        let dest = ScreenSaverLogic.installDestination(
            screenSaversDirectory: URL(fileURLWithPath: "/Users/u/Library/Screen Savers"))
        XCTAssertEqual(dest.path, "/Users/u/Library/Screen Savers/Waple.saver")
    }

    // MARK: - 대상 동영상 결정

    func testVideoPath_videoProject_returnsFullPath() {
        XCTAssertEqual(ScreenSaverLogic.videoPath(for: project(type: .video, fileName: "movie.mp4")),
                       "/tmp/wp/movie.mp4")
    }

    func testVideoPath_extensionCaseInsensitive() {
        XCTAssertEqual(ScreenSaverLogic.videoPath(for: project(type: .video, fileName: "MOVIE.MOV")),
                       "/tmp/wp/MOVIE.MOV")
    }

    func testVideoPath_nonVideoType_nil() {
        XCTAssertNil(ScreenSaverLogic.videoPath(for: project(type: .scene, fileName: "movie.mp4")),
                     "scene 배경은 화면보호기 대상이 아니다")
    }

    func testVideoPath_unsupportedContainer_nil() {
        XCTAssertNil(ScreenSaverLogic.videoPath(for: project(type: .video, fileName: "movie.webm")),
                     "webm 은 AVFoundation(saver)이 재생하지 못한다")
    }

    func testVideoPath_missingFileNameOrProject_nil() {
        XCTAssertNil(ScreenSaverLogic.videoPath(for: project(type: .video, fileName: nil)))
        XCTAssertNil(ScreenSaverLogic.videoPath(for: nil))
    }
}
