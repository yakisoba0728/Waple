import SwiftUI
import AppKit
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

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Waple 라이브러리").font(.headline)
                Spacer()
                Button("폴더 가져오기…") { importFolder() }
            }
            .padding()

            if viewModel.entries.isEmpty {
                Spacer()
                Text("‘폴더 가져오기…’로 Wallpaper Engine 폴더를 추가하세요.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.entries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                previewImage(for: entry)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)
                Text(badgeText(for: entry, supported: supported))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(supported ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(6)
            }
            Text(entry.title).font(.caption).lineLimit(1)
        }
        .opacity(supported ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if supported { viewModel.apply(entry) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(viewModel.selectedId == entry.id ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func badgeText(for entry: LibraryEntry, supported: Bool) -> String {
        guard supported else { return "지원 예정" }
        let type = WallpaperType.from(entry.typeRaw)
        return type == .scene ? "scene · 부분" : type.storageString
    }

    @ViewBuilder
    private func previewImage(for entry: LibraryEntry) -> some View {
        // SwiftUI body 는 선택 변경 등으로 자주 재평가된다. 디코드된 이미지를 캐시해
        // 매 렌더마다 디스크 읽기+디코드가 반복되지 않게 한다.
        if let url = viewModel.previewURL(for: entry), let image = PreviewImageCache.image(url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더(또는 여러 배경을 담은 상위 폴더)를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importParent(url)
        }
    }
}
