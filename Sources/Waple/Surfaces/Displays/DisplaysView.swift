import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleLibrary

// 다이어그램/레일 썸네일(감사 V06)은 종전 이 파일의 DisplaysThumbView 였다. 2026-08-17 개편에서
// 같은 F500 패턴의 그리드 쪽 복제와 함께 DesignSystem/Components/PreviewThumbnail 로 합쳤다 —
// 두 벌이 갈라져 플레이스홀더 채움이 이미 0.25 와 0.3 으로 어긋나 있었다.

/// NSScreen.frames(하단 원점) → 컨테이너 좌표(상단 원점) 비례 배치. 순수 함수 — 유닛 테스트 대상.
enum DisplayDiagramLayout {
    static func rects(screenFrames: [CGRect], container: CGSize, padding: CGFloat) -> [CGRect] {
        guard !screenFrames.isEmpty else { return [] }
        let union = screenFrames.dropFirst().reduce(screenFrames[0]) { $0.union($1) }
        let availW = max(1, container.width - padding * 2)
        let availH = max(1, container.height - padding * 2)
        let s = min(availW / union.width, availH / union.height)
        let offX = padding + (availW - union.width * s) / 2
        let offY = padding + (availH - union.height * s) / 2
        return screenFrames.map { f in
            // AppKit y(하단 기준) → 다이어그램 y(상단 기준): union 상단으로부터의 거리로 뒤집는다.
            let topDistance = union.maxY - f.maxY
            return CGRect(x: offX + (f.minX - union.minX) * s,
                          y: offY + topDistance * s,
                          width: f.width * s, height: f.height * s)
        }
    }
}

