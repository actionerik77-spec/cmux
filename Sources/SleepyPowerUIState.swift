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
    private var nextLockRequestID: UInt64 = 0
    private var activeLockRequestID: UInt64?

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
        activeLockRequestID = nil
        lockFailed = false
    }

    /// Captures the current session so an asynchronous lock result cannot
    /// update a later Sleepy Mode session.
    func currentSessionID() -> UUID {
        sessionID
    }

    /// Whether a Lock Mac request is currently awaiting confirmation.
    var isLockBusy: Bool {
        activeLockRequestID != nil
    }

    /// Starts one lock request and returns its session/request identity.
    /// Concurrent overlay buttons share this gate, so an older result cannot
    /// overwrite a newer request's outcome.
    func beginLockRequest() -> (sessionID: UUID, requestID: UInt64)? {
        guard activeLockRequestID == nil else { return nil }
        nextLockRequestID &+= 1
        activeLockRequestID = nextLockRequestID
        return (sessionID, nextLockRequestID)
    }

    /// Records a lock confirmation only when both the Sleepy session and the
    /// request identity are still current.
    func recordLockResult(
        _ confirmed: Bool,
        for attemptedSessionID: UUID,
        requestID: UInt64
    ) {
        guard attemptedSessionID == sessionID,
              activeLockRequestID == requestID else { return }
        activeLockRequestID = nil
        lockFailed = !confirmed
    }
}
