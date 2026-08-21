// 리눅스용 **Metal 대역 선언**(shim). 동작하지 않는다 — 타입체크 전용이다.
//
// 왜 있는가
// ---------
// `Sources/WapleRender/**` 는 `import Metal`/`MetalKit` 이라 리눅스에서 `swiftc -parse` 밖에
// 못 돌리는데 **`-parse` 는 타입체크를 하지 않는다**. 그 공백에서 macOS CI 가 두 번 깨졌다
// (`b98db0a` MSL 주석 개행, `bb5f902` 스코프에 없는 `texW`). 이 파일은 WapleRender 가 실제로
// 쓰는 Metal API 만 선언해 리눅스에서 `swiftc -typecheck` 를 가능하게 한다.
//
// 규약
// ----
// · 본문은 전부 `fatalError("linux shim")` 이다. **실행하면 안 된다.**
// · 각 선언 위에 실제 Metal 시그니처를 주석으로 적는다. 확신 없는 것은 `확신 없음` 이라고 적는다.
// · **여기 시그니처가 실제 Metal 과 다르면 거짓 통과/거짓 실패가 난다.** 실제 Metal 헤더가
//   바뀌었거나 여기 적힌 게 틀렸다면 macOS CI 가 최종 판정자다 — 이 심은 CI 를 대체하지 않는다.
// · WapleRender 가 **쓰지 않는** API 는 일부러 뺐다. 새 API 를 쓰기 시작하면 여기 추가해야 한다
//   (추가를 잊으면 "cannot find in scope" 로 즉시 드러나므로 조용한 실패는 없다).
@_exported import CoreGraphics

// MARK: - 스칼라 · 값 타입

/// 실제: `public struct MTLClearColor { public var red: Double; green; blue; alpha
///        public init(red: Double, green: Double, blue: Double, alpha: Double) }`
public struct MTLClearColor {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

/// 실제: `public struct MTLOrigin { public var x: Int, y: Int, z: Int; init(x:y:z:) }`
public struct MTLOrigin {
    public var x: Int, y: Int, z: Int
    public init(x: Int = 0, y: Int = 0, z: Int = 0) { self.x = x; self.y = y; self.z = z }
}

/// 실제: `public struct MTLSize { public var width: Int, height: Int, depth: Int; init(width:height:depth:) }`
public struct MTLSize {
    public var width: Int, height: Int, depth: Int
    public init(width: Int = 0, height: Int = 0, depth: Int = 0) {
        self.width = width; self.height = height; self.depth = depth
    }
}

/// 실제: `public struct MTLRegion { public var origin: MTLOrigin; public var size: MTLSize }`
public struct MTLRegion {
    public var origin: MTLOrigin, size: MTLSize
    public init(origin: MTLOrigin, size: MTLSize) { self.origin = origin; self.size = size }
}

/// 실제: `public func MTLRegionMake2D(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> MTLRegion`
public func MTLRegionMake2D(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: width, height: height, depth: 1))
}

/// 실제: `public func MTLRegionMake3D(_ x:_ y:_ z:_ width:_ height:_ depth:) -> MTLRegion`
public func MTLRegionMake3D(_ x: Int, _ y: Int, _ z: Int, _ w: Int, _ h: Int, _ d: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: z), size: MTLSize(width: w, height: h, depth: d))
}

/// 실제: `public struct MTLViewport { public var originX: Double, originY, width, height, znear, zfar: Double }`
/// (멤버 순서 = originX, originY, width, height, znear, zfar. 전부 `Double`.)
public struct MTLViewport {
    public var originX: Double, originY: Double, width: Double, height: Double, znear: Double, zfar: Double
    public init(originX: Double = 0, originY: Double = 0, width: Double = 0, height: Double = 0,
                znear: Double = 0, zfar: Double = 1) {
        self.originX = originX; self.originY = originY; self.width = width; self.height = height
        self.znear = znear; self.zfar = zfar
    }
}

