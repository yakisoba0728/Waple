import XCTest
@testable import WapleRender

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

    func testWallpaperEngineLifecycleAndAnimationHooksCaptured() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var t = '';
        export function init(value) {}
        export function update(value) { return t; }
        export function applyUserProperties(props) { t += props.mode.value; }
        export function cursorEnter(event) { t += ':enter'; }
        export function cursorLeave(event) { t += ':leave'; }
        export function animationEvent(event) { t += ':' + event.name + ':' + event.frame; }
        """))
        let expected: Set<String> = ["init", "applyUserProperties", "cursorEnter", "cursorLeave", "animationEvent"]

        XCTAssertTrue(expected.isSubset(of: e.hookNames), "missing hooks: \(expected.subtracting(e.hookNames))")

        e.callHook("applyUserProperties", eventJS: "({ mode: { value: 'dark' } })")
        e.callHook("cursorEnter", eventJS: "({ worldPosition: new Vec3(1, 2, 0) })")
        e.callHook("cursorLeave", eventJS: "({ worldPosition: new Vec3(3, 4, 0) })")
        e.callHook("animationEvent", eventJS: "new AnimationEvent({ name: 'intro', frame: 2 })")

        XCTAssertEqual(e.evaluate(current: ""), "dark:enter:leave:intro:2")
    }
}
