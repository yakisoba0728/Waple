import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender
import WapleSnapshot

/// 캡처 하네스의 **오디오 축 결정성**(BACKLOG "캡처 경로 잔여 갭" ②, 2026-08-27).
///
/// ## 무엇이 갈려 있었나
///
/// 이 리포에는 씬을 오프스크린으로 뜨는 하네스가 셋이다:
///
/// | 하네스 | 마운트 직후 |
/// |---|---|
/// | `SnapshotPipeline.captureFrame`(골든 CLI) | `pause()` + `setSpectrum(.silent)` |
/// | `ProfilePipeline.runProfile` | `pause()` + `setSpectrum(.silent)` |
/// | `AppDelegate.captureSceneStill`(앱 스틸) | **둘 다 없었다** |
///
/// 백로그는 그 차이를 "오디오 반응 씬 스틸이 그 순간의 스펙트럼을 구워서 매번 다른 이미지를
/// 낸다" 로 적어 뒀다. **실측하면 과대평가다** — 현행 코드에서 그 증상은 도달 불가다:
///
///  ① `SceneRenderer.currentSpectrum` 의 선언 초기값이 `.silent`(SceneRenderer.swift:1385).
///  ② `setSpectrum*` 밖에서 그 값을 쓰는 자리는 `SystemAudioSpectrumProvider.onFrame` 두 줄뿐
///     (:2170·:2178).
///  ③ 그 공급자는 `mount` 의 `if hasAudio, container.window != nil`(:2151) 안에서만 생긴다 —
///     두 캡처 하네스 모두 창에 안 들어가는 오프스크린 `NSView` 를 쓰므로 항상 건너뛴다.
///
/// 즉 실효 게이트는 "창 유무" **하나**이고, 세 하네스의 `pause()`/`setSpectrum(.silent)` 는
/// 프레시 헤드리스 인스턴스에서 전부 no-op 이다(그 두 줄이 먼저 쓰였고 `window != nil` 게이트는
/// 나중에 생겼다 — F833·E1⑦). 갈린 것은 픽셀이 아니라 **하네스의 모양**이었다.
///
/// ## 그래서 이 파일이 재는 것
///
/// 위 ①~③ 은 읽어서 아는 사실이라 언제든 조용히 무너질 수 있다(누가 캡처를 창 있는 컨테이너로
/// 옮기거나, 초기값을 바꾸거나). 여기서는 그 **결과**를 오라클로 못 박는다 —
/// "앱 스틸 시퀀스와 골든 시퀀스는 같은 픽셀을 낸다", 그리고 그 단언이 공집합이 아니라는
/// 증거로 "스펙트럼이 실제로 새면 그림이 눈에 띄게 달라진다" 를 같이 잰다.
///
/// `AppDelegate.captureSceneStill` 자체는 앱 타깃 private 라 여기서 못 부른다 —
/// `CapturePointerPinTests:120` 과 같은 구조적 한계이고, 그래서 그 함수가 쓰는 계약을
/// 렌더러 수준에서 같은 순서로 재현해 검증한다.
final class CaptureAudioDeterminismTests: XCTestCase {

