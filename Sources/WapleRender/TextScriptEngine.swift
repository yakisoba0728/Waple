import Foundation
import JavaScriptCore
import WapleCore

public struct SceneScriptLayerDescriptor {
    public var name: String
    public var visible: Bool
    public var alpha: Float
    public var origin: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var angles: SIMD3<Float>
    public var size: SIMD2<Float>
    public var solid: Bool
    public var text: String
    /// scene.json objects[] 의 id — JS 측 parent 체인 배선(F711)에 사용. 0 = 미지정(배선 안 함, 무회귀).
    public var id: Int
    /// 부모 오브젝트 id(scene.json parent) — 실 부모 레이어 바인딩(F711). nil = 루트.
    public var parentId: Int?
    /// animationlayers 바인딩 수 — ILayer.getAnimationLayerCount() 실값(F708). 0 = 미지정.
    public var animationLayerCount: Int

    public init(name: String, visible: Bool = true, alpha: Float = 1,
                origin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                angles: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                size: SIMD2<Float> = SIMD2<Float>(1, 1),
                solid: Bool = false, text: String = "",
                id: Int = 0, parentId: Int? = nil, animationLayerCount: Int = 0) {
        self.name = name
        self.visible = visible
        self.alpha = alpha
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.size = size
        self.solid = solid
        self.text = text
        self.id = id
        self.parentId = parentId
        self.animationLayerCount = animationLayerCount
    }
}

/// 씬 단위 공유 JSContext(SceneRenderer mount 당 1개): shims 를 1회 평가하고, 씬의 모든 프로퍼티
/// 스크립트(레이어 color/alpha/visible, 효과 상수, 텍스트)가 이 컨텍스트를 공유한다 — `shared` 전역으로
/// 스크립트 간 통신(실물 3394601417: visible 스크립트의 컨트롤러가 shared.a 를 세팅, 43개 스크립트가 분기).
/// 각 스크립트는 IIFE 로 감싸므로 update/스크립트-로컬 상태는 클로저에 격리된다.
public final class SceneScriptContext {
    let context: JSContext
    /// 사운드 트리거 트랜스포트(라이브 mount 시 SceneRenderer 가 연결). nil 이면 __wapleSound 브리지는 no-op —
    /// 헤드리스/캡처(오디오 미생성)에서 getLayer(사운드).play() 는 안전 무시된다.
    public weak var soundTransport: SceneAudioPlayer?
    /// F810: 씬 스크립트 localStorage 디스크 저장소. nil(기본) = 종전 인메모리 전용(헤드리스/테스트 무회귀).
    public let localStorageStore: ScriptLocalStorage?
    /// E1(⑤): thisScene.createLayer 무해 스텁 경고 — 레이어 이름별 1회만(매 프레임 재호출 스팸 방지).
    private var warnedCreateLayerNames: Set<String> = []

