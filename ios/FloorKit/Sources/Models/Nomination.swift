import Foundation

/// `GET /v1/nominations/{id}`
public struct Nomination: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var congress: Int
    public var number: Int
    /// 0 unless the Senate split the nomination into parts.
    public var part: Int
    /// As the Senate cites it on the roll call, e.g. `PN1093-3`.
    public var citation: String
    /// nil for military nominations, which promote officers in bulk and name nobody. Fall back to
    /// ``positionTitle`` and ``organization``.
    public var nomineeName: String?
    public var positionTitle: String?
    public var organization: String?
    /// Congress.gov's full sentence, including the "vice ..." clause.
    public var description: String?
    public var nomineeCount: Int?
    public var isMilitary: Bool
    /// Calendar day, `YYYY-MM-DD`.
    public var receivedOn: String?
    public var latestAction: LatestAction?
    public var votes: [Vote]

    public init(
        id: String, congress: Int, number: Int, part: Int, citation: String, nomineeName: String?,
        positionTitle: String?, organization: String?, description: String?, nomineeCount: Int?,
        isMilitary: Bool, receivedOn: String?, latestAction: LatestAction?, votes: [Vote]
    ) {
        self.id = id
        self.congress = congress
        self.number = number
        self.part = part
        self.citation = citation
        self.nomineeName = nomineeName
        self.positionTitle = positionTitle
        self.organization = organization
        self.description = description
        self.nomineeCount = nomineeCount
        self.isMilitary = isMilitary
        self.receivedOn = receivedOn
        self.latestAction = latestAction
        self.votes = votes
    }

    /// Who or what the vote is on: the nominee's name, or the post itself for a military
    /// nomination, which names no one.
    public var displayName: String {
        if let nomineeName { return nomineeName }
        return [positionTitle, organization].compactMap(\.self).joined(separator: ", ")
    }

    public var receivedOnDay: Date? { receivedOn.flatMap(Formats.day) }
}
