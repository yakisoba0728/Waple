import Foundation
import CoreGraphics
import ImageIO
import Compression
import WapleCore

public enum TexDecoder {
    private static let maxEmbeddedImageDimension = 8192
    private static let maxEmbeddedImageBytes = 256 << 20

    /// keepFullAtlas: 단일-이미지 다중프레임 스프라이트시트는 imgW/imgH(단일 프레임 크기) 크롭을 건너뛰고
    /// 디코드 아틀라스(decodeW×decodeH) 전체를 보존한다 — TEXS 프레임 좌표(예 frame1 x=1920)가 imgW 를
    /// 넘어서므로 크롭하면 frame≥1 이 소실돼 spriteFrameTexture 가 1px 클램프 블릿(흑화)한다. 호출자
    /// (resolveTextureWithFrames)만 true — 일반/단일프레임 경로는 종전대로 크롭(무회귀).
    public static func rgba(from tex: TexImage, data: Data, keepFullAtlas: Bool = false) -> (pixels: Data, width: Int, height: Int)? {
        switch tex.payload {
        case .png, .jpeg:
            return decodeEncoded(data.subdata(in: tex.payloadRange), inBytes: tex.payloadRange.count, format: "png/jpeg")
        case .embeddedImage:
            // imageFormat 이 인코딩 이미지(PNG/JPEG/GIF)로 지정한 mip. LZ4 해제(mipBytes) 후 CGImageSource 디코드
            // — fast-path 512B 스캔이 놓치는 LZ4 압축 임베디드 이미지 경로. straight-alpha 규약은 draw 가 유지.
            guard let mip = tex.mip, let dec = mipBytes(mip: mip, data: data) else { return nil }
            return decodeEncoded(dec, inBytes: mip.payloadRange.count, format: "embedded")
        case .rawRGBA8888:
            let w = tex.width, h = tex.height
            guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            let need = w * h * 4
            let sub = data.subdata(in: tex.payloadRange)
            guard sub.count >= need else { return nil }
            return (sub.prefix(need), w, h)
        case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA:
            guard let mip = tex.mip else { return nil }
            return decodeMip(payload: tex.payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        case .video, .unknown:
            return nil
        }
    }

    /// 조건 변형(TEXB0004) 선택 디코드: tex.variants 가 있으면 프로퍼티 값으로 mip 선택 후 디코드,
    /// 없으면(또는 미매치=기본 mip 선택 시) 기존 rgba(from:data:). 변형 mip 은 기본과 동일 포맷(파일
    /// format 기반 DXT/raw)이라 decodeMip 재사용. 젤다 튜닉색(tuniccolor) 등 프로퍼티 연동 텍스처용.
    public static func rgba(from tex: TexImage, data: Data, properties: [String: PropertyValue],
                            keepFullAtlas: Bool = false)
        -> (pixels: Data, width: Int, height: Int)? {
        guard !tex.variants.isEmpty,
              let mip = tex.selectedMip(properties: properties), mip != tex.mip else {
            return rgba(from: tex, data: data, keepFullAtlas: keepFullAtlas)
        }
        switch tex.payload {
        case .bc3, .bc2, .bc1, .r8, .rg88, .lz4RGBA:
            return decodeMip(payload: tex.payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        default:
            return rgba(from: tex, data: data, keepFullAtlas: keepFullAtlas)   // 변형이나 mip 기반 아님(미관측) — 안전 폴백
        }
    }

    /// 특정 아틀라스 페이지(image index) 디코드. 다중 image = GIF 스프라이트 페이지(각 자체 mip0,
    /// frame.imageId 가 페이지 인덱스 — RePKG ConvertToGif). index 0/단일 image/범위 밖은 mip0(=rgba) 로.
    /// mip 기반(raw/DXT) 포맷에만 의미(임베디드 이미지 페이지는 단일이라 rgba 사용).
    public static func rgba(from tex: TexImage, data: Data, imageIndex: Int) -> (pixels: Data, width: Int, height: Int)? {
        guard imageIndex > 0, imageIndex < tex.mips.count else { return rgba(from: tex, data: data) }
        return decodeMip(payload: tex.payload, mip: tex.mips[imageIndex], data: data)
    }

    /// mip 기반(raw/DXT) 포맷 1장 디코드 + 패딩 크롭. 단일/다중 페이지 공용(mip 인자로 페이지 선택).
    private static func decodeMip(payload: TexImage.PayloadKind, mip: TexImage.CompressedMip, data: Data,
                                  keepFullAtlas: Bool = false)
        -> (pixels: Data, width: Int, height: Int)? {
        guard WapleProfiler.enabled else { return _decodeMip(payload: payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = _decodeMip(payload: payload, mip: mip, data: data, keepFullAtlas: keepFullAtlas)
        WapleProfiler.recordTex(format: "\(payload)", outBytes: out?.pixels.count ?? 0,
                                inBytes: mip.payloadRange.count, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return out
    }

    private static func _decodeMip(payload: TexImage.PayloadKind, mip: TexImage.CompressedMip, data: Data,
                                   keepFullAtlas: Bool)
        -> (pixels: Data, width: Int, height: Int)? {
        guard let dec = mipBytes(mip: mip, data: data) else { return nil }
        let w = mip.decodeWidth, h = mip.decodeHeight
        // 스프라이트시트 아틀라스는 전체 보존(프레임 좌표가 imgW/imgH 를 넘음), 그 외는 패딩 크롭.
        func finish(_ rgba: Data) -> (Data, Int, Int) { keepFullAtlas ? (rgba, w, h) : cropped(rgba, mip) }
        switch payload {
        case .bc3:
            guard let rgba = DXT5Decoder.decode(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .bc2:
            guard let rgba = DXT5Decoder.decodeBC2(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .bc1:
            guard let rgba = DXT5Decoder.decodeBC1(dec, width: w, height: h) else { return nil }
            return finish(rgba)
        case .r8:
            // 단일 채널 8bit(WE fmt9). raw 바이트 = 픽셀당 값. 그레이스케일(v,v,v)+불투명(255)로 확장 —
            // 소비처(opacity 마스크 등)는 .r 을 읽으므로 r=v 로 정확하고, 직접 표시 시에도 회색으로 자연스럽다.
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
            return finish(rgba)
        case .rg88:
            // 2채널 8bit(WE fmt8): byte0→루마(r=g=b), byte1→알파. 판정(2026-07-09, RePKG 대조):
            // 실물 셰이더 common_fragment.h:98 ConvertTexture0Format(RG88)=`.rrrg` — GL_RG8 샘플은 .r=byte0/.g=byte1
            // 이므로 (byte0,byte0,byte0,byte1). HLSL_SM30 경로 `.rrra`(A8L8 에뮬)도 동일 결론 → 아래 코드가 정본.
            // ⚠️ RePKG RG88.cs:40 은 정반대(`Rgba32(G,G,G,R)` = byte1→루마, byte0→알파)지만, 실제 렌더 규약은
            // 셰이더이므로 Waple 이 옳다(RePKG 를 보고 뒤집지 말 것). rain_drops_sheet 등 파티클 시트가 이 포맷.
            // 마스크 소비(.r)도 r 그대로라 양쪽 정확. (REFRACT 의 스크린 굴절 곱은 항등 근사 — 별도 미구현.)
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
            return finish(rgba)
        case .lz4RGBA:
            guard dec.count >= w * h * 4 else { return nil }
            return finish(dec)
        default:
            return nil
        }
    }

    /// mip 페이로드 바이트: lz4 플래그면 해제, 아니면 그대로(TEXB0001 등 비압축).
    private static func mipBytes(mip: TexImage.CompressedMip, data: Data) -> Data? {
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

    /// 인코딩 이미지(PNG/JPEG/GIF) 바이트 → straight-alpha RGBA. png/jpeg·embedded 케이스 공용.
    /// 계측 시 texDecode 페이즈 누적(CGImageSource 디코드 + straight 역변환 포함).
    private static func decodeEncoded(_ imageData: Data, inBytes: Int, format: String) -> (Data, Int, Int)? {
        guard WapleProfiler.enabled else { return decodeEncodedImpl(imageData) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = decodeEncodedImpl(imageData)
        WapleProfiler.recordTex(format: format, outBytes: out?.0.count ?? 0, inBytes: inBytes, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return out
    }

    private static func decodeEncodedImpl(_ imageData: Data) -> (Data, Int, Int)? {
        guard embeddedImagePropertiesAreWithinLimits(imageData),
              let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return draw(img)
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
