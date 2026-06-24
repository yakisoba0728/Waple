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
            guard let mip = tex.bc3 else { return nil }
            let comp = data.subdata(in: mip.payloadRange)
            var dst = [UInt8](repeating: 0, count: mip.decompressedSize)
            let got = comp.withUnsafeBytes { srcp in
                dst.withUnsafeMutableBytes { dstp in
                    compression_decode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, mip.decompressedSize,
                                              srcp.bindMemory(to: UInt8.self).baseAddress!, comp.count, nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard got == mip.decompressedSize,
                  let rgba = DXT5Decoder.decode(Data(dst), width: mip.width, height: mip.height) else { return nil }
            return (rgba, mip.width, mip.height)
        case .video, .unknown:
            return nil
        }
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
