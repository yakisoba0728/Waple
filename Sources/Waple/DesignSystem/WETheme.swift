// ⚠ 추정 토큰 — Task 1 실측 교정 대기
import SwiftUI
import AppKit

/// WE 2.8.42 실측 디자인 토큰 — 수치의 유일한 출처(표면 뷰에 리터럴 금지).
/// 출처: docs/reference/we/sp1-measurements.md (installed-filter-*.png 스포이드/실측).
enum WETheme {
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    enum Colors {
        static let titlebar      = WETheme.color(0x0C0D13)  // 실측표 bgTitlebar 로 교체
        static let tabRow        = WETheme.color(0x0C0D13)  // bgTabRow
        static let tabActive     = WETheme.color(0x173A66)  // tabActive
        static let tabInactive   = WETheme.color(0x15161D)  // tabInactive
        static let window        = WETheme.color(0x101219)  // bgGrid(콘텐츠 기본 바탕)
        static let panel         = WETheme.color(0x14161F)  // bgPanel(우측 패널·시트)
        static let sidebar       = WETheme.color(0x12141C)  // bgSidebar(필터 패널, SP2)
        static let field         = WETheme.color(0x07080C)  // bgField(검색창)
        static let control       = WETheme.color(0x191B24)  // bgControl(콤보·일반 버튼)
        static let controlHover  = WETheme.color(0x232633)  // control 호버(실측 불가 시 control+10%)
        static let largeButton   = WETheme.color(0x191C26)  // bgLargeButton(하단 대형)
        static let bottomBar     = WETheme.color(0x0E0F16)  // bgBottomBar
        static let border        = WETheme.color(0x2A2D3A)  // 컨트롤 1px 보더(확대 실측)
        static let accent        = WETheme.color(0x2A6EE0)  // accent(필터·확인·» 파랑)
        static let danger        = WETheme.color(0xC03830)  // danger(구독 취소)
        static let textPrimary   = WETheme.color(0xFFFFFF)
        static let textSecondary = WETheme.color(0xA7ADBB)
        static let textDisabled  = WETheme.color(0x5A5F6D)
    }

    enum Metrics {
        static let titlebarH: CGFloat = 34        // 실측표로 교체
        static let tabRowH: CGFloat = 30
        static let tabH: CGFloat = 26
        static let searchRowH: CGFloat = 44
        static let fieldH: CGFloat = 30
        static let rightPanelW: CGFloat = 315
        static let bottomPlaylistRowH: CGFloat = 36
        static let bottomLargeRowH: CGFloat = 34
        static let corner: CGFloat = 3
        static let hPad: CGFloat = 10             // 셸 좌우 기본 패딩
        static let gap: CGFloat = 8               // 컨트롤 사이 기본 간격
        static let trafficLightInset: CGFloat = 78 // 신호등 폭 회피(타이틀 좌측 요소 시작점)
    }

    enum Fonts {
        static let title = Font.system(size: 13)          // 타이틀바 중앙
        static let tab = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let sectionBold = Font.system(size: 15, weight: .bold)  // "재생목록" 라벨
    }
}

extension NSColor {
    /// NSWindow.backgroundColor 용(콘텐츠가 타이틀바 아래까지 칠할 때 이음새 방지).
    static var weWindowBackground: NSColor {
        NSColor(WETheme.Colors.window)
    }
}
