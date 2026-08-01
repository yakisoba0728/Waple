import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 실측 ground-truth 하네스: 사용자 제공 실제 WE 배경 폴더(기본 ~/Downloads/wallpaper_dev/backgrounds,
/// WAPLE_REAL_PKGS 환경변수로 재지정)를 전수 마운트+캡처한다. 폴더가 없으면 skip — CI 안전.
/// 하드 어서션은 "마운트가 크래시/스로우 없이 되고 PNG 가 나온다"까지만. 효과 번역 성공/폴백 통계는
/// 렌더러의 NSLog 라인(effect via GLSL→MSL translator / translate failed / MSL compile failed / skipped)을
/// 러너 stderr 에서 수집해 판단한다(사람/에이전트가 grep).
/// GT 실행용 스텁: 항상 "정지" — 폴러가 osascript 를 스폰하지 않는다.
struct StoppedNowPlayingProvider: NowPlayingProvider {
    func fetch() -> NowPlayingInfo? { nil }
}

final class RealPackagesGroundTruthTests: XCTestCase {
    func testMountAndCaptureAllRealScenes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let baseURL = URL(fileURLWithPath: base)
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir: \(base)") }
        let outDir = URL(fileURLWithPath: "/tmp/waple_gt")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // S4①(2026-07-27): SnapshotPipeline.pinRenderSettings(WapleCompat --capture 경로)와 달리 이 GT
        // 하네스는 여태 JS Date 를 핀하지 않았다 — engine.timeOfDay/hours 조건부 스크립트를 가진 씬은
        // 테스트를 실행하는 실 벽시계(및 그 순간의 시스템 TZ)에 따라 luma 가 흔들려 luma_baseline.json
        // 드리프트 경고가 "씬은 시간 함수"라는 오분류로 흡수되고 있었다(아래 주석 "하드 fail 은 오탐 위험"
        // 참고 — 실은 우리 하네스가 벽시계를 핀 안 한 게 원인의 일부). SnapshotPipeline.captureEpochMillis 와
        // 동일 상수로 핀(값은 WapleCompat 의존 없이 리터럴 중복 — TextEngineTests 등 기존 관례와 동형).
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        TextScriptEngine.captureDateEpochMillis = 1_704_110_400_000   // 2024-01-01 12:00:00 UTC
        defer { TextScriptEngine.captureDateEpochMillis = oldEpoch }

        // WE base-assets(공유 텍스처 + common_*.h)가 있으면 연결 — common.h 헬퍼 의존 효과까지 실측.
        // env WAPLE_BASE_ASSETS 우선, 기본 ~/Downloads/wallpaper_dev/assets. 테스트 후 원복.
        let assetsPath = ProcessInfo.processInfo.environment["WAPLE_BASE_ASSETS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/assets")
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
            NSLog("%@", "[WapleGT] base-assets: \(assetsPath)")
        }
        defer { BaseAssetsSettings.baseAssetsDirectory = oldBase }

        var mounted = 0, captured = 0, failed: [String] = [], missingCapture: [String] = []
        var lumas: [String: Float] = [:]
        let folders = (try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.pkg").path)
                   || FileManager.default.fileExists(atPath: $0.appendingPathComponent("gifscene.pkg").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            let id = folder.lastPathComponent
            NSLog("%@", "[WapleGT] ===== scene \(id) =====")
            do {
                let project = try ProjectJSONParser.parse(folderURL: folder)
                let r = SceneRenderer()
                // 미디어 씬(media*Changed 소비)이 실제 AppleScript 폴링을 돌리지 않게 스텁 주입(결정적 + TCC 무).
                r.nowPlayingProvider = StoppedNowPlayingProvider()
                try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)), project: project)
                mounted += 1
                // t=6.0: 인트로 페이드(검정 커버 알파 애니 — 실물 3577990983 류)가 끝난 정상상태 캡처.
                // t=0.5 는 다수 씬이 페이드 중이라 preview 파리티가 계통적으로 저평가된다(2026-07-06 실증).
                let urls = r.captureFrames(width: 640, height: 360, times: [6.0], toDir: outDir)
                if let u = urls.first {
                    let dst = outDir.appendingPathComponent("\(id).png")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.moveItem(at: u, to: dst)
                    captured += 1
                    if let l = Self.meanLuma(dst) { lumas[id] = l }
                } else {
                    missingCapture.append(id)
                    NSLog("%@", "[WapleGT] capture MISSING \(id)")
                }
                r.teardown()
            } catch {
                failed.append("\(id): \(error)")
                NSLog("%@", "[WapleGT] mount FAILED \(id): \(error)")
            }
        }
        NSLog("%@", "[WapleGT] SUMMARY mounted=\(mounted)/\(folders.count) captured=\(captured) missingCapture=\(missingCapture) failed=\(failed)")
        // per-scene 평균 luma 기준선 비교(시각 회귀 조기 감지 — 2902406982 백화가 놓쳤던 클래스).
        // 기준선이 없으면 생성. 초과 편차는 경고 로그(씬은 시간 함수라 하드 fail 은 오탐 위험).
        let baseURL2 = outDir.appendingPathComponent("luma_baseline.json")
        if let data = try? Data(contentsOf: baseURL2),
           let base = try? JSONDecoder().decode([String: Float].self, from: data) {
            var drifted: [String] = []
            for (id, l) in lumas {
                if let b = base[id], abs(b - l) > 0.15 {
                    drifted.append("\(id): \(b) → \(l)")
                }
            }
            if !drifted.isEmpty {
                NSLog("%@", "[WapleGT] ⚠️ LUMA DRIFT (기준선 대비 >0.15): \(drifted) — 의도된 변화면 \(baseURL2.path) 삭제로 재생성")
            }
            // 신규 씬은 기준선에 병합
            var merged = base
            for (id, l) in lumas where merged[id] == nil { merged[id] = l }
            if merged.count != base.count, let d = try? JSONEncoder().encode(merged) { try? d.write(to: baseURL2) }
        } else if let d = try? JSONEncoder().encode(lumas) {
            try? d.write(to: baseURL2)
            NSLog("%@", "[WapleGT] luma 기준선 생성: \(baseURL2.path) (\(lumas.count)씬)")
        }
        XCTAssertGreaterThan(mounted, 0, "실측 씬이 하나도 마운트되지 않음")
        XCTAssertEqual(failed.count, 0, "mount 실패: \(failed)")
        XCTAssertEqual(captured, mounted, "캡처 누락: \(missingCapture)")

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
    }

    /// 기준선 대비 평균 luma 허용 편차. 캡처 환경(GPU·드라이버) 차이를 흡수하되
    /// 눈에 보이는 밝기 변화는 잡는 폭. 0.02 는 8비트로 약 5단계다.
    static let lumaDriftTolerance: Double = 0.02

    /// PNG 평균 luma(0..1). 디코드 실패 → nil.
    static func meanLuma(_ url: URL) -> Float? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = min(cg.width, 160), h = min(cg.height, 90)  // 다운샘플로 충분(평균)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Double = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
        }
        return Float(sum / Double(w * h) / 255.0)
    }
}
