// 리눅스용 **UniformTypeIdentifiers 대역 선언**(shim). 타입체크 전용.
// 배경·규약은 `metal.swift` 머리말 참조. `WallpaperSchemeHandler.mimeType(for:)` 만 쓴다.
import Foundation

/// 실제: `@frozen public struct UTType: Equatable, Hashable, Sendable {
///        public init?(filenameExtension: String)
///        public init?(filenameExtension: String, conformingTo supertype: UTType)
///        public var preferredMIMEType: String? { get }
///        public var identifier: String { get } }`
/// 확신 없음: `UTType` 은 실제로는 `Sendable`·`ReferenceConvertible` 계열 애노테이션이 더 붙어 있다.
/// 여기서는 호출부가 쓰는 실패가능 이니셜라이저와 `preferredMIMEType` 만 재현한다.
public struct UTType: Equatable, Hashable {
    public let identifier: String
    public init?(filenameExtension: String) { nil }
    public var preferredMIMEType: String? { nil }
    /// [2026-08-21] `--tests` 가 요구한 표면 — `TexDecoderTests:24` 가 `UTType.png.identifier`
    /// 를 `CGImageDestinationCreateWithData` 의 타입 인자로 넘긴다. 여기서만 **식별자 값이
    /// 실제로 쓰이므로** 더미가 아니라 진짜 UTI 문자열을 넣는다(타입만 맞추면 되는 다른
    /// 심들과 다른 예외 — 값이 틀려도 타입체크는 통과하지만, 나중에 이 상수를 읽고 뭔가를
    /// 판단하는 코드가 생기면 조용히 틀린다).
    private init(_ id: String) { self.identifier = id }
    public static let png = UTType("public.png")
    public static let jpeg = UTType("public.jpeg")
    public static let tiff = UTType("public.tiff")
}
