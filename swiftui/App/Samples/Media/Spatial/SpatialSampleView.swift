import ARKit
import AVFoundation
import CatalogCore
import RealityKit
import SwiftUI
import UIKit

struct SpatialSampleView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case ar = "AR"
        case game = "ミニゲーム"
        var id: Self { self }
    }

    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var mode: Mode = .ar
    @State private var model = SpatialModel()
    @State private var authorization: AVAuthorizationStatus = .notDetermined
    @State private var arRequest = false
    @State private var cameraRequestPending = false

    var body: some View {
        Form {
            Picker("遊び方", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if mode == .ar { arContent } else { TileSearchGame() }
        }
        .navigationTitle("空間に置く・遊ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: arRequest) {
            guard arRequest else { return }
            defer { cameraRequestPending = false }
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
            guard !Task.isCancelled, mode == .ar, scenePhase == .active else { return }
            guard authorization == .authorized else {
                await diagnostics?.record(sample: .spatial, action: .track, outcome: .limited)
                return
            }
            model.begin()
        }
        .onChange(of: mode) { _, mode in
            if mode != .ar { stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && model.running) { stop() }
            if phase == .active { authorization = AVCaptureDevice.authorizationStatus(for: .video) }
        }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private var arContent: some View {
        if !ARWorldTrackingConfiguration.isSupported {
            ContentUnavailableView("AR に対応していない端末です", systemImage: "arkit",
                                   description: Text("ミニゲームを選ぶとカメラなしで遊べます。"))
        } else if authorization == .denied || authorization == .restricted {
            Section("カメラへのアクセス") {
                Text("AR ではカメラへのアクセスが必要です。ミニゲームはカメラを使いません。")
                if authorization == .denied {
                    Button("設定を開く") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                    }
                }
            }
        } else if model.running {
            Section("床か机にブロックを置く") {
                ARStage(model: model, command: model.command, diagnostics: diagnostics)
                    .frame(height: 265)
                    .accessibilityHidden(true)
                Label(model.guidance, systemImage: "viewfinder")
                    .accessibilityAddTraits(.updatesFrequently)
                Button("画面中央に置く") { model.command = .place }
                    .disabled(!model.canPlace || model.placements >= SpatialModel.placementLimit)
                LabeledContent("配置数", value: "\(model.placements) / \(SpatialModel.placementLimit)")
                Button("配置と追跡をリセット") { model.command = .reset }
                Button("AR を終了", action: stop)
            }
            Section("このセッションの測定") {
                LabeledContent("カメラフレーム更新", value: model.frameRate.map { "\($0.formatted(.number.precision(.fractionLength(1)))) fps" } ?? "—")
                LabeledContent("端末の熱状態", value: model.thermal)
            }
        } else {
            Section("平らな面を探す") {
                Text("周囲の安全を確かめ、床か机へカメラをゆっくり向けます。再開時は新しい配置から始めます。")
                if cameraRequestPending {
                    ProgressView("カメラへのアクセスを確認中")
                    Button("キャンセル", action: stop)
                } else {
                    Button("AR を始める") {
                        if arRequest {
                            if authorization == .authorized { model.begin() }
                        } else {
                            cameraRequestPending = true
                            arRequest = true
                        }
                    }
                }
            }
        }
    }

    private func stop() {
        model.end()
        arRequest = false
        cameraRequestPending = false
    }
}

@MainActor
@Observable
private final class SpatialModel {
    enum Command { case place, reset }

    static let placementLimit = 6
    var command: Command?
    var running = false
    var canPlace = false
    var guidance = "床か机へカメラをゆっくり向けてください。"
    var placements = 0
    var frameRate: Double?
    var thermal = "確認中"

    func begin() {
        running = true
        resetDisplay()
    }

    func end() {
        running = false
        command = nil
    }

    func resetDisplay() {
        canPlace = false
        guidance = "床か机へカメラをゆっくり向けてください。"
        placements = 0
        frameRate = nil
        thermal = "確認中"
    }
}

private struct ARStage: UIViewRepresentable {
    let model: SpatialModel
    let command: SpatialModel.Command?
    let diagnostics: DiagnosticStore?

