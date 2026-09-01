import Foundation

/// WE 의 **웹 월페이퍼 호환성 패치**(`assets/zcompat/web/<워크샵ID>.json`) 스키마와 적용 규칙.
///
/// 근거(전부 `bin/webwallpaper64.exe`, imagebase 0x140000000 — **`wallpaper64.exe` 가 아니다**.
/// 웹 월페이퍼 프로세스는 CEF 서브프로세스인 `webwallpaper64.exe` 이고 zcompat 문자열·파서는
/// 이 바이너리에만 있다. 설치본 전수 grep 결과 `zcompat` 보유 파일은
/// `bin/webwallpaper64.exe` 와 `bin/wallpaperui.exe` 둘뿐):
///
///  - 문자열 블록 `.rdata` 파일오프셋 0x119108–0x119186 :
///    `"length before: "`, `"Failed writing compat fix at %S\n"`, `"431960"`,
///    `"assets/zcompat/web"`, `".json"`, `"actions"`, `"file"`, `"replace"`, `"insert"`.
///    → VA 0x14011ab08–0x14011ab86. 스키마 키는 이 넷이 전부다.
///  - 파서 본체는 URL 해석 함수 0x14000bd80–0x14000d978 안에 인라인돼 있고,
///    zcompat 구간은 0x14000c241–0x14000d14f 다.
///
/// ## 복원한 규칙(주소별 근거)
///
/// | 단계 | VA | 동작 |
/// |---|---|---|
/// | 프로젝트 디렉터리 | 0x14000c292–0x14000c2b1 | `dirname(index.html)` 을 보관(= 액션 `file` 의 기준) |
/// | 워크샵 ID | 0x14000c29e | 프로젝트 디렉터리의 **폴더명** |
/// | 앱ID 게이트 | 0x14000c3ec–0x14000c415 | 조부모 폴더명이 길이 6 이고 `"431960"`(WE 의 Steam AppID)일 때만 진행 |
/// | JSON 경로 | 0x14000c468–0x14000c544 | `<실행파일의 조부모>/assets/zcompat/web/<워크샵ID>.json` |
/// | 존재 확인 | 0x14000c5f9 (0x140006a50 = GetFileAttributesExW 래퍼) | 없으면 그대로 반환 |
/// | `actions` | 0x14000c751–0x14000c76f | jsoncpp 태그 **6(array)** 이 아니면 통째 무시 |
/// | 항목 검증 | 0x14000c826–0x14000c88c | `file`·`replace`·`insert` 셋 다 태그 **4(string)** 이어야 하고, 하나라도 아니면 그 항목만 건너뛰고 **다음 항목으로 계속**(0x14000d0ca 가 이터레이터++ 후 0x14000c804 루프 헤드로 복귀) |
/// | 대상 경로 | 0x14000c907–0x14000c925 | `프로젝트디렉터리 + file` |
/// | 내용 비었으면 | 0x14000c992 | 아무것도 안 하고 다음 항목 |
/// | 치환 | 0x14000ca90–0x14000cc51 | `find(replace, pos)` → `replace(pos, replace.len, insert)` → `pos += insert.len` 의 **전체 치환 루프** |
/// | 기록 | 0x14000cec7–0x14000cf4c | 파일을 **디스크에 덮어쓴다**. 실패 시 `"Failed writing compat fix at %S\n"`(0x14000cf7e) |
///
/// ## Waple 의 의도적 분기 두 가지
///
/// 1. **디스크를 고치지 않는다.** WE 는 사용자의 워크샵 파일을 실제로 덮어쓴다(0x14000cee4 에서
///    출력 스트림을 열고 0x14000cf3b 로 쓴다). Waple 은 `WallpaperSchemeHandler` 가 파일을
///    **서빙할 때 메모리에서** 치환한다. 결과 바이트는 동일하고, 남의 파일을 건드리지 않으며,
///    WE 가 필요로 한 멱등성 논증(패치 후에는 `replace` 가 더 이상 매치되지 않는다)에 기대지
///    않아도 된다.
/// 2. **`replace` 가 빈 문자열이면 그 항목을 버린다.** WE 의 루프는 여기서 **멈추지 않는다** —
///    `std::string::find(ptr, pos, 0)` 는 `pos <= size` 이면 `pos` 를 돌려주므로, `insert` 도
///    비었으면 `pos` 가 영원히 제자리다(무한 루프). 동봉 5건에는 없는 형태지만 JSON 은 사용자
///    파일이라 방어한다.
///
/// 앱ID 게이트("431960")는 Waple 에서 재현하지 않는다 — 그건 **워크샵 설치본인지**를 가르는
/// 윈도우 경로 관습이고, Waple 은 라이브러리 폴더 구조가 다르다. 대신 프로젝트 폴더명
/// (`WallpaperProject.id` = 워크샵 ID)을 그대로 키로 쓴다(WE 도 같은 값을 쓴다).
public enum WebCompatPatch {

