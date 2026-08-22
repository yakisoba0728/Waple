import XCTest
import simd
@testable import WapleCore

/// 오디오 어노테이션 파서를 **실물 파일**에 대고 재는 시험.
///
/// `AudioResponseTests` 는 어노테이션 다섯 줄을 테스트 안에 인라인 문자열로 들고 파스한다.
/// 그건 파서 규약을 잠그지만 **실물 파일이 그대로 들어갔을 때 무슨 일이 나는지**는 못 본다.
/// 실제로 그 틈에 사고가 하나 숨어 있었다 — 아래 `testShippedShaderFilesAreCRLF` 참조.
///
/// 이 파일이 잠그는 것 셋:
///  1. 동봉 `WEAssets` 에서 오디오 어노테이션을 가진 셰이더가 **정확히 둘**이라는 인구조사.
///  2. 그 둘의 파스 결과가 이름표 폴백(`declaredDefaults(effectName:)`)과 **전건 같다**는 것
///     — 즉 `SceneRendererResources.audioParams` 를 리터럴에서 파서로 옮긴 변경이 동봉 코퍼스
///     전건에서 **비트동일**이라는 근거다. 워크샵 코퍼스는 이 컨테이너에 없어 **미측정**.
///  3. 실물이 **CRLF** 라 원문을 그대로 넘기면 파서가 nil 을 준다는 것(그래서 호출부가 정규화한다).
final class AudioAnnotationCorpusTests: XCTestCase {

    /// 동봉 자산 루트(`BlendModeDomainTests.assetsRoot` 와 같은 규약).
    private static func assetsRoot() -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
           fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func lfNormalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func shaderText(_ rel: String) throws -> String {
        let root = try XCTUnwrap(Self.assetsRoot(), "동봉 WEAssets 를 못 찾았다(WAPLE_WE_ASSETS)")
        let url = root.appendingPathComponent(rel)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: 1) CRLF — 원문 그대로는 파서가 못 읽는다

    /// **동봉 `.vert` 는 CRLF 다.** `file(1)` 실측: `pulse.vert`·`shake.vert` 둘 다
    /// `CRLF line terminators`, CRLF 83 / LF 83(= LF 단독 0줄).
    ///
    /// 그런데 `declaredDefaults(shaderSource:)` 는 `split(separator: "\n")` 으로 쪼갠다.
    /// Swift 문자열은 그래핌 클러스터 단위라 **`"\r\n"` 이 한 개의 `Character`** 이고 `"\n"` 과
    /// 같지 않다(공통 브리프 함정 11 — `AssetJSON.relaxed` 와 `BlendModeDomainTests` 가 같은 것에
    /// 당했다). 그래서 CRLF 파일은 **한 줄**이 되고, 그 한 줄의 첫 `//` 앞이 `uniform ` 으로
    /// 시작하지 않으므로 파서가 다섯 키를 **하나도** 못 잡아 nil 을 돌려준다.
    ///
    /// 이 단정이 값으로 못 박는 것: 파서를 붙이는 것만으로는 기능이 살지 않는다. 호출부
    /// (`SceneRendererResources.audioAnnotationSource`)가 LF 로 정규화해서 넘겨야 한다.
    /// 파서 자체를 `isNewline` 으로 고치면 이 테스트의 첫 단정이 뒤집히므로, 그때 이 주석과
    /// 단정을 같이 고쳐라 — 조용히 지나가지 않는다.
    func testShippedShaderFilesAreCRLFSoRawSourceParsesToNil() throws {
        for rel in ["effects/pulse/shaders/effects/pulse.vert",
                    "effects/shake/shaders/effects/shake.vert"] {
            let raw = try shaderText(rel)
            XCTAssertTrue(raw.contains("\r\n"), "\(rel) 이 더 이상 CRLF 가 아니다")
            XCTAssertFalse(raw.contains("g_AudioBounds") && raw.contains("\n") && !raw.contains("\r\n"),
                           "\(rel) 이 LF 단독이면 이 테스트의 전제가 바뀐다")
            XCTAssertNil(AudioResponse.declaredDefaults(shaderSource: raw),
                         "\(rel): CRLF 원문은 파서가 못 읽는다 — 못 읽는 것이 지금의 계약이다")
            XCTAssertNotNil(AudioResponse.declaredDefaults(shaderSource: Self.lfNormalized(raw)),
                            "\(rel): LF 로 정규화하면 파스돼야 한다")
        }
    }

    // MARK: 2) 실물 파스 결과 = 손으로 적은 표

