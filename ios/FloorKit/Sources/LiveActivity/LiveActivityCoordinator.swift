import APIClient
import Foundation
import Models

/// Where the coordinator reads the floor from: the API in the app, a stub in tests.
public protocol LiveSource: Sendable {
    func liveNow() async throws -> Live
    /// One vote with your members' positions (`GET /v1/votes/{id}?members=`).
    func voteDetail(id: String, members: [String]) async throws -> VoteDetail
}

extension FloorAPI: LiveSource {
    public func liveNow() async throws -> Live { try await live(since: 120) }

    public func voteDetail(id: String, members: [String]) async throws -> VoteDetail {
        try await vote(id: id, members: members)
    }
}

/// The Live Activities this phone is showing. ActivityKit in the app (`ios/Floor/LiveActivities.swift`),
/// a fake in tests.
@MainActor
public protocol ActivityHost: AnyObject {
    /// The user allows Live Activities for Floor (Settings › Floor › Live Activities).
    var enabled: Bool { get }
    /// Running activities, by vote id, with the content each shows now.
    func running() -> [String: VoteActivityAttributes.ContentState]
    func start(_ attributes: VoteActivityAttributes, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async throws
    func update(voteId: String, _ content: VoteActivityAttributes.ContentState, staleAt: Date) async
    /// Shows the final, then the system removes it at `dismissAt` (or at once, if that has passed).
    func end(voteId: String, _ content: VoteActivityAttributes.ContentState, dismissAt: Date) async
}

/// Starts, updates and ends Live Activities from `/v1/live` while the app is open (round 8,
/// section A, "local start"). It polls only while the app is in the foreground — the app's
/// `scenePhase` starts and cancels ``run()`` — and never in the background: a vote that opens
/// while the app is closed reaches the phone by push-to-start (apps/worker/src/push.ts).
///
/// A vote involves you when one of your members sits in its chamber, or it is on a bill you follow
/// (the same rule as the worker's). Starting one needs the "Live Activities" switch (on by
/// default); updating and ending the ones already running never does, so turning it off does not
/// strand an activity.
@MainActor
public final class LiveActivityCoordinator {
    /// Who and what you follow, read fresh each poll.
    public struct Interest: Sendable {
        /// Your members, reps first, in your order.
        public var members: [Member]
        public var bills: Set<String>
        public var liveActivities: Bool

        public init(members: [Member], bills: Set<String>, liveActivities: Bool) {
            self.members = members
            self.bills = bills
            self.liveActivities = liveActivities
        }
    }

    /// `/v1/live` is cached at the edge for 5 s, so polling faster buys nothing.
    public static let interval: Duration = .seconds(5)
    /// Neither chamber sitting and nothing open: a vote cannot open within the minute.
    public static let idleInterval: Duration = .seconds(60)

    private let source: any LiveSource
    private let host: any ActivityHost
    private let interest: @MainActor () -> Interest
    private let now: () -> Date
    /// Votes already started this session, or seen running: one the user dismissed is not
    /// started again.
    private var started: Set<String> = []

    public init(
        source: any LiveSource, host: any ActivityHost, now: @escaping () -> Date = Date.init,
        interest: @escaping @MainActor () -> Interest
    ) {
        self.source = source
        self.host = host
        self.now = now
        self.interest = interest
    }

    /// Polls until the task is cancelled (the app leaves the foreground), as often as ``poll()`` says.
    public func run() async {
        while !Task.isCancelled {
            let wait = await poll()
            try? await Task.sleep(for: wait)
        }
    }

    /// Your members on a vote: those who sit in its chamber.
    static func members(on vote: Vote, of yours: [Member]) -> [Member] {
        yours.filter { $0.chamber == vote.chamber }
    }

    static func involves(_ live: LiveVote, _ interest: Interest) -> Bool {
        !members(on: live.vote, of: interest.members).isEmpty || live.billId.map(interest.bills.contains) == true
    }

    /// One pass: start what opened, update what changed, end what went final. Returns how long to
    /// wait before the next.
    @discardableResult
    public func poll() async -> Duration {
        let interest = interest()
        let running = host.running()
        let at = now()
        // Activities the worker started by push count as started too.
        started.formUnion(running.keys)
        let canStart = interest.liveActivities && host.enabled && (!interest.members.isEmpty || !interest.bills.isEmpty)
        // Nothing could start and nothing is running: no request at all.
        guard canStart || !running.isEmpty else { return Self.interval }
        guard let live = try? await source.liveNow() else { return Self.interval }

        if canStart {
            for vote in live.openVotes where running[vote.id] == nil && !started.contains(vote.id) && Self.involves(vote, interest) {
                let content = VoteActivityAttributes.ContentState(live: vote, members: Self.members(on: vote.vote, of: interest.members))
                do {
                    try await host.start(VoteActivityAttributes(live: vote), content, staleAt: at.addingTimeInterval(VoteActivityAttributes.staleAfter))
                    started.insert(vote.id)
                } catch {
                    // Too many activities, or Live Activities turned off since: try again next poll.
                }
            }
        }

        for (id, shown) in running {
            if let vote = live.votes.first(where: { $0.id == id }) {
                let members = Self.members(on: vote.vote, of: interest.members)
                if vote.vote.state == .final {
                    await finish(id, vote: vote, members: members, at: at)
                } else {
                    let content = VoteActivityAttributes.ContentState(live: vote, members: members)
                    if content != shown {
                        await host.update(voteId: id, content, staleAt: at.addingTimeInterval(VoteActivityAttributes.staleAfter))
                    }
                }
            } else {
                // Gone from /v1/live (final more than two hours ago, while the app was away): ask
                // for the vote itself, and end it if it is final.
                await finishGone(id, shown: shown, interest: interest, at: at)
            }
        }

        let sitting = live.chambers.contains(where: \.inSession)
        return sitting || !live.openVotes.isEmpty || !host.running().isEmpty ? Self.interval : Self.idleInterval
    }

    /// Ends with your members' positions. If they cannot be fetched the activity stays as it is and
    /// the next poll tries again, rather than ending on "not recorded yet".
    private func finish(_ id: String, vote: LiveVote, members: [Member], at: Date) async {
        let ids = Array(members.prefix(10).map(\.bioguideId))
        var positions: [MemberPosition] = []
        if !ids.isEmpty {
            guard let detail = try? await source.voteDetail(id: id, members: ids) else { return }
            positions = detail.positions
        }
        let content = VoteActivityAttributes.ContentState(live: vote, members: members, positions: positions)
        await host.end(voteId: id, content, dismissAt: Self.dismissal(vote, now: at))
    }

    private func finishGone(_ id: String, shown: VoteActivityAttributes.ContentState, interest: Interest, at: Date) async {
        let ids = Array(interest.members.prefix(10).map(\.bioguideId))
        guard let detail = try? await source.voteDetail(id: id, members: ids), detail.vote.state == .final else { return }
        let live = LiveVote(
            vote: detail.vote, openedAt: shown.openedAt, announcedAt: shown.calledAt, postedAt: nil, measure: detail.measure
        )
        let members = Self.members(on: detail.vote, of: interest.members)
        let content = VoteActivityAttributes.ContentState(live: live, members: members, positions: detail.positions)
        await host.end(voteId: id, content, dismissAt: at)
    }

    /// 15 minutes after the final was seen (`postedAt`), or from now when it was not timed.
    static func dismissal(_ vote: LiveVote, now: Date) -> Date {
        let finalAt = vote.postedAt.flatMap(Formats.instant) ?? now
        return max(now, finalAt.addingTimeInterval(VoteActivityAttributes.lingerAfterFinal))
    }
}
