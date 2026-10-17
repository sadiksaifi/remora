# Remote desktop input

Keyboard, five-button pointer, wheel, focus release, and remote cursor support are implemented on `feat/input`. Session window integration is the remaining follow-up in `feat/live-session`.

## Session window integration

After constructing the session and desktop view:

```swift
desktopView.input = session
```

In the existing session event switch on MainActor:

```swift
case .cursorChanged(let cursor):
    desktopView.apply(cursor: cursor)
```

The view becomes first responder when attached to its window. It enables mouse-move delivery and observes focus changes itself. `RDPSession.init` is MainActor-isolated because it snapshots Carbon's current input source and keyboard type. All session commands remain callable from any thread.

## Protocol

```swift
public protocol RemoteSession: AnyObject, Sendable {
    var events: AsyncStream<SessionEvent> { get }
    func connect()
    func disconnect()
    func sendKey(_ key: KeyInput)
    func sendPointer(position: RemotePoint, buttons: PointerButtons)
    func sendWheel(_ wheel: WheelInput)
    func synchronize(locks: LockKeys)
    func releaseAll()
}
```

`KeyInput` carries `keyCode: UInt16` and `isDown: Bool`. `RemotePoint` carries `x: UInt16` and `y: UInt16` in remote pixels. `PointerButtons` contains `.left`, `.right`, `.middle`, `.back`, and `.forward`. `WheelInput` carries signed `vertical: Int32` and `horizontal: Int32` in 1/120-notch units, positive up/right. `LockKeys` contains `.capsLock`, `.numLock`, and `.scrollLock`.

```swift
public enum RemoteCursor: Sendable, Equatable {
    case image(pixels: Data, width: Int, height: Int, hotspot: RemotePoint)
    case hidden
    case systemDefault
}

// Added to SessionEvent:
case cursorChanged(RemoteCursor)
```

Cursor images use tightly packed, straight-alpha BGRA bytes. Their dimensions and hotspot use remote pixels. The view scales both to points using the current desktop transform, including Retina scaling.

## Input behavior

Every input command enters a mutex-protected C queue and signals a manual-reset WinPR event. The session loop waits on that event with FreeRDP's handles. It detaches and drains the queue on the session thread. Resetting the wake event under the queue mutex prevents lost wakeups. Only consecutive pointer moves coalesce. Button transitions retain their coordinates and order.

The bridge tracks keys and buttons actually sent to FreeRDP. Release-all sends their matching releases. Focus loss resets view state and scroll remainders. Focus gain synchronizes lock keys. The last requested lock state is also synchronized after connection, so focus before connection does not lose it.

Ordinary key repeats are forwarded. The bridge sets FreeRDP's repeat flag when that key is already down. Modifier transitions use each side's NX_DEVICE mask and suppress duplicate flags events. Caps Lock changes produce complete down/up strokes. A local key-up monitor balances Command shortcuts even when AppKit consumes their key-up before responder dispatch.

Cmd-Q and Cmd-Ctrl-F stay local. No system shortcut event tap was added. Letterbox bars cannot start input or produce remote positions. A button release after dragging into a bar uses the last valid remote position to avoid a stuck button.

## Wheel conversion

Precise scroll deltas use 3 wheel units per point, or 40 points per notch. Mouse-wheel line deltas use 120 units per line. Each axis retains its fractional remainder. Momentum events pass through once.

