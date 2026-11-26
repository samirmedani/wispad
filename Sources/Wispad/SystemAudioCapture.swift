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

    private let queue = DispatchQueue(label: "com.yatofix.wispad.meeting-audio", qos: .userInitiated)
    private var micEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var wav: WAVStream?
    private var outputURL: URL?
    private var startedAt: Date?
    private var systemTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var systemIOProcID: AudioDeviceIOProcID?
    private let mixLock = NSLock()
    private var systemBuffer: [Float] = []
    private(set) var activeMode: SourceMode = .micOnly
    private static let sampleRate = 16_000
    private static let log = Logger.wispad("reunion-audio")

    func start(directory: URL, includeSystemAudio: Bool) throws -> (url: URL, mode: SourceMode) {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("meeting-\(UUID().uuidString).wav")
            let stream = try WAVStream(url: url, sampleRate: Self.sampleRate)
            self.wav = stream
            self.outputURL = url
            self.startedAt = Date()
            self.activeMode = .micOnly
            self.mixLock.lock()
            self.systemBuffer.removeAll(keepingCapacity: true)
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
                stopSystemAudioTap()
                stream.close()
                throw AudioCaptureError.noInput
            }
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(Self.sampleRate),
                channels: 1,
                interleaved: true
            ), let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                stopSystemAudioTap()
                stream.close()
                throw AudioCaptureError.engine(String(localized: "Format audio indisponible."))
            }
            self.converter = conv
            self.micEngine = engine
            input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer, targetFormat: targetFormat, converter: conv)
            }
            engine.prepare()
            try engine.start()
            return (url, activeMode)
        }
    }

    func stop() -> (url: URL?, duration: TimeInterval) {
        queue.sync {
            micEngine?.inputNode.removeTap(onBus: 0)
            micEngine?.stop()
            micEngine = nil
            converter = nil
            stopSystemAudioTap()
            wav?.close()
            wav = nil
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let url = outputURL
            outputURL = nil
            startedAt = nil
            return (url, max(0, elapsed))
        }
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
        wav?.append(data)
    }

    @available(macOS 14.2, *)
    private func startSystemAudioTap() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            Self.log.notice("capture audio système indisponible (code \(tapStatus, privacy: .public)), repli micro")
            return false
        }
        self.systemTapID = tapID

        let tapUID = description.uuid.uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "WispadMeetingTap",
            kAudioAggregateDeviceUIDKey as String: "com.yatofix.wispad.meetingtap.\(tapUID)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
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

        // Lit le taux d'échantillonnage nominal du périphérique d'agrégation pour sous-échantillonner à 16 kHz.
        var nominalRate: Float64 = 48_000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(aggID, &rateAddress, 0, nil, &rateSize, &nominalRate)
        let step = max(1, Int((nominalRate / Double(Self.sampleRate)).rounded()))

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = bufferList.first, let dataPtr = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let floatCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let frames = floatCount / channels
            guard frames > 0 else { return }
            let samples = dataPtr.assumingMemoryBound(to: Float.self)
            var downsampled: [Float] = []
            downsampled.reserveCapacity(frames / step + 1)
            var idx = 0
            while idx < frames {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += samples[idx * channels + ch]
                }
                downsampled.append(sum / Float(channels))
                idx += step
            }
            self.mixLock.lock()
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
