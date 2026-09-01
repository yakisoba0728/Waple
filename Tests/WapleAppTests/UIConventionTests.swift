import XCTest

/// UI 규약 오라클 — 소스 텍스트 스캔.
///
/// ## 왜 이런 테스트가 필요한가
///
/// `WapleAppTests` 292개 중 **`import SwiftUI` 하는 파일이 하나도 없다**(2026-08-17 실측).
/// SwiftUI 뷰를 인스턴스화하는 테스트가 0개라, 레이아웃·색·모션·접근성을 **어떻게 바꾸든
/// 292개가 전부 초록으로 남는다.** 이 스위트가 실제로 잡는 UI 회귀는 카피(문구) 변경뿐이다.
///
/// 뷰 스냅샷 테스트를 도입하자는 게 아니다 — 무거운 데다 이 저장소의 골든 정책과도 어긋난다.
/// 대신 `LocalizationCoverageTests` 가 이미 쓰는 방식(소스 전문 정규식 스캔)으로,
/// **규약 위반을 기계가 판정할 수 있는 만큼만** 잡는다.
///
/// ## 허용 목록은 줄어들기만 한다
///
/// 각 규약에는 현재 위반 파일의 허용 목록이 붙어 있다. 2026-08-17 UI 개편에서 그 파일을
/// 담당하는 단위가 **자기 파일을 목록에서 지우면서** 마이그레이션한다.
/// 목록에 있는데 더는 위반하지 않는 파일이 남아 있으면 그것도 실패다 — 목록이 조용히
/// 썩어서 새 위반을 덮어주는 걸 막는다. **목록에 파일을 추가하지 마라.**
///
/// 규약 본문: `docs/ui-redesign-2026-08-17.md` §4(접근성) · 부록 A(토큰 적용 지도).
final class UIConventionTests: XCTestCase {

