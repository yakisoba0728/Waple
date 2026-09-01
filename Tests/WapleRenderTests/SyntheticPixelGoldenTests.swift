import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender
import WapleSnapshot

/// **CI 에서 도는 픽셀 골든.** 지금까지 이 리포에 없던 축이다.
///
/// 커밋된 스냅샷 기준선(`spec/golden/snapshot/`, 썸네일 340장)은 실물 코퍼스가 있어야
/// 뜨고, 비교는 로컬 맥에서 손으로 도는 `scripts/mac-session/golden-gate.sh:96` 하나뿐이다
/// (`spec/golden/gate-analysis.json` → `oracle.gate.compareWiring.ciCallSites` 가 문자 그대로 `[]`).
/// 그래서 렌더러를 고쳐도 **픽셀 회귀를 자동으로 잡는 장치가 없었다** — 스위트 안의 유일한
/// 골든 테스트 `GoldenBaselineOracleTests` 는 manifest.json 을 자기 자신과 대조한다.
/// 값진 검사지만 검증 대상이 렌더러가 아니라 JSON 파일이다.
///
/// 이 테스트는 씬을 **코드로 합성**해서 그 구멍을 메운다. 코퍼스가 필요 없으므로
/// CI 러너에서 그대로 돈다(Metal 은 CI 에서 정상 동작한다 — 실측 스킵 46/2270).
///
/// ## 기준선 만들기
///
/// ```
/// WAPLE_GOLDEN_BOOTSTRAP=1 swift test --filter SyntheticPixelGolden
/// ```
/// `spec/golden/synthetic/<이름>.png` 를 쓰고 스킵한다. 그 PNG 를 커밋하면 그때부터 게이트다.
///
/// **기준선이 없으면 스킵이 아니라 실패다.** 없을 때 조용히 만들고 통과하는 설계는
/// 이 리포가 이미 한 번 당했다(`RealPackagesGroundTruthTests` 의 `/tmp/waple_gt/luma_baseline.json`
/// 은 새 머신에서 영원히 실패할 수 없다). 만들기는 위 환경변수를 **명시할 때만** 한다.
final class SyntheticPixelGoldenTests: XCTestCase {

    // MARK: - 대상 씬
    //
    // 실물 코퍼스 대신 코드로 만든다. 고르는 기준은 "고친 적 있는 경로를 지나갈 것":
    // 알파 합성 · colorBlendMode(common_blending.h) · 텍스처 샘플링(그라디언트, 보간).
    // 단색 플랫이 아닌 그라디언트를 하나 넣는 이유는, 단색만 있으면 샘플러/보간이
    // 깨져도 평균이 그대로라 통과하기 때문이다.

    private struct Case {
        let name: String
        let scene: String
        let files: [(String, Data)]
    }

