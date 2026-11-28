import AVFoundation
import SwiftUI
import UIKit

struct PlaybackSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PlaybackModel()
    @State private var source: PlaybackSource = .stream
    @State private var seekPosition: Double?
    @State private var isScrubbing = false

    var body: some View {
        Form {
            Section("再生する素材") {
                Picker("素材", selection: $source) {
                    ForEach(PlaybackSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                Text(source == .stream ? "Apple のテスト配信へ接続します。" : "同梱の短い確認音です。機内モードでも試せます。")
                    .foregroundStyle(.secondary)
            }
            Section("プレーヤー") {
                if source == .stream {
                    let token = model.generation
                    VideoSurface(player: model.player) {
                        model.displayedFrame(generation: token)
                    }
                    .id(token)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityLabel("動画")
                }
                Label(model.status.label, systemImage: model.status == .failed ? "exclamationmark.circle" : "play.circle")
                    .accessibilityAddTraits(.updatesFrequently)
                if model.status == .loading || model.status == .waiting {
                    ProgressView().accessibilityLabel(model.status.label)
                }
                if model.status == .failed, let message = model.failureMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                if model.duration > 0 && model.status != .idle && model.status != .failed {
                    Slider(
                        value: Binding(get: { seekPosition ?? model.seconds }, set: { seekPosition = $0 }),
                        in: 0...model.duration,
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing, let seekPosition {
                                model.seek(to: seekPosition)
                                self.seekPosition = nil
                            }
                        }
                    )
                    .accessibilityLabel("再生位置")
                    .accessibilityValue(time(model.seconds))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: model.seek(to: model.seconds + 10)
                        case .decrement: model.seek(to: model.seconds - 10)
                        @unknown default: break
                        }
                    }
                    LabeledContent("再生位置", value: "\(time(seekPosition ?? model.seconds)) / \(time(model.duration))")
                    Button("10秒進む") { model.seek(to: model.seconds + 10) }
                        .disabled(isScrubbing)
                }
                controls
            }
            Section("この再生の測定") {
                metric("アイテム準備完了", model.preparedMilliseconds)
                if source == .stream { metric("映像の表示準備完了", model.firstFrameMilliseconds) }
                LabeledContent("再バッファ", value: "\(model.stalls) 回")
                LabeledContent("再バッファの合計", value: "\(model.stalledSeconds.formatted(.number.precision(.fractionLength(1)))) 秒")
                if let bitrate = model.averageVideoBitrate {
                    LabeledContent("配信の選択レート", value: "\(Int(bitrate / 1_000)) kbps")
                }
            }
        }
        .navigationTitle("動画と音声を再生する")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: source) { _, _ in model.release() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.release(rememberPosition: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            if model.status != .idle { model.release(rememberPosition: true) }
        }
        .onDisappear { model.release() }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.status {
        case .idle, .failed, .ended:
            Button(model.status == .failed ? "再試行" : "再生") {
                model.load(source, diagnostics: diagnostics, resume: model.status == .idle)
            }
        case .playing, .paused, .ready, .waiting:
            Button(model.status == .paused ? "再開" : "一時停止", action: model.togglePause)
            Button("停止") { model.release() }
        case .loading:
            Button("読み込みを中止") { model.release() }
        }
    }

    private func metric(_ label: String, _ milliseconds: Double?) -> some View {
        LabeledContent(label, value: milliseconds.map { "\(Int($0)) ms" } ?? "—")
    }

    private func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var ready: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        var ready: @MainActor () -> Void
        var observation: NSKeyValueObservation?

        init(ready: @escaping @MainActor () -> Void) { self.ready = ready }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeCoordinator() -> Coordinator { Coordinator(ready: ready) }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        let coordinator = context.coordinator
        coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak coordinator] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak coordinator] in coordinator?.ready() }
        }
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        context.coordinator.ready = ready
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.playerLayer.player = nil
    }
}

#Preview {
    NavigationStack { PlaybackSampleView() }
}
