---
name: remora
description: Remote desktop control through the Remora app's `remora` CLI, over RDP or VNC. Use when a task needs the screen of a remote Windows, Linux or Mac machine, or mentions Remora.
---

# Remora

Remora is a Mac app for RDP and VNC. Its `remora` CLI sees and drives Remora's sessions.
`remora --help` and `remora COMMAND --help` list every command, flag, default and limit. Where this guide and the help disagree, the help is right.

Pass `--json` to every command. Each prints one envelope: `{"ok":true,"result":{...}}` or `{"ok":false,"error":{"code":...,"message":...,"hint":...}}`.

## The loop

The screenshot is ground truth. A successful input command proves only that Remora sent the input. What the remote app did shows up in the next screenshot.

C is a saved connection name or UUID from `remora connection list --json`. S, I and F are the `session`, `image` and `frame` values that commands return.

1. Connect: run `remora session list --json`, then `remora connect C --background --json`. Save `result.session` as S. If S was already in the list, the user opened this session, and `connect` reused it.
2. Observe: `remora screenshot --session S --output /tmp/remora-1.png --json`, then read the PNG. Save `result.image` as I and `result.frame` as F. Remora never overwrites a file, so give each screenshot a new path.
3. Act on what the screenshot shows: `remora click X Y --image I --session S --json`. With `--image`, X and Y are pixels in that screenshot from its top-left, so a screenshot shrunk with `--max-size` still maps to the right point.
4. Wait: `remora wait --for frame --after F --session S --timeout 10s --json`. A `frame-timeout` means the screen did not change. Observe anyway.
5. Go back to step 2. The task is done when a screenshot shows the goal state. Report that screenshot's path.

## Finish

When the task ends, done or abandoned, hand the session back:

1. Release control: `remora session stop --session S --json`. This returns control to the user.
2. If you opened S, close it: `remora session close --session S --json`. This disconnects the session and closes its tab. If the user opened S, leave it open.

## Input

- Send one input command at a time. A command sent while another runs fails with `input-busy`.
- `type` sends line breaks as Enter and can run for up to 60 seconds. Servers drop characters their keyboard layout lacks, and some drop emoji. For that text, and for long text, paste instead: `remora clipboard set --text "..." --session S --json`, then `remora key Ctrl+V --session S --json`. On a Mac, the chord is `Cmd+V`.
- After a `timeout` or `outcome-unknown` failure, the input may have landed. Take a screenshot before you repeat it.
- Record video only when the user asks for it or the task needs motion or timing: `remora recording start --session S --json`, then `remora recording stop --session S --json`.

## Failures

Most failures name their next step in `error.hint`. Follow it. These three need a decision the hint leaves out:

- `prompt-required`: Remora is waiting on a credentials or certificate prompt. P is the UUID in `error.details.prompt`. Show it with `remora prompt get P --json`, and ask the user before you accept a certificate or supply a password. Then answer with `remora prompt respond P connect --json` or `remora prompt respond P cancel --json`.
- `user-active`: the user took over the session, and Resume is theirs to press. Wait with `remora wait --for resumed --session S --timeout 1m --json`, and repeat the wait after each timeout. Then take a new screenshot.
- `cancelled` with the message "Agent control was stopped.": the user pressed Stop Agent Control. End the task, report the last screenshot, and leave the session open, including one you opened. Your next input command would take control back.
