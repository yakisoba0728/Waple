import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 씬 공유 JSContext: 씬의 모든 프로퍼티 스크립트가 하나의 컨텍스트를 공유해 `shared` 로 통신한다
/// (실물 3394601417: visible 스크립트의 컨트롤러가 shared.a 를 세팅, 43개 스크립트가 분기).
/// 각 스크립트는 IIFE 로 격리 — update/스크립트 로컬 상태는 클로저에 갇힌다.
final class SceneSharedScriptTests: XCTestCase {
    /// 컨트롤러(top-level 사이드이펙트, update 없음) → 소비자(shared 분기) 통신.
    func testSharedStateFlowsBetweenEngines() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        // 실물 bt.visible 패턴: top-level 에서 shared 초기화, cursorClick 만 export.
        let controller = """
        'use strict';
        let cl=false;
        shared.a=1;
        export function cursorClick(event) { shared.a = cl ? 1 : 0; cl = !cl; }
        """
        let ctrl = try XCTUnwrap(TextScriptEngine(script: controller, scene: scene),
                                 "update 없는 컨트롤러도 로드(사이드이펙트)돼야 함")
        XCTAssertFalse(ctrl.hasUpdate)
        XCTAssertNil(ctrl.evaluate(current: ""))

        // 실물 time_b2.alpha 패턴: shared.a 로 분기.
        let consumer = """
        'use strict';
        export function update(value) { if (shared.a==1) { value=0.2; } else { value=1; } return value; }
        """
        let cons = try XCTUnwrap(TextScriptEngine(script: consumer, scene: scene))
        XCTAssertEqual(try XCTUnwrap(cons.evaluateVec(current: [1])).first ?? -1, 0.2, accuracy: 1e-4)
    }

    /// 스크립트-로컬 상태(var/let, scriptProperties, update 이름)가 엔진 간 충돌하지 않아야 한다.
    func testScriptLocalStateStaysIsolated() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        func src(_ label: String) -> String {
            """
            var counter = 0;
            export var scriptProperties = createScriptProperties().addText({name:'tag', value:'\(label)'}).finish();
            export function update(v) { counter += 1; return scriptProperties.tag + counter; }
            """
        }
        let a = try XCTUnwrap(TextScriptEngine(script: src("A"), scene: scene))
        let b = try XCTUnwrap(TextScriptEngine(script: src("B"), scene: scene))
        XCTAssertEqual(a.evaluate(current: ""), "A1")
        XCTAssertEqual(a.evaluate(current: ""), "A2")   // A 의 counter 만 증가
        XCTAssertEqual(b.evaluate(current: ""), "B1")   // update/counter/scriptProperties 미충돌
        XCTAssertEqual(a.evaluate(current: ""), "A3")
    }

    /// visible 스크립트용 evaluateBool: 부울/숫자(0=false) 반환 해석.
    func testEvaluateBoolForVisibleScripts() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return !v; }", scene: scene))
        XCTAssertEqual(e.evaluateBool(current: false), true)
        XCTAssertEqual(e.evaluateBool(current: true), false)
        let n = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return shared.q ? 1 : 0; }", scene: scene))
        XCTAssertEqual(n.evaluateBool(current: true), false)  // shared.q 미정의 → 0 → false
    }

    /// 깨진 스크립트는 nil, 컨텍스트는 오염되지 않고 계속 사용 가능해야 한다.
    func testSyntaxErrorReturnsNilWithoutPoisoningContext() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        XCTAssertNil(TextScriptEngine(script: "syntax error (((", scene: scene))
        let ok = try XCTUnwrap(TextScriptEngine(script: "export function update(v){ return 'ok'; }", scene: scene))
        XCTAssertEqual(ok.evaluate(current: ""), "ok")
    }

    /// engine.runtime 은 씬 컨텍스트 전역 — setRuntime 이 모든 엔진에 보인다.
    func testEngineRuntimeSharedAcrossEngines() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(script: "export function update(v){ return v + engine.runtime; }", scene: scene))
        a.setRuntime(2)
        XCTAssertEqual(try XCTUnwrap(a.evaluateVec(current: [1])).first ?? 0, 3, accuracy: 1e-4)
    }

    func testInitRunsOnceBeforeFirstUpdateInSharedContext() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var initCount = 0;
        var seed = new Vec3(0, 0, 0);
        export function init(value) {
            initCount += 1;
            seed = value.copy();
            value.x = 99;
        }
        export function update(value) {
            return new Vec3(seed.x + value.x + initCount,
                            seed.y + value.y + initCount,
                            seed.z + value.z + initCount);
        }
        """, scene: scene))

        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [1, 2, 3])), [3, 5, 7])
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [4, 5, 6])), [6, 8, 10])
    }

    func testInitOnlyEngineRunsOnceWithoutArgumentsAndPublishesSharedState() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let initOnly = try XCTUnwrap(TextScriptEngine(script: """
        // F702(S-8): 훅 인자는 원시값 맵(props.theme = "dark") — `.value` 래퍼 접근은 구 계약.
        export function applyUserProperties(props) { shared.theme = props.theme; }
        export function init() {
            shared.initCount = (shared.initCount || 0) + 1;
            shared.initArgumentCount = arguments.length;
        }
        """, scene: scene))

        XCTAssertFalse(initOnly.hasUpdate)
        initOnly.applyUserProperties(#"{"theme":{"type":"text","value":"dark"}}"#)
        initOnly.callInitIfNeeded()
        initOnly.callInitIfNeeded()
        initOnly.callHook("init", eventJS: "'generic-bypass'")
        initOnly.callHook("applyUserProperties", eventJS: #"({"theme":{"value":"light"}})"#)

        let probe = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.theme + '/' + shared.initCount + '/' + shared.initArgumentCount;
        }
        """, scene: scene))
        XCTAssertEqual(probe.evaluate(current: ""), "dark/1/0")
    }

    /// engine.userProperties 는 **원시값**이다 — {type,value} 래퍼가 아니다.
    /// 코퍼스 진실(실측): `engine.userProperties.<KEY>` 65회 등장, `.value` 동반 **0회**. 스크립트는
    /// 원시값을 느슨비교(`== 2`, `!= 0`)로 직접 읽는다. {type,value} 는 project.json `condition` DSL
    /// ("advancesettings.value == true")과 web API(WallpaperBridgeJS)의 형태이지 스크립트 API 가 아니다.
    ///
    /// 스크립트 자체 applyUserProperties 훅이 없어도 update() 안에서 읽혀야 한다(훅 무관 상시 주입).
    /// 아래 스크립트는 실코퍼스 2911866381 축자 인용:
    ///   `if (engine.userProperties.timeofday != 0) { value = engine.userProperties.timeofday - 1; }`
    /// 래퍼를 노출하면 `{obj} != 0` → true(오분기) → `{obj} - 1` → **NaN** → blendValue 오염 → 씬 암전.
    /// noopProxy 폴백도 함께 배제한다(`'' - 0` → 0 ≠ 7).
    func testEngineUserPropertiesExposeRawValuesNotTypeValueWrappers() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            var timeofday = (engine.userProperties.timeofday != 0)
                ? engine.userProperties.timeofday - 1
                : 'day';
            return [timeofday,
                    engine.userProperties.timeofday == 0,
                    engine.userProperties.meteor == false,
                    engine.userProperties.daytime - 0,
                    engine.userProperties.timeofday.value === undefined].join('/');
        }
        """, scene: scene))
        // 2911866381 실 project.json 형태: combo 는 문자열("0"), bool 은 진짜 bool, slider 는 수치.
        e.applyUserProperties(#"{"timeofday":{"type":"combo","value":"0"},"meteor":{"type":"bool","value":false},"daytime":{"type":"slider","value":7}}"#)
        // 래퍼 노출 시: "NaN/false/false/NaN/false" — 오분기 + NaN 전파.
        XCTAssertEqual(e.evaluate(current: ""), "day/true/true/7/true")
    }

    /// 원시값이라도 combo 문자열('2')이 `== 2` 로 참이어야 한다(느슨비교 — 수치 강제변환 금지).
    /// 실코퍼스 3151551777: `engine.userProperties.timeofday == 99`.
    func testEngineUserPropertiesLooseEqualityMatchesComboStrings() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return [engine.userProperties.timeofday == 99,
                    engine.userProperties.timeofday == 1,
                    engine.userProperties.label === 'Both'].join('/');
        }
        """, scene: scene))
        e.applyUserProperties(#"{"timeofday":{"type":"combo","value":"99"},"label":{"type":"text","value":"Both"}}"#)
        XCTAssertEqual(e.evaluate(current: ""), "true/false/true")
    }

    func testThrowingLifecycleFunctionsAreNotRetriedOrCrossContaminateSharedContext() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let throwing = try XCTUnwrap(TextScriptEngine(script: """
        shared.applyAttempts = 0;
        shared.initAttempts = 0;
        export function applyUserProperties(props) {
            shared.applyAttempts += 1;
            throw new Error('apply boom');
        }
        export function init() {
            shared.initAttempts += 1;
            throw new Error('init boom');
        }
        """, scene: scene))

        throwing.applyUserProperties(#"{"mode":{"value":"first"}}"#)
        throwing.applyUserProperties(#"{"mode":{"value":"second"}}"#)
        throwing.callInitIfNeeded()
        throwing.callInitIfNeeded()
        throwing.callHook("applyUserProperties", eventJS: #"({"mode":{"value":"generic"}})"#)
        throwing.callHook("init", eventJS: "({})")

        let lazy = try XCTUnwrap(TextScriptEngine(script: """
        shared.lazyInitAttempts = 0;
        export function init(value) {
            shared.lazyInitAttempts += 1;
            throw new Error('lazy init boom');
        }
        export function update(value) {
            return shared.lazyInitAttempts + '/' + value;
        }
        """, scene: scene))
        XCTAssertNil(lazy.evaluate(current: "first"))
        XCTAssertEqual(lazy.evaluate(current: "second"), "1/second")

        let healthy = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.applyAttempts + '/' + shared.initAttempts + '/healthy';
        }
        """, scene: scene))
        XCTAssertEqual(healthy.evaluate(current: ""), "1/1/healthy")
    }

    func testSceneLayerDescriptorsBackEnumerateLayersAndThisLayer() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "owner"),
            SceneScriptLayerDescriptor(name: "playerbounds", visible: true, alpha: 0.42),
            SceneScriptLayerDescriptor(name: "playeroutlineanim", visible: true, alpha: 1),
            SceneScriptLayerDescriptor(name: "playerhidden", visible: false, alpha: 1),
            SceneScriptLayerDescriptor(name: "tracktitle", visible: true, text: "Song")
        ]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        let playerLayers = [];
        let appearAnim = thisScene.getLayer("playeroutlineanim").getTextureAnimation();
        export function init(value) {
            thisScene.enumerateLayers().forEach(element => {
                if (element.name.includes("player") && element.visible) {
                    playerLayers.push(element);
                }
            });
            thisScene.getLayer("tracktitle").text = "Changed";
            appearAnim.setFrame(3);
        }
        export function update(value) {
            shared.uiopacity = playerLayers[0].alpha;
            return new Vec3(playerLayers.length, shared.uiopacity, thisLayer.name === "owner" ? appearAnim.getFrame() : -1);
        }
        """, scene: scene, currentLayerName: "owner"))

        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))

        XCTAssertEqual(out[0], 2, accuracy: 1e-4)
        XCTAssertEqual(out[1], 0.42, accuracy: 1e-4)
        XCTAssertEqual(out[2], 3, accuracy: 1e-4)
    }

    func testCameraTransformsAndAnimationStateMatch3DScripts() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "3D Camera", visible: true),
            SceneScriptLayerDescriptor(name: "link_child"),
            SceneScriptLayerDescriptor(name: "owner", origin: [2, 0, 0])
        ]))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            const camera = thisScene.getCameraTransforms();
            const delta = camera.center.subtract(camera.eye);
            const surprise = thisScene.getLayer("link_child")
                .getAnimationLayer("Surprise")
                .getAnimation("surprise")
                .isPlaying();
            const targetAngle = Math.atan2(camera.eye.x - thisLayer.origin.x,
                                           camera.eye.z - thisLayer.origin.z);
            return new Vec3(delta.z, surprise ? 1 : 0, targetAngle);
        }
        """, scene: scene, currentLayerName: "owner"))

        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))

        XCTAssertEqual(out[0], -1, accuracy: 1e-4)
        XCTAssertEqual(out[1], 1, accuracy: 1e-4)
        XCTAssertTrue(out[2].isFinite)
    }
}

final class SceneVisibleScriptClassificationTests: XCTestCase {
    func testVectorValuedVisibleScriptsAreDetected() {
        XCTAssertTrue(SceneRenderer.isVectorValuedVisibleScript("""
        export function update(value) {
            value.x = 1;
            value.y = 2;
            return value;
        }
        """))

        XCTAssertTrue(SceneRenderer.isVectorValuedVisibleScript("""
        export function update(value) {
            return new Vec3(value.x, value.y, value.z);
        }
        """))
    }

    func testBoolVisibleScriptsRemainEligible() {
        XCTAssertFalse(SceneRenderer.isVectorValuedVisibleScript("""
        shared.a = 1;
        export function cursorClick(event) { shared.a = shared.a ? 0 : 1; }
        export function update(value) { return shared.a === 1 ? true : value; }
        """))
    }
}

/// 렌더 통합: visible 스크립트 레이어(draw 스킵/부활) + shared 컨트롤러→소비자(실물 3394601417 축소판).
final class SceneVisibleScriptRenderTests: XCTestCase {
    /// 오브젝트: 흰 bg → 초록(alpha 스크립트: shared.a==1 → 1) → 컨트롤러(visible 스크립트 top-level 이
    /// shared.a=1, update 없음) → 빨강 풀스크린(visible 스크립트 false → draw 스킵)
    /// → 파랑 좌반(정적 visible false + 스크립트 true → 부활).
    func testSharedControllerAndVisibleScriptsEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/green.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":0,"script":"'use strict';\\nexport function update(v){ if(shared.a==1){ v=1; } else { v=0; } return v; }"}},
           {"id":3,"image":"models/ctrl.json","origin":"4 4 0","size":"2 2",
            "visible":{"value":true,"script":"'use strict';\\nlet cl=false;\\nshared.a=1;\\nexport function cursorClick(e){ shared.a=cl?1:0; cl=!cl; }"}},
           {"id":4,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v){ return false; }"}},
           {"id":5,"image":"models/blue.json","origin":"480 540 0","size":"960 1080",
            "visible":{"value":false,"script":"'use strict';\\nexport function update(v){ return true; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("green", solidTex(0, 255, 0)),
                            ("ctrl", solidTex(255, 255, 255)), ("red", solidTex(255, 0, 0)),
                            ("blue", solidTex(0, 0, 255))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_sharedjs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "sharedjs", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "sharedjs", tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_sharedjs")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let c = rep.colorAt(x: x, y: y)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        // 우반: 초록(컨트롤러의 shared.a=1 → alpha 1). 빨강(visible false)은 어디에도 없어야.
        let right = px(48, 18)
        XCTAssertGreaterThan(right.g, 0.8, "shared 소비자 alpha 미적용(초록이어야): \(right)")
        XCTAssertLessThan(right.r, 0.2, "빨강 visible-false 레이어가 그려짐: \(right)")
        // 좌반: 파랑(정적 false + 스크립트 true → 부활).
        let left = px(16, 18)
        XCTAssertGreaterThan(left.b, 0.8, "정적 false + 스크립트 true 레이어 미부활(파랑이어야): \(left)")
        XCTAssertLessThan(left.r, 0.2, "빨강 visible-false 레이어가 그려짐: \(left)")
    }
}

final class SceneScriptMountLifecycleTests: XCTestCase {
    private var propertyStoreIDs: [String] = []

    override func tearDown() {
        for id in propertyStoreIDs { UserPropertyStore.reset(id: id) }
        super.tearDown()
    }

    private func makeProject(
        id: String,
        marker: String,
        properties: [String: Any],
        presetOverrides: [String: PropertyValue] = [:]
    ) throws -> WallpaperProject {
        UserPropertyStore.reset(id: id)
        propertyStoreIDs.append(id)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-scene-lifecycle-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let script = """
        function propertyValue(props, key) {
            // F760: 훅 인자는 원시값 맵(F702 신 WE 계약) — `.value` 래퍼 접근은 구 계약이라 undefined 만 나온다.
            return Object.prototype.hasOwnProperty.call(props, key)
                ? String(props[key]) : 'missing';
        }
        shared.order = ['top:\(marker)'];
        export function applyUserProperties(props) {
            shared.payload = [
                propertyValue(props, 'enabled'),
                propertyValue(props, 'amount'),
                propertyValue(props, 'label'),
                propertyValue(props, 'mode'),
                propertyValue(props, 'baseOnly')
            ].join('|');
            shared.order.push('apply:' + Object.keys(props).length);
        }
        export function init() {
            shared.order.push('init:' + arguments.length + ':' + shared.payload);
        }
        export function cursorClick(event) {
            shared.clicks = (shared.clicks || 0) + 1;
        }
        """
        let sceneObject: [String: Any] = [
            "general": [
                "orthogonalprojection": ["width": 320, "height": 180],
                "clearcolor": "0 0 0"
            ],
            "objects": [[
                "name": "lifecycle-\(marker)",
                "text": ["value": "", "script": script],
                "font": "systemfont_arial",
                "pointsize": 16,
                "origin": "10 10 0",
                "scale": "1 1",
                "visible": ["value": true]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: sceneObject, options: [.sortedKeys])
        try encodePkg([("scene.json", sceneData)]).write(to: dir.appendingPathComponent("scene.pkg"))

        let projectObject: [String: Any] = [
            "type": "scene",
            "file": "scene.pkg",
            "general": ["properties": properties]
        ]
        let projectData = try JSONSerialization.data(withJSONObject: projectObject, options: [.sortedKeys])
        try projectData.write(to: dir.appendingPathComponent("project.json"))

        return WallpaperProject(
            id: id,
            type: .scene,
            fileName: "scene.pkg",
            previewName: nil,
            title: id,
            tags: [],
            contentRating: nil,
            workshopId: nil,
            dependency: nil,
            folderURL: dir,
            presetOverrides: presetOverrides
        )
    }

    private func state(in scene: SceneScriptContext) throws -> String {
        let probe = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.order.join(',') + '/' + String(shared.payload) + '/' + String(shared.clicks || 0);
        }
        """, scene: scene))
        return try XCTUnwrap(probe.evaluate(current: ""))
    }

    func testMountDeliversOneEffectiveSnapshotToInitialAndLateEngines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let id = "scene-lifecycle-effective-\(UUID().uuidString)"
        let project = try makeProject(
            id: id,
            marker: "first",
            properties: [
                "enabled": ["type": "bool", "value": true],
                "amount": ["type": "slider", "value": 9.0],
                "label": ["type": "text", "value": "default"],
                "mode": ["type": "text", "value": "default"],
                "baseOnly": ["type": "text", "value": "base"]
            ],
            presetOverrides: [
                "enabled": .bool(false),
                "amount": .number(5),
                "mode": .string("preset")
            ]
        )
        UserPropertyStore.set(.number(0), key: "amount", id: id)
        UserPropertyStore.set(.string(""), key: "label", id: id)
        UserPropertyStore.set(.string("user"), key: "mode", id: id)

        let renderer = SceneRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        let mountedScene = try XCTUnwrap(renderer.sceneScript)
        XCTAssertEqual(
            try state(in: mountedScene),
            "top:first,apply:5,init:0:false|0||user|base/false|0||user|base/0"
        )

        // Mutating persistence after mount must not change the cached snapshot delivered to later engines.
        UserPropertyStore.set(.bool(true), key: "enabled", id: id)
        UserPropertyStore.set(.number(8), key: "amount", id: id)
        UserPropertyStore.set(.string("changed"), key: "label", id: id)
        UserPropertyStore.set(.string("changed"), key: "mode", id: id)

        let late = try XCTUnwrap(renderer.makeScriptEngine("""
        var trace = ['top'];
        var delivered = '';
        export function applyUserProperties(props) {
            delivered = [props.enabled, props.amount, props.label,
                         props.mode, props.baseOnly].join('|');
            trace.push('apply');
        }
        export function init(value) { trace.push('init:' + value); }
        export function update(value) {
            trace.push('update:' + value);
            return trace.join(',') + '/' + delivered;
        }
        """))
        XCTAssertEqual(late.evaluate(current: "A"), "top,apply,init:A,update:A/false|0||user|base")
        XCTAssertEqual(late.evaluate(current: "B"), "top,apply,init:A,update:A,update:B/false|0||user|base")
    }

    // [2026-08-25] `@MainActor` — `simulateCursorClick` 이 `SceneRenderer` 에서 라이브 전용으로
    // 분류돼(메인에서만 불리는 경로) `@MainActor` 가 붙었다. 이 테스트도 같은 계약을 따른다.
    @MainActor func testDirectRemountUsesEmptyObjectAndDoesNotDispatchToStaleEngine() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldProject = try makeProject(
            id: "scene-lifecycle-old-\(UUID().uuidString)",
            marker: "old",
            properties: ["mode": ["type": "text", "value": "old"]]
        )
        let newProject = try makeProject(
            id: "scene-lifecycle-new-\(UUID().uuidString)",
            marker: "new",
            properties: [:]
        )
        let renderer = SceneRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: oldProject)
        defer { renderer.teardown() }

        let oldScene = try XCTUnwrap(renderer.sceneScript)
        let stale = try XCTUnwrap(renderer.eventEngines.first)
        XCTAssertEqual(renderer.eventEngines.count, 1)

        // No explicit teardown: mount itself owns remount cleanup.
        try renderer.mount(in: container, project: newProject)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(renderer.eventEngines.count, 1)
        XCTAssertFalse(renderer.eventEngines.contains { $0 === stale })

        // U-W5b: 커서 훅은 이제 히트한 오브젝트에 바인딩된 스크립트에만 간다(`0x14018a709`–`0x14018a723`).
        // 이 씬의 스크립트는 **텍스트 오브젝트**에 붙어 있고, 텍스트의 히트 상자는 실물에서 래스터된
        // 픽셀 크기인데(`docs/re/scene-script-api.md` §9.1 (b) `size` [미해결]) Waple 은 그 값을 모른다.
        // 그래서 텍스트 소유 대상은 `PointerHit.DeliveryScope.geometryUnknown` = **종전 배달 유지**로
        // 떨어지고, 좌표 (1,1) 은 여기서 여전히 무의미하다. 이 테스트가 보는 것은 좌표가 아니라
        // **리마운트 후 새 엔진이 받고 스테일 엔진은 못 받는다**는 것이므로 의도는 그대로다.
        // 텍스트 히트 기하가 확정되면 이 좌표는 load-bearing 이 된다 — 그때 같이 고쳐야 한다.
        renderer.simulateCursorClick(x: 1, y: 1)
        let newScene = try XCTUnwrap(renderer.sceneScript)
        XCTAssertEqual(
            try state(in: newScene),
            "top:new,apply:0,init:0:missing|missing|missing|missing|missing/missing|missing|missing|missing|missing/1"
        )
        XCTAssertEqual(
            try state(in: oldScene),
            "top:old,apply:1,init:0:missing|missing|missing|old|missing/missing|missing|missing|old|missing/0"
        )
    }
}