/// 실제: `public struct MTLScissorRect { public var x: Int, y: Int, width: Int, height: Int }`
public struct MTLScissorRect {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

// MARK: - 열거형 (전부 `UInt` raw 의 `@objc enum` 이다. 케이스 이름만 맞추면 된다)

/// 실제: `public enum MTLPixelFormat: UInt` — 케이스는 WapleRender 가 쓰는 것만 옮겼다.
public enum MTLPixelFormat: UInt {
    case invalid = 0
    case r8Unorm = 10
    case r16Float = 25
    case rg8Unorm = 30
    case rg16Float = 65
    case rgba8Unorm = 70
    case rgba8Unorm_srgb = 71
    case bgra8Unorm = 80
    case bgra8Unorm_srgb = 81
    case rgb10a2Unorm = 90
    case rg32Float = 105
    case rgba16Unorm = 110
    case rgba16Snorm = 112
    case rgba16Float = 115
    case rgba32Float = 125
    case depth32Float = 252
    case bc1_rgba = 130
    case bc1_rgba_srgb = 131
    case bc2_rgba = 132
    case bc2_rgba_srgb = 133
    case bc3_rgba = 134
    case bc3_rgba_srgb = 135
    // 확신 없음: raw 값은 실제 Metal 의 숫자를 그대로 옮긴 것이 아니다(케이스 이름만 쓰이므로
    // 값 자체는 타입체크에 영향이 없다). 씬이 rawValue 로 왕복을 하기 시작하면 여기가 거짓이 된다.
}

/// 실제: `public enum MTLTextureType: UInt { case type1D, type1DArray, type2D, type2DArray,
///        type2DMultisample, typeCube, typeCubeArray, type3D, type2DMultisampleArray, typeTextureBuffer }`
public enum MTLTextureType: UInt {
    case type1D = 0, type1DArray = 1, type2D = 2, type2DArray = 3, type2DMultisample = 4
    case typeCube = 5, typeCubeArray = 6, type3D = 7, type2DMultisampleArray = 8, typeTextureBuffer = 9
}

/// 실제: `public struct MTLTextureUsage: OptionSet { static let unknown/shaderRead/shaderWrite/
///        renderTarget/pixelFormatView }` (RawValue = UInt)
public struct MTLTextureUsage: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let unknown = MTLTextureUsage(rawValue: 0)
    public static let shaderRead = MTLTextureUsage(rawValue: 1)
    public static let shaderWrite = MTLTextureUsage(rawValue: 2)
    public static let renderTarget = MTLTextureUsage(rawValue: 4)
    public static let pixelFormatView = MTLTextureUsage(rawValue: 16)
}

/// 실제: `public enum MTLStorageMode: UInt { case shared, managed, private, memoryless }`
/// `private` 는 Swift 키워드라 실제 API 에서도 백틱(`.private`)으로 쓴다.
public enum MTLStorageMode: UInt {
    case shared = 0, managed = 1, `private` = 2, memoryless = 3
}

/// 실제: `public enum MTLCPUCacheMode: UInt { case defaultCache, writeCombined }`
public enum MTLCPUCacheMode: UInt { case defaultCache = 0, writeCombined = 1 }

/// 실제: `public struct MTLResourceOptions: OptionSet` — `storageModeShared` 등.
public struct MTLResourceOptions: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let cpuCacheModeWriteCombined = MTLResourceOptions(rawValue: 1)
    public static let storageModeShared = MTLResourceOptions(rawValue: 0)
    public static let storageModeManaged = MTLResourceOptions(rawValue: 16)
    public static let storageModePrivate = MTLResourceOptions(rawValue: 32)
    public static let storageModeMemoryless = MTLResourceOptions(rawValue: 48)
    public static let hazardTrackingModeUntracked = MTLResourceOptions(rawValue: 256)
}

/// 실제: `public enum MTLLoadAction: UInt { case dontCare, load, clear }`
public enum MTLLoadAction: UInt { case dontCare = 0, load = 1, clear = 2 }

/// 실제: `public enum MTLStoreAction: UInt { case dontCare, store, multisampleResolve,
///        storeAndMultisampleResolve, unknown, customSampleDepthStore }`
public enum MTLStoreAction: UInt {
    case dontCare = 0, store = 1, multisampleResolve = 2, storeAndMultisampleResolve = 3
    case unknown = 4, customSampleDepthStore = 5
}

/// 실제: `public enum MTLPrimitiveType: UInt { case point, line, lineStrip, triangle, triangleStrip }`
public enum MTLPrimitiveType: UInt { case point = 0, line = 1, lineStrip = 2, triangle = 3, triangleStrip = 4 }

