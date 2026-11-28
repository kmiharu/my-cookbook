import AVFoundation
import CatalogCore
import Foundation
import Observation

enum PlaybackSource: String, CaseIterable, Identifiable {
    case stream = "HLS 動画と音声"
    case audio = "端末内の確認音"

    var id: Self { self }

    var url: URL? {
        switch self {
        case .stream:
            URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")
        case .audio:
            Bundle.main.url(forResource: "PlaybackTone", withExtension: "wav")
        }
    }
}

@MainActor
@Observable
final class PlaybackModel {
    enum Status {
        case idle, loading, ready, playing, waiting, paused, ended, failed

        var label: String {
            switch self {
            case .idle: "停止中"
            case .loading: "読み込み中"
            case .ready: "再生を準備しました"
            case .playing: "再生中"
            case .waiting: "再バッファ中"
            case .paused: "一時停止中"
            case .ended: "再生が終了しました"
            case .failed: "読み込めませんでした"
            }
        }
    }

    let player = AVPlayer()
    private(set) var status: Status = .idle
    private(set) var seconds = 0.0
    private(set) var duration = 0.0
    private(set) var preparedMilliseconds: Double?
    private(set) var firstFrameMilliseconds: Double?
    private(set) var stalls = 0
    private(set) var stalledSeconds = 0.0
    private(set) var averageVideoBitrate: Double?
    private(set) var failureMessage: String?
    private(set) var generation = 0

    private let clock = ContinuousClock()
    @ObservationIgnored private var requestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var stalledAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastTelemetryAt: ContinuousClock.Instant?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var finishedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var diagnostics: DiagnosticStore?
    @ObservationIgnored private var startupWatchdog: Task<Void, Never>?
    @ObservationIgnored private var audioSessionActive = false
    private var source: PlaybackSource = .stream
    private var wantsPlayback = false
    private var hasPlayed = false
    private var resumeAt = 0.0
    private var seekRevision = 0