    /// zcompat JSON 한 항목. WE 의 키 이름을 그대로 쓴다 — `replace` 가 **찾을 문자열**,
    /// `insert` 가 **넣을 문자열**이다(이름이 직관과 반대라 헷갈리기 쉽다: 0x14000c8b3 이
    /// `replace` 값을 needle 슬롯 `[rbp+0x60]` 에, 0x14000c902 가 `insert` 값을 replacement
    /// 슬롯 `[rbp+0x170]` 에 넣고, 0x14000cab0 의 find 가 needle 로 `[rbp-0x18]`(=`replace`
    /// 사본)을 받는다).
    public struct Action: Equatable, Sendable {
        /// 프로젝트 디렉터리 기준 상대 경로. 동봉 5건은 전부 `/` 구분자.
        public let file: String
        /// 찾을 바이트열.
        public let replace: String
        /// 대신 넣을 바이트열.
        public let insert: String

        public init(file: String, replace: String, insert: String) {
            self.file = file
            self.replace = replace
            self.insert = insert
        }
    }

    /// 한 워크샵 항목의 패치 전표.
    public struct PatchSet: Equatable, Sendable {
        public let actions: [Action]
        public var isEmpty: Bool { actions.isEmpty }
        public static let empty = PatchSet(actions: [])

        public init(actions: [Action]) { self.actions = actions }

        /// 요청 상대 경로에 적용될 액션들(선언 순서 유지 — WE 도 배열 순서대로 돈다).
        public func actions(forRelativePath path: String) -> [Action] {
            let key = WebCompatPatch.normalizedRelativePath(path)
            guard !key.isEmpty else { return [] }
            return actions.filter { WebCompatPatch.normalizedRelativePath($0.file) == key }
        }

        /// 이 전표가 언급하는 파일이 하나라도 있는지(스킴 핸들러의 빠른 게이트).
        public var referencedFiles: Set<String> {
            Set(actions.map { WebCompatPatch.normalizedRelativePath($0.file) }.filter { !$0.isEmpty })
        }
    }

    // MARK: - 스키마 파스

    /// `{"actions":[{"file","replace","insert"}, ...]}` 를 WE 의 관용도로 읽는다.
    ///
    /// WE 판정 그대로:
    ///  - 최상위가 오브젝트가 아니거나 `actions` 가 배열이 아니면 → 빈 전표(0x14000c76f).
    ///  - 항목이 오브젝트가 아니거나 세 키 중 하나라도 문자열이 아니면 → **그 항목만** 버린다
    ///    (0x14000c844·0x14000c868·0x14000c88c 가 전부 0x14000d0ca = "다음 항목" 으로 간다).
    ///  - jsoncpp 의 태그 4 는 **문자열만**이다. 숫자·불리언은 문자열로 강제되지 않으므로
    ///    여기서도 `as? String` 만 받는다.
    public static func parse(_ data: Data) -> PatchSet {
        guard let root = AssetJSON.dictionary(data) else { return .empty }
        guard let raw = root["actions"] as? [Any] else { return .empty }
        var out: [Action] = []
        out.reserveCapacity(raw.count)
        for element in raw {
            guard let entry = element as? [String: Any],
                  let file = entry["file"] as? String,
                  let replace = entry["replace"] as? String,
                  let insert = entry["insert"] as? String else { continue }
            // Waple 분기 2 — 빈 needle 은 WE 에서 무한 루프다. 위 타입 주석 참조.
            if replace.isEmpty { continue }
            out.append(Action(file: file, replace: replace, insert: insert))
        }
        return PatchSet(actions: out)
    }

