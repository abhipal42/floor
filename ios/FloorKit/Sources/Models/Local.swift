import Foundation

// v0.2.60, the Local tab (the locked mock https://claude.ai/artifact/Lz7DMYwAUMLCzUQwuupFKW, State &
// city option A): the user's state and saved cities as hubs. `GET /v1/local`, `/v1/local/{id}` and
// `/v1/local/{state}/legislators`. Decoded leniently, as `News` is: one bad item is dropped, an
// unknown enum value reads as the safe default, and a missing field reads as nil or empty.

/// One place Floor can show: a state (Open States) or a city (a council records feed, or news only).
public struct Jurisdiction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case state, city
    }

    public enum Coverage: String, Codable, Sendable, Hashable, CaseIterable {
        /// Items from the last 90 days.
        case records
        /// A records source exists; nothing from it yet.
        case pending
        /// No records source Floor can read: headlines only.
        case newsOnly = "news_only"
    }

    /// `ny`, `nyc`, `seattle`.
    public var id: String
    public var kind: Kind
    /// `New York State`, `New York City`.
    public var name: String
    /// Postal code.
    public var state: String
    /// The Census place GEOID, for a city.
    public var placeGeoid: String?
    public var coverage: Coverage

    public init(id: String, kind: Kind, name: String, state: String, placeGeoid: String? = nil, coverage: Coverage) {
        self.id = id
        self.kind = kind
        self.name = name
        self.state = state
        self.placeGeoid = placeGeoid
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, state, placeGeoid, coverage }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? ""
        placeGeoid = (try? c.decodeIfPresent(String.self, forKey: .placeGeoid)) ?? nil
        coverage = ((try? c.decodeIfPresent(String.self, forKey: .coverage)) ?? nil).flatMap(Coverage.init(rawValue:)) ?? .pending
    }
}

/// `GET /v1/local`: the registry.
public struct LocalJurisdictions: Codable, Sendable, Hashable {
    public var jurisdictions: [Jurisdiction]

    public init(jurisdictions: [Jurisdiction]) {
        self.jurisdictions = jurisdictions
    }

    private enum CodingKeys: String, CodingKey { case jurisdictions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jurisdictions = ((try? c.decodeIfPresent([LossyElement<Jurisdiction>].self, forKey: .jurisdictions)) ?? [])
            .compactMap(\.value)
    }

    public var cities: [Jurisdiction] { jurisdictions.filter { $0.kind == .city } }

    /// The state hub for a postal code.
    public func state(_ postal: String) -> Jurisdiction? {
        jurisdictions.first { $0.kind == .state && $0.state.caseInsensitiveCompare(postal) == .orderedSame }
    }

    /// The registry city a Census place is, if it is one.
    public func city(placeGeoid: String) -> Jurisdiction? {
        cities.first { $0.placeGeoid == placeGeoid }
    }
}

/// A state bill signed or waiting, or a city council matter passed.
public struct LocalItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        case signed
        case becameLaw = "became_law"
        case passed
        case awaitingGovernor = "awaiting_governor"
    }

    public var id: String
    /// `S 1234`, `Int. 891-A`, `CB 121276`.
    public var identifier: String
    public var title: String
    public var summary: String?
    /// `State Senate`, `Assembly`, `City Council`.
    public var body: String
    /// `YYYY-MM-DD`.
    public var date: String
    public var status: Status
    public var yes: Int?
    public var no: Int?
    public var url: String?

    public init(id: String, identifier: String, title: String, summary: String? = nil, body: String, date: String,
                status: Status, yes: Int? = nil, no: Int? = nil, url: String? = nil) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.body = body
        self.date = date
        self.status = status
        self.yes = yes
        self.no = no
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case id, identifier, title, summary, body, date, status, yes, no, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(String.self, forKey: .date)
        status = try c.decode(Status.self, forKey: .status)
        identifier = ((try? c.decodeIfPresent(String.self, forKey: .identifier)) ?? nil) ?? ""
        summary = ((try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        body = ((try? c.decodeIfPresent(String.self, forKey: .body)) ?? nil) ?? ""
        yes = (try? c.decodeIfPresent(Int.self, forKey: .yes)) ?? nil
        no = (try? c.decodeIfPresent(Int.self, forKey: .no)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
    }

    public var link: URL? { url.flatMap(URL.init(string:)) }

    /// The tally, when the record has one.
    public var tally: (yes: Int, no: Int)? {
        guard let yes, let no else { return nil }
        return (yes, no)
    }

    /// `Nov 11`, a calendar day read in UTC so it never shifts with the reader's zone.
    public var shortDate: String {
        guard let day = Formats.day(date) else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return day.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: .gmt)
            .month(.abbreviated).day())
    }
}

