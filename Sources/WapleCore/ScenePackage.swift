import Foundation

public enum ScenePackageError: Error, Equatable { case malformed }

public struct ScenePackage {
    public struct Entry: Equatable {
        public let name: String
        public let offset: Int
        public let size: Int
    }

    /// 바이트를 어디서 가져오는가. `.pkg` 는 단일 blob 슬라이스, 언팩 프로젝트 폴더는 지연 파일 읽기.
    /// 폴더를 통째로 메모리에 올리지 않는 이유: WE 설치본 기본 프로젝트가 최대 38 MB 이고 그중
    /// 상당량이 Waple 이 절대 읽지 않는 `.png` 원본(같은 자산의 `.tex` 와 병존)이다.
    private enum Storage {
        case blob(data: Data, base: Int)
        case directory(root: URL)
    }

    public let entries: [Entry]
    private let storage: Storage
    private let entryByName: [String: Entry]
    private let entryByNormalizedName: [String: Entry]

    private init(entries: [Entry], storage: Storage) {
        self.entries = entries
        self.storage = storage
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
        // [2026-07-27 정정] 이전 주석은 WE-ENGINE-ANALYSIS-2026-07-27.md §2 의 "PKGV 뒤 4자리 = per-file
        // serial(임의값), 버전 아님" 서술을 그대로 채택했으나, 로컬 코퍼스 169개 scene.pkg 의 매직 도수
        // 분포로 반증됐다: distinct 14값 중 0023×51/0022×47/0021×30/0024×12/0018×8/0020×6/0019×5/
        // 0017×3/0016×2, 롱테일 0001·0007·0008·0011·0012 각 1건 — 51중복 클러스터+구버전 롱테일은
        // per-file 난수 serial 로는 나올 수 없는 전형적 "버전 채택 곡선"이다(WE-2.8-deep-KR.md B1 이
        // 동일 결론 — PKGV0001~0024 14종 공존, 최빈 0023, 최신 0024 — 을 이미 확립해 둔 바 있다).
        //
        // 즉 4자리는 **포맷 버전**이다. 다만 값 범위 게이트를 두지 않는 근거는 바뀐다: RePKG
        // PackageReader.cs(Magic 필드를 그대로 읽어 바로 ReadEntries 로 진입, 버전별 분기 전무)가
        // 보여주듯 관측된 모든 버전에서 컨테이너 프레이밍(entry_count/index/data 레이아웃)이 불변이라,
        // 값 게이트가 추가 검증을 사지 못한다(대비: Model3D.swift 의 MDLV 는 버전마다 메시 바이트
        // 레이아웃이 실제로 달라 미목격 버전을 의도적으로 거부한다 — 두 정책은 상충이 아니라 포맷별
        // 실제 위험 차이를 반영한다). 구조 검증(정확히 "PKGV"+4 ASCII 숫자)만 유지하고 값 범위 게이트는
        // 생략한다 — 단 "버전"이므로 PKGV0100 이상 미래 버전도 낙관적으로 파싱을 시도한다는 뜻이며,
        // 종전 주석의 "관측 1~24, 99까지 허용" 식 안전 여백과는 성격이 다르다.
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
        return ScenePackage(entries: entries, storage: .blob(data: data, base: blobBase))
    }

    public func data(for name: String) -> Data? {
        let e = entryByName[name] ?? entryByNormalizedName[Self.normalizedLookupKey(name)]
        guard let e else { return nil }
        switch storage {
        case .blob(let blob, let blobBase):
            let start = blob.startIndex + blobBase + e.offset
            return blob.subdata(in: start ..< start + e.size)
        case .directory(let root):
            // e.name 은 아래 `fromDirectory` 가 루트 상대 경로로만 만든다(심볼릭 링크·상위 경로 배제).
            var url = root
            for component in e.name.split(separator: "/") { url.appendPathComponent(String(component)) }
            return try? Data(contentsOf: url)
        }
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
        return ScenePackage(entries: entries, storage: .blob(data: blob, base: 0))
    }

    /// G-E3-01: **언팩 프로젝트 폴더**를 패키지로 마운트한다.
    ///
    /// `scene.pkg` 는 워크샵 업로드 산출물일 뿐 저작·배포의 유일한 형태가 아니다. 실측(WE 2.8.42
    /// 설치본): `projects/` 아래 기본 배경 19종 + 템플릿 2종이 **전부 언팩 폴더**이고 `.pkg` 는
    /// 0개다. 에디터가 만드는 로컬 프로젝트도 언팩이다. 즉 종전의 `scene.pkg` 전용 마운트는
    /// "워크샵에서 받은 것만 돌아간다" 는 뜻이었다 — WE 를 설치한 사용자가 자기 기본 배경을
    /// 넣거나 에디터로 만든 배경을 넣으면 전건 "적용 실패" 다.
    ///
    /// 조회 키 규약은 `.pkg` 와 같아야 한다(`normalizedLookupKey` = 역슬래시→슬래시 + 소문자).
    /// 그래서 엔트리 이름을 루트 상대 경로로 만들고 구분자를 `/` 로 고정한다.
    ///
    /// - Note: 심볼릭 링크는 건너뛴다(루트 밖 탈출 차단). 숨김 파일도 건너뛴다.
    public static func fromDirectory(_ root: URL) -> ScenePackage? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let rootComponents = root.standardizedFileURL.pathComponents
        var entries: [Entry] = []
        let maxEntries = 65_536
        for case let url as URL in walker {
            if entries.count >= maxEntries { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let components = url.standardizedFileURL.pathComponents
            // 표준화 후에도 루트 접두가 유지되는 경로만 채택 — 링크를 타고 밖으로 나간 항목 배제.
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { continue }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            entries.append(Entry(name: relative, offset: 0, size: values.fileSize ?? 0))
        }
        guard !entries.isEmpty else { return nil }
        return ScenePackage(entries: entries, storage: .directory(root: root))
    }
}
