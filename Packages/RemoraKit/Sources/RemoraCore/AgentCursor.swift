import CoreGraphics
import Foundation

// Cursor motion and artwork from the Codex cursor kit. Values mirror its docs/spec.md.
// Both renderers share this value model, in points with a monotonic host-supplied clock.
//
// Coordinate space: points, y grows downward (a flipped NSView, CG event space).
// Rotation: radians, positive is clockwise on screen.

public enum CursorTuning {
    // Glyph, local frame: tip toward -y, origin at the rotation pivot. The outline is a closed
    // Catmull-Rom spline through these points, in order, starting at the tip.
    public static let outline: [CGPoint] = [
        CGPoint(x: 0.30, y: -7.22),    // tip, the hotspot
        CGPoint(x: 1.77, y: -6.16),
        CGPoint(x: 5.79, y: 1.84),
        CGPoint(x: 6.29, y: 2.89),
        CGPoint(x: 6.29, y: 4.14),
        CGPoint(x: 4.77, y: 4.92),
        CGPoint(x: 0.30, y: 3.54),     // notch
        CGPoint(x: -4.17, y: 4.92),
        CGPoint(x: -5.70, y: 4.14),
        CGPoint(x: -5.70, y: 2.89),
        CGPoint(x: -5.19, y: 1.84),
        CGPoint(x: -1.18, y: -6.16),
    ]
    public static let haloOffset = CGPoint(x: -0.16, y: -2.36)   // halo center in the local frame
    public static let restRotation = -44.46 * .pi / 180

    // Travel. Response grows with distance: fitted to 0.44 s at 430 pt and 0.59 s at 830 pt.
    public static let scootDistance = 36.0
    public static let responseBase = 0.28
    public static let responsePerPoint = 0.000375
    public static let responseRange = 0.30...0.65
    public static let travelDamping = 0.80
    public static let scootResponse = 0.22
    public static let scootDamping = 0.85
    public static let departureBlend = 0.35          // share of the turn from heading to chord
    public static let departureMaxTurn = 60.0 * .pi / 180
    public static let departureHandle = 0.38         // first control point, fraction of distance
    public static let arrivalBlend = 0.12
    public static let arrivalMaxTurn = 15.0 * .pi / 180
    public static let arrivalHandle = 0.30
    public static let arrivedTolerance = 0.003
    public static let arrivedVelocity = 0.08

    // Heading.
    public static let headingInFlight = (response: 0.103, damping: 0.35)
    public static let headingAtRest = (response: 0.27, damping: 1.0)
    public static let headingScoot = (response: 0.16, damping: 0.70)
    public static let headingReleaseProgress = 0.98  // stop following the tangent past this
    public static let scootTiltPerSpeed = 1.0 / 40.0 * .pi / 180  // radians per pt/s
    public static let scootTiltMax = 14.0 * .pi / 180

    // Shape at speed. Springs follow targets driven by speed and, for the width, acceleration.
    public static let speedUnit = 4000.0             // pt/s
    public static let accelerationUnit = 50000.0     // pt/s^2
    public static let accelerationSmoothing = 0.012  // s, one-pole filter on the acceleration
    public static let along = (response: 0.345, damping: 0.814, perSpeed: 0.464)
    public static let across = (response: 0.479, damping: 0.272, perAcceleration: 0.242, perSpeed: 0.038)
    public static let haloAtSpeed = (response: 0.543, damping: 0.598, perSpeed: 0.277)

    // Press. Scales about the tip so the hotspot stays put.
    public static let clickDepth = 0.78
    public static let dragDepth = 0.86
    public static let pressDown = (response: 0.147, damping: 1.0)
    public static let pressUp = (response: 0.314, damping: 0.68)
    public static let pressHold = 0.10               // s from press start; the click event fires at its end

    // Idle sway while the agent thinks: a pure sine that starts at phase 0.
    public static let swayAmplitude = 10.23 * .pi / 180
    public static let swayPeriod = 1.3835

