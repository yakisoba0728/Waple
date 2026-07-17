import XCTest
import simd
@testable import WapleCore

/// 실물 퍼펫 **모델 데이터** 기반 캐스케이드 블렌드 검증(코퍼스 존재 시만 — WAPLE_REAL_PKGS/~/Downloads/…).
/// 2955378002 "rennee"(19본, 클립 2개 "Animation 1"/"Animation 2", clip0↔clip1 포즈차 Δ≈169):
/// scene.json animationlayers = [Animation 1(절대), Animation 2(가산)] — 실측 확정 config 로 블렌드.
///
/// 범위 주의(정직성): 이는 실물 **퍼펫 모델(.mdl)을 직접 로드**한 블렌드-수학 검증이다. rennee 는 씬에서
/// `visible={"user":{"condition":"3","name":"weather"},"value":false}` — 기본 숨김(날씨 조건부)이라 레이어로
/// 로드되지 않는다. 코퍼스 전수 스캔 결과 **가시 로드되는 다층 퍼펫 39씬은 전부 클립이 근사 동일**(장식용
/// 루프)이라, 기본 뷰에서 렌더 레벨로 다층/단층 차이를 보이는 씬은 없다(SP 리포트). 즉 블렌드 인프라는
/// 정확하나(유닛+본 모델 데이터로 검증), 기본 코퍼스 뷰에서 가시 효과는 조건부(사용자 토글 시 발현).
/// (단층 무회귀는 프레임인코더 gate + 유닛 testSingleAbsoluteLayerMatchesSingleClip 로 보장.)
final class PuppetBlendRealSceneTests: XCTestCase {
    private func corpusBase() -> String {
        ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
    }
    private func poseDelta(_ x: [simd_float4x4], _ y: [simd_float4x4]) -> Float {
        var m: Float = 0
        for (a, b) in zip(x, y) { for c in 0..<4 { m = max(m, abs(a[c] - b[c]).max()) } }
        return m
    }
    private func maxDeltaOverTime(_ model: PuppetModel,
                                  _ layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)]) -> Float {
        var md: Float = 0
        for t in stride(from: Float(0.1), through: 1.5, by: 0.2) {
            md = max(md, poseDelta(PuppetPose.blendedSkinMatrices(model: model, layers: layers, time: t),
                                   PuppetPose.skinMatrices(model: model, animation: 0, time: t)))
        }
        return md
    }

    func testRenneeMultiLayerBlendDiffersFromSingleClip() throws {
        let pkgPath = corpusBase() + "/2955378002/scene.pkg"
        guard FileManager.default.fileExists(atPath: pkgPath) else { throw XCTSkip("corpus 없음 — skip(CI 안전)") }
        let pkg = try ScenePackage.parse(try Data(contentsOf: URL(fileURLWithPath: pkgPath)))
        guard let mdl = pkg.data(for: "models/rennee_puppet.mdl"), let model = PuppetModel.parse(mdl),
              model.bones.count > 0, model.animations.count >= 2 else { throw XCTSkip("rennee 퍼펫 로드 실패 — skip") }

        let i1 = PuppetPose.clipIndex(model: model, name: "Animation 1", fallback: 0)
        let i2 = PuppetPose.clipIndex(model: model, name: "Animation 2", fallback: 1)
        XCTAssertNotEqual(i1, i2, "두 레이어가 상이 클립 참조(비퇴화)")

        // (a) 실측 config: Animation 1(절대) + Animation 2(가산) → 가산 레이어가 clip0 포즈를 변형.
        let real = maxDeltaOverTime(model, [(i1, false, 1, 1), (i2, true, 1, 1)])
        NSLog("[test] rennee real(abs+additive) blend Δ vs clip0 = \(real)")
        XCTAssertGreaterThan(real, 1e-2, "가산 레이어(Animation 2)가 단일 clip0 포즈를 실제로 변형")

        // (b) 절대 캐스케이드 오버라이드: [A1 절대, A2 절대 w1] → clip1(Animation 2) = clip0 과 상이.
        let cascadeOverride = maxDeltaOverTime(model, [(i1, false, 1, 1), (i2, false, 1, 1)])
        XCTAssertGreaterThan(cascadeOverride, 1e-2, "절대 캐스케이드 w=1 → 둘째 클립 오버라이드(≠ clip0)")

        // (c) 단층 무회귀: 단일 절대 레이어 weight=1 = skinMatrices(그 클립)(포즈 동일).
        let single = PuppetPose.skinnedPositions(model: model,
            matrices: PuppetPose.skinMatrices(model: model, animation: i1, time: 0.7))
        let blend1 = PuppetPose.skinnedPositions(model: model,
            matrices: PuppetPose.blendedSkinMatrices(model: model, layers: [(i1, false, 1, 1)], time: 0.7))
        var maxV: Float = 0
        for (a, b) in zip(single, blend1) { maxV = max(maxV, abs(a - b).max()) }
        XCTAssertLessThan(maxV, 1e-3, "단일 절대 레이어 = 단일 클립 스키닝(무회귀)")
    }

    /// 실코퍼스 animationlayers 스크립트 캡처 회귀(rate 3씬 ∪ visible 15씬 대표):
    /// - 2955378002 obj 10311 / 3448290956 obj 179: rate 오디오 스크립트 — base 파서는 폐기(red).
    /// - 3641860575 obj 219: visible 스크립트 — 종전 캡처 무회귀 앵커.
    /// 캐스케이드 소비자(encodeLayer) 가 per-frame 로 읽는 값의 원천이 이 캡처다.
    func testRealSceneAnimationLayerScriptCapture() throws {
        func parse(_ sid: String) throws -> SceneDocument {
            let pkgPath = corpusBase() + "/\(sid)/scene.pkg"
            guard FileManager.default.fileExists(atPath: pkgPath) else { throw XCTSkip("corpus 없음 — skip(CI 안전)") }
            return try SceneDocument.parse(
                package: try ScenePackage.parse(try Data(contentsOf: URL(fileURLWithPath: pkgPath))))
        }
        func layer(_ doc: SceneDocument, _ id: Int) throws -> SceneLayer {
            try XCTUnwrap(doc.layers.first { $0.id == id }, "layer \(id) 부재")
        }

        let rennee = try layer(try parse("2955378002"), 10311)   // 'circle 0-1 x1.1'
        XCTAssertEqual(rennee.animationLayers.count, 2)
        XCTAssertNotNil(rennee.animationLayers[1].scripts["rate"],
                        "2955378002 rate 오디오 스크립트가 캡처돼야(base: 폐기)")
        XCTAssertEqual(rennee.animationLayers[1].rate, 1.1, accuracy: 1e-4, "정적 rate 초기값 무회귀")

        let eye = try layer(try parse("3448290956"), 179)        // '头位置'
        XCTAssertEqual(eye.animationLayers.count, 2)
        for i in [0, 1] {
            XCTAssertNotNil(eye.animationLayers[i].scripts["rate"], "3448290956 [\(i)] rate 스크립트 캡처")
            XCTAssertNil(eye.animationLayers[i].scripts["blend"],
                         "blend 는 user 바인딩(스크립트 아님) — 오캡처 금지")
            XCTAssertEqual(eye.animationLayers[i].blend, 0.3, accuracy: 1e-4, "blend {user,value} 정적 언랩 무회귀")
        }

        let bird = try layer(try parse("3641860575"), 219)       // 'b1'
        XCTAssertNotNil(bird.animationLayers.first?.scripts["visible"],
                        "3641860575 visible 스크립트 캡처(종전 동작 무회귀 앵커)")
    }
}
