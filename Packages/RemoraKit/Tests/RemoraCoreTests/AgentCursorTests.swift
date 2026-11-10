import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import RemoraCore

private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
private let moves: [(from: CGPoint, to: CGPoint, marks: [(Double, Double)])] = [
    (
        CGPoint(x: 116, y: 766), CGPoint(x: 781, y: 266),
        [(0.25, 0.108), (0.50, 0.142), (0.75, 0.192), (0.90, 0.267), (0.95, 0.308)]
    ),
    (
        CGPoint(x: 422, y: 464), CGPoint(x: 121, y: 771),
        [(0.25, 0.083), (0.50, 0.117), (0.75, 0.150), (0.90, 0.200), (0.95, 0.233)]
    ),
]

@Test func cursorMatchesMeasuredTravel() throws {
    for (index, move) in moves.enumerated() {
        let name = index == 0 ? "move-a-831pt" : "move-b-430pt"
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "CursorReference"))
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst().map { row in
            row.split(separator: ",").map { Double($0)! }
        }
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let recordedEnd = CGPoint(x: last[1], y: last[2])
        let recordedChord = distance(CGPoint(x: first[1], y: first[2]), recordedEnd)
        var cursor = CursorMotion(hotspot: move.from, bounds: bounds)
        cursor.isVisible = true
        cursor.step(1)
        cursor.move(to: move.to)
        let end = CGPoint(x: move.to.x - cursor.restTipOffset.x, y: move.to.y - cursor.restTipOffset.y)
        let chord = distance(cursor.center, end)
        var reached: [Double: Double] = [:]
        for tick in 1...180 {
            cursor.step(1.0 / 120)
            let covered = 1 - distance(cursor.center, end) / chord
            for (fraction, _) in move.marks where reached[fraction] == nil && covered >= fraction {
                reached[fraction] = Double(tick) / 120
            }
        }
        for (fraction, _) in move.marks {
            let sample = try #require(rows.first { 1 - distance(CGPoint(x: $0[1], y: $0[2]), recordedEnd) / recordedChord >= fraction })
            let measured = sample[0] - first[0]
            #expect(abs((reached[fraction] ?? .infinity) - measured) <= 0.03)
        }
    }
}

@Test func cursorArrivesExactlyAcrossGlyphAndRecorderScales() {
    for size in [1.0, 2, 3] {
        for move in moves {
            var cursor = CursorMotion(hotspot: move.from, bounds: bounds, size: size)
            cursor.isVisible = true
            cursor.step(1)
            cursor.move(to: move.to)
            let delay = cursor.arrivalDelay
            var stepped = cursor
            var elapsed = 0.0
            while stepped.isMoving {
                stepped.step(1.0 / 480)
                elapsed += 1.0 / 480
            }
            #expect(abs(delay - elapsed) < 0.000001)
            cursor.step(delay)
            #expect(!cursor.isMoving)
            #expect(distance(cursor.pose.hotspot, move.to) < 0.5)
            for unit in [1.0, 2] {
                let frame = AgentCursorFrame(pose: cursor.pose, unit: unit)
                #expect(distance(frame.pose.hotspot, CGPoint(x: move.to.x * unit, y: move.to.y * unit)) < 0.5)
            }
        }
    }
}

@Test(arguments: [0.0, 18, -18])
func cursorScootTiltDependsOnlyOnSignedHorizontalVelocity(dx: Double) {
    let start = CGPoint(x: 400, y: 400)
    for dy in [dx == 0 ? 30.0 : 24.0, dx == 0 ? -30.0 : -24.0] {
        var diagonal = CursorMotion(hotspot: start, bounds: bounds)
        diagonal.isVisible = true
        diagonal.step(1)
        var horizontal = diagonal
        diagonal.move(to: CGPoint(x: start.x + dx, y: start.y + dy))
        horizontal.move(to: CGPoint(x: start.x + dx, y: start.y))
        diagonal.step(0.1)
        horizontal.step(0.1)
        // Both straight scoots have the same horizontal velocity at every instant.
        #expect(abs(diagonal.pose.rotation - horizontal.pose.rotation) < 0.000001)
        if dx == 0 {
            #expect(abs(diagonal.pose.rotation - CursorTuning.restRotation) < 0.000001)
        } else {
            #expect((diagonal.pose.rotation - CursorTuning.restRotation) * dx > 0)
        }
    }
}

@Test func cursorTimeIsIndependentOfReadersAndMonotonic() {
    var base = CursorMotion(hotspot: moves[0].from, bounds: bounds, time: 100)
    base.isVisible = true
    base.move(to: moves[0].to)
    var sixty = base
    var oneTwenty = base
    var once = base
    for tick in 1...30 { sixty.advance(to: 100 + Double(tick) / 60) }
    for tick in 1...60 { oneTwenty.advance(to: 100 + Double(tick) / 120) }
    once.advance(to: 100.5)
    #expect(distance(sixty.pose.center, once.pose.center) < 0.000001)
    #expect(distance(oneTwenty.pose.center, once.pose.center) < 0.000001)
    #expect(abs(sixty.pose.rotation - once.pose.rotation) < 0.000001)
    let pose = once.pose
    once.advance(to: 99)
    #expect(once.pose.center == pose.center)
    once.advance(to: 10_000)
    #expect(!once.isMoving)
    #expect(distance(once.pose.hotspot, moves[0].to) < 0.5)
    #expect(once.isSettled)
}

