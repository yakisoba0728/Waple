// 리눅스용 **CoreText 대역 선언**(shim). 타입체크 전용. 사용처: `TextRasterizer.swift`.
@_exported import CoreGraphics

/// 실제: `public class CTFont` — CoreFoundation 불투명 타입.
public class CTFont { internal init(unavailable: ()) {} }
/// 실제: `public class CTFontDescriptor`
public class CTFontDescriptor { internal init(unavailable: ()) {} }
/// 실제: `public class CTLine`
public class CTLine { internal init(unavailable: ()) {} }
/// 실제: `public class CTTypesetter`
public class CTTypesetter { internal init(unavailable: ()) {} }
/// 실제: `public class CTFrame` / `CTFramesetter` — WapleRender 는 쓰지 않는다(참고용 미선언).

/// 실제: `public enum CTFontUIFontType: UInt32 { case none, user, userFixedPitch, system, ... }`
/// 확신 없음: 케이스 목록·원시값은 실제 헤더 그대로가 아니다. `.system` 만 쓰인다.
public struct CTFontUIFontType: RawRepresentable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = CTFontUIFontType(rawValue: 0xFFFFFFFF)
    public static let user = CTFontUIFontType(rawValue: 0)
    public static let userFixedPitch = CTFontUIFontType(rawValue: 1)
    public static let system = CTFontUIFontType(rawValue: 2)
    public static let emphasizedSystem = CTFontUIFontType(rawValue: 3)
}

/// 실제: `public enum CTLineTruncationType: UInt32 { case start, end, middle }`
public struct CTLineTruncationType: RawRepresentable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let start = CTLineTruncationType(rawValue: 0)
    public static let end = CTLineTruncationType(rawValue: 1)
    public static let middle = CTLineTruncationType(rawValue: 2)
}

/// 실제: `public struct CFRange { public var location: CFIndex; public var length: CFIndex
///        public init(location: CFIndex, length: CFIndex) }` (CFIndex = Int)
public typealias CFIndex = Int
public struct CFRange {
    public var location: CFIndex
    public var length: CFIndex
    public init() { self.init(location: 0, length: 0) }
    public init(location: CFIndex, length: CFIndex) { self.location = location; self.length = length }
}

// MARK: - 폰트 생성

/// 실제: `public func CTFontCreateWithName(_ name: CFString, _ size: CGFloat,
///        _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont` (**non-optional** 반환 —
/// 미설치 폰트도 nil 이 아니라 조용한 폴백 페이스를 준다. TextRasterizer 주석이 그 사실을 적고 있다.)
public func CTFontCreateWithName(_ name: CFString, _ size: CGFloat,
                                 _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont {
    CTFont(unavailable: ())
}
/// 실제: `public func CTFontCreateWithFontDescriptor(_ descriptor: CTFontDescriptor, _ size: CGFloat,
///        _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont`
public func CTFontCreateWithFontDescriptor(_ descriptor: CTFontDescriptor, _ size: CGFloat,
                                           _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont {
    CTFont(unavailable: ())
}
/// 실제: `public func CTFontCreateUIFontForLanguage(_ uiType: CTFontUIFontType, _ size: CGFloat,
///        _ language: CFString?) -> CTFont?` (**옵셔널** — 위 두 개와 다르다)
public func CTFontCreateUIFontForLanguage(_ uiType: CTFontUIFontType, _ size: CGFloat,
                                          _ language: CFString?) -> CTFont? { nil }
/// 실제: `public func CTFontManagerCreateFontDescriptorFromData(_ data: CFData) -> CTFontDescriptor?`
public func CTFontManagerCreateFontDescriptorFromData(_ data: CFData) -> CTFontDescriptor? { nil }

/// 실제: `public func CTFontCopyFamilyName(_ font: CTFont) -> CFString`
public func CTFontCopyFamilyName(_ font: CTFont) -> CFString { "" as NSString }
/// 실제: `public func CTFontCopyPostScriptName(_ font: CTFont) -> CFString`
public func CTFontCopyPostScriptName(_ font: CTFont) -> CFString { "" as NSString }
/// 실제: `public func CTFontGetAscent(_ font: CTFont) -> CGFloat` (descent/leading 도 같은 꼴)
public func CTFontGetAscent(_ font: CTFont) -> CGFloat { 0 }
public func CTFontGetDescent(_ font: CTFont) -> CGFloat { 0 }
public func CTFontGetLeading(_ font: CTFont) -> CGFloat { 0 }
public func CTFontGetSize(_ font: CTFont) -> CGFloat { 0 }

// MARK: - 줄 · 타입세터

/// 실제: `public func CTLineCreateWithAttributedString(_ attrString: CFAttributedString) -> CTLine`
/// `CFAttributedString` 은 `NSAttributedString` 과 toll-free bridged 다.
public func CTLineCreateWithAttributedString(_ attrString: NSAttributedString) -> CTLine {
    CTLine(unavailable: ())
}
/// 실제: `public func CTLineCreateTruncatedLine(_ line: CTLine, _ width: Double,
///        _ truncationType: CTLineTruncationType, _ truncationToken: CTLine?) -> CTLine?`
public func CTLineCreateTruncatedLine(_ line: CTLine, _ width: Double,
                                      _ truncationType: CTLineTruncationType,
                                      _ truncationToken: CTLine?) -> CTLine? { nil }
/// 실제: `public func CTLineCreateJustifiedLine(_ line: CTLine, _ justificationFactor: CGFloat,
///        _ justificationWidth: Double) -> CTLine?`
public func CTLineCreateJustifiedLine(_ line: CTLine, _ justificationFactor: CGFloat,
                                      _ justificationWidth: Double) -> CTLine? { nil }
/// 실제: `public func CTLineGetTypographicBounds(_ line: CTLine,
///        _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?,
///        _ leading: UnsafeMutablePointer<CGFloat>?) -> Double`
public func CTLineGetTypographicBounds(_ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?,
                                       _ descent: UnsafeMutablePointer<CGFloat>?,
                                       _ leading: UnsafeMutablePointer<CGFloat>?) -> Double { 0 }
/// 실제: `public func CTLineDraw(_ line: CTLine, _ context: CGContext)`
public func CTLineDraw(_ line: CTLine, _ context: CGContext) {}
/// 실제: `public func CTLineGetGlyphCount(_ line: CTLine) -> CFIndex`
public func CTLineGetGlyphCount(_ line: CTLine) -> CFIndex { 0 }

/// 실제: `public func CTTypesetterCreateWithAttributedString(_ string: CFAttributedString) -> CTTypesetter`
public func CTTypesetterCreateWithAttributedString(_ string: NSAttributedString) -> CTTypesetter {
    CTTypesetter(unavailable: ())
}
/// 실제: `public func CTTypesetterSuggestLineBreak(_ typesetter: CTTypesetter, _ startIndex: CFIndex,
///        _ width: Double) -> CFIndex`
public func CTTypesetterSuggestLineBreak(_ typesetter: CTTypesetter, _ startIndex: CFIndex,
                                         _ width: Double) -> CFIndex { 0 }
/// 실제: `public func CTTypesetterCreateLine(_ typesetter: CTTypesetter, _ stringRange: CFRange) -> CTLine`
public func CTTypesetterCreateLine(_ typesetter: CTTypesetter, _ stringRange: CFRange) -> CTLine {
    CTLine(unavailable: ())
}
