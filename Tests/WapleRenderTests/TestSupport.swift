import Foundation
import WebKit
import WapleRender

// WapleRenderTests 공용 테스트 스캐폴딩 — 종전 11개 파일의 로컬 중복 사본 통합(2026-07-06 감사 §2).
// 규약: 이 인코딩 바이트가 곧 파서/렌더 테스트의 입력 — 기존 사본과 바이트 동일해야 한다.

/// 메인 런루프를 펌핑하며 JS 평가 결과를 동기 수령. 완료 핸들러는 메인 큐 배달 —
/// 세마포어로 메인 스레드를 막으면 데드락이므로 펌핑으로 대기한다. 타임아웃 시 nil.
func pumpEvalJS(_ web: WKWebView, _ js: String, timeout: TimeInterval = 3) -> Any? {
    var result: Any?
    var done = false
    web.evaluateJavaScript(js) { v, _ in result = v; done = true }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !done, Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    return result
}

/// LE u32 4바이트. truncatingIfNeeded — 일부 테스트가 i32(-1)(TEXB imageFormat v3)을 쓴다.
func i32(_ n: Int) -> Data {
    var v = UInt32(truncatingIfNeeded: n).littleEndian
    return Data(bytes: &v, count: 4)
}

/// 최소 PKGV0001 컨테이너 인코드(ScenePackage.parse 와 동일 구조).
func encodePkg(_ files: [(String, Data)]) -> Data {
    var out = Data()
    let version = "PKGV0001"
    out.append(i32(version.utf8.count)); out.append(version.data(using: .utf8)!)
    out.append(i32(files.count))
    var offset = 0
    for (name, data) in files {
        out.append(i32(name.utf8.count)); out.append(name.data(using: .utf8)!)
        out.append(i32(offset)); out.append(i32(data.count)); offset += data.count
    }
    for (_, data) in files { out.append(data) }
    return out
}

/// 디코드 가능한 단색 .tex = TEXV0005 헤더(34바이트 패딩 → PNG 오프셋 42, 시그니처는 스니프 limit 512 내) + 솔리드 PNG.
func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255, w: Int = 8, h: Int = 8) -> Data {
    var px = [UInt8](); px.reserveCapacity(w * h * 4)
    for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, alpha]) }
    let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
    var tex = Data("TEXV0005".utf8)
    tex.append(Data(repeating: 0, count: 34))
    tex.append(png)
    return tex
}
