import AppKit

/// RGBA8 픽셀 버퍼 → PNG 인코드. 헤드리스 렌더 검증(오프스크린 텍스처 readback → PNG → Read)용.
/// 라이브 데스크탑을 건드리지 않으므로 가림 여부와 무관하게 시각 검증이 가능하다.
public enum OffscreenCapture {
    /// width×height RGBA8(행당 width*4 바이트, 상단 행 우선) → PNG Data. 실패 시 nil.
    public static func png(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let dst = rep.bitmapData else { return nil }
        rgba.withUnsafeBytes { src in
            dst.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: width * height * 4)
        }
        return rep.representation(using: .png, properties: [:])
    }
}
