import Foundation
import XCTest
@testable import WapleCore

/// `spec/engine/tonemapping.json` 의 **확정** 항목을 값으로 잠그고, 그중 산술로 옮겨진 것은
/// `LDRBloomMath`/`HDRBloomMath` 와 **양쪽에서** 대조한다.
///
/// 왜 정본을 테스트가 읽는가
/// ------------------------
/// 이 문서가 담은 사실의 대부분은 **부재**(톤 곡선·노출·화이트포인트·디더가 없다)와
/// **색 공간·정밀도**다. 부재에는 대응 코드가 없고, 색 공간은 `WapleRender` 쪽이라
/// 리눅스에서 실행되지 않는다. 그래서 여기서 잠글 수 있는 것은 **사실 그 자체**뿐이고
/// 사실의 정본은 `spec/engine/tonemapping.json` 이다.
///
/// 이 테스트가 막는 사고는 셋이다.
///  ① 코퍼스·바이너리가 있는 머신에서 `scripts/spec/measure_tonemapping.py` 를 다시 돌렸을 때
///     이 수치들이 **조용히 바뀌는 것**(`docs/dev/re-methodology.md` §2 함정 19·20).
///  ② 정본과 구현이 갈리는 것 — `blur13Weights`·탭 스트라이드·기본값을 양쪽에서 대조한다.
///  ③ "톤매핑이 없다" 가 **재지 않은 0** 으로 퇴화하는 것. 전수 인구(셰이더 137 · 씬 186)를
///     같이 단언해서, 표본이 0 이 되면 개수 쪽이 먼저 붉어지게 한다.
///
/// [2026-08-28] 위 씬 수는 358 이었다 — 동봉과 설치본을 둘 다 세서 172씬이 두 번 들어간
/// 값이다. ①이 막으려던 "조용히 바뀌는 것" 은 잡았지만, **틀린 값이 조용히 굳는 것** 은 못
/// 막았다. 개수를 잠글 때는 **모집단 이름도 같이 잠가야 한다**(아래 `corpusPopulation` 단언).
///
/// 근거 VA 는 `docs/re/tonemapping.md` · `docs/re/scene-postprocessing.md` 에 있다.
final class ToneMappingCanonTests: XCTestCase {

    // MARK: 정본 로드

