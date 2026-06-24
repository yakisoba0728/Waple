import Foundation
import CoreGraphics
import ImageIO
import Compression
import WapleCore

public enum TexDecoder {
    public static func rgba(from tex: TexImage, data: Data) -> (pixels: Data, width: Int, height: Int)? {
        switch tex.payload {
        case .png, .jpeg:
            let sub = data.subdata(in: tex.payloadRange)
            guard let src = CGImageSourceCreateWithData(sub as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return draw(img)
        case .rawRGBA8888:
            let w = tex.width, h = tex.height
            guard w > 0, h > 0 else { return nil }
            let need = w * h * 4
            let sub = data.subdata(in: tex.payloadRange)
            guard sub.count >= need else { return nil }
            return (sub.prefix(need), w, h)
        case .bc3:
            guard let mip = tex.mip,
                  let dec = lz4(data.subdata(in: mip.payloadRange), expected: mip.decompressedSize),
                  let rgba = DXT5Decoder.decode(dec, width: mip.decodeWidth, height: mip.decodeHeight) else { return nil }
            return cropped(rgba, mip)
        case .lz4RGBA:
            guard let mip = tex.mip,
                  let dec = lz4(data.subdata(in: mip.payloadRange), expected: mip.decompressedSize),
                  dec.count >= mip.decodeWidth * mip.decodeHeight * 4 else { return nil }
            return cropped(dec, mip)
        case .video, .unknown:
            return nil
        }
    }

    /// LZ4 raw 해제. 성공 시 정확히 expected 바이트 반환.
    private static func lz4(_ comp: Data, expected: Int) -> Data? {
        guard expected > 0 else { return nil }
        var dst = [UInt8](repeating: 0, count: expected)
        let got = comp.withUnsafeBytes { srcp -> Int in
            dst.withUnsafeMutableBytes { dstp in
                compression_decode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        return got == expected ? Data(dst) : nil
    }

    /// 패딩 텍스처(decode dims)에서 실제 이미지(top-left image dims)만 크롭.
    private static func cropped(_ rgba: Data, _ mip: TexImage.CompressedMip) -> (Data, Int, Int) {
        let dw = mip.decodeWidth, dh = mip.decodeHeight, iw = mip.imageWidth, ih = mip.imageHeight
        if iw == dw && ih == dh { return (rgba, dw, dh) }
        guard iw > 0, ih > 0, iw <= dw, ih <= dh, rgba.count >= dw * dh * 4 else { return (rgba, dw, dh) }
        var out = Data(count: iw * ih * 4)
        rgba.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for y in 0..<ih {
                    memcpy(dst.baseAddress!.advanced(by: y * iw * 4),
                           src.baseAddress!.advanced(by: y * dw * 4), iw * 4)
                }
            }
        }
        return (out, iw, ih)
    }

    private static func draw(_ img: CGImage) -> (Data, Int, Int)? {
        let w = img.width, h = img.height
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
