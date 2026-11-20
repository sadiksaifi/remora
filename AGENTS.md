# Remora

A native macOS desktop client for RDP and VNC.

## Architecture

- Put behavior, invariants, and cleanup in deep modules with narrow interfaces. Expose intentional operations and typed recoverable failures.
- Keep product policy portable. Reach frameworks, external systems, and capabilities through narrow adapters chosen by constructor injection. Add a boundary only for durable replaceability or locality.
- Use Apple's Human Interface Guidelines for macOS 27 as the UI design baseline.
- Less code is better code: every line we own is maintenance. Prefer an Apple framework, FreeRDP, LibVNCClient, or a well-maintained library over writing our own, and cut features and flags that another path already covers.

## Development

- Run tasks with `mise run`. `.mise.toml` defines them, and `mise tasks` lists them. Before a commit, run only the checks for what changed, such as `mise run test --filter <name>`. Before pushing or opening a PR, run `mise run check`.
- Commit messages and PR titles are Conventional Commits, since PRs are squash-merged. `mise run lint:commit <file>` checks one, and `mise run setup:hooks` installs a hook that checks each commit.
- CI runs `mise run check` on the GitHub `xcode-27` runner with `REMORA_AD_HOC_SIGNING=1`, `mise run lint:workflows`, and `mise run lint:commit` on the PR title. After changing `.github/`, run `mise run lint:workflows`.

## Agent interface

- Agents learn the `remora` CLI from its `--help` and from `error.hint`. When a change alters what the CLI does, update the command's help and the failure code's hint in `ControlFailure.Code.hint` in the same change. The build fails on a command without a description, and on a `remora ...` command in a hint or in the skill that no longer parses.
- `skills/remora/SKILL.md` holds only the policy that help cannot state.

## Verifying in the app

- Verify on the development app, Remora Dev, built and launched with `mise run launch`, with a temporary connection to the local test RDP target. Remora Dev keeps its own data, Keychain items, settings, control socket and links, apart from the installed Remora. Drive it with its own CLI, `build/DerivedData/Build/Products/Debug/Remora Dev.app/Contents/Helpers/remora`. Leave the installed `/Applications/Remora.app`, other running instances, the Penguin connection, saved connections, Keychain entries and the live `connections.json` untouched, and type no passwords.
- Keep remote captures under `.snap/`, and delete any test capture saved to the system screenshot location.
