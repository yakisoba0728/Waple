import XCTest
import Foundation
import AppKit
import AVFoundation
import WebKit
import WapleCore
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

/// 최소 유효 MDLV0023 평면 메시 데이터(material path = "materials/plane.json"). 정점 4개(quad),
/// 인덱스 6개, pos3+normal3+tangent4+uv2 = 48B/vertex. 3D 렌더 테스트 7개 파일에서 동일 사본이었음.
func planeModel() -> Data {
    var data = Data("MDLV0023".utf8)
    data.append(0)
    func u32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func f32(_ value: Float) {
        var little = value
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    u32(0x0000000f); u32(1); u32(1)
    data.append(Data("materials/plane.json".utf8)); data.append(0)
    u32(0)
    f32(-1); f32(-1); f32(0); f32(1); f32(1); f32(0)
    u32(0x0000000f)
    let vertices: [(Float, Float, Float, Float)] = [
        (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
    ]
    u32(UInt32(vertices.count * 48))
    for (x, y, u, v) in vertices {
        [x, y, 0, 0, 0, 1, 1, 0, 0, -1, u, v].forEach(f32)
    }
    let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
    u32(UInt32(indices.count * MemoryLayout<UInt16>.stride))
    for index in indices {
        var little = index.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    return data
}

/// planeModel() 의 material path 지정판 — Reflect/Refract 테스트에서 동일 사본 2개 통합.
func planeModel(material: String) -> Data {
    var data = Data("MDLV0023".utf8)
    data.append(0)
    func u32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func f32(_ value: Float) {
        var little = value
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    u32(0x0000000f); u32(1); u32(1)
    data.append(Data(material.utf8)); data.append(0)
    u32(0)
    f32(-1); f32(-1); f32(0); f32(1); f32(1); f32(0)
    u32(0x0000000f)
    let vertices: [(Float, Float, Float, Float)] = [
        (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
    ]
    u32(UInt32(vertices.count * 48))
    for (x, y, u, v) in vertices {
        [x, y, 0, 0, 0, 1, 1, 0, 0, -1, u, v].forEach(f32)
    }
    let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
    u32(UInt32(indices.count * MemoryLayout<UInt16>.stride))
    for index in indices {
        var little = index.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    return data
}

/// 임시 디렉토리 생성(UUID 기반 고유 경로). Video/Media 테스트 3개 파일 동일 사본 통합.
func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 최소 비디오 WallpaperProject 생성. Video/Media 테스트 3개 파일 동일 사본 통합.
/// 주의: 이름이 짧지만 호출부가 `project(id:fileName:dir:)` 로 고정되어 이 시그니처 유지.
func project(id: String, fileName: String, dir: URL) -> WallpaperProject {
    WallpaperProject(id: id, type: .video, fileName: fileName, previewName: nil,
                     title: id, tags: [], contentRating: nil, workshopId: nil,
                     dependency: nil, folderURL: dir)
}

/// makeTex(format:w:h:payload:) — 최소 TEXV0005+TEXI0001+TEXB0001 컨테이너.
/// VideoTextureExtractor/VideoBackedSceneCapture 테스트 동일 사본 통합.
func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
    var b: [UInt8] = []
    b += bytes(tag("TEXV0005"), tag("TEXI0001"))
    b += bytes(i32b(format), i32b(0), i32b(w), i32b(h), i32b(w), i32b(h))
    b += bytes(tag("TEXB0001"), payload)
    return Data(b)
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

// MARK: - 동봉 WEAssets 루트 (2026-08-25 통합)

/// 동봉 `WEAssets` 루트. **이 파일의 위치**에서 리포 루트로 거슬러 올라간다.
///
/// **[2026-08-25] 종전엔 작업 디렉터리(cwd)에서 8단계 상향 탐색했다.** 그 사본이 9곳에 흩어져
/// 있었고 전부 같은 함정을 공유했다 — 실패하면 `nil` 을 돌려주고 호출부가 `XCTSkip` 으로
/// 사라진다. `cd /tmp && swift test --package-path <repo>` 나 Xcode 실행처럼 cwd 가 리포 밖인
/// 실행에서는 동봉 자산 오라클 8건이 통째로 조용히 빠지고, 그 상태로 초록이 뜬다.
///
/// **WEAssets 2,940 파일은 리포에 커밋돼 있다.** 즉 "못 찾음" 은 환경 조건이 아니라 버그다.
/// 소스 파일 위치는 cwd 와 달리 실행 방식에 흔들리지 않는다 — `LocalizationCoverageTests` 와
/// `TexSpriteSheetBlendTests` 가 이미 쓰던 규약이고, 여기서 그쪽으로 통일한다.
///
/// `WAPLE_WE_ASSETS` 오버라이드는 유지한다(리눅스 하네스가 넣는다). 오버라이드가 가리키는
/// 트리에 특정 파일이 없어서 나는 스킵은 정상이다 — 여기서 막는 것은 **루트 자체를 못 찾는**
/// 경우다. `testBundledWEAssetsRootIsAlwaysFindable` 이 그 자리를 실패로 낸다.
func bundledWEAssetsRoot() -> URL? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
       fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    let repoRoot = URL(fileURLWithPath: #filePath)   // Tests/<Target>/TestSupport.swift
        .deletingLastPathComponent()                  // Tests/<Target>
        .deletingLastPathComponent()                  // Tests
        .deletingLastPathComponent()                  // repo root
    let cand = repoRoot.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
    return fm.fileExists(atPath: cand.path) ? cand : nil
}

// MARK: - 오디오 출력 가용성 게이트 (2026-08-25)

/// **기본 오디오 출력이 실제로 재생을 시작할 수 있는가.**
///
/// [2026-08-25] 이 게이트가 없어서 실측으로 당했다. 개발 머신의 기본 출력이 블루투스 동글
/// (Sennheiser BTD 700)이었는데 헤드셋이 꺼지자, 장치는 `system_profiler` 목록에 **그대로 남아
/// 있으면서** `AVAudioPlayer.play()` 가 `false` 를 돌려줬다. 결과는 `isPlaying == true` 를 단언하는
/// 테스트 **12개(단언 15건)** 가 한꺼번에 빨개지는 것이고, 실패 메시지는 전부 그냥
/// `XCTAssertTrue failed` 다 — 원인을 가리키는 신호가 하나도 없다.
///
/// 그 상태에서 소스 변경을 의심하느라 시간을 태웠다. 되돌려도 같은 15건이 실패해서야 환경임을
/// 알았고, 무음 WAV 를 `AVAudioPlayer` 로 열어 `play()` 를 부르는 최소 재현으로 확정했다.
///
/// 그래서 **원인을 말하는 스킵**으로 바꾼다. 이 리포는 스킵을 싫어하지만(스킵은 실패로 보고되지
/// 않는다), 그 위험은 CI 의 스킵 상한 100 이 받아 준다 — 무코퍼스 기준 스킵이 63~64 이므로
/// 이 12건이 CI 에서 풀리지 않으면 76 이 되고, 그 변화는 census 스텝에 그대로 찍힌다.
/// **CI(macos-26)에는 재생 가능한 출력 장치가 있어서 이 게이트는 CI 에서 열린다** — 즉 회귀
/// 감시는 그대로 유지되고, 헤드셋을 끈 노트북에서만 조용해진다.
///
/// 한 번만 재고 캐시한다(테스트마다 재면 프로세스당 12회 장치 접근이다).
enum AudioOutputProbe {
    nonisolated(unsafe) private static var cached: Bool?

    /// 무음 WAV 0.1초를 볼륨 0 으로 재생 시도 — 소리는 나지 않고 장치 가용성만 본다.
    static var canStartPlayback: Bool {
        if let c = cached { return c }
        let sr = 44100, frames = sr / 10, bytes = frames * 2
        var d = Data()
        func le32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); le32(36 + bytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); le32(16); le16(1); le16(1); le32(sr)
        le32(sr * 2); le16(2); le16(16)
        d.append(Data("data".utf8)); le32(bytes); d.append(Data(count: bytes))
        let ok: Bool
        if let p = try? AVAudioPlayer(data: d) {
            p.volume = 0
            ok = p.play() && p.isPlaying
            p.stop()
        } else {
            ok = false
        }
        cached = ok
        return ok
    }
}

/// 재생 시작을 단언하는 테스트 앞에 둔다. 장치가 없으면 **원인을 말하며** 스킵한다.
func skipUnlessAudioOutputCanPlay(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipUnless(AudioOutputProbe.canStartPlayback,
                      "기본 오디오 출력이 재생을 시작하지 못한다(AVAudioPlayer.play() == false). "
                        + "블루투스 헤드셋이 꺼져 있으면 장치는 목록에 남아도 재생이 안 된다 — "
                        + "코드 결함이 아니라 환경이다. 출력 장치를 바꾸거나 헤드셋을 켜고 다시 돌려라.",
                      file: file, line: line)
}