    // Appear and hide.
    public static let appear = (response: 0.32, damping: 0.72)
    public static let appearMinScale = 0.62
    public static let appearMaxBlur = 5.0            // points

    // Integration step. Springs are stiff; sub-step so 30 Hz hosts stay stable.
    public static let maxSubstep = 1.0 / 480
}

/// Damped spring: `response` is the undamped period in seconds, `damping` the fraction of critical damping.
public struct Spring: Sendable {
    public var value: Double
    public var velocity: Double = 0

    public init(_ value: Double) { self.value = value }

    public mutating func step(toward target: Double, response: Double, damping: Double, dt: Double) {
        let omega = 2 * .pi / response
        velocity += (omega * omega * (target - value) - 2 * damping * omega * velocity) * dt
        value += velocity * dt
    }
}

/// Everything a renderer needs for one frame.
public struct CursorPose: Sendable {
    public var center: CGPoint        // the pivot; translate here, then rotate, then scale
    public var rotation: Double       // radians, clockwise
    public var scaleAcross: Double    // local x, across the arrow axis
    public var scaleAlong: Double     // local y, along the arrow axis
    public var opacity: Double
    public var blurRadius: Double     // points
    public var haloCenter: CGPoint
    public var haloScale: Double
    public var hotspot: CGPoint       // where the tip is right now
}

