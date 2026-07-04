import Foundation
import JavaScriptCore

/// 씬 단위 공유 JSContext(SceneRenderer mount 당 1개): shims 를 1회 평가하고, 씬의 모든 프로퍼티
/// 스크립트(레이어 color/alpha/visible, 효과 상수, 텍스트)가 이 컨텍스트를 공유한다 — `shared` 전역으로
/// 스크립트 간 통신(실물 3394601417: visible 스크립트의 컨트롤러가 shared.a 를 세팅, 43개 스크립트가 분기).
/// 각 스크립트는 IIFE 로 감싸므로 update/스크립트-로컬 상태는 클로저에 격리된다.
public final class SceneScriptContext {
    let context: JSContext

    public init?() {
        guard let ctx = JSContext() else { return nil }
        context = ctx
        ctx.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] scene script context exception: \(ex?.toString() ?? "?")")
        }
        ctx.evaluateScript(TextScriptEngine.shims)
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

    public init?(script: String) {
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
    }

    /// 씬 공유 컨텍스트 모드: 스크립트를 IIFE 로 감싸 평가(전역 오염/update 이름충돌 방지)하고
    /// update 를 반환받아 보관. update 부재도 성공(nil update — top-level 사이드이펙트는 이미 실행됨).
    /// 로드 예외(문법 오류 등) → nil, 공유 컨텍스트는 오염되지 않는다(IIFE 미실행).
    public init?(script: String, scene: SceneScriptContext) {
        context = scene.context
        var hadException = false
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] scene script load exception: \(ex?.toString() ?? "?")")
            hadException = true
        }
        let cleaned = Self.stripModuleSyntax(script)
        let wrapped = "(function(){\n\(cleaned)\n;return (typeof update !== 'undefined') ? update : null;\n})()"
        let out = context.evaluateScript(wrapped)
        guard !hadException else { return nil }
        updateFn = (out?.isObject == true) ? out : nil
    }

    /// update 함수 보유 여부(false = 사이드이펙트 전용 스크립트 — evaluate 계열은 항상 nil).
    public var hasUpdate: Bool { updateFn != nil }

    /// update(current) 호출 → 새 텍스트. 예외/비문자열 → nil.
    public func evaluate(current: String) -> String? {
        guard let updateFn else { return nil }
        var failed = false
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] text script update exception: \(ex?.toString() ?? "?")")
            failed = true
        }
        guard let out = updateFn.call(withArguments: [current]), !failed, out.isString else { return nil }
        return out.toString()
    }

    /// visible 스크립트용: update(current) → 부울(숫자는 0=false). 예외/부재/비해석 → nil(현상 유지).
    public func evaluateBool(current: Bool) -> Bool? {
        guard let updateFn else { return nil }
        var failed = false
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] visible script exception: \(ex?.toString() ?? "?")")
            failed = true
        }
        guard let out = updateFn.call(withArguments: [current]), !failed else { return nil }
        if out.isBoolean { return out.toBool() }
        if out.isNumber { return out.toDouble() != 0 }
        return nil
    }

    /// 효과 상수 스크립트용: engine.runtime 갱신(초).
    public func setRuntime(_ t: Double) {
        context.evaluateScript("__engineState.runtime = \(t);")
    }

    /// update({x,y,z...}) 호출 → 수치 배열(스칼라는 1개). 예외/비수치 → nil.
    public func evaluateVec(current: [Float]) -> [Float]? {
        guard let updateFn else { return nil }
        var failed = false
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] constant script exception: \(ex?.toString() ?? "?")")
            failed = true
        }
        let arg: Any = current.count >= 3
            ? ["x": current[0], "y": current[1], "z": current[2]]
            : (current.first.map { Double($0) } ?? 0)
        guard let out = updateFn.call(withArguments: [arg]), !failed else { return nil }
        if out.isNumber { return [Float(out.toDouble())] }
        guard out.isObject else { return nil }
        let x = out.objectForKeyedSubscript("x"), y = out.objectForKeyedSubscript("y"), z = out.objectForKeyedSubscript("z")
        guard let x, let y, let z, x.isNumber, y.isNumber, z.isNumber else { return nil }
        return [Float(x.toDouble()), Float(y.toDouble()), Float(z.toDouble())]
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
        func isIdent(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }
        func emit(_ c: Character) { out.append(c); if !c.isWhitespace { prevSig = c } }
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
            // 식별자 시작(문자/_/$): 전체 word 소비 — 항상 완전 토큰 경계에서만 진입.
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                let word = Array(chars[i..<j])
                let isKeyword = (word == Array("export") || word == Array("import")) && prevSig != "."
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
                emitAll(word); i = j; continue
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

    /// `import` 키워드 직후 인덱스 j 에서 시작하는 import 문을 소비하고 no-op 바인딩 코드를 emit,
    /// 문 끝(모듈 문자열 + 선택 `;`) 다음 인덱스를 반환. 모듈 문자열 전에 `;` 를 만나면 미변형(리터럴 emit).
    private static func neutralizeImport(_ chars: [Character], _ j: Int, _ n: Int,
                                         emit: ([Character]) -> Void) -> Int {
        // 모듈 지정자(첫 문자열 리터럴)까지 스캔 — 그 사이가 clause(+ 후행 from).
        var m = j
        while m < n, chars[m] != "'", chars[m] != "\"", chars[m] != "`" {
            if chars[m] == ";" || chars[m] == "\n" { emit(Array("import")); return j }  // 문자열 없는 import → 원문
            m += 1
        }
        guard m < n else { emit(Array("import")); return j }
        var clause = String(chars[j..<m]).trimmingCharacters(in: .whitespaces)
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
            guard let asIdx = clause.range(of: " as ") else { return "" }
            let name = String(clause[asIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
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

    /// createScriptProperties 빌더 + 엔진 API no-op Proxy 심(SceneScriptContext 와 공유).
    static let shims = """
    'use strict';
    function createScriptProperties() {
        var props = {};
        var builder = {};
        function add(d) { if (d && d.name !== undefined) { props[d.name] = d.value; } return builder; }
        ['addCheckbox','addText','addSlider','addCombo','addColor','addTextInput','addFile'].forEach(function(k){ builder[k] = add; });
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
    // engine: runtime 등 실수치 프로퍼티는 실제 타깃에 두고, 나머지는 no-op 흡수.
    var __engineState = { runtime: 0.0, frameTime: 0.016 };
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
    Vec3.prototype.copy = function () { return new Vec3(this.x, this.y, this.z); };
    Vec3.prototype.length = function () { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); };
    function Vec2(x, y) {
        if (typeof x === 'object' && x) { this.x = x.x || 0; this.y = x.y || 0; }
        else { this.x = x || 0; this.y = y || 0; }
    }
    Vec2.prototype.add = function (o) { return (typeof o === 'number') ? new Vec2(this.x + o, this.y + o) : new Vec2(this.x + o.x, this.y + o.y); };
    Vec2.prototype.subtract = function (o) { return (typeof o === 'number') ? new Vec2(this.x - o, this.y - o) : new Vec2(this.x - o.x, this.y - o.y); };
    Vec2.prototype.multiply = function (o) { return (typeof o === 'number') ? new Vec2(this.x * o, this.y * o) : new Vec2(this.x * o.x, this.y * o.y); };
    Vec2.prototype.copy = function () { return new Vec2(this.x, this.y); };
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
            return { x: r, y: g, z: b };
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
            return { x: h, y: mx === 0 ? 0 : d / mx, z: mx };
        }
    };
    var shared = {};
    var thisScene = __noopProxy();
    var thisObject = __noopProxy();
    var thisLayer = __noopProxy();
    var input = __noopProxy();
    var console = { log: function(){}, error: function(){} };
    """
}
