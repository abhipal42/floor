import APIClient
import Foundation
import Models

/// One member: who they are, how often they side with their party, and their recent votes.
@MainActor
@Observable
public final class RepScreenModel {
    public struct Record: Equatable, Sendable {
        public var detail: MemberDetail
        public var votes: [MemberVote]
    }

    public enum Phase: Equatable {
        case loading
        case loaded(Record)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// Set while any of the record on screen is saved rather than fresh; see `revalidate`.
    public private(set) var saved: SavedCopy?
    /// Bumped by each load, so a load that has been overtaken drops its results.
    private var generation = 0

    private let bioguideId: String
    private let api: FloorAPI
    private let limit: Int

    public init(bioguideId: String, api: FloorAPI, limit: Int = 40) {
        self.bioguideId = bioguideId
        self.api = api
        self.limit = limit
    }

    /// True until a load has finished with everything fresh — including one that was cancelled
    /// part-way — so a screen that reappears runs the refresh again.
    public var needsRefresh: Bool {
        if case .loaded = phase { return saved != nil }
        return true
    }

    public func load() async {
        generation += 1
        let mine = generation
        // A record already on screen stays there while it refreshes, rather than flashing a spinner.
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        do {
            // Saved record first, then the network; see `revalidate`.
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [bioguideId, limit] pass in
                // Two independent requests, so they go together rather than one after the other.
                async let detail = pass.api.member(id: bioguideId)
                async let votes = pass.api.memberVotes(id: bioguideId, limit: limit)
                let record = Record(detail: try await detail, votes: try await votes.votes)
                guard mine == generation else { throw CancellationError() }
                phase = .loaded(record)
            }
        } catch is CancellationError {
            // Overtaken or cancelled: nothing to say, and `needsRefresh` still holds.
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load this member.")
        }
    }
}

public extension PartyLoyalty {
    /// Party unity as a whole percentage, or nil when there is nothing to report.
    ///
    /// nil for an independent: "their party's majority" is themselves, so the API leaves those
    /// votes uncounted rather than reporting a meaningless 100%. The screen must show nothing.
    var unityPercent: Int? {
        withPartyShare.map { Int(($0 * 100).rounded()) }
    }
}

public extension Member {
    /// "U.S. Representative · D-TX-37", as the canvas writes the eyebrow.
    var roleLine: String {
        let office = chamber == .house ? "U.S. Representative" : "U.S. Senator"
        return "\(office) · \(partyAndSeat)"
    }
}

public extension MemberVote {
    /// How to label this row in a record: the measure where there is one, else the question.
    var rowTitle: String {
        measure?.headline ?? vote.question
    }

    /// Whether the member sided with the outcome. nil when the vote settled nothing to side with,
    /// as a Speaker ballot that elected nobody does.
    var agreedWithOutcome: Bool? {
        guard vote.kind == .question, let leader = vote.leader else { return nil }
        switch position {
        case .yea: return leader == .yea
        case .nay: return leader == .nay
        default: return nil
        }
    }
}

// MARK: - Your three (the locked AppRep mock)

/// Your whole delegation on one tab: a switcher, and every member's record loaded together so a
/// fact can compare your two senators.
@MainActor
@Observable
public final class YourThreeModel {
    public let members: [Member]
    public var selectedId: String
    /// One per member, built once so switching back does not reload.
    public let records: [String: RepScreenModel]

    public init(members: [Member], api: FloorAPI, selectedId: String? = nil) {
        self.members = members
        self.selectedId = selectedId ?? members.first?.bioguideId ?? ""
        var records: [String: RepScreenModel] = [:]
        for member in members { records[member.bioguideId] = RepScreenModel(bioguideId: member.bioguideId, api: api) }
        self.records = records
    }

    public var selected: RepScreenModel? { records[selectedId] }

