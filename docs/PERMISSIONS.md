# Feature and Permission Matrix

| Feature | macOS API | Permission or entitlement | Fallback when unavailable | What it does not cover |
| --- | --- | --- | --- | --- |
| Create vault | `hdiutil create`, APFS/AES-256 sparse bundle | None beyond writing to Application Support | Reports the failure; no vault or credential is claimed | Nothing beyond the encrypted image itself |
| Store vault credential | Data-protection Keychain, `SecAccessControl` | User presence (Touch ID or Mac password) | Mac password when Touch ID is unavailable | Does not protect a Mac that is unlocked |
| Unlock / mount vault | `hdiutil attach -stdinpass` | Keychain user presence, or a recovery key typed by the user | Recovery key entry when Keychain access is lost | Does not protect files a user copies out of a mounted vault |
| Eject vault | `hdiutil detach` | None | Reports busy and leaves the vault mounted | Cannot detach a vault with open files |
| Import vault | File copy + byte/file verification + `hdiutil isencrypted` | File access chosen by the user | Rejects non-encrypted or unsupported images | Does not verify the vault password until first unlock |
| Export vault | File copy + byte/file verification | Folder access chosen by the user | Requires the vault to be locked | Does not back up Keychain or the recovery key |
| App privacy screen | `NSWorkspace` activation notifications, `NSPanel`, LocalAuthentication | User presence to unlock the screen | Screen stays until quit or dismiss | App execution, background helpers, alternate launch paths, content shown before the panel |
| Website privacy screen | `NSAppleScript` + Automation, `AEDeterminePermissionToAutomateTarget` | Automation for each supported browser | Fails closed: no screen, records that protection is unavailable | Private windows, unsupported browsers, pages displayed before the URL check, history storage (never stored) |
| Relock on idle | `CGEventSource` idle time | None | Reports when a busy vault cannot be ejected | A busy vault stays mounted |
| Relock on sleep / screen lock | `NSWorkspace.willSleep`, `com.apple.screenIsLocked` | None | Reports when a busy vault cannot be ejected | Forced termination, power loss |
| Local activity history | JSON in Application Support | None | Prunable and clearable; unreadable history is preserved aside | Never stores file names, vault names, URLs, or credentials |
| Configuration export | JSON save panel | Folder access chosen by the user | No export when there are no rules | No credentials, history, or vault contents |
