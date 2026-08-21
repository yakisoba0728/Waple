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
        // serial(임의값), 버전 아님" 서술을 그대로 채택했으나, 워크샵 코퍼스의 매직 도수 분포로 반증됐다.
        //
        // [2026-08-21 재정정 — 인용 수치가 틀려 있었다] 종전 이 자리에는 "로컬 코퍼스 **169개**,
        // 0023×51/0022×47/0021×30/0024×12/0018×8/0020×6/0019×5/0017×3/0016×2 + 롱테일 0001 등" 이
        // 적혀 있었고 근거로 `WE-2.8-deep-KR.md` 를 댔다. **그 파일은 이 저장소에도 시스템 어디에도
        // 없고**(find 전역 0건), 실측 산출물이 말하는 수치는 다르다. 정본은 `spec/formats/pkg.json`
        // `format.pkg.magicDistribution`(생성기 `scripts/spec/measure_corpus.py`)이고 그 값은
        //   PKGV0023×50 · 0022×46 · 0021×28 · 0024×13 · 0020×6 · 0018×5 · 0019×5 · 0017×3 ·
        //   0002/0007/0008/0011/0012/0016 각 ×1  = **distinct 14종 / 합계 162**
        // 다(롱테일 최소값은 0001 이 아니라 **0002**). 그 162 의 내역도 이제 갈라진다 —
        // `measure_corpus.py` 는 폴더마다 `scene.pkg` 와 `gifscene.pkg` 를 **둘 다** 열고,
        // 독립 산출물 `Waple-wallpaper-source/corpus_scan/scenes-index.tsv`(`pkgv_census.py`,
        // 같은 워크샵 루트 446 폴더)는 `scene.pkg` 만 세어 **161개 · 엔트리 19,777** 이다.
        // 162 − 161 = 1(gifscene.pkg), 19,781 − 19,777 = 4 이고 확장자 델타가 `.json` +3 · `.tex` +1 ·
        // 나머지 전부 0 이라 **그 한 개의 gifscene.pkg 는 엔트리 4개(json 3 + tex 1)** 다.
        // 두 수치는 모순이 아니라 분모가 다르다.
        //
        // 도수 곡선의 성격은 그대로다: 최빈값 하나에 50건이 몰리고 구버전이 1건씩 꼬리를 끄는 모양은
        // per-file 난수 serial 로는 나올 수 없다. 게다가 **엔진의 상한이 정확히 24**이고(아래 ②)
        // 관측 최대값도 0024 라 "버전" 해석과 정확히 맞물린다.
        //
        // 즉 4자리는 **포맷 버전**이다. 다만 값 범위 게이트를 두지 않는 근거는 바뀐다: RePKG
        // PackageReader.cs(Magic 필드를 그대로 읽어 바로 ReadEntries 로 진입, 버전별 분기 전무)가
        // 보여주듯 관측된 모든 버전에서 컨테이너 프레이밍(entry_count/index/data 레이아웃)이 불변이라,
        // 값 게이트가 추가 검증을 사지 못한다(대비: Model3D.swift 의 MDLV 는 버전마다 메시 바이트
        // 레이아웃이 실제로 달라 미목격 버전을 의도적으로 거부한다 — 두 정책은 상충이 아니라 포맷별
        // 실제 위험 차이를 반영한다).
        //
        // [2026-08-21 정정 — docs/re/package-format.md §2.2·§7.4] 위 문단의 결론(프레이밍이 버전
        // 불변)은 엔진 코드로도 맞다(`0x140276980` 이후 버전 분기가 없다). **틀린 것은 그 아래
        // 함의였다** — "그러니 WE 도 낙관적으로 받는다" 는 사실이 아니고, 이 게이트는 두 방향 모두
        // WE 와 반대다. 실물 로더(`0x140276941`–`0x140276967`):
        //
        //     call ReadLengthPrefixedString(stream, &magic, maxLen=8)   ; 0x140276941
        //     cmp  qword [rbp+0xf], 4 ; jbe skip                        ; 0x140276946  len>4 일 때만 검사
        //     call atoi(magic.c_str() + 4)                              ; 0x14027695f
        //     cmp  eax, 0x18 ; jle ok                                   ; 0x140276964  **24 초과면 거부**
        //
        // ① **접두 비교가 없다.** ASCII `PKGV` 는 `wallpaper64.exe` 전역에서 **0건**이다(대비:
        //    `TEXV0005`·`MDLV0023` 은 각각 `0x14048b910`·`0x140492318` 에 리터럴로 있고 `memcmp`
        //    로 비교된다 — 즉 "매직을 안 두는 포맷" 이라는 판정이지 검사 누락이 아니다).
        //    `atoi` 규약상 `"XXXX0023"` 도 통과하고, 길이 ≤4 면 버전 검사 자체를 건너뛴다.
        // ② **상한 24 를 건다.** `PKGV0025` 이상은 `"Cannot open %s, version %i not supported."`
        //    (`0x1404922e8`)로 거부된다.
        //
        // [2026-08-21 보강 — 쓰는 쪽은 다른 바이너리다] "`PKGV` 0건" 은 `wallpaper64.exe` 한정으로만
        // 참이다. `wallpaperui.exe`(12,742,640 B)에는 **2건**이 있고 둘 다 결정적이다(문서 §2.2b):
        //   · 파일 오프셋 `0xad0898` — `"unpackProject\0…\0-o\0-i\0PKGV0024\0packProject\0…"`
        //     = 패커 CLI 옆에 **현행 버전이 단일 상수로 하드코딩**돼 있다.
        //   · 파일 오프셋 `0xab2876` — `"checkWallpaperPKGVersions"`. `ui/dist/scripts/scripts.js` 가
        //     `callDeferred("browseWallpaperObject","checkWallpaperPKGVersions", device.mpkgsupport||0, …)`
        //     로 불러 배경마다 **기기 지원 수준과 대조**한다.
        // 곧 4자리가 "버전" 이라는 판정은 도수 곡선(위)만이 아니라 **쓰는 쪽 상수 + 대조 API** 로도
        // 독립 확정된다. 그 상수 `0024` 는 코퍼스 최대값과도, 리더 상한 24 와도 정확히 같다.
        //
        // 그럼에도 **코드는 그대로 둔다 — 의도적 이탈이다.** 근거 둘:
        //   · 엄격한 쪽(접두 강제)은 이 리포의 신뢰 경계 정책과 맞고, 잃는 것이 관측되지 않는다.
        //     이 환경의 실물 표본이 0개라 "접두가 다른 pkg" 는 가설일 뿐이다(§1.1: 두 루트
        //     9,078 파일 전건에서 `PKGV` 매직 0건, `.pkg` 확장자 0건).
        //   · 관대한 쪽(상한 없음)은 프레이밍이 버전 불변이라는 위 결론의 직접 귀결이다. 상한을
        //     넣으면 미래 버전에서 **파싱 가능한 파일을 거부**하게 되고, 그 대가로 얻는 것은
        //     WE 와 같은 에러 메시지뿐이다.
        // 두 이탈 모두 `ScenePackageWEParityTests` 가 **의도임을 못 박아** 둔다(우연한 회귀와 구분).
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
            // [2026-08-21 — §4.2·§7.5] **`size <= 0` 엔트리는 "없음"과 같다.** VFS 조회
            // (`0x140273f50`)는 해시 히트 직후 `cmp dword [rbx+0x34], 0` / `jle`(`0x14027412a`)
            // 로 크기를 한 번 더 보고, 0 이하면 **못 찾은 것과 같은 자리**(`0x140274161`)로 빠져
            // 마운트된 디렉터리에서 실제 파일을 연다. 즉 0바이트 엔트리는 열림이 아니라 폴백이다.
            //
            // 종전 Waple 은 빈 `Data` 를 **성공**으로 돌려줬고, 그걸 받은
            // `SceneRendererResources.probeAssetData` 가 `.data(빈 것)` 으로 보고 공유
            // (base-assets) 폴백을 건너뛰었다 — WE 라면 공유 자산으로 채워질 자리가 0바이트로
            // 굳는다. 여기서 `nil` 을 내면 그 폴백 사슬이 그대로 이어진다.
            //
            // **`.directory` 백엔드에는 적용하지 않는다.** 폴더 마운트(`0x1402764d0`)는 엔트리
            // 표를 만들지 않고 파일을 바로 열므로, 디스크의 진짜 0바이트 파일은 WE 에서도
            // "0바이트로 열림" 이다. 아래 `.directory` 분기가 그대로 읽어 빈 `Data` 를 낸다.
            //
            // 도달: 0바이트 엔트리를 가진 pkg 는 관측하지 못했다(이 환경 실물 표본 0개). 즉
            // 이 가드는 무회귀이고, 근거는 코퍼스가 아니라 로더 코드다.
            guard e.size > 0 else { return nil }
            let start = blob.startIndex + blobBase + e.offset
            return blob.subdata(in: start ..< start + e.size)
        case .directory(let root):
            // e.name 은 아래 `fromDirectory` 가 루트 상대 경로로만 만든다(심볼릭 링크·상위 경로 배제).
            var url = root
            for component in e.name.split(separator: "/") { url.appendPathComponent(String(component)) }
            return try? Data(contentsOf: url)
        }
    }

    /// C `tolower` 와 **바이트별로 같은** 소문자화. UTF-8 연속 바이트(0x80 이상)는 손대지 않는다.
    ///
    /// WE 는 엔트리 이름을 적재할 때(`0x140276ac0`–`0x140276ad6`)도, 조회 키를 정규화할 때
    /// (`0x140274000`–`0x140274015`)도 `movsx ecx, byte [..]` → CRT `tolower`(`0x1402bfb1c`) 를
    /// 바이트마다 돈다. 그 CRT 함수의 빠른 경로는 `lea eax,[rcx-0x41] ; cmp eax,0x19 ; ja` —
    /// 곧 **`'A'..'Z'` 만 +0x20** 이고, 부호확장된 0x80 이상 바이트는 무부호 비교에서 탈락해
    /// 원본 그대로 다시 쓰인다. 확장자 소문자화(`0x140054262`–`0x140054276`)도 같은 루프다.
    ///
    /// Swift `.lowercased()` 는 **유니코드 전체 케이스 매핑**이라 키릴 `И`·그리스 `Σ`·터키
    /// `İ`(→ 2 스칼라로 늘어남)까지 접는다. 그러면 WE 에서 **서로 다른** 두 엔트리가 Waple
    /// 에서만 같은 정규화 키로 충돌해 먼저 온 것이 이긴다(`init` 의 `normalizedIndex`).
    ///
    /// 도달 실측 ①(2026-08-21): 두 루트 9,078 파일의 경로 컴포넌트 **3,374 종에 비-ASCII 0건**,
    /// ASCII 폴딩과 유니코드 폴딩이 갈리는 이름 **0건**.
    ///
    /// 도달 실측 ②(2026-08-21 추가 — 표본이 훨씬 크다). 종전 이 자리는 워크샵 쪽 근거로
    /// `spec/corpus/workshop-shaders.json`(셰이더만 뽑은 부분집합)을 대며 "갈리는 것 0건" 이라
    /// 적었다. **전수로 다시 재면 0건이 아니다.** `Waple-wallpaper-source/corpus_scan/`
    /// `entry-name-frequency.tsv` 는 같은 워크샵 루트 446 폴더의 `scene.pkg` 161개에서 나온
    /// **엔트리 경로 11,338 종 / 출현 19,777건** 전수다. 그 위에서:
    ///   · 대문자 보유 **3,061 종**(27.0%) — 정규화 색인이 실제로 일하는 양이 이만큼이다
    ///   · 비-ASCII **2,422 종**(21.4%, 한자·키릴)
    ///   · **ASCII 폴딩 ≠ 유니코드 폴딩: 114 종**(전부 키릴 대문자. 예 `materials/Спойлер Ч.tex`)
    ///   · 그런데 **폴딩 충돌군은 양쪽 다 14군이고, 유니코드에서만 생기는 충돌은 0군**이다
    /// 즉 이 정정이 무회귀인 진짜 이유는 "갈리는 이름이 없어서" 가 아니라 **갈리는 114종이
    /// 아무와도 충돌하지 않아서**다(조회 키와 저장 키를 같은 함수로 접으므로 히트는 그대로 난다).
    /// 그러니 근거는 여전히 코퍼스가 아니라 로더 코드이고, 코퍼스는 "잃는 것이 없다" 만 말한다.
    ///
    /// 같은 전수에서 나온 경로 위생 도수(`docs/re/package-format.md` §1.1c): 역슬래시 **0건** · `..` 성분 **0건** ·
    /// 절대경로 **0건** · 선행 `./`·`//`·양끝 공백 **0건** · 최대 깊이 6 · 최대 이름 266 B.
    ///
    /// - Note: 역슬래시→슬래시 치환은 WE 에 **없다**. 다만 이건 정확 일치(`entryByName`)가
    ///   먼저 이긴 뒤의 폴백 색인이라 히트만 늘리고 뺏지 않으므로 그대로 둔다(§7.3).
    static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 &+ 0x20 : $0 }, as: UTF8.self)
    }

    private static func normalizedLookupKey(_ name: String) -> String {
        asciiLowercased(name.replacingOccurrences(of: "\\", with: "/"))
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

// MARK: - 마운트 대상 결정 (WE 파리티)

/// 씬을 **무엇으로 마운트할지**의 결정. `ScenePackage.resolveMountSource(...)` 의 결과다.
public enum SceneMountSource: Equatable {
    /// 이 `.pkg` 컨테이너를 연다(`ScenePackage.parse`).
    case package(URL)
    /// 프로젝트 폴더를 통째로 마운트한다(`ScenePackage.fromDirectory`).
    case directory
}

extension ScenePackage {
    /// 종전(2026-08-21 이전) Waple 의 마운트 선택자 — `scene.pkg`/`gifscene.pkg` **이름 두 개**를
    /// 하드코딩해 찾는다. 이제는 `resolveMountSource` 의 **마지막 폴백**으로만 쓴다(§7.1 ③).
    ///
    /// 왜 지우지 않는가: `project.json` 의 `file` 이 없거나(361건 중 0건) 경로 검사에 걸려
    /// 정규화가 nil 을 내는 경우, 결정 근거가 아예 사라진다. 그때 종전 동작으로 떨어지는 편이
    /// "적용 실패" 보다 낫다. WE 에는 이 폴백이 **없다**(WE 는 `file` 이 없으면 프리셋 병합
    /// 경로로 가고, 거기서도 못 정하면 실패한다 — `0x14011d9e1`).
    public static func legacyPackageURL(in folder: URL) -> URL? {
        let fm = FileManager.default
        for name in ["scene.pkg", "gifscene.pkg"] {
            let u = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        // 대소문자 보존 파일시스템(리눅스·case-sensitive APFS)에서 `Scene.pkg` 같은 표기를 살린다.
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for expected in ["scene.pkg", "gifscene.pkg"] {
                if let actual = names.first(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
                    return folder.appendingPathComponent(actual)
                }
            }
        }
        return nil
    }

    /// **`project.json` 의 `file` 이 마운트 대상을 정한다** — `.pkg` 의 존재가 아니라(§6·§7.1).
    ///
    /// 종전 Waple 은 폴더에 `scene.pkg`/`gifscene.pkg` 가 **있으면 무조건** 그것을 열었다.
    /// WE 규칙과 세 군데에서 갈렸고, 그중 하나는 관측 가능한 적용 실패였다:
    ///
    /// | 상황 | WE | 종전 Waple |
    /// | --- | --- | --- |
    /// | `file:"scene.json"` + 잔존 `scene.pkg` | `scene.json`(폴더) | `scene.pkg` → **다른 씬** |
    /// | `file:"techno.json"` 부재 + `techno.pkg` 존재 | `techno.pkg` | 폴더 → `.noScene` → **적용 실패** |
    /// | `file:"scene.pkg"` 부재 + `scene.json` 존재 | 실패 | `scene.json` 으로 성공(더 관대) |
    ///
    /// 실물 절차는 두 함수에 걸쳐 있다.
    ///
    /// **① `project.json` 리더 `0x14011d7d0`** 가 `file` 을 폴더 기준 절대경로로 정규화해
    /// 되써 넣고(`0x14011d9e1`·`0x14011deb4`), 그 뒤 `.pkg` 재작성을 시도한다
    /// (`0x14011e330`–`0x14011e3f9`). 게이트가 **넷이고 순서가 있다**:
    ///
    ///     cmp  dword [rdi+4], 1        ; ① 유도 타입이 Scene 일 때만          0x14011e330
    ///     jne  skip
    ///     call 0x14011e880             ; ② json["dependency"] 가 string(tag 4) 이면 skip
    ///     test al, al ; jne skip       ;    (0x14011e894 find + 0x14011e8c5 cmp [rax+8],4)
    ///     call 0x140018f30             ; ③ is_regular_file(<file 절대경로>) 면 skip  0x14011e34d
    ///     test al, al ; jne skip
    ///     ... replace_extension("pkg") ; 0x14011e368 "pkg"(점 없음) + 0x140060d90
    ///     call 0x140018f30             ; ④ 바꾼 경로가 실제 파일일 때만       0x14011e3ae
    ///     je   skip
    ///     ... json["file"] = <그 .pkg 절대경로>                              0x14011e3f2
    ///
    /// **② 마운트 디스패처 `0x14010df40`** 는 그렇게 확정된 `file` 을 `std::filesystem::path` 로
    /// 만들어(`0x14010dfbc`) **확장자만** 보고 갈린다. 확장자는 `0x140053f80` 이 뽑아 바이트별
    /// ASCII `tolower`(`0x140054262`–`0x140054276`)로 접은 것이다:
    ///
    /// | 순서 | 조건 | 동작 | VA |
    /// | --- | --- | --- | --- |
    /// | 1 | `.gif` | 플래그 `0x20` 세우고 GIF 씬 경로로 이탈 | `0x14010e0ee`–`0x14010e12c` |
    /// | 2 | `.pkg` | `0x140276700`(패키지 적재) | `0x14010e14d`–`0x14010e18a` |
    /// | 3 | 그 외 | `0x1402764d0`(**부모 폴더**를 루트로 마운트) | `0x14010e1d1`–`0x14010e20c` |
    ///
    /// **어느 분기도 다른 분기를 되짚지 않는다** — 2번에서 실패하면 에러 코드 5 로 끝난다.
    ///
    /// 이 함수는 ①의 ②③④와 ②의 2·3번을 그대로 옮긴다. ①의 게이트 ①(타입 Scene)은 호출자가
    /// 이미 만족한다 — 씬 렌더러 마운트 경로에서만 부른다.
    ///
    /// **의도적 이탈 3건**(전부 이 코퍼스 도달 0건):
    ///   · `.gif` 전용 분기가 없다. Waple 에는 GIF 씬 경로 자체가 없으므로 폴더 마운트로 떨어진다
    ///     (종전과 같다). 설치본+동봉 361건 중 `file` 이 `.gif` 인 것은 0건이다.
    ///   · 3번 분기에서 **부모 폴더가 아니라 프로젝트 폴더**를 마운트한다. `file` 에 하위 디렉터리가
    ///     끼면(`"sub/scene.json"`) WE 는 `sub/` 만, Waple 은 그 상위까지 본다 — Waple 이 상위집합이라
    ///     씬 문서 이름(`sub/scene.json`)도 그대로 풀린다. 361건 전건이 디렉터리 성분 없는 파일명이다.
    ///   · 마지막 폴백 `legacyPackageURL` 은 WE 에 없다(위 주석).
    ///
    /// **[미해결]** `file` 이 명시적으로 `*.pkg` 일 때 WE 가 여는 **씬 문서 이름**은 `filename()`
    /// 이 아니라 `stem() + ".json"` 이다(`0x14010e22a` `path::stem` → `0x14010e253`
    /// `std::string::append(".json", 5)`). 곧 `file:"techno.pkg"` 면 안에서 `techno.json` 을 찾는다.
    /// Waple 은 `SceneDocument.parse(sceneFileName:)` 에 `project.fileName`(= `"techno.pkg"`)을
    /// 넘기고 `scene.json`/`gifscene.json` 으로만 폴백하므로 그 한 경우에 `.noScene` 이 된다.
    /// 고치지 않은 이유: `check_scene_mount_parity.py` 가 `sceneFileName: project.fileName` 리터럴을
    /// **고정 불변식으로 핀**해 두었고(그 게이트는 이 과제 소유가 아니다), 도달이 0건이다 —
    /// 설치본·동봉 361건 중 `file` 이 `.pkg` 인 것은 0건이고, ①의 재작성 경로는 `project.fileName`
    /// 이 원문 `.json` 그대로라 영향이 없다.
    ///
    /// **[2026-08-21 도달 보강 — 워크샵 쪽도 0이다]** 종전 근거는 설치본·동봉뿐이라 "워크샵에서는
    /// 다를 수 있다" 가 열려 있었다. `Waple-wallpaper-source/corpus_scan/entry-name-frequency.tsv`
    /// (워크샵 446 폴더 · `scene.pkg` 161개 · 엔트리 경로 11,338 종 전수)에서 **디렉터리 성분이 없는
    /// 경로는 딱 하나이고 그것이 `scene.json`, 도수 161** 이다 — 곧 **161개 pkg 전건**이 루트에
    /// `scene.json` 을 갖고, 다른 이름의 루트 씬 문서도 하위 디렉터리 씬 문서도 **0건**이다.
    /// 컨테이너 이름도 전건 `scene.pkg` 다(예외 `gifscene.pkg` 1건). 즉 `stem + ".json"` 규칙과
    /// 하드코딩 `scene.json` 이 워크샵 코퍼스 전건에서 **같은 답**을 낸다.
    ///
    /// - Parameters:
    ///   - folderURL: 프로젝트 폴더.
    ///   - fileName: `project.json` 의 `file`(이미 `WallpaperPathSecurity.normalizedRelativePath`
    ///     를 통과한 상대 경로). nil 이면 곧장 마지막 폴백으로 간다.
    ///   - hasDependency: `project.json` 이 문자열 `dependency` 를 선언했는가 — 게이트 ②.
    ///     WE 는 jsoncpp 타입 태그 4(string)만 본다(`0x14011e8c5`). Waple 의 `WallpaperProject`
    ///     `dependency` 는 경로 검사를 한 번 더 거치므로, 검사에 걸린 문자열은 여기서 `false` 로
    ///     보인다 — 361건 중 `dependency`/`preset` 보유가 **0건**이라 도달하지 않는다.
    public static func resolveMountSource(folderURL: URL,
                                          fileName: String?,
                                          hasDependency: Bool = false) -> SceneMountSource {
        let fm = FileManager.default
        func isRegularFile(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        if let declared = WallpaperPathSecurity.containedFileURL(fileName, root: folderURL) {
            // ③ 선언된 파일이 실재하면 그것이 단독 결정자다 — `.pkg` 를 찾아보지도 않는다.
            if isRegularFile(declared) {
                return asciiLowercased(declared.pathExtension) == "pkg" ? .package(declared) : .directory
            }
            // ②④ 없을 때만, 그리고 `dependency` 가 없을 때만 stem 을 `.pkg` 로 바꿔 본다.
            if !hasDependency {
                let sibling = declared.deletingPathExtension().appendingPathExtension("pkg")
                if isRegularFile(sibling) { return .package(sibling) }
            }
        }
        if let legacy = legacyPackageURL(in: folderURL) { return .package(legacy) }
        return .directory
    }
}
