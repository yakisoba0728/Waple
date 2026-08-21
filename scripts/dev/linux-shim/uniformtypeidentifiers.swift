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
}
