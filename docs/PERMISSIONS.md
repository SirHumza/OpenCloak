# OpenCloak permissions

OpenCloak requests permissions only when a feature needs them.

| Permission | Use | When requested |
|---|---|---|
| Automation / Apple Events | Read the current URL in supported browsers and cover matching pages | When website rules are used and macOS prompts |
| Camera | Capture an optional local photo after failed authentication | Only after intruder photos are enabled and an unlock fails |
| Keychain user presence | Release a stored vault key through Touch ID or macOS-supported user presence | When unlocking a vault with a saved credential |
| Accessibility / Input Monitoring | Not used | Never requested |
| Full Disk Access | Not used | Never requested |

OpenCloak does not use private APIs or install a privileged helper. Website monitoring depends on Automation access and is not browser-enforced. Camera denial leaves the authentication failure handling intact and simply skips the photo.

For a notarized distribution, sign with Developer ID, enable the hardened runtime, and submit with `notarytool`. The repository's release script requires an existing signing identity and notarization keychain profile; it does not contain signing credentials.
