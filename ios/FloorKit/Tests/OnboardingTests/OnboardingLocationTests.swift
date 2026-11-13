import Foundation
import Testing
@testable import Onboarding
import Models

/// "Use my location", state by state, as the locked LocApp mock draws them. Every response is a
/// real `/v1/reps?lat=&lng=` body captured from the deployed API on 2026-11-12, and every expected
/// value is written out by hand rather than derived from the code under test.
///
/// An extension of `OnboardingModelTests` so it shares that suite's `.serialized`: both drive the
/// one shared `StubAPIProtocol`.
extension OnboardingModelTests {
    private func query(_ name: String) -> String? {
        StubAPIProtocol.lastURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    // MARK: - Allowed

    @Test func allowThenFindsTheDistrictFromThePoint() async throws {
        let location = StubLocation(.allowed(precise: true))
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)
        #expect(model.offersLocation)

        await model.useMyLocation()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(reps.district.name == "TX-37")
        #expect(reps.members.map(\.lastName) == ["Doggett", "Cornyn", "Cruz"])
        #expect(model.source == .location)
        #expect(model.notice == nil)
        // The mock hides the field and the button behind a location result.
        #expect(model.showsAddressField == false)
        #expect(model.offersLocation == false)
        #expect(location.authorizationRequests == 1)
        #expect(location.fixRequests == 1)
        #expect(query("lat") == "30.2747")
        #expect(query("lng") == "-97.7404")
        #expect(query("address") == nil)
    }

