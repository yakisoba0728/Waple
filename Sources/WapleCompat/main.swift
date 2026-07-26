import Foundation
import WapleCore
import WapleRender

struct WapleCompatCLI {
    var rootPath: String = NSHomeDirectory() + "/Downloads/wallpaper_dev"
    var outputJSON = false
    var strict = false
    var deep = false
    var only: String? = nil
    var decodeOggIn: String? = nil       // dev 하니스: ogg → 원시 float32 인터리브 PCM(stdout)
    var decodeNaive = false
    var captureOut: String? = nil        // --capture <outDir>: 씬 스냅샷 캡처 + 매니페스트
    var compareBaseline: String? = nil   // --compare <baselineDir>: 현재 빌드 캡처 vs 베이스라인 diff
    var label: String? = nil             // --label <name>: 베이스라인 폴더명(기본 git sha)
    var profileOut: String? = nil        // --profile <outDir>: 단일 씬(--only 필수) 성능 실측 JSON
    var inventoryOut: String? = nil      // --inventory <csv>: 표본 선정용 씬별 메타(파스만)
    var remount = false                  // --remount: 프로세스 내 2차 마운트(웜) 비용 측정
    var frameRes = "1920x1080"           // --frame-res WxH: 실해상도 프레임 타이밍(GPU 예산 분모)