@Test func cursorDragPinsEverySampleAndPress() {
    var cursor = CursorMotion(hotspot: .zero, bounds: bounds)
    cursor.isVisible = true
    cursor.step(1)
    cursor.pressDown(depth: CursorTuning.dragDepth)
    for tick in 1...50 {
        let sample = CGPoint(x: tick * 10, y: tick * 5)
        cursor.follow(to: sample)
        cursor.step(1.0 / 60)
        #expect(distance(cursor.pose.hotspot, sample) < 0.000001)
    }
    #expect(!cursor.isMoving)
    cursor.release()
    cursor.step(2)
    #expect(cursor.isSettled)
}

@Test func cursorInterruptedMoveSettlesAcrossAFullHeadingTurn() {
    var cursor = CursorMotion(hotspot: CGPoint(x: 756, y: 491), bounds: bounds)
    cursor.isVisible = true
    cursor.step(1)
    cursor.move(to: CGPoint(x: 647, y: 100))
    cursor.step(0.279)
    let target = CGPoint(x: 1003, y: 746)
    cursor.move(to: target)
    #expect(!cursor.isSettled)
    for _ in 0..<180 { cursor.step(1.0 / 60) }
    #expect(!cursor.isMoving)
    #expect(distance(cursor.pose.hotspot, target) < 0.5)
    let error = cursor.pose.rotation - CursorTuning.restRotation
    #expect(abs(atan2(sin(error), cos(error))) < 0.0001)
    #expect(cursor.isSettled)
}

@Test(arguments: [false, true])
func cursorVisibilityBlurFollowsOpacity(reduceMotion: Bool) {
    var cursor = CursorMotion(hotspot: CGPoint(x: 400, y: 400), bounds: bounds)
    cursor.reduceMotion = reduceMotion
    for visible in [true, false] {
        cursor.isVisible = visible
        cursor.step(0.05)
        #expect(cursor.pose.opacity > 0 && cursor.pose.opacity < 1)
        let expectedBlur = reduceMotion ? 0 : (1 - cursor.pose.opacity) * 5
        #expect(abs(cursor.pose.blurRadius - expectedBlur) < 0.000001)
        for unit in [1.0, 2] {
            let frame = AgentCursorFrame(pose: cursor.pose, unit: unit)
            let sprite = SessionOverlayDrawing().agentCursor(frame)
            #expect(abs(frame.pose.blurRadius / unit - expectedBlur) < 0.000001)
            #expect(abs(sprite.blurRadius - expectedBlur * unit) < 0.000001)
        }
        for _ in 0..<120 {
            cursor.step(1.0 / 120)
            let expectedBlur = reduceMotion ? 0 : (1 - cursor.pose.opacity) * 5
            #expect(abs(cursor.pose.blurRadius - expectedBlur) < 0.000001)
        }
        #expect(abs(cursor.pose.opacity - (visible ? 1 : 0)) < 0.0001)
        #expect(cursor.isSettled)
        if reduceMotion {
            #expect(cursor.pose.scaleAcross == 1 && cursor.pose.scaleAlong == 1)
        }
    }
}

@Test func cursorReducedMotionCrossfadesWithoutStretchOrSway() {
    var cursor = CursorMotion(hotspot: moves[0].from, bounds: bounds)
    cursor.reduceMotion = true
    cursor.isVisible = true
    cursor.isThinking = true
    cursor.step(1)
    cursor.move(to: moves[0].to)
    #expect(abs(cursor.arrivalDelay - 0.2) < 0.000001)
    cursor.step(0.05)
    #expect(abs(cursor.pose.opacity - 0.5) < 0.000001)
    #expect(distance(cursor.pose.hotspot, moves[0].from) < 0.5)
    cursor.step(0.05)
    #expect(cursor.pose.opacity < 0.000001)
    #expect(distance(cursor.pose.hotspot, moves[0].to) < 0.5)
    cursor.step(0.1)
    #expect(abs(cursor.pose.opacity - 1) < 0.000001)
    #expect(!cursor.isMoving)
    #expect(cursor.pose.scaleAcross == 1 && cursor.pose.scaleAlong == 1)
    #expect(cursor.pose.rotation == CursorTuning.restRotation)
    #expect(cursor.pose.blurRadius == 0)
    cursor.pressDown()
    cursor.step(0.1)
    #expect(cursor.pose.scaleAcross < 0.8)
}

@Test func cursorThinkingWindowAndSettling() {
    var cursor = CursorMotion(hotspot: .zero, bounds: bounds)
    cursor.isVisible = true
    cursor.step(2)
    #expect(cursor.isSettled)
    cursor.thinkingWindow = 2.5..<32
    cursor.advance(to: 2.5)
    #expect(abs(cursor.pose.rotation - CursorTuning.restRotation) < 0.000001)
    cursor.advance(to: 2.6)
    #expect(cursor.pose.rotation > CursorTuning.restRotation)
    #expect(!cursor.isSettled)
    cursor.advance(to: 31.99)
    let rotation = cursor.pose.rotation
    cursor.advance(to: 32)
    #expect(abs(cursor.pose.rotation - rotation) < 0.02)
    cursor.advance(to: 34)
    #expect(cursor.isSettled)
    cursor.isVisible = false
    cursor.step(0.01)
    #expect(!cursor.isSettled)
    cursor.step(2)
    #expect(cursor.isSettled)
}

@Test func cursorAndDisplayLinkUseTheSameClock() {
    let before = ProcessInfo.processInfo.systemUptime
    let displayTime = CACurrentMediaTime()
    let after = ProcessInfo.processInfo.systemUptime
    #expect(displayTime >= before - 0.001 && displayTime <= after + 0.001)
}
