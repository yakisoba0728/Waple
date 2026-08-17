import SwiftUI
import WapleLibrary

/// 툴바 필터 팝오버 — 태그·나이 등급.
///
/// ## 왜 두 축만 남았나
///
/// 종전 필터 사이드바는 유형·즐겨찾기·나이 등급·태그 넷을 한 열에 세워 두고 창 좌측을
/// 상시 점유했다. 개편에서 좌측은 네비게이션 사이드바가 가져갔고, 넷 중 **유형과
/// 즐겨찾기는 사이드바 항목으로 승격**했다(청사진 §1.2). 남는 둘은 값이 라이브러리에서
/// 유도되는 동적 축이라 사이드바에 상주시키면 목록이 라이브러리 크기만큼 길어진다.
/// 희소하게 쓰이는 축을 상시 노출하지 않는 것이 툴바 팝오버를 고른 이유다.
///
/// 승격의 대가로 **유형 다중 선택이 사라진다**(사이드바 행은 하나만 강조된다). 이건 의도된
/// 교환이다 — 사이드바 선택 유도가 표현할 수 없는 조합이면 아무 행도 강조하지 않으므로
/// (`LibrarySection.selection`), 다중 유형을 남겨두면 화면이 거짓말을 하는 상태가 생긴다.
///
/// ## 초기화가 자기 축만 지우는 이유
///
/// 종전 버튼은 기준 전체를 초기화했다. 지금 그렇게 하면 사이드바에서 고른 유형·즐겨찾기까지
/// 함께 풀려, 태그 팝오버를 열어 초기화를 눌렀는데 좌측 선택이 '전체' 로 튀는 동작이 된다.
/// 팝오버가 소유한 축만 지운다. 기준 전체 초기화는 그리드의 무결과 상태가 이미 제공한다
/// (그쪽은 검색까지 함께 지우는 탈출 수단이라 전체 초기화가 맞다).
struct FilterPopover: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        content
            .frame(width: FilterPopoverSize.width)
            .frame(maxHeight: FilterPopoverSize.maxHeight)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.availableTags.isEmpty && viewModel.availableRatings.isEmpty {
            // 커스텀 빈 상태를 그리지 않는다 — 시스템이 여백·글자 위계·접근성을 전부 준다.
            ContentUnavailableView("거를 수 있는 항목이 없습니다",
                                   systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("가져온 배경에 태그나 나이 등급이 없습니다."))
                .padding(Space.panelInset)
        } else {
            filterList
        }
    }

    private var filterList: some View {
        List {
            if !viewModel.availableRatings.isEmpty { ratingSection }
            if !viewModel.availableTags.isEmpty { tagSection }
            Section {
                Button("필터 초기화") { clearOwnedAxes() }
                    .disabled(!hasOwnedFilters)
            }
        }
        .listStyle(.sidebar)
    }

    private var ratingSection: some View {
        Section {
            ForEach(viewModel.availableRatings, id: \.self) { rating in
                Toggle(isOn: binding(for: rating, in: \.ratings)) {
                    Text(verbatim: ContentRatingLabel.pretty(rating))
                }
            }
        } header: {
            Text("나이 등급")
        }
    }

    private var tagSection: some View {
        Section {
            HStack {
                // 감사 V06: '전체'는 available 전체 선택 — LibraryFiltering 은 이 상태를
                // 무필터로 간주하므로 태그 없는 배경도 그대로 보인다.
                Button("전체") { viewModel.criteria.tags = Set(viewModel.availableTags) }
                Button("없음") { viewModel.criteria.tags = [] }
            }
            .buttonStyle(.link)
            .font(Typography.caption)
            ForEach(viewModel.availableTags, id: \.self) { tag in
                // 태그는 사용자 데이터다 — 번역 대상이 아니므로 문자열 오버로드가 맞다.
                Toggle(tag, isOn: binding(for: tag, in: \.tags))
            }
        } header: {
            Text("태그")
        }
    }

    private var hasOwnedFilters: Bool {
        !viewModel.criteria.tags.isEmpty || !viewModel.criteria.ratings.isEmpty
    }

    private func clearOwnedAxes() {
        viewModel.criteria.tags = []
        viewModel.criteria.ratings = []
    }

    /// Set 멤버십 ↔ Toggle 바인딩(제네릭 — 태그·등급 공용).
    private func binding<T: Hashable>(for value: T,
                                      in keyPath: WritableKeyPath<LibraryFilterCriteria, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { viewModel.criteria[keyPath: keyPath].contains(value) },
            set: { on in
                if on { viewModel.criteria[keyPath: keyPath].insert(value) }
                else { viewModel.criteria[keyPath: keyPath].remove(value) }
            })
    }
}

/// 팝오버 치수.
///
/// 디자인 시스템은 이 페이즈 동안 동결이라 토큰을 늘릴 수 없어 여기에 둔다.
/// 폭은 종전 필터 사이드바가 쓰던 `Metrics.sidebarWidth` 를 그대로 승계한다 — 그래서 그
/// 상수는 아직 사용처가 있다(개편 마감 단계에서 처분을 판단할 때 이 사실을 함께 볼 것).
/// 높이는 상한이다. 팝오버 안의 목록은 라이브러리에 든 태그 수만큼 길어지는데, 상한이
/// 없으면 태그가 많은 라이브러리에서 팝오버가 화면 밖까지 뻗는다(디스플레이 시트가
/// 이상 폭 전파로 겪고 있는 것과 같은 종류의 문제다). 상한에 걸리면 목록이 스크롤한다.
private enum FilterPopoverSize {
    static let width: CGFloat = Metrics.sidebarWidth
    static let maxHeight: CGFloat = 360
}

/// WE `contentrating` 원문 → 표시 라벨(미지 값은 원문 그대로).
///
/// 열거 라벨을 계산 프로퍼티로 두고 생 한국어를 돌려주면 커버리지 스캔에 안 걸리고, 받는
/// 쪽은 비현지화 오버로드로 붙는다 — 종전 구현이 정확히 그 상태라 세 등급이 영어 시스템에서
/// 한국어로 남아 있었다. 여기서 완성해 넘긴다.
enum ContentRatingLabel {
    static func pretty(_ raw: String) -> String {
        switch raw.lowercased() {
        case "everyone": return NSLocalizedString("전체 이용가", comment: "WE 나이 등급")
        case "questionable": return NSLocalizedString("주의", comment: "WE 나이 등급")
        case "mature": return NSLocalizedString("성인", comment: "WE 나이 등급")
        default: return raw
        }
    }
}