    mutating func parse(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()
        // 값 누락 시 조용한 무시 금지 — CI 의 `--capture`(outDir 누락)가 기본 스캔 후 exit 0 으로 오인됨.
        func value(for option: String) throws -> String {
            guard let v = iterator.next() else { throw CLIError.missingValue(option) }
            return v
        }
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                outputJSON = true
            case "--strict":
                strict = true
            case "--deep":
                deep = true
            case "--only":
                only = try value(for: "--only")
            case "--decode-ogg":
                decodeOggIn = try value(for: "--decode-ogg")
            case "--naive":
                decodeNaive = true
            case "--capture":
                captureOut = try value(for: "--capture")
            case "--compare":
                compareBaseline = try value(for: "--compare")
            case "--label":
                label = try value(for: "--label")
            case "--profile":
                profileOut = try value(for: "--profile")
            case "--inventory":
                inventoryOut = try value(for: "--inventory")
            case "--remount":
                remount = true
            case "--frame-res":
                frameRes = try value(for: "--frame-res")
            case "--help", "-h":
                printUsage()
                Foundation.exit(0)
            default:
                if arg.hasPrefix("-") {
                    throw CLIError.unknownOption(arg)
                }
                rootPath = arg
            }
        }
    }

    /// F150: 상호배타 최상위 모드 플래그(우선순위: inventory>profile>capture>compare>decode-ogg>deep>기본)를
    /// 둘 이상 주면 실제 실행되는 것 1개만 밝히고 나머지는 무시됨을 stderr 로 경고(실행 자체는 그대로 —
    /// 발견성만 개선. 값 누락은 이미 `value(for:)` 의 missingValue 로 막혀 있었는데 이 조합만 사각지대였다).
    /// `--only`/`--json`/`--strict` 가 현재 모드에서 아예 소비되지 않는 조합도 함께 경고한다.
    private func warnIgnoredFlagCombinations() {
        let given: [(String, Bool)] = [
            ("--inventory", inventoryOut != nil),
            ("--profile", profileOut != nil),
            ("--capture", captureOut != nil),
            ("--compare", compareBaseline != nil),
            ("--decode-ogg", decodeOggIn != nil),
            ("--deep", deep),
        ]
        let active = given.filter(\.1).map(\.0)
        if active.count > 1 {
            fputs("WapleCompat: \u{26A0}\u{FE0F} 상호배타 모드 플래그 \(active.count)개 동시 지정(\(active.joined(separator: ", "))) — 우선순위상 '\(active[0])'만 실행되고 나머지는 무시됩니다.\n", stderr)
        }
        // F521: --only 소비 여부는 실제 실행 모드(active.first — 우선순위 최상위) 기준으로 판정.
        // 종전 `!deep && profileOut == nil` 조건은 --deep+--capture+--only 처럼 deep 이 우선순위에서
        // 밀린 조합을 건너뛰었다(capture 가 실행되고 --only 는 무시되는데 무경고).
        let activeMode = active.first
        if let o = only, activeMode != "--deep", activeMode != "--profile" {
            fputs("WapleCompat: \u{26A0}\u{FE0F} --only \(o) 는 --deep 또는 --profile 모드에서만 적용됩니다 — 현재 모드(\(activeMode ?? "기본 스캔"))에서는 무시됩니다.\n", stderr)
        }
        // F521: decode-ogg 도 --json/--strict 미적용 모드 — 종전 목록 누락으로 무경고였다.
        if (outputJSON || strict), (inventoryOut != nil || profileOut != nil || captureOut != nil || compareBaseline != nil || decodeOggIn != nil) {
            fputs("WapleCompat: \u{26A0}\u{FE0F} --json/--strict 는 capture/compare/profile/inventory/decode-ogg 모드에 적용되지 않습니다(해당 모드는 자체 exit code 로만 결과를 알립니다).\n", stderr)
        }
    }

    func run() throws {
        let root = NSString(string: rootPath).expandingTildeInPath
        warnIgnoredFlagCombinations()
        if let inv = inventoryOut {
            let code = ProfilePipeline.runInventory(root: root, outCSV: URL(fileURLWithPath: NSString(string: inv).expandingTildeInPath))
            Foundation.exit(code)
        }
        if let out = profileOut {
            guard let id = only else { fputs("WapleCompat: --profile requires --only <sceneID>\n", stderr); Foundation.exit(2) }
            let parts = frameRes.lowercased().split(separator: "x")
            let fw = parts.count == 2 ? Int(parts[0]) ?? 1920 : 1920
            let fh = parts.count == 2 ? Int(parts[1]) ?? 1080 : 1080
            let code = ProfilePipeline.runProfile(root: root, outDir: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath),
                                                  only: id, remount: remount, frameW: fw, frameH: fh)
            Foundation.exit(code)
        }
        if let out = captureOut {
            let code = SnapshotPipeline.runCapture(root: root, outDir: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath), label: label)
            Foundation.exit(code)
        }
        if let baseline = compareBaseline {
            let code = SnapshotPipeline.runCompare(root: root, baselineDir: URL(fileURLWithPath: NSString(string: baseline).expandingTildeInPath))
            Foundation.exit(code)
        }
        if let inPath = decodeOggIn {
            let data = try Data(contentsOf: URL(fileURLWithPath: inPath))
            let audio = try OggVorbisDecoder.decode(data, useFastIMDCT: !decodeNaive)
            fputs("ch=\(audio.channels) sr=\(audio.sampleRate) frames=\(audio.frameCount)\n", stderr)
            audio.samples.withUnsafeBytes { FileHandle.standardOutput.write(Data($0)) }
            return
        }
        if deep {
            let (report, unsupported, projectsFound) = DeepScan.run(rootPath: rootPath, only: only)
            // 감사 V06: 프로젝트 0개(루트/--only 오지정)면 형제 모드 F520 가드와 동일하게 exit 2
            // — "0건 리포트 + exit 0" 의 CI false-green 차단.
            guard projectsFound else { Foundation.exit(2) }
            print(report)
            // F151: --deep 은 예전엔 항상 return→exit 0 이라 --strict 와 병행해도 실패를 절대 못 잡았다.
            // 기본(비-deep) 스캔의 --strict 게이트(아래, blockedProjects>0 → exit 1)와 동일 취지로,
            // 파싱 가능한 핵심 에셋 기준 미지원 프로젝트가 있으면 실패시킨다.
            if strict, unsupported > 0 {
                Foundation.exit(1)
            }
            return
        }
        let report = try WallpaperCompatibilityAnalyzer.scan(
            rootURL: URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true)
        )

        if outputJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(report.markdown())
        }

        if strict, report.summary.blockedProjects > 0 {
            Foundation.exit(1)
        }
    }

    // F149: 종전엔 --json/--strict/경로만 안내해 --deep·--capture 등 대다수 서브모드가 은폐돼 있었다.
    // 아래는 parse(arguments:) 가 실제로 처리하는 전 옵션(11개 + --help)을 나열한다.
    private func printUsage() {
        print("""
        Usage: WapleCompat [mode flags] [--json] [--strict] [wallpaper_dev_or_backgrounds_path]

        Default mode: scans Wallpaper Engine project folders (WallpaperCompatibilityAnalyzer) and
        reports Waple compatibility risks. Default path: ~/Downloads/wallpaper_dev

        Mode flags (mutually exclusive — priority order below, first given wins, rest are ignored
        with a warning; each mode has its own exit code and is unaffected by --json/--strict):
          --inventory <csv>       Write per-scene metadata CSV (parse-only, for sample selection).
          --profile <outDir>      Perf-profile a single scene (requires --only <sceneID>).
          --capture <outDir>      Capture pixel snapshots of the corpus + write a manifest.
          --compare <baselineDir> Capture + diff current build against a --capture baseline.
          --decode-ogg <file>     Decode one .ogg (Vorbis) to raw float32 PCM on stdout (dev harness).
          --deep                  Deep compat scan: real parse/decode/translate/compile over the
                                   corpus (see DeepScan report for exact "supported" criteria).

        Modifiers:
          --json                  Default-mode output as JSON instead of markdown.
          --strict                Default mode: exit 1 if any project is blocked (severity=error).
                                   --deep mode: exit 1 if any project-level asset is unsupported.
          --only <id>             Restrict to one scene ID (--deep and --profile only; ignored
                                   elsewhere with a warning).
          --label <name>          --capture: baseline folder name (default: short git SHA).
          --remount               --profile: also measure a second (warm) in-process mount.
          --frame-res <WxH>       --profile: capture resolution (default 1920x1080).
          --naive                 --decode-ogg: use the naive (non-fast-IMDCT) decode path.
          --help, -h               Print this message and exit 0.

        Default path (when no mode flag / no positional arg is given): ~/Downloads/wallpaper_dev
        """)
    }

    enum CLIError: Error, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)

        var description: String {
            switch self {
            case .unknownOption(let option):
                return "unknown option: \(option)"
            case .missingValue(let option):
                return "missing value for option: \(option)"
            }
        }
    }
}

var cli = WapleCompatCLI()
do {
    try cli.parse(arguments: CommandLine.arguments)
    try cli.run()
} catch {
    fputs("WapleCompat: \(error)\n", stderr)
    Foundation.exit(2)
}
