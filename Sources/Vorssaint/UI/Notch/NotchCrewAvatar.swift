// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import QuartzCore
import SwiftUI

/// Who an agent looks like: a simple body, a color and one accessory, picked
/// from its id so it keeps the same face on every launch and every display.
struct NotchCrewIdentity: Equatable {
    enum Body: CaseIterable { case round, squircle, bean, gem }
    enum Accessory: CaseIterable { case none, antenna, cheeks, visor }

    let body: Body
    let accessory: Accessory
    let color: NSColor
    /// Spreads blinks and glances so a roster never moves in step.
    let phase: Double

    /// Muted brights that hold up on the island's black.
    private static let palette: [NSColor] = [
        NSColor(red: 1.00, green: 0.55, blue: 0.45, alpha: 1), // coral
        NSColor(red: 0.45, green: 0.86, blue: 0.70, alpha: 1), // mint
        NSColor(red: 0.47, green: 0.70, blue: 1.00, alpha: 1), // sky
        NSColor(red: 0.74, green: 0.60, blue: 1.00, alpha: 1), // lilac
        NSColor(red: 1.00, green: 0.80, blue: 0.42, alpha: 1), // sand
        NSColor(red: 0.70, green: 0.90, blue: 0.40, alpha: 1), // lime
        NSColor(red: 1.00, green: 0.56, blue: 0.75, alpha: 1), // rose
        NSColor(red: 0.38, green: 0.82, blue: 0.88, alpha: 1), // teal
    ]

    init(id: String) {
        // FNV-1a: Swift's own hash changes on every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        body = Body.allCases[Int(hash % UInt64(Body.allCases.count))]
        accessory = Accessory.allCases[Int((hash >> 8) % UInt64(Accessory.allCases.count))]
        color = Self.palette[Int((hash >> 16) % UInt64(Self.palette.count))]
        phase = Double((hash >> 24) % 1000) / 1000
    }

    var tint: Color { Color(nsColor: color) }
}

/// An agent's face. Its motion is its status, so the roster needs no other
/// indicator: calm and curious at rest, bobbing while it works, swaying with
/// wide eyes when it needs the person, a happy hop when a run lands, and
/// asleep when paused. Every movement is a layer animation the compositor
/// runs, and it stops while the window is hidden or covered.
final class NotchCrewAvatarView: NSView {
    private let figure = CALayer()
    private let bodyShape = CAShapeLayer()
    private let shine = CAShapeLayer()
    private let eyes = CALayer()
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private let accessory = CAShapeLayer()
    private let accessoryTip = CAShapeLayer()
    private let badge = CAShapeLayer()

    private var identity = NotchCrewIdentity(id: "")
    private var state: PaperclipAgentState = .idle
    private var size: CGFloat = 0
    private var animates = false
    private var drawn: (NotchCrewIdentity, PaperclipAgentState, CGFloat)?
    private var moving: Bool?
    private var visibilityObserver: NSObjectProtocol?

