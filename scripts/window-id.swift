// 지정 앱(기본 Waple)의 메인창(layer 0) 정보 출력 — 캡처용.
//   window-id.swift [앱이름]            → CGWindowID
//   window-id.swift [앱이름] --bounds   → "X Y W H" (시트가 창 위에 겹쳐도 영역 캡처로 포함 가능)
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let name = args.count > 1 ? args[1] : "Waple"
let wantBounds = args.contains("--bounds")
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    if wantBounds {
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
        exit(0)
    }
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
fputs("window not found: \(name)\n", stderr)
exit(1)
