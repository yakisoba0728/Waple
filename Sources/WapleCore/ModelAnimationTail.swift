import Foundation

/// MDLA events retain the original timestamp and opaque payload, even when no JSON marker is present.
public struct ModelAnimationEvent: Equatable, Sendable {
    public let time: Float
    public let payload: String
    public init(time: Float, payload: String) { self.time = time; self.payload = payload }
}

/// Serialized MDLA tail, not the sizes of its allocated C++ objects.
/// Source: FUN_140261880.c lines1996..3050; flags&1 reads18B, while0xC0 is a heap allocation.
enum ModelAnimationTail {
    struct Result {
        let end: Int
        let events: [ModelAnimationEvent]
        func markers(fps: Float) -> [AnimationMarker] {
            events.compactMap { event in
                guard let object = AssetJSON.dictionary(Data(event.payload.utf8)),
                      let name = object["name"] as? String,
                      let frame = safeFloat(Double(event.time) * Double(fps)) else { return nil }
                return AnimationMarker(name: name, frame: frame)
            }
        }
    }

    static func parse(_ bytes: [UInt8], at start: Int, limit: Int, version: Int, flags: UInt32,
                      boneCount: Int, tagCount: Int, constraintCount: Int, meshCount: Int) -> Result? {
        guard start >= 0, limit <= bytes.count, start <= limit,
              boneCount >= 0, tagCount >= 0, constraintCount >= 0, meshCount >= 0 else { return nil }
        var p = start
        func advance(_ count: Int) -> Bool {
            guard count >= 0, count <= limit - p else { return false }
            p += count
            return true
        }
        func u8() -> UInt8? {
            guard p < limit else { return nil }
            defer { p += 1 }
            return bytes[p]
        }
        func u16() -> UInt16? {
            guard p <= limit - 2 else { return nil }
            defer { p += 2 }
            return UInt16(clamping: bytes[p]) | UInt16(clamping: bytes[p + 1]) << 8
        }
        func u32() -> UInt32? {
            guard p <= limit - 4, let value = readU32LE(bytes, at: p) else { return nil }
            p += 4
            return value
        }
        func records(_ count: Int, scalar: Bool) -> Bool {
            guard count <= (limit - p) / 8 else { return false }
            for _ in 0..<count {
                guard u32() != nil, let size = u32(), size % (scalar ? 4 : 36) == 0,
                      advance(Int(clamping: size)) else { return false }
            }
            return true
        }
        if version >= 2, !records(tagCount, scalar: false) { return nil }
        guard records(constraintCount, scalar: true) else { return nil }
        if version >= 3 {
            guard let count = u32(), records(Int(clamping: count), scalar: true), let gate = u8() else { return nil }
            if gate != 0, !records(boneCount, scalar: true) { return nil }
        }
        if version >= 4 {
            guard let gate = u8() else { return nil }
            if gate != 0 {
                guard meshCount <= (limit - p) / 4 else { return nil }
                for _ in 0..<meshCount {
                    guard let mask = u32() else { return nil }
                    if mask & 1 != 0 {
                        guard advance(4), let count = u16(), Int(clamping: count) <= (limit - p) / 6 else { return nil }
                        for _ in 0..<count {
                            guard u16() != nil, let size = u32(), size % 4 == 0,
                                  advance(Int(clamping: size)) else { return nil }
                        }
                    }
                }
            }
        }
        if version >= 5, !advance(24) { return nil }
        if version >= 6 {
            guard let gate = u8() else { return nil }
            if gate != 0, !records(boneCount, scalar: true) { return nil }
        }
        if flags & 1 != 0, !advance(18) { return nil }
        guard let count = u32(), Int(clamping: count) <= (limit - p) / 5 else { return nil }
        var events: [ModelAnimationEvent] = []
        events.reserveCapacity(Int(clamping: count))
        for _ in 0..<count {
            guard let time = u32(), p < limit,
                  let payload = readCString(bytes, at: p, maxLength: limit - p - 1), payload.next <= limit else { return nil }
            events.append(ModelAnimationEvent(time: Float(bitPattern: time), payload: payload.value))
            p = payload.next
        }
        return Result(end: p, events: events)
    }
}
