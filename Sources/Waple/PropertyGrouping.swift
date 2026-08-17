import WapleCore

/// 속성 편집기의 섹션 한 덩어리.
///
/// `title` 은 `displayOnly` 속성의 인덱스다 — 문자열이 아니라 인덱스를 담는 이유는 라벨
/// 정돈(`PropertyLabel.pretty`)이 뷰 쪽 관심사이고, 이 타입은 **어디서 자르는가**만 알면
/// 되기 때문이다. 순수하게 유지되므로 단위 테스트가 붙는다.
struct PropertySection: Equatable {
    /// 섹션 제목이 될 displayOnly 속성의 인덱스. nil = 제목 없는 선두 덩어리.
    var title: Int?
    /// 이 섹션에 속한 편집 컨트롤의 인덱스(원본 배열 기준, 순서 보존).
    var rows: [Int]
}

/// 평면 속성 목록 → 섹션(순수).
///
/// ## 왜 자르나
///
/// 실측(2026-08-17): 속성이 243개인 씬이 있고, 그게 300pt 인스펙터에 **평면 한 줄기**로
/// 들어간다. 스크롤 막대가 실오라기가 되고 무엇이 무엇과 한 묶음인지 읽히지 않는다.
///
/// 자를 자리는 이미 데이터에 있었다. WE 속성 목록에는 편집 컨트롤이 아닌 `displayOnly`
/// 항목이 섞여 있고, 원본 제작자가 그걸 **구분 문구로** 쓴다. 종전 편집기는 그걸 그냥
/// 회색 캡션 한 줄로 그려서, 화면에서는 제목처럼 보이는데 구조로는 아무 의미가 없었다.
/// 여기서 그 의도를 구조로 승격한다 — `Form(.grouped)` 이 섹션 카드를 공짜로 준다.
///
/// ## 제목만 있고 내용이 없는 덩어리를 버리지 않는 이유
///
/// `displayOnly` 는 항상 제목인 게 아니다. 그냥 안내 문구인 경우도 있고, 그건 뒤에 컨트롤이
/// 따라오지 않는 것으로 드러난다. 버리면 원본이 사용자에게 하려던 말이 사라진다 —
/// 호출부가 `rows.isEmpty` 를 보고 제목이 아니라 문단으로 그린다.
enum PropertyGrouping {
    /// - Parameters:
    ///   - properties: 원본 속성 배열.
    ///   - visible: 표시 대상 인덱스(조건부 표시·장식 제외를 이미 통과한 것).
    static func sections(in properties: [WallpaperProperty], visible: [Int]) -> [PropertySection] {
        var out: [PropertySection] = []
        var current = PropertySection(title: nil, rows: [])
        for i in visible where properties.indices.contains(i) {
            if PropertyControl.kind(forType: properties[i].type) == .displayOnly {
                // 선두의 빈 덩어리는 버린다 — 첫 속성이 곧 구분 문구인 경우가 흔한데,
                // 그때 제목도 내용도 없는 섹션을 하나 만들면 카드 하나가 빈 채로 뜬다.
                if current.title != nil || !current.rows.isEmpty { out.append(current) }
                current = PropertySection(title: i, rows: [])
            } else {
                current.rows.append(i)
            }
        }
        if current.title != nil || !current.rows.isEmpty { out.append(current) }
        return out
    }
}
