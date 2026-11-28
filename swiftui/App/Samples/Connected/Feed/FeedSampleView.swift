import CatalogCore
import SwiftUI

enum FeedSource: String, CaseIterable, Identifiable, Sendable {
    case fixture = "再現用データ"
    case live = "Hacker News API"

    var id: Self { self }
}

struct FeedArticle: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let url: URL?
}

struct FeedPage: Sendable {
    let articles: [FeedArticle]
    let hasMore: Bool
}

actor ArticleFeed {
    static let pageSize = 12
    static let pageLimit = 5

    enum FeedError: Error {
        case invalidResponse
        case responseTooLarge
        case noPublicStories
    }

    private struct Story: Decodable {
        let title: String?
        let url: URL?
        let by: String?
        let descendants: Int?
        let deleted: Bool?
        let dead: Bool?
    }

    private let session: URLSession
    private var cachedPages: [Int: FeedPage] = [:]
    private var snapshot: [Int] = []
    private var generation: UUID?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func page(_ index: Int, source: FeedSource, generation requestedGeneration: UUID) async throws -> FeedPage {
        guard (0..<Self.pageLimit).contains(index) else { return FeedPage(articles: [], hasMore: false) }
        if source == .fixture { return Self.fixturePage(index) }
        if generation != requestedGeneration {
            cachedPages.removeAll()
            snapshot.removeAll()
            generation = requestedGeneration
        }
        if let cached = cachedPages[index] { return cached }
        if snapshot.isEmpty {
            let ids: [Int] = try await fetch("topstories.json")
            try verify(requestedGeneration)
            snapshot = Array(ids.prefix(Self.pageSize * Self.pageLimit))
        }
        let start = index * Self.pageSize
        let end = min(start + Self.pageSize, snapshot.count)
        guard start < end else { return FeedPage(articles: [], hasMore: false) }
        let ids = Array(snapshot[start..<end])
        var indexed: [Int: FeedArticle] = [:]
        try await withThrowingTaskGroup(of: (Int, FeedArticle?).self) { group in
            for (position, id) in ids.enumerated() {
                group.addTask { try await (position, self.article(id)) }
            }
            for try await (position, article) in group {
                indexed[position] = article
            }
        }
        try verify(requestedGeneration)
        let articles = ids.indices.compactMap { indexed[$0] }
        guard !articles.isEmpty else { throw FeedError.noPublicStories }
        let page = FeedPage(articles: articles, hasMore: end < snapshot.count)
        cachedPages[index] = page
        return page
    }

    private func verify(_ requestedGeneration: UUID) throws {
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CancellationError() }
    }

    private func article(_ id: Int) async throws -> FeedArticle? {
        let story: Story? = try await fetch("item/\(id).json")
        guard let story, let title = story.title, story.deleted != true, story.dead != true else { return nil }
        let url = story.url.flatMap { url -> URL? in
            guard url.scheme == "https" || url.scheme == "http", url.host != nil,
                  url.absoluteString.utf8.count <= 1_024 else { return nil }
            return url
        }
        let author = String((story.by ?? "不明").prefix(50))
        let summary = "投稿者 \(author) · コメント \(story.descendants ?? 0) 件"
        return FeedArticle(id: "hn-\(id)", title: String(title.prefix(240)), summary: summary, url: url)
    }

    private func fetch<Item: Decodable>(_ path: String) async throws -> Item {
        let root = URL(string: "https://hacker-news.firebaseio.com/v0/")!
        guard let endpoint = URL(string: path, relativeTo: root)?.absoluteURL else { throw FeedError.invalidResponse }
        let (bytes, response) = try await session.bytes(from: endpoint)
        defer { bytes.task.cancel() }
        let byteLimit = 96 * 1024
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FeedError.invalidResponse
        }
        guard response.expectedContentLength <= byteLimit else { throw FeedError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            guard body.count < byteLimit else { throw FeedError.responseTooLarge }
            body.append(byte)
        }
        return try JSONDecoder().decode(Item.self, from: body)
    }

    private static func fixturePage(_ index: Int) -> FeedPage {
        let topics = ["地域の本を探す", "海岸を観察する", "街路樹を知る", "写真を整理する",
                      "道具を修理する", "夕方の散歩を計画する", "天気図を読む", "朝市を見に行く",
                      "録音を聞き返す", "展示を振り返る", "川沿いの地図を読む", "季節の記録をつける"]
        let perspectives = ["入門", "実践", "調べ方", "記録例", "まとめ"]
        let articles = topics.enumerated().map { position, topic in
            FeedArticle(
                id: "fixture-\(index)-\(position)",
                title: "\(topic)・\(perspectives[index])",
                summary: "「\(topic)」を試すための架空の記事です。最初に気づいたことを1つ書き留め、次に同じことを試したときに見比べてみましょう。",
                url: nil
            )
        }
        return FeedPage(articles: articles, hasMore: index + 1 < pageLimit)
    }
}

