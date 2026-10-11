import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import WispadCore
import ServiceManagement

enum PermissionCenter {
    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        switch microphoneStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func inputMonitoringTrusted() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }
}

enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
