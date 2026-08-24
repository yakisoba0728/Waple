import SwiftUI

/// 다운로드 전제조건 바 — steamcmd 상태 · 다운로드 계정 · API 키 교체.
///
/// ## 왜 따로 뺐나 — 둘러보기에는 이게 없어서 막다른 길이 있었다
///
/// 종전에는 창작마당>검색 안에만 있었다. 그런데 다운로드는 **둘러보기 레일에서도 시작된다**.
/// 계정을 한 번도 입력하지 않은 사용자가 레일에서 다운로드를 누르면 "계정을 먼저 입력하세요"
/// 라는 안내만 받고, 그 화면 어디에도 입력할 자리가 없다. 안내가 가리키는 곳이 존재하지
/// 않는 상태였다. 두 표면이 같은 뷰모델과 같은 다운로드 상태를 공유하므로 이 줄도 공유한다.
///
/// ## 왜 콘텐츠 안에 남겨 두나
///
/// 계정 같은 것은 원래 설정 창이 제자리다. 그런데 설정 창에는 steamcmd 항목이 하나도 없고
/// (2026-08-17 실측), 그 파일은 이번 페이즈에 다른 단위가 고치고 있다. 여기서 지우면
/// **키를 바꾸거나 계정을 넣을 방법이 앱 전체에서 사라진다.** 옮기는 것은 설정 화면에 자리가
/// 생긴 다음 일이고, 그때 이 파일을 통째로 지우면 된다.
///
/// ## 콘텐츠가 아니라 크롬으로 보이게
///
/// 종전에는 우물 위에 바로 얹혀 있어서, 특히 steamcmd 경고가 켜지면 콘텐츠 맨 앞의 오류
/// 배너처럼 읽혔다. 재질 + 아래 구분선을 주면 같은 정보가 "창의 부속 줄" 로 읽힌다 —
/// 툴바 아래 유틸리티 바는 맥 앱의 흔한 형태이고, 콘텐츠 우물과 층이 달라진다.
struct WorkshopUtilityBar: View {
    /// API 키 삭제 확인 — 되돌리기 어려운 동작이라 확인을 거친다(2026-08-25).
    @State private var confirmClearKey = false
    @ObservedObject var vm: WorkshopViewModel

    var body: some View {
        VStack(spacing: 0) {
            row
            Divider()
        }
        .background(Surface.chrome)
    }

    private var row: some View {
        HStack(spacing: Space.controlGap) {
            if !vm.steamcmdAvailable {
                Label("steamcmd 미설치 — `brew install steamcmd` 후 다시 실행",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(ColorRole.warning)
            }
            Spacer(minLength: Space.controlGap)
            Text("steamcmd 계정").font(Typography.caption).foregroundStyle(.secondary)
            TextField("username", text: $vm.usernameInput)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .frame(width: Metrics.usernameFieldWidth)
                .help("다운로드용 Steam 계정. 최초 1회 터미널에서 `steamcmd +login <계정>` 으로 로그인해 세션을 캐시하세요 — 비밀번호는 앱이 저장하지 않습니다.")
            // [2026-08-25] 확인 없이 바로 지우고 있었다. 이 버튼은 **Keychain 에 저장된 키를
            // 즉시 삭제**하는데, 사용자가 되돌릴 방법은 Steam 사이트에서 키를 다시 받아 붙여넣는
            // 것뿐이다(앱은 사본을 안 갖는다). 되돌리기 어려운 동작에는 확인을 둔다 —
            // 같은 규약을 `WallpaperGridView:66`(라이브러리 제거)과 `SelectionPanelView:359`
            // (폴더 삭제·속성 초기화)가 이미 쓰고 있었고 여기만 빠져 있었다.
            Button("API 키 변경") { confirmClearKey = true }
                .controlSize(.small)
                .help("Keychain 의 Steam Web API 키를 지우고 다시 입력")
                .confirmationDialog("저장된 API 키를 지울까요?", isPresented: $confirmClearKey) {
                    Button("키 삭제", role: .destructive) { vm.clearAPIKey() }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("Keychain 에서 삭제되고 창작마당 검색이 멈춥니다. 다시 쓰려면 키를 새로 입력해야 합니다.")
                }
        }
        .padding(.horizontal, Space.contentInset)
        .padding(.vertical, Space.controlGap)
    }
}
