import Foundation
import JavaScriptCore

/// WE 텍스트 프로퍼티 스크립트 실행기(JavaScriptCore).
/// 계약(실물): `createScriptProperties()` 빌더(.addCheckbox/.addText/... → .finish() = name→기본값 객체)
/// + `export function update(value) → String`. engine/shared/thisScene 등 엔진 API 는 no-op Proxy 로 심 —
/// 미디어류 스크립트는 데이터가 없어 자연히 빈 문자열을 반환(graceful).
/// ES 모듈 export 구문은 평가 전에 제거(JSC 는 스크립트 평가에서 모듈 미지원).
public final class TextScriptEngine {
    private let context: JSContext
    private let updateFn: JSValue

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

    /// update(current) 호출 → 새 텍스트. 예외/비문자열 → nil.
    public func evaluate(current: String) -> String? {
        var failed = false
        context.exceptionHandler = { _, ex in
            NSLog("%@", "[Waple] text script update exception: \(ex?.toString() ?? "?")")
            failed = true
        }
        guard let out = updateFn.call(withArguments: [current]), !failed, out.isString else { return nil }
        return out.toString()
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
        return names.map { "var \($0) = __noopProxy();" }.joined(separator: " ")
    }

    /// createScriptProperties 빌더 + 엔진 API no-op Proxy 심.
    private static let shims = """
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
    var engine = __noopProxy();
    var shared = {};
    var thisScene = __noopProxy();
    var thisObject = __noopProxy();
    var thisLayer = __noopProxy();
    var input = __noopProxy();
    var console = { log: function(){}, error: function(){} };
    """
}
