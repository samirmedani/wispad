import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Micro (périphérique d'entrée) vu par CoreAudio.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    var uid: String
    var name: String
    var id: String { uid }
}

/// Périphériques d'entrée du Mac. Lecture seule, sauf le choix du micro d'un moteur audio de Wispad : le micro
/// du système n'est jamais modifié.
enum AudioInputDevices {
    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { device in
            guard inputChannels(device) > 0,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Micro choisi dans Réglages Système › Son › Entrée.
    static func systemDefault() -> AudioInputDevice? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0,
              let uid = string(device, kAudioDevicePropertyDeviceUID),
              let name = string(device, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(uid: uid, name: name)
    }

    /// Fait écouter ce micro au moteur, avant son démarrage. Faux si le micro a disparu entre-temps : le moteur
    /// garde alors celui du système.
    @discardableResult
    static func use(_ uid: String, in engine: AVAudioEngine) -> Bool {
        guard let device = deviceIDs().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }),
              let unit = engine.inputNode.audioUnit else { return false }
        var chosen = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &chosen, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func inputChannels(_ device: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
