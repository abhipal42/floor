import Foundation

/// What a phone wants alerts about: one member, bill or topic and its "How they voted" switch
/// (`PUT /v1/devices`). A followed item whose switch is off is still sent, because "A vote opened"
/// covers votes involving any of your members and bills, not only the ones whose result alerts you.
/// A topic alerts only for its bills' steps, and only with ``BillAlerts/throughTopics`` on; its
/// `howVoted` is ignored.
public struct DeviceSubscription: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case member, bill, topic
    }

    public var kind: Kind
    /// A Bioguide ID, a bill id (`119-hr-1013`), or a topic's exact name (`Health`).
    public var id: String
    public var howVoted: Bool

    public init(kind: Kind, id: String, howVoted: Bool) {
        self.kind = kind
        self.id = id
        self.howVoted = howVoted
    }
}

/// The "Bills you follow" switches on the Alerts screen: one per step on the road to law.
public struct BillAlerts: Codable, Sendable, Hashable {
    /// "Scheduled for the floor".
    public var floorScheduled: Bool
    /// "Passes or fails a chamber, with the score".
    public var chamberVote: Bool
    /// "Sent to the President".
    public var toPresident: Bool
    /// "Becomes law or is vetoed".
    public var lawOrVeto: Bool
    /// "Committee action" (busy).
    public var committee: Bool
    /// "Through topics too": bills in a followed topic alert as if followed.
    public var throughTopics: Bool

    public init(floorScheduled: Bool, chamberVote: Bool, toPresident: Bool, lawOrVeto: Bool, committee: Bool, throughTopics: Bool) {
        self.floorScheduled = floorScheduled
        self.chamberVote = chamberVote
        self.toPresident = toPresident
        self.lawOrVeto = lawOrVeto
        self.committee = committee
        self.throughTopics = throughTopics
    }

    /// The locked design's defaults, and the API's when a registration leaves them out.
    public static let defaults = BillAlerts(
        floorScheduled: true, chamberVote: true, toPresident: true, lawOrVeto: true, committee: false, throughTopics: false
    )
}

/// `PUT /v1/devices`: the whole registration each time. No account and no address: tokens, one
/// switch, and public ids. The phone is identified by its own random key in the `Authorization`
/// header, never by anything in here.
public struct DeviceRegistration: Codable, Sendable, Hashable {
    public enum Environment: String, Codable, Sendable, Hashable, CaseIterable {
        case sandbox, production
    }

    /// The APNs token for alerts, as hex; nil without notification permission.
    public var apnsToken: String?
    public var apnsEnvironment: Environment
    /// ActivityKit's push-to-start token, as hex (iOS 17.2+).
    public var pushToStartToken: String?
    /// "A vote opened": the push alert.
    public var voteOpened: Bool
    /// "Live Activities": start one, silently, when a vote involving these opens.
    public var liveActivities: Bool
    public var subscriptions: [DeviceSubscription]
    /// "Bills you follow": which steps of a followed bill alert.
    public var billAlerts: BillAlerts

    public init(
        apnsToken: String?, apnsEnvironment: Environment, pushToStartToken: String?, voteOpened: Bool,
        liveActivities: Bool, subscriptions: [DeviceSubscription], billAlerts: BillAlerts = .defaults
    ) {
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.pushToStartToken = pushToStartToken
        self.voteOpened = voteOpened
        self.liveActivities = liveActivities
        self.subscriptions = subscriptions
        self.billAlerts = billAlerts
    }

    // Encoded with explicit nulls: the route requires every key, and a missing token means "none".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apnsToken, forKey: .apnsToken)
        try container.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(pushToStartToken, forKey: .pushToStartToken)
        try container.encode(voteOpened, forKey: .voteOpened)
        try container.encode(liveActivities, forKey: .liveActivities)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(billAlerts, forKey: .billAlerts)
    }
}

/// The answer to `PUT /v1/devices`.
public struct DeviceRegistered: Codable, Sendable, Hashable {
    public var subscriptions: Int
    public var voteOpened: Bool
    /// The switches the API stored.
    public var billAlerts: BillAlerts

    public init(subscriptions: Int, voteOpened: Bool, billAlerts: BillAlerts = .defaults) {
        self.subscriptions = subscriptions
        self.voteOpened = voteOpened
        self.billAlerts = billAlerts
    }

    // An API from before the switches answered without them: those were the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decode(Int.self, forKey: .subscriptions)
        voteOpened = try container.decode(Bool.self, forKey: .voteOpened)
        billAlerts = try container.decodeIfPresent(BillAlerts.self, forKey: .billAlerts) ?? .defaults
    }
}

/// `GET /v1/bills/{id}/share`: what the share sheet sends for a bill.
public struct BillShare: Codable, Sendable, Hashable {
    /// `https://floor-web-seven.vercel.app/bill/119/hr/5267`: a page that works without the app, and opens it where installed.
    public var url: String
    /// The neutral line to send with it.
    public var text: String
    /// The preview card's kicker, `H.R. 5267 · ON THE FLOOR THIS WEEK`.
    public var kicker: String

    public init(url: String, text: String, kicker: String) {
        self.url = url
        self.text = text
        self.kicker = kicker
    }
}

/// `PUT /v1/devices/activities/{voteId}`: a running Live Activity's push token, as hex.
public struct ActivityToken: Codable, Sendable, Hashable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

public extension Data {
    /// An APNs token as the API takes it: lower-case hex.
    var hexToken: String { map { String(format: "%02x", $0) }.joined() }
}
