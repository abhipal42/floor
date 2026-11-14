import Foundation
import Models

/// The bill's facts, and nothing else, as Speak up and the offline share line say them. Everything
/// here comes from the bill record and the week's schedule; there is no opinion in it and no AI
/// (round 11, section C: "Floor writes the facts, you write the opinion").
public struct BillFacts: Sendable, Hashable {
    public var citation: String
    /// The bill's own name when it has one worth saying (`American Franchise Act`), else nil.
    public var name: String?
    public var stage: BillStage?
    public var originChamber: Chamber?
    /// Where it is on a floor list this week, if it is.
    public var listing: FloorListing?
    public var hasVotes: Bool

    public init(citation: String, name: String?, stage: BillStage?, originChamber: Chamber?, listing: FloorListing?, hasVotes: Bool) {
        self.citation = citation
        self.name = name
        self.stage = stage
        self.originChamber = originChamber
        self.listing = listing
        self.hasVotes = hasVotes
    }

    public init(bill: Bill, listing: FloorListing?) {
        self.init(
            citation: bill.citation, name: Self.name(bill), stage: bill.stage, originChamber: bill.originChamber,
            listing: listing, hasVotes: !bill.votes.isEmpty
        )
    }

    /// A short title; else the official title when it names an act (`American Franchise Act`,
    /// `… Act of 2026`); else nothing, so a long descriptive title ("To amend …") is never read
    /// out as a name. The API's share line uses the short title the same way.
    static func name(_ bill: Bill) -> String? {
        if let short = bill.shortTitle { return Self.trimmingThe(short) }
        let title = bill.title.trimmingCharacters(in: .whitespaces)
        let namesAnAct = title.range(of: #"\bAct( of \d{4})?$"#, options: .regularExpression) != nil
        return namesAnAct && title.count <= 90 ? Self.trimmingThe(title) : nil
    }

    private static func trimmingThe(_ name: String) -> String {
        name.range(of: "the ", options: [.anchored, .caseInsensitive]).map { String(name[$0.upperBound...]) } ?? name
    }

    /// `H.R. 5267, the American Franchise Act,` or just `H.R. 7254`.
    public var named: String {
        name.map { "\(citation), the \($0)," } ?? citation
    }

    /// `is scheduled for a House vote the week of November 16`, else where it stands, as the API's
    /// share line says it (`STAGE_CLAUSE` in apps/api/src/share.ts).
    public var clause: String {
        if let listing {
            switch listing.chamber {
            case .house: return "is scheduled for a House vote the week of \(listing.weekOf)"
            case .senate: return "is on the Senate's program for the week of \(listing.weekOf)"
            }
        }
        switch stage {
        case .introduced: return "was introduced in the \(originChamber?.name ?? "Congress")"
        case .passedHouse: return "passed the House"
        case .passedSenate: return "passed the Senate"
        case .passedBoth: return "passed the House and the Senate"
        case .toPresident: return "was sent to the President"
        case .law: return "became law"
        case .vetoed: return "was vetoed"
        case .failed: return "failed"
        case .adopted: return "was agreed to"
        case nil: return "is before Congress"
        }
    }

    /// The fact as one sentence: `H.R. 5267, the American Franchise Act, is scheduled for a House
    /// vote the week of November 16.`
    public var sentence: String { "\(named) \(clause)." }
}

/// A bill on this week's floor list, as the bill screen's banner and Speak up name it.
public struct FloorListing: Sendable, Hashable {
    public var chamber: Chamber
    public var category: ScheduleCategory
    /// `November 16`.
    public var weekOf: String
    /// `Nov 16`.
    public var weekOfShort: String

    public init(chamber: Chamber, category: ScheduleCategory, weekOf: String, weekOfShort: String) {
        self.chamber = chamber
        self.category = category
        self.weekOf = weekOf
        self.weekOfShort = weekOfShort
    }

    public init?(schedule: Schedule, billId: String) {
        guard let found = schedule.listing(billId: billId) else { return nil }
        let short = schedule.monday?.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day()) ?? schedule.week
        self.init(chamber: found.chamber, category: found.item.category, weekOf: schedule.weekOf, weekOfShort: short)
    }

    /// The banner's line: `Scheduled for House consideration under a rule, week of Nov 16.`
    public var bannerLine: String {
        switch (chamber, category) {
        case (.house, .rule): "Scheduled for House consideration under a rule, week of \(weekOfShort)."
        case (.house, .suspension): "Scheduled for the House's fast track, needing two-thirds, week of \(weekOfShort)."
        case (.house, .other): "On the House's floor list, week of \(weekOfShort)."
        case (.senate, _): "Named in the Senate's program, week of \(weekOfShort)."
        }
    }
}

/// "Your view · you choose": the four stances. None is chosen until the person taps one.
public enum Stance: String, CaseIterable, Sendable, Identifiable {
    case support, oppose, howWillYouVote, question

