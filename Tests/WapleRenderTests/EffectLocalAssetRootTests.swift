import XCTest
import Foundation
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

/// G-B2-06 정정(2026-08-20): 씬의 `effects[].passes[]` 오버라이드는 매니페스트 `passes[]` 의
/// **원본 배열 인덱스**로 정렬된다 — 명령 패스(`command:"copy"`/`"swap"`)도 슬롯을 하나 쓴다.
///
/// 이 리포는 여기서 한 번 틀렸다. "motionblur 는 effect.json 3패스인데 씬 패스는 2개,
/// fluidsimulation 은 20인데 18개" 라는 **개수 세기**만 보고 "씬은 셰이더 패스만 담는다" 고
/// 결론내 셰이더 전용 커서를 넣었는데, 원본 파서에는 명령 패스를 건너뛰는 분기 자체가 없다.
/// 루프 증가점(`0x1401e814e`)으로 가는 분기는 conditions 탈락 하나뿐이고, 씬 조회는
/// `0x1401e7a6e` 의 `mov edx, ebx` — 같은 원본 인덱스다.
///
/// 개수가 안 맞았던 진짜 이유는 **범위 밖 = 오버라이드 없음**이라서다. fluidsimulation 은
/// 명령 패스가 배열 끝이라 에디터가 후행 빈 원소를 잘라냈고, motionblur 는 중간이라 씬
/// `passes[1]` 이 빈 `{}` 로 남았다.
final class ScenePassOverrideIndexTests: XCTestCase {

    private func pass(_ tag: String) -> SceneEffectPass {
        var p = SceneEffectPass()
        p.constants[tag] = [1]
        return p
    }

    /// motionblur 배치 그대로: 매니페스트 [0]셰이더 [1]copy [2]셰이더, 씬은 2개.
    /// 셰이더 패스 1(원본 인덱스 2)은 씬 `passes[1]` 이 **아니라** 범위 밖을 받아야 한다.
    func testCommandPassConsumesASceneSlot() {
        let scene = [pass("first"), SceneEffectPass()]
        XCTAssertEqual(SceneRenderer.sceneOverride(forRawPassIndex: 0, in: scene).constants["first"], [1],
                       "셰이더 패스 0 은 씬 passes[0] 을 받는다")
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: 1, in: scene).constants.isEmpty,
                      "copy 패스가 씬 passes[1](빈 객체)을 소비한다")
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: 2, in: scene).constants.isEmpty,
                      "셰이더 패스 1 은 원본 인덱스 2 — 범위 밖이라 오버라이드가 없다")
    }

    /// 범위 밖은 에러도 클램프도 랩어라운드도 아니다. 마지막 원소로 클램프하면 앞 패스의
    /// 상수가 뒤 패스에 새는데, 그건 원본에 없는 동작이다.
    func testOutOfRangeYieldsEmptyOverrideNotAClamp() {
        let scene = [pass("a"), pass("b")]
        XCTAssertEqual(SceneRenderer.sceneOverride(forRawPassIndex: 1, in: scene).constants["b"], [1])
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: 2, in: scene).constants.isEmpty)
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: 99, in: scene).constants.isEmpty)
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: -1, in: []).constants.isEmpty)
        XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: 0, in: []).constants.isEmpty)
    }

    /// fluidsimulation 배치: 명령 패스가 **끝**이라 원본 인덱스 규약과 셰이더 전용 커서가
    /// 우연히 같은 답을 낸다 — 이 자산만 보면 규약을 판별할 수 없다는 사실 자체를 고정한다.
    func testTrailingCommandPassesCannotDiscriminateTheRule() {
        let scene = (0..<18).map { pass("p\($0)") }
        for i in 0..<18 {
            XCTAssertEqual(SceneRenderer.sceneOverride(forRawPassIndex: i, in: scene).constants["p\(i)"], [1])
        }
        for i in 18..<20 {
            XCTAssertTrue(SceneRenderer.sceneOverride(forRawPassIndex: i, in: scene).constants.isEmpty,
                          "후행 swap 패스는 범위 밖 — 오버라이드 없음")
        }
    }
}

/// X-⑨ 조회 **순서** 회귀 가드. 이 순서를 한 번 틀렸고 CI 가 잡았다.
///
/// 처음 구현은 `quietAssetData("<root>/<name>")` → `quietAssetData("<name>")` 였다. 그런데
/// `quietAssetData` 자체가 **pkg → 베이스 자산** 순으로 훑기 때문에, 첫 조회가 pkg 에서
/// 빗나가면 곧장 베이스의 `<root>/<name>` 을 집어 **pkg 의 `<name>` 을 영원히 가린다.**
///
/// 실제 증상: 워크샵 pkg 가 자기 `shaders/effects/opacity.frag` 를 실었는데 동봉 스톡
/// opacity 셰이더가 이겼다(`SceneTranslatedEffectRenderTests.testShippedGLSLWinsOverHandPort`
/// 가 빨갛게 잡았다 — 씬이 빨강을 그려야 하는데 흰색이 나왔다).
///
/// 올바른 순서는 넷이다:
///   ① pkg `<root>/<name>`  ② pkg `<name>`  ③ base `<root>/<name>`  ④ base `<name>`
/// 씬이 실어 보낸 자산을 번들 자산이 덮는 일은 어떤 경우에도 없어야 한다.
final class EffectScopedLookupOrderTests: XCTestCase {