    /// 어두운 파랑 바닥(오디오 무관) 위에 흰색 풀스크린 레이어 + pulse(AUDIOPROCESSING=3,
    /// PULSEALPHA). 무음이면 흰 레이어 alpha 0 → 바닥만 보이고(luma ≈ 0.10), 최대면 흰색이
    /// 덮는다(luma → 1). pulse 배선은 `SceneAudioRenderTests.testPulseAlphaRespondsToSpectrum`
    /// 과 같다(그 테스트가 CI 초록이므로 **이 픽스처가 스펙트럼에 반응한다는 것은 이미 실측돼 있다**).
    ///
    /// 바닥을 깐 것은 **의도적**이다. pulse 단독 씬은 무음에서 프레임이 거의 검게 나오는데,
    /// 그러면 "무음이라 검다" 와 "렌더가 아예 안 됐다" 가 구분되지 않아 하네스 대조가 사실상
    /// 빈 프레임 두 장을 비교하는 꼴이 된다(`SyntheticPixelGoldenTests` 의 검은-프레임 경고와
    /// 같은 함정). 바닥은 무음 프레임에도 내용을 주고, 무음↔최대 luma 격차도 크게 벌린다.
    private static let scene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
     "objects":[
       {"id":1,"image":"models/base.json","origin":"960 540 0","size":"1920 1080"},
       {"id":2,"image":"models/pulse.json","origin":"960 540 0","size":"1920 1080",
        "effects":[{"file":"effects/pulse/effect.json","passes":[{
           "combos":{"AUDIOPROCESSING":3,"PULSEALPHA":1,"PULSECOLOR":0},
           "constantshadervalues":{"audiobounds":"0 1","audioamount":1}}]}]}]}
    """

    private static let width = 160
    private static let height = 90

    /// `AppDelegate.captureSceneStill` 이 하는 것과 **같은 순서**로 캡처 인스턴스를 만든다:
    /// 생성 → 포인터 핀 → 오프스크린 컨테이너 마운트. 핀 값 `(0.5, 0.5)` 도 그 함수 그대로다.
    private func mountCaptureInstance(tag: String) throws -> (SceneRenderer, NSView) {
        let pkg = encodePkg([
            ("scene.json", Data(Self.scene.utf8)),
            ("models/base.json", #"{"material":"materials/base.json"}"#.data(using: .utf8)!),
            ("materials/base.json", #"{"passes":[{"textures":["base"]}]}"#.data(using: .utf8)!),
            ("materials/base.tex", solidTex(20, 20, 60)),
            ("models/pulse.json", #"{"material":"materials/pulse.json"}"#.data(using: .utf8)!),
            ("materials/pulse.json", #"{"passes":[{"textures":["white"]}]}"#.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_capaudio_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let r = SceneRenderer()
        r.capturePointerUV = SIMD2<Float>(0.5, 0.5)
        try r.mount(in: container, project: project)
        return (r, container)
    }

    private func captureRGBA(_ r: SceneRenderer, tag: String) throws -> [UInt8] {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_capaudio_out_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: Self.width, height: Self.height, times: [1.0], toDir: out)
        return try Self.rgba(ofPNGAt: try XCTUnwrap(urls.first, "\(tag): captureFrames 가 아무것도 내지 않았다"))
    }

    /// PNG → 패딩 없는 RGBA8. `NSBitmapImageRep.bitmapData` 를 그대로 쓰지 않는 이유는
    /// bytesPerRow 정렬 패딩이 폭×4 가정을 깨기 때문이다(`SyntheticPixelGoldenTests` 와 같은 규약).
    private static func rgba(ofPNGAt url: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: url)
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            throw NSError(domain: "CaptureAudioDeterminism", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "PNG 디코드 실패: \(url.lastPathComponent)",
            ])
        }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw NSError(domain: "CaptureAudioDeterminism", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext 생성 실패"])
        }
        return px
    }

    // MARK: - 오라클

    /// **캡처 인스턴스에는 라이브 스펙트럼 공급원이 아예 없다.**
    ///
    /// `mount` 의 오디오 게이트(`SceneRenderer.swift:2151`)는 `hasAudio` 와
    /// `container.window != nil` 둘 다 요구한다. 캡처 컨테이너는 어떤 창에도 안 들어가므로
    /// 두 번째가 항상 거짓이고, 그래서 `SystemAudioSpectrumProvider` 가 만들어지지 않는다 —
    /// `currentSpectrum` 을 선언 초기값 `.silent` 에서 움직일 수 있는 유일한 주체가 없다는 뜻이다.
    ///
    /// 이 단언이 깨지는 날은 캡처 경로가 창 있는 컨테이너로 옮겨졌거나 게이트가 느슨해진
    /// 날이고, 그때는 `pause()`/`setSpectrum(.silent)` 가 no-op 이 아니게 된다.
    func testCaptureInstanceHasNoLiveSpectrumSource() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let (r, container) = try mountCaptureInstance(tag: "src")
        defer { r.teardown() }
        XCTAssertNil(container.window, "캡처 컨테이너는 창에 속하지 않아야 — mount 오디오 게이트의 전제")
        XCTAssertNil(r.audioProvider, "캡처(헤드리스) 인스턴스는 시스템 오디오 스펙트럼 공급자를 만들지 않아야")
        XCTAssertEqual(r.currentSpectrum, AudioSpectrum16.silent,
                       "마운트만으로 스펙트럼이 무음에서 움직였다 — 라이브 값이 캡처로 새는 경로가 생겼다")
        // `hasAudio` 는 **단언하지 않고 기록만** 한다. 이 픽스처의 승격은 이펙트 해석 경로
        // (번역기 `usesAudio` / 손포팅 `audioParams`)에 달려 있어 여기서 재는 계약이 아니다 —
        // 위 두 단언은 `hasAudio` 가 무엇이든 성립해야 하는 것들이다.
        NSLog("%@", "[Waple] capture-audio: hasAudio=\(r.hasAudio) spectrum=\(r.currentSpectrum == .silent ? "silent" : "非silent")")
    }

    /// **앱 스틸 시퀀스 ≡ 골든 시퀀스** — 같은 씬을 두 하네스 순서로 뜨면 픽셀이 같아야 한다.
    ///
    /// A = 종전 `captureSceneStill`(마운트 → 캡처). B = 골든 하네스(마운트 → `pause()` →
    /// `setSpectrum(.silent)` → 캡처). 이 등식이 백로그 ② 가 걱정한 바로 그것이고,
    /// 오늘 참인 이유는 위 `testCaptureInstanceHasNoLiveSpectrumSource` 의 두 단언이다.
    func testStillHarnessSequenceMatchesGoldenHarnessSequence() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }

        let (a, _) = try mountCaptureInstance(tag: "still")
        defer { a.teardown() }
        let stillPixels = try captureRGBA(a, tag: "still")

        let (b, _) = try mountCaptureInstance(tag: "golden")
        defer { b.teardown() }
        b.pause()                    // 골든 하네스 순서 그대로(SnapshotPipeline.captureFrame:157-158)
        b.setSpectrum(.silent)
        let goldenPixels = try captureRGBA(b, tag: "golden")

        // 빈 프레임 두 장을 비교하고 초록을 받는 것을 먼저 막는다(검은-프레임 함정).
        XCTAssertGreaterThan(meanLuma(rgba: stillPixels), 0.02,
                             "사실상 검은 프레임 — 씬이 렌더되지 않았다면 아래 대조는 아무것도 재지 않는다")

        let m = diffRGBA(stillPixels, goldenPixels)
        NSLog("%@", "[Waple] capture-audio 하네스 대조: meanAbsDiff=\(m.meanAbsDiff) fracExceeding=\(m.fracExceeding)")
        XCTAssertTrue(passes(m, .strict),
                      "앱 스틸 시퀀스와 골든 시퀀스의 픽셀이 갈렸다 "
                      + "(meanAbsDiff=\(m.meanAbsDiff) fracExceeding=\(m.fracExceeding)) — "
                      + "pause()/setSpectrum(.silent) 가 no-op 이 아니게 됐다는 뜻이고, "
                      + "그러면 스틸은 뜰 때마다 다른 그림이 된다")
    }

    /// **공집합 방지** — 스펙트럼이 실제로 새면 그림이 눈에 띄게 달라진다.
    ///
    /// 이게 없으면 위 두 테스트는 "이 픽스처는 애초에 오디오를 안 쓴다" 로도 통과한다.
    /// 여기서 재는 차이의 크기가 곧 백로그 ② 가 실현됐을 때의 **증상 크기**다.
    func testInjectedSpectrumWouldVisiblyChangeTheStill() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }

        let (r, _) = try mountCaptureInstance(tag: "inject")
        defer { r.teardown() }
        let silent = try captureRGBA(r, tag: "inject_silent")
        r.setSpectrum(AudioSpectrum16(left: [Float](repeating: 1, count: 16),
                                      right: [Float](repeating: 1, count: 16)))
        let loud = try captureRGBA(r, tag: "inject_loud")

        let silentLuma = meanLuma(rgba: silent), loudLuma = meanLuma(rgba: loud)
        let m = diffRGBA(silent, loud)
        NSLog("%@", "[Waple] capture-audio 주입 대조: luma \(silentLuma) → \(loudLuma) "
              + "meanAbsDiff=\(m.meanAbsDiff) fracExceeding=\(m.fracExceeding)")
        XCTAssertGreaterThan(loudLuma, silentLuma + 0.15,
                             "픽스처가 스펙트럼에 반응하지 않는다 — 위 두 오라클이 공집합 통과가 된다")
        XCTAssertFalse(passes(m, .strict),
                       "무음/최대 스펙트럼 프레임이 strict 를 통과했다 — 비교가 아무것도 잡지 못한다는 뜻")
    }
}
