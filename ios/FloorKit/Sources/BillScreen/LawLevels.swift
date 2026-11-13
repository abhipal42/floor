import Foundation
import Models

/// "Six levels to law", as the locked Bill mock draws them: Introduced, Committee, House, Senate,
/// Same text, Signed.
///
/// Built on ``BillProgress`` for the two chambers and the law marker, so the six levels and the old
/// path-to-law stepper can never disagree about whether a chamber passed it. What this adds:
///
/// - **Committee** has no summary marker of its own. It counts as cleared when an action says the
///   bill was reported or discharged, or when the bill reached the floor at all (a floor vote, or a
///   chamber passing it) — a bill brought up under suspension skips markup but has plainly got past
///   that level.
/// - **Stuck** is a chamber that voted on the bill and lost without passing it — a failed cloture
///   vote, say — as opposed to *failed*, which is Congress.gov's own "Failed of passage" marker.
///   Both are drawn in the nay colour.
/// - **Same text** is presentment ("Presented to President", "Cleared for White House", or law
///   itself) for a bill. A concurrent resolution is never presented, so for one it is both chambers
///   agreeing with no amendment left unresolved.
/// - **BOSS** marks a level with a supermajority in its way: the House or Senate when one of its
///   votes on this bill needed two-thirds or sixty, and Signed whenever the measure can become law,
///   because a veto can only be overcome by two-thirds of both.
/// - A level the measure never has to reach (the other chamber for a simple resolution, Signed for
///   any resolution that is not joint) is ``State/notApplicable``.
public struct LawLevels: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case done, pending, stuck, failed, notApplicable
    }

    public struct Level: Sendable, Hashable, Identifiable {
        public var number: Int
        public var name: String
        public var state: State
        public var boss: Bool
        public var id: Int { number }
    }

    public static let names = ["Introduced", "Committee", "House", "Senate", "Same text", "Signed"]

    public var levels: [Level]
    /// The citation, for the sentences below.
    public var citation: String
    public var isResolution: Bool
    /// The chamber it started in, which is the one it goes to first.
    public var origin: Chamber
    /// The losing vote that left a chamber stuck, if one did.
    public var stoppedBy: Vote?

    public init(bill: Bill) {
        let progress = BillProgress(bill: bill)
        let origin = bill.originChamber ?? .house
        let texts = bill.actions.map { $0.text.lowercased() }
        func any(_ needles: [String]) -> Bool { texts.contains { t in needles.contains { t.contains($0) } } }

        func chamberStep(_ chamber: Chamber) -> BillProgress.Step? {
            progress.steps.first { $0.label.hasSuffix(chamber == .house ? "House" : "Senate") }
        }
        var stoppedBy: Vote?
        func chamberState(_ chamber: Chamber) -> State {
            guard let step = chamberStep(chamber) else { return .notApplicable }
            switch step.state {
            case .done: return .done
            case .failed: return .failed
            case .pending:
                // Votes arrive newest first; the latest losing vote in this chamber is what stopped it.
                if let lost = bill.votes.first(where: {
                    $0.chamber == chamber && $0.outcome == .failed && $0.failureStopsTheBill
                }) {
                    stoppedBy = stoppedBy ?? lost
                    return .stuck
                }
                return .pending
            }
        }
        func supermajority(_ chamber: Chamber) -> Bool {
            bill.votes.contains { $0.chamber == chamber && $0.threshold != .majority }
        }

        let introduced: State = progress.steps.first?.state == .done ? .done : .pending
        let house = chamberState(.house)
        let senate = chamberState(.senate)
        let reachedFloor = !bill.votes.isEmpty || house == .done || senate == .done
        let committee: State = reachedFloor || any(["reported", "discharged"]) ? .done : .pending

        let sameText: State
        if bill.chambersThatMustAct(origin: origin, other: origin == .house ? .senate : .house).count < 2 {
            sameText = .notApplicable
        } else if bill.canBecomeLaw {
            sameText = any(["presented to president", "cleared for white house", "became public law"]) ? .done : .pending
        } else {
            let amended = texts.contains { $0.contains("passed/agreed to in") && $0.contains("with an amendment") }
            let resolved = texts.contains { $0.contains("resolving differences") && $0.contains("agree") }
            sameText = house == .done && senate == .done && (!amended || resolved) ? .done : .pending
        }

        let signed: State
        if !bill.canBecomeLaw {
            signed = .notApplicable
        } else if progress.steps.last?.label == "Became law", progress.steps.last?.state == .done {
            signed = .done
        } else if any(["vetoed by president", "pocket veto"]) {
            signed = .failed
        } else {
            signed = .pending
        }

        let states = [introduced, committee, house, senate, sameText, signed]
        let boss = [false, false, supermajority(.house), supermajority(.senate), false, bill.canBecomeLaw]
        levels = zip(Self.names.indices, states).map { index, state in
            Level(number: index + 1, name: Self.names[index], state: state, boss: boss[index] && state != .notApplicable)
        }
        citation = bill.citation
        isResolution = bill.isResolution
        self.origin = origin
        self.stoppedBy = stoppedBy
    }

    /// How many levels it has climbed, in the order it meets them: 3 for a bill that has passed the
    /// House and waits on the Senate, and 3 for one that started in the Senate and passed it.
    public var reached: Int { climbed.count }

    /// The run of done levels from the start, in meeting order, skipping ones that do not apply.
    private var climbed: [Level] {
        var run: [Level] = []
        for level in ordered where level.state != .notApplicable {
            guard level.state == .done else { break }
            run.append(level)
        }
        return run
    }

    /// Every level this measure has to reach is done: a law, or a resolution agreed to.
    public var isComplete: Bool {
        levels.allSatisfy { $0.state == .done || $0.state == .notApplicable }
    }

    /// The levels in the order this measure meets them: the Senate before the House for a bill
    /// that started in the Senate.
    var ordered: [Level] {
        guard origin == .senate else { return levels }
        var copy = levels
        copy.swapAt(2, 3)
        return copy
    }

    public var isLaw: Bool { levels[5].state == .done }

    /// The header's verdict: `LAW`, `LEVEL 3 OF 6`, `STOPPED AT THE 60`, `FAILED IN THE HOUSE`.
    public var status: String {
        if isLaw { return "LAW" }
        if isComplete { return "ADOPTED" }
        if let failed = levels.first(where: { $0.state == .failed }) {
            return failed.number == 6 ? "VETOED" : "FAILED IN THE \(failed.name.uppercased())"
        }
        if let stuck = levels.first(where: { $0.state == .stuck }) {
            switch stoppedBy?.threshold {
            case .threeFifthsSworn: return "STOPPED AT THE 60"
            case .twoThirds: return "SHORT OF TWO-THIRDS"
            default: return "STUCK IN THE \(stuck.name.uppercased())"
            }
        }
        return "LEVEL \(reached) OF 6"
    }

    /// `H.R. 1013 passed the House. Next: the Senate.`
    public var sentence: String {
        if isLaw { return "\(citation) is law." }
        if isComplete { return "\(citation) was adopted." }
        if let failed = levels.first(where: { $0.state == .failed }) {
            return failed.number == 6 ? "\(citation) was vetoed." : "\(citation) failed in the \(failed.name)."
        }
        if let stuck = levels.first(where: { $0.state == .stuck }) {
            return "\(citation) is stuck in the \(stuck.name)."
        }
        let done = climbed.last
        let next = ordered.first { $0.state != .done && $0.state != .notApplicable }
        let did: String = switch done?.name {
        case "Introduced": "was introduced"
        case "Committee": "cleared committee"
        case "House": isResolution ? "was agreed to in the House" : "passed the House"
        case "Senate": isResolution ? "was agreed to in the Senate" : "passed the Senate"
        case "Same text": "cleared both chambers in the same text"
        default: "has not been introduced"
        }
        guard let next else { return "\(citation) \(did)." }
        let what: String = switch next.name {
        case "Introduced": "introduction"
        case "Committee": "committee"
        case "House": "the House"
        case "Senate": "the Senate"
        case "Same text": "the same text in both chambers"
        default: "the President's signature"
        }
        return "\(citation) \(did). Next: \(what)."
    }
}

public extension Vote {
    /// Whether losing this vote stops the measure where it is. A failed passage, cloture, motion
    /// to proceed or suspension does; a failed amendment, motion to recommit or to table does not —
    /// those failing is usually how a bill gets through.
    var failureStopsTheBill: Bool {
        ["Passage", "Cloture", "Motion to proceed", "Suspension", "Resolution", "Concur", "Veto override"]
            .contains(questionKind)
    }
}
