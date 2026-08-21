// 리눅스용 **ImageIO 대역 선언**(shim). 타입체크 전용. 사용처: `TexDecoder.swift`.
@_exported import CoreGraphics

/// 실제: `public class CGImageSource` (CoreFoundation 불투명 타입)
public class CGImageSource {
    internal init(unavailable: ()) {}
}

/// 실제: `public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource?`
public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? { nil }
/// 실제: `public func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource?`
public func CGImageSourceCreateImageAtIndex(_ isrc: CGImageSource, _ index: Int,
                                            _ options: CFDictionary?) -> CGImage? { nil }
/// 실제: `public func CGImageSourceCopyPropertiesAtIndex(_ isrc: CGImageSource, _ index: Int,
///        _ options: CFDictionary?) -> CFDictionary?`
public func CGImageSourceCopyPropertiesAtIndex(_ isrc: CGImageSource, _ index: Int,
                                               _ options: CFDictionary?) -> CFDictionary? { nil }
/// 실제: `public func CGImageSourceGetCount(_ isrc: CGImageSource) -> Int`
public func CGImageSourceGetCount(_ isrc: CGImageSource) -> Int { 0 }

/// 실제: 이 키들은 `CFString` 전역 상수다(`kCGImagePropertyPixelWidth` 등).
public let kCGImagePropertyPixelWidth: CFString = "PixelWidth" as NSString
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight" as NSString
public let kCGImagePropertyHasAlpha: CFString = "HasAlpha" as NSString
public let kCGImagePropertyOrientation: CFString = "Orientation" as NSString
