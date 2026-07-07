import XCTest
@testable import WapleRender
import WapleCore

final class SceneAudioPlayerTests: XCTestCase {

    // ── 순수 로직 ──────────────────────────────────────────────────────────

    func testEffectiveVolumeIsAuthorTimesSetting() {
        XCTAssertEqual(SceneAudioPlayer.effectiveVolume(author: 0.6, setting: 0.5), 0.3, accuracy: 1e-6)
        XCTAssertEqual(SceneAudioPlayer.effectiveVolume(author: 1.0, setting: 0.0), 0.0)   // 설정 음소거 → 무음
        XCTAssertEqual(SceneAudioPlayer.effectiveVolume(author: 2.0, setting: 2.0), 1.0)   // 상한 클램프
        XCTAssertEqual(SceneAudioPlayer.effectiveVolume(author: -1, setting: 0.5), 0.0)    // 하한 클램프
    }

    private func sound(_ paths: [String], mode: String = "loop") -> SceneSound {
        SceneSound(id: 1, sounds: paths, volume: 0.5, playbackMode: mode,
                   startSilent: false, minTime: 0, maxTime: 0)
    }

    private func silentSound(_ paths: [String], mode: String = "loop") -> SceneSound {
        SceneSound(id: 1, sounds: paths, volume: 0.5, playbackMode: mode,
                   startSilent: true, minTime: 0, maxTime: 0)
    }

    func testPickReturnsSingleEntry() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.mp3", data: Data([1, 2, 3]))])
        let r = SceneAudioPlayer.pick(sound(["sounds/a.mp3"]), package: pkg)
        XCTAssertEqual(r?.name, "sounds/a.mp3")
        XCTAssertEqual(r?.data, Data([1, 2, 3]))
    }

    func testPickSkipsOggAndFallsBackToPlayable() {
        // ogg 는 미지원 → 스킵, 재생가능(mp3)만 남는다.
        let pkg = ScenePackage.assemble([(name: "sounds/b.mp3", data: Data([9]))])
        let r = SceneAudioPlayer.pick(sound(["sounds/a.ogg", "sounds/b.mp3"]), package: pkg)
        XCTAssertEqual(r?.name, "sounds/b.mp3")
    }

    func testPickReturnsNilWhenAllUnsupported() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.ogg", data: Data([1]))])
        XCTAssertNil(SceneAudioPlayer.pick(sound(["sounds/a.ogg"]), package: pkg))
    }

    func testPickReturnsNilWhenPkgEntryMissing() {
        let pkg = ScenePackage.assemble([(name: "other.txt", data: Data([1]))])
        XCTAssertNil(SceneAudioPlayer.pick(sound(["sounds/a.mp3"]), package: pkg))
    }

    // ── 재생 통합(mute) ─────────────────────────────────────────────────────

    /// 유효한 무음 WAV 를 pkg 에서 추출해 AVAudioPlayer 로 재생 시작하는지(설정 음량 0=mute, TCC 불요).
    func testStartsMutedPlayback() {
        let pkg = ScenePackage.assemble([(name: "sounds/t.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/t.wav"])], package: pkg, settingVolume: 0)  // mute
        XCTAssertEqual(player.playerCount, 1)   // 플레이어 장착됨
        XCTAssertTrue(player.isPlaying)          // 재생 시작됨(음소거여도 play)
        player.teardown()
        XCTAssertFalse(player.isPlaying)
    }

    func testStartSilentSoundsDoNotAutoPlay() {
        let pkg = ScenePackage.assemble([(name: "sounds/t.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [silentSound(["sounds/t.wav"])], package: pkg, settingVolume: 1)

        XCTAssertEqual(player.playerCount, 0)
        XCTAssertFalse(player.isPlaying)
    }

    /// PCM 16-bit mono 무음 WAV(RIFF) — AVAudioPlayer 가 디코드 가능한 최소 합성 오디오.
    static func silentWAV(seconds: Double = 0.2, sampleRate: Int = 8000) -> Data {
        let n = Int(Double(sampleRate) * seconds)
        let dataBytes = n * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + dataBytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)                // PCM, mono
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)               // byterate, blockalign, 16-bit
        d.append(Data("data".utf8)); u32(dataBytes)
        d.append(Data(repeating: 0, count: dataBytes))                      // 무음 샘플
        return d
    }
}
