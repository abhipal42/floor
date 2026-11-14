import APIClient
import DesignSystem
import Foundation
import Models
import Onboarding
import RepScreen
import SwiftUI

/// "+ Add": searches sitting members as you type, a short pause after the last keystroke.
@MainActor
@Observable
public final class MemberSearchModel {
    public var query = ""
    /// nil for both chambers: the mock's All / Senate / House switch.
    public var chamber: Chamber?
    /// The members found for ``searched``; kept while a newer search loads, so the list doesn't blink.
    public private(set) var results: [Member] = []
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

    /// What is sent: the query trimmed, or nil when it is under two characters (the API's minimum),
    /// in which case nothing is searched and the list clears.
    public nonisolated static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 ? trimmed : nil
    }

    /// Changes with anything that should start a new search, for `.task(id:)`.
    public var key: String { "\(chamber?.rawValue ?? "all")|\(query)" }

    /// Results by chamber, Senate first as the API orders them, empty groups left out.
    public nonisolated static func groups(_ members: [Member]) -> [(chamber: Chamber, members: [Member])] {
        [Chamber.senate, .house].compactMap { chamber in
            let these = members.filter { $0.chamber == chamber }
            return these.isEmpty ? nil : (chamber, these)
        }
    }

    public var groups: [(chamber: Chamber, members: [Member])] { Self.groups(results) }

    /// Waits out the pause, then searches. Run from `.task(id: key)`, so the next keystroke cancels
    /// it before it sends anything; a cancelled search changes nothing on screen.
    public func search() async {
        guard let text = Self.normalized(query) else {
            results = []
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
        isLoading = true
        do {
            let found = try await api.searchMembers(query: text, chamber: chamber)
            guard !Task.isCancelled else { return }
            results = found.members
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

/// The search sheet, built to the locked mock's section B: a search field, All / Senate / House,
/// results grouped Senate then House with a Follow toggle each, and the no-results card.
struct AddMembersView: View {
    @State var model: MemberSearchModel
    let follows: Follows
    let reps: [String]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ADD MEMBERS").font(Typography.headline(28)).foregroundStyle(Palette.text)
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
            TextField("Name, state or district", text: $model.query)
                .scaledFont(15, weight: .medium)
                .foregroundStyle(Palette.text)
                .focused($focused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search members of Congress")
                .accessibilityHint("A name, a state like New York, or a district like NY-8")
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
                .accessibilityLabel(option?.name ?? "Both chambers")
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
        } else if let searched = model.searched, model.results.isEmpty, !model.isLoading {
            notice(title: "NO MEMBERS MATCH \u{201C}\(searched.uppercased())\u{201D}",
                   body: "Try a last name, a state, or a district like TX-37.")
        } else if model.searched == nil, !model.isLoading {
            Text("Search all sitting members: senators, representatives, delegates and Puerto Rico's resident commissioner.")
                .scaledFont(13)
                .foregroundStyle(Palette.textMuted)
                .padding(.top, 6)
        }
        if model.error == nil {
            ForEach(model.groups, id: \.chamber) { group in
                Text("\(group.chamber.name.uppercased()) · \(group.members.count)")
                    .font(Typography.label(12))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.members) { member in result(member) }
            }
        }
    }

    private func result(_ member: Member) -> some View {
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
