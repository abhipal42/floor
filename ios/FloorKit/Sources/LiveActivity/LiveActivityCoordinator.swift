import APIClient
import Foundation
import Models

/// Where the coordinator reads the floor from: the API in the app, a stub in tests.
public protocol LiveSource: Sendable {
    func liveNow() async throws -> Live
    func positions(voteId: String, members: [String]) async throws -> [MemberPosition]
}

extension FloorAPI: LiveSource {
    public func liveNow() async throws -> Live { try await live(since: 120) }

    public func positions(voteId: String, members: [String]) async throws -> [MemberPosition] {
        try await vote(id: voteId, members: members).positions
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
/// `scenePhase` starts and cancels ``run(every:)`` — and never in the background: a vote that opens
/// while the app is closed reaches the phone by push-to-start (apps/worker/src/push.ts).
///
/// A vote involves you when one of your members sits in its chamber, or it is on a bill you follow
/// (the same rule as the worker's). Starting one needs "A vote opened" on; updating and ending the
/// ones already running never does, so turning the switch off does not strand an activity.
@MainActor
public final class LiveActivityCoordinator {
    /// Who and what you follow, read fresh each poll.
    public struct Interest: Sendable {
        /// Your members, reps first, in your order.
        public var members: [Member]
        public var bills: Set<String>
        public var voteOpened: Bool

        public init(members: [Member], bills: Set<String>, voteOpened: Bool) {
            self.members = members
            self.bills = bills
            self.voteOpened = voteOpened
        }
    }

    /// `/v1/live` is cached at the edge for 5 s, so polling faster buys nothing.
    public static let interval: Duration = .seconds(5)

    private let source: any LiveSource
    private let host: any ActivityHost
    private let interest: @MainActor () -> Interest
    private let now: () -> Date
    /// Votes already started this session: one the user dismissed is not started again.
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

    /// Polls until the task is cancelled (the app leaves the foreground).
    public func run(every interval: Duration = LiveActivityCoordinator.interval) async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: interval)
        }
    }

    /// Your members on a vote: those who sit in its chamber.
    static func members(on vote: Vote, of yours: [Member]) -> [Member] {
        yours.filter { $0.chamber == vote.chamber }
    }

    static func involves(_ live: LiveVote, _ interest: Interest) -> Bool {
        !members(on: live.vote, of: interest.members).isEmpty || live.billId.map(interest.bills.contains) == true
    }

    /// One pass: start what opened, update what changed, end what went final.
    public func poll() async {
        guard let live = try? await source.liveNow() else { return }
        let interest = interest()
        let running = host.running()
        let at = now()

        if interest.voteOpened, host.enabled {
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
            guard let vote = live.votes.first(where: { $0.id == id }) else { continue }
            let members = Self.members(on: vote.vote, of: interest.members)
            if vote.vote.state == .final {
                let ids = members.prefix(10).map(\.bioguideId)
                let positions = ids.isEmpty ? [] : ((try? await source.positions(voteId: id, members: Array(ids))) ?? [])
                let content = VoteActivityAttributes.ContentState(live: vote, members: members, positions: positions)
                await host.end(voteId: id, content, dismissAt: Self.dismissal(vote, now: at))
            } else {
                let content = VoteActivityAttributes.ContentState(live: vote, members: members)
                if content != shown {
                    await host.update(voteId: id, content, staleAt: at.addingTimeInterval(VoteActivityAttributes.staleAfter))
                }
            }
        }
    }

    /// 15 minutes after the final was seen (`postedAt`), or from now when it was not timed.
    static func dismissal(_ vote: LiveVote, now: Date) -> Date {
        let finalAt = vote.postedAt.flatMap(Formats.instant) ?? now
        return max(now, finalAt.addingTimeInterval(VoteActivityAttributes.lingerAfterFinal))
    }
}
