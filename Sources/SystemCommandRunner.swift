import Darwin
import CoreGraphics
import Foundation
import Security

/// Real command runner. Blocking work happens on background queues and is
/// surfaced through async APIs, so awaiting callers (including MainActor UI)
/// suspend rather than block. Privileged work is serialized on a private queue
/// that also owns the `AuthorizationRef`, so there is no shared mutable global
/// and the admin prompt is not guarded by a lock held elsewhere.
/// `AuthorizationExecuteWithPrivileges` is Swift-unavailable, so it's loaded via
/// `dlsym` (deprecated but present); macOS caches the admin credential (~5 min)
/// so back-to-back toggles don't re-prompt.
final class SystemCommandRunner: SleepyCommandRunning, @unchecked Sendable {
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef?,
        UnsafePointer<CChar>?,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let authExec: AuthExecFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: AuthExecFn.self)
    }()

    private typealias LockScreenFn = @convention(c) () -> Void

    /// `SACLockScreenImmediate` from `login.framework` — the call behind the
    /// Apple menu's "Lock Screen" (⌃⌘Q), predating the macOS 14 deployment
    /// floor. It replaces shelling out to the `CGSession` binary, which macOS
    /// 26 removed together with `User.menu`
    /// (https://github.com/manaflow-ai/cmux/issues/9730). Resolved via `dlsym`
    /// like `authExec` above, so no private symbol is linked and a macOS that
    /// drops it degrades to a reported failure, not a crash. The private API has
    /// no documented return contract; established clients declare it `void`, so
    /// cmux verifies the resulting public lock signal instead of interpreting
    /// an undocumented return register as status.
    private static let lockScreenImmediate: LockScreenFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    private let privilegedQueue = DispatchQueue(label: "com.cmux.sleepyMode.privileged")
    private var authorization: AuthorizationRef?  // accessed only on privilegedQueue

    func run(_ tool: String, _ args: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                continuation.resume()
            }
        }
    }

    func capture(_ tool: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Asks loginwindow to lock without blocking the caller's actor. Returns
    /// only after the public session state or the request-local lock notification
    /// confirms the transition. Cancellation (when Sleepy Mode exits) ends an
    /// unconfirmed request without claiming that the Mac was locked.
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool {
        guard let lockScreenImmediate = Self.lockScreenImmediate else {
            return false
        }

        // Register before invoking loginwindow. The distributed event is the
        // authoritative completion signal on hosts that do not expose the
        // `CGSSessionScreenIsLocked` dictionary key, and AsyncStream buffers it
        // if the IPC returns before the consumer starts awaiting.
        let lockNotifications = Self.lockScreenNotifications()
        guard !Task.isCancelled else {
            lockNotifications.continuation.finish()
            return false
        }
        lockScreenImmediate()
        if Self.isScreenLocked() {
            lockNotifications.continuation.finish()
            return true
        }
        let confirmed = await Self.waitForLockNotification(lockNotifications.stream)
        lockNotifications.continuation.finish()
        return confirmed
    }

    private static func lockScreenNotifications() -> (
        stream: AsyncStream<Void>,
        continuation: AsyncStream<Void>.Continuation
    ) {
        let center = DistributedNotificationCenter.default()
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let token = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield(())
        }
        let tokenBox = DistributedObserverToken(center: center, token: token)
        continuation.onTermination = { _ in tokenBox.remove() }
        return (stream, continuation)
    }

    private static func waitForLockNotification(
        _ notifications: AsyncStream<Void>
    ) async -> Bool {
        // AsyncStream's iterator observes task cancellation and finishes the
        // continuation, which removes the distributed observer through
        // `onTermination`. There is intentionally no polling/deadline here:
        // loginwindow may publish the event after an arbitrary IPC delay, while
        // the owning Sleepy Mode task provides the lifecycle cancellation bound.
        for await _ in notifications {
            return true
        }
        return false
    }

    private static func screenLockState() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    private static func isScreenLocked() -> Bool {
        screenLockState() == true
    }

    @discardableResult
    func runPrivileged(_ tool: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            privilegedQueue.async {
                continuation.resume(returning: self.runPrivilegedOnQueue(tool, args))
            }
        }
    }

    // Runs only on privilegedQueue, which serializes access to `authorization`.
    private func runPrivilegedOnQueue(_ tool: String, _ args: [String]) -> Bool {
        guard let authExec = Self.authExec, let authorization = authorizationRefOnQueue() else { return false }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let status = tool.withCString { toolPtr -> OSStatus in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                authExec(authorization, toolPtr, 0, buffer.baseAddress, &pipe)
            }
        }
        // Drain to EOF so we block (on this background queue) until the tool
        // exits and callers can re-read accurate state.
        if let pipe {
            var line = [CChar](repeating: 0, count: 256)
            while fgets(&line, 256, pipe) != nil {}
            fclose(pipe)
        }
        return status == errAuthorizationSuccess
    }

    private func authorizationRefOnQueue() -> AuthorizationRef? {
        if let authorization { return authorization }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }
        authorization = ref
        return ref
    }
}
