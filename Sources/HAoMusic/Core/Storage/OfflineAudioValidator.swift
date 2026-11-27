import AVFoundation
import CryptoKit
import Foundation

enum OfflineAudioValidator {
    /// Read both encoded bytes and decoded frames. An HTTP 200 or a playable
    /// header is insufficient evidence that the complete song arrived.
    /// Returns the file's MD5, so a provisional descriptor (no checksum from
    /// its source) can be finalized with the real one after verification.
    @discardableResult
    static func validate(url: URL, descriptor: OfflineAudioDescriptor) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == descriptor.byteCount else { throw OfflineAudioError.incomplete }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = Insecure.MD5()
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty { digest.update(data: data) }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        // A provisional descriptor carries the MD5 of its URL, not of the
        // file: size + a full decode + the duration below are the proof,
        // and the caller finalizes the descriptor with this checksum.
        if !descriptor.identity.md5Provisional {
            guard checksum == descriptor.identity.contentMD5.lowercased() else { throw OfflineAudioError.checksumMismatch }
        }
        do {
            let audio = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384),
                  audio.processingFormat.sampleRate > 0 else { throw OfflineAudioError.invalidAudio }
            var frames: Int64 = 0
            while audio.framePosition < audio.length {
                let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), audio.length - audio.framePosition))
                try audio.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw OfflineAudioError.invalidAudio }
                frames += Int64(buffer.frameLength)
            }
            let duration = Double(frames) / audio.processingFormat.sampleRate
            guard frames > 0, abs(duration - descriptor.duration) <= max(2, descriptor.duration * 0.03) else {
                throw OfflineAudioError.invalidAudio
            }
        } catch { throw OfflineAudioError.invalidAudio }
        return checksum
    }
}
