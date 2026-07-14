import XCTest
@testable import Waple

final class BaseAssetsWarningGateTests: XCTestCase {
    private enum Diagnostic {
        case scene(Bool)
        case web
        case video
    }

    private enum SwapFailure: Error {
        case mount
    }

    private func sceneDiagnostic(_ diagnostic: Diagnostic) -> Bool? {
        guard case .scene(let missing) = diagnostic else {
            return nil
        }
        return missing
    }

    func testFailedSwapSelfContainedSceneAndNonSceneRenderersDoNotPresent() {
        var gate = BaseAssetsWarningGate()
        var presented: [String] = []
        let failure: Result<[Diagnostic], Error> = .failure(SwapFailure.mount)
        gate.presentIfNeeded(
            after: failure,
            fingerprint: "<automatic>",
            missingRequiredSharedAssets: sceneDiagnostic,
            present: { presented.append($0); return true }
        )

        let noMiss: Result<[Diagnostic], Error> = .success([.scene(false), .web, .video])
        gate.presentIfNeeded(
            after: noMiss,
            fingerprint: "<automatic>",
            missingRequiredSharedAssets: sceneDiagnostic,
            present: { presented.append($0); return true }
        )

        XCTAssertTrue(presented.isEmpty)
    }

    func testMultiMonitorMissPresentsOnceUntilFingerprintChanges() {
        var gate = BaseAssetsWarningGate()
        var presented: [String] = []
        let misses: Result<[Bool], Error> = .success([true, true, false])

        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        XCTAssertEqual(presented, [BaseAssetsWarningGate.message])
        XCTAssertEqual(
            BaseAssetsWarningGate.message,
            "공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요."
        )

        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/b",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        XCTAssertEqual(presented, [BaseAssetsWarningGate.message, BaseAssetsWarningGate.message])
    }

    func testReturningToWarnedFingerprintDoesNotRepresentButNewOneDoes() {
        var gate = BaseAssetsWarningGate()
        var presented: [String] = []
        let miss: Result<[Bool], Error> = .success([true])
        func warn(_ fingerprint: String) {
            gate.presentIfNeeded(
                after: miss,
                fingerprint: fingerprint,
                missingRequiredSharedAssets: { $0 },
                present: { presented.append($0); return true }
            )
        }

        warn("/assets/a")                       // ① A 최초 경고
        warn("/assets/b")                        // ② B(신규)는 다른 fingerprint라 구 로직이 여기서 게이트를 리셋했음
        warn("/assets/a")                        // ③ A 복귀 — 이미 경고했으므로 재경고 없어야 함
        XCTAssertEqual(presented.count, 2, "returning to an already-warned fingerprint must not re-warn")

        warn("/assets/c")                        // ④ C(신규)는 경고함
        XCTAssertEqual(presented.count, 3)
    }

    func testHiddenWindowDoesNotConsumePresentationAllowance() {
        var gate = BaseAssetsWarningGate()
        let miss: Result<[Bool], Error> = .success([true])
        var windowVisible = false
        var notifyCalls = 0
        var bannerCount = 0

        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )
        windowVisible = true
        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )
        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )

        XCTAssertEqual(notifyCalls, 2, "the hidden attempt is retried, then a visible banner consumes the gate")
        XCTAssertEqual(bannerCount, 1)
    }
}