    /// width/height = 프로젝션(캔버스) 크기 — thisScene.size/screenSize/resolution·engine.canvasSize 의
    /// 실값(기본 1920×1080: 기존 호출부 무회귀). SceneRenderer mount 가 doc.projectionWidth/Height 전달.
    public init?(layers: [SceneScriptLayerDescriptor] = [], soundNames: [String] = [],
                 width: Float = 1920, height: Float = 1080,
                 localStorageStore: ScriptLocalStorage? = nil) {
        guard let ctx = JSContext() else { return nil }
        context = ctx
        self.localStorageStore = localStorageStore
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] scene script context exception: \(ex?.toString() ?? "?")")
        }
        // F810: 스토리지 브리지는 shims 평가보다 먼저 — localStorage IIFE 가 평가 시점에 스냅샷으로 시드한다.
        if let store = localStorageStore { installStorageBridge(ctx, store: store) }
        ctx.evaluateScript(TextScriptEngine.shims)
        if let ms = TextScriptEngine.captureDateEpochMillis { ctx.evaluateScript(TextScriptEngine.dateOverrideJS(ms)) }
        ctx.evaluateScript("__setCanvasSize(\(TextScriptEngine.jsNumber(width)), \(TextScriptEngine.jsNumber(height)));")
        if TextScriptEngine.isScreensaver { ctx.evaluateScript("__setScreensaver(true);") }  // 기본 false = 미주입 = 무변화
        installSoundBridge(ctx)
        installWarnBridge(ctx)
        if !layers.isEmpty {
            ctx.evaluateScript("__setSceneLayers(\(Self.layersJSONArray(layers)));")
        }
        let named = soundNames.filter { !$0.isEmpty }
        if !named.isEmpty {
            ctx.evaluateScript("__setSoundLayers(\(Self.stringJSONArray(named)));")
        }
    }

    /// F810(S-7 잔여): localStorage 네이티브 브리지 — shims 의 localStorage IIFE 가 평가 시점에
    /// __wapleStorageSnapshot 으로 시드하고, set/delete/clear 마다 디스크 스토어와 동기화한다.
    /// 블록이 store 를 강참조하지만 store 는 컨텍스트를 참조하지 않아 순환 없음.
    private func installStorageBridge(_ ctx: JSContext, store: ScriptLocalStorage) {
        let snapshot: @convention(block) () -> String = { store.snapshotJSON() }
        let set: @convention(block) (String, String) -> Void = { k, v in store.set(key: k, json: v) }
        let del: @convention(block) (String) -> Void = { k in store.delete(key: k) }
        let clear: @convention(block) () -> Void = { store.clear() }
        ctx.setObject(snapshot, forKeyedSubscript: "__wapleStorageSnapshot" as NSString)
        ctx.setObject(set, forKeyedSubscript: "__wapleStorageSet" as NSString)
        ctx.setObject(del, forKeyedSubscript: "__wapleStorageDelete" as NSString)
        ctx.setObject(clear, forKeyedSubscript: "__wapleStorageClear" as NSString)
    }

    /// JS __wapleSound 가 호출하는 네이티브 전역을 트랜스포트에 연결. [weak self] 로 캡처(JSContext 가
    /// 블록을 보유 — self 강참조면 순환 참조). 값 타입 브리징: Bool/Double 은 JSC 가 그대로 왕복.
    private func installSoundBridge(_ ctx: JSContext) {
        let play: @convention(block) (String) -> Void = { [weak self] n in self?.soundTransport?.play(name: n) }
        let stop: @convention(block) (String) -> Void = { [weak self] n in self?.soundTransport?.stop(name: n) }
        let pause: @convention(block) (String) -> Void = { [weak self] n in self?.soundTransport?.pause(name: n) }
        let isPlaying: @convention(block) (String) -> Bool = { [weak self] n in self?.soundTransport?.isPlaying(name: n) ?? false }
        let getVolume: @convention(block) (String) -> Double = { [weak self] n in Double(self?.soundTransport?.volume(name: n) ?? 0) }
        let setVolume: @convention(block) (String, Double) -> Void = { [weak self] n, v in self?.soundTransport?.setVolume(name: n, Float(v)) }
        ctx.setObject(play, forKeyedSubscript: "__wapleSoundPlay" as NSString)
        ctx.setObject(stop, forKeyedSubscript: "__wapleSoundStop" as NSString)
        ctx.setObject(pause, forKeyedSubscript: "__wapleSoundPause" as NSString)
        ctx.setObject(isPlaying, forKeyedSubscript: "__wapleSoundIsPlaying" as NSString)
        ctx.setObject(getVolume, forKeyedSubscript: "__wapleSoundGetVolume" as NSString)
        ctx.setObject(setVolume, forKeyedSubscript: "__wapleSoundSetVolume" as NSString)
    }

    /// E1(⑤): thisScene.createLayer 무해 스텁 경고 브리지 — 이름별 1회(스팸 방지).
    private func installWarnBridge(_ ctx: JSContext) {
        let warnCreateLayer: @convention(block) (String) -> Void = { [weak self] name in
            guard let self, !self.warnedCreateLayerNames.contains(name) else { return }
            self.warnedCreateLayerNames.insert(name)
            WapleLog.warn("[Waple] thisScene.createLayer(\"\(name)\") — JS 배열에만 추가되고 GPU 렌더 경로가 없어 화면에 나타나지 않습니다")
        }
        ctx.setObject(warnCreateLayer, forKeyedSubscript: "__wapleWarnCreateLayer" as NSString)
    }

    /// 오디오 스펙트럼 실데이터 주입(채널당 64빈): __audioBuffer 를 제자리 갱신(left/right·16/32/64·spectrum)
    /// 후 registerAudioBuffers 콜백 발화. 라이브 오디오 provider onFrame(30fps, main 큐)에서만 호출 —
    /// 캡처/헤드리스는 미호출로 버퍼 0 유지(스냅샷 결정성). 64빈 미만 입력은 JS 쪽 __num 이 0 폴백.
    public func setAudio(left64: [Float], right64: [Float]) {
        context.evaluateScript("__setAudioData(\(Self.floatArrayLiteral(left64)), \(Self.floatArrayLiteral(right64)));")
    }

    /// F713(S-31): input.cursorWorldPosition/cursorScreenPosition 폴터 주입 — 제자리 갱신이라 스크립트가
    /// 보관한 참조도 따라온다. 렌더러의 포인터 이벤트 지점(SceneRenderer dispatchPointerEvent)이 프레임/
    /// 이벤트마다 호출하는 연결점. world = 씬 픽셀(상단 원점), screen = 표현 좌표.
    public func setCursorState(worldX: Float, worldY: Float, screenX: Float, screenY: Float, leftDown: Bool) {
        context.evaluateScript("__setCursorState(\(TextScriptEngine.jsNumber(worldX)), \(TextScriptEngine.jsNumber(worldY)), \(TextScriptEngine.jsNumber(screenX)), \(TextScriptEngine.jsNumber(screenY)), \(leftDown));")
    }

    /// F710(S-35): JS thisScene 레이어를 최신 디스크립터로 **제자리** 갱신 — getLayer 가 반환한 JS 객체를
    /// 스크립트가 쥐고 있어도 라이브 트랜스폼을 읽게 하는 연결점(렌더러가 프레임마다 호출).
    /// 디스크립터 배열 순서는 mount 의 __setSceneLayers 와 동일해야 한다(인덱스 정합).
    public func updateSceneLayers(_ layers: [SceneScriptLayerDescriptor]) {
        context.evaluateScript("__updateSceneLayers(\(Self.layersJSONArray(layers)));")
    }

    private static func floatArrayLiteral(_ values: [Float]) -> String {
        "[" + values.map(TextScriptEngine.jsNumber).joined(separator: ",") + "]"
    }

    private static func stringJSONArray(_ names: [String]) -> String {
        guard JSONSerialization.isValidJSONObject(names),
              let data = try? JSONSerialization.data(withJSONObject: names),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func layersJSONArray(_ layers: [SceneScriptLayerDescriptor]) -> String {
        let objects = layers.map { l -> [String: Any] in
            [
                "name": l.name,
                "visible": l.visible,
                "alpha": Double(l.alpha),
                "origin": [Double(l.origin.x), Double(l.origin.y), Double(l.origin.z)],
                "scale": [Double(l.scale.x), Double(l.scale.y), Double(l.scale.z)],
                "angles": [Double(l.angles.x), Double(l.angles.y), Double(l.angles.z)],
                "size": [Double(l.size.x), Double(l.size.y)],
                "solid": l.solid,
                "text": l.text,
                "id": l.id,
                "parentId": l.parentId ?? NSNull(),
                "animationLayerCount": l.animationLayerCount
            ]
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

/// F810(S-7 잔여): 씬 스크립트 localStorage 디스크 영속 — F701 의 인메모리 저장소를 앱 재시작·리마운트
/// 간에도 복원(miDragable 계열 드래그 위치 등). 저장 위치는 기존 스토어 관례(LibraryStore·변환 캐시와
/// 같은 ~/Library/Application Support/Waple 하위)의 script-storage/<씬 id>.json — 본문은
/// {키: JSON 인코딩 값 문자열} 딕셔너리(값은 JS 측이 JSON.stringify 한 문자열로 왕복, 복원 시 parse).
/// 저장 시점: 값 변경 디바운스(기본 0.75s) + flush()(마운트 해제 경로)의 최소 설계. 쓰기 실패는 로그만
/// (저장 불가가 렌더를 죽이지 않음). WE 의 location 네임스페이스 분리(global/screen)는 의미 미확정 —
/// F701 과 동일하게 단일 네임스페이스로 무시(추측 구현 안 함).
public final class ScriptLocalStorage {
    /// 기본 저장 루트(~/Library/Application Support/Waple/script-storage).
    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Waple/script-storage", isDirectory: true)
    }

    private let fileURL: URL
    private var values: [String: String] = [:]
    private let lock = NSLock()
    private let saveQueue = DispatchQueue(label: "waple.script-localstorage", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private let debounce: TimeInterval

    /// sceneId = 배경 프로젝트 id(워크숍 id 등). 파일명 안전 문자(영숫자 . - _) 외는 '_' 치환.
    /// baseDirectory/debounce 는 테스트 주입용(nil/기본 = Application Support 경로·0.75s).
    public init(sceneId: String, baseDirectory: URL? = nil, debounce: TimeInterval = 0.75) {
        let safe = String(sceneId.map { ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") ? $0 : "_" })
        self.fileURL = (baseDirectory ?? Self.defaultBaseDirectory())
            .appendingPathComponent((safe.isEmpty ? "scene" : safe) + ".json")
        self.debounce = debounce
        if let data = try? Data(contentsOf: fileURL),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            values = dict
        }
    }

    deinit { flush() }

    /// JS 시드용 스냅샷(전체 딕셔너리 JSON 문자열). 직렬화 불가 시 "{}".
    public func snapshotJSON() -> String {
        lock.lock(); let dict = values; lock.unlock()
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    public func set(key: String, json: String) {
        lock.lock(); values[key] = json; lock.unlock()
        scheduleSave()
    }

    public func delete(key: String) {
        lock.lock(); values.removeValue(forKey: key); lock.unlock()
        scheduleSave()
    }

    public func clear() {
        lock.lock(); values.removeAll(); lock.unlock()
        scheduleSave()
    }

    private func scheduleSave() {
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSave?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            self.pendingSave = item
            self.saveQueue.asyncAfter(deadline: .now() + self.debounce, execute: item)
        }
    }

    /// 즉시 동기 저장(마운트 해제/teardown·deinit·테스트). 디바운스 대기분을 흡수하는 최종 기록.
    public func flush() {
        lock.lock(); let dict = values; lock.unlock()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("%@", "[Waple] script localStorage save failed at \(fileURL.path): \(error)")
        }
    }
}

/// WE 텍스트 프로퍼티 스크립트 실행기(JavaScriptCore).
/// 계약(실물): `createScriptProperties()` 빌더(.addCheckbox/.addText/... → .finish() = name→기본값 객체)
/// + `export function update(value) → String`. engine/shared/thisScene 등 엔진 API 는 no-op Proxy 로 심 —
/// 미디어류 스크립트는 데이터가 없어 자연히 빈 문자열을 반환(graceful).
/// ES 모듈 export 구문은 평가 전에 제거(JSC 는 스크립트 평가에서 모듈 미지원).
/// 두 모드: ① 단독 컨텍스트(웹/텍스트 호환 — update 필수) ② 씬 공유 컨텍스트(IIFE 격리 —
/// update 없는 사이드이펙트 전용 스크립트도 로드: 실물 컨트롤러는 top-level 에서 shared 를 초기화하고
/// cursorClick 만 export 한다).
public final class TextScriptEngine {
    /// 캡처/스냅샷 결정성 훅: 설정 시 JSContext 의 `new Date()`(무인자)/`Date.now()` 가 이 고정 epoch(ms)를
    /// 반환 — 벽시계 텍스트(시계/날짜 레이어)가 재캡처마다 동일 픽셀. nil(프로덕션 기본) = 실 벽시계 유지.
    /// SnapshotPipeline.pinRenderSettings 가 캡처 동안만 핀(defer 복원). 인자 있는 `new Date(ms)` 등은 불변.
    public static var captureDateEpochMillis: Double?

    /// engine.isScreensaver() 반환값(WE: 화면보호기로 구동 중이면 true). 프로세스 전역 — 실행 문맥이
    /// 컨텍스트 생성 전 1회 설정. 기본 false(데스크탑 배경 = 화면보호기 아님; 캡처·기존 앱 경로 무변화 가드).
    /// 현 Waple 화면보호기(WapleSaverView)는 동영상 전용이라 씬 스크립트 경로가 없어 상시 false —
    /// 씬 화면보호기 모드가 생기면 그 진입점이 true 설정(하드코딩 false 제거로 배관만 확보).
    public static var isScreensaver = false

    /// captureDateEpochMillis 주입용 JS: 전역 Date 를 감싸 무인자 생성/now 만 고정, 나머지는 실 Date 로 위임.
    static func dateOverrideJS(_ epochMillis: Double) -> String {
        let ms = epochMillis.isFinite ? epochMillis : 0
        return """
        (function(){
            var g = Function('return this')();
            var R = g.Date, FIXED = \(ms);
            function D() {
                if (arguments.length === 0) { return new R(FIXED); }
                return new (R.bind.apply(R, [null].concat(Array.prototype.slice.call(arguments))))();
            }
            D.prototype = R.prototype;
            D.now = function(){ return FIXED; };
            D.parse = R.parse; D.UTC = R.UTC;
            g.Date = D;
        })();
        """
    }

    private let context: JSContext
    private let updateFn: JSValue?
    private let initFn: JSValue?
    private let applyUserPropertiesFn: JSValue?
    private var didCallInit = false
    private var didApplyUserProperties = false
    /// Generic event hooks only. Lifecycle functions have dedicated storage and gates.
    private var hookFns: [String: JSValue] = [:]

    private static let lifecycleFunctionNames = ["init", "applyUserProperties"]
    static let eventHookNames = ["cursorClick", "cursorDown", "cursorUp", "cursorMove",
                                 "cursorEnter", "cursorLeave", "animationEvent",
                                 "mediaPlaybackChanged", "mediaPropertiesChanged", "mediaThumbnailChanged",
                                 "mediaTimelineChanged", "mediaStatusChanged"]
    private static let maxScriptCharacters = 512_000

    /// 프로퍼티 스크립트 사용자 오버라이드(JSON)를 컨텍스트 전역 `__scriptPropOverrides` 에 주입. 스크립트
    /// 평가 직전 호출 — createScriptProperties 심이 이 값으로 소스 기본값을 대체한다. 공유 컨텍스트에선
    /// 매 로드 직전 재설정(잔류 무해 — 다음 로드가 덮어씀). nil 이면 null(오버라이드 없음 = 무회귀).
    static func injectScriptPropOverrides(_ ctx: JSContext, json: String?) {
        if let json {
            ctx.setObject(json, forKeyedSubscript: "__scriptPropOverridesJSON" as NSString)
            ctx.evaluateScript("__scriptPropOverrides = (function(){try{return JSON.parse(__scriptPropOverridesJSON);}catch(e){return null;}})();")
        } else {
            ctx.evaluateScript("__scriptPropOverrides = null;")
        }
    }

    /// F475: `__scriptPropOverrides` 는 **컨텍스트 전역** — 공유 컨텍스트에서 이후 로드되는 타 엔진이
    /// 덮어쓴다. top-level 이 아니라 init/update 안에서 createScriptProperties() 를 지연 호출하는
    /// 스크립트는 그 시점의 전역을 읽으므로, 이 엔진의 스크립트 코드가 실행되기 직전마다 로드 시점에
    /// 찍어둔 자기 스냅샷으로 복원해야 한다(아래 두 헬퍼).
    private var scriptPropOverridesSnapshot: JSValue?

    /// 컨텍스트 전역 `__scriptPropOverrides` 현재 값의 스냅샷(null/undefined → nil).
    private static func currentScriptPropOverrides(_ ctx: JSContext) -> JSValue? {
        guard let v = ctx.objectForKeyedSubscript("__scriptPropOverrides"), !v.isNull, !v.isUndefined else { return nil }
        return v
    }

    /// F475: 이 엔진의 오버라이드를 컨텍스트 전역에 복원(없으면 null — 타 엔진 값 잔류 차단).
    private func restoreScriptPropOverrides() {
        context.setObject(scriptPropOverridesSnapshot ?? NSNull(),
                          forKeyedSubscript: "__scriptPropOverrides" as NSString)
    }

    public init?(script: String, scriptPropsJSON: String? = nil) {
        guard Self.passesPracticalSafetyChecks(script) else { return nil }
        guard let ctx = JSContext() else { return nil }
        context = ctx
        var hadException = false
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] text script exception: \(ex?.toString() ?? "?")")
            hadException = true
        }
        ctx.evaluateScript(Self.shims)
        if let ms = Self.captureDateEpochMillis { ctx.evaluateScript(Self.dateOverrideJS(ms)) }
        if Self.isScreensaver { ctx.evaluateScript("__setScreensaver(true);") }  // 기본 false = 미주입 = 무변화
        Self.injectScriptPropOverrides(ctx, json: scriptPropsJSON)
        scriptPropOverridesSnapshot = Self.currentScriptPropOverrides(ctx)   // F475
        let cleaned = Self.stripModuleSyntax(script)
        ctx.evaluateScript(cleaned)
        guard !hadException,
              let fn = ctx.objectForKeyedSubscript("update"), fn.isObject else { return nil }
        updateFn = fn
        let i = ctx.objectForKeyedSubscript("init")
        initFn = (i?.isObject == true) ? i : nil
        let apply = ctx.objectForKeyedSubscript("applyUserProperties")
        applyUserPropertiesFn = (apply?.isObject == true) ? apply : nil
        for name in Self.eventHookNames {
            if let f = ctx.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
        }
    }

    /// 씬 공유 컨텍스트 모드: 스크립트를 IIFE 로 감싸 평가(전역 오염/update 이름충돌 방지)하고
    /// {update, cursorClick, media*Changed...} 훅 딕셔너리를 반환받아 보관.
    /// update/훅 부재도 성공(top-level 사이드이펙트는 이미 실행됨).
    /// 로드 예외(문법 오류 등) → nil, 공유 컨텍스트는 오염되지 않는다(IIFE 미실행).
    /// currentLayerIndex(F709/S-34): thisLayer 를 스크립트가 붙은 오브젝트 자체로 직결하는 디스크립터
    /// 인덱스 — 중복명/묪명 레이어에서 이름 조회는 첫 매치로 오바인딩된다(WE 계약은 객체 자체 바인딩).
    /// nil 이면 종전 이름 조회 폴터(무회귀).
    public init?(script: String, scene: SceneScriptContext, currentLayerName: String? = nil,
                 currentLayerIndex: Int? = nil, scriptPropsJSON: String? = nil) {
        guard Self.passesPracticalSafetyChecks(script) else { return nil }
        let ctx = scene.context
        context = ctx
        var hadException = false
        // 공유 컨텍스트의 기존 핸들러(SceneScriptContext 로깅)를 저장 후 복원 — 로드용 핸들러가
        // 컨텍스트에 잔류해 이후 무관한 평가의 예외를 오귀속하지 않도록. (defer 는 로컬 ctx 사용 —
        // init 실패 경로에서 self 접근 불가.)
        let saved = ctx.exceptionHandler
        defer { ctx.exceptionHandler = saved }
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] scene script load exception: \(ex?.toString() ?? "?")")
            hadException = true
        }
        let cleaned = Self.stripModuleSyntax(script)
        let exports = (["update"] + Self.lifecycleFunctionNames + Self.eventHookNames)
            .map { "\($0): (typeof \($0) !== 'undefined') ? \($0) : null" }
            .joined(separator: ", ")
        let layerArg = currentLayerName.map(Self.javascriptStringLiteral) ?? "null"
        let layerIndexArg = currentLayerIndex.map(String.init) ?? "null"
        let wrapped = """
        (function(__wapleThisLayer){
        var __wapleGlobal = Function('return this')();
        var thisLayer = __wapleThisLayer || __wapleGlobal.thisLayer;
        var thisObject = thisLayer;
        \(cleaned)
        ;return { \(exports) };
        })(__wapleLayerForScript(\(layerArg), \(layerIndexArg)))
        """
        Self.injectScriptPropOverrides(context, json: scriptPropsJSON)
        scriptPropOverridesSnapshot = Self.currentScriptPropOverrides(context)   // F475
        let out = context.evaluateScript(wrapped)
        guard !hadException else { return nil }
        if let out, out.isObject {
            let u = out.objectForKeyedSubscript("update")
            updateFn = (u?.isObject == true) ? u : nil
            let i = out.objectForKeyedSubscript("init")
            initFn = (i?.isObject == true) ? i : nil
            let apply = out.objectForKeyedSubscript("applyUserProperties")
            applyUserPropertiesFn = (apply?.isObject == true) ? apply : nil
            for name in Self.eventHookNames {
                if let f = out.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
            }
        } else {
            updateFn = nil
            initFn = nil
            applyUserPropertiesFn = nil
        }
    }

    /// update 함수 보유 여부(false = 사이드이펙트 전용 스크립트 — evaluate 계열은 항상 nil).
    public var hasUpdate: Bool { updateFn != nil }

    /// export 된 이벤트 훅 이름들(update 제외). 비어 있으면 이벤트 배달 대상 아님.
    public var hookNames: Set<String> { Set(hookFns.keys) }

    /// 공유 JSContext 규약: 호출용 예외 핸들러는 저장/복원(교체 후 미복원 시 마지막 핸들러가 컨텍스트에
    /// 잔류해 다른 엔진/시점의 예외를 오귀속). 예외 → "[Waple] <tag>: …" 로깅 + body 의 failed() 가 true.
    private func withExceptionCapture<T>(_ tag: String, _ body: (_ failed: () -> Bool) -> T?) -> T? {
        var failed = false
        let saved = context.exceptionHandler
        defer { context.exceptionHandler = saved }
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] \(tag): \(ex?.toString() ?? "?")")
            failed = true
        }
        restoreScriptPropOverrides()   // F475: 지연 createScriptProperties 호출은 자기 오버라이드를 봐야 함
        return body { failed }
    }

    /// 이벤트 훅 호출: eventJS(이벤트 생성식 — `new MediaPlaybackEvent({...})` / `({ worldPosition: new Vec3(..) })`)
    /// 를 이 엔진의 컨텍스트에서 평가해 1개 인자로 전달. Vec3/Media*Event 는 shims 클래스라 스크립트가
    /// 메서드 체이닝(subtract/multiply/add)을 그대로 쓸 수 있다. 미보유 훅/예외 → no-op(로깅, 컨텍스트 불오염).
    public func callHook(_ name: String, eventJS: String) {
        guard let fn = hookFns[name] else { return }
        _ = withExceptionCapture("\(name) hook exception") { failed -> JSValue? in
            guard let ev = context.evaluateScript("(\(eventJS))"), !failed() else { return nil }
            return fn.call(withArguments: [ev])
        }
    }

    /// Deliver the mount's effective WallpaperProperty JSON once. The gate is set before JSON evaluation/call,
    /// so malformed JSON or a throwing script is logged and never retried automatically.
    /// engine.userProperties(코퍼스 17씬)는 훅 유무와 무관하게 항상 채운다 — noopProxy 폴백은 truthy 라
    /// 부울 분기가 항상 참으로 새는 오분기 버그(0 수치보다 악질).
    /// 수용된 순서 제약: 공유 컨텍스트 첫 스크립트의 톱레벨 코드는 이 주입 이전에 실행됨 — 실물
    /// 스크립트는 update()/init() 안에서 읽는다(build3D 선행과 동일한 기존 제약, 재구조화 금지).
    public func applyUserProperties(_ propertiesJSON: String) {
        guard !didApplyUserProperties else { return }
        didApplyUserProperties = true
        _ = withExceptionCapture("applyUserProperties hook exception") { failed -> JSValue? in
            guard let properties = context.evaluateScript("(\(propertiesJSON))"), !failed() else { return nil }
            context.setObject(properties, forKeyedSubscript: "__wapleUserProperties" as NSString)
            // engine.userProperties = **원시값** 맵({type,value} 래퍼 아님). 코퍼스 실측: `engine.userProperties.<KEY>`
            // 65회 등장, `.value` 동반 0회 — 스크립트는 `engine.userProperties.timeofday == 2` 처럼 직접 비교한다.
            // {type,value} 는 project.json `condition` DSL 과 web API 의 형태이지 스크립트 API 가 아니다.
            // 래퍼를 노출하면 `{obj} != 0` → true(오분기) → `{obj} - 1` → NaN 전파 → 씬 암전(2911866381).
            // 값은 combo 문자열('0'/'99') 그대로 — 코퍼스는 전부 느슨비교라 수치 강제변환은 불필요하고
            // 문자열 프로퍼티(combo/text)를 깨뜨린다. 산출기 weUserPropertiesJSON 은 WebRenderer 와 공유 —
            // 거기선 {type,value} 가 올바른 web 계약이므로 반드시 이 주입 지점에서만 벗긴다.
            context.evaluateScript("""
            __wapleUserPropertiesRaw = (function (o) {
                var r = {};
                for (var k in o) { r[k] = o[k] ? o[k].value : o[k]; }
                return r;
            })(__wapleUserProperties);
            engine.userProperties = __wapleUserPropertiesRaw;
            """)
            guard let applyUserPropertiesFn, !failed() else { return nil }
            // F702(S-8): 훅 인자도 원시값 맵이어야 한다(WE 계약 — 실물 58씬 전부 `.value` 접근 없이
            // `changedUserProperties.mode === 2` 처럼 직접 비교). 종전엔 {type,value} 래퍼를 그대로 넘겨
            // hasOwnProperty 게이트 통과 후 기본값이 래퍼 객체로 덮어써져 수치 비교가 NaN→false 로 굳었다.
            let hookArg = context.objectForKeyedSubscript("__wapleUserPropertiesRaw")
            let result = applyUserPropertiesFn.call(withArguments: [hookArg ?? properties])
            return failed() ? nil : result
        }
    }

    /// Initialize an init-only SceneScript once with zero arguments.
    /// F712(S-38): 반환값은 initReturnValue 에 캐시 — update 없는 프로퍼티 스크립트의 evaluate* 가
    /// 이를 프로퍼티값으로 서빙한다(WE: init 반환 = 바운드 프로퍼티에 적용할 수정값, d.ts:52-55).
    public func callInitIfNeeded() {
        guard let initFn = takeInitFunctionIfNeeded() else { return }
        _ = withExceptionCapture("init hook exception") { failed -> JSValue? in
            let result = initFn.call(withArguments: [])
            if let result, !result.isUndefined, !result.isNull { initReturnValue = result }
            return failed() ? nil : result
        }
    }

    /// update(current) 호출 → 새 텍스트. 예외/비문자열 → nil.
    public func evaluate(current: String) -> String? {
        return withExceptionCapture("text script update exception") { failed -> String? in
            let initValue = callInitIfNeeded(argument: current)
            guard !failed() else { return nil }
            if let updateFn {
                // F712: init 반환(수정값)이 있으면 첫 update 의 current 로 공급(WE init→update 계약).
                let arg: Any = initValue ?? current
                guard let out = updateFn.call(withArguments: [arg]), !failed(), out.isString else { return nil }
                return out.toString()
            }
            // F712: init-only 텍스트 스크립트 — init 반환 문자열을 프로퍼티값으로 적용, 없으면 nil(현상 유지).
            guard let v = initValue ?? initReturnValue, v.isString else { return nil }
            return v.toString()
        }
    }

    /// visible 스크립트용: update(current) → 부울(숫자는 0=false). 예외/부재/비해석 → nil(현상 유지).
    public func evaluateBool(current: Bool) -> Bool? {
        return withExceptionCapture("visible script exception") { failed -> Bool? in
            let initValue = callInitIfNeeded(argument: current)
            guard !failed() else { return nil }
            let out: JSValue?
            if let updateFn {
                let arg: Any = initValue ?? current
                guard let o = updateFn.call(withArguments: [arg]), !failed() else { return nil }
                out = o
            } else {
                out = initValue ?? initReturnValue   // F712: init-only — init 반환을 프로퍼티값으로
            }
            guard let out else { return nil }
            if out.isBoolean { return out.toBool() }
            if out.isNumber { return out.toDouble() != 0 }
            return nil
        }
    }

    /// 효과 상수 스크립트용: engine.runtime 갱신(초) + engine.setTimeout 만기 큐 펌프.
    /// 공유 씬 컨텍스트에선 여러 엔진이 같은 t 로 재호출 — 펌프는 멱등(만기분은 1회만 발화).
    /// F700(S-6): __setRuntime 이 frametime 을 실델타(t − 직전 t)로 갱신한다(같은 t 재호출은 물변화).
    public func setRuntime(_ t: Double) {
        restoreScriptPropOverrides()   // F475: __pumpTimeouts 만기 콜백도 이 엔진의 스크립트 코드
        context.evaluateScript("__setRuntime(\(t.isFinite ? t : 0));")
    }

    /// update({x,y,z...}) 호출 → 수치 배열(스칼라는 1개). 예외/비수치 → nil.
    public func evaluateVec(current: [Float]) -> [Float]? {
        return withExceptionCapture("constant script exception") { failed -> [Float]? in
            guard let arg = vecArgument(current), !failed() else { return nil }
            let initValue = callInitIfNeeded(argument: arg)
            guard !failed() else { return nil }
            if let updateFn {
                let updateArg: Any = initValue ?? arg   // F712: init 수정값을 첫 update 의 current 로
                guard let out = updateFn.call(withArguments: [updateArg]), !failed() else { return nil }
                return Self.floatArray(from: out)
            }
            // F712(S-38): update 없는 init-only 프로퍼티 스크립트(실물 3367988661 드래그 패밀리의
            // `return localStorage.get(storageName) || thisLayer.origin`) — WE 는 init 반환값을 바운드
            // 프로퍼티에 적용하므로 per-frame 동일값으로 서빙(매 프레임 nil 이면 정적값에 묻힌다).
            return Self.floatArray(from: initValue ?? initReturnValue)
        }
    }

    private func takeInitFunctionIfNeeded() -> JSValue? {
        guard !didCallInit else { return nil }
        didCallInit = true
        return initFn
    }

    /// F712(S-38): init 의 반환값 캐시 — WE 계약은 "바운드 프로퍼티에 적용할 수정값"(d.ts:52-55).
    /// update 보유 스크립트는 첫 update 의 current 로 공급되고, init-only 스크립트는 evaluate* 가 이 값을 서빙.
    private var initReturnValue: JSValue?

    /// init 을 1회 발화하고, 수정값 반환이 있으면 캐시 후 돌려준다(미발화/undefined/null → nil).
    @discardableResult
    private func callInitIfNeeded(argument: Any) -> JSValue? {
        guard let initFn = takeInitFunctionIfNeeded() else { return nil }
        guard let r = initFn.call(withArguments: [initArgument(from: argument)]),
              !r.isUndefined, !r.isNull else { return nil }
        initReturnValue = r
        return r
    }

    /// 스크립트 반환값 → 수치 배열: 스칼라는 1개, Vec2/Vec3 형({x,y[,z]})은 성별 순, 배열 형은 앞에서부터.
    /// W3-③: NaN/Infinity 성분이 하나라도 있으면 전체를 nil 로 거부(위 "예외/비수치 → nil" 계약의 연장 —
    /// JS 의 NaN 은 typeof 'number' 라 isNumber 검사만으론 안 걸러진다). 호출부(evaluateVec)가 nil 을
    /// "이전 프레임 값 유지"로 처리하므로, 스크립트가 undefined 피연산자로 NaN 을 만들어내도(실물
    /// 3616389236: WEMath.mix(a,b,undefined) 의 speed 미초기화) 버텍스가 소멸하지 않고 직전 값을 유지한다.
    static func floatArray(from value: JSValue?) -> [Float]? {
        guard let value else { return nil }
        if value.isNumber {
            let d = value.toDouble()
            return d.isFinite ? [Float(d)] : nil
        }
        guard value.isObject else { return nil }
        let x = value.objectForKeyedSubscript("x"), y = value.objectForKeyedSubscript("y"),
            z = value.objectForKeyedSubscript("z")
        if let x, let y, x.isNumber, y.isNumber {
            let xd = x.toDouble(), yd = y.toDouble()
            guard xd.isFinite, yd.isFinite else { return nil }
            if let z, z.isNumber {
                let zd = z.toDouble()
                guard zd.isFinite else { return nil }
                return [Float(xd), Float(yd), Float(zd)]
            }
            return [Float(xd), Float(yd)]
        }
        if let len = value.objectForKeyedSubscript("length"), len.isNumber, len.toInt32() > 0 {
            var out: [Float] = []
            for i in 0..<len.toInt32() {
                guard let e = value.objectAtIndexedSubscript(Int(i)), e.isNumber else { return nil }
                let d = e.toDouble()
                guard d.isFinite else { return nil }
                out.append(Float(d))
            }
            return out
        }
        return nil
    }

    private func initArgument(from argument: Any) -> Any {
        guard let value = argument as? JSValue,
              value.isObject,
              let copy = value.objectForKeyedSubscript("copy"),
              copy.isObject,
              let copied = value.invokeMethod("copy", withArguments: []),
              !copied.isUndefined,
              !copied.isNull
        else { return argument }
        return copied
    }

    private func vecArgument(_ current: [Float]) -> JSValue? {
        if current.count >= 3 {
            return context.evaluateScript("new Vec3(\(Self.jsNumber(current[0])), \(Self.jsNumber(current[1])), \(Self.jsNumber(current[2])))")
        }
        if current.count >= 2 {
            return context.evaluateScript("new Vec2(\(Self.jsNumber(current[0])), \(Self.jsNumber(current[1])))")
        }
        return JSValue(double: Double(current.first ?? 0), in: context)
    }

    static func jsNumber(_ value: Float) -> String {  // SceneScriptContext 도 사용(비유한 → "0" 가드)
        let d = Double(value)
        return d.isFinite ? String(d) : "0"
    }

    /// ES 모듈 구문 중화(토큰 인지 — minified 한 줄 소스 포함). 문자열/주석 밖의 `export` 키워드를 제거하고
    /// (`export default X` → `var __default = X`, `export {..}`/`export * ..` 문 삭제), `import ... from '...'`
    /// 문을 no-op 프록시 바인딩으로 치환한다. 동적 `import(...)`/`import.meta`, 문자열 리터럴 속 'export'/'import',
    /// 멤버 접근 `x.export`/프로퍼티 키 `{export:..}` 는 불간섭. (JSC 는 스크립트 평가에서 ES 모듈 미지원 —
    /// 실물 난독화 텍스트 스크립트가 한 줄에 mid-line export 를 흩뿌려 줄 단위 스트리퍼로는 로드 실패했다.)
    static func stripModuleSyntax(_ src: String) -> String {
        let chars = Array(src)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)
        var i = 0
        var prevSig: Character? = nil   // 마지막 비공백 코드 문자(멤버 접근 `.export` 판별)
        var lastKeywordAllowsRegex = false
        var sawLineBreak = false        // 마지막 코드 토큰 이후 개행 경과(ASI 판별 — F472)
        func isIdent(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }
        // 피연산자 종료 문자(식 연속 위치) — 이 직후 개행 없는 import/export 는 문 키워드가 될 수
        // 없다(ASI 는 라인터미네이터 필요): 시작 판정을 놓친 정규식 내부의 키워드다(F472).
        func isOperandEnding(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$" || c == ")" || c == "]"
                || c == "\"" || c == "'" || c == "`"
        }
        func emit(_ c: Character) {
            out.append(c)
            if !c.isWhitespace {
                prevSig = c
                sawLineBreak = false
                if !"({[=,:;!?&|+-*%^~<>".contains(c) { lastKeywordAllowsRegex = false }
            }
        }
        func emitAll(_ s: [Character]) { for c in s { emit(c) } }
        func nextNonWS(_ from: Int) -> Int { var k = from; while k < n && chars[k].isWhitespace { k += 1 }; return k }
        // chars[at...] 가 word 로 시작하고 그 뒤가 경계면 그 word 길이, 아니면 0.
        func matchWord(_ at: Int, _ word: [Character]) -> Bool {
            guard at + word.count <= n, Array(chars[at..<at + word.count]) == word else { return false }
            let after = at + word.count
            return after == n || !isIdent(chars[after])
        }

        while i < n {
            let c = chars[i]
            // 문자열 리터럴(' " `): 이스케이프 인지, 원문 보존.
            if c == "\"" || c == "'" || c == "`" {
                emit(c); i += 1
                while i < n {
                    let d = chars[i]
                    if d == "\\", i + 1 < n { emit(d); emit(chars[i + 1]); i += 2; continue }
                    emit(d); i += 1
                    if d == c { break }
                }
                continue
            }
            // 주석: 원문 보존 + prevSig 불변(주석은 코드 토큰 아님 — 주석 끝의 '.' 가 다음 export 를
            // 멤버 접근으로 오판하지 않도록 raw append; 실물 `//...may break.\nexport let` 회귀).
            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                while i < n && chars[i] != "\n" { out.append(chars[i]); i += 1 }
                continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                out.append(c); out.append(chars[i + 1]); i += 2
                while i < n {
                    if chars[i] == "*", i + 1 < n, chars[i + 1] == "/" { out.append("*"); out.append("/"); i += 2; break }
                    // 블록 주석 내부의 개행도 ASI 라인터미네이터로 친다(F472) — 주석은 emit 을 거치지
                    // 않으므로(prevSig 불변 규약) 여기서 별도 추적.
                    if chars[i] == "\n" || chars[i] == "\r" { sawLineBreak = true }
                    out.append(chars[i]); i += 1
                }
                continue
            }
            // 정규식 리터럴: 문자열처럼 원문 보존. `/export\s+default/` 내부 키워드를 모듈 구문으로
            // 오인하면 패턴이 조용히 깨진다. 완전한 JS lexer 는 아니지만 return/=/( 등 식 시작 위치를 처리한다.
            if c == "/", i + 1 < n,
               lastKeywordAllowsRegex || prevSig == nil || "({[=,:;!?&|+-*%^~<>".contains(prevSig!) {
                emit(c); i += 1
                var inClass = false
                while i < n {
                    let d = chars[i]
                    if d == "\\", i + 1 < n { emit(d); emit(chars[i + 1]); i += 2; continue }
                    if d == "[" { inClass = true }
                    if d == "]" { inClass = false }
                    emit(d); i += 1
                    if d == "/" && !inClass { break }
                }
                while i < n && isIdent(chars[i]) { emit(chars[i]); i += 1 }
                continue
            }
            // 식별자 시작(문자/_/$): 전체 word 소비 — 항상 완전 토큰 경계에서만 진입.
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                let word = Array(chars[i..<j])
                let wordString = String(word)
                // prevSig "/" 제외(감사 W-B4): 유효 JS 에서 `/` 직후 식별자 위치의 export/import 는
                // 정규식 리터럴 내부뿐(나눗셈 우변의 예약어는 비합법) — `if (ok) /export /` 처럼 위의
                // 정규식 시작 판정이 놓친 경우의 오폭 방지. `)`/`}` 를 정규식 시작 집합에 추가하는 방식은
                // 나눗셈 `(a+b)/2` 를 정규식으로 오파괴하므로 불가.
                // F472: 피연산자 종료(식별자/숫자/`)`/`]`/따옴표) 직후 **개행 없는** 키워드도 문 위치가
                // 아니다 — `if (ok) /a import 'x'/.test(s)` 처럼 시작 판정을 놓친 정규식 중간의 키워드를
                // 중화해 패턴을 파괴하는 경로 차단. ASI 가 성립하는 개행 경과 후나 `;`/`{`/`}` 뒤는 중화.
                let isKeyword = (word == Array("export") || word == Array("import"))
                    && prevSig != "." && prevSig != "/"
                    && (prevSig == nil || sawLineBreak || !isOperandEnding(prevSig!))
                if isKeyword {
                    let after = nextNonWS(j)
                    let ac: Character? = after < n ? chars[after] : nil
                    if ac == ":" { emitAll(word); i = j; continue }  // 프로퍼티 키
                    if word == Array("import") {
                        if ac == "(" || ac == "." { emitAll(word); i = j; continue }  // 동적 import / import.meta
                        i = neutralizeImport(chars, j, n, emit: emitAll); continue
                    }
                    // export
                    if matchWord(after, Array("default")) {
                        // F474: `export default function update(...)` 를 `var __default = function update...`
                        // 로 바꾸면 기명 함수식의 이름은 스코프에 바인딩되지 않아 update 훅 수집이 무음
                        // 실패한다. 기명 function 선언은 `export default ` 만 삭제해 선언 바인딩을 보존
                        // (익명/식 형태는 기존 __default 대입 유지).
                        let d = after + "default".count
                        let nd = nextNonWS(d)
                        if matchWord(nd, Array("function")) {
                            let nf = nextNonWS(nd + "function".count)
                            if nf < n, isIdent(chars[nf]), !chars[nf].isNumber {
                                i = d; continue
                            }
                        }
                        emitAll(Array("var __default =")); i = d; continue
                    }
                    if ac == "{" {
                        // F473: 멀티라인 `export { ... }` — 기존 스캔은 첫 \n 에서 멈춰 잔여 줄이
                        // SyntaxError 로 로드를 깼다. 목록 구성 문자만 통과시키며 닫는 } 까지 삭제하고
                        // 선택적 re-export 꼬리(`from 'm'`)·선택 `;` 까지 소비. 비정형(} 미발견/외부
                        // 문자)이면 기존 동작(첫 ;/\n 까지 삭제)으로 후퇴.
                        var m = after + 1
                        var close: Int? = nil
                        while m < n {
                            let c = chars[m]
                            if c == "}" { close = m; break }
                            if c == ";" || !(c.isLetter || c.isNumber || c == "_" || c == "$"
                                                || c == "," || c.isWhitespace) { break }
                            m += 1
                        }
                        if let close {
                            var e = close + 1
                            var f = e
                            while f < n && chars[f].isWhitespace { f += 1 }
                            if matchWord(f, Array("from")) {
                                var s = nextNonWS(f + "from".count)
                                if s < n, chars[s] == "'" || chars[s] == "\"" {
                                    let quote = chars[s]
                                    s += 1
                                    while s < n { if chars[s] == "\\", s + 1 < n { s += 2; continue }; let end = chars[s] == quote; s += 1; if end { break } }
                                    e = s
                                }
                            }
                            while e < n && chars[e].isWhitespace && chars[e] != "\n" { e += 1 }
                            if e < n && chars[e] == ";" { e += 1 }
                            i = e; continue
                        }
                        var m2 = after
                        while m2 < n && chars[m2] != ";" && chars[m2] != "\n" { m2 += 1 }
                        if m2 < n && chars[m2] == ";" { m2 += 1 }
                        i = m2; continue
                    }
                    if ac == "*" {
                        // export * .. — 문 전체(다음 ';' 까지) 삭제.
                        var m = after
                        while m < n && chars[m] != ";" && chars[m] != "\n" { m += 1 }
                        if m < n && chars[m] == ";" { m += 1 }
                        i = m; continue
                    }
                    // 일반 `export <decl>` — 키워드만 제거(뒤 공백/선언 유지).
                    i = j; continue
                }
                emitAll(word)
                lastKeywordAllowsRegex = ["return", "throw", "case", "delete", "typeof", "void", "new", "yield"].contains(wordString)
                i = j; continue
            }
            // 숫자 리터럴 선두(16진수 0x.. 등): word 로 오인 안 되게 통째 소비.
            if c.isNumber {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                emitAll(Array(chars[i..<j])); i = j; continue
            }
            if c == "\n" || c == "\r" { sawLineBreak = true }   // ASI 라인터미네이터(F472)
            emit(c); i += 1
        }
        return String(out)
    }

    /// 실용 안전 검사 — 자명한 무한 루프/초대형 소스를 로드 전에 거른다(거부 시 정적 텍스트 폴백).
    ///
    /// F470 잔여 리스크(문서화): JSC 평가는 호출 스레드(렌더/메인) **동기**이고, 공개 API 에는 평가
    /// 인터럽트/타임아웃 수단이 없다(JSContextGroupSetExecutionTimeLimit 등은 private SPI라 미채택).
    /// 백그라운드 스레드 격리는 프레임마다 동기 결과를 요구하는 호출 체인(AppDelegate → mount →
    /// makeScriptEngine → evaluate*)의 전면 재구조라 침습적이라 보류했다. 따라서 이 가드는 자명한
    /// 경우만 거르는 최선 노력이며 `while (f(x))` 류 계산 조건의 정교한 무한 루프는 여전히 통과한다 —
    /// 제3자 스크립트의 악의적/버그성 행 유발은 수용 리스크로 남는다(정상 스크립트 오탐보다 행
    /// 방지를 우선하는 기존 방향 유지).
    private static func passesPracticalSafetyChecks(_ script: String) -> Bool {
        guard script.count <= maxScriptCharacters else {
            NSLog("%@", "[Waple] text script rejected: source too large (\(script.count) chars)")
            return false
        }
        if containsObviousUnboundedLoop(script) {
            NSLog("%@", "[Waple] text script rejected: obvious unbounded loop")
            return false
        }
        return true
    }

    private static func containsObviousUnboundedLoop(_ src: String) -> Bool {
        let chars = Array(src)
        let n = chars.count
        var i = 0
        var prevSig: Character? = nil   // 마지막 비공백 코드 문자(정규식 시작 판별 — stripModuleSyntax 준용)
        var lastKeywordAllowsRegex = false
        func isIdent(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }
        func skipWS(_ p: inout Int) { while p < n && chars[p].isWhitespace { p += 1 } }
        func word(at p: Int, _ w: String) -> Bool {
            let a = Array(w)
            guard p + a.count <= n, Array(chars[p..<p + a.count]) == a else { return false }
            let beforeOK = p == 0 || !isIdent(chars[p - 1])
            let after = p + a.count
            let afterOK = after == n || !isIdent(chars[after])
            return beforeOK && afterOK
        }
        while i < n {
            let c = chars[i]
            if c == "\"" || c == "'" || c == "`" {
                i += 1
                while i < n {
                    if chars[i] == "\\", i + 1 < n { i += 2; continue }
                    let done = chars[i] == c
                    i += 1
                    if done { break }
                }
                prevSig = c   // 문자열 리터럴 = 피연산자 — 뒤따르는 / 는 나눗셈
                lastKeywordAllowsRegex = false
                continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "/" {
                while i < n && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {
                i += 2
                while i + 1 < n, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, n)
                continue
            }
            // 정규식 리터럴 스킵(감사 W-B7): /while (true)/ 같은 패턴 내부를 스캔해 정상 스크립트를
            // 오탐 거부하지 않도록. 시작 판정은 stripModuleSyntax(:485) 의 식-시작 휴리스틱 재사용 —
            // 나눗셈/정규식 모호성도 같은 수준에서만 처리한다(`)` 뒤 정규식은 여전히 미스킵).
            if c == "/", i + 1 < n,
               lastKeywordAllowsRegex || prevSig == nil || "({[=,:;!?&|+-*%^~<>".contains(prevSig!) {
                i += 1
                var inClass = false
                while i < n {
                    let d = chars[i]
                    if d == "\\", i + 1 < n { i += 2; continue }
                    if d == "[" { inClass = true }
                    if d == "]" { inClass = false }
                    i += 1
                    if d == "/" && !inClass { break }
                }
                while i < n && isIdent(chars[i]) { i += 1 }   // 플래그
                prevSig = "/"   // 리터럴 = 피연산자 — 뒤따르는 / 는 나눗셈
                lastKeywordAllowsRegex = false
                continue
            }
            // 식별자 시작(문자/_/$): word 단위 소비 — while/for 검사 + 정규식 허용 키워드 추적.
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                let wordString = String(chars[i..<j])
                if wordString == "while" {
                    var p = j
                    skipWS(&p)
                    if p < n, chars[p] == "(" {
                        p += 1
                        skipWS(&p)
                        if word(at: p, "true") {
                            p += "true".count
                            skipWS(&p)
                            if p < n, chars[p] == ")" { return true }
                        } else if let literal = numericLiteral(at: p), literal.isTruthy {
                            p += literal.length
                            skipWS(&p)
                            if p < n, chars[p] == ")" { return true }
                        } else {
                            // F470: `while (x)` 베어 식별자 조건 — `var x=1; while(x){}` 류 리터럴 가드
                            // 우회 차단(사실상 무한 루프 관용구). 비교식 `while (i<n)` 등은 허용 —
                            // 오탐은 정적 텍스트 폴백, 행 방지를 우선.
                            var q = p
                            while q < n && isIdent(chars[q]) { q += 1 }
                            if q > p {
                                skipWS(&q)
                                if q < n, chars[q] == ")" { return true }
                            }
                        }
                    }
                } else if wordString == "for" {
                    var p = j
                    skipWS(&p)
                    if p < n, chars[p] == "(" {
                        p += 1
                        skipWS(&p)
                        if forHeaderIsUnbounded(start: p) { return true }
                    }
                }
                lastKeywordAllowsRegex = ["return", "throw", "case", "delete", "typeof", "void", "new", "yield"].contains(wordString)
                prevSig = wordString.last
                i = j
                continue
            }
            // 숫자 리터럴 선두(16진수 0x.. 등): word 로 오인 안 되게 통째 소비(stripModuleSyntax 와 동일).
            if c.isNumber {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                prevSig = chars[j - 1]
                lastKeywordAllowsRegex = false
                i = j
                continue
            }
            if !c.isWhitespace {
                prevSig = c
                if !"({[=,:;!?&|+-*%^~<>".contains(c) { lastKeywordAllowsRegex = false }
            }
            i += 1
        }
        return false

        func numericLiteral(at p: Int) -> (length: Int, isTruthy: Bool)? {
            var q = p
            var hasDigit = false
            while q < n, chars[q].isNumber {
                hasDigit = true
                q += 1
            }
            guard hasDigit else { return nil }
            if q < n, chars[q] == "." {
                q += 1
                while q < n, chars[q].isNumber { q += 1 }
            }
            if q < n, chars[q] == "e" || chars[q] == "E" {
                q += 1
                if q < n, chars[q] == "+" || chars[q] == "-" { q += 1 }
                var hasExponent = false
                while q < n, chars[q].isNumber {
                    hasExponent = true
                    q += 1
                }
                if !hasExponent { return nil }
            }
            let raw = String(chars[p..<q])
            return (q - p, (Double(raw) ?? 0) != 0)
        }

        /// for 헤더 검사: 두 개의 ; 사이 조건식이 비어 있으면(공백뿐) 무한 루프 — F470: 기존은
        /// `for(;;` 리터럴과 거대 상한만 검사해 `for (var i=0;;i++)` 류(init 있는 빈 조건)가 우회했다.
        /// 문자열 스킵(감사 W-B6)·거대 상수 상한 휴리스틱은 기존 유지. 괄호 중첩(init 의 호출식)은
        /// 깊이 추적으로 걸러낸다. 세미콜론 부재(for-of/in)는 미판정(기존 동작).
        func forHeaderIsUnbounded(start: Int) -> Bool {
            var p = start
            var semicolons = 0
            var depth = 0
            var condition: [Character] = []
            while p < n {
                let c = chars[p]
                if c == ")", depth == 0 { break }
                // 문자열 리터럴은 통째로 스킵(외곽 스캐너와 동일, 감사 W-B6) — 문자열 속 숫자
                // (`table["16094592"]`)나 `;`/`)` 가 조건 수집을 오염해 정상 스크립트를 오탐했다.
                if c == "\"" || c == "'" || c == "`" {
                    p += 1
                    while p < n {
                        if chars[p] == "\\", p + 1 < n { p += 2; continue }
                        let done = chars[p] == c
                        p += 1
                        if done { break }
                    }
                    continue
                }
                if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                if c == ";", depth == 0 {
                    semicolons += 1
                    p += 1
                    if semicolons == 2 { break }
                    continue
                }
                if semicolons == 1 { condition.append(c) }
                p += 1
            }
            guard semicolons >= 2 else { return false }
            let text = String(condition)
            // F470: 빈 조건(공백뿐) = 무한 루프 — init/update 절 유무와 무관하게 거부(`for(;;)` 와 동일 기준).
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return text.range(of: #"(?:\d{8,}|1e\d{2,})"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// `import` 키워드 직후 인덱스 j 에서 시작하는 import 문을 소비하고 no-op 바인딩 코드를 emit,
    /// 문 끝(모듈 문자열 + 선택 `;`) 다음 인덱스를 반환. 모듈 문자열 전에 `;` 를 만나면 미변형(리터럴 emit).
    private static func neutralizeImport(_ chars: [Character], _ j: Int, _ n: Int,
                                         emit: ([Character]) -> Void) -> Int {
        // 모듈 지정자(첫 문자열 리터럴)까지 스캔 — 그 사이가 clause(+ 후행 from).
        // clause 구성 문자(식별자/{},*·공백·개행)만 통과 — 멀티라인 import 도 중화하되,
        // 그 외 문자(`.`=import.meta, `(`=동적 import, `;`=문자열 없는 문)는 원문 emit(오소비 방지).
        var m = j
        while m < n, chars[m] != "'", chars[m] != "\"", chars[m] != "`" {
            let c = chars[m]
            guard c.isLetter || c.isNumber || c == "_" || c == "$"
                    || c == "{" || c == "}" || c == "," || c == "*" || c.isWhitespace else {
                emit(Array("import")); return j
            }
            m += 1
        }
        guard m < n else { emit(Array("import")); return j }
        // importBindings 는 개행 비인지(.whitespaces) — clause 의 개행을 공백으로 정규화.
        var clause = String(chars[j..<m])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // 후행 from 키워드 제거(`* as X from` → `* as X`; 부재 시 side-effect import).
        if clause == "from" { clause = "" }
        else if clause.hasSuffix("from") {
            let before = clause.index(clause.endIndex, offsetBy: -4)
            if before == clause.startIndex || !(clause[clause.index(before, offsetBy: -1)].isLetter
                || clause[clause.index(before, offsetBy: -1)].isNumber
                || clause[clause.index(before, offsetBy: -1)] == "_" || clause[clause.index(before, offsetBy: -1)] == "$") {
                clause = String(clause[..<before]).trimmingCharacters(in: .whitespaces)
            }
        }
        // 모듈 문자열 소비.
        let quote = chars[m]
        var s = m + 1
        while s < n { if chars[s] == "\\", s + 1 < n { s += 2; continue }; let end = chars[s] == quote; s += 1; if end { break } }
        // 선택 세미콜론.
        var e = s
        while e < n && chars[e].isWhitespace && chars[e] != "\n" { e += 1 }
        if e < n && chars[e] == ";" { s = e + 1 }
        emit(Array(importBindings(clause: clause)))
        return s
    }

    /// import clause → no-op 프록시 var 선언 코드. 빈 clause(side-effect) → "".
    /// `* as X` / `{a, b as c}` / `default` / `default, {..}`(콤보) 지원. WEColor/WEMath/WEVector 는 실심 바인딩.
    private static func importBindings(clause: String) -> String {
        let clause = clause.trimmingCharacters(in: .whitespaces)
        guard !clause.isEmpty else { return "" }
        func decl(_ name: String) -> String {
            switch name {
            case "WEColor": return "var WEColor = __WEColor;"
            case "WEMath": return "var WEMath = __WEMath;"
            case "WEVector": return "var WEVector = __WEVector;"   // F706(S-42)
            default: return "var \(name) = __noopProxy();"
            }
        }
        if clause.hasPrefix("*") {
            // minified `import*as e from"m"` 대응(감사 W-B5): as 주변 공백을 강제하지 않는다.
            // 단 `as` 직후는 공백 경계여야 함(아니면 `asdf` 같은 한 식별자 — 비합법 clause).
            let rest = String(clause.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("as"), let boundary = rest.dropFirst(2).first, boundary.isWhitespace else { return "" }
            let name = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "" : decl(name)
        }
        if clause.hasPrefix("{") {
            let inner = clause.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            let names = inner.split(separator: ",").compactMap { piece -> String? in
                let p = piece.trimmingCharacters(in: .whitespaces)
                if let asIdx = p.range(of: " as ") { return String(p[asIdx.upperBound...]).trimmingCharacters(in: .whitespaces) }
                return p.isEmpty ? nil : p
            }
            return names.map(decl).joined(separator: " ")
        }
        // default(+ 콤보): `default, {named}` / `default, * as ns`.
        if let comma = clause.firstIndex(of: ",") {
            let def = String(clause[..<comma]).trimmingCharacters(in: .whitespaces)
            let rest = importBindings(clause: String(clause[clause.index(after: comma)...]))
            return ([def.isEmpty ? nil : decl(def), rest.isEmpty ? nil : rest].compactMap { $0 }).joined(separator: " ")
        }
        return decl(clause)
    }

    private static func javascriptStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return String(json.dropFirst().dropLast())
    }

    /// createScriptProperties 빌더 + 엔진 API no-op Proxy 심(SceneScriptContext 와 공유).
    static let shims = """
    'use strict';
    // 프로퍼티 스크립트 사용자 오버라이드(저장 scriptproperties). 엔진 로드 시 JSON 을 주입 → 소스
    // `addColor({value:new Vec3(1,1,1)})` 등의 기본값을 대체. 미주입(null)이면 소스 기본값 유지(무회귀).
    var __scriptPropOverrides = null;
    function createScriptProperties() {
        var props = {};
        var builder = {};
        var __ov = __scriptPropOverrides || null;
        // 오버라이드 우선(없으면 소스 기본값). addColor 오버라이드는 "r g b" 문자열이라 Vec3 로 변환해야
        // 한다 — 스크립트가 .subtract/.multiply 등 Vec3 메서드를 호출하기 때문(문자열 주입 시 예외).
        function __pick(d, asColor) {
            var o = __ov ? __ov[d.name] : undefined;
            if (o === undefined) { return d.value; }
            if (asColor && typeof o === 'string') {
                var p = o.trim().split(/\\s+/);
                return new Vec3(__num(p[0], 0), __num(p[1], 0), __num(p[2], 0));
            }
            return o;
        }
        function add(d) { if (d && d.name !== undefined) { props[d.name] = __pick(d, false); } return builder; }
        function addColor(d) { if (d && d.name !== undefined) { props[d.name] = __pick(d, true); } return builder; }
        function firstOptionValue(options) {
            if (!options || !options.length) { return undefined; }
            var first = options[0];
            return first && typeof first === 'object' && first.value !== undefined ? first.value : first;
        }
        ['addCheckbox','addText','addSlider','addTextInput','addFile'].forEach(function(k){ builder[k] = add; });
        builder.addColor = addColor;
        builder.addCombo = function(d) {
            if (d && d.name !== undefined) {
                var o = __ov ? __ov[d.name] : undefined;
                props[d.name] = o !== undefined ? o
                    : (d.value !== undefined ? d.value
                    : (d.default !== undefined ? d.default
                    : (d.defaultValue !== undefined ? d.defaultValue : firstOptionValue(d.options))));
            }
            return builder;
        };
        builder.finish = function() { return props; };
        return builder;
    }
    function __noopProxy() {
        return new Proxy(function(){}, {
            get: function(t, k) { if (k === Symbol.toPrimitive) { return function(){ return ''; }; } return __noopProxy(); },
            set: function() { return true; },
            apply: function() { return __noopProxy(); },
            construct: function() { return __noopProxy(); }
        });
    }
    function __zeroArray(n) {
        var a = new Array(n);
        for (var i = 0; i < n; i += 1) { a[i] = 0; }
        return a;
    }
    var __audioBuffer = {
        left: __zeroArray(64), right: __zeroArray(64),
        left16: __zeroArray(16), right16: __zeroArray(16),
        left32: __zeroArray(32), right32: __zeroArray(32),
        left64: __zeroArray(64), right64: __zeroArray(64),
        average16: __zeroArray(16), average32: __zeroArray(32), average64: __zeroArray(64),
        spectrum: __zeroArray(64), waveform: __zeroArray(64)
    };
    __audioBuffer.average = __audioBuffer.average64;   // engine.audio.average 직접 접근용(res 미지정=64), average64 별칭
    // 프로젝션(캔버스) 크기 — thisScene.size/screenSize/resolution·engine.canvasSize 가 이 한 인스턴스를
    // 공유(별칭). __setCanvasSize 는 제자리 갱신이라 스크립트가 보관한 참조도 함께 갱신된다.
    // (Vec2/__num 은 함수 선언 호이스팅으로 이 시점 사용 가능.)
    var __canvasSize = new Vec2(1920, 1080);
    function __setCanvasSize(w, h) {
        __canvasSize.x = __num(w, 1920);
        __canvasSize.y = __num(h, 1080);
    }
    // engine.isScreensaver(): 프로세스 전역 플래그(Swift TextScriptEngine.isScreensaver 가 __setScreensaver 로 주입).
    var __isScreensaver = false;
    function __setScreensaver(v) { __isScreensaver = !!v; }
    // engine.setTimeout/setInterval: 벽시계가 아닌 runtime 클록 기반 만기 큐(결정적 — 캡처 t 주입 시 동일 발화).
    // 펌프는 setRuntime(= __engineState.runtime 갱신) 이 수행.
    var __timeoutQueue = [];   // {id, at(초), every(초, 0=1회), cb, cancelled}
    var __timeoutSeq = 0;
    // F704(S-40): WE 계약은 setTimeout/setInterval 이 "취소용 콜백" 반환(d.ts:2451-2456 "Returns a new callback
    // that can be used to stop") — 실물 관용구 `stopTimeout = engine.setTimeout(...); if (stopTimeout) stopTimeout();`
    // (3367988661 MI 패밀리)이 숫자 id 반환에서는 함수 호출 TypeError 로 update 가 죽었다.
    // clearTimeout 은 숫자 id(하위호환)와 취소함수(__wapleTimerId) 둘 다 수용(바이너리도 clearTimeout 수출).
    function __scheduleTimer(cb, ms, repeat) {
        if (typeof cb !== 'function') { return function() {}; }
        var id = ++__timeoutSeq;
        var entry = { id: id, at: __engineState.runtime + __num(ms, 0) / 1000,
                      every: repeat ? Math.max(__num(ms, 0), 1) / 1000 : 0, cb: cb, cancelled: false };
        __timeoutQueue.push(entry);
        var cancel = function() { entry.cancelled = true; };
        cancel.__wapleTimerId = id;
        return cancel;
    }
    function __pumpTimeouts() {
        var now = __engineState.runtime;
        var cutoff = __timeoutSeq;   // 콜백 내 재등록(0ms 체인)은 다음 틱으로 — 동일 틱 무한루프 방지
        var i;
        for (i = __timeoutQueue.length - 1; i >= 0; i -= 1) {   // 취소분 청소(큐 팽창 방지)
            if (__timeoutQueue[i].cancelled) { __timeoutQueue.splice(i, 1); }
        }
        for (;;) {
            var best = -1;
            for (i = 0; i < __timeoutQueue.length; i += 1) {   // ponytail: 선형 스캔 — 씬당 타이머는 한 자릿수
                var e = __timeoutQueue[i];
                if (e.at > now || e.id > cutoff || e.cancelled) { continue; }
                if (best < 0 || e.at < __timeoutQueue[best].at
                    || (e.at === __timeoutQueue[best].at && e.id < __timeoutQueue[best].id)) { best = i; }
            }
            if (best < 0) { return; }
            var entry = __timeoutQueue.splice(best, 1)[0];
            if (entry.every > 0 && !entry.cancelled) {   // setInterval: 다음 주기로 재등록
                entry.at += entry.every;   // 추격형(누적 틱 보존 — JS setInterval 세맨틱스)
                // 장시간 점프(슬립 복귀 등) 시 틱 폭주 방지: 64틱 이상 누적이면 fast-forward.
                if (entry.at + entry.every * 64 < now) { entry.at = now + entry.every; }
                __timeoutQueue.push(entry);
            }
            entry.cb();   // 예외 → evaluateScript 예외(기존 exceptionHandler 로깅). 잔여 만기분은 다음 틱에.
        }
    }
    // engine.audio/audioBuffer 실데이터: 네이티브 setAudio 가 호출. 배열은 제자리 갱신 —
    // 스크립트가 보관한 audioBuffer/g_AudioSpectrum* 별칭이 살아 있어야 한다. waveform 은 데이터원 없음(0 유지).
    var __audioCallbacks = [];
    function __setAudioData(l, r) {
        function avg(src, dst, group) {
            for (var i = 0; i < dst.length; i += 1) {
                var s = 0;
                for (var j = 0; j < group; j += 1) { s += src[i * group + j]; }
                dst[i] = s / group;
            }
        }
        for (var i = 0; i < 64; i += 1) {
            var lv = __num(l && l[i], 0), rv = __num(r && r[i], 0);
            __audioBuffer.left[i] = lv;   __audioBuffer.right[i] = rv;
            __audioBuffer.left64[i] = lv; __audioBuffer.right64[i] = rv;
            __audioBuffer.spectrum[i] = (lv + rv) / 2;
        }
        avg(__audioBuffer.left64, __audioBuffer.left32, 2);
        avg(__audioBuffer.right64, __audioBuffer.right32, 2);
        avg(__audioBuffer.left64, __audioBuffer.left16, 4);
        avg(__audioBuffer.right64, __audioBuffer.right16, 4);
        // H4: WE AudioBuffers.average = 좌우 평균(res 별). registerAudioBuffers 반환 버퍼가 이 배열을 별칭 참조.
        for (var m = 0; m < 64; m += 1) { __audioBuffer.average64[m] = (__audioBuffer.left64[m] + __audioBuffer.right64[m]) / 2; }
        for (var m = 0; m < 32; m += 1) { __audioBuffer.average32[m] = (__audioBuffer.left32[m] + __audioBuffer.right32[m]) / 2; }
        for (var m = 0; m < 16; m += 1) { __audioBuffer.average16[m] = (__audioBuffer.left16[m] + __audioBuffer.right16[m]) / 2; }
        for (var k = 0; k < __audioCallbacks.length; k += 1) { __audioCallbacks[k](__audioBuffer); }
    }
    // engine: runtime 등 실수치 프로퍼티는 실제 타깃에 두고, 나머지는 no-op 흡수.
    // frametime(소문자)이 실물 표기(818회/193pkg — 2881558311 ColorTinter 전환 타이머 등); frameTime 은 호환 보존.
    // F700(S-6): frametime 초기값 0.016 은 setRuntime 미호출 소비자(단독 평가)용 — 렌더 경로는 __setRuntime 이
    // 프레임마다 실델타로 덮어쓴다(WE: "Last frametime in seconds", d.ts:2492).
    var __engineState = { runtime: 0.0, frametime: 0.016, frameTime: 0.016,
                          audio: __audioBuffer, audioBuffer: __audioBuffer,
                          canvasSize: __canvasSize,
                          isWallpaper: function() { return true; },
                          isDesktopDevice: function() { return true; },
                          isMobileDevice: function() { return false; },
                          isScreensaver: function() { return __isScreensaver; },
                          isRunningInEditor: function() { return false; },
                          isPortrait: function() { return __canvasSize.y > __canvasSize.x; },
                          isLandscape: function() { return __canvasSize.x >= __canvasSize.y; },
                          setTimeout: function(cb, ms) { return __scheduleTimer(cb, ms, false); },
                          setInterval: function(cb, ms) { return __scheduleTimer(cb, ms, true); },
                          clearTimeout: function(id) {
                              var tid = (typeof id === 'function') ? id.__wapleTimerId : id;
                              for (var i = 0; i < __timeoutQueue.length; i += 1) {
                                  if (__timeoutQueue[i].id === tid) { __timeoutQueue[i].cancelled = true; }
                              }
                          },
                          AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
                          registerAudioBuffers: function(res) {
                              // H4: WE 계약은 registerAudioBuffers(resolution): AudioBuffers{left,right,average}(res 길이) 동기반환.
                              // 반환 배열은 __audioBuffer 제자리 배열의 별칭 → 매 프레임 setAudio 갱신이 반영된다.
                              // function 인자는 하위호환(콜백 등록도 계속 지원, __audioBuffer 반환).
                              if (typeof res === 'function') { __audioCallbacks.push(res); return __audioBuffer; }
                              var n = __num(res, 64);
                              if (n !== 16 && n !== 32 && n !== 64) { n = 64; }
                              return { left: __audioBuffer['left' + n], right: __audioBuffer['right' + n], average: __audioBuffer['average' + n] };
                          } };
    // F703(S-39): engine.timeOfDay = [0,1] 하루 진행률(WE 네이티브 getter, dig-scenescript-v8 §4 — d.ts:2487).
    // 부재 시 noopProxy 산술 0 으로 `engine.timeOfDay > sunRise/24` 가 영구 false(낮/밤 씬 영구 야간, 11씬).
    // Date 기반 — captureDateEpochMillis 핀(무인자 Date 고정)을 그대로 따라가 캡처 결정성 유지.
    Object.defineProperty(__engineState, 'timeOfDay', {
        get: function() {
            var d = new Date();
            return (d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds() + d.getMilliseconds() / 1000) / 86400;
        },
        set: function() {}   // 스크립트 대입은 무시(strict shims 라 setter 없으면 TypeError)
    });
    // F700(S-6): 프레임 절대시각 주입 — frametime 을 실델타(t − 직전 t)로 갱신한다. t > prev 일 때만 갱신:
    // 공유 컨텍스트에서 같은 t 로 엔진마다 재호출돼도 두 번째부터는 물변화(0 리셋 방지). 시간 후퇴(루프/리셋)도 유지.
    function __setRuntime(t) {
        t = __num(t, 0);
        var prev = __engineState.runtime;
        if (t > prev) { __engineState.frametime = t - prev; __engineState.frameTime = t - prev; }
        __engineState.runtime = t;
        __pumpTimeouts();
    }
    var engine = new Proxy(__engineState, {
        get: function(t, k) { if (k in t) { return t[k]; } return __noopProxy(); },
        set: function(t, k, v) { t[k] = v; return true; }
    });
    // WE 스크립트 표준 벡터(메서드 체이닝) — 레이어 컬러 스크립트가 사용.
    function Vec3(x, y, z) {
        if (typeof x === 'object' && x) { this.x = x.x || 0; this.y = x.y || 0; this.z = x.z || 0; }
        else { this.x = x || 0; this.y = y || 0; this.z = z || 0; }
    }
    Vec3.prototype.add = function (o) { return (typeof o === 'number') ? new Vec3(this.x + o, this.y + o, this.z + o) : new Vec3(this.x + o.x, this.y + o.y, this.z + o.z); };
    Vec3.prototype.subtract = function (o) { return (typeof o === 'number') ? new Vec3(this.x - o, this.y - o, this.z - o) : new Vec3(this.x - o.x, this.y - o.y, this.z - o.z); };
    Vec3.prototype.multiply = function (o) { return (typeof o === 'number') ? new Vec3(this.x * o, this.y * o, this.z * o) : new Vec3(this.x * o.x, this.y * o.y, this.z * o.z); };
    Vec3.prototype.divide = function (o) { return (typeof o === 'number') ? new Vec3(this.x / o, this.y / o, this.z / o) : new Vec3(this.x / o.x, this.y / o.y, this.z / o.z); };
    Vec3.prototype.mix = function (o, t) {
        t = Number(t) || 0;
        return new Vec3(this.x + ((o.x || 0) - this.x) * t,
                        this.y + ((o.y || 0) - this.y) * t,
                        this.z + ((o.z || 0) - this.z) * t);
    };
    Vec3.prototype.copy = function () { return new Vec3(this.x, this.y, this.z); };
    Vec3.prototype.length = function () { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); };
    // F705(S-41): d.ts Vec3 표면 보강 — 기존 add~length 뿐이라 reflect/normalize 호출이 TypeError 로 update 사망
    // (실물 2955378002 바운스: reflect 82회/10씬, normalize 3씬). add 등과 동일하게 새 Vec3 반환(비파괴) 규약.
    Vec3.prototype.normalize = function () {
        var l = this.length();
        return l > 0 ? new Vec3(this.x / l, this.y / l, this.z / l) : new Vec3(0, 0, 0);
    };
    Vec3.prototype.reflect = function (n) {   // 법선 n 에 대한 반사: v − 2·dot(v,n)·n (n 정규화 가정 — three.js 동일)
        n = n || { x: 0, y: 0, z: 0 };
        var d = 2 * (this.x * (n.x || 0) + this.y * (n.y || 0) + this.z * (n.z || 0));
        return new Vec3(this.x - d * (n.x || 0), this.y - d * (n.y || 0), this.z - d * (n.z || 0));
    };
    function Vec2(x, y) {
        if (typeof x === 'object' && x) { this.x = x.x || 0; this.y = x.y || 0; }
        else { this.x = x || 0; this.y = y || 0; }
    }
    Vec2.prototype.add = function (o) { return (typeof o === 'number') ? new Vec2(this.x + o, this.y + o) : new Vec2(this.x + o.x, this.y + o.y); };
    Vec2.prototype.subtract = function (o) { return (typeof o === 'number') ? new Vec2(this.x - o, this.y - o) : new Vec2(this.x - o.x, this.y - o.y); };
    Vec2.prototype.multiply = function (o) { return (typeof o === 'number') ? new Vec2(this.x * o, this.y * o) : new Vec2(this.x * o.x, this.y * o.y); };
    Vec2.prototype.divide = function (o) { return (typeof o === 'number') ? new Vec2(this.x / o, this.y / o) : new Vec2(this.x / o.x, this.y / o.y); };
    Vec2.prototype.mix = function (o, t) {
        t = Number(t) || 0;
        return new Vec2(this.x + ((o.x || 0) - this.x) * t,
                        this.y + ((o.y || 0) - this.y) * t);
    };
    Vec2.prototype.copy = function () { return new Vec2(this.x, this.y); };
    Vec2.prototype.length = function () { return Math.sqrt(this.x * this.x + this.y * this.y); };
    var __WEColor = {
        hsv2rgb: function(c) {
            var h = ((c.x % 1) + 1) % 1, s = c.y, v = c.z;
            var i = Math.floor(h * 6), f = h * 6 - i;
            var p = v * (1 - s), q = v * (1 - f * s), t2 = v * (1 - (1 - f) * s);
            var r, g, b;
            switch (i % 6) {
                case 0: r = v; g = t2; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t2; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t2; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return new Vec3(r, g, b);
        },
        rgb2hsv: function(c) {
            var r = c.x, g = c.y, b = c.z;
            var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
            var h = 0;
            if (d > 0) {
                if (mx === r) { h = ((g - b) / d) % 6; }
                else if (mx === g) { h = (b - r) / d + 2; }
                else { h = (r - g) / d + 4; }
                h /= 6; if (h < 0) { h += 1; }
            }
            return new Vec3(h, mx === 0 ? 0 : d / mx, mx);
        }
    };
    // WEMath 실심(코퍼스 58씬) — 표면은 공개 lib.sceneScript.d.ts 그대로: smoothStep/mix/deg2rad/rad2deg 뿐.
    var __WEMath = {
        // ponytail: d.ts 문구는 "min..max → [0,1] 재매핑"뿐 — Hermite 인지 선형 클램프인지 미확정.
        // GLSL/HLSL 동명 내장(셰이더 중심 엔진) 근거로 Hermite 채택; 골든 A/B 가 반박하면
        // `t * t * (3 - 2 * t)` 를 `t`(선형 램프)로 교체 — 두 형태는 구간 밖 클램프는 동일.
        smoothStep: function(min, max, value) {
            min = Number(min); max = Number(max); value = Number(value);
            if (min === max) { return value < min ? 0 : 1; }  // 퇴화(0폭 구간): step — 0나눗셈 NaN 누출 방지.
            var t = Math.max(0, Math.min(1, (value - min) / (max - min)));
            return t * t * (3 - 2 * t);
        },
        mix: function(a, b, value) { return Number(a) + (Number(b) - Number(a)) * Number(value); },
        deg2rad: Math.PI / 180,
        rad2deg: 180 / Math.PI
    };
    // F706(S-42): WEVector 실심 — 공개 표면은 angleVector2/vectorAngle2 단 2개(d.ts:1200-1209).
    // 종전 import 가 no-op Proxy(`var WEVector = __noopProxy();`)라 angleVector2 산술이 0 으로 붕괴(56회/10씬).
    // 각도 단위는 도(degree): 유일한 실물 사용 3351163962 `45 + Math.floor(Math.random() * 4) * 90`
    // (주석 "以90度为步长" = 90도 단위)이 도 단위를 증명 — WE 의 angles 관례(thisLayer.angles = 도)와도 일치.
    var __WEVector = {
        angleVector2: function(a) {
            var r = (Number(a) || 0) * Math.PI / 180;
            return new Vec2(Math.cos(r), Math.sin(r));
        },
        vectorAngle2: function(v) {
            return Math.atan2(v ? (Number(v.y) || 0) : 0, v ? (Number(v.x) || 0) : 0) * 180 / Math.PI;
        }
    };
    // 미디어 이벤트 클래스(실물 계약 — 필드는 193패키지 소비 역추출): 생성자는 기본값 채운 뒤
    // 주어진 필드를 전부 복사(실물 스크립트가 여러 이벤트를 한 객체에 합쳐 쓰는 union 소비 허용).
    // 상수 규약은 웹 wallpaperMediaIntegration 과 동일: STOPPED 0 / PLAYING 1 / PAUSED 2.
    function __mediaEvent(defaults) {
        return function (p) {
            var k;
            for (k in defaults) { this[k] = defaults[k]; }
            if (p) { for (k in p) { this[k] = p[k]; } }
        };
    }
    var MediaPlaybackEvent = __mediaEvent({ state: 0 });
    MediaPlaybackEvent.PLAYBACK_STOPPED = 0;
    MediaPlaybackEvent.PLAYBACK_PLAYING = 1;
    MediaPlaybackEvent.PLAYBACK_PAUSED = 2;
    var MediaPropertiesEvent = __mediaEvent({ title: '', artist: '', subTitle: '', albumTitle: '',
                                              albumArtist: '', genres: '', contentType: '' });
    var MediaTimelineEvent = __mediaEvent({ position: 0, duration: 0 });
    var MediaStatusEvent = __mediaEvent({ enabled: false });
    // 썸네일: 색 필드는 항상 Vec3(2881558311 ColorTinter 가 subtract/multiply/add 체이닝) — 인스턴스별 생성.
    function MediaThumbnailEvent(p) {
        this.thumbnail = null; this.hasThumbnail = false;
        this.primaryColor = new Vec3(0, 0, 0); this.secondaryColor = new Vec3(0, 0, 0);
        this.tertiaryColor = new Vec3(0, 0, 0);
        this.textColor = new Vec3(1, 1, 1); this.highContrastColor = new Vec3(1, 1, 1);
        if (p) { for (var k in p) { this[k] = p[k]; } }
    }
    var AnimationEvent = __mediaEvent({ name: '', frame: 0, progress: 0, finished: false });
    function __makeTextureAnimation() {
        return {
            frame: 0, frameCount: 1, fps: 0, rate: 1, duration: 0, paused: false,
            getFrame: function() { return this.frame; },
            setFrame: function(v) { this.frame = Number(v) || 0; return this; },
            getFrameCount: function() { return this.frameCount; },
            getRate: function() { return this.rate; },
            setRate: function(v) { this.rate = Number(v) || 0; return this; },
            getDuration: function() { return this.duration; },
            getProgress: function() { return this.frameCount > 0 ? this.frame / this.frameCount : 0; },
            setProgress: function(v) { this.frame = (Number(v) || 0) * this.frameCount; return this; },
            isPlaying: function() { return !this.paused; },
            isPaused: function() { return !!this.paused; },
            play: function() { this.paused = false; return this; },
            pause: function() { this.paused = true; return this; },
            stop: function() { this.paused = true; this.frame = 0; return this; }
        };
    }
    function __makeTexture() {
        var anim = __makeTextureAnimation();
        return {
            width: 1, height: 1, size: new Vec2(1, 1), animation: anim,
            getAnimation: function() { return anim; },
            getFrame: function() { return anim.frame; },
            setFrame: function(v) { anim.setFrame(v); return this; },
            play: function() { anim.play(); return this; },
            pause: function() { anim.pause(); return this; },
            stop: function() { anim.stop(); return this; }
        };
    }
    function __makeCamera() {
        return {
            position: new Vec3(0, 0, 0), eye: new Vec3(0, 0, 0),
            center: new Vec3(0, 0, -1), target: new Vec3(0, 0, -1),
            up: new Vec3(0, 1, 0), direction: new Vec3(0, 0, -1),
            fov: 45, near: 0.1, far: 1000,
            project: function(v) { return new Vec3(v); },
            unproject: function(v) { return new Vec3(v); },
            lookAt: function() { return this; }
        };
    }
    function __makeCameraTransforms() {
        return {
            position: new Vec3(0, 0, 0), targetPosition: new Vec3(0, 0, -1),
            eye: new Vec3(0, 0, 0), center: new Vec3(0, 0, -1),
            angles: new Vec3(0, 0, 0), targetAngles: new Vec3(0, 0, 0),
            target: new Vec3(0, 0, -1), up: new Vec3(0, 1, 0),
            distance: 0, targetDistance: 0, fov: 45
        };
    }
    function __makeAnimationLayer() {
        var anim = __makeTextureAnimation();
        return {
            name: '', blend: 1, weight: 1, animation: anim,
            getTextureAnimation: function() { return anim; },
            getAnimation: function() { return anim; },
            getBlend: function() { return this.blend; },
            setBlend: function(v) { this.blend = Number(v) || 0; return this; },
            getWeight: function() { return this.weight; },
            setWeight: function(v) { this.weight = Number(v) || 0; return this; },
            play: function() { anim.play(); return this; },
            pause: function() { anim.pause(); return this; },
            stop: function() { anim.stop(); return this; }
        };
    }
    var __rootLayer = null;
    // F707(S-32): Mat4 심 — 컬럼메이저 m[16](m[12]/m[13]/m[14] = 평행이동 x/y/z). 실물 판별식은
    // `parent.getTransformMatrix().m[13] > engine.canvasSize.y/2`(MI/시계 패밀리, 12씬)처럼 평행이동 성분 소비.
    // 로컬 TRS(angles = 도 단위, Rz·Ry·Rx 순 적용)를 부모 체인으로 합성해 월드행렬을 만든다.
    function __mat4Identity() { return { m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }; }
    function __mat4Multiply(a, b) {   // a·b (컬럼메이저)
        var o = new Array(16);
        for (var c = 0; c < 4; c += 1) {
            for (var r = 0; r < 4; r += 1) {
                o[c * 4 + r] = a.m[r] * b.m[c * 4] + a.m[4 + r] * b.m[c * 4 + 1]
                             + a.m[8 + r] * b.m[c * 4 + 2] + a.m[12 + r] * b.m[c * 4 + 3];
            }
        }
        return { m: o };
    }
    function __mat4FromTRS(origin, anglesDeg, scale) {
        var d = Math.PI / 180;
        var rx = (anglesDeg && anglesDeg.x || 0) * d, ry = (anglesDeg && anglesDeg.y || 0) * d,
            rz = (anglesDeg && anglesDeg.z || 0) * d;
        var cx = Math.cos(rx), sx = Math.sin(rx), cy = Math.cos(ry), sy = Math.sin(ry),
            cz = Math.cos(rz), sz = Math.sin(rz);
        var kx = scale && scale.x || 0, ky = scale && scale.y || 0, kz = scale && scale.z || 0;
        var tx = origin && origin.x || 0, ty = origin && origin.y || 0, tz = origin && origin.z || 0;
        // R = Rz·Ry·Rx 전개(컬럼 0..2 = 회전·스케일된 기저, m[12..14] = 평행이동):
        //  [ cz·cy,  cz·sy·sx − sz·cx,  cz·sy·cx + sz·sx ]
        //  [ sz·cy,  sz·sy·sx + cz·cx,  sz·sy·cx − cz·sx ]
        //  [  −sy,         cy·sx,               cy·cx      ]
        return { m: [
            cz * cy * kx, sz * cy * kx, -sy * kx, 0,
            (cz * sy * sx - sz * cx) * ky, (sz * sy * sx + cz * cx) * ky, cy * sx * ky, 0,
            (cz * sy * cx + sz * sx) * kz, (sz * sy * cx - cz * sx) * kz, cy * cx * kz, 0,
            tx, ty, tz, 1
        ] };
    }
    function __layerWorldMatrix(layer) {
        // 부모 체인 수집(루트 자기참조 순환은 제외) 후 바깥쪽부터 곱한다: world = L루트…L부모·L로컬.
        var chain = [];
        var p = layer.parent, depth = 0;
        while (p && p !== p.parent && depth < 32) { chain.push(p); p = p.parent; depth += 1; }
        var m = __mat4Identity();
        for (var i = chain.length - 1; i >= 0; i -= 1) {
            m = __mat4Multiply(m, __mat4FromTRS(chain[i].origin, chain[i].angles, chain[i].scale));
        }
        return __mat4Multiply(m, __mat4FromTRS(layer.origin, layer.angles, layer.scale));
    }
    function __makeLayer() {
        var tex = __makeTexture();
        var animLayer = __makeAnimationLayer();
        var layer = {
            name: '', visible: true, alpha: 1,
            origin: new Vec3(0, 0, 0), angles: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1),
            size: new Vec2(1, 1), color: new Vec3(1, 1, 1),
            text: '', solid: false, texture: tex, textures: [tex], parent: null, children: [],
            getTexture: function(i) { return this.textures[i || 0] || tex; },
            getTextureAnimation: function() { return tex.animation; },
            getAnimation: function() { return tex.animation; },
            getAnimationLayer: function() { return animLayer; },
            createAnimationLayer: function() { return animLayer; },
            setAnimationFrame: function(v) { tex.animation.setFrame(v); return this; },
            playAnimation: function() { tex.animation.play(); return this; },
            pauseAnimation: function() { tex.animation.pause(); return this; },
            stopAnimation: function() { tex.animation.stop(); return this; },
            getParent: function() { return this.parent || __rootLayer; },
            setParent: function(p) { this.parent = p || null; return this; },
            getChildren: function() { return this.children.slice(); },
            addChild: function(c) { if (c) { this.children.push(c); c.parent = this; } return this; },
            getName: function() { return this.name; },
            setName: function(v) { this.name = String(v || ''); return this; },
            getOrigin: function() { return this.origin; },
            setOrigin: function(v) { this.origin = new Vec3(v); return this; },
            getAngles: function() { return this.angles; },
            setAngles: function(v) { this.angles = new Vec3(v); return this; },
            getScale: function() { return this.scale; },
            setScale: function(v) { this.scale = new Vec3(v); return this; },
            getVisible: function() { return this.visible; },
            setVisible: function(v) { this.visible = !!v; return this; },
            getAlpha: function() { return this.alpha; },
            setAlpha: function(v) { this.alpha = Number(v) || 0; return this; },
            getText: function() { return this.text; },
            setText: function(v) { this.text = String(v || ''); return this; },
            // F707(S-32)/F708(S-33): ILayer 변환행렬(부모 체인 합성 월드)과 애니메이션 레이어 수 —
            // 미바인딩 시 `parent.getTransformMatrix().m[13]` 류가 TypeError 로 init/update 사망(12씬/7씬).
            getTransformMatrix: function() { return __layerWorldMatrix(this); },
            animationLayerCount: 0,   // __setSceneLayers 가 디스크립터 값으로 덮어씀(F708)
            getAnimationLayerCount: function() { return this.animationLayerCount; },
            getEffect: function() { return __noopProxy(); },
            // E1(⑤): ILayer.getVideoTexture/getParticleSystem/emitParticles 안전 심 — 종전 부재라
            // 평객체 호출 즉시 TypeError 로 init/update 전체가 죽고(정적 visible=false 레이어가 영구
            // 미표시로 굳는 등) 이후 스크립트 로직이 실행되지 않았다. getEffect 와 동일하게 noopProxy
            // 반환(임의 체인 호출 안전 — 실 비디오/파티클 연결은 렌더 경로 책임, 보류).
            getVideoTexture: function() { return __noopProxy(); },
            getParticleSystem: function() { return __noopProxy(); },
            emitParticles: function() { return this; }
        };
        return layer;
    }
    function __makeRootLayer() {
        var root = {
            name: '', visible: true, alpha: 1, parent: null, children: [],
            origin: new Vec3(0, 0, 0), angles: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1),
            size: new Vec2(1, 1), color: new Vec3(1, 1, 1),
            getParent: function() { return root; },
            setParent: function() { return root; },
            getChildren: function() { return root.children.slice(); },
            addChild: function(c) { if (c) { root.children.push(c); c.parent = root; } return root; },
            getName: function() { return root.name; },
            setName: function(v) { root.name = String(v || ''); return root; },
            getVisible: function() { return root.visible; },
            setVisible: function(v) { root.visible = !!v; return root; },
            getOrigin: function() { return root.origin; },
            getAngles: function() { return root.angles; },
            getScale: function() { return root.scale; },
            getTexture: function() { return __makeTexture(); },
            getTextureAnimation: function() { return __makeTextureAnimation(); },
            getAnimation: function() { return __makeTextureAnimation(); },
            getAnimationLayer: function() { return __makeAnimationLayer(); },
            createAnimationLayer: function() { return __makeAnimationLayer(); },
            getTransformMatrix: function() { return __mat4Identity(); },   // F707: 루트는 항등
            getAnimationLayerCount: function() { return 0; },              // F708
            getEffect: function() { return __noopProxy(); },
            getVideoTexture: function() { return __noopProxy(); },        // E1(⑤)
            getParticleSystem: function() { return __noopProxy(); },
            emitParticles: function() { return root; }
        };
        root.parent = root;
        return root;
    }
    function __makeScene(layer) {
        var camera = __makeCamera();
        var transforms = __makeCameraTransforms();
        var fallbackLayers = {};
        function fallbackLayer(name) {
            name = String(name || '');
            if (!fallbackLayers[name]) {
                var l = __makeLayer();
                l.name = name;
                l.alpha = 1;
                l.visible = true;
                l.solid = true;
                fallbackLayers[name] = l;
            }
            return fallbackLayers[name];
        }
        return {
            size: __canvasSize, screenSize: __canvasSize, resolution: __canvasSize,
            camera: camera, layers: [layer],
            __soundLayers: {},   // name → 사운드 레이어(getLayer/enumerateLayers 로 노출 — 트리거/주크박스)
            getCamera: function() { return camera; },
            getCameraTransforms: function() { return transforms; },
            setCameraTransforms: function(v) { if (v) { transforms = v; } return this; },
            __animations: {},   // name → 타임라인 애니메이션 no-op 심(이름별 캐시 — isPlaying 재조회 일관)
            // WE SceneScript thisScene.getAnimation(name): 명명 타임라인 애니메이션. Waple 은 씬 타임라인을
            // 렌더하지 않으므로 no-op 심(초기 정지) — 작가 스크립트의 .play() 체인이 예외 없이 완주해
            // shared 토글 등 후속 로직이 살게 하는 것이 목적(실물 3394601417 낮/밤: getAnimation("2chu") 라이브 호출).
            getAnimation: function(name) {
                var key = String(name || '');
                if (!this.__animations[key]) {
                    var a = __makeTextureAnimation();
                    a.paused = true;   // 타임라인은 play() 전 정지 상태가 규약
                    this.__animations[key] = a;
                }
                return this.__animations[key];
            },
            getLayer: function(i) {
                if (typeof i === 'string') {
                    for (var n = 0; n < this.layers.length; n += 1) {
                        if (this.layers[n].name === i) { return this.layers[n]; }
                    }
                    if (this.__soundLayers[i]) { return this.__soundLayers[i]; }   // 사운드 레이어 이름 매칭(트리거)
                    return fallbackLayer(i);
                }
                return this.layers[i || 0] || layer;
            },
            getLayerIndex: function(l) {
                var idx = this.layers.indexOf(l);
                return idx < 0 ? 0 : idx;
            },
            enumerateLayers: function() {
                var out = this.layers.slice();
                var hasNamed = false;
                for (var i = 0; i < out.length; i += 1) {
                    if (out[i].name) { hasNamed = true; break; }
                }
                if (!hasNamed) { out.push(fallbackLayer('player')); }
                for (var k in fallbackLayers) {
                    if (out.indexOf(fallbackLayers[k]) < 0) { out.push(fallbackLayers[k]); }
                }
                // 사운드 레이어도 열거(주크박스는 name.includes('.mp3') 등으로 자체 필터 — 별도 마커 불요).
                for (var sk in this.__soundLayers) {
                    if (out.indexOf(this.__soundLayers[sk]) < 0) { out.push(this.__soundLayers[sk]); }
                }
                return out;
            },
            createLayer: function(name) {
                // E1(⑤): 무해 스텁 — JS layers 배열에만 추가(실 GPU 렌더 경로 연결은 보류, 별도 갭).
                // 저작자가 이 반환 레이어를 이후 조작해도 화면엔 나타나지 않으므로 1회 경고.
                if (typeof __wapleWarnCreateLayer === 'function') { __wapleWarnCreateLayer(String(name || '')); }
                var l = __makeLayer();
                l.name = String(name || '');
                this.layers.push(l);
                return l;
            },
            // E1(⑤): IScene.destroyLayer/getLayerCount/getLayerByID 안전 심 — 종전 부재라
            // `thisScene.destroyLayer(x)` 호출 즉시 TypeError 로 update 전체가 죽었다(392).
            // 주의: this.layers 의 위치 인덱스는 렌더러 read-back 채널(readBackScriptLayerState)이
            // doc.layers 인덱스(=layer.uid)로 직접 참조하는 규약이라, splice 로 배열을 줄이면 그 뒤
            // 모든 레이어/텍스트의 인덱스가 한 칸씩 밀려 다른 레이어 값이 잘못 적용된다. 슬롯을
            // 보존하는 툼스톤(비가시 처리)으로 대체 — getLayerCount 만 툼스톤을 제외해 셈한다.
            destroyLayer: function(l) {
                var idx = -1;
                if (typeof l === 'string') {
                    for (var i = 0; i < this.layers.length; i += 1) { if (this.layers[i].name === l) { idx = i; break; } }
                } else if (l) {
                    idx = this.layers.indexOf(l);
                }
                if (idx >= 0) {
                    this.layers[idx].__wapleDestroyed = true;
                    this.layers[idx].visible = false;
                }
                return idx >= 0;
            },
            getLayerCount: function() {
                var n = 0;
                for (var i = 0; i < this.layers.length; i += 1) {
                    if (!this.layers[i].__wapleDestroyed) { n += 1; }
                }
                return n;
            },
            getLayerByID: function(id) {
                for (var i = 0; i < this.layers.length; i += 1) {
                    if (this.layers[i].__wapleId === id) { return this.layers[i]; }
                }
                return null;
            },
            sortLayer: function() { return this; },
            getInitialLayerConfig: function() { return { origin: new Vec3(0, 0, 0), angles: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1) }; },
            getObject: function(i) { return this.getLayer(i); },
            getTexture: function(i) { return layer.getTexture(i); }
        };
    }
    function __num(v, fallback) {
        v = Number(v);
        return isFinite(v) ? v : fallback;
    }
    function __vec3FromArray(v, fallback) {
        fallback = fallback || [0, 0, 0];
        return new Vec3(__num(v && v[0], fallback[0]), __num(v && v[1], fallback[1]), __num(v && v[2], fallback[2]));
    }
    function __vec2FromArray(v, fallback) {
        fallback = fallback || [0, 0];
        return new Vec2(__num(v && v[0], fallback[0]), __num(v && v[1], fallback[1]));
    }
    function __layerFromDescriptor(d) {
        var l = __makeLayer();
        d = d || {};
        l.name = String(d.name || '');
        l.visible = d.visible !== false;
        l.alpha = __num(d.alpha, 1);
        l.origin = __vec3FromArray(d.origin, [0, 0, 0]);
        l.scale = __vec3FromArray(d.scale, [1, 1, 1]);
        l.angles = __vec3FromArray(d.angles, [0, 0, 0]);
        l.size = __vec2FromArray(d.size, [1, 1]);
        l.solid = !!d.solid;
        l.text = String(d.text || '');
        l.__wapleId = (typeof d.id === 'number') ? d.id : 0;              // F711: parent 체인 배선용
        l.__wapleParentId = (typeof d.parentId === 'number') ? d.parentId : null;
        l.animationLayerCount = (typeof d.animationLayerCount === 'number') ? d.animationLayerCount : 0;   // F708
        return l;
    }
    // F711(S-36): getParent() 가 항상 root 였던 결함 — 디스크립터의 id/parentId(scene.json objects id 체계)로
    // 실 부모를 배선한다. 부모 id 가 디스크립터 목록에 없으면(비가시 그룹 등) parent=null 유지 → root 폴터(무회귀).
    function __wireLayerParents(layers) {
        var byId = {};
        for (var i = 0; i < layers.length; i += 1) {
            if (layers[i].__wapleId) { byId[layers[i].__wapleId] = layers[i]; }
        }
        for (i = 0; i < layers.length; i += 1) {
            var pid = layers[i].__wapleParentId;
            if (pid !== null && byId[pid]) { layers[i].parent = byId[pid]; }
        }
    }
    __rootLayer = __makeRootLayer();
    var thisLayer = __makeLayer();
    var thisObject = thisLayer;
    var thisScene = __makeScene(thisLayer);
    // 사운드 트리거 브리지: 네이티브 전역(__wapleSound* — SceneScriptContext 가 씬 컨텍스트에만 설치)로 위임.
    // 미설치(단독/웹 컨텍스트)면 typeof 가드로 안전 no-op. 실제 트랜스포트는 SceneAudioPlayer.
    var __wapleSound = {
        play: function(n){ if (typeof __wapleSoundPlay === 'function') { __wapleSoundPlay(String(n)); } },
        stop: function(n){ if (typeof __wapleSoundStop === 'function') { __wapleSoundStop(String(n)); } },
        pause: function(n){ if (typeof __wapleSoundPause === 'function') { __wapleSoundPause(String(n)); } },
        isPlaying: function(n){ return (typeof __wapleSoundIsPlaying === 'function') ? !!__wapleSoundIsPlaying(String(n)) : false; },
        getVolume: function(n){ return (typeof __wapleSoundGetVolume === 'function') ? Number(__wapleSoundGetVolume(String(n))) : 0; },
        setVolume: function(n, v){ if (typeof __wapleSoundSetVolume === 'function') { __wapleSoundSetVolume(String(n), Number(v)); } }
    };
    // 사운드 레이어 = 시각 레이어 슈퍼셋(color/setAlpha 등 no-op 보존 → enumerateLayers 소비자 무회귀)
    // + play/stop/pause/isPlaying 메서드 + .volume 세터/게터. getLayer(name)/enumerateLayers 로 노출.
    function __makeSoundLayer(name) {
        var layer = __makeLayer();
        layer.name = String(name || '');
        layer.solid = false;
        layer.play = function(){ __wapleSound.play(this.name); return this; };
        layer.stop = function(){ __wapleSound.stop(this.name); return this; };
        layer.pause = function(){ __wapleSound.pause(this.name); return this; };
        layer.isPlaying = function(){ return __wapleSound.isPlaying(this.name); };
        Object.defineProperty(layer, 'volume', {
            get: function(){ return __wapleSound.getVolume(layer.name); },
            set: function(v){ __wapleSound.setVolume(layer.name, v); }
        });
        return layer;
    }
    function __setSoundLayers(names) {
        if (!names || !names.length) { return; }
        for (var i = 0; i < names.length; i += 1) {
            var nm = String(names[i] || '');
            if (nm.length > 0) { thisScene.__soundLayers[nm] = __makeSoundLayer(nm); }
        }
    }
    function __setSceneLayers(descriptors) {
        if (!descriptors || !descriptors.length) { return; }
        var layers = [];
        for (var i = 0; i < descriptors.length; i += 1) {
            layers.push(__layerFromDescriptor(descriptors[i]));
        }
        if (layers.length > 0) {
            __wireLayerParents(layers);   // F711
            thisScene.layers = layers;
            thisLayer = layers[0];
            thisObject = thisLayer;
        }
    }
    // F710(S-35): thisScene.getLayer 정적 스냅샷 결함 — 네이티브가 프레임마다 최신 디스크립터를 밀어 넣는다.
    // 스크립트가 쥔 참조(getLayer 반환 객체)가 살아있도록 **필드 제자리 갱신**(origin/scale/angles/size 의
    // Vec 객체 또한 성분 대입 — `var o = layer.origin` 보관 참조까지 라이브).
    function __assignVec(v, a) {
        if (!a) { return; }
        v.x = __num(a[0], v.x);
        v.y = __num(a[1], v.y);
        if (a.length > 2) { v.z = __num(a[2], v.z); }
    }
    function __updateSceneLayers(descriptors) {
        if (!descriptors || !descriptors.length) { return; }
        var n = Math.min(descriptors.length, thisScene.layers.length);
        for (var i = 0; i < n; i += 1) {
            var d = descriptors[i], l = thisScene.layers[i];
            if (!d || !l) { continue; }
            l.visible = d.visible !== false;
            l.alpha = __num(d.alpha, l.alpha);
            __assignVec(l.origin, d.origin);
            __assignVec(l.scale, d.scale);
            __assignVec(l.angles, d.angles);
            __assignVec(l.size, d.size);
            l.text = String(d.text || '');
            l.solid = !!d.solid;
        }
    }
    // F709(S-34): thisLayer = 스크립트가 붙은 오브젝트 자체(WE 계약) — 디스크립터 인덱스가 오면 그 레이어로
    // 직결한다. 종전 이름 첫 매치는 중복명(498레이어)/묪명(82레이어)에서 오바인딩(묪명은 layers[0] 으로).
    function __wapleLayerForScript(name, index) {
        if (typeof index === 'number' && index >= 0 && index < thisScene.layers.length) {
            return thisScene.layers[index];
        }
        if (typeof name !== 'string' || name.length === 0) { return thisLayer; }
        return thisScene.getLayer(name);
    }
    var shared = { camera: thisScene.getCameraTransforms(), miTextContainerScale: new Vec2(1, 1) };
    // F701(S-7): localStorage 전역 실심 — WE 계약 get/set/delete/clear + LOCATION_GLOBAL/SCREEN 상수
    // (d.ts:2377, 바이너리 LocalStorageSet/Get/Delete/Clear·LSKV0001). 부재 시 init 첫행 `localStorage.get(...)`
    // 이 ReferenceError 로 init 전체를 죽여 shared.* 초기화가 연쇄 사망했다(31씬, miDragable 드래그 패밀리).
    // F810: 디스크 영속 — 씬 컨텍스트에 __wapleStorage* 네이티브 브리지(SceneScriptContext, 라이브 mount 한정)가
    // 있으면 스냅샷으로 시드하고 set/delete/clear 마다 동기화(디바운스 기록은 네이티브 ScriptLocalStorage).
    // 브리지 부재(단독 컨텍스트/헤드리스)는 종전 인메모리 폴터(무회귀). subscribe 통지원은 여전히 부재(no-op).
    var localStorage = (function() {
        var store = {};
        if (typeof __wapleStorageSnapshot === 'function') {
            try {
                var snap = JSON.parse(__wapleStorageSnapshot() || '{}');
                for (var sk in snap) {
                    if (Object.prototype.hasOwnProperty.call(snap, sk)) {
                        try { store[sk] = JSON.parse(snap[sk]); } catch (ignore) {}
                    }
                }
            } catch (ignore) {}
        }
        function __persist(k) {
            if (typeof __wapleStorageSet !== 'function') { return; }
            var j;
            try { j = JSON.stringify(store[k]); } catch (e) { return; }   // 순환참조 등 직렬화 불가는 영속 스킵
            if (typeof j === 'string') { __wapleStorageSet(k, j); }        // undefined/함수는 미영속(get 계약 불변)
        }
        return {
            LOCATION_GLOBAL: 'global',
            LOCATION_SCREEN: 'screen',
            get: function(key, location) {
                var k = String(key);
                return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : undefined;
            },
            set: function(key, value, location) { var k = String(key); store[k] = value; __persist(k); },
            delete: function(key, location) {
                var k = String(key);
                delete store[k];
                if (typeof __wapleStorageDelete === 'function') { __wapleStorageDelete(k); }
            },
            clear: function(location) {
                store = {};
                if (typeof __wapleStorageClear === 'function') { __wapleStorageClear(); }
            },
            subscribe: function(key, cb) { return function() {}; }   // 통지원 부재 — no-op 안전 폴터
        };
    })();
    // F713(S-31): input 폴터 실심 — 종전 __noopProxy() 는 truthy 라 실물 가드(`if (input.cursorWorldPosition)`)
    // 통과 후 산술이 0/NaN 으로 붕괴해 마우스 팔로우 레이어가 굳었다(29씬). 네이티브가 __setCursorState 로
    // 제자리 갱신(참조 보존); 미주입(헤드리스/캡처)이면 0/거짓 유지. d.ts:2314-2329 — x/y 만 유효.
    // 알려진 키(cursorWorldPosition/cursorScreenPosition/cursorLeftDown)는 실값, 그 외 멤버는 engine 과
    // 동일하게 no-op Proxy 흡수(실심화로 미지 멤버 접근이 TypeError 가 되는 회귀 방지).
    var __inputState = {
        cursorWorldPosition: new Vec3(0, 0, 0),
        cursorScreenPosition: new Vec3(0, 0, 0),
        cursorLeftDown: false
    };
    var input = new Proxy(__inputState, {
        get: function(t, k) { if (k in t) { return t[k]; } return __noopProxy(); },
        set: function(t, k, v) { t[k] = v; return true; }
    });
    function __setCursorState(wx, wy, sx, sy, down) {
        __inputState.cursorWorldPosition.x = __num(wx, 0);
        __inputState.cursorWorldPosition.y = __num(wy, 0);
        __inputState.cursorScreenPosition.x = __num(sx, 0);
        __inputState.cursorScreenPosition.y = __num(sy, 0);
        __inputState.cursorLeftDown = !!down;
    }
    var audioBuffer = __audioBuffer;
    var g_AudioSpectrum16Left = __audioBuffer.left16;
    var g_AudioSpectrum16Right = __audioBuffer.right16;
    var g_AudioSpectrum32Left = __audioBuffer.left32;
    var g_AudioSpectrum32Right = __audioBuffer.right32;
    var g_AudioSpectrum64Left = __audioBuffer.left64;
    var g_AudioSpectrum64Right = __audioBuffer.right64;
    var console = { log: function(){}, error: function(){} };
    """
}
