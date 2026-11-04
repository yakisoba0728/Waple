import Foundation
import WapleCore
import WapleSnapshot

/// --compare <baselineDir>: 현재 빌드를 두 프로세스에서 새로 캡처해 베이스라인 썸네일과 픽셀 diff.
/// 베이스라인의 entries(픽셀 산출 씬)만 순회 — empties(비디오-백드 등 범위 밖)는 건너뛴다.
/// 단, entry 였던 씬이 지금 empty/실패면 "렌더→무픽셀" 회귀로 잡는다.
/// 임계: 결정 씬은 strict, 비결정 씬은 lax. 종료코드: 결정 FAIL 또는 렌더→무픽셀 회귀가 있으면 1.
extension SnapshotPipeline {

    struct CompareRow {
        let id: String
        let metrics: DiffMetrics
        let deterministic: Bool
        let currentDeterministic: Bool
        let selfMaxDiff: Int
        let pass: Bool
    }

    // 판정 로직·임계는 `WapleSnapshot.goldenVerdict` 로 올렸다(2026-08-19).
    // 여기 지역 상수로 두면 테스트 타깃이 닿을 수 없어(WapleCompat 은 executableTarget)
    // SnapshotTests 가 수식을 베껴 자기 산수를 단언하는 상태가 된다. 그쪽 doc 참조.

