import Foundation
import AppKit
import CoreGraphics
import WapleCore
import WapleRender
import WapleSnapshot

/// 씬 픽셀 스냅샷 회귀 파이프라인(캡처/비교 드라이버).
/// 렌더러는 호출만 — SceneRenderer.mount/captureFrames/pause/setSpectrum 공개 API 재사용.
/// 헤드리스 캡처 규약은 RealPackagesGroundTruthTests 와 동일:
/// nowPlaying 스텁 + 고정 시각 t + 오디오 무신호(pause+silent) + 고정 파티클 시드로 결정성 확보.
enum SnapshotPipeline {

    // 고정 캡처 조건(변경 시 베이스라인 재생성 필요).
    // WAPLE_THUMB_W/H: 골든 대비 고해상 단건 캘리브 캡처용 오버라이드(예: HDR bloom #22 — 256×144 는
    // 글로우 반경/강도 판독 불가). 스냅샷 비교는 크기 불일치를 즉시 명시 오류로 거른다(SnapshotCompare).
    static let thumbW = ProcessInfo.processInfo.environment["WAPLE_THUMB_W"].flatMap(Int.init) ?? 256
    static let thumbH = ProcessInfo.processInfo.environment["WAPLE_THUMB_H"].flatMap(Int.init) ?? 144
    static let captureT: Float = 6.0   // 인트로 페이드가 끝난 정상상태(GT 규약과 동일)
    /// F2-puppet①: 애니메이션 시간의존 누적 결함(퍼펫 등)은 t=6.0 단일 프레임으로 노출되지 않는다.
    /// WAPLE_CAPTURE_TIME=<초>(콤마구분 복수 가능, 예 "0,2,6,12,30")로 캡처 시각을 오버라이드할 수 있게
    /// 확장 — 미설정 시 [captureT] 그대로라 코퍼스 --capture/--compare(베이스라인)는 무회귀. 다중 시각을
    /// 지정하면 captureFrame() 이 한 마운트에서 전부 렌더하고, runCapture() 가 captureT 에 대응하는
    /// 프레임만 기존 <id>.png 캐논 썸네일/매니페스트 entry 로 쓰며 나머지는 진단용 <id>_t<초>.png 로
    /// thumbs/ 옆에 남긴다(매니페스트 스키마 불변 — SnapshotEntry/SnapshotManifest 필드 추가 없음).
    static let captureTimes: [Float] = parseCaptureTimes(
        ProcessInfo.processInfo.environment["WAPLE_CAPTURE_TIME"], fallback: [captureT])
    /// 캐논(매니페스트 entry/self-check/해시 대상) 캡처 시각 — captureTimes 에 captureT 가 포함되면 그것,
    /// 아니면(명시적으로 6.0 을 뺀 진단 실행) 첫 값으로 폴백. 기본 경로(오버라이드 없음)에선 항상 captureT.
    static let primaryCaptureTime: Float = captureTimes.contains(captureT) ? captureT : (captureTimes.first ?? captureT)
    /// 저장이 아니라 **계산** 프로퍼티다. `FitMode` 는 WapleRender 의 public enum 이라 자동
    /// `Sendable` 추론을 못 받고, `static let` 이면 "비-Sendable 타입의 전역 가변 상태" 경고가
    /// 붙는다(엄격 동시성). 값이 상수 하나뿐이라 매번 만들어도 되고 그러면 공유 상태 자체가 없다.
    static var fitMode: FitMode { .fill }
    /// 벽시계 텍스트(시계/날짜 레이어)가 재캡처마다 동일 픽셀이 되도록 JS Date 무인자/now 를 핀하는 고정
    /// epoch(ms) — 임의 상수(2024-01-01 12:00:00 UTC = KST 21:00:00). 변경 시 시계/날짜 씬 베이스라인
    /// 재생성 필요. S4①(2026-07-27): getHours() 등 로컬 getter 는 TextScriptEngine.dateOverrideJS 가
    /// KST(UTC+9) 고정 오프셋으로 계산하므로 이 상수의 "KST 21:00" 해석은 캡처 머신의 실제 시스템 TZ 와
    /// 무관하게 항상 성립(호스트 TZ 미고정이 원인이던 하네스 결함 수정).
    static let captureEpochMillis: Double = 1_704_110_400_000
    /// F1-nondet(2026-07-28): 씬 스크립트 `Math.random()` 결정화 시드 — 임의 상수(변경 시 팔레트/랜덤
    /// 분기 의존 씬 베이스라인 재생성 필요). TextScriptEngine.captureRandomSeed 참고(팔레트 컨트롤러
    /// 실물 3300031038 — localStorage 미보유 헤드리스 마운트마다 다른 초기 팔레트를 골라 셀프체크
    /// 비결정으로 잡히던 근본원인).
    static let captureRandomSeed: UInt64 = 0xC0FFEE_1038

