import DesignSystem
import Models
import Onboarding
import SwiftUI

/// The Following tab, built to the locked mock (<https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre>,
/// section A): your reps, pinned from your district, then everyone you follow, newest first.
///
/// Edit hides or shows a rep (they can't be unfollowed: they are your district), unfollows anyone
/// else, and reorders them by dragging the handle — or, with VoiceOver, with the row's Move up and
/// Move down actions.
public struct FollowingView: View {
    let model: HomeModel
    let onOpenMember: (Member) -> Void
    let onFindReps: () -> Void
    let onChangeAddress: () -> Void
    @State private var editing = false
    @State private var adding = false

    public init(
        model: HomeModel,
        onOpenMember: @escaping (Member) -> Void,
        onFindReps: @escaping () -> Void,
        onChangeAddress: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenMember = onOpenMember
        self.onFindReps = onFindReps
        self.onChangeAddress = onChangeAddress
    }

    private var state: FollowState { model.follows.state }
    /// Everyone you follow who is not one of your reps (a rep is pinned above, never listed twice).
    private var followed: [Member] { state.followed(excludingReps: model.reps) }

    private func move(_ source: IndexSet, _ destination: Int) {
        let shown = followed.map(\.bioguideId)
        model.follows.update { $0.moveMembers(shown, fromOffsets: source, toOffset: destination) }
    }

    /// Edit is reachable whenever there is something to edit — any district (so a hidden rep can be
    /// shown again even when all of them are hidden and you follow nobody) or anyone followed.
    private var canEdit: Bool { model.delegation != nil || !followed.isEmpty }

