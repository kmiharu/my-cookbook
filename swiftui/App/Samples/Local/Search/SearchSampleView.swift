import CatalogCore
import SwiftUI

private struct SearchProduct: Identifiable, Sendable {
    let id: Int
    let title: String
    let category: SearchCategory
    let price: Int
}

private enum SearchCategory: String, CaseIterable, Codable, Sendable {
    case books = "本"
    case stationery = "文具"
    case tools = "道具"
}

private enum SearchSort: String, CaseIterable, Codable, Sendable {
    case number = "登録順"
    case price = "価格が低い順"
    case highPrice = "価格が高い順"
}

private struct SearchCondition: Codable, Equatable, Sendable {
    var text = ""
    var category: SearchCategory?
    var sort = SearchSort.number
}

private actor ProductIndex {
    private var products: [SearchProduct]?

    func search(_ condition: SearchCondition) throws -> [SearchProduct] {
        if products == nil {
            let categories = SearchCategory.allCases
            var seeded: [SearchProduct] = []
            seeded.reserveCapacity(10_000)
            for number in 1...10_000 {
                if number.isMultiple(of: 128) { try Task.checkCancellation() }
                let category = categories[number % categories.count]
                seeded.append(SearchProduct(id: number, title: "\(category.rawValue) \(number)", category: category,
                                            price: 100 + (number * 997) % 49_900))
            }
            products = seeded
        }

        let query = condition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [SearchProduct] = []
        for (index, product) in (products ?? []).enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if let category = condition.category, product.category != category { continue }
            if query.isEmpty || product.title.localizedStandardContains(query) { results.append(product) }
        }
        switch condition.sort {
        case .number: break
        case .price: results.sort { ($0.price, $0.id) < ($1.price, $1.id) }
        case .highPrice:
            results.sort { first, second in
                first.price == second.price ? first.id < second.id : first.price > second.price
            }
        }
        try Task.checkCancellation()
        return results
    }
}

struct SearchSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @State private var index = ProductIndex()
    @State private var saved: LocalRecords<SearchCondition?>
    @State private var text = ""
    @State private var category: SearchCategory?
    @State private var sort = SearchSort.number
    @State private var results: [SearchProduct] = []
    @State private var comparison: [SearchProduct] = []
    @State private var page = 0
    @State private var loading = true
    @State private var showComparison = false

    private let pageSize = 50

    init(preview: Bool = false) {
        _saved = State(initialValue: LocalRecords(initial: nil, fileName: preview ? nil : "search-v1.json"))
    }

    private var condition: SearchCondition { SearchCondition(text: text, category: category, sort: sort) }
    private var visibleProducts: ArraySlice<SearchProduct> {
        let start = min(page * pageSize, results.count)
        return results[start..<min(start + pageSize, results.count)]
    }

    var body: some View {
        List {
            Section("検索条件") {
                Picker("分類", selection: $category) {
                    Text("すべて").tag(nil as SearchCategory?)
                    ForEach(SearchCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Picker("並べ替え", selection: $sort) {
                    ForEach(SearchSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("この検索条件を保存") {
                    let snapshot = condition
                    Task {
                        let success = await saved.save(snapshot)
                        await diagnostics?.record(sample: .search, action: .save, outcome: success ? .success : .failure)
                    }
                }
                .disabled(!saved.canSave)
                if let entry = saved.value {
                    Button("保存した検索条件を使う") {
                        text = entry.text
                        category = entry.category
                        sort = entry.sort
                    }
                }
                LocalRecordStatus(store: saved)
            }
            Section {
                if loading {
                    ProgressView("検索中")
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "該当する商品がありません", systemImage: "magnifyingglass",
                        description: Text("検索語を短くするか、分類を変えてください。")
                    )
                } else {
                    ForEach(visibleProducts) { product in
                        let selected = comparison.contains { $0.id == product.id }
                        Button {
                            if selected { comparison.removeAll { $0.id == product.id } }
                            else if comparison.count < 3 { comparison.append(product) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(product.title).foregroundStyle(.primary)
                                    Text(priceLabel(product.price)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityHint(selected ? "比較から外す" : "比較に追加")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(!selected && comparison.count == 3)
                    }
                    HStack {
                        Button("前の50件") { page -= 1 }.disabled(page == 0)
                        Spacer()
                        Button("次の50件") { page += 1 }.disabled((page + 1) * pageSize >= results.count)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text(loading ? "結果" : "\(results.count.formatted()) 件")
            }
        }
        .navigationTitle("商品を調べて比較")
        .searchable(text: $text, prompt: "商品名で検索（例：本）")
        .toolbar {
            Button("比較 \(comparison.count)/3") { showComparison = true }
                .disabled(comparison.isEmpty)
        }
        .sheet(isPresented: $showComparison) {
            NavigationStack {
                List {
                    if comparison.isEmpty {
                        Text("一覧から比較したい商品を選んでください。")
                    }
                    ForEach(comparison) { product in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(product.title, value: priceLabel(product.price))
                            Button("比較から外す") { comparison.removeAll { $0.id == product.id } }
                                .accessibilityLabel("\(product.title)を比較から外す")
                        }
                    }
                }
                .navigationTitle("商品を比較")
                .toolbar { Button("閉じる") { showComparison = false } }
            }
        }
        .task { await saved.load() }
        .task(id: condition) { [condition] in await refresh(condition) }
    }

    private func refresh(_ condition: SearchCondition) async {
        guard !Task.isCancelled else { return }
        loading = true
        let start = ContinuousClock.now
        do {
            if !condition.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let searchStart = ContinuousClock.now
            let matches = try await index.search(condition)
            try Task.checkCancellation()
            results = matches
            page = 0
            loading = false
            await diagnostics?.record(sample: .search, action: .process, outcome: .success,
                                      milliseconds: searchStart.duration(to: .now).localMilliseconds)
        } catch {
            await diagnostics?.record(sample: .search, action: .process, outcome: .cancelled,
                                      milliseconds: start.duration(to: .now).localMilliseconds)
        }
    }

    private func priceLabel(_ amount: Int) -> String {
        amount.formatted(.currency(code: "JPY").locale(Locale(identifier: "ja_JP")))
    }
}

#Preview {
    NavigationStack { SearchSampleView(preview: true) }
}
