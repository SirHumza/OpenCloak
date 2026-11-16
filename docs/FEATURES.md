# OpenCloak feature and permission matrix

OpenCloak is a local privacy utility. Features marked “best effort” do not provide OS-enforced access control.

| Feature | Status | Boundary |
|---|---|---|
| Separate password and recovery key | Implemented | Recovery key is shown during setup; store it away from this Mac. |
| Touch ID unlock | Implemented when available | Uses Keychain biometric access control; password remains the recovery path. |
| Encrypted vaults | Implemented | AES-256 disk images; mounted contents are accessible to the logged-in user. |
| Hide applications | Implemented for movable third-party app bundles | Copies to encrypted sparse bundle, verifies, then removes source. System apps are rejected. App Store/TCC-sensitive apps may not work after relocation. |
| Temporarily open hidden app | Implemented | Opens from mounted encrypted image; the image is detached after the app terminates when macOS allows it. |
| Encrypt files and folders | Implemented | Verified copy to encrypted image, then source removal. A failure to restore never deletes the encrypted copy. |
| Lock apps | Best effort | OpenCloak detects activation and overlays all displays after launch. It cannot prevent process startup, background helpers, or pre-overlay content flashes. |
| Lock websites | Best effort: Safari, Chrome, Brave, Edge, Vivaldi | Reads the active tab using Automation permission. URL polling can show content briefly; private windows and other browsers are unsupported. |
| App schedules and fake-crash presentation | Implemented | Fake crash is an OpenCloak alert styled after macOS behavior, not the system crash reporter. Option must be held when choosing Reopen. |
| Intruder photos | Implemented, off by default | Camera permission is requested only after enabling the feature and a failed attempt. Photos stay local. |
| Automatic relock | Implemented | Sleep, screen lock, and configurable idle; busy disk images may remain mounted and are reported. |
| Multi-display overlay | Implemented | Convenience privacy screen, not a tamper-proof boundary. |
| Menu-bar-only mode and global shortcuts | Implemented | Shortcuts use Carbon registration. A hidden menu icon can be restored with the configured app shortcut. |
| Finder Services/context actions | Not implemented | Use the OpenCloak window to choose files. |
| Visible in-place folder lock and Finder badge | Not implemented | File protection relocates content into an encrypted image. |
| Spotlight/Launchpad suppression | Best effort | Removing the app bundle from its source location normally removes its listing; indexing caches and system policy are outside OpenCloak's control. |
| Additional themes and adjustable app text size | Not implemented | Uses the native system appearance. |
| Process blocking / anti-force-quit | Not implemented | Requires privileged or Apple-restricted mechanisms; relaunch-at-login is optional best effort. |

Build support targets macOS 12+ and creates a universal x86_64/arm64 app. Hardware-specific behavior still needs validation on each macOS release and device class.
