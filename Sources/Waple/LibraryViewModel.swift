import Foundation
import Combine
import WapleCore
import WapleLibrary
import WapleRender

/// 엔트리 하나의 프리뷰 해석 결과. 근거는 `LibraryViewModel.previewState(for:)`.
enum EntryPreviewState: Equatable {
    case image(URL)
    /// 폴더는 있는데 프리뷰 파일이 없다 — 정상 상태다(가져온 동영상 등).
    case noPreview
    /// 북마크가 끊겼거나 원본 폴더가 사라졌다 — 적용하면 실패한다.
    case missingFolder
}

/// AppDelegate가 배경 적용 요청을 받은 시점의 결과. ffmpeg 선변환은 렌더러 교체
/// 전에 비동기로 완료되므로 `pending`을 동기 성공으로 위장하지 않는다.
enum WallpaperApplyDisposition: Equatable {
    case applied
    case pending
    case failed
}

/// `.pending` 요청의 최종 결과. `cancelled`는 더 최신 적용 요청이 세대를 교체한 경우라
/// 실패 후보를 계속 순회하면 안 된다 — 사용자가 고른 새 배경을 옛 재생목록 콜백이 덮게 된다.
enum WallpaperApplyResolution: Equatable {
    case applied
    case failed
    case cancelled
}

