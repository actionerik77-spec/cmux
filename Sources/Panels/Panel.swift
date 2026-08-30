import Foundation
import Combine
import AppKit

/// Type of panel content
public enum PanelType: String, Codable, CaseIterable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview = "filepreview"
    case rightSidebarTool
    case customSidebar
    case simulator
    case agentSession
    case project
    case extensionBrowser
    case workspaceTodo
    case notifications
    case cloudVMLoading
    case mobilePairing
    case accountSignIn

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let type = Self(rawValue: rawValue) {
            self = type
            return
        }
        if rawValue.lowercased() == Self.filePreview.rawValue {
            self = .filePreview
            return
        }
        if rawValue.lowercased() == Self.rightSidebarTool.rawValue.lowercased() {
            self = .rightSidebarTool
            return
        }
        if rawValue.lowercased() == Self.customSidebar.rawValue.lowercased() {
            self = .customSidebar
            return
        }
        if rawValue.lowercased() == Self.agentSession.rawValue.lowercased() {
            self = .agentSession
            return
        }
        if rawValue.lowercased() == Self.workspaceTodo.rawValue.lowercased() {
            self = .workspaceTodo
            return
        }
        if rawValue.lowercased() == Self.notifications.rawValue.lowercased() {
            self = .notifications
            return
        }
        if rawValue.lowercased() == Self.cloudVMLoading.rawValue.lowercased() {
            self = .cloudVMLoading
            return
        }
        if rawValue.lowercased() == Self.mobilePairing.rawValue.lowercased() {
            self = .mobilePairing
            return
        }
        if rawValue.lowercased() == Self.accountSignIn.rawValue.lowercased() {
            self = .accountSignIn
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unknown panel type: \(rawValue)"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
    case textBoxInput
}

public enum BrowserPanelFocusIntent: Equatable {
    case webView
    case addressBar
    case findField
}

public enum FilePreviewPanelFocusIntent: Hashable {
    case textEditor
    case pdfCanvas
    case pdfThumbnails
    case pdfOutline
    case imageCanvas
    case mediaPlayer
    case quickLook
}

public enum ProjectPanelFocusIntent: Hashable {
    case navigator
    case detail
}

public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
    case filePreview(FilePreviewPanelFocusIntent)
    case project(ProjectPanelFocusIntent)
}

public enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    case navigation
    case userInitiated
    case notificationArrival
    case notificationDismiss
    case unreadIndicatorDismiss
    case debug
}

/// The built-in attention color used when no configured override is valid.
enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case notificationBlue

    var strokeColor: NSColor {
        switch self {
        case .notificationBlue:
            return .systemBlue
        }
    }
}

struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    let accent: WorkspaceAttentionFlashAccent
    let glowOpacity: Double
    let glowRadius: CGFloat
}

struct WorkspaceAttentionPersistentState: Equatable, Sendable {
    var unreadPanelIDs: Set<UUID> = []
    var focusedReadPanelID: UUID?
    var manualUnreadPanelIDs: Set<UUID> = []

    var indicatorPanelIDs: Set<UUID> {
        var ids = unreadPanelIDs.union(manualUnreadPanelIDs)
        if let focusedReadPanelID {
            ids.insert(focusedReadPanelID)
        }
        return ids
    }

    func hasCompetingIndicator(for panelID: UUID) -> Bool {
        indicatorPanelIDs.contains(where: { $0 != panelID })
    }
}

struct WorkspaceAttentionFlashDecision: Equatable, Sendable {
    let panelID: UUID
    let reason: WorkspaceAttentionFlashReason
    let isAllowed: Bool
}

