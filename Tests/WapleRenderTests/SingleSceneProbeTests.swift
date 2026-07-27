import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 단일 실물 씬 프로브(회귀 분리용): WAPLE_PROBE_ID 지정 씬만 마운트+캡처하고 luma 를 로그.
/// GT 전수 대비 빠른 A/B 판정(드리프트 원인 이분). WAPLE_PROBE_ID 미지정 시 skip.
final class SingleSceneProbeTests: XCTestCase {
    func testProbeSingleScene() throws {
        guard let id = ProcessInfo.processInfo.environment["WAPLE_PROBE_ID"] else { throw XCTSkip("set WAPLE_PROBE_ID") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 형제 하네스와 같은 WAPLE_REAL_PKGS/WAPLE_BASE_ASSETS 오버라이드 관례(F408 통일).
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("no scene \(id)") }
        let assetsPath = ProcessInfo.processInfo.environment["WAPLE_BASE_ASSETS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/assets")
        // F409: BaseAssetsSettings.baseAssetsDirectory 는 UserDefaults.standard 에 영속되는 프로세스
        // 전역 static — 복원 없이 바꾸면 개발자 실앱 설정에 영구 기록되고 동일 프로세스(swift test)의
        // 후속 테스트로 누수된다. 형제 하네스(RealPackagesGroundTruthTests/ForwardLightingGateProbeTests)
        // 는 이미 oldBase 저장+defer 복원을 쓴다 — 이 테스트만 비대칭이었다.
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        defer { BaseAssetsSettings.baseAssetsDirectory = oldBase }
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        // S4①(2026-07-27): 이 프로브는 코드 변경 A/B(두 태그를 뒤이어 캡처해 diff)가 주 용도인데, JS Date 를
        // 핀하지 않으면 hours 조건부/timeOfDay 씬은 두 캡처 사이에 흐른 실제 벽시계 시간(및 그 순간의 시스템
        // TZ)만으로도 픽셀이 갈려 코드 변경 유무와 무관한 diff 를 낼 수 있었다 — SnapshotPipeline 과 동일
        // 상수로 핀(WAPLE_PROBE_EPOCH_MS 로 다른 순간을 의도적으로 프로브하고 싶을 때만 재지정).
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        let epoch = Double(ProcessInfo.processInfo.environment["WAPLE_PROBE_EPOCH_MS"] ?? "") ?? 1_704_110_400_000
        TextScriptEngine.captureDateEpochMillis = epoch
        defer { TextScriptEngine.captureDateEpochMillis = oldEpoch }
        let out = URL(fileURLWithPath: "/tmp/waple_probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let project = try ProjectJSONParser.parse(folderURL: folder)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)), project: project)
        let time = Float(ProcessInfo.processInfo.environment["WAPLE_PROBE_TIME"] ?? "") ?? 6.0
        // 골든 대조용 고해상 오버라이드(WAPLE_THUMB_W/H) — 미지정 시 640×360.
        let capW = ProcessInfo.processInfo.environment["WAPLE_THUMB_W"].flatMap(Int.init) ?? 640
        let capH = ProcessInfo.processInfo.environment["WAPLE_THUMB_H"].flatMap(Int.init) ?? 360
        // WAPLE_PROBE_SETTLE=n: 컨트롤러 체인(shared 사이드이펙트) 정착용 선행 프레임 n개(라이브 동형).
        let settle = Int(ProcessInfo.processInfo.environment["WAPLE_PROBE_SETTLE"] ?? "") ?? 0
        let times = (settle > 0 ? (1...settle).map { time - Float($0) * 0.1 }.reversed() + [time] : [time])
        let urls = r.captureFrames(width: capW, height: capH, times: Array(times), toDir: out)
        for u in urls {
            let tag = ProcessInfo.processInfo.environment["WAPLE_PROBE_TAG"] ?? "probe"
            let dst = out.appendingPathComponent("\(id)_\(tag).png")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: u, to: dst)
            let l = RealPackagesGroundTruthTests.meanLuma(dst) ?? -1
            NSLog("%@", "[Probe] \(id) luma=\(l) \(dst.path)")
        }
        r.teardown()
    }
}
