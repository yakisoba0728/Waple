import SwiftUI
import AppKit
import WapleLibrary

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
/// 썸네일을 채우고, 클릭 선택 → 하단 액션(선택 배경 적용/할당 해제).
struct DisplaysView: View {
    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenKey: String?

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
            actionBar.padding(12)
        }
        .frame(minWidth: Metrics.displaysMin.width, minHeight: Metrics.displaysMin.height)
        .onAppear { if selectedScreenKey == nil { selectedScreenKey = viewModel.screens.first?.key } }
    }

    @ViewBuilder
    private func monitorBox(screen: (key: String, name: String), rect: CGRect) -> some View {
        let selected = selectedScreenKey == screen.key
        let assigned = viewModel.assignedEntry(forScreen: screen.key)
        ZStack(alignment: .bottomLeading) {
            thumbnail(for: assigned)
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
            .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
        .offset(x: rect.minX, y: rect.minY)
    }

    /// 할당 배경 썸네일(gif 는 정지 첫 프레임 — 다이어그램은 배치 확인 용도). 없으면 플레이스홀더.
    @ViewBuilder
    private func thumbnail(for entry: LibraryEntry?) -> some View {
        if let entry, let url = viewModel.previewURL(for: entry), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: Metrics.gap) {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key).font(.callout.weight(.semibold))
                if viewModel.focusedEntry == nil {
                    Text("설치됨 탭에서 배경을 먼저 선택하세요").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let entry = viewModel.focusedEntry { viewModel.assign(entry, toScreen: key) }
                } label: {
                    Label(applyLabel, systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.focusedEntry == nil
                          || !(viewModel.focusedEntry.map(viewModel.isSupported) ?? false))
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntry(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 30)
    }

    private var applyLabel: String {
        viewModel.focusedEntry.map { "'\($0.title)' 적용" } ?? "선택한 배경 적용"
    }
}
