import Foundation
import XCTest

final class CodeCoverageSourceHygieneTests: XCTestCase {
    /// 验证全部生产源码不包含阶段词或宿主项目专用表述。
    func testProductionSourcesUseNeutralLanguage() throws {
        let t_sourceFiles = try p_sourceFiles()
        let t_forbiddenTerms = ["P0", "P1A", "会话1", "-D -C", "DEBUGTOOL", "Mac 服务"]
        for t_file in t_sourceFiles {
            let t_content = try String(contentsOf: t_file, encoding: .utf8)
            for t_term in t_forbiddenTerms {
                XCTAssertFalse(t_content.contains(t_term), "\(t_file.lastPathComponent) 包含阶段或宿主词：\(t_term)")
            }
        }
    }

    /// 验证公开门面不把 Collector、Store、网络客户端或 runtime bridge 声明为公共 API。
    func testPublicFacadeDoesNotExposeInternalOwners() throws {
        let t_publicFile = p_packageRoot()
            .appendingPathComponent("Sources/CodeCoverageKit/Public/CodeCoverage.swift")
        let t_content = try String(contentsOf: t_publicFile, encoding: .utf8)
        let t_forbiddenPublicDeclarations = [
            "public class CoverageCollector",
            "public struct CoverageSnapshotStore",
            "public class CoverageUploadClient",
            "public actor CoverageProbeClient",
            "public class CodeCoverageRuntimeBridge"
        ]
        for t_declaration in t_forbiddenPublicDeclarations {
            XCTAssertFalse(t_content.contains(t_declaration))
        }
    }

    /// 验证 Package 只在 Debug 配置定义实现开关，Release 不导出可调用门面实现。
    func testPackageKeepsImplementationBehindDebugCondition() throws {
        let t_manifest = try String(
            contentsOf: p_packageRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let t_publicSource = try String(
            contentsOf: p_packageRoot().appendingPathComponent("Sources/CodeCoverageKit/Public/CodeCoverage.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(t_manifest.contains(#".define("CODE_COVERAGE_KIT_ENABLED", .when(configuration: .debug))"#))
        XCTAssertTrue(t_publicSource.hasPrefix("#if CODE_COVERAGE_KIT_ENABLED"))
    }

    /// 验证 CocoaPods 描述复用 Swift、Objective-C bridge 和配置资源，且不在 SDK 内冒充宿主配置边界。
    func testCocoaPodsSpecificationUsesSharedSourcesAndHostOwnedConfigurationGate() throws {
        let t_spec = try String(
            contentsOf: p_packageRoot().appendingPathComponent("CodeCoverageKit.podspec"),
            encoding: .utf8
        )
        XCTAssertTrue(t_spec.contains("Sources/CodeCoverageKit/**/*.swift"))
        XCTAssertTrue(t_spec.contains("Sources/CodeCoverageRuntimeBridge/**/*.{h,m}"))
        XCTAssertTrue(t_spec.contains("CODE_COVERAGE_KIT_ENABLED=1"))
        XCTAssertTrue(t_spec.contains("CodeCoverageKitConfiguration.json"))
        XCTAssertFalse(t_spec.contains(":configurations"))
    }

    /// 返回按路径排序的 SDK Swift 生产源码，确保静态扫描结果稳定。
    private func p_sourceFiles() throws -> [URL] {
        let t_root = p_packageRoot().appendingPathComponent("Sources/CodeCoverageKit", isDirectory: true)
        let t_enumerator = try XCTUnwrap(FileManager.default.enumerator(at: t_root, includingPropertiesForKeys: nil))
        return t_enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// 从当前测试源码位置解析 Package 根目录，不依赖调用方工作目录。
    private func p_packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
