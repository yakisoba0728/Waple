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
    var label: String? = nil             // --label <name>: 베이스라인 폴더명(기본 git sha)

    mutating func parse(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                outputJSON = true
            case "--strict":
                strict = true
            case "--deep":
                deep = true
            case "--only":
                only = iterator.next()
            case "--decode-ogg":
                decodeOggIn = iterator.next()
            case "--naive":
                decodeNaive = true
            case "--capture":
                captureOut = iterator.next()
            case "--label":
                label = iterator.next()
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
        if let out = captureOut {
            let code = SnapshotPipeline.runCapture(root: root, outDir: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath), label: label)
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

        var description: String {
            switch self {
            case .unknownOption(let option):
                return "unknown option: \(option)"
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
