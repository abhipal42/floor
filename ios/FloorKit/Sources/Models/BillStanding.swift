import Foundation

/// Where a bill stands, in the words of the Round 10 design's chips: `LAW`, `PASSED HOUSE`,
/// `SENATE CALENDAR`, `IN COMMITTEE`, `VOTE FAILED`.
///
/// Read from the stored stage (`apps/worker/src/stage.ts`) and the bill's latest action. The stage
/// says how far the bill has got; the latest action says where it sits now, which is what a chip
/// is for — a House-passed bill referred to a Senate committee reads `IN COMMITTEE`, its five-step
/// road still showing that the House passed it. A failed motion to proceed, a failed cloture vote
/// or a failed suspension leaves the stage where it was (HANDOFF lesson 50), so "VOTE FAILED" comes
/// from the latest action's own wording, as the server-side notes say it must.
public struct StageChip: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        /// Became law, or a resolution adopted: the yea colour.
        case law
        /// A failed vote, a veto, a defeat: the nay colour.
        case failed
        /// Anywhere on the way: outlined.
        case neutral
    }

    public var text: String
    public var tone: Tone

    public init(_ text: String, _ tone: Tone) {
        self.text = text
        self.tone = tone
    }

    /// The chip for a bill, or nil when neither the stage nor the latest action says anything (a
    /// bill known only from Congress.gov's list, with no action yet).
    public static func of(stage: BillStage?, latestAction: LatestAction?) -> StageChip? {
        let action = latestAction?.text.lowercased() ?? ""
        switch stage {
        case .law: return StageChip("LAW", .law)
        case .adopted: return StageChip("ADOPTED", .law)
        case .vetoed: return StageChip("VETOED", .failed)
        case .failed: return StageChip("FAILED", .failed)
        default: break
        }
        // An unstaged bill whose one listed action is its enactment is law (the API stages it so too).
        if action.contains("became public law") { return StageChip("LAW", .law) }
        if failedVote(action) { return StageChip("VOTE FAILED", .failed) }
        if stage == .toPresident || action.contains("presented to president") {
            return StageChip("TO THE PRESIDENT", .neutral)
        }
        if stage == .passedBoth { return StageChip("PASSED BOTH", .neutral) }
        if action.contains("calendar") {
            return StageChip(action.contains("senate") ? "SENATE CALENDAR" : "HOUSE CALENDAR", .neutral)
        }
        if action.hasPrefix("reported") || action.contains("ordered to be reported") {
            return StageChip("REPORTED", .neutral)
        }
        if inCommittee(action) { return StageChip("IN COMMITTEE", .neutral) }
        switch stage {
        case .passedHouse: return StageChip("PASSED HOUSE", .neutral)
        case .passedSenate: return StageChip("PASSED SENATE", .neutral)
        case .introduced: return StageChip("INTRODUCED", .neutral)
        default: return nil
        }
    }

    /// The latest action is a vote the measure itself lost. An allowlist of the measure-level
    /// failures, as Congress.gov words them:
    ///
    /// - "Motion to proceed to consideration of measure not agreed to in Senate by Yea-Nay Vote. 48 - 51."
    /// - "Cloture on the motion to proceed to the measure not invoked in Senate by Yea-Nay Vote. 51 - 48."
    /// - "Cloture on the measure not invoked in Senate by Yea-Nay Vote. 54 - 45."
    /// - "Failed of passage/not agreed to in House: On motion to suspend the rules and pass the bill …"
    /// - "Failed of passage in Senate by Yea-Nay Vote. 49 - 51."
    ///
    /// Everything else that "failed" or was "not agreed to" is about something other than the bill
    /// and is left out: an amendment (`S.Amdt.`, `H.Amdt.`, `SA 1234`), and the motions to table,
    /// reconsider, commit or recommit, waive (a budget point of order) and instruct conferees — a
    /// failed motion to recommit is the bill surviving, not failing.
    static func failedVote(_ action: String) -> Bool {
        let excluded = ["amdt", "motion to table", "motion to reconsider", "motion to commit",
                        "motion to recommit", "motion to waive", "motion to instruct"]
        guard !excluded.contains(where: action.contains),
              action.range(of: #"\bsa\s?\d+"#, options: .regularExpression) == nil
        else { return false }
        if action.contains("failed of passage") { return true }
        if action.contains("motion to proceed to consideration of measure"), action.contains("not agreed to") { return true }
        if action.contains("not invoked") {
            return action.contains("cloture on the motion to proceed") || action.contains("cloture on the measure")
        }
        return false
    }

    /// The latest action leaves the bill in committee: referred to one, or a hearing or markup held.
    /// Not when it was discharged from one (it has left), nor for the Committee of the Whole, which
    /// is the House floor sitting under its own rules.
    static func inCommittee(_ action: String) -> Bool {
        guard !action.contains("discharged"), !action.contains("committee of the whole") else { return false }
        return action.contains("referred to") || action.contains("hearings held") || action.contains("subcommittee")
            || action.contains("committee consideration") || action.contains("mark-up") || action.contains("markup")
    }
}

/// The five-step road on a bill row: introduced · passed one chamber · passed both · to the
/// President · law.
public enum BillRoad {
    public static let steps = ["introduced", "passed one chamber", "passed both", "to the President", "law"]

