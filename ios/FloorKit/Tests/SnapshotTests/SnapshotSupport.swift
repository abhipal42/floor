#if os(iOS)
import APIClient
import DesignSystem
import Foundation
import Models
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

// How these references are made, and why they only run on one simulator: docs/HANDOFF.md,
// "Snapshot tests" under M2. In short — an image depends on the iOS version that drew it, so the
// references are recorded on iOS 26.2 and every test here is skipped on anything else, with the
// reason in the test log, rather than failing for a reason that has nothing to do with the change.

/// The one environment the references were recorded in.
enum SnapshotEnvironment {
    /// The simulator runtime that drew the references. Bump it, re-record and review every image
    /// in one PR when it changes (see the handoff).
    static let pinnedOS = (major: 26, minor: 2)

    static var current: (major: Int, minor: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return (version.majorVersion, version.minorVersion)
    }

    static var matches: Bool { current == pinnedOS }

    static var skipReason: Comment {
        let pinned = "\(pinnedOS.major).\(pinnedOS.minor)"
        let here = "\(current.major).\(current.minor)"
        return Comment(rawValue: "Snapshot references are recorded on iOS \(pinned); this is iOS \(here), "
            + "where they would differ for reasons unrelated to the change.")
    }
}

/// One way of looking at a view: an appearance and a text size.
struct Look: Sendable {
    let name: String
    let style: UIUserInterfaceStyle
    let size: DynamicTypeSize

    static let light = Look(name: "light", style: .light, size: .large)
    static let dark = Look(name: "dark", style: .dark, size: .large)
    /// The largest accessibility size, where the layouts are most likely to break.
    static let largestText = Look(name: "ax5", style: .dark, size: .accessibility5)

    /// Light, dark, and the largest text size: what every key card and screen is checked in.
    static let all: [Look] = [.light, .dark, .largestText]

    var category: UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    /// 2x rather than the phone's 3x: the layout is in points either way, so a digit that wraps
    /// wraps at both, and the references are under half the size.
    var traits: UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.preferredContentSizeCategory = category
            traits.displayScale = 2
        }
    }
}

/// The iPhone 17 Pro's width in points, which every reference is drawn at.
let phoneWidth: CGFloat = 402

/// Anti-aliasing differs a little between machines even on one runtime. 98% perceptual precision
/// absorbs that, and nothing else: a moved digit, a wrapped line or a changed colour fails.
private let perceptualPrecision: Float = 0.98

/// Pixels that may differ outright, as a share of the image: 0.5%, room for a few anti-aliased
/// edges and nowhere near enough for a changed word or digit, which perceptual precision alone
/// could let through on a large screen if the change were faint.
private let precision: Float = 0.995

@MainActor
func assertCard<V: View>(
    _ view: V, _ looks: [Look] = Look.all,
    fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
    line: UInt = #line, column: UInt = #column
) {
    for look in looks {
        let framed = view
            .padding(16)
            .frame(width: phoneWidth)
            // Its own height, whatever height the host proposes first: a squeezed proposal would
            // let the scores' minimumScaleFactor shrink them, and the reference would keep that.
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.ground)
            .modifier(Appearance(look: look))
        assertSnapshot(
            of: framed,
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision, layout: .sizeThatFits, traits: look.traits),
            named: look.name, fileID: fileID, file: file, testName: testName, line: line, column: column
        )
    }
}

/// A whole screen at the phone's width and `height` points tall: tall enough to show the parts
/// a change is most likely to break, which is not always one screenful.
@MainActor
func assertScreen<V: View>(
    _ view: V, height: CGFloat = 874, _ looks: [Look] = Look.all,
    fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
    line: UInt = #line, column: UInt = #column
) {
    for look in looks {
        assertSnapshot(
            of: view.modifier(Appearance(look: look)),
            as: .image(
                precision: precision,
                perceptualPrecision: perceptualPrecision,
                layout: .fixed(width: phoneWidth, height: height),
                traits: look.traits
            ),
            named: look.name, fileID: fileID, file: file, testName: testName, line: line, column: column
        )
    }
}

/// The look set in SwiftUI's own environment too, not only the traits, so `@ScaledMetric`, the
/// custom fonts and the palette all read the same values whichever they consult.
private struct Appearance: ViewModifier {
    let look: Look

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, look.style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, look.size)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "America/New_York")!)
    }
}

// MARK: - Fixtures

private let fixtureDirectory: URL = {
    var dir = URL(fileURLWithPath: #filePath)
    dir.deleteLastPathComponent() // SnapshotTests
    dir.deleteLastPathComponent() // Tests
    return dir.appendingPathComponent("ModelsTests/Fixtures")
}()

/// One of the real staging responses captured in `ModelsTests/Fixtures`.
func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: fixtureDirectory.appendingPathComponent("\(name).json")))
}

/// The Austin delegation (TX-37): Doggett, Cornyn, Cruz.
func austin() throws -> Reps { try fixture("reps-location-austin") }

/// A member's vote from their captured record, as Home's feed hands it to a card.
func memberVote(_ record: String, _ voteId: String) throws -> MemberVote {
    let votes: MemberVotes = try fixture(record)
    return try #require(votes.votes.first { $0.vote.id == voteId })
}

// MARK: - A server made of fixtures

/// Answers the API's routes from the captured responses; anything not captured is a 404, as the
/// real API answers an unknown id. The routes are constant, so parallel tests cannot disturb each
/// other.
final class FixtureServer: URLProtocol {
    static let routes: [String: String] = [
        "/v1/reps": "reps-location-austin",
        "/v1/votes/house-119-2-321": "vote-passage-hr1013",
        "/v1/votes/house-119-1-100": "vote-question",
        "/v1/votes/house-118-1-10": "vote-election",
        "/v1/votes/senate-119-2-253": "vote-cloture-failed",
        "/v1/votes/house-119-2-293": "vote-two-thirds-failed",
        "/v1/bills/119-hconres-14": "bill",
        "/v1/bills/118-hr-3746": "bill-enacted",
        "/v1/bills/118-hconres-21": "bill-no-short-title",
        "/v1/bills/119-hr-9340": "bill-stuck-senate",
        "/v1/members/A000370": "member-detail",
        "/v1/members/C001098": "member-detail-cruz",
        "/v1/members/C001098/votes": "member-votes-cruz-40",
        "/v1/members/C001056/votes": "member-votes-cornyn-40",
        "/v1/members/D000399/votes": "member-votes-doggett-40",
    ]

    static var api: FloorAPI { api(FixtureServer.self) }

    static func api(_ protocolClass: URLProtocol.Type) -> FloorAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return FloorAPI(baseURL: URL(string: "https://api.example.test")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let name = Self.routes[url.path]
        let body = name.flatMap { try? Data(contentsOf: fixtureDirectory.appendingPathComponent("\($0).json")) }
            ?? Data(#"{"error":"Not found"}"#.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: name == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A phone with no connection: every request fails as offline.
final class OfflineServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Member portraits come from the network through `AsyncImage`. Refusing them makes every
/// portrait its initials, which is the same on every machine and needs no network.
final class NoPortraits: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unitedstates.github.io" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}

    static let installed: Bool = URLProtocol.registerClass(NoPortraits.self)
}
#endif
