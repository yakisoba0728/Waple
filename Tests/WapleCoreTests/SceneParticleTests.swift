import XCTest
@testable import WapleCore

final class SceneParticleTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    func testSceneSurfacesParticleObject() {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"name":"snow","particle":"particles/snow.json","origin":"128 128 0","scale":"0.5 0.5 0.5"}
         ]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","distancemax":1000,"rate":25,"origin":"150 550 0"}],
         "initializer":[{"name":"sizerandom","min":2,"max":30},{"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"}],
         "operator":[{"name":"movement","gravity":"0 0 0"},{"name":"alphafade","fadeintime":0.1}],
         "renderer":[{"name":"sprite"}],"maxcount":360,"starttime":15,
         "material":"materials/snow.json"}
        """
        let material = #"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/snow"]}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/snow.json", d(particle)),
            ("materials/snow.json", d(material)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.layers.count, 0)
        XCTAssertEqual(doc.particles.count, 1)
        let p = doc.particles[0]
        XCTAssertEqual(p.origin, Vec2(x: 128, y: 128))
        XCTAssertEqual(p.scale, Vec2(x: 0.5, y: 0.5))
        XCTAssertEqual(p.def.maxCount, 360)
        XCTAssertEqual(p.def.material?.blend, .additive)
        XCTAssertEqual(p.def.material?.textureName, "particle/snow")
        XCTAssertEqual(p.def.renderer, .sprite)
    }

    func testInvisibleParticleSkipped() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/x.json","visible":false}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/x.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 0)
    }

    func testMissingParticleFileDropped() {
        let scene = #"{"objects":[{"id":1,"particle":"particles/missing.json"}]}"#
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 0)  // 로드 실패 → 드롭(무크래시)
    }

    // MARK: instanceoverride (실측 127씬/866건 — 프리셋 인스턴스 모디파이어)

    /// 스칼라 오버라이드는 프리셋 값의 **배수**(WE 에디터 인스턴스 슬라이더): maxcount·버스트 ← count,
    /// 이미터 rate ← rate, 이니셜라이저 min/max ← size/alpha/lifetime/speed, colorn 은 색 배수.
    /// {user,value} 바인딩(실물 shimmering_particles count)도 언랩. id 는 인스턴스 식별자 — 미적용.
    func testInstanceOverrideScalesPresetDef() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/snow.json","origin":"0 0 0",
          "instanceoverride":{"id":126,"count":2.0,"rate":0.5,"size":2.0,
                              "alpha":{"user":"a","value":0.8},"speed":1.5,"lifetime":3.0,
                              "colorn":"0.5 0.5 1"}}]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":25,"instantaneous":4,"distancemax":100}],
         "initializer":[{"name":"sizerandom","min":2,"max":30},
                        {"name":"alpharandom","min":0.5,"max":1},
                        {"name":"lifetimerandom","min":1,"max":3},
                        {"name":"velocityrandom","min":"-10 -50 0","max":"10 -90 0"},
                        {"name":"colorrandom","min":"100 100 100","max":"200 200 200"}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/snow.json", d(particle)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        let def = doc.particles[0].def
        XCTAssertEqual(def.maxCount, 200, "count 2.0 → maxcount 100×2")
        guard case let .sphere(_, _, _, _, rate, burst, _) = def.emitters[0] else {
            return XCTFail("sphere emitter expected")
        }
        XCTAssertEqual(rate, 12.5, "rate 0.5 → 25×0.5")
        XCTAssertEqual(burst, 8, "count 2.0 → instantaneous 4×2")
        XCTAssertTrue(def.initializers.contains(.sizeRandom(min: 4, max: 60, exponent: 1)))
        XCTAssertTrue(def.initializers.contains(.alphaRandom(min: 0.4, max: 0.8, exponent: 1)),
                      "{user,value} 바인딩 alpha 0.8(언랩)×[0.5,1]")
        XCTAssertTrue(def.initializers.contains(.lifetimeRandom(min: 3, max: 9, exponent: 1)))
        XCTAssertTrue(def.initializers.contains(
            .velocityRandom(min: Vec3(x: -15, y: -75, z: 0), max: Vec3(x: 15, y: -135, z: 0), exponent: 1)))
        XCTAssertTrue(def.initializers.contains(
            .colorRandom(min: Vec3(x: 50, y: 50, z: 100), max: Vec3(x: 100, y: 100, z: 200), exponent: 1)))
    }

    /// SceneDocument의 재귀 자식 로더도 전체 override는 루트에만 적용하되, 엔진에서 같은 scene owner를
    /// 갖는 자식/손자에는 opcode4용 count 배수만 공유해야 한다.
    func testInstanceOverrideCountSharesRuntimeMultiplierWithDescendantsOnly() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/root.json",
          "instanceoverride":{"count":2}}]}
        """
        let root = """
        {"children":[{"name":"particles/child.json","type":"static","maxcount":6}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let child = """
        {"children":[{"name":"particles/grand.json","type":"static","maxcount":7}],
         "renderer":[{"name":"sprite"}],"maxcount":3}
        """
        let grand = """
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0"},{"offset":"7 0 0"}],
         "emitter":[{"name":"boxrandom","rate":0,"instantaneous":8,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencebetweencontrolpoints","count":4,"flags":16}],
         "renderer":[{"name":"sprite"}],"maxcount":8}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/root.json", d(root)),
            ("particles/child.json", d(child)),
            ("particles/grand.json", d(grand)),
        ])
        let def = try! SceneDocument.parse(package: pkg).particles[0].def
        let childDef = def.children[0].def
        let grandDef = childDef.children[0].def

        XCTAssertEqual(def.maxCount, 2, "전체 count override는 루트 정적 def에만 적용")
        XCTAssertEqual(childDef.maxCount, 3, "자식 maxcount는 authored 값 유지")
        XCTAssertEqual(grandDef.maxCount, 8, "손자 maxcount도 authored 값 유지")
        XCTAssertEqual(def.instanceCountMultiplier, 2)
        XCTAssertEqual(childDef.instanceCountMultiplier, 2)
        XCTAssertEqual(grandDef.instanceCountMultiplier, 2)

        var sim = ParticleSimulator(def: def, seed: 407)
        _ = sim.step(0.01)
        let particles = sim.descendantDisplay(path: [0, 0])
        XCTAssertEqual(particles.count, 8)
        for (particle, expectedX) in zip(particles, (0...7).map(Float.init)) {
            XCTAssertEqual(particle.pos.x, expectedX, accuracy: 1e-5)
        }
    }

    /// controlpointN 오버라이드는 CP 오프셋 **절대 대체**이고, controlpointattract 의 target 은 def 파스
    /// 시 CP 로 베이크되므로(ParticleSystem attract 재바인딩) 오버라이드가 베이크 **전에** 적용돼야 한다
    /// — 실측: CP 오버라이드 51오브젝트 중 22가 attract 보유(사후 def 복제로는 미치지 못하는 지점).
    func testInstanceOverrideControlPointRebakesAttractTarget() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/p.json",
          "instanceoverride":{"controlpoint1":"100 200 0"}}]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":1}],
         "operator":[{"name":"controlpointattract","controlpoint":1,"scale":2,"threshold":10}],
         "controlpoint":[{},{"offset":"5 5 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/p.json", d(particle)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        let def = doc.particles[0].def
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 100, y: 200, z: 0))
        XCTAssertTrue(def.operators.contains(
            .controlPointAttract(scale: 2, threshold: 10, target: Vec3(x: 100, y: 200, z: 0))),
            "attract target 이 오버라이드된 CP1 로 재베이크돼야 함 — got \(def.operators)")
    }

    /// 배수 대상 이니셜라이저가 프리셋에 없으면 주입(스폰 기본 1 × 배수 = 배수 자체).
    /// speed 는 속도원(velocityrandom 등)이 없으면 0×배수=0 — 주입하지 않는다.
    /// brightness 는 colorn 과 합성된 색 배수로 반영.
    func testInstanceOverrideInjectsInitializersWhenAbsent() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/p.json",
          "instanceoverride":{"size":2.0,"alpha":0.5,"lifetime":2.0,"speed":2.0,
                              "colorn":"1 0 0","brightness":2.0}}]}
        """
        let particle = #"{"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],"maxcount":10}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/p.json", d(particle)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        let def = doc.particles[0].def
        XCTAssertTrue(def.initializers.contains(.sizeRandom(min: 2, max: 2, exponent: 1)))
        XCTAssertTrue(def.initializers.contains(.alphaRandom(min: 0.5, max: 0.5, exponent: 1)))
        XCTAssertTrue(def.initializers.contains(.lifetimeRandom(min: 2, max: 2, exponent: 1)))
        XCTAssertTrue(def.initializers.contains(.colorList(colors: [Vec3(x: 2, y: 0, z: 0)])),
                      "colorn(1,0,0)×brightness2 합성 색 배수 주입")
        XCTAssertEqual(def.initializers.count, 4, "speed 는 속도원 부재 시 미주입")
    }

    /// id 만 있는 오버라이드(인스턴스 식별자)는 def 를 바꾸지 않는다 — 무오버라이드 파스와 동일.
    func testInstanceOverrideIdOnlyIsNoop() {
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":25,"distancemax":100}],
         "initializer":[{"name":"sizerandom","min":2,"max":30}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """
        func parse(_ objectJSON: String) -> ParticleSystemDef {
            let pkg = ScenePackage.assemble([
                ("scene.json", d(#"{"objects":[\#(objectJSON)]}"#)),
                ("particles/p.json", d(particle)),
            ])
            return try! SceneDocument.parse(package: pkg).particles[0].def
        }
        let plain = parse(#"{"id":1,"particle":"particles/p.json"}"#)
        let idOnly = parse(#"{"id":1,"particle":"particles/p.json","instanceoverride":{"id":126}}"#)
        XCTAssertEqual(plain, idOnly)
    }

    /// 3D 씬 파티클 오브젝트: 전-성분 origin/scale(z 포함)·parent·visible 을 SceneParticle 이 보존해야
    /// 3D 마운트가 원근 배치를 할 수 있다(2D 는 origin/scale Vec2 만 사용 — 무영향). 실물 3706286085
    /// SpeedLine(origin z=-58, 3D scale)·3737268876 torch(parent=1203) 구조를 축약.
    func testParticle3DTransformFieldsPreserved() {
        let scene = """
        {"general":{"fov":50.0},"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "objects":[
           {"id":1,"model":"models/x.mdl"},
           {"id":50,"name":"root","origin":"0 1 0"},
           {"id":2,"name":"speedline","particle":"particles/p.json","parent":50,
            "origin":"0 0 -58","scale":"0.01 0.01 0.025","angles":"0 0 0","visible":true}
         ]}
        """
        let particle = d(#"{"renderer":[{"name":"sprite"}],"maxcount":10,"material":"materials/p.json"}"#)
        let material = d(#"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/dot"]}]}"#)
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/p.json", particle), ("materials/p.json", material),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        let p = doc.particles[0]
        XCTAssertEqual(p.origin3D, Vec3(x: 0, y: 0, z: -58), "3D origin z 보존 실패")
        XCTAssertEqual(p.scale3D, Vec3(x: 0.01, y: 0.01, z: 0.025), "3D scale z 보존 실패")
        XCTAssertEqual(p.parent, 50, "parent 노드 id 보존 실패")
        XCTAssertTrue(p.visible)
        // 2D 경로 필드는 종전대로 첫 2성분(무회귀).
        XCTAssertEqual(p.origin, Vec2(x: 0, y: 0))
        XCTAssertEqual(p.scale, Vec2(x: 0.01, y: 0.01))
    }

    // MARK: - parallaxDepth (F200)

    /// 레이어(SceneLayer.parallaxDepth)와 동형 — 파티클 오브젝트도 parallaxDepth 를 보존해야
    /// 마우스 시차에서 깊이 차별화가 가능하다(코퍼스 실측: particle 오브젝트 53개 중 42개(79%) 보유).
    func testParticleParallaxDepthParsed() {
        let scene = #"{"objects":[{"id":1,"particle":"particles/p.json","parallaxDepth":"0.3 0.3 0"}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/p.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        XCTAssertEqual(doc.particles[0].parallaxDepth, Vec2(x: 0.3, y: 0.3))
    }

    /// 미지정 시 1(균일 시차, 무회귀 — 레이어 :946/:1070 기본값과 동형).
    func testParticleParallaxDepthDefaultsToOne() {
        let scene = #"{"objects":[{"id":1,"particle":"particles/p.json"}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/p.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        XCTAssertEqual(doc.particles[0].parallaxDepth, Vec2(x: 1, y: 1))
    }

    // MARK: - visible 스크립트 (F199, SceneVisibleScriptTests 의 레이어 규약과 동형)

    /// visible {"value":false,"script":...} → 578행 게이트를 스크립트 보유로 통과해 파스는 되지만
    /// (testInvisibleParticleSkipped 와 대비: 스크립트 없는 정적 false 만 드롭), 종전엔 SceneParticle
    /// 에 필드가 없어 스크립트가 유실되고 initialVisible=false 로 영구 고정됐다(런타임 토글 불능).
    func testParticleVisibleScriptCaptured() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/p.json",
          "visible":{"value":false,"script":"export function update(v){ return true; }"}}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/p.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1, "스크립트 보유 시 정적 false 라도 드롭되지 않아야")
        let p = doc.particles[0]
        XCTAssertFalse(p.visible, "초기값은 정적 value(false) 그대로 유지")
        XCTAssertEqual(p.visibleScript, "export function update(v){ return true; }")
    }

    /// 정적 visible(스크립트 없음)은 종전대로 visibleScript nil(무회귀).
    func testParticleNoVisibleScriptStaysNil() {
        let scene = #"{"objects":[{"id":1,"particle":"particles/p.json","visible":true}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/p.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        XCTAssertNil(doc.particles[0].visibleScript)
    }
}
