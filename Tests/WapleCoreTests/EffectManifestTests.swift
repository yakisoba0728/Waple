import XCTest
@testable import WapleCore

final class EffectManifestTests: XCTestCase {

    /// 중복 FBO 이름이 파스를 통과하고, **소비처가 그것으로 죽지 않아야** 한다.
    ///
    /// `EffectManifest` 는 치수만 8192 로 클램프하고 이름 유일성은 보지 않는다(설계상 그대로 둔다 —
    /// 파서는 파일이 말하는 것을 그대로 옮기는 게 맞다). 문제는 소비처였다:
    /// `SceneRendererResources.swift:573` 이 `Dictionary(uniqueKeysWithValues:)` 로 이름→인덱스
    /// 표를 만들면서 중복 키에 트랩했고, 그 줄이 `loadEffectManifest` 바로 다음이라
    /// **셰이더 해석보다 먼저** 터졌다. 매니페스트는 pkg 우선 조회라 워크샵 pkg 가 자체
    /// `effects/<name>/effect.json` 을 실으면 그대로 도달한다.
    ///
    /// 여기서는 파서가 중복을 보존하는지(= 소비처가 중복을 실제로 받게 되는지)를 고정한다.
    /// 소비처의 무트랩 규약은 같은 커밋에서 `uniquingKeysWith:` 로 바뀌었다.
    func testDuplicateFboNamesArePreservedForConsumers() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json","target":"_rt_Dup"}],
         "fbos":[{"name":"_rt_Dup","scale":1},{"name":"_rt_Dup","scale":4}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos.count, 2, "파서는 중복을 접지 않는다 — 접으면 소비처가 중복을 못 본다")
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_Dup", "_rt_Dup"])
        // 소비처가 쓰는 것과 같은 방식으로 표를 만들어도 트랩하지 않아야 한다(뒤가 이긴다).
        let index = Dictionary(m.fbos.enumerated().map { ($1.name, $0) },
                               uniquingKeysWith: { _, later in later })
        XCTAssertEqual(index["_rt_Dup"], 1, "중복 이름은 뒤 선언이 이겨야 한다")
    }
    /// 실물 localcontrast effect.json 구조 그대로.
    func testParsesPassesTargetsBindsFbos() throws {
        let json = """
        {"passes":[
           {"material":"materials/effects/a.json","target":"_rt_Q1",
            "bind":[{"name":"previous","index":0}]},
           {"material":"materials/effects/b.json","target":"_rt_Q2",
            "bind":[{"name":"_rt_Q1","index":0}]},
           {"material":"materials/effects/c.json",
            "bind":[{"name":"_rt_Q1","index":0},{"name":"previous","index":2}]}],
         "fbos":[
           {"name":"_rt_Q1","scale":4,"format":"rgba8888"},
           {"name":"_rt_Q2","scale":4}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 3)
        XCTAssertEqual(m.fbos.count, 2)
        XCTAssertEqual(m.fbos[0].name, "_rt_Q1")
        XCTAssertEqual(m.fbos[0].scale, 4)
        let p0 = m.passes[0]
        XCTAssertEqual(p0.material, "materials/effects/a.json")
        XCTAssertEqual(p0.target, "_rt_Q1")
        XCTAssertEqual(p0.binds.count, 1)
        XCTAssertEqual(p0.binds[0].name, "previous")
        XCTAssertEqual(p0.binds[0].index, 0)
        XCTAssertNil(m.passes[2].target, "target 부재 = 효과 출력")
        XCTAssertEqual(m.passes[2].binds[1].name, "previous")
        XCTAssertEqual(m.passes[2].binds[1].index, 2)
    }

    /// 단일 패스(shader 직지정 스타일)도 매니페스트로.
    func testSinglePassWithDirectShader() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 1)
        XCTAssertEqual(m.passes[0].shader, "effects/foo")
        XCTAssertNil(m.passes[0].material)
        XCTAssertTrue(m.fbos.isEmpty)
    }

    /// 실물 motionblur 의 command=copy 패스(셰이더 없이 source fbo → target fbo 지속).
    func testCopyCommandPass() throws {
        let json = #"{"passes":[{"material":"m.json","target":"_b2"},{"command":"copy","target":"_b1","source":"_b2"},{"material":"c.json"}],"fbos":[{"name":"_b1","scale":1},{"name":"_b2","scale":1}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 3)
        XCTAssertEqual(m.passes[1].command, "copy")
        XCTAssertEqual(m.passes[1].source, "_b2")
        XCTAssertEqual(m.passes[1].target, "_b1")
        XCTAssertNil(m.passes[1].material)
        XCTAssertNil(m.passes[0].command)
    }

    /// X-②: 실물 fluidsimulation `{"command":"swap","source":"_rt_SmokeVelocity1","target":"_rt_SmokeVelocity2"}`.
    func testSwapCommandPass() throws {
        let json = #"{"passes":[{"command":"swap","source":"_rt_V1","target":"_rt_V2"}],"fbos":[{"name":"_rt_V1","scale":1},{"name":"_rt_V2","scale":1}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes[0].command, "swap")
        XCTAssertEqual(m.passes[0].source, "_rt_V1")
        XCTAssertEqual(m.passes[0].target, "_rt_V2")
        XCTAssertNil(m.passes[0].material)
    }

    func testRejectsNegativeBindSlots() throws {
        let json = #"{"passes":[{"shader":"effects/foo","bind":[{"name":"previous","index":-1},{"name":"mask","index":0}]}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes[0].binds, [EffectManifest.Bind(name: "mask", index: 0)])
    }

    func testHugeFBOScaleDefaultsInsteadOfTrapping() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","scale":1e300}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos, [EffectManifest.FBO(name: "_rt", scale: 1)])
    }

    /// X-①: 실물 cursorripple `_rt_EightBuffer1/2` {fit:512} — 정사각 고정 크기(scale 무관).
    func testFBOFitParsedAsSquareFixedSize() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_EightBuffer1","fit":512,"format":"rgba8888"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos[0].fixedWidth, 512)
        XCTAssertEqual(m.fbos[0].fixedHeight, 512)
    }

    /// X-①: 실물 glitter `_rt_GlitterTiles` {width:256, height:256, uvs:"repeat"} — 비정사각도 지원 +
    /// 타일 아틀라스 랩 플래그.
    func testFBOWidthHeightAndUvsRepeatParsed() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_GlitterTiles","width":256,"height":128,"format":"r8","uvs":"repeat"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos[0].fixedWidth, 256)
        XCTAssertEqual(m.fbos[0].fixedHeight, 128)
        XCTAssertTrue(m.fbos[0].uvsRepeat)
    }

    /// scale 만 있으면 fixedWidth/fixedHeight 는 nil(종전 dst 비례 경로 무회귀).
    func testFBOWithoutFitOrSizeStaysScaleBased() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_Q","scale":4}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertNil(m.fbos[0].fixedWidth)
        XCTAssertNil(m.fbos[0].fixedHeight)
        XCTAssertFalse(m.fbos[0].uvsRepeat)
    }

    /// X-① 클램프: fit 의 신뢰불가 초대형 값(safeInt 범위 밖)은 scale 과 동일하게 무시(nil) —
    /// 트랩 없이 scale 기반 폴백으로 안전 낙하. 범위 안이지만 과대(>8192)한 값은 8192 로 클램프.
    func testHugeFBOFitDoesNotTrap() throws {
        let outOfRange = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":1e300}]}"#
        let m1 = try XCTUnwrap(EffectManifest.parse(Data(outOfRange.utf8)))
        XCTAssertNil(m1.fbos[0].fixedWidth)
        XCTAssertNil(m1.fbos[0].fixedHeight)

        let overCap = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":100000}]}"#
        let m2 = try XCTUnwrap(EffectManifest.parse(Data(overCap.utf8)))
        XCTAssertEqual(m2.fbos[0].fixedWidth, 8192)
        XCTAssertEqual(m2.fbos[0].fixedHeight, 8192)
    }

    // MARK: - X-⑧ fbos[].format / unique / clear (G-A5-05·06 / G-B2-02·03)

    /// 실물 `effects/fluidsimulation/effect.json` 의 fbos 선언 그대로(탭·공백까지 원문 형태).
    ///
    /// 이 넷이 **한 커밋에 같이** 가야 하는 이유가 여기 다 있다. 속도장은 `rg1616f`, 압력장은
    /// `r16f` 다 — 둘 다 **부호와 1.0 초과를 갖는 물리량**이라 종전의 rgba8Unorm([0,1] 클램프 +
    /// 8비트 양자화)으로는 원리적으로 못 담는다. 그리고 셋 다 `unique` + `clear` 라, 프레임을
    /// 넘겨 자기 직전 출력을 읽어야 하고 첫 프레임의 시작값이 정의돼 있어야 한다.
    /// 포맷만 고치고 지속을 안 고치면(또는 반대면) 유체는 여전히 안 돈다.
    func testFluidSimulationFboDeclarationsParseFormatUniqueAndClear() throws {
        let json = """
        {"passes":[{"material":"materials/effects/fluidsimulation/advect.json","target":"_rt_SmokeVelocity2"}],
         "fbos":[
          {"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokePressure1","fit":256,"format":"r16f","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokeDye1","fit":256,"format":"rgba_backbuffer","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokeCurl","fit":256,"format":"r16f","unique":true}
         ]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        let formats: [EffectManifest.FBO.Format] = [.rg1616f, .r16f, .rgbaBackbuffer, .r16f]
        XCTAssertEqual(m.fbos.compactMap(\.format), formats,
                       "format 문자열 4종이 전부 해석돼야 한다")
        XCTAssertEqual(m.fbos.compactMap(\.format).count, m.fbos.count, "미해석(nil)이 하나도 없어야 한다")
        XCTAssertTrue(m.fbos.allSatisfy(\.unique), "실물 유체 fbo 는 전건 unique 다")
        XCTAssertEqual(m.fbos.map { $0.clearColor != nil }, [true, true, true, false],
                       "clear 는 선언된 것만 — `_rt_SmokeCurl` 은 clear 가 없다")
        XCTAssertEqual(m.fbos[0].clearColor, SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(m.fbos[0].fixedWidth, 256, "fit 은 종전대로 정사각 고정 크기")
    }

    /// 실물 `effects/glitter/effect.json` — 단일 채널 아틀라스. `r8` 과 `uvs:"repeat"` 가 공존한다.
    func testGlitterTileAtlasParsesR8WithRepeatWrap() throws {
        let json = """
        {"passes":[{"material":"materials/effects/glitter/tiles.json","target":"_rt_GlitterTiles"}],
         "fbos":[{"name":"_rt_GlitterTiles","width":256,"height":256,"format":"r8","uvs":"repeat"}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        let f = try XCTUnwrap(m.fbos.first)
        XCTAssertEqual(f.format, .r8)
        XCTAssertTrue(f.uvsRepeat)
        XCTAssertFalse(f.unique, "unique 를 안 쓴 fbo 는 종전대로 풀에서 온다")
        XCTAssertNil(f.clearColor)
    }

    /// 미지 포맷 문자열은 **이펙트를 드롭하지 않는다** — nil 로 두고 소비처가 rgba8 로 간다.
    /// 미지 bind/target 을 폴백으로 처리한 G-A5-04 와 같은 정책이다.
    func testUnknownFormatStringFallsBackToNilRatherThanFailing() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json"}],
         "fbos":[{"name":"_rt_A","scale":1,"format":"bc7_srgb_from_the_future"},
                 {"name":"_rt_B","scale":1}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)), "미지 포맷이 파스를 죽이면 안 된다")
        XCTAssertEqual(m.fbos.count, 2)
        XCTAssertNil(m.fbos[0].format)
        XCTAssertNil(m.fbos[1].format, "format 키 부재도 nil")
    }

    /// `clear` 파스 — **원본 파서(`0x1401e7629`-`0x1401e7777`)에 맞춘다.**
    ///
    /// 처음 구현은 1/3/4 성분을 받고 콤마·탭도 구분자로 봤는데, 원본을 뜯어 보니 셋 다 달랐다.
    /// 이 테스트는 그 정정을 고정한다 — 관대한 쪽이 아니라 **원본과 같은 쪽**이 정답이다.
    func testClearColorParsingMatchesOriginalParser() {
        // 정상: 스페이스 구분 4성분.
        XCTAssertEqual(EffectManifest.parseClearColor("0 0 0 0"), SIMD4<Float>(0, 0, 0, 0))
        XCTAssertEqual(EffectManifest.parseClearColor("1 0.5 0.25 0.125"), SIMD4<Float>(1, 0.5, 0.25, 0.125))
        XCTAssertEqual(EffectManifest.parseClearColor("0  0   1 1"), SIMD4<Float>(0, 0, 1, 1),
                       "연속 스페이스는 빈 토큰을 만들지 않는다")

        // ③ 빈 문자열은 **클리어 안 함이 아니라 (0,0,0,0) 클리어**다(`0x1401e7641`).
        XCTAssertEqual(EffectManifest.parseClearColor(""), SIMD4<Float>(0, 0, 0, 0),
                       "원본은 빈 문자열에도 clear 비트를 세우고 4성분을 0 으로 채운다")

        // ② 4성분이 아니면 clear 비트 자체가 안 선다(`0x1401e777b` 로 빠진다).
        XCTAssertNil(EffectManifest.parseClearColor("0.5"), "1성분 그레이스케일 확장은 원본에 없다")
        XCTAssertNil(EffectManifest.parseClearColor("0.2 0.4 0.6"), "3성분 RGB+알파1 도 원본에 없다")
        XCTAssertNil(EffectManifest.parseClearColor("0 0"))
        XCTAssertNil(EffectManifest.parseClearColor("0 0 0 0 0"), "5성분")

        // ① 구분자는 스페이스뿐 — 콤마/탭은 구분자가 아니다(`cmp byte ptr [rdi], 0x20` 만 있다).
        XCTAssertNil(EffectManifest.parseClearColor("0,0,0,0"), "콤마 구분은 원본이 안 받는다")
        XCTAssertNil(EffectManifest.parseClearColor("0\t0\t0\t0"), "탭 구분도 안 받는다")

        // 타입/방어.
        XCTAssertNil(EffectManifest.parseClearColor("0 0 0 x"))
        XCTAssertNil(EffectManifest.parseClearColor(42), "문자열이 아닌 값 — 원본도 타입 태그 4(string)만 받는다")
        let absent: Any? = nil
        XCTAssertNil(EffectManifest.parseClearColor(absent))
        // 비유한값 거부는 원본에 없는 우리 방어다 — MTLClearColor 로 직행하는 값이라 막는다.
        XCTAssertNil(EffectManifest.parseClearColor("nan 0 0 0"))
        XCTAssertNil(EffectManifest.parseClearColor("inf 0 0 0"))
    }

    /// 원본은 `name` **또는** `format` 이 없으면 그 fbo 선언을 통째로 버린다
    /// (`0x1401e7440`/`0x1401e744f` → `jne 0x1401e7964`, 벡터에 push 안 함).
    /// 참조는 전부 이름 기반이고 이름→인덱스 변환이 루프 **뒤**에 일어나므로, 벡터가 압축돼도
    /// 어긋나지 않는다 — 우리 소비처도 이름 키 사전이라 같다.
    func testFboWithoutFormatKeyIsDroppedLikeTheOriginalParser() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json","target":"_rt_B"}],
         "fbos":[{"name":"_rt_NoFormat","scale":1},
                 {"name":"_rt_B","scale":1,"format":"rgba8888"},
                 {"scale":1,"format":"r8"}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_B"],
                       "format 없는 선언과 name 없는 선언이 둘 다 빠져야 한다")
    }

    /// 동봉 자산 전수 대조: 이 파서가 **실물에 나오는 포맷 문자열 5종을 전부** 안다.
    /// 하나라도 nil 로 떨어지면 그 fbo 는 조용히 rgba8 이 되므로, enum 누락을 여기서 잡는다.
    func testAllFormatStringsObservedInShippedAssetsAreKnown() {
        // 2026-08-20 실측 빈도: rgba8888 28 · rgba_backbuffer 13 · r16f 8 · rg1616f 4 · r8 2 (합 55 = 전건).
        let observed = ["rgba8888", "rgba_backbuffer", "r16f", "rg1616f", "r8"]
        for name in observed {
            XCTAssertNotNil(EffectManifest.FBO.Format(rawValue: name),
                            "동봉 자산이 실제로 쓰는 포맷 \(name) 을 enum 이 모른다")
        }
        // 표 자체는 동봉 자산이 아니라 **원본 바이너리**에서 왔다. `0x1401e53a0` 이 만드는 해시맵의
        // 19개 엔트리(소멸자 루프 `mov ebx, 0x13`, initializer_list 760 = 19 × 40) + 파서가 맵 조회
        // 전에 strcmp 로 가로채는 백버퍼 2종 = 21종. 동봉 5종만 넣으면 워크샵 저작이 쓰는 나머지가
        // 조용히 rgba8 로 떨어지므로 전부 싣는다.
        let originalTable = [
            "rgba8888", "rgb888", "rg88", "r8", "rgb565", "bc7", "dxt5", "dxt3", "dxt1",
            "rgba16161616f", "rgb161616f", "rg1616f", "r16f", "rgba16161616", "rgb161616",
            "rgba16161616S", "rgb161616S", "rgba8888s", "rgba1010102",
            "rgba_backbuffer", "rgb_backbuffer",
        ]
        XCTAssertEqual(originalTable.count, 21)
        XCTAssertEqual(Set(EffectManifest.FBO.Format.allCases.map(\.rawValue)), Set(originalTable),
                       "원본 표와 정확히 일치해야 한다 — 없는 걸 지어내지도, 있는 걸 빠뜨리지도 않는다")
        // 철자 함정: 16비트 SNORM 둘은 **대문자 S**, rgba8888s 는 **소문자 s**다(원본 .rdata 실측).
        XCTAssertNotNil(EffectManifest.FBO.Format(rawValue: "rgba16161616S"))
        XCTAssertNil(EffectManifest.FBO.Format(rawValue: "rgba16161616s"), "소문자 s 는 다른 문자열이다")
        XCTAssertNotNil(EffectManifest.FBO.Format(rawValue: "rgba8888s"))
        XCTAssertNil(EffectManifest.FBO.Format(rawValue: "rgba8888S"))
    }
}
