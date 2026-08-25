import Foundation
import Observation

/// Shared, observable Low Power UI state. Sleepy Mode creates one overlay window
/// per display; injecting a single instance into every `SleepyFaceView` keeps
/// their labels in sync and makes each button compute its next action from one
/// authoritative value (instead of per-window `@State` that goes stale when
/// another display toggles).
@MainActor
@Observable
final class SleepyPowerUIState {
    private var sessionID = UUID()

    /// Whether Low Power Mode is currently on (last re-read from the system).
    var isOn = false
    /// Whether a privileged toggle is in flight (disables the button).
    var isBusy = false
    /// True after a Lock Mac attempt reported failure, so the overlay tells the
    /// user instead of silently staying unlocked (the failure mode of
    /// https://github.com/manaflow-ai/cmux/issues/9730). Cleared when a later
    /// attempt confirms the lock or a new Sleepy Mode session begins.
    var lockFailed = false

    /// Starts a fresh overlay session and clears transient lock feedback.
    func beginSession() {
        sessionID = UUID()
        lockFailed = false
    }

    /// Captures the current session so an asynchronous lock result cannot
    /// update a later Sleepy Mode session.
    func currentSessionID() -> UUID {
        sessionID
    }

    /// Records whether a lock request was issued, only for the active session.
    func recordLockResult(_ requestWasIssued: Bool, for attemptedSessionID: UUID) {
        guard attemptedSessionID == sessionID else { return }
        lockFailed = !requestWasIssued
    }
}
