import XCTest
import simd
@testable import WapleRender

/// 앨범아트 주색 추출(순수 함수): 4bit/채널 양자화 히스토그램 → 최빈 버킷 평균 = primary,
/// primary 와 충분히 다른 차순위 = secondary/tertiary, 텍스트/고대비색은 primary 휘도로 흑/백.
final class ArtworkColorsTests: XCTestCase {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, count: Int) -> [UInt8] {
        var px: [UInt8] = []
        px.reserveCapacity(count * 4)
        for _ in 0..<count { px.append(contentsOf: [r, g, b, 255]) }
        return px
    }

    func testSolidColorIsPrimary() throws {
        let p = try XCTUnwrap(ArtworkColors.palette(rgba: solid(255, 0, 0, count: 16), width: 4, height: 4))
        XCTAssertEqual(p.primary.x, 1, accuracy: 0.05)
        XCTAssertEqual(p.primary.y, 0, accuracy: 0.05)
        XCTAssertEqual(p.primary.z, 0, accuracy: 0.05)
        // 단색 → secondary/tertiary 는 primary 로 폴백.
        XCTAssertEqual(p.secondary, p.primary)
        XCTAssertEqual(p.tertiary, p.secondary)
    }

    func testTwoToneMajorityAndSecondary() throws {
        // 빨강 12 + 파랑 4 → primary 빨강, secondary 파랑.
        let px = solid(255, 0, 0, count: 12) + solid(0, 0, 255, count: 4)
        let p = try XCTUnwrap(ArtworkColors.palette(rgba: px, width: 4, height: 4))
        XCTAssertEqual(p.primary.x, 1, accuracy: 0.05)
        XCTAssertEqual(p.secondary.z, 1, accuracy: 0.05)
        XCTAssertLessThan(p.secondary.x, 0.1)
    }

    func testThreeToneTertiary() throws {
        let px = solid(255, 0, 0, count: 8) + solid(0, 255, 0, count: 5) + solid(0, 0, 255, count: 3)
        let p = try XCTUnwrap(ArtworkColors.palette(rgba: px, width: 4, height: 4))
        XCTAssertEqual(p.primary.x, 1, accuracy: 0.05)
        XCTAssertEqual(p.secondary.y, 1, accuracy: 0.05)
        XCTAssertEqual(p.tertiary.z, 1, accuracy: 0.05)
    }

    /// 어두운 primary → 흰 텍스트, 밝은 primary → 검정 텍스트(고대비 동일 규칙).
    func testTextColorContrast() throws {
        let dark = try XCTUnwrap(ArtworkColors.palette(rgba: solid(20, 20, 40, count: 16), width: 4, height: 4))
        XCTAssertEqual(dark.textColor, SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(dark.highContrast, SIMD3<Float>(1, 1, 1))
        let light = try XCTUnwrap(ArtworkColors.palette(rgba: solid(240, 240, 220, count: 16), width: 4, height: 4))
        XCTAssertEqual(light.textColor, SIMD3<Float>(0, 0, 0))
    }

    /// 투명 픽셀은 무시. 전부 투명 → nil.
    func testAlphaIgnored() {
        var px = solid(255, 0, 0, count: 8) + solid(0, 255, 0, count: 8)
        for i in 0..<8 { px[i * 4 + 3] = 0 }  // 빨강을 전부 투명화
        let p = ArtworkColors.palette(rgba: px, width: 4, height: 4)
        XCTAssertEqual(p?.primary.y ?? 0, 1, accuracy: 0.05, "투명 빨강 무시 → 초록이 primary")
        var clear = solid(1, 2, 3, count: 4)
        for i in 0..<4 { clear[i * 4 + 3] = 0 }
        XCTAssertNil(ArtworkColors.palette(rgba: clear, width: 2, height: 2))
        XCTAssertNil(ArtworkColors.palette(rgba: [], width: 0, height: 0))
    }

    /// 웹 배달 포맷(실물 3639973107 이 #RRGGBB 를 파싱): 0..1 Vec3 → "#RRGGBB".
    func testHexString() {
        XCTAssertEqual(ArtworkColors.hexString(SIMD3<Float>(1, 0, 0)), "#FF0000")
        XCTAssertEqual(ArtworkColors.hexString(SIMD3<Float>(0, 0.5, 1)), "#0080FF")
        XCTAssertEqual(ArtworkColors.hexString(SIMD3<Float>(-1, 2, 0)), "#00FF00", "클램프")
    }

    /// 인코딩 이미지(PNG 바이트) 경로: 디코드 + 다운샘플 후 동일 추출.
    func testPaletteFromEncodedImage() throws {
        let png = try XCTUnwrap(OffscreenCapture.png(rgba: solid(0, 0, 255, count: 64), width: 8, height: 8))
        let p = try XCTUnwrap(ArtworkColors.palette(imageData: png))
        XCTAssertEqual(p.primary.z, 1, accuracy: 0.05)
        XCTAssertNil(ArtworkColors.palette(imageData: Data([1, 2, 3])), "디코드 실패 → nil")
    }
}