struct FeedSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("feed.bookmarks.v1") private var bookmarkData = Data()
    @AppStorage("feed.last-response.v1") private var cacheData = Data()
    @State private var service = ArticleFeed()
    @State private var source = FeedSource.fixture
    @State private var articles: [FeedArticle] = []
    @State private var generation = UUID()
    @State private var attempt = UUID()
    @State private var nextPage = 0
    @State private var hasMore = true
    @State private var showsCached = false
    @State private var showBookmarks = false
    @State private var phase = Phase.idle
    @State private var loadTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle, loading, failed, cancelled
    }

    private var bookmarks: [FeedArticle] {
        (try? JSONDecoder().decode([FeedArticle].self, from: bookmarkData)) ?? []
    }

    var body: some View {
        List {
            Section("表示する記事") {
                Picker("取得元", selection: $source) {
                    ForEach(FeedSource.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("ブックマークだけ表示", isOn: $showBookmarks)
                if source == .live {
                    Text("通信が必要です。記事リンクは外部サイトで開きます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section(showBookmarks ? "ブックマーク" : "記事") {
                let visible = showBookmarks ? bookmarks : articles
                if !showBookmarks && showsCached {
                    Label("前回取得した記事を表示しています", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { article in
                    NavigationLink {
                        FeedArticleDetail(article: article, bookmarkData: $bookmarkData)
                    } label: {
                        Text(article.title)
                    }
                }
                if showBookmarks && visible.isEmpty {
                    ContentUnavailableView("ブックマークがありません", systemImage: "bookmark",
                                           description: Text("記事の詳細で追加できます。"))
                }
                if !showBookmarks {
                    pageControl
                }
            }
        }
        .navigationTitle("記事を読む")
        .toolbar {
            Button("更新", systemImage: "arrow.clockwise") { reload(keepingCurrent: true) }
                .disabled(showBookmarks || phase == .loading)
        }
        .onChange(of: source) { _, _ in reload(keepingCurrent: false) }
        .onChange(of: showBookmarks) { _, onlyBookmarks in
            if onlyBookmarks { cancelLoad() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelLoad() }
        }
        .onAppear {
            if articles.isEmpty && phase == .idle { loadNext() }
        }
        .onDisappear { cancelLoad() }
    }

    @ViewBuilder private var pageControl: some View {
        switch phase {
        case .loading:
            ProgressView("記事を読み込んでいます")
            Button("読み込みを中止", action: cancelLoad)
        case .failed:
            Text("記事を取得できませんでした。通信状態を確認してください。")
            Button("再試行", action: loadNext)
        case .cancelled:
            Button("読み込みを再開", action: loadNext)
        case .idle:
            if hasMore {
                Button(articles.isEmpty ? "記事を読み込む" : "次の12件を読み込む", action: loadNext)
            } else {
                Text(articles.isEmpty ? "表示できる記事がありません。" : "最後の記事まで表示しています。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload(keepingCurrent: Bool) {
        cancelLoad()
        generation = UUID()
        nextPage = 0
        hasMore = true
        if !keepingCurrent {
            articles = source == .live ? ((try? JSONDecoder().decode([FeedArticle].self, from: cacheData)) ?? []) : []
        }
        showsCached = !articles.isEmpty && source == .live
        if !showBookmarks { loadNext() }
    }

    private func cancelLoad() {
        guard phase == .loading else { return }
        attempt = UUID()
        loadTask?.cancel()
        loadTask = nil
        phase = .cancelled
        Task { await diagnostics?.record(sample: .feed, action: .load, outcome: .cancelled) }
    }

    private func loadNext() {
        guard phase != .loading, hasMore else { return }
        phase = .loading
        let id = UUID()
        attempt = id
        let pageIndex = nextPage
        let requestedSource = source
        let requestedGeneration = generation
        let started = ContinuousClock.now
        loadTask = Task {
            do {
                let page = try await service.page(pageIndex, source: requestedSource, generation: requestedGeneration)
                try Task.checkCancellation()
                guard attempt == id else { return }
                if pageIndex == 0 {
                    articles = page.articles
                    showsCached = false
                } else {
                    articles.append(contentsOf: page.articles)
                }
                if source == .live, let data = try? JSONEncoder().encode(articles), data.count <= 120 * 1_024 {
                    cacheData = data
                }
                nextPage += 1
                hasMore = page.hasMore
                phase = .idle
                loadTask = nil
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                await diagnostics?.record(sample: .feed, action: .load, outcome: .success, milliseconds: milliseconds)
            } catch {
                guard attempt == id else { return }
                phase = Task.isCancelled ? .cancelled : .failed
                loadTask = nil
                await diagnostics?.record(sample: .feed, action: .load,
                                          outcome: Task.isCancelled ? .cancelled : .failure)
            }
        }
    }
}

private struct FeedArticleDetail: View {
    @Environment(\.diagnostics) private var diagnostics
    let article: FeedArticle
    @Binding var bookmarkData: Data

    private var bookmarks: [FeedArticle] {
        (try? JSONDecoder().decode([FeedArticle].self, from: bookmarkData)) ?? []
    }

    var body: some View {
        List {
            Section {
                Text(article.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(article.summary)
                if let url = article.url { Link("掲載サイトを開く", destination: url) }
            }
            Section {
                let saved = bookmarks.contains(where: { $0.id == article.id })
                Button(saved ? "ブックマークを外す" : "ブックマークに追加", systemImage: saved ? "bookmark.slash" : "bookmark") {
                    updateBookmark()
                }
                .disabled(!saved && bookmarks.count >= 100)
                if !saved && bookmarks.count >= 100 { Text("保存上限の100件に達しています。") }
            }
        }
        .navigationTitle("記事の詳細")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func updateBookmark() {
        var updated = bookmarks
        if let index = updated.firstIndex(where: { $0.id == article.id }) {
            updated.remove(at: index)
        } else if updated.count < 100 {
            updated.append(article)
        }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        bookmarkData = data
        Task { await diagnostics?.record(sample: .feed, action: .save, outcome: .success) }
    }
}

#Preview {
    NavigationStack { FeedSampleView() }
}
