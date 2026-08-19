import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender
import WapleSnapshot

/// `colorBlendMode` 32종이 **실제로 픽셀까지 도달하는지** 본다.
///
/// README 는 32종 전부 구현이라고 적고 `BlendMSL.applyBlending` 도 32개 case 를 갖고 있지만,
/// 픽셀까지 구동되는 것은 `BlendModeLayerTests` 의 2·18 과 기본 0 — **셋뿐**이었다.
/// 나머지 29종은 "코드가 있다" 와 "그린다" 사이가 비어 있었다. 셰이더가 통째로 폴백해도,
/// 스위치가 default 로 새도 아무 테스트가 울지 않는다.
///
/// ## 수식을 다시 구현하지 않는다
///
/// 32종의 기대 픽셀을 테스트에서 계산하려면 `common_blending.h` 를 Swift 로 옮겨야 하는데,
/// 그건 이 리포가 이미 당한 함정이다 — `SnapshotTests` 가 `relDiff`/`structureLoss` 를
/// 인라인으로 재구현해 **자기 산수를 단언**했고, 프로덕션 로직을 지워도 통과했다.
///
/// 대신 **렌더 결과 사이의 관계**만 본다. 관계는 구현(`BlendMSL.swift`)에서 직접 읽히고,
/// 수식을 옮기지 않아도 강하게 구속한다.
///
///   · `case 4` 와 `case 20` 은 문자 그대로 같은 식 `max(A+B-1, 0)` → 출력이 같아야 한다.
///   · `case 5`(Min)·`case 10`(Max)·`case 31` 은 `return` 으로 **최종 `mix(A, r, o)` 를
///     건너뛴다** → 5·10 은 opacity 를 바꿔도 출력이 변하지 않아야 한다.
///   · `case 1`(Darken)은 `min(A,B)` 를 mix 하므로 o=1 에서 `case 5` 와 같고,
///     `case 6`(Lighten)은 같은 이유로 o=1 에서 `case 10` 과 같아야 한다.
///   · 32종의 출력이 서로 충분히 갈려야 한다 — 전부 알파 합성으로 붕괴돼 있으면
///     여기서 잡힌다.
final class BlendModeCoverageTests: XCTestCase {

    /// 흰색을 배경으로 쓰면 많은 모드가 퇴화한다(min(1,B)=B, max(1,B)=1, 1*B=B …).
    /// 채널마다 값이 다른 중간색 둘을 써서 모드가 서로 갈리게 한다.
    private static let baseRGB: (UInt8, UInt8, UInt8) = (153, 77, 204)
    private static let overlayRGB: (UInt8, UInt8, UInt8) = (51, 179, 102)
    private static let width = 64
    private static let height = 36

