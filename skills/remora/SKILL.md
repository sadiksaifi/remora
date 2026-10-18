---
name: remora
description: Control a remote Windows, Linux or Mac desktop through the Remora app's `remora` CLI. Use when asked to operate, inspect, test or automate a remote desktop or RDP session.
---

# Remora

Remora is a Mac remote desktop app. Its `remora` CLI lets you see and drive its sessions.
Run `remora --help` and `remora COMMAND --help` for every command, flag and limit. If this guide and the help disagree, the help is right.

## Loop: connect, observe, act, wait, verify

Replace C with a saved connection name or UUID (`remora connection list`). Replace S, I and F with the session UUID, image receipt and frame revision that commands return.

1. Connect: `remora connect C --background --json`. Save `result.session` as S.
2. Observe: `remora screenshot --session S --output /tmp/remora-shot.png --json`. Read the PNG. Save `result.image` as I and `result.frame` as F.
3. Act on what you saw: `remora click 100 200 --image I --session S --json`. With `--image`, coordinates are that screenshot's pixels from the top-left.
4. Wait: `remora wait --for frame --after F --session S --timeout 10s --json`.
5. Verify with a new screenshot before choosing the next action.

## Rules

- Record your work with `remora recording start --session S`; finish with `remora recording stop --session S`.
- Success means the input was sent, not that the remote app finished. Only a screenshot shows the result.
- Pass `--output` with a new path you can read. Remora never overwrites a file.
- `type` sends line breaks as Enter. Servers can drop characters their keyboard layout lacks, and some drop emoji. For those, and for long text, use `remora clipboard set --text "..." --session S`, then `remora key Ctrl+V --session S`.
- A long `type` keeps running until it finishes, up to 60 seconds. Wait for it to exit. Input sent meanwhile returns `input-busy`.
- After a timeout or a lost reply, check state and take a screenshot before repeating an action.

## Refusals

- `user-active`: the human took over. Stop sending input. Run `remora wait --for resumed --session S --timeout 1m --json`, and keep waiting if it times out. Never resume the session yourself. After Resume, take a new screenshot.
- `observation-required`: take a new screenshot, then retry.
- `input-busy`: another input command is running, or control is changing hands. Wait, observe, then retry.

Stop Agent Control is a soft stop: your next input takes control again. To leave control with the human, stop sending input.
