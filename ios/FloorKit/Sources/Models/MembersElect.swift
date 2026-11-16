import Foundation

// Members-elect (round 12, https://claude.ai/artifact/Hod9RDLS1DgxapLeBcA3QY): the winners of a
// general election before they take office, and the seats whose race is not decided yet.
//
// Floor never calls a race. Every elect carries who called it (the AP for a senator-elect, the House
// Clerk's member-elect list for a representative-elect) and a source URL; a pending seat never
// carries a name. The API serves none of this once `takesOffice` has passed.
//
// Decoded leniently, as the disclosures are: the routes were built in parallel with these screens,
// so a missing list reads as empty, a row that cannot be read is dropped, and an older API's
// response still decodes.

/// The sitting member a seat belongs to now: the one an elect replaces, or a pending seat's incumbent.
public struct SeatHolder: Codable, Sendable, Hashable {
    public var bioguideId: String
    public var firstName: String
    public var lastName: String
    public var party: String

    public init(bioguideId: String, firstName: String, lastName: String, party: String) {
        self.bioguideId = bioguideId
        self.firstName = firstName
        self.lastName = lastName
        self.party = party
    }

    public var fullName: String { "\(firstName) \(lastName)" }
}

/// Who called the race, when, and where it says so.
public struct ElectCall: Codable, Sendable, Hashable {
    /// `AP` or `House Clerk`.
    public var by: String
    /// `YYYY-MM-DD`; nil when the source gives no date (the Clerk's list).
    public var on: String?
    public var sourceUrl: String?

    public init(by: String, on: String?, sourceUrl: String?) {
        self.by = by
        self.on = on
        self.sourceUrl = sourceUrl
    }

    private enum CodingKeys: String, CodingKey { case by, on, sourceUrl }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        by = try c.decode(String.self, forKey: .by)
        on = try? c.decodeIfPresent(String.self, forKey: .on)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
    }

    public var isClerk: Bool { by == "House Clerk" }
}

/// A member-elect: `MemberElect` in the API.
public struct MemberElect: Codable, Sendable, Hashable, Identifiable {
    /// `elect-2026-mi-sen`, `elect-2026-ny-12`.
    public var id: String
    /// Once assigned (the Clerk's list carries them); nil for most senators-elect.
    public var bioguideId: String?
    public var firstName: String
    public var lastName: String
    public var party: String
    public var state: String
    public var district: Int?
    public var chamber: Chamber
    /// `YYYY-MM-DD`, a calendar day: `2027-01-03`.
    public var takesOffice: String
    /// The member leaving the seat; nil when that is not known.
    public var replaces: SeatHolder?
    public var call: ElectCall
    public var fecCandidateId: String?
    /// A special election's winner who is not the incumbent: sworn in once the state certifies the
    /// result, on no known date. Then `takesOffice` is never shown, and the member they replace is
    /// not LEAVING (the API sends them no `leavingOn`). False from an API older than the field.
    public var takesOfficeOnCertification: Bool

    public init(
        id: String, bioguideId: String?, firstName: String, lastName: String, party: String, state: String,
        district: Int?, chamber: Chamber, takesOffice: String, replaces: SeatHolder?, call: ElectCall,
        fecCandidateId: String?, takesOfficeOnCertification: Bool = false
    ) {
        self.takesOfficeOnCertification = takesOfficeOnCertification
        self.id = id
        self.bioguideId = bioguideId
        self.firstName = firstName
        self.lastName = lastName
        self.party = party
        self.state = state
        self.district = district
        self.chamber = chamber
        self.takesOffice = takesOffice
        self.replaces = replaces
        self.call = call
        self.fecCandidateId = fecCandidateId
    }

