import AVFoundation
import Foundation

/// Approximate offline key recognition from imported audio, not cloud analysis.
/// Uses chroma energy from 16 short windows and major/minor tonal profiles.
/// Results are user-editable because full songs can change key and contain
/// strong overtones; never present this as an authoritative musical key.
enum LocalMixKeyAnalyzer {
    static func estimate(_ url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            return "Unknown"
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 8000, file.length > 4096 else { return "Unknown" }
        var chroma = [Double](repeating: 0, count: 12)
        var windowCount = 0
        let limit = min(file.length, Int64(sampleRate * 64))
        for n in 0..<16 {
            let pos = max(0, min(file.length - 4096, Int64(Double(n + 1) * Double(limit) / 17.0)))
            file.framePosition = pos
            do { try file.read(into: buffer, frameCount: 4096) }
            catch { continue }
            let count = Int(buffer.frameLength)
            guard count >= 2048, let channel = buffer.floatChannelData?[0] else { continue }
            var samples = [Double](repeating: 0, count: count)
            var energy = 0.0
            for i in 0..<count {
                let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(count - 1))
                let sample = Double(channel[i]) * win
                samples[i] = sample
                energy += sample * sample
            }
            if energy < 0.00001 { continue }

            for midi in 36...83 {
                let frequency = 440.0 * pow(2.0, Double(midi - 69) / 12)
                let omega = 2.0 * Double.pi * frequency / sampleRate
                let coeff = 2 * cos(omega)
                var one = 0.0, two = 0.0
                for sample in samples {
                    let current = sample + coeff * one - two
                    two = one
                    one = current
                }
                let power = max(0, one * one + two * two - coeff * one * two)
                // Taper the influence of upper harmonics of bass instruments.
                chroma[midi % 12] += sqrt(power) / pow(frequency, 0.3)
            }
            windowCount += 1
        }
        guard windowCount >= 3 else { return "Unknown" }
        let total = chroma.reduce(0, +)
        guard total > 0.05 else { return "Unknown" }

        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                     2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                     2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        let camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        let average = total / 12
        let variance = sqrt(chroma.reduce(0) { $0 + pow($1 - average, 2) } / 12)
        guard variance > average * 0.03 else { return "Unknown" }

        func cosineScore(_ profile: [Double], root: Int) -> Double {
            let pAvg = profile.reduce(0, +) / 12
            var numerator = 0.0, pNorm = 0.0, cNorm = 0.0
            for pitch in 0..<12 {
                let p = profile[(pitch - root + 12) % 12] - pAvg
                let c = chroma[pitch] - average
                numerator += p * c
                pNorm += p * p
                cNorm += c * c
            }
            return numerator / sqrt(max(0.000001, pNorm * cNorm))
        }

        var bestScore = 0.0, bestName = "Unknown"
        for root in 0..<12 {
            let a = cosineScore(major, root: root)
            if a > bestScore {
                bestScore = a
                bestName = "\(camelotMajor[root])B"
            }
            let b = cosineScore(minor, root: root)
            if b > bestScore {
                bestScore = b
                bestName = "\(camelotMinor[root])A"
            }
        }
        return bestScore >= 0.28 ? bestName : "Unknown"
    }
}
