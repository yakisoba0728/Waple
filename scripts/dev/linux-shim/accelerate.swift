// 리눅스용 **Accelerate 대역 선언**(shim). 타입체크 전용.
// 사용처: `SystemAudioSpectrumProvider.swift`(vDSP FFT), `SceneVideoLayer.swift`(vImage 회전/미러).
//
// **여기 값은 전부 가짜다.** FFT 결과·회전 결과는 계산되지 않는다 — 리눅스 타입체크는 이 코드의
// 수치 정합을 전혀 검증하지 않는다(그 검증은 macOS CI 와 `WapleCore` 쪽 순수 테스트의 몫이다).
@_exported import Foundation

// MARK: - vDSP (실수 FFT)

/// 실제: `public typealias vDSP_Length = UInt` / `vDSP_Stride = Int`
public typealias vDSP_Length = UInt
public typealias vDSP_Stride = Int
/// 실제: `public typealias FFTSetup = OpaquePointer`
public typealias FFTSetup = OpaquePointer
/// 실제: `public typealias FFTRadix = Int32` / `FFTDirection = Int32`
public typealias FFTRadix = Int32
public typealias FFTDirection = Int32
public let kFFTRadix2: Int32 = 0
public let kFFTRadix3: Int32 = 1
public let kFFTRadix5: Int32 = 2
public let FFT_FORWARD: Int32 = 1
public let FFT_INVERSE: Int32 = -1

/// 실제: `public struct DSPComplex { public var real: Float; public var imag: Float }`
public struct DSPComplex {
    public var real: Float, imag: Float
    public init(real: Float = 0, imag: Float = 0) { self.real = real; self.imag = imag }
}

/// 실제: `public struct DSPSplitComplex { public var realp: UnsafeMutablePointer<Float>
///        public var imagp: UnsafeMutablePointer<Float>
///        public init(realp: UnsafeMutablePointer<Float>, imagp: UnsafeMutablePointer<Float>) }`
public struct DSPSplitComplex {
    public var realp: UnsafeMutablePointer<Float>
    public var imagp: UnsafeMutablePointer<Float>
    public init(realp: UnsafeMutablePointer<Float>, imagp: UnsafeMutablePointer<Float>) {
        self.realp = realp; self.imagp = imagp
    }
}

/// 실제: `public func vDSP_create_fftsetup(_ __Log2n: vDSP_Length, _ __Radix: FFTRadix) -> FFTSetup?`
public func vDSP_create_fftsetup(_ log2n: vDSP_Length, _ radix: FFTRadix) -> FFTSetup? { nil }
/// 실제: `public func vDSP_destroy_fftsetup(_ __setup: FFTSetup?)`
public func vDSP_destroy_fftsetup(_ setup: FFTSetup?) {}
/// 실제: `public func vDSP_ctoz(_ __C: UnsafePointer<DSPComplex>, _ __IC: vDSP_Stride,
///        _ __Z: UnsafePointer<DSPSplitComplex>, _ __IZ: vDSP_Stride, _ __N: vDSP_Length)`
/// (`__Z` 는 `UnsafePointer<DSPSplitComplex>` 라 호출부가 `&split` 을 넘긴다.)
public func vDSP_ctoz(_ c: UnsafePointer<DSPComplex>, _ ic: vDSP_Stride,
                      _ z: UnsafePointer<DSPSplitComplex>, _ iz: vDSP_Stride, _ n: vDSP_Length) {}
/// 실제: `public func vDSP_fft_zrip(_ __Setup: FFTSetup, _ __C: UnsafePointer<DSPSplitComplex>,
///        _ __IC: vDSP_Stride, _ __Log2N: vDSP_Length, _ __Direction: FFTDirection)`
public func vDSP_fft_zrip(_ setup: FFTSetup, _ c: UnsafePointer<DSPSplitComplex>, _ ic: vDSP_Stride,
                          _ log2n: vDSP_Length, _ direction: FFTDirection) {}