    private enum CodingKeys: String, CodingKey {
        case id, bioguideId, firstName, lastName, party, state, district, chamber, takesOffice, replaces, call
        case fecCandidateId, takesOfficeOnCertification
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bioguideId = try? c.decodeIfPresent(String.self, forKey: .bioguideId)
        firstName = try c.decode(String.self, forKey: .firstName)
        lastName = try c.decode(String.self, forKey: .lastName)
        party = try c.decode(String.self, forKey: .party)
        state = try c.decode(String.self, forKey: .state)
        district = try? c.decodeIfPresent(Int.self, forKey: .district)
        chamber = try c.decode(Chamber.self, forKey: .chamber)
        takesOffice = try c.decode(String.self, forKey: .takesOffice)
        replaces = try? c.decodeIfPresent(SeatHolder.self, forKey: .replaces)
        call = try c.decode(ElectCall.self, forKey: .call)
        fecCandidateId = try? c.decodeIfPresent(String.self, forKey: .fecCandidateId)
        takesOfficeOnCertification = (try? c.decodeIfPresent(Bool.self, forKey: .takesOfficeOnCertification)) ?? false
    }

    public var fullName: String { "\(firstName) \(lastName)" }

    /// The year the race was decided: the call's, else the year before a term that starts in January.
    var electionYear: Int? {
        if let on = call.on, let year = Int(on.prefix(4)) { return year }
        guard let year = Int(takesOffice.prefix(4)) else { return nil }
        return takesOfficeOnCertification ? year : year - 1
    }

    /// The elect as a `Member`, for what draws a member (initials, party tint, seat badge). The id is
    /// the Bioguide ID once assigned, else the elect id, which names no portrait.
    public var asMember: Member {
        Member(bioguideId: bioguideId ?? id, firstName: firstName, lastName: lastName, party: party, state: state,
               district: district, chamber: chamber)
    }

    /// `Senator-elect`, `Representative-elect`, `Delegate-elect`.
    public var title: String { "\(asMember.title)-elect" }
}

/// A seat whose race is not decided: `PendingSeat` in the API. Never carries a candidate's name.
public struct PendingSeat: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case uncalled, runoff
    }

    public var id: String
    public var state: String
    public var district: Int?
    public var chamber: Chamber
    public var status: Status
    /// `YYYY-MM-DD`, for a runoff.
    public var runoffOn: String?
    public var incumbent: SeatHolder?
    public var sourceUrl: String?

    public init(
        id: String, state: String, district: Int?, chamber: Chamber, status: Status, runoffOn: String?,
        incumbent: SeatHolder?, sourceUrl: String?
    ) {
        self.id = id
        self.state = state
        self.district = district
        self.chamber = chamber
        self.status = status
        self.runoffOn = runoffOn
        self.incumbent = incumbent
        self.sourceUrl = sourceUrl
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, district, chamber, status, runoffOn, incumbent, sourceUrl
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(String.self, forKey: .state)
        district = try? c.decodeIfPresent(Int.self, forKey: .district)
        chamber = try c.decode(Chamber.self, forKey: .chamber)
        // A status this build does not know is still a seat without a winner.
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .uncalled
        runoffOn = try? c.decodeIfPresent(String.self, forKey: .runoffOn)
        incumbent = try? c.decodeIfPresent(SeatHolder.self, forKey: .incumbent)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
    }

    /// `LA-5`, `MI` for a Senate seat.
    public var seatBadge: String {
        Member(bioguideId: id, firstName: "", lastName: "", party: "", state: state, district: district, chamber: chamber)
            .seatBadge
    }
}

/// `GET /v1/members-elect?state=`.
public struct MembersElect: Codable, Sendable, Hashable {
    public var elect: [MemberElect]
    public var pending: [PendingSeat]