    /// 캡처 포인터 핀 값(0..1 UV, 상단 원점) — 마우스 미구동 규약과 동일한 중앙.
    /// 변경 시 포인터 반응 씬(g_PointerPosition 소비) 베이스라인 재생성 필요.
    static let capturePointerUV = SIMD2<Float>(0.5, 0.5)

    /// 폴링 없이 항상 "정지" — 미디어 씬이 osascript 를 스폰하지 않게(결정적·TCC 무).
    struct StoppedNowPlaying: NowPlayingProvider { func fetch() -> NowPlayingInfo? { nil } }

    enum Frame { case pixels([UInt8], png: URL); case empty }

    // MARK: 씬 열거

    /// F520: DeepScan.projectContainer 와 동일 규칙 — root 가 개발 루트(하위에 backgrounds/ 디렉터리)면
    /// 그 backgrounds 를, backgrounds 디렉터리 자체(또는 단일 씬 폴더)가 직접 지정되면 그대로 쓴다.
    /// 종전엔 무조건 <root>/backgrounds 만 열어서 직접 지정 시 scenes=0 인데도 exit 0 이었다.
    static func sceneContainer(root: String) -> URL {
        let r = URL(fileURLWithPath: root)
        let bg = r.appendingPathComponent("backgrounds", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: bg.path, isDirectory: &isDir), isDir.boolValue {
            return bg.standardizedFileURL
        }
        return r
    }

