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

// **`CFGetTypeID`/`CFBooleanGetTypeID` 는 여기 없다 — 일부러 뺐다.** [2026-08-21]
//
// 이 리포에서 그 둘을 내는 자리는 **`WapleCore` 하나**다: 스크립트가 `corefoundation.swift` 를
// `sed` 로 그 두 심볼만 public 으로 바꿔 `WapleCore` 스냅샷에 넣는다(스크립트 주석 참조).
// 종전에는 이 파일에도 같은 이름의 public 함수가 있었고, **두 모듈이 동시에 보이는 파일에서
// 호출이 통째로 모호해진다**. 실측 2026-08-21(`--app` 을 열면서 드러났다):
//
//   Sources/Waple/WorkshopAPI.swift:140:58: error: type of expression is ambiguous
//                                                  without a type annotation
//     guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { … }
//
// 그 파일은 `Foundation`+`Security`+`WapleCore` 만 import 하지만, `Security` 심이
// `CoreGraphics` 를 재수출하고 서곡이 `AppKit`(역시 CG 재수출)을 흘려서 둘 다 보인다.
// 렌더 축에서는 `CFGetTypeID` 를 부르는 파일이 `UserPropertyStore.swift`(Foundation+WapleCore)
// 하나뿐이라 지금까지 드러나지 않았을 뿐이다 — **잠재 결함이었지 앱 계층의 문제가 아니다.**

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

// MARK: - [2026-08-21] `--app` 이 요구한 표면 — CGWindowList
//
// `Sources/Waple/DesktopVisibilityMonitor.swift:146~165` 이 온스크린 창 목록을 떠서 데스크탑이
// 가려졌는지 판정한다. `--app` 이전에는 커버 밖이라 이 표면이 심에 없었다.

/// 실제: `public struct CGWindowListOption: OptionSet { public static var optionOnScreenOnly
///          / optionOnScreenAboveWindow / optionOnScreenBelowWindow / optionIncludingWindow
///          / excludeDesktopElements: CGWindowListOption }`
/// 확신 없음: 각 비트의 실제 값은 확인하지 못했다 — 호출부가 값을 읽지 않고 인자로만 넘긴다.
public struct CGWindowListOption: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let optionAll = CGWindowListOption(rawValue: 0)
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1 << 0)
    public static let optionOnScreenAboveWindow = CGWindowListOption(rawValue: 1 << 1)
    public static let optionOnScreenBelowWindow = CGWindowListOption(rawValue: 1 << 2)
    public static let optionIncludingWindow = CGWindowListOption(rawValue: 1 << 3)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 1 << 4)
}

/// 실제: `public typealias CGWindowID = UInt32` · `public let kCGNullWindowID: CGWindowID` (= 0)
public typealias CGWindowID = UInt32
public let kCGNullWindowID: CGWindowID = 0

/// 실제: `public func CGWindowListCopyWindowInfo(_ option: CGWindowListOption,
///          _ relativeToWindow: CGWindowID) -> CFArray?`
public func CGWindowListCopyWindowInfo(_ option: CGWindowListOption,
                                       _ relativeToWindow: CGWindowID) -> CFArray? { nil }

/// 실제: `CGWindow.h` 의 `extern const CFStringRef kCGWindowOwnerName;` 등.
/// 값은 딕셔너리 **키**로만 쓰이고 비교되지 않으므로 더미다 — 다만 서로 달라야 한다.
/// 확신 없음: 실제 raw 문자열은 `"kCGWindowOwnerName"` 계열이지만 여기서 확정할 근거가 없다.
public let kCGWindowOwnerName: CFString = "shim.kCGWindowOwnerName" as NSString
public let kCGWindowOwnerPID: CFString = "shim.kCGWindowOwnerPID" as NSString
public let kCGWindowLayer: CFString = "shim.kCGWindowLayer" as NSString
public let kCGWindowAlpha: CFString = "shim.kCGWindowAlpha" as NSString
public let kCGWindowBounds: CFString = "shim.kCGWindowBounds" as NSString
public let kCGWindowNumber: CFString = "shim.kCGWindowNumber" as NSString

// MARK: - [2026-08-21] `--app` 이 요구한 표면 — CFPreferences
//
// `Sources/Waple/ScreenSaverController.swift` 가 화면보호기 선택(`com.apple.screensaver` 의
// `moduleDict`, ByHost)을 CFPreferences 로 직접 읽고 쓴다 — 호출 18곳.
// 애플에서는 Foundation 이 CoreFoundation 을 재수출해서 들어오므로 그 파일은 `import AppKit`
// 하나뿐이다. 이 심 모듈이 그 자리를 대신한다(파일 머리말의 CF 최소분과 같은 이유).

/// 실제: `public let kCFPreferencesCurrentUser: CFString` 등 6종(`CFPreferences.h`).
/// 값은 도메인 지정에만 쓰이고 비교되지 않으므로 더미다 — 다만 서로 달라야 한다.
/// 확신 없음: 실제 raw 문자열은 `"kCFPreferencesCurrentUser"`·`"kCFPreferencesAnyHost"` 계열이다.
public let kCFPreferencesCurrentUser: CFString = "shim.kCFPreferencesCurrentUser" as NSString
public let kCFPreferencesAnyUser: CFString = "shim.kCFPreferencesAnyUser" as NSString
public let kCFPreferencesCurrentHost: CFString = "shim.kCFPreferencesCurrentHost" as NSString
public let kCFPreferencesAnyHost: CFString = "shim.kCFPreferencesAnyHost" as NSString
public let kCFPreferencesCurrentApplication: CFString = "shim.kCFPreferencesCurrentApplication" as NSString

/// 실제: `public func CFPreferencesCopyValue(_ key: CFString!, _ applicationID: CFString!,
///          _ userName: CFString!, _ hostName: CFString!) -> CFPropertyList!`
/// 확신 없음: 실물의 인자는 전부 **암묵적 언랩 옵셔널(`CFString!`)** 이고 반환은
/// `CFPropertyList!` 다. 여기서는 반환을 `CFTypeRef?`(= `AnyObject?`)로 뒀다 — 호출부가
/// `as? [String: Any]` 로 캐스팅하므로 통한다.
public func CFPreferencesCopyValue(_ key: CFString!, _ applicationID: CFString!,
                                   _ userName: CFString!, _ hostName: CFString!) -> CFTypeRef? { nil }

/// 실제: `public func CFPreferencesSetValue(_ key: CFString!, _ value: CFPropertyList!,
///          _ applicationID: CFString!, _ userName: CFString!, _ hostName: CFString!)`
public func CFPreferencesSetValue(_ key: CFString!, _ value: CFTypeRef?,
                                  _ applicationID: CFString!, _ userName: CFString!,
                                  _ hostName: CFString!) {}

/// 실제: `public func CFPreferencesSynchronize(_ applicationID: CFString!, _ userName: CFString!,
///          _ hostName: CFString!) -> Bool`
@discardableResult
public func CFPreferencesSynchronize(_ applicationID: CFString!, _ userName: CFString!,
                                     _ hostName: CFString!) -> Bool { true }
