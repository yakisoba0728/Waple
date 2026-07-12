// 지정 앱(기본 Waple)의 메인창(layer 0) CGWindowID 출력 — screencapture -l 용.
// 데스크탑 월페이퍼 창(레이어 음수)은 제외된다.
import CoreGraphics
import Foundation

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Waple"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
fputs("window not found: \(name)\n", stderr)
exit(1)
