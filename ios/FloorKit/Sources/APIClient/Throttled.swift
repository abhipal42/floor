import Foundation

/// How many requests a screen or the widget keeps in flight at once when it loads one record per
/// member. Six is URLSession's own per-host default; following thirty members should be thirty
/// requests six at a time, not thirty at once.
public let memberRequestConcurrency = 6

/// `transform` over every element, at most `limit` at a time, results in the input's order.
///
/// The first error cancels the rest and is rethrown, as a throwing task group does.
public func throttledMap<Element: Sendable, Result: Sendable>(
    _ elements: [Element],
    limit: Int = memberRequestConcurrency,
    _ transform: @escaping @Sendable (Element) async throws -> Result
) async throws -> [Result] {
    try await withThrowingTaskGroup(of: (Int, Result).self) { group in
        var results = [Result?](repeating: nil, count: elements.count)
        var next = 0
        let first = min(max(limit, 1), elements.count)
        while next < first {
            let index = next, element = elements[index]
            group.addTask { (index, try await transform(element)) }
            next += 1
        }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < elements.count {
                let index = next, element = elements[index]
                group.addTask { (index, try await transform(element)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
