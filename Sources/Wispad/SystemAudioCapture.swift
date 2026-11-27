import AVFoundation
import CoreAudio
import Foundation
import os
import WispadCore

/// Enregistreur de réunion sans bot : capture le microphone (et, sur macOS 14.2+ si autorisé, l'audio système via
/// CoreAudio Process Tap), écrit un WAV 16 kHz mono local (0600) prêt pour la transcription par morceaux.
final class MeetingAudioRecorder: @unchecked Sendable {
    enum SourceMode: Equatable, Sendable {
        case micOnly
        case micAndSystem
    }

    private let controlQueue = DispatchQueue(label: "com.yatofix.wispad.meeting-audio.control", qos: .userInitiated)
    /// File série dédiée aux écritures WAV et au mixage : aucune course entre le fil temps réel CoreAudio et `stop()`.
    private let ioQueue = DispatchQueue(label: "com.yatofix.wispad.meeting-audio.io", qos: .userInitiated)
    private var micEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var wav: WAVStream?
    private var outputURL: URL?
    private var startedAt: Date?
    private var isRunning = false
    private var systemTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var systemIOProcID: AudioDeviceIOProcID?
    private let mixLock = NSLock()
    private var systemBuffer: [Float] = []
    private var resamplePhase: Double = 0
    private var lastResampleSample: Float = 0
    private(set) var activeMode: SourceMode = .micOnly
    private static let sampleRate = 16_000
    private static let log = Logger.wispad("reunion-audio")

    deinit {
        _ = stop()
    }

