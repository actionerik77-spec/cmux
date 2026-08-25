import Foundation

struct MobileHostOrderedRequest: Sendable {
    let frameByteCount: Int
    let decodedRequest: Result<MobileHostRPCRequest, MobileHostRPCError>
}

struct MobileHostOrderedRequestQueue {
    private var requests: [MobileHostOrderedRequest] = []

    var isEmpty: Bool { requests.isEmpty }
    var frameByteCounts: [Int] { requests.map(\.frameByteCount) }

    mutating func enqueue(_ request: MobileHostOrderedRequest) {
        requests.append(request)
    }

    mutating func dequeue() -> MobileHostOrderedRequest? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }

    mutating func removeAll() {
        requests.removeAll()
    }
}

extension MobileHostRPCRequest {
    /// Whether this request can write terminal input and must therefore be
    /// handled in arrival order rather than on a concurrent response task.
    /// paste_image belongs here because its handler writes the materialized
    /// image path into the PTY; scroll and mouse belong here because their
    /// handlers emit mouse-report bytes when the terminal has mouse reporting
    /// active, and either could otherwise overtake earlier queued keystrokes.
    /// `mobile.chat.send` is included because attachment preparation suspends
    /// before it emits the same compound terminal write.
    var isOrderedTerminalInput: Bool {
        switch method {
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.mouse", "terminal.mouse",
             "mobile.chat.send", "mobile.chat.interrupt", "mobile.chat.answer":
            true
        default:
            false
        }
    }

    /// The per-surface ordering domain for an ordered terminal request.
    /// Requests without a surface selection share one conservative bucket.
    var orderedInputSurfaceKey: String {
        if method == "mobile.chat.send",
           let sessionID = params["session_id"] as? String {
            return "chat-session:" + sessionID
        }
        (params["surface_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Coordinates chat writes with per-surface terminal-input workers.
///
/// Normal terminal requests on different surfaces may proceed concurrently.
/// A chat send/answer/interrupt waits for all active terminal writes, then
/// blocks new terminal writes until its own compound operation completes.
actor MobileHostChatOrderingBarrier {
    private var activeNormalRequests = 0
    private var chatIsActive = false
    private var waitingChatRequests = 0
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []
    private var chatWaiters: [CheckedContinuation<Void, Never>] = []

    func enter(isChat: Bool) async {
        if isChat {
            guard !chatIsActive,
                  activeNormalRequests == 0,
                  chatWaiters.isEmpty else {
                waitingChatRequests += 1
                await withCheckedContinuation { chatWaiters.append($0) }
                return
            }
            chatIsActive = true
            return
        }

        guard !chatIsActive, waitingChatRequests == 0 else {
            await withCheckedContinuation { normalWaiters.append($0) }
            return
        }
        activeNormalRequests += 1
    }

    func leave(isChat: Bool) {
        if isChat {
            chatIsActive = false
        } else {
            activeNormalRequests = max(0, activeNormalRequests - 1)
        }
        drainWaiters()
    }

    private func drainWaiters() {
        guard !chatIsActive else { return }
        if activeNormalRequests == 0, !chatWaiters.isEmpty {
            waitingChatRequests = max(0, waitingChatRequests - 1)
            chatIsActive = true
            chatWaiters.removeFirst().resume()
            return
        }
        guard waitingChatRequests == 0 else { return }
        while !normalWaiters.isEmpty {
            activeNormalRequests += 1
            normalWaiters.removeFirst().resume()
        }
    }
}
