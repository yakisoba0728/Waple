import SwiftUI
import AppKit
import WapleCore
import WapleLibrary
import WapleRender

/// Now Playing 부제(순수): 타입 라벨 + 재생목록 상태. 뷰와 분리해 단위 테스트.
///
/// **문자열을 여기서 완성해 현지화까지 끝낸다.** 이 함수의 반환은 `String` 이라 뷰의
/// `Text(_:)` 는 비현지화 오버로드로 붙는다 — 즉 여기서 번역하지 않으면 영어 시스템에서도
/// 부제만 한국어로 남고 아무 것도 실패하지 않는다. 싱크 타입을 바꾸는 대신 생산 지점에서
/// 완성하는 쪽을 택한 이유는, 리터럴이 `NSLocalizedString(` 안에 남아야 커버리지 오라클이
/// 계속 볼 수 있기 때문이다(대입문으로 옮기면 어떤 스캔 패턴에도 안 걸린다).
///
/// 값이 끼는 두 조각은 보간이 아니라 포맷 지정자로 쓴다 — 보간은 en.lproj 키를 추론할 수
/// 없게 만들고, 어순이 다른 언어에서 조립이 깨진다.
enum NowPlayingSubtitle {
    static func text(typeRaw: String?, playlistCount: Int, intervalMinutes: Int, playlistEnabled: Bool) -> String {
        guard let typeRaw else {
            return NSLocalizedString("라이브러리에서 배경을 선택하세요", comment: "적용된 배경이 없을 때 하단 바 부제")
        }
        var parts = [typeLabel(typeRaw)]
        if playlistCount > 0 {
            parts.append(String(format: NSLocalizedString("재생목록 %lld개", comment: "재생목록 항목 수"),
                                playlistCount))
        }
        if playlistEnabled, playlistCount > 0 {
            parts.append(String(format: NSLocalizedString("%lld분마다 전환", comment: "재생목록 자동 전환 간격"),
                                intervalMinutes))
        }
        return parts.joined(separator: " · ")
    }

    /// 하단 바 음량/배속 컨트롤(w5d-settings-ia) 노출 여부 — 적용된 배경이 동영상일 때만. 설정 창에
    /// 묻혀 있던 컨트롤을 재생 컨텍스트(appliedEntry)를 이미 아는 하단 바로 옮기며, 씬/웹/무배경일
    /// 때는 스피커 아이콘 자체를 숨겨 무의미한 컨트롤을 노출하지 않는다.
    ///
    /// **배속 전용 판정이다** — 음량은 `showsVolumeControl` 을 쓴다(아래 참조).
    static func showsVideoControls(typeRaw: String?) -> Bool {
        typeRaw.map { WallpaperType.from($0) == .video } ?? false
    }

    /// 음량 컨트롤 노출 여부 — 동영상 **또는 씬**.
    ///
    /// 씬도 소리를 낸다. `SceneAudioPlayer` 가 mp3/wav/flac/ogg 를 재생하고 코퍼스 실측으로
    /// 자동재생 사운드 오브젝트 157개가 119씬에 있다. 그런데 그 최종 음량이
    /// `오서 볼륨 × VideoSettings.volume(id:)` 이고 후자의 기본값이 0(음소거)이라
    /// **씬 BGM 이 항상 들리지 않았다** — 재생은 실제로 되고 있었고 게인만 0이었다.
    ///
    /// 원인은 두 결정이 겹친 것이다. 하나는 "바탕화면이 예고 없이 소리 내지 않는다"(기본 0,
    /// `VideoSettings.swift`) — 이건 지금도 옳다. 다른 하나는 이 컨트롤을 `.video` 로 좁힌
    /// 것인데(w5d-settings-ia), 그때 씬 오디오가 **같은 볼륨 배관을 쓰고 있다는 사실**이
    /// 반영되지 않았다. 각각은 합리적이었는데 합쳐지니 씬 사용자에게 올릴 방법이 없어졌다
    /// (유일한 우회로가 `defaults write waple.video.volume.<id>` 였다).
    ///
    /// 배속은 여전히 동영상 전용이다 — `SceneAudioPlayer` 에 배속 개념이 없다.
    static func showsVolumeControl(typeRaw: String?) -> Bool {
        guard let t = typeRaw.map(WallpaperType.from) else { return false }
        return t == .video || t == .scene
    }

