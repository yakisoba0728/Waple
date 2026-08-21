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

// MARK: - CGImageDestination  (2026-08-21, `--tests` 요구 표면)
//
// `TexDecoderTests` 가 합성 PNG 픽스처를 만드는 데 쓴다. 프로덕션 `Sources/WapleRender/**` 는
// 이미지를 **읽기만** 하므로(`CGImageSource*`) 쓰기 쪽이 종전 심에 없었다.

/// 실제: `public class CGImageDestination` (CoreFoundation 불투명 타입)
public class CGImageDestination { internal init(unavailable: ()) {} }

/// 실제: `public func CGImageDestinationCreateWithData(_ data: CFMutableData, _ type: CFString,
///          _ count: Int, _ options: CFDictionary?) -> CGImageDestination?`
/// 확신 없음: 첫 인자를 `CFMutableData` 가 아니라 **`NSMutableData`** 로 받는다. 리눅스
/// Foundation 에 `CFMutableData` 타입앨리어스가 없고, 애플에서는 둘이 무료 브리지라 호출부
/// (`TexDecoderTests:24` 가 `NSMutableData` 를 넘긴다)가 그대로 통과한다.
public func CGImageDestinationCreateWithData(_ data: NSMutableData, _ type: CFString,
                                             _ count: Int, _ options: CFDictionary?) -> CGImageDestination? { nil }

/// 실제: `public func CGImageDestinationAddImage(_ idst: CGImageDestination, _ image: CGImage,
///          _ properties: CFDictionary?)`
public func CGImageDestinationAddImage(_ idst: CGImageDestination, _ image: CGImage,
                                       _ properties: CFDictionary?) {}

/// 실제: `public func CGImageDestinationFinalize(_ idst: CGImageDestination) -> Bool`
@discardableResult
public func CGImageDestinationFinalize(_ idst: CGImageDestination) -> Bool { false }