    /// Dragging reorders only in Edit, where the handle shows.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        editing ? { source, destination in move(source, destination) } : nil
    }

    /// "Edit" beside the Following count; nothing while already editing.
    private var editAction: (() -> Void)? {
        editing ? nil : { editing = true }
    }

    public var body: some View {
        List {
            header.plainRow()
            repsSection
            followingSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.ground)
        .refreshable { await model.load() }
        .sheet(isPresented: $adding) {
            AddMembersView(
                model: model.memberSearch(),
                follows: model.follows,
                reps: model.reps.map(\.bioguideId)
            )
        }
    }

    private var header: some View {
        HStack {
            Text("FOLLOWING").font(Typography.headline(28)).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !editing, canEdit {
                Button("EDIT") { editing = true }
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.threshold)
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .accessibilityLabel("Edit your members")
            }
            Button(editing ? "DONE" : "+ ADD") {
                if editing { editing = false } else { adding = true }
            }
            .font(Typography.label(15))
            .foregroundStyle(Palette.threshold)
            .buttonStyle(.plain)
            .accessibilityLabel(editing ? "Done editing" : "Add members")
        }
        .padding(.top, 8)
    }

    // MARK: Your reps

    @ViewBuilder
    private var repsSection: some View {
        if let delegation = model.delegation {
            let shown = editing ? model.reps : state.visibleReps(model.reps)
            groupHeader(
                "YOUR REPS · \(delegation.district.name)",
                trailing: editing ? "Change address" : "From your address",
                action: editing ? onChangeAddress : nil
            )
            .plainRow()
            ForEach(shown) { member in repRow(member).plainRow() }
            if !editing, shown.isEmpty {
                Text("You hid all your reps. Edit to show them again.")
                    .scaledFont(12).foregroundStyle(Palette.textMuted)
                    .plainRow()
            }
        } else {
            groupHeader("YOUR REPS", trailing: nil).plainRow()
            emptyCard(
                title: "NO DISTRICT YET",
                body: "Add your address or use your location to pin your own representative and senators here.",
                button: "FIND MY REPS", filled: false, action: onFindReps
            )
            .plainRow()
        }
    }

    // MARK: Following

    @ViewBuilder
    private var followingSection: some View {
        if followed.isEmpty {
            groupHeader("FOLLOWING", trailing: nil).padding(.top, 6).plainRow()
            emptyCard(
                title: "FOLLOW ANYONE IN CONGRESS",
                body: "Search by name, state or district. Their votes show up in Finals and your widgets.",
                button: "FIND MEMBERS TO FOLLOW", filled: true, action: { adding = true }
            )
            .plainRow()
        } else {
            groupHeader(
                "FOLLOWING · \(followed.count)",
                trailing: editing ? "Drag to reorder" : "Edit",
                action: editAction
            )
            .padding(.top, 6)
            .plainRow()
            ForEach(Array(followed.enumerated()), id: \.element.id) { index, member in
                followedRow(member, index: index).plainRow()
            }
            .onMove(perform: moveAction)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func repRow(_ member: Member) -> some View {
        if editing { repEditRow(member) } else { row(member) }
    }

    @ViewBuilder
    private func followedRow(_ member: Member, index: Int) -> some View {
        if editing { followedEditRow(member, index: index) } else { row(member) }
    }

    /// The compact player row: portrait, name, party · chamber · seat, loyalty, latest vote.
    private func row(_ member: Member) -> some View {
        let share = model.loyalty[member.bioguideId]?.withPartyShare
        let latest = model.latestVote(of: member)
        return Button { onOpenMember(member) } label: {
            HStack(spacing: 9) {
                MemberPortrait(member).frame(width: 30, height: 30)
                nameBlock(member, caption: FollowingText.caption(member))
                if let share {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(FollowingText.percent(share))
                            .font(Typography.display(17, weight: .blackItalic))
                            .foregroundStyle(Palette.text)
                        Text("with party").scaledFont(9.5, weight: .medium).foregroundStyle(Palette.textMuted)
                    }
                }
                if let latest {
                    PositionChipLabel(position: latest.position, choice: latest.choice)
                }
            }
            .rowSurface()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Spoken.followingRow(member, withPartyShare: share, latest: latest))
        .accessibilityHint("Opens their record")
    }

    private func repEditRow(_ member: Member) -> some View {
        let hidden = state.isHidden(rep: member.bioguideId)
        return HStack(spacing: 9) {
            MemberPortrait(member).frame(width: 30, height: 30)
            nameBlock(member, caption: "Pinned from your district")
            Button {
                model.follows.update { $0.setHidden(rep: member.bioguideId, !hidden) }
            } label: {
                Text(hidden ? "Hidden" : "Shown")
                    .scaledFont(11, weight: .bold)
                    .foregroundStyle(hidden ? Palette.textMuted : Palette.ground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(hidden ? Color.clear : Palette.text, in: .capsule)
                    .overlay(Capsule().strokeBorder(hidden ? Palette.raised : Palette.text, lineWidth: 1))
            }
            .buttonStyle(.plain)
            // A switch to VoiceOver: "Lloyd Doggett, shown, switch button".
            .accessibilityLabel(member.fullName)
            .accessibilityValue(hidden ? "Hidden" : "Shown")
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint(hidden ? "Shows them again" : "Hides them from Following, Finals and widgets")
        }
        .rowSurface()
        .opacity(hidden ? 0.75 : 1)
    }

    private func followedEditRow(_ member: Member, index: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Palette.textMuted)
                .accessibilityHidden(true)
            MemberPortrait(member).frame(width: 30, height: 30)
            nameBlock(member, caption: FollowingText.caption(member))
            Button("Unfollow") { model.follows.update { $0.unfollow(member: member.bioguideId) } }
                .scaledFont(11, weight: .bold)
                .foregroundStyle(Palette.nay)
                .buttonStyle(.plain)
                .accessibilityLabel("Unfollow \(member.fullName)")
        }
        .rowSurface()
        // One element per member, with the edit actions VoiceOver offers on it: the drag handle
        // cannot be dragged with VoiceOver, and the Unfollow button is one more swipe otherwise.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.fullName), \(index + 1) of \(followed.count)")
        .accessibilityActions {
            if index > 0 {
                Button("Move up") { move([index], index - 1) }
            }
            if index < followed.count - 1 {
                Button("Move down") { move([index], index + 2) }
            }
            Button("Unfollow") { model.follows.update { $0.unfollow(member: member.bioguideId) } }
        }
    }

    private func nameBlock(_ member: Member, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(member.lastName.uppercased())
                .font(Typography.display(17, weight: .blackItalic))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pieces

    private func groupHeader(_ title: String, trailing: String?, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(Typography.label(12))
                .tracking(1.2)
                .foregroundStyle(Palette.textMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                if let action {
                    Button(trailing, action: action)
                        .font(Typography.label(12))
                        .foregroundStyle(Palette.threshold)
                        .buttonStyle(.plain)
                } else {
                    Text(trailing).font(Typography.label(12)).foregroundStyle(Palette.textMuted)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func emptyCard(title: String, body: String, button: String, filled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
            Text(body).scaledFont(13).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(button)
                    .font(Typography.label(14))
                    .tracking(0.6)
                    .foregroundStyle(filled ? Palette.ground : Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(filled ? Palette.threshold : Color.clear, in: .rect(cornerRadius: 9))
                    .overlay {
                        if !filled { RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.raised, lineWidth: 1) }
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.panelBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// The words on a Following row, apart from the view so they can be tested.
public enum FollowingText {
    /// `D · House · TX-37`, `R · Senate · NY`, `R · House · WY-AL`, `D · Delegate · DC`.
    public static func caption(_ member: Member) -> String { "\(member.party) · \(member.seatCaption)" }

    /// `96.9%`, one decimal as the member screen prints it.
    public static func percent(_ share: Double) -> String { String(format: "%.1f%%", share * 100) }
}

/// The filled YEA / NAY / DNV chip, a candidate's name on a Speaker ballot.
struct PositionChipLabel: View {
    let position: Position
    let choice: String?

    var body: some View {
        Text(position.chip(choice: choice))
            .font(Typography.label(11))
            .tracking(0.8)
            .lineLimit(1)
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.position(position), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

private extension View {
    /// A List row that draws only its content: no inset, no separator, no background.
    func plainRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// The mock's `.mr` row: surface, hairline, 12pt corners.
    func rowSurface() -> some View {
        self.padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.panel, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
            .contentShape(.rect)
    }
}
