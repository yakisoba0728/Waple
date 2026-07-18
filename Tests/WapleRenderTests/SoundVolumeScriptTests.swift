import XCTest
@testable import WapleCore
@testable import WapleRender

/// F214: parseSound 는 volume 을 float(obj["volume"]) 로 언랩해 {value}만 취하고 {script}는 버린다 —
/// SceneSound 에 volumeScript 필드 부재. 실측: volume 이 script 바인딩인 사운드 12건(예 2911866381
/// 오디오/페이드 구동 볼륨). 파스 캡처 + SceneAudioPlayer 소비(볼륨 반영)까지 배선.
final class SoundVolumeScriptTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) -> ScenePackage {
        ScenePackage.assemble(files.map { (name: $0.0, data: Data($0.1.utf8)) })
    }

    // ── 파스 캡처 ──────────────────────────────────────────────────────────

    func testVolumeScriptCaptured() throws {
        let scene = """
        {"objects":[{"id":1,"name":"bgm","sound":["sounds/a.mp3"],"playbackmode":"loop",
                     "volume":{"value":0.2,"script":"export function update(v){ return 0.9; }"}}]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.sounds.count, 1)
        XCTAssertEqual(doc.sounds[0].volume, 0.2, accuracy: 1e-4, "정적 초기값은 그대로 유지")
        XCTAssertEqual(doc.sounds[0].volumeScript, "export function update(v){ return 0.9; }")
    }

    /// 가드: 스크립트 없는 정적 volume 은 volumeScript 가 nil(무회귀).
    func testStaticVolumeHasNoScript() throws {
        let scene = #"{"objects":[{"id":1,"name":"bgm","sound":["sounds/a.mp3"],"volume":0.5}]}"#
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertNil(doc.sounds[0].volumeScript)
    }

    // ── 소비 배선: SceneAudioPlayer.tick(time:) 이 스크립트 평가값을 authorVolume 에 반영 ────────

    private func sound(_ paths: [String], volume: Float = 0.5, name: String = "") -> SceneSound {
        SceneSound(id: 1, name: name, sounds: paths, volume: volume, playbackMode: "loop",
                   startSilent: true, minTime: 0, maxTime: 0)
    }

    /// tick(time:) 호출 전엔 정적(파스) 볼륨, 호출 후엔 스크립트 update() 반환값으로 갱신.
    func testTickAppliesVolumeScriptToNamedSound() throws {
        let pkgData = ScenePackage.assemble([(name: "sounds/m.wav", data: SceneAudioPlayerTests.silentWAV())])
        var snd = sound(["sounds/m.wav"], volume: 0.2, name: "music")
        snd.volumeScript = "export function update(v){ return 0.9; }"

        let scene = try XCTUnwrap(SceneScriptContext())
        let engine = try XCTUnwrap(TextScriptEngine(script: snd.volumeScript!, scene: scene))

        let player = SceneAudioPlayer()
        player.start(sounds: [snd], package: pkgData, settingVolume: 1,
                     volumeEngine: { _ in engine })
        XCTAssertEqual(player.volume(name: "music"), 0.2, accuracy: 1e-6, "tick 전엔 파스 정적값")

        player.tick(time: 0)
        XCTAssertEqual(player.volume(name: "music"), 0.9, accuracy: 1e-6, "tick 후 스크립트 반환값 반영")
        player.teardown()
    }

    /// volumeScript 가 없는 사운드는 tick 이 안전 no-op(정적 볼륨 유지).
    func testTickIsNoOpWithoutVolumeScript() throws {
        let pkgData = ScenePackage.assemble([(name: "sounds/m.wav", data: SceneAudioPlayerTests.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/m.wav"], volume: 0.4, name: "music")],
                     package: pkgData, settingVolume: 1)
        player.tick(time: 0)
        XCTAssertEqual(player.volume(name: "music"), 0.4, accuracy: 1e-6)
        player.teardown()
    }
}