enum WorkspaceAttentionCoordinator {
    static let notificationRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.35,
        glowRadius: 3
    )

    static let flashRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.6,
        glowRadius: 6
    )

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation, .userInitiated, .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return flashRingStyle
        }
    }

    static func decideFlash(
        targetPanelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        persistentState: WorkspaceAttentionPersistentState
    ) -> WorkspaceAttentionFlashDecision {
        let isAllowed: Bool
        switch reason {
        case .navigation:
            isAllowed = !persistentState.hasCompetingIndicator(for: targetPanelID)
        case .userInitiated, .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            isAllowed = true
        }

        return WorkspaceAttentionFlashDecision(
            panelID: targetPanelID,
            reason: reason,
            isAllowed: isAllowed
        )
    }
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

enum PanelOverlayRingMetrics {
    static let inset: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    static let lineWidth: CGFloat = 2.5

    static func pathRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }
}

struct WorkspaceAttentionOrbitBand: Equatable {
    let length: CGFloat
    let startDistanceBehindHead: CGFloat
    let opacity: CGFloat
    let lineWidth: CGFloat
    let highlightMix: CGFloat
    let glowRadius: CGFloat
    let glowOpacity: CGFloat
    let usesRoundCaps: Bool
}

struct WorkspaceAttentionOrbitGeometry: Equatable {
    let pathRect: CGRect
    let cornerRadius: CGFloat
    let perimeter: CGFloat
    let headLength: CGFloat
    let tailLength: CGFloat
    let tailBands: [WorkspaceAttentionOrbitBand]
    let head: WorkspaceAttentionOrbitBand
}

enum WorkspaceAttentionOrbitPattern {
    static let revolutionDuration: TimeInterval = 3.6
    static let baseLineWidth: CGFloat = 1.25
    static let baseOpacity: CGFloat = 0.42
    static let baseGlowRadius: CGFloat = 1.5
    static let baseGlowOpacity: CGFloat = 0.14
    static let reducedMotionLineWidth: CGFloat = PanelOverlayRingMetrics.lineWidth
    static let reducedMotionOpacity: CGFloat = 0.62
    static let reducedMotionGlowRadius: CGFloat = 2
    static let reducedMotionGlowOpacity: CGFloat = 0.18
    static let tailBandCount = 12

    private struct TailStop {
        let position: CGFloat
        let opacity: CGFloat
        let lineWidth: CGFloat
        let highlightMix: CGFloat
    }

    private static let tailStops: [TailStop] = [
        TailStop(position: 0, opacity: 0, lineWidth: 1, highlightMix: 0),
        TailStop(position: 0.18, opacity: 0.08, lineWidth: 1.1, highlightMix: 0),
        TailStop(position: 0.42, opacity: 0.22, lineWidth: 1.4, highlightMix: 0),
        TailStop(position: 0.66, opacity: 0.44, lineWidth: 1.8, highlightMix: 0),
        TailStop(position: 0.84, opacity: 0.66, lineWidth: 2.2, highlightMix: 0.10),
        TailStop(position: 1, opacity: 0.86, lineWidth: 2.5, highlightMix: 0.22),
    ]

    static func geometry(in bounds: CGRect) -> WorkspaceAttentionOrbitGeometry? {
        let pathRect = PanelOverlayRingMetrics.pathRect(in: bounds)
        guard pathRect.width > 0, pathRect.height > 0 else { return nil }
        let radius = min(
            PanelOverlayRingMetrics.cornerRadius,
            pathRect.width / 2,
            pathRect.height / 2
        )
        let perimeter =
            2 * (pathRect.width + pathRect.height - 4 * radius) +
            2 * .pi * radius
        guard perimeter > 0 else { return nil }

        let headLength = min(
            min(24, max(14, perimeter * 0.010)),
            perimeter * 0.03
        )
        let tailLength = min(
            min(240, max(120, perimeter * 0.075)),
            perimeter * 0.18
        )
        let bandLength = tailLength / CGFloat(tailBandCount)
        let tailBands = (0..<tailBandCount).map { index in
            let style = interpolatedTailStyle(
                at: (CGFloat(index) + 0.5) / CGFloat(tailBandCount)
            )
            return WorkspaceAttentionOrbitBand(
                length: bandLength,
                startDistanceBehindHead: headLength + tailLength - CGFloat(index) * bandLength,
                opacity: style.opacity,
                lineWidth: style.lineWidth,
                highlightMix: style.highlightMix,
                glowRadius: 2,
                glowOpacity: 0.24 * style.opacity,
                usesRoundCaps: false
            )
        }
        let head = WorkspaceAttentionOrbitBand(
            length: headLength,
            startDistanceBehindHead: headLength,
            opacity: 1,
            lineWidth: PanelOverlayRingMetrics.lineWidth,
            highlightMix: 0.68,
            glowRadius: 4,
            glowOpacity: 0.52,
            usesRoundCaps: true
        )
        return WorkspaceAttentionOrbitGeometry(
            pathRect: pathRect,
            cornerRadius: radius,
            perimeter: perimeter,
            headLength: headLength,
            tailLength: tailLength,
            tailBands: tailBands,
            head: head
        )
    }

