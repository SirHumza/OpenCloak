# Features and permissions

| Feature | State | Platform permission or limit |
|---|---|---|
| Encrypted sparse-bundle vaults | Implemented | macOS `hdiutil`; mounted data is accessible |
| Keychain credential + recovery key | Implemented | Native macOS user authentication |
| Vault import/export | Implemented | User-selected files and folders; no overwrite |
| App privacy screens | Implemented | Screen appears after app activation; does not stop launch |
| Website privacy screens | Implemented for Safari, Chrome, Brave, Edge, Vivaldi | macOS Automation permission; active tab only |
| Relock on inactivity, sleep, screen lock | Implemented | Ejection can fail while files are busy |
| Multi-display overlay | Implemented | Post-activation overlay; not tamper-proof |
| Local activity history | Implemented | Stores generic action/outcome only |
| Face recognition or face liveness | Not included | Nopal does not access a camera for authentication |
| EndpointSecurity process blocking | Not included | Requires Apple's entitlement and separate review |

Browser and app overlay behavior must be retested on every supported macOS release. Permission denial or unsupported browser scripting means the associated website screen cannot operate.