/// 실제: `public enum MTLIndexType: UInt { case uint16, uint32 }`
public enum MTLIndexType: UInt { case uint16 = 0, uint32 = 1 }

/// 실제: `public enum MTLCullMode: UInt { case none, front, back }`
public enum MTLCullMode: UInt { case none = 0, front = 1, back = 2 }

/// 실제: `public enum MTLWinding: UInt { case clockwise, counterClockwise }`
public enum MTLWinding: UInt { case clockwise = 0, counterClockwise = 1 }

/// 실제: `public enum MTLCompareFunction: UInt { case never, less, equal, lessEqual, greater,
///        notEqual, greaterEqual, always }`
public enum MTLCompareFunction: UInt {
    case never = 0, less = 1, equal = 2, lessEqual = 3, greater = 4, notEqual = 5, greaterEqual = 6, always = 7
}

/// 실제: `public enum MTLBlendFactor: UInt { ... }` — WapleRender 가 쓰는 케이스만.
public enum MTLBlendFactor: UInt {
    case zero = 0, one = 1
    case sourceColor = 2, oneMinusSourceColor = 3
    case sourceAlpha = 4, oneMinusSourceAlpha = 5
    case destinationColor = 6, oneMinusDestinationColor = 7
    case destinationAlpha = 8, oneMinusDestinationAlpha = 9
    case sourceAlphaSaturated = 10
    case blendColor = 11, oneMinusBlendColor = 12
    case blendAlpha = 13, oneMinusBlendAlpha = 14
}

/// 실제: `public enum MTLBlendOperation: UInt { case add, subtract, reverseSubtract, min, max }`
public enum MTLBlendOperation: UInt { case add = 0, subtract = 1, reverseSubtract = 2, min = 3, max = 4 }

/// 실제: `public struct MTLColorWriteMask: OptionSet` — `.none/.red/.green/.blue/.alpha/.all`
public struct MTLColorWriteMask: OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let none = MTLColorWriteMask(rawValue: 0)
    public static let red = MTLColorWriteMask(rawValue: 8)
    public static let green = MTLColorWriteMask(rawValue: 4)
    public static let blue = MTLColorWriteMask(rawValue: 2)
    public static let alpha = MTLColorWriteMask(rawValue: 1)
    public static let all = MTLColorWriteMask(rawValue: 15)
}

/// 실제: `public enum MTLVertexFormat: UInt { ... }` — 쓰는 케이스만.
public enum MTLVertexFormat: UInt {
    case invalid = 0
    case float = 28, float2 = 29, float3 = 30, float4 = 31
    case uchar4 = 3, short2 = 16, half2 = 25, half4 = 27
}

/// 실제: `public enum MTLVertexStepFunction: UInt { case constant, perVertex, perInstance, perPatch,
///        perPatchControlPoint }`
public enum MTLVertexStepFunction: UInt {
    case constant = 0, perVertex = 1, perInstance = 2, perPatch = 3, perPatchControlPoint = 4
}

/// 실제: `public enum MTLLanguageVersion: UInt { case version1_1, ... version3_1 }`
/// 확신 없음: 케이스 목록은 SDK 판마다 다르다. WapleRender 는 현재 `options: nil` 만 쓴다.
public enum MTLLanguageVersion: UInt {
    case version2_0 = 131072, version2_1 = 131073, version2_2 = 131074
    case version2_3 = 131075, version2_4 = 131076, version3_0 = 196608, version3_1 = 196609
}

// MARK: - 프로토콜 (Metal 의 객체는 전부 `@objc protocol` 이다)

/// 실제: `public protocol MTLResource: NSObjectProtocol { var label: String? { get set }
///        var device: MTLDevice { get }; var cpuCacheMode: MTLCPUCacheMode { get }
///        var storageMode: MTLStorageMode { get }; ... }`
public protocol MTLResource: AnyObject {
    var label: String? { get set }
    var storageMode: MTLStorageMode { get }
}

