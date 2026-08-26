/// A snapshot of whether a session aggregate should be shown or retired.
enum ClaudePermissionNotificationState: Equatable {
    /// Older records have no current PermissionRequest ownership metadata.
    case legacyUncorrelated
    /// At least one correlated permission or blocking tool still awaits input.
    case pending
    /// The current integration has no remaining permission owner.
    case settled
}
