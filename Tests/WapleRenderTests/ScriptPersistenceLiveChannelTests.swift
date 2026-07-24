import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// F810(S-7 잔여) 씬 스크립트 localStorage 디스크 영속 · F811(S-35 잔여) 3D 빌보드 라이브 채널 ·
/// F812 가림 오디오 대칭 회귀 테스트.
final class ScriptPersistenceLiveChannelTests: XCTestCase {

    // MARK: - F810: localStorage 디스크 영속

    private func tempStorageDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-ls-\(UUID().uuidString)", isDirectory: true)
    }

    /// set → flush → 신규 스토어/컨텍스트(= 앱 재시작·리마운트)에서 get 복원 — miDragable 드래그 위치 시나리오.
    func testLocalStoragePersistsAcrossContexts() throws {
        let dir = tempStorageDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store1 = ScriptLocalStorage(sceneId: "3367988661", baseDirectory: dir, debounce: 3600)
        let scene1 = try XCTUnwrap(SceneScriptContext(localStorageStore: store1))
        scene1.context.evaluateScript("localStorage.set('storedPos', { x: 123, y: 45, z: 0 }); localStorage.set('n', 7);")
        store1.flush()   // 마운트 해제(teardown) 경로의 즉시 기록
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("3367988661.json").path),
                      "flush 후 씬 id 키 JSON 파일이 디스크에 있어야")

        // 새 마운트(새 스토어 + 새 JSContext) — 디스크에서 시드돼야 한다.
        let store2 = ScriptLocalStorage(sceneId: "3367988661", baseDirectory: dir, debounce: 3600)
        let scene2 = try XCTUnwrap(SceneScriptContext(localStorageStore: store2))
        let pos = scene2.context.evaluateScript(
            "(function(){ var p = localStorage.get('storedPos'); return p ? p.x + ',' + p.y : 'missing'; })()")?.toString()
        XCTAssertEqual(pos, "123,45", "오브젝트 값(드래그 위치)이 재시작 간에 복원돼야")
        let n = scene2.context.evaluateScript("localStorage.get('n')")?.toString()
        XCTAssertEqual(n, "7", "스칼라 값도 복원돼야")
    }

    /// delete/clear 도 디스크에 반영(종전 인메모리 전용이면 리마운트 시 부활하는 결함).
    func testLocalStorageDeleteAndClearPersist() throws {
        let dir = tempStorageDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store1 = ScriptLocalStorage(sceneId: "s1", baseDirectory: dir, debounce: 3600)
        let scene1 = try XCTUnwrap(SceneScriptContext(localStorageStore: store1))
        scene1.context.evaluateScript("localStorage.set('a', 1); localStorage.set('b', 2); localStorage.delete('a');")
        store1.flush()
        let store2 = ScriptLocalStorage(sceneId: "s1", baseDirectory: dir, debounce: 3600)
        let scene2 = try XCTUnwrap(SceneScriptContext(localStorageStore: store2))
        let r = scene2.context.evaluateScript(
            "(localStorage.get('a') === undefined ? 'u' : 'bad') + '/' + localStorage.get('b')")?.toString()
        XCTAssertEqual(r, "u/2", "delete 는 영속, 나머지 키는 유지돼야")

        scene2.context.evaluateScript("localStorage.clear();")
        store2.flush()
        let store3 = ScriptLocalStorage(sceneId: "s1", baseDirectory: dir, debounce: 3600)
        let scene3 = try XCTUnwrap(SceneScriptContext(localStorageStore: store3))
        let c = scene3.context.evaluateScript("localStorage.get('b') === undefined ? 'u' : 'bad'")?.toString()
        XCTAssertEqual(c, "u", "clear 후엔 모든 키가 비어야")
    }

    /// 실물 3367988661(miDragable) init 계약: `localStorage.get(...) || thisLayer.origin` — 영속된
    /// 드래그 위치가 있으면 레이어 기본 origin 대신 그 값이 init 바인딩으로 서빙돼야 한다(리마운트 복원).
    func testDragPositionRestoredIntoInitBinding() throws {
        let dir = tempStorageDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 이전 마운트: 드래그 종료 시 위치 저장.
        let store1 = ScriptLocalStorage(sceneId: "3367988661", baseDirectory: dir, debounce: 3600)
        let scene1 = try XCTUnwrap(SceneScriptContext(localStorageStore: store1))
        scene1.context.evaluateScript("localStorage.set('storedPos', { x: 123, y: 45, z: 0 });")
        store1.flush()

        // 새 마운트: 같은 씬 id 의 스토어로 시드된 컨텍스트에서 init-only 스크립트 평가.
        let layer = SceneScriptLayerDescriptor(name: "drag", origin: SIMD3(42, 24, 0))
        let store2 = ScriptLocalStorage(sceneId: "3367988661", baseDirectory: dir, debounce: 3600)
        let scene2 = try XCTUnwrap(SceneScriptContext(layers: [layer], localStorageStore: store2))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function init() {
            return localStorage.get("storedPos") || thisLayer.origin;
        }
        """, scene: scene2, currentLayerIndex: 0))
        e.callInitIfNeeded()
        let v = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v[0], 123, accuracy: 1e-6, "영속된 드래그 x 가 레이어 기본값(42)을 이겨야")
        XCTAssertEqual(v[1], 45, accuracy: 1e-6, "영속된 드래그 y 가 레이어 기본값(24)을 이겨야")
    }

    /// 스토어 미주입(기본) — 종전 인메모리 계약 무회귀(컨텍스트 내 왕복만, 디스크 파일 미생성).
    func testLocalStorageWithoutStoreStaysInMemory() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let r = scene.context.evaluateScript(
            "(function(){ localStorage.set('k', 5); return localStorage.get('k'); })()")?.toString()
        XCTAssertEqual(r, "5", "브리지 부재 시에도 인메모리 set/get 은 동작해야(무회귀)")
        XCTAssertNil(scene.localStorageStore)
    }

    // MARK: - F811: 3D 빌보드 라이브 채널

    /// 스크립트로 움직인 3D 빌보드가 liveLayerStates 에 기록되고, pushLiveSceneLayers 가 JS
    /// thisScene.layers 를 제자리 갱신한다(2D encodeLayer/encodeText 의 F743 채널을 encode3D 경로로 완성).
    func testBillboardLiveChannelRecordsAndPushes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":2,"image":"models/solid.json","size":"2 2","color":"1 1 1","alpha":1,
            "origin":{"script":"export function update(value){ value.x = 111; value.y = 55; return value; }"}}
         ]}
        """
        let package = try ScenePackage.parse(encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/solid.json", #"{"material":"materials/solid.json"}"#.data(using: .utf8)!),
            ("materials/solid.json", #"{"passes":[{"shader":"flat"}]}"#.data(using: .utf8)!),
        ]))
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        let descriptors = SceneRenderer.sceneScriptLayers(from: doc)
        renderer.sceneScript = SceneScriptContext(layers: descriptors)
        renderer.sceneScriptBaseDescriptors = descriptors   // mount(:1064)과 동일한 라이브 갱신 기준
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: package, device: device)

        let bb = try XCTUnwrap(renderer.billboards.first, "스크립트 보유 빌보드가 로드돼야")
        XCTAssertEqual(bb.layerIndex, 0, "빌보드의 JS layers 인덱스 = doc.layers 인덱스")
        // build3D 말미 프라이밍(F309, evaluate3DScripts(time: 0))이 이미 라이브 채널에 기록한다.
        let rb = try XCTUnwrap(renderer.liveLayerStates[0],
                               "3D 빌보드도 evaluate3DScripts 가 liveLayerStates 에 기록해야")
        XCTAssertEqual(rb.origin?.x ?? -1, 111, accuracy: 1e-6)
        XCTAssertEqual(rb.origin?.y ?? -1, 55, accuracy: 1e-6)

        renderer.pushLiveSceneLayers()
        XCTAssertTrue(renderer.liveLayerStates.isEmpty, "push 후 큐는 비워져야(F743 소비 계약)")
        let js = renderer.sceneScript?.context
            .evaluateScript("thisScene.layers[0].origin.x + ',' + thisScene.layers[0].origin.y")?.toString()
        XCTAssertEqual(js, "111,55", "JS thisScene.layers[0].origin 이 빌보드 현재값으로 제자리 갱신돼야")
    }

    // MARK: - F812: 가림 오디오 대칭

    /// 가림 게이트의 오디오 배선(occlusionStopAudio/occlusionStartAudioIfNeeded — draw() 가 주입하는
    /// 실제 클로저)이 씬 사운드(sceneAudio)도 정지/재개한다(종전 스펙트럼 캡처만 정지하던 비대칭).
    func testOcclusionGateStopsAndResumesSceneAudio() throws {
        // startsilent+이름 있는 사운드는 디코드 없이 플레이리스트만 등록(SceneAudioPlayer.start :59-63).
        let snd = SceneSound(id: 1, name: "bgm", sounds: ["sounds/x.mp3"], volume: 1,
                             playbackMode: "loop", startSilent: true, minTime: 0, maxTime: 0)
        let player = SceneAudioPlayer()
        player.start(sounds: [snd], package: ScenePackage.assemble([]), settingVolume: 1)
        XCTAssertEqual(player.pausedPlaylistCountForTesting, 0)

        let renderer = SceneRenderer()
        renderer.sceneAudio = player
        renderer.occlusionStopAudio()
        XCTAssertEqual(player.pausedPlaylistCountForTesting, 1, "가림 진입 시 씬 사운드도 정지해야")
        renderer.occlusionStartAudioIfNeeded()
        XCTAssertEqual(player.pausedPlaylistCountForTesting, 0, "가림 해제 시 씬 사운드가 재개돼야")
        renderer.sceneAudio = nil
        renderer.occlusionStopAudio()   // 오디오 없는 씬 — 안전 no-op(무회귀)
    }
}
