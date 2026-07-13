import XCTest
@testable import Waple

/// 설정 창 표시용 순수 카탈로그/상태 판정 — 스텝 값이 기존 트레이 메뉴 값과 동일함을 고정한다.
final class SettingsPresentationTests: XCTestCase {

    func testVolumeAndRateStepsMatchLegacyTrayValues() {
        XCTAssertEqual(SettingsPresentation.volumeSteps.map(\.value), [0, 0.25, 0.5, 0.75, 1],
                       "기존 트레이 음소거/25/50/75/100% 와 동일해야 저장값 호환")
        XCTAssertEqual(SettingsPresentation.rateSteps.map(\.value), [0.5, 1, 1.5, 2])
        XCTAssertEqual(SettingsPresentation.playlistIntervalMinutes, [5, 15, 30, 60])
        for s in SettingsPresentation.volumeSteps + SettingsPresentation.rateSteps {
            XCTAssertFalse(s.label.isEmpty)
        }
    }

    func testOcclusionOptionsMatchLegacyMenu() {
        XCTAssertEqual(SettingsPresentation.occlusionOptions.map(\.raw), [-1, 0, 0.30, 0.50, 0.80],
                       "트레이 서브메뉴(사용 안 함/즉시/30/50/80%)에서 그대로 이관")
    }

    func testCurrentOcclusionRawRoundTripsEachOption() {
        for option in SettingsPresentation.occlusionOptions {
            let (enabled, threshold) = OcclusionMode.decode(option.raw)
            XCTAssertEqual(SettingsPresentation.currentOcclusionRaw(enabled: enabled, threshold: threshold),
                           option.raw, "옵션 \(option.label) 저장 → 역산 왕복")
        }
    }

    func testCurrentOcclusionRawFallsBackToOffForUnknownThreshold() {
        // 임계값은 옵션으로만 저장되므로 실사용 불가 경로 — 방어 폴백만 고정한다.
        XCTAssertEqual(SettingsPresentation.currentOcclusionRaw(enabled: true, threshold: 0.33), -1)
    }

    func testSaverStatus() {
        let dev = SettingsPresentation.saverStatus(bundled: false, selected: false)
        XCTAssertFalse(dev.canToggle, "번들에 .saver 없으면(개발 실행) 토글 불가")
        XCTAssertTrue(dev.label.contains("package-app"), "패키징 안내 포함")
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: true).canToggle)
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: true).label.contains("사용 중"))
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: false).canToggle)
    }

    func testFFmpegStatus() {
        XCTAssertTrue(SettingsPresentation.ffmpegStatus(available: true, path: "/opt/homebrew/bin/ffmpeg")
            .contains("/opt/homebrew/bin/ffmpeg"))
        XCTAssertTrue(SettingsPresentation.ffmpegStatus(available: false, path: nil).contains("brew install ffmpeg"))
    }
}
