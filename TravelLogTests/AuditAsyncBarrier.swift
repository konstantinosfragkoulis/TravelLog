import Foundation

/// Deterministic arrival barrier for regression tests. Tests explicitly
/// release held work, including cancelled workers, before awaiting completion.
actor AuditAsyncBarrier {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func arrive() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
    }

    func wait(until target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}