    /// `scripts/dev/linux-core-tests.sh` 는 테스트 소스를 **심링크로** 임시 패키지에 건다 —
    /// `#filePath` 를 그대로 거슬러 오르면 리포 밖으로 나간다. 심링크를 먼저 푼다
    /// (`MediaPlaybackCanonTests.canonURL` 과 같은 방식).
    private static func canonURL() -> URL? {
        let fm = FileManager.default
        let here = (try? fm.destinationOfSymbolicLink(atPath: #filePath)) ?? #filePath
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("spec/engine/tonemapping.json")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func entries() throws -> [String: (status: String, value: [String: Any])] {
        let url = try XCTUnwrap(Self.canonURL(), "spec/engine/tonemapping.json 을 못 찾았다")
        let raw = try Data(contentsOf: url)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let list = try XCTUnwrap(doc["entries"] as? [[String: Any]])
        var out: [String: (status: String, value: [String: Any])] = [:]
        for e in list {
            guard let id = e["id"] as? String, let status = e["status"] as? String else { continue }
            out[id] = (status, (e["value"] as? [String: Any]) ?? [:])
        }
        return out
    }

    private func value(_ id: String, file: StaticString = #filePath,
                       line: UInt = #line) throws -> [String: Any] {
        let all = try entries()
        let e = try XCTUnwrap(all[id], "정본 항목 \(id) 가 사라졌다", file: file, line: line)
        XCTAssertEqual(e.status, "확정", "\(id) 의 등급이 내려갔다", file: file, line: line)
        return e.value
    }

    // MARK: 부재 — 톤 곡선 · 노출 · 화이트포인트

    /// 이 리포에서 가장 되돌아가기 쉬운 결론이다: "톤매핑이 없으니 ACES 를 넣자".
    /// 넣으면 저역까지 곡선변형돼 WE 와 갈린다. 부재를 **표본 크기와 함께** 잠근다.
    func testNoToneOperatorIdentifierInAnyBundledShader() throws {
        let v = try value("engine.tonemap.operatorAbsence")
        XCTAssertEqual(v["shaderPopulation"] as? Int, 137,
                       "동봉 셰이더 전수가 137 이 아니다 — 표본이 바뀌면 0 의 뜻도 바뀐다")

        let census = try XCTUnwrap(v["identifierCensus"] as? [String: Any])
        // `ACES` 만 1건이고 그것은 "pieaces" 오타 주석이다. 나머지는 전부 0 이어야 한다.
        for token in ["Reinhard", "Uncharted", "filmic", "Hable", "tonemap", "whitepoint",
                      "exposure", "luminance", "histogram", "adapt", "dither", "bayer"] {
            let row = try XCTUnwrap(census[token] as? [String: Any], "식별자 \(token) 행이 없다")
            XCTAssertEqual(row["files"] as? Int, 0, "\(token) 이 셰이더에 나타났다")
        }
        let aces = try XCTUnwrap(census["ACES"] as? [String: Any])
        XCTAssertEqual(aces["files"] as? Int, 1, "ACES 히트 수가 바뀌었다")
        let sites = try XCTUnwrap(aces["sites"] as? [String])
        XCTAssertEqual(sites.count, 1)
        XCTAssertTrue(sites[0].hasPrefix("HLSL/dx11playlisttransition.vert:"),
                      "ACES 유일 히트가 오타 주석이 아닌 곳으로 옮겨갔다 — \(sites)")
    }

    /// 셰이더 평문이 아니라 **바이너리 쪽** 부재. 상수 적재 자리 수가 0 이라는 것이
    /// "엔진이 CPU 에서 톤 곡선을 걸지 않는다" 의 근거다(방법론 함정 4).
    ///
    /// **판별력 있는 상수에만 건다.** 둥근 십진수(Hable 의 0.1·0.2·0.02·0.3 …)는 어느
    /// 프로그램에나 나온다 — 실제로 `0.1` 4자리 중 셋이 `bloomhdrfeather` 기본값이다.
    /// 그것까지 0 이라고 단언하면 이 테스트가 **거짓을 잠그게** 된다.
    func testNoDiscriminatingToneOperatorOrTransferConstantIsLoaded() throws {
        let v = try value("engine.tonemap.operatorAbsence")
        XCTAssertEqual(v["discriminatingLoadSiteTotal"] as? Int, 0,
                       "판별력 있는 톤 곡선·전이함수 상수가 이미지에 나타났다")

        var discriminating = 0
        for key in ["binaryOperatorConstants", "binaryTransferConstants"] {
            let census = try XCTUnwrap(v[key] as? [String: Any], "\(key) 가 없다")
            XCTAssertFalse(census.isEmpty, "\(key) 가 비었다 — 재지 않은 0 이다")
            for (label, row) in census {
                let r = try XCTUnwrap(row as? [String: Any])
                guard r["discriminating"] as? Bool == true else { continue }
                discriminating += 1
                XCTAssertEqual(r["loadSites"] as? Int, 0,
                               "\(key).\(label) 이 이미지에 나타났다 — 엔진이 그 상수를 싣는다는 뜻이다")
            }
        }
        // 판별력 있는 상수가 통째로 사라져 "0 건 대조로 통과" 하는 것을 막는다.
        XCTAssertEqual(discriminating, 14, "판별력 있는 상수 수가 바뀌었다")

        // 판별력 없는 것도 **싣되 라벨이 붙어 있어야** 한다 — 숨기면 다음 사람이 근거로 쓴다.
        let op = try XCTUnwrap(v["binaryOperatorConstants"] as? [String: Any])
        let hableC = try XCTUnwrap(op["Hable.C=0.10"] as? [String: Any])
        XCTAssertEqual(hableC["discriminating"] as? Bool, false)
        XCTAssertGreaterThan(try XCTUnwrap(hableC["loadSites"] as? Int), 0,
                             "둥근 십진수가 0 이 됐다 — 판별력 없음의 실증이 사라진다")
        XCTAssertTrue(try XCTUnwrap(v["discriminatingNote"] as? String).contains("bloomhdrfeather"))

        // Waple 쪽 대응: 최종 패스가 `saturate` 뿐이고 전이함수 상수를 하나도 갖지 않는다.
        // (이 두 탐침은 `wapleParity` 가 소유하고, 나머지 탐침은
        //  engine.bloom.ldr.arithmetic.wapleProbes 가 소유한다 — 복제하지 않는다.)
        let parity = try XCTUnwrap(v["wapleParity"] as? [String: Any])
        XCTAssertEqual(parity["post.finalIsSaturateOnly"] as? Bool, true)
        XCTAssertEqual(parity["post.noTransferFunction"] as? Bool, true)
    }

    /// **양성 대조** — "0 은 스캐너가 고장난 것" 이라는 가장 흔한 반박을 닫는다.
    /// 같은 f32 스캐너를 설치본의 다른 이미지에 그대로 돌렸을 때 `FreeImage64.dll` 은
    /// sRGB 전이함수 상수를 실제로 내놓는다. 이 대조가 사라지면 `wallpaper64.exe` 의 0 은
    /// **재지 않은 0** 과 구별되지 않는다.
    func testTransferConstantScannerIsProvenAliveByPositiveControl() throws {
        let v = try value("engine.tonemap.operatorAbsence")
        let control = try XCTUnwrap(v["transferConstantPositiveControl"] as? [String: Any],
                                    "양성 대조가 사라졌다 — 0 의 뜻을 잃는다")
        let free = try XCTUnwrap(control["FreeImage64.dll"] as? [String: Any],
                                 "FreeImage64.dll 대조가 없다")
        var hits = 0
        for (_, n) in free { hits += (n as? NSNumber)?.intValue ?? 0 }
        XCTAssertGreaterThan(hits, 0,
                             "이미지 코덱에서도 전이함수 상수를 못 찾았다 — 스캐너가 죽었다는 뜻이다")
        XCTAssertEqual((free["2.4"] as? NSNumber)?.intValue, 3, "FreeImage 의 2.4 적재 자리 수")
        XCTAssertEqual((free["0.0031308"] as? NSNumber)?.intValue, 1, "FreeImage 의 OETF 무릎")

        // 음성 쪽: 셰이더 컴파일러는 색 변환을 하지 않는다.
        let dxc = try XCTUnwrap(control["d3dcompiler_47.dll"] as? [String: Any])
        for (label, n) in dxc {
            XCTAssertEqual((n as? NSNumber)?.intValue, 0, "d3dcompiler 에 \(label) 이 나타났다")
        }
    }

    /// 셰이더가 쓰는 Rec.601 삼중은 **적재 자리 0**(GPU 에서만 돈다)이고, 1건씩 잡히는
    /// Rec.709 삼중은 데스크톱 강조색 대비 판정이다. 이 갈림이 무너지면 결론이 흔들린다.
    func testShaderLumaWeightsAreNotLoadedByTheEngine() throws {
        let v = try value("engine.tonemap.operatorAbsence")
        let census = try XCTUnwrap(v["binaryLumaConstants"] as? [String: Any])
        for label in ["Rec601.0.299", "Rec601.0.587", "Rec601.0.114",
                      "Rec601.0.2989", "Rec601.0.5870", "Rec601.0.1140"] {
            let r = try XCTUnwrap(census[label] as? [String: Any], "\(label) 행이 없다")
            XCTAssertEqual(r["loadSites"] as? Int, 0, "\(label) 이 이미지에 나타났다")
        }
        for label in ["Rec709.0.2126", "Rec709.0.7152", "Rec709.0.0722"] {
            let r = try XCTUnwrap(census[label] as? [String: Any], "\(label) 행이 없다")
            XCTAssertEqual(r["loadSites"] as? Int, 1, "\(label) 의 적재 자리 수가 바뀌었다")
        }
        let note = try XCTUnwrap(v["lumaConstantHits"] as? String)
        XCTAssertTrue(note.contains("DwmIsCompositionEnabled"),
                      "Rec.709 히트의 소비처 설명이 사라졌다 — 다음 사람이 톤매핑으로 오독한다")
    }

    func testDitherPassIsAbsent() throws {
        let v = try value("engine.postprocess.ditherAbsence")
        XCTAssertEqual(v["shaderFilesWithDitherToken"] as? Int, 0)
        XCTAssertEqual(v["binaryAscii"] as? Int, 0)
        XCTAssertEqual(v["binaryUtf16le"] as? Int, 0)
    }

    // MARK: 전이함수 — 방향은 이름이 아니라 상수로 판정한다

    /// `combine_hdr_editor.frag` 의 함수 이름은 `srgb()` 지만 본문은 **디코드**다.
    /// 이름으로 방향을 정하면 뒤집힌다 — 실제로 한 번 뒤집혔던 자리다.
    func testTransferDirectionIsDecidedByConstantsNotFunctionName() throws {
        let v = try value("engine.tonemap.transferFunctionSites")
        let sites = try XCTUnwrap(v["sites"] as? [String: Any])
        XCTAssertEqual(sites.count, 5, "전이함수를 담은 파일 수가 바뀌었다 — \(sites.keys.sorted())")

        func direction(_ file: String) throws -> String {
            let row = try XCTUnwrap(sites[file] as? [String: Any], "\(file) 행이 없다")
            return try XCTUnwrap(row["direction"] as? String)
        }
        for f in ["combine_hdr.frag", "passthroughsrgb.frag", "combine_hdr_editor.frag"] {
            XCTAssertTrue(try direction(f).contains("디코드"), "\(f) 의 방향이 뒤집혔다")
        }
        XCTAssertTrue(try direction("passthroughlinear.frag").contains("인코드"))
        XCTAssertTrue(try direction("downsample_quarter_linear.frag").contains("인코드"))

        // 이름이 방향을 말하지 않는다는 것 자체를 잠근다.
        let editor = try XCTUnwrap(sites["combine_hdr_editor.frag"] as? [String: Any])
        XCTAssertEqual(editor["declaredFunctions"] as? [String], ["srgb"])
        XCTAssertEqual(editor["knee"] as? String, "0.04045")
        XCTAssertEqual(editor["exponent"] as? String, "2.4")

        // 적용 지점 전수 = 6. `combine_hdr.frag` 만 둘(DISPLAYHDR 분기 + SDR 분기)이다.
        var applied = 0
        for (_, row) in sites {
            applied += ((row as? [String: Any])?["applySites"] as? [String])?.count ?? 0
        }
        XCTAssertEqual(applied, 6, "전이함수 적용 지점 수가 바뀌었다")
    }

    /// 셋은 **런타임에 로드되지 않는다**. 그중 `combine_hdr_upsample_linear` 가 중요하다 —
    /// `combine_hdr.frag` 의 `#if LINEAR == 1` 은 `lin()` 을 건너뛰는 유일한 분기인데,
    /// 그 콤보를 거는 머티리얼이 도달 불가라 **SDR 경로에서 디코드는 항상 걸린다**.
    func testEditorAndDebugCombineMaterialsAreUnreachableAtRuntime() throws {
        let v = try value("engine.tonemap.transferFunctionSites")
        let reach = try XCTUnwrap(v["runtimeReachable"] as? [String: Any])
        func row(_ n: String) throws -> [String: Any] {
            try XCTUnwrap(reach[n] as? [String: Any], "\(n) 행이 없다")
        }
        // 미도달 판정은 **전체 경로와 맨몸 이름이 둘 다 없을 때만** 선다. 전체 경로만 보면
        // `solidlayer`·`passthrough` 처럼 맨몸 이름으로 열리는 것을 미로드로 오판한다.
        for name in ["combine_hdr_editor", "combine_hdr_upsample_linear", "combine_hdr_upsample_dbg"] {
            let r = try row(name)
            XCTAssertEqual(r["verdict"] as? String, "unreachable", "\(name) 이 도달 가능해졌다")
            XCTAssertEqual(r["pathString"] as? Bool, false, "\(name) 전체 경로")
            XCTAssertEqual(r["bareName"] as? Bool, false, "\(name) 맨몸 이름")
        }
        for name in ["combine_ldr", "combine_srgb", "combine_hdr_upsample",
                     "combine_dhdr_upsample", "combine_video_hdr",
                     "downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom",
                     "hdr_downsample", "hdr_downsample_bloom", "hdr_upsample", "hdr_upsample_cubic"] {
            XCTAssertEqual(try row(name)["verdict"] as? String, "loadable", "\(name) 이 도달 불가가 됐다")
        }
        // 과잉 주장 방지선: 전체 경로가 없어도 맨몸 이름이 있는 부류가 실제로 존재한다는 것을
        // 같이 잠근다. 이게 사라지면 다음 사람이 다시 "경로 없음 = 미로드" 로 되돌린다.
        for name in ["solidlayer", "passthrough"] {
            let r = try row(name)
            XCTAssertEqual(r["pathString"] as? Bool, false)
            XCTAssertEqual(r["verdict"] as? String, "nameOnly", "\(name) 은 맨몸 이름으로만 잡힌다")
        }
        XCTAssertEqual(v["ldrHasNoTransferFunction"] as? Bool, true)
    }

    // MARK: 최종 픽셀 식과 도달

    func testFinalPixelExpressionAndCorpusReach() throws {
        // [2026-08-28] 이 테스트가 고정하던 358 계열은 **이중계수된 값**이었다.
        //
        // 생성기 `measure_tonemapping.py` 의 `corpus_reach()` 가 동봉
        // `Sources/WapleRender/Resources/WEAssets/` 와 설치본 `WE_ROOT/assets/` 를 **둘 다**
        // 훑었는데, 그 둘은 같은 집합이다(md5 동일). 172씬을 두 번 세서 186 이 358 이 됐다.
        // 산술이 그대로 드러난다 — 348 = 178+170 · 6 = 5+1 · 4 = 3+1.
        //
        // 더 나쁜 것은 이 테스트가 그 값을 **잠그고 있었다**는 점이다. 정본이 틀린 채로
        // 초록이었고, 테스트는 "바뀌었는지" 만 봤지 "맞는지" 는 못 봤다. 여기서 배울 것은
        // 도수 단언에는 **모집단 이름이 같이 잠겨야 한다**는 것이다 — 그래서 아래에
        // `corpusPopulation` 을 함께 단언한다. 수치만 고정하면 같은 사고가 반복된다.
        let v = try value("engine.tonemap.finalPixelExpression")
        XCTAssertEqual(v["corpusScenes"] as? Int, 186, "씬 전수가 바뀌었다")

        // 모집단을 값과 함께 잠근다 — 어느 집합을 센 186 인지가 186 만큼 중요하다.
        let population = try XCTUnwrap(v["corpusPopulation"] as? String)
        XCTAssertTrue(population.contains("설치본"),
                      "도수의 모집단이 설치본이라는 선언이 사라졌다 — 이중계수 재발 경로다")

        let reachRaw = try XCTUnwrap(v["corpusReach"] as? [String: Any])
        var reach: [String: Int] = [:]
        for (k, n) in reachRaw { reach[k] = (n as? NSNumber)?.intValue }
        XCTAssertEqual(reach.values.reduce(0, +), 186, "도달 표의 합이 전수와 다르다")
        XCTAssertEqual(reach["LDR + bloom off"], 178)
        XCTAssertEqual(reach["LDR + bloom on"], 5)
        XCTAssertEqual(reach["HDR + bloom on"], 3)
        // `hdr:true && !bloom` 이 0 이라는 것이 `passthroughsrgb` 경로가 코퍼스로 재현되지
        // 않는다는 뜻이다 — 골든으로 그 분기를 검증할 수 없다는 사실을 잠근다.
        XCTAssertEqual(reach["HDR + bloom off"], 0)

        // 고유 HDR 씬은 3개다. 종전 4개는 `previewthunderbolt` 를 동봉 경로와 설치 경로로
        // 두 번 실은 것 — 이중계수의 같은 뿌리다. 경로 중복이 다시 들어오면 여기서 잡힌다.
        let hdrScenes = try XCTUnwrap(v["hdrScenes"] as? [String])
        XCTAssertEqual(hdrScenes.count, 3)

        // **[정정 2026-08-30] 종전 이 자리에 있던 집합 크기 단언은 자기가 노리는 이중계수를 못 잡았다.**
        //
        // `5d6cba8b` 은 `XCTAssertEqual(Set(hdrScenes).count, hdrScenes.count, …)` 를
        // "이중계수의 **재발 경로 자체**" 를 막는 방어로 들여놓았는데, 정작 그 버그는 같은
        // 씬을 **서로 다른 접두로** 실었다 — 문자열이 달라서 집합 크기가 줄지 않는다.
        // 실제로 변이를 넣어 재현했다(2026-08-30):
        //
        // | 변이 | 집합 단언 | 수 단언(바로 위 줄) |
        // | --- | --- | --- |
        // | 종전 4건(동봉+설치 중복) | **통과** — 4 == 4 | 실패 |
        // | 동봉 경로 1건만 남기고 수는 3 유지 | **통과** | **통과** |
        //
        // 둘째 줄이 진짜 구멍이다 — 이중계수의 뿌리인 "동봉 트리 경로가 목록에
        // 실린다" 가 수만 맞으면 통과해 버린다. 그래서 집합 크기 대신 **모집단 접두 자체**를
        // 단언한다: 모집단은 설치본 하나이므로(위 `corpusPopulation`) 모든 항목이
        // `WE_ROOT/` 으로 시작해야 하고, 동봉 트리 경로가 하나라도 들어오는 순간 그 자체가 실패다.
        for scene in hdrScenes {
            XCTAssertTrue(scene.hasPrefix("WE_ROOT/"),
                          "모집단 밖 경로가 HDR 씬 목록에 실렸다(이중계수 재발 경로): \(scene)")
            XCTAssertFalse(scene.contains("Resources/WEAssets"),
                           "동봉 트리 경로다 — 설치본 사본이므로 같이 실으면 이중계수다: \(scene)")
        }
        // 접두를 떼고 봐도 서로 다른 씬이어야 한다 — 다른 접두로 가장한 같은 씬을 잡는다.
        let hdrSceneSuffixes = hdrScenes.map { scene -> String in
            for prefix in ["WE_ROOT/assets/", "WE_ROOT/projects/",
                           "Sources/WapleRender/Resources/WEAssets/"] where scene.hasPrefix(prefix) {
                return String(scene.dropFirst(prefix.count))
            }
            return scene
        }
        XCTAssertEqual(Set(hdrSceneSuffixes).count, hdrSceneSuffixes.count,
                       "접두를 떼면 같은 씬이다 — 한 씬을 두 트리에서 실은 것")

        let byPath = try XCTUnwrap(v["byPath"] as? [String: String])
        XCTAssertEqual(byPath["LDR + bloom"], "scene + bloom — combine.frag:10-15. 곡선 없음, 클램프는 UNORM 타깃이 한다.")
        XCTAssertTrue(try XCTUnwrap(byPath["HDR + bloom (SDR)"]).contains("saturate(lin(scene + 4탭bloom))"))
        XCTAssertTrue(try XCTUnwrap(v["saturateIsClampNotCurve"] as? String).contains("항등"))
    }

    // MARK: 색 공간 · 정밀도

    /// 하드웨어 sRGB 뷰가 없다는 것은 포맷 enum 표에 `_SRGB` DXGI 값이 하나도 없다는 뜻이다.
    /// 이게 무너지면 "`lin()` 을 상쇄할 인코드가 없다" 는 논거가 통째로 무너진다.
    func testNoHardwareSRGBFormatArmExists() throws {
        let v = try value("engine.tonemap.chainColorSpace")
        let srgbArms = try XCTUnwrap(v["srgbArmsPresent"] as? [Any])
        XCTAssertTrue(srgbArms.isEmpty, "포맷 enum 표에 _SRGB arm 이 생겼다 — \(srgbArms)")
        let table = try XCTUnwrap(v["formatEnumToDXGI"] as? [String: Any])
        XCTAssertEqual(table.count, 28, "포맷 enum 표 길이가 바뀌었다")

        func dxgi(_ key: String) throws -> Int {
            let row = try XCTUnwrap(table[key] as? [String: Any], "enum \(key) 가 없다")
            return try XCTUnwrap(row["dxgi"] as? Int)
        }
        XCTAssertEqual(try dxgi("0x01"), 28, "LDR 컬러 타깃 enum 1 이 R8G8B8A8_UNORM 이 아니다")
        XCTAssertEqual(try dxgi("0x0f"), 10, "HDR 컬러 타깃 enum 0xf 가 R16G16B16A16_FLOAT 이 아니다")
        XCTAssertEqual(try dxgi("0x1b"), 0, "enum 0x1b(= 타깃 없음)이 바뀌었다")
    }

    /// LDR 블룸 체인이 8비트 UNORM 위에서 돈다는 것 — 임계를 넘긴 밝기가 1.0 이상으로
    /// 살아남지 않는다는 뜻이라 이식 시 fp16 으로 올리면 WE 보다 밝아진다.
    func testLDRChainIsEightBitAndHDRChainIsHalfFloat() throws {
        let v = try value("engine.tonemap.chainColorSpace")
        let prec = try XCTUnwrap(v["precisionByPath"] as? [String: String])
        XCTAssertTrue(try XCTUnwrap(prec["LDR"]).contains("8비트 UNORM"))
        XCTAssertTrue(try XCTUnwrap(prec["LDR"]).contains("매 패스 [0,1] 로 잘린다"))
        XCTAssertTrue(try XCTUnwrap(prec["HDR"]).contains("fp16"))
        XCTAssertTrue(try XCTUnwrap(v["renderTargetFormatSelect"] as? String).contains("0x14017f33d"),
                      "포맷 선택 지점 VA 가 사라졌다")
        // 감마가 그레이딩보다 앞이라는 순서 사실.
        XCTAssertTrue(try XCTUnwrap(v["whereGammaSitsInOrder"] as? String).contains("감마가 그레이딩보다 앞"))
    }

    // MARK: LDR 블룸 산술 — 정본 ↔ 구현

    /// 정본이 셰이더 평문에서 읽은 13탭 가중이 `LDRBloomMath` 의 리터럴과 같아야 한다.
    /// 한쪽만 고치면 여기서 갈린다(정본이 낡는 것도, 구현이 표류하는 것도 같이 잡는다).
    func testCanonBlur13WeightsMatchLDRBloomMath() throws {
        let v = try value("engine.bloom.ldr.arithmetic")
        let weightsRaw = try XCTUnwrap(v["blur13Weights"] as? [String: Any])
        XCTAssertEqual(weightsRaw.count, 2, "13탭 커널을 담은 셰이더 수가 바뀌었다")

        let impl = LDRBloomMath.blur13Weights
        var perFile: [String: [Float]] = [:]
        for (file, raw) in weightsRaw {
            let w = try XCTUnwrap(raw as? [Any]).map { ($0 as? NSNumber)?.floatValue ?? .nan }
            XCTAssertEqual(w.count, 13, "\(file) 의 탭 수가 13 이 아니다")
            for (i, x) in w.enumerated() where i < impl.count {
                XCTAssertEqual(x, impl[i], accuracy: 1e-7,
                               "\(file) 탭 \(i) 의 가중이 LDRBloomMath 와 다르다")
            }
            perFile[file] = w
        }
        // 두 셰이더가 같은 커널이라는 것도 함께 잠근다.
        let files = perFile.keys.sorted()
        XCTAssertEqual(perFile[files[0]], perFile[files[1]], "두 블러 패스의 커널이 갈렸다")
    }

    /// 두 블러 축의 스트라이드가 **풀해상도 8텍셀로 같다**(등방)는 것과, 이름의 h/v 가
    /// 실제 축과 반대라는 함정을 정본·구현 양쪽에서 잠근다.
    func testCanonBlurStrideMatchesLDRBloomMathAndIsIsotropic() throws {
        let v = try value("engine.bloom.ldr.arithmetic")
        let stride = try XCTUnwrap(v["blur13Stride"] as? [String: Any])

        let vPass = try XCTUnwrap(stride["downsample_eighth_blur_v.vert"] as? [String: Any])
        let hPass = try XCTUnwrap(stride["blur_h_bloom.vert"] as? [String: Any])
        // 이름이 _v 인 쪽이 x축, _h 인 쪽이 y축이다 — 뒤집으면 두 패스가 바뀐다.
        XCTAssertEqual(vPass["axis"] as? String, "x")
        XCTAssertEqual(hPass["axis"] as? String, "y")
        XCTAssertEqual((vPass["fullResTexels"] as? NSNumber)?.doubleValue, 8.0)
        XCTAssertEqual((hPass["fullResTexels"] as? NSNumber)?.doubleValue, 8.0)

        // 구현이 같은 8 풀텍셀을 만드는지 — 1/4 폭 2텍셀 = 1/8 높이 1텍셀 = 풀 8텍셀.
        let fullW = 1024, fullH = 512
        let x = LDRBloomMath.horizontalStepUV(quarterWidth: fullW / 4).x * Float(fullW)
        let y = LDRBloomMath.verticalStepUV(eighthHeight: fullH / 8).y * Float(fullH)
        XCTAssertEqual(x, 8, accuracy: 1e-4, "X 스트라이드가 풀해상도 8텍셀이 아니다")
        XCTAssertEqual(y, 8, accuracy: 1e-4, "Y 스트라이드가 풀해상도 8텍셀이 아니다")
        XCTAssertEqual(x, y, accuracy: 1e-4, "두 축이 비등방이 됐다")
    }

    func testLDRChainIsThreePassesWithNoPerPassTapUniform() throws {
        let v = try value("engine.bloom.ldr.arithmetic")
        XCTAssertEqual(v["passCount"] as? Int, 3)
        let ev = try XCTUnwrap(v["passCountEvidence"] as? String)
        for va in ["0x140183949", "0x140183966", "0x1401839b5", "0x140183a04"] {
            XCTAssertTrue(ev.contains(va), "LDR 분기 근거 VA \(va) 가 사라졌다")
        }
        XCTAssertTrue(try XCTUnwrap(v["tapUniformIsNotWrittenPerPass"] as? String).contains("0건"))
        XCTAssertTrue(try XCTUnwrap(v["strengthIsRaw"] as? String).contains("강도 정규화가 없다"))
    }

    /// 정본이 소스에서 읽어 둔 탐침이 전부 살아 있어야 한다. 하나라도 `false` 면
    /// 구현이 옮겨갔거나 이름이 바뀐 것이고, 그 상태로 재생성하면 축소 가드에 막힌다.
    func testWapleProbesInCanonAreAllLive() throws {
        let v = try value("engine.bloom.ldr.arithmetic")
        let probes = try XCTUnwrap(v["wapleProbes"] as? [String: Any])
        for key in ["ldr.extractTapIsFullResTexel", "ldr.horizontalStepIsTwoQuarterTexels",
                    "ldr.verticalStepIsOneEighthTexel", "ldr.gateIsSaturateOfExcess",
                    "ldr.saturationBoostFoldsToTwoCMinusGray", "ldr.compositeIsPlainAddition",
                    "ldr.noStrengthNormalization", "hdr.hasStrengthNormalization",
                    "hdr.blendParamsKneeIsThresholdTimesFeather",
                    "post.finalIsSaturateOnly", "post.noTransferFunction"] {
            XCTAssertEqual(probes[key] as? Bool, true, "탐침 \(key) 가 죽었다")
        }
        // 기본값은 정본과 구현 양쪽에서 대조한다.
        let canonStrength = try XCTUnwrap((probes["ldr.defaultStrength"] as? NSNumber)?.floatValue)
        let canonThreshold = try XCTUnwrap((probes["ldr.defaultThreshold"] as? NSNumber)?.floatValue)
        XCTAssertEqual(canonStrength, LDRBloomMath.defaultStrength, accuracy: 1e-7)
        XCTAssertEqual(canonThreshold, LDRBloomMath.defaultThreshold, accuracy: 1e-7)
        let half = try XCTUnwrap(probes["ldr.blur13HalfWeights"] as? [Any])
            .map { ($0 as? NSNumber)?.floatValue ?? .nan }
        XCTAssertEqual(half.count, LDRBloomMath.blur13HalfWeights.count)
        for (i, x) in half.enumerated() where i < LDRBloomMath.blur13HalfWeights.count {
            XCTAssertEqual(x, LDRBloomMath.blur13HalfWeights[i], accuracy: 1e-7)
        }
    }

    // MARK: 경로 갈림

    /// 두 경로를 가르는 것은 **비트13 하나**이고 소비 지점이 셋이다. 그리고 그 비트를
    /// 세우는 자리는 아직 열려 있다 — 그 정직함이 지워지지 않게 같이 잠근다.
    func testPathDivergenceGateAndOpenQuestion() throws {
        let v = try value("engine.bloom.pathDivergence")
        let gate = try XCTUnwrap(v["gate"] as? String)
        XCTAssertTrue(gate.contains("0x2000"))
        for va in ["0x14017f33d", "0x14017f7cb", "0x140183618"] {
            XCTAssertTrue(gate.contains(va), "비트13 소비 지점 \(va) 가 사라졌다")
        }
        let open = try XCTUnwrap(v["openQuestion"] as? String)
        XCTAssertTrue(open.contains("주입"), "주입 경로가 열려 있다는 서술이 사라졌다")

        let rows = try XCTUnwrap(v["rows"] as? [String: Any])
        let fmt = try XCTUnwrap(rows["렌더타깃 포맷"] as? [String: String])
        XCTAssertTrue(try XCTUnwrap(fmt["LDR"]).contains("R8G8B8A8_UNORM"))
        XCTAssertTrue(try XCTUnwrap(fmt["HDR"]).contains("R16G16B16A16_FLOAT"))

        let strength = try XCTUnwrap(rows["강도 파라미터"] as? [String: String])
        XCTAssertTrue(try XCTUnwrap(strength["LDR"]).contains("생값"))
        XCTAssertTrue(try XCTUnwrap(strength["HDR"]).contains("scatter^(max(N,2)−2)"))

        // 정본이 적은 HDR 정규화식을 구현으로 다시 계산해 맞춰 본다.
        let n = 8
        let expected = LDRBloomMath.defaultStrength / (powf(1.619, Float(max(n, 2) - 2)) + 1)
        XCTAssertEqual(HDRBloomMath.normalizedStrength(strength: 2, scatter: 1.619, levels: n),
                       expected, accuracy: 1e-6)
    }
}