    /// 모드 하나를 렌더해 RGBA 를 돌려준다.
    private func render(mode: Int, alpha: Float) throws -> [UInt8] {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/a.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/b.json","origin":"960 540 0","size":"1920 1080",
            "alpha":\(alpha),"colorBlendMode":\(mode)}]}
        """
        let dir = try tempDir()
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/a.json", #"{"material":"materials/a.json"}"#.data(using: .utf8)!),
            ("materials/a.json", #"{"passes":[{"textures":["a"]}]}"#.data(using: .utf8)!),
            ("materials/a.tex", solidTex(Self.baseRGB.0, Self.baseRGB.1, Self.baseRGB.2)),
            ("models/b.json", #"{"material":"materials/b.json"}"#.data(using: .utf8)!),
            ("materials/b.json", #"{"passes":[{"textures":["b"]}]}"#.data(using: .utf8)!),
            ("materials/b.tex", solidTex(Self.overlayRGB.0, Self.overlayRGB.1, Self.overlayRGB.2)),
        ]
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))

        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height)),
                    project: project(id: "bm\(mode)_\(Int(alpha * 100))", fileName: "scene.pkg", dir: dir))
        defer { r.teardown() }
        let out = try tempDir()
        let url = try XCTUnwrap(r.captureFrames(width: Self.width, height: Self.height,
                                                times: [0.1], toDir: out).first,
                                "mode \(mode): captureFrames 가 아무것도 내지 않았다")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var px = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        guard let cg = rep.cgImage else {
            throw NSError(domain: "BlendModeCoverage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cgImage 없음(mode \(mode))"])
        }
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: Self.width, height: Self.height,
                                      bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard ok else {
            throw NSError(domain: "BlendModeCoverage", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext 생성 실패(mode \(mode))"])
        }
        return px
    }

    private func same(_ a: [UInt8], _ b: [UInt8]) -> Bool { passes(diffRGBA(a, b), .strict) }

    /// 중앙 픽셀 RGB — 서로 다른 모드를 구분하는 서명으로 쓴다(전면 단색이라 중앙이 대표한다).
    private func centerRGB(_ px: [UInt8]) -> [UInt8] {
        let i = ((Self.height / 2) * Self.width + Self.width / 2) * 4
        return [px[i], px[i + 1], px[i + 2]]
    }

    /// 32종 전부 그려지고, 서로 충분히 갈리는가.
    ///
    /// 붕괴 검출이 목적이다 — 셰이더가 폴백하거나 스위치가 default 로 새면 결과가 한두
    /// 종류로 수렴한다. 정확한 값은 여기서 판정하지 않는다(그건 관계 테스트가 한다).
    func testAllThirtyTwoModesRenderAndStayDistinct() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        var signatures: [Int: [UInt8]] = [:]
        for mode in 1...32 {
            let px = try render(mode: mode, alpha: 1.0)
            let luma = meanLuma(rgba: px)
            XCTAssertGreaterThan(luma, 0.01, "mode \(mode): 사실상 검은 프레임(meanLuma \(luma))")
            signatures[mode] = centerRGB(px)
        }
        let distinct = Set(signatures.values.map { "\($0[0]),\($0[1]),\($0[2])" })
        print("[BlendModeCoverage] 32종 중 서로 다른 출력 \(distinct.count)종")
        for m in (1...32).sorted() {
            print("[BlendModeCoverage]   mode \(m): \(signatures[m]!)")
        }
        // 하한은 보수적으로 둔다. 일부 모드가 이 색 조합에서 우연히 겹치는 것은 정상이고
        // (4≡20 은 설계상 동일), 잡으려는 것은 "전부 한두 종류로 붕괴" 다.
        XCTAssertGreaterThanOrEqual(distinct.count, 12,
            "32종이 \(distinct.count)종으로 붕괴했다 — 블렌딩이 통째로 폴백했을 가능성이 크다")
    }

    /// `BlendMSL.applyBlending` 에서 직접 읽히는 항등·비항등 관계.
    /// 수식이 아니라 **구현의 구조**를 단언한다.
    func testIdentitiesReadOffTheImplementation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }

        // case 4 와 case 20 은 같은 식이다: max(A + B - 1.0, 0.0)
        XCTAssertTrue(same(try render(mode: 4, alpha: 1.0), try render(mode: 20, alpha: 1.0)),
                      "case 4(Subtract)와 case 20 은 같은 식인데 출력이 갈렸다")

        // case 5(Min)·case 10(Max) 은 `return` 으로 최종 mix(A, r, o) 를 건너뛴다
        // → opacity 를 바꿔도 출력이 변하지 않아야 한다.
        XCTAssertTrue(same(try render(mode: 5, alpha: 1.0), try render(mode: 5, alpha: 0.35)),
                      "case 5(Min)가 opacity 에 반응했다 — 구현은 mix 를 건너뛴다")
        XCTAssertTrue(same(try render(mode: 10, alpha: 1.0), try render(mode: 10, alpha: 0.35)),
                      "case 10(Max)가 opacity 에 반응했다 — 구현은 mix 를 건너뛴다")

        // 대조군: case 1(Darken)은 같은 min(A,B) 를 쓰지만 mix 를 거치므로 opacity 에 반응해야
        // 한다. 이게 없으면 위 두 단언은 "그냥 알파가 통째로 안 먹는다" 로도 통과한다.
        XCTAssertFalse(same(try render(mode: 1, alpha: 1.0), try render(mode: 1, alpha: 0.35)),
                       "case 1(Darken)이 opacity 를 무시했다 — 알파 경로 자체가 죽었을 수 있다")

        // o=1 이면 mix(A, r, 1) == r 이므로 mix 를 타는 쪽과 건너뛰는 쪽이 같아져야 한다.
        XCTAssertTrue(same(try render(mode: 1, alpha: 1.0), try render(mode: 5, alpha: 1.0)),
                      "o=1 에서 case 1(Darken)과 case 5(Min)가 갈렸다")
        XCTAssertTrue(same(try render(mode: 6, alpha: 1.0), try render(mode: 10, alpha: 1.0)),
                      "o=1 에서 case 6(Lighten)과 case 10(Max)이 갈렸다")

        // 인자 순서가 뒤바뀐 쌍은 서로 달라야 한다 — 같아지면 스왑이 반영되지 않은 것이다.
        // case 11 Overlay = we_overlay(A,B) vs case 13 HardLight = we_overlay(B,A)
        XCTAssertFalse(same(try render(mode: 11, alpha: 1.0), try render(mode: 13, alpha: 1.0)),
                       "Overlay(11)와 HardLight(13)가 같다 — we_overlay 의 인자 스왑이 반영되지 않았다")
        // case 21 Reflect = we_reflect(A,B) vs case 22 Glow = we_reflect(B,A)
        XCTAssertFalse(same(try render(mode: 21, alpha: 1.0), try render(mode: 22, alpha: 1.0)),
                       "Reflect(21)와 Glow(22)가 같다 — we_reflect 의 인자 스왑이 반영되지 않았다")
    }
}
