// 리눅스용 **CoreGraphics + CoreFoundation 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 동일하다.
//
// 이 모듈이 CF 타입까지 함께 들고 있는 이유: 애플에서 `CFData`/`CFAbsoluteTime` 은 Foundation 이
// CoreFoundation 을 재수출해서 들어온다. 리눅스 Foundation 은 그 재수출을 하지 않고, 재수출을
// 흉내내려면 Foundation 자체를 대역으로 갈아야 해서 비용이 크다. 대신 이 모듈을 `Metal`·`AppKit`
// 심이 `@_exported import` 해서 같은 자리에 놓는다.
//
// 리눅스 Foundation 이 **이미 주는 것**(다시 선언하면 충돌한다):
//   CGFloat, CGPoint, CGSize, CGRect, CGVector, NSPoint/NSSize/NSRect(별칭), NSEdgeInsets,
//   NSObject, NSNumber, NSString, NSAttributedString, NSLock, NSLog, NSNull, NSRange
@_exported import Foundation
// 리눅스 Foundation 은 `URLSession`/`HTTPURLResponse` 를 **`AnyObject` 로 가는 deprecated 별칭**으로만
// 두고 실물은 `FoundationNetworking` 에 있다(애플에서는 Foundation 하나에 다 있다). 재수출하지 않으면
// `NowPlayingProvider.swift` 가 "type 'URLSession' (aka 'AnyObject') has no member 'shared'" 로 깨진다.
@_exported import FoundationNetworking

// MARK: - CoreFoundation 최소 대역

/// 실제: `CFData`/`CFString` 은 CoreFoundation 의 불투명 타입이고 Foundation 의 `NSData`/`NSString`
/// 과 **toll-free bridged** 다. 리눅스에는 그 브리지가 없어 `data as CFData` 가 안 된다 —
/// 그래서 별칭으로 둔다. `as CFData` / `as CFString` 캐스트가 그대로 통과한다.
public typealias CFData = NSData
public typealias CFString = NSString
public typealias CFDictionary = NSDictionary
public typealias CFArray = NSArray
public typealias CFTypeRef = AnyObject
public typealias CFTypeID = UInt
public typealias CFAbsoluteTime = Double
public typealias CFTimeInterval = Double

/// 실제: `public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime`
/// (2001-01-01 UTC 기준 초. `Date().timeIntervalSinceReferenceDate` 와 같은 기준점이다.)
public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Date().timeIntervalSinceReferenceDate }

/// 실제: `public func CFGetTypeID(_ cf: CFTypeRef) -> CFTypeID`
/// macOS 는 `CFGetTypeID(n) == CFBooleanGetTypeID()` 로 JSON true/false 를 숫자와 가른다.
/// 리눅스에는 그 타입 태그가 없어 `objCType == "c"`(char) 로 같은 판정을 한다 —
/// `linux-shim/corefoundation.swift`(WapleCore 쪽)와 **같은 규약**이다.
public func CFGetTypeID(_ cf: CFTypeRef) -> CFTypeID {
    guard let n = cf as? NSNumber else { return 0 }
    return String(cString: n.objCType) == "c" ? 1 : 0
}
/// 실제: `public func CFBooleanGetTypeID() -> CFTypeID`
public func CFBooleanGetTypeID() -> CFTypeID { 1 }

// MARK: - CGAffineTransform