    func load(_ source: PlaybackSource, diagnostics: DiagnosticStore?, resume: Bool = true) {
        let initialTime = resume && source == self.source ? resumeAt : 0
        release()
        self.source = source
        self.diagnostics = diagnostics
        resumeAt = initialTime
        seconds = initialTime
        duration = 0
        preparedMilliseconds = nil
        firstFrameMilliseconds = nil
        stalls = 0
        stalledSeconds = 0
        averageVideoBitrate = nil
        failureMessage = nil
        hasPlayed = false
        guard let url = source.url else {
            failureMessage = "同梱の素材を読み込めませんでした。もう一方の素材をお試しください。"
            status = .failed
            record(.load, outcome: .failure)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            failureMessage = "音声の再生を準備できませんでした。他の音声が停止してから再試行してください。"
            status = .failed
            record(.load, outcome: .failure)
            return
        }

        let item = AVPlayerItem(url: url)
        if source == .stream {
            item.preferredPeakBitRate = 3_000_000
            item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        }
        let token = generation
        requestedAt = clock.now
        wantsPlayback = true
        status = .loading
        lastTelemetryAt = clock.now
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged(token: token) }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.playbackStatusChanged(token: token) }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.updateTime(seconds, token: token) }
        }
        finishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(token: token) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        startupWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, generation == token, !hasPlayed, wantsPlayback else { return }
            fail()
        }
    }

    func togglePause() {
        switch status {
        case .playing, .ready, .waiting:
            wantsPlayback = false
            player.pause()
            endStall(outcome: .cancelled)
            status = .paused
        case .paused:
            wantsPlayback = true
            player.play()
        default:
            break
        }
    }

    func seek(to seconds: Double, resumeWhenDone: Bool? = nil) {
        guard let item = player.currentItem, item.status == .readyToPlay, seconds.isFinite else { return }
        let target = max(0, min(seconds, duration))
        let timestamp = clock.now
        let token = generation
        seekRevision += 1
        let revision = seekRevision
        item.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, token == generation, revision == seekRevision else { return }
                record(.seek, outcome: completed ? .success : .cancelled, since: timestamp)
                guard completed else { return }
                self.seconds = target
                if resumeWhenDone == true && wantsPlayback { player.play() }
            }
        }
    }

    func displayedFrame(generation token: Int) {
        guard token == generation, source == .stream,
              firstFrameMilliseconds == nil, let requestedAt else { return }
        firstFrameMilliseconds = requestedAt.duration(to: clock.now).mediaMilliseconds
        record(.firstFrame, outcome: .success, since: requestedAt)
    }

    func release(rememberPosition: Bool = false) {
        let wasStarting = status == .loading
        generation += 1
        resumeAt = rememberPosition ? seconds : 0
        if wasStarting, let requestedAt {
            record(.load, outcome: .cancelled, since: requestedAt)
        }
        wantsPlayback = false
        endStall(outcome: .cancelled)
        startupWatchdog?.cancel()
        startupWatchdog = nil
        observations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let finishedObserver { NotificationCenter.default.removeObserver(finishedObserver) }
        finishedObserver = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        requestedAt = nil
        status = .idle
    }

    private func itemStatusChanged(token: Int) {
        guard token == generation, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard preparedMilliseconds == nil else { return }
            if let requestedAt {
                preparedMilliseconds = requestedAt.duration(to: clock.now).mediaMilliseconds
                record(.ready, outcome: .success, since: requestedAt)
            }
            if item.duration.seconds.isFinite { duration = max(0, item.duration.seconds) }
            if resumeAt > 0, duration > 0 {
                player.pause()
                seek(to: resumeAt, resumeWhenDone: true)
            }
            playbackStatusChanged(token: token)
        case .failed:
            fail()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func playbackStatusChanged(token: Int) {
        guard token == generation, player.currentItem?.status == .readyToPlay else { return }
        switch player.timeControlStatus {
        case .playing:
            startupWatchdog?.cancel()
            startupWatchdog = nil
            if !hasPlayed { record(.play, outcome: .success, since: requestedAt) }
            hasPlayed = true
            endStall(outcome: .success)
            status = .playing
        case .waitingToPlayAtSpecifiedRate:
            guard wantsPlayback else { return }
            if !hasPlayed {
                status = .ready
                return
            }
            if stalledAt == nil {
                stalledAt = clock.now
                stalls += 1
            }
            status = .waiting
        case .paused:
            guard status != .ended, status != .failed else { return }
            status = wantsPlayback ? .ready : .paused
        @unknown default:
            break
        }
    }

    private func endStall(outcome: DiagnosticOutcome) {
        guard let stalledAt else { return }
        self.stalledAt = nil
        stalledSeconds += stalledAt.duration(to: clock.now).mediaMilliseconds / 1_000
        record(.rebuffer, outcome: outcome, since: stalledAt)
    }

    private func updateTime(_ seconds: Double, token: Int) {
        guard token == generation, seconds.isFinite else { return }
        self.seconds = max(seconds, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite { self.duration = max(0, duration) }
        if let lastTelemetryAt, lastTelemetryAt.duration(to: clock.now) >= .seconds(5) {
            self.lastTelemetryAt = clock.now
            if let bitrate = player.currentItem?.accessLog()?.events.last?.indicatedBitrate, bitrate > 0 {
                averageVideoBitrate = bitrate
            }
        }
    }

    private func finish(token: Int) {
        guard token == generation else { return }
        wantsPlayback = false
        endStall(outcome: .success)
        status = .ended
    }

    private func fail() {
        record(.load, outcome: .failure, since: requestedAt)
        endStall(outcome: .failure)
        status = .failed
        release()
        failureMessage = source == .stream
            ? "通信状態を確認して、もう一度お試しください。確認音なら通信せずに再生できます。"
            : "確認音を再生できませんでした。もう一度お試しください。"
        status = .failed
    }

    private func record(_ action: DiagnosticAction, outcome: DiagnosticOutcome, since: ContinuousClock.Instant? = nil) {
        let elapsed = since.map { $0.duration(to: clock.now).mediaMilliseconds }
        Task { [diagnostics] in
            await diagnostics?.record(sample: .playback, action: action, outcome: outcome, milliseconds: elapsed)
        }
    }
}
