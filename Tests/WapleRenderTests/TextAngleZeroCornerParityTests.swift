import XCTest
@testable import WapleCore
@testable import WapleRender

/// W3-⑤(b) 검증 지적 대응: `encodeText`(`quadDirty = t.def.angleZ != 0`)가 정적 angleZ≠0 텍스트를
/// SceneRendererResources.rasterize() 의 정적(무회전) 래스터 경로에서 quadVertices() 동적 재계산
/// 경로로 갈아탄다 — 회전뿐 아니라 앵커/코너 산출 수식 자체가 바뀌므로, angleZ→0 극한에서 두 경로가
/// 정확히 같은 코너를 내지 않으면 미세각(코퍼스 실측 다수, 예 -0.02687rad) 텍스트가 "회전"이 아니라
/// "위치 이동"으로 나타난다. 이 테스트는 두 경로의 코너 산출식을 angleZ=0 에서 대수적으로 비교해
/// (Metal/렌더 불필요 — 순수 기하) 앵커가 정확히 일치함을 증명한다. non-center 정렬(9종 전 조합)
/// + 코퍼스 실측 튜플(2981249186/3352517853/2902406982) 포함.
final class TextAngleZeroCornerParityTests: XCTestCase {
    struct Tuple { let origin: Vec2; let size: Vec2; let scale: Vec2; let h: String; let v: String }

    /// SceneRendererResources.rasterize() 의 x0/y0/w/h 산출을 그대로 재현(정적 경로 정답지 — 회전 없음).
    private func staticCorners(_ t: Tuple, projW: Float, projH: Float) -> [SIMD2<Float>] {
        let w = t.size.x * t.scale.x, h = t.size.y * t.scale.y
        let x0: Float
        switch t.h {
        case "left": x0 = t.origin.x
        case "right": x0 = t.origin.x - w
        default: x0 = t.origin.x - w / 2
        }
        // W1-yaxis: y-up — y0 은 박스의 작은 쪽 scene-y(top 앵커는 origin 이 위쪽 변 = y0=origin−h).
        let y0: Float
        switch t.v {
        case "top": y0 = t.origin.y - h
        case "bottom": y0 = t.origin.y
        default: y0 = t.origin.y - h / 2
        }
        func ndc(_ x: Float, _ y: Float) -> SIMD2<Float> { SceneRenderer.pxToNDC(x, y, projW: projW, projH: projH) }
        // 실물 rasterize() 코너 순서와 동형: [tl, tr, br, bl] — tl = (x0, y0+h)(scene-y 큰 쪽 = 화면 위).
        return [ndc(x0, y0 + h), ndc(x0 + w, y0 + h), ndc(x0 + w, y0), ndc(x0, y0)]
    }

    /// quadVertices(angleZ: 0, ...) 의 4 코너(TL/TR/BR/BL) — encodeText 동적 경로가 실제로 쓰는 함수.
    private func dynamicCorners(_ t: Tuple, projW: Float, projH: Float) -> [SIMD2<Float>] {
        let align = SceneRenderer.textAlignmentString(h: t.h, v: t.v)
        let verts = SceneRenderer.quadVertices(origin: t.origin, size: t.size, scale: t.scale,
                                                            angleZ: 0, alignment: align,
                                                            projW: projW, projH: projH)
        // verts: [tl,tr,br,tl,br,bl] (두 삼각형 인터리브) — 고유 4코너만 추출.
        return [SIMD2(verts[0].x, verts[0].y), SIMD2(verts[1].x, verts[1].y),
                SIMD2(verts[2].x, verts[2].y), SIMD2(verts[5].x, verts[5].y)]
    }

    private func assertCornersMatch(_ t: Tuple, projW: Float = 3840, projH: Float = 2160,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let s = staticCorners(t, projW: projW, projH: projH)
        let d = dynamicCorners(t, projW: projW, projH: projH)
        for i in 0..<4 {
            XCTAssertEqual(s[i].x, d[i].x, accuracy: 1e-4, "corner \(i) x (\(t.h)/\(t.v))", file: file, line: line)
            XCTAssertEqual(s[i].y, d[i].y, accuracy: 1e-4, "corner \(i) y (\(t.h)/\(t.v))", file: file, line: line)
        }
    }

    /// 9점 앵커 전 조합(합성 — hw/hh 비대칭 입력으로 축별 독립성까지 커버).
    func testAllNineAnchorsMatchAtZeroAngle() {
        let origin = Vec2(x: 1234.5, y: 678.9)
        let size = Vec2(x: 240, y: 60)
        let scale = Vec2(x: 1.6, y: 0.8)   // 비대칭 스케일 — w/h 축 혼선 시 즉시 실패하도록.
        for h in ["left", "right", "center"] {
            for v in ["top", "bottom", "center"] {
                assertCornersMatch(Tuple(origin: origin, size: size, scale: scale, h: h, v: v))
            }
        }
    }

    /// 코퍼스 실측 미세각 텍스트(2981249186)의 실제 origin/size(rasterWidth·Height 대용)/scale/정렬 —
    /// right-align(비-center)이라 hw 의존 앵커 이동이 실제로 검증된다.
    func testRealCorpusRightAlignedMicroAngleTuple() {
        // id=79 "DAY"(2981249186): pointSize 18 폰트 래스터 폭 대용으로 임의 라스터 크기(90×24)를 쓴다
        // — 이 테스트의 목적은 실제 글리프 픽셀이 아니라 "hw/hh 가 무엇이든 두 경로가 같은 앵커를
        // 낸다"는 것이므로 rasterWidth/Height 의 정확한 값 자체는 무관(대수적 항등식).
        let t = Tuple(origin: Vec2(x: 3800.234, y: 322.43594), size: Vec2(x: 90, y: 24),
                     scale: Vec2(x: 1.14488, y: 1.13179), h: "right", v: "center")
        assertCornersMatch(t)
    }

    /// id=392 "Wednesday"(3352517853) — left-align.
    func testRealCorpusLeftAlignedMicroAngleTuple() {
        let t = Tuple(origin: Vec2(x: 1534.5658, y: 865.6686), size: Vec2(x: 220, y: 18),
                     scale: Vec2(x: 0.387004, y: 0.387004), h: "left", v: "center")
        assertCornersMatch(t)
    }

    /// id=197(3563096027) — left/top, maxWidth 워드랩(300-DPI 멀티라인 경로) 튜플 — rasterWidth/Height
    /// 가 300-DPI 배율로 커지는 경로에서도 두 식이 동일 hw/hh 를 공유하는지(더블스케일 회귀 가드).
    func testRealCorpusLeftTopWrappedMicroAngleTuple() {
        let t = Tuple(origin: Vec2(x: 1865.0, y: 330.0), size: Vec2(x: 800, y: 240),
                     scale: Vec2(x: 1.0, y: 1.0), h: "left", v: "top")
        assertCornersMatch(t)
    }
}
