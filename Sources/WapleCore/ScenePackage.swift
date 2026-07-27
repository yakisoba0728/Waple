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
    private let entryByName: [String: Entry]
    private let entryByNormalizedName: [String: Entry]

    private init(entries: [Entry], blob: Data, blobBase: Int) {
        self.entries = entries
        self.blob = blob
        self.blobBase = blobBase
        var index: [String: Entry] = [:]
        var normalizedIndex: [String: Entry] = [:]
        for entry in entries where index[entry.name] == nil {
            index[entry.name] = entry
        }
        for entry in entries {
            let key = Self.normalizedLookupKey(entry.name)
            if normalizedIndex[key] == nil { normalizedIndex[key] = entry }
        }
        self.entryByName = index
        self.entryByNormalizedName = normalizedIndex
    }

    public static func parse(_ data: Data) throws -> ScenePackage {
        // Data 직접 인덱싱 — 종전 [UInt8](data) 전량 복사는 700MB pkg 의 mappedIfSafe(비상주) 이점을
        // 무효화(DeepScan 동시 스캔 OOM 방지 설계). 헤더만 순차 판독, blob 은 원본 Data 참조 유지.
        let base = data.startIndex   // Data 슬라이스는 startIndex 0 이 아닐 수 있음
        let total = data.count
        let maxEntries = 65_536
        func i32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= total else { throw ScenePackageError.malformed }
            let i = base + o
            return Int(UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24)
        }
        var p = 0
        let vlen = try i32(p); p += 4
        guard vlen >= 0, p + vlen <= total else { throw ScenePackageError.malformed }
        let magic = String(decoding: data[(base + p)..<(base + p + vlen)], as: UTF8.self)
        // WE-ENGINE-ANALYSIS-2026-07-27.md §2 (corpus_scan/pkgv_parse.py, 446씬·19,777엔트리 0파스에러
        // 대조): "PKGV" 뒤 4자리는 **per-file serial**(임의값)이지 버전이 아니다 — authoritative 필드는
        // 뒤따르는 entry_count(offset 0x0c, 아래 `count`)다. 종전 코드는 이를 "버전"으로 오인해 1~99
        // 범위 게이트를 걸었다(실코퍼스 관측 1~24 내에선 무해했으나 의미상 오류 — serial 이 100 이상인
        // 정상 pkg 를 향후 거부할 잠재 위험). 구조 검증(정확히 "PKGV"+4 ASCII 숫자)만 유지하고 값 범위
        // 게이트는 제거 — serial 값 자체는 무의미하므로 파싱에 쓰지 않는다.
        guard magic.range(of: "^PKGV[0-9]{4}$", options: .regularExpression) != nil else {
            throw ScenePackageError.malformed
        }
        p += vlen
        let count = try i32(p); p += 4
        guard count >= 0, count <= maxEntries else { throw ScenePackageError.malformed }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let nlen = try i32(p); p += 4
            guard nlen >= 0, p + nlen <= total else { throw ScenePackageError.malformed }
            let name = String(decoding: data[(base + p)..<(base + p + nlen)], as: UTF8.self); p += nlen
            let off = try i32(p); p += 4
            let sz = try i32(p); p += 4
            entries.append(Entry(name: name, offset: off, size: sz))
        }
        let blobBase = p
        for e in entries {
            guard e.offset >= 0, e.size >= 0, blobBase + e.offset + e.size <= total else {
                throw ScenePackageError.malformed
            }
        }
        return ScenePackage(entries: entries, blob: data, blobBase: blobBase)
    }

    public func data(for name: String) -> Data? {
        let e = entryByName[name] ?? entryByNormalizedName[Self.normalizedLookupKey(name)]
        guard let e else { return nil }
        let start = blob.startIndex + blobBase + e.offset
        return blob.subdata(in: start ..< start + e.size)
    }

    private static func normalizedLookupKey(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    /// 엔트리 목록으로부터 패키지를 조립(파싱 결과와 동일 구조). 테스트/리패킹용.
    public static func assemble(_ files: [(name: String, data: Data)]) -> ScenePackage {
        var blob = Data()
        var entries: [Entry] = []
        var offset = 0
        for (name, data) in files {
            entries.append(Entry(name: name, offset: offset, size: data.count))
            blob.append(data)
            offset += data.count
        }
        return ScenePackage(entries: entries, blob: blob, blobBase: 0)
    }
}