    /// pkg 가 팩 루트 경로로만 자산을 실었고 베이스에는 **이펙트-로컬 경로로** 같은 이름이
    /// 있을 때, pkg 것이 이겨야 한다. 이게 깨지면 워크샵 커스텀 셰이더가 통째로 무시된다.
    func testPackageRootBeatsBundledEffectLocalPath() throws {
        // 동봉 팩에 실제로 존재하는 이펙트-로컬 셰이더를 고른다(스톡 opacity).
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let bundledLocal = dir.appendingPathComponent("effects/opacity/shaders/effects/opacity.frag")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundledLocal.path),
                          "동봉 스톡 opacity 의 로컬 셰이더가 없다 — 이 대조의 전제가 바뀌었다")

        let renderer = makeRenderer()
        let marker = Data("// PKG-WINS-MARKER\n".utf8)
        let pkg = try makePackage([("shaders/effects/opacity.frag", marker)])
        let got = renderer.effectScopedData("shaders/effects/opacity.frag",
                                            root: "effects/opacity", package: pkg)
        XCTAssertEqual(got, marker,
                       "pkg 가 팩 루트에 실은 셰이더가 동봉 이펙트-로컬 셰이더에 가려졌다")
    }

    /// pkg 가 아무것도 안 실었으면 베이스로 내려가고, 거기서는 이펙트-로컬이 팩 루트보다 앞선다.
    func testFallsBackToBundledAndPrefersLocalRootThere() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let bundledLocal = dir.appendingPathComponent("effects/opacity/shaders/effects/opacity.frag")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundledLocal.path))

        let renderer = makeRenderer()
        // 빈 배열을 넘기면 안 된다 — `ScenePackage.fromDirectory` 는 엔트리가 0개면 nil 이다
        // (`ScenePackage.swift` 의 `guard !entries.isEmpty`). 조회 대상과 무관한 파일을 하나 넣어
        // "pkg 는 존재하되 이 셰이더는 없다" 상태를 만든다.
        let empty = try makePackage([("scene.json", Data("{}".utf8))])
        let got = renderer.effectScopedData("shaders/effects/opacity.frag",
                                            root: "effects/opacity", package: empty)
        // 동봉 파일 바이트와 직접 비교하지 **않는다**. `assetBaseRoots` 의 첫 루트는 사용자 WE
        // 설치본이라(BaseAssetsSettings.searchRoots), 검증용 맥 세션처럼 설치본이 있는 환경에서는
        // 그쪽 파일이 이겨 바이트가 다를 수 있다 — CI(설치본 없음)에서만 초록인 테스트가 된다.
        // 계약은 "pkg 가 비면 **이펙트-로컬 경로로** 베이스에서 찾아낸다" 이므로 그것만 본다.
        XCTAssertNotNil(got, "pkg 가 비면 베이스에서 찾아야 한다")
        XCTAssertEqual(got, renderer.baseAssetData("effects/opacity/shaders/effects/opacity.frag"),
                       "이펙트-로컬 경로로 해석돼야 한다(팩 루트 경로가 아니라)")
        XCTAssertNil(renderer.baseAssetData("shaders/effects/opacity.frag"),
                     "팩 루트에는 없다 — 그래서 로컬 루트가 필요한 것이다")
    }

    /// root 가 nil 이면 종전 경로 그대로(무회귀).
    func testNilRootBehavesLikePlainLookup() throws {
        let renderer = makeRenderer()
        let marker = Data("// ROOTLESS\n".utf8)
        let pkg = try makePackage([("shaders/effects/opacity.frag", marker)])
        XCTAssertEqual(renderer.effectScopedData("shaders/effects/opacity.frag", root: nil, package: pkg),
                       marker)
        XCTAssertEqual(renderer.effectScopedData("shaders/effects/opacity.frag", root: "", package: pkg),
                       marker, "빈 문자열 루트도 nil 과 같게 다뤄야 한다")
    }

    /// `assetBaseRoots` 는 `mount` 가 심는다 — 마운트 없이 조회만 시험하므로 직접 채운다.
    /// 안 채우면 베이스 폴백이 통째로 죽어서 "pkg 가 이겼다" 가 거짓 통과가 된다.
    private func makeRenderer() -> SceneRenderer {
        let r = SceneRenderer()
        r.assetBaseRoots = SceneRenderer.resolvedAssetBaseRoots()
        return r
    }

    private func makePackage(_ files: [(String, Data)]) throws -> ScenePackage {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_scoped_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try XCTUnwrap(ScenePackage.fromDirectory(dir))
    }
}
