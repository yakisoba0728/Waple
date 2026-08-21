import XCTest
@testable import WapleCore

/// `ScenePackage` 의 **중복 엔트리 승자 규약**을 값으로 잠근다.
///
/// **[2026-08-21 철회 — 이 파일의 결론이 뒤집혔다]** 종전 이 파일의 머리말은 이랬다:
///
/// > ScenePackage 중복 엔트리 first-wins 규약 잠금 — 인덱스 구축이 선행자 유지(exact/normalized 모두
/// > `if index[name] == nil`)로 구현된 **의도된 디듑**이다. last-wins 로 회귀하면 data(for:) 의
/// > 에셋 선택이 바뀌는데 기존 테스트는 중복 엔트리를 다루지 않아 전부 녹색이었다.
///
/// 마지막 문장(테스트 공백)은 맞았다. **"의도된 디듑" 이라는 근거가 틀렸다** — 엔진을 근거로 댄
/// 적이 없고, 로더를 다시 뜨니 WE 는 정확히 반대로 동작한다. 근거 VA 는 `ScenePackage.init` 주석에
/// 전부 적었고, 요약하면 이렇다:
///
///   · 엔트리 이름은 적재 때 **제자리에서** ASCII 소문자화된다(`0x140276ac0`–`0x140276ad6`) —
///     WE 에는 대소문자를 보존하는 색인이 아예 없다.
///   · TOC 삽입은 `0x140276ae4 call 0x140277890`(find-or-emplace, FNV-1a 64) 뒤에
///     **조건 없이** `0x140276aef mov [rcx+0x30], eax`(offset) · `0x140276af5 mov [rcx+0x34], eax`
///     (size) 로 덮어쓴다 ⇒ **마지막 엔트리가 이긴다.**
///   · 조회(`0x140273f50`)도 요청을 같은 방식으로 접어 **맵을 한 번만** 찌른다.
///
/// 그래서 아래 테스트들은 값이 뒤집힌 채로 남는다. **지우지 않는 이유**: 이 파일이 없으면 다음
/// 사람이 "중복은 선행자 유지" 로 다시 되돌린다(실제로 한 번 그렇게 굳었다).
///
/// 도달은 **0 이 아니라 미측정**이다 — 워크샵 전수(엔트리 경로 11,338 종)에 ASCII 폴딩 충돌군이
/// **14군** 있고, pkg 별 동시 보유는 그 산출물로 못 재며 상한이 **16 pkg / 161** 이다.
final class ScenePackageFixRegressionTests: XCTestCase {
    /// 완전히 같은 이름이 두 번 오면 **뒤에 온 엔트리**가 이긴다.
    ///
    /// 종전 단언: `first`("중복 exact 이름은 선행 엔트리 유지(first-wins)"). 뒤집혔다.
    func testDuplicateExactNamesKeepLastEntryLikeWE() {
        let first = Data("FIRST".utf8), second = Data("SECOND".utf8)
        let pkg = ScenePackage.assemble([(name: "a/b.json", data: first),
                                         (name: "a/b.json", data: second)])
        XCTAssertEqual(pkg.data(for: "a/b.json"), second,
                       "WE 는 같은 접힌 키에 offset/size 를 덮어쓴다(0x140276aef·0x140276af5)")
        // 엔트리 표 자체는 TOC 순서 그대로 둘 다 남는다 — 접히는 것은 조회 색인뿐이다.
        XCTAssertEqual(pkg.entries.map(\.name), ["a/b.json", "a/b.json"])
    }

    /// 대소문자만 다른 두 엔트리는 WE 에서 **한 칸**이고, 뒤에 온 것이 이긴다.
    /// 요청 철자가 무엇이든(정확 일치든 아니든) 답이 같아야 한다 — WE 에는 정확 일치 색인이 없다.
    ///
    /// 종전 단언: `models/a.json` → `second`("exact 일치는 normalized 조회보다 우선"),
    /// `MODELS/A.JSON` → `first`("정규화 키 충돌은 선행 엔트리 유지"). **둘 다 뒤집혔다** —
    /// 종전 규약은 한 pkg 안에서 서로 다른 두 답을 냈고, WE 는 그 둘을 구별하지 못한다.
    ///
    /// **[주의] 이 케이스에 역슬래시를 섞으면 안 된다.** WE 는 구분자를 손대지 않으므로
    /// `Models\A.JSON` 과 `models/a.json` 은 WE 에서 **서로 다른 키**다 — 아래
    /// `testBackslashEntryStaysSeparateLikeWE` 가 그 축을 따로 잰다.
    func testFoldedKeyCollisionKeepsLastEntryLikeWE() {
        let first = Data("FIRST".utf8), second = Data("SECOND".utf8)
        let pkg = ScenePackage.assemble([(name: "Models/A.JSON", data: first),
                                         (name: "models/a.json", data: second)])
        for probe in ["models/a.json", "MODELS/A.JSON", "Models/A.JSON", "models/A.json"] {
            XCTAssertEqual(pkg.data(for: probe), second,
                           "\(probe): 접힌 키가 같으면 WE 는 마지막 엔트리 하나만 본다")
        }
    }

