import CatalogCore
import PhotosUI
import SwiftUI
import UIKit

struct ImageEditingSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var processor = MediaImageProcessor()
    @State private var selection: PhotosPickerItem?
    @State private var importRevision = 0
    @State private var source: Data?
    @State private var preview: UIImage?
    @State private var edits = ImageEdits()
    @State private var history: [ImageEdits] = []
    @State private var stroke: [CGPoint] = []
    @State private var drawing = false
    @State private var previewRevision = 0
    @State private var exportRequest: UUID?
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var busyImporting = false
    @State private var busyRendering = false
    @State private var fixture: URL?
    @State private var previewActive = true

    private let maximumStrokes = 24
    private let maximumPoints = 96

    var body: some View {
        Form {
            Section("素材を選ぶ") {
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                }
                .disabled(exportRequest != nil || busyImporting)
                Button("サンプル画像を使う") {
                    guard let url = Bundle.main.url(forResource: "StudioSample", withExtension: "png") else {
                        message = "同梱の画像が見つかりませんでした。写真を選び直してください。"
                        return
                    }
                    selection = nil
                    importRevision += 1
                    fixture = url
                }
                .disabled(exportRequest != nil || busyImporting)
                if busyImporting {
                    ProgressView("写真を読み込み中")
                    Button("キャンセル", action: cancelImport)
                }
                if let message {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            Section("プレビュー") {
                if let preview {
                    imagePreview(preview)
                    if busyRendering { ProgressView("プレビューを更新中") }
                } else {
                    ContentUnavailableView("画像がありません", systemImage: "photo",
                                           description: Text("写真を選ぶか、サンプル画像を使えます。"))
                }
            }
            if source != nil {
                editingControls
                Section("書き出し") {
                    if exportRequest != nil {
                        ProgressView("JPEG を作成中")
                        Button("キャンセル") { exportRequest = nil }
                    } else if let exportURL {
                        ShareLink(item: exportURL, subject: Text("編集した写真")) {
                            Label("画像を共有", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("JPEG を書き出す") { exportRequest = UUID() }
                            .disabled(busyImporting || busyRendering)
                    }
                }
            }
        }
        .navigationTitle("写真を加工する")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { _, item in
            if item != nil {
                fixture = nil
                importRevision += 1
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelWork() }
            if phase == .active { resumePreview() }
        }
        .onAppear(perform: resumePreview)
        .onDisappear(perform: cancelWork)
        .task(id: importRevision) { await importPhoto(revision: importRevision) }
        .task(id: previewRevision) { await updatePreview(revision: previewRevision) }
        .task(id: exportRequest) { await exportPhoto(request: exportRequest) }
    }

    private var editingControls: some View {
        Section("加工") {
            Toggle("正方形に切り抜く", isOn: Binding(
                get: { edits.squareCrop },
                set: { enabled in changeEdits { $0.squareCrop = enabled } }
            ))
            Picker("フィルタ", selection: Binding(
                get: { edits.filter },
                set: { filter in changeEdits { $0.filter = filter } }
            )) {
                ForEach(StudioFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("指で線を描く", isOn: $drawing)
            Button("中央に線を引く") {
                changeEdits { $0.strokes.append([CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5)]) }
            }
            .disabled(edits.strokes.count >= maximumStrokes)
            if edits.strokes.count >= maximumStrokes {
                Text("線は 24 本まで追加できます。取り消すと新しい線を描けます。")
                    .foregroundStyle(.secondary)
            }
            Button("直前の加工を取り消す") {
                guard let previous = history.popLast() else { return }
                edits = previous
                requestPreview()
            }
            .disabled(history.isEmpty)
        }
        .disabled(exportRequest != nil || busyImporting)
    }

    private func imagePreview(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                if drawing {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            guard let first = stroke.first else { return }
                            var path = Path()
                            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                            for point in stroke.dropFirst() {
                                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                            }
                            context.stroke(path, with: .color(.yellow), style: StrokeStyle(
                                lineWidth: max(2, min(size.width, size.height) * 0.015), lineCap: .round, lineJoin: .round
                            ))
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard !busyRendering, !busyImporting, exportRequest == nil,
                                      edits.strokes.count < maximumStrokes,
                                      geometry.size.width > 0, geometry.size.height > 0 else { return }
                                let point = CGPoint(
                                    x: min(1, max(0, drag.location.x / geometry.size.width)),
                                    y: min(1, max(0, drag.location.y / geometry.size.height))
                                )
                                if stroke.count < maximumPoints {
                                    stroke.append(point)
                                } else {
                                    stroke[maximumPoints - 1] = point
                                }
                            }
                            .onEnded { _ in
                                let finished = stroke
                                stroke.removeAll(keepingCapacity: true)
                                if finished.count > 1, edits.strokes.count < maximumStrokes {
                                    changeEdits { $0.strokes.append(finished) }
                                }
                            }
                        )
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxHeight: 320)
            .accessibilityLabel("加工した画像のプレビュー")
    }

    private func changeEdits(_ update: (inout ImageEdits) -> Void) {
        history.append(edits)
        if history.count > 20 { history.removeFirst() }
        update(&edits)
        requestPreview()
    }

    private func requestPreview() {
        previewRevision += 1
        exportURL = nil
        message = nil
    }

    private func importPhoto(revision: Int) async {
        if let fixture {
            await loadImage(revision: revision, file: fixture, selection: nil)
        } else if let selection {
            await loadImage(revision: revision, file: nil, selection: selection)
        }
    }

    private func loadImage(revision: Int, file: URL?, selection: PhotosPickerItem?) async {
        busyImporting = true
        message = nil
        let began = ContinuousClock.now
        defer { if revision == importRevision { busyImporting = false } }
        do {
            let imported = try await selection?.loadTransferable(type: ImportedPhoto.self)
            defer {
                if let imported { try? FileManager.default.removeItem(at: imported.url) }
            }
            guard let url = imported?.url ?? file else { throw MediaImageError.invalidImage }
            let asset = try await processor.prepare(url)
            try Task.checkCancellation()
            guard revision == importRevision else { return }
            source = asset.full
            preview = UIImage(data: asset.preview)
            edits = ImageEdits()
            history.removeAll()
            requestPreview()
            await record(.load, .success, began)
        } catch is CancellationError {
            await record(.load, .cancelled, began)
        } catch {
            guard !Task.isCancelled, revision == importRevision else { return }
            message = (error as? MediaImageError)?.localizedDescription ?? "写真を読み込めませんでした。通信と容量を確認して、選び直してください。"
            self.selection = nil
            fixture = nil
            await record(.load, .failure, began)
        }
    }

    private func updatePreview(revision: Int) async {
        guard let source, previewActive else { return }
        let currentEdits = edits
        let began = ContinuousClock.now
        busyRendering = true
        defer { if revision == previewRevision { busyRendering = false } }
        do {
            try await Task.sleep(for: .milliseconds(100))
            let result = try await processor.preview(source, edits: currentEdits)
            try Task.checkCancellation()
            guard revision == previewRevision else { return }
            preview = UIImage(data: result)
            await record(.process, .success, began)
        } catch is CancellationError {
            await record(.process, .cancelled, began)
        } catch {
            guard !Task.isCancelled, revision == previewRevision else { return }
            message = "プレビューを作成できませんでした。直前の加工を取り消すか、写真を選び直してください。"
            await record(.process, .failure, began)
        }
    }

    private func exportPhoto(request: UUID?) async {
        guard let request, let source else { return }
        let began = ContinuousClock.now
        defer { if request == exportRequest { exportRequest = nil } }
        do {
            let url = try await processor.export(source, edits: edits)
            if Task.isCancelled || request != exportRequest {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            exportURL = url
            await record(.save, .success, began)
        } catch is CancellationError {
            await record(.save, .cancelled, began)
        } catch {
            guard !Task.isCancelled, request == exportRequest else { return }
            message = (error as? MediaImageError)?.localizedDescription ?? "書き出せませんでした。空き容量を確認してお試しください。"
            await record(.save, .failure, began)
        }
    }

    private func cancelImport() {
        fixture = nil
        selection = nil
        importRevision += 1
        busyImporting = false
    }

    private func cancelWork() {
        cancelImport()
        exportRequest = nil
        busyRendering = false
        previewActive = false
        previewRevision += 1
    }

    private func resumePreview() {
        guard !previewActive else { return }
        previewActive = true
        previewRevision += 1
    }

    private func record(_ action: DiagnosticAction, _ outcome: DiagnosticOutcome, _ began: ContinuousClock.Instant) async {
        await diagnostics?.record(sample: .studio, action: action, outcome: outcome,
                                  milliseconds: began.duration(to: .now).mediaMilliseconds)
    }
}

#Preview {
    NavigationStack { ImageEditingSampleView() }
}
