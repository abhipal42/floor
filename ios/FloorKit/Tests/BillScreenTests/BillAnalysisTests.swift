import APIClient
import Foundation
import Models
import Testing
@testable import BillScreen

/// A captured response from `ModelsTests/Fixtures`, read from the source tree.
private func fixture(_ name: String) throws -> Data {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // BillScreenTests
    dir.deleteLastPathComponent() // Tests
    return try Data(contentsOf: dir.appendingPathComponent("ModelsTests/Fixtures/\(name).json"))
}

/// A fixture with some of its top-level fields replaced, e.g. a bill CRS has not summarised yet.
private func fixture(_ name: String, setting changes: [String: Any]) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    for (key, value) in changes { object[key] = value }
    return try JSONSerialization.data(withJSONObject: object)
}

/// The analysis fixture with `source.stale` set.
private func staleAnalysis() throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: fixture("bill-analysis")) as? [String: Any])
    var source = try #require(object["source"] as? [String: Any])
    source["stale"] = true
    object["source"] = source
    return try JSONSerialization.data(withJSONObject: object)
}

/// Answers the bill route and the analysis route separately, each as the test says.
final class BillRoutes: URLProtocol {
    enum Answer: Sendable {
        case ok(Data)
        case status(Int, Data)
        case offline
        /// `ok`, but only after a delay: a request still in flight while the test looks.
        case slow(Data)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var billAnswer: Answer = .offline
    nonisolated(unsafe) private static var analysisAnswer: Answer = .offline

    static func set(bill: Answer, analysis: Answer) {
        lock.lock()
        billAnswer = bill
        analysisAnswer = analysis
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillRoutes.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let answer = url.path.hasSuffix("/analysis") ? Self.analysisAnswer : Self.billAnswer
        Self.lock.unlock()
        let (status, body): (Int, Data)
        switch answer {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case let .ok(data): (status, body) = (200, data)
        case let .status(code, data): (status, body) = (code, data)
        case let .slow(data):
            nonisolated(unsafe) let this = self
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
                this.client?.urlProtocol(this, didLoad: data)
                this.client?.urlProtocolDidFinishLoading(this)
            }
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let notYet = Data(#"{"error":"No AI analysis for bill 118-hr-3746 yet"}"#.utf8)
private let fetchedAt = ISO8601DateFormatter().date(from: "2026-11-13T09:30:00Z")!

// The bill responses are H.R. 3746's capture and the analysis is H.R. 6363's (the only bill with an
// analysis fixture built from its real CRS summary). The model never mixes the two: it shows the
// analysis it is sent, and reads only `summary` off the bill.
@MainActor
@Suite("Bill screen AI section", .serialized)
struct BillAnalysisTests {
    private let cache: SwiftDataResponseCache
    private let api: FloorAPI

    init() throws {
        cache = try SwiftDataResponseCache.inMemory()
        api = FloorAPI(
            baseURL: URL(string: "https://api.example.test")!, session: BillRoutes.session(),
            cache: cache, now: { fetchedAt }
        )
    }

    private func screen(_ bill: BillRoutes.Answer, analysis: BillRoutes.Answer) -> BillScreenModel {
        BillRoutes.set(bill: bill, analysis: analysis)
        let model = BillScreenModel(billId: "118-hr-3746", api: api)
        return model
    }

    private func analysis(_ model: BillScreenModel) throws -> AIAnalysis {
        guard case let .loaded(shown) = model.analysis else {
            Issue.record("expected an analysis, got \(model.analysis)")
            throw CancellationError()
        }
        return shown
    }

    // MARK: - States

    @Test func startsLoadingSoTheSkeletonShows() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        #expect(model.analysis == .loading)
    }

    @Test func showsTheAnalysisWithItsHeadingsAndTheAPIsDisclaimer() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        await model.load()
        let shown = try analysis(model)
        // `impact` is empty in the response, so it has no heading.
        #expect(shown.groups.map(\.heading) == ["What it does", "What it changes", "Who it touches"])
        #expect(shown.groups[1].lines.map(\.text) == [
            "Section 101 extends expiring programs.",
            "Some agencies are funded through January 19, 2024.",
        ])
        let response = try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis"))
        #expect(shown.disclaimer == response.disclaimer)
        #expect(shown.stage == "Public Law")
        #expect(shown.stale == false)
    }

