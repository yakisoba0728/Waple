import SwiftUI
import WapleLibrary

/// 설치됨 탭 필터 사이드바(WE 필터 패널의 네이티브 번역). 상태는 전부 viewModel.criteria.
struct FilterSidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        List {
            Section {
                Toggle("즐겨찾기만", isOn: $viewModel.criteria.favoritesOnly)
                Button("필터 초기화") { viewModel.criteria = LibraryFilterCriteria() }
                    .disabled(!viewModel.criteria.isActive)
            } header: { Text("표시") }

            Section {
                ForEach([LibraryTypeFilter.scene, .video, .web], id: \.self) { t in
                    Toggle(t.label, isOn: binding(for: t, in: \.types))
                }
            } header: { Text("유형") }

            if !viewModel.availableRatings.isEmpty {
                Section {
                    ForEach(viewModel.availableRatings, id: \.self) { r in
                        Toggle(ratingLabel(r), isOn: binding(for: r, in: \.ratings))
                    }
                } header: { Text("나이 등급") }
            }

            if !viewModel.availableTags.isEmpty {
                Section {
                    HStack {
                        Button("전체") { viewModel.criteria.tags = Set(viewModel.availableTags) }
                        Button("없음") { viewModel.criteria.tags = [] }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    ForEach(viewModel.availableTags, id: \.self) { tag in
                        Toggle(tag, isOn: binding(for: tag, in: \.tags))
                    }
                } header: { Text("태그") }
            }
        }
        .listStyle(.sidebar)
        .frame(width: Metrics.sidebarWidth)
    }

    /// Set 멤버십 ↔ Toggle 바인딩(제네릭 — 타입/태그/등급 공용).
    private func binding<T: Hashable>(for value: T,
                                      in keyPath: WritableKeyPath<LibraryFilterCriteria, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { viewModel.criteria[keyPath: keyPath].contains(value) },
            set: { on in
                if on { viewModel.criteria[keyPath: keyPath].insert(value) }
                else { viewModel.criteria[keyPath: keyPath].remove(value) }
            })
    }

    /// WE contentrating 원문 → 표시 라벨(미지 값은 원문 그대로).
    private func ratingLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "everyone": return "전체 이용가"
        case "questionable": return "주의"
        case "mature": return "성인"
        default: return raw
        }
    }
}
