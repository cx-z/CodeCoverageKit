import XCTest
@testable import CodeCoverageKit

final class CoverageBuildMetadataTests: XCTestCase {
    /// 验证 SDK 只声明中性的 Build metadata 资源名。
    func testMetadataResourceName() {
        XCTAssertEqual(CoverageBuildMetadata.resourceName, "CodeCoverageBuildMetadata")
    }

    /// 验证现有 schema 与字段名可被 SDK 原样解码，不改变 Build 身份或服务配置。
    func testDecodesGenericMetadataSchema() throws {
        let t_metadata = try CoverageBuildMetadata.decode(try CoverageTestFixtures.metadataData())

        XCTAssertEqual(t_metadata.project, "ExampleProject")
        XCTAssertEqual(t_metadata.cycleID, CoverageTestFixtures.cycleID)
        XCTAssertEqual(t_metadata.buildID, CoverageTestFixtures.buildID)
        XCTAssertEqual(t_metadata.coverageServerURL.absoluteString, "http://192.168.1.20:8765")
        XCTAssertEqual(t_metadata.runUploadToken, CoverageTestFixtures.token)
    }

    /// 验证无效 UUID 在进入采集与上传前被拒绝。
    func testRejectsInvalidBuildIdentifier() throws {
        let t_data = try CoverageTestFixtures.metadataData(buildID: "not-a-uuid")

        XCTAssertThrowsError(try CoverageBuildMetadata.decode(t_data)) { error in
            XCTAssertEqual(error.localizedDescription, "Coverage Build 元数据中的 build_id 不是有效 UUID。")
        }
    }

    /// 在提供真实 coveragectl metadata 路径时校验其可由 SDK 读取；普通开发测试可安全跳过。
    func testDecodesCoveragectlMetadataFixtureWhenProvided() throws {
        guard let t_path = ProcessInfo.processInfo.environment["COVERAGECTL_METADATA_FIXTURE"] else {
            throw XCTSkip("未提供真实 coveragectl metadata fixture")
        }
        let t_metadata = try CoverageBuildMetadata.decode(try Data(contentsOf: URL(fileURLWithPath: t_path)))
        XCTAssertFalse(t_metadata.project.isEmpty)
        XCTAssertNotNil(UUID(uuidString: t_metadata.buildID))
        XCTAssertFalse(t_metadata.runUploadToken.isEmpty)
    }
}