    static func normalizedPhase(systemUptime: TimeInterval) -> CGFloat {
        guard systemUptime.isFinite, systemUptime > 0 else { return 0 }
        let remainder = systemUptime.truncatingRemainder(dividingBy: revolutionDuration)
        return CGFloat(remainder / revolutionDuration)
    }

    static func dashPhase(
        for band: WorkspaceAttentionOrbitBand,
        perimeter: CGFloat,
        normalizedPhase: CGFloat
    ) -> CGFloat {
        band.startDistanceBehindHead - normalizedPhase * perimeter
    }

    private static func interpolatedTailStyle(at position: CGFloat) -> TailStop {
        let position = max(0, min(1, position))
        guard let upperIndex = tailStops.firstIndex(where: { $0.position >= position }) else {
            return tailStops[tailStops.count - 1]
        }
        guard upperIndex > 0 else { return tailStops[0] }
        let lower = tailStops[upperIndex - 1]
        let upper = tailStops[upperIndex]
        let span = max(upper.position - lower.position, 0.0001)
        let progress = (position - lower.position) / span
        return TailStop(
            position: position,
            opacity: lower.opacity + (upper.opacity - lower.opacity) * progress,
            lineWidth: lower.lineWidth + (upper.lineWidth - lower.lineWidth) * progress,
            highlightMix: lower.highlightMix + (upper.highlightMix - lower.highlightMix) * progress
        )
    }
}

#if DEBUG
func cmuxFlashDebugID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(6))
}

func cmuxFlashDebugRect(_ rect: CGRect?) -> String {
    guard let rect else { return "nil" }
    return String(
        format: "%.1f,%.1f %.1fx%.1f",
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height
    )
}

func cmuxFlashDebugBool(_ value: Bool) -> Int {
    value ? 1 : 0
}
#endif

struct FocusFlashSegment: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
    let targetOpacity: Double
    let curve: FocusFlashCurve
}

enum FocusFlashPattern {
    static let values: [Double] = [0, 1, 0, 1, 0]
    static let keyTimes: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let duration: TimeInterval = 0.9
    static let curves: [FocusFlashCurve] = [.easeOut, .easeIn, .easeOut, .easeIn]
    static let ringInset: Double = Double(PanelOverlayRingMetrics.inset)
    static let ringCornerRadius: Double = Double(PanelOverlayRingMetrics.cornerRadius)

    static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }

    static func opacity(at elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }

        for index in 0..<segments.count {
            let startTime = keyTimes[index] * duration
            let endTime = keyTimes[index + 1] * duration
            if elapsed > endTime {
                continue
            }

            let segmentDuration = max(endTime - startTime, 0.0001)
            let rawProgress = max(0, min(1, (elapsed - startTime) / segmentDuration))
            let curvedProgress = interpolatedProgress(rawProgress, curve: curves[index])
            let startOpacity = values[index]
            let endOpacity = values[index + 1]
            return startOpacity + ((endOpacity - startOpacity) * curvedProgress)
        }

        return values.last ?? 0
    }

    private static func interpolatedProgress(_ progress: Double, curve: FocusFlashCurve) -> Double {
        switch curve {
        case .easeIn:
            return progress * progress
        case .easeOut:
            let inverse = 1 - progress
            return 1 - (inverse * inverse)
        }
    }
}

