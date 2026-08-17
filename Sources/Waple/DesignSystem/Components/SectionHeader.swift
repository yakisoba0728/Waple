import SwiftUI

/// 콘텐츠 영역 안의 섹션 제목 — 디스커버 레일 제목, 디스플레이 시트 헤더.
///
/// **사이드바의 `Section` 헤더가 아니다.** 그쪽은 `List(.sidebar)` 가 스타일까지 전부 준다
/// (커스텀으로 흉내내지 마라 — 청사진 §3.1). 이 컴포넌트는 시스템이 헤더를 그려 주지 않는
/// 자리, 즉 우물 위에 직접 놓이는 제목만 담당한다.
///
/// **왜 굳이 컴포넌트인가.** 2026-08-17 실측: `.title3.weight(.semibold)` 라는 같은 표현이
/// 세 파일에 각각 적혀 있고 셋의 위계가 서로 다르다. 우연히 같은 값이라 한 곳을 조정하면
/// 나머지가 조용히 뒤처진다. 역할 이름을 두면 무엇과 무엇이 같은 급인지 코드에 남는다.
///
/// ## 접근성 — 여기가 이 컴포넌트의 실질이다
///
/// 굵은 글씨는 눈에만 제목이다. `.isHeader` 트레잇이 붙어야 VoiceOver 로터의 제목 탐색에
/// 걸리고, 그래야 레일이 여럿인 화면에서 섹션 단위로 건너뛸 수 있다. 각 화면이 알아서
/// 붙이게 두면 붙는 곳과 안 붙는 곳이 갈린다 — 지금은 전 화면 0건이다.
struct SectionHeader: View {
    /// 제목. `String` 이 아니라 `Text` 인 이유는 `TypeBadge` 문서와 같다 — 비현지화
    /// 오버로드로 조용히 번역이 사라지는 걸 타입으로 막는다.
    let title: Text
    /// 앞에 붙는 SF Symbol. 없으면 글자만. 시트 헤더처럼 화면 정체성을 아이콘이 같이
    /// 말해 주는 자리에만 쓴다 — 레일 제목마다 아이콘을 붙이면 목록이 시끄러워진다.
    var symbol: String?

    var body: some View {
        heading
            .font(Typography.sectionHeader)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var heading: some View {
        if let symbol {
            Label(title: { title }, icon: { Image(systemName: symbol) })
        } else {
            title
        }
    }
}
