import XCTest
@testable import WapleCore
@testable import WapleRender

/// 씬 스크립트 API 표면 대조(docs/re/scene-script-api.md) 중 **동봉 도달이 있는 갭**의 회귀 묶음.
///
/// 각 테스트가 대조 근거를 인용한다:
///  · 선언 — `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`(파일:행)
///  · 실물 — wallpaper64.exe VA(imagebase 0x140000000) 또는 scenescript64.dll VA(0x180000000)
///  · 도달 — 동봉 `Sources/WapleRender/Resources/WEAssets` 안의 스크립트
///
/// 다루는 갭(동봉 도달 순):
///  · ITextLayer.pointsize/font(d.ts:1606·1611, exe 등록부 0x140258CA0) — 심에 아예 없었다.
///  · IScene.createLayer(d.ts:2175, DLL 0x181633290) — 설정 객체를 통째로 버렸다.
///  · IScene.sortLayer(d.ts:2180, DLL 0x181634EB0) — 인자를 버리고 씬을 돌려줬다(반환형 Boolean).
///  · IScene.getLayerIndex(d.ts:2185, DLL 0x181635200) — 문자열 인자를 못 받았다.
///  · IEffect.executeMaterialFunction(d.ts:1295, exe 0x1401EE3A0–0x1401EE51B) — 인자를 버렸다.
final class SceneScriptAPISurfaceTests: XCTestCase {

    // MARK: ITextLayer.pointsize / font  (동봉 도달 각 2)

