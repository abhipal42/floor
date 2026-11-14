import Foundation

/// What a phone wants alerts about: one member or bill and its "How they voted" switch
/// (`PUT /v1/devices`). A followed item whose switch is off is still sent, because "A vote opened"
/// covers votes involving any of your members and bills, not only the ones whose result alerts you.
public struct DeviceSubscription: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case member, bill
    }

    public var kind: Kind
    /// A Bioguide ID, or a bill id (`119-hr-1013`).
    public var id: String
    public var howVoted: Bool

    public init(kind: Kind, id: String, howVoted: Bool) {
        self.kind = kind
        self.id = id
        self.howVoted = howVoted
    }
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
    /// "A vote opened".
    public var voteOpened: Bool
    public var subscriptions: [DeviceSubscription]

    public init(
        apnsToken: String?, apnsEnvironment: Environment, pushToStartToken: String?, voteOpened: Bool,
        subscriptions: [DeviceSubscription]
    ) {
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.pushToStartToken = pushToStartToken
        self.voteOpened = voteOpened
        self.subscriptions = subscriptions
    }

    // Encoded with explicit nulls: the route requires every key, and a missing token means "none".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apnsToken, forKey: .apnsToken)
        try container.encode(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(pushToStartToken, forKey: .pushToStartToken)
        try container.encode(voteOpened, forKey: .voteOpened)
        try container.encode(subscriptions, forKey: .subscriptions)
    }
}

/// The answer to `PUT /v1/devices`.
public struct DeviceRegistered: Codable, Sendable, Hashable {
    public var subscriptions: Int
    public var voteOpened: Bool

    public init(subscriptions: Int, voteOpened: Bool) {
        self.subscriptions = subscriptions
        self.voteOpened = voteOpened
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
