import SwiftUI
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

/// WE 디스플레이 화면: 모니터 배치 다이어그램 + 선택 모니터에 배경 할당/해제.
struct DisplaysTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var selectedScreenKey: String?
    /// AppDelegate 주입 — NSScreen 프레임(키 순서는 viewModel.screens와 동일해야 함).
    var screenFrames: () -> [CGRect]

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let screens = viewModel.screens
                let rects = DisplayDiagramLayout.rects(screenFrames: screenFrames(),
                                                       container: geo.size, padding: 24)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(screens, rects)), id: \.0.key) { screen, rect in
                        monitorBox(screen: screen, rect: rect)
                    }
                }
            }
            actionBar
        }
        .padding()
        .onAppear { if selectedScreenKey == nil { selectedScreenKey = viewModel.screens.first?.key } }
    }

    @ViewBuilder
    private func monitorBox(screen: (key: String, name: String), rect: CGRect) -> some View {
        let selected = selectedScreenKey == screen.key
        VStack(spacing: 4) {
            Text(screen.name).font(.headline).lineLimit(1)
            Text(viewModel.assignedEntryTitle(forScreen: screen.key) ?? "전역 배경").font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(width: rect.width, height: rect.height)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
        .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key).bold()
                Spacer()
                Button("선택한 배경 적용") {
                    if let entry = viewModel.focusedEntry { viewModel.assign(entry, toScreen: key) }
                }
                .disabled(viewModel.focusedEntry == nil || !(viewModel.focusedEntry.map(viewModel.isSupported) ?? false))
                .help("설치됨 탭에서 배경을 먼저 선택하세요")
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntryTitle(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundColor(.secondary)
            }
        }
        .frame(height: 28)
    }
}
