import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock 아이콘 없는 메뉴바(액세서리) 앱. 스모크 캡처(WAPLE_SMOKE*)만 regular.
// 해석은 SmokeLaunch 하나가 한다 — 종전엔 여기·AppDelegate·MainWindowView 가 각자
// ProcessInfo 를 읽어, 한 곳만 고치고 넘어가도 아무것도 실패하지 않았다.
let smoke = SmokeLaunch.current
app.setActivationPolicy(smoke.isCapture ? .regular : .accessory)
// 오타난 TAB 값으로 엉뚱한 화면을 찍고 통과시키지 않는다. 기본으로 폴백하되 조용히는 아니다.
if let unrecognized = smoke.unrecognizedTab {
    NSLog("%@", "[Waple] WAPLE_SMOKE_TAB=\(unrecognized) 은 알 수 없는 값입니다 "
          + "— installed/discover/workshop 중 하나여야 합니다. 기본(라이브러리 > 전체)으로 시작합니다.")
}

// 액세서리 앱은 메인 메뉴가 없어 ⌘C/⌘V 등 표준 편집 단축키가 모든 텍스트 필드에서 죽는다
// (API 키 붙여넣기 불가 버그). 메뉴 바에 보이지는 않아도 키 이퀴밸런트 라우팅은 mainMenu 를
// 타므로, 편집 메뉴 하나만 최소로 단다. 액션은 전부 퍼스트 리스폰더 체인.
//
// ⚠️ `addItem(withTitle:)` 은 이중 사각지대였다. 커버리지 오라클의 패턴 3 은 소문자
// `title:` 만 보므로 대문자 `withTitle:` 은 스캔에서 빠지고, AppKit 은 이 경로를 자동
// 현지화하지도 않는다 — 테스트는 초록인데 영어 시스템에서 편집 메뉴만 한국어였다.
// 그래서 여기 래핑과 `LocalizationCoverageTests` 의 패턴 추가는 **같은 커밋**이어야 한다.
// 패턴만 먼저 넣으면 strings 에 키가 생겨 "번역됨" 으로 보이는데 런타임은 계속 한국어인
// 거짓 초록이 된다.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: NSLocalizedString("편집", comment: "메인 메뉴 — 편집"))
editMenu.addItem(withTitle: NSLocalizedString("실행 취소", comment: "편집 메뉴"),
                 action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: NSLocalizedString("다시 실행", comment: "편집 메뉴"),
                 action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: NSLocalizedString("오려두기", comment: "편집 메뉴"),
                 action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: NSLocalizedString("복사", comment: "편집 메뉴"),
                 action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: NSLocalizedString("붙여넣기", comment: "편집 메뉴"),
                 action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: NSLocalizedString("전체 선택", comment: "편집 메뉴"),
                 action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
