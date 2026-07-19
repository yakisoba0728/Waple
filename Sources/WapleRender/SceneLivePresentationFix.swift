import Foundation

/// 라이브 데스크탑 프레젠트 보정(순수 계산 — 단위 테스트 가능).
///
/// macOS 26+ 에서 데스크탑 레벨(`WallpaperWindowLevel.desktopWallpaper`) 창에 얹힌 MTKView 의
/// CAMetalLayer drawable 프레젠트가 상하로 뒤집혀 나타나는 컴포지팅 회귀(실기기 macOS 27.0
/// Build 26A5378n 확인 — scene 배경만, video/web 은 정상)를 보정하기 위한 단일 게이트.
///
/// 인코딩 수학(pxToNDC 등)은 캡처(WapleCompat 골든 170씬)와 라이브가 finalizeScene/encodeDrawPlan
/// 을 공유해 비트동일 — 캡처는 offscreen 텍스처를 직접 readback 해 drawable/CAMetalLayer 를
/// 아예 거치지 않는다. 따라서 뒤집힘의 원인은 셰이더/투영이 아니라 "그 텍스처를 화면에 얹는"
/// 마지막 프레젠트 단계뿐이라는 결론이며, 이 게이트는 그 단계(MTKView.layer.isGeometryFlipped)
/// 에만 적용한다.
///
/// isGeometryFlipped 는 레이어 자신의 콘텐츠 프레젠트에만 영향을 주고, NSView 히트테스트/마우스
/// 좌표 변환(view.convert, pointerSceneCoords → sceneCoords)은 화면·윈도우 물리 좌표(AppKit
/// 하단원점, CALayer 와 무관) 기반이라 전혀 건드리지 않는다 — 시각이 바로잡히면 클릭 역매핑도
/// 수학적으로 함께 정합된다(별도 보정 불요, sceneCoords 의 "뷰 좌표(AppKit 하단원점) → 씬 픽셀
/// (WE 상단원점)" 가정이 애초에 isGeometryFlipped=false 표준 프레젠트를 전제하기 때문).
///
/// macOS 14(프로젝트 최소 타깃)~15 는 video/web 이 정상이고 이 회귀의 필드 보고가 없어 정상으로
/// 추정하나 실기기로 확증하지는 못했다 — 무조건 flip 은 만약 14/15 가 실은 정상이었다면 그걸
/// 깨뜨릴 위험이 있어, 버전 게이트로 위험을 최소화한다. 경계가 틀렸다고 밝혀지면(예: 14/15 도
/// 회귀가 있었다거나, 26 미만/초과에서 경계가 달라진다거나) `needsDesktopFlipY(majorVersion:)`
/// 한 곳만 고치면 된다.
public enum SceneLivePresentationFix {
    /// 순수 판정(테스트용) — 메이저 버전만 비교, AppKit/런타임 의존 없음.
    static func needsDesktopFlipY(majorVersion: Int) -> Bool {
        majorVersion >= 26
    }

    /// 실사용 게이트 — 현재 런타임 OS 메이저 버전으로 판정.
    public static var needsDesktopFlipY: Bool {
        needsDesktopFlipY(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}
