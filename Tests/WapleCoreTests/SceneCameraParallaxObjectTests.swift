import XCTest
@testable import WapleCore

final class SceneCameraParallaxObjectTests: XCTestCase {
    /// 공통 오브젝트 표는 타입별 파서가 버리는 그룹/비가시 객체도 보존하고, parent id는 WE의
    /// first-wins 소유자에 연결해야 한다. 렌더러가 leaf 배열별로 이 규칙을 복제하면 안 된다.
    func testParsesCommonParallaxDescriptorsAndResolvesTopmostRootFirstWins() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100}},"objects":[
          {"id":10,"origin":"40 50 0","parallaxDepth":"0 0"},
          {"id":11,"parent":10,"origin":"30 0 0","parallaxDepth":"2 3"},
          {"id":10,"origin":"160 50 0","parallaxDepth":"1 1"},
          {"id":12,"parent":10,"origin":"-30 0 0","parallaxDepth":"4 5"}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.parallaxObjects.count, 4)
        XCTAssertEqual(doc.parallaxObjects[1].origin, Vec2(x: 30, y: 0))
        XCTAssertEqual(doc.parallaxObjects[1].depth, Vec2(x: 2, y: 3))

        let roots = doc.cameraParallaxRootsByOrder()
        XCTAssertEqual(roots[1]?.order, 0)
        XCTAssertEqual(roots[1]?.origin, Vec2(x: 40, y: 50))
        XCTAssertEqual(roots[1]?.depth, Vec2(x: 0, y: 0))
        XCTAssertEqual(roots[3]?.order, 0, "중복 id=10은 objects[] 앞 후보가 parent 승자")
    }

    /// cycle 방어를 정상 계층의 최대 깊이 제한으로 겸용하면 33단계부터 중간 노드를 root로 오판한다.
    /// parent 수에는 엔진 계약상 상한이 없으므로, 유한 그래프는 실제 최상위까지 전부 따라가야 한다.
    func testResolvesAcyclicParentChainsBeyondThirtyTwoLevels() throws {
        let objects = (0..<40).map { i -> String in
            let parent = i == 0 ? "" : ",\"parent\":\(i)"
            return "{\"id\":\(i + 1)\(parent),\"origin\":\"\(i) 0 0\",\"parallaxDepth\":\"\(i + 1) 1\"}"
        }.joined(separator: ",")
        let scene = "{\"general\":{\"orthogonalprojection\":{\"width\":200,\"height\":100}},\"objects\":[\(objects)]}"
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))

        let root = try XCTUnwrap(doc.cameraParallaxRootsByOrder()[39])
        XCTAssertEqual(root.order, 0)
        XCTAssertEqual(root.origin, Vec2(x: 0, y: 0))
        XCTAssertEqual(root.depth, Vec2(x: 1, y: 1))
    }
}
