import Foundation
import Testing
@testable import Onboarding

/// `PendingAnswer` is the part of `CoreLocationProvider` that decides when a caller gets an answer:
/// the system's, or the timeout's. Tested on its own because the system half needs a device.
@MainActor
@Suite("Location provider's pending answers")
struct PendingAnswerTests {
    /// A second tap while the first is pending joins it: one system request, two answers.
    @Test func aSecondWaiterJoinsTheFirstAndTheRequestStartsOnce() async throws {
        let pending = PendingAnswer<Int>()
        var starts = 0
        let first = Task { try await pending.wait(timeout: .seconds(60), fallback: .success(-1)) { starts += 1 } }
        let second = Task { try await pending.wait(timeout: .seconds(60), fallback: .success(-1)) { starts += 1 } }
        while !pending.isWaiting { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        pending.finish(.success(7))

        #expect(try await first.value == 7)
        #expect(try await second.value == 7)
        #expect(starts == 1)
        #expect(!pending.isWaiting)
    }

    /// Nothing from the system: the timeout answers, so a caller can never hang.
    @Test func theTimeoutAnswersWhenTheSystemNeverDoes() async throws {
        let pending = PendingAnswer<String>()
        let answer = try await pending.wait(timeout: .milliseconds(20), fallback: .success("denied")) {}
        #expect(answer == "denied")
        #expect(!pending.isWaiting)
    }

    @Test func aTimeoutFailureIsThrown() async {
        let pending = PendingAnswer<Int>()
        await #expect(throws: LocationFailure.timedOut) {
            try await pending.wait(timeout: .milliseconds(20), fallback: .failure(LocationFailure.timedOut)) {}
        }
    }

    /// A late `didFailWithError` after the timeout already answered changes nothing, and does not
    /// answer the *next* request either.
    @Test func aLateAnswerIsIgnoredAndTheOldTimeoutCannotAnswerTheNextRequest() async throws {
        let pending = PendingAnswer<Int>()
        let timedOut = try await pending.wait(timeout: .milliseconds(20), fallback: .success(-1)) {}
        #expect(timedOut == -1)
        pending.finish(.success(99)) // late: nobody waiting

        // The next request has a long timeout; only its own answer may end it.
        let next = Task { try await pending.wait(timeout: .seconds(60), fallback: .success(-2)) {} }
        while !pending.isWaiting { await Task.yield() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(pending.isWaiting)
        pending.finish(.success(3))
        #expect(try await next.value == 3)
    }

    /// An answer before the timeout disarms it: the waiter gets the system's answer, not the fallback.
    @Test func theSystemsAnswerBeatsTheTimeout() async throws {
        let pending = PendingAnswer<Int>()
        let task = Task { try await pending.wait(timeout: .milliseconds(200), fallback: .success(-1)) {} }
        while !pending.isWaiting { await Task.yield() }
        pending.finish(.success(1))
        #expect(try await task.value == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!pending.isWaiting)
    }
}
