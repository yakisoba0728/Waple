import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// X-⑧ (G-A5-06/G-B2-02 · G-A5-05/G-B2-03): effect.json `fbos[].format` / `unique` / `clear`.
///
/// 왜 한 묶음인가. 종전엔 `format` 키를 아예 파스하지 않아 **모든 중간 FBO 가 rgba8Unorm** 이었다.
/// 동봉 자산 실측으로 fbo 선언 55건 전건이 `format` 을 갖고 그중 27건이 rgba8 이 아니다.
/// 가장 심한 것이 `fluidsimulation` 이다 — 속도장 `rg1616f`, 압력/발산/컬 `r16f` 는 전부
/// **부호 있고 1.0 을 넘는 물리량**이라 unorm([0,1] 클램프 + 8비트 양자화)으로는 담을 수가 없다.
/// 동시에 그 버퍼들은 전건 `unique`(프레임 간 지속) + `clear`(생성 1회 초기화)다. 포맷만 고치면
/// 상태가 매 프레임 사라지고, 지속만 고치면 값이 클램프된다. 그래서 같이 간다.
final class EffectFBOFormatTests: XCTestCase {

    // MARK: 포맷 매핑 — 장치 없이 검증 가능한 순수 함수

    func testFormatStringsMapToMatchingMetalFormats() {
        typealias F = EffectManifest.FBO.Format
        XCTAssertEqual(SceneRenderer.metalFormat(F.rgba8888, hdr: false), .rgba8Unorm)
        XCTAssertEqual(SceneRenderer.metalFormat(F.rgba8888, hdr: true), .rgba8Unorm,
                       "rgba8888 은 고정 포맷 — HDR 이라고 승격되지 않는다")
        XCTAssertEqual(SceneRenderer.metalFormat(F.r16f, hdr: false), .r16Float)
        XCTAssertEqual(SceneRenderer.metalFormat(F.rg1616f, hdr: false), .rg16Float)
        XCTAssertEqual(SceneRenderer.metalFormat(F.r8, hdr: false), .r8Unorm)
    }

    /// `rgba_backbuffer` 만 조건부다 — 이름 그대로 "백버퍼와 같은 포맷".
    func testBackbufferFormatFollowsSceneHDR() {
        XCTAssertEqual(SceneRenderer.metalFormat(EffectManifest.FBO.Format.rgbaBackbuffer, hdr: false), .rgba8Unorm)
        XCTAssertEqual(SceneRenderer.metalFormat(EffectManifest.FBO.Format.rgbaBackbuffer, hdr: true), .rgba16Float,
                       "HDR 씬에서 백버퍼 추종 FBO 가 8비트로 남으면 >1 이 그 자리에서 클램프된다")
    }

    /// 미지/미선언은 이펙트를 드롭하지 않고 rgba8 로 간다(G-A5-04 폴백 정책과 동일).
    func testUnknownOrAbsentFormatFallsBackToRGBA8() {
        XCTAssertEqual(SceneRenderer.metalFormat(nil, hdr: false), .rgba8Unorm)
        XCTAssertEqual(SceneRenderer.metalFormat(nil, hdr: true), .rgba8Unorm,
                       "미선언은 HDR 여부와 무관하게 종전 동작(rgba8) 유지 — 무회귀")
    }

    /// **이 테스트가 이 커밋의 요점이다.** 유체 시뮬 버퍼가 부동소수로 할당되는가.
    /// 하나라도 unorm 으로 떨어지면 압력 반복이 발산하거나 속도 부호가 통째로 날아간다.
    func testFluidSimulationBuffersResolveToSignedFloatFormats() {
        let velocity = SceneRenderer.metalFormat(EffectManifest.FBO.Format.rg1616f, hdr: false)
        let pressure = SceneRenderer.metalFormat(EffectManifest.FBO.Format.r16f, hdr: false)
        for (name, fmt) in [("속도장", velocity), ("압력장", pressure)] {
            XCTAssertTrue(fmt == .rg16Float || fmt == .r16Float,
                          "\(name)이 부동소수가 아니다(\(fmt)) — 부호와 1.0 초과를 잃는다")
            XCTAssertNotEqual(fmt, .rgba8Unorm, "\(name)이 종전 하드코딩 값으로 되돌아갔다")
        }
    }

