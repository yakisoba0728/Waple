import SwiftUI

/// WE 공용 버튼. toolbar=어두운 사각(우상단·재생목록 줄), accent=파랑, large*=하단 대형 2종.
struct WEButtonStyle: ButtonStyle {
    enum Kind { case toolbar, accent, large, largeAccent }
    var kind: Kind = .toolbar

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = {
            switch kind {
            case .toolbar: return WETheme.Colors.control
            case .accent: return WETheme.Colors.accent
            case .large: return WETheme.Colors.largeButton
            case .largeAccent: return WETheme.Colors.accent
            }
        }()
        let isLarge = kind == .large || kind == .largeAccent
        return configuration.label
            .font(WETheme.Fonts.body)
            .foregroundColor(WETheme.Colors.textPrimary)
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: isLarge ? WETheme.Metrics.bottomLargeRowH : WETheme.Metrics.fieldH - 4)
            .frame(maxWidth: isLarge ? .infinity : nil)
            .background(configuration.isPressed ? bg.opacity(0.8) : bg)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
            .contentShape(Rectangle())
    }
}

/// 상단 탭(설치됨/검색/창작마당). 활성=파랑 틴트 채움+파랑 보더, hasDropdown=우측 ▾.
struct WETabButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    var hasDropdown: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(WETheme.Fonts.caption)
                Text(title).font(WETheme.Fonts.tab)
                if hasDropdown { Image(systemName: "chevron.down").font(.system(size: 8)) }
            }
            .foregroundColor(WETheme.Colors.textPrimary)
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: WETheme.Metrics.tabH)
            .background(isActive ? WETheme.Colors.tabActive : WETheme.Colors.tabInactive)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(isActive ? WETheme.Colors.accent : WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
        }
        .buttonStyle(.plain)
    }
}

/// 우상단 버튼(모바일/디스플레이/설정). disabledHint 있으면 비활성+툴팁.
struct WETopButton: View {
    let title: String
    let systemImage: String
    var disabledHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(WETheme.Fonts.caption)
                Text(title)
            }
        }
        .buttonStyle(WEButtonStyle(kind: .toolbar))
        .disabled(disabledHint != nil)
        .opacity(disabledHint != nil ? 0.55 : 1)
        .help(disabledHint ?? title)
    }
}

/// 검색창 — 좌측 텍스트, 우측 돋보기(WE 배치).
struct WESearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 0) {
            TextField("검색", text: $text)
                .textFieldStyle(.plain)
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textPrimary)
                .padding(.horizontal, WETheme.Metrics.hPad)
            Image(systemName: "magnifyingglass")
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textSecondary)
                .padding(.trailing, WETheme.Metrics.hPad)
        }
        .frame(height: WETheme.Metrics.fieldH)
        .background(WETheme.Colors.field)
        .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
            .stroke(WETheme.Colors.border, lineWidth: 1))
        .cornerRadius(WETheme.Metrics.corner)
    }
}

/// 콤보(정렬 등) — 어두운 사각 + 우측 ▾, Menu 기반.
struct WEComboBox<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(label(opt)) { selection = opt }
            }
        } label: {
            HStack {
                Text(label(selection)).font(WETheme.Fonts.body)
                    .foregroundColor(WETheme.Colors.textPrimary)
                Spacer(minLength: WETheme.Metrics.gap)
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .foregroundColor(WETheme.Colors.textSecondary)
            }
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: WETheme.Metrics.fieldH)
            .background(WETheme.Colors.control)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
