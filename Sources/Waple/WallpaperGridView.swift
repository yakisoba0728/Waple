import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleCore
import WapleLibrary

/// 미리보기 이미지 디코드 캐시(URL→NSImage). body 재평가마다의 반복 디스크 I/O 제거.
private enum PreviewImageCache {
    private static let cache = NSCache<NSURL, NSImage>()
    static func image(_ url: URL) -> NSImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// 네이티브 그리드: underPage 우물 + 라운드 썸네일 타일(제목 아래) + 호버 라이브 프리뷰/리프트 +
/// 적용 중 액센트 링. 클릭=선택, 더블클릭=적용(기존 UX 유지).
struct WallpaperGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var hoveredId: String?

    private let columns = [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing)]

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing + 6) {
                        ForEach(viewModel.filteredEntries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("라이브러리가 비어 있습니다").font(.title3.weight(.semibold))
            Text("Wallpaper Engine 폴더·zip·동영상을 드래그하거나 가져오세요")
                .font(.callout).foregroundStyle(.secondary)
            Button("배경화면 가져오기…") { importFolder() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let focused = viewModel.focusedId == entry.id
        let applied = viewModel.selectedId == entry.id
        let hovered = hoveredId == entry.id

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                preview(for: entry, animating: hovered)
                    .frame(height: Metrics.tileThumbHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .stroke(applied ? Color.accentColor : (focused ? Color.secondary.opacity(0.6) : .clear),
                            lineWidth: applied ? 2.5 : 1.5)
            )
            .overlay(alignment: .topTrailing) { typeBadge(for: entry, supported: supported) }
            .overlay(alignment: .bottomLeading) {
                if applied {
                    Image(systemName: "play.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .saturation(supported ? 1 : 0.4)
            .opacity(supported ? 1 : 0.55)

            Text(entry.title)
                .font(.caption)
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.45 : 0), radius: 9, y: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { if supported { _ = viewModel.apply(entry) } }
        .onTapGesture { viewModel.focusedId = entry.id }
        .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    private func typeBadge(for entry: LibraryEntry, supported: Bool) -> some View {
        Label(supported ? NowPlayingSubtitle.typeLabel(entry.typeRaw) : "지원 예정",
              systemImage: typeSymbol(entry.typeRaw))
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
    }

    private func typeSymbol(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return "sparkles"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        case .preset: return "square.stack"
        case .application, .unknown: return "questionmark.circle"
        }
    }

    @ViewBuilder
    private func preview(for entry: LibraryEntry, animating: Bool) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            if PreviewMedia.isAnimated(url) {
                AnimatedPreviewView(url: url, animating: animating)
            } else if let image = PreviewImageCache.image(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholderThumb
            }
        } else {
            placeholderThumb
        }
    }

    private var placeholderThumb: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry, supported: Bool) -> some View {
        Button("선택(속성 보기)") { viewModel.focusedId = entry.id }
        if supported { Button("적용") { _ = viewModel.apply(entry) } }
        if WallpaperType.from(entry.typeRaw) == .web {
            Button("적용 + 조작 창 열기") { _ = viewModel.apply(entry); viewModel.onOpenInteraction?() }
        }
        if supported {
            Button(viewModel.isInPlaylist(entry) ? "재생목록에서 제거" : "재생목록에 추가") { viewModel.togglePlaylist(entry) }
            Menu("모니터에 적용") {
                ForEach(viewModel.screens, id: \.key) { screen in
                    Button(screen.name + (viewModel.assignedEntryTitle(forScreen: screen.key).map { " (현재: \($0))" } ?? "")) {
                        viewModel.assign(entry, toScreen: screen.key)
                    }
                }
                if viewModel.screens.contains(where: { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }) {
                    Divider()
                    ForEach(viewModel.screens.filter { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }, id: \.key) { screen in
                        Button("\(screen.name) 할당 해제") { viewModel.clearAssignment(forScreen: screen.key) }
                    }
                }
            }
        }
    }

    // MARK: 임포트(로직 무변경)

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더·상위 폴더·.zip·동영상(mp4/mov)을 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { routeImport(url) }
    }

    private func routeImport(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { viewModel.importZip(url) }
        else if VideoImport.isVideoFile(url) { viewModel.importVideoFile(url) }
        else { viewModel.importParent(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURL = UTType.fileURL.identifier
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURL) {
            handled = true
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.routeImport(url) }
            }
        }
        return handled
    }
}
