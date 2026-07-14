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

    func run() throws {
        let root = NSString(string: rootPath).expandingTildeInPath
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
            print(DeepScan.run(rootPath: rootPath, only: only))
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

    private func printUsage() {
        print("""
        Usage: WapleCompat [--json] [--strict] [wallpaper_dev_or_backgrounds_path]

        Scans Wallpaper Engine project folders and reports Waple compatibility risks.
        Default path: ~/Downloads/wallpaper_dev
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
