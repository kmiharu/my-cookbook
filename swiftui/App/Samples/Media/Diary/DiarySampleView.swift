import AVFoundation
import CatalogCore
import PhotosUI
import SwiftUI

struct DiarySampleView: View {
    private struct PhotoRequest {
        enum Source { case library(PhotosPickerItem), camera(CGImage, Int32) }
        let id = UUID()
        let source: Source
    }

    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var store = DiaryStore()
    @State private var audio = DiaryAudio()
    @State private var processor = MediaImageProcessor()
    @State private var entries: [DiaryEntry] = []
    @State private var loading = true
    @State private var savedEntriesError: String?
    @State private var note = ""
    @State private var place = ""
    @State private var selection: PhotosPickerItem?
    @State private var photoRequest: PhotoRequest?
    @State private var photo: MediaImageAsset?
    @State private var cameraRequest: UUID?
    @State private var cameraSheet = false
    @State private var micRequest: UUID?
    @State private var saveRequest: UUID?
    @State private var message: String?
    @State private var showSettings = false

    var body: some View {
        Form {
            Section("日記を書く") {
                TextField("できごと", text: $note, axis: .vertical)
                    .lineLimit(3...5)
                    .accessibilityHint("1文字から400文字まで")
                    .disabled(saveRequest != nil)
                TextField("場所（任意）", text: $place)
                    .accessibilityHint("80文字まで")
                    .disabled(saveRequest != nil)
                photoControls
                audioControls
                if let message {
                    Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if showSettings {
                    Button("設定を開く") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                    }
                }
                if saveRequest != nil {
                    ProgressView("日記を保存中")
                } else {
                    Button("日記を保存") { saveRequest = UUID() }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || photoRequest != nil || audio.isRecording || micRequest != nil)
                }
            }
            savedEntries
        }
        .navigationTitle("思い出を残す")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .task(id: photoRequest?.id) { await loadPhoto(photoRequest) }
        .task(id: cameraRequest) { await showCamera(cameraRequest) }
        .task(id: micRequest) { await startRecording(micRequest) }
        .task(id: saveRequest) { await save(saveRequest) }
        .onChange(of: selection) { _, selection in
            if let selection { photoRequest = PhotoRequest(source: .library(selection)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            audio.suspend()
        }
        .onDisappear {
            if !cameraSheet { suspend() }
        }
        .fullScreenCover(isPresented: $cameraSheet) {
            SystemCamera { result in
                cameraSheet = false
                if let (image, orientation) = result {
                    photoRequest = PhotoRequest(source: .camera(image, orientation))
                } else {
                    Task { await diagnostics?.record(sample: .journal, action: .capture, outcome: .cancelled) }
                }
            } failed: {
                cameraSheet = false
                message = "写真を取り込めませんでした。撮り直すか、写真を選んでください。"
                Task { await diagnostics?.record(sample: .journal, action: .capture, outcome: .failure) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var photoControls: some View {
        if let photo, let image = UIImage(data: photo.preview) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 180)
                .accessibilityLabel("日記に添付する写真")
            Button("添付する写真を外す") {
                cancelPhoto()
                self.photo = nil
            }
            .disabled(saveRequest != nil)
        }
        if photoRequest != nil || cameraRequest != nil {
            ProgressView("写真を準備中")
            Button("キャンセル", action: cancelPhoto)
        } else {
            PhotosPicker(selection: $selection, matching: .images) {
                Label("写真を選ぶ", systemImage: "photo")
            }
            .disabled(saveRequest != nil || audio.isRecording)
            Button("写真を撮る", systemImage: "camera") {
                cameraRequest = UUID()
            }
            .disabled(saveRequest != nil || audio.isRecording)
        }
    }

    @ViewBuilder
    private var audioControls: some View {
        if audio.isRecording {
            Label("録音中・最長30秒", systemImage: "mic.fill")
                .accessibilityAddTraits(.updatesFrequently)
            Button("録音を止める") { audio.stopRecording() }
        } else if micRequest != nil {
            ProgressView("マイクへのアクセスを確認中")
            Button("キャンセル") { micRequest = nil }
        } else {
            Button(audio.recording == nil ? "音声を録音" : "音声を録り直す", systemImage: "mic") {
                micRequest = UUID()
            }
            .disabled(saveRequest != nil || photoRequest != nil)
            if let url = audio.recording {
                Button(audio.isPlaying ? "再生を止める" : "録音を聴く", systemImage: "speaker.wave.2") {
                    if audio.isPlaying {
                        audio.stopPlayback()
                    } else {
                        do { try audio.play(url) } catch { message = DiaryAudioError.cannotPlay.localizedDescription }
                    }
                }
                Button("添付する音声を外す", action: audio.removeRecording)
                    .disabled(saveRequest != nil)
            }
        }
    }

    private var savedEntries: some View {
        Section("保存した日記") {
            if loading {
                ProgressView("日記を読み込み中")
            } else if let savedEntriesError {
                Text(savedEntriesError)
                Button("再試行") { Task { await reload() } }
            } else if entries.isEmpty {
                ContentUnavailableView("日記はまだありません", systemImage: "book.closed",
                                       description: Text("できごとを書くと、この端末に保存できます。"))
            } else {
                ForEach(entries) { entry in
                    NavigationLink {
                        DiaryDetailView(entry: entry, store: store) { entries = $0 }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.note).lineLimit(2)
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func showCamera(_ request: UUID?) async {
        guard let request else { return }
        defer { if request == cameraRequest { cameraRequest = nil } }
        message = nil
        showSettings = false
        audio.stopPlayback()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            message = "この端末ではカメラを使えません。「写真を選ぶ」を試せます。"
            await diagnostics?.record(sample: .journal, action: .capture, outcome: .limited)
            return
        }
        let authorized = await requestCameraAccess()
        guard !Task.isCancelled, request == cameraRequest, scenePhase != .background else { return }
        if authorized {
            cameraSheet = true
        } else {
            message = "カメラへのアクセスを許可すると撮影できます。写真の選択も使えます。"
            showSettings = AVCaptureDevice.authorizationStatus(for: .video) == .denied
            await diagnostics?.record(sample: .journal, action: .capture, outcome: .limited)
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    private func loadPhoto(_ request: PhotoRequest?) async {
        guard let request else { return }
        let began = ContinuousClock.now
        let action: DiagnosticAction
        switch request.source {
        case .camera: action = .capture
        case .library: action = .load
        }
        defer {
            if request.id == photoRequest?.id {
                photoRequest = nil
                selection = nil
            }
        }
        message = nil
        do {
            let asset: MediaImageAsset
            switch request.source {
            case .camera(let image, let orientation):
                asset = try await processor.prepare(image, orientation: orientation)
            case .library(let item):
                guard let file = try await item.loadTransferable(type: ImportedPhoto.self) else {
                    throw MediaImageError.invalidImage
                }
                defer { try? FileManager.default.removeItem(at: file.url) }
                asset = try await processor.prepare(file.url)
            }
            try Task.checkCancellation()
            guard request.id == photoRequest?.id else { return }
            photo = asset
            await record(action, .success, began)
        } catch is CancellationError {
            await record(action, .cancelled, began)
        } catch {
            guard !Task.isCancelled, request.id == photoRequest?.id else { return }
            message = (error as? MediaImageError)?.localizedDescription ?? "写真を読み込めませんでした。別の写真を選んでください。"
            await record(action, .failure, began)
        }
    }

    private func cancelPhoto() {
        photoRequest = nil
        selection = nil
        cameraRequest = nil
    }

    private func startRecording(_ request: UUID?) async {
        guard let request else { return }
        defer { if request == micRequest { micRequest = nil } }
        showSettings = false
        message = nil
        let authorized = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled, request == micRequest, scenePhase != .background else { return }
        guard authorized else {
            message = "マイクへのアクセスを許可すると録音できます。文章と写真はそのまま保存できます。"
            showSettings = true
            await diagnostics?.record(sample: .journal, action: .capture, outcome: .limited)
            return
        }
        do {
            try audio.startRecording()
            await diagnostics?.record(sample: .journal, action: .capture, outcome: .success)
        } catch {
            message = DiaryAudioError.cannotRecord.localizedDescription
            await diagnostics?.record(sample: .journal, action: .capture, outcome: .failure)
        }
    }

    private func reload() async {
        loading = true
        savedEntriesError = nil
        defer { loading = false }
        let began = ContinuousClock.now
        do {
            entries = try await store.entries()
            await record(.load, .success, began)
        } catch {
            savedEntriesError = "日記を読み込めませんでした。"
            await record(.load, .failure, began)
        }
    }

    private func save(_ request: UUID?) async {
        guard let request else { return }
        defer { if request == saveRequest { saveRequest = nil } }
        let began = ContinuousClock.now
        message = nil
        showSettings = false
        do {
            let saved = try await store.save(note: note, place: place, photo: photo, audio: audio.recording)
            // A successful manifest write is committed even if the screen was closed while saving.
            entries = saved
            note = ""
            place = ""
            photo = nil
            audio.removeRecording()
            savedEntriesError = nil
            message = "日記を端末に保存しました。"
            await record(.save, .success, began)
        } catch is CancellationError {
            await record(.save, .cancelled, began)
        } catch {
            if !Task.isCancelled {
                message = (error as? DiaryStoreError)?.localizedDescription ?? "保存できませんでした。空き容量を確認して、もう一度お試しください。"
            }
            await record(.save, .failure, began)
        }
    }

    private func suspend() {
        cancelPhoto()
        micRequest = nil
        saveRequest = nil
        audio.suspend()
        cameraSheet = false
    }

    private func record(_ action: DiagnosticAction, _ outcome: DiagnosticOutcome, _ began: ContinuousClock.Instant) async {
        await diagnostics?.record(sample: .journal, action: action, outcome: outcome,
                                  milliseconds: began.duration(to: .now).mediaMilliseconds)
    }
}

private struct DiaryDetailView: View {
    let entry: DiaryEntry
    let store: DiaryStore
    var updateEntries: ([DiaryEntry]) -> Void

    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var audio = DiaryAudio()
    @State private var preview: UIImage?
    @State private var audioURL: URL?
    @State private var message: String?
    @State private var loading = true
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var showingPhoto = false

    var body: some View {
        Form {
            Section {
                Text(entry.note)
                LabeledContent("記録日時", value: entry.date.formatted(date: .abbreviated, time: .shortened))
                if !entry.place.isEmpty { LabeledContent("場所", value: entry.place) }
            }
            if entry.hasPhoto || entry.hasAudio {
                Section("添付") {
                    if loading { ProgressView("添付を読み込み中") }
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().accessibilityLabel("日記の写真")
                        Button("写真を拡大する") { showingPhoto = true }
                    }
                    if let audioURL {
                        Button(audio.isPlaying ? "再生を止める" : "録音を聴く") {
                            if audio.isPlaying {
                                audio.stopPlayback()
                            } else {
                                do { try audio.play(audioURL) } catch { message = DiaryAudioError.cannotPlay.localizedDescription }
                            }
                        }
                    }
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            Section {
                Button("日記を削除", role: .destructive) { confirmDelete = true }
                    .disabled(deleting)
            }
        }
        .navigationTitle("保存した日記")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPhoto) {
            DiaryPhotoView(entry: entry, store: store)
        }
        .confirmationDialog("この日記を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("日記を削除", role: .destructive) { Task { await deleteEntry() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("本文、写真、録音を端末から削除します。")
        }
        .task {
            defer { loading = false }
            do {
                let attachment = try await store.detail(for: entry)
                try Task.checkCancellation()
                preview = attachment.photo.flatMap { UIImage(data: $0) }
                audioURL = attachment.audio
            } catch is CancellationError {} catch { message = "添付を読み込めませんでした。" }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { audio.stopPlayback() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            audio.stopPlayback()
        }
        .onDisappear(perform: audio.stopPlayback)
    }

    private func deleteEntry() async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        audio.stopPlayback()
        do {
            updateEntries(try await store.delete(entry))
            await diagnostics?.record(sample: .journal, action: .save, outcome: .success)
            dismiss()
        } catch {
            message = "削除できませんでした。もう一度お試しください。"
            await diagnostics?.record(sample: .journal, action: .save, outcome: .failure)
        }
    }
}

private struct DiaryPhotoView: View {
    let entry: DiaryEntry
    let store: DiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit().accessibilityLabel("日記の写真")
                } else if failed {
                    ContentUnavailableView("写真を読み込めませんでした", systemImage: "photo")
                } else {
                    ProgressView("写真を読み込み中")
                }
            }
            .navigationTitle("日記の写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { dismiss() } }
            .task {
                do {
                    let data = try await store.photo(for: entry)
                    try Task.checkCancellation()
                    photo = UIImage(data: data)
                    failed = photo == nil
                } catch is CancellationError {} catch { failed = true }
            }
        }
    }
}

#Preview {
    NavigationStack { DiarySampleView() }
}
