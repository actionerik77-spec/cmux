/// The correlation contract used by one Claude session's permission rows.
enum ClaudePermissionNotificationMode: String, Codable, Equatable {
    /// One row represents every concurrently pending permission in the session.
    case sessionAggregate
}
