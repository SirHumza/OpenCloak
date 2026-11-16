# Nopal: Native Mac Privacy App Design

## Product brief

Nopal is an English-only, open-source macOS privacy app inspired by the workflows and compact visual language of Cloak. It will provide a polished menu-bar utility and main window for managing encrypted file vaults and privacy rules. Nopal will use original branding, copy, artwork, and implementation.

The project prioritizes security, reliability, privacy, recovery, performance, and native macOS integration. It runs locally without an account, analytics, or network dependency. Its security claims must match the guarantees macOS actually provides.

## Goals

- Make creating, unlocking, locking, and recovering encrypted vaults clear and dependable.
- Offer useful app and website privacy rules with accurate disclosure that ordinary app-level screens do not prevent protected processes from running.
- Integrate with native macOS authentication, Keychain, menu bar, file dialogs, notifications, accessibility, and lifecycle events.
- Preserve user data across cancellation, crashes, low storage, open files, and interrupted operations.
- Publish source under the MIT License with build, threat model, limitations, and contribution documentation.

## Non-goals

- Claim to stop all access by an administrator, malware running as the user, or a person who has unlocked the Mac.
- Claim app rules prevent an application or its background helpers from executing.
- Require an account, cloud service, telemetry, subscription, or third-party runtime service.
- Reuse Cloak's name, assets, text, source code, or distinctive branding.
- Depend on Apple's EndpointSecurity entitlement for the baseline product.

## Users and success criteria

The primary user wants to keep private files protected on a shared or unattended Mac without trusting a cloud service. Secondary users want a quick privacy screen when handing over a Mac or browsing sensitive sites.

Success means a new user can create and verify a vault, understand whether it is locked or mounted, safely eject it, and restore it from a backup without losing data. Every visible protection feature identifies what it protects and what it does not. The app remains responsive during disk operations and can recover from interrupted workflows without silently deleting or overwriting user data.

## Supported platform

- Native Swift application using SwiftUI and AppKit where needed.
- Universal Apple silicon and Intel build.
- Deployment target: macOS 13 Ventura.
- Test on macOS 13 and the latest public macOS release available at release time.
- English UI only for the initial release.
- Xcode project and command-line build/test instructions; no third-party runtime dependencies unless a reviewed security or reliability need justifies one.

## User experience

The app lives primarily in the menu bar. Selecting it opens a native main window with a sidebar for **Overview**, **Vaults**, **Apps**, **Websites**, and **Settings**. The interface follows familiar privacy-app patterns: a compact navigation rail, clear state labels, prominent add controls, and focused detail panes. The visual identity and all assets are original to Nopal.

Overview shows vault lock/mount state, active privacy rules, and the last local security-relevant actions. Vaults supports create, unlock, lock/eject, reveal in Finder, import, export, and recovery guidance. Apps and Websites show explicit rule state and macOS permissions needed. Settings controls relock behavior, authentication fallback, and local event-history retention.

Every destructive or ambiguous operation explains its result before proceeding. Cancellation leaves the prior state intact. A busy vault cannot be forcibly detached by default; the app reports that it is busy and offers retry. It identifies the blocking process only when macOS provides reliable evidence. There is no fake-crash mode or covert camera capture in the baseline release.

## Architecture

A small native app is divided into UI, policy/state coordination, and platform adapters. SwiftUI renders navigation and forms. AppKit supplies menu-bar behavior, window lifecycle integration, and native panels. A vault service owns state transitions and invokes macOS disk-image tooling through a constrained process adapter. A Keychain service owns secrets and authentication policy. An event recorder stores minimal local events without file contents, browsing history, or telemetry.

The policy layer is the only owner of persisted app/site rules and relock state. Services expose typed outcomes so UI cannot report success before the operating system confirms the operation. Long-running disk work executes away from the main thread, reports cancellable progress where safe, and serializes operations per vault.

## Vault security and data integrity

Use Apple's encrypted sparse disk-image format as the initial vault container rather than inventing a cryptographic format. Validate the chosen format against macOS 13 and current macOS before committing to it. A vault is either locked, unlocking, mounted, locking, or in an error/recovery state; transitions are persisted only after confirmed operating-system results.

