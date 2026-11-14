import DesignSystem
import Models
import Onboarding
import SwiftUI

/// The Following tab: a Members · Bills · Topics switch (the locked Round 10 design,
/// <https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>, section A) over three lists.
///
/// **Members** is the round 9 mock unchanged (<https://claude.ai/artifact/C7qGitvJMSLFmCkYYQgNre>,
/// section A): your reps, pinned from your district, then everyone you follow, newest first. Edit
/// hides or shows a rep (they can't be unfollowed: they are your district), unfollows anyone else,
/// and reorders them by dragging the handle — or, with VoiceOver, with the row's Move up and Move
/// down actions.
///
/// **Bills**: each followed bill's citation, stage chip, label, latest step and five-step road.
/// **Topics**: followed topics with their counts, then the biggest others as suggestions.
public struct FollowingView: View {
    /// The switch at the top of the tab.
    public enum Segment: String, CaseIterable, Sendable {
        case members, bills, topics
    }

    let model: HomeModel
    let onOpenMember: (Member) -> Void
    let onOpenBill: (String) -> Void
    let onOpenTopic: (String) -> Void
    /// The bell in the top bar: the Alerts screen. nil (previews) shows no bell.
    let onOpenAlerts: (() -> Void)?
    let onFindReps: () -> Void
    let onChangeAddress: () -> Void
    @State private var editing = false
    @State private var adding = false
    @State private var segment: Segment

    public init(
        model: HomeModel,
        segment: Segment = .members,
        onOpenMember: @escaping (Member) -> Void,
        onOpenBill: @escaping (String) -> Void = { _ in },
        onOpenTopic: @escaping (String) -> Void = { _ in },
        onOpenAlerts: (() -> Void)? = nil,
        onFindReps: @escaping () -> Void,
        onChangeAddress: @escaping () -> Void
    ) {
        self.model = model
        _segment = State(initialValue: segment)
        self.onOpenMember = onOpenMember
        self.onOpenBill = onOpenBill
        self.onOpenTopic = onOpenTopic
        self.onOpenAlerts = onOpenAlerts
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
            segmentSwitch.plainRow()
            switch segment {
            case .members:
                repsSection
                followingSection
            case .bills:
                billsSection
            case .topics:
                topicsSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Palette.ground)
        .refreshable {
            await model.load()
            if segment == .topics { await model.loadTopics() }
        }
        .task(id: segment) {
            if segment == .topics, model.topicList == nil { await model.loadTopics() }
        }
        .onChange(of: segment) { editing = false }
        .sheet(isPresented: $adding) {
            AddFollowsView(
                model: model.followSearch(),
                follows: model.follows,
                reps: model.reps.map(\.bioguideId),
                onOpenBill: onOpenBill,
                onOpenTopic: onOpenTopic
            )
        }
    }

    /// `MEMBERS · 6`, `BILLS · 3`, `TOPICS · 2`.
    nonisolated static func segmentTitle(_ segment: Segment, count: Int) -> String {
        "\(segment.rawValue.uppercased()) · \(count)"
    }

    private func count(_ segment: Segment) -> Int {
        switch segment {
        case .members: model.yourMembers.count
        // The list's own rows, so the count is what is listed.
        case .bills: model.followedBills.count
        case .topics: model.followedTopics.count
        }
    }

    private var segmentSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases, id: \.self) { option in
                let on = segment == option
                let count = count(option)
                Button { segment = option } label: {
                    Text(Self.segmentTitle(option, count: count))
                        .font(Typography.label(12))
                        .tracking(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(on ? Palette.text : Palette.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? Palette.chip : Color.clear, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.rawValue.capitalized), \(count) followed")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
    }

    private var header: some View {
        HStack {
            Text("FOLLOWING").font(Typography.headline(28)).foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !editing, let onOpenAlerts {
                Button(action: onOpenAlerts) {
                    Image(systemName: "bell")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.threshold)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .accessibilityLabel("Alerts")
                .accessibilityHint("Choose which votes alert you")
            }
            if !editing, canEdit, segment == .members {
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
            .accessibilityLabel(editing ? "Done editing" : "Add members, bills or topics")
        }
        .padding(.top, 8)
    }

    // MARK: Bills

    @ViewBuilder
    private var billsSection: some View {
        let bills = model.followedBills
        if bills.isEmpty {
            emptyCard(
                title: "FOLLOW A BILL",
                body: "Search by number (hr 1013, S. 2) or by words. Each step it takes shows here, and its votes in Finals.",
                button: "FIND BILLS TO FOLLOW", filled: true, action: { adding = true }
            )
            .plainRow()
        } else {
            ForEach(bills) { bill in
                Button { onOpenBill(bill.id) } label: { BillRowView(bill: bill) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the bill")
                    .accessibilityAction(named: "Unfollow") { unfollow(bill: bill.id) }
                    .swipeActions(edge: .trailing) {
                        Button("Unfollow", role: .destructive) { unfollow(bill: bill.id) }
                    }
                    .plainRow()
            }
            Text(BillRoad.legend)
                .scaledFont(10, weight: .medium)
                .foregroundStyle(Palette.textMuted)
                .plainRow()
            ForEach([model.unavailableBillsNote, model.billLimitNote].compactMap(\.self), id: \.self) { note in
                Text(note).scaledFont(12).foregroundStyle(Palette.textMuted).plainRow()
            }
        }
    }

    private func unfollow(bill id: String) {
        model.follows.update { $0.unfollow(bill: id) }
    }

    /// Unfollow, never toggle: a swipe that lands twice must not follow the topic again.
    private func unfollow(topic name: String) {
        model.follows.update { $0.unfollow(topic: name) }
    }

    // MARK: Topics

    @ViewBuilder
    private var topicsSection: some View {
        let followed = model.followedTopicRows
        if followed.isEmpty {
            emptyCard(
                title: "FOLLOW A TOPIC",
                body: "A topic is one of the 32 policy areas the Congressional Research Service puts every bill in. Follow one to see its bills as they move, and its votes in Finals.",
                button: "SEARCH TOPICS", filled: false, action: { adding = true }
            )
            .plainRow()
        } else {
            ForEach(followed, id: \.name) { row in
                Button { onOpenTopic(row.name) } label: {
                    TopicRowView(
                        name: row.name, detail: row.topic.map(TopicText.detail),
                        spoken: row.topic.map(Spoken.topicRow) ?? row.name
                    ) {
                        Text("›").font(.system(size: 18)).foregroundStyle(Palette.textMuted).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the topic's bills")
                .accessibilityAction(named: "Unfollow") { unfollow(topic: row.name) }
                .swipeActions(edge: .trailing) {
                    Button("Unfollow", role: .destructive) { unfollow(topic: row.name) }
                }
                .plainRow()
            }
        }
        if model.topicList == nil {
            if let error = model.topicListError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).scaledFont(12).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.loadTopics() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .buttonStyle(.plain)
                }
                .plainRow()
            } else {
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 12).plainRow()
            }
        } else if !model.suggestedTopics.isEmpty {
            groupHeader("SUGGESTED", trailing: nil).padding(.top, 8).plainRow()
            ForEach(model.suggestedTopics) { topic in
                TopicRowView(
                    name: topic.name, detail: "\(topic.bills.formatted()) \(topic.bills == 1 ? "bill" : "bills")",
                    spoken: Spoken.topicRow(topic), onOpen: { onOpenTopic(topic.name) }
                ) {
                    FollowPill(on: false, name: topic.name, hint: "Adds votes on its bills to Finals") {
                        model.follows.toggle(topic: topic.name)
                    }
                }
                .plainRow()
            }
        }
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