    func makeCoordinator() -> Coordinator { Coordinator(model: model, diagnostics: diagnostics) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.start(view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        guard let command else { return }
        // Observable state can only be written after this representable update ends.
        Task { @MainActor [weak coordinator = context.coordinator, weak model] in
            guard let model, model.running, model.command == command else { return }
            model.command = nil
            coordinator?.perform(command, in: view)
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.end(view)
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        enum Tracking: Equatable {
            case normal, unavailable
            case initializing, motion, features, relocalizing, other
        }

        private weak var model: SpatialModel?
        private weak var view: ARView?
        private let diagnostics: DiagnosticStore?
        private var anchors: [AnchorEntity] = []
        private var mesh: MeshResource?
        private var tracking: Tracking?
        private var windowStart: TimeInterval?
        private var frameCount = 0
        private var lastThermal: ProcessInfo.ThermalState?

        init(model: SpatialModel, diagnostics: DiagnosticStore?) {
            self.model = model
            self.diagnostics = diagnostics
        }

        func start(_ view: ARView) {
            self.view = view
            view.session.delegateQueue = .main
            view.session.delegate = self
            mesh = .generateBox(size: 0.08, cornerRadius: 0.012)
            run(view)
        }

        func end(_ view: ARView) {
            view.session.delegate = nil
            view.session.pause()
            clearAnchors(in: view)
            mesh = nil
            self.view = nil
        }

        func perform(_ command: SpatialModel.Command, in view: ARView) {
            switch command {
            case .place:
                place(in: view)
            case .reset:
                clearAnchors(in: view)
                model?.resetDisplay()
                run(view)
            }
        }

        private func run(_ view: ARView) {
            tracking = nil
            windowStart = nil
            frameCount = 0
            lastThermal = nil
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal]
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        private func place(in view: ARView) {
            guard let model, model.canPlace, let mesh,
                  anchors.count < SpatialModel.placementLimit else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let began = ContinuousClock.now
            guard let hit = view.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal).first else {
                model.guidance = "中央に水平面が見つかりません。机か床に向け直してください。"
                record(.process, .limited)
                return
            }
            let anchor = AnchorEntity(world: hit.worldTransform)
            let block = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)])
            block.position.y = 0.04
            anchor.addChild(block)
            view.scene.addAnchor(anchor)
            anchors.append(anchor)
            model.placements = anchors.count
            model.guidance = "ブロックを置きました。"
            record(.process, .success, began.duration(to: .now).mediaMilliseconds)
        }

        private func clearAnchors(in view: ARView) {
            anchors.forEach { view.scene.removeAnchor($0) }
            anchors.removeAll()
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let value: Tracking
            switch frame.camera.trackingState {
            case .normal: value = .normal
            case .notAvailable: value = .unavailable
            case .limited(let reason):
                switch reason {
                case .initializing: value = .initializing
                case .excessiveMotion: value = .motion
                case .insufficientFeatures: value = .features
                case .relocalizing: value = .relocalizing
                @unknown default: value = .other
                }
            }
            let timestamp = frame.timestamp
            // start(_:) sets the delegate queue to the main queue. Avoid creating one task per frame.
            MainActor.assumeIsolated { frameArrived(timestamp, tracking: value) }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated {
                model?.canPlace = false
                model?.guidance = "AR が中断されました。"
                record(.track, .cancelled)
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated {
                guard let view, model?.running == true else { return }
                perform(.reset, in: view)
            }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
            MainActor.assumeIsolated {
                model?.canPlace = false
                model?.guidance = "AR を開始できませんでした。配置と追跡をリセットしてください。"
                record(.track, .failure)
            }
        }

        private func frameArrived(_ time: TimeInterval, tracking: Tracking) {
            guard let model, model.running else { return }
            if self.tracking != tracking {
                self.tracking = tracking
                model.canPlace = tracking == .normal
                switch tracking {
                case .normal:
                    model.guidance = "画面中央を床か机に合わせて、ブロックを置けます。"
                    record(.trackingNormal, .success)
                case .unavailable:
                    model.guidance = "追跡を利用できません。配置と追跡をリセットできます。"
                    record(.trackingUnavailable, .limited)
                case .initializing, .relocalizing:
                    model.guidance = "周囲を認識しています。床か机にカメラを向けてください。"
                    record(.trackingLimited, .limited)
                case .motion, .features, .other:
                    model.guidance = "端末をゆっくり動かし、模様や輪郭のある面にカメラを向けてください。"
                    record(.trackingLimited, .limited)
                }
            }
            guard let start = windowStart else {
                windowStart = time
                return
            }
            frameCount += 1
            let elapsed = time - start
            guard elapsed >= 1 else { return }
            model.frameRate = Double(frameCount) / elapsed
            // The UI refreshes once a second. Diagnostic frame intervals are sampled every five seconds.
            if Int(time / 5) != Int(start / 5) {
                record(.frameInterval, .success, elapsed * 1_000 / Double(frameCount))
            }
            windowStart = time
            frameCount = 0
            let thermal = ProcessInfo.processInfo.thermalState
            if lastThermal != thermal {
                lastThermal = thermal
                switch thermal {
                case .nominal: model.thermal = "通常"
                case .fair: model.thermal = "やや上昇"
                case .serious: model.thermal = "高い"
                case .critical: model.thermal = "非常に高い"
                @unknown default: model.thermal = "不明"
                }
                record(.thermal, thermal == .serious || thermal == .critical ? .limited : .success)
            }
        }

        private func record(_ action: DiagnosticAction, _ outcome: DiagnosticOutcome, _ milliseconds: Double? = nil) {
            Task { [diagnostics] in
                await diagnostics?.record(sample: .spatial, action: action, outcome: outcome, milliseconds: milliseconds)
            }
        }
    }
}

private struct TileSearchGame: View {
    @Environment(\.diagnostics) private var diagnostics
    @State private var revealed: Set<Int> = []
    @State private var stars: Set<Int> = [1, 4, 7]
    @State private var finished = false

    var body: some View {
        Section("3 個の星を探す") {
            Text(finished ? "すべての星を見つけました。" : "タイルを開いて星を探してください。")
            LabeledContent("見つけた星", value: "\(revealed.intersection(stars).count) / 3")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44)), count: 3)) {
                ForEach(0..<9) { index in
                    Button {
                        revealed.insert(index)
                        if stars.isSubset(of: revealed) {
                            finished = true
                            Task { await diagnostics?.record(sample: .spatial, action: .play, outcome: .success) }
                        }
                    } label: {
                        Image(systemName: symbol(index))
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .disabled(finished || revealed.contains(index))
                    .accessibilityLabel("タイル \(index + 1)")
                    .accessibilityValue(revealed.contains(index) ? (stars.contains(index) ? "星" : "空") : "未確認")
                }
            }
            Button("新しいゲーム") {
                stars = Set((0..<9).shuffled().prefix(3))
                revealed.removeAll()
                finished = false
            }
        }
    }

    private func symbol(_ index: Int) -> String {
        guard revealed.contains(index) else { return "questionmark" }
        return stars.contains(index) ? "star.fill" : "circle"
    }
}

#Preview {
    NavigationStack { SpatialSampleView() }
}
