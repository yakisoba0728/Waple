import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(ProcessInfo.processInfo.environment["WAPLE_SMOKE"] == nil ? .accessory : .regular)   // Dock 아이콘 없는 메뉴바(액세서리) 앱 (WAPLE_SMOKE=1 이면 스모크용 regular)
app.run()
