import Models
import SwiftUI

/// A final, as the locked Home mock draws it: chamber tag, citation and date, what it needed, the
/// title, the two scores either side of the result, the threshold bar, and your members.
///
/// The score row is a fixed 36pt side label, a flexible score, a fixed 84pt result, the mirror. The
/// scores take `lineLimit(1)` and a `minimumScaleFactor`, so a three-digit House total can never
/// stack into 2/1/6 again (the bug the previous card fixed by the same means).
///
/// A Speaker election has no yea or nay, so it gets its own body: the leading candidates, and
/// whether this ballot elected anyone (HANDOFF lesson 16 — leading a ballot is not winning it).
public struct ScoreboardCard: View {
    let vote: Vote
    let title: String
    let citation: String?
    let positions: [MemberPosition]

    public init(vote: Vote, title: String, citation: String? = nil, positions: [MemberPosition] = []) {
        self.vote = vote
        self.title = title
        self.citation = citation
        self.positions = positions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineSpacing(2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if vote.kind == .election {
                ElectionBody(vote: vote)
            } else if let line = vote.line {
                scoreRow
                ThresholdBar(line: line)
            }
            footer
        }
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SkewChip(vote.chamber.name.uppercased())
            Text([citation, dayText].compactMap(\.self).joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(vote.kind == .election ? "MAJORITY OF NAMES" : (vote.line?.label ?? ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.threshold)
                .lineLimit(1)
        }
    }

    private var dayText: String? {
        vote.occurredAtDate?.formatted(.dateTime.month(.abbreviated).day())
    }

    private var scoreRow: some View {
        HStack(spacing: 0) {
            Text("YEA").font(Typography.label(13)).foregroundStyle(Palette.yea)
                .frame(width: 36, alignment: .leading)
            score(vote.totals.yea, Palette.yea)
            resultChip.frame(width: 84)
            score(vote.totals.nay, Palette.nay)
            Text("NAY").font(Typography.label(13)).foregroundStyle(Palette.nay)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var resultChip: some View {
        switch vote.state {
        case .final:
            SkewChip(vote.outcomeWord ?? "FINAL", background: Palette.outcome(vote.outcome), size: 13)
        case .open:
            SkewChip("VOTING", background: Palette.liveText, size: 13)
        case .scheduled:
            SkewChip("SOON", background: Palette.scheduled, size: 13)
        }
    }

    private func score(_ value: Int, _ color: Color) -> some View {
        Text("\(value)")
            .font(Typography.score(48))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(vote.questionKind)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(positions) { position in
                HStack(spacing: 6) {
                    MemberPortrait(position.member).frame(width: 20, height: 20)
                    Text(label(position))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.position(position.position))
                        .lineLimit(1)
                }
            }
        }
    }

    private func label(_ position: MemberPosition) -> String {
        position.position == .candidate ? (position.choice ?? "BALLOT").uppercased() : position.position.shortLabel
    }

    private var accessibilityText: String {
        var parts = ["\(vote.chamber.name)", citation, dayText, title].compactMap(\.self)
        if vote.kind == .election, vote.state != .final {
            parts.append(vote.state == .open ? "Voting" : "Scheduled")
        } else if vote.kind == .election {
            if let elected = vote.electedSpeaker {
                parts.append("\(elected.name) elected Speaker with \(elected.total)")
            } else if let leader = vote.leadingCandidate {
                parts.append("\(leader.name) led with \(leader.total); nobody was elected on this ballot")
            }
        } else {
            parts.append("Yea \(vote.totals.yea), Nay \(vote.totals.nay)")
            if let word = vote.outcomeWord { parts.append(word.capitalized) }
            if let line = vote.line { parts.append("Needed \(line.needed)") }
        }
        for position in positions {
            parts.append("\(position.member.lastName) \(label(position).capitalized)")
        }
        return parts.joined(separator: ". ")
    }
}

/// A Speaker ballot: who led, by how much, and whether anyone reached a majority of the votes cast
/// for a person.
struct ElectionBody: View {
    let vote: Vote

    private var castForAPerson: Int { vote.candidates.reduce(0) { $0 + $1.total } }

    var body: some View {
        let leaders = vote.candidates.sorted { $0.total > $1.total }.prefix(2)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(leaders.enumerated()), id: \.element.name) { index, candidate in
                    VStack(alignment: index == 0 ? .leading : .trailing, spacing: 0) {
                        Text(candidate.name.uppercased())
                            .font(Typography.label(13))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Text("\(candidate.total)")
                            .font(Typography.score(48))
                            .monospacedDigit()
                            .foregroundStyle(index == 0 ? Palette.text : Palette.trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
                    if index == 0, vote.state != .final {
                        // Counting is not over: ELECTED or NO WINNER would call it early.
                        SkewChip(
                            vote.state == .open ? "VOTING" : "SOON",
                            background: vote.state == .open ? Palette.liveText : Palette.scheduled,
                            size: 13
                        )
                    } else if index == 0 {
                        SkewChip(
                            vote.electedSpeaker == nil ? "NO WINNER" : "ELECTED",
                            foreground: vote.electedSpeaker == nil ? Palette.text : Palette.ground,
                            background: vote.electedSpeaker == nil ? Palette.raised : Palette.yea,
                            size: 13
                        )
                    }
                }
            }
            GeometryReader { geo in
                let width = geo.size.width
                let share = castForAPerson > 0 ? Double(leaders.first?.total ?? 0) / Double(castForAPerson) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.panelBorder)
                    Capsule().fill(Palette.text).frame(width: width * share)
                    Rectangle().fill(Palette.threshold).frame(width: 2, height: 14).offset(x: width * 0.5)
                }
            }
            .frame(height: 6)
        }
    }
}

#Preview("Final") {
    ScoreboardCard(vote: .sample, title: "Establishing the congressional budget", citation: "H.Con.Res. 14", positions: [.sample])
        .padding(16)
        .background(Palette.ground)
}

#Preview("Speaker ballot") {
    ScoreboardCard(vote: .sampleElection, title: "Election of the Speaker")
        .padding(16)
        .background(Palette.ground)
}
