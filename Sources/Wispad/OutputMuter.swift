import AudioToolbox
import CoreAudio
import Foundation
import WispadCore

/// Coupe le son du Mac pendant une dictée et le rétablit ensuite. Ne touche à rien si le son était déjà coupé.
/// L'état est noté dans les préférences : après un plantage, le lancement suivant rétablit le son.
@MainActor
enum OutputMuter {
    private static let storeKey = "wispad.output.muted"
    private static var muted: (device: AudioDeviceID, previousVolume: Float32?)?

    /// Coupe la sortie par défaut si la règle le demande.
    static func mute(enabled: Bool, mode: OutputMuteMode) {
        guard muted == nil, let device = defaultOutput() else { return }
        let headphones = isHeadphones(device)
        let alreadyMuted = (readMute(device) ?? false) || (readVolume(device) ?? 1) == 0
        guard OutputMutePolicy.shouldMute(enabled: enabled, mode: mode, outputIsHeadphones: headphones, alreadyMuted: alreadyMuted) else { return }
        if canSetMute(device), setMute(device, true) {
            muted = (device, nil)
        } else if let volume = readVolume(device), setVolume(device, 0) {
            muted = (device, volume)
        } else {
            return
        }
        remember(device: device, previousVolume: muted?.previousVolume)
    }

    /// Rétablit le son coupé par Wispad.
    static func restore() {
        guard let state = muted else { return }
        muted = nil
        if let volume = state.previousVolume { _ = setVolume(state.device, volume) } else { _ = setMute(state.device, false) }
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// Au lancement : si Wispad a quitté pendant une dictée, le son est rétabli.
    static func recoverAfterCrash() {
        guard let saved = UserDefaults.standard.dictionary(forKey: storeKey),
              let uid = saved["uid"] as? String, let device = deviceID(uid: uid) else {
            UserDefaults.standard.removeObject(forKey: storeKey)
            return
        }
        if let volume = saved["volume"] as? Float { _ = setVolume(device, volume) } else { _ = setMute(device, false) }
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    /// Casque : Bluetooth (AirPods…) ou prise jack du Mac. Le reste (haut-parleurs du Mac, écran, HDMI…) : haut-parleurs.
    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var where_ = address(kAudioDevicePropertyTransportType)
        if AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        var source = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var sourceAddress = address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &sourceAddress),
           AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &size, &source) == noErr {
            return source == 0x6864706E // 'hdpn' : casque branché sur la prise jack
        }
        return false
    }

    private static func readMute(_ device: AudioDeviceID) -> Bool? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var where_ = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &where_), AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func canSetMute(_ device: AudioDeviceID) -> Bool {
        var where_ = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &where_) && AudioObjectIsPropertySettable(device, &where_, &settable) == noErr && settable.boolValue
    }

    private static func setMute(_ device: AudioDeviceID, _ on: Bool) -> Bool {
        var value = UInt32(on ? 1 : 0)
        var where_ = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func readVolume(_ device: AudioDeviceID) -> Float32? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var where_ = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &where_), AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setVolume(_ device: AudioDeviceID, _ volume: Float32) -> Bool {
        var value = volume
        var where_ = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func remember(device: AudioDeviceID, previousVolume: Float32?) {
        guard let uid = uid(of: device) else { return }
        var saved: [String: Any] = ["uid": uid]
        if let previousVolume { saved["volume"] = Float(previousVolume) }
        UserDefaults.standard.set(saved, forKey: storeKey)
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var where_ = address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var where_ = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
