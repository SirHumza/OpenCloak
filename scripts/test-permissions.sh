#!/bin/bash
# Reports whether user-presence authentication and browser Automation are available.
# Uses only non-prompting APIs, so it never raises a system dialog. macOS reports
# Automation state only for a running app, so --launch starts one browser in the
# background, measures it, and quits it again without sending it any Apple event.
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH_BROWSER=""
case "${1:-}" in
  --launch) LAUNCH_BROWSER="${2:-com.apple.Safari}" ;;
  "") ;;
  -h|--help)
    echo "Usage: scripts/test-permissions.sh [--launch [BUNDLE_ID]]"
    echo "  --launch  start a supported browser briefly so its Automation state can be read"
    exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 64 ;;
esac

TEMP_DIR="$(mktemp -d -t opencloak-permissions)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/main.swift" <<'SWIFT'
import AppKit
import Foundation
import LocalAuthentication

let launchTarget = ProcessInfo.processInfo.environment["OPENCLOAK_LAUNCH_BROWSER"].flatMap { $0.isEmpty ? nil : $0 }
var preexisting: Set<pid_t> = []

if let launchTarget {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: launchTarget) {
        preexisting = Set(NSRunningApplication.runningApplications(withBundleIdentifier: launchTarget)
            .map(\.processIdentifier))
        if preexisting.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            let opened = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
                opened.signal()
            }
            opened.wait()
            var waited = 0.0
            while waited < 8,
                  NSRunningApplication.runningApplications(withBundleIdentifier: launchTarget).isEmpty {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 0.25
            }
            Thread.sleep(forTimeInterval: 1)
            print("Started \(launchTarget) briefly to read its Automation state.\n")
        } else {
            print("\(launchTarget) was already running and will be left alone.\n")
        }
    } else {
        print("\(launchTarget) is not installed on this Mac.\n")
    }
}

let context = LAContext()
var ownerError: NSError?
let owner = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &ownerError)
print("User-presence authentication (LocalAuthentication)")
print("  Mac password or Touch ID: \(owner ? "available" : "unavailable")")
if !owner, let ownerError { print("  reason: \(ownerError.localizedDescription)") }

let biometricContext = LAContext()
var biometricError: NSError?
let biometrics = biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
if biometrics {
    let kind = biometricContext.biometryType == .touchID ? "Touch ID" : "biometrics"
    print("  \(kind): available")
} else {
    print("  biometrics: unavailable\(biometricError.map { " (\($0.localizedDescription))" } ?? "")")
}

print("")
print("Browser Automation (askUser = false, so no dialog is shown)")
for browser in BrowserPermissions.supportedBrowsers {
    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil
    guard installed else {
        print("  \(browser.name): not installed")
        continue
    }
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
    let status = BrowserPermissions.status(for: browser.bundleID)
    print("  \(browser.name): \(status.label)\(running ? "" : " (start the browser to read this state)")")
}

if let launchTarget, preexisting.isEmpty {
    let launched = NSRunningApplication.runningApplications(withBundleIdentifier: launchTarget)
        .filter { !preexisting.contains($0.processIdentifier) }
    for application in launched { application.terminate() }
    var waited = 0.0
    while waited < 5, !NSRunningApplication.runningApplications(withBundleIdentifier: launchTarget).isEmpty {
        Thread.sleep(forTimeInterval: 0.25)
        waited += 0.25
    }
    // Safari can outlive a graceful terminate while it tears down; do not leave it running.
    for application in NSRunningApplication.runningApplications(withBundleIdentifier: launchTarget) {
        application.forceTerminate()
    }
    if !launched.isEmpty { print("\nQuit the browser instance this probe started.") }
}
SWIFT

swiftc -o "$TEMP_DIR/probe" Sources/OpenCloakApp/BrowserPermissions.swift "$TEMP_DIR/main.swift" \
  -framework AppKit -framework Carbon -framework LocalAuthentication
OPENCLOAK_LAUNCH_BROWSER="$LAUNCH_BROWSER" "$TEMP_DIR/probe"

printf '\nA denial above is reported, not asserted: this probe proves the permission paths run,\nnot that access has been granted. Granting access needs a person at the Mac.\n'
