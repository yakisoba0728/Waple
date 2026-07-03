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
            guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            let need = w * h * 4
            let sub = data.subdata(in: tex.payloadRange)
            guard sub.count >= need else { return nil }
            return (sub.prefix(need), w, h)
        case .bc3:
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data),
                  let rgba = DXT5Decoder.decode(dec, width: mip.decodeWidth, height: mip.decodeHeight) else { return nil }
            return cropped(rgba, mip)
        case .bc1:
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data),
                  let rgba = DXT5Decoder.decodeBC1(dec, width: mip.decodeWidth, height: mip.decodeHeight) else { return nil }
            return cropped(rgba, mip)
        case .lz4RGBA:
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data),
                  dec.count >= mip.decodeWidth * mip.decodeHeight * 4 else { return nil }
            return cropped(dec, mip)
        case .video, .unknown:
            return nil
        }
    }

    /// mip0 페이로드 바이트: lz4 플래그면 해제, 아니면 그대로(TEXB0001 등 비압축).
    private static func mipBytes(tex: TexImage, data: Data) -> Data? {
        guard let mip = tex.mip else { return nil }
        let payload = data.subdata(in: mip.payloadRange)
        return mip.lz4 ? lz4(payload, expected: mip.decompressedSize) : payload
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

    /// PNG/JPEG → straight-alpha RGBA. 디코더 출력 규약은 전 포맷 STRAIGHT 로 통일한다
    /// (raw/BC3/LZ4 는 WE 저장 그대로 straight — PNG 경로만 CG 가 premultiplied 를 강제하므로 역변환).
    /// 파이프라인 규약(설계 §3): 텍스처/이펙트 패스 straight, premultiply 는 최종 컴포지트에서 1회.
    private static func draw(_ img: CGImage) -> (Data, Int, Int)? {
        let w = img.width, h = img.height
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  // CGContext 는 non-premultiplied 드로잉을 지원하지 않아 premultipliedLast 로 그린 뒤 역변환한다.
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(px[i + 3])
                if a == 0 || a == 255 { continue }
                px[i]     = UInt8(min(255, Int(px[i])     * 255 / a))
                px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a))
                px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
            }
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