    /// 표시용 유형 라벨. 계산 프로퍼티/함수가 생 리터럴을 돌려주면 커버리지 스캔에 안 걸리므로
    /// 열거 라벨은 전부 `NSLocalizedString` 으로 감싼다(미지 타입은 WE 원문이라 번역 대상 아님).
    static func typeLabel(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return NSLocalizedString("장면", comment: "배경 유형")
        case .video: return NSLocalizedString("동영상", comment: "배경 유형")
        case .web: return NSLocalizedString("웹", comment: "배경 유형")
        case .preset: return NSLocalizedString("프리셋", comment: "배경 유형")
        case .application: return NSLocalizedString("응용 프로그램", comment: "배경 유형")
        case .unknown(let s): return s
        }
    }

    /// 하단 바 표시 엔트리(F495): 전역 선택 우선, 없으면 모니터 할당 중 하나 — 할당만으로 재생 중인
    /// 세션(전역 적용 무)에서 "적용된 배경 없음"으로 표시되던 불일치 방지.
    static func displayedEntry(global: LibraryEntry?, assignedIds: [String], entries: [LibraryEntry]) -> LibraryEntry? {
        if let global { return global }
        guard let id = assignedIds.first else { return nil }
        return entries.first { $0.id == id }
    }

    /// 모니터 할당 id 목록(감사 V06): Dictionary 순회 순서는 실행/상태마다 달라 멀티모니터에서
    /// 표시되는 배경이 들쭉날쭉했다 — 화면 키 정렬 순으로 고정해 결정적으로 한다.
    static func sortedAssignedIds(_ all: [String: String]) -> [String] {
        all.sorted { $0.key < $1.key }.map(\.value)
    }

    /// 대상별 값이 모두 같으면 그 값, 아니면 nil(F496) — 멀티모니터에 서로 다른 값이 적용된 상태에서
    /// 첫 대상 값만 보고 틀린 체크마크를 달지 않게 한다(nil = 체크 없음).
    static func commonValue(_ values: [Float]) -> Float? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// 시그니처: 하단 Now Playing 바 — 적용 중 배경의 애니 썸네일·제목 상시 + 재생 컨트롤 + 재생목록 + 가져오기.
