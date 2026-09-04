import CodeCoverageRuntimeBridge
import XCTest

final class CodeCoverageRuntimeBridgeTests: XCTestCase {
    /// 验证独立 Clang Target 能从测试进程中的 LLVM runtime 取得真实非空 buffer 快照。
    func testCapturesLLVMProfileBuffer() throws {
        let t_data = try CodeCoverageRuntimeBridge.snapshotData()
        XCTAssertFalse(t_data.isEmpty)

        let t_directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: t_directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: t_directory) }
        let t_profileURL = t_directory.appendingPathComponent("runtime.profraw")
        let t_mergedURL = t_directory.appendingPathComponent("runtime.profdata")
        try t_data.write(to: t_profileURL, options: [.atomic])
        let t_process = Process()
        t_process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        t_process.arguments = ["llvm-profdata", "merge", "-sparse", t_profileURL.path, "-o", t_mergedURL.path]
        try t_process.run()
        t_process.waitUntilExit()
        XCTAssertEqual(t_process.terminationStatus, 0)
        XCTAssertGreaterThan((try Data(contentsOf: t_mergedURL)).count, 0)
    }
}
