import XCTest
@testable import WapleCompatCore

final class SnapshotProcessIsolationTests: XCTestCase {
    func testSelfCheckPassExitCodeTreatsEmptyCaptureAsFailure() {
        XCTAssertEqual(SnapshotPipeline.selfCheckPassExitCode(failures: [], empties: []), 0)
        XCTAssertEqual(SnapshotPipeline.selfCheckPassExitCode(failures: ["broken"], empties: []), 1)
        XCTAssertEqual(SnapshotPipeline.selfCheckPassExitCode(failures: [], empties: ["blank"]), 1,
                       "helper가 PNG를 내지 못한 씬을 exit 0으로 숨기면 안 됨")
    }

    func testSelfCheckPassRunsInAFreshProcessAndForwardsPathsVerbatim() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "waple-snapshot-process-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let script = dir.appendingPathComponent("capture-helper.sh")
        let output = dir.appendingPathComponent("self check", isDirectory: true)
        let root = dir.appendingPathComponent("corpus root", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
            #!/bin/sh
            printf '%s\n%s\n%s\n%s\n' "$$" "$1" "$2" "$3" > "$3/invocation.txt"
            """.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let status = try SnapshotPipeline.launchSelfCheckPass(
            executableURL: script, root: root.path, outDir: output)

        XCTAssertEqual(status, 0)
        let fields = try String(contentsOf: output.appendingPathComponent("invocation.txt"),
                                encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(fields.count, 4)
        let childPID = try XCTUnwrap(Int(fields[0]))
        XCTAssertNotEqual(childPID, Int(ProcessInfo.processInfo.processIdentifier),
                          "셀프체크가 부모 프로세스 안에서 재실행되면 per-process 난수를 검출하지 못한다")
        XCTAssertEqual(fields[1], "--snapshot-self-check-pass")
        XCTAssertEqual(fields[2], root.path)
        XCTAssertEqual(fields[3], output.path)
    }
}
