import XCTest
import simd
@testable import WapleCore

/// 텍스트 오브젝트 **커서 히트 상자**의 순수 산술 잠금 (BD, 2026-08-21 — `docs/re/text-layer.md` §8b/§11.2).
///
/// 실물은 텍스트를 이미지와 **같은** 상자 함수 `0x14019dbb0` 에 넣고(히트 순회가 타입 1 과 4 를 같은
/// 분기로 모은다 — `0x14018a044`–`0x14018a050`), 그 함수가 읽는 크기가 `+0x2f0` 이다
/// (`0x14019dd8a` `mov rax, qword [rbx+0x2f0]`). 텍스트의 `+0x2f0` 은 vtable `0x140491950` 슬롯
/// `+0x110` = `0x140258900` 이 레이아웃마다 덮어쓰고, 그 함수 전체가 아래 식이다.
///
/// 여기서 잠그는 것은 그 식(`PointerHit.textHitSize`)과 패딩 게이트(`PointerHit.textPaddingActive`)다.
/// `SceneRenderer.buildPointerTargets` 의 텍스트 분기가 이 둘 + 그리기 경로의 `layerHitQuad` /
/// `textAlignmentString` 만으로 쿼드를 만든다(신규 수식 0개) — 그래서 회전·앵커 정합은 이미지 경로의
/// 기존 테스트가 이미 덮고, 새로 잠글 것이 이 파일의 산술이다.
final class TextLayerHitBoxTests: XCTestCase {

    // MARK: - 패딩 게이트 (`0x140258954`–`0x14025896d` 의 세 갈래 논리합)

    /// 게이트가 다 거짓이면 패딩 항이 **0** 이다 — `0x14025896f` 이 `[rsp+0x50]` 를 0 으로 깔고
    /// `xmm4`/`xmm3` 를 거기서 읽는다. 이것이 설치본·리포 동봉 코퍼스의 전건 경로다.
    func testAllGatesOffMeansTheHitBoxIsExactlyTheInkBox() {
        XCTAssertFalse(PointerHit.textPaddingActive(hasEffects: false, opaqueBackground: false,
                                                    colorBlendMode: 0))
        let box = PointerHit.textHitSize(inkBox: SIMD2<Float>(380, 118),
                                         padding: SIMD2<Float>(32, 32), paddingActive: false)
        XCTAssertEqual(box, SIMD2<Float>(380, 118), "게이트가 꺼지면 padding 값이 무엇이든 무시된다")
    }

    /// 세 게이트를 각각 하나씩. `colorBlendMode` 갈래는 **0 도 31 도 아닐 때만** 참이다
    /// (`0x1401e6f7a` `test eax,eax` → `0x1401e6f7e` `cmp eax,0x1f` → `0x1401e6f81` `jne` 로 `or`).
    func testPaddingGateMirrorsTheEngineThreeWayOr() {
        XCTAssertTrue(PointerHit.textPaddingActive(hasEffects: true, opaqueBackground: false,
                                                   colorBlendMode: 0), "이펙트 체인 존재(+0x320 > 0)")
        XCTAssertTrue(PointerHit.textPaddingActive(hasEffects: false, opaqueBackground: true,
                                                   colorBlendMode: 0), "opaquebackground(+0x594 bit1)")
        XCTAssertTrue(PointerHit.textPaddingActive(hasEffects: false, opaqueBackground: false,
                                                   colorBlendMode: 2), "오프스크린 합성(+0x304 bit4)")
        XCTAssertFalse(PointerHit.textPaddingActive(hasEffects: false, opaqueBackground: false,
                                                    colorBlendMode: 31),
                       "31 은 예외다 — 0 과 함께 `or` 를 건너뛴다(0x1401e6f7e)")
        XCTAssertFalse(PointerHit.textPaddingActive(hasEffects: false, opaqueBackground: false,
                                                    colorBlendMode: 0))
    }

    // MARK: - 크기 산술 (`0x1402589a9`–`0x1402589c1`)

    /// `xmm4 += xmm4` — 패딩은 **축마다 2배**로 들어간다(양쪽에 붙기 때문).
    func testPaddingIsAddedTwicePerAxis() {
        let box = PointerHit.textHitSize(inkBox: SIMD2<Float>(100, 40),
                                         padding: SIMD2<Float>(32, 8), paddingActive: true)
        XCTAssertEqual(box, SIMD2<Float>(100 + 64, 40 + 16))
    }

