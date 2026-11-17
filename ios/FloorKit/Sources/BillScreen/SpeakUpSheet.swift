import DesignSystem
import Models
import Onboarding
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Speak up (round 11, section C of <https://claude.ai/artifact/VdSGbow4qnJwYe2sV7Tb2r>): a message
/// about this bill to one of **your own** members — offices discard mail from outside the
/// district — that the person finishes and sends through the office's own form, or a call script.
///
/// The product calls, kept here: no stance is ever chosen for you; the text is fixed, with only the
/// bill's facts (``SpeakUpTemplate``), no AI and no talking points; nothing is stored or sent by
/// Floor. The message lives in this sheet's state and goes when it closes.
public struct SpeakUpSheet: View {
    let facts: BillFacts
    let delegation: Delegation?
    let contact: (Member) async -> MemberContact?
    let onSetDistrict: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var recipient: Member?
    @State private var stance: Stance?
    @State private var text = ""
    /// The text as last generated, to tell an edited message from an untouched one.
    @State private var generated = ""
    @State private var contacts: [String: MemberContact] = [:]
    @State private var calling = false
    @State private var copied = false

    /// `initialStance`, `recipientId`, `startCalling` and `contacts` exist for the snapshots, which draw the
    /// mock's states; the app opens the sheet with no stance chosen, always.
    public init(
        facts: BillFacts, delegation: Delegation?, contact: @escaping (Member) async -> MemberContact?,
        onSetDistrict: (() -> Void)?, initialStance: Stance? = nil, recipientId: String? = nil, startCalling: Bool = false,
        contacts: [String: MemberContact] = [:]
    ) {
        _calling = State(initialValue: startCalling)
        _contacts = State(initialValue: contacts)
        self.facts = facts
        self.delegation = delegation
        self.contact = contact
        self.onSetDistrict = onSetDistrict
        let all = delegation.map(Self.recipients) ?? []
        let first = all.first { $0.bioguideId == recipientId } ?? all.first
        _recipient = State(initialValue: first)
        _stance = State(initialValue: initialStance)
        if let first, let delegation, let initialStance {
            let message = SpeakUpTemplate.message(to: first, district: delegation.district, facts: facts, stance: initialStance)
            _text = State(initialValue: message)
            _generated = State(initialValue: message)
        }
    }

    /// Your representative, then your senators.
    static func recipients(_ delegation: Delegation) -> [Member] {
        delegation.members.filter { $0.chamber == .house } + delegation.members.filter { $0.chamber == .senate }
    }

    /// `Rep. Doggett`, `Sen. Cornyn`, `Del. Norton`.
    static func shortName(_ member: Member) -> String {
        let prefix = switch member.title {
        case "Senator": "Sen."
        case "Delegate": "Del."
        case "Resident Commissioner": "Res. Comm."
        default: "Rep."
        }
        return "\(prefix) \(member.lastName)"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if calling, let recipient, let delegation {
                    callView(recipient, district: delegation.district)
                } else {
                    writeView
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.ground)
        .task(id: recipient?.bioguideId) {
            guard let recipient, contacts[recipient.bioguideId] == nil else { return }
            if let found = await contact(recipient) { contacts[recipient.bioguideId] = found }
        }
    }

    // MARK: Write

    @ViewBuilder
    private var writeView: some View {
        Text("SPEAK UP · \(facts.citation.uppercased())")
            .font(Typography.headline(22))
            .foregroundStyle(Palette.text)
            .accessibilityAddTraits(.isHeader)
        if let delegation {
            label("TO · YOUR MEMBERS")
            chips(Self.recipients(delegation), selected: recipient?.bioguideId, title: Self.shortName, id: \.bioguideId) { member in
                choose(recipient: member, delegation: delegation)
            }
            label("YOUR VIEW · YOU CHOOSE")
            chips(Stance.allCases, selected: stance?.id, title: \.chip, id: \.id) { choice in
                choose(stance: choice, delegation: delegation)
            }
            message
            actions(delegation)
            Text("Floor fills in only the bill's facts. Nothing is picked for you, and nothing is sent or stored.")
                .scaledFont(10)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            noDistrict
        }
    }

    private var noDistrict: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SET YOUR DISTRICT FIRST").font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
            Text("Offices count mail and calls only from their own constituents, so Speak up writes only to your representative and your two senators. Floor doesn't know your district yet.")
                .scaledFont(13)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onSetDistrict {
                Button {
                    dismiss()
                    onSetDistrict()
                } label: {
                    Text("SET YOUR DISTRICT")
                        .font(Typography.label(14)).tracking(0.6)
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Palette.threshold, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Text("You can still call any member from the Contact tab on their page.")
                .scaledFont(11)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    @ViewBuilder
    private var message: some View {
        if stance == nil {
            Text("Pick your view and the message appears here, with the bill's facts filled in.")
                .scaledFont(11.5)
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.raised, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        } else {
            TextEditor(text: $text)
                .scaledFont(12.5)
                .foregroundStyle(Palette.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 230)
                .padding(6)
                .background(Palette.widget, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
                .accessibilityLabel("Message")
                .accessibilityHint("Edit it as you like. Replace the bracketed lines with your own words.")
        }
    }

    private func actions(_ delegation: Delegation) -> some View {
        let form = recipient.flatMap { SpeakUpTemplate.formURL(for: $0, contact: contacts[$0.bioguideId]) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                button(copied ? "COPIED ✓" : "COPY & OPEN FORM", filled: true, enabled: stance != nil && form != nil) {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = text
                    #endif
                    copied = true
                    if let form { openURL(form) }
                }
                .accessibilityHint("Copies the message and opens the office's contact form to paste it into")
                button("CALL INSTEAD", filled: false, enabled: recipient != nil) { calling = true }
                    .accessibilityHint("Shows a short script and the office's phone number")
            }
            if let recipient, recipient.chamber == .house, contacts[recipient.bioguideId]?.contactForm == nil {
                Text("No form listed for this office, so this opens the House's \"Write Your Representative\" form, which checks your ZIP.")
                    .scaledFont(10)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Call

    @ViewBuilder
    private func callView(_ member: Member, district: District) -> some View {
        let contact = contacts[member.bioguideId]
        Text("CALL \(Self.shortName(member).uppercased())")
            .font(Typography.headline(22))
            .foregroundStyle(Palette.text)
            .accessibilityAddTraits(.isHeader)
        HStack(spacing: 10) {
            Image(systemName: "phone").foregroundStyle(Palette.threshold).frame(width: 28, height: 28)
                .background(Palette.chip, in: .rect(cornerRadius: 8)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact?.phone ?? "No phone number listed").scaledFont(13, weight: .bold).foregroundStyle(Palette.text)
                Text("Washington office").scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        label("WHAT TO SAY · ABOUT 30 SECONDS")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(SpeakUpTemplate.callScript(to: member, district: district, facts: facts, stance: stance).enumerated()), id: \.offset) { _, line in
                Text(line).scaledFont(12).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.widget, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        HStack(spacing: 6) {
            let tel = SpeakUpTemplate.telURL(contact?.phone)
            button("CALL", filled: true, enabled: tel != nil) { if let tel { openURL(tel) } }
                .accessibilityHint("Opens the Phone app with the number")
            button("DONE", filled: false, enabled: true) { calling = false }
        }
    }

    // MARK: Pieces

    private func choose(recipient member: Member, delegation: Delegation) {
        let old = recipient
        recipient = member
        copied = false
        guard let stance else { return }
        let next = SpeakUpTemplate.message(to: member, district: delegation.district, facts: facts, stance: stance)
        if text == generated || old == nil {
            text = next
        } else if let old {
            // Edited: swap only the greeting and where-you-live line, keeping the person's words.
            text = text
                .replacingOccurrences(of: SpeakUpTemplate.greeting(old), with: SpeakUpTemplate.greeting(member))
                .replacingOccurrences(
                    of: SpeakUpTemplate.residence(old, district: delegation.district),
                    with: SpeakUpTemplate.residence(member, district: delegation.district)
                )
        }
        generated = next
    }

    private func choose(stance choice: Stance, delegation: Delegation) {
        guard let recipient else { return }
        let old = stance
        stance = choice
        copied = false
        let next = SpeakUpTemplate.message(to: recipient, district: delegation.district, facts: facts, stance: choice)
        if let old, text != generated, let swapped = SpeakUpTemplate.restanced(text, from: old, to: choice, member: recipient) {
            text = swapped
        } else if old == nil || text == generated {
            text = next
        }
        generated = next
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typography.label(10.5))
            .tracking(1.0)
            .foregroundStyle(Palette.textMuted)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func chips<Item, ID: Hashable>(
        _ items: [Item], selected: ID?, title: @escaping (Item) -> String, id: KeyPath<Item, ID>,
        choose: @escaping (Item) -> Void
    ) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let on = item[keyPath: id] == selected
                Button { choose(item) } label: {
                    Text(title(item))
                        .scaledFont(11.5, weight: .semibold)
                        .foregroundStyle(on ? Palette.ground : Palette.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(on ? Palette.text : Color.clear, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.clear : Palette.raised, lineWidth: 1))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private func button(_ title: String, filled: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.label(13))
                .tracking(0.6)
                .foregroundStyle(filled ? Palette.ground : Palette.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(filled ? Palette.threshold : Color.clear, in: .rect(cornerRadius: 9))
                .overlay { if !filled { RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.raised, lineWidth: 1) } }
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Chips that wrap onto the next line when they run out of room. Public for Finals' story cards.
public struct FlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + itemWidth > width {
                y += rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