Generate a high-entropy vault password with the system cryptographic random generator. Store it only in Keychain, protected by the user's selected authentication policy. Touch ID gates secret retrieval; it is not itself the encryption key. Offer an explicit recovery secret during creation. It must independently recover the vault credential if Keychain access is lost, not merely duplicate the Keychain item. Display it once, require the user to confirm they saved it, and never silently upload or persist it in plaintext. Clearly explain that losing both the Mac's Keychain access and recovery secret makes the vault unrecoverable. The implementation plan must choose and validate a safe recovery construction compatible with the selected encrypted disk-image API before vault creation ships.

Creation uses a temporary destination and atomic rename after successful creation and validation. Import never overwrites an existing vault. Export writes to a new user-selected destination, verifies completion, and preserves the original. Failed, cancelled, or interrupted operations clean up only files created by that operation. Never delete or replace the source as part of import/export.

Locking requests unmount/eject and reports failure if files are busy. The app never claims a vault is protected while mounted. Sleep and screen-lock events request relocking; if safe eject fails, the app records and surfaces the unresolved mounted state rather than claiming success. App termination attempts orderly cleanup but cannot promise eject after forced termination or power loss.

Passwords and recovery secrets must not appear in logs, crash messages, process arguments, analytics, or temporary plaintext files. The process adapter must pass secrets through a protected pipe or another reviewed mechanism supported by the selected macOS command/API. Command construction must avoid shell interpolation. If this cannot be implemented safely with the chosen disk-image API, block vault creation pending a safer adapter.

## App and website privacy rules

Rules are local and use allow-listed app identifiers or validated URL patterns. Website matching supports exact hosts and optional path prefixes; it does not collect or retain general browsing history. Browser integration must be explicit about required Accessibility or Automation permissions and must fail closed in its UI state when permission is missing.

The baseline app monitor may observe launches and present a privacy screen after launch. It must label this as a **privacy screen**, never as execution blocking. It cannot guarantee protection of background helpers, alternate launch paths, or content displayed before the screen appears. Website rules cover only tested browser/version combinations and must disclose gaps. A future EndpointSecurity system extension is a separate opt-in project requiring Apple's entitlement and adversarial bypass tests.

## Privacy and local data

No account, telemetry, advertising, or network requests are required. Rules, settings, and minimal event history remain local. Event history records actions and outcomes, not file names, file contents, URLs visited, or authentication secrets. Users can clear event history and export their configuration. Website favicons, if added, are fetched only with explicit consent; the initial release can use generic icons to avoid network access.

## Failure handling and recovery

- Authentication cancellation returns to the prior locked state.
- Keychain denial or unavailable Touch ID offers only the configured, explicit fallback.
- Disk full, invalid image, mount failure, and busy files produce actionable messages and preserve source data.
- Duplicate destination names require an explicit new destination; no implicit overwrite.
- Interrupted create/import/export leaves either the original valid item or a clearly marked recoverable temporary item; startup recovery never deletes ambiguous user data automatically.
- A corrupted or inaccessible vault is never “repaired” destructively without a separate user-approved copy and documented recovery attempt.

## Open-source release

The repository includes `LICENSE` (MIT), `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, a threat model, reproducible build instructions, and a feature/permission matrix. Do not include signing credentials, provisioning profiles, private certificates, or user data. Releases are signed/notarized when signing credentials are available; unsigned developer builds remain documented.

## Validation requirements

Before release, verify build and tests on macOS 13 and current macOS, on Apple silicon and Intel where hardware is available. Test vault creation, reopen, mount, unmount, recovery, backup restore, duplicate names, cancellation at every safe boundary, disk-full handling, busy files, process termination, sleep/wake, screen lock, Keychain denial, authentication cancellation, and forced app termination. Confirm secrets do not appear in process arguments, logs, temporary files, or crash output. Test app/site privacy rules against background apps, alternate launch paths, permission denial, private browser windows, and browser updates; publish all observed limits.

## Delivery sequence

1. Project skeleton, license, build workflow, native app shell, and accessible navigation.
2. Vault state model and safe disk-image adapter, first exercised in isolated temporary directories.
3. Keychain authentication, recovery secret flow, create/unlock/eject, and interruption recovery.
4. Import/export, local event history, and complete failure-state UX.
5. App privacy screens with explicit limits; add website privacy integration only for browser paths that can be validated.
6. Security review, compatibility matrix, release packaging, and public documentation.

Each stage must leave the preceding data-integrity guarantees intact. No stage may advertise a feature before its supported platform paths and failure behavior have been validated.