    /// The bill has a summary and the worker just hasn't written an analysis: say nothing.
    @Test func noAnalysisForABillWithASummaryHidesTheSection() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .status(404, notYet))
        await model.load()
        #expect(model.analysis == .hidden)
    }

    /// No CRS summary, so there is nothing to write one from: the "No summary yet" card.
    @Test func noAnalysisAndNoSummaryShowsNoSummaryYet() async throws {
        let bill = try fixture("bill-enacted", setting: ["summary": NSNull(), "summaryStage": NSNull()])
        let model = screen(.ok(bill), analysis: .status(404, notYet))
        await model.load()
        #expect(model.analysis == .noSummary)
    }

    @Test func aBlankSummaryCountsAsNone() throws {
        var bill = try JSONDecoder().decode(Bill.self, from: fixture("bill-enacted"))
        #expect(BillScreenModel.none(bill) == .hidden)
        bill.summary = " \n"
        #expect(BillScreenModel.none(bill) == .noSummary)
    }

    @Test func aStaleAnalysisSaysTheSummaryHasChanged() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try staleAnalysis()))
        await model.load()
        #expect(try analysis(model).stale)
        #expect(AIAnalysis.staleNote == "The CRS summary has changed since this was written.")
    }

    /// The bill still shows; only its AI section admits it failed.
    @Test func aServerErrorFailsOnlyTheAISection() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .status(500, Data("oops".utf8)))
        await model.load()
        guard case .loaded = model.phase else { Issue.record("bill should show"); return }
        #expect(model.analysis == .failed)
    }

    // MARK: - Offline

    /// A 404 is saved as "none", so offline the screen still knows there was nothing to show.
    @Test func aSavedNoneStaysHiddenOffline() async throws {
        let online = screen(.ok(try fixture("bill-enacted")), analysis: .status(404, notYet))
        await online.load()
        let keys = await cache.entries().map(\.key)
        #expect(keys.contains("api.example.test/v1/bills/118-hr-3746/analysis"))

        let offline = screen(.offline, analysis: .offline)
        await offline.load()
        #expect(offline.analysis == .hidden)
        #expect(offline.saved?.status == .offline)
    }

    @Test func aSavedAnalysisShowsOffline() async throws {
        let online = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        await online.load()
        let offline = screen(.offline, analysis: .offline)
        await offline.load()
        #expect(try analysis(offline).groups.count == 3)
    }

    /// The bill was saved but its analysis never was: the saved pass's miss is not the answer, the
    /// network pass's failure is.
    @Test func anUnsavedAnalysisOfflineFailsAfterTheSavedBillShows() async throws {
        await cache.save(try fixture("bill-enacted"), for: "api.example.test/v1/bills/118-hr-3746", at: fetchedAt)
        let model = screen(.offline, analysis: .offline)
        await model.load()
        guard case .loaded = model.phase else { Issue.record("saved bill should show"); return }
        #expect(model.analysis == .failed)
    }

    // MARK: - Citations

    @Test func aChipOpensItsParagraphVerbatimOneAtATime() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        await model.load()
        let shown = try analysis(model)
        let response = try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis"))
        let section101 = try #require(shown.citations.first { $0.section == "Sec. 101" })
        let purpose = try #require(shown.groups.first?.lines.first?.citations.first)

        #expect(model.openCitation == nil)
        model.toggleCitation(section101.id)
        #expect(model.openCitation == section101.id)
        #expect(section101.source == response.source.paragraphs[4])
        #expect(section101.source.hasPrefix("(Sec. 101) This section provides continuing FY2024 appropriations"))
        #expect(shown.sourceLabel(section101) == "CRS SUMMARY · ¶5 · PUBLIC LAW")

        model.toggleCitation(purpose.id)
        #expect(model.openCitation == purpose.id)
        model.toggleCitation(purpose.id)
        #expect(model.openCitation == nil)
    }

    @Test func chipsNameTheParagraphAndTheSectionWhenThereIsOne() throws {
        let shown = AIAnalysis(try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis")))
        #expect(shown.citations.map(\.label) == ["CRS ¶2", "CRS ¶5 · Sec. 101", "CRS ¶7", "CRS ¶2"])
    }

    /// A line none of whose citations resolves is cut, not shown uncited; an analysis left with no
    /// lines is treated as none.
    @Test func cutsALineItCannotTieToASource() throws {
        var response = try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis"))
        response.provisions[0].citations[0].paragraph = 99
        let shown = AIAnalysis(response)
        #expect(shown.groups[1].lines.map(\.text) == ["Some agencies are funded through January 19, 2024."])

        for key in [\BillAnalysis.provisions, \.affectedGroups, \.impact] { response[keyPath: key] = [] }
        response.purpose?.citations[0].paragraph = 0
        #expect(AIAnalysis(response).groups.isEmpty)
    }

    /// The worker checked each quote is in its paragraph; a response that contradicts its own
    /// source loses that citation here too. Typography and spacing don't count as a difference.
    @Test func cutsACitationWhoseQuoteIsNotInItsParagraph() throws {
        var response = try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis"))
        response.provisions[0].citations[0].quote = "funds the Pentagon through 2030"
        #expect(AIAnalysis(response).groups[1].lines.map(\.text) == ["Some agencies are funded through January 19, 2024."])

        // Case, a run of spaces, a line break, a curly apostrophe and a trailing ellipsis all fold.
        let paragraph = "The Secretary’s report is due within 90 days."
        #expect(AIAnalysis.quote("...the secretary's  report\nis DUE…", isIn: paragraph))
        #expect(AIAnalysis.quote("the secretary's report is late", isIn: paragraph) == false)
        #expect(AIAnalysis.quote("…", isIn: paragraph) == false)
        #expect(AIAnalysis.quote("report – within", isIn: "report - within 90 days"))
    }

    @Test func cutsALineWithBlankText() throws {
        var response = try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis"))
        response.provisions[0].text = "  \n"
        #expect(AIAnalysis(response).groups[1].lines.map(\.text) == ["Some agencies are funded through January 19, 2024."])
    }

    /// A different analysis on refresh closes the open chip: its id may now name another line.
    @Test func aChangedAnalysisClosesTheOpenCitationButTheSameOneKeepsIt() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        await model.load()
        let first = try #require(try analysis(model).citations.first)
        model.toggleCitation(first.id)
        await model.load()
        #expect(model.openCitation == first.id)

        BillRoutes.set(bill: .ok(try fixture("bill-enacted")), analysis: .ok(try staleAnalysis()))
        await model.load()
        #expect(try analysis(model).stale)
        #expect(model.openCitation == nil)
    }

    /// Try again shows the skeleton at once, then whatever the new request brings.
    @Test func tryAgainShowsTheSkeletonThenTheResult() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .status(500, Data("oops".utf8)))
        await model.load()
        #expect(model.analysis == .failed)

        BillRoutes.set(bill: .ok(try fixture("bill-enacted")), analysis: .slow(try fixture("bill-analysis")))
        let retry = Task { await model.retryAnalysis() }
        await Task.yield()
        #expect(model.analysis == .loading)
        await retry.value
        #expect(try analysis(model).groups.count == 3)
    }

    /// A "none" saved earlier is replaced as soon as the network has an analysis.
    @Test func aSavedNoneGivesWayToANewAnalysis() async throws {
        let before = screen(.ok(try fixture("bill-enacted")), analysis: .status(404, notYet))
        await before.load()
        #expect(before.analysis == .hidden)

        let after = screen(.ok(try fixture("bill-enacted")), analysis: .ok(try fixture("bill-analysis")))
        await after.load()
        #expect(try analysis(after).groups.count == 3)
        #expect(after.saved == nil)
    }

    /// Two loads at once (a pull to refresh over the first open): the later one wins and the
    /// overtaken one leaves nothing behind — no failure, no skeleton.
    @Test func overlappingLoadsSettleOnTheLatest() async throws {
        let model = screen(.ok(try fixture("bill-enacted")), analysis: .slow(try fixture("bill-analysis")))
        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await (first, second)
        #expect(try analysis(model).groups.count == 3)
        guard case .loaded = model.phase else { Issue.record("bill should show"); return }
    }

    // MARK: - Accessibility

    @Test func voiceOverReadsEachLineAsAIWrittenWithItsSource() throws {
        let shown = AIAnalysis(try JSONDecoder().decode(BillAnalysis.self, from: fixture("bill-analysis")))
        let lines = shown.groups.flatMap(\.lines)
        #expect(lines.map(\.accessibilityLabel) == [
            "AI-written: The act continues FY2024 funding for federal agencies, cited from CRS paragraph 2",
            "AI-written: Section 101 extends expiring programs, cited from CRS paragraph 5, Sec. 101",
            "AI-written: Some agencies are funded through January 19, 2024, cited from CRS paragraph 7",
            "AI-written: Federal agencies, cited from CRS paragraph 2",
        ])
        let open = try #require(shown.citations.first)
        #expect(shown.sourceAccessibilityLabel(open).hasPrefix(
            "CRS summary, paragraph 2, Public Law: This act provides continuing FY2024 appropriations"
        ))
    }

    @Test func aLineWithSeveralSourcesNamesThemAll() {
        let citation = { (n: Int) in AIAnalysis.Citation(id: "\(n)", paragraph: n, section: nil, source: "") }
        let line = AIAnalysis.Line(id: "x", text: "Text.", citations: [citation(1), citation(2), citation(3)])
        #expect(line.accessibilityLabel
            == "AI-written: Text, cited from CRS paragraph 1, CRS paragraph 2, and CRS paragraph 3")
    }
}
