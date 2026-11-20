# Remora

A native macOS desktop client for RDP and VNC.

## Architecture

- Put behavior, invariants, and cleanup in deep modules with narrow interfaces. Expose intentional operations and typed recoverable failures.
- Keep product policy portable. Reach frameworks, external systems, and capabilities through narrow adapters chosen by constructor injection. Add a boundary only for durable replaceability or locality.
- Use Apple's Human Interface Guidelines for macOS 27 as the UI design baseline.
- Less code is better code: every line we own is maintenance. Prefer an Apple framework, FreeRDP, LibVNCClient, or a well-maintained library over writing our own, and cut features and flags that another path already covers.

## Development

- Run tasks with `mise run`. Before a commit, run only the checks for what changed, such as `mise run test --filter <name>`. Before pushing or opening a PR, run `mise run check`.
- Verify changes in Remora Dev, which `mise run launch` builds and opens, and leave the installed Remora untouched.

## Agent interface

- Agents learn the `remora` CLI from its `--help` and from `error.hint`. When a change alters what the CLI does, update the command's help and the failure code's hint in `ControlFailure.Code.hint` in the same change. The build fails on a command without a description, and on a `remora ...` command in a hint or in the skill that no longer parses.
- `skills/remora/SKILL.md` holds only the policy that help cannot state.
