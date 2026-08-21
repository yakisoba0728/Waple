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

    /// 디스크립터가 값을 안 주면 `SceneDocument.parseText` 의 폴백과 같은 기본값
    /// (**pointsize 32** · font "systemfont_arial")이어야 한다.
    /// undefined 가 아니어야 한다는 것이 핵심이다 — undefined 는 산술을 NaN 으로 오염시킨다.
    ///
    /// **[2026-08-21] 16 → 32.** 옛 기대값 16 은 Waple 의 파스 폴백이 16 이던 시절 것이고,
    /// 그 16 자체가 WE 와 어긋나 있었다 — 텍스트 오브젝트 생성자 `0x140256bf2`
    /// (`mov dword [rdi+0x4e0], 0x42000000`)가 **32.0** 을 심는다. 이 테스트의 취지는
    /// "기본값이 파스 폴백과 같고 undefined 가 아니다" 이지 특정 숫자가 아니므로, 폴백을
    /// 따라 올린다. (줄번호 인용도 낡아 있어 심볼 인용으로 바꿨다.)
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
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0])).first ?? -1, 32, accuracy: 1e-5)
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
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0])), [2, 1, -1],
                       "문자열/객체 모두 실 인덱스, 못 찾으면 -1(BO: 실물 0x181635525 = Smi -1)")
    }

    /// **BO(2026-08-21)** — `getLayerIndex` 의 실패 반환은 0 이 아니라 **-1** 이다.
    ///
    /// 실물 콜백 `scenescript64.dll` `0x181635200`(imagebase 0x180000000). 실패 경로 셋이 한 자리로 모인다:
    ///  · 인자 0개 — `0x18163545f  cmp dword [rdi], 1` / `jl 0x181635525`
    ///  · args[0] 이 Object(`0x180016c40`)·Number(`0x180016c70`)·String(instance type<0x80) 중
    ///    어느 것도 아님 — `0x1816354ab  jae 0x181635525`
    ///  · 공통 인자 해석기 `0x1816372d0` 이 nullptr — `0x1816354c6  je 0x181635525`
    /// 그리고 `0x181635525  mov qword [rdi+0x30], 0xfffffffffffffffe`. `[rdi+0x30]` 이 반환값 슬롯이고
    /// 성공 경로가 `0x1816354e8  add rax, rax` 로 값을 싣는 데서 보듯 Smi 태깅은 value*2 라
    /// `0xfffffffffffffffe` = **-1**. 0 은 "0번 레이어" 라는 유효한 답이라 실패와 구분되지 않는다.
    func testGetLayerIndexFailureIsMinusOne() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "a"), SceneScriptLayerDescriptor(name: "b")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                return [thisScene.getLayerIndex('nope'),       // 이름 불일치
                        thisScene.getLayerIndex({ name: 'x' }), // 씬에 없는 객체
                        thisScene.getLayerIndex(9),             // 범위 밖 인덱스
                        thisScene.getLayerIndex(1)];            // 유효 인덱스는 그대로
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0, 0])), [-1, -1, -1, 1],
                       "실패 셋은 전부 -1, 유효 인덱스는 보존")
    }

    /// **BO(2026-08-21)** — `getLayer(String)` 은 이름 조회에 실패하면 **base-10 정수로 파싱해 id 조회**한다.
    ///
    /// 공통 인자 해석기 `scenescript64.dll` `0x1816372d0`:
    ///  · String → 호스트 vtable `+0x8`(이름). 실패 시 `0x181637348  call 0x1817465c4`(strtoll, r8d=0xa)
    ///    → `0x181637357  call [r8+0x10]`(id).
    ///  · Number → `+0x18`(인덱스) · Object → 내부 필드 언랩 · 그 외 → nullptr.
    /// 공식 스니펫(`script_project_attachment.js`)이 id 를 `'{{ID}}'` 처럼 **문자열로** 심으므로
    /// 그 값이 `getLayer` 로 흘러들 수 있다 — 종전 심은 이름 불일치로 합성 폴백(씬에 없는 유령)을 줬다.
    func testGetLayerStringFallsBackToNumericId() throws {
        var a = SceneScriptLayerDescriptor(name: "a"); a.id = 7
        var b = SceneScriptLayerDescriptor(name: "b"); b.id = 42
        let scene = try XCTUnwrap(SceneScriptContext(layers: [a, b]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                var byId = thisScene.getLayer('42');
                var byName = thisScene.getLayer('a');
                return byId.name + '|' + byName.name;
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(engine.evaluate(current: ""), "b|a",
                       "숫자 문자열은 id 로, 그 밖은 이름으로 해석")
    }

    /// **BO(2026-08-21)** — `sortLayer` 의 두 번째 인자는 **반드시 Number** 다.
    ///
    /// `0x181635165  lea rcx, [rdi+0x58]`(= args[1]) · `0x181635169  call 0x180016c70`(Value::IsNumber)
    /// · `0x18165816e  test al,al` / `je` → 실패 루트. 숫자 문자열('0')도 IsNumber 가 아니라 거부다.
    /// 인자 2개 미만도 같은 자리로 간다(`0x18163510f  cmp dword [rdi], 2` / `jge`).
    /// 실패 반환은 `[isolate+0x388]` = **false**(루트 표 undefined 0x368 · the_hole 0x370 ·
    /// null 0x378 · true 0x380 · false 0x388 — `isRunningInEditor` `0x181654d17` 의
    /// `[r8 + rdx*8 + 0x380]` 이 같은 표를 쓴다).
    func testSortLayerRequiresNumericIndex() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "a"), SceneScriptLayerDescriptor(name: "b")
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(
            script: """
            export function update(v) {
                return [thisScene.sortLayer('b', 0) === true ? 1 : 0,
                        thisScene.sortLayer('b', '0') === false ? 1 : 0,
                        thisScene.sortLayer('b') === false ? 1 : 0,
                        thisScene.sortLayer('b', 3) === true ? thisScene.getLayer('b').__wapleSortIndex : -1];
            }
            """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0, 0])), [1, 1, 1, 3],
                       "숫자만 통과 · 인자 부족은 false · 성공은 위치 기록")
    }

    // MARK: ILocalStorage  (설치본 도달 — dino_run 이 set/get 을 LOCATION_GLOBAL 로 쓴다)

    /// **BO(2026-08-21)** — `localStorage.set(key, undefined)` 은 **delete 와 같다**.
    ///
    /// 실물 `0x181658680`(LocalStorageSet):
    ///  · `0x18165876c  mov rdx, [r15]` — args[1](인자 1개면 `[isolate+0x368]` = undefined)
    ///  · `0x181658781  mov r10d, 0x83` / `0x181658787  cmp word [rax+rcx+7], r10w` — Oddball 타입
    ///  · `0x18165878f  mov eax, [rdx+0x17]` / `sar eax, 1` / `cmp eax, 4` — Oddball **kind 4 = undefined**
    ///  · `0x18165879c  call 0x181658f70` — 곧 `localStorage.delete` 콜백으로 꼬리호출
    /// 그리고 `delete` 의 반환은 Boolean 이다(`0x1816590bc  call [rax+0xd8]` → `neg al`/`sbb rcx,rcx`
    /// → `0x1816590cb  mov rcx, [rax + rcx*8 + 0x388]` = true(+0x380)/false(+0x388), d.ts:2371).
    func testLocalStorageSetUndefinedErasesAndDeleteReturnsBoolean() throws {
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            localStorage.set('hi', 5);
            var before = localStorage.get('hi');
            localStorage.set('hi', undefined);          // = delete
            var after = localStorage.get('hi') === undefined ? 1 : 0;
            localStorage.set('again', 1);
            localStorage.set('again');                  // 인자 1개도 undefined = delete
            var after2 = localStorage.get('again') === undefined ? 1 : 0;
            localStorage.set('d', 1);
            var d1 = localStorage.delete('d') === true ? 1 : 0;
            var d2 = localStorage.delete('never') === false ? 1 : 0;
            return [before, after, after2, d1 + d2];
        }
        """))
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0, 0, 0, 0])), [5, 1, 1, 2],
                       "undefined 대입은 삭제, delete 는 Boolean")
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

    // MARK: T-G15 — 디스크립터가 실값을 안 받아 API 기본값이 조용히 들어가던 표면

    /// `SceneScriptLayerDescriptor` 에 자리가 없어 JS 심의 하드코딩 기본값이 저작값 대신 보이던
    /// 필드 전수(= `pointsize` 가 늘 16 이던 G15 와 같은 부류). 근거는 `docs/re/scene-script-api.md` §9.
    ///
    ///  · `color`(d.ts:1586 ITextLayer · :1785 IImageLayer) — 종전 항상 (1,1,1)
    ///  · `parallaxDepth`(d.ts:2039 ILayer) — 종전 심에 **프로퍼티 자체가 없어** undefined
    ///  · `alignment`(d.ts:1790 IImageLayer, exe 0x140211070) — 종전 부재
    ///  · `perspective`(d.ts:1565) · `horizontalalign`(:1621) · `verticalalign`(:1626) ·
    ///    `anchor`(:1632) · `padding`(:1616) · `opaquebackground`(:1596) · `backgroundcolor`(:1601) ·
    ///    `limitrows`/`maxrows`(:1637·1642) · `limitwidth`/`maxwidth`(:1647·1652)
    func testStaticLayerSurfaceFollowsDescriptor() throws {
        var d = SceneScriptLayerDescriptor(name: "t", text: "hi", pointSize: 48, font: "fonts/X.ttf")
        d.color = SIMD3<Float>(0.25, 0.5, 0.75)
        d.parallaxDepth = SIMD2<Float>(2, 3)
        d.alignment = "bottomleft"
        d.perspective = true
        d.horizontalAlign = "left"
        d.verticalAlign = "top"
        d.anchor = "center"
        d.padding = SIMD2<Float>(4, 8)
        d.opaqueBackground = true
        d.backgroundColor = SIMD3<Float>(0.1, 0.2, 0.3)
        d.limitRows = true
        d.maxRows = 7
        d.limitWidth = true
        d.maxWidth = 123
        let scene = try XCTUnwrap(SceneScriptContext(layers: [d]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var l = thisLayer;
            return [l.color.x, l.color.y, l.color.z,
                    l.parallaxDepth.x, l.parallaxDepth.y,
                    l.alignment === 'bottomleft' ? 1 : 0,
                    l.perspective ? 1 : 0,
                    l.horizontalalign === 'left' ? 1 : 0,
                    l.verticalalign === 'top' ? 1 : 0,
                    l.anchor === 'center' ? 1 : 0,
                    l.padding.x, l.padding.y,
                    l.opaquebackground ? 1 : 0,
                    l.backgroundcolor.x, l.backgroundcolor.y, l.backgroundcolor.z,
                    l.limitrows ? 1 : 0, l.maxrows,
                    l.limitwidth ? 1 : 0, l.maxwidth];
        }
        """, scene: scene, currentLayerIndex: 0))
        let got = try XCTUnwrap(engine.evaluateVec(current: [0]))
        let want: [Float] = [0.25, 0.5, 0.75, 2, 3, 1, 1, 1, 1, 1, 4, 8, 1, 0.1, 0.2, 0.3, 1, 7, 1, 123]
        XCTAssertEqual(got.count, want.count)
        for (i, w) in want.enumerated() where i < got.count {
            XCTAssertEqual(got[i], w, accuracy: 1e-5, "성분 \(i)")
        }
    }

    /// 디스크립터 미지정 시 기본값은 심 하드코딩값(= 파스 폴백)과 같고 **undefined 가 아니다**.
    /// undefined 는 산술을 NaN 으로 오염시켜 스크립트 결과 전체를 무효로 만든다.
    func testStaticLayerSurfaceDefaultsAreDefined() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [SceneScriptLayerDescriptor(name: "a")]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var l = thisLayer;
            return [l.color.x, l.parallaxDepth.x, l.parallaxDepth.y,
                    typeof l.alignment === 'string' && l.alignment.length > 0 ? 1 : 0,
                    l.padding.x, l.padding.y, l.maxrows, l.maxwidth];
        }
        """, scene: scene, currentLayerIndex: 0))
        let got = try XCTUnwrap(engine.evaluateVec(current: [0]))
        // padding 은 **vec2 다**(d.ts:1616 의 `Number` 는 선언 오류). 텍스트 디스크립터 등록
        // 0x140259421 이 타입 태그 1(vec2, 멤버 +0x4e8)이고, 생성자 0x140256bbf/0x140256bc9 가
        // (32,32) 를 심는다 — `SceneTextLayer.padding` 폴백과 같다.
        XCTAssertEqual(got, [1, 1, 1, 1, 32, 32, 1, 500])
    }

    /// 프레임 말 라이브 갱신(`updateSceneLayers`)은 **정적 표면을 건드리지 않는다** — 마운트에서
    /// 실린 값이 그대로 남고 live 채널(visible/alpha/origin/scale/angles)만 움직인다.
    /// (라이브 경로가 정적 키를 안 싣는 것은 매 프레임 직렬화 비용 때문이다 — `layersJSONArray(full:)`.)
    func testLiveUpdateDoesNotResetStaticSurface() throws {
        var d = SceneScriptLayerDescriptor(name: "a", alpha: 1)
        d.color = SIMD3<Float>(0.25, 0.5, 0.75)
        d.anchor = "center"
        d.maxWidth = 123
        let scene = try XCTUnwrap(SceneScriptContext(layers: [d]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return [thisLayer.color.x, thisLayer.anchor === 'center' ? 1 : 0,
                    thisLayer.maxwidth, thisLayer.alpha];
        }
        """, scene: scene, currentLayerIndex: 0))
        scene.updateSceneLayers([SceneScriptLayerDescriptor(name: "a", alpha: 0.25)])
        let got = try XCTUnwrap(engine.evaluateVec(current: [0]))
        XCTAssertEqual(got, [0.25, 1, 123, 0.25])
    }

    // MARK: IScene.getLayerByID — 공식 스니펫은 **문자열**을 넘긴다

    /// d.ts:2138 은 `getLayerByID(id: String)` 이고, WE 편집기가 붙여 넣는 공식 스니펫
    /// `ui/dist/monaco/snippets/script_project_attachment.js` 가 `getLayerByID('{{ID}}')` 로
    /// **따옴표 안에** 정수 id 를 심는다. 종전 심의 `__wapleId === id` 는 number === string 이라
    /// 그 형태에서 항상 null 이었다.
    func testGetLayerByIDAcceptsStringAndNumber() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "root", id: 0),
            SceneScriptLayerDescriptor(name: "puppet", id: 4242)
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            var byString = thisScene.getLayerByID('4242');
            var byNumber = thisScene.getLayerByID(4242);
            return [byString && byString.name === 'puppet' ? 1 : 0,
                    byNumber && byNumber.name === 'puppet' ? 1 : 0,
                    thisScene.getLayerByID('9999') === null ? 1 : 0,
                    thisScene.getLayerByID(0) === null ? 1 : 0];
        }
        """, scene: scene, currentLayerIndex: 0))
        // 마지막 항: __wapleId 0 = "id 미지정" 이라 0 질의가 무명 레이어를 잡으면 안 된다.
        XCTAssertEqual(try XCTUnwrap(engine.evaluateVec(current: [0])), [1, 1, 1, 1])
    }

    // MARK: IEffectLayer.transformAttachmentToTexture — 부재로 스크립트 전체가 죽던 자리

    /// d.ts:1555 · exe `0x1401ed0d0`. 종전 심에 **없어서** 공식 스니펫
    /// `script_project_attachment.js` / `..._angle.js` 가 첫 update 에서
    /// `TypeError: thisLayer.transformAttachmentToTexture is not a function` 으로 죽었다
    /// (공식 스니펫 15개 중 도달 2건). 부착점 본 트랜스폼은 렌더 경로 소유라 심이 계산할 근거가
    /// 없으므로 `getEffect`/`getVideoTexture` 와 같은 no-op 프록시 규약이다 — **죽지만 않는다**.
    /// 결과값은 수치가 아니라 nil(= "직전 값 유지")이 되어 그림은 종전 정적 위치와 같다.
    func testProjectAttachmentSnippetDoesNotThrow() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "eye", id: 11),
            SceneScriptLayerDescriptor(name: "puppet", id: 4242)
        ]))
        // WE 공식 스니펫 원문에서 {{ID}}/{{NAME}} 만 치환한 형태.
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        'use strict';

        export function update() {
            return thisLayer.transformAttachmentToTexture(thisScene.getLayerByID('4242'), 'head').translation();
        }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertNil(engine.evaluateVec(current: [1, 2]),
                     "수치가 아닌 반환은 nil = 직전 값 유지(예외로 죽지 않는 것이 핵심)")
        // 같은 스크립트를 두 번 돌려도 컨텍스트가 오염되지 않는다.
        XCTAssertNil(engine.evaluateVec(current: [1, 2]))
    }

    // MARK: 훅 테이블 대조 — scenescript64.dll 0x1819a3ee0 (19엔트리)

    /// 실물 훅 이름 테이블은 **19개**이고 소비자 `0x18164bfa0` 가 `cmp r14, 0x13`(`0x18164c65e`)로
    /// 그만큼 돈다. `d.ts` `IComponent` 는 17개만 선언한다(`animationEvent` id 6 · `cursorHitTest`
    /// id 7 누락). Waple 은 그중 `cursorHitTest` 하나만 일부러 뺀다 — exe 어디에서도 발화되지 않는
    /// 죽은 훅이다(`docs/re/pointer-interaction.md` §5.1 W-13).
    func testEventHookSurfaceMatchesRealHookTable() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [SceneScriptLayerDescriptor(name: "a")]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) { return v; }
        export function resizeScreen(size) { }
        export function destroy() { }
        export function applyGeneralSettings(s) { }
        export function cursorEnter(e) { }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(engine.hookNames,
                       Set(["resizeScreen", "destroy", "applyGeneralSettings", "cursorEnter"]),
                       "훅 테이블 id 2·3·5 도 수집돼야 한다(발화 배선은 렌더러 몫)")
        XCTAssertFalse(TextScriptEngine.eventHookNames.contains("cursorHitTest"),
                       "id 7 은 실물이 발화하지 않는다 — 수집 대상이 아니다")
        XCTAssertTrue(TextScriptEngine.eventHookNames.contains("animationEvent"),
                      "id 6 은 d.ts 에 없지만 실물이 발화한다")
    }

    // MARK: T-G15 배선 — 씬 문서 → 디스크립터 (`SceneRenderer.sceneScriptLayers(from:)`)

    /// **위 `testStaticLayerSurfaceFollowsDescriptor` 가 못 잡는 자리다.** 그 테스트는 디스크립터를
    /// 손으로 만들어 심 표면만 본다 — `fdc21e8` 이 디스크립터에 자리를 만들고도 실값을 안 채우던
    /// 동안 그 테스트는 초록이었다(`docs/re/scene-script-api.md` §9 이 "잡히는 유일한 지점" 이라고
    /// 적어 둔 표가 이것이다). 여기서는 **실 `SceneDocument.parse` 를 통과시켜** 저작값이 끝까지
    /// 가는지 본다. `sceneScriptLayers(from:)` 는 순수 static 이라 Metal/마운트가 필요 없다.
    private func parsedDoc(_ sceneJSON: String, extra: [(String, Data)] = []) throws -> SceneDocument {
        try SceneDocument.parse(package: ScenePackage.assemble(
            [(name: "scene.json", data: Data(sceneJSON.utf8))] + extra.map { (name: $0.0, data: $0.1) }))
    }

    func testAuthoredSceneValuesReachTheScriptDescriptor() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":7,"name":"img","image":"models/a.json","origin":"100 200 30","size":"64 32",
            "scale":"2 3 4","angles":"10 20 90","color":"0.25 0.5 0.75","parallaxDepth":"0.3 0.4",
            "alignment":"topleft","perspective":true,"parent":3,"solid":false},
           {"id":9,"name":"txt","text":"hi","font":"fonts/X.ttf","pointsize":48,"parent":7,
            "origin":"11 22 33","scale":"1 1 5","angles":"0 0 45","parallaxDepth":"0.6 0.7",
            "color":"0.1 0.2 0.3","horizontalalign":"right","verticalalign":"top",
            "anchor":"topcenter","padding":"7 9","opaquebackground":true,
            "backgroundcolor":"0.9 0.8 0.7","limitrows":true,"maxrows":4,
            "limitwidth":true,"maxwidth":123}
         ]}
        """
        let d = SceneRenderer.sceneScriptLayers(from: try parsedDoc(scene, extra: [
            ("models/a.json", Data(#"{"material":"materials/a.json"}"#.utf8)),
            ("materials/a.json", Data(#"{"passes":[{"textures":["a"]}]}"#.utf8)),
        ]))
        XCTAssertEqual(d.count, 2, "이미지 1 + 텍스트 1(이미지 먼저 — layersJSONArray 인덱스 규약)")

        let img = d[0]
        XCTAssertEqual(img.id, 7); XCTAssertEqual(img.parentId, 3)
        XCTAssertEqual(img.color, SIMD3<Float>(0.25, 0.5, 0.75))
        XCTAssertEqual(img.parallaxDepth, SIMD2<Float>(0.3, 0.4))
        XCTAssertEqual(img.alignment, "topleft")
        XCTAssertTrue(img.perspective)
        XCTAssertFalse(img.solid, "ILayer.solid = 플래그워드 +0x120 bit13(ctor 기본 true)")
        XCTAssertEqual(img.origin.z, 30)
        XCTAssertEqual(img.scale.z, 4, "종전엔 1 로 하드코딩됐다")
        XCTAssertNotEqual(img.angles.x, 0, "종전엔 (0,0,angleZ) 였다")
        XCTAssertNotEqual(img.angles.y, 0)

        let t = d[1]
        XCTAssertEqual(t.id, 9, "텍스트 id 미배선이면 getLayerByID 와 부모 배선이 동시에 막힌다")
        XCTAssertEqual(t.parentId, 7, "미배선이면 getParent() 가 언제나 루트")
        XCTAssertEqual(t.origin.z, 33)
        XCTAssertEqual(t.scale.z, 5)
        XCTAssertNotEqual(t.angles.z, 0)
        XCTAssertEqual(t.parallaxDepth, SIMD2<Float>(0.6, 0.7))
        XCTAssertEqual(t.color, SIMD3<Float>(0.1, 0.2, 0.3))
        XCTAssertEqual(t.horizontalAlign, "right")
        XCTAssertEqual(t.verticalAlign, "top")
        XCTAssertEqual(t.anchor, "topcenter")
        XCTAssertEqual(t.padding, SIMD2<Float>(7, 9))
        XCTAssertTrue(t.opaqueBackground)
        XCTAssertEqual(t.backgroundColor, SIMD3<Float>(0.9, 0.8, 0.7))
        XCTAssertTrue(t.limitRows);  XCTAssertEqual(t.maxRows, 4)
        XCTAssertTrue(t.limitWidth); XCTAssertEqual(t.maxWidth, 123)
        XCTAssertEqual(t.pointSize, 48); XCTAssertEqual(t.font, "fonts/X.ttf")
    }

    /// 실물은 **게이트가 꺼져 있어도 저작값을 멤버에 그대로 싣는다.** 적용 루프 `0x1401731d0` 이
    /// JSON 멤버 이름을 해시해 디스크립터를 찾고 `0x140173398` `call qword [rax+8]` 로 **그 키의
    /// 주입기 하나만** 부르기 때문이다 — `maxrows` 주입기 `0x1401a4930`(int, `mov [r14+rbp], eax`)은
    /// `+0x594` 를 읽지 않고, `limitrows` 주입기 `0x14025aca0`(`or ecx,8`)은 `+0x510` 을 읽지 않는다.
    /// 게이트를 보는 것은 **소비부뿐**이다(레이아웃 요청 조립 `0x1402574aa` `test cl,8`).
    ///
    /// **종전 이 테스트는 그 반대를 단언했다**(`maxRows == 1` / `maxWidth == 500`). 그건 실물 규약이
    /// 아니라 **Waple 이 값을 접어 버리던 [미해결] 을 단언으로 굳혀 둔 것**이었고, 주석이 스스로
    /// 그렇게 적어 두고 있었다. `6a83b9a`(파스에서 게이트/값 분리) + `docs/re/text-layer.md` §11.2 ①
    /// (`sceneScriptLayers` 조립부가 값 멤버를 직독)으로 저작값이 이제 끝까지 간다.
    func testUncheckedRowAndWidthLimitsStillCarryTheAuthoredValues() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"x","font":"systemfont_arial","pointsize":32,
                     "origin":"0 0 0","scale":"1 1","limitrows":false,"maxrows":9,
                     "limitwidth":false,"maxwidth":999}]}
        """
        let t = SceneRenderer.sceneScriptLayers(from: try parsedDoc(scene))[0]
        XCTAssertFalse(t.limitRows);  XCTAssertEqual(t.maxRows, 9, "게이트가 꺼져도 값 멤버는 저작값")
        XCTAssertFalse(t.limitWidth); XCTAssertEqual(t.maxWidth, 999)

        // 키 자체가 없을 때만 생성자 기본값이다 — `maxrows` `0x140256c2e` `mov dword [rdi+0x510], 1`,
        // `maxwidth` `0x140256c1a` `mov dword [rdi+0x508], 0x43fa0000`(= 500.0f).
        let bare = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":2,"name":"u","text":"x","font":"systemfont_arial","pointsize":32,
                     "origin":"0 0 0","scale":"1 1"}]}
        """
        let b = SceneRenderer.sceneScriptLayers(from: try parsedDoc(bare))[0]
        XCTAssertFalse(b.limitRows);  XCTAssertEqual(b.maxRows, 1)
        XCTAssertFalse(b.limitWidth); XCTAssertEqual(b.maxWidth, 500)
    }

    /// 저작이 없으면 파스 폴백 == 디스크립터 기본값 == 심 하드코딩값이어야 한다(무회귀 가드).
    func testUnauthoredSceneKeepsShimDefaults() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"x","font":"systemfont_arial","pointsize":32,
                     "origin":"0 0 0","scale":"1 1"}]}
        """
        let t = SceneRenderer.sceneScriptLayers(from: try parsedDoc(scene))[0]
        XCTAssertEqual(t.color, SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(t.horizontalAlign, "center")
        XCTAssertEqual(t.verticalAlign, "center")
        XCTAssertEqual(t.anchor, "none")
        XCTAssertEqual(t.padding, SIMD2<Float>(32, 32), "ctor 0x140256bbf/0x140256bc9 = 32.0")
        XCTAssertFalse(t.opaqueBackground)
        XCTAssertEqual(t.backgroundColor, SIMD3<Float>(0, 0, 0))
        XCTAssertTrue(t.solid, "solid ctor 기본 true(bit13, 0x1401ddc72 리터럴 0x2001)")
        XCTAssertEqual(t.parallaxDepth, SIMD2<Float>(1, 1))
    }
}