/// 실제: `public func vDSP_zvmags(_ __A: UnsafePointer<DSPSplitComplex>, _ __IA: vDSP_Stride,
///        _ __C: UnsafeMutablePointer<Float>, _ __IC: vDSP_Stride, _ __N: vDSP_Length)`
public func vDSP_zvmags(_ a: UnsafePointer<DSPSplitComplex>, _ ia: vDSP_Stride,
                        _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {}
/// 실제: `public func vvsqrtf(_ _: UnsafeMutablePointer<Float>, _ _: UnsafePointer<Float>,
///        _ _: UnsafePointer<Int32>)` — vForce 의 성분별 제곱근(길이는 세 번째 인자가 가리키는 Int32).
/// 호출부가 `vvsqrtf(&result, mags, [Int32(half)])` 처럼 배열 리터럴을 넘긴다(Swift 가 포인터로 브리지).
public func vvsqrtf(_ y: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>,
                    _ n: UnsafePointer<Int32>) {}
/// 실제: `public func vvsqrt(_ _: UnsafeMutablePointer<Double>, _ _: UnsafePointer<Double>,
///        _ _: UnsafePointer<Int32>)`
public func vvsqrt(_ y: UnsafeMutablePointer<Double>, _ x: UnsafePointer<Double>,
                   _ n: UnsafePointer<Int32>) {}

/// 실제: `public func vDSP_vsmul(_ __A:_ __IA:_ __B:_ __C:_ __IC:_ __N:)`
public func vDSP_vsmul(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>,
                       _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {}

// MARK: - vImage

/// 실제: `public typealias vImagePixelCount = UInt` / `vImage_Flags = UInt32` / `vImage_Error = Int`
public typealias vImagePixelCount = UInt
public typealias vImage_Flags = UInt32
public typealias vImage_Error = Int
public let kvImageNoFlags: Int = 0
public let kvImageNoError: vImage_Error = 0

/// 실제: `public typealias Pixel_8888 = (UInt8, UInt8, UInt8, UInt8)`
public typealias Pixel_8888 = (UInt8, UInt8, UInt8, UInt8)

/// 실제: `public struct vImage_Buffer { public var data: UnsafeMutableRawPointer!
///        public var height: vImagePixelCount; public var width: vImagePixelCount
///        public var rowBytes: Int }`
public struct vImage_Buffer {
    public var data: UnsafeMutableRawPointer!
    public var height: vImagePixelCount
    public var width: vImagePixelCount
    public var rowBytes: Int
    public init() { self.init(data: nil, height: 0, width: 0, rowBytes: 0) }
    public init(data: UnsafeMutableRawPointer!, height: vImagePixelCount,
                width: vImagePixelCount, rowBytes: Int) {
        self.data = data; self.height = height; self.width = width; self.rowBytes = rowBytes
    }
}

/// 실제: 90° 회전 상수는 `Int32` 전역이고 `vImageRotate90_*` 의 인자는 `UInt8` 이라
/// 호출부가 `UInt8(kRotate90DegreesClockwise)` 로 좁힌다.
public let kRotate0DegreesClockwise: Int32 = 0
public let kRotate90DegreesClockwise: Int32 = 3
public let kRotate180DegreesClockwise: Int32 = 2
public let kRotate270DegreesClockwise: Int32 = 1

/// 실제: `public func vImageHorizontalReflect_ARGB8888(_ src: UnsafePointer<vImage_Buffer>,
///        _ dest: UnsafePointer<vImage_Buffer>, _ flags: vImage_Flags) -> vImage_Error`
public func vImageHorizontalReflect_ARGB8888(_ src: UnsafePointer<vImage_Buffer>,
                                             _ dest: UnsafePointer<vImage_Buffer>,
                                             _ flags: vImage_Flags) -> vImage_Error { 0 }
/// 실제: `public func vImageVerticalReflect_ARGB8888(...) -> vImage_Error`
public func vImageVerticalReflect_ARGB8888(_ src: UnsafePointer<vImage_Buffer>,
                                           _ dest: UnsafePointer<vImage_Buffer>,
                                           _ flags: vImage_Flags) -> vImage_Error { 0 }
/// 실제: `public func vImageRotate90_ARGB8888(_ src: UnsafePointer<vImage_Buffer>,
///        _ dest: UnsafePointer<vImage_Buffer>, _ rotationConstant: UInt8,
///        _ backColor: UnsafePointer<Pixel_8888>, _ flags: vImage_Flags) -> vImage_Error`
public func vImageRotate90_ARGB8888(_ src: UnsafePointer<vImage_Buffer>,
                                    _ dest: UnsafePointer<vImage_Buffer>,
                                    _ rotationConstant: UInt8,
                                    _ backColor: UnsafePointer<Pixel_8888>,
                                    _ flags: vImage_Flags) -> vImage_Error { 0 }
