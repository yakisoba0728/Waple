// 리눅스용 **Compression 대역 선언**(shim). 타입체크 전용. 사용처: `TexDecoder.swift`(LZ4 RAW).
@_exported import Foundation

/// 실제: `public struct compression_algorithm: RawRepresentable` — C 열거형 임포트.
/// `COMPRESSION_LZ4_RAW` 등은 그 타입의 전역 상수다.
public struct compression_algorithm: RawRepresentable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_LZ4 = compression_algorithm(rawValue: 0x100)
public let COMPRESSION_LZ4_RAW = compression_algorithm(rawValue: 0x101)
public let COMPRESSION_ZLIB = compression_algorithm(rawValue: 0x205)
public let COMPRESSION_LZFSE = compression_algorithm(rawValue: 0x801)
public let COMPRESSION_LZMA = compression_algorithm(rawValue: 0x306)

/// 실제: `public func compression_decode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>,
///        _ dst_size: Int, _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
///        _ scratch_buffer: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int`
/// 반환은 실제로 쓴 바이트 수(실패 0).
public func compression_decode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?,
                                      _ algorithm: compression_algorithm) -> Int { 0 }
/// 실제: `public func compression_encode_buffer(...) -> Int` (인자 배치는 decode 와 같다)
public func compression_encode_buffer(_ dst_buffer: UnsafeMutablePointer<UInt8>, _ dst_size: Int,
                                      _ src_buffer: UnsafePointer<UInt8>, _ src_size: Int,
                                      _ scratch_buffer: UnsafeMutableRawPointer?,
                                      _ algorithm: compression_algorithm) -> Int { 0 }
