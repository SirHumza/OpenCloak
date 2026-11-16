# Nopal

Nopal is an open-source macOS privacy app for encrypted file vaults and local app/website privacy screens. It uses native SwiftUI, AppKit, Keychain, LocalAuthentication, and macOS disk images. It has no account, telemetry, advertising, or required network service.

## Build

Requires macOS 13 or later and Xcode Command Line Tools. Build a universal Apple silicon + Intel app bundle with:

```sh
./scripts/build-app.sh
open .build/nopal-app/Nopal.app
```

The app is an unsigned development build. macOS may require you to approve opening it. For a local Intel-only check, use the `x86_64-apple-macosx13.0` target in the build script. Run core and disk-image tests with:

```sh
./scripts/test-core.sh
./scripts/test-hdiutil.sh
```

`swift build` also works with a complete Xcode installation. The local Command Line Tools-only environment used during development lacks SwiftPM's manifest API and XCTest, so the scripts above provide direct compiler-based validation.

## Features

- Create, unlock, eject, import, and export AES-256 encrypted sparse-bundle vaults. Import verifies the encrypted bundle copy; the existing vault password or recovery key is checked on first unlock.
- Keep vault credentials in the macOS Keychain behind native user authentication. macOS may offer Touch ID, Apple Watch, or the account password, depending on hardware and settings.
- Display a recovery key once at vault creation. Imported vaults retain their existing credentials and enroll in Keychain after a successful first unlock.
- Relock mounted vaults on screen lock, sleep, or configured inactivity. Busy vaults remain visibly mounted until macOS allows ejection.
- Add local app and website privacy rules. Nopal uses a blurred full-screen overlay across connected displays and asks macOS for authentication.
- Record a limited local activity log with no app names, vault names, file names, URLs, or credentials.

## Security boundary

Vault contents are encrypted while the vault is unmounted. A mounted vault is accessible to the logged-in session. Nopal's app privacy screen appears after macOS reports the protected app as active; it cannot prevent the app or background helpers from starting, and content may appear before the overlay. Website screens read only the active tab URL in supported browsers after macOS Automation permission. They are convenience screens, not browser-enforced access controls.

Read [SECURITY.md](SECURITY.md), [the threat model](docs/THREAT-MODEL.md), and [the feature/permission matrix](docs/FEATURES.md) before relying on Nopal for sensitive data. This project is under active development and is not a substitute for FileVault, OS updates, or a separate backup.

## License

MIT. See [LICENSE](LICENSE).

## Validation coverage

`./scripts/test-core.sh` runs deterministic state, rule persistence, corruption-preservation, event-retention, and website matching tests. `./scripts/test-hdiutil.sh` exercises repeated encrypted APFS create, wrong-key rejection, read-only remount, content integrity, and eject cycles on macOS. UI automation behavior depends on per-user Automation permission and should be checked on each supported macOS release.
