import CatalogCore
import Foundation
import PhotosUI
import SwiftUI

private struct SocialDraft: Codable, Equatable, Sendable {
    var text = ""
    var attachment: FixtureAttachment?

    var hasContent: Bool { !text.trimmedForFixture.isEmpty || attachment != nil }
}

private struct SocialPost: Codable, Identifiable, Sendable {
    let id: String
    let author: String
    let text: String
    let attachment: FixtureAttachment?
}

private struct SocialState: Codable, Sendable {
    var draft = SocialDraft()
    var posts: [SocialPost] = []
    var liked: Set<String> = []
}

private enum SocialSeedFeed {
    static let total = 36
    static let pageSize = 8

    static func page(offset: Int) async throws -> [SocialPost] {
        try await Task.sleep(for: .milliseconds(250))
        let topics = ["今朝は公園を散歩しました。", "読んだ本の感想をノートにまとめました。", "季節の写真を整理しています。"]
        return (offset..<min(offset + pageSize, total)).map { index in
            SocialPost(id: "seed-\(index)", author: "再現用アカウント \(index + 1)", text: topics[index % topics.count], attachment: nil)
        }
    }
}

struct SocialSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = SocialState()
    @State private var draft = SocialDraft()
    @State private var seedPosts: [SocialPost] = []
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageLoading = false
    @State private var simulateFailure = false
    @State private var loaded = false
    @State private var status: String?
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var paging: Task<Void, Never>?

    private static let disk = FixtureDisk("social.json", initial: SocialState())

    var body: some View {
        List {
            Section {
                FixtureModeNote(detail: "端末に保存する投稿の再現です。他の利用者には公開されません。")
                Toggle("投稿エラーを再現", isOn: $simulateFailure).disabled(work != nil)
            }
            Section("投稿を書く") {
                TextField("本文（500文字まで）", text: $draft.text, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(!loaded || work != nil)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("写真を添付", systemImage: "photo")
                }
                .disabled(!loaded || imageLoading || work != nil)
                if imageLoading { ProgressView("添付画像を準備中") }
                if let attachment = draft.attachment {
                    FixtureAttachmentPreview(attachment: attachment)
                    Button("添付を外す") { draft.attachment = nil; selectedPhoto = nil }
                        .disabled(work != nil)
                }
                Button("下書きを保存") { saveDraft() }
                    .disabled(!loaded || work != nil || imageLoading || draft == state.draft)
                Button("投稿する") { publish() }
                    .disabled(!loaded || work != nil || imageLoading || !draft.hasContent)
                if draft != state.draft {
                    Text("別の画面に移動する前に、編集中の内容を下書きに保存できます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if work != nil && loaded {
                    ProgressView("処理中")
                    Button("中断する") { work?.cancel() }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
                if !loaded && work == nil { Button("読み込みを再試行") { load() } }
            }
            Section("フィード") {
                ForEach(state.posts + seedPosts) { post in postRow(post) }
                if paging != nil {
                    ProgressView("投稿を読み込み中")
                } else if loaded && seedPosts.count < SocialSeedFeed.total {
                    Button(seedPosts.isEmpty ? "投稿を読み込む" : "さらに読み込む") { loadPage() }
                }
            }
        }
        .navigationTitle("投稿と交流")
        .task { load() }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await prepareAttachment(selectedPhoto)
        }
        .onDisappear { work?.cancel(); paging?.cancel(); selectedPhoto = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { work?.cancel(); paging?.cancel(); selectedPhoto = nil }
        }
    }

    private func postRow(_ post: SocialPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.author).font(.headline)
            if !post.text.isEmpty { Text(post.text) }
            if let attachment = post.attachment { FixtureAttachmentPreview(attachment: attachment) }
            let liked = state.liked.contains(post.id)
            Button { react(to: post.id) } label: {
                Label(liked ? "いいねを取り消す" : "いいねする", systemImage: liked ? "heart.fill" : "heart")
            }
            .buttonStyle(.borderless)
            .disabled(work != nil)
        }
    }

    private func load() {
        guard !loaded, work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                state = try await Self.disk.read()
                try Task.checkCancellation()
                draft = state.draft
                loaded = true
                loadPage()
            } catch is CancellationError {
                return
            } catch {
                error = "下書きと投稿を読み込めませんでした。端末の空き容量を確認してください。"
            }
        }
    }

    private func loadPage() {
        guard paging == nil, seedPosts.count < SocialSeedFeed.total else { return }
        let start = ContinuousClock.now
        paging = Task {
            defer { paging = nil }
            do {
                seedPosts += try await SocialSeedFeed.page(offset: seedPosts.count)
                await diagnostics?.record(sample: .social, action: .load, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                await diagnostics?.record(sample: .social, action: .load, outcome: .cancelled)
            } catch {
                error = "投稿を読み込めませんでした。読み込みを再試行してください。"
                await diagnostics?.record(sample: .social, action: .load, outcome: .failure)
            }
        }
    }

    private func prepareAttachment(_ item: PhotosPickerItem) async {
        imageLoading = true
        defer { imageLoading = false }
        do {
            guard let result = try await item.loadTransferable(type: FixtureAttachment.self) else {
                error = "画像を準備できませんでした。32 MB・1億画素以下の別の写真を選んでください。"
                return
            }
            try Task.checkCancellation()
            draft.attachment = result
            error = nil
        } catch is CancellationError {
            return
        } catch {
            error = "画像を準備できませんでした。32 MB・1億画素以下の別の写真を選んでください。"
        }
    }

    private func saveDraft() {
        guard draft.text.fitsFixtureLimit(500) else { error = "本文を500文字以内にしてください。"; return }
        let snapshot = draft
        change(message: "下書きを保存しました") { $0.draft = snapshot }
    }

    private func publish() {
        let text = draft.text.trimmedForFixture
        guard text.fitsFixtureLimit(500) else { error = "本文を500文字以内にしてください。"; return }
        let post = SocialPost(id: UUID().uuidString, author: "あなた（端末内）", text: text, attachment: draft.attachment)
        change(message: "投稿の再現が完了しました", publishing: true) { value in
            value.posts.insert(post, at: 0)
            let trimmed = value.posts.dropFirst(12)
            value.liked.subtract(trimmed.map(\.id))
            value.posts = Array(value.posts.prefix(12))
            value.draft = SocialDraft()
        }
    }

    private func react(to id: String) {
        change { value in
            if value.liked.remove(id) == nil { value.liked.insert(id) }
        }
    }

    private func change(message: String? = nil, publishing: Bool = false, edit: @escaping @Sendable (inout SocialState) -> Void) {
        guard loaded, work == nil else { return }
        error = nil
        status = nil
        let fail = simulateFailure
        work = Task {
            let start = ContinuousClock.now
            defer { work = nil }
            do {
                if publishing { try await Task.sleep(for: .milliseconds(550)) }
                try Task.checkCancellation()
                if publishing && fail {
                    error = "投稿できませんでした。投稿エラーの設定を確認してから再試行してください。"
                    await diagnostics?.record(sample: .social, action: .process, outcome: .failure)
                    return
                }
                state = try await Self.disk.update(edit)
                status = message
                if publishing { draft = state.draft; selectedPhoto = nil }
                await diagnostics?.record(sample: .social, action: .save, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                await diagnostics?.record(sample: .social, action: .save, outcome: .cancelled)
            } catch {
                error = "変更を保存できませんでした。空き容量を確認して再試行してください。"
                await diagnostics?.record(sample: .social, action: .save, outcome: .failure)
            }
        }
    }
}

#Preview { NavigationStack { SocialSampleView() } }
