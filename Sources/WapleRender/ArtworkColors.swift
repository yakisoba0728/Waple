import AppKit
import simd

/// 앨범아트 주색 추출(썸네일 이벤트 primaryColor/secondaryColor/... 공급원).
/// 코어는 순수 함수: RGBA 픽셀 → 4bit/채널 양자화 히스토그램 → 최빈 버킷의 평균색.
public enum ArtworkColors {
    public struct Palette: Equatable {
        public var primary: SIMD3<Float>
        public var secondary: SIMD3<Float>
        public var tertiary: SIMD3<Float>
        /// primary 위에 얹을 텍스트 색(흑/백 — primary 휘도 기준).
        public var textColor: SIMD3<Float>
        public var highContrast: SIMD3<Float>
    }

    /// RGBA8 픽셀 배열에서 팔레트 추출(순수). 알파 < 128 픽셀은 무시. 유효 픽셀 없음 → nil.
    /// primary = 최빈 양자화 버킷의 평균색, secondary/tertiary = primary(들)와 RGB 거리 0.2 이상인
    /// 차순위 버킷(없으면 앞 색으로 폴백). text/highContrast = primary 휘도(0.6 문턱)로 흑/백.
    public static func palette(rgba: [UInt8], width: Int, height: Int) -> Palette? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        // 4bit/채널 버킷(4096) → (count, sumR, sumG, sumB)
        var count = [Int](repeating: 0, count: 4096)
        var sum = [SIMD3<Double>](repeating: .zero, count: 4096)
        var total = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            guard rgba[i + 3] >= 128 else { continue }
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            count[key] += 1
            sum[key] += SIMD3(Double(r), Double(g), Double(b))
            total += 1
        }
        guard total > 0 else { return nil }
        // 버킷 평균색을 빈도순으로 정렬(동률은 버킷 인덱스 — 결정적).
        let ranked = (0..<4096).filter { count[$0] > 0 }
            .sorted { count[$0] != count[$1] ? count[$0] > count[$1] : $0 < $1 }
            .map { SIMD3<Float>(sum[$0] / Double(count[$0]) / 255.0) }
        let primary = ranked[0]
        func nextDistinct(from picked: [SIMD3<Float>]) -> SIMD3<Float>? {
            ranked.first { c in picked.allSatisfy { simd_distance($0, c) > 0.2 } }
        }
        let secondary = nextDistinct(from: [primary]) ?? primary
        let tertiary = nextDistinct(from: [primary, secondary]) ?? secondary
        let luma = 0.299 * primary.x + 0.587 * primary.y + 0.114 * primary.z
        let contrast: SIMD3<Float> = luma > 0.6 ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1)
        return Palette(primary: primary, secondary: secondary, tertiary: tertiary,
                       textColor: contrast, highContrast: contrast)
    }

    /// 인코딩 이미지(JPEG/PNG 바이트) → 64×64 이하로 다운샘플 디코드 후 팔레트. 디코드 실패 → nil.
    public static func palette(imageData: Data) -> Palette? {
        guard let img = NSImage(data: imageData),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = min(cg.width, 64), h = min(cg.height, 64)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // F840: `&px` 를 CGContext(data:) 에 넘기면 inout 로 만든 임시 포인터가 호출 밖으로 새어나간다(UB —
        // 그 포인터의 유효 수명은 CGContext 생성 호출 뿐이다). 형제 경로(TexDecoder.draw·
        // TextRasterizer.render)와 동일하게 컨텍스트 생성·드로잉을 withUnsafeMutableBytes 안에서 끝낸다.
        let ok = px.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return palette(rgba: px, width: w, height: h)
    }

    /// 0..1 Vec3 → "#RRGGBB"(클램프). 웹 썸네일 이벤트 색 포맷 — 실물 3639973107 이 #hex 를 파싱한다.
    public static func hexString(_ c: SIMD3<Float>) -> String {
        func b(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.x), b(c.y), b(c.z))
    }
}