/// `@unchecked Sendable`: 이 뷰모델의 상태는 **메인 큐 한정**이다. `@Published` 대입은 전부 SwiftUI
/// 갱신을 일으키므로 애초에 그럴 수밖에 없고, 유일한 오프메인 경로인 세 임포트(`importParent`/
/// `importZip`/`importVideoFile`)는 무거운 I/O 만 `importQueue` 에서 하고 스토어 등록·`entries`
/// 갱신은 `DispatchQueue.main.async` 홉 뒤에서 한다. 큐를 넘는 것은 `self` **참조**뿐이고,
/// 그 참조를 역참조하는 곳은 전부 그 메인 홉 안이다.
///
/// ★ 2026-08-19 여기서 **실제 경합 하나를 고쳤다.** `importVideoFile` 이 `importQueue` 안에서
/// `self.videoPrepare` 라는 `var` 를 직접 읽고 있었다 — 메인이 같은 순간 그 프로퍼티에 대입하면
/// (테스트가 실제로 그렇게 한다) 동기화가 전혀 없다. 이제 큐에 들어가기 전 메인에서 값을 읽어
/// 넘기고, 세 경로 모두 백그라운드 블록이 `self` 를 아예 캡처하지 않는다.
///
/// **원래 맞는 표기는 `@MainActor` 다.** 못 쓰는 이유는 코드가 아니라 빌드 구성이다 —
/// `VideoRenderer` 가 같은 이유로 같은 결론을 적어 둔 것과 동일하다. 테스트 타깃은 아직
/// Swift 5·minimal 이고 비격리 XCTest 메서드에서 이 타입을 직접 만들어 구동하는 파일이 넷
/// (`LibraryViewModelTests`·`VideoImportFixRegressionTests`·`LibraryRemovalTests`·
/// `LibraryApplyBranchTests`)이다. 소스에 `@MainActor` 를 붙이면 그 호출들이 **에러**가 되어
/// `swift test` 가 통째로 안 선다(같은 리포에서 `WorkshopViewModel`/`DiscoverViewModel` 을
/// `@MainActor` 로 올릴 때 그 테스트 넷이 전부 `@MainActor` 로 함께 올라간 이유가 이것이다).
/// **그 네 파일을 같은 커밋에서 `@MainActor` 로 올릴 때 이 표기를 `@MainActor` 로 교체할 것.**
final class LibraryViewModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selectedId: String?
    // MARK: - 브라우즈 상태(메인창 UI) — selectedId(=적용됨)와 구분되는 패널 포커스.
    @Published var focusedId: String?
    /// 우측 정보 패널 노출 여부(툴바 토글이 소유하던 로컬 @State 를 승격 — selectForPropertiesView 가
    /// focusedId 와 함께 갱신할 수 있어야 하기 때문. 기본 true(기존 동작 무회귀).
    @Published var panelVisible = true
    @Published var searchText = ""
    @Published var criteria = LibraryFilterCriteria()
    @Published var activeFolder: String?
    @Published var sortOrder: LibrarySortOrder = .recentFirst

    /// F840: 필터 결과 캐시. 종전에는 **읽을 때마다** 전체 엔트리를 걸러·정렬하고 Set 두 개
    /// (allTags/allRatings)를 새로 만들었다. WallpaperGridView.body 가 한 패스에서 이 값을 세 번
    /// 읽으므로 검색어 한 글자마다 전 엔트리 필터+정렬이 3회 돌았다.
    /// 무효화는 `objectWillChange` 구독 하나로 한다(init) — 입력(entries/searchText/criteria/
    /// sortOrder/activeFolder/폴더·즐겨찾기 스토어)이 바뀌는 모든 경로가 이미 그 신호를 낸다
    /// (@Published 대입은 자동, 스토어 변경 경로는 명시 `objectWillChange.send()`).
    /// 입력을 일일이 열거해 키를 만드는 대신 이 신호를 쓰면 "새 입력을 추가하며 무효화를 빠뜨리는"
    /// 실수 자체가 생기지 않는다.
    private var filteredCache: [LibraryEntry]?
    private var invalidationCancellable: AnyCancellable?

    var filteredEntries: [LibraryEntry] {
        if let cached = filteredCache { return cached }
        // 폴더는 사이드바가 고르는 걸러보기다 — 고르지 않았으면 좁히지 않는다(LibraryFolders 참조).
        // 폴더 안에서의 검색은 그 폴더 안에서 한다: 사이드바가 폴더를 강조하고 있는데 결과가
        // 폴더 밖까지 나오면 좌측 강조가 거짓말이 된다.
        let scoped = LibraryFolders.scoped(entries, folders: folders.folders, active: activeFolder)
        // r3-M24: "전체 선택 = 무필터" 판정의 모집단을 **명시적으로** 넘긴다. 안 넘기면 필터가
        // 폴더로 좁혀진 `scoped` 에서 모집단을 유도하는데, 사용자가 고른 태그/등급은 팝오버가
        // 나열한 `availableTags`/`availableRatings`(= 전체 엔트리)에서 왔다 — 두 집합이 다르면
        // 폴더 안에서 그 축이 통째로 건너뛰어져 필터가 조용히 무필터가 된다.
        let result = LibraryFiltering.apply(scoped, search: searchText, criteria: criteria,
                                            sort: sortOrder, isFavorite: { self.favorites.isFavorite($0) },
                                            availableTags: Set(availableTags),
                                            availableRatings: Set(availableRatings))
        filteredCache = result
        return result
    }
    var availableTags: [String] {
        Array(Set(entries.flatMap { $0.tags ?? [] })).sorted()
    }
    var availableRatings: [String] {
        Array(Set(entries.compactMap(\.contentRating))).sorted()
    }
    var focusedEntry: LibraryEntry? { entries.first { $0.id == focusedId } }
    /// 전역 선택 엔트리(selectedId) — 하단 바 제목 표시, 디스플레이 시트 미할당 모니터 미리보기
    /// 폴백(w5d-displays) 등이 공유. 없으면 nil.
    var globalEntry: LibraryEntry? { entries.first { $0.id == selectedId } }
    /// 하단 바 "현재:" 표시용 — 적용된(selectedId) 배경 제목.
    var appliedTitle: String? { globalEntry?.title }

    /// 적용 요청을 AppDelegate 로 전달한다. `pending`은 선변환 중이므로 선택을
    /// 아직 영속하지 않고, AppDelegate의 실제 교체 성공 콜백을 받은 이 타입이 commit한다.
    /// 완료 콜백은 반환값이 `.pending`일 때만 나중에 정확히 한 번 호출한다.
    var onApply: ((URL, @escaping (WallpaperApplyResolution) -> Void) -> WallpaperApplyDisposition)?

    /// 사용자에게 보여줄 메시지를 AppDelegate 로 전달한다.
    ///
    /// **오류 전용이 아니라 알림 채널이다.** 싱크는 상태 배너이고 배너는 중립 스타일
    /// (info 글리프)이라, 성공("배경 3개를 가져왔습니다")·부분 실패 안내도 같은 통로로 나간다.
    /// 종전 이름은 `onError` 였고 그 사실과 어긋나 있었다 — 이름만 보고 "오류일 때만 부른다"
    /// 고 읽으면 성공 통지용 채널을 새로 파게 된다. 이름을 고치려면 배선하는 AppDelegate 를
    /// 만져야 해서 Unit B 가 마감(Unit E)으로 넘겼고, 2026-08-17 여기서 닫았다.
    ///
    /// **넘어가는 값은 이미 현지화가 끝난 문자열이다.** 싱크가 받는 타입이 String 이라
    /// 거기서는 자동 번역이 걸리지 않는다 — 그 자리에 도착한 뒤에는 손쓸 방법이 없으므로
    /// 만드는 쪽에서 완성한다. 리터럴이 NSLocalizedString 안에 남아 현지화 커버리지 오라클에
    /// 그대로 잡히는 것도 이 방향을 고른 이유다(청사진 §5.0 의 권장안 (a)).
    var onNotify: ((String) -> Void)?

    private let store: LibraryStore
    let playlist: PlaylistStore
    let monitors: MonitorAssignmentStore
    let favorites: FavoritesStore
    let folders: FolderStore

    /// 화면 목록 제공(키+표시명) — AppDelegate 주입.
    var screensProvider: (() -> [(key: String, name: String)])?
    /// 모니터 할당 변경 → 즉시 재적용 트리거.
    var onAssignmentsChanged: (() -> Void)?
    /// 재생목록 변경 → 타이머 재구성 트리거.
    var onPlaylistChanged: (() -> Void)?
    /// 웹 조작 창 열기(적용된 웹 월페이퍼의 입력 프록시) — AppDelegate 주입.
    var onOpenInteraction: (() -> Void)?
    /// 툴바 설정 버튼 → AppDelegate.openSettings (SP5′).
    var onOpenSettings: (() -> Void)?
    /// 빈 라이브러리 상태의 "창작마당 열기" → MainWindowView 가 탭 전환(뷰 로컬 상태라 AppDelegate 아님).
    var onOpenWorkshop: (() -> Void)?
    /// 현재 적용 중인 동영상 프로젝트 id들(w5d-settings-ia, 하단 바 음량/배속 대상) — AppDelegate 주입.
    /// SettingsViewModel 이 쓰던 것과 동일 소스(VideoSettingsTarget.projectIds).
    var videoTargetIds: () -> [String] = { [] }
    /// 음량/배속 변경 반영(F820: 라이브 반영 — AppDelegate.applyLiveVideoSettings 주입, 리마운트 없음).
    var onVideoSettingsChanged: (() -> Void)?
    /// 하단 바: 재생목록 다음으로 — AppDelegate 주입.
    var onAdvancePlaylist: (() -> Void)?
    /// 하단 바: 전역 일시정지 토글(새 상태 반환) — AppDelegate 주입.
    var onTogglePause: (() -> Bool)?
    @Published var isPaused = false

    init(store: LibraryStore, playlist: PlaylistStore, monitors: MonitorAssignmentStore,
         favorites: FavoritesStore, folders: FolderStore) {
        self.store = store
        self.playlist = playlist
        self.monitors = monitors
        self.favorites = favorites
        self.folders = folders
        self.entries = store.entries
        self.selectedId = store.selectedId
        // F840: 어떤 입력이 바뀌든 ObservableObject 는 objectWillChange 를 먼저 낸다(willSet 시점) —
        // 그 순간 캐시를 버리면 다음 읽기가 새 값으로 다시 계산한다.
        invalidationCancellable = objectWillChange.sink { [weak self] _ in
            self?.filteredCache = nil
        }
    }

    // MARK: - 재생목록/모니터별

    func isInPlaylist(_ entry: LibraryEntry) -> Bool { playlist.ids.contains(entry.id) }

    func togglePlaylist(_ entry: LibraryEntry) {
        playlist.toggle(entry.id)
        objectWillChange.send()
        onPlaylistChanged?()
    }

    var screens: [(key: String, name: String)] { screensProvider?() ?? [] }

    func assign(_ entry: LibraryEntry, toScreen key: String) {
        monitors.setAssignment(entry.id, for: key)
        objectWillChange.send()
        onAssignmentsChanged?()
    }

    func clearAssignment(forScreen key: String) {
        monitors.setAssignment(nil, for: key)
        objectWillChange.send()
        onAssignmentsChanged?()
    }

    func assignedEntryTitle(forScreen key: String) -> String? {
        guard let id = monitors.assignment(for: key) else { return nil }
        return entries.first(where: { $0.id == id })?.title
    }

    /// 화면에 할당된 라이브러리 엔트리(썸네일 로딩용). 미할당/유실 id → nil(전역 배경).
    func assignedEntry(forScreen key: String) -> LibraryEntry? {
        guard let id = monitors.assignment(for: key) else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - 즐겨찾기/제거

    func isFavorite(_ entry: LibraryEntry) -> Bool { favorites.isFavorite(entry.id) }

    func toggleFavorite(_ entry: LibraryEntry) {
        favorites.toggle(entry.id)
        objectWillChange.send()
    }

    func moveToFolder(_ entry: LibraryEntry, folder: String?) {
        folders.move(entry.id, to: folder)
        objectWillChange.send()
    }

    /// 폴더 삭제(담긴 항목은 남는다).
    ///
    /// **보고 있던 폴더를 지우면 선택도 함께 푼다.** 안 그러면 `activeFolder` 가 없는 폴더를
    /// 가리킨 채 남아 그리드가 0건이 되는데, 그 0 은 검색·필터가 활성이 아니라 무결과 안내도
    /// 뜨지 않는다 — 아무 메시지 없는 빈 화면이고, 사이드바의 그 행도 이미 사라져서 되돌아갈
    /// 곳이 보이지 않는다. 폴더 삭제 진입점이 인스펙터라 삭제하는 쪽과 보고 있는 쪽이 다를 수
    /// 있으므로, 정리를 스토어 호출부마다 맡기지 않고 여기 한 곳에 둔다.
    func deleteFolder(_ name: String) {
        folders.removeFolder(name)
        if activeFolder == name { activeFolder = nil }
        objectWillChange.send()
    }

    /// 그리드 우클릭 "선택(속성 보기)" 진입점(w5d-settings-ia) — 포커스와 함께 정보 패널을 노출한다.
    /// 패널이 접힌 상태에서 focusedId 만 바꾸면 라벨이 약속한 속성이 어디에도 나타나지 않는 데드엔드가
    /// 된다 — 포커스 설정과 패널 노출을 하나로 묶어 항상 결과가 보이게 한다.
    func selectForPropertiesView(_ entry: LibraryEntry) {
        focusedId = entry.id
        panelVisible = true
    }

    /// 적용 중인(전역 선택된) 배경이 라이브러리에서 제거되면, AppDelegate 의
    /// 전역 선택(currentFolderURL/currentProjectId) 도 함께 지우도록 알린다(F070) — 안 하면 스테일한
    /// currentFolderURL 이 남아, 이후 화면 변경·할당 변경 재적용(applyCurrentSelection)이 라이브러리
    /// 에서 이미 사라진 배경을 전역으로 되살린다(제거는 파일을 보존하므로 폴더 자체는 여전히 유효해
    /// apply 가 조용히 성공해버린다).
    /// 모니터 할당이 함께 있어도 발화한다 — 그 경우에도 재적용(onAssignmentsChanged) 전에
    /// 전역 선택이 비워져야 부활을 막을 수 있다.
    var onGlobalSelectionRemoved: (() -> Void)?

    /// 라이브러리에서 제거(파일 보존) + 전 스토어 orphan 정리. 적용 중 배경은 계속 재생된다
    /// (렌더러는 폴더를 직접 들고 있음) — Now Playing 표시는 '적용된 배경 없음'으로 떨어진다.
    func remove(_ entry: LibraryEntry) {
        let hadAssignment = monitors.all.values.contains(entry.id)
        // F070: 전역 선택이었는지는 할당과 무관하게 판정한다 — 할당이 병존하면 onAssignmentsChanged
        // 경유 applyCurrentSelection 이 스테일 currentFolderURL 을 재적용해 제거된 배경을 되살리므로,
        // 그 전에 전역 선택을 비우는 통지(onGlobalSelectionRemoved)가 반드시 필요하다.
        let wasGlobalSelection = selectedId == entry.id
        // F069: 재생목록에 없던 항목을 제거할 때도 무조건 onPlaylistChanged 를 호출하면 자동전환
        // 카운트다운이 불필요하게 리셋된다 — 제거 전에 실제 포함 여부를 확인해 두었다가 가드한다.
        let wasInPlaylist = playlist.ids.contains(entry.id)
        store.remove(id: entry.id)
        playlist.remove(entry.id)
        monitors.removeAssignments(entryId: entry.id)
        favorites.remove(entry.id)
        folders.removeEntry(entry.id)
        // r3-M65: 속성 편집값도 함께 지운다. 종전엔 위 다섯 스토어만 정리해 `waple.userprops.<id>`
        // 가 UserDefaults 에 영구히 남았다 — 같은 id 를 다시 쓰는 경로(관리 폴더 **밖** 원본을
        // 다시 가져오기 · 고아 폴더 정리 후 재사용)에서 새 배경이 남의 편집값을 물려받는다.
        // 확인 대화상자 문구도 이 정리를 명시한다(`WallpaperGridView`·`SelectionPanelView`).
        //
        // **남는 격차: `script-storage/<id>.json`.** 그쪽은 `ScriptLocalStorage(sceneId: project.id)`
        // 로 **파서 프로젝트 id** 를 쓰는데 이 뷰모델은 라이브러리 엔트리 id 만 들고 있고 둘은
        // 다를 수 있다(F480/F194 접미 유일화). 잘못된 키로 남의 파일을 지우는 쪽이 남겨 두는
        // 것보다 나쁘므로 여기서는 손대지 않는다 — 프로젝트 파스를 이 경로에 들이는 별도 작업이다.
        UserPropertyStore.reset(id: entry.id)
        entries = store.entries
        if selectedId == entry.id { selectedId = nil }
        if focusedId == entry.id { focusedId = nil }
        if wasInPlaylist { onPlaylistChanged?() }
        // F070: 전역 선택 정리 통지는 재적용 트리거(onAssignmentsChanged → applyCurrentSelection)보다
        // 먼저 본다 — 순서가 뒤집히면 스테일 currentFolderURL 의 재적용이 먼저 일어나 부활한다.
        if wasGlobalSelection { onGlobalSelectionRemoved?() }
        if hadAssignment { onAssignmentsChanged?() }
    }

    /// 임포트 무거운 I/O(zip 해제·동영상 복사/프리뷰 디코드) 전용 직렬 큐(A2) — 메인 스레드 정지 방지.
    /// 직렬로 두어 종전(메인 직렬)과 같은 순차 실행을 유지한다(동명 관리 디렉터리 유일화 판정 경합 방지).
    private let importQueue = DispatchQueue(label: "waple.library.import", qos: .userInitiated)

    /// 진행 중인 임포트가 있는가.
    ///
    /// 백그라운드화(A2·F582)로 UI 정지는 없어졌지만, 그 대가로 **아무 일도 일어나지 않는
    /// 것처럼 보이게** 됐다 — 큰 zip 을 고르면 수 초 동안 화면에 아무 변화가 없고, 사용자는
    /// 실패한 줄 알고 다시 고른다. 개수가 아니라 불리언인 이유는 진행률을 알 수 없기
    /// 때문이다(ditto 해제·동영상 디코드는 중간 보고가 없다) — 알 수 없는 진행률을 가짜
    /// 막대로 그리느니 비결정 스피너가 정직하다.
    @Published private(set) var isImporting = false
    /// 동시에 여러 번 가져오기를 걸 수 있다(드롭 연타). 마지막 하나가 끝날 때만 표시를 내린다.
    private var importsInFlight = 0

    private func beginImport() {
        importsInFlight += 1
        isImporting = true
    }

    private func endImport() {
        importsInFlight = max(0, importsInFlight - 1)
        isImporting = importsInFlight > 0
    }

    /// 여러 배경을 한 번에 가져온 결과를 사용자에게 알린다.
    ///
    /// 종전에는 **전량 실패일 때만** 말했다. 다섯 중 셋만 들어오면 화면은 조용하고, 왜 둘이
    /// 빠졌는지는 로그(F584)를 봐야만 알 수 있었다 — 사용자에게 그 로그는 없는 것과 같다.
    /// 성공도 알린다: 이미 있던 배경을 다시 가져오면 그리드가 그대로라 아무 일도 안 일어난
    /// 것처럼 보인다.
    private func reportImport(imported: Int, attempted: Int, emptyMessage: String) {
        if attempted == 0 || (imported == 0 && attempted > 0) {
            onNotify?(emptyMessage)
        } else if imported < attempted {
            onNotify?(String(format: NSLocalizedString("%lld개 중 %lld개만 가져왔습니다. 나머지는 project.json 이 없거나 읽을 수 없습니다.",
                                                      comment: "부분 임포트 실패"),
                            attempted, imported))
        } else {
            onNotify?(String(format: NSLocalizedString("배경 %lld개를 가져왔습니다.", comment: "임포트 완료"),
                            imported))
        }
    }

    /// F582: 상위 폴더 가져오기도 zip/동영상과 같이 importQueue 를 거친다 — 후보 나열(디렉터리
    /// 순회 I/O)은 백그라운드, 스토어 등록(importFolders, 저장 일괄화)은 메인 홉(스토어 변경
    /// 메인 한정 규약 유지). 종전엔 호출 스레드=메인에서 전체 순회·파싱을 동기 실행해 UI 가 정지했다.
    func importParent(_ url: URL) {
        let store = self.store
        beginImport()
        // 백그라운드 블록은 self 를 캡처하지 않는다 — 순수 순회(scanImportableFolders)에 필요한 건
        // store 참조와 url 뿐이고, 뷰모델 상태는 아래 메인 홉에서만 만진다. 종전에는 여기서
        // `guard let self` 로 강한 참조를 잡아 두고 정작 쓰지는 않았다(캡처만 늘리는 코드였다).
        importQueue.async { [weak self] in
            let folders = store.scanImportableFolders(in: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.endImport() }
                let imported = store.importFolders(folders)
                self.entries = store.entries
                // 시도 수는 호출부가 이미 안다(후보 목록의 길이) — 이 경로는 스토어 시그니처를
                // 바꿀 필요가 없다.
                self.reportImport(
                    imported: imported.count, attempted: folders.count,
                    emptyMessage: NSLocalizedString("가져온 배경이 없습니다. 선택한 폴더에 유효한 project.json 이 있는지 확인하세요.",
                                                    comment: "상위 폴더 가져오기 전량 실패"))
            }
        }
    }

    /// zip 가져오기(작업 4) — 해제(ditto, 무거움)는 백그라운드 큐에서, 스토어 등록
    /// (importExtractedZip → entries 갱신)은 메인 홉에서 한다(스토어 변경 메인 한정 규약 유지).
    func importZip(_ url: URL) {
        let store = self.store
        beginImport()
        // 해제(ditto)는 인스턴스 상태를 건드리지 않는다 — 백그라운드 블록은 self 를 캡처하지 않는다.
        importQueue.async { [weak self] in
            let temp = store.extractZipToTemp(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.endImport() }
                // zip 은 안에 배경이 몇 개인지 호출부가 알 수 없다 — 시도 수를 스토어가 함께 낸다.
                let outcome = temp.map { store.importExtractedZipCounting($0) } ?? (imported: [], attempted: 0)
                self.entries = store.entries
                self.reportImport(
                    imported: outcome.imported.count, attempted: outcome.attempted,
                    emptyMessage: NSLocalizedString("zip 에서 가져온 배경이 없습니다. project.json 이 포함돼 있는지 확인하세요.",
                                                    comment: "zip 가져오기 전량 실패"))
            }
        }
    }

    /// 확장자 기반 임포트 라우팅(zip/동영상/폴더) — NSOpenPanel·드래그앤드롭 결과 URL 하나를 적절한
    /// store 임포트로 보낸다. WallpaperGridView(툴바·드롭)·NowPlayingBar(하단 가져오기)·AppDelegate
    /// (온보딩 "가져오기…", ImportPanel 경유)가 공유해 판정 로직이 여러 벌로 갈라지지 않게 한다.
    func routeImport(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { importZip(url) }
        else if VideoImport.isVideoFile(url) { importVideoFile(url) }
        else { importParent(url) }
    }

    /// 동영상 준비(복사+프리뷰 생성 — 무거운 I/O) 클로저. 백그라운드 큐에서 호출된다.
    /// 테스트는 스텁을 주입해 실 복사/디코드·실 관리 디렉터리 쓰기를 생략한다.
    /// 반환된 폴더는 이 임포트 전용으로 새로 만든 것이어야 한다 — 등록 실패 시 제거된다(F583).
    /// `@Sendable`: 이 클로저는 `importQueue`(백그라운드)에서 호출된다 — 종전에는 그 사실이 타입에
    /// 없었고, 게다가 **백그라운드에서 이 `var` 를 직접 읽고 있었다**(메인의 대입과 경합). 이제
    /// 호출부가 큐에 들어가기 전 메인에서 값을 읽어 넘기고, 타입이 오프메인 호출을 명시한다.
    var videoPrepare: @Sendable (URL) -> URL? = { VideoImport.prepare(from: $0) }

    /// 원시 mp4/mov 가져오기(작업 5) — prepare(복사+프리뷰 디코드, 무거움)는 백그라운드 큐에서,
    /// 스토어 등록(importFolder → entries 갱신)은 메인 홉에서 한다(스토어 변경 메인 한정 규약 유지).
    func importVideoFile(_ url: URL) {
        let store = self.store
        // ★ 경합 수정: 종전엔 백그라운드 블록이 `self.videoPrepare` 를 그 자리에서 읽었다.
        //   메인이 같은 프로퍼티에 대입하는 것과 동기화가 없었다 — 큐에 들어가기 전 메인에서 읽는다.
        let prepare = self.videoPrepare
        beginImport()
        importQueue.async { [weak self] in
            let folder = prepare(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.endImport() }
                guard let folder, (try? store.importFolder(folder)) != nil else {
                    // F583: 준비(관리 폴더에 복사 완료) 후 등록이 실패하면 부분 산출물이 고아로 남는다 —
                    // 이 임포트를 위해 만든 폴더이므로 정리한다(videoPrepare 계약 주석 참조).
                    if let folder { try? FileManager.default.removeItem(at: folder) }
                    self.onNotify?(String(format: NSLocalizedString("동영상 가져오기에 실패했습니다: %@",
                                                                   comment: "동영상 임포트 실패"),
                                         url.lastPathComponent))
                    return
                }
                self.entries = store.entries
                self.onNotify?(String(format: NSLocalizedString("배경 %lld개를 가져왔습니다.", comment: "임포트 완료"), 1))
            }
        }
    }

    /// 워크샵 다운로드 직후 평점 반영(0…1). 표시용 메타 — 실패 무해.
    func setRating(_ score: Double, for entry: LibraryEntry) {
        store.setRating(score, id: entry.id)
        entries = store.entries
    }

    /// 워크샵 다운로드로 받은 배경 폴더 1개를 라이브러리에 가져온다(기존 importFolder 재사용). 실패 → nil.
    @discardableResult
    func importDownloaded(_ folderURL: URL) -> LibraryEntry? {
        guard let entry = try? store.importFolder(folderURL) else {
            onNotify?(String(format: NSLocalizedString("다운로드한 폴더를 가져오지 못했습니다: %@",
                                                      comment: "워크샵 다운로드분 임포트 실패"),
                            folderURL.lastPathComponent))
            return nil
        }
        entries = store.entries
        return entry
    }

    /// 적용 요청의 세 상태를 그대로 돌려준다. 특히 `.pending`을 Bool 성공으로 접지 않는다 —
    /// 재생목록은 RendererSwap 성공 뒤에만 시계/커서를 확정해야 한다.
    @discardableResult
    func apply(_ entry: LibraryEntry,
               completion: @escaping (WallpaperApplyResolution) -> Void = { _ in })
        -> WallpaperApplyDisposition {
        guard let folder = store.resolveFolderURL(for: entry) else {
            onNotify?(String(format: NSLocalizedString("‘%@’의 폴더를 찾을 수 없습니다. 다시 가져오세요.",
                                                      comment: "적용 실패 — 폴더 해석 불가"),
                            entry.title))
            return .failed
        }
        // 성공이 확인된 뒤에만 선택을 영속·강조한다. pending 시에도 기존 선택을 유지해
        // 변환 실패가 새 선택으로 보이는 상태를 만들지 않는다.
        let disposition = onApply?(folder) { [weak self] resolution in
            if resolution == .applied { self?.commitAppliedSelection(entryId: entry.id) }
            completion(resolution)
        } ?? .failed
        guard disposition != .failed else {
            onNotify?(String(format: NSLocalizedString("‘%@’을(를) 적용하지 못했습니다.",
                                                      comment: "적용 실패 — 마운트 거부"),
                            entry.title))
            return .failed
        }
        if disposition == .applied { commitAppliedSelection(entryId: entry.id) }
        return disposition
    }

    private func commitAppliedSelection(entryId: String) {
        store.select(entryId)
        selectedId = entryId
    }

    /// Finder에서 보기 등 파일시스템 접근용 폴더 URL(w5d-library). 해석 실패(북마크 stale·손상 등) → nil.
    func folderURL(for entry: LibraryEntry) -> URL? {
        store.resolveFolderURL(for: entry)
    }

    func previewURL(for entry: LibraryEntry) -> URL? {
        guard case .image(let url) = previewState(for: entry) else { return nil }
        return url
    }

    /// 타일이 그려야 할 프리뷰 상태.
    ///
    /// **폴더 유실과 프리뷰 부재를 가른다.** 둘 다 화면에서는 똑같이 회색 사진 글리프로
    /// 보이는데 원인도 대응도 전혀 다르다 — 앞은 원본이 사라졌거나 북마크가 끊긴 것이라
    /// 다시 가져와야 하고(적용하면 실패한다), 뒤는 프리뷰 파일만 없는 정상 상태다.
    /// 종전에는 `previewURL` 이 둘 다 nil 로 뭉개서 구분할 방법이 없었다.
    ///
    /// 한 번의 북마크 해석으로 둘을 함께 결정하는 것이 요점이다. 호출부가 `previewURL` 과
    /// `folderURL` 을 따로 물으면 타일마다 해석이 두 번 일어나고, 그리드는 body 평가마다
    /// 타일 수만큼 그걸 반복한다.
    func previewState(for entry: LibraryEntry) -> EntryPreviewState {
        guard let folder = store.resolveFolderURL(for: entry) else { return .missingFolder }
        guard let preview = WallpaperPathSecurity.containedFileURL(entry.previewName, root: folder) else {
            return .noPreview
        }
        return .image(preview)
    }

    func isSupported(_ entry: LibraryEntry) -> Bool {
        WallpaperType.from(entry.typeRaw).isSupportedInMVP
    }

    /// id(드래그앤드롭 등 문자열 페이로드로 전달된 경우) → 지원되는 실제 엔트리. 존재하지 않거나
    /// 지원 예정 타입이면 nil(w5d-displays — 디스플레이 시트 레일 드래그 대상 검증에 사용).
    func supportedEntry(forId id: String) -> LibraryEntry? {
        guard let entry = entries.first(where: { $0.id == id }), isSupported(entry) else { return nil }
        return entry
    }

    // MARK: - 유저 속성 편집

    /// 편집 가능한 속성 목록(기본값 + 저장된 오버라이드 병합).
    func editableProperties(for entry: LibraryEntry) -> [WallpaperProperty] {
        guard let folder = store.resolveFolderURL(for: entry) else { return [] }
        let parsed = try? ProjectJSONParser.parse(folderURL: folder)
        let resolved = parsed.flatMap { project in
            PresetResolver.resolve(
                project: project,
                originalFolder: folder,
                dependencyFolder: { dependency in
                    guard let dependencyEntry = store.entries.first(where: { $0.id == dependency }) else { return nil }
                    return store.resolveFolderURL(for: dependencyEntry)
                },
                parse: { try? ProjectJSONParser.parse(folderURL: $0) }
            )
        }
        let propertyRoot = resolved?.folderURL ?? folder
        guard let props = try? WallpaperProperties.parse(folderURL: propertyRoot) else { return [] }
        let overrides = UserPropertyStore.overrides(
            id: entry.id,
            presetOverrides: resolved?.presetOverrides ?? [:],
            presetResourceRoot: resolved?.presetFolderURL
        )
        return WallpaperProperties.applying(overrides: overrides, to: props)
    }

    func setProperty(key: String, value: PropertyValue, for entry: LibraryEntry) {
        UserPropertyStore.set(value, key: key, id: entry.id)
        reapplyIfCurrent(entry)
    }

    func resetProperties(for entry: LibraryEntry) {
        UserPropertyStore.reset(id: entry.id)
        reapplyIfCurrent(entry)
    }

    /// 현재 적용 중인 배경이면 즉시 재적용(변경 반영 — fit-mode 패턴).
    private func reapplyIfCurrent(_ entry: LibraryEntry) {
        if selectedId == entry.id {
            guard let folder = store.resolveFolderURL(for: entry) else { return }
            _ = onApply?(folder, { _ in })
            return
        }
        if monitors.all.values.contains(entry.id) {
            onAssignmentsChanged?()
        }
    }
}