    /// 검색 루트들에서 `zcompat/web/<projectID>.json` 을 찾아 파스한다(첫 히트 우선).
    ///
    /// WE 는 실행 파일 위치에서 `assets/zcompat/web` 을 만들지만(0x14000c47c), Waple 의
    /// `BaseAssetsSettings.searchRoots` 는 이미 `assets` 에 해당하는 디렉터리들을 준다
    /// (사용자 지정 WE 설치본 → 앱 동봉 `WEAssets`). 그래서 `assets/` 접두는 붙이지 않는다.
    public static func load(projectID: String, in roots: [URL]) -> PatchSet {
        guard let name = sanitizedProjectID(projectID) else { return .empty }
        for root in roots {
            let url = root.appendingPathComponent("zcompat/web/\(name).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let set = parse(data)
            if !set.isEmpty { return set }
        }
        return .empty
    }

    /// 프로젝트 ID 를 파일명 조각으로 쓰기 전 검사. WE 는 이 값을 **디렉터리 이름**에서
    /// 뽑으므로 구분자가 섞일 수 없지만, Waple 의 `WallpaperProject.id` 는 상위 계층이 채우는
    /// 문자열이라 경로 탈출 가능성을 여기서 끊는다(`..`, `/`, `\`, 널, 빈 문자열).
    static func sanitizedProjectID(_ id: String) -> String? {
        guard !id.isEmpty, id != ".", id != ".." else { return nil }
        guard !id.contains("/"), !id.contains("\\"), !id.contains("\0") else { return nil }
        return id
    }

    // MARK: - 경로 정규화

    /// 액션의 `file` 과 요청 경로를 같은 형태로 만든다.
    ///
    ///  - `\` → `/` : WE 는 윈도우 경로 결합이라 두 구분자가 같은 뜻이다(0x140006700 등
    ///    모든 경로 스캐너가 `0x2f`(`/`)와 `0x5c`(`\`)를 동등하게 본다).
    ///  - 선행 `/`·`./` 제거, 중복 `/` 접기.
    ///  - **소문자화** : WE 는 문자열 비교가 아니라 그 경로로 파일을 열고, 윈도우 파일시스템은
    ///    대소문자를 구분하지 않는다. 즉 실제 동작이 대소문자 무시다.
    ///
    ///    **[정정 r4-21] "동봉 5건은 전부 소문자" 는 거짓이다.** 동봉 코퍼스
    ///    (`Sources/WapleRender/Resources/WEAssets/zcompat/web`, JSON 5개 / 액션 17개)를 전수
    ///    파스하면 **4개 파일**의 `file` 이 `index_files/index.min.js.Download` 로 대문자 `D` 를
    ///    포함한다(780658164 · 780662613 · 780675904 · 854685299). 즉 소문자화는 "달라지는 항목이
    ///    없는" 무해한 정규화가 아니라, 그 4건을 **실제로 바꿔서** 요청 경로와 맞춰 주는 자리다.
    ///    결론(소문자화가 옳다)은 그대로지만 근거를 뒤집어 적어야 한다 — 소문자화를 빼면
    ///    동봉 자산의 다수가 매치에 실패한다.
    static func normalizedRelativePath(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == "." { continue }
            out.append(part)
        }
        return out.joined(separator: "/").lowercased()
    }

    // MARK: - 적용

    /// 액션 하나를 바이트열에 **전체 치환**으로 적용한다(WE 0x14000ca90 루프와 같은 의미론).
    ///
    /// 진행 위치를 `insert` 길이만큼 밀기 때문에(0x14000cb28 `add r14, r15`) 넣은 텍스트가
    /// `replace` 를 포함해도 다시 매치되지 않는다 — 동봉 5건 중 4건
    /// (`u(t,e){t.texImage2D` → `u(t,e){if(e!=null)t.texImage2D`)이 정확히 그 형태다.
    public static func applied(_ data: Data, action: Action) -> Data {
        let needle = Array(action.replace.utf8)
        guard !needle.isEmpty else { return data }
        let replacement = Array(action.insert.utf8)
        var bytes = Array(data)
        var pos = 0
        while let hit = firstIndex(of: needle, in: bytes, from: pos) {
            bytes.replaceSubrange(hit..<(hit + needle.count), with: replacement)
            pos = hit + replacement.count
        }
        return Data(bytes)
    }

    /// 여러 액션을 선언 순서대로 누적 적용.
    public static func applied(_ data: Data, actions: [Action]) -> Data {
        actions.reduce(data) { applied($0, action: $1) }
    }

    /// 텍스트 편의 오버로드(테스트·문서용). UTF-8 왕복이므로 바이트 경로와 결과가 같다.
    public static func applied(_ text: String, actions: [Action]) -> String {
        String(decoding: applied(Data(text.utf8), actions: actions), as: UTF8.self)
    }

    /// `haystack[from...]` 에서 `needle` 의 첫 위치. 없으면 nil.
    /// 단순 스캔이다 — needle 이 짧고 파일도 수백 KB 라 충분하다.
    /// **[정정 r4-21] 동봉 최대 길이는 63 이 아니라 68 바이트**다(`784979889.json` 의
    /// `renderer = new THREE.WebGLRenderer({alpha: true, antialias: ` — 동봉 코퍼스 17액션 전수).
    /// 상한을 쓰는 코드는 없고 이 문장 하나가 근거였으므로 값만 바로잡는다.
    static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        let last = haystack.count - needle.count
        guard from <= last else { return nil }
        let head = needle[0]
        var i = from
        while i <= last {
            if haystack[i] == head {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
