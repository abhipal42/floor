import APIClient
import DesignSystem
import Foundation
import Models
import Onboarding
import RepScreen
import SwiftUI

/// "+ Add": one search over members, bills and topics (`GET /v1/search`), a short pause after the
/// last keystroke. Built to the locked Round 10 design, section C
/// (<https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>). It replaced v0.2.28's member-only search;
/// the API reads its members with that search's own reader (`/v1/members?q=`'s), and the sheet
/// keeps its All / Senate / House switch, which narrows the members.
@MainActor
@Observable
public final class FollowSearchModel {
    /// A group of results, in the order the sheet shows them: topics, bills, members.
    public enum Section: Equatable, Sendable {
        case topics([Topic])
        /// `billNumber`: the query read as a bill number, so these are that bill in each Congress.
        case bills([BillListItem], billNumber: Bool)
        /// Empty when words matched topics or bills but no member: the sheet says so under the
        /// heading, as the mock does.
        case members([Member])
    }

    public var query = ""
    /// nil for both chambers: v0.2.28's All / Senate / House switch. Narrows the members only.
    public var chamber: Chamber?
    /// The results for ``searched``; kept while a newer search loads, so the list doesn't blink.
    public private(set) var results: SearchResults?
    /// The text the results are for, or nil before any search has finished.
    public private(set) var searched: String?
    public private(set) var isLoading = false
    public private(set) var error: String?

    private let api: FloorAPI
    private let debounce: Duration

    public init(api: FloorAPI, debounce: Duration = .milliseconds(300)) {
        self.api = api
        self.debounce = debounce
    }

    /// What is sent: the query trimmed, or nil when it is under two characters or over 100 (the
    /// API's bounds), in which case nothing is searched and the list clears.
    public nonisolated static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...100).contains(trimmed.count) ? trimmed : nil
    }

    /// The results as the sheet groups them. A bill number is that bill and nothing else. Words
    /// show topics and bills only when there are some, and members always — with nothing found
    /// anywhere, no sections at all, and the sheet says nothing matched.
    public nonisolated static func sections(_ results: SearchResults) -> [Section] {
        if results.billNumber { return results.bills.isEmpty ? [] : [.bills(results.bills, billNumber: true)] }
        guard !(results.topics.isEmpty && results.bills.isEmpty && results.members.isEmpty) else { return [] }
        var sections: [Section] = []
        if !results.topics.isEmpty { sections.append(.topics(results.topics)) }
        if !results.bills.isEmpty { sections.append(.bills(results.bills, billNumber: false)) }
        sections.append(.members(results.members))
        return sections
    }

    public var sections: [Section] { results.map(Self.sections) ?? [] }

    /// What the sheet's `.task(id:)` watches: a new chamber searches again, as a keystroke does.
    public var key: String { "\(chamber?.rawValue ?? "all")|\(query)" }

    /// Members by chamber, Senate first as the API orders them, empty groups left out.
    public nonisolated static func groups(_ members: [Member]) -> [(chamber: Chamber, members: [Member])] {
        [Chamber.senate, .house].compactMap { chamber in
            let these = members.filter { $0.chamber == chamber }
            return these.isEmpty ? nil : (chamber, these)
        }
    }

    /// A search finished and found nothing at all.
    public var foundNothing: Bool { searched != nil && results != nil && sections.isEmpty && error == nil }

    /// Waits out the pause, then searches. Run from `.task(id: query)`, so the next keystroke
    /// cancels it before it sends anything; a cancelled search changes nothing on screen.
    public func search() async {
        guard Self.normalized(query) != nil else {
            results = nil
            searched = nil
            error = nil
            isLoading = false
            return
        }
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }
        await searchNow()
    }

    /// Searches what is typed straight away, without the pause (and, for previews and snapshots,
    /// without `.task`).
    public func searchNow() async {
        guard let text = Self.normalized(query) else {
            results = nil
            searched = nil
            error = nil
            isLoading = false
            return
        }
        isLoading = true
        do {
            let found = try await api.search(query: text, chamber: chamber)
            guard !Task.isCancelled else { return }
            results = found
            searched = text
            error = nil
            isLoading = false
        } catch is CancellationError {
            // A newer search has started and owns `isLoading` now.
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            self.error = (error as? FloorAPIError)?.errorDescription ?? "Couldn't search right now."
        }
    }
}

