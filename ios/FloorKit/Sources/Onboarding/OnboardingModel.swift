import APIClient
import Foundation
import Models

/// Drives onboarding: find the district from where you are or from an address, see who it
/// resolves to, confirm or try again.
///
/// The address lives only in ``address`` for as long as the screen is open, and a location only in
/// a local inside ``useMyLocation()`` for the length of one request. Each is sent to `/v1/reps`
/// and nowhere else — not stored, not logged, not cached, not part of ``Delegation``.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Phase: Equatable {
        case editing
        case looking
        /// Resolved, waiting for the person to confirm it is right.
        case found(Reps)
        /// Something went wrong; the text is safe to show.
        case failed(String)
    }

    /// How the current lookup was made. Only a location result offers "Not your district?".
    public enum Source: Equatable, Sendable {
        case address, location
    }

    /// The banner above the address field, as the LocApp mock draws it.
    public enum Notice: Equatable, Sendable {
        /// Denied, now or earlier, or withdrawn mid-fix: Settings › Floor turns it back on.
        case locationOff
        /// Location Services are off for the whole phone. Floor's own Settings page cannot help,
        /// so the banner names the system switch and has no link.
        case servicesOff
        /// Screen Time or a profile: not the person's to change, so no link either.
        case locationRestricted
        /// The API's 404 for a point: not in any U.S. congressional district.
        case outsideUS
        /// Precise Location is off. The result is still shown, with this warning above it.
        case approximate
        /// No fix in time, or Core Location failed.
        case locationUnavailable

        public var title: String {
            switch self {
            case .locationOff: "Location is off for Floor"
            case .servicesOff: "Location Services are off on this iPhone"
            case .locationRestricted: "Location is off for Floor"
            case .outsideUS: "That’s not in a U.S. district"
            case .approximate: "Approximate location"
            case .locationUnavailable: "Couldn’t find where you are"
            }
        }

        public var body: String {
            switch self {
            case .locationOff:
                "Turn it on in Settings › Floor › Location, or type an address below."
            case .servicesOff:
                "Turn them on in Settings › Privacy & Security › Location Services, or type an address below."
            case .locationRestricted:
                "Location is restricted on this iPhone, so Floor can’t ask for it. Type an address below."
            case .outsideUS:
                "Floor covers the House and Senate, so it needs a U.S. location or address. Type one below."
            case .approximate:
                "Precise location is off, so the point is only good to a few kilometres and can land in the next district over. Check these are yours."
            case .locationUnavailable:
                "Your iPhone didn’t get a fix in time. Try again, or type an address below."
            }
        }

        /// Whether the banner carries "Open Settings ›", which opens Floor's own page.
        public var opensSettings: Bool { self == .locationOff }

        /// Notices that a trip to Settings can clear, so coming back retries.
        var clearedInSettings: Bool { self == .locationOff || self == .servicesOff }
    }

    public var address: String = ""
    public private(set) var phase: Phase = .editing
    public private(set) var source: Source = .address
    public private(set) var notice: Notice?
    /// Set once the person has used location on this screen; the mock then stops offering it, so
    /// a denial or a wrong district leads to the address field rather than round again.
    public private(set) var triedLocation = false
    /// True while the system alert is up, so a second tap does not stack another request. The
    /// provider always answers (see ``LocationProvider``), so this cannot stick.
    public private(set) var askingPermission = false

    private let api: FloorAPI
    private let store: any DelegationStore
    private let now: @Sendable () -> Date
    /// Built on first use, not with the model: SwiftUI may construct a model it then discards, and
    /// each Core Location provider owns a `CLLocationManager`.
    @ObservationIgnored private var provider: (any LocationProvider)?
    /// Bumped by every lookup and every edit, so a result that arrives after the person has moved
    /// on is dropped rather than drawn over what they are doing now.
    @ObservationIgnored private var generation = 0

    /// - Parameter location: Core Location unless a test or preview passes its own.
    public init(
        api: FloorAPI,
        store: any DelegationStore,
        location: (any LocationProvider)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.store = store
        self.provider = location
        self.now = now
    }

    private var location: any LocationProvider {
        if let provider { return provider }
        let made = CoreLocationProvider()
        provider = made
        return made
    }

    /// Enough to be worth sending. The API itself requires five characters and explains what it
    /// wants, so this only stops obviously-empty submissions.
    public var canLookUp: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 && phase != .looking
    }

    /// "Use my location" is offered until it has been used — or again after a fix that never came,
    /// which is worth retrying.
    public var offersLocation: Bool {
        guard phase == .editing || isFailed else { return false }
        return !triedLocation || notice == .locationUnavailable
    }

    /// The address field is hidden only while a location lookup runs or shows its result; "Not
    /// your district?" brings it back.
    public var showsAddressField: Bool {
        switch phase {
        case .looking, .found: source == .address
        case .editing, .failed: true
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    public func lookUp() async {
        guard phase != .looking else { return }
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 5 else {
            phase = .failed("Enter a street address, city and state.")
            return
        }
        generation += 1
        let mine = generation
        source = .address
        notice = nil
        phase = .looking
        await resolve(mine) { try await self.api.reps(address: query) }
    }

    /// Ask for permission (the system alert, the first time), take one fix, and look it up.
    ///
    /// The coordinate never leaves this function except as the request itself.
    public func useMyLocation() async {
        guard phase != .looking, !askingPermission else { return }
        notice = nil
        askingPermission = true
        let authorization = await location.requestAuthorization()
        askingPermission = false
        // Only now: the screen behind the system alert stays as it was, button and all.
        triedLocation = true
        guard case let .allowed(precise) = authorization else {
            refused(authorization)
            return
        }
        await locate(precise: precise)
    }

    /// Coming back to the app with a "location is off" banner up: they went to Settings to turn it
    /// on, and the mock offers no button to try again, so try once more. If it is still off, nothing
    /// changes — the banner is not re-posted, so VoiceOver does not announce it again.
    public func retryAfterSettings() async {
        guard let notice, notice.clearedInSettings, phase != .looking, !askingPermission else { return }
        // Already answered, so this reads the setting without showing an alert.
        guard case let .allowed(precise) = await location.requestAuthorization() else { return }
        self.notice = nil
        await locate(precise: precise)
    }

    private func refused(_ authorization: LocationAuthorization) {
        switch authorization {
        case .servicesOff: notice = .servicesOff
        case .restricted: notice = .locationRestricted
        case .denied, .allowed: notice = .locationOff
        }
        phase = .editing
    }

    /// One fix, then the lookup.
    private func locate(precise: Bool) async {
        generation += 1
        let mine = generation
        source = .location
        phase = .looking
        let point: Coordinate
        do {
            point = try await location.currentLocation()
        } catch {
            guard mine == generation else { return }
            source = .address
            // Permission withdrawn mid-fix is "location off", not "no fix in time".
            notice = (error as? LocationFailure) == .denied ? .locationOff : .locationUnavailable
            phase = .editing
            return
        }
        guard mine == generation else { return }
        await resolve(mine, outsideUS: .outsideUS) {
            try await self.api.reps(latitude: point.latitude, longitude: point.longitude)
        }
        if mine == generation, case .found = phase, !precise { notice = .approximate }
    }

    /// The shared tail of both lookups. `outsideUS`: what a 404 means for a point, which is a banner
    /// rather than the address field's own error. Drops the answer if a newer lookup or an edit
    /// came since `mine`.
    private func resolve(_ mine: Int, outsideUS: Notice? = nil, _ request: () async throws -> Reps) async {
        let outcome: Result<Reps, any Error>
        do { outcome = .success(try await request()) } catch { outcome = .failure(error) }
        guard mine == generation else { return }
        switch outcome {
        case let .success(reps):
            guard !reps.members.isEmpty else {
                // A district with nobody in it means our member data is behind, not a bad address.
                fail("We found your district but not your representatives. Please try again shortly.")
                return
            }
            phase = .found(reps)
        case let .failure(error as FloorAPIError):
            if error.isNotFound, let outsideUS {
                source = .address
                notice = outsideUS
                phase = .editing
                return
            }
            // The API phrases its 4xx for people — a 404 here explains how to improve the address —
            // so show its wording and fall back to ours only for transport and decoding failures.
            fail(error.errorDescription ?? "Something went wrong. Please try again.")
        case .failure:
            fail("Something went wrong. Please try again.")
        }
    }

    private func fail(_ message: String) {
        // A failed location lookup lands on the address field, which then carries the message.
        source = .address
        phase = .failed(message)
    }

    /// Accepts the resolved delegation and stores it. Returns what was saved, or nil if there is
    /// nothing to confirm yet.
    @discardableResult
    public func confirm() -> Delegation? {
        guard case let .found(reps) = phase else { return nil }
        let delegation = Delegation(reps: reps, resolvedAt: now())
        store.save(delegation)
        return delegation
    }

    /// Go back to the field to correct the address, keeping what was typed. A lookup still in
    /// flight is dropped when it lands. A banner about a failed location stays, as the mock keeps
    /// it while you type; the approximate warning was about a result, which this discards.
    public func edit() {
        generation += 1
        phase = .editing
        if notice == .approximate { notice = nil }
    }

    /// Why a result deals one card, not three: D.C. and the territories have a delegate (Puerto
    /// Rico a resident commissioner) and no senators. nil for a state.
    ///
    /// "One, not three: D.C. has a delegate in the House and no senators. A delegate can’t vote to
    /// pass a bill, so Norton’s record is amendment votes."
    public static func singleMemberNote(_ reps: Reps) -> String? {
        guard reps.senators.isEmpty, let member = reps.representative, member.isDelegate else { return nil }
        let place = member.state == "DC" ? "D.C." : StateName.full(member.state)
        let office = member.title.lowercased()
        let article = office.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "One, not three: \(place) has \(article) \(office) in the House and no senators. "
            + "\(article.capitalized) \(office) can’t vote to pass a bill, so \(member.lastName)’s record is amendment votes."
    }

    /// "Not your district? Type an address": drop the location result and offer the field.
    public func typeAddressInstead() {
        generation += 1
        source = .address
        notice = nil
        phase = .editing
    }
}
