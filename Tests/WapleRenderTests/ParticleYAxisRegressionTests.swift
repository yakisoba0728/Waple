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
        // [2026-08-21] 8 → 12 float: 크로스페이드 배선(ParticleShaders.vertexFloats2D).
        XCTAssertEqual(verts.count, 6 * ParticleShaders.vertexFloats2D, "쿼드 1개 = 6정점×12float")
        // 인터리브 레이아웃: [ndc.x, ndc.y, u0, v0, r, g, b, a, u1, v1, blend, pad] × 6.
        let ys = stride(from: 1, to: verts.count, by: ParticleShaders.vertexFloats2D).map { verts[$0] }
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
        let ys = stride(from: 1, to: verts.count, by: ParticleShaders.vertexFloats2D).map { verts[$0] }
        // head(최신, y=+50)의 엣지 정점들이 tail(y=−5 근방)보다 확실히 위(NDC y 큼)여야 한다.
        XCTAssertGreaterThan(ys.max()!, ys.min()! + 0.2,
                             "리본이 위로 뻗어야(head 가 화면 위) — 실제 ys: \(ys)")
        XCTAssertGreaterThan(ys.max()!, 0, "head(y=+50) 근방 정점은 원점보다 위(NDC y>0)여야")
    }

    /// WE 리본 규약 3종을 고정한다 — 폭·UV 축·알파. 근거는 리포에 번들된 WE 원본 셰이더
    /// `Resources/WEAssets/shaders/genericropeparticle.geom` 이다.
    ///
    /// ① **반폭 = size**(`:79-80` `normalize(cross(eye,CP)) * sizeStart`) — 중심에서 ±size 라
    ///    전체폭이 2×size 다. 종전엔 쿼드 공식(`(uv.x-0.5)*size`)을 재사용해 `size*0.5` 였고
    ///    모든 리본이 **정확히 절반 폭**이었다.
    /// ② **u=가로, v=길이**(`:110·123·146·159` `vec2(0|1, uvMin..uvMax)`) — 종전엔 전치돼
    ///    리본 텍스처가 90° 돌아갔다.
    /// ③ **위치 기반 알파 페이드 없음** — 코멧 페이드는 `TRAILSCROLLALPHA`/`TRAILFADEALPHA`
    ///    콤보 뒤에 있고 기본 경로는 포인트 자신의 알파를 쓴다. 종전엔 `p.alpha * u` 로
    ///    항상 강제해 균일 알파를 의도한 리본도 꼬리가 투명해졌다.
    func testRibbonFollowsWEWidthUVAndAlphaConventions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"particle":"particles/rope.json","origin":"100 100 0","scale":"1 1 1"}]}
        """
        let particleJSON = #"{"renderer":[{"name":"ropetrail"}],"maxcount":4,"starttime":0,"material":"materials/dotmat.json"}"#
        let material = #"{"passes":[{"textures":["dot"]}]}"#
        let pkg = ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/rope.json", data: Data(particleJSON.utf8)),
            (name: "materials/dotmat.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: pkg, device: device)
        guard let sys = built.first, sys.isTrail else { XCTFail("리본 시스템 빌드 실패"); return }

        var particle = Particle()
        particle.size = 20            // 반폭 20px → 전체폭 40px (proj 200 → NDC 0.4)
        particle.alpha = 0.5          // 균일 알파 — 페이드가 강제되면 꼬리가 0 이 된다
        // 수평 이동: 접선이 x 축이라 폭은 순수 y 방향으로 벌어진다(측정이 단순해진다).
        particle.history = [SIMD3(-30, 0, 0), SIMD3(0, 0, 0), SIMD3(30, 0, 0)]
        var verts: [Float] = []
        XCTAssertTrue(renderer.appendRibbon(particle, sys, into: &verts))

        // 정점당 12 float: ndc.xy, u0,v0, rgba, u1,v1, blend, pad
        let vf = ParticleShaders.vertexFloats2D
        let ys = stride(from: 1, to: verts.count, by: vf).map { verts[$0] }
        let us = stride(from: 2, to: verts.count, by: vf).map { verts[$0] }
        let vs = stride(from: 3, to: verts.count, by: vf).map { verts[$0] }
        let alphas = stride(from: 7, to: verts.count, by: vf).map { verts[$0] }
        // ④ 리본은 크로스페이드를 안 탄다(WE rope 는 SPRITESHEET 콤보가 없는 별도 셰이더) —
        //    uv1 == uv0 · blend == 0 이라 `mix` 가 항등이고 렌더가 종전과 비트동일하다.
        let u1s = stride(from: 8, to: verts.count, by: vf).map { verts[$0] }
        let v1s = stride(from: 9, to: verts.count, by: vf).map { verts[$0] }
        let blends = stride(from: 10, to: verts.count, by: vf).map { verts[$0] }
        XCTAssertEqual(u1s, us, "리본의 두 번째 UV 는 첫 번째와 같아야 한다")
        XCTAssertEqual(v1s, vs, "리본의 두 번째 UV 는 첫 번째와 같아야 한다")
        XCTAssertTrue(blends.allSatisfy { $0 == 0 }, "리본 blend 는 전건 0 — 실제: \(Set(blends))")

        // ① 폭: 반폭 20px = NDC 0.2 → 양쪽 엣지 간격 0.4. size*0.5 였다면 0.2 가 나온다.
        XCTAssertEqual(ys.max()! - ys.min()!, 0.4, accuracy: 0.01,
                       "반폭은 size 그대로다(전체폭 2×size) — size*0.5 면 0.2 가 나온다")

        // ② UV 축: u 는 좌우 엣지라 {0,1} 두 값뿐이고, v 는 길이라 중간값을 갖는다.
        XCTAssertEqual(Set(us.map { ($0 * 1000).rounded() / 1000 }), [0, 1],
                       "u 는 폭(0/1 엣지)이어야 한다 — 전치돼 있으면 길이 따라 여러 값이 된다")
        XCTAssertTrue(vs.contains { $0 > 0.01 && $0 < 0.99 },
                      "v 는 길이 방향이라 중간값이 있어야 한다 — 실제 vs: \(Set(vs))")

        // ③ 알파: 저작값 그대로. 페이드가 강제되면 꼬리(u=0)가 0 이 된다.
        XCTAssertEqual(alphas.min()!, 0.5, accuracy: 1e-5,
                       "위치 기반 페이드를 얹지 않는다 — 강제되면 꼬리가 0")
        XCTAssertEqual(alphas.max()!, 0.5, accuracy: 1e-5)
    }

    /// 2D 파티클도 3축 회전을 **정사영**으로 표현한다.
    ///
    /// 2D 경로에는 z 좌표가 없어 out-of-plane 회전을 못 담는다고 보기 쉽지만, 화면 기저에
    /// 대해 접선을 구하고 xy 성분만 취하면 그게 정사영이다 — x·y 회전은 접선의 화면 성분을
    /// **단축**시켜 기울어 납작해지는 효과(foreshortening)를 만든다.
    ///
    /// 이 경로가 없으면 3축 회전의 도달이 3D 파티클 5씬에 그친다(33씬이 저작한다).
    func testParticle2DProjectsOutOfPlaneRotationAsForeshortening() {
        func screen(_ rot: SIMD3<Float>) -> (r: SIMD2<Float>, u: SIMD2<Float>) {
            let t = SceneRenderer.particleTangents(rotation: rot,
                                                   right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
            return (SIMD2(t.right.x, t.right.y), SIMD2(t.up.x, t.up.y))
        }
        // ① z-only 는 종전 롤 공식과 **완전 동치** — 33씬 밖 파티클은 픽셀 불변이어야 한다.
        for z in [Float(0.3), 1.2, -2.0] {
            let s = screen(SIMD3(0, 0, z))
            XCTAssertEqual(s.r.x, cos(z), accuracy: 1e-6)
            XCTAssertEqual(s.r.y, sin(z), accuracy: 1e-6)
            XCTAssertEqual(s.u.x, -sin(z), accuracy: 1e-6)
            XCTAssertEqual(s.u.y, cos(z), accuracy: 1e-6)
        }
        // ② x 회전은 up 을 단축한다(화면 밖으로 기울어 짧아 보인다). right 는 x 축이라 불변.
        let tiltX = screen(SIMD3(0.7, 0, 0))
        XCTAssertLessThan(simd_length(tiltX.u), 0.9, "x 회전 → up 이 단축돼야 한다")
        XCTAssertEqual(simd_length(tiltX.r), 1, accuracy: 1e-5, "x 회전은 right 를 안 건드린다")
        // ③ y 회전은 right 를 단축한다.
        let tiltY = screen(SIMD3(0, 0.7, 0))
        XCTAssertLessThan(simd_length(tiltY.r), 0.9, "y 회전 → right 가 단축돼야 한다")
        XCTAssertEqual(simd_length(tiltY.u), 1, accuracy: 1e-5)
    }
}