/// The search sheet: a field, then the results grouped Topics, Bills, Members, each with a Follow
/// toggle. Tapping a topic or a bill closes the sheet and opens it.
public struct AddFollowsView: View {
    @State private var model: FollowSearchModel
    let follows: Follows
    let reps: [String]
    let onOpenBill: (String) -> Void
    let onOpenTopic: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    /// - Parameter reps: your reps' Bioguide IDs; their rows read "Your rep" rather than Follow.
    public init(
        model: FollowSearchModel, follows: Follows, reps: [String],
        onOpenBill: @escaping (String) -> Void, onOpenTopic: @escaping (String) -> Void
    ) {
        _model = State(initialValue: model)
        self.follows = follows
        self.reps = reps
        self.onOpenBill = onOpenBill
        self.onOpenTopic = onOpenTopic
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ADD").font(Typography.headline(28)).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("DONE") { dismiss() }
                    .font(Typography.label(15))
                    .foregroundStyle(Palette.threshold)
                    .buttonStyle(.plain)
            }
            field
            chamberSwitch
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) { content }
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .background(Palette.ground.ignoresSafeArea())
        .task(id: model.key) { await model.search() }
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textMuted).accessibilityHidden(true)
            TextField("Members, bills, topics, or a bill number", text: $model.query)
                .scaledFont(15, weight: .medium)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search members, bills and topics")
                .accessibilityHint("A name, a state, a district like NY-8, words from a bill, a topic, or a bill number like H.R. 1013")
            if model.isLoading {
                ProgressView().controlSize(.small).tint(Palette.accent)
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Palette.panel, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.panelBorder, lineWidth: 1))
    }

    private var chamberSwitch: some View {
        HStack(spacing: 4) {
            ForEach([Chamber?.none, .senate, .house], id: \.self) { option in
                let on = model.chamber == option
                Button { model.chamber = option } label: {
                    Text(option?.name.uppercased() ?? "ALL")
                        .font(Typography.label(12))
                        .tracking(0.6)
                        .foregroundStyle(on ? Palette.text : Palette.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? Palette.chip : Color.clear, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.map { "\($0.name) members" } ?? "Members in both chambers")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            notice(title: "COULDN'T SEARCH", body: error)
        } else if model.foundNothing, let searched = model.searched {
            notice(title: "NOTHING MATCHES \u{201C}\(searched.uppercased())\u{201D}",
                   body: "Try a last name, a state, a district like TX-37, a topic like Health, or a bill number like hr 1013.")
        } else if model.searched == nil, !model.isLoading {
            Text("Search sitting members by name, state or district; bills by words or number (\u{201C}hr 1013\u{201D}, \u{201C}S. 2\u{201D}); and the 32 topics CRS sorts every bill into.")
                .scaledFont(13)
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 6)
        }
        if model.error == nil {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: FollowSearchModel.Section) -> some View {
        switch section {
        case let .topics(topics):
            heading(topics.count == 1 ? "TOPIC" : "TOPICS · \(topics.count)")
            ForEach(topics) { topic in
                TopicRowView(
                    name: topic.name, detail: TopicText.detail(topic), spoken: Spoken.topicRow(topic),
                    onOpen: { open { onOpenTopic(topic.name) } }
                ) {
                    FollowPill(on: follows.isFollowing(topic: topic.name), name: topic.name,
                               hint: "Adds votes on its bills to Finals") { follows.toggle(topic: topic.name) }
                }
            }
        case let .bills(bills, billNumber):
            heading(billNumber && bills.count == 1 ? "BILL" : "BILLS · \(bills.count)")
            ForEach(bills) { bill in
                BillRowView(bill: bill, showsLatest: billNumber, onOpen: { open { onOpenBill(bill.id) } }) {
                    FollowPill(on: follows.isFollowing(bill: bill.id), name: bill.citation,
                               hint: "Adds its votes to Finals") { follows.toggle(bill: bill) }
                }
            }
        case let .members(members):
            if members.isEmpty, let searched = model.searched {
                heading(model.chamber.map { "\($0.name.uppercased()) MEMBERS" } ?? "MEMBERS")
                Text("No \(model.chamber.map { "\($0.name) " } ?? "")members match \u{201C}\(searched)\u{201D}.")
                    .scaledFont(12.5)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.panelBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            // By chamber, as v0.2.28's member search grouped them: a whole state is 40 rows.
            ForEach(FollowSearchModel.groups(members), id: \.chamber) { group in
                heading("\(group.chamber.name.uppercased()) · \(group.members.count)")
                ForEach(group.members) { member in memberRow(member) }
            }
        }
    }

    /// Closes the sheet, then opens what was tapped on the tab beneath it.
    private func open(_ action: @escaping () -> Void) {
        dismiss()
        action()
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Typography.label(12))
            .tracking(1.2)
            .foregroundStyle(Palette.textMuted)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func memberRow(_ member: Member) -> some View {
        HStack(spacing: 9) {
            MemberPortrait(member).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.lastName.uppercased())
                    .font(Typography.display(17, weight: .blackItalic))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(FollowingText.caption(member)).scaledFont(10.5, weight: .medium).foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Spoken.member(member))
            FollowButton(member: member, follows: follows, isRep: reps.contains(member.bioguideId), compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.panelBorder, lineWidth: 1))
    }

    private func notice(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Typography.label(12)).tracking(1.2).foregroundStyle(Palette.textMuted)
            Text(body).scaledFont(13).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.panelBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .padding(.top, 10)
    }
}