    // MARK: 동봉 자산 전수 대조 — enum 이 실물을 전부 아는가

    /// 동봉된 모든 `effect.json` 을 실제로 파스해서, `format` 문자열이 **하나도 미지로 떨어지지
    /// 않는지** 본다. 미지는 조용히 rgba8 이 되므로 enum 누락은 눈에 안 띈다.
    /// 동시에 "clear 를 가진 fbo 는 전건 unique" 라는 관측을 계약으로 고정한다 — 이게 깨지면
    /// 프레임 로컬 버퍼에 시작값을 정의하려는 자산이 있다는 뜻이라 소비처 설계를 다시 봐야 한다.
    func testShippedEffectManifestsHaveNoUnknownFormatAndClearImpliesUnique() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory,
                                "동봉 에셋을 못 찾으면 이 대조는 무의미하다")
        // 팩 **전체**를 훑는다 — `effect.json` 128개 중 6개는 `effects/` 밖에 있다
        // (`scenes/particleelementpreviews/*/effects/…`, `presets/*/preview*/effects/…`).
        // `effects/` 만 보면 그 6개가 조용히 빠진다.
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XCTFail("동봉 팩을 순회할 수 없다")
        }
        var totalFBOs = 0, withFormat = 0, rawDeclCount = 0, unknownFormat: [String] = []
        var clearNotUnique: [String] = []
        var formatHistogram: [String: Int] = [:]
        for case let url as URL in walker where url.lastPathComponent == "effect.json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: EffectManifest.relaxedJSON(data) ?? data))
                    as? [String: Any] else { continue }
            guard let m = EffectManifest.parse(data) else { continue }
            let raw = (obj["fbos"] as? [[String: Any]]) ?? []
            // 인덱스가 아니라 **이름**으로 원문과 맞춘다 — 파서는 name 없는 항목을 건너뛰고 64개에서
            // 끊으므로 인덱스 1:1 을 전제하면 언젠가 조용히 어긋난다(동봉 자산엔 중복 이름 0건).
            // **원문 선언 수를 따로 센다.** 파서가 `format` 없는 선언을 이미 버리므로 `m.fbos` 만
            // 세면 "전건이 format 을 갖는다" 는 정의상 참이 되어 아무것도 검사하지 못한다(항진식).
            rawDeclCount += raw.count
            var rawFormatByName: [String: String] = [:]
            for r in raw {
                if let n = r["name"] as? String, let fmt = r["format"] as? String { rawFormatByName[n] = fmt }
            }
            for f in m.fbos {
                totalFBOs += 1
                let rawFormat = rawFormatByName[f.name]
                if let rf = rawFormat {
                    withFormat += 1
                    formatHistogram[rf, default: 0] += 1
                    if f.format == nil { unknownFormat.append("\(url.lastPathComponent):\(f.name)=\(rf)") }
                }
                if f.clearColor != nil && !f.unique {
                    clearNotUnique.append("\(url.path):\(f.name)")
                }
            }
        }
        XCTAssertGreaterThan(totalFBOs, 0, "fbo 선언을 하나도 못 읽었다 — 순회가 잘못됐다")
        XCTAssertEqual(unknownFormat, [], "enum 이 모르는 포맷 문자열이 실물에 있다(조용히 rgba8 이 된다)")
        XCTAssertEqual(clearNotUnique, [], "clear 를 가졌는데 unique 가 아닌 fbo — 소비처 전제가 깨진다")
        XCTAssertEqual(withFormat, totalFBOs, "보존된 fbo 는 정의상 전건 format 보유")
        XCTAssertEqual(totalFBOs, rawDeclCount,
                       "format 없는 선언이 드롭됐다 — 실측 55/55 관측이 깨졌으니 관측을 갱신할 것")
        // 2026-08-20 실측 분포. 자산 교체로 흔들릴 수 있으니 동등이 아니라 존재만 고정한다.
        for expected in ["rgba8888", "rgba_backbuffer", "r16f", "rg1616f", "r8"] {
            XCTAssertNotNil(formatHistogram[expected], "실물에서 사라진 포맷: \(expected)")
        }
    }
}
