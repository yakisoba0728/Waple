import Foundation
import AppKit
import AVFoundation
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

/// 위 i32 의 [UInt8] 반환판(바이트 동일) — 헤더를 [UInt8] 로 조립하는 픽스처용.
func i32b(_ n: Int) -> [UInt8] { Array(i32(n)) }

/// 청크를 순서대로 이어붙인다. 긴 `+` 체인(6~10항)은 항마다 오버로드 후보가 곱해져 타입체커가
/// 지수 폭발한다 — 특히 Data 와 [UInt8] 가 한 체인에 섞이면 항마다 결과 타입 후보가 둘로 갈린다.
/// 구형 툴체인(CI 러너 Xcode 16.2 / Swift 6.0.3)에선 "unable to type-check this expression in
/// reasonable time" 컴파일 에러로 CI 를 세웠고, 최신 툴체인에서도 한 식에 1.3초를 태웠다.
/// 인자 타입이 [UInt8] 로 고정되는 가변인자 헬퍼는 항 수에 선형이다.
func bytes(_ chunks: [UInt8]...) -> [UInt8] { chunks.flatMap { $0 } }

/// NUL 종단 태그 바이트("TEXV0005" + 0x00) — 컨테이너 시그니처/블록 헤더 규약.
func tag(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

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

/// 세로 그라디언트 .tex(디코드 가능) — row 0(이미지 상단)=top 색, 마지막 row(하단)=bottom 색 선형보간.
/// 뒤집힘 방향(top/bottom) 단언 회귀 테스트 전용(F1: 커스텀 2D 레이어 shader UV 규약).
func verticalGradientTex(top: (UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8), w: Int = 8, h: Int = 8) -> Data {
    var px = [UInt8](); px.reserveCapacity(w * h * 4)
    for y in 0..<h {
        let t: Float = h > 1 ? Float(y) / Float(h - 1) : 0
        let r = UInt8(Float(top.0) + (Float(bottom.0) - Float(top.0)) * t)
        let g = UInt8(Float(top.1) + (Float(bottom.1) - Float(top.1)) * t)
        let b = UInt8(Float(top.2) + (Float(bottom.2) - Float(top.2)) * t)
        for _ in 0..<w { px.append(contentsOf: [r, g, b, 255]) }
    }
    let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
    var tex = Data("TEXV0005".utf8)
    tex.append(Data(repeating: 0, count: 34))
    tex.append(png)
    return tex
}

/// 가로 그라디언트 .tex(디코드 가능) — column 0(이미지 좌측)=left 색, 마지막 column(우측)=right 색 선형보간.
/// 좌우 미러링(음수 scale.x) 단언 회귀 테스트 전용(F5: 3D 빌보드 스케일 부호).
func horizontalGradientTex(left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8), w: Int = 8, h: Int = 8) -> Data {
    var px = [UInt8](); px.reserveCapacity(w * h * 4)
    for _ in 0..<h {
        for x in 0..<w {
            let t: Float = w > 1 ? Float(x) / Float(w - 1) : 0
            let r = UInt8(Float(left.0) + (Float(right.0) - Float(left.0)) * t)
            let g = UInt8(Float(left.1) + (Float(right.1) - Float(left.1)) * t)
            let b = UInt8(Float(left.2) + (Float(right.2) - Float(left.2)) * t)
            px.append(contentsOf: [r, g, b, 255])
        }
    }
    let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
    var tex = Data("TEXV0005".utf8)
    tex.append(Data(repeating: 0, count: 34))
    tex.append(png)
    return tex
}

/// 최소 유효 mp4 생성(AVAssetWriter, 4프레임 64×64 h264).
func makeTinyMP4(at url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<4 {
        // writer 실패 시 input 은 영원히 ready 되지 않을 수 있다 — status 검사 + 타임아웃으로 행 방지.
        let deadline = Date(timeIntervalSinceNow: 5)
        while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard writer.status == .writing else {
            throw NSError(domain: "makeTinyMP4", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter 실패: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"])
        }
        guard input.isReadyForMoreMediaData else {
            throw NSError(domain: "makeTinyMP4", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "isReadyForMoreMediaData 대기 타임아웃(5s)"])
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "makeTinyMP4", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "pixelBufferPool 생성 실패"])
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            throw NSError(domain: "makeTinyMP4", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "CVPixelBuffer 생성 실패"])
        }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
        throw NSError(domain: "makeTinyMP4", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "finishWriting 실패: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"])
    }
}

/// F5-2 테스트 전용 — 4사분면 색(저장 그대로: TL=빨강/TR=초록/BL=파랑/BR=노랑) + 지정 preferredTransform
/// 태그를 가진 정사각형 mp4(2프레임). 정사각형이라 회전해도 치수가 불변이라 헤드리스/라이브 대조가 단순해진다.
func makeOrientedMP4(at url: URL, transform: CGAffineTransform, size: Int = 64) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size,
        AVVideoHeightKey: size,
    ])
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size,
        kCVPixelBufferHeightKey as String: size,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let half = size / 2
    for i in 0..<2 {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard writer.status == .writing else {
            throw NSError(domain: "makeOrientedMP4", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter 실패: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"])
        }
        guard input.isReadyForMoreMediaData else {
            throw NSError(domain: "makeOrientedMP4", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "isReadyForMoreMediaData 대기 타임아웃(5s)"])
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "makeOrientedMP4", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "pixelBufferPool 생성 실패"])
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else {
            throw NSError(domain: "makeOrientedMP4", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "CVPixelBuffer 생성 실패"])
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            let px = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<size {
                    let o = y * bpr + x * 4
                    let bgr: (UInt8, UInt8, UInt8)
                    if x < half && y < half { bgr = (0, 0, 255) }        // TL 빨강
                    else if x >= half && y < half { bgr = (0, 255, 0) }  // TR 초록
                    else if x < half && y >= half { bgr = (255, 0, 0) }  // BL 파랑
                    else { bgr = (0, 255, 255) }                        // BR 노랑
                    px[o] = bgr.0; px[o + 1] = bgr.1; px[o + 2] = bgr.2; px[o + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
        throw NSError(domain: "makeOrientedMP4", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "finishWriting 실패: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"])
    }
}

/// 캡처 PNG 의 평균 luma((r+g+b)/3 평균) — 최대 ~40×40 그리드 서브샘플. 실패 시 -1.
func avgLuma(_ url: URL) -> Double {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return -1 }
    var sum = 0.0; var n = 0
    let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 40)
    for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            if let c = rep.colorAt(x: x, y: y) {
                sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3.0; n += 1
            }
        }
    }
    return n > 0 ? sum / Double(n) : -1
}