    @Test func sendsThePointRoundedToFourDecimals() async throws {
        let location = StubLocation(fix: .success(Coordinate(latitude: 30.274_712_9, longitude: -97.740_389_6)))
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)
        await model.useMyLocation()
        #expect(query("lat") == "30.2747")
        #expect(query("lng") == "-97.7404")
        let url = try #require(StubAPIProtocol.lastURL?.absoluteString)
        #expect(!url.contains("30.27471"))
        #expect(!url.contains("97.74038"))
    }

    @Test func notYourDistrictGoesToTheAddressField() async throws {
        let model = model(.json(try repsFixture("reps-location-austin")))
        await model.useMyLocation()
        model.typeAddressInstead()
        #expect(model.phase == .editing)
        #expect(model.source == .address)
        #expect(model.showsAddressField)
        // Location was used; the mock's "address" step offers only the field.
        #expect(model.offersLocation == false)
        #expect(model.confirm() == nil)
    }

    // MARK: - Refused

    @Test func deniedShowsTheSettingsBannerAndKeepsTheField() async {
        let location = StubLocation(.denied)
        let model = model(.failure(URLError(.badURL)), location: location)

        await model.useMyLocation()

        #expect(model.phase == .editing)
        #expect(model.notice == .locationOff)
        #expect(model.notice?.title == "Location is off for Floor")
        #expect(model.notice?.body == "Turn it on in Settings › Floor › Location, or type an address below.")
        #expect(model.notice?.opensSettings == true)
        #expect(model.showsAddressField)
        #expect(model.offersLocation == false)
        // No fix was taken and nothing was sent.
        #expect(location.fixRequests == 0)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    /// Back from Settings with location now on: the mock has no button left to tap, so it retries.
    @Test func retriesOnReturnFromSettingsOnlyWhileTheDenialBannerIsUp() async throws {
        let location = StubLocation(.denied)
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)

        await model.retryAfterSettings()
        #expect(location.authorizationRequests == 0)

        await model.useMyLocation()
        #expect(model.notice == .locationOff)
        location.authorization = .allowed(precise: true)
        await model.retryAfterSettings()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(reps.district.name == "TX-37")
        #expect(model.notice == nil)
        #expect(location.authorizationRequests == 2)
    }

    /// Still off on return: nothing is re-posted, no fix is attempted, nothing is sent.
    @Test func returningFromSettingsStillDeniedChangesNothing() async {
        let location = StubLocation(.denied)
        let model = model(.failure(URLError(.badURL)), location: location)
        await model.useMyLocation()
        #expect(model.notice == .locationOff)

        await model.retryAfterSettings()

        #expect(model.notice == .locationOff)
        #expect(model.phase == .editing)
        #expect(location.authorizationRequests == 2)
        #expect(location.fixRequests == 0)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    /// Location Services off for the whole phone: Floor's own Settings page can't help.
    @Test func locationServicesOffNamesTheSystemSwitchWithoutAnAppLink() async throws {
        let location = StubLocation(.servicesOff)
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)

        await model.useMyLocation()

        #expect(model.phase == .editing)
        #expect(model.notice == .servicesOff)
        #expect(model.notice?.title == "Location Services are off on this iPhone")
        #expect(model.notice?.body
            == "Turn them on in Settings › Privacy & Security › Location Services, or type an address below.")
        #expect(model.notice?.opensSettings == false)
        #expect(model.showsAddressField)
        #expect(location.fixRequests == 0)
        #expect(StubAPIProtocol.lastURL == nil)

        // Turned on in Settings and back: it retries.
        location.authorization = .allowed(precise: true)
        await model.retryAfterSettings()
        guard case .found = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
    }

    @Test func permissionWithdrawnMidFixIsLocationOffNotATimeout() async {
        let location = StubLocation(fix: .failure(.denied))
        let model = model(.failure(URLError(.badURL)), location: location)

        await model.useMyLocation()

        #expect(model.notice == .locationOff)
        #expect(model.notice?.opensSettings == true)
        #expect(model.phase == .editing)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    /// "Not your district?" — or any edit — while a fix is still coming: the late fix is dropped,
    /// never looked up, and never drawn over the address field.
    @Test func aFixThatLandsAfterThePersonMovedOnIsDropped() async throws {
        let location = StubLocation()
        location.holdFix = true
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)

        let task = Task { await model.useMyLocation() }
        while !location.isHoldingFix { await Task.yield() }
        #expect(model.phase == .looking)
        model.typeAddressInstead()
        location.release(.success(Coordinate(latitude: 30.2747, longitude: -97.7404)))
        await task.value

        #expect(model.phase == .editing)
        #expect(model.source == .address)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    @Test func aSecondLookupWhileOneIsRunningIsIgnored() async throws {
        let location = StubLocation()
        location.holdFix = true
        let model = model(.json(try repsFixture("reps-location-austin")), location: location)

        let task = Task { await model.useMyLocation() }
        while !location.isHoldingFix { await Task.yield() }
        model.address = "1100 Congress Ave, Austin, TX 78701"
        await model.lookUp()
        await model.useMyLocation()
        #expect(StubAPIProtocol.lastURL == nil)
        #expect(location.authorizationRequests == 1)

        location.release(.success(Coordinate(latitude: 30.2747, longitude: -97.7404)))
        await task.value
        guard case .found = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(query("lat") == "30.2747")
        #expect(query("address") == nil)
    }

    @Test func restrictedSaysSoWithoutASettingsLinkThatCannotHelp() async {
        let location = StubLocation(.restricted)
        let model = model(.failure(URLError(.badURL)), location: location)

        await model.useMyLocation()

        #expect(model.phase == .editing)
        #expect(model.notice == .locationRestricted)
        #expect(model.notice?.title == "Location is off for Floor")
        #expect(model.notice?.opensSettings == false)
        #expect(model.showsAddressField)
        #expect(location.fixRequests == 0)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    @Test func typingAfterADenialKeepsTheBannerAndLooksUpTheAddress() async throws {
        let model = model(.json(try repsFixture("reps-location-austin")), location: StubLocation(.denied))
        await model.useMyLocation()
        model.address = "1100 Congress Ave, Austin, TX 78701"
        model.edit()
        #expect(model.notice == .locationOff)

        await model.lookUp()
        guard case .found = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(model.notice == nil)
        #expect(model.source == .address)
        #expect(query("address") == "1100 Congress Ave, Austin, TX 78701")
        #expect(query("lat") == nil)
    }

    // MARK: - Approximate

    @Test func reducedAccuracyStillShowsTheResultUnderAWarning() async throws {
        let model = model(.json(try repsFixture("reps-location-austin")), location: StubLocation(.allowed(precise: false)))

        await model.useMyLocation()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(reps.district.name == "TX-37")
        #expect(model.notice == .approximate)
        #expect(model.notice?.title == "Approximate location")
        #expect(model.notice?.body == "Precise location is off, so the point is only good to a few kilometres and can land in the next district over. Check these are yours.")
        #expect(model.notice?.opensSettings == false)
        // Still confirmable: the warning asks them to check, it does not refuse.
        #expect(model.confirm()?.district.district == 37)
    }

    @Test func theApproximateWarningGoesWithItsResult() async throws {
        let model = model(.json(try repsFixture("reps-location-austin")), location: StubLocation(.allowed(precise: false)))
        await model.useMyLocation()
        model.typeAddressInstead()
        #expect(model.notice == nil)
    }

    // MARK: - Failures

    @Test func aPointOutsideTheUSShowsTheBannerAndTheField() async throws {
        let location = StubLocation(fix: .success(Coordinate(latitude: 51.5074, longitude: -0.1278)))
        let model = model(.json(try repsFixture("reps-location-london"), status: 404), location: location)

        await model.useMyLocation()

        #expect(model.phase == .editing)
        #expect(model.notice == .outsideUS)
        #expect(model.notice?.title == "That’s not in a U.S. district")
        #expect(model.notice?.body == "Floor covers the House and Senate, so it needs a U.S. location or address. Type one below.")
        #expect(model.notice?.opensSettings == false)
        #expect(model.showsAddressField)
        #expect(model.source == .address)
        #expect(query("lat") == "51.5074")
        #expect(query("lng") == "-0.1278")
    }

    @Test func aNetworkErrorFallsBackToTheFieldWithAShortMessage() async {
        let model = model(.failure(URLError(.notConnectedToInternet)))

        await model.useMyLocation()

        guard case let .failed(message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message == "Couldn't reach Floor. Check your connection and try again.")
        #expect(model.showsAddressField)
        #expect(model.source == .address)
        #expect(model.notice == nil)
    }

    @Test func noFixInTimeFallsBackToTheFieldAndOffersARetry() async {
        let location = StubLocation(fix: .failure(.timedOut))
        let model = model(.failure(URLError(.badURL)), location: location)

        await model.useMyLocation()

        #expect(model.phase == .editing)
        #expect(model.notice == .locationUnavailable)
        #expect(model.notice?.title == "Couldn’t find where you are")
        #expect(model.showsAddressField)
        #expect(model.offersLocation)
        #expect(StubAPIProtocol.lastURL == nil)
    }

    // MARK: - One member, at large

    @Test func washingtonDealsOneDelegateAndSaysWhy() async throws {
        let location = StubLocation(fix: .success(Coordinate(latitude: 38.8977, longitude: -77.0365)))
        let store = InMemoryDelegationStore()
        let model = model(.json(try repsFixture("reps-location-dc")), store: store, location: location)

        await model.useMyLocation()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(reps.members.map(\.lastName) == ["Norton"])
        #expect(StateName.districtName(state: reps.district.state, district: reps.district.district)
            == "District of Columbia")
        #expect(OnboardingModel.singleMemberNote(reps)
            == "One, not three: D.C. has a delegate in the House and no senators. A delegate can’t vote to pass a bill, so Norton’s record is amendment votes.")

        let saved = try #require(model.confirm())
        #expect(saved.memberIds == ["N000147"])
        #expect(saved.representative?.lastName == "Norton")
        #expect(saved.senators.isEmpty)
        #expect(store.load() == saved)
    }

    @Test func aStateGetsNoSingleMemberNoteAndATerritoryGetsItsOwnTitle() throws {
        let texas = try JSONDecoder().decode(Reps.self, from: Data(try repsFixture("reps-location-austin").utf8))
        #expect(OnboardingModel.singleMemberNote(texas) == nil)
        let wyoming = try JSONDecoder().decode(Reps.self, from: Data(try repsFixture("reps-location-cheyenne").utf8))
        #expect(OnboardingModel.singleMemberNote(wyoming) == nil)

        let puertoRico = Reps(
            district: District(congress: 119, state: "PR", district: 0, countyFips: nil),
            members: [Member(bioguideId: "TEST-PR", firstName: "Pablo", lastName: "Hernández", party: "D",
                             state: "PR", district: 0, chamber: .house)]
        )
        #expect(OnboardingModel.singleMemberNote(puertoRico)
            == "One, not three: Puerto Rico has a resident commissioner in the House and no senators. A resident commissioner can’t vote to pass a bill, so Hernández’s record is amendment votes.")
    }

    @Test func cheyenneIsWyomingsAtLargeDistrict() async throws {
        let location = StubLocation(fix: .success(Coordinate(latitude: 41.1400, longitude: -104.8202)))
        let model = model(.json(try repsFixture("reps-location-cheyenne")), location: location)

        await model.useMyLocation()

        guard case let .found(reps) = model.phase else {
            Issue.record("expected .found, got \(model.phase)")
            return
        }
        #expect(StateName.districtName(state: reps.district.state, district: reps.district.district)
            == "Wyoming's at-large district")
        #expect(reps.members.map(\.seatCaption) == ["House · WY-AL", "Senate · WY", "Senate · WY"])
        #expect(query("lat") == "41.1400")
        #expect(query("lng") == "-104.8202")
    }

    // MARK: - Privacy

    /// The point is used for one request and dropped: not in the saved record, not anywhere in the
    /// defaults it is saved to, and not held by the model afterwards.
    @Test func neverStoresTheCoordinates() async throws {
        let suite = "floor.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDelegationStore(defaults: defaults)
        let location = StubLocation(fix: .success(Coordinate(latitude: 30.274_712_9, longitude: -97.740_389_6)))
        let model = model(.json(try repsFixture("reps-location-austin")), store: store, location: location)

        await model.useMyLocation()
        let saved = try #require(model.confirm())

        let encoded = try #require(String(data: JSONEncoder().encode(saved), encoding: .utf8))
        let everything = String(describing: defaults.dictionaryRepresentation())
            + String(data: try #require(defaults.data(forKey: UserDefaultsDelegationStore.key)), encoding: .utf8)!
        for text in [encoded, everything] {
            #expect(!text.contains("30.27"))
            #expect(!text.contains("97.74"))
            #expect(!text.contains("latitude"))
            #expect(!text.contains("\"lat\""))
        }
        // What it does keep is the district and the members.
        #expect(encoded.contains("D000399"))

        // Nor does the model keep the point once the request is made.
        let held = Mirror(reflecting: model).children.map { String(describing: $0.value) }.joined(separator: " ")
        #expect(!held.contains("30.27"))
        #expect(!held.contains("Coordinate("))
    }
}