/// 실제: `public struct CGAffineTransform { public var a, b, c, d, tx, ty: CGFloat
///        public static let identity: CGAffineTransform; init(a:b:c:d:tx:ty:) }`
public struct CGAffineTransform: Equatable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }
    /// 실제: `public init(rotationAngle angle: CGFloat)` — 반시계 회전.
    /// [2026-08-21] `--tests` 가 요구한 표면(`MediaFixRegressionTests:481` 이 30° 회전을
    /// "8원소 어디에도 안 맞는다" 는 음성 대조로 쓴다). **값이 맞아야 한다** — 그 단언은
    /// 실제 성분을 보고 `nil` 을 기대하므로 더미(항등)로 두면 테스트의 의미가 뒤집힌다
    /// (타입만 맞추는 다른 심들과 다른 예외다. 여기서는 산식이 짧고 명확해서 그대로 적는다).
    public init(rotationAngle angle: CGFloat) {
        let c = cos(angle), s = sin(angle)
        self.init(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }
    /// 실제: `public init(scaleX sx: CGFloat, y sy: CGFloat)`
    public init(scaleX sx: CGFloat, y sy: CGFloat) {
        self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }
    /// 실제: `public init(translationX tx: CGFloat, y ty: CGFloat)`
    public init(translationX tx: CGFloat, y ty: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }
    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    /// 실제: `public var isIdentity: Bool { get }`
    public var isIdentity: Bool { self == .identity }
    /// 실제: `public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform`
    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: a * t2.a + b * t2.c, b: a * t2.b + b * t2.d,
                          c: c * t2.a + d * t2.c, d: c * t2.b + d * t2.d,
                          tx: tx * t2.a + ty * t2.c + t2.tx, ty: tx * t2.b + ty * t2.d + t2.ty)
    }
}

// MARK: - 색공간 · 이미지

/// 실제: `public class CGColorSpace { public init?(name: CFString)
///        public class let sRGB: CFString; genericRGBLinear; displayP3; ... }`
/// `CGColorSpace.sRGB` 는 **색공간이 아니라 이름 상수(CFString)** 다 — `CGColorSpace(name:)` 에 넘긴다.
public class CGColorSpace {
    public static let sRGB: CFString = "kCGColorSpaceSRGB" as NSString
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear" as NSString
    public static let displayP3: CFString = "kCGColorSpaceDisplayP3" as NSString
    public static let extendedLinearSRGB: CFString = "kCGColorSpaceExtendedLinearSRGB" as NSString
    public init?(name: CFString) { nil }
    internal init(unavailable: ()) {}
}

/// 실제: `public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace` (non-optional)
public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(unavailable: ()) }
/// 실제: `public func CGColorSpaceCreateDeviceGray() -> CGColorSpace`
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(unavailable: ()) }

/// 실제: `public enum CGImageAlphaInfo: UInt32 { case none, premultipliedLast, premultipliedFirst,
///        last, first, noneSkipLast, noneSkipFirst, alphaOnly }`
/// `rawValue` 는 `UInt32` 다 — `bitmapInfo:` 인자에 그대로 넘어간다.
public enum CGImageAlphaInfo: UInt32 {
    case none = 0, premultipliedLast = 1, premultipliedFirst = 2, last = 3, first = 4
    case noneSkipLast = 5, noneSkipFirst = 6, alphaOnly = 7
}

/// 실제: `public struct CGBitmapInfo: OptionSet { public let rawValue: UInt32 ... }`
public struct CGBitmapInfo: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let alphaInfoMask = CGBitmapInfo(rawValue: 31)
    public static let floatComponents = CGBitmapInfo(rawValue: 256)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 28672)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 8192)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 16384)
}

/// 실제: `public class CGImage { public var width: Int { get }; height; bitsPerComponent;
///        bitsPerPixel; bytesPerRow; colorSpace: CGColorSpace?; alphaInfo: CGImageAlphaInfo;
///        dataProvider: CGDataProvider? ... }`
public class CGImage {
    public var width: Int { fatalError("linux shim") }
    public var height: Int { fatalError("linux shim") }
    public var bitsPerComponent: Int { fatalError("linux shim") }
    public var bitsPerPixel: Int { fatalError("linux shim") }
    public var bytesPerRow: Int { fatalError("linux shim") }
    public var alphaInfo: CGImageAlphaInfo { fatalError("linux shim") }
    public var colorSpace: CGColorSpace? { fatalError("linux shim") }
    internal init(unavailable: ()) {}
}

/// 실제: `public enum CGInterpolationQuality: Int32 { case `default`, none, low, medium, high }`
public enum CGInterpolationQuality: Int32 {
    case `default` = 0, none = 1, low = 2, medium = 3, high = 4
}

