import AVFoundation
import Foundation
import Observation

enum DiaryAudioError: LocalizedError {
    case cannotRecord, cannotPlay

    var errorDescription: String? {
        switch self {
        case .cannotRecord: "音声を録音できませんでした。端末の空き容量とマイクを確認してください。"
        case .cannotPlay: "音声を再生できませんでした。音声を録り直してください。"
        }
    }
}

@MainActor
@Observable
final class DiaryAudio {
    static let maximumSeconds = 30.0

    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var recording: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var operation: Task<Void, Never>?

    func startRecording() throws {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diary-recordings", isDirectory: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) {
                let created = try old.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .now
                if created.timeIntervalSinceNow < -86_400 { try? FileManager.default.removeItem(at: old) }
            }
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ])
            guard recorder.record(forDuration: Self.maximumSeconds) else { throw DiaryAudioError.cannotRecord }
            self.recorder = recorder
            isRecording = true
            operation = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.maximumSeconds)) } catch { return }
                self?.stopRecording()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            deactivateAudio()
            throw error
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        operation?.cancel()
        operation = nil
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        isRecording = false
        deactivateAudio()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        removeRecording()
        recording = url
    }

    func play(_ url: URL) throws {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.duration.isFinite, player.duration > 0, player.play() else { throw DiaryAudioError.cannotPlay }
            self.player = player
            isPlaying = true
            let duration = min(Self.maximumSeconds, player.duration)
            operation = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                self?.stopPlayback()
            }
        } catch {
            deactivateAudio()
            throw error
        }
    }

    func stopPlayback() {
        guard let player else { return }
        operation?.cancel()
        operation = nil
        player.stop()
        self.player = nil
        isPlaying = false
        deactivateAudio()
    }

    func suspend() {
        stopRecording()
        stopPlayback()
    }

    func removeRecording() {
        stopPlayback()
        if let recording { try? FileManager.default.removeItem(at: recording) }
        recording = nil
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
