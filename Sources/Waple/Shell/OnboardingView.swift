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

/// 준비 항목 체크리스트 시트. 시각은 전부 시스템(SF Symbols·시맨틱 컬러), 치수는 Metrics 만.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap * 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Waple 시작하기").font(.title2).bold()
                Text("아래를 확인하면 바로 배경을 즐길 수 있어요. 모두 나중에 설정에서 바꿀 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(done: model.hasContent, title: "배경 추가",
                detail: "배경 폴더나 zip 을 창에 끌어다 놓거나, 창작마당 탭에서 내려받으세요.") {
                Button("가져오기…") { model.importContent() }
                    .buttonStyle(.borderedProminent)
            }

            row(done: model.baseAssetsSet, title: "공유 에셋 폴더 (선택)",
                detail: "일부 씬은 Wallpaper Engine 공유 assets 폴더의 텍스처가 필요합니다.") {
                Button("폴더 선택…") { model.chooseBaseAssets() }
            }

            row(done: model.ffmpegAvailable, title: "ffmpeg (선택)",
                detail: model.ffmpegAvailable
                    ? "사용 가능 — 동영상 변환 준비됨."
                    : "mkv/webm 동영상 가져오기에 필요합니다 — brew install ffmpeg") { EmptyView() }

            Spacer(minLength: 0)

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
        .padding(Metrics.gap * 3)
        .frame(width: Metrics.onboardingSize.width, height: Metrics.onboardingSize.height)
    }

    @ViewBuilder
    private func row(done: Bool, title: String, detail: String,
                     @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Metrics.gap * 1.5) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
        }
    }
}
