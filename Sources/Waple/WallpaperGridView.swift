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

/// 설치됨 탭 좌측 그리드: 클릭=선택(패널), 더블클릭=적용, 호버=gif 재생+제목. WE 브라우저 재현.
struct WallpaperGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var hoveredId: String?

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.filteredEntries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding(12)
                }
                .background(WETheme.Colors.window)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("라이브러리가 비어 있습니다").font(.title3)
            Text("Wallpaper Engine 폴더·zip·동영상을 드래그하거나 가져오세요.").foregroundColor(.secondary)
            Button("폴더 가져오기…") { importFolder() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WETheme.Colors.window)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let focused = viewModel.focusedId == entry.id
        let applied = viewModel.selectedId == entry.id
        let hovered = hoveredId == entry.id
        ZStack(alignment: .bottomLeading) {
            preview(for: entry, animating: hovered)
                .frame(height: 110).frame(maxWidth: .infinity).clipped()
            // 하단 그라데이션 + 제목(WE 타일) — 호버/포커스에서만 노출.
            if hovered || focused {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44).frame(maxHeight: .infinity, alignment: .bottom)
                Text(entry.title).font(.caption).bold().foregroundColor(.white)
                    .lineLimit(1).padding(6)
            }
            // 타입/상태 뱃지(우상단)
            VStack(alignment: .trailing, spacing: 3) {
                badge(badgeText(for: entry, supported: supported), color: supported ? Color.accentColor : .gray)
                if applied { badge("적용됨", color: .green) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
        }
        .cornerRadius(8)
        .opacity(supported ? 1.0 : 0.5)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(focused ? Color.accentColor : (applied ? Color.green.opacity(0.7) : Color.clear), lineWidth: 2))
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { if supported { _ = viewModel.apply(entry) } }
        .onTapGesture { viewModel.focusedId = entry.id }
        .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color).foregroundColor(.white).cornerRadius(4)
    }

    private func badgeText(for entry: LibraryEntry, supported: Bool) -> String {
        guard supported else { return "지원 예정" }
        let type = WallpaperType.from(entry.typeRaw)
        return type == .scene ? "scene · 부분" : type.storageString
    }

    @ViewBuilder
    private func preview(for entry: LibraryEntry, animating: Bool) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            if PreviewMedia.isAnimated(url) {
                AnimatedPreviewView(url: url, animating: animating)
            } else if let image = PreviewImageCache.image(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
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

    // MARK: 임포트(기존 LibraryView에서 이동 — 로직 무변경)

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
