import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Typography legibility")
struct TypographyLegibilityTests {
    @Test func everyTextTokenMeetsTheGlobalReadableFloor() {
        let sizes = [
            AppTheme.FontSize.micro,
            AppTheme.FontSize.xxs,
            AppTheme.FontSize.xs,
            AppTheme.FontSize.sm,
            AppTheme.FontSize.smMd,
            AppTheme.FontSize.md,
            AppTheme.FontSize.mdLg,
            AppTheme.FontSize.lg,
            AppTheme.FontSize.lgXl,
            AppTheme.FontSize.xlSm,
            AppTheme.FontSize.xl,
            AppTheme.FontSize.title1,
            AppTheme.FontSize.title2,
            AppTheme.FontSize.display,
        ]

        #expect(AppTheme.FontSize.minimumReadable >= 11)
        #expect(sizes.allSatisfy { $0 >= AppTheme.FontSize.minimumReadable })
    }

    @Test func mutedTextRetainsReadableContrast() {
        #expect(AppTheme.Text.muted.alphaComponent >= 0.5)
    }

    @Test func sourceTypographyDoesNotBypassTheThemeFloor() throws {
        let sourceRoot = try repositoryRoot().appendingPathComponent("Sources/NexGenVideo")
        let files = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        let forbiddenPatterns = [
            #"system\(size:\s*[0-9]"#,
            #"NSFont\.(systemFont|monospacedSystemFont)\(ofSize:\s*[0-9]"#,
            #"\.font\(\.(caption2|caption|footnote)\)"#,
        ]

        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbiddenPatterns where source.range(
                of: pattern,
                options: .regularExpression
            ) != nil {
                Issue.record("Typography bypasses AppTheme in \(file.path)")
            }
        }
    }

    private func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
              !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path
              ) {
            root.deleteLastPathComponent()
        }
        try #require(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path
        ))
        return root
    }
}
