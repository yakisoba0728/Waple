// 지정 앱(기본 Waple)의 메인창(layer 0) 정보 출력 — 캡처용.
//   window-id.swift [앱이름]            → CGWindowID
//   window-id.swift [앱이름] --bounds   → "X Y W H" (시트가 창 위에 겹쳐도 영역 캡처로 포함 가능)
//   window-id.swift --pid <PID>         → 그 프로세스의 창만 (병렬 세션 필수)
import CoreGraphics
import Foundation

// 감사 V06: 플래그 단독 호출(`--bounds` 만) 시 args[1] 이 플래그를 앱 이름으로 잡아 항상 실패했다 —
// `--` 접두 인자는 플래그로 구분하고, 첫 비플래그 인자를 앱 이름으로 쓴다(생략 시 기본 Waple).
let args = Array(CommandLine.arguments.dropFirst())
let wantBounds = args.contains("--bounds")
let name = args.first(where: { !$0.hasPrefix("--") }) ?? "Waple"

// 2026-08-17: 이름만으로 찾으면 **남의 창을 찍는다.** 병렬 워크트리 둘이 각자 Waple 을 띄우면
// 먼저 잡히는 창이 이기고, 실제로 한 단위의 캡처에 다른 단위의 UI 가 들어갔다. 캡처를 판정
// 근거로 쓰는 이상 이건 조용한 오염이다 — 스크린샷은 그럴듯하게 나오고 아무 것도 실패하지 않는다.
// PID 를 주면 그 프로세스로 좁힌다. 안 주면 종전대로 이름으로 찾되, 후보가 둘 이상이면
// 아무 거나 고르지 않고 **실패**한다 — 틀린 창을 찍느니 멈추는 게 낫다.
let wantPID: Int? = args.firstIndex(of: "--pid").flatMap { i in
    i + 1 < args.count ? Int(args[i + 1]) : nil
}
if args.contains("--pid"), wantPID == nil {
    fputs("--pid 에 정수 PID 가 필요하다\n", stderr)
    exit(2)
}

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let matches = list.filter { w in
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { return false }
    if let pid = wantPID { return (w[kCGWindowOwnerPID as String] as? Int) == pid }
    return (w[kCGWindowOwnerName as String] as? String) == name
}
// 막으려는 것은 **다른 프로세스**의 창을 찍는 것이지, 한 프로세스가 창을 둘 연 경우가 아니다
// (Waple 은 메인 창 + 설정 창을 동시에 띄우고 스모크가 실제로 그 상태를 찍는다). 그래서
// 판정 기준은 창 개수가 아니라 **서로 다른 PID 의 개수**다 — 여기서 개수로 재면 멀쩡한
// 캡처 경로가 깨진다.
if wantPID == nil {
    let pids = Set(matches.compactMap { $0[kCGWindowOwnerPID as String] as? Int })
    if pids.count > 1 {
        fputs("""
              '\(name)' layer-0 창이 서로 다른 프로세스 \(pids.count)개에 있다 \
              (PID \(pids.sorted().map(String.init).joined(separator: ", "))).
              어느 것을 찍을지 알 수 없어 멈춘다 — 병렬 세션이면 `--pid <PID>` 로 좁혀라.

              """, stderr)
        exit(3)
    }
}
for w in matches {
    if wantBounds {
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
        exit(0)
    }
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
fputs("window not found: \(wantPID.map { "pid \($0)" } ?? name)\n", stderr)
exit(1)
