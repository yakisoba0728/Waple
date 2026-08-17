import SwiftUI
import WapleLibrary

/// 메인창 네비게이션 사이드바(소스리스트).
///
/// `List(selection:)` + `.listStyle(.sidebar)` 가 소스리스트 외관·섹션 접힘·선택 하이라이트·
/// 키보드 이동·VoiceOver 표현을 전부 준다. 커스텀으로 흉내내지 않는 이유가 이것이다 —
/// 이 앱의 커스텀 타일들이 지금 접근성 0인 것과 같은 함정을 사이드바에서 반복하지 않는다.
///
/// 선택 값을 자기 `@State` 로 들지 않고 바인딩으로 받는다. 필터 상태에서 유도된 값이라
/// 여기서 저장하면 두 벌이 되고, 두 벌은 반드시 갈라진다(근거는 `LibrarySection`).
struct SidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var selection: LibrarySelection?

    var body: some View {
        List(selection: $selection) {
            librarySection
            // 폴더가 하나도 없으면 섹션째 숨긴다 — 빈 헤더는 소음이다.
            if !viewModel.folders.folders.isEmpty { folderSection }
            workshopSection
        }
        .listStyle(.sidebar)
        // 고정폭 금지: 영어 UI 에서 항목 라벨이 길어지고(Workshop·Favorites) 큰 글씨 설정에서 더 길어진다.
        .navigationSplitViewColumnWidth(min: Metrics.navSidebarMin,
                                        ideal: Metrics.navSidebarIdeal,
                                        max: Metrics.navSidebarMax)
    }

    private var librarySection: some View {
        Section {
            Label("전체", systemImage: "square.grid.2x2").tag(LibrarySelection.all)
            Label("씬", systemImage: "sparkles").tag(LibrarySelection.scene)
            Label("동영상", systemImage: "play.rectangle").tag(LibrarySelection.video)
            Label("웹", systemImage: "globe").tag(LibrarySelection.web)
            Label("즐겨찾기", systemImage: "heart").tag(LibrarySelection.favorites)
        } header: {
            Text("라이브러리")
        }
    }

    private var folderSection: some View {
        Section {
            // 폴더 이름은 사용자 데이터다 — 번역 대상이 아니므로 String 오버로드가 맞다.
            ForEach(viewModel.folders.folders, id: \.name) { folder in
                Label(folder.name, systemImage: "folder").tag(LibrarySelection.folder(folder.name))
            }
        } header: {
            Text("폴더")
        }
    }

    private var workshopSection: some View {
        Section {
            Label("둘러보기", systemImage: "sparkle.magnifyingglass").tag(LibrarySelection.discover)
            Label("검색", systemImage: "magnifyingglass").tag(LibrarySelection.workshopSearch)
        } header: {
            Text("창작마당")
        }
    }
}