    public var id: String { rawValue }

    /// The chip.
    public var chip: String {
        switch self {
        case .support: "I support it"
        case .oppose: "I oppose it"
        case .howWillYouVote: "How will you vote?"
        case .question: "I have a question"
        }
    }
}

/// The fixed text Speak up fills in: the greeting, where you live (your district, which the office
/// checks), the bill's facts and the stance you picked — nothing else — plus two placeholders for
/// what only you can add. Never stored, never sent by Floor.
public enum SpeakUpTemplate {
    public static let ownWords = "[Add your own words (optional)]"
    public static let nameAndAddress = "[Your name and address go in the office's form]"

    /// `Dear Representative Doggett,`, `Dear Senator Cornyn,`, `Dear Delegate Norton,`.
    public static func greeting(_ member: Member) -> String {
        "Dear \(member.title) \(member.lastName),"
    }

    /// `I live in Texas's 37th District.`; for a senator, `I live in Texas.`
    public static func residence(_ member: Member, district: District) -> String {
        if member.chamber == .senate { return "I live in \(StateName.inSentence(district.state))." }
        return "I live in \(StateName.districtName(state: district.state, district: district.district))."
    }

    /// The stance as one line, in the member's title where it asks them something.
    public static func stanceLine(_ stance: Stance, member: Member) -> String {
        switch stance {
        case .support: "I support it."
        case .oppose: "I oppose it."
        case .howWillYouVote: "How do you plan to vote, and why?"
        case .question: "I have a question about it:"
        }
    }

    public static func message(to member: Member, district: District, facts: BillFacts, stance: Stance) -> String {
        [
            greeting(member),
            "\(residence(member, district: district)) \(facts.sentence) \(stanceLine(stance, member: member))",
            ownWords,
            nameAndAddress,
        ].joined(separator: "\n\n")
    }

    /// `text` with its stance line swapped for `stance`'s, so a choice changed after editing keeps
    /// the edits; nil when the old line is no longer in the text (the person rewrote it).
    public static func restanced(_ text: String, from old: Stance, to new: Stance, member: Member) -> String? {
        let oldLine = stanceLine(old, member: member)
        guard let range = text.range(of: oldLine) else { return nil }
        return text.replacingCharacters(in: range, with: stanceLine(new, member: member))
    }

    /// The call script, line by line: the same facts, read aloud, and the stance the person
    /// picked (or, with none picked, the choices to pick from).
    public static func callScript(to member: Member, district: District, facts: BillFacts, stance: Stance?) -> [String] {
        let place = member.chamber == .senate
            ? StateName.inSentence(district.state)
            : StateName.districtName(state: district.state, district: district.district)
        let who = member.chamber == .senate ? "the Senator" : "the \(member.title == "Representative" ? "Representative" : member.title)"
        let stanceLine: String = switch stance {
        case .support: "I support it."
        case .oppose: "I oppose it."
        case .howWillYouVote: "I'd like to know how \(who) plans to vote."
        case .question: "I have a question about it: [your question]"
        case nil: "\"I support it.\" / \"I oppose it.\" / \"I'd like to know where \(who) stands.\" (you pick)"
        }
        let quoted = stance == nil ? stanceLine : "\"\(stanceLine)\""
        return [
            "\"Hi, I'm a constituent from [your city], \(place).\"",
            "\"I'm calling about \(facts.citation)\(facts.name.map { ", the \($0)" } ?? ""). It \(facts.clause).\"",
            quoted,
            "\"Thank you.\"",
        ]
    }

    /// Where "Write" goes: the office's own form; else, for a House member, the House's "Write Your
    /// Representative" form (which checks your ZIP); else the senator's website.
    public static func formURL(for member: Member, contact: MemberContact?) -> URL? {
        if let form = contact?.contactForm.flatMap(URL.init(string:)) { return form }
        if member.chamber == .house { return houseFindYourRep }
        return contact?.website.flatMap(URL.init(string:))
    }

    public static let houseFindYourRep = URL(string: "https://www.house.gov/representatives/find-your-representative")!

    /// `tel:2022254865`.
    public static func telURL(_ phone: String?) -> URL? {
        guard let phone else { return nil }
        let digits = phone.filter(\.isNumber)
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

/// What Share sends when `GET /v1/bills/{id}/share` can't be reached: the same link shape and a
/// line built from the bill the way the API builds its own (`shareText`, apps/api/src/share.ts).
public enum ShareFallback {
    public static func url(_ bill: Bill) -> URL {
        URL(string: "https://floor.app/bill/\(bill.congress)/\(bill.type)/\(bill.number)")!
    }

    public static func text(_ facts: BillFacts) -> String {
        let tail = facts.listing != nil ? "What it does and how our members vote:"
            : facts.hasVotes ? "What it does and how our members voted:" : "What it does and where it stands:"
        return "\(facts.sentence) \(tail)"
    }
}