    public func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            for model in records.values {
                // Not "already loaded": a record on saved data, or whose refresh was cancelled when
                // the tab went away, refreshes again when it comes back.
                if !model.needsRefresh { continue }
                group.addTask { await model.load() }
            }
        }
    }

    /// The "did you know" line for one member, given what has loaded for the others.
    public func fact(for member: Member) -> String? {
        guard case let .loaded(record)? = records[member.bioguideId]?.phase else { return nil }
        let senators = members.filter { $0.chamber == .senate }
        // The first senator gets the agreement fact, the second their attendance, so the two tabs
        // say different things — as the mock's Schumer and Gillibrand tabs do.
        if member.chamber == .senate, senators.count == 2, senators.first == member,
           let other = senators.last, case let .loaded(theirs)? = records[other.bioguideId]?.phase {
            return RecordFacts.agreement(record.votes, theirs.votes)
        }
        return RecordFacts.didYouKnow(member: member, votes: record.votes)
    }
}

/// The player card's tier, from crossovers: votes against their own party's majority.
public enum Tier: String, Sendable {
    case starter = "STARTER"
    case swing = "SWING"
    case maverick = "MAVERICK"

    /// 400 or more is a MAVERICK, 300 or more a SWING, anything less a STARTER.
    public init(crossovers: Int) {
        self = crossovers >= 400 ? .maverick : crossovers >= 300 ? .swing : .starter
    }
}

/// The last-40 numbers behind the rings and the grid.
public struct RecordStats: Sendable, Hashable {
    /// Oldest first, as the grid reads left to right: at most 40.
    public var calls: [MemberVote]
    /// Calls where they cast anything — yea, nay, present or a name.
    public var showedUp: Int
    public var present: Int
    public var missed: Int
    /// Yea-or-nay votes on a question that settled something.
    public var decided: Int
    /// Of those, how many went their way.
    public var sidedWithOutcome: Int

    public init(votes: [MemberVote], window: Int = 40) {
        calls = Array(votes.prefix(window).reversed())
        missed = calls.filter { $0.position == .notVoting }.count
        present = calls.filter { $0.position == .present }.count
        showedUp = calls.count - missed
        let sided = calls.compactMap(\.sidedWithOutcome)
        decided = sided.count
        sidedWithOutcome = sided.filter { $0 }.count
    }

    public var showedUpShare: Double? { calls.isEmpty ? nil : Double(showedUp) / Double(calls.count) }
    public var winningShare: Double? { decided == 0 ? nil : Double(sidedWithOutcome) / Double(decided) }
}

public extension MemberVote {
    /// Whether the member was on the winning side: yea on a question that carried, nay on one that
    /// failed. Unlike ``agreedWithOutcome`` this reads the outcome rather than which side had more
    /// votes, which matters where they differ — 212–206 under suspension *lost*. nil for present,
    /// a missed vote, or a Speaker ballot.
    var sidedWithOutcome: Bool? {
        guard let outcome = vote.outcome else { return nil }
        switch position {
        case .yea: return outcome == .carried
        case .nay: return outcome == .failed
        default: return nil
        }
    }

    /// How the grid and the readout cite it: the measure, else the kind of question.
    var cite: String { measure?.citation ?? vote.questionKind }

    /// "Nov 11, H.R. 1013, Nay", for VoiceOver on a grid square.
    var spokenSummary: String {
        let day = vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())
        let position = self.position == .candidate ? (choice ?? "a candidate") : self.position.shortLabel.capitalized
        return [day, cite, position].compactMap(\.self).joined(separator: ", ")
    }
}

