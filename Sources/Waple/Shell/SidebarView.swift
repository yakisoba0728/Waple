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

    /// 삭제 확인 대기 중인 폴더 이름. `nil` = 대화상자 없음.
    ///
    /// 폴더 삭제는 되돌릴 수 없고(담긴 항목은 남지만 그룹은 사라진다) 우클릭 한 번으로
    /// 일어나서는 안 된다. 인스펙터의 같은 동작도 확인 대화상자를 거친다 — 진입점이
    /// 둘로 늘어도 확인 단계는 같아야 한다.
    @State private var deletingFolder: String?

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
        .confirmationDialog(folderDeletePrompt, isPresented: folderDeletePresented) {
            if let name = deletingFolder {
                Button("폴더 삭제(항목은 유지)", role: .destructive) { viewModel.deleteFolder(name) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("폴더만 사라지고 안에 있던 배경은 라이브러리에 그대로 남습니다.")
        }
    }

    private var folderDeletePrompt: String {
        guard let name = deletingFolder else { return "" }
        return String(format: NSLocalizedString("'%@' 폴더를 삭제할까요?", comment: "폴더 삭제 확인"), name)
    }

    private var folderDeletePresented: Binding<Bool> {
        Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })
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
                Label(folder.name, systemImage: "folder")
                    .tag(LibrarySelection.folder(folder.name))
                    .contextMenu { folderRowMenu(folder.name) }
                    // 우클릭 메뉴는 마우스 전용이다 — 보조기술·키보드 사용자에게 그 안의
                    // 항목은 존재하지 않는 것과 같다(청사진 §4.3). 같은 동작을 접근성
                    // 액션으로 1:1 로 낸다. 이름을 `Text` 로 넘기는 것은 현지화 때문이다:
                    // `accessibilityAction(named:)` 자체는 스캔 패턴에 없지만 안에 든
                    // `Text` 리터럴은 잡힌다(§5.3).
                    .accessibilityAction(named: Text("폴더 삭제(항목은 유지)")) {
                        deletingFolder = folder.name
                    }
            }
        } header: {
            Text("폴더")
        }
    }

    /// 폴더 행 우클릭 메뉴. 인스펙터의 폴더 메뉴와 **같은 동작**을 사이드바에도 낸다 —
    /// 폴더를 지우려고 굳이 그 폴더에 든 배경을 하나 골라 인스펙터를 열 이유가 없다.
    /// Finder/Photos 의 소스리스트 관례이기도 하다.
    @ViewBuilder
    private func folderRowMenu(_ name: String) -> some View {
        Button("폴더 삭제(항목은 유지)", role: .destructive) { deletingFolder = name }
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