    /// **역슬래시는 WE 의 키에 섞이지 않는다.** WE 의 조회 정규화는 바이트별 `tolower` 뿐이고
    /// (`0x140274000`–`0x140274015`) 구분자 치환이 **없다**. 곧 `Models\A.JSON` 의 키는
    /// `models\a.json`, `models/a.json` 의 키는 `models/a.json` — **다른 칸**이다.
    ///
    /// Waple 의 역슬래시→슬래시 관용은 그 **뒤의 폴백**으로만 살아야 한다. 이 테스트는
    /// last-wins 를 넣으면서 그 성질이 깨지지 않았는지를 잰다(설계 첫 판에서 실제로 깼다 —
    /// 접힌 색인 하나에 역슬래시까지 접었더니 `Models\A.JSON` 질의가 **다른 엔트리**를 줬다).
    func testBackslashEntryStaysSeparateLikeWE() {
        let first = Data("FIRST".utf8), second = Data("SECOND".utf8)
        let pkg = ScenePackage.assemble([(name: #"Models\A.JSON"#, data: first),
                                         (name: "models/a.json", data: second)])
        // WE 와 같은 답: 각자 자기 키로 닿는다.
        XCTAssertEqual(pkg.data(for: #"Models\A.JSON"#), first,
                       #"WE 의 키는 `models\a.json` 이라 슬래시 엔트리와 겹치지 않는다"#)
        XCTAssertEqual(pkg.data(for: #"MODELS\a.JSON"#), first, "대소문자만 접힌다")
        XCTAssertEqual(pkg.data(for: "models/a.json"), second)
        XCTAssertEqual(pkg.data(for: "MODELS/A.JSON"), second)
    }

    /// 워크샵 코퍼스에 **실제로 있는** 충돌 이름쌍으로 같은 규약을 잰다
    /// (`corpus_scan/entry-name-frequency.tsv`: `models/Background.json` ×2 · `models/background.json` ×4,
    /// `models/Sky/Sky.mdl` ×1 · `models/sky/sky.mdl` ×1). 합성 이름만 쓰면 "실물엔 없는 얘기" 로
    /// 읽히기 쉬워 실측 이름을 함께 박아 둔다.
    func testCorpusObservedCaseCollisionPairsFoldToOneEntry() throws {
        let upper = Data("UPPER".utf8), lower = Data("LOWER".utf8)
        let p = try ScenePackage.parse(ScenePackageTests.makePkg([
            ("models/Background.json", upper),
            ("models/background.json", lower),
        ]))
        XCTAssertEqual(p.entries.count, 2, "TOC 는 두 줄 그대로다")
        XCTAssertEqual(p.data(for: "models/Background.json"), lower)
        XCTAssertEqual(p.data(for: "models/background.json"), lower)

        let q = try ScenePackage.parse(ScenePackageTests.makePkg([
            ("models/sky/sky.mdl", lower),
            ("models/Sky/Sky.mdl", upper),
        ]))
        XCTAssertEqual(q.data(for: "models/sky/sky.mdl"), upper, "뒤에 온 대문자 표기가 이긴다")
        XCTAssertEqual(q.data(for: "models/Sky/Sky.mdl"), upper)
    }

    /// **폴더 마운트에는 이 규약을 적용하지 않는다.** WE 의 폴더 마운트(`0x1402764d0`)는 엔트리
    /// 표를 만들지 않고 요청 경로로 파일을 바로 열므로, 그쪽에서 WE 와 같은 답은 **정확 일치**다.
    /// (리눅스처럼 대소문자를 구분하는 파일시스템에서만 두 파일이 공존할 수 있다.)
    func testDirectoryMountStillPrefersExactPath() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-pkg-dupdir-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("LOWER".utf8).write(to: root.appendingPathComponent("a.json"))
        try Data("UPPER".utf8).write(to: root.appendingPathComponent("A.json"))
        let p = try XCTUnwrap(ScenePackage.fromDirectory(root))
        guard p.entries.count == 2 else {
            // 대소문자를 구분하지 않는 파일시스템(기본 APFS/HFS+)이면 파일이 하나로 합쳐진다.
            // 그때는 이 테스트가 잴 것이 없다 — 건너뛴다.
            XCTAssertEqual(p.entries.count, 1)
            return
        }
        XCTAssertEqual(p.data(for: "a.json"), Data("LOWER".utf8))
        XCTAssertEqual(p.data(for: "A.json"), Data("UPPER".utf8))
    }
}