/// 실제: `public protocol MTLBuffer: MTLResource { var length: Int { get }
///        func contents() -> UnsafeMutableRawPointer
///        func didModifyRange(_ range: Range<Int>) }`
public protocol MTLBuffer: MTLResource {
    var length: Int { get }
    func contents() -> UnsafeMutableRawPointer
    func didModifyRange(_ range: Range<Int>)
}

/// 실제: `public protocol MTLTexture: MTLResource { var textureType: MTLTextureType { get }
///        var pixelFormat: MTLPixelFormat { get }; var width/height/depth: Int { get }
///        var mipmapLevelCount: Int { get }; var sampleCount: Int { get }; var arrayLength: Int { get }
///        var usage: MTLTextureUsage { get }
///        func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion,
///                      mipmapLevel level: Int)
///        func replace(region: MTLRegion, mipmapLevel: Int, withBytes: UnsafeRawPointer, bytesPerRow: Int)
///        func replace(region:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:)
///        func makeTextureView(pixelFormat: MTLPixelFormat) -> MTLTexture? }`
public protocol MTLTexture: MTLResource {
    var textureType: MTLTextureType { get }
    var pixelFormat: MTLPixelFormat { get }
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var mipmapLevelCount: Int { get }
    var sampleCount: Int { get }
    var arrayLength: Int { get }
    var usage: MTLTextureUsage { get }
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel level: Int)
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, bytesPerImage: Int,
                  from region: MTLRegion, mipmapLevel level: Int, slice: Int)
    func replace(region: MTLRegion, mipmapLevel level: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int)
    func replace(region: MTLRegion, mipmapLevel level: Int, slice: Int, withBytes pixelBytes: UnsafeRawPointer,
                 bytesPerRow: Int, bytesPerImage: Int)
    func makeTextureView(pixelFormat: MTLPixelFormat) -> MTLTexture?
}

/// 실제: `public protocol MTLFunction: NSObjectProtocol { var name: String { get }
///        var label: String? { get set }; ... }`
public protocol MTLFunction: AnyObject {
    var name: String { get }
    var label: String? { get set }
}

/// 실제: `public protocol MTLLibrary: NSObjectProtocol { var functionNames: [String] { get }
///        func makeFunction(name: String) -> MTLFunction?
///        func makeFunction(name: String, constantValues: MTLFunctionConstantValues) throws -> MTLFunction }`
public protocol MTLLibrary: AnyObject {
    var label: String? { get set }
    var functionNames: [String] { get }
    func makeFunction(name functionName: String) -> MTLFunction?
}

/// 실제: `public protocol MTLDepthStencilState: NSObjectProtocol { var label: String? { get } }`
public protocol MTLDepthStencilState: AnyObject {
    var label: String? { get }
}

/// 실제: `public protocol MTLRenderPipelineState: NSObjectProtocol { var label: String? { get } ... }`
public protocol MTLRenderPipelineState: AnyObject {
    var label: String? { get }
}

/// 실제: `public protocol MTLDrawable: NSObjectProtocol { func present(); var drawableID: Int { get } ... }`
public protocol MTLDrawable: AnyObject {
    func present()
}

/// 실제: `public protocol MTLCommandEncoder: NSObjectProtocol { var label: String? { get set }
///        func endEncoding(); func pushDebugGroup(_:); func popDebugGroup() }`
public protocol MTLCommandEncoder: AnyObject {
    var label: String? { get set }
    func endEncoding()
    func pushDebugGroup(_ string: String)
    func popDebugGroup()
}

/// 실제: `public protocol MTLBlitCommandEncoder: MTLCommandEncoder { ... }`
public protocol MTLBlitCommandEncoder: MTLCommandEncoder {
    func copy(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture)
    func copy(from sourceTexture: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin,
              sourceSize: MTLSize, to destinationTexture: MTLTexture, destinationSlice: Int,
              destinationLevel: Int, destinationOrigin: MTLOrigin)
    func generateMipmaps(for texture: MTLTexture)
    func synchronize(resource: MTLResource)
}

