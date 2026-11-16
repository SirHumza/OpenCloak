# OpenCloak Threat Model

## Assets

- The plaintext contents of a vault while it is mounted.
- The vault credential and recovery key.
- Privacy rules and the fact that a rule exists.
- Minimal local activity history.

## Adversaries and outcomes

| Adversary | Outcome |
| --- | --- |
| Someone using the Mac while a vault is locked | Cannot read vault contents without the Keychain credential and user presence. |
| Casual observer of the screen | App and website privacy screens cover the screen until authentication or an explicit quit/close action. Content displayed before the screen appears may be seen. |
| Person who obtains the Mac while it is asleep or screen-locked | Relock ejects mounted vaults when macOS reports the event. A forced power loss or busy vault can leave it mounted until observed. |
| Person with the Keychain item but not the user | The item is protected by user presence; Touch ID or the Mac password is required. Touch ID is not the encryption key. |
| Administrator, root, or malware as the logged-in user | **Out of scope.** Such an attacker can attach the image, read mounted files, or replace OpenCloak. |
| Remote attacker | OpenCloak makes no network requests, so there is no remote service to compromise. |
| Browser or page attacker | Website screens read only the active tab URL after the fact. A page can display sensitive content before the screen appears, and unsupported browsers are not covered. |

## Guarantees

- Vaults use Apple's encrypted sparse disk image format (APFS, AES-256); OpenCloak does not invent a cryptographic container.
- A vault credential is 256 bits from `SecRandomCopyBytes`, stored only in the data-protection Keychain with `.userPresence` (or `.biometryCurrentSet` when Touch ID only is selected).
- Secrets go to `hdiutil` through a pipe with `-stdinpass`; they never appear in process arguments, shell strings, logs, activity history, or temporary plaintext files.
- Mount state comes from `hdiutil info`. A vault is called mounted only when macOS reports a mounted volume; a busy eject is a failure.
- Creation is a temporary sparse bundle followed by an atomic move. Interrupted creation leaves a temporary vault that can be finished, never silently deleted.
- Import/export copy and verify byte counts and file counts, never overwrite an existing destination, and never modify the source.
- The recovery key is the actual 256-bit vault credential shown once, so it independently recovers the vault if Keychain access is lost. It is not a duplicate Keychain item or a wrapped copy that requires the Keychain.
- Activity history contains action summaries and outcomes only.

## Known limitations

- No protection against an administrator, root, malware running as the user, or a Mac that is already unlocked.
- App rules cannot block execution, background helpers, or alternate launch paths; they cover an app after macOS reports activation.
- Website rules cover only tested browser/version combinations; private windows and unsupported browsers are out of scope.
- Relock cannot detach a busy vault. The unresolved mounted state is recorded and surfaced.
- Forced termination and power loss can leave a vault mounted.
- Changing the authentication policy affects credentials saved after the change; an existing credential may keep its earlier access control if macOS rejects the ACL update.
- Recovery depends on the user keeping the recovery key. There is no account recovery service.

## Secret-handling checklist

Checked against `Sources/OpenCloakCore/VaultService.swift` and `Sources/OpenCloakApp/PrivacyCoordinator.swift`, and by rerunning both test suites.

- [x] Secret passed only via pipe to `hdiutil -stdinpass`. Every secret-bearing call (`create`, `attach`) passes `-stdinpass`, and `run(arguments:secret:)` writes the credential to the process's standard input rather than an argument.
- [x] Secret not interpolated into a shell command. All disk-image work uses `Process` with `executableURL` `/usr/bin/hdiutil` and an argument array. No shell, `NSTask`, or string-built command exists in the sources.
- [x] Secret not included in `LocalizedError` messages or activity summaries. Errors carry fixed text, hdiutil's own output, or an OSStatus number; activity summaries are fixed strings.
- [x] Secret not written to configuration export. `testConfigurationExportIsCredentialFree` asserts the exported JSON contains no password, recovery, secret, or credential text.
- [x] Secret not copied to a temporary plaintext file. The credential is written only to the Keychain item and the stdin pipe; the only files OpenCloak leaves behind are the encrypted sparse bundle and its own JSON records.
- [x] Authentication cancellation returns to the prior locked state. `read(account:)` maps `errSecUserCanceled` and `errSecAuthFailed` to `.authenticationCancelled` before any `attach` runs, and a failed overlay evaluation leaves the screen up without marking the rule unlocked.
