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

    private func sound(_ paths: [String], mode: String = "loop", startSilent: Bool = false) -> SceneSound {
        SceneSound(id: 1, sounds: paths, volume: 0.5, playbackMode: mode,
                   startSilent: startSilent, minTime: 0, maxTime: 0)
    }

    func testPlayableEntriesFiltersOggKeepsOrder() {
        XCTAssertEqual(SceneAudioPlayer.playableEntries(sound(["a.ogg", "b.mp3", "c.wav"])), ["b.mp3", "c.wav"])
        XCTAssertEqual(SceneAudioPlayer.playableEntries(sound(["a.OGG"])), [])   // 대소문자 무시
    }

    func testFirstIndexSequentialModesStartAtZero() {
        XCTAssertEqual(SceneAudioPlayer.firstIndex(mode: "loop", count: 3), 0)
        XCTAssertEqual(SceneAudioPlayer.firstIndex(mode: "single", count: 3), 0)
        XCTAssertNil(SceneAudioPlayer.firstIndex(mode: "loop", count: 0))
        for _ in 0..<20 {
            let r = SceneAudioPlayer.firstIndex(mode: "random", count: 3)
            XCTAssertNotNil(r); XCTAssertTrue((0..<3).contains(r!))
        }
    }

    /// 다중 엔트리 = 플레이리스트(실측: 33오브젝트 전부 상이한 곡 목록). loop 는 순차 순환.
    func testNextIndexLoopCyclesPlaylist() {
        XCTAssertEqual(SceneAudioPlayer.nextIndex(mode: "loop", current: 0, count: 3), 1)
        XCTAssertEqual(SceneAudioPlayer.nextIndex(mode: "loop", current: 2, count: 3), 0)   // 끝 → 처음
        XCTAssertEqual(SceneAudioPlayer.nextIndex(mode: "loop", current: 0, count: 1), 0)   // 단곡 반복
    }

    /// single 은 목록을 순차 1회 재생 후 종료(nil).
    func testNextIndexSingleEndsAfterOnePass() {
        XCTAssertEqual(SceneAudioPlayer.nextIndex(mode: "single", current: 0, count: 3), 1)
        XCTAssertNil(SceneAudioPlayer.nextIndex(mode: "single", current: 2, count: 3))
        XCTAssertNil(SceneAudioPlayer.nextIndex(mode: "single", current: 0, count: 1))
    }

    /// random 은 곡 종료마다 무작위 재선곡(셔플 연속 재생 — 실측: 랜덤 9오브젝트 전부 다중 목록).
    func testNextIndexRandomAlwaysContinues() {
        for _ in 0..<20 {
            let r = SceneAudioPlayer.nextIndex(mode: "random", current: 1, count: 4)
            XCTAssertNotNil(r); XCTAssertTrue((0..<4).contains(r!))
        }
        XCTAssertNil(SceneAudioPlayer.nextIndex(mode: "random", current: 0, count: 0))
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

    /// startsilent=true(확정: 트리거 대기) → 시작 시 자동재생 없음.
    func testStartSilentSoundsDoNotAutoPlay() {
        let pkg = ScenePackage.assemble([(name: "sounds/t.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/t.wav"], startSilent: true)], package: pkg, settingVolume: 1)

        XCTAssertEqual(player.playerCount, 0)
        XCTAssertFalse(player.isPlaying)
    }

    /// 다중 엔트리는 동시 재생이 아니라 플레이리스트 — 오브젝트당 플레이어 1개.
    func testMultiEntryMountsSinglePlayer() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.wav", data: Self.silentWAV()),
                                         (name: "sounds/b.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/a.wav", "sounds/b.wav"])], package: pkg, settingVolume: 0)
        XCTAssertEqual(player.playerCount, 1)
        XCTAssertTrue(player.isPlaying)
        player.teardown()
    }

    /// 첫 엔트리 pkg 누락/디코드 실패 시 다음 후보로 폴백해 재생.
    func testStartFallsBackToNextPlayableEntry() {
        let pkg = ScenePackage.assemble([(name: "sounds/b.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/missing.mp3", "sounds/b.wav"])], package: pkg, settingVolume: 0)
        XCTAssertEqual(player.playerCount, 1)
        XCTAssertTrue(player.isPlaying)
        player.teardown()
    }

    func testAllEntriesUnplayableMountsNothing() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.ogg", data: Data([1]))])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/a.ogg"])], package: pkg, settingVolume: 1)
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
