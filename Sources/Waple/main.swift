import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let env = ProcessInfo.processInfo.environment
// Dock 아이콘 없는 메뉴바(액세서리) 앱. 스모크 캡처(WAPLE_SMOKE*)만 regular.
let smokeCapture = env["WAPLE_SMOKE"] != nil || env["WAPLE_SMOKE_SETTINGS"] != nil || env["WAPLE_SMOKE_ONBOARDING"] != nil
app.setActivationPolicy(smokeCapture ? .regular : .accessory)

// 액세서리 앱은 메인 메뉴가 없어 ⌘C/⌘V 등 표준 편집 단축키가 모든 텍스트 필드에서 죽는다
// (API 키 붙여넣기 불가 버그). 메뉴 바에 보이지는 않아도 키 이퀴밸런트 라우팅은 mainMenu 를
// 타므로, 편집 메뉴 하나만 최소로 단다. 액션은 전부 퍼스트 리스폰더 체인.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "편집")
editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
