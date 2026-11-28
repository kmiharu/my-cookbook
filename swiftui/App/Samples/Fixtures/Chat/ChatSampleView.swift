import CatalogCore
import Foundation
import PhotosUI
import SwiftUI

private struct ChatMessage: Codable, Identifiable, Sendable {
    enum Delivery: String, Codable, Sendable {
        case incoming, queued, failed, simulated

        var title: String {
            switch self {
            case .incoming: "受信済みの例"
            case .queued: "送信処理中"
            case .failed: "送信できませんでした"
            case .simulated: "送信の再現完了"
            }
        }
    }

    let id: UUID
    let sentAt: Date
    let text: String
    let attachment: FixtureAttachment?
    var delivery: Delivery

    init(id: UUID = UUID(), sentAt: Date = .now, text: String, attachment: FixtureAttachment? = nil, delivery: Delivery) {
        self.id = id
        self.sentAt = sentAt
        self.text = text
        self.attachment = attachment
        self.delivery = delivery
    }
}

struct ChatSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachment: FixtureAttachment?
    @State private var imageLoading = false
    @State private var simulateFailure = false
    @State private var loaded = false
    @State private var alertText: String?
    @State private var work: Task<Void, Never>?

    private static let disk = FixtureDisk("chat.json", initial: [
        ChatMessage(text: "明日の打ち合わせは午後2時からです。", delivery: .incoming)
    ])

    var body: some View {
        List {
            Section {
                FixtureModeNote(detail: "再現用の会話です。送信先への接続はありません。")
                Toggle("送信エラーを再現", isOn: $simulateFailure)
                    .disabled(work != nil)
            }
            Section("会話") {
                if !loaded {
                    if alertText == nil { ProgressView("会話を読み込み中") }
                    else { Button("読み込みを再試行") { beginLoad() } }
                } else if messages.isEmpty {
                    ContentUnavailableView("メッセージがありません", systemImage: "bubble.left.and.bubble.right")
                } else {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.delivery == .incoming ? "サンプル相手" : "あなた").font(.headline)
                            if !message.text.isEmpty { Text(message.text) }
                            if let attachment = message.attachment { FixtureAttachmentPreview(attachment: attachment) }
                            Text(message.sentAt, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(message.delivery.title).font(.caption).foregroundStyle(.secondary)
                            if message.delivery == .failed {
                                Button("再送する") { send(message) }
                                    .buttonStyle(.borderless)
                                    .disabled(work != nil)
                            }
                        }
                        .id(message.id)
                    }
                }
            }
            Section("メッセージを書く") {
                TextField("本文（500文字まで）", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(work != nil)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("写真を添付", systemImage: "photo")
                }
                .disabled(imageLoading || work != nil)
                if imageLoading { ProgressView("添付画像を準備中") }
                if let attachment {
                    FixtureAttachmentPreview(attachment: attachment)
                    Button("添付を外す") { self.attachment = nil; selectedPhoto = nil }
                        .disabled(work != nil)
                }
                Button("送信する") { submitDraft() }
                    .disabled(!loaded || work != nil || imageLoading || (draft.trimmedForFixture.isEmpty && attachment == nil))
                if work != nil && loaded { Button("中断する") { work?.cancel() } }
                if let alertText {
                    Label(alertText, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("メッセージ")
        .task { beginLoad() }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await prepareAttachment(selectedPhoto)
        }
        .onDisappear { work?.cancel(); selectedPhoto = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { work?.cancel(); selectedPhoto = nil }
        }
    }

    private func beginLoad() {
        guard !loaded, work == nil else { return }
        alertText = nil
        work = Task {
            defer { work = nil }
            do {
                let saved = try await Self.disk.read()
                messages = saved.map { message in
                    var item = message
                    if item.delivery == .queued { item.delivery = .failed }
                    return item
                }
                loaded = true
            } catch {
                alertText = "会話を読み込めませんでした。端末の空き容量を確認してください。"
            }
        }
    }

    private func prepareAttachment(_ item: PhotosPickerItem) async {
        imageLoading = true
        defer { imageLoading = false }
        do {
            guard let result = try await item.loadTransferable(type: FixtureAttachment.self) else {
                alertText = "画像を準備できませんでした。32 MB・1億画素以下の別の写真を選んでください。"
                return
            }
            try Task.checkCancellation()
            attachment = result
            alertText = nil
        } catch is CancellationError {
            return
        } catch {
            alertText = "画像を準備できませんでした。32 MB・1億画素以下の別の写真を選んでください。"
        }
    }

    private func submitDraft() {
        let text = draft.trimmedForFixture
        guard text.fitsFixtureLimit(500) else {
            alertText = "本文を500文字以内にしてください。"
            return
        }
        send(ChatMessage(text: text, attachment: attachment, delivery: .queued), clearDraft: true)
    }

    private func send(_ message: ChatMessage, clearDraft: Bool = false) {
        guard loaded, work == nil else { return }
        let fail = simulateFailure
        alertText = nil
        work = Task {
            let start = ContinuousClock.now
            defer { work = nil }
            do {
                try Task.checkCancellation()
                messages = try await save(message, delivery: .queued)
                if clearDraft {
                    draft = ""
                    attachment = nil
                    selectedPhoto = nil
                }
                do {
                    try await Task.sleep(for: .milliseconds(650))
                    messages = try await save(message, delivery: fail ? .failed : .simulated)
                    await diagnostics?.record(sample: .chat, action: .process, outcome: fail ? .failure : .success, milliseconds: fixtureElapsedMilliseconds(since: start))
                } catch is CancellationError {
                    messages = try await save(message, delivery: .failed)
                    await diagnostics?.record(sample: .chat, action: .process, outcome: .cancelled)
                }
            } catch is CancellationError {
                await diagnostics?.record(sample: .chat, action: .process, outcome: .cancelled)
            } catch {
                if let index = messages.firstIndex(where: { $0.id == message.id && $0.delivery == .queued }) {
                    messages[index].delivery = .failed
                }
                alertText = "会話を保存できませんでした。空き容量を確認して再試行してください。"
                await diagnostics?.record(sample: .chat, action: .save, outcome: .failure)
            }
        }
    }

    private func save(_ message: ChatMessage, delivery: ChatMessage.Delivery) async throws -> [ChatMessage] {
        var updated = message
        updated.delivery = delivery
        let item = updated
        return try await Self.disk.update { messages in
            if let index = messages.firstIndex(where: { $0.id == item.id }) { messages[index] = item }
            else { messages.append(item) }
            messages = Array(messages.suffix(20))
        }
    }
}

#Preview { NavigationStack { ChatSampleView() } }
