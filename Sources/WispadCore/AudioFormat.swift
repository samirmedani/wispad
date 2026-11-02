import Foundation

public enum PCM16Resampler {
    public static func resample(_ input: Data, from inputRate: Int, to outputRate: Int) -> Data {
        if inputRate == outputRate { return input }
        let inputCount = input.count / 2
        guard inputCount > 0, inputRate > 0, outputRate > 0 else { return Data() }
        let outputCount = max(1, Int((Double(inputCount) * Double(outputRate) / Double(inputRate)).rounded(.toNearestOrAwayFromZero)))
        var output = Data(count: outputCount * MemoryLayout<Int16>.size)
        input.withUnsafeBytes { inputRaw in
            let inputSamples = inputRaw.bindMemory(to: Int16.self)
            output.withUnsafeMutableBytes { outputRaw in
                let outputSamples = outputRaw.bindMemory(to: Int16.self)
                if inputCount == 1 {
                    for index in 0..<outputCount {
                        outputSamples[index] = inputSamples[0]
                    }
                    return
                }
                let last = Double(inputCount - 1)
                let scale = last / Double(max(outputCount - 1, 1))
                for index in 0..<outputCount {
                    let position = Double(index) * scale
                    let left = min(Int(position), inputCount - 1)
                    let right = min(left + 1, inputCount - 1)
                    let fraction = position - Double(left)
                    let value = Double(inputSamples[left]) + (Double(inputSamples[right]) - Double(inputSamples[left])) * fraction
                    outputSamples[index] = Int16(max(-32768, min(32767, value.rounded())))
                }
            }
        }
        return output
    }
}

public enum WAVHeader {
    public static func make(dataBytes: Int, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(bitsPerSample))
        data.append(contentsOf: [UInt8]("data".utf8))
        data.appendLE(UInt32(dataBytes))
        return data
    }
}

public final class WAVStream: @unchecked Sendable {
    private let handle: FileHandle
    private var dataBytes = 0
    public let sampleRate: Int
    public let url: URL

    public var durationSeconds: Double {
        Double(dataBytes / 2) / Double(sampleRate)
    }

    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVHeader.make(dataBytes: 0, sampleRate: sampleRate))
    }

    public func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        do {
            try handle.write(contentsOf: pcm)
            dataBytes += pcm.count
        } catch {
            // A full disk should not crash a dictation. The caller still has the live transcript.
        }
    }

    public func close() {
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVHeader.make(dataBytes: dataBytes, sampleRate: sampleRate))
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    /// Fichier d'une écoute que Wispad n'a pas pu fermer (fermeture inattendue) : son en-tête dit encore 0 octet.
    /// Il reçoit la taille réelle des données. Rend la durée, nil si le fichier est absent, illisible ou vide.
    public static func repair(url: URL, sampleRate: Int = 16_000) -> Double? {
        let headerSize = WAVHeader.make(dataBytes: 0, sampleRate: sampleRate).count
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(headerSize) else { return nil }
        let available = Int(size) - headerSize
        let dataBytes = available - available % 2
        guard dataBytes > 0 else { return nil }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVHeader.make(dataBytes: dataBytes, sampleRate: sampleRate))
        } catch {
            return nil
        }
        return Double(dataBytes / 2) / Double(sampleRate)
    }
}

/// La dictée dont le micro écrit le fichier, notée dès son début : si Wispad se ferme sans prévenir (plantage), son
/// audio est retrouvé au lancement suivant et rangé dans l'historique, prêt à transcrire. Aucun texte ni contexte.
public struct InterruptedDictation: Equatable, Sendable {
    public var path: String
    public var provider: String
    public var model: String
    public var appName: String?
    public var bundleID: String?
    public var savedAt: Date

    public init(path: String, provider: String, model: String, appName: String?, bundleID: String?, savedAt: Date = Date()) {
        self.path = path
        self.provider = provider
        self.model = model
        self.appName = appName
        self.bundleID = bundleID
        self.savedAt = savedAt
    }

    public static let defaultsKey = "wispad.dictation.interrupted"
    /// Au-delà, l'audio a pu être effacé par la conservation : la note ne décrit plus rien d'utile.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public func save(defaults: UserDefaults = .standard) {
        var record: [String: Any] = ["path": path, "provider": provider, "model": model, "saved": savedAt.timeIntervalSince1970]
        if let appName { record["app"] = appName }
        if let bundleID { record["bundle"] = bundleID }
        defaults.set(record, forKey: Self.defaultsKey)
    }

    /// La note, effacée dès la lecture ; nil si elle manque, est incomplète ou trop vieille.
    public static func take(defaults: UserDefaults = .standard, now: Date = Date()) -> InterruptedDictation? {
        guard let record = defaults.dictionary(forKey: defaultsKey) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        guard let path = record["path"] as? String, !path.isEmpty,
              let provider = record["provider"] as? String, let model = record["model"] as? String,
              let saved = record["saved"] as? Double, (0...lifetime).contains(now.timeIntervalSince1970 - saved) else { return nil }
        return InterruptedDictation(path: path, provider: provider, model: model, appName: record["app"] as? String,
                                    bundleID: record["bundle"] as? String, savedAt: Date(timeIntervalSince1970: saved))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
