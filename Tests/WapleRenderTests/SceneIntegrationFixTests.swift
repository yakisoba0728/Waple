import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// fix-i2 통합 수정(F740–F745) 회귀 테스트 — 1차 스웜이 파스·보존한 필드/API 의 렌더 소비 배선.
/// Metal 디바이스가 필요한 항목(② 텍스트 이펙트 GPU 체인)은 시그니처/무회귀 게이트만 검증하고
/// 실픽셀 검증은 기존 골든 파이프라인(캡처 A/B)에 위임한다(사유 기록).
final class SceneIntegrationFixTests: XCTestCase {

    // MARK: - F740(S-22): 파티클 시트 프레임 폴터의 animationmode/sequencemultiplier 소비

    /// sequence = 수명에 걸쳐 시트를 순차 재생(×sequencemultiplier 회 반복).
    func testF740SequenceFrameIndex_progressesOverLifetimeWithMultiplier() {
        // age/lifetime=0.25, fc=4, mul=2 → 진행 0.25×4×2=2.0 → 프레임 2(수명 내 2회 반복).
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.25, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 2), 2)
        // mul=1: 0.75×4×1=3.0 → 프레임 3(종전 frametime 폴터라면 Int(0.75/0.1)%4=3 으로 우연 일치 — 아래로 구분).
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.75, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 1), 3)
        // 구분 케이스: age=0.5, ft=0.1 → frametime 폴터는 Int(5)%4=1 이지만 sequence(mul=1)는 0.5×4=2.
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.5, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 1), 2,
            "S-22: sequence 는 frametime 이 아니라 수명 비율 기반이어야 한다")
    }

    /// nil/randomframe 은 종전 frametime gif 폴터 그대로(무회귀). randomframe 의 스폰 확정은 시뮬 소유(F622).
    func testF740NilMode_keepsFrametimeFallback() {
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.35, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: nil, seqMul: 5), 3)
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.35, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .randomframe, seqMul: 5), 3)
    }

    /// 방어: seqMul=0 → 정지 프레임 0, 비유한 입력/단일 프레임 → 트랩 없이 0.
    func testF740SequenceFrameIndex_guards() {
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.9, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 0), 0)
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 5, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 1, mode: .sequence, seqMul: 3), 0)
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: .infinity, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: .nan), 0)
        // 수명 퇴화(≈0) → frametime 폴터(무크래시).
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.35, lifetime: 0, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 1), 3)
    }

    /// F530-sweep: **유한하지만 Int 범위를 넘는** 입력.
    ///
    /// 위 guards 테스트는 비유한(`.infinity`/`.nan`)만 덮었다. 종전 구현은 `guard v.isFinite`
    /// 뒤에 맨 `Int(v)` 를 썼는데, Swift 의 `Int(Float)` 는 범위를 넘으면 클램프가 아니라
    /// **트랩**이다 — `"sequencemultiplier": 1e19` 한 줄로 워크샵 배경화면이 앱을 죽였다.
    /// 이 함수는 쿼드(`:123`)·로프(`:262`) 두 경로에서 **매 프레임** 불린다.
    ///
    /// 3D 형제(`SceneRenderer3D.swift` 파티클 frametime 폴터)도 같은 가드를 받았으나
    /// 렌더 루프 내부라 여기서 직접 부를 수 없다 — 회귀는 이 테스트가 대표한다.
    func testF530ParticleSheetFrameIndex_survivesFiniteButOutOfRangeInput() {
        // sequence 경로: age/lifetime × fc × seqMul 이 Float(Int.max) 를 넘는다.
        for mul in [Float(1e19), 1e30, .greatestFiniteMagnitude] {
            XCTAssertEqual(
                SceneRenderer.particleSheetFrameIndex(age: 0.5, lifetime: 1, frameTime: 0.1,
                                                      frameCount: 2, mode: .sequence, seqMul: mul), 0,
                "seqMul \(mul): 트랩 대신 프레임 0 폴백이어야 한다")
        }
        // frametime 폴터 경로: age 자체가 거대하거나 비유한. mode 가 nil 이면 종전엔
        // isFinite 가드조차 없었다 — `.infinity` 는 sequence 경로에서만 막혔다.
        for age in [Float(1e30), .greatestFiniteMagnitude, .infinity, .nan] {
            XCTAssertEqual(
                SceneRenderer.particleSheetFrameIndex(age: age, lifetime: 1, frameTime: 0.1,
                                                      frameCount: 4, mode: nil, seqMul: 1), 0,
                "age \(age): frametime 폴터도 트랩 대신 0 이어야 한다")
        }
        // 음수 age(시뮬 이상치)도 인덱스 음수를 만들지언정 죽지 않는다.
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: -1e30, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: nil, seqMul: 1), 0)

        // 대조군: 가드를 넣으면서 **절사 규약이 반올림으로 바뀌지 않았는지**.
        // 같은 파일의 safeFloatToInt 는 `.rounded()` 라 여기 쓰면 프레임이 한 칸 밀린다.
        // 0.7×4×1 = 2.8 → 절사 2 (반올림이면 3).
        XCTAssertEqual(
            SceneRenderer.particleSheetFrameIndex(age: 0.7, lifetime: 1, frameTime: 0.1,
                                                  frameCount: 4, mode: .sequence, seqMul: 1), 2,
            "절사 규약이 반올림으로 바뀌었다 — 모든 스프라이트 애니가 한 프레임씩 밀린다")
    }

    // MARK: - F742(S-19): dependencies depLater — 의존 타깃을 의존자 직전으로 이동

    private func layer(id: Int, order: Int, dependencies: [Int] = []) -> SceneLayer {
        var l = SceneLayer(textureEntryName: "t.tex", origin: Vec2(x: 0, y: 0),
                           size: Vec2(x: 1, y: 1), scale: Vec2(x: 1, y: 1), angleZ: 0,
                           alpha: 1, color: Vec3(x: 1, y: 1, z: 1), brightness: 1,
                           parallaxDepth: Vec2(x: 1, y: 1), effects: [])
        l.id = id; l.order = order; l.dependencies = dependencies
        return l
    }

    /// depLater(실물 3113287126 idx2→idx4 형): 후순위 타깃이 의존자 직전으로 이동.
    func testF742DepLater_targetMovesBeforeDependent() {
        let a = layer(id: 10, order: 0, dependencies: [30])   // idx0 → idx2 의존
        let b = layer(id: 20, order: 1)
        let c = layer(id: 30, order: 2)
        let plan: [SceneRenderer.DrawItem] = [
            .init(kind: .layer, idx: 0), .init(kind: .layer, idx: 1), .init(kind: .layer, idx: 2),
        ]
        let out = SceneRenderer.applyingDependencies(plan, layers: [a, b, c])
        XCTAssertEqual(out.map { $0.idx }, [2, 0, 1],
                       "S-19: 타깃(idx2)이 의존자(idx0)보다 뒤면 직전으로 이동해야 한다")
    }

    /// 이미 선행인 엣지(코퍼스 39건 중 37)는 그대로(무회귀) + 텍스트/파티클 아이템 불변.
    func testF742AlreadyOrdered_planUnchanged() {
        let a = layer(id: 10, order: 2, dependencies: [30])   // idx2 → idx0 의존(이미 선행)
        let c = layer(id: 30, order: 0)
        let plan: [SceneRenderer.DrawItem] = [
            .init(kind: .layer, idx: 0), .init(kind: .text, idx: 0),
            .init(kind: .particle, idx: 0), .init(kind: .layer, idx: 1),
        ]
        let out = SceneRenderer.applyingDependencies(plan, layers: [c, a])
        XCTAssertEqual(out.map { "\($0.kind)" }, plan.map { "\($0.kind)" })
        XCTAssertEqual(out.map { $0.idx }, plan.map { $0.idx })
    }

    /// 미등록 id/자기참조/id=0 은 무시(무회귀·무크래시).
    func testF742UnknownOrSelfDependency_ignored() {
        let a = layer(id: 10, order: 0, dependencies: [999, 10])
        let b = layer(id: 0, order: 1, dependencies: [10])    // id=0 은 해석 대상 아님(타깃이 될 수 없음)
        let plan: [SceneRenderer.DrawItem] = [.init(kind: .layer, idx: 0), .init(kind: .layer, idx: 1)]
        let out = SceneRenderer.applyingDependencies(plan, layers: [a, b])
        XCTAssertEqual(out.map { $0.idx }, [0, 1])
    }

    // MARK: - F743(S-36/S-33): sceneScriptLayers 디스크립터 id/parentId/animationLayerCount

    func testF743SceneScriptLayers_carriesIdParentAndAnimLayerCount() {
        var l = layer(id: 42, order: 0)
        l.parent = 7
        l.animationLayers = [AnimationLayer(name: "a", additive: false, blend: 1, rate: 1, visible: true),
                             AnimationLayer(name: "b", additive: true, blend: 0.5, rate: 1, visible: true)]
        let doc = SceneDocument(projectionWidth: 1920, projectionHeight: 1080,
                                clearColor: Vec3(x: 0, y: 0, z: 0),
                                parallaxEnabled: false, parallaxAmount: 0,
                                parallaxMouseInfluence: 0, parallaxDelay: 0,
                                layers: [l], particles: [])
        let desc = SceneRenderer.sceneScriptLayers(from: doc)
        XCTAssertEqual(desc.first?.id, 42, "S-36: getParent() 체인 배선은 objects id 가 필요")
        XCTAssertEqual(desc.first?.parentId, 7)
        XCTAssertEqual(desc.first?.animationLayerCount, 2, "S-33: getAnimationLayerCount() 실값")
    }

    // MARK: - F743(S-34): currentLayerIndex 로 thisLayer 직결(중복명 오바인딩 해소)

    /// 두 레이어가 같은 이름 — 인덱스 바인딩은 두 번째를 정확히 가리켜야 한다(이름 조회는 첫 매치 폴터).
    func testF743CurrentLayerIndex_bindsExactObjectNotFirstNameMatch() throws {
        let d0 = SceneScriptLayerDescriptor(name: "dup", alpha: 1)
        let d1 = SceneScriptLayerDescriptor(name: "dup", alpha: 1)
        let ctx = try XCTUnwrap(SceneScriptContext(layers: [d0, d1], soundNames: [],
                                                   width: 1920, height: 1080))
        let engine = TextScriptEngine(script: "thisLayer.alpha = 0.25;",
                                      scene: ctx, currentLayerName: "dup", currentLayerIndex: 1)
        XCTAssertNotNil(engine)
        XCTAssertEqual(ctx.context.evaluateScript("thisScene.layers[1].alpha")?.toDouble(), 0.25)
        XCTAssertEqual(ctx.context.evaluateScript("thisScene.layers[0].alpha")?.toDouble(), 1.0,
                       "S-34: 이름 첫 매치가 아니라 디스크립터 인덱스의 오브젝트를 건드려야 한다")
    }

    // MARK: - F743(S-35): updateSceneLayers — getLayer 참조의 라이브(제자리) 갱신

    func testF743UpdateSceneLayers_liveInPlaceUpdate() throws {
        let d0 = SceneScriptLayerDescriptor(name: "clock", origin: SIMD3<Float>(1, 2, 0))
        let ctx = try XCTUnwrap(SceneScriptContext(layers: [d0], soundNames: [],
                                                   width: 1920, height: 1080))
        // 스크립트가 쥔 참조(getLayer 반환 객체)가 살아 있도록 제자리 갱신돼야 한다(F710 JS 계약).
        _ = ctx.context.evaluateScript("var __held = thisScene.getLayer('clock');")
        var moved = d0
        moved.origin = SIMD3<Float>(999, 2, 0); moved.visible = false
        ctx.updateSceneLayers([moved])
        XCTAssertEqual(ctx.context.evaluateScript("__held.origin.x")?.toDouble(), 999)
        XCTAssertEqual(ctx.context.evaluateScript("__held.visible")?.toBool(), false,
                       "S-35: 프레임 간 움직인 레이어를 t=0 스냅샷이 아니라 현재값으로 읽어야 한다")
    }

    // MARK: - F743(S-31): setCursorState — input 폴ling 실데이터

    func testF743SetCursorState_feedsInputPolling() throws {
        let ctx = try XCTUnwrap(SceneScriptContext(layers: [], soundNames: [],
                                                   width: 1920, height: 1080))
        XCTAssertEqual(ctx.context.evaluateScript("input.cursorLeftDown")?.toBool(), false,
                       "미주입 초기값은 거짓(헤드리스 무클릭 계약)")
        ctx.setCursorState(worldX: 100, worldY: 50, screenX: 200, screenY: 100, leftDown: true)
        XCTAssertEqual(ctx.context.evaluateScript("input.cursorWorldPosition.x")?.toDouble(), 100)
        XCTAssertEqual(ctx.context.evaluateScript("input.cursorWorldPosition.y")?.toDouble(), 50)
        XCTAssertEqual(ctx.context.evaluateScript("input.cursorScreenPosition.x")?.toDouble(), 200)
        XCTAssertEqual(ctx.context.evaluateScript("input.cursorLeftDown")?.toBool(), true)
    }

    // MARK: - F744(S-18)/F741(S-13): 무회귀 게이트 문서화

    /// sceneZoom 기본 1 → aspectScale 곱 스킵(침침 줌과 동형 가드). 텍스트 effects 기본 공배열 → 원본 경로.
    func testF744F741Defaults_areNoOp() {
        let r = SceneRenderer()
        XCTAssertEqual(r.sceneZoom, 1, "F695 부재 씬은 전역 줌 1 = 무회귀")
        XCTAssertTrue(r.liveLayerStates.isEmpty, "F743: 인코딩 전 라이브 채널은 비어 있어야 한다")
    }
}