/// `GET /v1/local/{id}`: one hub.
public struct LocalHub: Codable, Sendable, Hashable {
    public var jurisdiction: Jurisdiction
    public var updatedAt: String?
    /// State: signed or became law; city: passed. Last 30 days, newest first.
    public var enacted: [LocalItem]
    /// State only: passed both chambers, not yet signed or vetoed.
    public var waiting: [LocalItem]
    /// Last 7 days, newest first; never AI-read.
    public var news: [Headline]

    public init(jurisdiction: Jurisdiction, updatedAt: String? = nil, enacted: [LocalItem] = [],
                waiting: [LocalItem] = [], news: [Headline] = []) {
        self.jurisdiction = jurisdiction
        self.updatedAt = updatedAt
        self.enacted = enacted
        self.waiting = waiting
        self.news = news
    }

    private enum CodingKeys: String, CodingKey { case jurisdiction, updatedAt, enacted, waiting, news }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jurisdiction = try c.decode(Jurisdiction.self, forKey: .jurisdiction)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
        func items(_ key: CodingKeys) -> [LocalItem] {
            ((try? c.decodeIfPresent([LossyElement<LocalItem>].self, forKey: key)) ?? []).compactMap(\.value)
                .sorted { $0.date > $1.date }
        }
        enacted = items(.enacted)
        waiting = jurisdiction.kind == .city ? [] : items(.waiting)
        news = Headline.newestFirst(
            ((try? c.decodeIfPresent([LossyElement<Headline>].self, forKey: .news)) ?? []).compactMap(\.value)
        )
    }

    /// Nothing passed, waiting or in the news.
    public var isEmpty: Bool { enacted.isEmpty && waiting.isEmpty && news.isEmpty }
}

/// A member of the user's state legislature, from Open States.
public struct StateLegislator: Codable, Sendable, Hashable, Identifiable {
    public enum Chamber: String, Codable, Sendable, Hashable, CaseIterable {
        case upper, lower
    }

    public var id: String
    public var name: String
    /// As Open States writes it: `Democratic`, `Republican`, `Independent`.
    public var party: String
    public var chamber: Chamber
    public var district: String
    public var photoUrl: String?
    public var url: String?

    public init(id: String, name: String, party: String, chamber: Chamber, district: String,
                photoUrl: String? = nil, url: String? = nil) {
        self.id = id
        self.name = name
        self.party = party
        self.chamber = chamber
        self.district = district
        self.photoUrl = photoUrl
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case id, name, party, chamber, district, photoUrl, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        chamber = try c.decode(Chamber.self, forKey: .chamber)
        party = ((try? c.decodeIfPresent(String.self, forKey: .party)) ?? nil) ?? ""
        district = ((try? c.decodeIfPresent(String.self, forKey: .district)) ?? nil) ?? ""
        photoUrl = (try? c.decodeIfPresent(String.self, forKey: .photoUrl)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
    }

    /// `D`, `R`, `I`: the letter the party colours key on.
    public var partyLetter: String {
        let lower = party.lowercased()
        if lower.hasPrefix("democrat") { return "D" }
        if lower.hasPrefix("republican") { return "R" }
        return party.isEmpty ? "" : "I"
    }

    /// `KG` for Kristen Gonzalez.
    public var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first.map(String.init) }.joined().uppercased()
    }
}

/// `GET /v1/local/{state}/legislators`.
public struct StateLegislators: Codable, Sendable, Hashable {
    public var legislators: [StateLegislator]

    public init(legislators: [StateLegislator]) {
        self.legislators = legislators
    }

    private enum CodingKeys: String, CodingKey { case legislators }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        legislators = ((try? c.decodeIfPresent([LossyElement<StateLegislator>].self, forKey: .legislators)) ?? [])
            .compactMap(\.value)
            .sorted { $0.chamber == .upper && $1.chamber == .lower }
    }

    public static let none = StateLegislators(legislators: [])
}

/// The words the state hub needs that depend on the state: what its chambers are called.
///
/// Kept to the same table as Android (the lead's parity call, v0.2.60): New York's lower chamber is
/// the Assembly, every other state's reads "State House". California, Nevada, New Jersey and
/// Wisconsin also call theirs the Assembly, and Maryland, Virginia and West Virginia the House of
/// Delegates; widen this on both platforms together.
public enum StateChambers {
    /// States whose lower chamber is named the Assembly here.
    static let assembly: Set<String> = ["NY"]

    /// `State Senate`, `Assembly`, `State House`.
    public static func name(_ chamber: StateLegislator.Chamber, state: String) -> String {
        switch chamber {
        case .upper: "State Senate"
        case .lower: assembly.contains(state.uppercased()) ? "Assembly" : "State House"
        }
    }

    /// `Assembly member` in New York, `state representative` elsewhere.
    public static func lowerMember(state: String) -> String {
        assembly.contains(state.uppercased()) ? "Assembly member" : "state representative"
    }

    /// `State Senate · District 59`.
    public static func seat(_ legislator: StateLegislator, state: String) -> String {
        let chamber = name(legislator.chamber, state: state)
        return legislator.district.isEmpty ? chamber : "\(chamber) · District \(legislator.district)"
    }
}