Cocoa's positive horizontal delta points left. `ScrollAccumulator` negates X to express RDP's positive-right convention and preserves Y. This follows [SDL's Cocoa wheel adapter](https://github.com/libsdl-org/SDL/blob/main/src/video/cocoa/SDL_cocoamouse.m). It does not invert either axis using `isDirectionInvertedFromDevice`, because AppKit has already applied the natural scrolling preference.

FreeRDP's SDL3 client sends positive vertical values with `PTR_FLAGS_WHEEL` and positive horizontal values with `PTR_FLAGS_HWHEEL`. The bridge uses the same convention. It splits each axis into chunks of at most 255 units and encodes signed chunks with `chunk & 0x1FF`. For example, -120 becomes 0x188 and +120 becomes 0x078. Each axis gets its own flag, so a diagonal event never combines WHEEL and HWHEEL in one packet.

## Key mapping verification

The throwaway check at `/Users/sdk/Projects/Remora/.snap/input-check/check.c` printed WinPR's original result and the bridge result for every `kVK_*` constant in the installed Carbon `Events.h`. Its executable was deleted after the check. The unit test also checks all 120 constants against physical PC Set 1 expectations.

Bit 8 denotes an E0 prefix. Zero means unsupported. The table below uses ANSI/JIS mode. In ISO mode, `kVK_ISO_Section` maps to 0x0029 and `kVK_ANSI_Grave` maps to 0x0056, matching FreeRDP's Mac client correction. The keyboard type is captured once with `KBGetLayoutType(LMGetKbdType())`.

The bridge corrects right Control, disables Fn's erroneous right-Windows mapping, restores physical F13/F15, and fills keypad equals, JIS, media, and context-menu gaps. Eisu deliberately maps to Japanese NonConvert and Kana to Hiragana. Fn has no PC scancode and stays local. Real ANSI, ISO, and JIS hardware and remote IME behavior remain untested.

| Carbon key | Apple code | WinPR 3.32.2 | Bridge |
| --- | --- | --- | --- |
| `kVK_ANSI_A` | `0x00` | `0x001E` | `0x001E` |
| `kVK_ANSI_S` | `0x01` | `0x001F` | `0x001F` |
| `kVK_ANSI_D` | `0x02` | `0x0020` | `0x0020` |
| `kVK_ANSI_F` | `0x03` | `0x0021` | `0x0021` |
| `kVK_ANSI_H` | `0x04` | `0x0023` | `0x0023` |
| `kVK_ANSI_G` | `0x05` | `0x0022` | `0x0022` |
| `kVK_ANSI_Z` | `0x06` | `0x002C` | `0x002C` |
| `kVK_ANSI_X` | `0x07` | `0x002D` | `0x002D` |
| `kVK_ANSI_C` | `0x08` | `0x002E` | `0x002E` |
| `kVK_ANSI_V` | `0x09` | `0x002F` | `0x002F` |
| `kVK_ANSI_B` | `0x0B` | `0x0030` | `0x0030` |
| `kVK_ANSI_Q` | `0x0C` | `0x0010` | `0x0010` |
| `kVK_ANSI_W` | `0x0D` | `0x0011` | `0x0011` |
| `kVK_ANSI_E` | `0x0E` | `0x0012` | `0x0012` |
| `kVK_ANSI_R` | `0x0F` | `0x0013` | `0x0013` |
| `kVK_ANSI_Y` | `0x10` | `0x0015` | `0x0015` |
| `kVK_ANSI_T` | `0x11` | `0x0014` | `0x0014` |
| `kVK_ANSI_1` | `0x12` | `0x0002` | `0x0002` |
| `kVK_ANSI_2` | `0x13` | `0x0003` | `0x0003` |
| `kVK_ANSI_3` | `0x14` | `0x0004` | `0x0004` |
| `kVK_ANSI_4` | `0x15` | `0x0005` | `0x0005` |
| `kVK_ANSI_6` | `0x16` | `0x0007` | `0x0007` |
| `kVK_ANSI_5` | `0x17` | `0x0006` | `0x0006` |
| `kVK_ANSI_Equal` | `0x18` | `0x000D` | `0x000D` |
| `kVK_ANSI_9` | `0x19` | `0x000A` | `0x000A` |
| `kVK_ANSI_7` | `0x1A` | `0x0008` | `0x0008` |
| `kVK_ANSI_Minus` | `0x1B` | `0x000C` | `0x000C` |
| `kVK_ANSI_8` | `0x1C` | `0x0009` | `0x0009` |
| `kVK_ANSI_0` | `0x1D` | `0x000B` | `0x000B` |
| `kVK_ANSI_RightBracket` | `0x1E` | `0x001B` | `0x001B` |
| `kVK_ANSI_O` | `0x1F` | `0x0018` | `0x0018` |
| `kVK_ANSI_U` | `0x20` | `0x0016` | `0x0016` |
| `kVK_ANSI_LeftBracket` | `0x21` | `0x001A` | `0x001A` |
| `kVK_ANSI_I` | `0x22` | `0x0017` | `0x0017` |
| `kVK_ANSI_P` | `0x23` | `0x0019` | `0x0019` |
| `kVK_ANSI_L` | `0x25` | `0x0026` | `0x0026` |
| `kVK_ANSI_J` | `0x26` | `0x0024` | `0x0024` |
| `kVK_ANSI_Quote` | `0x27` | `0x0028` | `0x0028` |
| `kVK_ANSI_K` | `0x28` | `0x0025` | `0x0025` |
| `kVK_ANSI_Semicolon` | `0x29` | `0x0027` | `0x0027` |
| `kVK_ANSI_Backslash` | `0x2A` | `0x002B` | `0x002B` |
| `kVK_ANSI_Comma` | `0x2B` | `0x0033` | `0x0033` |
| `kVK_ANSI_Slash` | `0x2C` | `0x0035` | `0x0035` |
| `kVK_ANSI_N` | `0x2D` | `0x0031` | `0x0031` |
| `kVK_ANSI_M` | `0x2E` | `0x0032` | `0x0032` |
| `kVK_ANSI_Period` | `0x2F` | `0x0034` | `0x0034` |
| `kVK_ANSI_Grave` | `0x32` | `0x0029` | `0x0029` |
| `kVK_ANSI_KeypadDecimal` | `0x41` | `0x0053` | `0x0053` |
| `kVK_ANSI_KeypadMultiply` | `0x43` | `0x0037` | `0x0037` |
| `kVK_ANSI_KeypadPlus` | `0x45` | `0x004E` | `0x004E` |
| `kVK_ANSI_KeypadClear` | `0x47` | `0x0045` | `0x0045` |
| `kVK_ANSI_KeypadDivide` | `0x4B` | `0x0135` | `0x0135` |
| `kVK_ANSI_KeypadEnter` | `0x4C` | `0x011C` | `0x011C` |
| `kVK_ANSI_KeypadMinus` | `0x4E` | `0x004A` | `0x004A` |
| `kVK_ANSI_KeypadEquals` | `0x51` | `0x0000` | `0x0059` |
| `kVK_ANSI_Keypad0` | `0x52` | `0x0052` | `0x0052` |
| `kVK_ANSI_Keypad1` | `0x53` | `0x004F` | `0x004F` |
| `kVK_ANSI_Keypad2` | `0x54` | `0x0050` | `0x0050` |
| `kVK_ANSI_Keypad3` | `0x55` | `0x0051` | `0x0051` |
| `kVK_ANSI_Keypad4` | `0x56` | `0x004B` | `0x004B` |
| `kVK_ANSI_Keypad5` | `0x57` | `0x004C` | `0x004C` |
| `kVK_ANSI_Keypad6` | `0x58` | `0x004D` | `0x004D` |
| `kVK_ANSI_Keypad7` | `0x59` | `0x0047` | `0x0047` |
| `kVK_ANSI_Keypad8` | `0x5B` | `0x0048` | `0x0048` |
| `kVK_ANSI_Keypad9` | `0x5C` | `0x0049` | `0x0049` |
| `kVK_Return` | `0x24` | `0x001C` | `0x001C` |
| `kVK_Tab` | `0x30` | `0x000F` | `0x000F` |
| `kVK_Space` | `0x31` | `0x0039` | `0x0039` |
| `kVK_Delete` | `0x33` | `0x000E` | `0x000E` |
| `kVK_Escape` | `0x35` | `0x0001` | `0x0001` |
| `kVK_Command` | `0x37` | `0x015B` | `0x015B` |
| `kVK_Shift` | `0x38` | `0x002A` | `0x002A` |
| `kVK_CapsLock` | `0x39` | `0x003A` | `0x003A` |
| `kVK_Option` | `0x3A` | `0x0038` | `0x0038` |
| `kVK_Control` | `0x3B` | `0x001D` | `0x001D` |
| `kVK_RightCommand` | `0x36` | `0x015C` | `0x015C` |
| `kVK_RightShift` | `0x3C` | `0x0036` | `0x0036` |
| `kVK_RightOption` | `0x3D` | `0x0138` | `0x0138` |
| `kVK_RightControl` | `0x3E` | `0x015C` | `0x011D` |
| `kVK_Function` | `0x3F` | `0x015C` | `0x0000` |
| `kVK_F17` | `0x40` | `0x0068` | `0x0068` |
| `kVK_VolumeUp` | `0x48` | `0x0000` | `0x0130` |
| `kVK_VolumeDown` | `0x49` | `0x0000` | `0x012E` |
| `kVK_Mute` | `0x4A` | `0x0000` | `0x0120` |
| `kVK_F18` | `0x4F` | `0x0069` | `0x0069` |
| `kVK_F19` | `0x50` | `0x006A` | `0x006A` |
| `kVK_F20` | `0x5A` | `0x006B` | `0x006B` |
| `kVK_F5` | `0x60` | `0x003F` | `0x003F` |
| `kVK_F6` | `0x61` | `0x0040` | `0x0040` |
| `kVK_F7` | `0x62` | `0x0041` | `0x0041` |
| `kVK_F3` | `0x63` | `0x003D` | `0x003D` |
| `kVK_F8` | `0x64` | `0x0042` | `0x0042` |
| `kVK_F9` | `0x65` | `0x0043` | `0x0043` |
| `kVK_F11` | `0x67` | `0x0057` | `0x0057` |
| `kVK_F13` | `0x69` | `0x0137` | `0x0064` |
| `kVK_F16` | `0x6A` | `0x0067` | `0x0067` |
| `kVK_F14` | `0x6B` | `0x0065` | `0x0065` |
| `kVK_F10` | `0x6D` | `0x0044` | `0x0044` |
| `kVK_ContextualMenu` | `0x6E` | `0x0000` | `0x015D` |
| `kVK_F12` | `0x6F` | `0x0058` | `0x0058` |
| `kVK_F15` | `0x71` | `0x0146` | `0x0066` |
| `kVK_Help` | `0x72` | `0x0152` | `0x0152` |
| `kVK_Home` | `0x73` | `0x0147` | `0x0147` |
| `kVK_PageUp` | `0x74` | `0x0149` | `0x0149` |
| `kVK_ForwardDelete` | `0x75` | `0x0153` | `0x0153` |
| `kVK_F4` | `0x76` | `0x003E` | `0x003E` |
| `kVK_End` | `0x77` | `0x014F` | `0x014F` |
| `kVK_F2` | `0x78` | `0x003C` | `0x003C` |
| `kVK_PageDown` | `0x79` | `0x0151` | `0x0151` |
| `kVK_F1` | `0x7A` | `0x003B` | `0x003B` |
| `kVK_LeftArrow` | `0x7B` | `0x014B` | `0x014B` |
| `kVK_RightArrow` | `0x7C` | `0x014D` | `0x014D` |
| `kVK_DownArrow` | `0x7D` | `0x0150` | `0x0150` |
| `kVK_UpArrow` | `0x7E` | `0x0148` | `0x0148` |
| `kVK_ISO_Section` | `0x0A` | `0x0056` | `0x0056` |
| `kVK_JIS_Yen` | `0x5D` | `0x0000` | `0x007D` |
| `kVK_JIS_Underscore` | `0x5E` | `0x0000` | `0x0073` |
| `kVK_JIS_KeypadComma` | `0x5F` | `0x0053` | `0x007E` |
| `kVK_JIS_Eisu` | `0x66` | `0x0000` | `0x007B` |
| `kVK_JIS_Kana` | `0x68` | `0x0000` | `0x0070` |

## Validation

- `swift build --package-path Packages/RemoraKit` passed.
- `swift test --package-path Packages/RemoraKit` passed all eight tests. New tests cover key mapping, ISO positions, modifier sides, Caps Lock, repeats/releases, and scroll accumulation.
- `xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Debug -derivedDataPath "$PWD/.build/xcode" build` passed with no warnings from project code. Xcode emitted its AppIntents metadata warning because the app does not link AppIntents.
- No RDP server was available. Input delivery and cursor rendering against a live server remain unverified.
- `Vendor/build` links to `/Users/sdk/Projects/Remora/.snap/engine/Vendor/build`. The engine build script was not run.
- `SessionWindowController.swift`, `SessionWindows.swift`, `AppDelegate.swift`, and `project.yml` were not edited.

## Files

- `Packages/RemoraKit/Package.swift`
- `Packages/RemoraKit/Sources/CFreeRDPBridge/include/CFreeRDPBridge.h`
- `Packages/RemoraKit/Sources/CFreeRDPBridge/input.h`
- `Packages/RemoraKit/Sources/CFreeRDPBridge/input.c`
- `Packages/RemoraKit/Sources/CFreeRDPBridge/session.c`
- `Packages/RemoraKit/Sources/RDPSession/KeyboardLayout.swift`
- `Packages/RemoraKit/Sources/RDPSession/RDPSession.swift`
- `Packages/RemoraKit/Sources/RemoraCore/Input.swift`
- `Packages/RemoraKit/Sources/RemoraCore/RemoteSession.swift`
- `Packages/RemoraKit/Tests/RemoraCoreTests/InputTests.swift`
- `Packages/RemoraKit/Tests/RemoraCoreTests/KeyMappingTests.swift`
- `Remora/RemoteDesktopCursor.swift`
- `Remora/RemoteDesktopInput.swift`
- `Remora/RemoteDesktopView.swift`
- `docs/input.md`
