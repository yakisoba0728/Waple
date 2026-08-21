// 리눅스용 **CoreVideo 대역 선언**(shim). 타입체크 전용. 사용처: `SceneVideoLayer.swift`.
@_exported import CoreGraphics
@_exported import Metal

/// 실제: `public typealias CVReturn = Int32`
public typealias CVReturn = Int32
public let kCVReturnSuccess: CVReturn = 0

/// 실제: `public class CVBuffer` / `CVImageBuffer` / `CVPixelBuffer` 는 CoreFoundation 불투명 타입이고
/// `CVPixelBuffer` 는 `CVImageBuffer` 의 별칭 계열이다.
public class CVPixelBuffer { internal init(unavailable: ()) {} }
public typealias CVImageBuffer = CVPixelBuffer
/// 실제: `public class CVMetalTexture` / `CVMetalTextureCache`
public class CVMetalTexture { internal init(unavailable: ()) {} }
public class CVMetalTextureCache { internal init(unavailable: ()) {} }

/// 실제: `public struct CVPixelBufferLockFlags: OptionSet { public static var readOnly }`
public struct CVPixelBufferLockFlags: OptionSet {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let readOnly = CVPixelBufferLockFlags(rawValue: 1)
}

/// 실제: `public var kCFAllocatorDefault: CFAllocator!` — CoreFoundation 전역.
public typealias CFAllocator = AnyObject
public let kCFAllocatorDefault: CFAllocator? = nil

/// 실제: `public func CVPixelBufferGetWidth(_ pixelBuffer: CVPixelBuffer) -> Int`
public func CVPixelBufferGetWidth(_ pixelBuffer: CVPixelBuffer) -> Int { 0 }
public func CVPixelBufferGetHeight(_ pixelBuffer: CVPixelBuffer) -> Int { 0 }
public func CVPixelBufferGetBytesPerRow(_ pixelBuffer: CVPixelBuffer) -> Int { 0 }
/// 실제: `public func CVPixelBufferGetBaseAddress(_ pixelBuffer: CVPixelBuffer) -> UnsafeMutableRawPointer?`
public func CVPixelBufferGetBaseAddress(_ pixelBuffer: CVPixelBuffer) -> UnsafeMutableRawPointer? { nil }
/// 실제: `public func CVPixelBufferLockBaseAddress(_ pixelBuffer: CVPixelBuffer,
///        _ lockFlags: CVPixelBufferLockFlags) -> CVReturn`
@discardableResult
public func CVPixelBufferLockBaseAddress(_ pixelBuffer: CVPixelBuffer,
                                         _ lockFlags: CVPixelBufferLockFlags) -> CVReturn { 0 }
@discardableResult
public func CVPixelBufferUnlockBaseAddress(_ pixelBuffer: CVPixelBuffer,
                                           _ unlockFlags: CVPixelBufferLockFlags) -> CVReturn { 0 }
public func CVPixelBufferGetPixelFormatType(_ pixelBuffer: CVPixelBuffer) -> OSType { 0 }

/// 실제: `public typealias OSType = UInt32`
public typealias OSType = UInt32
/// 실제: `public var kCVPixelFormatType_32BGRA: OSType { get }` (FourCC 'BGRA')
public let kCVPixelFormatType_32BGRA: OSType = 0x42475241
public let kCVPixelBufferPixelFormatTypeKey: CFString = "PixelFormatType" as NSString
public let kCVPixelBufferMetalCompatibilityKey: CFString = "MetalCompatibility" as NSString
public let kCVPixelBufferIOSurfacePropertiesKey: CFString = "IOSurfaceProperties" as NSString

/// 실제: `public func CVMetalTextureCacheCreate(_ allocator: CFAllocator?,
///        _ cacheAttributes: CFDictionary?, _ metalDevice: MTLDevice,
///        _ textureAttributes: CFDictionary?,
///        _ cacheOut: UnsafeMutablePointer<CVMetalTextureCache?>) -> CVReturn`
public func CVMetalTextureCacheCreate(_ allocator: CFAllocator?, _ cacheAttributes: CFDictionary?,
                                      _ metalDevice: MTLDevice, _ textureAttributes: CFDictionary?,
                                      _ cacheOut: UnsafeMutablePointer<CVMetalTextureCache?>) -> CVReturn { 0 }

/// 실제: `public func CVMetalTextureCacheCreateTextureFromImage(_ allocator: CFAllocator?,
///        _ textureCache: CVMetalTextureCache, _ sourceImage: CVImageBuffer,
///        _ textureAttributes: CFDictionary?, _ pixelFormat: MTLPixelFormat,
///        _ width: Int, _ height: Int, _ planeIndex: Int,
///        _ textureOut: UnsafeMutablePointer<CVMetalTexture?>) -> CVReturn`
public func CVMetalTextureCacheCreateTextureFromImage(
    _ allocator: CFAllocator?, _ textureCache: CVMetalTextureCache, _ sourceImage: CVImageBuffer,
    _ textureAttributes: CFDictionary?, _ pixelFormat: MTLPixelFormat, _ width: Int, _ height: Int,
    _ planeIndex: Int, _ textureOut: UnsafeMutablePointer<CVMetalTexture?>) -> CVReturn { 0 }

/// 실제: `public func CVMetalTextureGetTexture(_ image: CVMetalTexture) -> MTLTexture?`
public func CVMetalTextureGetTexture(_ image: CVMetalTexture) -> MTLTexture? { nil }
/// 실제: `public func CVMetalTextureCacheFlush(_ textureCache: CVMetalTextureCache, _ options: CVOptionFlags)`
public func CVMetalTextureCacheFlush(_ textureCache: CVMetalTextureCache, _ options: UInt64) {}