    static func sceneFolders(root: String) -> [URL] {
        let base = sceneContainer(root: root)
        let fm = FileManager.default
        func isScene(_ u: URL) -> Bool {
            fm.fileExists(atPath: u.appendingPathComponent("scene.pkg").path)
                || fm.fileExists(atPath: u.appendingPathComponent("gifscene.pkg").path)
        }
        if isScene(base) { return [base] }   // 단일 씬 폴더 직접 지정
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return items.filter(isScene).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: 단일 캡처(마운트 → 고정조건 렌더 → 256×144 PNG)

    /// 프레임을 내면 .pixels(정규화 RGBA + PNG경로), 픽셀이 없으면(비디오-백드 등) .empty.
    /// 마운트 스로우는 호출자로 전파(→ failures 버킷). captureTimes 가 복수면 한 마운트에서 전부 렌더해
    /// tmp 에 frame_t<초>.png 로 남기고(진단용, runCapture 가 골라 복사), 반환값은 항상 primaryCaptureTime
    /// 프레임 하나 — 기본 경로(오버라이드 없음)에선 종전과 완전히 동일한 단일 프레임 캡처.
    static func captureFrame(project: WallpaperProject, into tmp: URL) throws -> Frame {
        // F2-puppet①: tmp 는 runCapture 호출 전체(전 씬 + self-check 2차 캡처)에 걸쳐 재사용되는 PID-스코프
        // 고정 경로 — 이번 호출이 특정 시각의 프레임을 못 내면(writeFramePNG 실패) 그 파일명 자리에 "이전
        // 씬/이전 호출"이 남긴 동명 PNG가 그대로 남아 있을 수 있다. 매 호출 시작에 이번에 요청한 시각들의
        // 예상 파일명을 먼저 지워 "이번 호출이 실제로 쓴 파일만" 아래서 보이게 한다.
        let fm = FileManager.default
        for t in captureTimes {
            try? fm.removeItem(at: tmp.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png"))
        }
        let r = SceneRenderer()
        r.nowPlayingProvider = StoppedNowPlaying()
        // `NSView.init(frame:)` 은 SDK 가 메인 액터 전용으로 선언한 API 다. 이 CLI 는 파이프라인
        // 전체를 `main.swift` 최상위(= 메인 스레드)에서 **동기**로 실행한다 — 이 파일에도
        // ProfilePipeline 에도 디스패치가 하나도 없고, 병렬을 쓰는 것은 DeepScan 뿐이다.
        // 그래서 `assumeIsolated` 는 참인 단언이고, 나중에 누가 이 경로를 오프메인으로 옮기면
        // 조용히 어긋나는 대신 즉시 트랩된다.
        let container = MainActor.assumeIsolated { NSView(frame: NSRect(x: 0, y: 0, width: thumbW, height: thumbH)) }
        try r.mount(in: container, project: project)
        r.pause()                    // 라이브 입력(오디오 캡처·시차) 정지 → 결정성
        r.setSpectrum(.silent)       // 오디오-반응 효과를 무신호로 고정
        let urls = r.captureFrames(width: thumbW, height: thumbH, times: captureTimes, toDir: tmp)
        r.teardown()
        let primaryName = "frame_t\(String(format: "%.1f", primaryCaptureTime)).png"
        if let exact = urls.first(where: { $0.lastPathComponent == primaryName }) {
            guard let rgba = pngToRGBA(exact, width: thumbW, height: thumbH) else { return .empty }
            return .pixels(rgba, png: exact)
        }
        // primaryCaptureTime 프레임 자체가 없다(예: captureTimes 가 명시적으로 captureT 를 빼고 지정돼
        // primaryCaptureTime 이 첫 값으로 폴백했는데 그 프레임마저 못 나온 경우) — urls.first 로 대체하되
        // 매니페스트의 captureTime 필드(=primaryCaptureTime)와 실제 반환 프레임의 시각이 어긋난다는 사실을
        // 표면화한다(조용히 다른 시각 프레임을 "캐논"으로 둔갑시키지 않기 위함).
        guard let png = urls.first, let rgba = pngToRGBA(png, width: thumbW, height: thumbH) else { return .empty }
        fputs("[snap] ⚠️ primaryCaptureTime(\(primaryCaptureTime)) 프레임 없음 — \(png.lastPathComponent) 로 대체(매니페스트 captureTime 값과 실제 프레임 시각 불일치 가능)\n", stderr)
        return .pixels(rgba, png: png)
    }

    /// PNG → width×height RGBA8(premultipliedLast) 정규화 바이트. 캡처/비교가 동일 경로로 로드해야 diff 가 일관.
    /// F147: 원본 PNG 픽셀 크기가 요청 크기와 다르면(캡처 경로 해상도 버그 등) 조용히 리스케일해 삼키지
    /// 않고 stderr 경고 — diff 수학 자체는 항상 같은 길이 배열끼리 비교해야 하므로 리샘플은 유지하되
    /// 불일치 사실만 드러낸다(호출자는 이미 매니페스트 크기로 요청해 정상 caso 는 항상 일치).
    static func pngToRGBA(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if cg.width != width || cg.height != height {
            fputs("[snap] ⚠️ PNG 실제 크기(\(cg.width)x\(cg.height)) ≠ 요청 크기(\(width)x\(height)) — \(url.lastPathComponent), 강제 리스케일해 비교합니다\n", stderr)
        }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none   // 1:1 이라 무관하나 결정성 위해 고정
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return px
    }

    // MARK: --capture (자기-일관 셀프체크 포함 → 결정/비결정 자동 분류)

    static func runCapture(root: String, outDir: URL, label: String?) -> Int32 {
        let start = Date()
        let sha = gitSHA()
        let lbl = label ?? sha
        let dst = outDir.appendingPathComponent(lbl, isDirectory: true)
        let thumbs = dst.appendingPathComponent("thumbs", isDirectory: true)
        // F148: PID 로 스코프 — 동시 두 프로세스가 같은 고정 경로에 쓰면 서로의 캡처를 덮어써 매니페스트
        // 해시/썸네일 불일치나 쓰기 도중 읽기로 손상된 PNG "empty" 오분류가 날 수 있었다.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_snap_cap_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let restore = pinRenderSettings(root: root)
        defer { restore() }

        let folders = sceneFolders(root: root)
        // F520: 루트 오지정(backgrounds/단일 씬 폴더 미지정, 경로 오타 등)으로 씬 0개면 빈 매니페스트를
        // 쓰고 exit 0 → CI 가 성공으로 오인(F150/F151 이 막은 바로 그 류). 경고 후 비정상 종료.
        guard !folders.isEmpty else {
            fputs("[snap] ⚠️ 씬 0개 — root 가 개발 루트/backgrounds/단일 씬 폴더 중 하나인지 확인: \(root)\n", stderr)
            return 2
        }
        var entries: [SnapshotEntry] = [], empties: [String] = [], failures: [String] = []
        var nonDet: [String] = []

        for folder in folders {
            let id = folder.lastPathComponent
            autoreleasepool {
                do {
                    let project = try ProjectJSONParser.parse(folderURL: folder)
                    guard case let .pixels(rgba1, png1) = try captureFrame(project: project, into: tmp) else {
                        empties.append(id); return
                    }
                    // 썸네일 복사는 2차 캡처 전에 — 캡처 파일명이 고정(frame_t6.0.png)이라 셀프체크가
                    // png1 을 덮어쓰면 썸네일(2차)과 manifest hash/meanLuma(1차 rgba1)가 영구 불일치.
                    try? fm.removeItem(at: thumbs.appendingPathComponent("\(id).png"))
                    // F524: 복사 실패를 try? 로 삼키면 매니페스트 entry 만 남아 이후 compare 가 skippedMissing
                    // 으로 회귀 커버리지를 조용히 잃는다 — 실패를 stderr 로 표면화(캡처 자체는 계속).
                    do { try fm.copyItem(at: png1, to: thumbs.appendingPathComponent("\(id).png")) }
                    catch { fputs("[snap] ⚠️ 썸네일 복사 실패 \(id): \(error) — 이후 compare 에서 이 씬은 skip 됩니다\n", stderr) }
                    // F2-puppet①: WAPLE_CAPTURE_TIME 로 다중 시각을 지정했으면 진단용 부가 프레임을
                    // <id>_t<초>.png 로 thumbs/ 옆에 남긴다(매니페스트 entry/self-check 은 캐논 1장만 —
                    // 스키마 불변). 셀프체크(2차 캡처)가 tmp 를 덮어쓰기 전에 먼저 복사해야 한다.
                    if captureTimes.count > 1 {
                        for t in captureTimes where t != primaryCaptureTime {
                            let name = "frame_t\(String(format: "%.1f", t)).png"
                            let src = tmp.appendingPathComponent(name)
                            guard fm.fileExists(atPath: src.path) else { continue }
                            let dst = thumbs.appendingPathComponent("\(id)_t\(String(format: "%.1f", t)).png")
                            try? fm.removeItem(at: dst)
                            try? fm.copyItem(at: src, to: dst)
                        }
                    }
                    // 셀프체크: 재마운트로 두 번째 캡처 → 프레임 산출 씬만 2× (empty/fail 은 1×).
                    //
                    // [정정 2026-08-01] 종전 주석은 "**독립** 재마운트" 였는데 독립이 아니다.
                    // 2차 캡처가 **같은 프로세스** 안에서 일어나므로 프로세스 시작 시 정해지는 것
                    // (RNG 시드·정적 캐시·딕셔너리 순회 순서·셰이더 컴파일 순서 등)이 두 캡처에서
                    // 동일하다. 그 값이 실행마다 달라지면 화면이 달라지는데 여기선 항상 일치한다.
                    // 실측(macOS 2026-08-01): 같은 커밋·같은 빌드로 전 코퍼스를 두 번 떠서 대조하니
                    // **29종이 실행마다 다른데** 전부 deterministic=true / selfMaxDiff=0 으로 기록됐다.
                    // 그래서 이 필드는 이름이 약속하는 "재현 가능한가" 가 아니라
                    // **"같은 프로세스 안에서 두 번 그리면 같은가"** 만 답한다.
                    // 여파: SnapshotCompare 가 이 값으로 strict/lax 임계를 고른다(:85).
                    // 그 선택줄 자체는 **맞다**(결정적→strict, 비결정→lax). 문제는 분류가 틀려서
                    // 실제로는 비결정인 29종이 strict 로 새는 것 — 고칠 곳은 :85 가 아니라 여기다.
                    // 고치려면 2차 캡처를 별도 프로세스에서 돌리거나 교차 실행 재현성을 별도 필드로 둔다.
                    // 근거·수치: spec/golden/gate-analysis.json (oracle.gate.selfCheckIsIntraProcess)
                    // F522: 스키마 규약(SnapshotEntry.selfMaxDiff "셀프체크 안 했으면 -1")에 맞춰 2차 캡처가
                    // 픽셀을 내지 못하면 -1 유지 — 종전엔 0 이 기록돼 "실행했는데 최대차 0"과 구분 불가였다.
                    var deterministic = true, selfMax = -1, note: String? = nil
                    if case let .pixels(rgba2, _) = (try? captureFrame(project: project, into: tmp)) ?? .empty {
                        let sd = diffRGBA(rgba1, rgba2)
                        selfMax = sd.maxAbsDiff
                        deterministic = passes(sd, .selfConsistent)
                        if !deterministic { note = "self-diff mean=\(String(format: "%.2f", sd.meanAbsDiff)) frac=\(String(format: "%.4f", sd.fracExceeding))"; nonDet.append(id) }
                    } else {
                        deterministic = false; note = "second capture empty"; nonDet.append(id)
                    }
                    entries.append(SnapshotEntry(id: id, width: thumbW, height: thumbH,
                                                 hash: fnv1a(rgba1), meanLuma: meanLuma(rgba: rgba1),
                                                 deterministic: deterministic, selfMaxDiff: selfMax, note: note))
                } catch {
                    failures.append(id)
                    fputs("[snap] mount FAILED \(id): \(error)\n", stderr)
                }
            }
        }

        let manifest = SnapshotManifest(
            gitSHA: sha, label: lbl, thumbWidth: thumbW, thumbHeight: thumbH,
            captureTime: primaryCaptureTime, createdAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries.sorted { $0.id < $1.id }, empties: empties.sorted(), failures: failures.sorted(),
            activeDebugGates: activeDebugGates())
        do {
            try manifest.encoded().write(to: dst.appendingPathComponent("manifest.json"))
        } catch {
            fputs("[snap] manifest write failed: \(error)\n", stderr); return 2
        }

        let det = entries.count - nonDet.count
        let dt = Date().timeIntervalSince(start)
        print("""
        [snap capture] \(lbl)  (git \(sha))
          scenes=\(folders.count)  captured=\(entries.count)  empty=\(empties.count)  failed=\(failures.count)
          determinism: 결정 \(det) / 비결정 \(nonDet.count)\(nonDet.isEmpty ? "" : "  " + nonDet.prefix(12).joined(separator: ","))
          empties(범위 밖 비디오-백드 추정 포함): \(empties.prefix(20).joined(separator: ","))\(empties.count > 20 ? " …+\(empties.count - 20)" : "")
          elapsed=\(String(format: "%.1f", dt))s  →  \(dst.path)
        """)
        if !failures.isEmpty { fputs("[snap] ⚠️ \(failures.count) 씬 마운트 실패: \(failures.joined(separator: ","))\n", stderr) }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: 공용 설정 핀(base-assets + fitMode) — GT 하니스와 동일 규약

    static func pinRenderSettings(root: String) -> () -> Void {
        let oldFit = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = fitMode
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        TextScriptEngine.captureDateEpochMillis = captureEpochMillis
        let oldRandomSeed = TextScriptEngine.captureRandomSeed
        TextScriptEngine.captureRandomSeed = captureRandomSeed
        // 포인터 핀(2026-08-02) — 이걸 안 하면 캡처 시점의 **실제 마우스 커서 위치**가
        // g_PointerPosition 으로 들어가 픽셀에 구워진다(세션마다 29종이 달랐던 근본원인,
        // spec/golden/nondeterminism.json → oracle.nondet.rootCause). 중앙 고정 = 마우스 미구동 규약.
        let oldPointer = SceneRenderer.capturePointerUV
        SceneRenderer.capturePointerUV = capturePointerUV
        let assetsPath = ProcessInfo.processInfo.environment["WAPLE_BASE_ASSETS"] ?? (root + "/assets")
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        return { SceneRenderSettings.fitMode = oldFit; BaseAssetsSettings.baseAssetsDirectory = oldBase
                 TextScriptEngine.captureDateEpochMillis = oldEpoch
                 TextScriptEngine.captureRandomSeed = oldRandomSeed
                 SceneRenderer.capturePointerUV = oldPointer }
    }

    /// F145: 렌더 출력을 변형하는 WAPLE_* 디버그 게이트(mount/encode 시 ProcessInfo 에서 라이브로 읽힘 —
    /// pinRenderSettings 가 핀하는 fitMode/base-assets/captureEpoch 와 달리 이들은 캡처 파이프라인이
    /// 중화하지 않는다) 중 현재 활성인 것만 이름을 모아 매니페스트에 기록. 캡처 당시 상태를 남겨야
    /// runCompare 가 베이스라인과의 게이트 불일치(=오염 가능성)를 사후에라도 경고할 수 있다.
    static func activeDebugGates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var active: [String] = []
        if env["WAPLE_NO_BLOOM"] != nil { active.append("WAPLE_NO_BLOOM") }
        if let v = env["WAPLE_LAYER_TRUNC"], Int(v) != nil { active.append("WAPLE_LAYER_TRUNC=\(v)") }
        if let v = env["WAPLE_MP_TRUNC"], Int(v) != nil { active.append("WAPLE_MP_TRUNC=\(v)") }
        if let v = env["WAPLE_EFFECT_SKIP"], !v.isEmpty { active.append("WAPLE_EFFECT_SKIP=\(v)") }
        if env["WAPLE_DISABLE_TRANSLATED"] == "1" { active.append("WAPLE_DISABLE_TRANSLATED=1") }
        if env["WAPLE_BC_NATIVE"] == "0" { active.append("WAPLE_BC_NATIVE=0") }
        // F2-puppet 지적: WAPLE_CAPTURE_TIME(위 captureTimes)도 캡처 시각을 바꿔 diff 결과를 좌우하는
        // 렌더-변형 게이트인데 이 목록에 빠져 있으면 runCompare 의 F145 게이트 불일치 경고와 매니페스트의
        // activeDebugGates 기록 양쪽에서 누락된다. fallback([captureT])과 실제로 다를 때만 등재해
        // "값은 있지만 기본값과 같아 무효과"인 경우를 활성으로 오표기하지 않는다.
        if env["WAPLE_CAPTURE_TIME"] != nil, captureTimes != [captureT] {
            active.append("WAPLE_CAPTURE_TIME=\(captureTimes.map { "\($0)" }.joined(separator: ","))")
        }
        return active.sorted()
    }

    /// cwd 의 git HEAD 단축 sha(레이블 기본값용 — 코드 리포 버전이 의도, 코퍼스 root 와 무관).
    /// 리포 밖에서 실행하면 "unknown" — 그럴 땐 --label 로 지정.
    static func gitSHA() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "unknown" }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "unknown" : s
    }
}
