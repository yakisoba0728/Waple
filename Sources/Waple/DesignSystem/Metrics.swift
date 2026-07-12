import AppKit
import SwiftUI

/// 네이티브 재설계 치수 상수. 색 토큰 없음 — 색은 시맨틱 컬러/시스템 재질만 쓴다(스펙 §2).
enum Metrics {
    // 그리드 타일(16:10 썸네일 + 아래 제목)
    static let tileWidth: CGFloat = 200
    static let tileThumbHeight: CGFloat = 125
    static let tileCorner: CGFloat = 8
    static let gridSpacing: CGFloat = 14

    // 좌측 필터 사이드바
    static let sidebarWidth: CGFloat = 220

    // 우측 상세 패널
    static let panelWidth: CGFloat = 300
    static let heroHeight: CGFloat = 170

    // 하단 Now Playing 바
    static let nowPlayingHeight: CGFloat = 56
    static let nowPlayingThumb: CGFloat = 40

    // 창
    static let windowDefault = NSSize(width: 1280, height: 820)
    static let windowMin = NSSize(width: 1024, height: 680)
    static let displaysMin = NSSize(width: 860, height: 560)

    // 공통 간격
    static let gap: CGFloat = 8
}