/// 실제: `public enum CGTextDrawingMode: Int32 { case fill, stroke, fillStroke, invisible, ... }`
public enum CGTextDrawingMode: Int32 {
    case fill = 0, stroke = 1, fillStroke = 2, invisible = 3
}

/// 실제: `public class CGColor { public init?(red:green:blue:alpha:) ... }`
public class CGColor {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
    internal init(unavailable: ()) {}
}

/// 실제: `public class CGContext { public init?(data: UnsafeMutableRawPointer?, width: Int,
///        height: Int, bitsPerComponent: Int, bytesPerRow: Int, space: CGColorSpace,
///        bitmapInfo: UInt32) }` — `bitmapInfo` 는 `UInt32`(= `CGImageAlphaInfo.rawValue`) 다.
public class CGContext {
    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int,
                 bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) { nil }
    /// 실제: `open func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false)`
    public func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false) { fatalError("linux shim") }
    public var interpolationQuality: CGInterpolationQuality {
        get { fatalError("linux shim") } set { fatalError("linux shim") }
    }
    /// 실제: `open var textPosition: CGPoint { get set }`
    public var textPosition: CGPoint { get { fatalError("linux shim") } set { fatalError("linux shim") } }
    public func setAllowsFontSmoothing(_ allows: Bool) { fatalError("linux shim") }
    public func setShouldSmoothFonts(_ should: Bool) { fatalError("linux shim") }
    public func setAllowsAntialiasing(_ allows: Bool) { fatalError("linux shim") }
    public func setShouldAntialias(_ should: Bool) { fatalError("linux shim") }
    public func setFillColor(_ color: CGColor) { fatalError("linux shim") }
    public func setTextDrawingMode(_ mode: CGTextDrawingMode) { fatalError("linux shim") }
    public func fill(_ rect: CGRect) { fatalError("linux shim") }
    public func clear(_ rect: CGRect) { fatalError("linux shim") }
    public func translateBy(x: CGFloat, y: CGFloat) { fatalError("linux shim") }
    public func scaleBy(x: CGFloat, y: CGFloat) { fatalError("linux shim") }
    public func saveGState() { fatalError("linux shim") }
    public func restoreGState() { fatalError("linux shim") }
    public func makeImage() -> CGImage? { fatalError("linux shim") }
}

// MARK: - 디스플레이 · 윈도우 레벨(CoreGraphics 의 윈도우 서버 API)

/// 실제: `public typealias CGDirectDisplayID = UInt32`
public typealias CGDirectDisplayID = UInt32
/// 실제: `public typealias CGWindowLevel = Int32`
public typealias CGWindowLevel = Int32

/// 실제: `public enum CGWindowLevelKey: Int32 { case baseWindow, minimumWindow, desktopWindow,
///        backstopMenu, normalWindow, floatingWindow, tornOffMenuWindow, dockWindow,
///        mainMenuWindow, statusWindow, modalPanelWindow, popUpMenuWindow, draggingWindow,
///        screenSaverWindow, maximumWindow, overlayWindow, helpWindow, utilityWindow,
///        desktopIconWindow, cursorWindow, assistiveTechHighWindow, numberOfWindowLevelKeys }`
/// 확신 없음: 케이스 **순서/원시값**은 실제 헤더 순서를 그대로 옮긴 것이 아니다.
/// `WallpaperWindowLevel` 은 `.desktopIconWindow` 이름만 쓰므로 값은 타입체크에 영향이 없다.
public enum CGWindowLevelKey: Int32 {
    case baseWindow = 0, minimumWindow, desktopWindow, backstopMenu, normalWindow
    case floatingWindow, tornOffMenuWindow, dockWindow, mainMenuWindow, statusWindow
    case modalPanelWindow, popUpMenuWindow, draggingWindow, screenSaverWindow, maximumWindow
    case overlayWindow, helpWindow, utilityWindow, desktopIconWindow, cursorWindow
    case assistiveTechHighWindow, numberOfWindowLevelKeys
}

/// 실제: `public func CGWindowLevelForKey(_ key: CGWindowLevelKey) -> CGWindowLevel`
public func CGWindowLevelForKey(_ key: CGWindowLevelKey) -> CGWindowLevel { 0 }
