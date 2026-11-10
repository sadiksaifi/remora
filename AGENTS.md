# Remora

A native macOS desktop client for RDP and VNC.

## Architecture

- Put behavior, invariants, and cleanup in deep modules with narrow interfaces. Expose intentional operations and typed recoverable failures.
- Keep product policy portable. Reach frameworks, external systems, and capabilities through narrow adapters chosen by constructor injection. Add a boundary only for durable replaceability or locality.
- Use Apple's Human Interface Guidelines for macOS 27 as the UI design baseline.
- Less code is better code: every line we own is maintenance. Prefer an Apple framework, FreeRDP, LibVNCClient, or a well-maintained library over writing our own, and cut features and flags that another path already covers.

## Development

- `mise install` installs the pinned tools, and `mise tasks` lists the tasks. Run `mise run engine` once before the first `mise run build` or `mise run test`.

## Agent skill

- When a change alters what the `remora` CLI does, update `skills/remora/SKILL.md` in the same change, with the smallest edit that keeps it true. The skill holds only what `remora --help` does not tell an agent.

## Verifying in the app

- Verify on a development build you launch yourself, with a temporary connection to the local test RDP target. Leave the installed `/Applications/Remora.app`, other running instances, the Penguin connection, saved connections, Keychain entries and the live `connections.json` untouched, and type no passwords.
- Keep remote captures under `.snap/`, and delete any test capture saved to the system screenshot location.