public struct CursorMotion: Sendable {
    public var bounds: CGRect
    /// Drawn size multiplier; 1 is Codex's size. Keeps the hotspot on the drawn tip.
    public var size: Double = 1
    public var isVisible = false
    /// Set while the agent waits on the model. The cursor sways only while it is also idle.
    public var isThinking = false
    public private(set) var center: CGPoint
    public var isMoving: Bool { path != nil || reducedTravel != nil }
    /// Absolute uptime window supplied by the session's input policy.
    public var thinkingWindow: Range<TimeInterval>?
    public var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if let destination { place(at: destination) }
            swayStart = nil
            along = Spring(1); across = Spring(1); haloAtSpeed = Spring(1)
        }
    }

    private var destination: CGPoint?
    private var followedHotspot: CGPoint?
    private var reducedTravel: (target: CGPoint, start: Double)?
    private var epoch = 0.0
    private var ticks = 0
    private var lastAdvance = 0.0

    private struct Path: Sendable {
        var p0, p1, p2, p3: CGPoint
        var response, damping: Double
        var isScoot: Bool
        var progress = Spring(0)
    }

    private var path: Path?
    private var rotation = Spring(CursorTuning.restRotation)
    private var swayStart: Double?
    private var press = Spring(1)
    private var pressTarget = 1.0
    private var appear = Spring(0)
    private var along = Spring(1)
    private var across = Spring(1)
    private var haloAtSpeed = Spring(1)
    private var speed = 0.0
    private var acceleration = 0.0
    private var time = 0.0

    public init(hotspot: CGPoint, bounds: CGRect, size: Double = 1, time: TimeInterval = 0) {
        self.epoch = time
        self.time = time
        self.lastAdvance = time
        self.bounds = bounds
        self.size = size
        self.center = .zero
        self.center = hotspot - restTipOffset
    }

    /// Tip offset from the pivot in the rest pose.
    public var restTipOffset: CGPoint {
        (CursorTuning.outline[0] * size).rotated(by: CursorTuning.restRotation)
    }

    // MARK: Commands

    /// Start a move so the tip lands on `hotspot`. Replaces any move in progress.
    public mutating func move(to hotspot: CGPoint) {
        guard (hotspot - pose.hotspot).length >= 0.5 else { place(at: hotspot); return }
        destination = hotspot
        followedHotspot = nil
        if reduceMotion {
            reducedTravel = (hotspot, time)
            return
        }
        let start = center
        let end = hotspot - restTipOffset
        let chord = end - start
        let distance = chord.length

        if distance < CursorTuning.scootDistance {
            path = Path(p0: start, p1: start + chord * (1.0 / 3), p2: start + chord * (2.0 / 3), p3: end,
                        response: CursorTuning.scootResponse, damping: CursorTuning.scootDamping, isScoot: true)
            return
        }

        // Leave along the current heading, bend toward the target, arrive near the chord direction.
        let chordAngle = chord.heading
        let turn = wrapAngle(chordAngle - rotation.value)
        let departAngle = rotation.value + clamp(turn * CursorTuning.departureBlend, CursorTuning.departureMaxTurn)
        let arriveAngle = chordAngle - clamp(turn * CursorTuning.arrivalBlend, CursorTuning.arrivalMaxTurn)
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let p1 = (start + CGPoint(heading: departAngle) * (distance * CursorTuning.departureHandle)).clamped(to: inset)
        let p2 = (end - CGPoint(heading: arriveAngle) * (distance * CursorTuning.arrivalHandle)).clamped(to: inset)
        let response = min(max(CursorTuning.responseBase + CursorTuning.responsePerPoint * distance,
                               CursorTuning.responseRange.lowerBound), CursorTuning.responseRange.upperBound)
        path = Path(p0: start, p1: p1, p2: p2, p3: end,
                    response: response, damping: CursorTuning.travelDamping, isScoot: false)
    }

    /// Jump without animating, for first placement.
    public mutating func place(at hotspot: CGPoint) {
        path = nil
        reducedTravel = nil
        destination = hotspot
        followedHotspot = hotspot
        center = hotspot - restTipOffset
        rotation = Spring(CursorTuning.restRotation)
        along = Spring(1); across = Spring(1); haloAtSpeed = Spring(1)
        speed = 0; acceleration = 0
    }

    /// Drag samples pin the drawn tip, including while the press spring is settling.
    public mutating func follow(to hotspot: CGPoint) {
        path = nil
        reducedTravel = nil
        destination = hotspot
        followedHotspot = hotspot
        center = hotspot - restTipOffset
    }

    public mutating func pressDown(depth: Double = CursorTuning.clickDepth) { pressTarget = depth }
    public mutating func release() { pressTarget = 1 }

    // MARK: Simulation

    /// Fixed-grid integration makes the pose independent of how often either renderer reads it.
    /// Times use system uptime, as does CADisplayLink.timestamp. Backward reads are ignored.
    @discardableResult
    public mutating func advance(to target: TimeInterval) -> Bool {
        guard target.isFinite, target >= lastAdvance else { return false }
        lastAdvance = target
        let endTick = Int(((target - epoch) / CursorTuning.maxSubstep + 0.000001).rounded(.down))
        let count = max(0, endTick - ticks)
        var arrived = false
        for _ in 0..<min(count, 960) {
            ticks += 1
            time = epoch + Double(ticks) * CursorTuning.maxSubstep
            arrived = substep(CursorTuning.maxSubstep) || arrived
        }
        if count > 960 {
            ticks = endTick
            time = epoch + Double(ticks) * CursorTuning.maxSubstep
            if let destination { place(at: destination) }
            press = Spring(pressTarget)
            appear = Spring(isVisible ? 1 : 0)
            let thinking = isThinking || thinkingWindow?.contains(time) == true
            if !reduceMotion && isVisible && thinking && pressTarget == 1 {
                if swayStart == nil { swayStart = thinkingWindow?.lowerBound ?? time }
            } else { swayStart = nil }
            arrived = true
        }
        return arrived
    }

    @discardableResult
    public mutating func step(_ dt: Double) -> Bool {
        guard dt > 0 else { return false }
        return advance(to: lastAdvance + dt)
    }

    /// Exact remaining delay on this model's integration grid, without changing the model.
    public var arrivalDelay: TimeInterval {
        var copy = self
        while copy.isMoving { copy.advance(to: copy.time + CursorTuning.maxSubstep) }
        return max(0, copy.time - lastAdvance)
    }

    public var isSettled: Bool {
        func settled(_ spring: Spring, _ target: Double) -> Bool {
            abs(spring.value - target) < 0.0001 && abs(spring.velocity) < 0.001
        }
        return !isMoving && swayStart == nil
            && abs(wrapAngle(rotation.value - CursorTuning.restRotation)) < 0.0001 && abs(rotation.velocity) < 0.001
            && settled(press, pressTarget) && settled(appear, isVisible ? 1 : 0)
            && settled(along, 1) && settled(across, 1) && settled(haloAtSpeed, 1)
    }

    private mutating func substep(_ dt: Double) -> Bool {
        if let travel = reducedTravel {
            let elapsed = time - travel.start
            if elapsed >= 0.1 { center = travel.target - restTipOffset; followedHotspot = travel.target }
            if elapsed >= 0.2 - 0.000001 { reducedTravel = nil }
        }
        let previous = center
        var tangent: CGPoint?
        var arrived = false

        if var p = path {
            p.progress.step(toward: 1, response: p.response, damping: p.damping, dt: dt)
            let u = p.progress.value
            if u <= 1 {
                center = bezier(p, max(0, u))
                tangent = bezierTangent(p, min(max(u, 0.001), 0.999))
            } else {
                // Overshoot continues along the end tangent.
                let endTangent = p.p3 - p.p2
                center = p.p3 + endTangent * (3 * (u - 1))
                tangent = endTangent
            }
            if abs(1 - u) < CursorTuning.arrivedTolerance && abs(p.progress.velocity) < CursorTuning.arrivedVelocity {
                center = p.p3
                path = nil
                followedHotspot = destination
                arrived = true
            } else {
                path = p
            }
        }

        let velocity = (center - previous) * (1 / dt)
        let newSpeed = velocity.length
        let rawAcceleration = (newSpeed - speed) / dt
        speed = newSpeed
        acceleration += (rawAcceleration - acceleration) * min(dt / CursorTuning.accelerationSmoothing, 1)

        stepHeading(tangent: tangent, horizontalVelocity: velocity.x, dt: dt)
        if !reduceMotion { stepShape(dt: dt) }
        let pressSpring = pressTarget < 1 ? CursorTuning.pressDown : CursorTuning.pressUp
        press.step(toward: pressTarget, response: pressSpring.response, damping: pressSpring.damping, dt: dt)
        if reduceMotion {
            appear.value = min(1, max(0, appear.value + (isVisible ? dt : -dt) / 0.1))
            appear.velocity = 0
        } else {
            appear.step(toward: isVisible ? 1 : 0,
                        response: CursorTuning.appear.response, damping: CursorTuning.appear.damping, dt: dt)
        }
        return arrived
    }

    private mutating func stepHeading(tangent: CGPoint?, horizontalVelocity: Double, dt: Double) {
        // Sway starts at phase 0 when the cursor goes idle while thinking. When it ends, the
        // current sway offset is handed to the heading spring so the angle stays continuous.
        let swaying = !reduceMotion && isVisible && (isThinking || thinkingWindow?.contains(time) == true) && !isMoving && pressTarget == 1
        if swaying, swayStart == nil {
            swayStart = time
        } else if !swaying, swayStart != nil {
            rotation.value += swayOffset
            swayStart = nil
        }

        let target: Double
        let spring: (response: Double, damping: Double)
        if let p = path, p.isScoot {
            let tilt = clamp(horizontalVelocity * CursorTuning.scootTiltPerSpeed, CursorTuning.scootTiltMax)
            target = CursorTuning.restRotation + tilt
            spring = CursorTuning.headingScoot
        } else if let p = path, let tangent, p.progress.value < CursorTuning.headingReleaseProgress {
            target = tangent.heading
            spring = CursorTuning.headingInFlight
        } else {
            target = CursorTuning.restRotation
            spring = CursorTuning.headingAtRest
        }
        rotation.step(toward: rotation.value + wrapAngle(target - rotation.value),
                      response: spring.response, damping: spring.damping, dt: dt)
    }

    private mutating func stepShape(dt: Double) {
        let u = min(speed / CursorTuning.speedUnit, 2)
        let a = min(max(acceleration / CursorTuning.accelerationUnit, -2), 2)
        let al = CursorTuning.along, ac = CursorTuning.across, h = CursorTuning.haloAtSpeed
        along.step(toward: 1 - al.perSpeed * u, response: al.response, damping: al.damping, dt: dt)
        across.step(toward: 1 + ac.perAcceleration * a - ac.perSpeed * u, response: ac.response, damping: ac.damping, dt: dt)
        haloAtSpeed.step(toward: 1 - h.perSpeed * u, response: h.response, damping: h.damping, dt: dt)
    }

    private var swayOffset: Double {
        guard let swayStart else { return 0 }
        return CursorTuning.swayAmplitude * sin(2 * .pi * (time - swayStart) / CursorTuning.swayPeriod)
    }

    // MARK: Output

    public var pose: CursorPose {
        let travelOpacity = reducedTravel.map {
            let elapsed = time - $0.start
            return elapsed < 0.1 ? max(0, 1 - elapsed / 0.1) : min(1, (elapsed - 0.1) / 0.1)
        } ?? 1
        let visibility = min(max(appear.value, 0), 1) * travelOpacity
        let angle = rotation.value + swayOffset
        // Press and appear scale about the tip, so the hotspot stays on target.
        let scale = press.value * (reduceMotion ? 1 : CursorTuning.appearMinScale + (1 - CursorTuning.appearMinScale) * appear.value)
        let tipLocal = CursorTuning.outline[0] * size
        let tip = center + tipLocal.rotated(by: angle)
        let drawnCenter = tip + (center - tip) * scale
        let across = scale * self.across.value
        let along = scale * self.along.value
        let drawnTip = CGPoint(x: Double(tipLocal.x) * across, y: Double(tipLocal.y) * along).rotated(by: angle)
        let drawnHotspot = drawnCenter + drawnTip
        let correction = followedHotspot.map { $0 - drawnHotspot } ?? .zero
        return CursorPose(
            center: drawnCenter + correction,
            rotation: angle,
            scaleAcross: across,
            scaleAlong: along,
            opacity: visibility,
            blurRadius: reduceMotion ? 0 : (1 - visibility) * CursorStyle.appearBlur,
            haloCenter: drawnCenter + correction + (CursorTuning.haloOffset * (size * scale)).rotated(by: angle),
            haloScale: haloAtSpeed.value * press.value * (0.7 + 0.3 * appear.value),
            hotspot: drawnHotspot + correction)
    }

    /// Path progress of the current move, 0...1 (can exceed 1 on overshoot). Nil when idle.
    public var moveProgress: Double? { path?.progress.value }

    private func bezier(_ p: Path, _ u: Double) -> CGPoint {
        let a = 1 - u
        return p.p0 * (a * a * a) + p.p1 * (3 * a * a * u) + p.p2 * (3 * a * u * u) + p.p3 * (u * u * u)
    }

    private func bezierTangent(_ p: Path, _ u: Double) -> CGPoint {
        let a = 1 - u
        return (p.p1 - p.p0) * (3 * a * a) + (p.p2 - p.p1) * (6 * a * u) + (p.p3 - p.p2) * (3 * u * u)
    }
}

