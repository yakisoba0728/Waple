// 리눅스용 **CryptoKit 대역 선언**(shim). 타입체크 전용.
// 사용처: `VideoTextureExtractor.swift`(캐시 지문), `FFmpegConverter.swift`.
//
// 주의: 애플의 CryptoKit 은 리눅스에서 swift-crypto(`import Crypto`)로 대체되지만, 여기서는
// **타입체크만** 하면 되므로 실제 해시를 계산하지 않는다. 이 심으로 통과한 코드의 해시 값이
// 맞는지는 검증되지 않는다.
@_exported import Foundation

/// 실제: `public struct SHA256Digest: Digest, Sequence` — `Collection<UInt8>` 이라
/// `map { String(format: "%02x", $0) }` 같은 관용구가 통한다.
public struct SHA256Digest: Sequence, Equatable, CustomStringConvertible {
    private let bytes: [UInt8] = []
    public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
    public var description: String { "" }
}

/// 실제: `public struct SHA256: HashFunction { public init(); public mutating func update(data:)
///        public func finalize() -> SHA256Digest; public static func hash(data:) -> SHA256Digest }`
public struct SHA256 {
    public init() {}
    public mutating func update<D: DataProtocol>(data: D) {}
    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {}
    public func finalize() -> SHA256Digest { SHA256Digest() }
    public static func hash<D: DataProtocol>(data: D) -> SHA256Digest { SHA256Digest() }
}

/// 실제: `public enum Insecure { public struct MD5: HashFunction { ... } }`
/// 확신 없음: WapleRender 가 실제로 쓰는지 확인되지 않았다(census 에는 SHA256 만 나왔다).
public enum Insecure {
    public struct MD5Digest: Sequence, Equatable, CustomStringConvertible {
        private let bytes: [UInt8] = []
        public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
        public var description: String { "" }
    }
    public struct MD5 {
        public init() {}
        public mutating func update<D: DataProtocol>(data: D) {}
        public func finalize() -> MD5Digest { MD5Digest() }
        public static func hash<D: DataProtocol>(data: D) -> MD5Digest { MD5Digest() }
    }
}
