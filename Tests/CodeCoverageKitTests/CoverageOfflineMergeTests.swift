#if os(macOS)
import Foundation
import XCTest
@_spi(OfflineMerge) @testable import CodeCoverageKit

final class CoverageOfflineMergeTests: XCTestCase {
    /// Exercises the actual Swift/NSData/C ownership boundary and compares the full fixed-binary LLVM export.
    func testSwiftProviderMergesRealProfilesAndRejectsUnknownInput() throws {
        let t_root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: t_root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: t_root) }
        let t_source = t_root.appendingPathComponent("sample.c"), t_binary = t_root.appendingPathComponent("sample")
        try "#include <stdlib.h>\n/* Exercises opposite condition directions. */\nstatic int route(int n) { if(n>2 && n<8)return 4;return n?7:0;}\n/* Produces an exit-time raw profile for one launch. */\nint main(int c,char **v){return route(c>1?atoi(v[1]):0)==-1;}\n".write(to: t_source, atomically: true, encoding: .utf8)
        _ = try p_run(["clang", "-fprofile-instr-generate", "-fcoverage-mapping", t_source.path, "-o", t_binary.path])
        let t_raw = [t_root.appendingPathComponent("a.profraw"), t_root.appendingPathComponent("b.profraw")]
        var t_processIDs: [Int32] = []
        for (t_index, t_url) in t_raw.enumerated() {
            let t_process = Process()
            t_process.executableURL = t_binary
            t_process.arguments = [String(t_index == 0 ? 0 : 4)]
            t_process.environment = ProcessInfo.processInfo.environment.merging(["LLVM_PROFILE_FILE": t_url.path]) { _, value in value }
            try t_process.run(); t_processIDs.append(t_process.processIdentifier); t_process.waitUntilExit(); XCTAssertEqual(t_process.terminationStatus, 0)
        }
        let t_inputs = try t_raw.map { try Data(contentsOf: $0) }, t_before = try t_raw.map { try Data(contentsOf: $0) }
        let t_limits = CoverageMergeLimits(maxSources: 64, maxInputBytes: 1024 * 1024, maxOutputBytes: 1024 * 1024,
            maxRecords: 10000, timeoutMilliseconds: 10000, maxRequestBytes: 1024 * 1024, maxRequestGrowthRatio: 1,
            minimumSavingsBytes: 1, minimumSavingsRatio: 0.1, maxProcessResidentBytes: Int.max, minimumFreeDiskBytes: 1)
        let t_merged = try CoverageLLVMProfileMerger.merge(profiles: t_inputs, limits: t_limits)
        let t_actual = t_root.appendingPathComponent("client.profdata"), t_control = t_root.appendingPathComponent("control.profdata")
        try t_merged.write(to: t_actual)
        _ = try p_run(["llvm-profdata", "merge", "-sparse", t_raw[0].path, t_raw[1].path, "-o", t_control.path])
        let t_expected = try p_run(["llvm-cov", "export", t_binary.path, "-instr-profile=" + t_control.path])
        let t_export = try p_run(["llvm-cov", "export", t_binary.path, "-instr-profile=" + t_actual.path])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: t_expected) as? NSDictionary, try JSONSerialization.jsonObject(with: t_export) as? NSDictionary)
        XCTAssertEqual(t_before, try t_raw.map { try Data(contentsOf: $0) })
        let t_cycle = UUID().uuidString.lowercased(), t_build = UUID().uuidString.lowercased(), t_device = UUID().uuidString.lowercased()
        let t_records = t_inputs.enumerated().map { t_index, t_profile in
            CoverageSnapshotRecord(captureSequence: 1, schemaVersion: 1, runID: UUID().uuidString.lowercased(), cycleID: t_cycle,
                buildID: t_build, deviceID: t_device, processID: t_processIDs[t_index], launchID: UUID().uuidString.lowercased(),
                capturedAt: "2026-01-01T00:00:00Z", appState: "active", triggerReason: "manual_snapshot",
                profileRelativePath: "fixture.profraw", size: t_profile.count, sha256: CoverageCanonicalJSON.sha256(t_profile),
                uploadStatus: .pending, retryCount: 0, lastError: nil, serverReceivedAt: nil, analyzable: nil)
        }
        let t_client = CoverageUploadClient()
        let t_configuration = try CoverageServerConfiguration.make(serverURLText: "http://192.168.1.8:8765", runUploadToken: "fictional-local-fixture-token")
        let t_originalSizes = try t_records.enumerated().map { t_index, t_record in
            try t_client.prepareUpload(record: t_record, profileURL: t_raw[t_index], configuration: t_configuration).body.count
        }
        let t_aggregate = try CoverageAggregateRecord(records: t_records, payload: t_merged, launchID: UUID().uuidString.lowercased())
        let t_candidate = try t_client.prepareUpload(descriptor: CoverageUploadDescriptor(aggregate: t_aggregate), profile: t_merged, configuration: t_configuration)
        XCTAssertEqual(t_candidate.request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertGreaterThan(t_candidate.uncompressedBodySize, t_merged.count)
        if let t_output = ProcessInfo.processInfo.environment["CCK_MEASUREMENT_OUTPUT"] {
            let t_measurement: [String: Int] = ["sources": t_records.count, "raw_gzip_sum": t_originalSizes.reduce(0,+),
                "largest_raw_gzip": t_originalSizes.max()!, "merged_gzip": t_candidate.body.count,
                "input_profile_bytes": t_inputs.reduce(0) { $0 + $1.count }, "output_profile_bytes": t_merged.count]
            try JSONSerialization.data(withJSONObject: t_measurement, options: [.sortedKeys]).write(to: URL(fileURLWithPath: t_output))
        }

        var t_unknown = t_inputs[0]; t_unknown[8] = 11
        XCTAssertThrowsError(try CoverageLLVMProfileMerger.merge(profiles: [t_unknown, t_inputs[1]], limits: t_limits))
        XCTAssertThrowsError(try CoverageLLVMProfileMerger.merge(profiles: [t_inputs[0].prefix(20), t_inputs[1]], limits: t_limits))
    }

    /// Runs only isolated fixture compiler/tools with the same fixed developer directory used for dependency validation.
    private func p_run(_ arguments: [String]) throws -> Data {
        let t_process = Process(), t_output = Pipe(), t_error = Pipe()
        t_process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        t_process.arguments = arguments
        t_process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": "/Applications/Xcode263.app/Contents/Developer"]) { _, value in value }
        t_process.standardOutput = t_output; t_process.standardError = t_error
        try t_process.run()
        let t_data = t_output.fileHandleForReading.readDataToEndOfFile()
        t_process.waitUntilExit()
        guard t_process.terminationStatus == 0 else { throw NSError(domain: "FixtureTool", code: Int(t_process.terminationStatus)) }
        return t_data
    }
}
#endif
