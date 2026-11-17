import Foundation

/// A vote as one step in a measure's story on the Finals feed: what kind of step it was, in plain
/// words, and whether it decided the measure or only moved it along.
///
/// Read from ``Vote/explainer``'s `kind`, the API's registry (`apps/api/src/votekinds.ts`), so the
/// step and the vote screen's explainer line can never call one vote two things.
public extension Vote {
    /// The explainer kinds that move a measure along without deciding it: debate, scheduling,
    /// sending it elsewhere, quorum and the chair. Every other kind the API emits (passage,
    /// suspension, confirmation, adoption, an amendment, concurring, an override, a treaty, a
    /// Speaker election) is a decision. A measure with only these votes is an "Also this week" row
    /// rather than a story card. The same list as Android's `VoteStep.PROCEDURAL_KINDS`.
    static let proceduralKinds: Set<String> = [
        "cloture", "cloture_motion_to_proceed", "motion_to_proceed",
        "previous_question", "rule", "consideration",
        "recommit", "commit", "refer", "table", "table_reconsider", "reconsider", "discharge",
        "go_to_conference", "instruct_conferees",
        "adjourn", "quorum_call", "attendance", "point_of_order", "appeal",
    ]

    /// True when the vote only moved its measure along (``proceduralKinds``). A question the API
    /// has no explainer for counts as a decision, so a measure is never demoted to a mini row on a
    /// guess.
    var isProcedural: Bool { explainer.map { Self.proceduralKinds.contains($0.kind) } ?? false }

    /// What the step was, in plain words: `Rule for debate`, `Passage`, `Cloture`, `Confirmation`.
    /// A kind with no name here falls back to ``questionKind``.
    var stepName: String {
        guard let kind = explainer?.kind, let name = Self.stepNames[kind] else { return questionKind }
        return name
    }

    private static let stepNames: [String: String] = [
        "cloture": "Cloture",
        "cloture_motion_to_proceed": "Cloture to take it up",
        "motion_to_proceed": "Motion to take it up",
        "nomination": "Confirmation",
        "treaty": "Ratification",
        "suspension": "Passage",
        "previous_question": "Previous question",
        "rule": "Rule for debate",
        "consideration": "Taking it up",
        "passage": "Passage",
        "joint_resolution": "Passage",
        "resolution": "Adoption",
        "concurrent_resolution": "Adoption",
        "veto_override": "Veto override",
        "conference_report": "Conference report",
        "amendment": "Amendment",
        "concur": "Agreeing to the Senate's changes",
        "concur_with_amendment": "Answering the Senate's changes",
        "go_to_conference": "Going to conference",
        "instruct_conferees": "Instructing negotiators",
        "recommit": "Motion to recommit",
        "commit": "Motion to commit",
        "refer": "Motion to refer",
        "table": "Motion to table",
        "table_reconsider": "Closing the vote",
        "reconsider": "Reconsidering",
        "discharge": "Discharge petition",
        "adjourn": "Adjournment",
        "quorum_call": "Quorum call",
        "attendance": "Attendance",
        "point_of_order": "Point of order",
        "appeal": "Appeal of the chair",
        "speaker_election": "Speaker election",
    ]

    /// The verdict chip on a story card: PASSED HOUSE, PASSED SENATE, CONFIRMED, REJECTED, AGREED
    /// TO, FAILED, OVERRIDDEN; the chamber's own result uppercased when none of them fits; nil with
    /// no result at all.
    var verdict: String? {
        switch outcomeWord {
        case "PASSED": "PASSED \(chamber == .house ? "HOUSE" : "SENATE")"
        case "AGREED": "AGREED TO"
        case "REJECTED" where explainer?.kind != "nomination": "FAILED"
        case let word?: word
        case nil: result?.uppercased()
        }
    }
}
