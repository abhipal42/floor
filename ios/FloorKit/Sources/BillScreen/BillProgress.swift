import Foundation
import Models

/// A bill's path to law, as a list of steps with what has happened to each.
///
/// Derived from the actions Congress.gov marks with no chamber. Those are its own summary labels —
/// `Introduced in House`, `Passed/agreed to in Senate: …`, `Failed of passage/not agreed to in
/// House …`, `Became Public Law No: 118-5.` — and keying on them is far steadier than reading the
/// free-text actions, which are written per clerk and vary.
public struct BillProgress: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Reached.
        case done
        /// Reached and rejected there; the bill goes no further.
        case failed
        /// Not reached yet.
        case pending
    }

    public struct Step: Sendable, Hashable, Identifiable {
        public var label: String
        public var state: State
        /// The day it happened, where a marker gave one.
        public var on: String?

        public var id: String { label }
    }

    public var steps: [Step]

    /// True once the bill is law, or once a chamber has rejected it.
    public var isSettled: Bool {
        steps.contains { $0.state == .failed } || steps.last?.state == .done
    }

    public init(bill: Bill) {
        let markers = bill.actions.filter { $0.chamber == nil }
        let origin = bill.originChamber ?? .house
        let other: Chamber = origin == .house ? .senate : .house

        /// The day of the first marker whose text matches, newest-first order being how the API
        /// returns actions.
        func day(_ matching: (String) -> Bool) -> String? {
            markers.last { matching($0.text) }?.actedOn
        }
        func passed(_ chamber: Chamber) -> String? {
            if let marked = day({ $0.localizedCaseInsensitiveContains("Passed/agreed to in \(name(chamber))") }) {
                return marked
            }
            // Bill actions lag their votes: roll calls arrive from the Clerk within the hour, while
            // a bill's actions are re-fetched from Congress.gov on a slower cadence. Left at the
            // marker alone, this screen says "Passed House" is pending directly below the passage
            // vote it just listed. The chamber's own roll call settles it.
            return bill.votes.first { $0.chamber == chamber && $0.isFinalPassage }?
                .occurredAt.flatMap { String($0.prefix(10)) }
        }
        func rejected(_ chamber: Chamber) -> Bool {
            markers.contains {
                $0.text.localizedCaseInsensitiveContains("Failed of passage/not agreed to in \(name(chamber))")
            }
        }

        var steps: [Step] = []

        // The action list is capped, so a long-running bill can lose its introduction off the end.
        // `introducedOn` is the authority; the marker only supplies a date when that is missing.
        let introducedOn = bill.introducedOn ?? day { $0.localizedCaseInsensitiveContains("Introduced in") }
        steps.append(Step(label: "Introduced", state: introducedOn == nil ? .pending : .done, on: introducedOn))

        let verb = bill.isResolution ? "Agreed to in" : "Passed"
        for chamber in bill.chambersThatMustAct(origin: origin, other: other) {
            let on = passed(chamber)
            steps.append(Step(
                label: "\(verb) \(name(chamber))",
                state: on != nil ? .done : (rejected(chamber) ? .failed : .pending),
                on: on
            ))
        }

        if bill.canBecomeLaw {
            let on = day { $0.localizedCaseInsensitiveContains("Became Public Law") }
            steps.append(Step(label: "Became law", state: on != nil ? .done : .pending, on: on))
        }

        self.steps = steps
    }
}

/// Free rather than a method: `init` needs it before `steps` is set, and an instance method is not
/// available until every stored property is.
private func name(_ chamber: Chamber) -> String {
    chamber == .house ? "House" : "Senate"
}

public extension Vote {
    /// Whether this roll call carried the measure in its chamber, as opposed to a procedural vote
    /// on the way there. Congress.gov's own result wording is the signal; the question narrows it
    /// so a failed recommittal or a rule vote is not mistaken for passage.
    var isFinalPassage: Bool {
        // `outcome`, not the wording again: "Not Agreed to" contains "agreed".
        guard outcome == .carried else { return false }
        let q = question.lowercased()
        return q.contains("passage") || q.contains("concur") || q.contains("agreeing to the resolution")
    }
}

public extension Bill {
    /// A resolution is agreed to rather than passed, and most never reach the President.
    var isResolution: Bool {
        ["hres", "sres", "hconres", "sconres"].contains(type)
    }

    /// Only bills and joint resolutions can become law. A simple resolution binds one chamber; a
    /// concurrent resolution binds both but is never presented to the President.
    var canBecomeLaw: Bool {
        ["hr", "s", "hjres", "sjres"].contains(type)
    }

    /// Which chambers have to act. A simple resolution never leaves the one it started in.
    func chambersThatMustAct(origin: Chamber, other: Chamber) -> [Chamber] {
        ["hres", "sres"].contains(type) ? [origin] : [origin, other]
    }
}
