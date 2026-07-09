import AppKit
import SwiftUI
import WapleCore
import WapleLibrary

extension LibraryEntry: Identifiable {}

/// 배경별 유저 속성 편집 시트(WE 속성 패널 대응). 변경 즉시 저장 + 현재 배경이면 재적용.
struct PropertyEditorView: View {
    let entry: LibraryEntry
    @ObservedObject var viewModel: LibraryViewModel
    @State private var props: [WallpaperProperty] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entry.title) — 속성").font(.headline)
                Spacer()
                Button("초기화") {
                    viewModel.resetProperties(for: entry)
                    props = viewModel.editableProperties(for: entry)
                }
                Button("닫기") { viewModel.propertyEditorEntry = nil }
            }
            .padding()
            Divider()
            if props.isEmpty {
                Spacer()
                Text("이 배경에는 편집 가능한 속성이 없습니다.").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(PropertyDecoration.visibleIndices(in: props), id: \.self) { i in
                            control(for: i)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { props = viewModel.editableProperties(for: entry) }
    }

    private func label(_ p: WallpaperProperty) -> String {
        // WE 라벨은 HTML 조각을 담기도 한다 — 태그 제거해 평문 표시.
        let raw = p.text ?? p.key
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ i: Int, _ value: PropertyValue) {
        props[i].value = value
        viewModel.setProperty(key: props[i].key, value: value, for: entry)
    }

    @ViewBuilder
    private func control(for i: Int) -> some View {
        let p = props[i]
        switch PropertyControl.kind(forType: p.type) {
        case .toggle:
            Toggle(label(p), isOn: Binding(
                get: { if case .bool(let b) = props[i].value { return b }; return false },
                set: { commit(i, .bool($0)) }))
        case .slider:
            VStack(alignment: .leading, spacing: 2) {
                let v = { if case .number(let n) = props[i].value { return n }; return 0 }()
                Text("\(label(p)): \(String(format: "%.2f", v))").font(.caption)
                Slider(value: Binding(
                    get: { if case .number(let n) = props[i].value { return n }; return 0 },
                    set: { commit(i, .number($0)) }),
                    in: PropertyControl.sliderRange(min: p.min, max: p.max))
            }
        case .picker:
            Picker(label(p), selection: Binding(
                get: { props[i].value },
                set: { commit(i, $0) })) {
                ForEach(Array((p.options ?? []).enumerated()), id: \.offset) { _, opt in
                    Text(opt.label).tag(opt.value)
                }
            }
        case .color:
            ColorPicker(label(p), selection: Binding(
                get: {
                    if case .string(let s) = props[i].value {
                        let f = s.split(separator: " ").compactMap { Double($0) }
                        if f.count >= 3 { return Color(red: f[0], green: f[1], blue: f[2]) }
                    }
                    return .white
                },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    commit(i, .string(String(format: "%.5f %.5f %.5f", ns.redComponent, ns.greenComponent, ns.blueComponent)))
                }), supportsOpacity: false)
        case .textInput:
            HStack {
                Text(label(p)).font(.caption)
                TextField("", text: Binding(
                    get: { if case .string(let s) = props[i].value { return s }; return "" },
                    set: { props[i].value = .string($0) }))
                .onSubmit { viewModel.setProperty(key: props[i].key, value: props[i].value, for: entry) }
            }
        case .file:
            resourcePicker(for: i, directory: false)
        case .directory:
            resourcePicker(for: i, directory: true)
        case .displayOnly:
            Text(label(p)).font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func resourcePicker(for i: Int, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label(props[i])).font(.caption)
                Spacer()
                Button {
                    chooseResource(for: i, directory: directory)
                } label: {
                    Label("선택", systemImage: directory ? "folder" : "doc")
                }
                if selectedPath(props[i]) != nil {
                    Button {
                        commit(i, .string(""))
                    } label: {
                        Label("지우기", systemImage: "xmark")
                    }
                }
            }
            if let path = selectedPath(props[i]), !path.isEmpty {
                Text(path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func selectedPath(_ property: WallpaperProperty) -> String? {
        guard case .string(let path) = property.value else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func chooseResource(for i: Int, directory: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            commit(i, .string(url.path))
        }
    }
}
