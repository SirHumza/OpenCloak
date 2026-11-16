# Security Policy

## Supported versions

Nopal 0.1.x on macOS 13 or later is the supported baseline. Developer builds are unsigned and intended for review and local use.

## Reporting a vulnerability

Report security issues privately through the repository's security advisory feature. Do not include vault contents, passwords, or recovery keys in a report. If a proof of concept needs a real vault, create a new empty vault for it.

Please allow time for a fix before public disclosure. This project has no bug bounty.

## What Nopal guarantees

- Vault contents are encrypted at rest by Apple's encrypted sparse disk image format (APFS, AES-256).
- The vault credential is generated from the system cryptographic random generator, stored only in the data-protection Keychain with user-presence access control, and never written to logs, activity history, configuration exports, process arguments, or temporary plaintext files.
- Disk work goes through `/usr/bin/hdiutil` with an argument array and the secret written to stdin. No shell is involved.
- Creation uses a temporary destination and an atomic move. Import and export copy and verify; they never overwrite an existing destination and never modify the source.
- A vault is only reported as mounted after `hdiutil attach` reports a mounted volume, and a busy eject is reported as a failure with the vault still mounted.
- Activity history stores action summaries and outcomes only.

## What Nopal does not guarantee

- It does not stop an administrator, root user, malware running as the logged-in user, or anyone with the Mac unlocked.
- App rules do not prevent apps or background helpers from executing.
- Website rules cover only the tested browsers and do not see pages in private windows or pages Nopal cannot read.
- Forced termination or power loss can leave a vault mounted; Nopal reports that outcome on the next observation but cannot prevent it.
- Losing both Keychain access and the recovery key makes a vault unrecoverable. There is no server-side recovery.

## Local data locations

- Vaults: `~/Library/Application Support/Nopal/Vaults`
- Privacy rules: `~/Library/Application Support/Nopal/privacy-rules.json`
- Activity history: `~/Library/Application Support/Nopal/events.json`
- Preferences: standard macOS user defaults for the app

Files created by Nopal use owner-only permissions (0700 directories, 0600 files) where the system permits.

## Permissions used

- **Touch ID / LocalAuthentication** for retrieving a Keychain vault credential.
- **Automation (Apple Events)** only when a website rule is enabled, to read the active tab URL of a supported browser. Missing permission disables website screens rather than silently claiming coverage.
- No Accessibility, Screen Recording, camera, microphone, or network permission is requested.
