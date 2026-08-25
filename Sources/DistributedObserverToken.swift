import Foundation

/// Retains a distributed-notification token until its owning async stream ends.
///
/// Foundation's observer protocol is not Sendable, but this wrapper only moves
/// the token to the stream termination callback so it can remove the observer;
/// it never reads or mutates token state across the callback boundary.
final class DistributedObserverToken: @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let token: any NSObjectProtocol

    init(center: DistributedNotificationCenter, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func remove() {
        center.removeObserver(token)
    }
}