    public init(elect: [MemberElect] = [], pending: [PendingSeat] = []) {
        self.elect = elect
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case elect, pending }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (elect, pending) = ElectLists.decode(c, elect: .elect, pending: .pending)
    }

    /// Only the seats an address's delegation holds: the state's Senate seats and its House district.
    public func seats(state: String, district: Int?) -> MembersElect {
        func mine(_ s: String, _ c: Chamber, _ d: Int?) -> Bool {
            s == state && (c == .senate || d == district)
        }
        return MembersElect(elect: elect.filter { mine($0.state, $0.chamber, $0.district) },
                            pending: pending.filter { mine($0.state, $0.chamber, $0.district) })
    }
}

/// How the lists that carry elects and pending seats read them, wherever they sit.
enum ElectLists {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, elect: K, pending: K) -> ([MemberElect], [PendingSeat]) {
        let e = ((try? c.decodeIfPresent([LossyElement<MemberElect>].self, forKey: elect)) ?? []).compactMap(\.value)
        let p = ((try? c.decodeIfPresent([LossyElement<PendingSeat>].self, forKey: pending)) ?? []).compactMap(\.value)
        return (e, p)
    }
}

/// The FEC totals of a member-elect's campaign.
public struct ElectFunding: Codable, Sendable, Hashable {
    public var cycle: Int?
    public var receipts: Double?
    public var disbursements: Double?
    /// `YYYY-MM-DD`: the last day the reports cover.
    public var coverageEnd: String?
    public var sourceUrl: String?

    public init(cycle: Int?, receipts: Double?, disbursements: Double?, coverageEnd: String?, sourceUrl: String?) {
        self.cycle = cycle
        self.receipts = receipts
        self.disbursements = disbursements
        self.coverageEnd = coverageEnd
        self.sourceUrl = sourceUrl
    }

    private enum CodingKeys: String, CodingKey { case cycle, receipts, disbursements, coverageEnd, sourceUrl }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cycle = try? c.decodeIfPresent(Int.self, forKey: .cycle)
        receipts = try? c.decodeIfPresent(Double.self, forKey: .receipts)
        disbursements = try? c.decodeIfPresent(Double.self, forKey: .disbursements)
        coverageEnd = try? c.decodeIfPresent(String.self, forKey: .coverageEnd)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
    }
}

/// A member-elect's candidate financial disclosure: assets in ranges as filed, never a total.
public struct ElectDisclosure: Codable, Sendable, Hashable {
    public var filedAt: String?
    public var sourceUrl: String?
    public var assets: [DisclosedAsset]
    /// Filed on paper: linked, not read.
    public var paper: Bool

    public init(filedAt: String?, sourceUrl: String?, assets: [DisclosedAsset], paper: Bool) {
        self.filedAt = filedAt
        self.sourceUrl = sourceUrl
        self.assets = assets
        self.paper = paper
    }

    private enum CodingKeys: String, CodingKey { case filedAt, sourceUrl, assets, paper }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filedAt = try? c.decodeIfPresent(String.self, forKey: .filedAt)
        sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
        assets = ((try? c.decodeIfPresent([LossyElement<DisclosedAsset>].self, forKey: .assets)) ?? []).compactMap(\.value)
        paper = (try? c.decodeIfPresent(Bool.self, forKey: .paper)) ?? false
    }
}

/// `GET /v1/members-elect/{id}`.
public struct ElectProfile: Codable, Sendable, Hashable {
    public var elect: MemberElect
    public var funding: ElectFunding?
    public var disclosure: ElectDisclosure?

    public init(elect: MemberElect, funding: ElectFunding?, disclosure: ElectDisclosure?) {
        self.elect = elect
        self.funding = funding
        self.disclosure = disclosure
    }

    private enum CodingKeys: String, CodingKey { case elect, funding, disclosure }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elect = try c.decode(MemberElect.self, forKey: .elect)
        funding = try? c.decodeIfPresent(ElectFunding.self, forKey: .funding)
        disclosure = try? c.decodeIfPresent(ElectDisclosure.self, forKey: .disclosure)
    }
}

// MARK: - Rows

