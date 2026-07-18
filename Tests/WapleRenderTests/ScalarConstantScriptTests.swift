import XCTest
import CryptoKit
@testable import WapleCore
@testable import WapleRender

/// 스칼라 효과 상수 스크립트 미캡처 결함(parseEffects 의 float 언랩 short-circuit)의 재현·가드.
/// - 재현체: 실물 3219908811 "audioamount"(WE AudioAmount 템플릿, 스칼라 {value:0.1, script}) — 오디오
///   반응 유니폼. base 파스는 스크립트를 삼켜 유니폼이 0.1 로 동결, WE 는 매 프레임 오디오로 구동.
/// - 가드: 스칼라-스크립트 없는 효과 씬은 리오더 전후 파스 산출 불변.
final class ScalarConstantScriptTests: XCTestCase {
    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    /// 실물 3219908811 audioamount 스크립트 원문(WE 공식 AudioAmount 템플릿, workshop 2413251683).
    /// average[0](저역) 을 smoothingRate 로 평활 → 스칼라 반환. 무음이면 0 으로, 큰음이면 저역 크기로 수렴.
    private let audioScript = #"""
    'use strict';
    let frequencyResolution = 16;
    let sourceFrequency = 0;
    let smoothingRate = 30.0;
    let audioBuffer = engine.registerAudioBuffers(frequencyResolution);
    var smoothValue = 5.0;
    var initialvalue;
    export function update(value) {
        let audioDelta = audioBuffer.average[sourceFrequency] - smoothValue;
        smoothValue += audioDelta * engine.frametime * smoothingRate;
        smoothValue = Math.min(5.0, smoothValue);
        value = (smoothValue * 1.0);
        return value;
    }
    export function init(value) { initialvalue = value; }
    """#

    /// parseEffects 산출 전체(2D 레이어 + 3D 오브젝트 — 둘 다 같은 parseEffects 경유).
    private func allEffects(_ doc: SceneDocument) -> [SceneEffect] {
        doc.layers.flatMap(\.effects) + doc.objects3D.flatMap(\.effects)
    }

    private func allConstantScripts(_ doc: SceneDocument) -> [String: String] {
        var out: [String: String] = [:]
        for eff in allEffects(doc) { for pass in eff.passList {
            for (k, v) in pass.constantScripts { out[k] = v }
        } }
        return out
    }

    /// 파스→캡처→구동 일괄: 스칼라 오디오 스크립트가 (1) 파스에서 캡처되고 (2) 오디오로 스칼라 유니폼을
    /// 실제 분기시키는지. base 에선 (1) 자체가 실패(스크립트 미캡처 → 유니폼 0.1 동결).
    func testAudioReactiveScalarConstantCapturedAndDrivesUniform() throws {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 100, "height": 100], "clearcolor": "0 0 0"],
            "objects": [[
                "image": "models/x.json", "origin": "50 50 0", "size": "10 10",
                "effects": [["file": "effects/e.json", "passes": [[
                    "constantshadervalues": ["audioamount": ["script": audioScript, "value": 0.1]]
                ]]]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scene)
        let package = ScenePackage.assemble([
            ("scene.json", sceneData), ("models/x.json", Data(model.utf8)), ("materials/m.json", Data(material.utf8)),
        ])
        let doc = try SceneDocument.parse(package: package)
        // (1) 스칼라 스크립트 파스 캡처 — base 미캡처면 여기서 실패(재현체 base 판정).
        let src = try XCTUnwrap(allConstantScripts(doc)["audioamount"],
                                "스칼라 오디오 스크립트가 파스에서 캡처돼야(base 결함: float 언랩 삼킴)")

        // (2) 캡처된 스크립트를 소비처와 동일하게 구동: setAudio(무음/큰음) 후 프레임 반복 → evaluateVec 스칼라.
        func settle(loud: Bool) throws -> Float {
            let ctx = try XCTUnwrap(SceneScriptContext(width: 100, height: 100))
            let engine = try XCTUnwrap(TextScriptEngine(script: src, scene: ctx))
            let level: Float = loud ? 1.0 : 0.0
            ctx.setAudio(left64: Array(repeating: level, count: 64), right64: Array(repeating: level, count: 64))
            var v: Float = 0.1
            for _ in 0..<40 { v = try XCTUnwrap(engine.evaluateVec(current: [v])?.first) }  // 프레임당 smoothValue 평활
            return v
        }
        let quiet = try settle(loud: false)
        let loud = try settle(loud: true)
        NSLog("%@", "[ScalarRepro] audioamount uniform: base(고정)=0.1, fix quiet=\(quiet) loud=\(loud)")
        // 오디오 반응 = 실효과: 큰음이 무음보다 크고, 정적 0.1 이 아닌 스크립트 구동값.
        XCTAssertLessThan(quiet, 0.2, "무음 → 0 수렴")
        XCTAssertGreaterThan(loud, 0.7, "큰음 → 저역 크기(≈1)로 수렴, 0.1 정적 아님")
        XCTAssertGreaterThan(loud, quiet + 0.5, "오디오 반응 스칼라 유니폼 분기(base 는 0.1 동결로 불가)")
    }

    // MARK: 실코퍼스(env WAPLE_REAL_PKGS ?? ~/Downloads/wallpaper_dev/backgrounds, 부재 시 skip — CI 안전)

    private func corpusRoot() throws -> URL {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir: \(base)") }
        return URL(fileURLWithPath: base)
    }

    private func parseScene(_ sid: String) throws -> SceneDocument {
        let pkgURL = try corpusRoot().appendingPathComponent("\(sid)/scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path) else { throw XCTSkip("no scene.pkg: \(sid)") }
        let package = try ScenePackage.parse(Data(contentsOf: pkgURL))
        return try SceneDocument.parse(package: package)
    }

    /// 재현체 실 pkg: 3219908811 은 스칼라-스크립트(audioamount×10, 벡터-스크립트 0) — base 파스는 전량 삼켜
    /// constantScripts 가 빔, fix 는 캡처. 스칼라 상수 스크립트 미캡처 결함의 실증.
    func testRealCorpusScalarScriptCaptured() throws {
        let doc = try parseScene("3219908811")
        let scripts = allConstantScripts(doc)
        XCTAssertNotNil(scripts["audioamount"],
                        "실 pkg 3219908811 의 스칼라 audioamount 스크립트가 캡처돼야(base: constantScripts 공집합)")
    }

    /// 가드: 스칼라-스크립트 없는 효과 씬 3종(벡터-스크립트 3146703458 / 정적만 3299228616·3538758087,
    /// scene.json 정밀 스캔 기준) 의 파스 산출(constants·constantScripts·constantScriptProps) 이 수정 전후 불변.
    /// expected 는 base HEAD(74defee) 캡처 SHA-256 — fix 실행이 동일하면 무회귀 증명.
    /// 2026-07-16 리베이스: P0 배치 9bad33d 중 0662e0b(parseNode shape:quad 이펙트 승격)가 두 씬의
    /// shape:quad 오브젝트("Light shafts" 6개/1개)에 달린 lightshafts 효과를 신규 파스 — a4c678b↔9bad33d
    /// 덤프 diff 로 순수 삽입(기존 라인 무변형·instanceoverride 무영향·이후 P1 무영향) 검증 후 갱신.
    func testEffectSceneParseUnchangedGuard() throws {
        let expected: [String: String] = [
            "3146703458": "e1ad41a0a7f45f1dc0271b62614e52764296481c11ccec9fe5a82d6fc23ab839",  // 벡터-스크립트 6패스
            "3299228616": "61e18d9f418d0b7763ad91ad315d5052c00d2b91baaa24f2009c5a3bd9359f30",  // 정적 97→103패스(0662e0b lightshafts ×6 승격)
            "3538758087": "3ed3ab44d0713dd9a602067803581dda9873721b1dc18d31f63e75dfb77b8d0e",  // 정적 102→106패스(F201: effects[].visible={value:false,script} 4건(blend×2/blendgradient×2, 호버 토글) 보존 편입)
        ]
        for (sid, want) in expected.sorted(by: { $0.key < $1.key }) {
            let doc = try parseScene(sid)
            var lines: [String] = []
            for (ei, eff) in allEffects(doc).enumerated() {
                for (pi, pass) in eff.passList.enumerated() {
                    let c = pass.constants.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                    let s = pass.constantScripts.keys.sorted().joined(separator: ",")
                    let sp = pass.constantScriptProps.keys.sorted().joined(separator: ",")
                    lines.append("E\(ei)(\(eff.name))P\(pi)|const:\(c)|scr:\(s)|sp:\(sp)")
                }
            }
            XCTAssertFalse(lines.isEmpty, "가드 \(sid): 효과 상수 파스 산출이 비면 가드가 공허 — 씬 선정 오류")
            let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            NSLog("%@", "[ScalarGuard] \(sid) sha256=\(digest) lines=\(lines.count)")
            if !want.hasPrefix("@@") {
                XCTAssertEqual(digest, want, "가드 \(sid): 스칼라-스크립트 없는 효과 씬 base≠fix (무회귀 위반)")
            }
        }
    }
}