    /// 흰 배경 + 오버레이 한 장. mode 를 바꿔 블렌딩 경로를 지나간다.
    private func overlayCase(name: String, mode: Int, alpha: Float,
                             overlayTex: Data) -> Case {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/o.json","origin":"960 540 0","size":"1440 810",
            "alpha":\(alpha),"colorBlendMode":\(mode)}]}
        """
        return Case(name: name, scene: scene, files: [
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/o.json", #"{"material":"materials/o.json"}"#.data(using: .utf8)!),
            ("materials/o.json", #"{"passes":[{"textures":["o"]}]}"#.data(using: .utf8)!),
            ("materials/o.tex", overlayTex),
        ])
    }

    private func cases() -> [Case] {
        [
            // 알파 합성 — 절반 투명 빨강이 흰 위에. 알파 프리멀티플라이가 어긋나면 색이 튄다.
            overlayCase(name: "alpha-red-over-white", mode: 0, alpha: 0.5,
                        overlayTex: solidTex(255, 0, 0)),
            // multiply(2) — 흰×빨강=빨강. 구현이 없으면 일반 합성이라 같은 답이 나오므로
            // 아래 difference 와 **쌍으로** 봐야 의미가 있다.
            overlayCase(name: "blend-multiply", mode: 2, alpha: 1,
                        overlayTex: solidTex(255, 0, 0)),
            // difference(18) — 흰 vs 흰 = 검정. 일반 합성이면 흰색이 남아 갈린다.
            overlayCase(name: "blend-difference", mode: 18, alpha: 1,
                        overlayTex: solidTex(255, 255, 255)),
            // 세로 그라디언트 — 텍스처 샘플링·보간이 픽셀에 남는 케이스.
            overlayCase(name: "gradient-vertical", mode: 0, alpha: 1,
                        overlayTex: verticalGradientTex(top: (255, 32, 32), bottom: (32, 32, 255))),
            // 가로 그라디언트 — **좌우 미러링을 잡는 유일한 케이스**.
            // [2026-08-19] 종전 4종은 단색 셋 + 세로 그라디언트 하나라 x 축이 뒤집혀도
            // 픽셀이 그대로였다(단색은 대칭, 세로 그라디언트는 x 에 불변). uv.x 부호나
            // 정점 winding 이 뒤집히는 회귀가 이 세트를 그냥 통과했다는 뜻이다.
            // 헬퍼는 이미 있었다(`TestSupport.swift:89`) — 골든 세트만 안 쓰고 있었다.
            overlayCase(name: "gradient-horizontal", mode: 0, alpha: 1,
                        overlayTex: horizontalGradientTex(left: (255, 32, 32), right: (32, 32, 255))),
        ]
    }

    // MARK: - 경로

    /// 리포 루트 기준 `spec/golden/synthetic/`.
    /// 테스트 바이너리는 `.build` 안이므로 소스 위치에서 거슬러 올라간다
    /// (`GoldenBaselineOracleTests.load` 와 동일한 검증된 방식).
    private static var baselineDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WapleRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("spec/golden/synthetic", isDirectory: true)
    }

    private static let width = 128
    private static let height = 72
    /// 캡처 시각을 고정한다 — 애니메이션이 없는 씬이지만 시각이 흔들리면 비교가 흔들린다.
    private static let captureTime: Float = 0.1

    // MARK: - 렌더

    private func renderRGBA(_ c: Case) throws -> [UInt8] {
        let dir = try tempDir()
        var files = c.files
        files.append(("scene.json", c.scene.data(using: .utf8)!))
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))

        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0,
                                                    width: Self.width, height: Self.height)),
                           project: project(id: c.name, fileName: "scene.pkg", dir: dir))
        defer { renderer.teardown() }

        let out = try tempDir()
        let url = try XCTUnwrap(renderer.captureFrames(width: Self.width, height: Self.height,
                                                       times: [Self.captureTime], toDir: out).first,
                                "\(c.name): captureFrames 가 아무것도 내지 않았다")
        return try Self.rgba(ofPNGAt: url)
    }

    /// PNG → 패딩 없는 RGBA8. `NSBitmapImageRep.bitmapData` 를 그대로 쓰지 않는 이유는
    /// bytesPerRow 에 정렬 패딩이 붙을 수 있어 폭×4 를 가정한 비교가 어긋나기 때문이다.
    /// 알려진 레이아웃의 컨텍스트에 다시 그려서 확정한다.
    private static func rgba(ofPNGAt url: URL) throws -> [UInt8] {
        let data = try Data(contentsOf: url)
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            // 스킵이 아니라 에러다 — 스킵은 통과로 집계되므로 디코드가 깨진 채로 초록이 뜬다.
            throw NSError(domain: "SyntheticPixelGolden", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "PNG 디코드 실패: \(url.lastPathComponent)",
            ])
        }
        let w = width, h = height
        guard rep.pixelsWide == w, rep.pixelsHigh == h else {
            throw NSError(domain: "SyntheticPixelGolden", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "크기 불일치 \(rep.pixelsWide)x\(rep.pixelsHigh) (기대 \(w)x\(h)) — \(url.lastPathComponent)",
            ])
        }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else {
            throw NSError(domain: "SyntheticPixelGolden", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext 생성 실패"])
        }
        return px
    }

    // MARK: - 게이트

    func testSyntheticScenesMatchCommittedGolden() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let bootstrapping = ProcessInfo.processInfo.environment["WAPLE_GOLDEN_BOOTSTRAP"] == "1"
        let dir = Self.baselineDir
        if bootstrapping {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var missing: [String] = []
        var failures: [String] = []

        // **[정정 2026-09-01] `cases()` 목록이 줄어드는 것을 잡을 단언이 없었다.**
        // 종전엔 `for c in cases()` 뿐이라, 목록이 한 종으로 줄어도 남은 하나가 기준선과
        // 맞으면 그대로 초록이었다. 특히 `gradient-horizontal` 은 이 세트에서 **좌우
        // 미러링을 잡는 유일한 케이스**라(아래 cases() 주석의 2026-08-19 이력) 그것만
        // 빠져도 uv.x 부호·정점 winding 회귀가 다시 통과한다.
        // 형제 오라클은 정확히 이런 카운트 게이트를 둔다
        // (`GoldenBaselineOracleTests` 의 `XCTAssertEqual(b.entries.count, 170)` 두 자리).
        let all = cases()
        XCTAssertEqual(all.count, 5, "합성 골든 케이스가 5종이어야 한다 — 목록이 줄었다")
        XCTAssertEqual(Set(all.map(\.name)).count, all.count,
                       "케이스 이름이 중복이다 — 기준선 PNG 가 서로 덮인다")
        XCTAssertTrue(all.contains { $0.name == "gradient-horizontal" },
                      "좌우 미러링을 잡는 유일한 케이스가 빠졌다")

        var compared = 0
        for c in all {
            let actual = try renderRGBA(c)

            // 전면 단색(특히 검정)은 "렌더가 아예 안 됐다" 의 전형이다. 기준선과 비교하기
            // 전에 먼저 거른다 — 기준선 자체가 검정으로 떠 있으면 비교는 영원히 통과한다.
            let luma = meanLuma(rgba: actual)
            XCTAssertGreaterThan(luma, 0.02, "\(c.name): 사실상 검은 프레임(meanLuma \(luma))")

            let ref = dir.appendingPathComponent("\(c.name).png")
            if bootstrapping {
                let png = try XCTUnwrap(OffscreenCapture.png(rgba: actual,
                                                             width: Self.width, height: Self.height),
                                        "\(c.name): PNG 인코드 실패")
                try png.write(to: ref)
                continue
            }
            guard FileManager.default.fileExists(atPath: ref.path) else {
                missing.append(c.name)
                continue
            }

            let expected = try Self.rgba(ofPNGAt: ref)
            compared += 1
            let m = diffRGBA(expected, actual)
            // 측정값은 통과해도 남긴다 — 임계값을 나중에 근거 있게 조일 수 있게.
            print("[SyntheticPixelGolden] \(c.name): meanAbsDiff=\(m.meanAbsDiff) "
                  + "fracExceeding=\(m.fracExceeding) meanLuma=\(luma)")
            if !passes(m, .strict) {
                failures.append("\(c.name): meanAbsDiff=\(m.meanAbsDiff) fracExceeding=\(m.fracExceeding)")
            }
        }

        if bootstrapping {
            throw XCTSkip("기준선을 \(dir.path) 에 썼다 — 확인 후 커밋하면 그때부터 게이트다")
        }
        if !missing.isEmpty {
            XCTFail("""
                기준선 없음: \(missing.joined(separator: ", ")).
                `WAPLE_GOLDEN_BOOTSTRAP=1 swift test --filter SyntheticPixelGolden` 로 만들고 커밋할 것.
                (없을 때 조용히 만들고 통과시키지 않는다 — 그러면 게이트가 아니라 도장이 된다.)
                """)
        }
        // 위 missing 이 비어 있어도, 실제로 몇 종을 대조했는지 함께 못 박는다 —
        // "0종 비교 후 무회귀" 를 초록으로 내지 않기 위한 모집단 하한이다.
        XCTAssertEqual(compared, all.count,
                       "대조한 케이스가 \(compared)/\(all.count)종 — 기준선이 일부만 있다")
        if !failures.isEmpty {
            XCTFail("""
                픽셀 회귀 \(failures.count)건:
                \(failures.joined(separator: "\n"))
                의도한 변경이면 위 부트스트랩 명령으로 다시 뜨고, **눈으로 확인한 뒤** 커밋할 것.
                """)
        }
    }

    /// 게이트가 실제로 회귀를 잡는지 스스로 검증한다(음성 대조).
    ///
    /// 픽셀 골든의 고전적 실패는 "비교는 도는데 무엇도 못 잡는" 상태다. 여기서는
    /// 기준선과 **다르게 만든** 프레임이 반드시 걸리는지를 본다 — 걸리지 않으면
    /// 임계값이나 비교 자체가 무의미하다는 뜻이다.
    func testGateActuallyCatchesADifference() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let red = try renderRGBA(overlayCase(name: "neg-a", mode: 0, alpha: 1,
                                             overlayTex: solidTex(255, 0, 0)))
        let blue = try renderRGBA(overlayCase(name: "neg-b", mode: 0, alpha: 1,
                                              overlayTex: solidTex(0, 0, 255)))
        let m = diffRGBA(red, blue)
        XCTAssertFalse(passes(m, .strict),
                       "빨강과 파랑 프레임이 strict 를 통과했다 — 비교가 아무것도 잡지 못한다는 뜻")
        // 같은 씬을 두 번 그리면 통과해야 한다(그렇지 않으면 게이트가 상시 빨강이 된다).
        let redAgain = try renderRGBA(overlayCase(name: "neg-a2", mode: 0, alpha: 1,
                                                  overlayTex: solidTex(255, 0, 0)))
        let same = diffRGBA(red, redAgain)
        print("[SyntheticPixelGolden] 자기일관성: meanAbsDiff=\(same.meanAbsDiff) "
              + "fracExceeding=\(same.fracExceeding)")
        XCTAssertTrue(passes(same, .strict),
                      "동일 씬 재렌더가 strict 를 통과하지 못했다 — 임계값이 너무 빡빡하거나 렌더가 비결정적이다")
    }
}
