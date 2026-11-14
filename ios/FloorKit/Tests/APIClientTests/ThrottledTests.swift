import Foundation
import Testing
@testable import APIClient

/// Counts how many transforms are running at once.
private actor Gauge {
    private(set) var running = 0
    private(set) var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() { running -= 1 }
}

private struct Boom: Error {}

@Suite("Throttled requests")
struct ThrottledTests {
    /// Following thirty members is thirty requests, six at a time, answered in the order asked.
    @Test func runsAtMostSixAtOnceAndKeepsTheOrder() async throws {
        let gauge = Gauge()
        let results = try await throttledMap(Array(0..<30)) { n in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...10)))
            await gauge.leave()
            return n * 2
        }
        #expect(results == (0..<30).map { $0 * 2 })
        let peak = await gauge.peak
        #expect(peak <= memberRequestConcurrency)
        #expect(peak > 1)
        #expect(memberRequestConcurrency == 6)
    }

    @Test func anEmptyListIsNoRequests() async throws {
        #expect(try await throttledMap([Int]()) { $0 }.isEmpty)
    }

    @Test func oneFailureFailsTheWhole() async {
        await #expect(throws: Boom.self) {
            _ = try await throttledMap(Array(0..<10)) { n in
                if n == 7 { throw Boom() }
                return n
            }
        }
    }
}