struct NowPlayingBar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var showPlaylist = false

    /// 제목·부제 블록의 최대 폭. 이 화면 하나만 쓰는 값이라 공용 토큰(`Metrics`)이 아니라
    /// 여기 둔다 — 긴 제목이 오른쪽 컨트롤을 밀어내지 않게 하는 상한이다.
    private static let textMaxWidth: CGFloat = 380
    /// 재생목록 팝오버 폭. 역시 이 화면 전용 상수다.
    private static let playlistPopoverWidth: CGFloat = 280

    private var appliedEntry: LibraryEntry? {
        // F495: 전역 선택만 볼 경우 할당-전용 세션에서 재생 중인데도 "적용된 배경 없음"으로 표시됨.
        // 감사 V06: 대상 id 는 키 정렬 순(결정적) — Dictionary values 순회는 실행마다 달랐다.
        NowPlayingSubtitle.displayedEntry(global: viewModel.globalEntry,
                                          assignedIds: NowPlayingSubtitle.sortedAssignedIds(viewModel.monitors.all),
                                          entries: viewModel.entries)
    }

    var body: some View {
        HStack(spacing: Space.stackGap) {
            thumb
            nowPlayingText

            Spacer()

            // 아이콘 전용 버튼은 Label(문구)+iconOnly 로 만든다 — Label 이 접근성 이름이 되고
            // .help 가 툴팁이 된다. Image 만 쓰면 보조기술에는 이름 없는 버튼으로 읽힌다.
            // 삼항으로 String 을 고르면 두 리터럴 모두 커버리지 스캔에서 빠지므로 Text/Label 을 고른다.
            Button {
                if let paused = viewModel.onTogglePause?() { viewModel.isPaused = paused }
            } label: {
                if viewModel.isPaused {
                    Label("재생", systemImage: "play.fill").font(.title3)
                } else {
                    Label("일시정지", systemImage: "pause.fill").font(.title3)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(viewModel.isPaused ? Text("재생") : Text("일시정지"))

            Button { viewModel.onAdvancePlaylist?() } label: {
                Label("다음 배경", systemImage: "forward.fill").font(.title3)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(viewModel.playlist.ids.count < 2)
            .help("다음 배경")

            // w5d-settings-ia: 동영상 음량/배속 — 재생 컨텍스트(appliedEntry)를 이미 아는 하단 바로
            // 설정 창에서 이관. 적용된 배경이 동영상일 때만 노출(그 외엔 컨트롤할 대상이 없다).
            if NowPlayingSubtitle.showsVolumeControl(typeRaw: appliedEntry?.typeRaw) {
                videoControlsMenu
            }

            Divider().frame(height: 24)

            Button { showPlaylist.toggle() } label: {
                Label("재생목록", systemImage: "music.note.list")
            }
            .popover(isPresented: $showPlaylist, arrowEdge: .top) { playlistPopover }

            Button { openWallpaperPanel() } label: {
                Label("가져오기", systemImage: "plus")
            }
            .help("Wallpaper Engine 폴더·zip·동영상 가져오기")
        }
        .padding(.horizontal, Space.barInset)
        // 고정 높이가 아니라 하한이다 — 큰 글씨 설정에서 고정 56pt 는 글자를 자른다.
        .frame(minHeight: Metrics.nowPlayingHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Surface.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    /// 제목 + 부제. 보조기술에는 두 줄이 아니라 항목 하나로 읽혀야 한다.
    private var nowPlayingText: some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            // 옵셔널 제목에 리터럴을 nil 병합으로 붙이면 인자 타입이 String 이 되어 비현지화
            // 오버로드가 선택된다 — 리터럴을 눈앞에 적어 놓고도 번역이 사라지고, 커버리지
            // 스캐너도 리터럴이 여는 괄호 바로 뒤에 오지 않아 놓친다. 영어 캡처에서 실제로 이
            // 한 줄만 한국어로 남아 있었다. 그래서 폴백을 여기서 완성해 넘긴다.
            Text(appliedEntry?.title
                 ?? NSLocalizedString("적용된 배경 없음", comment: "하단 바 — 적용된 배경이 없을 때 제목"))
                .font(Typography.bodyEmphasis)
                .lineLimit(1)
            Text(NowPlayingSubtitle.text(typeRaw: appliedEntry?.typeRaw,
                                         playlistCount: viewModel.playlist.ids.count,
                                         intervalMinutes: viewModel.playlist.intervalMinutes,
                                         playlistEnabled: viewModel.playlist.enabled))
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: Self.textMaxWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thumb: some View {
        Group {
            if let e = appliedEntry, let url = viewModel.previewURL(for: e) {
                AnimatedPreviewView(url: url, animating: !viewModel.isPaused).scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ColorRole.placeholderFill)
            }
        }
        .frame(width: Metrics.nowPlayingThumb, height: Metrics.nowPlayingThumb)
        .clipShape(RoundedRectangle(cornerRadius: Surface.thumbCorner))
        // 바로 옆 텍스트가 같은 정보를 말한다 — 보조기술에 두 번 읽히지 않게 장식으로 감춘다.
        .accessibilityHidden(true)
    }

    /// 음량/배속 메뉴(w5d-settings-ia). F820 으로 리마운트 없는 라이브 반영이 됐지만, 연속
    /// 슬라이더는 드래그 틱마다 UserDefaults 쓰기+플레이어 조정을 유발하므로 이산 스텝 유지 —
    /// SettingsPresentation 의 기존 스텝을 재사용해 설정 창과 동일한 값 집합(저장값 호환).
    /// 대상은 videoTargetIds()(모니터별 할당 포함, 설정 창과 동일 소스).
    /// 배속 섹션 노출 — 동영상일 때만. 음량은 씬에도 열려 있다(showsVolumeControl).
    private var showsRate: Bool {
        NowPlayingSubtitle.showsVideoControls(typeRaw: appliedEntry?.typeRaw)
    }

    private var videoControlsMenu: some View {
        Menu {
            Section("음량") {
                ForEach(SettingsPresentation.volumeSteps, id: \.value) { step in
                    Button {
                        applyToVideoTargets { VideoSettings.setVolume(step.value, id: $0) }
                    } label: {
                        if step.value == currentVideoVolume {
                            Label(step.label, systemImage: "checkmark")
                        } else {
                            Text(step.label)
                        }
                    }
                }
            }
            // 배속은 동영상 전용이다 — SceneAudioPlayer 에 배속 개념이 없고, 씬에 노출하면
            // 눌러도 아무 일이 없는 컨트롤이 된다(이 메뉴를 씬에 연 이유가 음량 하나다).
            if showsRate {
                Section("배속") {
                    ForEach(SettingsPresentation.rateSteps, id: \.value) { step in
                        Button {
                            applyToVideoTargets { VideoSettings.setRate(step.value, id: $0) }
                        } label: {
                            if step.value == currentVideoRate {
                                Label(step.label, systemImage: "checkmark")
                            } else {
                                Text(step.label)
                            }
                        }
                    }
                }
            }
        } label: {
            // [2026-08-25] **삼항으로 String 을 고르면 안 된다** — 이 파일 :125 가 스스로 적어 둔
            // 규약인데 여기서 어기고 있었다. `Label(_ title: String, systemImage:)` 는 `String` 을
            // 받는 **비현지화 오버로드**라, 삼항이 만든 `String` 은 `LocalizedStringKey` 로 해석되지
            // 않는다. 두 문자열 다 en.lproj 에 번역이 있는데도(`"음량" = "Volume";` 외) 영어
            // 시스템에서 **한국어가 그대로 뜬다**. `.labelStyle(.iconOnly)` 라 이 문구는 화면이
            // 아니라 **접근성 이름**으로 읽히므로, 증상은 VoiceOver 사용자에게만 보인다.
            //
            // `LocalizationCoverageTests` 도 이걸 못 잡는다 — 두 문자열이 각각 :225 `Section("음량")`
            // 과 :263 `.help("동영상 음량 · 배속")` 에서 **우연히** 추출되기 때문이다. 즉 번역은
            // 있는데 이 자리만 안 쓰는 상태였고, 커버리지 오라클은 초록이었다.
            let icon = currentVideoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            if showsRate {
                Label("동영상 음량 · 배속", systemImage: icon).font(.title3)
            } else {
                Label("음량", systemImage: icon).font(.title3)
            }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("동영상 음량 · 배속")
    }

    private var currentVideoVolume: Float? {
        NowPlayingSubtitle.commonValue(viewModel.videoTargetIds().map { VideoSettings.volume(id: $0) })
    }
    private var currentVideoRate: Float? {
        NowPlayingSubtitle.commonValue(viewModel.videoTargetIds().map { VideoSettings.rate(id: $0) })
    }

    /// 현재 적용 중인 모든 동영상 대상(모니터별 할당 포함)에 변경을 저장하고 라이브 반영을 태운다
    /// (F820 — 리마운트 없이 AVPlayer.volume/defaultRate 직접 조정, 재생 리셋 없음).
    private func applyToVideoTargets(_ mutate: (String) -> Void) {
        let ids = viewModel.videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach(mutate)
        viewModel.onVideoSettingsChanged?()
    }

    /// 재생목록 관리: 자동 전환·간격 + 선택 항목 추가/제거 + 목록.
    private var playlistPopover: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // playlist(PlaylistStore)는 @Published 가 아니라 직접 mutate 만으로는 body(간격 라벨·부제)가
            // 재평가되지 않는다 — togglePlaylist 전례처럼 owning VM 에 objectWillChange 를 쏘아 갱신을 건다.
            Toggle("자동 전환", isOn: Binding(
                get: { viewModel.playlist.enabled },
                set: { viewModel.playlist.enabled = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }))
            Stepper(String(format: NSLocalizedString("간격: %lld분", comment: "재생목록 전환 간격"),
                            viewModel.playlist.intervalMinutes), value: Binding(
                get: { viewModel.playlist.intervalMinutes },
                set: { viewModel.playlist.intervalMinutes = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }), in: 1...240)
            // w5d-playback: 고정 순서만 순환하던 자동 전환에 무작위 순서 옵션 추가.
            Toggle("셔플(무작위 순서)", isOn: Binding(
                get: { viewModel.playlist.shuffle },
                set: { viewModel.playlist.shuffle = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }))
            if let focused = viewModel.focusedEntry {
                // 종전엔 문자열 보간으로 라벨을 만들어 번역이 조용히 사라졌다(비현지화 오버로드).
                // 포맷 지정자로 조립해 en.lproj 키를 고정한다.
                Button { viewModel.togglePlaylist(focused) } label: {
                    Text(playlistToggleLabel(for: focused))
                }
            }
            Divider()
            if viewModel.playlist.ids.isEmpty {
                Text("재생목록이 비어 있습니다 — 타일 우클릭 또는 위 버튼으로 추가하세요")
                    .font(Typography.caption).foregroundStyle(.secondary)
            } else {
                // [2026-08-25] 목록이 **읽기 전용**이었다. 추가는 타일 우클릭·위 버튼 둘로 되는데
                // 제거는 "그 항목을 다시 찾아 우클릭" 밖에 없었다 — 목록을 보면서 지울 수 없다.
                // 여기 제거 버튼을 둔다(추가와 같은 `togglePlaylist` 를 쓴다).
                //
                // **고아 id**: 라이브러리에서 지워진 배경이 재생목록에 남아 있으면 `entries` 에서
                // 찾을 수 없다. 그때는 제목 대신 id 를 보여주고(종전과 동일) 버튼은 비활성으로 둔다 —
                // `togglePlaylist` 는 `LibraryEntry` 를 받으므로 부를 대상이 없다. 비활성 버튼이
                // 아무 일도 안 하는 버튼보다 낫다.
                ForEach(viewModel.playlist.ids, id: \.self) { id in
                    let entry = viewModel.entries.first { $0.id == id }
                    HStack(spacing: Space.controlGap) {
                        Text(entry?.title ?? id)
                            .font(Typography.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            if let entry { viewModel.togglePlaylist(entry) }
                        } label: {
                            Label("재생목록에서 제거", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(entry == nil)
                        .help("재생목록에서 제거")
                    }
                }
            }
        }
        .padding(Space.panelInset)
        .frame(width: Self.playlistPopoverWidth)
    }

    private func playlistToggleLabel(for entry: LibraryEntry) -> String {
        let format = viewModel.isInPlaylist(entry)
            ? NSLocalizedString("'%@' 재생목록에서 제거", comment: "재생목록 토글 버튼")
            : NSLocalizedString("'%@' 재생목록에 추가", comment: "재생목록 토글 버튼")
        return String(format: format, entry.title)
    }

    /// '가져오기' = 디스크에서 임포트(WallpaperGridView 와 공유하는 ImportPanel — 폴더/zip/동영상).
    private func openWallpaperPanel() {
        ImportPanel.run(into: viewModel)
    }
}
