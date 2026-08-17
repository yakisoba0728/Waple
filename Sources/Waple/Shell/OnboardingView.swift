import SwiftUI
import AppKit

/// 최초 실행 온보딩 시트 모델(앱셸 스코프 B). 첫 실행 1회 라이브러리 창 위에 뜬다.
/// 항목 상태(초록=해결)는 기존 감지에서 주입하고, "해결" 액션은 기존 설정 배관을 재사용한다
/// (새 설정 시스템 없음 — LibraryViewModel.on* / SettingsViewModel 전례와 동일).
final class OnboardingModel: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var hasContent = false
    @Published private(set) var baseAssetsSet = false
    @Published private(set) var ffmpegAvailable = false

    /// 현재 상태 소스(AppDelegate 주입): 라이브러리 배경 유무·공유 에셋 폴더 지정·ffmpeg 유무.
    var readiness: () -> (content: Bool, baseAssets: Bool, ffmpeg: Bool) = { (false, false, false) }
    var onChooseBaseAssets: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// '배경 추가' 행 "가져오기…" 액션(w5d-onboarding) — AppDelegate 가 WallpaperGridView.importFolder 와
    /// 동일한 NSOpenPanel+routeImport 배선(ImportPanel)을 주입한다.
    var onImport: (() -> Void)?

    /// 최신 상태를 다시 읽어 반영(표시 직전·에셋 폴더 선택 후).
    func refresh() {
        let r = readiness()
        hasContent = r.content
        baseAssetsSet = r.baseAssets
        ffmpegAvailable = r.ffmpeg
    }

    func present() { refresh(); isPresented = true }
    func dismiss() { isPresented = false }

    /// 공유 에셋 폴더 선택(NSOpenPanel runModal — 반환 후 상태 재조회로 초록 갱신).
    func chooseBaseAssets() {
        onChooseBaseAssets?()
        refresh()
    }

    /// 배경 가져오기(NSOpenPanel runModal — 반환 후 상태 재조회로 초록 갱신). 필수 단계(hasContent)를
    /// 시트에서 한 번에 끝낼 수 있게 한다(어포던스 역전 정정 — 종전엔 선택 단계인 공유 에셋 폴더에만
    /// 버튼이 있고 정작 필수인 배경 추가는 액션이 없어 시트를 닫고 다시 찾아야 했다).
    func importContent() {
        onImport?()
        refresh()
    }
}

/// 준비 항목 체크리스트 시트. 시각은 전부 시스템(SF Symbols·시맨틱 컬러), 치수는 토큰만.
struct OnboardingView: View {
    /// 체크리스트가 이 높이를 넘으면 시트가 더 자라지 않고 스크롤한다.
    /// 3행 기준 실제 콘텐츠는 이보다 한참 작아서, 평상시에는 이 값이 보이지 않는다 —
    /// 큰 글씨 설정에서만 발동하는 상한이다(F090 의 목적 그대로).
    private static let checklistMaxHeight: CGFloat = 520

    @ObservedObject var model: OnboardingModel