/// Protocol for all panel types (terminal, browser, etc.)
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// Box that owns this panel's restart-stable surface identity.
    var stableSurfaceIdentity: PanelStableSurfaceIdentity { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash(reason: WorkspaceAttentionFlashReason)

    /// Capture the panel-local focus target that should be restored later.
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent

    /// Return the best focus target to restore when this panel becomes active again.
    func preferredFocusIntentForActivation() -> PanelFocusIntent

    /// Prime panel-local focus state before activation side effects run.
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)

    /// Restore a previously captured focus target.
    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool

    /// Return the semantic focus target currently owned by this panel, if any.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?

    /// Explicitly yield a previously owned focus target before another panel restores focus.
    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

/// Extension providing default implementations
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .panel
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }

    func triggerFlash() {
        triggerFlash(reason: .navigation)
    }
}

@MainActor
final class CloudVMLoadingPanel: Panel {
    enum Phase {
        case loading
        case failed(String, elapsedSeconds: Int)
    }

    let id: UUID
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVMLoading
    @Published var startedAt: Date
    @Published var phase: Phase = .loading

    var displayTitle: String {
        String(localized: "panel.cloudVM.loading.title", defaultValue: "Cloud VM")
    }

    var displayIcon: String? { "cloud.fill" }

    init(id: UUID = UUID(), workspaceId: UUID, startedAt: Date = Date()) {
        self.id = id
        self.workspaceId = workspaceId
        self.startedAt = startedAt
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    func showFailure(_ message: String) {
        let trimmed = Self.presentableFailureMessage(from: message)
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt).rounded(.down)))
        phase = .failed(trimmed.isEmpty
            ? String(localized: "panel.cloudVM.loading.failed.generic", defaultValue: "Cloud VM could not be opened.")
            : trimmed,
            elapsedSeconds: elapsedSeconds
        )
    }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    func resetLoading() {
        startedAt = Date()
        phase = .loading
    }

    private static func presentableFailureMessage(from rawMessage: String) -> String {
        let cleaned = rawMessage
            .replacingOccurrences(of: "\u{001B}[2K", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let joined = cleaned.joined(separator: "\n")
        let lowercased = joined.lowercased()

        if lowercased.contains("local cmux web server") || lowercased.contains("localhost:") || lowercased.contains("127.0.0.1:") {
            return String(
                localized: "panel.cloudVM.loading.failed.localServer",
                defaultValue: "The local cmux web server is offline. Start it and retry Open Cloud VM."
            )
        }
        if lowercased.contains("waiting for the cloud vm service")
            || lowercased.contains("vm_cloud_service_unavailable")
            || lowercased.contains("http 502")
            || lowercased.contains("http 503")
            || lowercased.contains("service unavailable") {
            return String(
                localized: "panel.cloudVM.loading.failed.serviceUnavailable",
                defaultValue: "The Cloud VM service could not create a VM yet. Retry keeps using this pinned Cloud VM slot, and once a VM exists cmux will always reattach to that same VM."
            )
        }
        if lowercased.contains("password") || lowercased.contains("permission denied") {
            return String(
                localized: "panel.cloudVM.loading.failed.auth",
                defaultValue: "cmux could not open a passwordless terminal session. Try opening the Cloud VM again."
            )
        }

        var seen = Set<String>()
        let collapsed = cleaned.filter { line in
            let key = line.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return !key.contains("created cloud vm")
                && !key.contains("[cmux]")
                && !key.contains("freestyle")
                && !key.contains("provider")
                && !key.contains("http://")
                && !key.contains("https://")
        }
        return String(collapsed.joined(separator: "\n").prefix(600))
    }
}
