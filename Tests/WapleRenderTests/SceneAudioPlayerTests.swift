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

    private func sound(_ paths: [String], mode: String = "loop", startSilent: Bool = false,
                       name: String = "", minTime: Float = 0, maxTime: Float = 0) -> SceneSound {
        SceneSound(id: 1, name: name, sounds: paths, volume: 0.5, playbackMode: mode,
                   startSilent: startSilent, minTime: minTime, maxTime: maxTime)
    }

    /// isPlaying(name:) 이 조건을 만족할 때까지 메인 런루프를 최대 deadline 초 스핀(자연종료 대기).
    private func spin(until predicate: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// ogg 는 이제 자체 디코드로 재생 가능 → 필터되지 않고 순서 보존(전 포맷 통과).
    func testPlayableEntriesKeepsAllSupportedFormats() {
        XCTAssertEqual(SceneAudioPlayer.playableEntries(sound(["a.ogg", "b.mp3", "c.wav", "d.flac"])),
                       ["a.ogg", "b.mp3", "c.wav", "d.flac"])
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

    // ── random 곡 간 간격(mintime/maxtime) ──────────────────────────────────

    /// random 만 대기; loop/single 은 즉시(0).
    func testGapSecondsOnlyRandom() {
        XCTAssertEqual(SceneAudioPlayer.gapSeconds(mode: "loop", minTime: 2, maxTime: 5), 0)
        XCTAssertEqual(SceneAudioPlayer.gapSeconds(mode: "single", minTime: 2, maxTime: 5), 0)
        for _ in 0..<50 {
            let g = SceneAudioPlayer.gapSeconds(mode: "random", minTime: 2, maxTime: 5)
            XCTAssertGreaterThanOrEqual(g, 2); XCTAssertLessThanOrEqual(g, 5)
        }
    }

    /// 경계: min>max 스왑, 미지정(0,0)→0, 음수 클램프, min==max→고정.
    func testGapSecondsBoundaries() {
        XCTAssertEqual(SceneAudioPlayer.gapSeconds(mode: "random", minTime: 0, maxTime: 0), 0)   // 미지정
        for _ in 0..<50 {
            let swap = SceneAudioPlayer.gapSeconds(mode: "random", minTime: 5, maxTime: 2)       // min>max 스왑
            XCTAssertGreaterThanOrEqual(swap, 2); XCTAssertLessThanOrEqual(swap, 5)
            let neg = SceneAudioPlayer.gapSeconds(mode: "random", minTime: -3, maxTime: 4)        // 음수 하한 클램프
            XCTAssertGreaterThanOrEqual(neg, 0); XCTAssertLessThanOrEqual(neg, 4)
        }
        XCTAssertEqual(SceneAudioPlayer.gapSeconds(mode: "random", minTime: 3, maxTime: 3), 3)    // 고정
        XCTAssertEqual(SceneAudioPlayer.gapSeconds(mode: "random", minTime: -5, maxTime: -1), 0)  // 전부 음수→0
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

    /// 깨진 ogg(1바이트)는 디코드 실패 → 폴백 후보 없음 → 아무것도 마운트 안 함.
    func testAllEntriesUnplayableMountsNothing() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.ogg", data: Data([1]))])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/a.ogg"])], package: pkg, settingVolume: 1)
        XCTAssertEqual(player.playerCount, 0)
        XCTAssertFalse(player.isPlaying)
    }

    /// 실물 ogg(Vorbis) 엔트리 → 디코드 → WAV → AVAudioPlayer 장착·재생(mute). 전 경로 검증.
    func testOggEntryDecodesAndPlays() {
        let pkg = ScenePackage.assemble([(name: "sounds/a.ogg", data: TinyOgg.data)])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/a.ogg"])], package: pkg, settingVolume: 0)
        XCTAssertEqual(player.playerCount, 1)   // ogg 가 디코드되어 플레이어 장착됨
        XCTAssertTrue(player.isPlaying)
        player.teardown()
    }

    // ── 이름 주소 트리거 트랜스포트(사운드 트리거 시스템) ────────────────────────

    /// 이름 있는 startsilent 사운드: start 후엔 미재생(등록만) → play(name:) 트리거 시 재생.
    func testNamedStartSilentRegistersButTriggersOnPlay() {
        let pkg = ScenePackage.assemble([(name: "sounds/dial.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/dial.wav"], mode: "single", startSilent: true, name: "dial.wav")],
                     package: pkg, settingVolume: 0)
        XCTAssertFalse(player.isPlaying(name: "dial.wav"), "startsilent 은 시작 시 무음")
        XCTAssertEqual(player.playerCount, 0)

        player.play(name: "dial.wav")
        XCTAssertTrue(player.isPlaying(name: "dial.wav"), "트리거 후 재생 상태")
        XCTAssertEqual(player.playerCount, 1)
        player.teardown()
        XCTAssertFalse(player.isPlaying(name: "dial.wav"))
    }

    /// 상태가 진짜다: 곡 자연종료 시 isPlaying(name:) 이 false 로 떨어진다(주크박스 폴링 계약).
    func testTriggeredSoundReportsNotPlayingAfterNaturalEnd() {
        let pkg = ScenePackage.assemble([(name: "sounds/sfx.wav", data: Self.silentWAV(seconds: 0.15))])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/sfx.wav"], mode: "single", startSilent: true, name: "sfx")],
                     package: pkg, settingVolume: 0)
        player.play(name: "sfx")
        XCTAssertTrue(player.isPlaying(name: "sfx"))
        spin(until: { !player.isPlaying(name: "sfx") })
        XCTAssertFalse(player.isPlaying(name: "sfx"), "0.15초 곡 자연종료 후 isPlaying false 이어야")
        player.teardown()
    }

    /// stop(name:) → 즉시 정지.
    func testStopByNameHaltsPlayback() {
        let pkg = ScenePackage.assemble([(name: "sounds/loop.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/loop.wav"], mode: "loop", startSilent: true, name: "bgm")],
                     package: pkg, settingVolume: 0)
        player.play(name: "bgm")
        XCTAssertTrue(player.isPlaying(name: "bgm"))
        player.stop(name: "bgm")
        XCTAssertFalse(player.isPlaying(name: "bgm"))
        player.teardown()
    }

    /// .volume 게터/세터: 스크립트가 세팅한 오서 볼륨이 그대로 회수된다(설정 배수는 감춤).
    func testVolumeGetterSetterRoundTrips() {
        let pkg = ScenePackage.assemble([(name: "sounds/m.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/m.wav"], mode: "loop", startSilent: true, name: "music")],
                     package: pkg, settingVolume: 0.5)
        XCTAssertEqual(player.volume(name: "music"), 0.5, accuracy: 1e-6)   // 오서 볼륨(sound helper 0.5)
        player.setVolume(name: "music", 0.25)
        XCTAssertEqual(player.volume(name: "music"), 0.25, accuracy: 1e-6)
        player.play(name: "music")
        player.setVolume(name: "music", 0.8)   // 재생 중 변경도 안전
        XCTAssertEqual(player.volume(name: "music"), 0.8, accuracy: 1e-6)
        player.teardown()
    }

    /// 미등록 이름은 전 트랜스포트 연산이 안전 no-op(스크립트 오타/부재 레이어 방어).
    func testUnknownNameIsSafeNoOp() {
        let player = SceneAudioPlayer()
        player.play(name: "nope")
        player.stop(name: "nope")
        player.setVolume(name: "nope", 0.5)
        XCTAssertFalse(player.isPlaying(name: "nope"))
        XCTAssertEqual(player.volume(name: "nope"), 0)
    }

    /// 재트리거는 처음부터 재시작(클릭 SFX 반복 클릭 규약) — 여전히 재생 상태.
    func testRetriggerRestartsPlayback() {
        let pkg = ScenePackage.assemble([(name: "sounds/click.wav", data: Self.silentWAV())])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/click.wav"], mode: "single", startSilent: true, name: "click")],
                     package: pkg, settingVolume: 0)
        player.play(name: "click")
        XCTAssertTrue(player.isPlaying(name: "click"))
        player.play(name: "click")   // 재트리거
        XCTAssertTrue(player.isPlaying(name: "click"), "재트리거 후에도 재생 중")
        XCTAssertEqual(player.playerCount, 1)
        player.teardown()
    }

    /// F410 회귀: random 모드 곡 종료로 예약된 gap 콜백이 만기되기 전 play(name:) 재트리거로 새 곡이
    /// 시작되면, stale 콜백이 stopped/paused=false 만 보고 play(at:) 로 플레이어를 교체해 새 곡을 중간에
    /// 끊었다. 세대 불일치로 폐기돼야 한다(새 곡은 자연종료까지 생존).
    func testStaleGapCallbackDoesNotCutRetriggeredTrack() {
        // 단일 엔트리 random: 재선곡이 항상 같은 곡(결정성), gap 0.6초 고정(min==max).
        let pkg = ScenePackage.assemble([(name: "sounds/a.wav", data: Self.silentWAV(seconds: 1.0))])
        let player = SceneAudioPlayer()
        player.start(sounds: [sound(["sounds/a.wav"], mode: "random", startSilent: true,
                                    name: "bgm", minTime: 0.6, maxTime: 0.6)],
                     package: pkg, settingVolume: 0)
        player.play(name: "bgm")
        XCTAssertTrue(player.isPlaying(name: "bgm"))
        // 첫 곡 자연종료 대기 → gap(0.6초) 콜백 예약(구 세대 캡처)
        spin(until: { !player.isPlaying(name: "bgm") })
        XCTAssertFalse(player.isPlaying(name: "bgm"), "1.0초 곡 자연종료 후 gap 대기 중이어야")
        // gap 대기 중 재트리거 → 새 세대에서 같은 곡 처음부터 재생(1.0초)
        player.play(name: "bgm")
        XCTAssertTrue(player.isPlaying(name: "bgm"))
        // stale 콜백 만기(재트리거 후 ≈0.55초)와 재생 곡 자연종료(+1.0초)를 모두 지난 시점에 관측.
        // 수정 전: stale 콜백이 ≈0.55초 시점에 플레이어를 교체(곡 절단 후 재시작) → 이 시점에도 재생 중.
        // 수정 후: stale 콜백 폐기 → 재생 곡은 자연종료, 다음 gap 대기 중 → 미재생.
        let sampleAt = Date().addingTimeInterval(1.25)
        spin(until: { Date() >= sampleAt })
        XCTAssertFalse(player.isPlaying(name: "bgm"),
                       "F410: gap 중 재트리거된 새 곡이 stale 콜백에 교체·절단되지 않아야(자연종료 후 gap 대기 상태)")
        player.teardown()
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
