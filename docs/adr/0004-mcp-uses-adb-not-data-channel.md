# ADR-0004: MCP uses adb, not Data Channel (for now)

## Status

Accepted — 2026-07-31

## Context

DroidMate’s GUI talks to the device over the **Data Channel** (custom TCP framing via adb forward + DroidMate Server jar). Agents use the separate **DroidMateMCP** executable.

It is natural to ask whether MCP should share the Data Channel so agents and the GUI see the same FS semantics (`exists`/`is_dir`, FS mutations, resume markers).

## Decision

**MCP remains adb-based** for tools (shell, pull/push, pm, input, etc.). It does **not** open a Data Channel session in v0.2.

## Rationale

1. **Independence** — Agents can work without the Mac GUI running, and without competing for the single server port/session.
2. **Scope** — Full Data Channel reuse needs a shared library (`Protocol` + transport + transfer engine), jar packaging for MCP, and careful multi-client rules on the Android server.
3. **Parity where it matters** — MCP already approximates GUI semantics with dedicated tools (`path_exists`, protected `delete_path`, clearer `list_files` missing-path errors).
4. **Risk** — Wiring MCP into TransferEngine/`@MainActor` UI types would couple agent automation to AppKit/SwiftUI lifecycle.

## Consequences

- Agents use **adb**; the app uses **Data Channel** for interactive file UX.
- Future “MCP Data Channel” is a **new ADR** after extracting a Foundation-only core and defining multi-session server behavior.
- Docs (`docs/MCP.md`) state explicitly that MCP does not use the Data Channel.

## Alternatives considered

| Option | Why not now |
|--------|-------------|
| MCP spawns its own server + forward | Port conflicts with GUI; jar/bootstrap duplication |
| MCP attaches to running GUI via XPC | Requires GUI always on; new IPC surface |
| Shared library only (no MCP connect yet) | Prep: **DroidMateWire** ships Protocol + adb bootstrap (`AdbLocator`/`ServerLauncher`); MCP uses shared adb location but still no Data Channel session |
