import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 상호작용·미디어 e2e: cursorClick(클릭 시뮬 → 캡처 픽셀 변화)과 미디어 이벤트(가짜 프로바이더 →
/// 썸네일 주색이 레이어 색에 반영). 실물 검증(3394601417 주야 토글, 2881558311 ColorTinter)은
/// 실물 패키지 폴더가 있을 때만(없으면 skip — CI 안전).
final class SceneInteractionMediaE2ETests: XCTestCase {
    private func i32(_ n: Int) -> Data { var v = UInt32(n).littleEndian; return Data(bytes: &v, count: 4) }

    private func encodePkg(_ files: [(String, Data)]) -> Data {
        var out = Data()
        let version = "PKGV0001"
        out.append(i32(version.utf8.count)); out.append(version.data(using: .utf8)!)
        out.append(i32(files.count))
        var offset = 0
        for (name, data) in files {
            out.append(i32(name.utf8.count)); out.append(name.data(using: .utf8)!)
            out.append(i32(offset)); out.append(i32(data.count)); offset += data.count
        }
        for (_, data) in files { out.append(data) }
        return out
    }

    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    private func makeProject(_ files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                title: id, tags: [], contentRating: nil, workshopId: nil,
                                dependency: nil, folderURL: dir)
    }

    private func realProject(_ id: String) throws -> WallpaperProject {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else {
            throw XCTSkip("no real pkg: \(id)")
        }
        return try ProjectJSONParser.parse(folderURL: folder)
    }

    private func meanRGB(_ url: URL) throws -> (r: Double, g: Double, b: Double) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                sum.r += c.redComponent; sum.g += c.greenComponent; sum.b += c.blueComponent
                n += 1
            }
        }
        return (sum.r / Double(n), sum.g / Double(n), sum.b / Double(n))
    }

    // MARK: - cursorClick

    /// 합성 토글 씬(실물 3394601417 축소판): 컨트롤러 visible 스크립트가 cursorClick 으로 shared.a 토글,
    /// 소비자 alpha 스크립트가 shared.a 로 빨강 오버레이 on/off. simulateCursorClick 전후 캡처 픽셀 검증.
    func testSimulatedClickTogglesSyntheticScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/ctrl.json","origin":"4 4 0","size":"2 2",
            "visible":{"value":true,"script":"'use strict';\\nlet cl=false;\\nshared.a=1;\\nexport function cursorClick(event){ if(cl==false){ shared.a=0; cl=true; } else { shared.a=1; cl=false; } }"}},
           {"id":3,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":1,"script":"'use strict';\\nexport function update(v){ return shared.a==1 ? 1 : 0; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("ctrl", solidTex(128, 128, 128)),
                            ("red", solidTex(255, 0, 0))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_click_e2e"))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_click_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func capture(_ tag: String) throws -> (r: Double, g: Double, b: Double) {
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
            let dst = out.appendingPathComponent("\(tag).png")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: url, to: dst)
            return try meanRGB(dst)
        }
        let before = try capture("before")
        XCTAssertGreaterThan(before.r, 0.8, "초기 shared.a=1 → 빨강 오버레이 on: \(before)")
        XCTAssertLessThan(before.g, 0.2)

        r.simulateCursorClick(x: 960, y: 540)
        let after = try capture("after_click")
        XCTAssertGreaterThan(after.g, 0.8, "클릭 → shared.a=0 → 오버레이 off(흰 bg): \(after)")

        r.simulateCursorClick(x: 960, y: 540)
        let again = try capture("after_second_click")
        XCTAssertLessThan(again.g, 0.2, "재클릭 → 오버레이 복귀: \(again)")
    }

    /// 실물 3394601417: visible 스크립트의 cursorClick 이 주야(shared.a) 토글 — 클릭 전후 luma 변화.
    func testRealDayNightToggle3394601417() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)),
                    project: try realProject("3394601417"))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_click_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func luma(_ tag: String) throws -> Double {
            let url = try XCTUnwrap(r.captureFrames(width: 640, height: 360, times: [0.5], toDir: out).first)
            let dst = out.appendingPathComponent("\(tag).png")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: url, to: dst)
            let c = try meanRGB(dst)
            return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        }
        let day = try luma("3394601417_before")
        r.simulateCursorClick(x: 960, y: 540)
        let night = try luma("3394601417_after")
        NSLog("%@", "[WapleE2E] 3394601417 luma day=\(day) night=\(night) delta=\(abs(day - night))")
        XCTAssertGreaterThan(abs(day - night), 0.02,
                             "클릭(주야 토글) 전후 luma 무변화: \(day) → \(night)")
        r.simulateCursorClick(x: 960, y: 540)
        let day2 = try luma("3394601417_again")
        XCTAssertLessThan(abs(day - day2), 0.02, "재클릭 → 원상 복귀: \(day) → \(day2)")
    }

    // MARK: - cursorClick → 사운드 트리거

    /// 합성 씬(실물 2955378002/3146703458 축소판): startsilent 사운드 오브젝트 name='dial.wav' +
    /// cursorClick 스크립트 `getLayer('dial.wav').play()`. 헤드리스 mount(오디오 미생성)라 트랜스포트를
    /// 수동 연결(캡처 결정성 유지) 후 simulateCursorClick → 실 dispatch 경로로 트랜스포트 재생 단언.
    func testSimulatedClickTriggersSoundTransport() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080",
            "visible":{"value":true,"script":"'use strict';\\nexport function cursorClick(event){ thisScene.getLayer('dial.wav').play(); }"}},
           {"id":2,"name":"dial.wav","sound":["sounds/dial.wav"],"playbackmode":"single","startsilent":true,"volume":1}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        files.append(("models/bg.json", Data(#"{"material":"materials/bg.json"}"#.utf8)))
        files.append(("materials/bg.json", Data(#"{"passes":[{"textures":["bg"]}]}"#.utf8)))
        files.append(("materials/bg.tex", solidTex(255, 255, 255)))
        files.append(("sounds/dial.wav", SceneAudioPlayerTests.silentWAV()))

        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_sound_e2e"))
        defer { r.teardown() }

        // 헤드리스라 sceneAudio 는 미생성 → 트랜스포트 수동 연결(라이브 배선과 동일 seam).
        let audio = SceneAudioPlayer()
        let pkg = ScenePackage.assemble([(name: "sounds/dial.wav", data: SceneAudioPlayerTests.silentWAV())])
        audio.start(sounds: [SceneSound(id: 2, name: "dial.wav", sounds: ["sounds/dial.wav"], volume: 1,
                                        playbackMode: "single", startSilent: true, minTime: 0, maxTime: 0)],
                    package: pkg, settingVolume: 0)   // mute — 무음 재생(상태만 검증, 실청취 불가)
        r.sceneScript?.soundTransport = audio

        XCTAssertFalse(audio.isPlaying(name: "dial.wav"), "클릭 전 startsilent 무음")
        r.simulateCursorClick(x: 960, y: 540)
        XCTAssertTrue(audio.isPlaying(name: "dial.wav"),
                      "cursorClick → getLayer('dial.wav').play() → 트랜스포트 재생 전이 실패")
        audio.teardown()
    }

    // MARK: - cursorEnter/cursorLeave 호버 + animationEvent

    /// 합성 씬: 호버존 레이어(name=hoverzone, 200×200@480,270)의 cursorEnter/Leave 가 shared.h 토글,
    /// 빨강 오버레이가 shared.h 로 on/off. simulateCursorMove 로 경계 진입/이탈 시 픽셀 변화 검증.
    /// (엔진이 바인드 레이어를 히트테스트 — 스크립트는 좌표를 안 본다.)
    func testCursorEnterLeaveHoverTogglesScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"name":"hoverzone","image":"models/ctrl.json","origin":"480 270 0","size":"200 200",
            "visible":{"value":true,"script":"'use strict';\\nshared.h=0;\\nexport function cursorEnter(event){ shared.h=1; }\\nexport function cursorLeave(event){ shared.h=0; }"}},
           {"id":3,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":1,"script":"'use strict';\\nexport function update(v){ return shared.h==1 ? 1 : 0; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("ctrl", solidTex(255, 255, 255)),
                            ("red", solidTex(255, 0, 0))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_hover_e2e"))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_hover_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func capture(_ tag: String) throws -> (r: Double, g: Double, b: Double) {
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
            let dst = out.appendingPathComponent("\(tag).png")
            try? FileManager.default.removeItem(at: dst); try FileManager.default.moveItem(at: url, to: dst)
            return try meanRGB(dst)
        }
        let before = try capture("before")
        XCTAssertGreaterThan(before.g, 0.8, "호버 전: 빨강 오버레이 off(흰): \(before)")

        r.simulateCursorMove(x: 480, y: 270)   // 호버존(380..580, 170..370) 내부 → cursorEnter
        let enter = try capture("enter")
        XCTAssertGreaterThan(enter.r, 0.8, "진입 → 오버레이 on(빨강): \(enter)")
        XCTAssertLessThan(enter.g, 0.2)

        r.simulateCursorMove(x: 1400, y: 900)  // 경계 밖 → cursorLeave
        let leave = try capture("leave")
        XCTAssertGreaterThan(leave.g, 0.8, "이탈 → 오버레이 off(흰): \(leave)")
    }

    /// animationEvent 발송 진입점(발화원 대체): simulateAnimationEvent('go') → 훅이 shared 토글 → 픽셀 변화.
    /// (실 발화원인 타임라인/퍼펫 마커는 수정 금지 파일 소관 — 여기선 스크립트 측 배선만 검증.)
    func testSimulateAnimationEventTogglesScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"name":"ctrlx","image":"models/ctrl.json","origin":"4 4 0","size":"2 2",
            "visible":{"value":true,"script":"'use strict';\\nshared.a=0;\\nexport function animationEvent(event){ if(event.name=='go'){ shared.a=1; } }"}},
           {"id":3,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":1,"script":"'use strict';\\nexport function update(v){ return shared.a==1 ? 1 : 0; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("ctrl", solidTex(128, 128, 128)),
                            ("red", solidTex(255, 0, 0))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_animevt_e2e"))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_animevt_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func capture(_ tag: String) throws -> (r: Double, g: Double, b: Double) {
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
            let dst = out.appendingPathComponent("\(tag).png")
            try? FileManager.default.removeItem(at: dst); try FileManager.default.moveItem(at: url, to: dst)
            return try meanRGB(dst)
        }
        let before = try capture("before")
        XCTAssertGreaterThan(before.g, 0.8, "이벤트 전: off(흰): \(before)")
        r.simulateAnimationEvent(name: "go")
        let after = try capture("after")
        XCTAssertGreaterThan(after.r, 0.8, "animationEvent('go') → shared.a=1 → 오버레이 on(빨강): \(after)")
        XCTAssertLessThan(after.g, 0.2)
    }

    /// 실 발화원(타임라인 마커 검출): options.events{frame:15,"go"} 타임라인이 재생 클록으로
    /// 마커를 **넘는 순간** 훅 발화 — simulateAnimationEvent 아닌 tickAnimationEvents(라이브 draw 가
    /// 매 프레임 호출하는 검출 경로) 로 시간 전진. 마커 전은 미발화(타이밍 검증).
    func testTimelineMarkerFiresAnimationEventOnRealPlaybackPath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"name":"ctrlx","image":"models/ctrl.json","size":"2 2",
            "origin":{"value":"4 4 0",
                      "animation":{"c0":[{"frame":0,"value":0},{"frame":30,"value":0}],
                                   "relative":true,
                                   "options":{"fps":30,"length":30,"mode":"single",
                                              "events":[{"frame":15,"name":"go"}]}}},
            "visible":{"value":true,"script":"'use strict';\\nshared.a=0;\\nexport function animationEvent(event){ if(event.name=='go'){ shared.a=1; } }"}},
           {"id":3,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":1,"script":"'use strict';\\nexport function update(v){ return shared.a==1 ? 1 : 0; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("ctrl", solidTex(128, 128, 128)),
                            ("red", solidTex(255, 0, 0))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_animevt_marker_e2e"))
        defer { r.teardown() }
        XCTAssertEqual(r.animEventTargets.count, 1, "이벤트 타깃: ctrl 오브젝트 1개(타임라인+훅 엔진)")
        let out = URL(fileURLWithPath: "/tmp/waple_animevt_marker_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func capture(_ tag: String) throws -> (r: Double, g: Double, b: Double) {
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
            let dst = out.appendingPathComponent("\(tag).png")
            try? FileManager.default.removeItem(at: dst); try FileManager.default.moveItem(at: url, to: dst)
            return try meanRGB(dst)
        }
        r.tickAnimationEvents(time: 0.1)   // frame 3 < 마커 15 — 미발화
        let before = try capture("before")
        XCTAssertGreaterThan(before.g, 0.8, "마커(frame 15) 전: off(흰): \(before)")
        r.tickAnimationEvents(time: 1.0)   // frame 30 — (3, 30] 이 15 를 통과 → 발화
        let after = try capture("after")
        XCTAssertGreaterThan(after.r, 0.8, "마커 통과 → animationEvent('go') → 오버레이 on(빨강): \(after)")
        XCTAssertLessThan(after.g, 0.2)
    }

    /// 통합(실물 3737268876 젤다): mount → 시간 전진(tickAnimationEvents = 라이브 draw 검출 경로) →
    /// animationlayers blend 타임라인의 "surprise" 마커(frame 0)가 같은 오브젝트 핸들러에 배달돼
    /// shared.guestBlink=3(surprise 핸들러 전용 값) — 이후 눈꺼풀 타임라인 half@0→blink@2→half@6→open@8
    /// 순차 발화로 0 복귀(시각순·오브젝트 스코프 검증).
    func testRealZeldaSurpriseMarkerFiresOnPlayback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)),
                    project: try realProject("3737268876"))
        defer { r.teardown() }
        XCTAssertFalse(r.animEventTargets.isEmpty, "젤다: 이벤트 타깃(타임라인+훅 엔진) 수집돼야")
        let probe = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ return shared.guestBlink === undefined ? -1 : shared.guestBlink; }",
            scene: try XCTUnwrap(r.sceneScript)))
        XCTAssertEqual(probe.evaluateVec(current: [0])?.first, 0, "mount 직후: 훅 미발화(스크립트 초기값 0)")
        r.tickAnimationEvents(time: 1.0 / 60)   // 최초 틱: frame 0 마커(surprise 등) 발화
        XCTAssertEqual(probe.evaluateVec(current: [0])?.first, 3,
                       "'surprise' 훅 수신 — guestBlink=3 은 surprise 핸들러 전용 값")
        r.tickAnimationEvents(time: 0.5)        // frame 15: 눈꺼풀 blink@2→half@6→open@8 시각순 발화
        XCTAssertEqual(probe.evaluateVec(current: [0])?.first, 0,
                       "blink 타임라인 완주(open@8 이 마지막) → 0 복귀")
    }

    // MARK: - 미디어 → 씬 배달

    private struct FakeMediaProvider: NowPlayingProvider, ArtworkProviding {
        let artwork: Data?
        func fetch() -> NowPlayingInfo? {
            NowPlayingInfo(state: .playing, title: "T1", artist: "A1", album: "L1", position: 30, duration: 120)
        }
        func fetchArtwork() -> Data? { artwork }
    }

    /// 합성 씬: mediaThumbnailChanged(primaryColor) → 레이어 color 스크립트(실물 ColorTinter 패턴,
    /// engine.frametime 타이머) 반영 + mediaPropertiesChanged/TimelineChanged 소비.
    func testFakeProviderDeliversThumbnailColorToScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 실물 2881558311 ColorTinter 스크립트 원문 패턴(전환 0.5초).
        let tinter = """
        'use strict';\\nconst DURATION = 0.5;\\nlet newColor = new Vec3(0, 0, 0);\\nlet oldColor = new Vec3(0, 0, 0);\\nlet timer = DURATION;\\nexport function update() {\\n\\tvar color = newColor;\\n\\tif (timer < DURATION) {\\n\\t\\tcolor = newColor.subtract(oldColor).multiply(timer / DURATION).add(oldColor);\\n\\t\\ttimer += engine.frametime;\\n\\t}\\n\\treturn color;\\n}\\nexport function mediaThumbnailChanged(event) {\\n\\ttimer = 0;\\n\\toldColor = newColor;\\n\\tnewColor = event.primaryColor;\\n}
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/white.json","origin":"960 540 0","size":"1920 1080",
            "color":{"value":"1 1 1","script":"\(tinter)"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        files.append(("models/white.json", Data(#"{"material":"materials/white.json"}"#.utf8)))
        files.append(("materials/white.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)))
        files.append(("materials/white.tex", solidTex(255, 255, 255)))

        // 아트워크 = 순수 파랑 PNG → primaryColor Vec3(0,0,1).
        var art = [UInt8]()
        for _ in 0..<64 { art.append(contentsOf: [0, 0, 255, 255]) }
        let artPNG = try XCTUnwrap(OffscreenCapture.png(rgba: art, width: 8, height: 8))

        let r = SceneRenderer()
        r.nowPlayingProvider = FakeMediaProvider(artwork: artPNG)
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try makeProject(files, id: "waple_media_e2e"))
        defer { r.teardown() }

        // 폴러 첫 배달까지 스핀(fetch 는 백그라운드 → 메인 배달).
        let deadline = Date().addingTimeInterval(10)
        while r.mediaDeliveryCountForTesting < 1, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(r.mediaDeliveryCountForTesting, 1, "미디어 폴러 미배달")

        let out = URL(fileURLWithPath: "/tmp/waple_media_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // 전환 타이머(0.5초 = frametime 0.016 × ~32 프레임)를 update 호출로 진행시킨 뒤 마지막 프레임 검증.
        let times = (0...40).map { Float($0) / 30.0 }
        let urls = r.captureFrames(width: 64, height: 36, times: times, toDir: out)
        let last = try XCTUnwrap(urls.last)
        let c = try meanRGB(last)
        XCTAssertGreaterThan(c.b, 0.8, "썸네일 primaryColor(파랑) 미반영: \(c)")
        XCTAssertLessThan(c.r, 0.2, "빨강/흰색 잔존 — 색 전환 실패: \(c)")
    }

    /// 실물 2881558311(ColorTinter 뮤직 씬): 가짜 프로바이더의 파랑 아트워크 주입 전후 캡처 —
    /// 씬 배색(ColorTinterPrimary/Secondary 솔리드 레이어)이 변해야 한다.
    func testReal2881558311ThumbnailColorE2E() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        var art = [UInt8]()
        for _ in 0..<64 { art.append(contentsOf: [255, 0, 0, 255]) }  // 순수 빨강 아트워크
        let artPNG = try XCTUnwrap(OffscreenCapture.png(rgba: art, width: 8, height: 8))

        let r = SceneRenderer()
        r.nowPlayingProvider = FakeMediaProvider(artwork: artPNG)
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)),
                    project: try realProject("2881558311"))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_media_e2e")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // 배달 전 기준 캡처(전환 타이머 진행 전 — 검정 초기 배색).
        let beforeURL = try XCTUnwrap(r.captureFrames(width: 640, height: 360, times: [0.5], toDir: out).first)
        let beforeDst = out.appendingPathComponent("2881558311_before.png")
        try? FileManager.default.removeItem(at: beforeDst)
        try FileManager.default.moveItem(at: beforeURL, to: beforeDst)
        let before = try meanRGB(beforeDst)

        let deadline = Date().addingTimeInterval(10)
        while r.mediaDeliveryCountForTesting < 1, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(r.mediaDeliveryCountForTesting, 1, "미디어 폴러 미배달")

        // 전환 타이머 진행(update 호출 40회) 후 마지막 프레임.
        let times = (0...40).map { Float($0) / 30.0 }
        let afterURL = try XCTUnwrap(r.captureFrames(width: 640, height: 360, times: times, toDir: out).last)
        let afterDst = out.appendingPathComponent("2881558311_after.png")
        try? FileManager.default.removeItem(at: afterDst)
        try FileManager.default.moveItem(at: afterURL, to: afterDst)
        let after = try meanRGB(afterDst)

        let delta = abs(after.r - before.r) + abs(after.g - before.g) + abs(after.b - before.b)
        NSLog("%@", "[WapleE2E] 2881558311 before=\(before) after=\(after) delta=\(delta)")
        XCTAssertGreaterThan(delta, 0.02, "썸네일 색 미반영(배색 무변화): \(before) → \(after)")
        XCTAssertGreaterThan(after.r - before.r, 0.01, "빨강 아트워크 → 빨강 성분 증가 기대: \(before) → \(after)")
    }
}
