import AppKit
import SwiftUI
import WapleCore
import WapleLibrary

// F502: 모듈 전역 retroactive conformance(extension LibraryEntry: Identifiable) 제거 — 사용처는
// 전부 명시적 id: 파라미터라 이 conformance 에 의존하지 않음. 향후 WapleLibrary 가 직접 채택할 때
// 중복 선언 빌드 오류를 만든다.

/// 속성 라벨 표시(순수): HTML 태그 제거 + 미번역 로컬라이즈 키(ui_*/스네이크 케이스) 정돈.
enum PropertyLabel {
    static func pretty(text: String?, key: String) -> String {
        var raw = (text?.isEmpty == false ? text! : key)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 미번역 키 감지: 공백 없이 [a-z0-9_] 만이고 '_' 포함 — 접두 제거 후 사람이 읽게.
        let keyLike = raw.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil && raw.contains("_")
        guard keyLike else { return raw }
        for prefix in ["ui_browse_properties_", "ui_properties_", "ui_"] where raw.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count))
            break
        }
        let words = raw.split(separator: "_").map(String.init)
        guard let first = words.first else { return raw }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// 감사 V06: ColorPicker 는 Slider 와 달리 editingChanged 콜백이 없어 컬러 패널 드래그 중 set 이
/// 연속 발화한다 — 매번 commit(setProperty → reapplyIfCurrent 전체 리마운트)하면 리마운트 스톰이
/// 되므로, 마지막 변경 뒤 1회만 실행되도록 취소·재예약하는 최소 디바운서(AppDelegate 화면 구성 변경
/// 디바운스와 동일 패턴). F494 슬라이더의 "드래그 중 로컬 값만, 종료 시 1회 커밋"과 동등한 효과.
final class CommitDebouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var work: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    /// 대기 중인 실행을 취소하고 delay 후 1회 실행을 재예약 — 연속 호출은 마지막 것만 실행된다.
    func schedule(_ action: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: action)
        work = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 대기 중인 실행 취소(즉시 커밋 경로와의 중복 발화 방지).
    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// 배경별 유저 속성 편집 시트(WE 속성 패널 대응). 변경 즉시 저장 + 현재 배경이면 재적용.
struct PropertyEditorView: View {
    let entry: LibraryEntry
    @ObservedObject var viewModel: LibraryViewModel
    @State private var props: [WallpaperProperty] = []
    /// textInput 미커밋 편집 추적 — Enter 없이 포커스 이동/시트 닫힘 시에도 커밋(변경 유실 방지).
    /// (키스트로크 커밋은 부적절: setProperty 가 현재 배경 리마운트를 유발.)
    @FocusState private var focusedText: Int?
    @State private var dirtyText = Set<Int>()
    /// F494: 슬라이더 미커밋 편집 추적 — 드래그 틱마다 commit(setProperty → 전체 리마운트)하던 것을
    /// textInput 과 같은 패턴(드래그 중엔 로컬 값만, 종료 시 1회 커밋)으로. 초당 수십 회 리마운트 방지.
    @State private var dirtySliders = Set<Int>()
    /// 감사 V06: 컬러 미커밋 편집 추적 + 디바운스 — 컬러 패널 드래그 중엔 로컬 값만 갱신하고
    /// 커밋(setProperty → 전체 리마운트)은 입력이 멈춘 뒤(또는 시트 닫힘 시) 1회.
    @State private var dirtyColors = Set<Int>()
    @State private var colorDebouncer = CommitDebouncer(delay: 0.5)

    var body: some View {
        VStack(spacing: 0) {
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
        .onAppear { props = viewModel.editableProperties(for: entry) }
        // F501: 1-파라미터 onChange(of:perform:) 는 macOS 14 에서 deprecated — 2-파라미터 신형으로.
        .onChange(of: focusedText) { _, newValue in
            for i in dirtyText where i != newValue { commitDirtyText(i) }   // 포커스 이탈 커밋
        }
        .onDisappear {
            for i in dirtyText { commitDirtyText(i) }   // 시트 닫힘 시 잔여 커밋
            for i in dirtySliders { commitDirtySlider(i) }   // F494: 드래그 중 닫힘 대비
            commitDirtyColors()   // 감사 V06: 디바운스 대기 중 닫힘 대비
        }
    }

    /// 편집된(dirty) textInput 만 영속화 — 무변경 커밋의 불필요한 리마운트 방지.
    private func commitDirtyText(_ i: Int) {
        guard dirtyText.remove(i) != nil, props.indices.contains(i) else { return }
        viewModel.setProperty(key: props[i].key, value: props[i].value, for: entry)
    }

    /// F494: 편집된(dirty) 슬라이더만 영속화(드래그 종료 시 1회) — 무변경 커밋의 리마운트 방지.
    private func commitDirtySlider(_ i: Int) {
        guard dirtySliders.remove(i) != nil, props.indices.contains(i) else { return }
        viewModel.setProperty(key: props[i].key, value: props[i].value, for: entry)
    }

    /// 감사 V06: dirty 컬러 전부 영속화(디바운스 1회 발화/시트 닫힘 시) — 대기 중 디바운스는 취소해
    /// 중복 커밋하지 않는다.
    private func commitDirtyColors() {
        colorDebouncer.cancel()
        let indices = dirtyColors
        dirtyColors.removeAll()
        for i in indices where props.indices.contains(i) {
            viewModel.setProperty(key: props[i].key, value: props[i].value, for: entry)
        }
    }

    private func label(_ p: WallpaperProperty) -> String {
        PropertyLabel.pretty(text: p.text, key: p.key)
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
                // F494: 드래그 틱마다 commit(setProperty → 전체 리마운트)하지 않고, 로컬 값만 갱신하다가
                // 드래그 종료(onEditingChanged false) 시 1회 커밋 — 초당 수십 회 리마운트·깜빡임 방지.
                Slider(value: Binding(
                    get: { if case .number(let n) = props[i].value { return n }; return 0 },
                    set: { props[i].value = .number($0); dirtySliders.insert(i) }),
                    in: PropertyControl.sliderRange(min: p.min, max: p.max),
                    onEditingChanged: { editing in if !editing { commitDirtySlider(i) } })
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
            // 감사 V06: ColorPicker 는 editingChanged 가 없어 드래그 종료를 알 수 없다 — set 마다
            // 즉시 commit 하던 것(컬러 패널 드래그 중 연속 리마운트 스톰)을 F494 슬라이더와 동등하게
            // 로컬 값만 갱신 + dirty 추적 후 디바운스 1회 커밋으로.
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
                    props[i].value = .string(String(format: "%.5f %.5f %.5f", ns.redComponent, ns.greenComponent, ns.blueComponent))
                    dirtyColors.insert(i)
                    colorDebouncer.schedule { commitDirtyColors() }
                }), supportsOpacity: false)
        case .textInput:
            HStack {
                Text(label(p)).font(.caption)
                TextField("", text: Binding(
                    get: { if case .string(let s) = props[i].value { return s }; return "" },
                    set: { props[i].value = .string($0); dirtyText.insert(i) }))
                .focused($focusedText, equals: i)
                .onSubmit { commitDirtyText(i) }
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
