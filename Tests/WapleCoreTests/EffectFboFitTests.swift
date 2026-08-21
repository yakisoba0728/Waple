import XCTest
@testable import WapleCore

/// **W-FIT — `effect.json` 의 `fbos[].fit` 규약.**
///
/// 종전 Waple 은 `fit:N` 을 **N×N 정사각**으로 읽었다(`EffectManifest.parse` 가
/// `fixedWidth = fixedHeight = N`). 원본은 그렇지 않다 — `wallpaper64.exe`
/// `0x1401eb2cc`–`0x1401eb381` 이 **긴 변을 N 에 맞추고 종횡비를 보존하며 확대하지 않는다**.
/// 1920×1080 dst 에서 `fit:256` 은 **256×144** 다.
///
/// 규약 전문과 VA 근거는 `EffectManifest.FBO.fittedBox` 주석에 있다. 여기서는 그 규약의
/// **관측 가능한 결과**만 고정한다 — 특히 정사각으로 되돌리면 반드시 깨지는 자리들을.
///
/// 왜 이 파일이 따로인가: `EffectManifestTests` 는 "파스가 무엇을 담는가" 를 재고, 여기는
/// "담긴 값이 dst 를 만나 무슨 치수가 되는가" 를 잰다. 후자는 파스와 렌더 사이의 순수 함수라
/// 리눅스 레인에서 끝난다(WapleRender 는 Metal 전용이라 여기서 못 부른다).
final class EffectFboFitTests: XCTestCase {

    // MARK: - 헬퍼

    private func fbo(_ json: String) throws -> EffectManifest.FBO {
        let doc = #"{"passes":[{"shader":"effects/foo"}],"fbos":[\#(json)]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(doc.utf8)))
        return try XCTUnwrap(m.fbos.first)
    }

    /// 튜플은 `XCTAssertEqual` 이 안 받는다 — 한 줄로 비교하려고 배열로 편다.
    private func box(_ f: EffectManifest.FBO, _ w: Int, _ h: Int) -> [Int]? {
        guard let b = f.fittedBox(baseWidth: w, baseHeight: h) else { return nil }
        return [b.width, b.height]
    }

    // MARK: - W-FIT-2 major 선택 · 종횡비 보존