    /// d.ts:1606·1611 의 `pointsize: Number` / `font: String`. exe 등록부 0x140258CA0–0x14025A713 이
    /// 텍스트 레이어 프로퍼티로 둘 다 건다. 종전 심의 레이어 객체에는 이 두 키가 **없어서**
    /// `thisLayer.pointsize` 가 undefined → 그 값을 쓰는 산술이 전부 NaN 이었다.
    func testTextLayerPointSizeAndFontAreReadable() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "clock", text: "<3D Clock>",
                                       pointSize: 24, font: "fonts/Monofur-PK7og.ttf")
        ]))
        let size = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return thisLayer.pointsize; }",
            scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(size.evaluateVec(current: [0])).first ?? -1, 24, accuracy: 1e-5,
                       "ITextLayer.pointsize(d.ts:1606)는 디스크립터 실값이어야")
        let font = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return thisLayer.font; }",
            scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(font.evaluate(current: ""), "fonts/Monofur-PK7og.ttf",
                       "ITextLayer.font(d.ts:1611)는 디스크립터 실값이어야")
    }

    /// 디스크립터가 값을 안 주면 SceneDocument 의 텍스트 파스 폴백과 같은 기본값
    /// (pointsize 16 · font "systemfont_arial" — SceneDocument.swift:1794-1795)이어야 한다.
    /// undefined 가 아니어야 한다는 것이 핵심이다 — undefined 는 산술을 NaN 으로 오염시킨다.
    func testTextLayerPointSizeAndFontDefaultsAreNotUndefined() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [SceneScriptLayerDescriptor(name: "a")]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                return (typeof thisLayer.pointsize === 'number' && isFinite(thisLayer.pointsize)
                        && typeof thisLayer.font === 'string' && thisLayer.font.length > 0)
                       ? thisLayer.pointsize : -1;
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0])).first ?? -1, 16, accuracy: 1e-5)
    }

    /// 프레임 말 갱신(__updateSceneLayers)에서도 두 값이 따라와야 한다 — 마운트 경로만 고치면
    /// 첫 프레임과 이후 프레임의 값이 갈린다(layersJSONArray 주석의 단위 경계와 같은 함정).
    func testTextLayerPointSizeFollowsLiveDescriptorUpdate() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "a", pointSize: 16, font: "systemfont_arial")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return thisLayer.pointsize; }",
            scene: scene, currentLayerIndex: 0))
        scene.updateSceneLayers([
            SceneScriptLayerDescriptor(name: "a", pointSize: 48, font: "fonts/Other.ttf")
        ])
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0])).first ?? -1, 48, accuracy: 1e-5)
    }

    // MARK: IScene.createLayer(설정 객체)  (동봉 도달 2)

    /// d.ts:2175 `createLayer(configuration: String|Object|IAssetHandle|IModelData)`.
    /// 동봉 `presets/clock/preview3dclock/scene.json` 의 텍스트 스크립트 init 이 그림자 레이어를
    /// 설정 객체로 만든다(text/color/alpha/pointsize/font/perspective). 종전 심은 인자를
    /// `String(name || '')` 로 밟아 이름이 "[object Object]" 가 되고 나머지는 전부 버려졌다.
    func testCreateLayerAppliesObjectConfiguration() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "3D Clock", text: "<3D Clock>",
                                       pointSize: 24, font: "fonts/Monofur-PK7og.ttf")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            var s;
            export function init() {
                s = thisScene.createLayer({ text: 'shadow', color: '0 0 0', alpha: 1,
                                            pointsize: thisLayer.pointsize, font: thisLayer.font,
                                            perspective: true });
            }
            export function update(v) {
                return [s.pointsize, s.color.x, s.alpha, s.perspective ? 1 : 0,
                        s.text === 'shadow' ? 1 : 0, s.font === thisLayer.font ? 1 : 0];
            }
            """, scene: scene, currentLayerIndex: 0))
        let out = try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0]))
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out[0], 24, accuracy: 1e-5, "pointsize 가 설정 객체에서 와야")
        XCTAssertEqual(out[1], 0, accuracy: 1e-5, "color 는 \"0 0 0\" 문자열 파스(Vec3)")
        XCTAssertEqual(out[2], 1, accuracy: 1e-5, "alpha")
        XCTAssertEqual(out[3], 1, accuracy: 1e-5, "perspective")
        XCTAssertEqual(out[4], 1, accuracy: 1e-5, "text")
        XCTAssertEqual(out[5], 1, accuracy: 1e-5, "font")
    }

    /// 문자열 인자는 종전 경로 그대로여야 한다(무회귀) — 설정 객체 지원이 이름 생성 규약을 바꾸지 않는다.
    func testCreateLayerStringArgumentUnchanged() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [SceneScriptLayerDescriptor(name: "a")]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                var l = thisScene.createLayer('coin');
                return l.name === 'coin' && thisScene.getLayer('coin') === l ? 1 : 0;
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0])).first ?? -1, 1, accuracy: 1e-5)
    }

    // MARK: IScene.sortLayer / getLayerIndex  (동봉 도달 각 2)

    /// d.ts:2180 `sortLayer(layer, index): Boolean`. 종전은 인자를 전부 버리고 씬(truthy)을 돌려줬다.
    /// 유효한 대상/인덱스면 true, 못 찾은 대상이면 false 여야 한다.
    func testSortLayerReturnsBooleanAndRecordsIndex() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "clock"), SceneScriptLayerDescriptor(name: "post")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                var ok = thisScene.sortLayer(thisScene.getLayer('post'), 0);
                var bad = thisScene.sortLayer('nope', 0);
                var nan = thisScene.sortLayer(thisScene.getLayer('post'), 'x');
                var idx = thisScene.getLayer('post').__wapleSortIndex;
                return [ok === true ? 1 : 0, bad === false ? 1 : 0, nan === false ? 1 : 0, idx];
            }
            """, scene: scene, currentLayerIndex: 0))
        let out = try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0, 0]))
        XCTAssertEqual(out, [1, 1, 1, 0], "sortLayer 는 Boolean 을 돌려주고 요청 위치를 기록해야")
    }

    /// d.ts:2185 `getLayerIndex(layer: String|ILayer): Number` — 문자열도 받는다.
    /// WE 동봉 dino_run 의 `thisScene.getLayerIndex('postprocess')` 가 종전엔 항상 0 이었다.
    func testGetLayerIndexAcceptsStringAndLayer() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "a"), SceneScriptLayerDescriptor(name: "b"),
            SceneScriptLayerDescriptor(name: "postprocess")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                return [thisScene.getLayerIndex('postprocess'),
                        thisScene.getLayerIndex(thisScene.getLayer('b')),
                        thisScene.getLayerIndex('missing')];
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0])), [2, 1, 0],
                       "문자열/객체 모두 실 인덱스, 못 찾으면 종전과 같이 0")
    }

    // MARK: IEffect.executeMaterialFunction  (동봉 자산 도달 1 — fluidsimulation)

    /// d.ts:1295 `executeMaterialFunction(propertyName: String): void`.
    /// 실물 0x1401EE3A0–0x1401EE51B 은 이름으로 `functions[]` 를 찾아 그 FBO 들을 클리어한다.
    /// 심은 요청을 호출 순서대로 적재하고 네이티브가 드레인한다 — 종전 `return e` 는 이름조차 안 봤다.
    func testExecuteMaterialFunctionRecordsNamesInCallOrder() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) { return v; }
            thisObject.executeMaterialFunction('clearVelocity');
            thisObject.executeMaterialFunction('clearDye');
            thisObject.executeMaterialFunction('clearVelocity');
            """,
            owner: .effect(materials: [["raythreshold": [0.5]], ["rayintensity": [0.4]]])))
        XCTAssertEqual(engine.drainMaterialFunctionCalls(),
                       ["clearVelocity", "clearDye", "clearVelocity"],
                       "호출 순서와 중복이 보존돼야(실물은 호출마다 1회 클리어)")
    }

    /// 드레인은 **읽으면 비운다** — 매 프레임 소비자가 같은 요청을 두 번 실행하면 안 된다.
    func testExecuteMaterialFunctionDrainIsConsuming() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) { return v; }
            thisObject.executeMaterialFunction('clearDye');
            """, owner: .effect(materials: [[:]])))
        XCTAssertEqual(engine.drainMaterialFunctionCalls(), ["clearDye"])
        XCTAssertEqual(engine.drainMaterialFunctionCalls(), [], "두 번째 드레인은 비어야")
    }

    /// 이름이 문자열이 아니거나 비면 적재하지 않는다(실물도 문자열 비교로 못 찾으면 아무 일도 안 한다).
    /// 상한 64: 이름은 JS 인자라 신뢰 경계 밖이다 — 무한 적재를 막는다.
    func testExecuteMaterialFunctionIgnoresNonStringAndCaps() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) { return v; }
            thisObject.executeMaterialFunction('');
            thisObject.executeMaterialFunction(null);
            thisObject.executeMaterialFunction(42);
            for (var i = 0; i < 200; i += 1) { thisObject.executeMaterialFunction('x'); }
            """, owner: .effect(materials: [[:]])))
        XCTAssertEqual(engine.drainMaterialFunctionCalls().count, 64,
                       "비문자열/빈 이름은 무시하고 적재는 64 로 상한")
    }

    /// 레이어 프로퍼티 스크립트(owner == .layer — 전체의 대다수)는 항상 빈 배열이어야 한다(호출자 무영향).
    func testDrainIsEmptyForLayerOwnedScripts() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return v; }"))
        XCTAssertEqual(engine.drainMaterialFunctionCalls(), [])
    }

    /// 이펙트 상수 되읽기(boundObjectMaterialWrites)가 함수 적재 때문에 오염되면 안 된다 —
    /// `__waple` 접두 키는 되읽기에서 제외된다.
    func testMaterialWritesUnaffectedByFunctionCalls() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) { return v; }
            thisObject.executeMaterialFunction('clearDye');
            thisObject.getMaterial(0).raythreshold = 0.75;
            """, owner: .effect(materials: [["raythreshold": [0.5]]])))
        let writes = engine.boundObjectMaterialWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0]["raythreshold"] ?? [], [0.75])
        XCTAssertNil(writes[0]["__wapleFunctionCalls"])
    }

    // MARK: 실물 함수 테이블 대조

    /// 동봉 `effects/fluidsimulation/effect.json` 이 정의하는 두 함수가 스크립트 이름 그대로
    /// EffectManifest.function(named:) 으로 풀려야 한다 — drainMaterialFunctionCalls 의 소비 규약
    /// (이름 → fboIndices → 클리어 예약)이 실제로 성립하는지 확인한다.
    func testBundledFluidSimulationFunctionsResolveByScriptName() throws {
        let root = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory, "동봉 WEAssets 없음")
        let url = root.appendingPathComponent("effects/fluidsimulation/effect.json")
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(EffectManifest.parse(data))
        for name in ["clearVelocity", "clearDye"] {
            let fn = try XCTUnwrap(manifest.function(named: name), "\(name) 이 파스돼야")
            XCTAssertEqual(fn.action, .clear, "원본이 아는 action 은 clear 하나뿐(0x1401E845A)")
            XCTAssertFalse(fn.fboIndices.isEmpty, "인덱스가 비면 항목 자체가 안 생긴다(0x1401E884A)")
            for i in fn.fboIndices {
                XCTAssertTrue(i >= 0 && i < manifest.fbos.count, "fbo 인덱스는 파스된 목록 범위 안")
            }
        }
        XCTAssertNil(manifest.function(named: "clearNothing"), "없는 이름은 nil(실물도 무시)")
    }
}