/// One row of a delegation that may be changing hands: a member (tagged LEAVING when an elect
/// replaces them), an elect directly under the member they replace, or a seat with no winner yet.
public enum SeatRow: Sendable, Hashable, Identifiable {
    /// `leavingOn`: the day they leave, `YYYY-MM-DD`, or nil when they are staying.
    case member(Member, leavingOn: String?)
    case elect(MemberElect)
    case pending(PendingSeat)

    public var id: String {
        switch self {
        case let .member(member, _): "member-\(member.bioguideId)"
        case let .elect(elect): elect.id
        case let .pending(seat): "pending-\(seat.id)"
        }
    }

    /// Members in their order, each followed by the elect replacing them and any undecided seat
    /// they hold; elects and seats that match no member listed go last.
    public static func rows(members: [Member], elect: [MemberElect], pending: [PendingSeat]) -> [SeatRow] {
        var rows: [SeatRow] = []
        var placedElect = Set<String>(), placedPending = Set<String>()
        for member in members {
            let replacing = elect.filter { $0.replaces?.bioguideId == member.bioguideId }
            // A special election's winner takes office on certification, with no date to leave by.
            let leaving = member.leavingOn ?? replacing.first { !$0.takesOfficeOnCertification }?.takesOffice
            rows.append(.member(member, leavingOn: leaving))
            for e in replacing where placedElect.insert(e.id).inserted { rows.append(.elect(e)) }
            for p in pending where p.incumbent?.bioguideId == member.bioguideId && placedPending.insert(p.id).inserted {
                rows.append(.pending(p))
            }
        }
        rows += elect.filter { !placedElect.contains($0.id) }.map(SeatRow.elect)
        rows += pending.filter { !placedPending.contains($0.id) }.map(SeatRow.pending)
        return rows
    }

    /// True when some row is about a seat changing hands, not only sitting members staying put.
    public static func changing(_ rows: [SeatRow]) -> Bool {
        rows.contains {
            if case let .member(_, leavingOn) = $0 { return leavingOn != nil }
            return true
        }
    }
}

// MARK: - Words