    func start(directory: URL, includeSystemAudio: Bool) throws -> (url: URL, mode: SourceMode) {
        try controlQueue.sync {
            guard !isRunning else {
                throw AudioCaptureError.engine(String(localized: "Un enregistrement de réunion est déjà en cours."))
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("meeting-\(UUID().uuidString).wav")
            let stream = try WAVStream(url: url, sampleRate: Self.sampleRate)
            self.outputURL = url
            self.startedAt = Date()
            self.activeMode = .micOnly
            self.ioQueue.sync {
                self.wav = stream
            }
            self.mixLock.lock()
            self.systemBuffer.removeAll(keepingCapacity: true)
            self.resamplePhase = 0
            self.lastResampleSample = 0
            self.mixLock.unlock()

            if includeSystemAudio {
                if #available(macOS 14.2, *) {
                    if startSystemAudioTap() {
                        self.activeMode = .micAndSystem
                    }
                }
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                cleanupFailedStart(url: url)
                throw AudioCaptureError.noInput
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(Self.sampleRate),
                channels: 1,
                interleaved: true
            ), let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                cleanupFailedStart(url: url)
                throw AudioCaptureError.engine(String(localized: "Format audio indisponible."))
            }
            self.converter = conv
            self.micEngine = engine
            input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer, targetFormat: targetFormat, converter: conv)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                engine.stop()
                self.micEngine = nil
                self.converter = nil
                cleanupFailedStart(url: url)
                throw error
            }
            self.isRunning = true
            return (url, activeMode)
        }
    }

    func stop() -> (url: URL?, duration: TimeInterval) {
        controlQueue.sync {
            guard isRunning || micEngine != nil || aggregateDeviceID != kAudioObjectUnknown else {
                return (nil, 0)
            }
            isRunning = false
            micEngine?.inputNode.removeTap(onBus: 0)
            micEngine?.stop()
            micEngine = nil
            converter = nil
            stopSystemAudioTap()
            // Draine toutes les écritures en vol sur `ioQueue` avant de finaliser l'en-tête WAV.
            ioQueue.sync {
                wav?.close()
                wav = nil
            }
            mixLock.lock()
            systemBuffer.removeAll(keepingCapacity: false)
            mixLock.unlock()
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let url = outputURL
            outputURL = nil
            startedAt = nil
            return (url, max(0, elapsed))
        }
    }

    private func cleanupFailedStart(url: URL) {
        stopSystemAudioTap()
        ioQueue.sync {
            wav?.close()
            wav = nil
        }
        outputURL = nil
        startedAt = nil
        activeMode = .micOnly
        try? FileManager.default.removeItem(at: url)
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0, let int16Ptr = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        mixLock.lock()
        let sysAvailable = min(count, systemBuffer.count)
        if sysAvailable > 0 {
            for i in 0..<sysAvailable {
                let micSample = Float(int16Ptr[i]) / 32_768.0
                let mixed = max(-1.0, min(1.0, micSample + systemBuffer[i] * 0.85))
                int16Ptr[i] = Int16(mixed * 32_767.0)
            }
            systemBuffer.removeFirst(sysAvailable)
        }
        mixLock.unlock()
        let data = Data(bytes: int16Ptr, count: count * MemoryLayout<Int16>.size)
        ioQueue.async { [weak self] in
            self?.wav?.append(data)
        }
    }

    @available(macOS 14.2, *)
    private func startSystemAudioTap() -> Bool {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            Self.log.notice("capture audio système indisponible (code \(tapStatus, privacy: .public)), repli micro")
            return false
        }
        self.systemTapID = tapID

        // Lire le format natif du tap (taux d'échantillonnage réel, 44.1 kHz ou 48 kHz selon la sortie active).
        var tapASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapFormatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tapID, &tapFormatAddress, 0, nil, &asbdSize, &tapASBD)

        let tapUID = description.uuid.uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "WispadMeetingTap",
            kAudioAggregateDeviceUIDKey as String: "com.yatofix.wispad.meetingtap.\(tapUID)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var aggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            self.systemTapID = kAudioObjectUnknown
            return false
        }
        self.aggregateDeviceID = aggID

        var nominalRate: Float64 = (formatStatus == noErr && tapASBD.mSampleRate > 0) ? tapASBD.mSampleRate : 48_000
        if formatStatus != noErr || tapASBD.mSampleRate <= 0 {
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(aggID, &rateAddress, 0, nil, &rateSize, &nominalRate)
        }
        let stepRatio = max(0.5, nominalRate / Double(Self.sampleRate))

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !bufferList.isEmpty else { return }

            // Gère à la fois les buffers entrelacés (1 buffer, N canaux) et non-entrelacés (M buffers, 1 canal chacun).
            var monoFrames: [Float] = []
            if bufferList.count == 1, let first = bufferList.first, let dataPtr = first.mData {
                let channels = max(1, Int(first.mNumberChannels))
                let floatCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let frames = floatCount / channels
                guard frames > 0 else { return }
                let samples = dataPtr.assumingMemoryBound(to: Float.self)
                monoFrames.reserveCapacity(frames)
                if channels == 1 {
                    for i in 0..<frames { monoFrames.append(samples[i]) }
                } else {
                    let scale = 1.0 / Float(channels)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for ch in 0..<channels { sum += samples[i * channels + ch] }
                        monoFrames.append(sum * scale)
                    }
                }
            } else {
                var minFrames = Int.max
                for buf in bufferList {
                    guard buf.mData != nil else { continue }
                    let ch = max(1, Int(buf.mNumberChannels))
                    let frames = (Int(buf.mDataByteSize) / MemoryLayout<Float>.size) / ch
                    minFrames = min(minFrames, frames)
                }
                guard minFrames > 0, minFrames != Int.max else { return }
                monoFrames = Array(repeating: 0, count: minFrames)
                var totalChannels = 0
                for buf in bufferList {
                    guard let ptr = buf.mData else { continue }
                    let ch = max(1, Int(buf.mNumberChannels))
                    let samples = ptr.assumingMemoryBound(to: Float.self)
                    for i in 0..<minFrames {
                        for c in 0..<ch { monoFrames[i] += samples[i * ch + c] }
                    }
                    totalChannels += ch
                }
                if totalChannels > 1 {
                    let scale = 1.0 / Float(totalChannels)
                    for i in 0..<minFrames { monoFrames[i] *= scale }
                }
            }
            guard !monoFrames.isEmpty else { return }

            // Rééchantillonnage linéaire fractionnaire (évite la dérive de +9 % sur les sorties 44,1 kHz).
            self.mixLock.lock()
            var pos = self.resamplePhase
            let prev = self.lastResampleSample
            let count = monoFrames.count
            var downsampled: [Float] = []
            downsampled.reserveCapacity(Int(Double(count) / stepRatio) + 2)
            while pos < Double(count) {
                let idx = Int(floor(pos))
                let frac = Float(pos - Double(idx))
                let s0 = idx < 0 ? prev : monoFrames[idx]
                let s1 = (idx + 1) < count ? monoFrames[idx + 1] : monoFrames[count - 1]
                downsampled.append(s0 + (s1 - s0) * frac)
                pos += stepRatio
            }
            self.resamplePhase = pos - Double(count)
            self.lastResampleSample = monoFrames[count - 1]
            if self.systemBuffer.count < Self.sampleRate * 10 {
                self.systemBuffer.append(contentsOf: downsampled)
            }
            self.mixLock.unlock()
        }
        guard createStatus == noErr, let procID else {
            stopSystemAudioTap()
            return false
        }
        self.systemIOProcID = procID
        let startStatus = AudioDeviceStart(aggID, procID)
        if startStatus != noErr {
            stopSystemAudioTap()
            return false
        }
        return true
    }

    private func stopSystemAudioTap() {
        if aggregateDeviceID != kAudioObjectUnknown, let procID = systemIOProcID {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        systemIOProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if #available(macOS 14.2, *), systemTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(systemTapID)
            systemTapID = kAudioObjectUnknown
        }
    }
}