/// The computed "did you know" lines. Every one is arithmetic over the record on screen; none is
/// written by a model and none claims anything the numbers do not show.
public enum RecordFacts {
    /// A representative's suspension record if they have one in view; otherwise their attendance.
    public static func didYouKnow(member: Member, votes: [MemberVote], window: Int = 40) -> String? {
        let calls = Array(votes.prefix(window))
        guard !calls.isEmpty else { return nil }
        let name = member.lastName
        let suspensions = calls.filter { $0.vote.questionKind == "Suspension" }
        if member.chamber == .house, !suspensions.isEmpty {
            let yeas = suspensions.filter { $0.position == .yea }
            let others = suspensions.filter { $0.position != .yea }
            var text = "\(suspensions.count) of \(name)'s last \(calls.count) calls came up under suspension, "
                + "the two-thirds fast lane."
            if others.isEmpty {
                text += " \(name) voted yea on every one."
            } else if others.count <= 2 {
                let list = others.map { "\($0.cite) (\($0.position.shortLabel.lowercased()))" }
                text += " \(name) voted yea on \(yeas.count) — the exception\(others.count == 1 ? " was" : "s were") "
                    + list.joined(separator: " and ") + "."
            } else {
                let nays = suspensions.filter { $0.position == .nay }.count
                let missed = suspensions.filter { $0.position == .notVoting }.count
                text += " \(name) voted yea on \(yeas.count)"
                if nays > 0 { text += ", nay on \(nays)" }
                if missed > 0 { text += ", and missed \(missed)" }
                text += "."
            }
            return text
        }
        return attendance(name: name, calls: calls)
    }

    static func attendance(name: String, calls: [MemberVote]) -> String {
        let missed = calls.filter { $0.position == .notVoting }
        switch missed.count {
        case 0:
            return "\(name) cast a vote on every one of their last \(calls.count) calls."
        case 1...2:
            let list = missed.map { row -> String in
                let day = row.vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())
                return [row.cite, day].compactMap(\.self).joined(separator: ", ")
            }
            return "\(name)'s missed vote\(missed.count == 1 ? "" : "s") in the last \(calls.count): "
                + list.joined(separator: "; ") + "."
        default:
            return "\(name) missed \(missed.count) of their last \(calls.count) calls."
        }
    }

    /// The tally behind the two-senator fact: calls both cast yea or nay, and the ones they split on.
    public static func agreementCounts(_ a: [MemberVote], _ b: [MemberVote]) -> (same: Int, both: Int, splits: [MemberVote]) {
        let theirs = Dictionary(b.map { ($0.vote.id, $0) }, uniquingKeysWith: { first, _ in first })
        var same = 0
        var both = 0
        var splits: [MemberVote] = []
        for row in a where row.position == .yea || row.position == .nay {
            guard let other = theirs[row.vote.id], other.position == .yea || other.position == .nay else { continue }
            both += 1
            if other.position == row.position { same += 1 } else { splits.append(row) }
        }
        return (same, both, splits)
    }

    /// "Your two senators voted the same way on 35 of the 39 calls they both cast — they split on
    /// S. 4668 twice and H.R. 3633."
    public static func agreement(_ a: [MemberVote], _ b: [MemberVote], window: Int = 40) -> String? {
        let (same, both, splits) = agreementCounts(Array(a.prefix(window)), Array(b.prefix(window)))
        guard both > 0 else { return nil }
        var text = "Your two senators voted the same way on \(same) of the \(both) calls they both cast"
        if splits.isEmpty { return text + "." }
        var counts: [(String, Int)] = []
        for row in splits {
            // A split with no measure is named by its kind: "a motion to table".
            let cite = row.measure?.citation ?? "a \(row.vote.questionKind.lowercased())"
            if let i = counts.firstIndex(where: { $0.0 == cite }) { counts[i].1 += 1 } else { counts.append((cite, 1)) }
        }
        guard counts.count <= 3 else { return text + "." }
        let words = [2: "twice", 3: "three times", 4: "four times"]
        let list = counts.map { $0.1 > 1 ? "\($0.0) \(words[$0.1] ?? "\($0.1) times")" : $0.0 }
        let joined = list.count == 1 ? list[0] : list.dropLast().joined(separator: ", ") + " and " + list.last!
        text += " — they split on \(joined)."
        return text
    }
}

public extension Member {
    /// "House · New York 8th · D", "Senate · New York · D".
    var seatLine: String {
        let state = StateName.full(self.state)
        if chamber == .house, let district {
            return "House · \(state) \(district == 0 ? "at-large" : StateName.ordinal(district)) · \(party)"
        }
        return "Senate · \(state) · \(party)"
    }

    /// "NY-8" for a representative, "NY" for a senator.
    var badge: String {
        if chamber == .house, let district { return "\(state)-\(district == 0 ? "AL" : String(district))" }
        return state
    }
}
