import AppKit

/// 데스크탑 배경 창의 윈도우 레벨(순수 계산 — 단위 테스트 가능).
///
/// DesktopWindow 가 유일한 사용처지만, 값 계산을 분리해 테스트로 규약을 고정한다.
public enum WallpaperWindowLevel {
    /// 데스크탑 아이콘 레벨 바로 아래(= 정적 배경 위, Finder 아이콘 아래).
    /// Wallpaper Engine 과 동일하게 아이콘이 라이브 배경 **위**에 렌더된다.
    public static var desktopWallpaper: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    }
}
