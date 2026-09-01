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
         "fbos":[{"name":"_rt_Dup","scale":1,"format":"rgba8888"},{"name":"_rt_Dup","scale":4,"format":"rgba8888"}]}
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
           {"name":"_rt_Q2","scale":4,"format":"rgba8888"}]}
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
        let json = #"{"passes":[{"material":"m.json","target":"_b2"},{"command":"copy","target":"_b1","source":"_b2"},{"material":"c.json"}],"fbos":[{"name":"_b1","scale":1,"format":"rgba8888"},{"name":"_b2","scale":1,"format":"rgba8888"}]}"#
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
        let json = #"{"passes":[{"command":"swap","source":"_rt_V1","target":"_rt_V2"}],"fbos":[{"name":"_rt_V1","scale":1,"format":"rgba8888"},{"name":"_rt_V2","scale":1,"format":"rgba8888"}]}"#
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

    /// r3-O11: `bind` · `fbos` 도 `passes` 와 같은 **원소별 폴백**이어야 한다. 종전 두 배열은
    /// `as? [[String: Any]]` 배열 전체 캐스트라 원소 하나가 비객체면 그 배열이 통째로 비었다.
    func testMalformedBindAndFboElementsDropIndividually() throws {
        let json = """
        {"passes":[{"shader":"effects/foo",
                    "bind":["junk",{"name":"previous","index":0},7,{"name":"mask","index":1}]}],
         "fbos":["junk",{"name":"_rt_A","scale":1,"format":"rgba8888"},
                 42,{"name":"_rt_B","scale":2,"format":"rgba8888"}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes[0].binds,
                       [EffectManifest.Bind(name: "previous", index: 0),
                        EffectManifest.Bind(name: "mask", index: 1)],
                       "비객체 bind 원소만 드롭되고 나머지는 살아야")
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_A", "_rt_B"],
                       "비객체 fbo 원소만 드롭되고 나머지는 살아야")
    }

    func testHugeFBOScaleDefaultsInsteadOfTrapping() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","scale":1e300,"format":"rgba8888"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos, [EffectManifest.FBO(name: "_rt", scale: 1, format: .rgba8888)])
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
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_Q","scale":4,"format":"rgba8888"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertNil(m.fbos[0].fixedWidth)
        XCTAssertNil(m.fbos[0].fixedHeight)
        XCTAssertFalse(m.fbos[0].uvsRepeat)
    }

    /// X-① 클램프: fit 의 신뢰불가 초대형 값(safeInt 범위 밖)은 scale 과 동일하게 무시(nil) —
    /// 트랩 없이 scale 기반 폴백으로 안전 낙하. 범위 안이지만 과대(>8192)한 값은 8192 로 클램프.
    func testHugeFBOFitDoesNotTrap() throws {
        let outOfRange = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":1e300,"format":"rgba8888"}]}"#
        let m1 = try XCTUnwrap(EffectManifest.parse(Data(outOfRange.utf8)))
        XCTAssertNil(m1.fbos[0].fixedWidth)
        XCTAssertNil(m1.fbos[0].fixedHeight)

        let overCap = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":100000,"format":"rgba8888"}]}"#
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

    /// 두 가지가 **다르다**는 것을 고정한다. 처음 쓸 때 이 둘을 같은 것으로 묶었다가 틀렸다.
    ///
    /// ① `format` 이 **문자열인데 표에 없는 값** → 그 fbo 는 살아남고 `format` 만 nil 이다.
    ///    원본이 해시맵 miss 에서 0(rgba8888)을 돌려주는 것(`0x1401e546a`)과 같게, 소비처가
    ///    rgba8 로 폴백한다. 미지 bind/target 을 이펙트 드롭이 아니라 폴백으로 처리한
    ///    G-A5-04 와 같은 정책이다.
    /// ② `format` 키가 **아예 없다** → 그 fbo 선언을 통째로 버린다(`0x1401e744f`).
    ///    이건 폴백이 아니라 드롭이다 — 아래 별도 테스트가 본다.
    func testUnknownFormatStringSurvivesAsNilButMissingKeyDoesNot() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json"}],
         "fbos":[{"name":"_rt_A","scale":1,"format":"bc7_srgb_from_the_future"},
                 {"name":"_rt_B","scale":1}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)), "미지 포맷이 파스를 죽이면 안 된다")
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_A"],
                       "미지 문자열은 살아남고, 키 부재는 드롭된다")
        XCTAssertNil(m.fbos[0].format, "표에 없는 문자열은 nil — 소비처가 rgba8 로 간다")
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

    // MARK: - T09-D1 functions / T09-D2 passes[].compose

    /// 실물 `effects/fluidsimulation/effect.json` 의 `functions` 블록 그대로 + 그 블록이 참조하는
    /// fbo 선언들. 선행 스윕은 "Waple 이 이 블록을 안 읽는다" 를 **미확인**으로 남겼는데, 원본은
    /// 읽을 뿐 아니라 **소비한다** — 스크립트 `executeMaterialFunction(name)` 의 대상 테이블이다
    /// (등록 `0x1401f0156`/`0x1401f016c`, 구현 `0x1401ee3a0`–`0x1401ee51b`).
    ///
    /// 인덱스가 중요하다. 원본은 이름이 아니라 **파스된 fbo 목록의 인덱스**를 저장하고
    /// (`0x1401e8630`–`0x1401e867d`), 소비 시점에는 그 인덱스로 곧장 FBO 배열을 친다
    /// (`0x1401ee440`, stride 0x50). 그래서 우리도 파스 시점에 풀어 둔다.
    func testFluidSimulationFunctionsResolveToFboIndices() throws {
        let json = """
        {"passes":[{"material":"materials/effects/fluidsimulation_advection.json","target":"_rt_SmokeVelocity2"}],
         "fbos":[
          {"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokeVelocity2","fit":256,"format":"rg1616f","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokeDye1","fit":256,"format":"rgba_backbuffer","clear":"0 0 0 0","unique":true},
          {"name":"_rt_SmokeDye2","fit":256,"format":"rgba_backbuffer","clear":"0 0 0 0","unique":true}
         ],
         "functions":{
          "clearVelocity":{"action":"clear","fbos":["_rt_SmokeVelocity1","_rt_SmokeVelocity2"]},
          "clearDye":{"action":"clear","fbos":["_rt_SmokeDye1","_rt_SmokeDye2"]}
         }}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        // jsoncpp 객체는 std::map — `getMemberNames`(`0x1401e8272`)가 사전순을 준다.
        XCTAssertEqual(m.functions.map(\.name), ["clearDye", "clearVelocity"],
                       "원본 멤버 열거 순서(사전순)와 같아야 한다")
        XCTAssertEqual(m.functions.map(\.action), [.clear, .clear])
        XCTAssertEqual(m.function(named: "clearVelocity")?.fboIndices, [0, 1])
        XCTAssertEqual(m.function(named: "clearDye")?.fboIndices, [2, 3])
        XCTAssertNil(m.function(named: "clearPressure"), "선언 안 된 이름은 nil")
    }

    /// 항목을 **통째로 버리는** 조건 넷을 한 자리에 고정한다. 넷 다 원본이 `push` 를 건너뛰는
    /// 경로라, 관대하게 받으면 우리만 존재하지 않는 클리어를 돌게 된다.
    func testFunctionsDropEntriesTheOriginalParserRejects() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json"}],
         "fbos":[{"name":"_rt_A","scale":1,"format":"rgba8888"}],
         "functions":{
          "ok":{"action":"clear","fbos":["_rt_A"]},
          "notAnObject":["_rt_A"],
          "unknownAction":{"action":"blur","fbos":["_rt_A"]},
          "actionNotString":{"action":1,"fbos":["_rt_A"]},
          "missingAction":{"fbos":["_rt_A"]},
          "fbosNotArray":{"action":"clear","fbos":"_rt_A"},
          "fbosMissing":{"action":"clear"},
          "noneResolve":{"action":"clear","fbos":["_rt_Nope","_rt_AlsoNope"]},
          "emptyFbos":{"action":"clear","fbos":[]}
         }}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.functions.map(\.name), ["ok"], """
            원본이 버리는 것: 값이 객체가 아님(`0x1401e83f9`) · action 이 문자열 "clear" 가 아님
            (`0x1401e842d`/`0x1401e8454`/`0x1401e845a`) · fbos 가 배열이 아님(`0x1401e84df`) ·
            푼 인덱스가 0개(`0x1401e884a`)
            """)
        XCTAssertEqual(m.functions[0].fboIndices, [0])
    }

    /// 배열 원소 단위 규약 — **못 푼 이름과 문자열 아닌 원소는 그 원소만** 빠지고, 항목은 산다.
    /// (`0x1401e8593` 은 다음 원소로, `0x1401e867d` 는 인덱스 없이 다음 원소로 간다.)
    /// 그리고 인덱스는 **파스가 끝난** fbos 기준이라, format 없어 버려진 선언(X-⑧)만큼 당겨진다.
    func testFunctionFboListSkipsBadElementsAndIndexesTheSurvivingFboList() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json"}],
         "fbos":[{"name":"_rt_Dropped","scale":1},
                 {"name":"_rt_A","scale":1,"format":"rgba8888"},
                 {"name":"_rt_B","scale":1,"format":"r8"}],
         "functions":{"f":{"action":"clear","fbos":["_rt_Missing",7,null,"_rt_B","_rt_A"]}}}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_A", "_rt_B"], "전제: format 없는 선언은 드롭된다")
        XCTAssertEqual(m.function(named: "f")?.fboIndices, [1, 0],
                       "미지 이름·비문자열은 원소만 빠지고 순서는 선언 순서를 따른다")
    }

    /// T09-D2: `compose` 는 **진짜 boolean 만** 켠다(`0x1401e7dac` 의 `cmp byte [rax+8], 5`).
    /// `fbos[].unique` 와 같은 함정이다 — Swift 의 `1 as? Bool` 은 true 로 성공한다.
    func testComposeAcceptsOnlyRealBooleanTrue() throws {
        let json = """
        {"passes":[{"material":"a.json","compose":true},
                   {"material":"b.json","compose":false},
                   {"material":"c.json","compose":1},
                   {"material":"d.json","compose":"true"},
                   {"material":"e.json"}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.map(\.compose), [true, false, false, false, false],
                       "숫자 1 과 문자열 \"true\" 는 원본이 안 받는다")
    }

    /// 실물 `effects/refraction/effect.json` 의 형태 — 1패스가 compose, 2패스는 아니다.
    /// 원본에서 이 켜짐 하나가 ① 중간 렌더 타깃 +1(`0x1401e633f`·`0x1401e6345`)과
    /// ② 그 패스 직후 핑퐁 타깃 교체(`0x1401e9b8f`–`0x1401e9bf0`)를 만든다.
    func testRefractionShapedManifestKeepsComposeOnFirstPassOnly() throws {
        let json = """
        {"replacementkey":"refract",
         "passes":[{"material":"materials/effects/refract/refract.json","compose":true,
                    "bind":[{"name":"previous","index":0}]},
                   {"material":"materials/effects/refract/copy.json",
                    "bind":[{"name":"previous","index":0}]}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.map(\.compose), [true, false])
        XCTAssertEqual(m.replacementKey, "refract")
        XCTAssertTrue(m.functions.isEmpty, "functions 없는 이펙트는 빈 목록")
    }

    // MARK: - 동봉 자산 전건 회귀

    /// 동봉 `Sources/WapleRender/Resources/WEAssets/effects` 를 찾는다.
    /// `scripts/dev/linux-core-tests.sh` 는 테스트 소스를 **심링크로** 임시 패키지에 건다 —
    /// 그래서 `#filePath` 를 그대로 거슬러 오르면 리포 밖으로 나간다. 심링크를 먼저 푸는
    /// 이 방식은 `Model3DMeshFramingTests.mdlSearchRoots` 에서 이미 검증됐다.
    private static func bundledEffectsRoot() -> URL? {
        let fm = FileManager.default
        // 하네스가 넣어 주는 절대 경로를 먼저 본다(scripts/dev/linux-core-tests.sh).
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty {
            let cand = URL(fileURLWithPath: p).appendingPathComponent("effects")
            if fm.fileExists(atPath: cand.path) { return cand }
        }
        let here = (try? fm.destinationOfSymbolicLink(atPath: #filePath)) ?? #filePath
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets/effects")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// 동봉 `Resources/WEAssets/effects/**/effect.json` **122개 전건**을 실제로 파스한다.
    ///
    /// 목적이 셋이다.
    ///  ① 두 키를 새로 읽기 시작했으니 나머지 120개 스키마가 그대로인지 본다(스키마 실패 0건).
    ///  ② `functions`/`compose` 의 **실측 도달 수를 못박는다** — 자산이 갱신돼 도달이 늘면
    ///     여기서 깨져서 배선 여부를 다시 보게 된다.
    ///  ③ **CRLF 관용 구멍**(아래)을 수치로 고정한다.
    ///
    /// 파스 입력은 **CRLF→LF 정규화본**이다. 그래야 이 테스트가 재는 것이 "매니페스트 스키마"로
    /// 한정된다 — 원시 바이트로 재면 `AssetJSON.relaxed` 의 줄 주석 스키퍼가 `"\r\n"` 을 개행으로
    /// 못 알아보는 별건 버그(`EffectManifest.relaxedJSON` 주석의 2026-08-21 정정)에 가려진다.
    /// 그 별건은 아래에서 따로, 플랫폼 가정 없이 잰다.
    ///
    /// 2026-08-21 실측: `functions` 1개 파일(`fluidsimulation`), `compose` 2개 파일
    /// (`refraction` + 그 preview 사본 `refraction/preview/effects/refract`).
    func testEveryBundledEffectManifestParsesAndFunctionComposeReachIsPinned() throws {
        let root = try XCTUnwrap(Self.bundledEffectsRoot(), "동봉 WEAssets/effects 를 못 찾았다")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                                  includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "effect.json" }
            .sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 122, "동봉 effect.json 개수가 바뀌었다 — 아래 기대값도 다시 세라")

        var withFunctions: [String] = []
        var withCompose: [String] = []
        var schemaFailures: [String] = []
        /// CRLF 관용 구멍에 막혀 **원시 바이트로는** 파스가 안 되는 파일들. 정규화하면 전부 산다.
        var crlfBlocked: [String] = []
        var byName: [String: EffectManifest] = [:]
        for url in files {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let raw = try Data(contentsOf: url)
            let lf = Data(String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").utf8)
            guard let m = EffectManifest.parse(lf) else { schemaFailures.append(rel); continue }
            byName[rel] = m
            if EffectManifest.parse(raw) == nil { crlfBlocked.append(rel) }
            if !m.functions.isEmpty { withFunctions.append(rel) }
            if m.passes.contains(where: \.compose) { withCompose.append(rel) }
        }
        XCTAssertTrue(schemaFailures.isEmpty,
                      "CRLF 를 정규화하고도 못 읽는 매니페스트가 있으면 스키마 회귀다: \(schemaFailures)")
        XCTAssertEqual(withFunctions, ["fluidsimulation/effect.json"])
        XCTAssertEqual(withCompose, ["refraction/effect.json",
                                     "refraction/preview/effects/refract/effect.json"])

        // ③ CRLF 관용 구멍. 동봉 122개는 **전건 CRLF** 라, 줄 주석 스키퍼가 `"\r\n"` 을 개행으로
        //    못 알아보면 첫 주석부터 파일 끝까지 지워져 통째로 nil 이 된다(리눅스 실측 25건,
        //    macOS 는 트레일링 콤마도 엄격해 `fluidsimulation` 이 더해져 26건이었다).
        //    `AssetJSON.relaxed` 가 `isNewline` 을 쓰도록 고쳐 **0 으로 조였다**(2026-08-21).
        //    이 값이 다시 0 을 넘으면 그 회귀다.
        XCTAssertTrue(crlfBlocked.allSatisfy { byName[$0] != nil },
                      "정규화 후에도 못 읽으면 CRLF 문제가 아니다")
        XCTAssertEqual(crlfBlocked, [],
                       "원시 CRLF 바이트로 못 읽는 매니페스트 — AssetJSON.relaxed 회귀")

        // 도달한 1건의 내용까지 실물로 고정한다 — 인덱스는 선언 순서(9개 중 0·1 과 6·7)다.
        let fluid = try XCTUnwrap(byName["fluidsimulation/effect.json"])
        XCTAssertEqual(fluid.fbos.count, 9)
        XCTAssertEqual(fluid.functions.map(\.name), ["clearDye", "clearVelocity"])
        XCTAssertEqual(fluid.function(named: "clearDye")?.fboIndices, [6, 7])
        XCTAssertEqual(fluid.function(named: "clearVelocity")?.fboIndices, [0, 1])
        XCTAssertEqual(fluid.function(named: "clearDye")?.fboIndices.map { fluid.fbos[$0].name },
                       ["_rt_SmokeDye1", "_rt_SmokeDye2"])
        XCTAssertEqual(fluid.function(named: "clearVelocity")?.fboIndices.map { fluid.fbos[$0].name },
                       ["_rt_SmokeVelocity1", "_rt_SmokeVelocity2"])
        // 소비처가 쓰는 클리어 색은 fbo 선언에서 온다(`0x1401ee472`–`0x1401ee491`, movss 4개) — 넷 다 있어야 한다.
        for idx in [0, 1, 6, 7] {
            XCTAssertEqual(fluid.fbos[idx].clearColor, SIMD4<Float>(0, 0, 0, 0),
                           "\(fluid.fbos[idx].name) 의 clear 가 없으면 클리어 색이 정의되지 않는다")
        }

        // 도달한 2건의 compose 위치도 고정한다 — 둘 다 1패스만 compose 다.
        for rel in withCompose {
            XCTAssertEqual(byName[rel]?.passes.map(\.compose), [true, false], rel)
        }
    }

    // MARK: - 이펙트 패스 콤보 키의 대소문자 — `resolvePassCombos.canonical()` 제거 근거

    /// **2026-08-21: `SceneRendererResources.resolvePassCombos` 의 `canonical(_:)` 삭제를 지키는 잠금.**
    ///
    /// 그 헬퍼는 저작 콤보 키를 셰이더 `[COMBO]` **선언 이름 집합 안에서만** 대소문자 무시로
    /// 접었다. 지금은 `GLSLTranslator.translate` 진입의 `uppercasedComboKeys`(실물 파스 시점
    /// `toupper` 루프 `0x14015458c`–`0x1401545aa` 의 이행)가 **선언 유무와 무관하게 전건**을
    /// 접으므로 그 근사는 잉여다. 다만 렌더 계층은 리눅스에서 타입체크조차 안 되므로,
    /// 삭제가 안전한 **전제 조건**만 여기서 코어 레인에 못박는다.
    ///
    /// 전제: `resolvePassCombos` 가 실제로 보는 두 모집단에 **대문자가 아닌 콤보 키가 없다**.
    ///   · A = `effect.json passes[].material` 이 가리키는 머티리얼의 `passes[0].combos`
    ///   · B = 씬 `objects[].effects[].passes[].combos`
    /// 하나라도 소문자·혼합 키가 들어오면 여기서 깨지고, 그때는 `uppercasedComboKeys` 를
    /// `public` 으로 올려 이 함수에서 **딕셔너리별로** 접는 정본 수정안을 실행해야 한다
    /// (`SceneRendererResources.swift` 의 `resolvePassCombos` 주석 참조).
    ///
    /// 동봉 실측(2026-08-21): A **3종/7회** · B **24종/64회** · 소문자 0.
    /// 설치본 `assets`+`projects` 까지 넓히면 A 3종/14회 · B 25종/134회이고 역시 소문자 0이다
    /// (설치본은 CI 에 없어 여기서는 동봉만 잰다).
    func testEffectPassComboKeysAreAllUppercaseInBundledAssets() throws {
        let effects = try XCTUnwrap(Self.bundledEffectsRoot(), "동봉 WEAssets/effects 를 못 찾았다")
        let assets = effects.deletingLastPathComponent()          // …/WEAssets
        let fm = FileManager.default
        let walker = try XCTUnwrap(fm.enumerator(at: assets, includingPropertiesForKeys: nil))
        let jsons = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }

        func dict(_ url: URL) -> [String: Any]? {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return AssetJSON.dictionary(d)
        }

        var popA: [String: Int] = [:]      // 이펙트 머티리얼 combos
        var popB: [String: Int] = [:]      // 씬 이펙트 패스 combos
        for url in jsons {
            guard let j = dict(url) else { continue }
            if url.lastPathComponent == "effect.json" {
                for case let mp as [String: Any] in (j["passes"] as? [Any] ?? []) {
                    guard let rel = mp["material"] as? String else { continue }
                    // 이펙트-로컬 → 팩 루트 순(렌더러 `effectScopedData` 와 같은 순서).
                    let cands = [url.deletingLastPathComponent().appendingPathComponent(rel),
                                 assets.appendingPathComponent(rel)]
                    guard let hit = cands.first(where: { fm.fileExists(atPath: $0.path) }),
                          let m = dict(hit),
                          let p0 = (m["passes"] as? [Any])?.first as? [String: Any],
                          let cb = p0["combos"] as? [String: Any] else { continue }
                    for k in cb.keys { popA[k, default: 0] += 1 }
                }
            }
            for case let o as [String: Any] in (j["objects"] as? [Any] ?? []) {
                for case let e as [String: Any] in (o["effects"] as? [Any] ?? []) {
                    for case let ps as [String: Any] in (e["passes"] as? [Any] ?? []) {
                        guard let cb = ps["combos"] as? [String: Any] else { continue }
                        for k in cb.keys { popB[k, default: 0] += 1 }
                    }
                }
            }
        }

        XCTAssertEqual(popA.count, 3, "A 모집단(이펙트 머티리얼 combos) 종수가 바뀌었다: \(popA.keys.sorted())")
        XCTAssertEqual(popA.values.reduce(0, +), 7, "A 모집단 도수가 바뀌었다")
        XCTAssertEqual(popB.count, 24, "B 모집단(씬 이펙트 패스 combos) 종수가 바뀌었다: \(popB.keys.sorted())")
        XCTAssertEqual(popB.values.reduce(0, +), 64, "B 모집단 도수가 바뀌었다")
        // `DIRECTDRAW` 는 호출부가 **정확일치**로 조회하는 유일한 콤보다
        // (`SceneRendererResources.swift` 의 `combos["DIRECTDRAW"] == 1`) — 소문자로 저작되면
        // 번역기는 접어서 보는데 그 자리만 못 본다. 지금은 전건 대문자다.
        XCTAssertTrue(popB.keys.contains("DIRECTDRAW"), "DIRECTDRAW 가 B 모집단에서 사라졌다")

        let lower = (Array(popA.keys) + Array(popB.keys)).filter { $0 != $0.uppercased() }.sorted()
        XCTAssertTrue(lower.isEmpty,
                      "이펙트 패스 콤보에 대문자가 아닌 키가 생겼다 — resolvePassCombos 의 대소문자 접기를 "
                      + "되살려야 한다(정본 수정안은 그 함수 주석): \(lower)")
    }
}