/// 실제: `public protocol MTLRenderCommandEncoder: MTLCommandEncoder { ... }`
/// 인덱스 인자 라벨은 전부 `index:`(단수)다 — `at:` 이 아니다(구 Objective-C 이름과 다르다).
public protocol MTLRenderCommandEncoder: MTLCommandEncoder {
    func setRenderPipelineState(_ pipelineState: MTLRenderPipelineState)
    func setDepthStencilState(_ depthStencilState: MTLDepthStencilState?)
    func setCullMode(_ cullMode: MTLCullMode)
    func setFrontFacing(_ frontFacingWinding: MTLWinding)
    func setViewport(_ viewport: MTLViewport)
    func setScissorRect(_ rect: MTLScissorRect)
    /// 실제: `func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float)`
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float)
    func setVertexBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setVertexTexture(_ texture: MTLTexture?, index: Int)
    func setFragmentBuffer(_ buffer: MTLBuffer?, offset: Int, index: Int)
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentTexture(_ texture: MTLTexture?, index: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType,
                               indexBuffer: MTLBuffer, indexBufferOffset: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType,
                               indexBuffer: MTLBuffer, indexBufferOffset: Int, instanceCount: Int)
}

/// 실제: `public protocol MTLCommandBuffer: NSObjectProtocol { ... }`
public protocol MTLCommandBuffer: AnyObject {
    var label: String? { get set }
    func makeRenderCommandEncoder(descriptor renderPassDescriptor: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder?
    func makeBlitCommandEncoder() -> MTLBlitCommandEncoder?
    func present(_ drawable: MTLDrawable)
    func addCompletedHandler(_ block: @escaping (MTLCommandBuffer) -> Void)
    func commit()
    func waitUntilCompleted()
    func waitUntilScheduled()
}

/// 실제: `public protocol MTLCommandQueue: NSObjectProtocol { var label: String? { get set }
///        var device: MTLDevice { get }; func makeCommandBuffer() -> MTLCommandBuffer? }`
public protocol MTLCommandQueue: AnyObject {
    var label: String? { get set }
    func makeCommandBuffer() -> MTLCommandBuffer?
}

/// 실제: `public protocol MTLDevice: NSObjectProtocol { ... }`
/// `makeLibrary(source:options:)` 는 `throws`, `makeRenderPipelineState(descriptor:)` 도 `throws`.
/// 나머지 팩토리는 옵셔널 반환이다.
public protocol MTLDevice: AnyObject {
    var name: String { get }
    var registryID: UInt64 { get }
    var currentAllocatedSize: Int { get }
    var recommendedMaxWorkingSetSize: UInt64 { get }
    var hasUnifiedMemory: Bool { get }
    /// 실제: `var supportsBCTextureCompression: Bool { get }` (macOS 11+)
    var supportsBCTextureCompression: Bool { get }
    func makeCommandQueue() -> MTLCommandQueue?
    func makeBuffer(length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> MTLBuffer?
    func makeTexture(descriptor: MTLTextureDescriptor) -> MTLTexture?
    func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> MTLDepthStencilState?
    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> MTLLibrary
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState
}

/// 실제 Metal 에서 `options:` 는 **생략 가능**하다 — Clang 임포터가 후행 NS_OPTIONS 인자에
/// `= []` 기본값을 자동 부여하기 때문이다(`SceneRenderer.swift:1620/1629/1637` 이 실제로 생략한다).
/// 순수 Swift 프로토콜 요구사항에는 기본값을 못 쓰므로(`default argument not permitted in a
/// protocol method`) 확장 오버로드로 같은 호출 형태를 만든다.
public extension MTLDevice {
    func makeBuffer(length: Int) -> MTLBuffer? { makeBuffer(length: length, options: []) }
    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int) -> MTLBuffer? {
        makeBuffer(bytes: pointer, length: length, options: [])
    }
}

/// 실제: `public func MTLCreateSystemDefaultDevice() -> MTLDevice?`
public func MTLCreateSystemDefaultDevice() -> MTLDevice? { nil }

// MARK: - 디스크립터 (전부 `NSObject` 서브클래스이고 `init()` 로 만든다)

/// 실제: `open class MTLCompileOptions: NSObject { open var languageVersion: MTLLanguageVersion
///        open var fastMathEnabled: Bool; open var preprocessorMacros: [String: NSObject]? }`
open class MTLCompileOptions {
    public var languageVersion: MTLLanguageVersion = .version2_0
    public var fastMathEnabled: Bool = true
    public var preprocessorMacros: [String: NSObject]?
    public init() {}
}

/// 실제: `open class MTLTextureDescriptor: NSObject { ... }`
/// `texture2DDescriptor(pixelFormat:width:height:mipmapped:)` 는 **클래스 메서드**이고
/// non-optional `MTLTextureDescriptor` 를 돌려준다.
open class MTLTextureDescriptor {
    public var textureType: MTLTextureType = .type2D
    public var pixelFormat: MTLPixelFormat = .rgba8Unorm
    public var width: Int = 1
    public var height: Int = 1
    public var depth: Int = 1
    public var mipmapLevelCount: Int = 1
    public var sampleCount: Int = 1
    public var arrayLength: Int = 1
    public var resourceOptions: MTLResourceOptions = []
    public var cpuCacheMode: MTLCPUCacheMode = .defaultCache
    public var storageMode: MTLStorageMode = .managed
    public var usage: MTLTextureUsage = .shaderRead
    public var allowGPUOptimizedContents: Bool = true
    public init() {}
    public class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int,
                                          mipmapped: Bool) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = pixelFormat; d.width = width; d.height = height
        return d
    }
}

