import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleLibrary

/// 다이어그램/레일 썸네일(감사 V06) — WallpaperGridView.PreviewImageCache 의 F500 패턴 재사용:
/// 조회는 cached()(동기, body 평가 중 디스크 읽기 없음), 최초 디코드는 .task 의 load()(백그라운드).
/// 종전 전용 DisplaysImageCache(F498)는 body 평가 중 메인 스레드 동기 NSImage(contentsOf:) 디코드였다
/// (당시 주석의 "PreviewImageCache 는 file-private" 주장은 스테일 — 실제로는 internal 단위 테스트 대상).
private struct DisplaysThumbView: View {
    let url: URL
    var placeholderFont: Font = .title2
    @State private var image: NSImage?

    init(url: URL, placeholderFont: Font = .title2) {
        self.url = url
        self.placeholderFont = placeholderFont
        _image = State(initialValue: PreviewImageCache.cached(url))   // NSCache 조회만 — 디스크 읽기 없음
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                    Image(systemName: "photo").font(placeholderFont).foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            image = await PreviewImageCache.load(url)
        }
    }
}

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
                Label("디스플레이", systemImage: "display.2").font(.title3.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            GeometryReader { geo in
                let _ = screensGeneration   // F497: 변경 시 재평가되도록 body 가 의존
                let screens = viewModel.screens
                let rects = DisplayDiagramLayout.rects(screenFrames: screenFrames(),
                                                       container: geo.size, padding: 28)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(screens, rects)), id: \.0.key) { screen, rect in
                        monitorBox(screen: screen, rect: rect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            statusRow.padding(.horizontal, 14).padding(.top, 10)
            assignmentRail
        }
        .frame(minWidth: Metrics.displaysMin.width, minHeight: Metrics.displaysMin.height)
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
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text(assigned?.title ?? "전역 배경")
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.tileCorner)
            .stroke(dropTargeted ? Color.accentColor : (selected ? Color.accentColor : Color(nsColor: .separatorColor)),
                    lineWidth: dropTargeted ? 4 : (selected ? 3 : 1)))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
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

    /// 할당 배경 썸네일(gif 는 정지 첫 프레임 — 다이어그램은 배치 확인 용도). 미할당(entry==nil)이면
    /// 실제 전역 배경(viewModel.globalEntry) 미리보기로 폴백해 살짝 디밍 렌더(w5d-displays) — 다이어그램이
    /// "그 화면에 실제로 표시 중인" 배경을 보여주게 한다("전역 배경" 라벨은 기존 그대로 유지).
    /// 전역도 없으면(둘 다 nil) 플레이스홀더.
    @ViewBuilder
    private func thumbnail(for entry: LibraryEntry?, dimmed: Bool = false) -> some View {
        let resolved = entry ?? viewModel.globalEntry
        Group {
            if let resolved, let url = viewModel.previewURL(for: resolved) {
                DisplaysThumbView(url: url)
            } else {
                ZStack {
                    Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: Metrics.gap) {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key).font(.callout.weight(.semibold))
                Text("아래에서 배경을 클릭하거나 박스로 드래그하면 바로 적용됩니다")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntry(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 22)
    }

    /// 시트 내 배경 선택 레일(w5d-displays) — viewModel.entries + previewURL 재사용. 모니터 선택 후
    /// 썸네일 클릭(또는 다이어그램 박스로 드래그) = 그 화면에 즉시 assign. 그리드 왕복도, focusedEntry
    /// 의존(오적용 풋건)도 없다.
    private var assignmentRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Metrics.gap) {
                ForEach(viewModel.entries, id: \.id) { entry in
                    railTile(entry)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Metrics.gap)
        }
        .frame(height: 92)
        .background(.bar)
    }

    @ViewBuilder
    private func railTile(_ entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let assignedHere = selectedScreenKey.flatMap { viewModel.assignedEntry(forScreen: $0)?.id } == entry.id
        VStack(spacing: 3) {
            railThumbnail(entry)
                .frame(width: 74, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(assignedHere ? Color.accentColor : .clear, lineWidth: 2))
            Text(entry.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 74)
        .opacity(supported ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard supported, let key = selectedScreenKey else { return }
            viewModel.assign(entry, toScreen: key)
        }
        .onDrag { NSItemProvider(object: entry.id as NSString) }
        .help(supported ? entry.title
              : String(format: NSLocalizedString("%@ — 지원 예정", comment: "미지원 항목 툴팁"), entry.title))
    }

    @ViewBuilder
    private func railThumbnail(_ entry: LibraryEntry) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            DisplaysThumbView(url: url, placeholderFont: .caption)
        } else {
            ZStack {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                Image(systemName: "photo").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
