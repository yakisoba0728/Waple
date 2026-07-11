import Foundation

/// zip 배경 가져오기(작업 4)의 해제(주입 가능)·배경 루트 탐색(순수).
/// import 오케스트레이션(관리 위치 이동 + 북마크)은 `LibraryStore.importZip`.
public enum ZipImporter {
    /// 디렉터리 트리에서 project.json 을 담은 배경 루트들을 찾는다. 루트 발견 시 그 아래로는
    /// 내려가지 않는다(배경 폴더 내부 하위 자산 폴더를 별개 배경으로 오인하지 않도록).
    /// zip 이 wrapper/Wallpaper/project.json 처럼 감싸여 있어도 재귀로 찾아낸다
    /// (importParent 는 1단계만 훑어 이런 중첩을 놓친다 — 그래서 별도 탐색이 필요).
    public static func findProjectRoots(in root: URL, fileManager: FileManager = .default) -> [URL] {
        var roots: [URL] = []
        func walk(_ dir: URL) {
            if fileManager.fileExists(atPath: dir.appendingPathComponent("project.json").path) {
                roots.append(dir)
                return  // 배경 루트 발견 → 하위 탐색 중단
            }
            let subs = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
            for sub in subs {
                // 심링크 미추종(fileExists 는 링크를 따라간다) — 악성 zip 의 절대링크(evil→/)로
                // 전체 디스크를 걷거나, 외부 경로의 project.json 을 배경 루트로 오인해
                // importZip 이 외부 원본 폴더를 imported/ 로 이동(파괴)하는 것 방지.
                let rv = try? sub.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rv?.isSymbolicLink != true, rv?.isDirectory == true else { continue }
                walk(sub)
            }
        }
        walk(root)
        return roots
    }

    /// `/usr/bin/ditto -x -k <zip> <dest>`. 종료코드 0 = 성공.
    /// 기본 구현 — 테스트는 대체 클로저를 주입한다.
    public static func dittoExtract(_ zipURL: URL, _ dest: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zipURL.path, dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