// MARK: Glyph outline

public enum CursorGlyph {
    /// The outline in the local frame (tip toward -y, pivot at the origin), scale 1 = points.
    /// Each Catmull-Rom span becomes one cubic Bezier.
    public static func path(scale: CGFloat = 1) -> CGPath {
        let pts = CursorTuning.outline.map { $0 * Double(scale) }
        let n = pts.count
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i + n - 1) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            path.addCurve(to: p2, control1: p1 + (p2 - p0) * (1.0 / 6), control2: p2 - (p3 - p1) * (1.0 / 6))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: Geometry helpers

fileprivate func wrapAngle(_ a: Double) -> Double {
    var x = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
    if x < 0 { x += 2 * .pi }
    return x - .pi
}

fileprivate func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, -limit), limit) }

fileprivate extension CGPoint {
    /// Unit vector for a tip heading: 0 points up, positive turns clockwise.
    init(heading: Double) { self.init(x: sin(heading), y: -cos(heading)) }
    /// Heading of this vector in the same convention.
    var heading: Double { atan2(Double(x), Double(-y)) }
    var length: Double { hypot(Double(x), Double(y)) }
    func rotated(by a: Double) -> CGPoint {
        let c = cos(a), s = sin(a)
        return CGPoint(x: Double(x) * c - Double(y) * s, y: Double(x) * s + Double(y) * c)
    }
    func clamped(to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, r.minX), r.maxX), y: min(max(y, r.minY), r.maxY))
    }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: Double(a.x) * k, y: Double(a.y) * k) }
}


