#if os(iOS)
@testable import BillScreen
import Foundation
import Models
import SnapshotTesting
import SwiftUI
import Testing

/// The Bill screen's AI section on its own, in the states that draw something.
///
/// On its own rather than on a bill screen: the only analysis fixture is H.R. 6363's (built from its
/// real CRS summary), and there is no captured bill response for H.R. 6363 to put it under. The
/// screens' own snapshots get a 404 for the analysis, so their AI section is hidden. The skeleton is
/// left out: it animates.
@MainActor
@Suite("AI section snapshots", .serialized, .enabled(if: SnapshotEnvironment.matches, SnapshotEnvironment.skipReason))
struct AIAnalysisSnapshotTests {
    private func analysis(stale: Bool = false) throws -> AIAnalysis {
        var response = try fixture("bill-analysis", as: BillAnalysis.self)
        response.source.stale = stale
        return AIAnalysis(response)
    }

    private func section(_ phase: BillScreenModel.AnalysisPhase, open: String? = nil) -> some View {
        AIAnalysisSection(phase: phase, openCitation: open, onToggle: { _ in }, onRetry: {})
    }

    /// Every heading, chip and the disclaimer, with the `Sec. 101` citation open.
    @Test func citationOpen() throws {
        let shown = try analysis()
        let open = try #require(shown.citations.first { $0.section != nil })
        assertCard(section(.loaded(shown), open: open.id))
    }

    @Test func stale() throws {
        assertCard(section(.loaded(try analysis(stale: true))), [.light])
    }

    @Test func noSummaryYet() {
        assertCard(section(.noSummary), [.light, .dark])
    }

    @Test func failed() {
        assertCard(section(.failed), [.light])
    }
}
#endif
