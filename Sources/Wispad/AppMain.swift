import AppKit
import WispadCore
import SwiftUI

@main
enum WispadMain {
    static func main() {
        #if DEBUG
        // Aperçus, démos, sondes et autotests : jamais dans la version Release.
        if DevTools.handle(CommandLine.arguments) { return }
        #endif
        if CommandLine.arguments.contains("--check-permissions") {
            MainActor.assumeIsolated {
                print("microphone=\(PermissionCenter.microphoneStatus().rawValue)")
                print("accessibility=\(PermissionCenter.accessibilityTrusted(prompt: false))")
                print("inputMonitoring=\(PermissionCenter.inputMonitoringTrusted())")
            }
            return
        }
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            let app = NSApplication.shared
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}
