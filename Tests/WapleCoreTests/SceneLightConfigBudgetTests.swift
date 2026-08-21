import XCTest
@testable import WapleCore

/// `general.lightconfig` **소비** 규약 — `SceneLightSlotKind` / `SceneLightSlotBudget`(WapleCore).
///
/// 파스(니블 폭·절단·`isUInt` 게이트)는 `SceneGeneralKeysTests` 가 이미 덮는다. 이 파일은 그 다음,
/// 즉 **파스된 값이 라이트를 어떻게 자르는가**를 못박는다. 렌더 소비부
/// (`Scene3DLighting.resolveLights(_:nodes:config:)`)는 `import Metal` 이라 리눅스에서 타입체크조차
/// 안 되므로, 예산 산술만 Core 로 빼서 여기서 잠근다.
///
/// ## 근거 VA (2026-08-21 재확인, imagebase 0x140000000)
/// - 파스 OR: point `and 0xf` → `or [rcx+0x121c],eax` `0x140187b7a` · spot `shl 4` `0x140187bab` ·
///   tube `shl 8` `0x140187bd7` · directional `shl 0xc` `0x140187c03` · spotcookie `shl 0x12`
///   `0x140187c32` · spotshadowcookie `shl 0x14` `0x140187c66` · spotshadow `shl 0x10` `0x140187c93` ·
///   directionalshadow `shl 0x16` `0x140187cb9` · pointshadow `shl 0x18` `0x140187d00`.
///   섀도우 3키를 통째로 버리는 게이트는 `cmp byte [r13+0x1ac],0` `0x140187c39`(= 앱 섀도우 품질).
/// - 콤보 세터 `0x1401a5c40`–`0x1401a6c5d`(9키 ↔ 9콤보 1:1).
/// - 유니폼 패커 잔여 카운터: point `0x14019325f` · spot `0x140192dbf` · tube `0x140192a19` ·
///   directional `0x14019111d` · pointshadow `0x14019332b` · directionalshadow `0x14019353a`.
/// - 타입 문자열 표 5엔트리 `0x14025e853`–`0x14025e9c9`(`"point"`→5 = 레거시 레인).
/// - 셰이더 쪽 평문 교차확인(V0 레인): `uniform vec4 g_LPoint_Color[LIGHTS_POINT];`
///   (`generic3.frag:64`)와 `for (uint l = 0u; l < CASTU(LIGHTS_POINT); ++l)`(`:90`)
///   — **콤보 값이 곧 배열 길이이자 루프 상한**이라는 것이 셰이더 파일에 그대로 적혀 있다.
final class SceneLightConfigBudgetTests: XCTestCase {

    // MARK: - 종류 매핑 — `l` 접두 4종만 V1 레인이다

    /// WE 문자열 표는 5엔트리이고 `"point"` 는 enum **5**(레거시 4슬롯 레인)다. V1 패커
    /// (`0x140191114` `cmp eax,1` / `jne`)가 4·5 를 버리므로 `lightconfig` 슬롯을 먹지 않는다.
    func testSlotKindAcceptsOnlyV1LaneTypes() {
        XCTAssertEqual(SceneLightSlotKind(weLightType: "lpoint"), .point)
        XCTAssertEqual(SceneLightSlotKind(weLightType: "lspot"), .spot)
        XCTAssertEqual(SceneLightSlotKind(weLightType: "ltube"), .tube)
        XCTAssertEqual(SceneLightSlotKind(weLightType: "ldirectional"), .directional)
        XCTAssertEqual(SceneLightSlotKind(weLightType: "LPoint"), .point, "대소문자 무관")

        // 레거시/미지 — 예산 밖. 여기가 nil 이 아니게 되면 `lightconfig` 를 가진 씬의 레거시
        // 라이트가 통째로 드롭돼 화면이 검어진다(arsenal 은 ambientcolor 가 완전 검정).
        XCTAssertNil(SceneLightSlotKind(weLightType: "point"))
        XCTAssertNil(SceneLightSlotKind(weLightType: "spot"))
        XCTAssertNil(SceneLightSlotKind(weLightType: "tube"))
        XCTAssertNil(SceneLightSlotKind(weLightType: "directional"))
        XCTAssertNil(SceneLightSlotKind(weLightType: ""))
        XCTAssertNil(SceneLightSlotKind(weLightType: "lpoints"))
    }