    private static let ink = NSColor(white: 0.07, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        figure.masksToBounds = false
        layer?.addSublayer(figure)
        for part in [accessory, accessoryTip, bodyShape, shine, eyes, badge] { figure.addSublayer(part) }
        eyes.addSublayer(leftEye)
        eyes.addSublayer(rightEye)
        shine.fillColor = NSColor.white.withAlphaComponent(0.28).cgColor
        accessory.fillColor = nil
        accessory.lineCap = .round
        badge.fillColor = NSColor.systemOrange.cgColor
        badge.strokeColor = NSColor.black.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(identity: NotchCrewIdentity, state: PaperclipAgentState, size: CGFloat, animates: Bool) {
        self.identity = identity
        self.state = state
        self.size = size
        self.animates = animates
        needsLayout = true
    }

    func stop() {
        animates = false
        refreshMotion()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                self?.refreshMotion()
            }
        }
        refreshMotion()
    }

    override func viewDidHide() { super.viewDidHide(); refreshMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshMotion() }

    override func layout() {
        super.layout()
        let side = size > 0 ? size : min(bounds.width, bounds.height)
        if drawn.map({ $0.0 != identity || $0.1 != state || $0.2 != side }) ?? true {
            draw(side: side)
            drawn = (identity, state, side)
            moving = nil
        }
        refreshMotion()
    }

    // MARK: Drawing

    private func draw(side s: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        figure.frame = CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
        let box = CGRect(x: 0, y: 0, width: s, height: s)
        let sleepy = state == .offline || state == .paused
        let color = state == .offline ? identity.color.blended(withFraction: 0.65, of: .gray) ?? identity.color
            : identity.color
        bodyShape.frame = box
        bodyShape.path = bodyPath(in: box.insetBy(dx: s * 0.06, dy: s * 0.06))
        bodyShape.fillColor = color.cgColor
        bodyShape.opacity = sleepy ? 0.7 : 1
        // A soft highlight high on the body reads as volume at any size.
        shine.frame = box
        shine.path = CGPath(ellipseIn: CGRect(x: s * 0.24, y: s * 0.62, width: s * 0.2, height: s * 0.12), transform: nil)
        shine.opacity = s >= 14 ? 1 : 0

        eyes.frame = box
        let eyeY = s * (identity.body == .bean ? 0.46 : 0.5)
        let gap = s * 0.15
        for (eye, x) in [(leftEye, s / 2 - gap), (rightEye, s / 2 + gap)] {
            eye.frame = CGRect(x: x - s * 0.12, y: eyeY - s * 0.15, width: s * 0.24, height: s * 0.3)
            let local = CGRect(origin: .zero, size: eye.frame.size)
            eye.path = eyePath(in: local, side: s)
            let stroked = state == .done || sleepy
            eye.fillColor = stroked ? nil : Self.ink.cgColor
            eye.strokeColor = stroked ? Self.ink.cgColor : nil
            eye.lineWidth = max(1, s * 0.065)
            eye.lineCap = .round
        }

        drawAccessory(side: s, color: color)
        let dot = max(4, s * 0.3)
        badge.frame = CGRect(x: s - dot * 0.85, y: s - dot * 0.85, width: dot, height: dot)
        badge.path = CGPath(ellipseIn: CGRect(origin: .zero, size: badge.frame.size), transform: nil)
        badge.lineWidth = max(1, dot * 0.18)
        badge.isHidden = state != .waiting
    }

    private func bodyPath(in rect: CGRect) -> CGPath {
        switch identity.body {
        case .round:
            return CGPath(ellipseIn: rect, transform: nil)
        case .squircle:
            return CGPath(roundedRect: rect, cornerWidth: rect.width * 0.32, cornerHeight: rect.height * 0.32, transform: nil)
        case .bean:
            // Taller than wide, rounder at the bottom.
            let bean = rect.insetBy(dx: rect.width * 0.08, dy: 0)
            return CGPath(roundedRect: bean, cornerWidth: bean.width * 0.48, cornerHeight: bean.height * 0.42, transform: nil)
        case .gem:
            let path = CGMutablePath()
            let r = rect.width / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let points = (0..<6).map { index -> CGPoint in
                let angle = Double.pi / 3 * Double(index) + Double.pi / 6
                return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
            }
            // Rounded corners keep the gem friendly.
            let corner = r * 0.28
            path.move(to: CGPoint(x: (points[5].x + points[0].x) / 2, y: (points[5].y + points[0].y) / 2))
            for index in 0..<6 {
                path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % 6], radius: corner)
            }
            path.closeSubpath()
            return path
        }
    }

    private func eyePath(in rect: CGRect, side s: CGFloat) -> CGPath {
        let width = s * 0.1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        switch state {
        case .done:
            // Happy eyes: a small arch.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x - width * 0.75, y: center.y - s * 0.02))
            path.addQuadCurve(to: CGPoint(x: center.x + width * 0.75, y: center.y - s * 0.02),
                              control: CGPoint(x: center.x, y: center.y + s * 0.11))
            return path
        case .offline, .paused:
            // Asleep: a closed line.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x - width * 0.6, y: center.y - s * 0.02))
            path.addLine(to: CGPoint(x: center.x + width * 0.6, y: center.y - s * 0.02))
            return path
        case .working:
            // Focused: narrowed.
            let height = s * 0.11
            let eye = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            return CGPath(roundedRect: eye, cornerWidth: width / 2, cornerHeight: height / 2, transform: nil)
        case .waiting:
            // Wide and looking up for help.
            let diameter = s * 0.15
            return CGPath(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2 + s * 0.03,
                                            width: diameter, height: diameter), transform: nil)
        case .idle:
            let height = s * 0.2
            let eye = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            return CGPath(roundedRect: eye, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        }
    }

    private func drawAccessory(side s: CGFloat, color: NSColor) {
        accessory.frame = CGRect(x: 0, y: 0, width: s, height: s)
        accessoryTip.frame = accessory.frame
        accessory.path = nil
        accessoryTip.path = nil
        accessory.fillColor = nil
        accessory.strokeColor = color.cgColor
        accessory.lineWidth = max(1, s * 0.07)
        // Fine details vanish at the strip's size; the body and eyes carry it.
        guard s >= 13 else { return }
        switch identity.accessory {
        case .none:
            break
        case .antenna:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: s * 0.5, y: s * 0.9))
            path.addLine(to: CGPoint(x: s * 0.58, y: s * 1.06))
            accessory.path = path
            let tip = s * 0.14
            accessoryTip.path = CGPath(ellipseIn: CGRect(x: s * 0.58 - tip / 2, y: s * 1.06 - tip / 2,
                                                         width: tip, height: tip), transform: nil)
            accessoryTip.fillColor = (state == .working ? NSColor.white : color).cgColor
        case .cheeks:
            let path = CGMutablePath()
            let blush = s * 0.1
            for x in [s * 0.27, s * 0.73] {
                path.addEllipse(in: CGRect(x: x - blush / 2, y: s * 0.33, width: blush, height: blush * 0.6))
            }
            accessoryTip.path = path
            accessoryTip.fillColor = NSColor(red: 1, green: 0.4, blue: 0.5, alpha: 0.55).cgColor
            accessoryTip.zPosition = 1
        case .visor:
            // A band across the eyes, darker than the body.
            let band = CGRect(x: s * 0.2, y: s * 0.4, width: s * 0.6, height: s * 0.22)
            accessoryTip.path = CGPath(roundedRect: band, cornerWidth: band.height / 2, cornerHeight: band.height / 2,
                                       transform: nil)
            accessoryTip.fillColor = NSColor.white.withAlphaComponent(0.32).cgColor
            accessoryTip.zPosition = 1
        }
    }

    // MARK: Motion

    private func refreshMotion() {
        let now = animates && !isHiddenOrHasHiddenAncestor
            && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        guard moving != now else { return }
        moving = now
        for part in [figure, eyes, badge, accessoryTip] { part.removeAllAnimations() }
        guard now else { return }
        let s = max(1, size > 0 ? size : min(bounds.width, bounds.height))
        let start = CACurrentMediaTime() + identity.phase * 2
        switch state {
        case .idle:
            // Calm and a little curious: a blink, a look around.
            eyes.add(blink(every: 4.2 + identity.phase * 2, at: start), forKey: "blink")
            eyes.add(glance(distance: s * 0.05, every: 7, at: start), forKey: "glance")
            figure.add(drift(s * 0.025, every: 3.2, at: start), forKey: "drift")
        case .working:
            // In gear: a steady bob and eyes reading line after line.
            figure.add(drift(s * 0.06, every: 0.42, at: start), forKey: "bob")
            eyes.add(glance(distance: s * 0.06, every: 1.4, at: start), forKey: "read")
            if identity.accessory == .antenna { accessoryTip.add(flash(at: start), forKey: "flash") }
        case .waiting:
            // Swaying and looking up: it wants the person.
            let sway = CABasicAnimation(keyPath: "transform.rotation.z")
            sway.fromValue = -0.16
            sway.toValue = 0.16
            sway.duration = 0.75
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sway.beginTime = start
            figure.add(sway, forKey: "sway")
            badge.add(flash(at: start), forKey: "flash")
        case .done:
            // A happy hop, then it settles.
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, s * 0.14, 0, s * 0.06, 0, 0]
            hop.keyTimes = [0, 0.12, 0.26, 0.36, 0.46, 1]
            hop.duration = 2.6
            hop.repeatCount = 3
            hop.beginTime = CACurrentMediaTime()
            figure.add(hop, forKey: "hop")
        case .paused, .offline:
            // Asleep: only a slow breath.
            let breath = CABasicAnimation(keyPath: "transform.scale")
            breath.fromValue = 0.97
            breath.toValue = 1.0
            breath.duration = 2.4
            breath.autoreverses = true
            breath.repeatCount = state == .paused ? .infinity : 0
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.beginTime = start
            figure.add(breath, forKey: "breath")
        }
    }

    private func blink(every period: CFTimeInterval, at start: CFTimeInterval) -> CAAnimation {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        let close = 0.14 / period
        blink.values = [1, 1, 0.1, 1]
        blink.keyTimes = [0, NSNumber(value: 1 - close * 2), NSNumber(value: 1 - close), 1]
        blink.duration = period
        blink.repeatCount = .infinity
        blink.beginTime = start
        return blink
    }

    private func glance(distance: CGFloat, every period: CFTimeInterval, at start: CFTimeInterval) -> CAAnimation {
        let look = CAKeyframeAnimation(keyPath: "transform.translation.x")
        look.values = [0, -distance, -distance, 0, distance, distance, 0]
        look.keyTimes = [0, 0.12, 0.38, 0.5, 0.62, 0.88, 1]
        look.duration = period
        look.repeatCount = .infinity
        look.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        look.beginTime = start
        return look
    }

    private func drift(_ distance: CGFloat, every period: CFTimeInterval, at start: CFTimeInterval) -> CAAnimation {
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = 0
        drift.toValue = distance
        drift.duration = period
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        drift.beginTime = start
        return drift
    }

    private func flash(at start: CFTimeInterval) -> CAAnimation {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 1
        flash.toValue = 0.25
        flash.duration = 0.6
        flash.autoreverses = true
        flash.repeatCount = .infinity
        flash.beginTime = start
        return flash
    }
}

/// An agent's face in SwiftUI. The frame is the body; an antenna or a hop
/// reaches a little past it.
struct NotchCrewAvatar: View {
    let agentID: String
    let state: PaperclipAgentState
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchCrewAvatarBridge(identity: NotchCrewIdentity(id: agentID), state: state, size: size,
                              animates: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct NotchCrewAvatarBridge: NSViewRepresentable {
    let identity: NotchCrewIdentity
    let state: PaperclipAgentState
    let size: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> NotchCrewAvatarView { NotchCrewAvatarView() }
    func updateNSView(_ view: NotchCrewAvatarView, context: Context) {
        view.configure(identity: identity, state: state, size: size, animates: animates)
    }
    static func dismantleNSView(_ view: NotchCrewAvatarView, coordinator: ()) { view.stop() }
}
