import XCTest
@testable import WapleRender
import WapleCore

/// 씬 스크립트 이벤트 훅(cursorClick/media*Changed): IIFE 반환을 update 단일에서 훅 딕셔너리로 확장.
/// 이벤트 스키마는 실물 역추출(193패키지 스캔):
///  - cursorClick(event{ worldPosition: Vec3(씬픽셀, y-down), button }) — 3394601417 주야 토글, 2902406982 드래그
///  - mediaPlaybackChanged(MediaPlaybackEvent{ state })  state ∈ {PLAYBACK_STOPPED:0, PLAYBACK_PLAYING:1, PLAYBACK_PAUSED:2}
///  - mediaPropertiesChanged(MediaPropertiesEvent{ title, artist, albumTitle, albumArtist, subTitle, contentType })
///  - mediaThumbnailChanged(MediaThumbnailEvent{ primaryColor/secondaryColor/tertiaryColor/textColor/highContrastColor: Vec3(0..1), hasThumbnail })
///    (2881558311 ColorTinter: newColor = event.primaryColor 후 Vec3 메서드 체이닝 — Vec3 필수)
///  - mediaTimelineChanged(MediaTimelineEvent{ position, duration }) 초 단위
///  - mediaStatusChanged(MediaStatusEvent{ enabled })
final class SceneEventHookTests: XCTestCase {
    /// 실물 3394601417 'bt' 패턴: update 없이 cursorClick 만 export — 훅이 보관되고 호출 시 shared 토글.
    func testCursorClickHookCapturedAndCallable() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let controller = """
        'use strict';
        let cl=false;
        shared.a=1;
        export function cursorClick(event) { if(cl==false){ shared.a=0; cl=true; } else { shared.a=1; cl=false; } }
        """
        let ctrl = try XCTUnwrap(TextScriptEngine(script: controller, scene: scene))
        XCTAssertFalse(ctrl.hasUpdate)
        XCTAssertTrue(ctrl.hookNames.contains("cursorClick"))