/// 실제: `open class MTLDepthStencilDescriptor: NSObject { open var depthCompareFunction:
///        MTLCompareFunction; open var isDepthWriteEnabled: Bool; open var label: String? }`
open class MTLDepthStencilDescriptor {
    public var depthCompareFunction: MTLCompareFunction = .always
    public var isDepthWriteEnabled: Bool = false
    public var label: String?
    public init() {}
}

/// 실제: `open class MTLRenderPassAttachmentDescriptor: NSObject { open var texture: MTLTexture?
///        open var level: Int; open var slice: Int; open var depthPlane: Int
///        open var loadAction: MTLLoadAction; open var storeAction: MTLStoreAction
///        open var resolveTexture: MTLTexture? ... }`
open class MTLRenderPassAttachmentDescriptor {
    public var texture: MTLTexture?
    public var level: Int = 0
    public var slice: Int = 0
    public var depthPlane: Int = 0
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .dontCare
    public var resolveTexture: MTLTexture?
    public init() {}
}

/// 실제: `open class MTLRenderPassColorAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
///        open var clearColor: MTLClearColor }`
public final class MTLRenderPassColorAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
}

/// 실제: `open class MTLRenderPassDepthAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
///        open var clearDepth: Double }`
public final class MTLRenderPassDepthAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
    public var clearDepth: Double = 1.0
}

/// 실제: `open class MTLRenderPassColorAttachmentDescriptorArray: NSObject`.
/// **서브스크립트는 IUO(`...Descriptor!`) 로 임포트된다** — ObjC 게터가 nonnull, 세터가 nullable 이라
/// Swift 가 둘을 맞추면서 IUO 가 된다. 그래서 호출부가 `colorAttachments[0]` 도 `colorAttachments[0]!`
/// 도 쓸 수 있다(둘 다 실제로 쓰인다 — 후자는 `HDRBloomPass.swift:80`).
public final class MTLRenderPassColorAttachmentDescriptorArray {
    private var store: [Int: MTLRenderPassColorAttachmentDescriptor] = [:]
    public subscript(index: Int) -> MTLRenderPassColorAttachmentDescriptor! {
        get { if let v = store[index] { return v }
              let v = MTLRenderPassColorAttachmentDescriptor(); store[index] = v; return v }
        set { store[index] = newValue }
    }
}

/// 실제: `open class MTLRenderPassDescriptor: NSObject { open class func renderPassDescriptor()
///        -> MTLRenderPassDescriptor; open var colorAttachments: ...Array (get only)
///        open var depthAttachment: MTLRenderPassDepthAttachmentDescriptor! }`
open class MTLRenderPassDescriptor {
    public let colorAttachments = MTLRenderPassColorAttachmentDescriptorArray()
    public var depthAttachment: MTLRenderPassDepthAttachmentDescriptor! = MTLRenderPassDepthAttachmentDescriptor()
    public var renderTargetWidth: Int = 0
    public var renderTargetHeight: Int = 0
    public init() {}
    public class func renderPassDescriptor() -> MTLRenderPassDescriptor { MTLRenderPassDescriptor() }
}

