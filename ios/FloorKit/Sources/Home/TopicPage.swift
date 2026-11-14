import APIClient
import DesignSystem
import Foundation
import Models
import Onboarding
import SwiftUI

/// A topic's bills, newest action first, a page at a time (`GET /v1/topics/{name}/bills`), filtered
/// All · Moving · Law · Stalled. The first page of each filter opens on its saved copy and
/// revalidates; later pages are fetched as the list reaches its end.
@MainActor
@Observable
public final class TopicPageModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public let name: String
    public private(set) var filter: TopicFilter = .all
    public private(set) var phase: Phase = .loading
    /// Every page loaded so far for ``filter``, without repeats.
    public private(set) var bills: [BillListItem] = []
    /// The topic's counts as the latest page gave them.
    public private(set) var topic: Topic?
    /// nil once the last page is in.
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    /// Set when a later page failed; the bills already shown stay.
    public private(set) var moreError: String?
    public private(set) var saved: SavedCopy?
    /// Bumped by each first-page load, so a load overtaken by a filter change drops its results.
    private var generation = 0
    /// The next page's request while it is out. A filter change or a refresh cancels it, so its
    /// `isLoadingMore` can never outlive the list it was for and stall paging on the new one.
    private var moreTask: Task<Void, Never>?
    /// True while a first page is loading, saved pass included: its cursor may be the saved copy's,
    /// so no next page is asked for until the fresh page 1 is in.
    private var firstPageLoading = false
    /// The list reached its end while page 1 was still loading; the next page is asked for once it
    /// lands, since the row that asked has already appeared and won't again.
    private var wantsMore = false

    private let api: FloorAPI

    public init(name: String, api: FloorAPI) {
        self.name = name
        self.api = api
    }

    public var hasMore: Bool { nextCursor != nil }

    /// What an empty filter says: `No Health bills have become law this Congress yet.`
    public nonisolated static func emptyMessage(topic: String, filter: TopicFilter) -> String {
        switch filter {
        case .all: "No \(topic) bills this Congress yet."
        case .moving: "No \(topic) bills have had an action in the last 90 days."
        case .law: "No \(topic) bills have become law this Congress yet."
        case .stalled: "No \(topic) bills have gone 90 days without an action."
        }
    }

    /// The filter's label on the switch.
    public nonisolated static func label(_ filter: TopicFilter) -> String {
        switch filter {
        case .all: "All"
        case .moving: "Moving"
        case .law: "Law"
        case .stalled: "Stalled"
        }
    }

    public func select(_ next: TopicFilter) async {
        guard next != filter else { return }
        filter = next
        bills = []
        nextCursor = nil
        moreError = nil
        phase = .loading
        await load()
    }

    /// The first page for the filter: saved, then fresh. Cancels a next page still out, which
    /// belongs to the list this replaces.
    public func load() async {
        generation += 1
        let mine = generation
        let filter = filter
        cancelMore()
        firstPageLoading = true
        wantsMore = false
        if case .loaded = phase {} else {
            phase = .loading
            saved = nil
        }
        do {
            try await revalidate(api, report: { if mine == generation { saved = $0 } }) { [name] pass in
                let page = try await pass.api.topicBills(name: name, filter: filter)
                guard mine == generation else { throw CancellationError() }
                topic = page.topic
                bills = Self.unique(page.bills)
                nextCursor = page.nextCursor
                moreError = nil
                phase = .loaded
            }
        } catch is CancellationError {
        } catch {
            guard mine == generation else { return }
            saved = nil
            phase = .failed((error as? FloorAPIError)?.errorDescription ?? "Couldn't load \(name).")
        }
        guard mine == generation else { return }
        firstPageLoading = false
        if wantsMore {
            wantsMore = false
            await loadMore()
        }
    }

    /// The next page, appended. One at a time; a failure keeps the list and offers Try again.
    public func loadMore() async {
        if firstPageLoading {
            wantsMore = true
            return
        }
        guard case .loaded = phase, let cursor = nextCursor, moreTask == nil else { return }
        let mine = generation
        let filter = filter
        isLoadingMore = true
        let task = Task { [weak self, api, name] in
            let result: Result<TopicBills, any Error>
            do {
                result = .success(try await api.topicBills(name: name, filter: filter, cursor: cursor))
            } catch {
                result = .failure(error)
            }
            self?.finishMore(result, generation: mine)
        }
        moreTask = task
        await task.value
    }

    private func finishMore(_ result: Result<TopicBills, any Error>, generation mine: Int) {
        // Overtaken (a filter change, a refresh): `cancelMore` already cleared the state, and a newer
        // next page may own it now.
        guard mine == generation else { return }
        moreTask = nil
        isLoadingMore = false
        switch result {
        case let .success(page):
            topic = page.topic
            bills = Self.unique(bills + page.bills)
            nextCursor = page.nextCursor
            moreError = nil
        case let .failure(error):
            if error is CancellationError { return }
            moreError = (error as? FloorAPIError)?.errorDescription ?? "Couldn't load more bills."
        }
    }

    private func cancelMore() {
        moreTask?.cancel()
        moreTask = nil
        isLoadingMore = false
    }

    /// A bill whose action moved between two page requests can appear on both; it is listed once.
    nonisolated static func unique(_ bills: [BillListItem]) -> [BillListItem] {
        var seen = Set<String>()
        return bills.filter { seen.insert($0.id).inserted }
    }
}

