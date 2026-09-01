import SwiftUI
import WapleCore
import WapleLibrary

/// 표준 인스펙터의 콘텐츠: 히어로 프리뷰(상시 애니) → 제목·메타 → 액션 → 속성 편집.
///
/// ## 스크롤러가 하나다
///
/// 종전에는 이 뷰가 `ScrollView` 를 하나 두고 그 안에 또 `ScrollView` 를 가진 속성 편집기를
/// 넣고 있었다. 중첩 스크롤은 휠이 어느 쪽을 움직이는지 예측할 수 없고, 안쪽이 바깥쪽의
/// 이상 높이를 밀어 올려 스크롤 막대가 두 개 생긴다. 지금은 **머리 부분은 고정, 속성만
/// 스크롤**한다. 그 배치를 고른 이유는 하나 더 있다 — 속성이 243개인 씬에서 한 줄기로
/// 스크롤하면 `배경으로 적용` 버튼이 위로 밀려 사라진다. 인스펙터에서 가장 자주 누르는
/// 버튼이 스크롤 밖으로 나가면 안 된다.
///
/// ## 폭을 스스로 정하지 않는다
///
/// 종전 `.frame(width: Metrics.panelWidth)` 는 창의 인스펙터 열 폭(min/ideal/max)과 싸운다.
/// 사용자가 열 경계를 끌어도 콘텐츠가 300pt 를 고집하면 남는 자리가 빈 띠로 남는다.
/// 폭은 `MainWindowView` 의 `inspectorColumnWidth` 가 결정한다.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var confirmRemove = false
    @State private var confirmReset = false
    @State private var deletingFolder: String?
    @State private var newFolderName = ""
    @State private var newFolderPrompt = false
    /// 초기화가 올린다 — 편집기가 저장된 오버라이드를 제자리에서 다시 읽는다.
    @State private var propsReload = 0
    @State private var savedFlash = false
    @State private var savedToken = 0

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                // 네이티브 빈 상태(w5d-polish) — WorkshopTabView:33 과 동일한 ContentUnavailableView 문법.
                ContentUnavailableView("배경을 선택하세요", systemImage: "photo.on.rectangle.angled")
            }
        }
        .background(ColorRole.panel)
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        VStack(spacing: 0) {
            header(entry, supported: supported)
            Divider()
            propertiesHeader(entry)
            // id 는 엔트리에만 건다 — 초기화는 재마운트가 아니라 제자리 재로드다.
            PropertyEditorView(entry: entry, viewModel: viewModel,
                               reloadToken: propsReload, onCommit: flashSaved)
                .id(entry.id)
        }
        .modifier(InspectorDialogs(
            entry: entry,
            confirmRemove: $confirmRemove,
            confirmReset: $confirmReset,
            deletingFolder: $deletingFolder,
            newFolderPrompt: $newFolderPrompt,
            newFolderName: $newFolderName,
            remove: { viewModel.remove(entry) },
            reset: { resetProperties(for: entry) },
            deleteFolder: { name in viewModel.deleteFolder(name) },
            createFolder: { name in viewModel.moveToFolder(entry, folder: name) }))
    }

    // MARK: - 머리 부분

    private func header(_ entry: LibraryEntry, supported: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            hero(entry)
            titleBlock(entry, supported: supported)
            actions(entry, supported: supported)
        }
        .padding(Space.panelInset)
    }

    /// 히어로는 장식이다 — 바로 아래 제목이 이 항목의 이름을 이미 말한다. 라벨 없는 이미지를
    /// 하나 더 노출하면 보조기술이 읽을 게 늘기만 한다.
    private func hero(_ entry: LibraryEntry) -> some View {
        heroContent(entry)
            .frame(height: Metrics.heroHeight)
            .frame(maxWidth: .infinity)
            .tileThumbnailClip(corner: Surface.cardCorner)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func heroContent(_ entry: LibraryEntry) -> some View {
        let url = viewModel.previewURL(for: entry)
        if let url, PreviewMedia.isAnimated(url) {
            // r3-M67: `animating: true` 하드코딩이었다 — 인스펙터 히어로는 화면에서 가장 큰
            // 프리뷰인데 열려 있는 내내 무조건 루프 재생했고, "동작 줄이기"를 한 번도 보지
            // 않았다(`AnimatedPreviewView` 소비처 세 곳 어디에도 참조가 0건이었다).
            // 조회는 `SystemPreference` 가 한다 — `Motion` 토큰이 곡선을 감싸는 것과 같은 이유로,
            // 화면 코드가 접근성 설정을 직접 읽는 자리를 늘리지 않는다.
            AnimatedPreviewView(url: url, animating: !SystemPreference.reduceMotion).scaledToFill()
        } else {
            // 플레이스홀더는 공유 썸네일이 내장한다 — 종전에는 이 자리에 같은 ZStack 을
            // 다시 적어서 채움 불투명도가 그리드(0.25)와 어긋나 있었다(0.3).
            PreviewThumbnail(url: url, placeholderFont: Typography.sectionHeader)
        }
    }

    private func titleBlock(_ entry: LibraryEntry, supported: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(Typography.itemTitle).lineLimit(2)
                Spacer()
                favoriteButton(entry)
            }
            HStack(spacing: Space.xs) {
                Text(verbatim: metaLine(entry, supported: supported))
                if let rating = entry.rating { ratingBadge(rating) }
            }
            .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    /// 아이콘만 있는 버튼은 보조기술에 이름이 없다. `Label` 을 아이콘 스타일로 두면 화면은
    /// 그대로이면서 이름이 생긴다(§4.5) — 삼항이 문자열이 아니라 `Text` 를 고르는 것도
    /// 같은 이유다(번역이 조용히 사라지지 않게).
    private func favoriteButton(_ entry: LibraryEntry) -> some View {
        let isFavorite = viewModel.isFavorite(entry)
        return Button {
            viewModel.toggleFavorite(entry)
        } label: {
            Label {
                isFavorite ? Text("즐겨찾기 해제") : Text("즐겨찾기")
            } icon: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(isFavorite ? ColorRole.selected : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? Text("즐겨찾기 해제") : Text("즐겨찾기"))
    }

    /// 별 글리프는 보조기술에 읽히지 않는다 — 값과 이름을 나눠 주는 공유 배지가 그걸 처리한다.
    private func ratingBadge(_ rating: Double) -> some View {
        MetricBadge(symbol: "star.fill",
                    value: Text(verbatim: String(format: "%.1f/5", rating * 5)),
                    label: Text("평점"))
            .foregroundStyle(ColorRole.rating)
    }

    /// 유형 + 미지원 꼬리표 한 줄. 조립을 뷰 밖으로 뺀 이유는 두 가지다.
    ///
    /// 종전에는 `유형라벨 + " · 지원 예정"` 문자열 덧셈이었다. 앞쪽은 이미 번역된 값인데
    /// 뒤쪽 꼬리표는 생 한국어라, 영어 시스템에서 "Video · 지원 예정" 처럼 반만 번역된 줄이
    /// 나온다. 완성된 문자열을 넘기려면 꼬리표까지 포함해 포맷 지정자로 조립해야 한다.
    /// 그리고 뷰 빌더 안에서 조건 분기로 문자열을 만들면 그 자리의 식이 길어진다(타입체커).
    private func metaLine(_ entry: LibraryEntry, supported: Bool) -> String {
        let type = NowPlayingSubtitle.typeLabel(entry.typeRaw)
        guard !supported else { return type }
        return String(format: NSLocalizedString("%@ · 지원 예정", comment: "미지원 배경 메타 줄"), type)
    }

    // MARK: - 액션

    @ViewBuilder
    private func actions(_ entry: LibraryEntry, supported: Bool) -> some View {
        VStack(spacing: Space.controlGap) {
            applyButton(entry, supported: supported)
            HStack(spacing: Space.controlGap) {
                monitorMenu(entry, supported: supported)
                playlistButton(entry, supported: supported)
            }
            .frame(maxWidth: .infinity)
            folderMenu(entry)
            if WallpaperType.from(entry.typeRaw) == .web {
                Button { viewModel.onOpenInteraction?() } label: {
                    Label("조작 창 열기", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
                }
            }
            removeButton()
        }
    }

    private func applyButton(_ entry: LibraryEntry, supported: Bool) -> some View {
        Button {
            _ = viewModel.apply(entry)
        } label: {
            Label("배경으로 적용", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // F503: .keyboardShortcut(.defaultAction) 제거 — 창 전체에 걸리는 바로가기라
        // 패널 표시 중 검색 필드 등 무관한 포커스에서 Enter 를 쳐도 포커스된 엔트리가
        // 적용(전체 리마운트)되는 오발동 풋건이 있었다. 적용은 더블클릭·컨텍스트 메뉴·
        // 이 버튼 클릭으로 충분하다(비파괴적이라 low 판단이나 오발동 방지가 낫다고 판단).
        //
        // 2026-08-17: 그 판단은 유지한다. 대신 키보드 경로는 **타일 쪽**에서 준다 —
        // 그리드 타일의 Return 은 그 타일에 포커스가 있을 때만 발화하므로, 검색 필드에서
        // Enter 를 쳤을 때 배경이 적용되는 종전 풋건이 되살아나지 않는다.
        .disabled(!supported)
    }

    private func monitorMenu(_ entry: LibraryEntry, supported: Bool) -> some View {
        Menu {
            ForEach(viewModel.screens, id: \.key) { screen in
                Button(screen.name) { viewModel.assign(entry, toScreen: screen.key) }
            }
            // 그리드 우클릭에만 있던 해제 경로를 여기에도 둔다 — 타일의 접근성 액션
            // `모니터에 적용` 이 이 메뉴로 안내하는데, 붙이기만 되고 떼기가 없으면
            // 그 경로로 온 사용자가 할당을 되돌릴 방법이 없다.
            let assigned = viewModel.screens.filter { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }
            if !assigned.isEmpty {
                Divider()
                ForEach(assigned, id: \.key) { screen in
                    Button(String(format: NSLocalizedString("%@ 할당 해제", comment: "모니터 할당 해제"),
                                  screen.name)) {
                        viewModel.clearAssignment(forScreen: screen.key)
                    }
                }
            }
        } label: {
            Label("모니터별", systemImage: "display")
        }
        .disabled(!supported)
    }

    private func playlistButton(_ entry: LibraryEntry, supported: Bool) -> some View {
        Button {
            viewModel.togglePlaylist(entry)
        } label: {
            Label {
                viewModel.isInPlaylist(entry) ? Text("목록 제거") : Text("목록 추가")
            } icon: {
                Image(systemName: viewModel.isInPlaylist(entry) ? "minus.circle" : "plus.circle")
            }
        }
        .disabled(!supported)
    }

    /// 폴더 컨트롤.
    ///
    /// 폴더는 사이드바로 올라갔고 그리드의 폴더 타일은 사라진다. 그런데 **항목을 폴더에
    /// 넣는 일**은 여전히 어딘가에 있어야 하고, 종전에는 그리드 우클릭의 중첩 메뉴에만
    /// 있었다 — 중첩 메뉴는 접근성 액션으로 평탄화되지 않으므로 보조기술로는 도달 불가였다.
    /// 표준 컨트롤인 이 메뉴가 그 대체 경로다(청사진 §4.3).
    ///
    /// `폴더 삭제` 도 여기 둔다. 청사진은 그 자리를 사이드바 행의 우클릭으로 지목했지만
    /// 사이드바는 이 단위의 소유가 아니다 — 폴더 타일이 사라지는 순간 앱에서 폴더를 지울
    /// 방법이 아예 없어지므로, 도달 가능한 자리를 하나는 남겨 둔다. 사이드바 경로는
    /// 마감 단계에서 추가하면 되고, 둘이 함께 있어도 규약에 어긋나지 않는다.
    @ViewBuilder
    private func folderMenu(_ entry: LibraryEntry) -> some View {
        let current = viewModel.folders.folderName(of: entry.id)
        Menu {
            Button("새 폴더…") { newFolderPrompt = true }
            if !viewModel.folders.folders.isEmpty { Divider() }
            ForEach(viewModel.folders.folders, id: \.name) { folder in
                Button(folder.name) { viewModel.moveToFolder(entry, folder: folder.name) }
            }
            if let current {
                Divider()
                Button("폴더에서 제거") { viewModel.moveToFolder(entry, folder: nil) }
                Button("폴더 삭제(항목은 유지)", role: .destructive) { deletingFolder = current }
            }
        } label: {
            Label {
                // 폴더 이름은 사용자 데이터다 — 번역 대상이 아니라 verbatim.
                current.map { Text(verbatim: $0) } ?? Text("폴더 없음")
            } icon: {
                Image(systemName: current == nil ? "folder" : "folder.fill")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("폴더"))
    }

    /// 파괴적 버튼이 macOS `bordered` 스타일에서는 붉게 틴트되지 않는다(캡처 확인) —
    /// 역할은 유지하되 위험은 휴지통 글리프와 확인 대화상자가 전달한다(청사진 §9.4).
    private func removeButton() -> some View {
        Button(role: .destructive) {
            confirmRemove = true
        } label: {
            Label("라이브러리에서 제거", systemImage: "trash").frame(maxWidth: .infinity)
        }
    }

    // MARK: - 속성 머리줄

    private func propertiesHeader(_ entry: LibraryEntry) -> some View {
        HStack(spacing: Space.controlGap) {
            Text("속성").font(Typography.subsectionHeader)
            savedIndicator
            Spacer()
            // 종전에는 평범한 캡션 버튼이었다 — 같은 패널의 `라이브러리에서 제거` 는
            // 파괴적 역할 + 확인 대화상자를 제대로 쓰는데 이쪽만 규칙이 달랐다.
            // 되돌릴 수 없기는 마찬가지다(저장된 오버라이드가 전부 사라진다).
            Button("초기화", role: .destructive) { confirmReset = true }
                .font(Typography.caption)
        }
        .padding(.horizontal, Space.panelInset)
        .padding(.vertical, Space.controlGap)
    }

    /// 커밋에는 화면 반응이 없었다 — 슬라이더를 놓아도 아무 일도 안 일어난 것처럼 보인다
    /// (적용 중이 아닌 배경이면 실제로 화면에 아무 변화가 없다). 잠깐 뜨는 확인 표시로
    /// 저장됐다는 사실만 전달한다.
    @ViewBuilder
    private var savedIndicator: some View {
        if savedFlash {
            Label("저장됨", systemImage: "checkmark.circle.fill")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func flashSaved() {
        savedToken &+= 1
        let token = savedToken
        Motion.run(Motion.stateChange) { savedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: SavedFlash.dwellNanoseconds)
            // 그 사이 새 커밋이 있었으면 그쪽 타이머가 이어받는다 — 연속 편집 중에 표시가
            // 깜빡이지 않게 한다.
            guard savedToken == token else { return }
            Motion.run(Motion.stateChange) { savedFlash = false }
        }
    }

    private func resetProperties(for entry: LibraryEntry) {
        viewModel.resetProperties(for: entry)
        propsReload &+= 1
    }
}

/// "저장됨" 표시가 머무는 시간.
///
/// 디자인 시스템은 이 페이즈 동안 동결이라 `Motion` 에 넣을 수 없어 여기 둔다. 값은
/// 읽고 이해할 시간(약 1초)에 여유를 더한 것이고, 애니메이션 길이가 아니라 **대기 시간**이라
/// 모션 감소 설정과 무관하다 — 감소 모드에서 짧게 만들면 오히려 못 읽는다.
private enum SavedFlash {
    static let dwellNanoseconds: UInt64 = 1_600_000_000
}

/// 인스펙터가 띄우는 확인·입력 대화상자 넷.
///
/// 뷰 빌더 밖으로 뺀 이유는 타입체커다 — 같은 뷰에 `confirmationDialog` 셋과 `alert` 하나를
/// 이어 붙이면 그 자리의 식이 네 겹 더 깊어진다(이 저장소에서 네 번 터진 자리다).
/// 모아 두면 "이 패널에서 되돌릴 수 없는 동작이 무엇인가" 도 한눈에 보인다.
private struct InspectorDialogs: ViewModifier {
    let entry: LibraryEntry
    @Binding var confirmRemove: Bool
    @Binding var confirmReset: Bool
    @Binding var deletingFolder: String?
    @Binding var newFolderPrompt: Bool
    @Binding var newFolderName: String
    let remove: () -> Void
    let reset: () -> Void
    let deleteFolder: (String) -> Void
    let createFolder: (String) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(format: NSLocalizedString("'%@'을(를) 라이브러리에서 제거할까요?",
                                                 comment: "라이브러리 제거 확인"), entry.title),
                isPresented: $confirmRemove) {
                Button("제거(파일은 유지)", role: .destructive, action: remove)
                Button("취소", role: .cancel) {}
            } message: {
                Text("디스크의 원본 폴더는 삭제되지 않습니다. 재생목록·모니터 할당·즐겨찾기·폴더·속성 편집값이 함께 제거됩니다.")
            }
            .confirmationDialog("속성을 기본값으로 되돌릴까요?", isPresented: $confirmReset) {
                Button("초기화", role: .destructive, action: reset)
                Button("취소", role: .cancel) {}
            } message: {
                Text("이 배경에 저장한 속성 변경이 모두 사라집니다.")
            }
            .confirmationDialog(folderDeletePrompt, isPresented: folderDeletePresented) {
                if let name = deletingFolder {
                    Button("폴더 삭제(항목은 유지)", role: .destructive) { deleteFolder(name) }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("폴더만 사라지고 안에 있던 배경은 라이브러리에 그대로 남습니다.")
            }
            .alert("새 폴더", isPresented: $newFolderPrompt) {
                TextField("폴더 이름", text: $newFolderName)
                Button("만들기") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { createFolder(name) }
                    newFolderName = ""
                }
                Button("취소", role: .cancel) { newFolderName = "" }
            }
    }

    private var folderDeletePrompt: String {
        guard let name = deletingFolder else { return "" }
        return String(format: NSLocalizedString("'%@' 폴더를 삭제할까요?", comment: "폴더 삭제 확인"), name)
    }

    private var folderDeletePresented: Binding<Bool> {
        Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })
    }
}
