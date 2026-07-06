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

    // MARK: - enable 시 사용자 원본 화면보호기 백업 판정
    // (disable 이 무조건 제거해 사용자의 원래 화면보호기를 잃던 회귀의 방지선)

    func testShouldBackup_userSaver_true() {
        // 사용자가 고른 다른 화면보호기 → 백업해야 disable 시 원복 가능.
        XCTAssertTrue(ScreenSaverLogic.shouldBackup(current: ["moduleName": "Flurry", "path": "/x", "type": 0]))
    }

    func testShouldBackup_alreadyWaple_false() {
        // 이미 Waple(재활성) → 첫 enable 때 만든 원본 백업을 덮어쓰면 안 됨.
        XCTAssertFalse(ScreenSaverLogic.shouldBackup(current: ["moduleName": ScreenSaverLogic.saverName]))
    }

    func testShouldBackup_noSelection_false() {
        // 선택 없음 → disable 의 복원(=제거)이 원상("없음")복구이므로 백업 불필요.
        XCTAssertFalse(ScreenSaverLogic.shouldBackup(current: nil))
    }

    func testShouldBackup_malformedDict_true() {
        // moduleName 없는 비정상 dict 도 데이터 보존 차원에서 백업(원복 시 그대로 되돌림).
        XCTAssertTrue(ScreenSaverLogic.shouldBackup(current: ["path": "/x"]))
    }
}