/// The dates and lines the elect rows and screen print. Calendar days are read and printed in UTC
/// so Jan 3 never slides to Jan 2 west of Greenwich; the locale is the caller's (the environment's).
public enum ElectText {
    /// `Jan 3, 2027`.
    public static func day(_ iso: String, locale: Locale) -> String? {
        Formats.day(iso).map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: .gmt)) }
    }

    /// `Jan 3`.
    public static func monthDay(_ iso: String, locale: Locale) -> String? {
        Formats.day(iso).map { $0.formatted(Date.FormatStyle(locale: locale, timeZone: .gmt).month(.abbreviated).day()) }
    }

    /// The general election before a term that starts on `takesOffice`: the Tuesday after the first
    /// Monday in November of the year before (2 U.S.C. §7), `YYYY-MM-DD`.
    public static func electionDay(takesOffice: String) -> String? {
        Int(takesOffice.prefix(4)).flatMap { electionDay(year: $0 - 1) }
    }

    /// The general election day of an elect's race: a special election held with the general falls
    /// on the same day (Ohio's, Nov 3, 2026).
    public static func electionDay(_ elect: MemberElect) -> String? {
        elect.electionYear.flatMap(electionDay(year:))
    }

    /// The Congress they sit in: the next one for a January start, the current one for a special.
    public static func congress(_ elect: MemberElect) -> Int? {
        if elect.takesOfficeOnCertification { return elect.electionYear.map { ($0 - 1789) / 2 + 1 } }
        return congress(takesOffice: elect.takesOffice)
    }

    /// `Jan 3`, or `when Ohio certifies` for a special election's winner, who has no date.
    public static func takesOffice(_ elect: MemberElect, locale: Locale) -> String {
        if elect.takesOfficeOnCertification { return "when \(StateName.full(elect.state)) certifies" }
        return monthDay(elect.takesOffice, locale: locale) ?? elect.takesOffice
    }

    /// The Tuesday after the first Monday in November of `year`, `YYYY-MM-DD`.
    public static func electionDay(year: Int) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let first = utc.date(from: DateComponents(year: year, month: 11, day: 1)) else { return nil }
        let weekday = utc.component(.weekday, from: first) // 1 = Sunday, 2 = Monday
        let firstMonday = 1 + (9 - weekday) % 7
        return String(format: "%04d-11-%02d", year, firstMonday + 1)
    }

    /// The Congress a term starting on `takesOffice` sits in: 2027 is the 120th.
    public static func congress(takesOffice: String) -> Int? {
        guard let year = Int(takesOffice.prefix(4)) else { return nil }
        return (year - 1789) / 2 + 1
    }

    /// `Race called by AP`, `Listed by the House Clerk`.
    public static func calledBy(_ call: ElectCall) -> String {
        call.isClerk ? "Listed by the House Clerk" : "Race called by \(call.by)"
    }

    /// Under an elect row: `Race called by AP on Nov 4. Floor shows the call, it doesn't make one.`
    public static func callLine(_ call: ElectCall, locale: Locale) -> String {
        let when = call.on.flatMap { monthDay($0, locale: locale) }.map { " on \($0)" } ?? ""
        return call.isClerk
            ? "Listed by the House Clerk\(when). Floor shows the list, it doesn't make one."
            : "Race called by \(call.by)\(when). Floor shows the call, it doesn't make one."
    }

    /// `Michigan's Senate seat`, `New York's 12th District`.
    public static func seatName(state: String, district: Int?, chamber: Chamber) -> String {
        if chamber == .house, let district { return StateName.districtName(state: state, district: district) }
        let name = StateName.full(state)
        return "\(name.hasSuffix("s") ? "\(name)'" : "\(name)'s") Senate seat"
    }

    /// The pending seat's placeholder: a title and a line, never a name.
    public static func pending(_ seat: PendingSeat, locale: Locale) -> (title: String, body: String) {
        let seatName = seatName(state: seat.state, district: seat.district, chamber: seat.chamber)
        switch seat.status {
        case .runoff:
            let when = seat.runoffOn.flatMap { monthDay($0, locale: locale) }
            return (when.map { "Runoff \($0)" } ?? "Runoff ahead",
                    "\(seatName): no winner yet. This seat fills in when the race is decided.")
        case .uncalled:
            return ("Race not called yet",
                    "\(seatName): Floor waits for the call. It never shows a leader or a projection.")
        }
    }
}

// MARK: - Samples

// Abdul El-Sayed (Michigan, Senate), as the contract's fixture has him: elected Nov 3, 2026, the
// AP's call early on Nov 4, FEC S6MI00418 through the pre-general report (Oct 14).

public extension MemberElect {
    static let sample = MemberElect(
        id: "elect-2026-mi-sen", bioguideId: nil, firstName: "Abdul", lastName: "El-Sayed", party: "D", state: "MI",
        district: nil, chamber: .senate, takesOffice: "2027-01-03",
        replaces: SeatHolder(bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D"),
        call: ElectCall(
            by: "AP", on: "2026-11-04",
            sourceUrl: "https://www.wsbtv.com/news/trending/election-2026-abdul-el-sayed-prevails-win-us-senate-seat-michigan/DGWW7OLFAVCKBH3ZXXU5Y46YVE/"
        ),
        fecCandidateId: "S6MI00418"
    )
}

/// A layout sample, not a real race (the locked mock's LA-5, marked SAMPLE there): tests only.
public extension PendingSeat {
    static let sample = PendingSeat(
        id: "elect-2026-la-5", state: "LA", district: 5, chamber: .house, status: .runoff, runoffOn: "2026-12-12",
        incumbent: nil, sourceUrl: "https://example.com/sample-pending-seat"
    )
}