    // MARK: - 미저작(nil) = 종전 폴백 (무회귀의 핵심)

    /// **동봉 씬 172개 중 170개가 이 경로다(2026-08-21 실측).** 미저작이면 어떤 `take` 도 실패하지
    /// 않아야 한다 —
    /// 실패하는 순간 라이트가 사라지고 그 씬들의 픽셀이 바뀐다.
    func testUnauthoredBudgetNeverDropsAnything() {
        var b = SceneLightSlotBudget(nil)
        for kind in SceneLightSlotKind.allCases {
            XCTAssertNil(b.remaining(kind), "미저작은 상한 자체가 없다")
            XCTAssertNil(b.remainingShadow(kind))
        }
        for _ in 0..<64 {
            for kind in SceneLightSlotKind.allCases {
                XCTAssertTrue(b.take(kind), "미저작 예산은 무제한")
            }
            XCTAssertTrue(b.takeShadow(.point))
            XCTAssertTrue(b.takeShadow(.directional))
        }
        // tube/spot 은 WE 에도 섀도우 판이 없다(tube 스니펫 0x14048c9e0 마지막 인자 리터럴 1.0).
        XCTAssertFalse(b.takeShadow(.spot))
        XCTAssertFalse(b.takeShadow(.tube))
    }

    /// 빈 객체 `{}` 는 nil 이 아니라 "전건 0 으로 저작됨" 이다 — WE 는 그때 V1 라이트를 하나도
    /// 싣지 않는다(`0x140190ca8` `test r9d,r9d; je`). 저작/미저작을 구분해 남긴 이유가 이것.
    func testAuthoredAllZeroDropsEverything() {
        var b = SceneLightSlotBudget(SceneLightConfig())
        for kind in SceneLightSlotKind.allCases {
            XCTAssertEqual(b.remaining(kind), 0)
            XCTAssertFalse(b.take(kind))
        }
        XCTAssertFalse(b.takeShadow(.point))
        XCTAssertFalse(b.takeShadow(.directional))
    }

    // MARK: - 종별 총량

    func testPerKindQuotaIsExactAndIndependent() {
        var c = SceneLightConfig()
        c.point = 2; c.spot = 1; c.tube = 0; c.directional = 3
        var b = SceneLightSlotBudget(c)

        XCTAssertTrue(b.take(.point)); XCTAssertTrue(b.take(.point))
        XCTAssertFalse(b.take(.point), "3번째 point 는 드롭(0x140193265 je)")
        XCTAssertEqual(b.remaining(.point), 0)

        XCTAssertTrue(b.take(.spot)); XCTAssertFalse(b.take(.spot))
        XCTAssertFalse(b.take(.tube), "tube:0 은 첫 라이트부터 드롭")
        // point 를 다 써도 directional 예산은 그대로 — 카운터가 종별로 따로다.
        XCTAssertEqual(b.remaining(.directional), 3)
        XCTAssertTrue(b.take(.directional))
    }