/// A topic's page (Round 10, section B): its name, Follow / Following, the filter, and its bills,
/// each opening the bill screen.
public struct TopicPageView: View {
    @State private var model: TopicPageModel
    let follows: Follows
    let onOpenBill: (String) -> Void

    public init(model: TopicPageModel, follows: Follows, onOpenBill: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.follows = follows
        self.onOpenBill = onOpenBill
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let saved = model.saved { SavedDataNote(saved) }
                // Follow sits beside the name rather than in the navigation bar, where iOS 26 draws
                // a toolbar item on its own glass capsule that the pill's colours fight.
                HStack(alignment: .center, spacing: 10) {
                    Text(model.name.uppercased())
                        .font(Typography.headline(34))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    FollowPill(
                        on: follows.isFollowing(topic: model.name), onTitle: "✓ FOLLOWING", name: model.name,
                        hint: "Adds votes on its bills to Finals and lists it under Following"
                    ) { follows.toggle(topic: model.name) }
                }
                if let topic = model.topic {
                    Text(TopicText.detail(topic)).scaledFont(12).foregroundStyle(Palette.textMuted)
                }
                filterSwitch
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.ground)
        .refreshable { await model.load() }
        .task { if case .loaded = model.phase {} else { await model.load() } }
    }

    private var filterSwitch: some View {
        HStack(spacing: 4) {
            ForEach(TopicFilter.allCases, id: \.self) { option in
                let on = model.filter == option
                Button { Task { await model.select(option) } } label: {
                    Text(TopicPageModel.label(option).uppercased())
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
                .accessibilityLabel(option == .law ? "Became law" : TopicPageModel.label(option))
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.panel, in: .rect(cornerRadius: 9))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.top, 40)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).font(Typography.body).foregroundStyle(Palette.textSecondary)
                Button("Try again") { Task { await model.load() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .panel()
        case .loaded:
            if model.bills.isEmpty {
                Text(TopicPageModel.emptyMessage(topic: model.name, filter: model.filter))
                    .scaledFont(13)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, 6)
            }
            ForEach(model.bills) { bill in
                Button { onOpenBill(bill.id) } label: { BillRowView(bill: bill, showsRoad: false) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the bill")
                    .onAppear { if bill.id == model.bills.last?.id { Task { await model.loadMore() } } }
            }
            if model.isLoadingMore {
                ProgressView().tint(Palette.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if let error = model.moreError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).scaledFont(12).foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await model.loadMore() } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                .padding(.top, 6)
            }
            if !model.bills.isEmpty {
                Text("\u{201C}Stalled\u{201D} means no action in 90 days. It describes; it doesn't predict.")
                    .scaledFont(11)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, 6)
            }
        }
    }
}
