import AVFoundation

/// The app's `DriveAudioBuffer` (in `ios/SpeakUp/Drive/DriveAudio.swift`, which needs iOS's
/// audio session and so is not shared): one input buffer and where it starts on the drive clock.
struct DriveAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Seconds since the drive started.
    let startTime: TimeInterval
}