    /// 실물 `fluidsimulation` 의 속도/압력/발산/컬 6장이 전부 `fit:256` 이다.
    /// 가로 화면에서 **256×144**(16:9), 세로 화면에서 **144×256** 이어야 한다.
    ///
    /// 이 하나가 W1 의 본체다. 정사각이면 `aspect = g_Texture0Resolution.y/.x` 가
    /// 0.5625 대신 1.0 이 되어 중력·염료 에미터·커서 반경 셋이 동시에 어긋난다.
    func testFitKeepsAspectAndPicksLongerSideAsMajor() throws {
        let f = try fbo(#"{"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f"}"#)
        XCTAssertEqual(box(f, 1920, 1080), [256, 144], "가로 16:9 — 긴 변(너비)이 256")
        XCTAssertEqual(box(f, 1080, 1920), [144, 256], "세로 9:16 — 긴 변(높이)이 256")
        XCTAssertEqual(box(f, 2560, 1440), [256, 144], "같은 종횡비면 dst 가 달라도 같은 치수")
        XCTAssertEqual(box(f, 3440, 1440), [256, 107], "21:9 울트라와이드 — 1440/3440*256 = 107.16 → 107")
        XCTAssertEqual(box(f, 256, 256), [256, 256], "정사각 dst 에서만 정사각이 나온다")
    }

    /// `W == H` 는 원본에서 너비 분기로 간다(`0x1401eb30c` 의 `jb` 는 **미만**일 때만 튄다).
    /// 두 분기의 답이 같으므로 관측으로는 구별되지 않는다 — 그 사실 자체를 고정한다.
    func testSquareBaseIsBranchIndependent() throws {
        let f = try fbo(#"{"name":"_rt","fit":100,"format":"rgba8888"}"#)
        XCTAssertEqual(box(f, 640, 640), [100, 100])
    }

    // MARK: - W-FIT-3 확대 금지

    /// 실물 `cursorripple` 의 `_rt_EightBuffer1/2` 가 `fit:512` 다. 동봉 preview 씬은
    /// **256×256 레이어**라, 확대 금지가 걸려 512 가 아니라 **256** 이 나와야 한다.
    /// 종전 정사각 규약은 여기서 512×512 를 만들었다 — 동봉 자산에서 **실제로 도달하는**
    /// 유일한 치수 변화다.
    func testFitNeverEnlargesBeyondTheSource() throws {
        let f = try fbo(#"{"name":"_rt_EightBuffer1","fit":512,"format":"rgba8888"}"#)
        XCTAssertEqual(box(f, 256, 256), [256, 256], "확대 금지 — 512 로 키우지 않는다")
        XCTAssertEqual(box(f, 1920, 1080), [512, 288], "여유가 있으면 봉투대로 줄인다")
        XCTAssertEqual(box(f, 400, 300), [400, 300], "긴 변이 봉투보다 작으면 dst 그대로")
        // 짧은 변도 원본을 넘지 않는다(명시 클램프는 긴 변에만 있고 짧은 변은 수학적 귀결).
        for (w, h) in [(1920, 1080), (256, 256), (400, 300), (100, 900)] {
            let b = try XCTUnwrap(box(f, w, h))
            XCTAssertLessThanOrEqual(b[0], w, "너비가 원본을 넘었다 (\(w)x\(h))")
            XCTAssertLessThanOrEqual(b[1], h, "높이가 원본을 넘었다 (\(w)x\(h))")
        }
    }

    // MARK: - W-FIT-1 절단 · 하한

    /// 짧은 변은 float32 비율 곱의 **0 방향 절단**이다(`cvttss2si`, `0x1401eb33b`).
    /// 반올림이면 34, 절단이라 33 이다.
    func testMinorSideTruncatesTowardZero() throws {
        let f = try fbo(#"{"name":"_rt","fit":100,"format":"rgba8888"}"#)
        XCTAssertEqual(box(f, 1000, 333), [100, 33], "333/1000*100 = 33.3 → 33 (반올림이면 33)")
        XCTAssertEqual(box(f, 1000, 339), [100, 33], "339/1000*100 = 33.9 → **33** — 반올림이면 34")
        XCTAssertEqual(box(f, 1000, 999), [100, 99], "99.9 → 99")
    }

    /// 짧은 변이 0 으로 절단되는 극단에서도 **0 이나 음수가 나가지 않는다** —
    /// 0 은 `makeTexture` 에서 죽는다. (원본 하한은 2, 여기는 1 — 의도적 편차는
    /// `FBO.fittedBox` 주석 참조.)
    func testDegenerateRatiosNeverProduceZeroOrNegativeDimensions() throws {
        let f = try fbo(#"{"name":"_rt","fit":1,"format":"rgba8888"}"#)
        XCTAssertEqual(box(f, 4, 4000), [1, 1], "4/4000*1 = 0.001 → 0 → 하한 1")
        XCTAssertEqual(box(f, 4000, 4), [1, 1])
        // 신뢰 경계 밖 dst — 0/음수/거대값이 와도 계산이 성립하고 결과는 양수다.
        let g = try fbo(#"{"name":"_rt","fit":256,"format":"rgba8888"}"#)
        for (w, h) in [(0, 0), (-1, -1), (1, 1), (Int.max, Int.max), (Int.min, 1080)] {
            let b = try XCTUnwrap(box(g, w, h), "fit 이 선언돼 있으면 항상 값이 나와야 한다")
            XCTAssertGreaterThanOrEqual(b[0], 1, "치수가 0 이하다 (\(w)x\(h))")
            XCTAssertGreaterThanOrEqual(b[1], 1, "치수가 0 이하다 (\(w)x\(h))")
        }
    }

    // MARK: - W-FIT-4 `scale` 과의 합성

    /// 원본은 `fit` 으로 정한 "full" 크기를 렌더타깃 생성자에 넘기고, 생성자가 **그 뒤에**
    /// `scale` 로 나눈다(`0x1400d2c9b`–`0x1400d2ce4`). 즉 경쟁이 아니라 합성이다.
    /// 동봉+설치본 FBO 선언 112건(동봉 55 + 설치본 57) 중 동시 선언은 0건이라 **실측 도달이 없다** —
    /// 규약만 고정한다.
    func testFitAndScaleCompose() throws {
        let f = try fbo(#"{"name":"_rt","fit":256,"scale":2,"format":"rgba8888"}"#)
        XCTAssertEqual(box(f, 1920, 1080), [128, 72], "fit 로 256x144 → scale 2 로 128x72")
        let g = try fbo(#"{"name":"_rt","fit":256,"scale":8,"format":"rgba8888"}"#)
        XCTAssertEqual(box(g, 1920, 1080), [32, 18])
    }

    /// `width`/`height` 가 선언돼 있으면 그 값이 `fit` 의 **입력**을 갈아치운다
    /// (`0x1401eb2e3`/`0x1401eb2f4` — dst 대신 선언값이 비교 대상이 된다). 그래서 major 판정도
    /// 선언값으로 한다. 동봉·설치본 도달 0건.
    func testDeclaredWidthHeightFeedTheFitInput() throws {
        let f = try fbo(#"{"name":"_rt","fit":256,"width":1024,"format":"rgba8888"}"#)
        // W=1024(선언), H=1080(dst) → H 가 major → H'=256, W'=1024/1080*256 = 242.7 → 242
        XCTAssertEqual(box(f, 1920, 1080), [242, 256])
        let g = try fbo(#"{"name":"_rt","fit":256,"width":1024,"height":512,"format":"rgba8888"}"#)
        // dst 를 전혀 안 본다 — 1024x512 가 입력이라 256x128.
        XCTAssertEqual(box(g, 1920, 1080), [256, 128])
        XCTAssertEqual(box(g, 100, 100), [256, 128], "선언값이 있으면 dst 와 무관하다")
    }

    // MARK: - 무회귀: `fit` 미선언은 종전 그대로

    /// `fit` 이 없으면 `fittedBox` 는 **nil** 을 준다 — 소비처가 종전 경로
    /// (`fixedWidth ?? dst/scale`)를 그대로 타야 하기 때문이다. 동봉+설치본 FBO 선언 112건 중
    /// `fit` 은 28건뿐이고 나머지는 전부 이 갈래다.
    func testWithoutFitTheBoxIsNilSoConsumersKeepTheOldPath() throws {
        let scaleOnly = try fbo(#"{"name":"_rt_Q","scale":4,"format":"rgba8888"}"#)
        XCTAssertNil(box(scaleOnly, 1920, 1080))
        XCTAssertNil(scaleOnly.fit)
        XCTAssertNil(scaleOnly.fixedWidth)
        XCTAssertNil(scaleOnly.fixedHeight)

        // 실물 glitter `_rt_GlitterTiles` — width/height 만, fit 없음.
        let wh = try fbo(#"{"name":"_rt_GlitterTiles","width":256,"height":256,"format":"r8","uvs":"repeat"}"#)
        XCTAssertNil(box(wh, 1920, 1080), "width/height 만이면 fit 경로를 타지 않는다")
        XCTAssertEqual(wh.fixedWidth, 256)
        XCTAssertEqual(wh.fixedHeight, 256)

        // 아무것도 없으면 셋 다 nil(= dst/scale).
        let bare = try fbo(#"{"name":"_rt","format":"rgba8888"}"#)
        XCTAssertNil(bare.fit)
        XCTAssertNil(bare.declaredWidth)
        XCTAssertNil(bare.declaredHeight)
        XCTAssertNil(box(bare, 1920, 1080))
    }

    /// 하위호환 표현의 **함정**을 고정한다: `fit` 만 있는 FBO 의 `fixedWidth/fixedHeight` 는
    /// 정사각 **봉투**이지 치수가 아니다. 이 둘을 치수로 쓰면 W1 이 되살아난다.
    func testLegacyFixedSizeMirrorsTheEnvelopeNotTheResult() throws {
        let f = try fbo(#"{"name":"_rt","fit":256,"format":"rgba8888"}"#)
        XCTAssertEqual(f.fixedWidth, 256)
        XCTAssertEqual(f.fixedHeight, 256)
        let envelope = [try XCTUnwrap(f.fixedWidth), try XCTUnwrap(f.fixedHeight)]
        XCTAssertNotEqual(box(f, 1920, 1080), envelope,
                          "봉투를 치수로 쓰면 정사각으로 되돌아간다 — 소비처는 fittedBox 를 써야 한다")
    }

    /// 신뢰 경계 밖 `fit` 값이 트랩 없이 접히는지(종전 `EffectManifestTests` 의 클램프 규약을
    /// 치수 쪽에서 다시 본다). 8192 클램프 뒤에도 확대 금지가 다시 덮으므로 dst 그대로다.
    func testHostileFitValuesFoldToTheSourceSize() throws {
        let over = try fbo(#"{"name":"_rt","fit":100000,"format":"rgba8888"}"#)
        XCTAssertEqual(over.fit, 8192, "8192 클램프")
        XCTAssertEqual(box(over, 1920, 1080), [1920, 1080], "확대 금지가 다시 덮는다")
        let huge = try fbo(#"{"name":"_rt","fit":1e300,"format":"rgba8888"}"#)
        XCTAssertNil(huge.fit, "safeInt 범위 밖 — 미선언으로 낙하")
        XCTAssertNil(box(huge, 1920, 1080))
        let boolish = try fbo(#"{"name":"_rt","fit":true,"format":"rgba8888"}"#)
        XCTAssertNil(boolish.fit, "boolean 은 fit 이 아니다")
    }

    // MARK: - 의도적 편차: 하한이 원본 2 가 아니라 1 이다

    /// **편차가 관측되는 구간을 정확히 못박는다(2026-08-21 재확인).**
    ///
    /// 원본은 렌더타깃 생성자가 축마다 `max(2, full/scale)` 을 건다(`0x1400d2cac` / `0x1400d2ccc`,
    /// 리사이즈 경로 `0x140161f83`–`0x140161f9e`). Waple 의 `fittedBox` 는 `max(1, ·)` 이다
    /// (사유는 `FBO.fittedBox` 주석의 "의도적 편차"). 두 값이 갈리는 **필요충분조건**은
    /// "그 축의 계산 결과가 0 또는 1" 이다. `fit` FBO 는 코퍼스 전건이 `scale` 미선언(=1)이므로
    /// (`fit`+`scale` 동시 선언 0건, 아래 전수 테스트가 지킨다) 갈리는 축은 **파생되는 짧은 변**
    /// 뿐이고, 조건은 `trunc(minor/major × min(fit,major)) ≤ 1` 이다.
    ///
    /// 긴 변은 `min(fit, major)` 이고 `fit ≥ 1`·`major ≥ 1` 이라 **항상 ≥ 1** 이며
    /// (dst 는 `max(4, ·)` 로, `width`/`height` 선언은 `max(1, ·)` 로 하한이 걸린다),
    /// 원본과 갈리려면 `min(fit, major) == 1` 이어야 한다 — 그 경우도 여기서 같이 고정한다.
    func testLowerBoundDeviationBoundaryIsTheDerivedShortSide() throws {
        let f = try fbo(#"{"name":"_rt","fit":256,"format":"rgba8888"}"#)
        // 경계 바로 위/아래를 float32 산술 그대로 짚는다(정수 `minor*fit/major` 로는 재현 못 한다).
        XCTAssertEqual(box(f, 1920, 16), [256, 2], "16/1920×256 = 2.133 → 2 — 하한과 무관, 원본과 동일")
        XCTAssertEqual(box(f, 1920, 15), [256, 2], "15/1920×256 = 2.0 정확 → 2 — 여기까지 원본과 동일")
        XCTAssertEqual(box(f, 1920, 14), [256, 1], "14/1920×256 = 1.866 → 1 — **여기부터 편차**(원본 2)")
        XCTAssertEqual(box(f, 1920, 4), [256, 1], "4/1920×256 = 0.533 → 0 → 하한 1(원본 2)")
        // 종횡비로 다시 쓰면 `major:minor` 가 `fit/2 : 1` 보다 극단일 때다 — fit 256 이면 128:1.
        XCTAssertEqual(box(f, 1280, 10), [256, 2], "128:1 정확 — 아직 아니다")
        XCTAssertEqual(box(f, 1280, 9), [256, 1], "142:1 — 편차 구간")
        // 긴 변 쪽 편차는 `fit == 1` 이라는 병리 입력에서만 난다.
        let one = try fbo(#"{"name":"_rt","fit":1,"format":"rgba8888"}"#)
        XCTAssertEqual(box(one, 1920, 1080), [1, 1], "원본이면 2x2 — fit:1 은 코퍼스 0건")
    }

    /// **동봉+설치 코퍼스에서 그 편차 구간에 닿는 자리가 하나도 없다**는 재확인(2026-08-21).
    ///
    /// `fit` 을 선언한 이펙트는 `fluidsimulation`(256) · `cursorripple`(512) 두 종뿐이고,
    /// 그 둘을 **쓰는** 씬은 각자의 `preview/scene.json` 4건(동봉 2 + 설치본 2)이며 전부
    /// **256×256 정사각 레이어**다(`size:"256 256"`, `orthogonalprojection 256×256`,
    /// `scale:"1 1 1"`). 정사각이면 `minor == major` 라 짧은 변도 `min(fit, 256)` 이므로
    /// 256 또는 256 — 하한 근처에 **64배 이상** 여유가 있다.
    ///
    /// 여기서는 그 site 기하와 실사용 디스플레이 기하 전부에서 **양 축이 2 이상**임을 지킨다.
    /// 하나라도 2 미만이 되면 하한 편차가 관측 가능해지므로 `fittedBox` 의 `max(1,·)` 를
    /// 원본대로 `max(2,·)` 로 올릴지 다시 판단해야 한다.
    func testLowerBoundDeviationHasNoCorpusReach() throws {
        let geometries: [(Int, Int)] = [
            (256, 256),      // 동봉/설치 실사용 site 4건 전부
            (1920, 1080), (1080, 1920), (2560, 1440), (3840, 2160), (3440, 1440),
            (1366, 768), (5120, 1440),   // 32:9 슈퍼울트라와이드
        ]
        for fit in [256, 512] {
            let f = try fbo(#"{"name":"_rt","fit":\#(fit),"format":"rgba8888"}"#)
            for (w, h) in geometries {
                let b = try XCTUnwrap(f.fittedBox(baseWidth: w, baseHeight: h))
                XCTAssertGreaterThanOrEqual(b.width, 2, "fit:\(fit) @ \(w)x\(h) 폭이 하한 편차 구간에 들어갔다")
                XCTAssertGreaterThanOrEqual(b.height, 2, "fit:\(fit) @ \(w)x\(h) 높이가 하한 편차 구간에 들어갔다")
            }
        }
        // 실사용 site 기하에서의 실제 답도 같이 못박는다(여유가 얼마나 되는지가 판단 근거다).
        let fluid = try fbo(#"{"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f"}"#)
        XCTAssertEqual(box(fluid, 256, 256), [256, 256], "하한 1 과 128배 여유")
        let ripple = try fbo(#"{"name":"_rt_EightBuffer1","fit":512,"format":"rgba8888"}"#)
        XCTAssertEqual(box(ripple, 256, 256), [256, 256], "확대 금지로 256 — 하한 1 과 128배 여유")
    }

    // MARK: - 동봉 자산 전수 — `fit` 을 쓰는 FBO 를 하나도 빠뜨리지 않는다

    private static func bundledEffectsRoot() -> URL? {
        let fm = FileManager.default
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

    /// 동봉 `effect.json` 전건에서 `fit` 보유 FBO 를 **세고**, 1920×1080 dst 에서의 치수를
    /// 이름별로 못박는다. 자산이 갱신돼 `fit` 이 늘면 여기서 깨져 이 표를 다시 세게 된다.
    ///
    /// 2026-08-21 실측(동봉 122파일 · FBO 선언 55건): `fit` 보유 **14건**, 이펙트 **2종**
    /// (`fluidsimulation` 본체 6 + preview 사본 6, `cursorripple` 본체 2).
    /// `fit` 과 `scale`(또는 `width`/`height`)을 **동시에** 선언한 FBO 는 0건이다.
    func testBundledFitDeclarationsAreEnumeratedAndSized() throws {
        let root = try XCTUnwrap(Self.bundledEffectsRoot(), "동봉 WEAssets/effects 를 못 찾았다")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: nil))
        let files = walker.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "effect.json" }
            .sorted { $0.path < $1.path }

        var rows: [String] = []          // "<상대경로>|<fbo>|<fit>|<1920x1080 치수>"
        var comboed: [String] = []       // fit 과 scale/width/height 를 함께 쓴 것
        for url in files {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            // 동봉 자산은 전건 CRLF 다 — `EffectManifestTests` 와 같은 이유로 정규화해 파스한다.
            let raw = try Data(contentsOf: url)
            let lf = Data(String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").utf8)
            guard let m = EffectManifest.parse(lf) else { continue }
            for f in m.fbos where f.fit != nil {
                let b = try XCTUnwrap(f.fittedBox(baseWidth: 1920, baseHeight: 1080))
                rows.append("\(rel)|\(f.name)|\(f.fit ?? -1)|\(b.width)x\(b.height)")
                if f.scale != 1 || f.declaredWidth != nil || f.declaredHeight != nil {
                    comboed.append("\(rel)|\(f.name)")
                }
            }
        }
        XCTAssertTrue(comboed.isEmpty, "fit 과 scale/width/height 동시 선언이 생겼다 — W-FIT-4 재확인: \(comboed)")
        XCTAssertEqual(rows.count, 14, "동봉 `fit` 선언 수가 바뀌었다 — 아래 표를 다시 세라")
        XCTAssertEqual(rows.sorted(), [
            "cursorripple/effect.json|_rt_EightBuffer1|512|512x288",
            "cursorripple/effect.json|_rt_EightBuffer2|512|512x288",
            "fluidsimulation/effect.json|_rt_SmokeCurl|256|256x144",
            "fluidsimulation/effect.json|_rt_SmokeDivergence|256|256x144",
            "fluidsimulation/effect.json|_rt_SmokePressure1|256|256x144",
            "fluidsimulation/effect.json|_rt_SmokePressure2|256|256x144",
            "fluidsimulation/effect.json|_rt_SmokeVelocity1|256|256x144",
            "fluidsimulation/effect.json|_rt_SmokeVelocity2|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokeCurl|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokeDivergence|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokePressure1|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokePressure2|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokeVelocity1|256|256x144",
            "fluidsimulation/preview/effects/fluidsimulation/effect.json|_rt_SmokeVelocity2|256|256x144",
        ].sorted())

        // 두 이펙트의 **동봉 preview 씬은 256×256 레이어**다(`preview/scene.json` 의
        // `orthogonalprojection` 과 오브젝트 `size` 가 둘 다 256). 거기서 무엇이 바뀌고
        // 무엇이 안 바뀌는지를 같이 못박는다 — 이게 동봉 자산의 실제 그림 변화 전부다.
        let fluid = try fbo(#"{"name":"_rt_SmokeVelocity1","fit":256,"format":"rg1616f"}"#)
        XCTAssertEqual(box(fluid, 256, 256), [256, 256], "fluidsimulation preview 는 종전과 같다")
        let ripple = try fbo(#"{"name":"_rt_EightBuffer1","fit":512,"format":"rgba8888"}"#)
        XCTAssertEqual(box(ripple, 256, 256), [256, 256],
                       "cursorripple preview 는 512x512 → 256x256 으로 바뀐다(확대 금지)")
    }
}
