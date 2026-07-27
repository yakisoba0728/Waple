import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// W3-⑤(b): 텍스트 오브젝트의 정적 angleZ(scene.json "angles" 의 z 성분 — 스크립트 없는 저작값) 렌더
/// 적용. 종전엔 SceneTextLayer 에 angleZ 필드 자체가 없어 encodeText 의 회전 변수가 항상 0 으로
/// 시작했고, 정적 회전 텍스트(3146703458 의 178° 등 6오브젝트)가 무회전으로 그려졌다.
final class TextStaticAngleRenderTests: XCTestCase {
    private func capture(scene: String, id: String) throws -> NSBitmapImageRep {
        let files: [(String, Data)] = [("scene.json", Data(scene.utf8))]
        let r = SceneRenderer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id + "_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 200, height: 200, times: [0.2], toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// (x,y) 를 중심으로 한 사각 영역에 밝은(글리프 잉크) 픽셀이 하나라도 있는지 — 개별 픽셀 하나만
    /// 보면 글리프의 획 사이 공백을 짚어 위양성/위음성이 날 수 있어 소영역 스캔으로 완화.
    private func hasInkNear(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, radius: Int = 8) -> Bool {
        for dx in stride(from: -radius, through: radius, by: 2) {
            for dy in stride(from: -radius, through: radius, by: 2) {
                guard let c = rep.colorAt(x: x + dx, y: y + dy) else { continue }
                if c.brightnessComponent > 0.3 { return true }
            }
        }
        return false
    }

    private func scene(angles: String) -> String {
        """
        {"general":{"orthogonalprojection":{"width":200,"height":200},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"name":"t","text":"M","font":"systemfont_arial","pointsize":8,
                     "color":"1 1 1","alpha":1,"horizontalalign":"left","verticalalign":"center",
                     "origin":"100 100 0","angles":"0 0 \(angles)"}]}
        """
    }

    /// 회귀 가드(무회전 sanity): angleZ=0 은 origin 기준 우측(left-align 이 늘어나는 방향)에 잉크,
    /// 좌측엔 잉크가 없어야 한다 — 아래 180° 테스트와 대조되는 베이스라인.
    func testZeroAngleRendersToTheRightOfOrigin() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let rep = try capture(scene: scene(angles: "0"), id: "waple_w3_5_angle0")
        XCTAssertTrue(hasInkNear(rep, 115, 100), "angleZ=0: origin 우측(115,100) 부근에 글리프가 있어야")
        XCTAssertFalse(hasInkNear(rep, 85, 100), "angleZ=0: origin 좌측(85,100) 에는 아무것도 없어야")
    }

    /// 실물 3146703458 축소판: 정적 angleZ≈178°(스크립트 없음)면 left-align 텍스트가 origin 기준
    /// 좌측으로 뒤집혀 그려져야 한다(피벗은 origin — alignedCenter 앵커 규약, quadVertices 재사용).
    func testStaticAngleZRotatesTextAboutOrigin() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let rep = try capture(scene: scene(angles: "3.14159265"), id: "waple_w3_5_angle180")
        XCTAssertTrue(hasInkNear(rep, 85, 100), "angleZ=π: 180° 회전으로 origin 좌측(85,100) 에 글리프가 와야")
        XCTAssertFalse(hasInkNear(rep, 115, 100), "angleZ=π: origin 우측(115,100) 은 이제 비어 있어야")
    }

    /// 검증 지적 대응(⑤b 변화 표면): `quadDirty = angleZ != 0` 가 극소각(코퍼스 실측, 예 -0.02687rad)
    /// 텍스트를 rasterize() 정적 경로에서 quadVertices() 동적 경로로 갈아탄다 — 회전 반영 자체가
    /// 아니라 "위치가 같이 튀지 않는가"가 관건. angleZ=0(정적 경로)과 angleZ=0.001(동적 경로, 회전
    /// 자체는 육안/잉크스캔 해상도 아래)의 잉크 위치가 동일 판정 범위 내에 있어야 한다 — 다르면
    /// 경로 전환 자체가 앵커를 이동시키는 회귀(TextAngleZeroCornerParityTests 의 대수 증명의 렌더 대조).
    func testMicroAngleDoesNotJumpFromStaticPath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let staticRep = try capture(scene: scene(angles: "0"), id: "waple_w3_5_angle_static")
        let microRep = try capture(scene: scene(angles: "0.001"), id: "waple_w3_5_angle_micro")
        // 정적 경로가 잉크를 낸 지점(우측)엔 동적 경로도 잉크가 있어야 하고, 비어있던 지점(좌측)은
        // 계속 비어 있어야 한다 — 극소 회전이 앵커를 옮기지 않았음을 렌더 레벨에서 재확인.
        XCTAssertTrue(hasInkNear(staticRep, 115, 100))
        XCTAssertTrue(hasInkNear(microRep, 115, 100), "angleZ=0.001: 정적 경로와 같은 위치(115,100)에 잉크가 있어야 — 경로 전환이 위치를 옮기면 안 됨")
        XCTAssertFalse(hasInkNear(microRep, 85, 100), "angleZ=0.001: origin 좌측은 여전히 비어 있어야")
    }
}