/// 디스플레이 화면(WE 디스플레이 선택의 네이티브 번역): 모니터 배치 다이어그램에 할당 배경
/// 썸네일을 채우고, 클릭 선택 → 하단 레일에서 배경 클릭/드래그로 즉시 할당(w5d-displays — 시트
/// 내 완결). 종전엔 "적용" 버튼이 그리드(시트 밖 상태)의 focusedEntry 에 의존해, 모달로 열린
/// 시트 안에서는 다른 배경을 고를 방법이 없고(왕복 강제) 오적용 풋건도 있었다.
struct DisplaysView: View {
    /// 시트의 이상 크기·상한. `Metrics` 는 Phase 0 이후 동결이라 이 화면 전용 상수는 여기 산다.
    ///
    /// **이상 폭을 명시하는 것이 팽창 결함(청사진 §9.1)을 끊는 수단이다.** 종전에는 루트에
    /// `minWidth` 만 있어서, 시트가 자기 폭을 물으면 아래 레일이 그 답을 대신 했다 —
    /// `ScrollView(.horizontal)` 은 스크롤 축의 이상 크기로 **콘텐츠의 이상 크기를 그대로 위로
    /// 전파**하므로, 라이브러리 항목 수 × 타일 폭이 곧 시트의 이상 폭이 됐다.
    /// 2026-08-17 실측으로 이 기전을 확정했다: 같은 빌드에서 라이브러리 200개 → 시트
    /// 1800×560(= 화면 폭에 걸려 잘린 값), 5개 → 860×560(= `displaysMin` 그대로).
    /// 항목 수가 폭을 바꾸는 것이 곧 전파의 증거다.
    ///
    /// 그래서 레일 쪽을 고치는 대신 **루트가 자기 이상 크기를 스스로 말하게** 한다. 레일에
    /// 상한을 씌우는 방식은 스크롤되는 자식이 하나 더 생기면 같은 결함이 되돌아온다.
    static let idealWidth: CGFloat = 960
    static let idealHeight: CGFloat = 620
    /// 모달 시트는 부모 창보다 커서는 안 된다 — 부모의 최소 폭이 상한의 근거다.
    static let maxWidth: CGFloat = Metrics.windowMin.width
    static let maxHeight: CGFloat = Metrics.windowMin.height

    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenKey: String?
    @State private var dropTargetKey: String?
    /// F497: 시트가 열린 동안의 모니터 구성 변경을 반영하기 위한 재평가 트리거 — screens /
    /// screenFrames() 는 body 재평가 시에만 다시 읽힌다.
    @State private var screensGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: Text("디스플레이"), symbol: "display.2")
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Space.panelInset)
            Divider()
            GeometryReader { geo in
                let _ = screensGeneration   // F497: 변경 시 재평가되도록 body 가 의존
                let screens = viewModel.screens
                let rects = DisplayDiagramLayout.rects(screenFrames: screenFrames(),
                                                       container: geo.size,
                                                       padding: Metrics.diagramPadding)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(screens, rects)), id: \.0.key) { screen, rect in
                        monitorBox(screen: screen, rect: rect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(ColorRole.well)
            Divider()
            statusRow.padding(.horizontal, Space.panelInset).padding(.top, Space.md)
            assignmentRail
        }
        .frame(minWidth: Metrics.displaysMin.width,
               idealWidth: Self.idealWidth,
               maxWidth: Self.maxWidth,
               minHeight: Metrics.displaysMin.height,
               idealHeight: Self.idealHeight,
               maxHeight: Self.maxHeight)
        .onAppear { if selectedScreenKey == nil { selectedScreenKey = viewModel.screens.first?.key } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // F497: AppDelegate 의 rebuild 가 0.5초 디바운스로 뒤따르므로, 그 직후에 읽도록 살짝 늦게 갱신.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { screensGeneration += 1 }
        }
    }

    @ViewBuilder
    private func monitorBox(screen: (key: String, name: String), rect: CGRect) -> some View {
        let selected = selectedScreenKey == screen.key
        let dropTargeted = dropTargetKey == screen.key
        let assigned = viewModel.assignedEntry(forScreen: screen.key)
        ZStack(alignment: .bottomLeading) {
            thumbnail(for: assigned, dimmed: assigned == nil)
                .frame(width: rect.width, height: rect.height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(ColorRole.mediaScrimOpacity)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: Space.hairline) {
                Text(screen.name).font(Typography.bodyEmphasis).foregroundStyle(ColorRole.onMedia)
                assignedLabel(assigned)
                    .font(Typography.caption).foregroundStyle(ColorRole.onMediaSecondary).lineLimit(1)
            }
            .padding(Space.md)
        }
        .frame(width: rect.width, height: rect.height)
        .tileThumbnailClip(corner: Surface.tileCorner)
        .tileRing(TileRing.surface(dropTargeted: dropTargeted, selected: selected))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
        // 종전 이 다이어그램은 드래그(또는 마우스 클릭) 전용이라 키보드·보조기술로는 모니터를
        // 고를 방법이 아예 없었다. label 은 모니터 이름, value 는 지금 그 화면에 뜨는 배경이다
        // (청사진 §4.2). isSelected 는 위 링의 `selected` 와 **같은 조건**이어야 한다.
        .tileAccessibility(label: Text(screen.name),
                           value: assignedLabel(assigned),
                           isSelected: selected,
                           onActivate: { selectedScreenKey = screen.key })
        // 목표 인터랙션(w5d-displays): 레일 썸네일을 다이어그램 박스로 직접 드래그해 즉시 지정.
        // WallpaperGridView.handleDrop 과 동일하게 NSItemProvider 로드 → 메인 스레드에서 반영.
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTargetKey == screen.key },
            set: { dropTargetKey = $0 ? screen.key : (dropTargetKey == screen.key ? nil : dropTargetKey) }
        )) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { reading, _ in
                guard let id = reading as? String else { return }
                DispatchQueue.main.async {
                    guard let entry = viewModel.supportedEntry(forId: id) else { return }
                    selectedScreenKey = screen.key
                    viewModel.assign(entry, toScreen: screen.key)
                }
            }
            return true
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    /// 모니터 박스가 읽는 "지금 이 화면의 배경". 할당이 있으면 그 제목(런타임 데이터라 번역
    /// 대상이 아니다), 없으면 고정 문구다.
    ///
    /// **삼항으로 `String` 을 고르면 안 된다.** `Text(assigned?.title ?? "전역 배경")` 은
    /// `Text(_: some StringProtocol)` 오버로드로 해석돼 "전역 배경" 이 조용히 번역되지 않고,
    /// 리터럴이 `Text(` 바로 뒤에 오지 않아 커버리지 스캔에도 안 걸린다(청사진 §5.0·§5.3).
    /// `Text` 자체를 골라 넘기면 두 문제가 함께 사라지고, 접근성 value 와 화면 표시가 같은
    /// 한 벌을 쓰게 된다.
    private func assignedLabel(_ entry: LibraryEntry?) -> Text {
        entry.map { Text($0.title) } ?? Text("전역 배경")
    }

    /// 할당 배경 썸네일(gif 는 정지 첫 프레임 — 다이어그램은 배치 확인 용도). 미할당(entry==nil)이면
    /// 실제 전역 배경(viewModel.globalEntry) 미리보기로 폴백해 살짝 디밍 렌더(w5d-displays) — 다이어그램이
    /// "그 화면에 실제로 표시 중인" 배경을 보여주게 한다("전역 배경" 라벨은 기존 그대로 유지).
    /// 전역도 없으면(둘 다 nil) 플레이스홀더.
    ///
    /// `if let url` 분기를 없애고 nil 을 그대로 넘긴다. 분기가 남아 있으면 두 갈래가 서로 다른
    /// 뷰 정체성이라, 플레이스홀더 ↔ 그림 전환이 재마운트가 되고 `PreviewThumbnail` 이 스스로
    /// url 변경을 처리하는 경로(`reloadIfNeeded`)를 우회한다. 분기를 남겨 둔 것은 추출 커밋에서
    /// 정체성을 안 바꾸려던 흔적이었고, 합치는 것이 그 컴포넌트 문서가 지정한 다음 단계다.
    private func thumbnail(for entry: LibraryEntry?, dimmed: Bool = false) -> some View {
        let resolved = entry ?? viewModel.globalEntry
        return PreviewThumbnail(url: resolved.flatMap { viewModel.previewURL(for: $0) },
                                placeholderFont: .title2)
            .opacity(dimmed ? ColorRole.dimmedOpacity : 1)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: Space.controlGap) {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key)
                    .font(Typography.bodyEmphasis)
                Text("아래에서 배경을 클릭하거나 박스로 드래그하면 바로 적용됩니다")
                    .font(Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntry(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundStyle(.secondary)
                Spacer()
            }
        }
        // 고정 높이는 큰 글씨 설정에서 잘린다(청사진 §4.5) — 바닥만 정하고 넘치면 늘어나게 한다.
        .frame(minHeight: 22)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 시트 내 배경 선택 레일(w5d-displays) — viewModel.entries + previewURL 재사용. 모니터 선택 후
    /// 썸네일 클릭(또는 다이어그램 박스로 드래그) = 그 화면에 즉시 assign. 그리드 왕복도, focusedEntry
    /// 의존(오적용 풋건)도 없다.
    private var assignmentRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Space.controlGap) {
                ForEach(viewModel.entries, id: \.id) { entry in
                    railTile(entry)
                }
            }
            .padding(.horizontal, Space.panelInset)
            .padding(.vertical, Space.controlGap)
        }
        // 고정 높이(92) 대신 콘텐츠가 정하게 두고 바닥만 건다 — 큰 글씨 설정에서 캡션이 잘리던
        // 자리다(청사진 §4.5). fixedSize 가 없으면 세로로 유연한 ScrollView 가 VStack 의 남은
        // 공간을 전부 먹어 다이어그램이 찌그러진다.
        .frame(minHeight: Self.railMinHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Surface.chrome)
    }

    private static let railMinHeight: CGFloat = 92
    private static let railTileWidth: CGFloat = 74
    private static let railThumbHeight: CGFloat = 46

    @ViewBuilder
    private func railTile(_ entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let assignedHere = selectedScreenKey.flatMap { viewModel.assignedEntry(forScreen: $0)?.id } == entry.id
        VStack(spacing: Space.xxs) {
            railThumbnail(entry)
                .frame(width: Self.railTileWidth, height: Self.railThumbHeight)
                .tileThumbnailClip(corner: Surface.thumbCorner)
                .tileRing(TileRing.tile(selected: assignedHere, focused: false),
                          corner: Surface.thumbCorner)
            Text(entry.title).font(Typography.badge).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: Self.railTileWidth)
        .opacity(supported ? 1 : ColorRole.unsupportedOpacity)
        .contentShape(Rectangle())
        .onTapGesture { assign(entry, supported: supported) }
        .onDrag { NSItemProvider(object: entry.id as NSString) }
        .help(supported ? entry.title
              : String(format: NSLocalizedString("%@ — 지원 예정", comment: "미지원 항목 툴팁"), entry.title))
        // 툴팁은 포인터에게만 보인다. 미지원이라는 사실을 보조기술에도 같은 말로 전한다 —
        // 위 opacity 만으로는 전달되지 않는다(청사진 §4.2·§4.5).
        .tileAccessibility(label: Text(entry.title),
                           value: supported ? nil : Text("지원 예정"),
                           isSelected: assignedHere,
                           onActivate: { assign(entry, supported: supported) })
    }

    /// 레일 썸네일 활성화 = 선택된 모니터에 즉시 할당. 탭과 Return 이 같은 경로를 타야
    /// 키보드 사용자가 보는 결과와 마우스 사용자가 보는 결과가 갈리지 않는다.
    private func assign(_ entry: LibraryEntry, supported: Bool) {
        guard supported, let key = selectedScreenKey else { return }
        viewModel.assign(entry, toScreen: key)
    }

    /// 위 `thumbnail(for:dimmed:)` 과 같은 이유로 분기를 없앴다.
    private func railThumbnail(_ entry: LibraryEntry) -> some View {
        PreviewThumbnail(url: viewModel.previewURL(for: entry), placeholderFont: .caption)
    }
}
