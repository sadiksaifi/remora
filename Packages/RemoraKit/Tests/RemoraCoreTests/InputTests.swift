import RemoraCore
import Testing

@Test func modifierTransitionsUseDeviceFlagsWhenTheEventHasNoKeyCode() {
    var state = KeyboardState()
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x100008) == [KeyInput(keyCode: 0x37, isDown: true)])
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x100018) == [KeyInput(keyCode: 0x36, isDown: true)])
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x100010) == [KeyInput(keyCode: 0x37, isDown: false)])
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0) == [KeyInput(keyCode: 0x36, isDown: false)])
}

@Test func aggregateModifiersPreserveKnownSidesWithoutAddingAnotherKey() {
    for (aggregate, left, right, rightMask): (UInt, UInt16, UInt16, UInt) in [
        (0x20000, 0x38, 0x3C, 0x04), (0x40000, 0x3B, 0x3E, 0x2000),
        (0x80000, 0x3A, 0x3D, 0x40), (0x100000, 0x37, 0x36, 0x10)
    ] {
        var state = KeyboardState()
        #expect(state.flagsChanged(keyCode: 0, rawFlags: aggregate) == [KeyInput(keyCode: left, isDown: true)])
        #expect(state.flagsChanged(keyCode: 0, rawFlags: aggregate).isEmpty)
        #expect(state.flagsChanged(keyCode: 0, rawFlags: 0) == [KeyInput(keyCode: left, isDown: false)])
        #expect(state.flagsChanged(keyCode: right, rawFlags: aggregate | rightMask) == [KeyInput(keyCode: right, isDown: true)])
        #expect(state.flagsChanged(keyCode: 0, rawFlags: aggregate).isEmpty)
        #expect(state.flagsChanged(keyCode: 0, rawFlags: 0) == [KeyInput(keyCode: right, isDown: false)])
    }
}

@Test func focusResetSuppressesHeldModifiersAcrossAggregateAndDeviceEvents() {
    var state = KeyboardState()
    state.reset(capsLockOn: false, rawFlags: 0x42000) // Right Control held at focus reset.
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x40000).isEmpty)
    #expect(state.flagsChanged(keyCode: 0x3B, rawFlags: 0x42001) == [KeyInput(keyCode: 0x3B, isDown: true)])
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x40000).isEmpty)
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0) == [KeyInput(keyCode: 0x3B, isDown: false)])
    #expect(state.flagsChanged(keyCode: 0, rawFlags: 0x40000) == [KeyInput(keyCode: 0x3B, isDown: true)])
}

@Test func eachModifierSideReleasesIndependently() {
    let modifiers: [(UInt16, UInt, UInt16, UInt)] = [
        (0x38, 0x02, 0x3C, 0x04), (0x3B, 0x01, 0x3E, 0x2000),
        (0x3A, 0x20, 0x3D, 0x40), (0x37, 0x08, 0x36, 0x10)
    ]
    for (left, leftMask, right, rightMask) in modifiers {
        var state = KeyboardState()
        #expect(state.flagsChanged(keyCode: left, rawFlags: leftMask) == [KeyInput(keyCode: left, isDown: true)])
        #expect(state.flagsChanged(keyCode: right, rawFlags: leftMask | rightMask) == [KeyInput(keyCode: right, isDown: true)])
        #expect(state.flagsChanged(keyCode: left, rawFlags: rightMask) == [KeyInput(keyCode: left, isDown: false)])
        #expect(state.releaseAll() == [KeyInput(keyCode: right, isDown: false)])
    }
}

@Test func capsLockTogglesWithCompleteStrokes() {
    var state = KeyboardState()
    let stroke = [KeyInput(keyCode: 0x39, isDown: true), KeyInput(keyCode: 0x39, isDown: false)]
    #expect(state.flagsChanged(keyCode: 0x39, rawFlags: 0x10000) == stroke)
    #expect(state.flagsChanged(keyCode: 0x39, rawFlags: 0x10000).isEmpty)
    #expect(state.releaseAll().isEmpty)
    #expect(state.flagsChanged(keyCode: 0x39, rawFlags: 0) == stroke)
    state.reset(capsLockOn: true)
    #expect(state.flagsChanged(keyCode: 0x39, rawFlags: 0x10000).isEmpty)
}

@Test func repeatsAndFocusLossKeepBalancedKeys() {
    var state = KeyboardState()
    #expect(state.key(keyCode: 0, isDown: true) == [KeyInput(keyCode: 0, isDown: true)])
    #expect(state.key(keyCode: 0, isDown: true) == [KeyInput(keyCode: 0, isDown: true)])
    #expect(state.key(keyCode: 0x38, isDown: true).isEmpty)
    #expect(state.releaseAll() == [KeyInput(keyCode: 0, isDown: false)])
    #expect(state.key(keyCode: 0, isDown: false).isEmpty)
}

@Test func trackpadRetainsFractionsAndDirectionOnBothAxes() {
    var scroll = ScrollAccumulator()
    #expect(scroll.accumulate(x: 0.1, y: -0.1, precise: true) == WheelInput(vertical: 0, horizontal: 0))
    #expect(scroll.accumulate(x: 0.4, y: -0.4, precise: true) == WheelInput(vertical: -1, horizontal: -1))
    #expect(scroll.accumulate(x: 0.5, y: -0.5, precise: true) == WheelInput(vertical: -2, horizontal: -2))
}

@Test func mouseWheelUsesNotchesAndResetDropsMomentumRemainder() {
    var scroll = ScrollAccumulator()
    #expect(scroll.accumulate(x: -2, y: 1, precise: false) == WheelInput(vertical: 120, horizontal: 240))
    _ = scroll.accumulate(x: 0.2, y: 0.2, precise: true)
    scroll.reset()
    #expect(scroll.accumulate(x: 0.2, y: 0.2, precise: true) == WheelInput(vertical: 0, horizontal: 0))
}
