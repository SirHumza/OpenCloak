# OpenCloak

OpenCloak is an open-source macOS privacy app for encrypted file vaults and local app/website privacy screens. It uses native SwiftUI, AppKit, Keychain, LocalAuthentication, and macOS disk images. It has no account, telemetry, advertising, or required network service.

## Project progress

<progress value="18" max="20">18 of 20 feature areas implemented</progress> **18 of 20 feature areas implemented** (including best-effort integrations). App and website screens are privacy overlays, not OS-enforced access controls. The two unimplemented areas and platform boundaries are listed in [the feature matrix](docs/FEATURES.md).

## Build

Requires macOS 12 Monterey or later and Xcode Command Line Tools. (The design spec proposed macOS 13; the UI avoids Ventura-only SwiftUI so the app can build and run on Monterey as well.) Build a universal Apple silicon + Intel app bundle with:

```sh
./scripts/build-app.sh
open .build/opencloak-app/OpenCloak.app
```

The app is an unsigned development build. macOS may require you to approve opening it. For a local Intel-only check, use the `x86_64-apple-macosx12.0` target in the build script. The script ad-hoc signs the bundle because arm64 refuses to execute unsigned binaries. Run core, disk-image, and permission tests with:

```sh
./scripts/test-core.sh
./scripts/test-hdiutil.sh
./scripts/test-permissions.sh
```

`test-permissions.sh` compiles the shipping browser-permission code and reports, using only the non-prompting APIs, whether user-presence authentication exists and what Automation status each supported browser currently has. A denial is printed rather than treated as a test failure, because granting it needs a person.

To distribute the app, replace the ad-hoc signature with a Developer ID signature, hardened runtime, and a notarization ticket:

```sh
OPENCLOAK_NOTARY_PROFILE=opencloak ./scripts/release-app.sh
```

This needs a paid Apple Developer account and a `notarytool` keychain profile. Without a certificate the script stops and lists the identities it found, rather than producing a bundle that silently fails Gatekeeper.

`swift build` also works with a complete Xcode installation. The local Command Line Tools-only environment used during development lacks SwiftPM's manifest API and XCTest, so the scripts above provide direct compiler-based validation.

## Features

- Set up a separate OpenCloak password and one-time recovery key. Touch ID is available where macOS supports it; the Mac account password is not accepted for OpenCloak-owned protection.
- Create, unlock, eject, import, and export AES-256 encrypted sparse-bundle vaults. Vault credentials are kept in the Keychain and protected by macOS user-presence controls.
- Encrypt and hide application bundles, and lock individual files or folders by moving verified copies into encrypted sparse bundles. Hidden apps can be opened from their encrypted volume without restoring their original path.
- In Finder, use Services → “Lock with OpenCloak” or “Hide with OpenCloak” on a selected file, folder, or app.
- Add app launch privacy rules and website rules. App rules are post-launch privacy screens, not process blockers. Website rules monitor the active tab through macOS Automation in Safari, Chrome, Brave, Edge, and Vivaldi.
- Configure app schedules and a native-looking fake-crash dialog, global shortcuts, menu-bar visibility, optional intruder photos, and relocking on sleep, screen lock, or inactivity.
- Keep local activity history without recording filenames, vault names, URLs, or credentials.

See [the feature and permission matrix](docs/FEATURES.md) for limitations. Visible in-place folder locks with Finder badges and privileged process blocking remain unimplemented; app and website gates are best-effort overlays. OpenCloak does not claim system-level enforcement against an administrator or a user who disables it.

## Security boundary

Vault contents are encrypted while the vault is unmounted. A mounted vault is accessible to the logged-in session. OpenCloak's app privacy screen appears after macOS reports the protected app as active; it cannot prevent the app or background helpers from starting, and content may appear before the overlay. Website screens read only the active tab URL in supported browsers after macOS Automation permission. They are convenience screens, not browser-enforced access controls.

Read [SECURITY.md](SECURITY.md), [the threat model](docs/THREAT-MODEL.md), and [the feature/permission matrix](docs/FEATURES.md) before relying on OpenCloak for sensitive data. This project is under active development and is not a substitute for FileVault, OS updates, or a separate backup.

## License

MIT. See [LICENSE](LICENSE).

## Validation coverage

`./scripts/test-core.sh` runs deterministic state, rule persistence, corruption-preservation, event-retention, and website matching tests. `./scripts/test-hdiutil.sh` exercises repeated encrypted APFS create, wrong-key rejection, read-only remount, content integrity, and eject cycles on macOS. UI automation behavior depends on per-user Automation permission and should be checked on each supported macOS release.
