import XCTest
@testable import WapleCore
@testable import WapleRender

/// 씬 스크립트 엔진(TextScriptEngine) 갭 수정 회귀 묶음 — 각 테스트가 재현체 실물 패턴을 인용한다.
/// 대상: S-6 frametime 실델타(F700) · S-7 localStorage(F701) · S-8 applyUserProperties 원시값(F702)
/// · S-39 timeOfDay(F703) · S-40 setTimeout 취소함수+setInterval(F704) · S-41 Vec3 reflect/normalize(F705)
/// · S-42 WEVector(F706) · S-32 getTransformMatrix(F707) · S-33 getAnimationLayerCount(F708)
/// · S-34 thisLayer 인덱스 바인딩(F709) · S-35 getLayer 라이브 갱신(F710) · S-36 getParent 실부모(F711)
/// · S-38 init 반환값 적용(F712) · S-31 input.cursorWorldPosition 폴터(F713).
final class TextScriptEngineSceneFixRegressionTests: XCTestCase {

    // MARK: S-6 / F700 — engine.frametime 실델타

    /// setRuntime 절대시각 주입으로 frametime 이 실델타(0.016 하드코딩 아님)가 되고,
    /// 같은 t 재호출(공유 컨텍스트 다중 엔진)에서는 0 으로 리셋되지 않는다.
    func testFrametimeTracksRealDelta() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return engine.frametime; }", scene: scene))
        let b = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return engine.frametime; }", scene: scene))
        // 30fps 프레임 시각 주입: t=0 → t=1/30 → t=2/30.
        a.setRuntime(0)
        a.setRuntime(1.0 / 30.0)
        XCTAssertEqual(try XCTUnwrap(a.evaluateVec(current: [0])).first ?? -1, Float(1.0 / 30.0), accuracy: 1e-5,
                       "frametime 은 실델타 1/30 이어야(종전 0.016 하드코딩)")
        // 같은 t 로 두 번째 엔진 호출(인코더의 엔진별 setRuntime 재호출 패턴) — 델타 유지, 0 리셋 금지.
        b.setRuntime(1.0 / 30.0)
        XCTAssertEqual(try XCTUnwrap(b.evaluateVec(current: [0])).first ?? -1, Float(1.0 / 30.0), accuracy: 1e-5)
        // 다음 프레임 진행 — 델타 갱신 지속.
        a.setRuntime(2.0 / 30.0)
        XCTAssertEqual(try XCTUnwrap(a.evaluateVec(current: [0])).first ?? -1, Float(1.0 / 30.0), accuracy: 1e-5)
        // 시간 후퇴(루프/리셋) 시에는 마지막 델타 유지(0/음수 리셋 아님).
        a.setRuntime(0)
        XCTAssertEqual(try XCTUnwrap(a.evaluateVec(current: [0])).first ?? -1, Float(1.0 / 30.0), accuracy: 1e-5)
    }

    /// setRuntime 미호출 소비자(단독 평가 — ScalarConstantScriptTests 패턴)는 초기값 0.016 유지(무회귀).
    func testFrametimeDefaultUnchangedWithoutSetRuntime() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return engine.frametime; }", scene: scene))
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, Float(0.016), accuracy: 1e-6)
    }

    // MARK: S-7 / F701 — localStorage 전역

    /// 실물 3367988661(miDragable) init 첫행 `localStorage.get(...)` 패턴이 ReferenceError 없이 완주하고
    /// shared.* 초기화가 연쇄로 살아있는지 — 부재 시 init 전체 사망이 재현되던 결함.
    func testLocalStorageKeepsInitChainAlive() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'isMovable', value: false }).finish();
        export function init() {
            shared.miDragable = localStorage.get("miDragable");
            shared.miDragable = shared.miDragable == undefined ? scriptProperties.isMovable : shared.miDragable;
            return localStorage.get("storedPos") || thisLayer.origin;
        }
        export function cursorUp(event) { localStorage.set("storedPos", thisLayer.origin); }
        export function update(value) { return shared.miDragable ? 1 : 0; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script, scene: scene),
                              "localStorage 부재 시 init ReferenceError — 엔진 자체는 로드돼야 함")
        // 저장값 부재 → isMovable 기본값(false) 폴터 → update 는 0.
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [1])).first ?? -1, 0, accuracy: 1e-6)
    }

    /// get/set/delete/clear 왕복 + LOCATION 상수 노출.
    func testLocalStorageRoundTrip() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var r = [];
            r.push(localStorage.get('k') === undefined ? 'u' : 'bad');
            localStorage.set('k', 7);
            r.push(localStorage.get('k'));
            localStorage.delete('k');
            r.push(localStorage.get('k') === undefined ? 'u' : 'bad');
            localStorage.set('a', 1); localStorage.set('b', 2); localStorage.clear();
            r.push(localStorage.get('a') === undefined ? 'u' : 'bad');
            r.push(localStorage.LOCATION_GLOBAL + '/' + localStorage.LOCATION_SCREEN);
            return r.join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "u,7,u,u,global/screen")
    }

    // MARK: S-8 / F702 — applyUserProperties 훅 인자 원시값

    /// 실물 관용구 `changedUserProperties.mode === 2`(래퍼 아닌 원시값 직접 비교)가 참이어야 한다.
    /// 종전 {type,value} 래퍼 그대로 전달 → `props.mode` 가 객체여서 비교 false/NaN 굳음.
    func testApplyUserPropertiesHookReceivesRawValues() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var applied = -1;
        export function applyUserProperties(props) {
            if (props.mode !== undefined) { applied = (props.mode === 2) ? 1 : 0; }
        }
        export function update(v) { return applied; }
        """, scene: scene))
        e.applyUserProperties(#"{"mode":{"type":"combo","value":2}}"#)
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-6,
                       "훅 인자는 원시값 맵이어야(props.mode === 2)")
        // engine.userProperties 도 원시값(기존 계약 무회귀).
        let g = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return engine.userProperties.mode; }", scene: scene))
        g.applyUserProperties(#"{"mode":{"type":"combo","value":2}}"#)
        XCTAssertEqual(try XCTUnwrap(g.evaluateVec(current: [0])).first ?? -1, 2, accuracy: 1e-6)
    }

    // MARK: S-39 / F703 — engine.timeOfDay

    /// timeOfDay 는 [0,1] 실수 — 캡처 핀(정오 epoch)으로 고정하면 0.5(±경계 허용)여야 한다.
    func testTimeOfDayReflectsWallClock() throws {
        // UTC 정오 — 로컬 타임존 무관하게 [0,1] 범위와 단조성만 검증(로컬 시각 의존 회피).
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var t = engine.timeOfDay;
            return (typeof t === 'number' && t >= 0 && t < 1) ? 1 : 0;
        }
        """, scene: scene))
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-6,
                       "engine.timeOfDay 는 [0,1] 실수여야(종전 noopProxy 산술 0)")
    }

    /// 캡처 핀(captureDateEpochMillis) 시 timeOfDay 도 고정된다 — 스냅샷 결정성 계약.
    func testTimeOfDayPinnedUnderCapture() throws {
        // 2024-01-01 06:00:00 UTC = 1704088800000 ms — 로컬 시각으로 변환돼도 같은 날 같은 시각.
        TextScriptEngine.captureDateEpochMillis = 1_704_088_800_000
        defer { TextScriptEngine.captureDateEpochMillis = nil }
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) { return engine.timeOfDay; }
        """, scene: scene))
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute, .second],
                                            from: Date(timeIntervalSince1970: 1_704_088_800))
        let expect = Float(comps.hour! * 3600 + comps.minute! * 60 + comps.second!) / 86400
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, expect, accuracy: 1e-3)
    }

    // MARK: S-40 / F704 — setTimeout 취소함수 + setInterval

    /// WE 계약: setTimeout 은 취소용 콜백 반환 — 실물 관용구 `stopTimeout();` 이 TypeError 없이 취소해야.
    /// clearTimeout(숫자 id/취소함수) 하위호환도 유지.
    func testSetTimeoutReturnsCancelCallback() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var fired = [];
        var stopA = engine.setTimeout(function(){ fired.push('a'); }, 500);
        engine.setTimeout(function(){ fired.push('b'); }, 500);
        if (stopA) { stopA(); }   // 실물 MI 패밀리 관용구 — 숫자 반환이면 여기서 TypeError
        var dead = engine.setTimeout(function(){ fired.push('x'); }, 100);
        engine.clearTimeout(dead);   // 취소함수를 clearTimeout 에 넘기는 형태도 수용
        export function update(v) { return fired.join(''); }
        """, scene: scene))
        e.setRuntime(2.0)
        XCTAssertEqual(e.evaluate(current: ""), "b", "취소된 a/x 는 미발화")
    }

    /// setInterval: 매 주기 반복 발화 + 반환된 취소함수로 중단.
    func testSetIntervalFiresRepeatedlyUntilCancelled() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var ticks = 0;
        var stop = engine.setInterval(function(){ ticks += 1; if (ticks >= 4) { stop(); } }, 500);
        export function update(v) { return ticks; }
        """, scene: scene))
        e.setRuntime(0.4)
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 0, accuracy: 1e-6)
        e.setRuntime(1.1)   // 0.5, 1.0 만기(추격 발화)
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 2, accuracy: 1e-6)
        e.setRuntime(2.2)   // 1.5, 2.0 만기
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 4, accuracy: 1e-6)
        // 취소(4회 도달 시 stop()) 후에는 시간이 지나도 정지.
        e.setRuntime(5.0)
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0])).first ?? -1, 4, accuracy: 1e-6)
    }

    // MARK: S-41 / F705 — Vec3 reflect/normalize

    func testVec3ReflectAndNormalize() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var d = new Vec3(1, -1, 0);
            var r = d.reflect(new Vec3(0, 1, 0));          // 수평면 반사 → (1, 1, 0)
            var n = new Vec3(3, 0, 4).normalize();          // 길이 5 → (0.6, 0, 0.8)
            var zero = new Vec3(0, 0, 0).normalize();       // 영벡터 → (0,0,0) (NaN 아님)
            return [r.x, r.y, r.z, n.x, n.z, zero.x].join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "1,1,0,0.6,0.8,0")
    }

    // MARK: S-42 / F706 — WEVector import 실심

    /// `import * as WEVector from 'WEVector'` 가 실심 바인딩 — 도(degree) 단위 왕복.
    func testWEVectorAngleVector2RoundTrip() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        import * as WEVector from 'WEVector';
        export function update(v) {
            var d = WEVector.angleVector2(90);              // 도 단위 → (0, 1)
            var back = WEVector.vectorAngle2(new Vec2(0, 1));
            var d45 = WEVector.angleVector2(45 + 90);       // 실물 3351163962 패턴(45+k·90) → 135°
            return [d.x.toFixed(3), d.y.toFixed(3), back.toFixed(1), d45.x.toFixed(3), d45.y.toFixed(3)].join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "0.000,1.000,90.0,-0.707,0.707")
    }

    // MARK: S-32 / F707 — getTransformMatrix

    /// m[12]/m[13] = 월드 평행이동 — 부모 합성 포함(실물 `parent.getTransformMatrix().m[13] > canvasSize.y/2`).
    func testGetTransformMatrixComposesParentChain() throws {
        let parent = SceneScriptLayerDescriptor(name: "p", origin: SIMD3(100, 200, 0), id: 10)
        let child = SceneScriptLayerDescriptor(name: "c", origin: SIMD3(5, 6, 0), id: 11, parentId: 10)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [parent, child]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var m = thisScene.getLayer('c').getTransformMatrix();
            var r = thisScene.getLayer('p').getTransformMatrix();
            return [m.m[12], m.m[13], m.m[14], r.m[12], r.m[13]].join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "105,206,0,100,200",
                       "자식 월드 = 부모(100,200) 합성 + 로컬(5,6)")
    }

    /// 스케일된 부모 아래 자식 평행이동은 부모 스케일이 적용된다(월드 = 부모TRS · 로컬).
    func testGetTransformMatrixAppliesParentScale() throws {
        let parent = SceneScriptLayerDescriptor(name: "p", origin: SIMD3(10, 0, 0),
                                                scale: SIMD3(2, 2, 2), id: 10)
        let child = SceneScriptLayerDescriptor(name: "c", origin: SIMD3(5, 5, 0), id: 11, parentId: 10)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [parent, child]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var m = thisScene.getLayer('c').getTransformMatrix();
            return [m.m[12], m.m[13]].join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "20,10", "월드 = (10,0) + 2×(5,5)")
    }

    // MARK: S-33 / F708 — getAnimationLayerCount

    func testGetAnimationLayerCountBound() throws {
        let layer = SceneScriptLayerDescriptor(name: "c", animationLayerCount: 3)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [layer]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return thisLayer.getAnimationLayerCount() + '/' + thisScene.getLayer('c').getAnimationLayerCount();
        }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(e.evaluate(current: ""), "3/3", "TypeError 아닌 실수치 반환")
    }

    // MARK: S-34 / F709 — thisLayer 인덱스 직결

    /// 중복명 레이어 2개: 인덱스 지정 시 스크립트가 붙은 오브젝트 자체에 바인딩(이름 첫 매치 아님).
    func testThisLayerBindsByDescriptorIndex() throws {
        let a = SceneScriptLayerDescriptor(name: "dup", origin: SIMD3(1, 0, 0))
        let b = SceneScriptLayerDescriptor(name: "dup", origin: SIMD3(2, 0, 0))
        let scene = try XCTUnwrap(SceneScriptContext(layers: [a, b]))
        let script = "export function update(v) { return thisLayer.origin.x; }"
        let first = try XCTUnwrap(TextScriptEngine(script: script, scene: scene, currentLayerIndex: 0))
        let second = try XCTUnwrap(TextScriptEngine(script: script, scene: scene, currentLayerIndex: 1))
        XCTAssertEqual(try XCTUnwrap(first.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(second.evaluateVec(current: [0])).first ?? -1, 2, accuracy: 1e-6,
                       "인덱스 미지정이면 둘 다 첫 매치(1)로 오바인딩되던 결함")
        // 무회귀: 인덱스 미지정 + 이름 지정은 종전 이름 조회.
        let legacy = try XCTUnwrap(TextScriptEngine(script: script, scene: scene, currentLayerName: "dup"))
        XCTAssertEqual(try XCTUnwrap(legacy.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-6)
    }

    // MARK: S-35 / F710 — getLayer 라이브 갱신

    /// updateSceneLayers 제자리 갱신: 스크립트가 보관한 참조까지 새 트랜스폼을 읽는다.
    func testUpdateSceneLayersRefreshesLiveReferences() throws {
        let layer = SceneScriptLayerDescriptor(name: "c", alpha: 1, origin: SIMD3(1, 2, 0))
        let scene = try XCTUnwrap(SceneScriptContext(layers: [layer]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var held = null;
        export function update(v) {
            if (!held) { held = thisScene.getLayer('c'); }   // t=0 스냅샷에 굳는지 검사용 보관 참조
            return held.origin.x + ',' + held.alpha;
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "1,1")
        scene.updateSceneLayers([SceneScriptLayerDescriptor(name: "c", alpha: 0.5, origin: SIMD3(9, 2, 0))])
        XCTAssertEqual(e.evaluate(current: ""), "9,0.5",
                       "보관 참조까지 라이브여야(종전 마운트 스냅샷 고정)")
    }

    // MARK: S-36 / F711 — getParent 실부모

    /// 실물 3367988661 `parent = thisLayer.getParent(); container = parent.getParent();` 체인 패턴.
    func testGetParentReturnsWiredParent() throws {
        let grand = SceneScriptLayerDescriptor(name: "grand", id: 20)
        let parent = SceneScriptLayerDescriptor(name: "parent", scale: SIMD3(2, 2, 2), id: 10, parentId: 20)
        let child = SceneScriptLayerDescriptor(name: "child", id: 11, parentId: 10)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [grand, parent, child]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var p = thisLayer.getParent();
            var g = p.getParent();
            return p.name + '/' + g.name + '/' + p.scale.x;
        }
        """, scene: scene, currentLayerIndex: 2))
        XCTAssertEqual(e.evaluate(current: ""), "parent/grand/2",
                       "종전 getParent() 는 항상 root(이름 공백)였다")
        // 부모 id 미존재(비가시 그룹 등) → root 폴터(무회귀·무크래시).
        let orphan = SceneScriptLayerDescriptor(name: "orphan", id: 30, parentId: 999)
        let scene2 = try XCTUnwrap(SceneScriptContext(layers: [orphan]))
        let e2 = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) { return thisLayer.getParent() === thisLayer.getParent() ? 1 : 0; }
        """, scene: scene2, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(e2.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-6)
    }

    // MARK: S-38 / F712 — init 반환값 적용

    /// update 보유 스크립트: init 반환(수정값)이 첫 update 의 current 로 공급된다.
    func testInitReturnFeedsFirstUpdate() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function init(value) { return value + 100; }
        export function update(value) { return value; }
        """, scene: scene))
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [5])).first ?? -1, 105, accuracy: 1e-6,
                       "첫 update 는 init 수정값을 current 로 받아야(WE 계약)")
        // 두 번째부터는 렌더러가 주는 현재값 그대로(init 재발화 없음).
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [5])).first ?? -1, 5, accuracy: 1e-6)
    }

    /// init-only 스크립트(실물 3367988661 드래그 `return localStorage.get(storageName) || thisLayer.origin`):
    /// init 반환값이 바운드 프로퍼티값으로 per-frame 서빙된다(종전 무인자 발화 + 반환 폐기).
    func testInitOnlyScriptServesInitReturn() throws {
        let layer = SceneScriptLayerDescriptor(name: "drag", origin: SIMD3(42, 24, 0))
        let scene = try XCTUnwrap(SceneScriptContext(layers: [layer]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function init() {
            return localStorage.get("storedPos") || thisLayer.origin;
        }
        """, scene: scene, currentLayerIndex: 0))
        e.callInitIfNeeded()   // mount 경로(SceneRenderer: init-only 는 즉시 발화)
        let v = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]),
                              "init 반환(=thisLayer.origin)이 프로퍼티값으로 서빙돼야")
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v[0], 42, accuracy: 1e-6)
        XCTAssertEqual(v[1], 24, accuracy: 1e-6)
        // 반복 호출에도 동일값 유지(1프레임 적용 후 소실 아님).
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0, 0, 0])).first ?? -1, 42, accuracy: 1e-6)
    }

    // MARK: S-31 / F713 — input.cursorWorldPosition 폴터

    /// update() 내 폴터 스타일: noopProxy 붕괴(0/NaN) 대신 실 Vec3 + 네이티브 주입 반영.
    func testInputCursorWorldPositionPolling() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            if (input.cursorWorldPosition) {   // noopProxy 도 truthy — 가드 통과 자체는 증명이 아님
                return input.cursorWorldPosition.x + ',' + input.cursorWorldPosition.y
                    + '/' + input.cursorLeftDown;
            }
            return 'noguard';
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "0,0/false", "미주입 기본값은 실 0/거짓(NaN 아님)")
        scene.setCursorState(worldX: 640, worldY: 360, screenX: 1280, screenY: 720, leftDown: true)
        XCTAssertEqual(e.evaluate(current: ""), "640,360/true")
    }

    // MARK: E1(⑤) — ILayer.getVideoTexture/getParticleSystem/emitParticles·IScene.destroyLayer 안전 심

    /// 종전 이 3개 메서드가 평객체에 부재라 첫 호출에서 TypeError 로 update() 전체가 죽어, 이 반환문에
    /// 도달하지 못했다(정적 visible=false 레이어가 영구 미표시로 굳는 등 후속 스크립트 로직 무력화).
    func testGetVideoTextureAndParticleSystemDoNotThrow() throws {
        let layer = SceneScriptLayerDescriptor(name: "c")
        let scene = try XCTUnwrap(SceneScriptContext(layers: [layer]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var t = thisLayer.getVideoTexture();
            var p = thisLayer.getParticleSystem();
            thisLayer.emitParticles(5);
            return (t ? 'tex' : 'no') + ',' + (p ? 'ps' : 'no') + ',reached';
        }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(e.evaluate(current: ""), "tex,ps,reached")
    }

    /// thisScene.destroyLayer 부재는 TypeError(392) — 이제 안전 제거 + getLayerCount/getLayerByID 동반.
    func testSceneDestroyLayerAndLayerCount() throws {
        let a = SceneScriptLayerDescriptor(name: "a", id: 1)
        let b = SceneScriptLayerDescriptor(name: "b", id: 2)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [a, b]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var before = thisScene.getLayerCount();
            var byId = thisScene.getLayerByID(2);
            thisScene.destroyLayer('b');
            var after = thisScene.getLayerCount();
            return before + ',' + after + ',' + (byId ? byId.getName() : 'null');
        }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(e.evaluate(current: ""), "2,1,b")
    }

    /// destroyLayer 가 splice 로 배열을 줄이면 그 뒤 레이어들의 위치 인덱스가 한 칸씩 밀린다 —
    /// 렌더러 read-back(readBackScriptLayerState)은 이름이 아니라 **위치 인덱스**(=doc.layers 인덱스)로
    /// thisScene.layers[i] 를 직접 읽으므로, 시프트가 나면 인덱스 1 이후 모든 레이어가 다른 레이어의
    /// origin/scale/angles/visible 을 뒤집어쓴다(툼스톤 대신 splice 를 쓰면 이 테스트가 실패해야 한다).
    func testSceneDestroyLayerPreservesSubsequentLayerIndices() throws {
        let a = SceneScriptLayerDescriptor(name: "a", id: 1)
        let b = SceneScriptLayerDescriptor(name: "b", id: 2)
        let c = SceneScriptLayerDescriptor(name: "c", origin: SIMD3<Float>(7, 8, 9), id: 3)
        let scene = try XCTUnwrap(SceneScriptContext(layers: [a, b, c]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            thisScene.destroyLayer('b');
            var atIndex2 = thisScene.layers[2];
            return atIndex2.name + ',' + atIndex2.origin.x + ',' + thisScene.layers.length;
        }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(e.evaluate(current: ""), "c,7,3",
                        "destroyLayer 이후에도 'c' 는 그대로 인덱스 2 를 유지해야(splice 시프트 금지)")
    }

    /// thisScene.createLayer 는 종전과 동일하게 무해 스텁(JS 배열에만 추가, GPU 렌더 미연결)이지만
    /// 이제 크래시 없이 반환값을 계속 조작할 수 있어야 한다(경고 로그는 별도 채널 — 반환 동작만 단언).
    func testCreateLayerStubRemainsHarmlessAndUsable() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var l = thisScene.createLayer('spawned');
            l.setOrigin(new Vec3(1, 2, 0));
            return thisScene.getLayerCount() + ',' + l.getOrigin().x;
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "2,1", "루트+신규 레이어 = 2, 신규 레이어 origin 조작 반영")
    }
}
