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

    /// ES 모듈 구문 중화: `export` 키워드 제거, `import ...` 는 바인딩을 no-op 프록시 var 로 치환
    /// (외부 유틸 모듈은 제공 불가 — 호출 시 프록시가 흡수, update 실패 시 nil → 빈 텍스트 graceful).
    static func stripModuleSyntax(_ src: String) -> String {
        var out: [String] = []
        for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = String(line)
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("import ") {
                out.append(importReplacement(t))
                continue
            }
            if let r = s.range(of: "export default") { s.replaceSubrange(r, with: "var __default =") }
            else if let r = s.range(of: "export ") {
                let before = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if before.isEmpty { s.replaceSubrange(r, with: "") }
            }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    /// `import * as X from ...` / `import X from ...` / `import {a, b} from ...` → no-op 프록시 바인딩.
    private static func importReplacement(_ line: String) -> String {
        guard let fromIdx = line.range(of: " from ") ?? line.range(of: " from\t") else { return "" }
        let clause = line[line.index(line.startIndex, offsetBy: "import ".count)..<fromIdx.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        var names: [String] = []
        if clause.hasPrefix("*") {
            if let asIdx = clause.range(of: " as ") {
                names.append(clause[asIdx.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        } else if clause.hasPrefix("{") {
            let inner = clause.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            for piece in inner.split(separator: ",") {
                let p = piece.trimmingCharacters(in: .whitespaces)
                // "orig as alias" → alias
                if let asIdx = p.range(of: " as ") { names.append(String(p[asIdx.upperBound...]).trimmingCharacters(in: .whitespaces)) }
                else if !p.isEmpty { names.append(p) }
            }
        } else if !clause.isEmpty {
            names.append(clause)
        }
        guard !names.isEmpty else { return "" }
        return names.map { name in
            // 실제 구현이 있는 모듈(WEColor)은 진짜 심으로 바인딩 — 컬러 사이클 스크립트가 동작한다.
            name == "WEColor" ? "var WEColor = __WEColor;" : "var \(name) = __noopProxy();"
        }.joined(separator: " ")
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