    /// `0x140258986` 의 `movss xmm0, [0x140492934]`(f32 512.0) + `minss` 두 번.
    func testPaddingIsClampedAt512PerAxis() {
        let box = PointerHit.textHitSize(inkBox: SIMD2<Float>(10, 10),
                                         padding: SIMD2<Float>(9999, 512), paddingActive: true)
        XCTAssertEqual(box, SIMD2<Float>(10 + 1024, 10 + 1024), "축당 min(padding,512) 의 2배")
    }

    /// **실물과 의도적으로 다르다.** 실물은 `minss`(상한)만 있어 음수 padding 이 상자를 줄인다.
    /// 좁히는 쪽으로 틀리면 그 텍스트에 붙은 스크립트가 커서 이벤트를 통째로 못 받으므로 하한 0 을 둔다.
    /// 도달 0(설치본 5/5 · 리포 동봉 3/3 전건 `"padding": 0`, 워크샵 정본 range `[0, 300]`).
    func testNegativePaddingNeverShrinksTheBox() {
        let box = PointerHit.textHitSize(inkBox: SIMD2<Float>(50, 20),
                                         padding: SIMD2<Float>(-40, -1), paddingActive: true)
        XCTAssertEqual(box, SIMD2<Float>(50, 20))
    }

    // MARK: - 코퍼스 실측 형상 (설치본 186씬 5오브젝트 · 리포 동봉 172씬 3오브젝트, 2026-08-21)

    /// 두 코퍼스의 텍스트는 전건 `"padding": 0`(스칼라) · `opaquebackground:false` · `effects` 없음 ·
    /// `colorBlendMode` 0 또는 부재다. 그래서 이 배선으로 **상자가 달라지는 오브젝트가 0건**이라는
    /// 사실을 파스에서 히트 상자까지 통째로 잠근다(스칼라 `0` 이 vec2 로 브로드캐스트되는 것 포함 —
    /// 실물 vec2 주입기 `0x1401a3fc0` 의 태그 1/2/3 브로드캐스트와 같은 규약).
    func testBundledCorpusShapeYieldsExactlyTheRasterBox() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":320,"height":180}},
         "objects":[{"id":231,"name":"label_coins","text":"00000","font":"fonts/Segment7Standard.otf",
                     "pointsize":64.0,"origin":"341.42999 185.12900 0.00000","scale":"0.057 0.057 0.057",
                     "anchor":"topright","horizontalalign":"right","verticalalign":"center",
                     "padding":0,"opaquebackground":false,"backgroundbrightness":1.0,
                     "limitrows":false,"maxrows":1,"limitwidth":false,"maxwidth":500.0}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let t = try XCTUnwrap(doc.texts.first)
        XCTAssertEqual(t.padding, Vec2(x: 0, y: 0), "스칼라 0 은 양축 브로드캐스트")
        XCTAssertTrue(t.effects.isEmpty)
        XCTAssertFalse(t.opaqueBackground)
        XCTAssertEqual(t.colorBlendMode, 0)
        XCTAssertTrue(t.isSolid, "solid 부재 = ctor 기본 true(bit13) → 히트 순회에 참가한다")

        let active = PointerHit.textPaddingActive(hasEffects: !t.effects.isEmpty,
                                                  opaqueBackground: t.opaqueBackground,
                                                  colorBlendMode: t.colorBlendMode)
        XCTAssertFalse(active)
        let raster = SIMD2<Float>(780, 291)   // 이 오브젝트의 저작 `size` 와 같은 자리(에디터 스냅샷)
        XCTAssertEqual(PointerHit.textHitSize(inkBox: raster,
                                              padding: SIMD2<Float>(t.padding.x, t.padding.y),
                                              paddingActive: active),
                       raster, "동봉/설치본 코퍼스에서는 배선 전후 상자가 한 픽셀도 안 바뀐다")
    }

    // MARK: - 상자 → 판정 (히트 쿼드까지 이어지는지)