    /// ## 높이를 고정하지 않는다 — 아래 40% 가 빈 칸이었다
    ///
    /// 종전에는 온보딩 시트의 고정 크기 상수(460×430)를 그대로 프레임에 박았고, 3행짜리 콘텐츠는
    /// 그 절반을 조금 넘겼다. 실측(2026-08-17): 마지막 행 아래로 약 40% 가 빈 공간이었고,
    /// 버튼 행만 바닥에 떨어져 있어 시트가 비어 보였다.
    ///
    /// 그래서 세로는 콘텐츠가 정하게 두고(폭만 고정), 상한은 체크리스트 쪽에 건다.
    /// 상한을 스크롤 컨테이너에 거는 이유는 F090 그대로다 — 큰 글씨 설정에서 잘리는 대신
    /// 스크롤되어야 한다. 고정 높이를 없앤다고 그 대비가 사라지는 게 아니라, 평상시에만
    /// 시트가 콘텐츠에 맞게 줄어든다.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    checklist
                }
            }
            .frame(maxHeight: Self.checklistMaxHeight)

            HStack {
                // 첫 실행 가치가 낮은 이차 동작이라 위계를 낮춘다(link 스타일 — 필수 행의 새 프로미넌트
                // "가져오기…" 버튼과 시각적으로 경쟁하지 않게).
                Button("설정 열기") { model.onOpenSettings?() }
                    .buttonStyle(.link)
                Spacer()
                Button("시작하기") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.sheetInset)
        .frame(width: Metrics.onboardingSize.width)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Waple 시작하기").font(Typography.windowHeading)
            Text("아래를 확인하면 바로 배경을 즐길 수 있어요. 모두 나중에 설정에서 바꿀 수 있습니다.")
                .font(Typography.secondaryBody).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var checklist: some View {
        row(done: model.hasContent, title: Text("배경 추가"),
            detail: Text("배경 폴더나 zip 을 창에 끌어다 놓거나, 창작마당 탭에서 내려받으세요.")) {
            Button("가져오기…") { model.importContent() }
                .buttonStyle(.borderedProminent)
        }

        row(done: model.baseAssetsSet, title: Text("공유 에셋 폴더 (선택)"),
            detail: Text("일부 씬은 Wallpaper Engine 공유 assets 폴더의 텍스처가 필요합니다.")) {
            Button("폴더 선택…") { model.chooseBaseAssets() }
        }

        // F089: 원시 mkv/webm 파일 "가져오기" 경로는 ffmpeg 유무와 무관하게 존재하지 않는다
        // (VideoImport.isVideoFile 은 mp4/mov/m4v 만 인식) — ffmpeg 의 실제 역할은 폴더/zip 으로
        // 들여온 WE 배경 패키지 *안*의 비-네이티브 동영상 컨테이너를 재생 가능하게 변환하는 것
        // 뿐이다. 설정 창 문구(SettingsPresentation.ffmpegStatus)와 표현을 통일해 온보딩만 다른
        // 기대를 심지 않게 한다.
        row(done: model.ffmpegAvailable, title: Text("ffmpeg (선택)"),
            detail: ffmpegDetail) { EmptyView() }
    }

    /// 삼항으로 `String` 을 고르면 두 리터럴이 **둘 다** 스캔에서 빠진다(청사진 §5.3).
    /// 고르는 대상을 `Text` 로 올리면 둘 다 잡히고 둘 다 번역된다.
    private var ffmpegDetail: Text {
        model.ffmpegAvailable
            ? Text("사용 가능 — 동영상 변환 준비됨.")
            : Text("배경 패키지 안 mkv/webm 동영상 변환에 필요합니다 — brew install ffmpeg")
    }

    /// ## 파라미터가 `String` 이 아니라 `Text` 인 이유 — 죽은 키 3건의 원인이었다
    ///
    /// 종전 시그니처는 `title: String` 이었고 본문이 `Text(title)` 이었다. 그건
    /// `Text(_: some StringProtocol)` 비현지화 오버로드라, 호출부의 한국어 리터럴이
    /// **런타임에 한 번도 조회되지 않았다.** 그런데 리터럴이 `title:` 뒤에 있어 커버리지
    /// 스캔에는 걸렸고, 그래서 en.lproj 에 번역이 멀쩡히 있는데 영어 시스템에서는 한국어가
    /// 나오는 상태로 세 키가 굳어 있었다(청사진 §5.4 의 "죽은 키" 3건이 정확히 이것이다).
    /// 타입을 `Text` 로 올리면 호출부가 리터럴을 `Text("…")` 로 쓰게 되고, 번역과 스캔이
    /// 같은 경로로 맞춰진다. `detail:` 은 애초에 스캔 패턴에도 없던 이름이라 번역조차 없었다.
    @ViewBuilder
    private func row(done: Bool, title: Text, detail: Text,
                     @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? ColorRole.ready : Color.secondary)
                .font(.title3)
                // 완료 여부가 색(초록/회색)과 글리프(체크/빈 원)로만 전달된다 — 보조기술에는
                // 둘 다 보이지 않으므로 말로도 준다. 행 전체를 combine 하지 않는 이유는
                // 오른쪽의 실제 버튼("가져오기…")이 그 안에 삼켜져 도달 불가가 되기 때문이다.
                .accessibilityLabel(done ? Text("완료") : Text("미완료"))
            VStack(alignment: .leading, spacing: Space.xxs) {
                title.font(Typography.subsectionHeader)
                detail.font(Typography.secondaryBody).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
        }
    }
}