        let consumer = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ return shared.a==1 ? 1 : 0; }", scene: scene))
        XCTAssertEqual(consumer.evaluateVec(current: [0])?.first, 1)
        ctrl.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(10, 20, 0), button: 0 })")
        XCTAssertEqual(consumer.evaluateVec(current: [0])?.first, 0, "클릭 후 shared.a=0 이어야")
        ctrl.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(10, 20, 0), button: 0 })")
        XCTAssertEqual(consumer.evaluateVec(current: [0])?.first, 1, "재클릭 → 복귀")
    }

    /// 실물 3394601417(낮/밤) 회귀: 훅이 thisScene.getAnimation(name).play() 를 라이브 호출한다 —
    /// 심이 없으면 TypeError 로 훅이 중단돼 cl 토글이 영구히 깨진다(shared.a 복귀 불가).
    /// getAnimation 은 이름별 캐시 no-op 애니메이션(초기 정지, play 후 isPlaying=true)이어야 한다.
    func testCursorClickHookSurvivesSceneGetAnimation() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let controller = """
        'use strict';
        let cl=false;
        shared.a=1;
        export function cursorClick(event) {
            if(cl==false){ shared.a=0; thisScene.getAnimation("2chu").play(); cl=true; }
            else { shared.a=1; thisScene.getAnimation("3chu").play(); cl=false; }
        }
        """
        let ctrl = try XCTUnwrap(TextScriptEngine(script: controller, scene: scene))
        let consumer = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ return shared.a==1 ? 1 : 0; }", scene: scene))
        ctrl.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(0, 0, 0), button: 0 })")
        XCTAssertEqual(consumer.evaluateVec(current: [0])?.first, 0, "클릭 → 밤(getAnimation 예외 없이 완주)")
        ctrl.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(0, 0, 0), button: 0 })")
        XCTAssertEqual(consumer.evaluateVec(current: [0])?.first, 1, "재클릭 → 낮 복귀(cl 토글 생존)")
        // 이름별 캐시 + 상태 일관: play 된 "2chu" 는 isPlaying, 미재생 이름은 정지 상태.
        let probe = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ return (thisScene.getAnimation('2chu').isPlaying() ? 1 : 0) + (thisScene.getAnimation('nope').isPlaying() ? 10 : 0); }",
            scene: scene))
        XCTAssertEqual(probe.evaluateVec(current: [0])?.first, 1)
    }

    /// cursorClick event.worldPosition 은 Vec3 — 실물 드래그 스크립트가 .x/.subtract 를 사용한다.
    func testCursorClickEventWorldPositionIsVec3() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        export function cursorClick(event) {
            shared.wx = event.worldPosition.x;
            shared.diff = new Vec3(100, 0, 0).subtract(event.worldPosition).x;
        }
        export function update(v){ return shared.wx + shared.diff; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene))
        e.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(30, 40, 0), button: 0 })")
        XCTAssertEqual(e.evaluateVec(current: [0])?.first ?? -1, 30 + 70, accuracy: 1e-4)
    }

    /// update 와 훅이 함께 export 돼도 둘 다 살아야 한다(기존 계약 무회귀).
    func testUpdateAndHooksCoexist() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        var v = 'a';
        export function update(cur){ return v; }
        export function mediaPropertiesChanged(event){ v = event.title; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene))
        XCTAssertTrue(e.hasUpdate)
        XCTAssertEqual(e.evaluate(current: ""), "a")
        e.callHook("mediaPropertiesChanged", eventJS: "new MediaPropertiesEvent({ title: 'T', artist: 'A' })")
        XCTAssertEqual(e.evaluate(current: ""), "T")
    }

    /// MediaPlaybackEvent 클래스 심: top-level 참조(실물 — "ReferenceError: MediaPlaybackEvent" 로드 실패)와
    /// 상수 값(PLAYBACK_STOPPED/PLAYING/PAUSED = 0/1/2, 웹 wallpaperMediaIntegration 과 동일 규약).
    func testMediaPlaybackEventClassShim() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        var state = MediaPlaybackEvent.PLAYBACK_STOPPED;
        export function mediaPlaybackChanged(event){ state = event.state; }
        export function update(v){ return state == MediaPlaybackEvent.PLAYBACK_PLAYING ? 1 : 0; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene), "MediaPlaybackEvent 미심 → 로드 실패했었다")
        XCTAssertEqual(e.evaluateVec(current: [0])?.first, 0)
        e.callHook("mediaPlaybackChanged", eventJS: "new MediaPlaybackEvent({ state: 1 })")
        XCTAssertEqual(e.evaluateVec(current: [0])?.first, 1)
    }

    /// 2881558311 ColorTinter 계약: mediaThumbnailChanged 의 primaryColor 는 Vec3 —
    /// newColor.subtract(oldColor).multiply(t).add(oldColor) 체이닝이 성립해야 한다.
    func testMediaThumbnailEventPrimaryColorVec3Chaining() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        let newColor = new Vec3(0, 0, 0);
        let oldColor = new Vec3(0, 0, 0);
        export function update(v) { return newColor.subtract(oldColor).multiply(1.0).add(oldColor); }
        export function mediaThumbnailChanged(event) { oldColor = newColor; newColor = event.primaryColor; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene))
        e.callHook("mediaThumbnailChanged",
                   eventJS: "new MediaThumbnailEvent({ primaryColor: new Vec3(0.5, 0.25, 1.0), hasThumbnail: true })")
        let c = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))
        XCTAssertEqual(c[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(c[1], 0.25, accuracy: 1e-4)
        XCTAssertEqual(c[2], 1.0, accuracy: 1e-4)
    }

    /// 썸네일 이벤트 기본값: 색 필드는 항상 Vec3(미지정도 안전), hasThumbnail=false.
    func testMediaThumbnailEventDefaults() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        var got = -1;
        export function mediaThumbnailChanged(e){ got = (e.hasThumbnail ? 1 : 0) + e.primaryColor.x + e.textColor.x; }
        export function update(v){ return got; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene))
        e.callHook("mediaThumbnailChanged", eventJS: "new MediaThumbnailEvent()")
        // hasThumbnail=false(0) + primary 0 + textColor 1(밝은 기본 흰 텍스트)
        XCTAssertEqual(e.evaluateVec(current: [0])?.first ?? -1, 1, accuracy: 1e-4)
    }

    /// 타임라인/속성/상태 이벤트: 실물 필드 소비 재현(position/duration 초, title/albumTitle/albumArtist).
    func testTimelinePropertiesStatusEvents() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let s = """
        var txt = '';
        export function mediaTimelineChanged(e){ txt = parseInt(e.position / 60) + ':' + (e.position % 60) + '/' + e.duration; }
        export function mediaPropertiesChanged(e){ txt = e.title + '|' + e.albumTitle + '|' + e.albumArtist; }
        export function mediaStatusChanged(e){ txt = e.enabled ? 'on' : 'off'; }
        export function update(v){ return txt; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: s, scene: scene))
        e.callHook("mediaTimelineChanged", eventJS: "new MediaTimelineEvent({ position: 75, duration: 200 })")
        XCTAssertEqual(e.evaluate(current: ""), "1:15/200")
        e.callHook("mediaPropertiesChanged",
                   eventJS: "new MediaPropertiesEvent({ title: 'T', albumTitle: 'AL', albumArtist: 'AA' })")
        XCTAssertEqual(e.evaluate(current: ""), "T|AL|AA")
        e.callHook("mediaStatusChanged", eventJS: "new MediaStatusEvent({ enabled: true })")
        XCTAssertEqual(e.evaluate(current: ""), "on")
    }

    /// 훅 내부 예외는 로깅 후 무시 — 엔진/컨텍스트 오염 없음.
    func testHookExceptionDoesNotPoison() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function cursorClick(ev){ throw new Error('boom'); }
        export function update(v){ return 'ok'; }
        """, scene: scene))
        e.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(0,0,0) })")
        XCTAssertEqual(e.evaluate(current: ""), "ok")
        // 미보유 훅 호출은 no-op.
        e.callHook("mediaTimelineChanged", eventJS: "new MediaTimelineEvent()")
    }

    /// 단독 컨텍스트 모드(웹/텍스트 호환)에서도 훅이 잡혀야 한다.
    func testStandaloneModeCapturesHooks() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var t = '';
        export function update(v){ return t; }
        export function mediaPropertiesChanged(ev){ t = ev.artist; }
        """))
        XCTAssertTrue(e.hookNames.contains("mediaPropertiesChanged"))
        e.callHook("mediaPropertiesChanged", eventJS: "new MediaPropertiesEvent({ artist: 'AR' })")
        XCTAssertEqual(e.evaluate(current: ""), "AR")
    }

    // MARK: - 사운드 트리거 브리지(getLayer/enumerateLayers → 네이티브 트랜스포트)

    private func soundScene(_ names: [String]) throws -> (SceneScriptContext, SceneAudioPlayer) {
        let scene = try XCTUnwrap(SceneScriptContext(soundNames: names))
        let pkg = ScenePackage.assemble([(name: "sounds/s.wav", data: SceneAudioPlayerTests.silentWAV())])
        let audio = SceneAudioPlayer()
        audio.start(sounds: names.map {
            SceneSound(id: 1, name: $0, sounds: ["sounds/s.wav"], volume: 0.5,
                       playbackMode: "single", startSilent: true, minTime: 0, maxTime: 0)
        }, package: pkg, settingVolume: 0)
        scene.soundTransport = audio
        return (scene, audio)
    }

    /// getLayer(사운드명) 이 사운드 레이어를 반환하고 .play() 가 실제 트랜스포트로 위임된다(단독 트리거).
    func testGetLayerSoundTriggerPlaysTransport() throws {
        let (scene, audio) = try soundScene(["dial.wav"])
        let e = try XCTUnwrap(TextScriptEngine(
            script: "export function cursorClick(ev){ thisScene.getLayer('dial.wav').play(); }", scene: scene))
        XCTAssertFalse(audio.isPlaying(name: "dial.wav"))
        e.callHook("cursorClick", eventJS: "({ worldPosition: new Vec3(0,0,0), button: 0 })")
        XCTAssertTrue(audio.isPlaying(name: "dial.wav"), "getLayer('dial.wav').play() → 트랜스포트 재생")
        audio.teardown()
    }

    /// 주크박스 패턴: enumerateLayers().filter(name.includes('.mp3')) → play/isPlaying/.volume 세터가
    /// 전부 네이티브 트랜스포트로 왕복(상태가 진짜 — play 전 isPlaying false, 후 true).
    func testEnumerateLayersJukeboxPattern() throws {
        let (scene, audio) = try soundScene(["song1.mp3"])
        let js = """
        var found = null;
        export function update(v){
            thisScene.enumerateLayers().forEach(function(el){ if (el.name.indexOf('.mp3') >= 0) { found = el; } });
            if (!found) { return 'none'; }
            var before = found.isPlaying() ? '1' : '0';
            found.play();
            found.volume = 0.3;
            return before + (found.isPlaying() ? '1' : '0');
        }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: js, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "01", "enumerate 로 곡 발견, play 전 미재생→후 재생")
        XCTAssertTrue(audio.isPlaying(name: "song1.mp3"))
        XCTAssertEqual(audio.volume(name: "song1.mp3"), 0.3, accuracy: 1e-6, "스크립트 .volume 세터가 트랜스포트 반영")
        audio.teardown()
    }

    /// 트랜스포트 미연결(헤드리스/캡처)이면 getLayer(사운드).play() 는 안전 no-op(예외/크래시 없음).
    func testSoundTriggerWithoutTransportIsSafeNoOp() throws {
        let scene = try XCTUnwrap(SceneScriptContext(soundNames: ["x.wav"]))   // soundTransport 미연결
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v){
            var l = thisScene.getLayer('x.wav');
            l.play(); l.stop(); l.volume = 0.5;
            return l.isPlaying() ? 'playing' : 'silent';
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "silent", "미연결 브리지는 isPlaying false, 크래시 없음")
    }

    /// F702(S-8): 훅 인자 props 는 원시값 맵(WE 계약 — engine.userProperties 와 동일, 코퍼스 58씬 직접 비교).
    func testLifecycleEntrypointsAreGatedAndExcludedFromGenericHooks() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var trace = ['top'];
        export function applyUserProperties(props) {
            trace.push('apply:' + props.enabled + ':' + props.amount + ':' + props.label);
        }
        export function init(value) { trace.push('init:' + value); }
        export function update(value) {
            trace.push('update:' + value);
            return trace.join('|');
        }
        export function cursorEnter(event) { trace.push('enter'); }
        export function animationEvent(event) { trace.push('animation:' + event.name + ':' + event.frame); }
        """))

        XCTAssertEqual(e.hookNames, Set(["cursorEnter", "animationEvent"]))
        XCTAssertFalse(e.hookNames.contains("init"))
        XCTAssertFalse(e.hookNames.contains("applyUserProperties"))

        e.applyUserProperties(#"{"enabled":{"value":false},"amount":{"value":0},"label":{"value":""}}"#)
        XCTAssertEqual(
            e.evaluate(current: "first"),
            "top|apply:false:0:|init:first|update:first"
        )

        e.applyUserProperties(#"{"enabled":{"value":true},"amount":{"value":99},"label":{"value":"again"}}"#)
        e.callHook("applyUserProperties", eventJS: #"({"enabled":{"value":true}})"#)
        e.callHook("init", eventJS: "'generic-bypass'")
        e.callHook("cursorEnter", eventJS: "({ worldPosition: new Vec3(1, 2, 0) })")
        e.callHook("animationEvent", eventJS: "new AnimationEvent({ name: 'intro', frame: 2 })")

        XCTAssertEqual(
            e.evaluate(current: "second"),
            "top|apply:false:0:|init:first|update:first|enter|animation:intro:2|update:second"
        )
    }
}
