import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// W1-yaxis: 파티클 sim 로컬(Particle.pos, 공식 주석 "씬 로컬 Y-up")이 씬 픽셀로 배선되는 부호를
/// 고정한다. 종전엔 씬 픽셀을 y-down 으로 오구현해 `wy = origin.y − scale.y·pos.y` 로 상쇄했으나,
/// pxToNDC 가 y-up 으로 바뀐 지금 이 `−` 를 그대로 두면 파티클이 물리와 반대 방향(예: 상승 파티클이
/// 화면에서 하강)으로 렌더된다. 이 테스트는 실제 GPUParticleSystem(buildParticles 경유, 실 텍스처)에
/// 수기 스냅샷을 주입해 particleVertices() 의 순수 산술만 검증(GPU 불요, 결정적).
final class ParticleYAxisRegressionTests: XCTestCase {
    private func dotPkg() -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"particle":"particles/dot.json","origin":"100 100 0","scale":"1 1 1"}]}
        """
        let particle = #"{"renderer":[{"name":"sprite"}],"maxcount":4,"starttime":0,"material":"materials/dotmat.json"}"#
        let material = #"{"passes":[{"textures":["dot"]}]}"#
        return ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/dot.json", data: Data(particle.utf8)),
            (name: "materials/dotmat.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
    }

    /// 스프라이트 파티클: sim 로컬 pos.y=+50(물리적으로 "위") 은 씬 중앙(origin=100,100, 200×200 캔버스)
    /// 보다 화면 위(NDC y 양수) 에 그려져야 한다. 종전 부호(`−`)라면 NDC y 가 음수(화면 아래)로 나와 적발.
    func testUpwardLocalParticleRendersAboveCenter() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = dotPkg()
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard let sys = built.first else { XCTFail("파티클 시스템 빌드 실패"); return }
        XCTAssertEqual(sys.origin.x, 100, accuracy: 1e-3)
        XCTAssertEqual(sys.origin.y, 100, accuracy: 1e-3)
        var particle = Particle()
        particle.pos = SIMD3(0, 50, 0)   // sim 로컬 y-up: "위"로 50px
        particle.size = 4
        particle.alpha = 1
        let verts = renderer.particleVertices([particle], sys)
        XCTAssertEqual(verts.count, 48, "쿼드 1개 = 6정점×8float")
        // 인터리브 레이아웃: [ndc.x, ndc.y, u, v, r, g, b, a] × 6.
        let ys = stride(from: 1, to: verts.count, by: 8).map { verts[$0] }
        XCTAssertTrue(ys.allSatisfy { $0 > 0.1 },
                      "pos.y=+50(sim 로컬 위)는 원점(NDC y=0)보다 화면 위(NDC y>0)여야 — 실제: \(ys)")
        _ = sys  // (var 로 받은 sys 자체는 미변형 사용 — mutating 경고 회피)
    }

    /// 리본(ropetrail) 경로도 동일 부호 규약(appendRibbon) — 히스토리 포인트 y=+50 이 화면 위에 와야 한다.
    func testUpwardHistoryPointRendersAboveCenterInRibbon() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"particle":"particles/rope.json","origin":"100 100 0","scale":"1 1 1"}]}
        """
        let particleJSON = #"{"renderer":[{"name":"ropetrail"}],"maxcount":4,"starttime":0,"material":"materials/dotmat.json"}"#
        let material = #"{"passes":[{"textures":["dot"]}]}"#
        let p = ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/rope.json", data: Data(particleJSON.utf8)),
            (name: "materials/dotmat.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard let sys = built.first, sys.isTrail else { XCTFail("리본 파티클 시스템 빌드 실패"); return }
        var particle = Particle()
        particle.size = 4
        particle.alpha = 1
        particle.history = [SIMD3(-5, 0, 0), SIMD3(0, 25, 0), SIMD3(5, 50, 0)]  // oldest→newest, 위로 이동
        var verts: [Float] = []
        let ok = renderer.appendRibbon(particle, sys, into: &verts)
        XCTAssertTrue(ok, "히스토리 3점은 유효 스팬(붕괴 아님) — 쿼드 폴백이면 안 됨")
        XCTAssertFalse(verts.isEmpty)
        let ys = stride(from: 1, to: verts.count, by: 8).map { verts[$0] }
        // head(최신, y=+50)의 엣지 정점들이 tail(y=−5 근방)보다 확실히 위(NDC y 큼)여야 한다.
        XCTAssertGreaterThan(ys.max()!, ys.min()! + 0.2,
                             "리본이 위로 뻗어야(head 가 화면 위) — 실제 ys: \(ys)")
        XCTAssertGreaterThan(ys.max()!, 0, "head(y=+50) 근방 정점은 원점보다 위(NDC y>0)여야")
    }
}
