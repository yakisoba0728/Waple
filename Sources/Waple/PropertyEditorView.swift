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

/// 배경별 유저 속성 편집기(WE 속성 패널 대응). 변경 즉시 저장 + 현재 배경이면 재적용.
///
/// ## 시트가 아니라 인스펙터 안이다 — 커밋 트리거가 하나 더 필요하다
///
/// 미커밋 편집(텍스트·슬라이더·컬러)의 마지막 방어선은 `onDisappear` 였다. 시트에서는
/// 닫힘이 곧 사라짐이라 그걸로 충분했지만, **인스펙터는 접어도 사라지지 않을 수 있다** —
/// 그 경우 드래그 중이던 슬라이더 값이 조용히 버려진다. 그래서 패널 노출 상태가 꺼지는
/// 것도 커밋 트리거로 본다(청사진 §7.3 의 위험 목록에 있던 항목이다).
///
/// ## 평면 목록 → 섹션
///
/// 종전에는 `ScrollView { VStack }` 한 줄기였다. 속성 243개짜리 씬에서 그건 읽을 수 없는
/// 벽이 된다. `Form(.grouped)` 로 올리면 섹션 카드·행 정렬·라벨 열 정렬을 시스템이 준다.
/// 자를 자리는 `PropertyGrouping`(순수)이 정한다.
struct PropertyEditorView: View {
    let entry: LibraryEntry
    @ObservedObject var viewModel: LibraryViewModel
    /// 값이 바뀌면 저장된 오버라이드를 다시 읽어 온다(초기화 버튼이 올린다).
    ///
    /// 종전에는 호출부가 `.id` 에 세대 번호를 섞어 편집기를 **통째로 재마운트**했다.
    /// 그러면 값 리셋이 하드컷으로 튀고 스크롤 위치까지 날아간다 — 240줄짜리 목록에서
    /// 그건 "어디를 보고 있었는지" 를 잃는 것이다. 제자리 재로드로 바꾼다.
    var reloadToken: Int = 0
    /// 값이 실제로 영속화될 때마다 호출된다(호출부의 "저장됨" 표시용).
    var onCommit: () -> Void = {}
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
        editor
            .onAppear { props = viewModel.editableProperties(for: entry) }
            // F501: 1-파라미터 onChange(of:perform:) 는 macOS 14 에서 deprecated — 2-파라미터 신형으로.
            .onChange(of: focusedText) { _, newValue in
                for i in dirtyText where i != newValue { commitDirtyText(i) }   // 포커스 이탈 커밋
            }
            .onChange(of: reloadToken) { _, _ in reload() }
            // 인스펙터를 접는 것은 사라짐이 아니다 — onDisappear 만 믿으면 그때 편집 중이던
            // 값이 조용히 버려진다.
            .onChange(of: viewModel.panelVisible) { _, visible in if !visible { commitPending() } }
            .onDisappear { commitPending() }
    }

    @ViewBuilder
    private var editor: some View {
        if props.isEmpty {
            // 커스텀 빈 상태를 그리지 않는다 — 여백·글자 위계·접근성을 시스템이 준다.
            ContentUnavailableView("편집할 속성이 없습니다", systemImage: "slider.horizontal.3",
                                   description: Text("이 배경에는 편집 가능한 속성이 없습니다."))
        } else {
            Form {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var sections: [PropertySection] {
        PropertyGrouping.sections(in: props, visible: PropertyDecoration.visibleIndices(in: props))
    }

    /// 제목만 있고 컨트롤이 없는 덩어리는 제목이 아니라 **안내 문단**이다(근거는
    /// `PropertyGrouping`). 섹션 헤더로 그리면 뒤에 아무 것도 없는 빈 카드가 뜬다.
    @ViewBuilder
    private func sectionView(_ section: PropertySection) -> some View {
        if section.rows.isEmpty {
            if let title = section.title, props.indices.contains(title) {
                Section { Text(verbatim: label(props[title])).font(Typography.caption)
                              .foregroundStyle(.secondary) }
            }
        } else if let title = section.title, props.indices.contains(title) {
            Section {
                ForEach(section.rows, id: \.self) { control(for: $0) }
            } header: {
                Text(verbatim: label(props[title]))
            }
        } else {
            Section { ForEach(section.rows, id: \.self) { control(for: $0) } }
        }
    }

    /// 저장된 오버라이드를 다시 읽는다. 미커밋 편집 추적은 함께 비운다 — 되돌린 값을
    /// 나중에 커밋해 방금 한 초기화를 무르는 일이 없어야 한다.
    private func reload() {
        colorDebouncer.cancel()
        dirtyText.removeAll()
        dirtySliders.removeAll()
        dirtyColors.removeAll()
        Motion.run(Motion.stateChange) { props = viewModel.editableProperties(for: entry) }
    }

    /// 미커밋 편집 전부를 영속화(패널 접힘·사라짐 대비).
    private func commitPending() {
        for i in dirtyText { commitDirtyText(i) }
        for i in dirtySliders { commitDirtySlider(i) }   // F494: 드래그 중 닫힘 대비
        commitDirtyColors()   // 감사 V06: 디바운스 대기 중 닫힘 대비
    }

    /// 편집된(dirty) textInput 만 영속화 — 무변경 커밋의 불필요한 리마운트 방지.
    private func commitDirtyText(_ i: Int) {
        guard dirtyText.remove(i) != nil else { return }
        persist(i)
    }

    /// F494: 편집된(dirty) 슬라이더만 영속화(드래그 종료 시 1회) — 무변경 커밋의 리마운트 방지.
    private func commitDirtySlider(_ i: Int) {
        guard dirtySliders.remove(i) != nil else { return }
        persist(i)
    }

    /// 감사 V06: dirty 컬러 전부 영속화(디바운스 1회 발화/패널 접힘 시) — 대기 중 디바운스는 취소해
    /// 중복 커밋하지 않는다.
    private func commitDirtyColors() {
        colorDebouncer.cancel()
        let indices = dirtyColors
        dirtyColors.removeAll()
        for i in indices { persist(i) }
    }

    /// 영속화의 **유일한 출구**. 커밋 경로가 넷(즉시·텍스트·슬라이더·컬러)이라 여기 모아 두지
    /// 않으면 "저장됨" 통지가 붙는 경로와 안 붙는 경로가 갈린다. 종전에도 같은 두 줄이
    /// 네 벌로 흩어져 있었다.
    private func persist(_ i: Int) {
        guard props.indices.contains(i) else { return }
        viewModel.setProperty(key: props[i].key, value: props[i].value, for: entry)
        onCommit()
    }

    private func label(_ p: WallpaperProperty) -> String {
        PropertyLabel.pretty(text: p.text, key: p.key)
    }

    private func commit(_ i: Int, _ value: PropertyValue) {
        guard props.indices.contains(i) else { return }
        props[i].value = value
        persist(i)
    }

    /// 속성 라벨은 WE 패키지가 담은 원본 문구다(사람이 읽는 값이지만 번역 대상이 아니다) —
    /// 그래서 전부 `verbatim`. 리터럴 오버로드로 붙이면 그때부터 이 앱의 번역 카탈로그에
    /// 없는 키를 조회하게 되고, 커버리지 오라클도 잡을 수 없는 잡음이 된다.
    @ViewBuilder
    private func control(for i: Int) -> some View {
        let p = props[i]
        switch PropertyControl.kind(forType: p.type) {
        case .toggle:
            Toggle(isOn: Binding(
                get: { if case .bool(let b) = props[i].value { return b }; return false },
                set: { commit(i, .bool($0)) })) { Text(verbatim: label(p)) }
        case .slider:
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(verbatim: label(p)).font(Typography.caption)
                    Spacer(minLength: Space.xs)
                    // 드래그 중 자리수가 바뀌어도 폭이 튀지 않도록 고정폭 숫자.
                    Text(verbatim: String(format: "%.2f", sliderValue(i)))
                        .font(Typography.metric).foregroundStyle(.secondary)
                }
                // F494: 드래그 틱마다 commit(setProperty → 전체 리마운트)하지 않고, 로컬 값만 갱신하다가
                // 드래그 종료(onEditingChanged false) 시 1회 커밋 — 초당 수십 회 리마운트·깜빡임 방지.
                Slider(value: Binding(
                    get: { sliderValue(i) },
                    set: { props[i].value = .number($0); dirtySliders.insert(i) }),
                    in: PropertyControl.sliderRange(min: p.min, max: p.max),
                    onEditingChanged: { editing in if !editing { commitDirtySlider(i) } })
                    .accessibilityLabel(Text(verbatim: label(p)))
            }
        case .picker:
            Picker(selection: Binding(
                get: { props[i].value },
                set: { commit(i, $0) })) {
                ForEach(Array((p.options ?? []).enumerated()), id: \.offset) { _, opt in
                    Text(verbatim: opt.label).tag(opt.value)
                }
            } label: {
                Text(verbatim: label(p))
            }
        case .color:
            // 감사 V06: ColorPicker 는 editingChanged 가 없어 드래그 종료를 알 수 없다 — set 마다
            // 즉시 commit 하던 것(컬러 패널 드래그 중 연속 리마운트 스톰)을 F494 슬라이더와 동등하게
            // 로컬 값만 갱신 + dirty 추적 후 디바운스 1회 커밋으로.
            ColorPicker(selection: Binding(
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
                }), supportsOpacity: false) {
                Text(verbatim: label(p))
            }
        case .textInput:
            TextField(text: Binding(
                get: { if case .string(let s) = props[i].value { return s }; return "" },
                set: { props[i].value = .string($0); dirtyText.insert(i) })) {
                Text(verbatim: label(p))
            }
            .focused($focusedText, equals: i)
            .onSubmit { commitDirtyText(i) }
        case .file:
            resourcePicker(for: i, directory: false)
        case .directory:
            resourcePicker(for: i, directory: true)
        case .displayOnly:
            // 섹션 제목으로 승격되지 못한 잔여(그룹핑이 걸러 주므로 보통 오지 않는다).
            Text(verbatim: label(p)).font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    private func sliderValue(_ i: Int) -> Double {
        if case .number(let n) = props[i].value { return n }
        return 0
    }

    @ViewBuilder
    private func resourcePicker(for i: Int, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(verbatim: label(props[i])).font(Typography.caption)
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
                // 경로는 파일시스템 값이라 번역 대상이 아니다.
                Text(verbatim: path).font(Typography.badge).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
