import Foundation
import XCTest
@testable import WapleCore

/// **오브젝트 id 중복 규약 — `objects[]` 배열 순서에서 앞이 이긴다(first-wins).**
///
/// 근거는 `SceneDocument.claimObjectID` 선언 주석이 VA 단위로 들고 있다. 요약:
/// 씬 로더(`0x140186c90`–`0x140188816`)는 중복 제거를 **하지 않고**(전건 `[scene+0x158]` push,
/// `0x140190842`), id 로 하나를 고르는 자리는 `Scene::findObjectById` `0x140196840` 하나뿐이며
/// 그것은 벡터를 **앞에서 뒤로** 훑어 첫 일치에서 멈춘다(`0x140196860`–`0x140196867`).
/// `parent` 해소 2차 패스(`0x140187fd2`–`0x140187fe7`)도 같고, id 집합 삽입
/// (`sub_140078250`)도 기존 키를 덮어쓰지 않는다(`0x14007831f`).
///
/// **형제 이름 주의(브리프 함정 8).** 패키지 엔트리 색인은 `adda85e` 가 확정한 대로
/// **뒤가 이긴다**(`ScenePackageWEParityTests` 가 그쪽을 잠근다). 오브젝트 id 는 반대다 —
/// 두 규약이 서로 반대라는 사실 자체를 이 파일이 잠근다.
///
/// 코퍼스 도달: 설치본 씬 문서 186개 / 오브젝트 294개에 중복 id **0건**이라 실물 대조는 불가능하다.
/// 그래서 이 테스트는 전부 **합성 씬**이고, 근거는 바이너리 단독이다.
final class SceneObjectIDDedupTests: XCTestCase {
    private let model = #"{"width":10,"height":10,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    /// 이미지 레이어가 실제로 만들어지려면 모델 json + 머티리얼이 패키지에 있어야 한다
    /// (`SceneDocumentTests` 와 같은 관례 — 없으면 `parseLayer` 가 nil 을 돌려 레이어가 사라진다).
    private let particle = #"{"renderer":[{"name":"sprite"}],"maxcount":1}"#

    private func parse(_ scene: String) throws -> SceneDocument {
        try SceneDocument.parse(package: try pkg([("scene.json", scene),
                                                  ("models/x.json", model),
                                                  ("materials/m.json", material),
                                                  ("particles/p.json", particle)]))
    }

    // MARK: 레이어끼리 중복 — 앞이 이긴다