    /// 패딩이 켜지면 잉크박스 **밖**의 점이 히트가 된다 — 넓어지는 방향이라 종전 전건 배달
    /// (`.geometryUnknown`)에서 좁혀질 때 스크립트가 죽는 실패를 만들지 않는다.
    func testPaddingWidensTheQuadSoEdgePointsStillHit() {
        let ink = SIMD2<Float>(100, 40)
        let padding = SIMD2<Float>(32, 32)
        let center = SIMD2<Float>(0, 0)
        let tight = PointerHit.Quad.layer(center: center,
                                          size: PointerHit.textHitSize(inkBox: ink, padding: padding,
                                                                       paddingActive: false),
                                          scale: SIMD2<Float>(1, 1), angleZ: 0)
        let padded = PointerHit.Quad.layer(center: center,
                                           size: PointerHit.textHitSize(inkBox: ink, padding: padding,
                                                                        paddingActive: true),
                                           scale: SIMD2<Float>(1, 1), angleZ: 0)
        let justOutside = SIMD2<Float>(70, 0)   // 잉크박스 반너비 50 밖, 패딩 반너비 82 안
        XCTAssertFalse(PointerHit.contains(tight, justOutside))
        XCTAssertTrue(PointerHit.contains(padded, justOutside))
        XCTAssertTrue(PointerHit.contains(tight, SIMD2<Float>(49, 19)), "잉크박스 안은 양쪽 다 히트")
    }

    /// 스케일은 상자 함수가 아니라 오브젝트 4×4 가 갖는다(`0x14019dde3`/`0x14019de31` 이 기저벡터에
    /// 곱한다) — Waple 도 `layerHitQuad` 가 `size × scale` 로 같은 자리에 곱한다. 패딩은 **스케일 전**
    /// 크기에 붙는다는 것을 잠근다(실물 `+0x2f0` 이 스케일 전 값이다 — `0x1402589b9`).
    func testPaddingAppliesBeforeScale() {
        let size = PointerHit.textHitSize(inkBox: SIMD2<Float>(100, 40),
                                          padding: SIMD2<Float>(10, 10), paddingActive: true)
        let q = PointerHit.Quad.layer(center: SIMD2<Float>(0, 0), size: size,
                                      scale: SIMD2<Float>(2, 2), angleZ: 0)
        XCTAssertEqual(q.axisX.x, 240, accuracy: 1e-4, "(100 + 2·10) × 2")
        XCTAssertEqual(q.axisY.y, 120, accuracy: 1e-4, "(40 + 2·10) × 2")
    }

    // MARK: - `limit*` 배선의 원천값 (BD 과제 ①)

    /// `SceneRenderer.sceneScriptLayers(from:)` 의 텍스트 블록이 이제 **값 멤버**를 읽는다
    /// (`d.maxRows = text.maxRowsValue` / `d.maxWidth = text.maxWidthValue`). 종전엔 계산 프로퍼티
    /// `text.maxRows`(게이트가 접힌 유효값)를 되읽어 `?? 1` 로 떨어뜨렸다 — 아래 `maxRows == nil` 이
    /// 바로 그 소실 지점이다. 실물은 게이트와 무관하게 저작값을 멤버에 싣는다(주입기 `0x1401a4930` /
    /// `0x1401a4b00` 이 `+0x594` 를 읽지 않는다).
    ///
    /// **한계(정직하게)**: 디스크립터 조립은 `WapleRender`(macOS 전용) 라 이 타깃에서 못 부른다.
    /// 여기서 잠그는 것은 조립부가 읽어야 하는 **원천값**이고, 조립부 자체의 잠금은
    /// `Tests/WapleRenderTests/SceneScriptAPISurfaceTests.swift` 쪽 몫이다(보고서 "넘길 것" 참조).
    func testUncheckedLimitValuesSurviveOnTheValueMembers() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"x","font":"systemfont_arial","pointsize":32,
                     "origin":"0 0 0","scale":"1 1","limitrows":false,"maxrows":9,
                     "limitwidth":false,"maxwidth":390}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let t = try XCTUnwrap(doc.texts.first)
        XCTAssertFalse(t.limitRows);  XCTAssertEqual(t.maxRowsValue, 9)
        XCTAssertFalse(t.limitWidth); XCTAssertEqual(t.maxWidthValue, 390)
        XCTAssertNil(t.maxRows, "소비 유효값은 nil — 조립부가 이걸 읽으면 9 가 1 로 접힌다")
        XCTAssertNil(t.maxWidth, "같은 이유로 390 이 500 으로 접힌다")
    }
}