    /// 니블은 4비트라 상한이 15, 섀도우/쿠키 계열은 2비트라 3 이다. 파스가 **절단**(클램프 아님)
    /// 하므로 16 은 0 이 되고, 15 는 15 슬롯이 된다.
    func testNibbleCeilingIsFifteen() throws {
        let c = try XCTUnwrap(SceneLightConfig.parse(json(#"{"point":15,"pointshadow":3}"#)))
        XCTAssertEqual(c.point, 15)
        XCTAssertEqual(c.pointShadow, 3)
        var b = SceneLightSlotBudget(c)
        for i in 0..<15 { XCTAssertTrue(b.take(.point), "슬롯 \(i)") }
        XCTAssertFalse(b.take(.point), "16번째는 없다 — 니블 상한")

        // 절단: 16 → 0(예산 전무), 17 → 1.
        let over = try XCTUnwrap(SceneLightConfig.parse(json(#"{"point":16}"#)))
        XCTAssertEqual(over.point, 0)
        var bo = SceneLightSlotBudget(over)
        XCTAssertFalse(bo.take(.point), "`{\"point\":16}` 은 WE 에서 0 이다(and eax,0xf)")

        let wrapped = try XCTUnwrap(SceneLightConfig.parse(json(#"{"point":17}"#)))
        XCTAssertEqual(wrapped.point, 1)
    }

    // MARK: - 섀도우는 가산이 아니라 **분할**

    /// 동봉 `collisionmodel` 의 형태 `{"point":1,"pointshadow":1}` 은 라이트 **1개**이고 그게
    /// 캐스터라는 뜻이다(생성기 point 루프가 `[0,PS)` 다음 `[PS,P)` 를 찍는다 — 0x140169d23/0x140169d42).
    func testShadowCountPartitionsTheKindQuotaRatherThanAddingToIt() {
        var c = SceneLightConfig()
        c.point = 1; c.pointShadow = 1
        var b = SceneLightSlotBudget(c)
        XCTAssertTrue(b.take(.point))
        XCTAssertTrue(b.takeShadow(.point))
        XCTAssertFalse(b.take(.point), "총량은 1 — 섀도우가 추가 슬롯을 만들지 않는다")
    }

    /// 섀도우 예산이 소진된 캐스터는 **셰이딩은 남고 그림자만 잃는다**
    /// (`0x140193331` 의 `je` 는 섀도우 프로젝션 기록만 건너뛴다).
    func testShadowExhaustionKeepsTheLightButDropsItsShadow() {
        var c = SceneLightConfig()
        c.point = 3; c.pointShadow = 1
        var b = SceneLightSlotBudget(c)

        XCTAssertTrue(b.take(.point)); XCTAssertTrue(b.takeShadow(.point))
        XCTAssertTrue(b.take(.point)); XCTAssertFalse(b.takeShadow(.point), "섀도우만 상실")
        XCTAssertTrue(b.take(.point), "라이트 자체는 셋째까지 산다")
    }

    /// directional 섀도우도 같은 규약이지만 **카운터가 따로**다(`[rbp+0x24]` 0x14019353a).
    /// spot/tube 는 종류 자체가 캐스터가 아니라 항상 false.
    func testShadowBudgetsAreSeparatePerKind() {
        var c = SceneLightConfig()
        c.point = 2; c.pointShadow = 0
        c.directional = 1; c.directionalShadow = 1
        c.spot = 1; c.tube = 1
        var b = SceneLightSlotBudget(c)

        XCTAssertTrue(b.take(.point))
        XCTAssertFalse(b.takeShadow(.point), "pointshadow:0")
        XCTAssertTrue(b.take(.directional))
        XCTAssertTrue(b.takeShadow(.directional), "point 소진과 무관")
        XCTAssertTrue(b.take(.spot))
        XCTAssertFalse(b.takeShadow(.spot), "spot 섀도우는 Waple 미이식(WE 는 별도 배열 구간)")
        XCTAssertTrue(b.take(.tube))
        XCTAssertFalse(b.takeShadow(.tube), "tube 는 WE 정본도 무섀도우")
    }

    // MARK: - 동봉 실물 코퍼스 — 예산을 켜도 **한 픽셀도 안 바뀐다**

    /// 무회귀의 본체. 동봉 자산 트리의 **모든 scene.json** 을 원문 바이트로 훑어
    /// `general.lightconfig` 예산을 그 씬의 라이트에 실제로 태워 본다. 드롭이 1건이라도 나오면
    /// 배선이 화면을 바꾼 것이다. 파스 계층이 아니라 JSON 원문을 읽으므로
    /// `SceneGeneralKeysTests.testBundledReachCensus` 와 **독립적인** 두 번째 그물이다.
    func testBundledCorpusIsUnchangedUnderTheBudget() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var scenes = 0, authored = 0, lightsSeen = 0, dropped = 0, shadowsLost = 0
        var legacyLane = 0
        for case let url as URL in en where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = AssetJSON.dictionary(data),
                  let general = obj["general"] as? [String: Any],
                  let objects = obj["objects"] as? [Any] else { continue }
            scenes += 1
            let config = SceneLightConfig.parse(general["lightconfig"])
            if config != nil { authored += 1 }
            var budget = SceneLightSlotBudget(config)
            for case let o as [String: Any] in objects {
                guard let raw = o["light"] else { continue }
                let type = ((raw as? [String: Any])?["value"] as? String ?? raw as? String ?? "")
                lightsSeen += 1
                guard let kind = SceneLightSlotKind(weLightType: type) else {
                    legacyLane += 1   // 예산 밖 — 종전 그대로 통과
                    continue
                }
                if !budget.take(kind) { dropped += 1; continue }
                if o["castshadow"] as? Bool == true, !budget.takeShadow(kind) { shadowsLost += 1 }
            }
        }
        XCTAssertGreaterThan(scenes, 150, "씬 트리가 비었다 — 경로가 틀린 것")
        XCTAssertEqual(authored, 2, "lightconfig 저작은 modeleditor + collisionmodel 2건뿐")
        XCTAssertEqual(lightsSeen, 3, "동봉 라이트는 lpoint 3개(modeleditor 2 + collisionmodel 1)")
        XCTAssertEqual(legacyLane, 0, "동봉 트리에 레거시 \"point\" 는 없다(설치본 projects/ 전용)")
        XCTAssertEqual(dropped, 0, "예산 때문에 사라지는 동봉 라이트는 0 이어야 한다")
        XCTAssertEqual(shadowsLost, 0, "예산 때문에 그림자를 잃는 동봉 라이트도 0")
    }

    /// 위 전수 스캔이 실제로 두 씬을 **읽었는지** 를 값으로 다시 못박는다(스캔이 조용히 0건을
    /// 훑고 통과하는 사고 방지).
    func testBundledAuthoredScenesHaveExactlyMatchingBudgets() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정")
        }
        func config(_ rel: String) throws -> SceneLightConfig {
            let data = try Data(contentsOf: root.appendingPathComponent(rel))
            let obj = try XCTUnwrap(AssetJSON.dictionary(data), rel)
            let general = try XCTUnwrap(obj["general"] as? [String: Any], rel)
            return try XCTUnwrap(SceneLightConfig.parse(general["lightconfig"]), rel)
        }
        // modeleditor: lpoint ×2, 캐스터 0 / 예산 point 2 · pointshadow 0 → 2 유지.
        var a = SceneLightSlotBudget(try config("scenes/modeleditor/scene.json"))
        XCTAssertTrue(a.take(.point)); XCTAssertTrue(a.take(.point))
        XCTAssertEqual(a.remaining(.point), 0)
        XCTAssertEqual(a.remainingShadow(.point), 0, "캐스터가 없으므로 0 이어도 무해")

        // collisionmodel: lpoint ×1(castshadow:true) / 예산 point 1 · pointshadow 1 → 그대로.
        var b = SceneLightSlotBudget(try config("scenes/particleelementpreviews/collisionmodel/scene.json"))
        XCTAssertTrue(b.take(.point))
        XCTAssertTrue(b.takeShadow(.point), "동봉 유일 캐스터가 그림자를 잃으면 안 된다")
    }
}
