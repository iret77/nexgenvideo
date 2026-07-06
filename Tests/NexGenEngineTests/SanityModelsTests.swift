import Foundation
import Testing
@testable import NexGenEngine

/// Port of `engine/tests/test_sanity.py`.
@Suite("Sanity Models")
struct SanityModelsTests {
    // MARK: - test_empty_report_is_clean

    @Test("an empty report is clean")
    func emptyReportIsClean() {
        #expect(SanityReport(project: "p").isClean == true)
    }

    // MARK: - test_report_partitions_by_level

    @Test("a report partitions findings by level")
    func reportPartitionsByLevel() {
        let report = SanityReport(
            project: "p",
            findings: [
                Finding(level: .error, code: "E1", shotId: "s1", message: "bad"),
                Finding(level: .warn, code: "W1", shotId: nil, message: "meh"),
                Finding(level: .info, code: "I1", shotId: nil, message: "fyi"),
            ]
        )
        #expect(report.errors.count == 1)
        #expect(report.warnings.count == 1)
        #expect(report.isClean == false)
    }
}
