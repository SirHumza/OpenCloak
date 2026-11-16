import AppKit
import Foundation
import LocalAuthentication
import OpenCloakCore

/// Asks for authentication before OpenCloak quits. Touch ID is tried first when a OpenCloak password is
/// configured; otherwise a password field is shown. Cancelling keeps OpenCloak running.
@MainActor
enum QuitGuard {
    static func confirm(protection: ProtectionStore, completion: @escaping (Bool) -> Void) {
        if protection.hasPassword {
            protection.authenticateUsingTouchID { success in
                if success {
                    completion(true)
                } else {
                    completion(passwordPrompt(protection: protection))
                }
            }
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(passwordPrompt(protection: protection))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Quit OpenCloak") { allowed, _ in
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    private static func passwordPrompt(protection: ProtectionStore) -> Bool {
        if !protection.hasPassword {
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Quit OpenCloak?"
        alert.informativeText = "Enter your OpenCloak password. Quitting stops hidden-app and folder protection until OpenCloak starts again."
        alert.alertStyle = .warning
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "OpenCloak password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return protection.authenticate(password: field.stringValue)
    }
}
