---
name: remora
description: Remote desktop control through the Remora app's `remora` CLI, over RDP or VNC. Use when a task needs the screen of a remote Windows, Linux or Mac machine, or mentions Remora.
---

# Remora

`remora --help` and `remora COMMAND --help` describe every command, flag and limit. Pass `--json` to every command. When a command fails, follow `error.hint`.

## The loop

The screenshot is ground truth. A successful input command proves only that Remora sent the input.

1. Connect: `remora connect C --background --json`, where C is a name from `remora connection list --json`. Use the `connect` result's `session` value as S.
2. Observe: `remora screenshot --session S --output PATH --json`, then read the PNG.
3. Act on what the screenshot shows, passing its `image` value as `--image`.
4. Wait: `remora wait --for frame --after F --session S --json`, where F is the screenshot's `frame` value. Then go back to step 2.

The task is done when a screenshot shows the goal state. Report that screenshot's path.

## The user's control

- Ask the user before you accept a certificate or supply a password.
- `user-active` and `agent-stopped` mean the user took control. Follow the hint, and leave the session open.
- When the task ends, run `remora session stop --session S --json`. Then close S with `remora session close --session S --json` only if `connect` returned `reused: false` and the user did not take over or stop control during the task.
