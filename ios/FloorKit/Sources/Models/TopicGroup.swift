import Foundation

/// The colour family a measure's story card is drawn in, from its CRS policy area.
///
/// Eight families for the 32 policy areas, so a feed reads as a few colours rather than thirty-two.
/// ``table`` is the one place the areas are mapped; Android's `TopicGroup.TABLE` is the same table,
/// and `TopicGroupTests` holds every area in ``Topic/names`` to a family.
public enum TopicGroup: String, CaseIterable, Sendable, Hashable {
    case defense, money, courts, health, land, rights, gov, other

    /// Every CRS policy area to its family. An area not here (Private Legislation, a renamed one)
    /// is ``other``.
    public static let table: [String: TopicGroup] = [
        "Armed Forces and National Security": .defense,
        "International Affairs": .defense,
        "Emergency Management": .defense,
        "Commerce": .money,
        "Economics and Public Finance": .money,
        "Finance and Financial Sector": .money,
        "Foreign Trade and International Finance": .money,
        "Labor and Employment": .money,
        "Taxation": .money,
        "Crime and Law Enforcement": .courts,
        "Law": .courts,
        "Education": .health,
        "Families": .health,
        "Housing and Community Development": .health,
        "Health": .health,
        "Social Welfare": .health,
        "Agriculture and Food": .land,
        "Animals": .land,
        "Energy": .land,
        "Environmental Protection": .land,
        "Public Lands and Natural Resources": .land,
        "Transportation and Public Works": .land,
        "Water Resources Development": .land,
        "Arts, Culture, Religion": .rights,
        "Civil Rights and Liberties, Minority Issues": .rights,
        "Immigration": .rights,
        "Native Americans": .rights,
        "Congress": .gov,
        "Government Operations and Politics": .gov,
        "Science, Technology, Communications": .other,
        "Social Sciences and History": .other,
        "Sports and Recreation": .other,
    ]

    /// The family's name, as the Bills tab's section headers and the Week tab's fast-track tiles
    /// print it: `Defense`, `Money`. The same words as Android's `TopicGroup.label`.
    public var name: String {
        switch self {
        case .defense: "Defense"
        case .money: "Money"
        case .courts: "Courts"
        case .health: "Health"
        case .land: "Land"
        case .rights: "Rights"
        case .gov: "Government"
        case .other: "Other"
        }
    }

    public static func of(policyArea: String?) -> TopicGroup {
        policyArea.flatMap { table[$0] } ?? .other
    }

    /// A bill by its policy area; a nomination to a court (its position names a judge, a court or a justice)
    /// as ``courts``, any other nomination as ``gov``; no measure at all as ``other``.
    public static func of(_ measure: MeasureSummary?) -> TopicGroup {
        guard let measure else { return .other }
        switch measure.kind {
        case .bill: return of(policyArea: measure.policyArea)
        case .nomination:
            let post = measure.position ?? ""
            return post.range(of: #"judge|court|justice"#, options: [.regularExpression, .caseInsensitive]) != nil ? .courts : .gov
        }
    }
}
