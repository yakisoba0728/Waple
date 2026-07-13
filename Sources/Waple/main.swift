import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let env = ProcessInfo.processInfo.environment
// Dock 아이콘 없는 메뉴바(액세서리) 앱. 스모크 캡처(WAPLE_SMOKE / WAPLE_SMOKE_SETTINGS)만 regular.
app.setActivationPolicy(env["WAPLE_SMOKE"] == nil && env["WAPLE_SMOKE_SETTINGS"] == nil ? .accessory : .regular)
app.run()
