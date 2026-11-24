# Design

The direction behind Remora's own UI.

## Principles

- **System first.** Follow [Apple's Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) for macOS 27 and later. Remora looks as if Apple built it: stock controls, system colors, SF Symbols, and the system's own Liquid Glass. A deviation is taste, listed below with its reason.
- **The remote screen is the content.** Controls live in the toolbar and the menus. A note over a live remote screen is short and leaves by itself.
- **One window.** A session is a tab in the main window.
- **The menu bar has every command.** Toolbar buttons, context menus and shortcuts repeat it.
- **One state, one signal.** A tab shows one icon. The state the person must act on wins.
- **A person outranks an agent.** While a command-line program controls a session, the window says so and Take Over is one click away.

## Taste

- **The tab strip is ours.** System window tabs can leave their window, and a session stays in the main one.
- **Glass holds plain fills.** A selected or hovered part inside a glass surface takes a plain fill, because glass on glass doubles the rims.