    public static func runCompare(root: String, baselineDir: URL) -> Int32 {
        let start = Date()
        guard let mdata = try? Data(contentsOf: baselineDir.appendingPathComponent("manifest.json")),
              let baseline = try? SnapshotManifest.decode(mdata) else {
            fputs("[snap] 베이스라인 매니페스트를 읽을 수 없음: \(baselineDir.path)/manifest.json\n", stderr)
            return 2
        }
        guard !baseline.entries.isEmpty else {
            fputs("[snap] baseline has no entries — comparison unverified\n", stderr)
            return 2
        }
        // 썸네일 크기 불일치 = 구 베이스라인 — min-길이 쓰레기 비교(무증상 대량 오탐 FAIL) 대신 명시 에러.
        guard baseline.thumbWidth == thumbW, baseline.thumbHeight == thumbH else {
            fputs("[snap] 베이스라인 썸네일 크기 \(baseline.thumbWidth)x\(baseline.thumbHeight) ≠ 현재 \(thumbW)x\(thumbH) — --capture 로 베이스라인 재생성 필요\n", stderr)
            return 2
        }
        // F2-puppet 지적: WAPLE_CAPTURE_TIME 이 SnapshotPipeline.captureTimes/primaryCaptureTime 을 거쳐
        // 캡처 시각 자체를 바꾸는데(①), 이 셸 변수가 --compare 로 잔류 전파돼도 아무도 검사하지 않으면
        // 베이스라인과 다른 시각의 프레임을 대조해 전면 허위 회귀가 나고, 출력만 봐선 정상 게이트 결과와
        // 구분되지 않는다. 매니페스트에 실제로 기록된 사실(baseline.captureTime)과 이번 비교가 캐논으로
        // 쓸 시각(primaryCaptureTime)을 직접 대조 — activeDebugGates() 의 env 재구성 경로에 기대지 않는
        // 가장 직접적인 형태.
        if baseline.captureTime != primaryCaptureTime {
            fputs("[snap] ⚠️ 캡처 시각 불일치 — 베이스라인=\(baseline.captureTime)s, 이번 비교=\(primaryCaptureTime)s(WAPLE_CAPTURE_TIME 확인) — 이 상태로는 서로 다른 시각의 프레임을 비교해 전면 허위 회귀가 날 수 있습니다.\n", stderr)
        }
        // F145: 베이스라인 캡처 당시 활성이던 렌더-변형 게이트와 지금 활성인 게이트가 다르면 diff 가
        // 게이트 차이 때문일 수 있음을 경고(하드 실패는 아님 — 게이트는 기본적으로 전부 꺼져 있어야
        // 정상이므로 대부분의 실행에선 둘 다 빈 배열이라 무해).
        // F523: nil(전-F145 베이스라인 = "기록 안 됨")과 빈 배열("0개 활성")은 다르다(Snapshot.swift
        // 스키마 주석). ?? [] 로 붕괴시키면 구 베이스라인의 게이트 오염을 경고할 수 없으므로 nil 은
        // 대조 불가로 명시하고 건너뛴다.
        if let baselineGates = baseline.activeDebugGates {
            let currentGates = SnapshotPipeline.activeDebugGates()
            if baselineGates != currentGates {
                fputs("[snap] ⚠️ 렌더-변형 디버그 게이트 불일치 — 베이스라인 캡처 시=\(baselineGates.isEmpty ? "없음" : baselineGates.joined(separator: ",")), 지금=\(currentGates.isEmpty ? "없음" : currentGates.joined(separator: ",")) — 아래 diff 가 실제 회귀가 아니라 이 차이 때문일 수 있습니다.\n", stderr)
            }
        } else {
            fputs("[snap] ⚠️ 베이스라인에 activeDebugGates 기록 없음(전-F145 스키마) — 캡처 당시 게이트 상태를 알 수 없어 불일치 검사를 건너뜁니다.\n", stderr)
        }
        let baseThumbs = baselineDir.appendingPathComponent("thumbs", isDirectory: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "waple_snap_cmp_\(UUID().uuidString)", isDirectory: true)
        let selfCheckDir = tmp.appendingPathComponent("self-check", isDirectory: true)
        do { try FileManager.default.createDirectory(at: selfCheckDir, withIntermediateDirectories: true) }
        catch {
            fputs("[snap] compare temporary directory unavailable: \(error)\n", stderr)
            return 2
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let restore = pinRenderSettings(root: root)
        defer { restore() }
        // Recheck this build in a fresh process. A historic nondeterministic label must not
        // permanently grant lax thresholds, nor hide a newly introduced loss of determinism.
        let helperPath = ProcessInfo.processInfo.environment["WAPLE_SNAPSHOT_HELPER"] ?? CommandLine.arguments[0]
        do {
            let status = try launchSelfCheckPass(executableURL: URL(fileURLWithPath: helperPath).standardizedFileURL,
                                                root: root, outDir: selfCheckDir)
            if status != 0 { fputs("[snap] current self-check helper exit \(status) — validating available frames\n", stderr) }
        } catch {
            fputs("[snap] current self-check unavailable: \(error)\n", stderr)
            return 2
        }

        var rows: [CompareRow] = []
        var regressedToEmpty: [String] = []   // 베이스라인엔 픽셀이 있었는데 지금 무픽셀/실패
        var lostDeterminism: [String] = []
        var selfCheckMissing: [String] = []
        var skippedMissing: [String] = []      // 현재 코퍼스에 없거나 썸네일 없음

        // F520: sceneFolders 와 동일 해석 — 개발 루트/backgrounds 직접 지정 모두 수용.
        let container = sceneContainer(root: root)
        for entry in baseline.entries {
            autoreleasepool {
                let folder = container.appendingPathComponent(entry.id)
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
                    guard let second = pngToRGBA(selfCheckDir.appendingPathComponent("\(entry.id).png"),
                                                 width: thumbW, height: thumbH) else {
                        selfCheckMissing.append(entry.id); return
                    }
                    let selfDiff = diffRGBA(cur, second)
                    let currentDeterministic = passes(selfDiff, .selfConsistent)
                    if entry.deterministic && !currentDeterministic { lostDeterminism.append(entry.id) }
                    // Tighten when either capture is deterministic; a regression never earns lax treatment.
                    let strict = entry.deterministic || currentDeterministic
                    let m = diffRGBA(cur, base)
                    let verdict = goldenVerdict(m, baselineMeanLuma: entry.meanLuma, deterministic: strict)
                    rows.append(CompareRow(id: entry.id, metrics: m, deterministic: strict,
                                           currentDeterministic: currentDeterministic,
                                           selfMaxDiff: selfDiff.maxAbsDiff, pass: verdict.pass))
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
            "\(r.id) mean=\(String(format: "%.2f", r.metrics.meanAbsDiff)) max=\(r.metrics.maxAbsDiff) frac=\(String(format: "%.4f", r.metrics.fracExceeding)) \(r.deterministic ? "strict" : "lax") current=\(r.currentDeterministic ? "det" : "nondet") selfMax=\(r.selfMaxDiff) \(r.pass ? "PASS" : "FAIL")"
        }

        print("""
        [snap compare] baseline \(baseline.label) (git \(baseline.gitSHA)) vs 현재 빌드
          compared=\(rows.count)  PASS=\(passCount)  FAIL(결정)=\(detFail.count)  FAIL(비결정)=\(ndFail.count)
          렌더→무픽셀 회귀=\(regressedToEmpty.count)\(regressedToEmpty.isEmpty ? "" : " " + regressedToEmpty.prefix(12).joined(separator: ","))
          skip(코퍼스/썸네일 없음)=\(skippedMissing.count)  baseline-empties(범위 밖, 미비교)=\(baseline.empties.count)
          결정성 소실=\(lostDeterminism.count)\(lostDeterminism.isEmpty ? "" : " " + lostDeterminism.joined(separator: ","))
          현재 셀프체크 누락=\(selfCheckMissing.count)
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

        // F520: 베이스라인 entry 가 대량으로 skip(코퍼스/썸네일 부재)이면 루트 오지정 또는 코퍼스
        // 유실 — 회귀(1)가 아니라 환경 오류(2). compared=0 인데 exit 0 은 CI 가 성공으로 오인한다.
        //
        // [수정 2026-08-19] 종전 조건은 `skippedMissing.count == baseline.entries.count` 였다 —
        // **완전일치일 때만** 걸린다. 170개 중 169개가 사라져도 통과였고, 그 한 개가 비교돼
        // 회귀가 없으면 호출자는 `OK 골든 무회귀` 를 초록으로 찍었다. 호출자 어느 쪽도 개수를
        // 보지 않는다(`golden-gate.sh` 는 `$?` 와 `[snap compare]` 유무만, `verify-plan-b12.sh` §7
        // 은 `$?` 만). 위 F520 주석이 **정확히 이 부류를 막으려고** 쓰였는데 compared==0 한 점만
        // 막은 셈이다. 비율 하한으로 바꾼다.
        //
        // 90% 인 이유: 코퍼스가 조금 다른 머신(썸네일 몇 개 부재)은 정상 운용이라 통과해야 하고,
        // "반쯤 유실된 채 무회귀" 는 막아야 한다. 이 값은 판정 임계가 아니라 **환경 온전성**
        // 기준이다 — 픽셀 임계와 달리 느슨하게 잡아도 잡으려는 것을 놓치지 않는다.
        //
        // 정수 산술로 쓴다(비율을 Double 로 내고 `Int(...)` 로 되돌리면 그 자체가
        // scripts/spec/check_int_narrowing.py 가 막는 부류가 된다 — 실제로 그 검사에 걸렸다).
        // r3-O17: 아래 두 환경-오류 분기(exit 2)는 **회귀 판정보다 먼저** 돈다. 그래서
        // "렌더→무픽셀 회귀" 가 실재하는 실행에서도 동시에 대량 skip 이 있으면 종료코드가
        // 1(회귀)이 아니라 2(환경 오류)로 나가고 stderr 한 줄도 환경 얘기만 한다.
        // 다만 **stdout 은 이미 위에서 `렌더→무픽셀 회귀=N` 과 id 목록을 먼저 찍는다** — 사람이
        // 보는 화면에는 회귀가 남는다. 오진단 위험은 종료코드와 stderr 한 줄에 한정된다
        // (원 발견의 "사람을 반대 방향으로 보낸다" 는 그만큼 과장이라 r3 §4.2 가 하향 정정했다).
        // 순서를 뒤집지 않는 이유: 모집단이 반쯤 유실된 상태의 회귀 목록은 그 자체가 신뢰할 수
        // 없어서, 먼저 환경을 고치라고 말하는 쪽이 옳다.
        let minComparedPercent = 90
        if rows.count * 100 < baseline.entries.count * minComparedPercent {
            let pct = rows.count * 100 / baseline.entries.count
            fputs("[snap] ⚠️ compared=\(rows.count)/\(baseline.entries.count) (\(pct)%) — "
                  + "하한 \(minComparedPercent)% 미만. 베이스라인 씬이 현재 코퍼스/썸네일에서 "
                  + "대량 누락됐다 — 이 상태의 '무회귀' 는 의미가 없다. "
                  + "root 지정 확인: \(root) (skip=\(skippedMissing.count))\n", stderr)
            return 2
        }
        if !selfCheckMissing.isEmpty {
            fputs("[snap] current self-check frames missing: \(selfCheckMissing.joined(separator: ",")) — comparison unverified\n", stderr)
            return 2
        }
        let regressed = !detFail.isEmpty || !regressedToEmpty.isEmpty || !lostDeterminism.isEmpty
        return regressed ? 1 : 0
    }
}