/// 실제: `open class MTLRenderPipelineColorAttachmentDescriptor: NSObject { ... }`
public final class MTLRenderPipelineColorAttachmentDescriptor {
    public var pixelFormat: MTLPixelFormat = .invalid
    public var isBlendingEnabled: Bool = false
    public var sourceRGBBlendFactor: MTLBlendFactor = .one
    public var destinationRGBBlendFactor: MTLBlendFactor = .zero
    public var rgbBlendOperation: MTLBlendOperation = .add
    public var sourceAlphaBlendFactor: MTLBlendFactor = .one
    public var destinationAlphaBlendFactor: MTLBlendFactor = .zero
    public var alphaBlendOperation: MTLBlendOperation = .add
    public var writeMask: MTLColorWriteMask = .all
    public init() {}
}

/// 실제: `open class MTLRenderPipelineColorAttachmentDescriptorArray: NSObject` — 서브스크립트는 IUO(위 참조).
public final class MTLRenderPipelineColorAttachmentDescriptorArray {
    private var store: [Int: MTLRenderPipelineColorAttachmentDescriptor] = [:]
    public subscript(index: Int) -> MTLRenderPipelineColorAttachmentDescriptor! {
        get { if let v = store[index] { return v }
              let v = MTLRenderPipelineColorAttachmentDescriptor(); store[index] = v; return v }
        set { store[index] = newValue }
    }
}

/// 실제: `open class MTLVertexAttributeDescriptor: NSObject { open var format: MTLVertexFormat
///        open var offset: Int; open var bufferIndex: Int }`
public final class MTLVertexAttributeDescriptor {
    public var format: MTLVertexFormat = .invalid
    public var offset: Int = 0
    public var bufferIndex: Int = 0
    public init() {}
}

/// 실제: `open class MTLVertexBufferLayoutDescriptor: NSObject { open var stride: Int
///        open var stepFunction: MTLVertexStepFunction; open var stepRate: Int }`
public final class MTLVertexBufferLayoutDescriptor {
    public var stride: Int = 0
    public var stepFunction: MTLVertexStepFunction = .perVertex
    public var stepRate: Int = 1
    public init() {}
}

public final class MTLVertexAttributeDescriptorArray {
    private var store: [Int: MTLVertexAttributeDescriptor] = [:]
    public subscript(index: Int) -> MTLVertexAttributeDescriptor! {
        get { if let v = store[index] { return v }
              let v = MTLVertexAttributeDescriptor(); store[index] = v; return v }
        set { store[index] = newValue }
    }
}

public final class MTLVertexBufferLayoutDescriptorArray {
    private var store: [Int: MTLVertexBufferLayoutDescriptor] = [:]
    public subscript(index: Int) -> MTLVertexBufferLayoutDescriptor! {
        get { if let v = store[index] { return v }
              let v = MTLVertexBufferLayoutDescriptor(); store[index] = v; return v }
        set { store[index] = newValue }
    }
}

/// 실제: `open class MTLVertexDescriptor: NSObject { open var layouts: ...Array (get)
///        open var attributes: ...Array (get); open class func vertexDescriptor() -> Self }`
open class MTLVertexDescriptor {
    public let attributes = MTLVertexAttributeDescriptorArray()
    public let layouts = MTLVertexBufferLayoutDescriptorArray()
    public init() {}
    public class func vertexDescriptor() -> MTLVertexDescriptor { MTLVertexDescriptor() }
}

/// 실제: `open class MTLRenderPipelineDescriptor: NSObject { ... }`
/// `sampleCount` 는 deprecated 이고 현행 이름은 `rasterSampleCount` 다 — 둘 다 둔다.
open class MTLRenderPipelineDescriptor {
    public var label: String?
    public var vertexFunction: MTLFunction?
    public var fragmentFunction: MTLFunction?
    public var vertexDescriptor: MTLVertexDescriptor?
    public var sampleCount: Int = 1
    public var rasterSampleCount: Int = 1
    public var isAlphaToCoverageEnabled: Bool = false
    public let colorAttachments = MTLRenderPipelineColorAttachmentDescriptorArray()
    public var depthAttachmentPixelFormat: MTLPixelFormat = .invalid
    public var stencilAttachmentPixelFormat: MTLPixelFormat = .invalid
    public init() {}
}
