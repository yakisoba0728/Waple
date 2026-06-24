import SwiftUI
import AppKit
import WapleLibrary

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
                Text(supported ? entry.typeRaw : "지원 예정")
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

    @ViewBuilder
    private func previewImage(for entry: LibraryEntry) -> some View {
        if let url = viewModel.previewURL(for: entry), let image = NSImage(contentsOf: url) {
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
