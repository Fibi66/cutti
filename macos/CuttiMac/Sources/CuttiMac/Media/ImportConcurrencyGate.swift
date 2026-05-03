import Foundation

/// Bounds the number of concurrent proxy transcodes to a fixed limit so a
/// drag-drop of many large files doesn't saturate Media Engine, disk and
/// memory all at once. Cooperates with structured cancellation: if a queued
/// import's `Task` is cancelled while waiting in `withPermit`, the waiter
/// is removed from the queue and `withPermit` rethrows `CancellationError`
/// instead of letting it sit forever.
actor ImportConcurrencyGate {

    private let limit: Int
    private var inFlight = 0

    /// Each waiter has its own continuation and a UUID so cancellations can
    /// remove a specific entry without scanning by identity.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit >= 1, "ImportConcurrencyGate limit must be >= 1")
        self.limit = limit
    }

    /// Acquires a permit, runs `body`, releases the permit. If the calling
    /// `Task` is cancelled while waiting OR while `body` is running, the
    /// permit is still released cleanly and the error is rethrown.
    func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        if inFlight < limit {
            inFlight += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: ())
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}
