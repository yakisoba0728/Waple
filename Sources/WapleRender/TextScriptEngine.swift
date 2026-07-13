import Foundation
import JavaScriptCore

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

    public init(name: String, visible: Bool = true, alpha: Float = 1,
                origin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                scale: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                angles: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                size: SIMD2<Float> = SIMD2<Float>(1, 1),
                solid: Bool = false, text: String = "") {
        self.name = name
        self.visible = visible
        self.alpha = alpha
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.size = size
        self.solid = solid
        self.text = text
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

    /// width/height = 프로젝션(캔버스) 크기 — thisScene.size/screenSize/resolution·engine.canvasSize 의
    /// 실값(기본 1920×1080: 기존 호출부 무회귀). SceneRenderer mount 가 doc.projectionWidth/Height 전달.
    public init?(layers: [SceneScriptLayerDescriptor] = [], soundNames: [String] = [],
                 width: Float = 1920, height: Float = 1080) {
        guard let ctx = JSContext() else { return nil }
        context = ctx
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] scene script context exception: \(ex?.toString() ?? "?")")
        }
        ctx.evaluateScript(TextScriptEngine.shims)
        ctx.evaluateScript("__setCanvasSize(\(TextScriptEngine.jsNumber(width)), \(TextScriptEngine.jsNumber(height)));")
        installSoundBridge(ctx)
        if !layers.isEmpty {
            ctx.evaluateScript("__setSceneLayers(\(Self.layersJSONArray(layers)));")
        }
        let named = soundNames.filter { !$0.isEmpty }
        if !named.isEmpty {
            ctx.evaluateScript("__setSoundLayers(\(Self.stringJSONArray(named)));")
        }
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

    /// 오디오 스펙트럼 실데이터 주입(채널당 64빈): __audioBuffer 를 제자리 갱신(left/right·16/32/64·spectrum)
    /// 후 registerAudioBuffers 콜백 발화. 라이브 오디오 provider onFrame(30fps, main 큐)에서만 호출 —
    /// 캡처/헤드리스는 미호출로 버퍼 0 유지(스냅샷 결정성). 64빈 미만 입력은 JS 쪽 __num 이 0 폴백.
    public func setAudio(left64: [Float], right64: [Float]) {
        context.evaluateScript("__setAudioData(\(Self.floatArrayLiteral(left64)), \(Self.floatArrayLiteral(right64)));")
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
                "text": l.text
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

/// WE 텍스트 프로퍼티 스크립트 실행기(JavaScriptCore).
/// 계약(실물): `createScriptProperties()` 빌더(.addCheckbox/.addText/... → .finish() = name→기본값 객체)
/// + `export function update(value) → String`. engine/shared/thisScene 등 엔진 API 는 no-op Proxy 로 심 —
/// 미디어류 스크립트는 데이터가 없어 자연히 빈 문자열을 반환(graceful).
/// ES 모듈 export 구문은 평가 전에 제거(JSC 는 스크립트 평가에서 모듈 미지원).
/// 두 모드: ① 단독 컨텍스트(웹/텍스트 호환 — update 필수) ② 씬 공유 컨텍스트(IIFE 격리 —
/// update 없는 사이드이펙트 전용 스크립트도 로드: 실물 컨트롤러는 top-level 에서 shared 를 초기화하고
/// cursorClick 만 export 한다).
public final class TextScriptEngine {
    private let context: JSContext
    private let updateFn: JSValue?
    private let initFn: JSValue?
    private var didCallInit = false
    /// export 된 이벤트 훅(name → 함수). update 외 실물 계약: cursorClick(3394601417 주야 토글),
    /// media*Changed(뮤직 씬 — 2881558311 ColorTinter 등). cursorDown/Up/Move 는 보관만(배선은 추후).
    private var hookFns: [String: JSValue] = [:]

    /// 씬 스크립트가 export 할 수 있는 이벤트 훅 이름(실물 193패키지 역추출).
    static let eventHookNames = ["init", "applyUserProperties",
                                 "cursorClick", "cursorDown", "cursorUp", "cursorMove",
                                 "cursorEnter", "cursorLeave", "animationEvent",
                                 "mediaPlaybackChanged", "mediaPropertiesChanged", "mediaThumbnailChanged",
                                 "mediaTimelineChanged", "mediaStatusChanged"]
    private static let maxScriptCharacters = 512_000

    public init?(script: String) {
        guard Self.passesPracticalSafetyChecks(script) else { return nil }
        guard let ctx = JSContext() else { return nil }
        context = ctx
        var hadException = false
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] text script exception: \(ex?.toString() ?? "?")")
            hadException = true
        }
        ctx.evaluateScript(Self.shims)
        let cleaned = Self.stripModuleSyntax(script)
        ctx.evaluateScript(cleaned)
        guard !hadException,
              let fn = ctx.objectForKeyedSubscript("update"), fn.isObject else { return nil }
        updateFn = fn
        let i = ctx.objectForKeyedSubscript("init")
        initFn = (i?.isObject == true) ? i : nil
        for name in Self.eventHookNames {
            if let f = ctx.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
        }
    }

    /// 씬 공유 컨텍스트 모드: 스크립트를 IIFE 로 감싸 평가(전역 오염/update 이름충돌 방지)하고
    /// {update, cursorClick, media*Changed...} 훅 딕셔너리를 반환받아 보관.
    /// update/훅 부재도 성공(top-level 사이드이펙트는 이미 실행됨).
    /// 로드 예외(문법 오류 등) → nil, 공유 컨텍스트는 오염되지 않는다(IIFE 미실행).
    public init?(script: String, scene: SceneScriptContext, currentLayerName: String? = nil) {
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
        let exports = (["update"] + Self.eventHookNames)
            .map { "\($0): (typeof \($0) !== 'undefined') ? \($0) : null" }
            .joined(separator: ", ")
        let layerArg = currentLayerName.map(Self.javascriptStringLiteral) ?? "null"
        let wrapped = """
        (function(__wapleThisLayer){
        var __wapleGlobal = Function('return this')();
        var thisLayer = __wapleThisLayer || __wapleGlobal.thisLayer;
        var thisObject = thisLayer;
        \(cleaned)
        ;return { \(exports) };
        })(__wapleLayerForScript(\(layerArg)))
        """
        let out = context.evaluateScript(wrapped)
        guard !hadException else { return nil }
        if let out, out.isObject {
            let u = out.objectForKeyedSubscript("update")
            updateFn = (u?.isObject == true) ? u : nil
            let i = out.objectForKeyedSubscript("init")
            initFn = (i?.isObject == true) ? i : nil
            for name in Self.eventHookNames {
                if let f = out.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
            }
        } else {
            updateFn = nil
            initFn = nil
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

    /// update(current) 호출 → 새 텍스트. 예외/비문자열 → nil.
    public func evaluate(current: String) -> String? {
        guard let updateFn else { return nil }
        return withExceptionCapture("text script update exception") { failed -> String? in
            callInitIfNeeded(argument: current)
            guard !failed() else { return nil }
            guard let out = updateFn.call(withArguments: [current]), !failed(), out.isString else { return nil }
            return out.toString()
        }
    }

    /// visible 스크립트용: update(current) → 부울(숫자는 0=false). 예외/부재/비해석 → nil(현상 유지).
    public func evaluateBool(current: Bool) -> Bool? {
        guard let updateFn else { return nil }
        return withExceptionCapture("visible script exception") { failed -> Bool? in
            callInitIfNeeded(argument: current)
            guard !failed() else { return nil }
            guard let out = updateFn.call(withArguments: [current]), !failed() else { return nil }
            if out.isBoolean { return out.toBool() }
            if out.isNumber { return out.toDouble() != 0 }
            return nil
        }
    }

    /// 효과 상수 스크립트용: engine.runtime 갱신(초) + engine.setTimeout 만기 큐 펌프.
    /// 공유 씬 컨텍스트에선 여러 엔진이 같은 t 로 재호출 — 펌프는 멱등(만기분은 1회만 발화).
    public func setRuntime(_ t: Double) {
        context.evaluateScript("__engineState.runtime = \(t); __pumpTimeouts();")
    }

    /// update({x,y,z...}) 호출 → 수치 배열(스칼라는 1개). 예외/비수치 → nil.
    public func evaluateVec(current: [Float]) -> [Float]? {
        guard let updateFn else { return nil }
        return withExceptionCapture("constant script exception") { failed -> [Float]? in
            guard let arg = vecArgument(current), !failed() else { return nil }
            callInitIfNeeded(argument: arg)
            guard !failed() else { return nil }
            guard let out = updateFn.call(withArguments: [arg]), !failed() else { return nil }
            if out.isNumber { return [Float(out.toDouble())] }
            guard out.isObject else { return nil }
            let x = out.objectForKeyedSubscript("x"), y = out.objectForKeyedSubscript("y"), z = out.objectForKeyedSubscript("z")
            guard let x, let y, x.isNumber, y.isNumber else { return nil }
            if let z, z.isNumber { return [Float(x.toDouble()), Float(y.toDouble()), Float(z.toDouble())] }
            return [Float(x.toDouble()), Float(y.toDouble())]
        }
    }

    private func callInitIfNeeded(argument: Any) {
        guard !didCallInit else { return }
        didCallInit = true
        guard let initFn else { return }
        initFn.call(withArguments: [initArgument(from: argument)])
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
        func isIdent(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }
        func emit(_ c: Character) {
            out.append(c)
            if !c.isWhitespace {
                prevSig = c
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
                let isKeyword = (word == Array("export") || word == Array("import"))
                    && prevSig != "." && prevSig != "/"
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
                        emitAll(Array("var __default =")); i = after + "default".count; continue
                    }
                    if ac == "{" || ac == "*" {
                        // export {..} / export * .. — 문 전체(다음 ';' 까지) 삭제.
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
            emit(c); i += 1
        }
        return String(out)
    }

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
            if word(at: i, "while") {
                var p = i + "while".count
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
                    }
                }
            } else if word(at: i, "for") {
                var p = i + "for".count
                skipWS(&p)
                if p < n, chars[p] == "(" {
                    p += 1
                    skipWS(&p)
                    if p < n, chars[p] == ";" {
                        p += 1
                        skipWS(&p)
                        if p < n, chars[p] == ";" { return true }
                    } else if forLoopHasHugeBound(start: p) {
                        return true
                    }
                }
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

        func forLoopHasHugeBound(start: Int) -> Bool {
            var p = start
            var semicolons = 0
            var condition: [Character] = []
            while p < n, chars[p] != ")" {
                let c = chars[p]
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
                if c == ";" {
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
    /// `* as X` / `{a, b as c}` / `default` / `default, {..}`(콤보) 지원. WEColor 는 실심 바인딩.
    private static func importBindings(clause: String) -> String {
        let clause = clause.trimmingCharacters(in: .whitespaces)
        guard !clause.isEmpty else { return "" }
        func decl(_ name: String) -> String {
            name == "WEColor" ? "var WEColor = __WEColor;" : "var \(name) = __noopProxy();"
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
    function createScriptProperties() {
        var props = {};
        var builder = {};
        function add(d) { if (d && d.name !== undefined) { props[d.name] = d.value; } return builder; }
        function firstOptionValue(options) {
            if (!options || !options.length) { return undefined; }
            var first = options[0];
            return first && typeof first === 'object' && first.value !== undefined ? first.value : first;
        }
        ['addCheckbox','addText','addSlider','addColor','addTextInput','addFile'].forEach(function(k){ builder[k] = add; });
        builder.addCombo = function(d) {
            if (d && d.name !== undefined) {
                props[d.name] = d.value !== undefined ? d.value
                    : (d.default !== undefined ? d.default
                    : (d.defaultValue !== undefined ? d.defaultValue : firstOptionValue(d.options)));
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
    // engine.setTimeout: 벽시계가 아닌 runtime 클록 기반 만기 큐(결정적 — 캡처 t 주입 시 동일 발화).
    // 펌프는 setRuntime(= __engineState.runtime 갱신) 이 수행.
    var __timeoutQueue = [];   // {id, at(초), cb}
    var __timeoutSeq = 0;
    function __pumpTimeouts() {
        var now = __engineState.runtime;
        var cutoff = __timeoutSeq;   // 콜백 내 재등록(0ms 체인)은 다음 틱으로 — 동일 틱 무한루프 방지
        for (;;) {
            var best = -1;
            for (var i = 0; i < __timeoutQueue.length; i += 1) {   // ponytail: 선형 스캔 — 씬당 타이머는 한 자릿수
                var e = __timeoutQueue[i];
                if (e.at > now || e.id > cutoff) { continue; }
                if (best < 0 || e.at < __timeoutQueue[best].at
                    || (e.at === __timeoutQueue[best].at && e.id < __timeoutQueue[best].id)) { best = i; }
            }
            if (best < 0) { return; }
            var entry = __timeoutQueue.splice(best, 1)[0];
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
    var __engineState = { runtime: 0.0, frametime: 0.016, frameTime: 0.016,
                          audio: __audioBuffer, audioBuffer: __audioBuffer,
                          canvasSize: __canvasSize,
                          setTimeout: function(cb, ms) {
                              if (typeof cb !== 'function') { return 0; }
                              var id = ++__timeoutSeq;
                              __timeoutQueue.push({ id: id, at: __engineState.runtime + __num(ms, 0) / 1000, cb: cb });
                              return id;
                          },
                          clearTimeout: function(id) {
                              for (var i = 0; i < __timeoutQueue.length; i += 1) {
                                  if (__timeoutQueue[i].id === id) { __timeoutQueue.splice(i, 1); return; }
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
            getEffect: function() { return __noopProxy(); }
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
            getEffect: function() { return __noopProxy(); }
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
                var l = __makeLayer();
                l.name = String(name || '');
                this.layers.push(l);
                return l;
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
        return l;
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
            thisScene.layers = layers;
            thisLayer = layers[0];
            thisObject = thisLayer;
        }
    }
    function __wapleLayerForScript(name) {
        if (typeof name !== 'string' || name.length === 0) { return thisLayer; }
        return thisScene.getLayer(name);
    }
    var shared = { camera: thisScene.getCameraTransforms(), miTextContainerScale: new Vec2(1, 1) };
    var input = __noopProxy();
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
