import Foundation

public enum ScenePackageError: Error, Equatable { case malformed }

public struct ScenePackage {
    public struct Entry: Equatable {
        public let name: String
        public let offset: Int
        public let size: Int
    }

    public let entries: [Entry]
    private let blob: Data
    private let blobBase: Int

    private init(entries: [Entry], blob: Data, blobBase: Int) {
        self.entries = entries
        self.blob = blob
        self.blobBase = blobBase
    }

    public static func parse(_ data: Data) throws -> ScenePackage {
        let b = [UInt8](data)
        func i32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= b.count else { throw ScenePackageError.malformed }
            return Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        var p = 0
        let vlen = try i32(p); p += 4
        guard vlen >= 0, p + vlen <= b.count else { throw ScenePackageError.malformed }
        p += vlen
        let count = try i32(p); p += 4
        guard count >= 0, count < 1_000_000 else { throw ScenePackageError.malformed }
        var entries: [Entry] = []
        for _ in 0..<count {
            let nlen = try i32(p); p += 4
            guard nlen >= 0, p + nlen <= b.count else { throw ScenePackageError.malformed }
            let name = String(decoding: b[p..<p + nlen], as: UTF8.self); p += nlen
            let off = try i32(p); p += 4
            let sz = try i32(p); p += 4
            entries.append(Entry(name: name, offset: off, size: sz))
        }
        let blobBase = p
        for e in entries {
            guard e.offset >= 0, e.size >= 0, blobBase + e.offset + e.size <= b.count else {
                throw ScenePackageError.malformed
            }
        }
        return ScenePackage(entries: entries, blob: data, blobBase: blobBase)
    }

    public func data(for name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let start = blob.startIndex + blobBase + e.offset
        return blob.subdata(in: start ..< start + e.size)
    }
}