    /// 리포 루트 — 테스트 바이너리는 .build 안이라 소스 파일 위치에서 거슬러 올라간다.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 화면 코드 전부. `DesignSystem/` 은 제외한다 — 토큰을 **정의**하는 곳이라
    /// 원시 애니메이션·색이 있는 게 정상이고, 문서 주석의 예제 코드도 들어 있다.
    private static func uiSources() throws -> [(name: String, text: String)] {
        let root = repoRoot.appendingPathComponent("Sources/Waple")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(name: String, text: String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relative.hasPrefix("DesignSystem/") else { continue }
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// 위반 판정 + 허용 목록 정합을 한 번에. `pending` 이 줄어드는 방향으로만 바뀐다.
    private func assertConvention(violates: (String) -> Bool,
                                  pending: Set<String>,
                                  rule: String,
                                  fix: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let sources = try Self.uiSources()
        XCTAssertGreaterThan(sources.count, 20, "소스 수집이 실패했다 — 경로 규약이 바뀌었나?",
                             file: file, line: line)
        let violators = Set(sources.filter { violates($0.text) }.map(\.name))
        let unexpected = violators.subtracting(pending).sorted()
        XCTAssertTrue(unexpected.isEmpty,
                      "\(rule)\n새 위반 \(unexpected.count)건:\n"
                        + unexpected.map { "  \($0)" }.joined(separator: "\n")
                        + "\n\(fix)",
                      file: file, line: line)
        let stale = pending.subtracting(violators).sorted()
        XCTAssertTrue(stale.isEmpty,
                      "\(rule)\n허용 목록이 스테일하다 — 아래 파일은 더 이상 위반하지 않는다.\n"
                        + "목록에서 지워라(안 지우면 그 파일의 다음 위반을 조용히 덮어준다):\n"
                        + stale.map { "  \($0)" }.joined(separator: "\n"),
                      file: file, line: line)
    }

    // MARK: - 모션

    /// 화면 코드는 애니메이션 곡선을 직접 만들지 않는다.
    ///
    /// `Motion` 토큰이 `reduceMotion` 분기를 안에 가두고 있으므로, 화면이 `.spring(...)` 을
    /// 직접 쓰는 순간 그 자리만 "동작 줄이기" 설정을 무시한다. 실측(2026-08-17): 소스 전체에
    /// `reduceMotion`·`accessibilityReduceTransparency`·`differentiateWithoutColor` 참조가
    /// **0건**이고 애니메이션 진입점 6개가 무조건 실행된다.
    func testAnimationsComeFromMotionTokens() throws {
        // 2026-08-17 기준 위반 4파일이 **전부** 마이그레이션을 끝냈다 —
        // MainWindowView·StatusBanner(Unit A, 셸 개편) · WallpaperGridView(Unit B,
        // 라이브러리 개편) · RemoteTile(Unit C, 창작마당 개편)이 각자 호버 리프트
        // 모디파이어와 Motion 토큰으로 옮기며 지웠다.
        //
        // 목록이 비었다고 이 테스트를 지우지 마라 — 이제부터는 **새 위반을 막는**
        // 역할이다. 생 `.animation(.spring(…))` 을 새로 쓰면 여기서 빨개진다.
        let pending: Set<String> = [
        ]
        try assertConvention(
            violates: { text in
                text.contains(".spring(") || text.contains(".easeInOut(")
                    || text.contains(".linear(") || text.contains("withAnimation(.")
            },
            pending: pending,
            rule: "모션은 Motion 토큰으로만 만든다(reduceMotion 분기가 토큰 안에 있다).",
            fix: "→ Motion.hoverLift / Motion.reveal / Motion.fade / Motion.revealTransition(edge:) "
                + "또는 View.tileLift(_:) 를 쓰고, 이 테스트의 pending 에서 자기 파일을 지워라."
        )
    }

    // MARK: - 접근성

    /// 우클릭 메뉴에만 있는 기능은 보조기술로 도달할 수 없다.
    ///
    /// `contextMenu` 는 마우스 우클릭 전용이다. VoiceOver 사용자와 키보드 전용 사용자에게
    /// 그 안의 항목은 존재하지 않는 것과 같다. 실측(2026-08-17): 라이브러리 타일의 우클릭
    /// 메뉴 11개 중 5개(선택(속성 보기)·적용 + 조작 창 열기·폴더로 이동·Finder에서 보기·
    /// 폴더 삭제)는 다른 어떤 경로로도 도달할 수 없다.
    /// **[정정 2026-08-30] 종전 판정은 `파일 단위`라 규약이 말하는 1:1 을 지키지 못했다.**
    ///
    /// 종전 술어: `text.contains(".contextMenu") && !text.contains(".accessibilityAction(")`.
    /// 즉 **파일 어딘가에** `accessibilityAction` 이 한 번만 있으면 그 파일의 우클릭 메뉴 항목
    /// **전부가 면제**됐다. `.contextMenu` 를 가진 두 파일(WallpaperGridView·Shell/SidebarView)이
    /// 둘 다 이미 `accessibilityAction` 을 갖고 있어서, 사실상 **영구 면제**였다.
    ///
    /// 실측으로 재현했다(2026-08-30): `WallpaperGridView.contextMenu(for:supported:)` 에
    /// 접근성 짝이 없는 파괴적 항목
    /// `Button("폴더 삭제(항목은 유지)", role: .destructive)` 를 넣고 `swift test --filter UIConvention`
    /// → **4건 전부 통과**. 우클릭으로만 닿는 파괴적 동작이 초록으로 실린다 — 이 테스트가 막으려던
    /// 바로 그 §4.3 위반이다. (이미 번역된 라벨을 쓰면 `LocalizationCoverageTests` 도 안 걸린다.)
    ///
    /// 그래서 **항목 단위**로 좁힌다. 메뉴 항목의 라벨 리터럴을 뽑아, 같은 문구의
    /// `accessibilityAction(named:)` 이 있는지 본다. 중첩 `Menu` 의 자식은 세지 않는다 —
    /// §4.3:440-442 가 중첩 메뉴는 **대표 액션 하나**로 내라고 규정하므로(accessibilityAction 은
    /// 중첩되지 않는다), 자식까지 세면 지금의 올바른 코드가 오탐으로 빨개진다.
    func testContextMenusHaveAccessibilityCounterpart() throws {
        let sources = try Self.uiSources()
        XCTAssertGreaterThan(sources.count, 20, "소스 수집이 실패했다 — 경로 규약이 바뀌었나?")

        // 판정 대상이 실제로 존재해야 한다 — 0건이면 이 오라클은 아무것도 안 본다.
        let withMenus = sources.filter { $0.text.contains(".contextMenu") }
        XCTAssertFalse(withMenus.isEmpty, "`.contextMenu` 를 가진 파일이 0건 — 스캔이 깨졌다")

        var unmatched: [String] = []
        var itemsChecked = 0
        for source in withMenus {
            let actions = Self.accessibilityActionLabels(source.text)
            for item in Self.contextMenuItems(source.text) {
                itemsChecked += 1
                // 라벨이 삼항(선택 상태에 따라 두 문구)이면 **두 문구 중 하나**라도 짝이 있으면 된다 —
                // 접근성 액션도 같은 삼항 `Text` 를 넘기는 것이 이 저장소의 형태다.
                guard !item.labels.isEmpty else { continue }
                if item.labels.allSatisfy({ !actions.contains($0) }) {
                    unmatched.append("\(source.name): \(item.labels.joined(separator: " / "))")
                }
            }
        }
        // 파서가 항목을 하나도 못 뽑았으면 위 루프는 공짜로 통과한다 — 그 상태를 실패로 낸다.
        XCTAssertGreaterThan(itemsChecked, 5,
                             "우클릭 메뉴 항목을 \(itemsChecked)개만 뽑았다 — 파서가 메뉴 형태 변화를 못 따라갔다")
        XCTAssertTrue(unmatched.isEmpty,
                      "contextMenu 항목은 accessibilityAction 으로 1:1 대응돼야 한다.\n"
                        + "짝 없는 항목 \(unmatched.count)건:\n"
                        + unmatched.map { "  \($0)" }.joined(separator: "\n")
                        + "\n→ 항목마다 .accessibilityAction(named: Text(\"…\")) { … } 를 붙여라. 규약은 §4.3.")
    }

    // MARK: - 메뉴/접근성 라벨 파스

    /// 한 항목 = 우클릭 메뉴의 **최상위** `Button`/`Menu` 하나. `labels` 는 그 라벨의 문자열
    /// 리터럴들(삼항이면 둘).
    struct MenuItem {
        let labels: [String]
    }

    /// `.contextMenu { … }` 의 항목을 뽑는다. 클로저가 로컬 빌더에 위임하면(이 저장소의 두 자리가
    /// 다 그렇다 — `contextMenu(for:supported:)` · `folderRowMenu(_:)`) 그 함수 본문까지 따라간다.
    static func contextMenuItems(_ text: String) -> [MenuItem] {
        var bodies: [String] = []
        var search = text.startIndex
        while let hit = text.range(of: ".contextMenu", range: search..<text.endIndex) {
            search = hit.upperBound
            guard let body = braceBody(text, from: hit.upperBound) else { continue }
            // 위임 형태(`{ someBuilder(...) }`)면 그 빌더 본문으로 갈아탄다.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = delegatedBuilderName(trimmed),
               let resolved = builderBody(text, name: name) {
                bodies.append(resolved)
            } else {
                bodies.append(body)
            }
        }
        return bodies.flatMap { topLevelItems($0) }
    }

    /// `{ foo(a: b) }` 처럼 **호출 하나뿐**인 본문이면 그 함수 이름.
    private static func delegatedBuilderName(_ body: String) -> String? {
        guard let paren = body.firstIndex(of: "("), body.hasSuffix(")") else { return nil }
        let name = String(body[body.startIndex..<paren])
        guard name.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil,
              !name.hasPrefix("Button"), !name.hasPrefix("Menu") else { return nil }
        return name
    }

    /// `private func <name>(…) -> some View {` 또는 `@ViewBuilder` 가 붙은 같은 선언의 본문.
    private static func builderBody(_ text: String, name: String) -> String? {
        let pattern = "func\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*\\("
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text),
              let open = text[r.upperBound...].firstIndex(of: "{") else { return nil }
        return braceBody(text, from: open)
    }

    /// `from` 이후 첫 `{` 의 짝을 찾아 그 안을 돌려준다(중첩 계산).
    private static func braceBody(_ text: String, from: String.Index) -> String? {
        guard let open = text[from...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var body = ""
        for ch in text[open...] {
            if ch == "{" {
                depth += 1
                if depth == 1 { continue }
            }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(ch)
        }
        return nil
    }

    /// 본문의 **최상위** `Button`/`Menu` 항목. 중첩 `{ … }`(= `Menu` 의 자식, `ForEach` 본문,
    /// `label:` 클로저)은 건너뛴다 — 단 `label:` 클로저의 `Text` 리터럴은 그 항목의 라벨이므로
    /// 항목에 귀속시킨다.
    static func topLevelItems(_ body: String) -> [MenuItem] {
        var items: [MenuItem] = []
        var i = body.startIndex
        while i < body.endIndex {
            // 최상위에서 Button/Menu 키워드를 만나면 그 항목의 라벨을 모은다.
            guard let kind = ["Button", "Menu"].first(where: { body[i...].hasPrefix($0) }) else {
                i = body.index(after: i); continue
            }
            // 낱말 경계 — `ButtonStyle` 같은 접두 오탐을 막는다.
            let after = body.index(i, offsetBy: kind.count, limitedBy: body.endIndex) ?? body.endIndex
            if after < body.endIndex, body[after].isLetter || body[after].isNumber {
                i = body.index(after: i); continue
            }
            // 이 항목의 텍스트 = 다음 최상위 Button/Menu 전까지(중첩 블록 포함).
            let (chunk, next) = itemChunk(body, from: i)
            items.append(MenuItem(labels: stringLiterals(labelRegion(chunk, kind: kind))))
            i = next
        }
        return items
    }

    /// 항목 하나의 텍스트와 다음 탐색 위치. 중첩 중괄호를 세어 자식 블록을 통째로 삼킨다.
    private static func itemChunk(_ body: String, from: String.Index) -> (String, String.Index) {
        var depth = 0
        var parens = 0
        var chunk = ""
        var i = from
        var sawBody = false
        while i < body.endIndex {
            let ch = body[i]
            if ch == "(" { parens += 1 }
            if ch == ")" { parens -= 1 }
            if ch == "{" { depth += 1; sawBody = true }
            if ch == "}" {
                depth -= 1
                chunk.append(ch)
                i = body.index(after: i)
                if depth == 0 && sawBody {
                    // **[정정 2026-09-01] `Button { 액션 } label: { 라벨 }` 을 여기서 잘라
                    // 라벨을 통째로 잃고 있었다.**
                    // 그 표기는 **액션** 클로저가 닫히는 이 지점에서 깊이 0으로 돌아온다.
                    // 종전엔 그대로 반환해 chunk 에 `label:` 절이 없었고, 그러면
                    // `labelRegion` 이 첫 괄호 그룹 — 액션 클로저 안의 함수 호출 인자
                    // (예: `togglePlaylist(entry)`) — 만 보게 되어 문자열 리터럴이 0개가
                    // 된다. 그 결과 호출부의 `guard !item.labels.isEmpty` 가 그 항목을
                    // **조용히 건너뛰었다**. 바로 위 `topLevelItems` 의 doc 이 "label: 클로저의
                    // Text 리터럴은 그 항목의 라벨이므로 항목에 귀속시킨다" 고 적어 둔 것과
                    // 코드가 어긋나 있었다. 실재 면제 두 자리: `WallpaperGridView` 의
                    // 재생목록 토글·즐겨찾기 토글(둘 다 `Button { … } label: { Text … }`).
                    var j = i
                    while j < body.endIndex, body[j].isWhitespace { j = body.index(after: j) }
                    if body[j...].hasPrefix("label:") { continue }
                    return (chunk, i)
                }
                continue
            }
            // 중첩·괄호 밖에서 개행을 만나고 이미 인자 목록이 닫혔으면 항목이 끝난 것
            // (`Button("x") { … }` 가 아니라 `Button("x", action:)` 한 줄 형태).
            if depth == 0 && parens == 0 && ch.isNewline && !chunk.isEmpty
                && chunk.contains("(") && !chunk.hasSuffix(",") {
                return (chunk, i)
            }
            chunk.append(ch)
            i = body.index(after: i)
        }
        return (chunk, i)
    }

    /// 항목 텍스트에서 **라벨이 있는 영역**만 남긴다 — 액션 클로저 안의 문자열(예:
    /// `NSLocalizedString` 인자)을 라벨로 오인하지 않기 위해서다.
    /// `Menu("제목") { … }` · `Button("제목") { … }` → 첫 인자 목록. `label:` 클로저가 있으면 그쪽.
    private static func labelRegion(_ chunk: String, kind: String) -> String {
        if let labelRange = chunk.range(of: "label:") {
            return String(chunk[labelRange.upperBound...])
        }
        guard let open = chunk.firstIndex(of: "(") else { return "" }
        var depth = 0
        var out = ""
        for ch in chunk[open...] {
            if ch == "(" { depth += 1; if depth == 1 { continue } }
            if ch == ")" { depth -= 1; if depth == 0 { break } }
            out.append(ch)
        }
        return out
    }

    /// `accessibilityAction(named:)` 이 내는 문구 전부. 인자가 `Text("…")` 면 그 리터럴,
    /// 식별자(`playlistLabel` 등)면 같은 파일에서 그 이름에 대입된 `Text` 리터럴들을 모은다.
    static func accessibilityActionLabels(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var search = text.startIndex
        while let hit = text.range(of: ".accessibilityAction(named:", range: search..<text.endIndex) {
            search = hit.upperBound
            // 인자 목록 한 개 분량을 떼어낸다.
            var depth = 1
            var arg = ""
            var i = hit.upperBound
            while i < text.endIndex, depth > 0 {
                let ch = text[i]
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1; if depth == 0 { break } }
                arg.append(ch)
                i = text.index(after: i)
            }
            let literals = stringLiterals(arg)
            if !literals.isEmpty {
                out.formUnion(literals)
            } else {
                // 식별자 경유 — `<name>: … Text("a") : Text("b")` 대입을 찾는다.
                let name = arg.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? ""
                if name.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil {
                    out.formUnion(assignedTextLiterals(text, name: name))
                }
            }
        }
        return out
    }

    /// `name: <식>` 또는 `name = <식>` 의 우변에 든 `Text("…")` 리터럴들(줄 단위).
    private static func assignedTextLiterals(_ text: String, name: String) -> Set<String> {
        var out: Set<String> = []
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\s*[:=]\\s*([^\\n]*)") else {
            return out
        }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let rhs = String(text[r])
            guard rhs.contains("Text(") else { continue }
            out.formUnion(stringLiterals(rhs))
        }
        return out
    }

    /// 이스케이프를 존중하는 문자열 리터럴 스캔. 보간(`\(…)`)이 든 리터럴은 문구 대조가
    /// 불가능하므로 제외한다.
    static func stringLiterals(_ s: String) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "\"" else { i = s.index(after: i); continue }
            var j = s.index(after: i)
            var literal = ""
            var closed = false
            while j < s.endIndex {
                let ch = s[j]
                if ch == "\\" {
                    let n = s.index(after: j)
                    if n < s.endIndex { literal.append(ch); literal.append(s[n]); j = s.index(after: n); continue }
                }
                if ch == "\"" { closed = true; break }
                literal.append(ch)
                j = s.index(after: j)
            }
            if closed, !literal.isEmpty, !literal.contains("\\(") { out.append(literal) }
            i = closed ? s.index(after: j) : j
        }
        return out
    }

    /// 탭으로 동작하는 커스텀 뷰는 자기가 무엇인지 보조기술에 알려야 한다.
    ///
    /// `VStack { 썸네일; 제목 }` + `.onTapGesture` 는 화면에서만 버튼이다 — 보조기술에는
    /// 이미지와 텍스트가 따로 읽히고, 누를 수 있다는 것도 선택 상태도 전달되지 않는다.
    /// 실측(2026-08-17): `Sources/Waple` 전체에서 `.accessibilityLabel`/`Value`/`Hint`/
    /// `Element`/`AddTraits`·`.focusable` 참조가 **전부 0건**이다.
    /// **[정정 2026-08-30] 이 게이트도 `파일 단위`였다 — 같은 구멍이다.**
    ///
    /// 종전 술어: `text.contains("onTapGesture") && !text.contains("tileAccessibility")
    /// && !text.contains(".accessibilityElement(")`. 파일 어딘가에 `tileAccessibility` 가
    /// 한 번 있으면 그 파일의 **모든** 탭 구동 뷰가 면제됐다.
    ///
    /// 실측 재현(2026-08-30): 이미 준수하는 `WallpaperGridView` 에 접근성 표현이 없는 새 탭
    /// 컨트롤(`Image(systemName: "trash").onTapGesture { … }`)을 넣었더니 **통과**했다.
    ///
    /// 그래서 **`onTapGesture` 자리마다** 판정한다. 그 자리가 속한 모디파이어 체인(같은 들여쓰기
    /// 블록)에 접근성 표현이 있는지 본다 — 파일 전체가 아니라 그 뷰만 본다.
    func testTapDrivenViewsDeclareAccessibility() throws {
        let sources = try Self.uiSources()
        XCTAssertGreaterThan(sources.count, 20, "소스 수집이 실패했다 — 경로 규약이 바뀌었나?")

        var violations: [String] = []
        var sitesChecked = 0
        for source in sources {
            for site in Self.tapGestureSites(source.text) {
                sitesChecked += 1
                if !site.hasAccessibility {
                    violations.append("\(source.name):\(site.line)")
                }
            }
        }
        // 실제 탭 구동 뷰가 존재해야 한다 — 0건이면 이 오라클이 아무것도 안 본다.
        XCTAssertGreaterThan(sitesChecked, 3,
                             "onTapGesture 자리를 \(sitesChecked)개만 찾았다 — 스캔이 깨졌다")
        XCTAssertTrue(violations.isEmpty,
                      "onTapGesture 로 동작하는 커스텀 뷰에는 접근성 표현이 있어야 한다.\n"
                        + "접근성 표현 없는 자리 \(violations.count)건:\n"
                        + violations.map { "  \($0)" }.joined(separator: "\n")
                        + "\n→ .tileAccessibility(label:value:isSelected:onActivate:) 를 붙여라. 표준 형태는 §4.1.")
    }

    struct TapSite {
        let line: Int
        let hasAccessibility: Bool
    }

    /// `onTapGesture` 자리마다, **그 자리가 속한 모디파이어 체인**에 접근성 표현이 있는지.
    ///
    /// 체인 판정은 들여쓰기로 한다: `.onTapGesture` 는 언제나 `.` 로 시작하는 체인 줄이므로,
    /// 같은 들여쓰기 깊이의 연속된 `.`-접두 줄이 한 뷰의 체인이다. 위아래로 그 블록을 훑어
    /// `tileAccessibility`·`.accessibilityElement(`·`.accessibilityLabel(`·`.accessibilityAddTraits(`
    /// 중 하나라도 있으면 준수로 본다.
    static func tapGestureSites(_ text: String) -> [TapSite] {
        let markers = ["tileAccessibility", ".accessibilityElement(",
                       ".accessibilityLabel(", ".accessibilityAddTraits(",
                       ".accessibilityValue(", ".accessibilityAction("]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        func isChainLine(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespaces).hasPrefix(".")
        }
        // 체인 중간의 주석 줄은 체인을 끊지 않는다 — 이 저장소는 모디파이어 사이에 규약 근거를
        // 길게 적는다(`DisplaysView.monitorBox` 가 `.onTapGesture` 와 `.tileAccessibility` 사이에
        // 세 줄을 넣는다). 주석에서 끊으면 준수하는 코드가 오탐으로 빨개진다 — 실제로 그랬다.
        func isCommentLine(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("//") || t.hasPrefix("/*") || t.hasPrefix("*")
        }
        // 체인 모디파이어의 **트레일링 클로저를 닫는** 줄도 체인을 끊지 않는다 —
        // `.overlay(…) {` … `}` 다음에 `.tileAccessibility(…)` 가 이어지는 형태가 그렇다.
        // 같은 들여쓰기의 `}` 는 그 클로저의 끝이지 뷰의 끝이 아니다.
        func isChainCloser(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespaces).hasPrefix("}")
        }
        var out: [TapSite] = []
        for (i, line) in lines.enumerated() where line.contains("onTapGesture") {
            let depth = indent(line)
            // 체인 시작까지 위로, 끝까지 아래로 — 같은 들여쓰기의 `.`-접두 줄이 이어지는 범위.
            var lo = i
            while lo > 0 {
                let prev = lines[lo - 1]
                let sameChain = isChainLine(prev) && indent(prev) == depth
                let comment = isCommentLine(prev) && indent(prev) >= depth
                // 체인의 **수신자**(첫 뷰 식)까지는 올라가지 않는다 — 접근성 표현은 언제나
                // 체인의 모디파이어로 붙으므로 체인 줄만 보면 충분하다.
                guard sameChain || comment || indent(prev) > depth else { break }
                lo -= 1
            }
            var hi = i
            while hi + 1 < lines.count {
                let next = lines[hi + 1]
                let sameChain = isChainLine(next) && indent(next) == depth
                let comment = isCommentLine(next) && indent(next) >= depth
                let closer = isChainCloser(next) && indent(next) == depth
                // **[정정 2026-09-01] 더 깊은 줄을 전부 삼켜 자식 뷰의 접근성 표현이
                // 부모의 준수 근거가 됐다.**
                // 종전 `continuation = indent(next) > depth` 는 `.overlay { … }` 안의
                // **자식 뷰가 붙인** `.accessibilityLabel(...)` 까지 체인에 흡수했다.
                // 그러면 탭 대상 뷰 자신은 아무것도 선언하지 않았는데 자식 배지 하나로
                // 준수 판정이 났다(합성 재현: 자식 오버레이에만 라벨을 둔 탭 뷰가 통과).
                // 더 깊으면서 `.` 로 시작하는 줄은 **자식의 모디파이어 체인**이므로 흡수하지
                // 않는다. 모디파이어 인자의 여러 줄 본문(`.overlay(…) {` 안의 뷰 식 등)은
                // `.` 로 시작하지 않으므로 종전대로 이어진다.
                // (현재 트리 실측: 이 조임 전후 모두 `Sources/Waple` 의 탭 자리 4곳이 전부
                //  준수 — 오탐이 새로 생기지 않는다.)
                let continuation = (indent(next) > depth && !isChainLine(next))
                    || next.trimmingCharacters(in: .whitespaces).isEmpty
                guard sameChain || comment || closer || continuation else { break }
                hi += 1
            }
            let chain = lines[lo...hi].joined(separator: "\n")
            out.append(TapSite(line: i + 1,
                               hasAccessibility: markers.contains { chain.contains($0) }))
        }
        return out
    }

    // MARK: - notify 미러 (2026-08-25)

    /// **`notify` 가 설정 창에도 흐르는가, 그리고 굽기 스피너를 건드리지 않는가.**
    ///
    /// `AppDelegate` 는 이 스위트에서 **한 번도 인스턴스화되지 않는다**(`grep 'AppDelegate()' Tests/` = 0건).
    /// 즉 `notify` 의 런타임 동작을 부를 방법이 없다. 이 파일 머리말이 적은 그 상황 그대로라,
    /// 같은 방식(소스 전문 스캔)으로 **기계가 판정할 수 있는 만큼만** 잡는다.
    ///
    /// 잠그는 것 둘:
    /// ① 미러가 존재한다 — 없으면 트레이에서 설정 창만 열고 누른 동작의 성패가 화면 어디에도 안 뜬다.
    /// ② 미러가 `isBakingStill` 을 건드리지 않는다 — 이 미러는 **모든** notify 를 받으므로,
    ///    굽는 도중 도착한 무관한 알림이 스피너를 먼저 끄면 안 된다. (굽기는 한 번에 두 번
    ///    알림이 올 수 있다 — `writeLockscreenStill`.)
    ///
    /// 못 잡는 것: 실제로 화면에 뜨는지. 그건 실기 확인 몫이다.
    func testNotifyMirrorsIntoSettingsWindowWithoutTouchingTheBakingSpinner() throws {
        let files = try Self.uiSources()
        let appDelegate = try XCTUnwrap(files.first { $0.name == "AppDelegate.swift" }?.text,
                                        "AppDelegate.swift 를 못 찾았다 — 스캔 루트가 바뀌었나?")
        // `notify(_:)` 본문만 떼어 본다. 다음 함수 선언 전까지.
        guard let start = appDelegate.range(of: "private func notify(_ message: String) -> Bool {") else {
            return XCTFail("notify(_:) 선언을 못 찾았다 — 시그니처가 바뀌었으면 이 오라클도 같이 고쳐라")
        }
        // 중괄호를 세어 **함수 본문만** 떼어낸다. 고정 길이로 자르면 뒤따르는 다른 함수가
        // 딸려 들어와 오탐이 난다 — 처음에 1600자로 잘랐다가 실제로 그 오탐을 봤다.
        var depth = 1
        var body = ""
        for ch in appDelegate[start.upperBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 { break } }
            body.append(ch)
        }
        XCTAssertGreaterThan(body.count, 200, "본문 추출이 실패했다 — 이 오라클이 아무것도 안 본다")

        // **주석을 걷어내고 본다.** 처음엔 안 걷었다가 "isBakingStill 을 건드리지 마라" 라고
        // 적어 둔 **설명 주석 자체**를 위반으로 셌다 — 규약을 적는 행위가 규약 위반이 되는 오탐이다.
        let code = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slash = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slash.lowerBound])
            }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("settingsWindow?.isVisible == true"),
                      "설정 창 가시성 게이트가 없다 — settingsVM 은 lazy 라 먼저 건드리면 조기 생성된다")
        XCTAssertTrue(code.contains("settingsVM.statusMessage = message"),
                      "설정 창 미러가 없다 — 트레이→설정 경로에서 성패가 화면에 안 뜬다")
        XCTAssertFalse(code.contains("isBakingStill"),
                       "notify 미러는 굽기 스피너를 건드리면 안 된다 — 무관한 알림이 스피너를 먼저 끈다")
    }
}