/// Fixed slate artwork shared by the screen and recorder. CGColor components are unpremultiplied sRGB.
public enum CursorStyle {
    public static let stroke = CGColor(srgbRed: 206 / 255, green: 208 / 255, blue: 211 / 255, alpha: 1)
    public static let strokeWidth = 1.39
    public static let fog = CGColor(srgbRed: 47 / 255, green: 74 / 255, blue: 98 / 255, alpha: 1)
    public static let fill = CGColor(srgbRed: (0.690 * 47 + 0.292 * 196) / (255 * 0.982),
        green: (0.690 * 74 + 0.292 * 183) / (255 * 0.982),
        blue: (0.690 * 98 + 0.292 * 190) / (255 * 0.982), alpha: 0.982)
    public static let haloRadius = 36.0
    public static let fogStops: [(radius: Double, alpha: Double)] = [
        (0, 0.623), (4, 0.605), (8, 0.534), (12, 0.417), (16, 0.283),
        (20, 0.165), (24, 0.081), (28, 0.033), (32, 0)]
    public static let liftStops: [(radius: Double, alpha: Double)] = [
        (0, 0.027), (4, 0.027), (8, 0.0267), (12, 0.0135), (16, 0.0084),
        (20, 0.0052), (24, 0.0016), (28, 0.0065), (32, 0.0051), (36, 0)]
    public static let appearBlur = CursorTuning.appearMaxBlur
}

/// A frozen renderer contract. Positions and blur are desktop pixels, with y growing downward.
/// Scale factors and rotation are dimensionless. `unit` is desktop pixels per spec point.
/// On screen map `pose.hotspot` through DesktopGeometry, then use point offsets
/// `(pose.center - pose.hotspot) / unit` and `(pose.haloCenter - pose.hotspot) / unit`.
public struct AgentCursorFrame: Sendable {
    public let pose: CursorPose
    public let fill: CGColor
    public let unit: Double
    /// False during travel, press, visibility transitions, heading settle, and thinking sway.
    public let isSettled: Bool

    public init(pose: CursorPose, unit: Double, isSettled: Bool = true) {
        var pixels = pose
        pixels.center = pose.center * unit
        pixels.hotspot = pose.hotspot * unit
        pixels.haloCenter = pose.haloCenter * unit
        pixels.blurRadius *= unit
        self.pose = pixels
        self.unit = unit
        self.fill = CursorStyle.fill
        self.isSettled = isSettled
    }
}

/// Shared desktop pixels per overlay point for recordings and the key press pill.
public func sessionOverlayUnit(scale: Double, desktopHeight: Double) -> Double {
    max(scale, desktopHeight / 1080)
}
