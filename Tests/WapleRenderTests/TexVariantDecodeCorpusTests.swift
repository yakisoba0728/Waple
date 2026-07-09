import XCTest
@testable import WapleRender
import WapleCore

/// 실물 검증(코퍼스 존재 시만): childlink_01.tex(젤다 아동 링크) 의 조건 변형이 tuniccolor 값에 따라
/// 서로 다른 색을 디코드하는지 — 파스→선택→디코드 전 경로를 실제 TexDecoder 로 통과. 코퍼스 없으면 스킵.
final class TexVariantDecodeCorpusTests: XCTestCase {
    private static let pkgPath = "/Users/yakisoba/Downloads/wallpaper_dev/backgrounds/3737268876/scene.pkg"

    func testChildlinkTunicVariantsDecodeDistinctColors() throws {
        guard FileManager.default.fileExists(atPath: Self.pkgPath) else {
            throw XCTSkip("corpus scene.pkg 부재 — 실물 변형 디코드 검증 스킵")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.pkgPath))
        let pkg = try ScenePackage.parse(data)
        let name = "materials/models/link_child/childlink_01.tex"
        guard let texData = pkg.data(for: name), let tex = TexImage.parse(texData) else {
            return XCTFail("childlink_01.tex 파스 실패")
        }
        XCTAssertEqual(tex.payload, .bc3)
        XCTAssertEqual(tex.variants.count, 3, "childlink = 변형 3")
        // 조건 실물 문법 확인.
        XCTAssertEqual(Set(tex.variants.map { $0.condition.name }), ["tuniccolor"])
        XCTAssertEqual(Set(tex.variants.map { $0.condition.value }), ["1", "2", "3"])

        func avg(_ tunic: String) -> SIMD3<Double>? {
            guard let d = TexDecoder.rgba(from: tex, data: texData,
                                          properties: ["tuniccolor": .string(tunic)]) else { return nil }
            return Self.alphaWeightedAvg(d.pixels)
        }
        guard let green = avg("0"), let red = avg("1"), let blue = avg("2"), let dark = avg("3") else {
            return XCTFail("디코드 실패")
        }
        func fmt(_ c: SIMD3<Double>) -> String { String(format: "(%.0f,%.0f,%.0f)", c.x, c.y, c.z) }
        print("[variant] tuniccolor 0/green=\(fmt(green)) 1/red=\(fmt(red)) 2/blue=\(fmt(blue)) 3/dark=\(fmt(dark))")

        // 4색이 서로 유의미하게 다름(디코드 RGBA 평균이 변형 간 상이).
        let colors = [("green", green), ("red", red), ("blue", blue), ("dark", dark)]
        for i in 0..<colors.count {
            for j in (i + 1)..<colors.count {
                let d = Self.dist(colors[i].1, colors[j].1)
                XCTAssertGreaterThan(d, 12, "변형색 \(colors[i].0)≠\(colors[j].0) (dist=\(String(format: "%.1f", d)))")
            }
        }
        // 도미넌트 채널이 튜닉색과 일치(선택이 올바른 변형을 골랐다는 강한 불변식).
        XCTAssertTrue(green.y > green.x && green.y > green.z, "tuniccolor=0 → 기본=초록(G 우세) \(fmt(green))")
        XCTAssertTrue(red.x > red.y && red.x > red.z, "tuniccolor=1 → 빨강(R 우세) \(fmt(red))")
        XCTAssertTrue(blue.z > blue.x && blue.z > blue.y, "tuniccolor=2 → 파랑(B 우세) \(fmt(blue))")
    }

    /// 알파 가중 RGB 평균(가시 픽셀 중심 — 투명부의 임의 RGB 배제).
    static func alphaWeightedAvg(_ rgba: Data) -> SIMD3<Double> {
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let s = p.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 < s.count {
                let a = Double(s[i + 3])
                r += Double(s[i]) * a; g += Double(s[i + 1]) * a; b += Double(s[i + 2]) * a; wsum += a
                i += 4
            }
        }
        guard wsum > 0 else { return SIMD3(0, 0, 0) }
        return SIMD3(r / wsum, g / wsum, b / wsum)
    }

    static func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }
}