    /// The legend printed under a list of bills.
    public static let legend = "Road to law: " + steps.joined(separator: " · ")
}

public extension BillListItem {
    /// Steps reached on the five-step road; nil when it cannot be drawn (not staged yet, failed, or
    /// a resolution adopted — whose road does not end at the President).
    var roadSteps: Int? { stage?.roadSteps }

    var chip: StageChip? { StageChip.of(stage: stage, latestAction: latestAction) }

    /// The row's latest step: `Received in the Senate … · Nov 12`, the action as Congress.gov wrote it.
    var latestStep: String? {
        guard let action = latestAction else { return nil }
        guard let day = Formats.monthDay(action.on) else { return action.text }
        return "\(action.text) · \(day)"
    }

    /// A bill's own record as a list row, for following it from its screen and for the Following
    /// tab's Bills, which refreshes from `GET /v1/bills/{id}`. "Stalled" is the API's rule — not
    /// settled and no action in 90 days — computed here, on the Eastern calendar.
    init(bill: Bill, now: Date = Date()) {
        let stalled: Bool = {
            if bill.stage?.isSettled == true { return false }
            guard let on = bill.latestAction?.onDay else { return true }
            var eastern = Calendar(identifier: .gregorian)
            eastern.timeZone = TimeZone(identifier: "America/New_York")!
            let parts = eastern.dateComponents([.year, .month, .day], from: now)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            guard let today = utc.date(from: parts), let cutoff = utc.date(byAdding: .day, value: -90, to: today) else {
                return false
            }
            return on < cutoff
        }()
        self.init(
            id: bill.id, congress: bill.congress, type: bill.type, number: bill.number, citation: bill.citation,
            label: bill.listLabel, title: bill.title, policyArea: bill.policyArea, stage: bill.stage,
            stalled: stalled, latestAction: bill.latestAction, hasFloorVote: !bill.votes.isEmpty
        )
    }
}

public extension BillListItem {
    /// A bill's record as its list row, keeping from `saved` what a record from an older response
    /// lacks: the stage (a response saved before the API sent stages) and the label.
    init(bill: Bill, keeping saved: BillListItem?, now: Date = Date()) {
        self.init(bill: bill, now: now)
        if stage == nil { stage = saved?.stage }
        if bill.label == nil, let label = saved?.label { self.label = label }
    }
}

public extension Formats {
    /// `Nov 11`: a calendar day, month and day only, in UTC for the reason ``dayText(_:)`` gives.
    static func monthDay(_ string: String) -> String? {
        guard let date = day(string) else { return nil }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day())
    }
}

public extension Spoken {
    /// A bill row: `H.R. 2493, Improving Care in Rural America Reauthorization Act of 2025. Senate
    /// calendar. Latest: Placed on Senate Legislative Calendar, Apr 22. Road to law: 2 of 5, passed
    /// one chamber.`
    static func billRow(_ bill: BillListItem) -> String {
        var parts = ["\(bill.citation), \(bill.label)"]
        if let chip = bill.chip { parts.append(chip.text.capitalized(with: Locale(identifier: "en_US"))) }
        if let action = bill.latestAction {
            parts.append("Latest: " + [action.text.trimmingTrailingStop, Formats.monthDay(action.on)]
                .compactMap(\.self).joined(separator: ", "))
        }
        if let steps = bill.roadSteps {
            parts.append("Road to law: \(steps) of \(BillRoad.steps.count), \(BillRoad.steps[steps - 1])")
        }
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    /// A topic row: `Health. 724 bills, 9 with a floor vote. Latest action Nov 12.`
    static func topicRow(_ topic: Topic) -> String {
        var parts = [topic.name, "\(topic.bills) \(topic.bills == 1 ? "bill" : "bills"), \(topic.billsWithFloorVote) with a floor vote"]
        if let latest = topic.latestActionOn.flatMap(Formats.monthDay) { parts.append("Latest action \(latest)") }
        return parts.map { $0 + "." }.joined(separator: " ")
    }

    /// What a Finals card adds when it is there because of a bill or topic you follow: `You follow
    /// H.R. 1013 and Health.`
    static func followReasons(_ reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        let list = reasons.count == 1 ? reasons[0]
            : reasons.dropLast().joined(separator: ", ") + " and " + reasons[reasons.count - 1]
        return "You follow \(list)."
    }
}

private extension String {
    var trimmingTrailingStop: String { hasSuffix(".") ? String(dropLast()) : self }
}

/// Why a vote is in Finals' Following feed beyond your members' chips: a bill you follow, or a
/// topic (CRS policy area) you follow. A vote can have both; your members show as chips.
public enum FollowMatch: Sendable, Hashable {
    case bill(citation: String)
    case topic(String)

    /// As the card prints it: `H.R. 1013 you follow`, `Health`.
    public var shown: String {
        switch self {
        case let .bill(citation): "\(citation) you follow"
        case let .topic(name): name
        }
    }

    /// As VoiceOver lists it after "You follow": `H.R. 1013`, `Health`.
    public var spoken: String {
        switch self {
        case let .bill(citation): citation
        case let .topic(name): name
        }
    }
}
