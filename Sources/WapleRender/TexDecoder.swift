import Foundation
import CoreGraphics
import ImageIO
import Compression
import WapleCore

public enum TexDecoder {
    private static let maxEmbeddedImageDimension = 8192
    private static let maxEmbeddedImageBytes = 256 << 20

    public static func rgba(from tex: TexImage, data: Data) -> (pixels: Data, width: Int, height: Int)? {
        switch tex.payload {
        case .png, .jpeg:
            let sub = data.subdata(in: tex.payloadRange)
            guard embeddedImagePropertiesAreWithinLimits(sub),
                  let src = CGImageSourceCreateWithData(sub as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return draw(img)
        case .embeddedImage:
            // imageFormat 이 인코딩 이미지(PNG/JPEG/GIF)로 지정한 mip. LZ4 해제(mipBytes) 후 CGImageSource 디코드
            // — fast-path 512B 스캔이 놓치는 LZ4 압축 임베디드 이미지 경로. straight-alpha 규약은 draw 가 유지.
            guard let dec = mipBytes(tex: tex, data: data),
                  embeddedImagePropertiesAreWithinLimits(dec),
                  let src = CGImageSourceCreateWithData(dec as CFData, nil),
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
        case .bc2:
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data),
                  let rgba = DXT5Decoder.decodeBC2(dec, width: mip.decodeWidth, height: mip.decodeHeight) else { return nil }
            return cropped(rgba, mip)
        case .bc1:
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data),
                  let rgba = DXT5Decoder.decodeBC1(dec, width: mip.decodeWidth, height: mip.decodeHeight) else { return nil }
            return cropped(rgba, mip)
        case .r8:
            // 단일 채널 8bit(WE fmt9). raw 바이트 = 픽셀당 값. 그레이스케일(v,v,v)+불투명(255)로 확장 —
            // 소비처(opacity 마스크 등)는 .r 을 읽으므로 r=v 로 정확하고, 직접 표시 시에도 회색으로 자연스럽다.
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data) else { return nil }
            let w = mip.decodeWidth, h = mip.decodeHeight
            guard w > 0, h > 0, dec.count >= w * h else { return nil }
            var rgba = Data(count: w * h * 4)
            dec.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                    for i in 0..<(w * h) {
                        let v = s[i]
                        d[i * 4] = v; d[i * 4 + 1] = v; d[i * 4 + 2] = v; d[i * 4 + 3] = 255
                    }
                }
            }
            return cropped(rgba, mip)
        case .rg88:
            // 2채널 8bit(WE fmt8): byte0→루마(r=g=b), byte1→알파. 판정(2026-07-09, RePKG 대조):
            // 실물 셰이더 common_fragment.h:98 ConvertTexture0Format(RG88)=`.rrrg` — GL_RG8 샘플은 .r=byte0/.g=byte1
            // 이므로 (byte0,byte0,byte0,byte1). HLSL_SM30 경로 `.rrra`(A8L8 에뮬)도 동일 결론 → 아래 코드가 정본.
            // ⚠️ RePKG RG88.cs:40 은 정반대(`Rgba32(G,G,G,R)` = byte1→루마, byte0→알파)지만, 실제 렌더 규약은
            // 셰이더이므로 Waple 이 옳다(RePKG 를 보고 뒤집지 말 것). rain_drops_sheet 등 파티클 시트가 이 포맷.
            // 마스크 소비(.r)도 r 그대로라 양쪽 정확. (REFRACT 의 스크린 굴절 곱은 항등 근사 — 별도 미구현.)
            guard let mip = tex.mip, let dec = mipBytes(tex: tex, data: data) else { return nil }
            let w = mip.decodeWidth, h = mip.decodeHeight
            guard w > 0, h > 0, dec.count >= w * h * 2 else { return nil }
            var rgba = Data(count: w * h * 4)
            dec.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                rgba.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                    for i in 0..<(w * h) {
                        let r = s[i * 2], g = s[i * 2 + 1]
                        d[i * 4] = r; d[i * 4 + 1] = r; d[i * 4 + 2] = r; d[i * 4 + 3] = g
                    }
                }
            }
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
        guard imageDimensionsAreWithinLimits(width: w, height: h) else { return nil }
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

    private static func embeddedImagePropertiesAreWithinLimits(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return false }
        return imageDimensionsAreWithinLimits(width: w, height: h)
    }

    private static func imageDimensionsAreWithinLimits(width w: Int, height h: Int) -> Bool {
        guard w > 0, h > 0, w <= maxEmbeddedImageDimension, h <= maxEmbeddedImageDimension else { return false }
        return w <= maxEmbeddedImageBytes / max(1, h * 4)
    }
}