    /// 같은 id 를 가진 레이어가 둘이고 자식이 그 id 를 부모로 삼는다.
    /// WE 는 **배열에서 먼저 나온** 레이어를 부모로 고른다 → 자식 월드는 (100, 50) 기준.
    /// 종전 Waple 은 `localT[l.id] = …` 무조건 대입이라 **뒤의** 레이어(1000, 500)가 이겼다.
    func testDuplicateLayerIDFirstInArrayWins() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"first","image":"models/x.json","origin":"100 50 0","scale":"1 1 1"},
           {"id":7,"name":"second","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertEqual(child.origin.x, 110, accuracy: 0.001, "앞의 id=7(100,50)이 부모여야 한다")
        XCTAssertEqual(child.origin.y, 70, accuracy: 0.001)
        // 중복 자체는 **제거되지 않는다** — WE 도 둘 다 만들어 둘 다 그린다(팩토리 전건 push).
        XCTAssertEqual(doc.layers.filter { $0.id == 7 }.count, 2,
                       "중복 id 오브젝트를 파스에서 버리면 안 된다(WE 는 둘 다 그린다)")
    }

    // MARK: 카테고리가 아니라 배열 위치가 이긴다

    /// 종전 규칙은 "레이어 > 노드" 였다(F437). WE 규칙은 "배열 순서" 다.
    /// 노드가 **앞**에 있으면 노드가 이긴다.
    func testEarlierNodeBeatsLaterLayerWithSameID() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"node-first","origin":"100 50 0","scale":"1 1 1"},
           {"id":7,"name":"layer-second","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertEqual(child.origin.x, 110, accuracy: 0.001, "앞의 노드(100,50)가 부모여야 한다")
        XCTAssertEqual(child.origin.y, 70, accuracy: 0.001)
    }

    /// 뒤집힌 배치 — 레이어가 앞이면 레이어가 이긴다(종전 규칙과 답이 같은 케이스.
    /// 두 테스트가 짝이어야 "배열 순서" 와 "카테고리 우선" 을 실제로 가른다).
    func testEarlierLayerBeatsLaterNodeWithSameID() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"layer-first","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":7,"name":"node-second","origin":"100 50 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertEqual(child.origin.x, 1010, accuracy: 0.001, "앞의 레이어(1000,500)가 부모여야 한다")
        XCTAssertEqual(child.origin.y, 520, accuracy: 0.001)
    }

    // MARK: 라이트 합성 경로도 같은 규약

    /// 배치를 **레이어 먼저**로 둔다. 빌더가 레이어 → 노드 순으로 돌기 때문에, 소유권 검사를
    /// 지우는 돌연변이는 이 배치에서만 답이 갈린다(노드가 레이어를 덮어쓴다). 노드 먼저 배치는
    /// `testEarlierNodeBeatsLaterLayerWithSameID` 가 덮는다.
    func testLightParentUsesFirstInArrayOnDuplicateID() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"layer-first","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":7,"name":"node-second","origin":"100 50 0","scale":"1 1 1"},
           {"id":2,"light":"lpoint","origin":"10 20 0","parent":7,"radius":10,"intensity":1}
         ]}
        """
        let doc = try parse(scene)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.origin.x, 1010, accuracy: 0.001, "앞의 레이어(1000,500)가 부모여야 한다")
        XCTAssertEqual(light.origin.y, 520, accuracy: 0.001)
    }

    // MARK: 가시성 상속도 같은 규약

    /// 같은 id 의 두 노드 중 **앞**이 보이면 자식은 숨지 않는다 — 종전에는 뒤의 항목이
    /// `parentOf` 를 덮어써서(그리고 카테고리 우선으로) 답이 달라질 수 있었다.
    func testVisibilityInheritanceUsesFirstInArrayOnDuplicateID() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"visible-first","origin":"0 0 0","scale":"1 1 1"},
           {"id":7,"name":"hidden-second","origin":"0 0 0","scale":"1 1 1","visible":false},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertFalse(child.hiddenByAncestor,
                       "앞의 id=7 이 보이므로 자식은 조상-은닉 대상이 아니다")
    }

    /// 대칭 케이스 — 숨은 쪽이 앞이면 자식이 숨는다.
    func testVisibilityInheritanceHidesWhenFirstDuplicateIsHidden() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"hidden-first","origin":"0 0 0","scale":"1 1 1","visible":false},
           {"id":7,"name":"visible-second","origin":"0 0 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertTrue(child.hiddenByAncestor,
                      "앞의 id=7 이 정적 비가시이므로 자식은 조상-은닉이다")
    }

    // MARK: id == 0 은 승자 경쟁에서 빠진다

    /// WE `sub_1401a38f0` 은 `asUInt64` 결과가 0 이면 저장을 건너뛴다(`0x1401a3964`) —
    /// 즉 `id:0` 은 "id 없음" 과 구분되지 않는다. 그러므로 id 0 짜리 오브젝트가 여럿이어도
    /// 서로의 트랜스폼을 빼앗지 않는다(그리고 `parent:0` 도 부모를 못 만든다).
    /// `"parent":0` 은 Waple 에서 **부모를 만들지 않는다**(id 0 이 소유권 경쟁에서 빠지므로
    /// `localT` 에 0 키가 없다 → 합성 안 함). WE 와의 차이는 아래 주석에 적었다.
    ///
    /// **WE 와 갈리는 자리(의도적 · 도달 0).** WE 의 `[obj+8]` 은 ctor 기본값이 0 이고
    /// `sub_1401a38f0` 이 0 을 저장하지 않으므로 **`id` 키가 없는 오브젝트도 id 가 0** 이다.
    /// 그래서 `parent:0` 은 로드 시점 해소(`0x1401de52c`)에서 "배열 앞쪽에 이미 만들어진,
    /// id 가 0 인 첫 오브젝트" 로 붙을 수 있다(로더 2차 패스는 `parent id == 0` 을 건너뛰므로
    /// — `0x140187fbd` — 재해소하지 않는다). 즉 **로드 순서에 의존하는 동작**이다.
    /// 설치본 186 씬 전수에서 `parent` 값은 `24` **2건뿐**이고 `parent:0` · `id:0` 은 **0건**이라
    /// 재현할 실물이 없다. 도달 0 인 기벽을 흉내 내는 대신 "부모 없음" 으로 고정하고 여기에 적어 둔다.
    func testParentZeroDoesNotBindToAnIDlessObject() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":0,"name":"idless","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":0,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertEqual(child.origin.x, 10, accuracy: 0.001, "parent:0 은 부모를 만들지 않는다(로컬 그대로)")
        XCTAssertEqual(child.origin.y, 20, accuracy: 0.001)
    }

    func testZeroIDObjectsDoNotClaimEachOther() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":0,"name":"a","image":"models/x.json","origin":"100 50 0","scale":"1 1 1"},
           {"id":0,"name":"b","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers[0].origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(doc.layers[1].origin.x, 1000, accuracy: 0.001)
    }

    // MARK: 텍스트 합성 경로(buildParentTransformMap)도 같은 규약

    /// `composeTextParentTransforms` 는 공용 헬퍼 `buildParentTransformMap` 을 쓴다 —
    /// 세 빌더가 같은 술어를 공유하는지 여기서 잠근다(사본이 다시 갈리면 이 테스트가 운다).
    func testTextParentUsesFirstInArrayOnDuplicateID() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"layer-first","image":"models/x.json","origin":"1000 500 0","scale":"1 1 1"},
           {"id":7,"name":"node-second","origin":"100 50 0","scale":"1 1 1"},
           {"id":9,"name":"t","text":"hi","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let t = try XCTUnwrap(doc.texts.first { $0.id == 9 })
        XCTAssertEqual(t.origin.x, 1010, accuracy: 0.001, "앞의 레이어(1000,500)가 부모여야 한다")
        XCTAssertEqual(t.origin.y, 520, accuracy: 0.001)
    }

    // MARK: 진 쪽이 남긴 parent 항목은 지워져야 한다

    /// 승자(부모 없음)가 **패자(부모 있음)보다 뒤에 순회**되는 배치. `parentOf[id] = parent` 를
    /// 조건부 대입(`if let`)으로 바꾸면 패자의 부모가 남아 자식이 할아버지까지 타고 올라간다.
    /// 순회 순서는 레이어 → 노드 → 텍스트라, 승자를 **노드**(order 1)로 패자를 **레이어**(order 2)로
    /// 두면 패자가 먼저 기록되고 승자가 덮어쓰는 경로를 지난다.
    func testLoserParentEntryIsCleared() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":8000,"height":8000}},
         "objects":[
           {"id":5,"name":"grandparent","origin":"1000 1000 0","scale":"1 1 1"},
           {"id":7,"name":"winner-node","origin":"100 50 0","scale":"1 1 1"},
           {"id":7,"name":"loser-layer","image":"models/x.json","origin":"0 0 0","parent":5,"scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":7,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        XCTAssertEqual(child.origin.x, 110, accuracy: 0.001, "승자 id=7 은 부모가 없다 — 조부모 1000 이 섞이면 안 된다")
        XCTAssertEqual(child.origin.y, 70, accuracy: 0.001)
        // 진 쪽 레이어는 **자기** 로컬(0,0) × 자기 부모(id 5, 1000/1000)로 합성돼야 한다.
        // 종전의 `world(자기 id)` 우회 형태는 `localT[7]` = 승자의 로컬을 자기 것으로 착각해
        // 진 쪽 레이어를 승자 좌표(100,50)로 끌어다 놓았다.
        let loser = try XCTUnwrap(doc.layers.first { $0.name == "loser-layer" })
        XCTAssertEqual(loser.origin.x, 1000, accuracy: 0.001, "진 쪽도 자기 로컬 × 자기 부모로 합성된다")
        XCTAssertEqual(loser.origin.y, 1000, accuracy: 0.001)
    }

    // MARK: 파티클이 부모 체인의 중간 마디일 때도 같은 규약

    func testParticleNodeParticipatesInIDOwnership() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":4000,"height":4000}},
         "objects":[
           {"id":7,"name":"hidden-group","origin":"0 0 0","scale":"1 1 1","visible":false},
           {"id":8,"name":"p","particle":"particles/p.json","origin":"0 0 0","parent":7,"scale":"1 1 1"},
           {"id":8,"name":"dup-node","origin":"0 0 0","scale":"1 1 1"},
           {"id":9,"name":"child","image":"models/x.json","origin":"10 20 0","parent":8,"scale":"1 1 1"}
         ]}
        """
        let doc = try parse(scene)
        let child = try XCTUnwrap(doc.layers.first { $0.id == 9 })
        // id=8 의 승자는 **앞의 파티클**이고 그 부모가 비가시 그룹 7 이므로 자식도 숨는다.
        // 종전 규칙(파티클이 마지막에 덮어씀)에서도 우연히 같은 답이 나올 수 있으므로,
        // 이 케이스의 값은 "파티클이 여전히 소유권 경쟁에 참여한다" 는 회귀 방지다.
        XCTAssertTrue(child.hiddenByAncestor)
    }
}
