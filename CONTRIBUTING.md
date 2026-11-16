# Contributing

Nopal is a native Swift app with no third-party runtime dependencies. Keep it that way unless a reviewed security or reliability need justifies a dependency.

## Before you start

- Read `docs/superpowers/specs/2026-11-16-nopal-design.md` and `docs/THREAT-MODEL.md`.
- Do not add telemetry, analytics, network calls, accounts, or cloud storage.
- Do not weaken data-integrity behavior to make a test or UI simpler.

## Build and test

```sh
cd Nopal
./scripts/test-core.sh        # core tests, no UI required
./scripts/build-app.sh        # universal developer app bundle
swift build                   # package build
```

Run `./scripts/test-core.sh` before proposing a change. If you touch the vault adapter, also exercise a real create/unlock/eject/export cycle on macOS and describe what you tested.

## Style

- Swift, deployment target macOS 13, universal architectures.
- Prefer small types with explicit state over implicit booleans.
- Typed errors, `LocalizedError` messages that tell the user what happened and what to do next.
- No secrets in logs, error strings, activity history, configuration exports, process arguments, or temporary plaintext files.
- Destructive operations require explicit confirmation and must never overwrite or delete user data implicitly.
- UI text must state what a feature does and does not protect.

## Data-integrity rules

- Never report success before the operating system confirms the result.
- Never force-detach a busy vault.
- Never auto-delete an interrupted or ambiguous vault; offer to finish setup instead.
- Import and export copy and verify; the source stays unchanged.
- Authentication cancellation returns to the previous locked state.

## Review

Changes that touch vault creation, Keychain access, recovery, or relock behavior need a second reviewer and a written test note covering cancellation, busy files, and failure paths. See `SECURITY.md` for the threat model summary.
