import Foundation
import WapleCore

public final class LibraryStore {
    private let baseDirectory: URL
    private let indexURL: URL
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var selectedId: String?

    /// 감사 V06 회귀 테스트 계측: save() 호출 횟수(일괄 임포트의 인덱스 재작성 횟수 검증용).
    private(set) var saveCount = 0

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.indexURL = baseDirectory.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("%@", "[Waple] failed to create library directory at \(baseDirectory.path): \(error)")
        }
        load()
        backfillMetadataIfNeeded()
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Waple", isDirectory: true)
    }

    private struct Index: Codable {
        var entries: [LibraryEntry]
        var selectedId: String?
    }

    /// load() 가 손상된 인덱스를 발견하면 true. 다음 save() 는 덮어쓰기 전에 원본을 백업해
    /// 복구 가능한 파일을 무음으로 파괴하는 것을 막는다.
    private var indexCorrupt = false
    /// load() 에서 읽기 자체가 실패(권한·잠금 등 일시적) → 원본이 멀쩡할 수 있어 save() 를 건너뛴다.
    private var indexLoadFailed = false

    private func load() {
        guard let data = readStoreFile(indexURL, what: "library index at \(indexURL.path)",
                                       note: "starting empty", loadFailed: &indexLoadFailed) else { return }
        do {
            let idx = try JSONDecoder().decode(Index.self, from: data)
            entries = idx.entries
            selectedId = idx.selectedId
        } catch {
            NSLog("%@", "[Waple] library index corrupt at \(indexURL.path): \(error) — preserving file, starting empty")
            indexCorrupt = true
        }
    }

    private func save() {
        saveCount += 1
        guard !indexLoadFailed else {
            NSLog("%@", "[Waple] library index save skipped at \(indexURL.path) — earlier read failed transiently, avoiding clobber")
            return
        }
        backupCorruptStoreFile(indexURL, &indexCorrupt)  // 손상 원본을 덮어쓰기 전 1회 백업
        let idx = Index(entries: entries, selectedId: selectedId)
        do {
            let data = try JSONEncoder().encode(idx)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            NSLog("%@", "[Waple] failed to save library index at \(indexURL.path): \(error)")
        }
    }

    @discardableResult
    public func importFolder(_ folderURL: URL) throws -> LibraryEntry {
        try importFolder(folderURL, saving: true)
    }

    /// F582: 일괄 임포트(importFolders)는 폴더마다 save() 하지 않고 마지막에 한 번만 저장한다
    /// (호출마다 전체 인덱스 재작성 O(n²) 방지). 단건 임포트는 종전대로 즉시 저장.
    private func importFolder(_ folderURL: URL, saving: Bool) throws -> LibraryEntry {
        let project = try ProjectJSONParser.parse(folderURL: folderURL)
        let bookmark = try folderURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        // F194: id 충돌 시, 기존 엔트리가 이 폴더와 다른 실경로(=서로 다른 배경이 우연히 같은 id로
        // 귀결 — 예: workshopid 없는 두 배경이 같은 폴더명)를 가리키면 무통지 대체(엔트리 실종 +
        // 북마크 앨리어싱) 대신 접미로 유일화해 둘 다 보존한다. 같은 실경로(재가져오기/갱신)면
        // 종전대로 덮어쓴다(테스트: testReimportUpdatesEntryAndMovesToEnd).
        var id = project.id
        if let existing = entries.first(where: { $0.id == id }) {
            // F586: 기존 엔트리의 북마크 해석이 실패(nil)하면 같은 소스인지 확인할 수 없다 —
            // 충돌 검사를 건너뛰고 무통지 대체하지 말고 유일화한다(보존 우선; 깨진 엔트리는
            // 어차피 해석 불가라 유실은 제한적).
            let sameFolder = resolveFolderURL(for: existing)?.standardizedFileURL
                == folderURL.standardizedFileURL
            if !sameFolder {
                // F581: 유일화 엔트리(id-2, id-3 …)가 이미 이 폴더를 가리키면 같은 소스의
                // 재임포트다 — 새 접미를 붙이지 말고 그 엔트리를 갱신한다(재임포트마다
                // X-3, X-4 … 중복 누적 방지).
                if let sameSource = entries.first(where: {
                    isUniquifiedVariant($0.id, base: id)
                        && resolveFolderURL(for: $0)?.standardizedFileURL == folderURL.standardizedFileURL
                }) {
                    id = sameSource.id
                } else {
                    id = uniqueEntryId(basedOn: id)
                }
            }
        }
        let entry = LibraryEntry(
            id: id,
            title: project.title,
            typeRaw: project.type.storageString,
            fileName: project.fileName,
            previewName: project.previewName,
            bookmark: bookmark,
            tags: project.tags,
            contentRating: project.contentRating
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        if saving { save() }
        return entry
    }

    /// id 가 base 의 유일화 변형("base-2", "base-3" …)인지(F581 — 재임포트 동일 소스 탐색).
    private func isUniquifiedVariant(_ id: String, base: String) -> Bool {
        guard id.hasPrefix("\(base)-") else { return false }
        return Int(id.dropFirst(base.count + 1)) != nil
    }

    /// 이미 쓰이는 id 와 충돌할 때 접미(-2, -3, …)로 유일화한다.
    private func uniqueEntryId(basedOn base: String) -> String {
        let existingIds = Set(entries.map(\.id))
        var n = 2
        while existingIds.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    @discardableResult
    public func importParent(_ parentURL: URL) -> [LibraryEntry] {
        importFolders(scanImportableFolders(in: parentURL))
    }

    /// importParent 의 1단계 — 가져올 배경 폴더 후보 나열(순수 I/O, entries/index 무접촉).
    /// F582: 백그라운드 큐에서 호출 가능(메인 스레드 동기 I/O 방지 — LibraryViewModel.importParent 가
    /// importQueue 경유로 이 단계를 백그라운드에서 돌린다).
    public func scanImportableFolders(in parentURL: URL) -> [URL] {
        let fm = FileManager.default
        // 사용자가 상위 폴더가 아니라 개별 배경 폴더(project.json 포함)를 직접 고른 경우,
        // 하위 폴더만 순회하면 아무것도 가져오지 못한다. 자신이 배경 폴더면 직접 가져온다.
        if fm.fileExists(atPath: parentURL.appendingPathComponent("project.json").path) {
            return [parentURL]
        }
        let subs = (try? fm.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return subs.filter { sub in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: sub.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// scanImportableFolders 결과를 순서대로 가져온다(스토어 변경 — 메인 스레드 규약).
    /// F582: 일괄 임포트는 폴더마다 저장하지 않고 마지막에 한 번만 save() 한다(호출마다 전체
    /// 인덱스 재작성이 누적되는 O(n²) 방지).
    @discardableResult
    public func importFolders(_ folderURLs: [URL]) -> [LibraryEntry] {
        var imported: [LibraryEntry] = []
        for url in folderURLs {
            if let entry = try? importFolder(url, saving: false) { imported.append(entry) }
        }
        if !imported.isEmpty { save() }
        return imported
    }

    /// zip 을 임시 디렉터리에 풀어, 담긴 모든 배경을 가져온다(작업 4).
    /// 배경 폴더는 관리 위치(base/imported/<폴더명>)로 **이동**해 북마크가 임시 정리 후에도 유효하게 한다
    /// (importFolder 는 폴더를 그 자리에서 북마크만 하므로, 임시 해제물을 지우면 엔트리가 깨진다).
    /// `extract` 주입으로 테스트 가능(기본 ditto). 가져온 엔트리 반환.
    @discardableResult
    public func importZip(_ zipURL: URL,
                          extract: (URL, URL) throws -> Bool = ZipImporter.dittoExtract) -> [LibraryEntry] {
        guard let temp = extractZipToTemp(zipURL, extract: extract) else { return [] }
        return importExtractedZip(temp)
    }

    /// zip 해제 단계(A2 — ditto waitUntilExit 블로킹 구간을 백그라운드 큐로 넘기기 위한 분리).
    /// 스토어 상태(entries/index)를 전혀 건드리지 않으므로 백그라운드 호출이 안전하다.
    /// 성공 시 해제된 임시 디렉터리(호출자가 importExtractedZip 에 넘겨 등록·정리), 실패 시 nil(정리됨).
    public func extractZipToTemp(_ zipURL: URL,
                                 extract: (URL, URL) throws -> Bool = ZipImporter.dittoExtract) -> URL? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("WapleZip-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: true)) != nil,
              (try? extract(zipURL, temp)) == true else {
            try? fm.removeItem(at: temp)
            return nil
        }
        return temp
    }

    /// extractZipToTemp 가 해제해 둔 임시 디렉터리의 배경들을 관리 위치로 옮겨 가져온다.
    /// 스토어 변경(importFolder → entries/save)을 포함하므로 스토어 규약대로 메인 스레드에서 호출.
    /// temp 는 성공/실패 무관하게 항상 정리된다.
    @discardableResult
    public func importExtractedZip(_ temp: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temp) }   // 임시 해제 작업공간 정리

        let importedDir = baseDirectory.appendingPathComponent("imported", isDirectory: true)
        try? fm.createDirectory(at: importedDir, withIntermediateDirectories: true)

        var imported: [LibraryEntry] = []
        var usedNames = Set<String>()   // 이번 zip 안의 동명 루트(WE export 관례 `Wallpaper/`) 상호 덮어쓰기 방지
        for root in ZipImporter.findProjectRoots(in: temp, fileManager: fm) {
            // F247: 관리 폴더명은 원본 래퍼 폴더명이 아니라 **project.json 이 선언한 id**
            // (workshopid 우선, 없으면 폴더명 폴백 — ProjectJSONParser.parse 와 동일 규칙)로 정한다.
            // 래퍼명(WE export 관례 `Wallpaper/`)은 비유일이라 그대로 쓰면, 동명이나 서로 다른
            // 배경의 두 번째 zip import 가 첫 배경의 관리 폴더를 조용히 지우고 그 위에 얹혀
            // 첫 엔트리의 북마크가 두 번째 배경 콘텐츠로 앨리어싱된다(무경고 데이터 손실).
            // move 전, 아직 임시 해제 위치에 있는 root 에서 미리 파싱한다.
            let parsed = try? ProjectJSONParser.parse(folderURL: root)
            let hasStableId = parsed?.workshopId != nil   // 전역 유일 식별자 — 있으면 재import 를 확정할 수 있다
            var name = WallpaperPathSecurity.normalizedPathComponent(parsed?.id) ?? root.lastPathComponent
            // F580: project.json 선언 id(workshopid 우선)는 살균되지 않은 원문이라 "../../" 같은
            // 경로 탈출 벡터다 — 그대로 관리 폴더명에 쓰면 dest 가 imported/ 밖을 가리켜
            // removeItem/moveItem 이 임의 디렉터리를 파괴·교체한다. 단일 컴포넌트로 살균하고,
            // 불가하면 원본 루트 폴더명으로 폴백한다.
            if usedNames.contains(name) {
                name = uniqueManagedName(name, usedNames: usedNames, in: importedDir, fm: fm)
            }
            // 콜 간(이전 import) 충돌: workshopid 로 정체성이 확정된 경우만 "같은 배경 재가져오기"로
            // 보고 덮어쓴다. 확정할 수 없는데(workshopid 없음) 관리 폴더가 이미 있으면 지우지 않고
            // 유일화한다 — 폴더명 폴백만으로는 서로 다른 배경을 구분할 수 없기 때문(무통지 데이터 손실 방지).
            if fm.fileExists(atPath: importedDir.appendingPathComponent(name).path), !hasStableId {
                name = uniqueManagedName(name, usedNames: usedNames, in: importedDir, fm: fm)
            }
            usedNames.insert(name)
            let dest = importedDir.appendingPathComponent(name, isDirectory: true)
            // F584: 실패 경로를 try? 로 삼키면 어느 배경이 왜 빠졌는지 무통지다 — 각 단계 실패를
            // 로그로 남기고, 이동 후 등록 실패 시 엔트리 없는 고아 관리 폴더를 정리한다.
            if fm.fileExists(atPath: dest.path) {
                do {
                    try fm.removeItem(at: dest)
                } catch {
                    NSLog("%@", "[Waple] failed to replace managed folder \(dest.path): \(error) — skipping")
                    continue
                }
            }
            do {
                try fm.moveItem(at: root, to: dest)
            } catch {
                NSLog("%@", "[Waple] failed to move \(root.path) into library: \(error) — skipping")
                continue
            }
            do {
                // 감사 V06: 루트마다 저장(saving: true)하면 인덱스를 N번 재작성하는 O(n²) —
                // F582(importFolders)와 같이 루프 동안은 저장을 미루고 마지막에 1회만 저장한다.
                let entry = try importFolder(dest, saving: false)
                imported.append(entry)
            } catch {
                NSLog("%@", "[Waple] failed to register imported folder \(dest.path): \(error) — removing")
                try? fm.removeItem(at: dest)
            }
        }
        if !imported.isEmpty { save() }   // 감사 V06: 일괄 임포트 저장 일괄화(F582 패턴)
        return imported
    }

    private func uniqueManagedName(_ base: String, usedNames: Set<String>, in importedDir: URL, fm: FileManager) -> String {
        var n = 2
        while usedNames.contains("\(base)-\(n)")
                || fm.fileExists(atPath: importedDir.appendingPathComponent("\(base)-\(n)").path) { n += 1 }
        return "\(base)-\(n)"
    }

    public func select(_ id: String) {
        selectedId = id
        save()
    }

    /// 엔트리 제거(파일은 건드리지 않음 — 인덱스 등록 해제). 선택 중이었으면 선택 해제.
    /// 스토어 간 orphan 정리는 호출자(LibraryViewModel.remove)가 오케스트레이션한다.
    public func remove(id: String) {
        entries.removeAll { $0.id == id }
        if selectedId == id { selectedId = nil }
        save()
    }

    public func resolveFolderURL(for entry: LibraryEntry) -> URL? {
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [], relativeTo: nil, bookmarkDataIsStale: &stale
            )
        } catch {
            NSLog("%@", "[Waple] failed to resolve bookmark for entry \(entry.id) (\(entry.title)): \(error)")
            return nil
        }
        // macOS 가 stale 을 표시하면 북마크를 재생성·영속화해야 향후 해석 실패를 막는다.
        if stale, let fresh = try? resolved.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
           let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].bookmark = fresh
            save()
        }
        return resolved
    }

    /// 워크샵 평점 저장(0…1). 미존재 id 는 no-op.
    public func setRating(_ rating: Double, id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].rating = rating
        save()
    }

    /// 구버전 인덱스(tags==nil) 엔트리의 tags/contentRating 을 디스크 project.json 에서 1회 백필.
    /// 폴더 해석 실패 엔트리는 빈 값([])으로 마킹해 매 실행 재시도 I/O 를 막는다.
    func backfillMetadataIfNeeded() {
        var changed = false
        for i in entries.indices where entries[i].tags == nil {
            changed = true
            guard let folder = resolveFolderURL(for: entries[i]),
                  let project = try? ProjectJSONParser.parse(folderURL: folder) else {
                entries[i].tags = []
                continue
            }
            entries[i].tags = project.tags
            entries[i].contentRating = project.contentRating
        }
        if changed { save() }
    }
}
