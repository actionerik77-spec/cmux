import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceAttentionFlashRingView: View {
    @Environment(\.workspaceAttentionColor) private var workspaceAttentionColor

    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    var body: some View {
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = Color(nsColor: workspaceAttentionColor.nsColor)

        RoundedRectangle(cornerRadius: CGFloat(FocusFlashPattern.ringCornerRadius))
            .stroke(color.opacity(opacity), lineWidth: PanelOverlayRingMetrics.lineWidth)
            .shadow(
                color: color.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
            .padding(CGFloat(FocusFlashPattern.ringInset))
            .allowsHitTesting(false)
    }
}

@MainActor
final class WorkspaceAttentionOrbitView: NSView {
    private static let animationKey = "cmux.workspace-attention-orbit"
    private static let dashOverlap: CGFloat = 0.35
    private static let highlightColor = NSColor(
        srgbRed: 234.0 / 255.0,
        green: 248.0 / 255.0,
        blue: 250.0 / 255.0,
        alpha: 1
    )

    private let baseLayer = CAShapeLayer()
    private let movingLayers: [CAShapeLayer]
    private var geometry: WorkspaceAttentionOrbitGeometry?
    private var attentionColor = WorkspaceAttentionColor(configuredHex: nil)
    private var attentionVisible = false
    private var renderingActive = true
    private var reduceMotionOverride: Bool?
    private var windowVisibilityOverride: Bool?

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        movingLayers = (0...WorkspaceAttentionOrbitPattern.tailBandCount).map { _ in CAShapeLayer() }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false
        baseLayer.fillColor = NSColor.clear.cgColor
        baseLayer.lineJoin = .round
        baseLayer.lineCap = .round
        baseLayer.shadowOffset = .zero
        baseLayer.opacity = 0
        layer?.addSublayer(baseLayer)

        for movingLayer in movingLayers {
            movingLayer.fillColor = NSColor.clear.cgColor
            movingLayer.lineJoin = .round
            movingLayer.shadowOffset = .zero
            movingLayer.opacity = 0
            layer?.addSublayer(movingLayer)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowOcclusion()
        updatePresentation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePresentation()
    }

    func setAttentionVisible(_ visible: Bool) {
        guard attentionVisible != visible else { return }
        attentionVisible = visible
        updatePresentation()
    }

    func setRenderingActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        updatePresentation()
    }

    func setAttentionColor(_ color: WorkspaceAttentionColor) {
        guard attentionColor != color else { return }
        attentionColor = color
        updateLayerColors()
    }

    func setReduceMotionOverride(_ reduceMotion: Bool?) {
        guard reduceMotionOverride != reduceMotion else { return }
        reduceMotionOverride = reduceMotion
        updatePresentation()
    }


    func setWindowVisibilityOverride(_ visible: Bool?) {
        guard windowVisibilityOverride != visible else { return }
        windowVisibilityOverride = visible
        updatePresentation()
    }
    func updateGeometry() {
        let nextGeometry = WorkspaceAttentionOrbitPattern.geometry(in: bounds)
        guard geometry != nextGeometry else { return }
        geometry = nextGeometry

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let geometry else {
            baseLayer.path = nil
            for movingLayer in movingLayers {
                movingLayer.path = nil
                movingLayer.removeAnimation(forKey: Self.animationKey)
            }
            CATransaction.commit()
            updatePresentation()
            return
        }

        let path = CGPath(
            roundedRect: geometry.pathRect,
            cornerWidth: geometry.cornerRadius,
            cornerHeight: geometry.cornerRadius,
            transform: nil
        )
        baseLayer.frame = bounds
        baseLayer.path = path

        let bands = geometry.tailBands + [geometry.head]
        for (movingLayer, band) in zip(movingLayers, bands) {
            movingLayer.removeAnimation(forKey: Self.animationKey)
            let dashLength = min(
                band.length + (band.usesRoundCaps ? 0 : Self.dashOverlap),
                geometry.perimeter
            )
            movingLayer.frame = bounds
            movingLayer.path = path
            movingLayer.lineDashPattern = [
                NSNumber(value: Double(dashLength)),
                NSNumber(value: Double(max(geometry.perimeter - dashLength, 0.1))),
            ]
            movingLayer.lineDashPhase = band.startDistanceBehindHead
            movingLayer.lineWidth = band.lineWidth
            movingLayer.lineCap = band.usesRoundCaps ? .round : .butt
            movingLayer.shadowRadius = band.glowRadius
            movingLayer.shadowOpacity = Float(band.glowOpacity)
        }
        CATransaction.commit()
        updateLayerColors()
        updatePresentation()
    }

    private var shouldReduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var shouldAnimate: Bool {
        guard attentionVisible, renderingActive, !shouldReduceMotion, geometry != nil else { return false }
        guard superview != nil, let window else { return false }
        return windowVisibilityOverride ?? window.occlusionState.contains(.visible)
    }

    private func observeWindowOcclusion() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    @objc private func windowOcclusionDidChange() {
        updatePresentation()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updatePresentation()
    }

    private func updatePresentation() {
        let shouldShow = attentionVisible && renderingActive && geometry != nil
        let reduceMotion = shouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = !shouldShow
        baseLayer.lineWidth = reduceMotion
            ? WorkspaceAttentionOrbitPattern.reducedMotionLineWidth
            : WorkspaceAttentionOrbitPattern.baseLineWidth
        baseLayer.shadowRadius = reduceMotion
            ? WorkspaceAttentionOrbitPattern.reducedMotionGlowRadius
            : WorkspaceAttentionOrbitPattern.baseGlowRadius
        baseLayer.shadowOpacity = Float(
            reduceMotion
                ? WorkspaceAttentionOrbitPattern.reducedMotionGlowOpacity
                : WorkspaceAttentionOrbitPattern.baseGlowOpacity
        )
        baseLayer.opacity = shouldShow
            ? Float(
                reduceMotion
                    ? WorkspaceAttentionOrbitPattern.reducedMotionOpacity
                    : WorkspaceAttentionOrbitPattern.baseOpacity
            )
            : 0

        let bands = geometry.map { $0.tailBands + [$0.head] } ?? []
        for (index, movingLayer) in movingLayers.enumerated() {
            let band = index < bands.count ? bands[index] : nil
            movingLayer.opacity = shouldAnimate ? Float(band?.opacity ?? 0) : 0
        }
        CATransaction.commit()

        if shouldAnimate {
            installAnimationsIfNeeded()
        } else {
            removeAnimations()
        }
    }

    private func updateLayerColors() {
        let color = attentionColor.nsColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.strokeColor = color.cgColor
        baseLayer.shadowColor = color.cgColor

        if let geometry {
            let bands = geometry.tailBands + [geometry.head]
            for (movingLayer, band) in zip(movingLayers, bands) {
                let bandColor = mixedAttentionColor(color, highlightMix: band.highlightMix)
                movingLayer.strokeColor = bandColor.cgColor
                movingLayer.shadowColor = bandColor.cgColor
            }
        }
        CATransaction.commit()
    }

    private func mixedAttentionColor(_ color: NSColor, highlightMix: CGFloat) -> NSColor {
        guard highlightMix > 0 else { return color }
        let base = color.usingColorSpace(.extendedSRGB) ?? color
        let highlight = Self.highlightColor.usingColorSpace(.extendedSRGB) ?? Self.highlightColor
        return base.blended(withFraction: highlightMix, of: highlight) ?? base
    }

    private func installAnimationsIfNeeded() {
        guard let geometry else { return }
        let bands = geometry.tailBands + [geometry.head]
        let globalNow = CACurrentMediaTime()
        let sharedPhase = globalNow.truncatingRemainder(
            dividingBy: WorkspaceAttentionOrbitPattern.revolutionDuration
        )

        for (movingLayer, band) in zip(movingLayers, bands) {
            guard movingLayer.animation(forKey: Self.animationKey) == nil else { continue }
            let layerNow = movingLayer.convertTime(globalNow, from: nil)
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = band.startDistanceBehindHead
            animation.toValue = band.startDistanceBehindHead - geometry.perimeter
            animation.duration = WorkspaceAttentionOrbitPattern.revolutionDuration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            animation.beginTime = layerNow - sharedPhase
            movingLayer.add(animation, forKey: Self.animationKey)
        }
    }

    private func removeAnimations() {
        for movingLayer in movingLayers {
            movingLayer.removeAnimation(forKey: Self.animationKey)
        }
    }
#if DEBUG
    func debugPresentationState() -> (
        isHidden: Bool,
        baseOpacity: Float,
        movingLayerCount: Int,
        animatedLayerCount: Int
    ) {
        (
            isHidden,
            baseLayer.opacity,
            movingLayers.count,
            movingLayers.count { $0.animation(forKey: Self.animationKey) != nil }
        )
    }
#endif
}

