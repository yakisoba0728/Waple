import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// W1-yaxis: SceneRendererResources.rasterize() 의 verticalalign 앵커가 quadVertices/alignedCenter
/// 의 새 y-up 부호(top→+hh, bottom→−hh)와 정합해야 한다(textAlignmentString 주석의 "정확히 일치"
/// 불변). "bottom" 정렬은 origin 이 텍스트 박스의 시각적 하단이어야 하며, y-up 세계에서 "하단"은
/// scene-y 가 **작은** 쪽이므로 박스는 origin 기준 위(scene-y 증가 방향)로만 뻗어야 한다.
final class TextAnchorYAxisRegressionTests: XCTestCase {
    private func readVerts(_ buf: MTLBuffer, count: Int = 6) -> [SIMD4<Float>] {
        let ptr = buf.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func textPkg(verticalAlign: String, originY: Float) -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"text":"Hi","origin":"100 \(originY)","horizontalalign":"center",
                     "verticalalign":"\(verticalAlign)","pointsize":16}]}
        """
        return ScenePackage.assemble([(name: "scene.json", data: Data(scene.utf8))])
    }

    /// verticalalign="bottom": origin(scene-y=40)이 박스의 하단(scene-y 작은 쪽)이어야 — 모든 정점의
    /// scene-y(및 그 NDC)가 origin.y 이상이며, 박스가 확실히 위로 뻗어야 한다(퇴화 방지).
    func testBottomAlignAnchorsAtBottomExtendingUpward() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = textPkg(verticalAlign: "bottom", originY: 40)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let texts = renderer.buildTexts(doc: doc, package: p, device: device)
        guard let g = texts.first, let buf = g.vertexBuffer else { XCTFail("텍스트 래스터/버퍼 실패"); return }
        let verts = readVerts(buf)
        let originNDCy: Float = 40 / 200 * 2 - 1  // pxToNDC(y-up) — origin(40) 의 NDC y
        let ys = verts.map { $0.y }
        XCTAssertTrue(ys.allSatisfy { $0 >= originNDCy - 1e-3 },
                      "bottom 정렬은 박스가 origin 위로만 뻗어야(모든 정점 NDC y ≥ origin) — 실제: \(ys), origin=\(originNDCy)")
        XCTAssertGreaterThan(ys.max()!, originNDCy + 0.01, "박스 상단이 origin 보다 확실히 위여야(퇴화 방지)")
    }

    /// verticalalign="top": origin(scene-y=160)이 박스의 상단(scene-y 큰 쪽)이어야 — 모든 정점의
    /// NDC y 가 origin 이하이며, 박스가 아래로 뻗어야 한다(bottom 과 대칭).
    func testTopAlignAnchorsAtTopExtendingDownward() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = textPkg(verticalAlign: "top", originY: 160)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let texts = renderer.buildTexts(doc: doc, package: p, device: device)
        guard let g = texts.first, let buf = g.vertexBuffer else { XCTFail("텍스트 래스터/버퍼 실패"); return }
        let verts = readVerts(buf)
        let originNDCy: Float = 160 / 200 * 2 - 1
        let ys = verts.map { $0.y }
        XCTAssertTrue(ys.allSatisfy { $0 <= originNDCy + 1e-3 },
                      "top 정렬은 박스가 origin 아래로만 뻗어야(모든 정점 NDC y ≤ origin) — 실제: \(ys), origin=\(originNDCy)")
        XCTAssertLessThan(ys.min()!, originNDCy - 0.01, "박스 하단이 origin 보다 확실히 아래여야(퇴화 방지)")
    }

    /// uv(0,0)(텍스트 글리프 첫 행 — C1 로 정방향 확정) 이 화면 위쪽(NDC y 최댓값)에 와야 콘텐츠가
    /// 상하반전되지 않는다(quadVertices 코너 재페어링과 동형 규약).
    func testGlyphTopUVMapsToVisuallyTopVertex() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = textPkg(verticalAlign: "center", originY: 100)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let texts = renderer.buildTexts(doc: doc, package: p, device: device)
        guard let g = texts.first, let buf = g.vertexBuffer else { XCTFail("텍스트 래스터/버퍼 실패"); return }
        let verts = readVerts(buf)
        // 첫 삼각형의 첫 정점 = uv(0,0)(rasterize() 정의). 그 NDC y 가 전체 중 최댓값이어야.
        XCTAssertEqual(verts[0].z, 0, accuracy: 1e-6); XCTAssertEqual(verts[0].w, 0, accuracy: 1e-6)
        let maxY = verts.map { $0.y }.max()!
        XCTAssertEqual(verts[0].y, maxY, accuracy: 1e-5, "uv(0,0) 정점이 화면 최상단이어야(상하반전 방지)")
    }
}
