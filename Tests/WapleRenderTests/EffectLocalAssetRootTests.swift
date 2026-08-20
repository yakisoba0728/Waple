import XCTest
@testable import WapleCore
@testable import WapleRender

/// X-⑨ (G-B2-08/G-B4-01): 이펙트가 **자기 자산 루트**를 갖는다.
///
/// 실측이 이 갭의 크기를 정한다. 동봉 팩의 스톡 이펙트 `effects/<name>/` 는 **46/46 전건**이
/// 자기 `shaders/` 와 `materials/` 를 갖고, 팩 루트에는 `shaders/effects/` 디렉터리가
/// **아예 없다**. 그런데 매니페스트와 머티리얼이 적는 경로는 그 로컬 루트 기준 상대 경로다:
///
///     effects/fluidsimulation/effect.json
///       → "material": "materials/effects/fluidsimulation_advection.json"
///     effects/fluidsimulation/materials/effects/fluidsimulation_advection.json
///       → "shader": "effects/fluidsimulation_advection"
///     실물: effects/fluidsimulation/shaders/effects/fluidsimulation_advection.frag
///
/// 종전엔 팩 루트에서만 찾아서 이 46종이 전건 해석 불가였다 — 번들에 76MB 를 넣어 두고
/// 정작 스톡 이펙트는 하나도 못 쓴 상태다. FBO 포맷·지속을 고쳐도 셰이더 자체를 못 찾으면
/// 유체는 여전히 안 돌기 때문에 같은 묶음으로 간다.
final class EffectLocalAssetRootTests: XCTestCase {

    private func effect(name: String, file: String = "") -> SceneEffect {
        // 인자 순서는 **선언 순서**를 따라야 한다(name, constants, textureNames, combos, file).
        SceneEffect(name: name, constants: [:], textureNames: [], combos: [:], file: file)
    }

    func testStockEffectRootFollowsConventionPath() {
        XCTAssertEqual(SceneRenderer.effectLocalRoot(effect(name: "fluidsimulation")),
                       "effects/fluidsimulation")
    }

    /// 워크샵 이펙트는 `file` 이 wsid 경로를 들고 있다 — 그 **부모 디렉터리**가 루트다.
    /// name 만 보면 wsid 가 유실돼 엉뚱한 스톡 이펙트 루트를 가리킨다.
    func testWorkshopEffectRootComesFromDeclaredFilePath() {
        let e = effect(name: "MyBlur", file: "effects/workshop/1234567890/MyBlur/effect.json")
        XCTAssertEqual(SceneRenderer.effectLocalRoot(e), "effects/workshop/1234567890/MyBlur")
    }

    /// 루트를 못 정하는 입력은 nil — 소비처가 종전 팩 루트 조회로 그대로 간다(무회귀).
    func testDegenerateInputsYieldNoRoot() {
        XCTAssertNil(SceneRenderer.effectLocalRoot(effect(name: "")))
        XCTAssertNil(SceneRenderer.effectLocalRoot(effect(name: "x", file: "effect.json")),
                     "슬래시가 없으면 부모 디렉터리가 없다")
    }

    /// 동봉 팩의 실물 배치를 계약으로 고정한다.
    ///
    /// 이게 깨지면(예: 자산을 팩 루트로 평탄화한 팩으로 교체) 로컬 루트 우선 조회는 폴백으로
    /// 흡수돼 무해하지만, **반대로 이 테스트가 통과하는 한 로컬 루트 없이는 스톡이 안 돈다**는
    /// 뜻이므로 회귀 시 원인을 여기서 바로 짚을 수 있다.
    func testShippedStockEffectsKeepAssetsInTheirOwnRoot() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let fm = FileManager.default
        let effects = dir.appendingPathComponent("effects", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: effects.path))?.sorted() ?? []
        var stock = 0, withOwnRoot = 0, missing: [String] = []
        for n in names {
            var isDir: ObjCBool = false
            let sub = effects.appendingPathComponent(n, isDirectory: true)
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.fileExists(atPath: sub.appendingPathComponent("effect.json").path) else { continue }
            stock += 1
            let hasShaders = fm.fileExists(atPath: sub.appendingPathComponent("shaders").path)
            let hasMaterials = fm.fileExists(atPath: sub.appendingPathComponent("materials").path)
            if hasShaders && hasMaterials { withOwnRoot += 1 } else { missing.append(n) }
        }
        XCTAssertGreaterThan(stock, 0, "스톡 이펙트를 하나도 못 찾았다 — 번들 배치가 바뀌었다")
        XCTAssertEqual(missing, [], "자기 shaders/materials 를 갖지 않은 스톡 이펙트")
        XCTAssertEqual(withOwnRoot, stock, "2026-08-20 실측은 46/46 전건이었다")
    }

    /// **팩 루트에는 `shaders/effects/` 가 없다.** 이 한 줄이 "베이스팩 폴백으로 46/46 해석 불가"
    /// 라는 진단의 근거다 — 폴백 경로에 애초에 디렉터리가 없으니 조회가 성공할 수가 없었다.
    func testPackRootHasNoEffectShaderDirectory() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let rootEffectShaders = dir.appendingPathComponent("shaders/effects", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootEffectShaders.path),
                       "팩 루트에 shaders/effects/ 가 생겼다면 폴백만으로도 해석될 수 있다 — 진단 갱신 필요")
        // 공유 헤더는 팩 루트에 있다(로컬 루트 조회 실패 후 폴백이 반드시 살아 있어야 하는 이유).
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("shaders/common.h").path))
    }

    /// 유체 시뮬의 실제 경로 체인이 전부 로컬 루트 아래 있다는 것을 파일 단위로 고정한다.
    func testFluidSimulationAssetChainResolvesOnlyUnderItsLocalRoot() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let fm = FileManager.default
        let root = "effects/fluidsimulation"
        let chain = ["materials/effects/fluidsimulation_advection.json",
                     "shaders/effects/fluidsimulation_advection.frag",
                     "shaders/effects/fluidsimulation_advection.vert"]
        for rel in chain {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("\(root)/\(rel)").path),
                          "로컬 루트에 없다: \(root)/\(rel)")
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(rel).path),
                           "팩 루트에도 있다면 이 갭은 유체에 도달하지 않는다: \(rel)")
        }
    }
}
