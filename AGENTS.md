# Remora

A macos native desktop client for RDP & coming soon for VNC.

## Architecture

- Put behavior, invariants, and cleanup in deep modules with narrow interfaces. Expose intentional operations and typed recoverable failures.
- Keep product policy portable. Reach frameworks, external systems, and capabilities through narrow adapters chosen by constructor injection. Add a boundary only for durable replaceability or locality.
- Use Apple's Human Interface Guidelines for macOS 27 as the UI design baseline.
- Less code is better code: every line we own is maintenance. Prefer an Apple framework, FreeRDP, or a well-maintained library over writing our own, and cut features and flags that another path already covers.

## Agent skill

- When a change alters what the `remora` CLI does, update `skills/remora/SKILL.md` in the same change, with the smallest edit that keeps it true. The skill holds only what `remora --help` does not tell an agent.
