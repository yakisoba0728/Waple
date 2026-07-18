import Foundation
import WapleCore
import WapleSnapshot

/// --compare <baselineDir>: 현재 빌드를 씬별 1회 캡처해 베이스라인 썸네일과 픽셀 diff.
/// 베이스라인의 entries(픽셀 산출 씬)만 순회 — empties(비디오-백드 등 범위 밖)는 건너뛴다.
/// 단, entry 였던 씬이 지금 empty/실패면 "렌더→무픽셀" 회귀로 잡는다.
/// 임계: 결정 씬은 strict, 비결정 씬은 lax. 종료코드: 결정 FAIL 또는 렌더→무픽셀 회귀가 있으면 1.
extension SnapshotPipeline {

    struct CompareRow {
        let id: String
        let metrics: DiffMetrics
        let deterministic: Bool
        let pass: Bool
    }

    static func runCompare(root: String, baselineDir: URL) -> Int32 {
        let start = Date()
        guard let mdata = try? Data(contentsOf: baselineDir.appendingPathComponent("manifest.json")),
              let baseline = try? SnapshotManifest.decode(mdata) else {
            fputs("[snap] 베이스라인 매니페스트를 읽을 수 없음: \(baselineDir.path)/manifest.json\n", stderr)
            return 2
        }
        // 썸네일 크기 불일치 = 구 베이스라인 — min-길이 쓰레기 비교(무증상 대량 오탐 FAIL) 대신 명시 에러.
        guard baseline.thumbWidth == thumbW, baseline.thumbHeight == thumbH else {
            fputs("[snap] 베이스라인 썸네일 크기 \(baseline.thumbWidth)x\(baseline.thumbHeight) ≠ 현재 \(thumbW)x\(thumbH) — --capture 로 베이스라인 재생성 필요\n", stderr)
            return 2
        }
        // F145: 베이스라인 캡처 당시 활성이던 렌더-변형 게이트와 지금 활성인 게이트가 다르면 diff 가
        // 게이트 차이 때문일 수 있음을 경고(하드 실패는 아님 — 게이트는 기본적으로 전부 꺼져 있어야
        // 정상이므로 대부분의 실행에선 둘 다 빈 배열이라 무해).
        let baselineGates = baseline.activeDebugGates ?? []
        let currentGates = SnapshotPipeline.activeDebugGates()
        if baselineGates != currentGates {
            fputs("[snap] ⚠️ 렌더-변형 디버그 게이트 불일치 — 베이스라인 캡처 시=\(baselineGates.isEmpty ? "없음" : baselineGates.joined(separator: ",")), 지금=\(currentGates.isEmpty ? "없음" : currentGates.joined(separator: ",")) — 아래 diff 가 실제 회귀가 아니라 이 차이 때문일 수 있습니다.\n", stderr)
        }
        let baseThumbs = baselineDir.appendingPathComponent("thumbs", isDirectory: true)
        // F148: PID 로 스코프(SnapshotPipeline.runCapture 와 동일 이유 — 동시 실행 간 캡처파일 충돌 방지).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_snap_cmp_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let restore = pinRenderSettings(root: root)
        defer { restore() }

        var rows: [CompareRow] = []
        var regressedToEmpty: [String] = []   // 베이스라인엔 픽셀이 있었는데 지금 무픽셀/실패
        var skippedMissing: [String] = []      // 현재 코퍼스에 없거나 썸네일 없음

        for entry in baseline.entries {
            autoreleasepool {
                let folder = URL(fileURLWithPath: root).appendingPathComponent("backgrounds/\(entry.id)")
                guard FileManager.default.fileExists(atPath: folder.path),
                      let base = pngToRGBA(baseThumbs.appendingPathComponent("\(entry.id).png"),
                                           width: baseline.thumbWidth, height: baseline.thumbHeight) else {
                    skippedMissing.append(entry.id); return
                }
                do {
                    let project = try ProjectJSONParser.parse(folderURL: folder)
                    guard case let .pixels(cur, _) = try captureFrame(project: project, into: tmp) else {
                        regressedToEmpty.append(entry.id); return
                    }
                    let m = diffRGBA(cur, base)
                    let thr: DiffThreshold = entry.deterministic ? .strict : .lax
                    rows.append(CompareRow(id: entry.id, metrics: m, deterministic: entry.deterministic, pass: passes(m, thr)))
                } catch {
                    regressedToEmpty.append(entry.id)
                    fputs("[snap] 현재 마운트 실패(회귀) \(entry.id): \(error)\n", stderr)
                }
            }
        }

        // 보고
        let detFail = rows.filter { !$0.pass && $0.deterministic }
        let ndFail  = rows.filter { !$0.pass && !$0.deterministic }
        let passCount = rows.filter { $0.pass }.count
        let top = rows.sorted { $0.metrics.meanAbsDiff > $1.metrics.meanAbsDiff }.prefix(10)
        let dt = Date().timeIntervalSince(start)

        func fmt(_ r: CompareRow) -> String {
            "\(r.id) mean=\(String(format: "%.2f", r.metrics.meanAbsDiff)) max=\(r.metrics.maxAbsDiff) frac=\(String(format: "%.4f", r.metrics.fracExceeding)) \(r.deterministic ? "det" : "nondet") \(r.pass ? "PASS" : "FAIL")"
        }

        print("""
        [snap compare] baseline \(baseline.label) (git \(baseline.gitSHA)) vs 현재 빌드
          compared=\(rows.count)  PASS=\(passCount)  FAIL(결정)=\(detFail.count)  FAIL(비결정)=\(ndFail.count)
          렌더→무픽셀 회귀=\(regressedToEmpty.count)\(regressedToEmpty.isEmpty ? "" : " " + regressedToEmpty.prefix(12).joined(separator: ","))
          skip(코퍼스/썸네일 없음)=\(skippedMissing.count)  baseline-empties(범위 밖, 미비교)=\(baseline.empties.count)
          elapsed=\(String(format: "%.1f", dt))s
        상위 편차 10:
        \(top.map { "  " + fmt($0) }.joined(separator: "\n"))
        """)
        if !detFail.isEmpty {
            print("결정 씬 FAIL (회귀):")
            for r in detFail.sorted(by: { $0.metrics.meanAbsDiff > $1.metrics.meanAbsDiff }) { print("  ✗ " + fmt(r)) }
        }
        if !ndFail.isEmpty {
            fputs("[snap] ⚠️ 비결정 씬 \(ndFail.count)종이 관대 임계도 초과(참고): \(ndFail.map { $0.id }.prefix(12).joined(separator: ","))\n", stderr)
        }

        let regressed = !detFail.isEmpty || !regressedToEmpty.isEmpty
        return regressed ? 1 : 0
    }
}