    /// 실물 두 파일이 `pulseDefaults`/`shakeDefaults` 를 **그대로** 준다.
    /// 인라인 픽스처가 아니라 파일에서 읽으므로, 자산이 갱신되면 여기서 갈린다.
    func testShippedShadersParseToTheNameTable() throws {
        let pulse = AudioResponse.declaredDefaults(
            shaderSource: Self.lfNormalized(try shaderText("effects/pulse/shaders/effects/pulse.vert")))
        let shake = AudioResponse.declaredDefaults(
            shaderSource: Self.lfNormalized(try shaderText("effects/shake/shaders/effects/shake.vert")))
        XCTAssertEqual(pulse, AudioResponse.pulseDefaults)
        XCTAssertEqual(shake, AudioResponse.shakeDefaults)
        XCTAssertEqual(pulse?.bounds, SIMD2<Float>(0.5, 1.0))
        XCTAssertEqual(shake?.bounds, SIMD2<Float>(0.0, 1.2))
        // 나머지 넷은 두 파일이 같다 — 갈리는 것은 `audiobounds` 하나뿐이라는 §9.1 표의 재확인.
        XCTAssertEqual(pulse?.freqMin, 0);  XCTAssertEqual(shake?.freqMin, 0)
        XCTAssertEqual(pulse?.freqMax, 1);  XCTAssertEqual(shake?.freqMax, 1)
        XCTAssertEqual(pulse?.power, 1);    XCTAssertEqual(shake?.power, 1)
        XCTAssertEqual(pulse?.multiply, 1); XCTAssertEqual(shake?.multiply, 1)
    }

    // MARK: 3) 인구조사 — 어노테이션을 가진 셰이더는 둘, 갈리는 이펙트는 0개

    /// **동봉 `WEAssets` 전수에서 오디오 어노테이션 셰이더는 2파일이다**(2026-08-21 실측).
    /// 그리고 그 둘 다 이름표 폴백과 파스 결과가 같으므로 **값이 갈리는 이펙트는 0개**다.
    ///
    /// 이 0 이 `SceneRendererResources.audioParams` 의 리터럴→파서 전환이 동봉 코퍼스 전건에서
    /// 비트동일이라는 근거다. **0 은 "리터럴로 둬도 된다" 는 뜻이 아니다** — 워크샵 셰이더는
    /// 이 컨테이너에 없어 미측정이고, 파서가 있어야 그쪽에서 추정으로 안 떨어진다.
    ///
    /// 스캔 규약은 파서와 같다: `//` 앞이 `uniform ` 으로 시작하는 줄만 보고 `"material"` 값으로
    /// 건다(유니폼 이름으로 걸면 `g_AudioPower`/`g_AudioMultiply` 때문에 둘을 놓친다).
    func testBundledCorpusCensusAndZeroDivergentEffects() throws {
        let root = try XCTUnwrap(Self.assetsRoot(), "동봉 WEAssets 를 못 찾았다(WAPLE_WE_ASSETS)")
        let fm = FileManager.default
        let en = try XCTUnwrap(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var withAudio: [(rel: String, parsed: AudioResponse.ShaderDefaults)] = []
        for case let url as URL in en {
            guard ["vert", "frag", "h"].contains(url.pathExtension) else { continue }
            scanned += 1
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let parsed = AudioResponse.declaredDefaults(shaderSource: Self.lfNormalized(raw)) else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            withAudio.append((rel, parsed))
        }
        XCTAssertGreaterThan(scanned, 400, "셰이더 스캔이 비었다 — 자산 배치가 바뀌었나")
        XCTAssertEqual(withAudio.count, 2,
                       "오디오 어노테이션 셰이더 수가 2 가 아니다: \(withAudio.map(\.rel).sorted())")
        XCTAssertEqual(Set(withAudio.map(\.rel)),
                       ["effects/pulse/shaders/effects/pulse.vert",
                        "effects/shake/shaders/effects/shake.vert"])
        // 갈리는 이펙트 수 = 0. 이름표는 파일명 basename(= 이펙트 이름) 으로 만든다.
        var divergent: [String] = []
        for hit in withAudio {
            let name = (hit.rel as NSString).lastPathComponent
                .replacingOccurrences(of: ".vert", with: "")
            if hit.parsed != AudioResponse.declaredDefaults(effectName: name) { divergent.append(hit.rel) }
        }
        XCTAssertEqual(divergent, [], "이름표 폴백과 갈리는 셰이더가 생겼다 — 표를 다시 재라")
    }
}
