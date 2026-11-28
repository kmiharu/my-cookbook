import CatalogCore
import Foundation
import SwiftUI

private struct FixtureProduct: Identifiable {
    let id: String
    let name: String
    let description: String
    let symbol: String
    let yen: Int
    let available: Int

    static let catalog = [
        Self(id: "notebook", name: "方眼ノート", description: "A5、80ページ。表紙は再生紙。", symbol: "book.closed", yen: 480, available: 5),
        Self(id: "bottle", name: "ステンレスボトル", description: "350 mL。ふたを外して洗えます。", symbol: "waterbottle", yen: 2_800, available: 4),
        Self(id: "bag", name: "折りたたみバッグ", description: "耐荷重5 kg。内ポケットに収納できます。", symbol: "bag", yen: 1_250, available: 8),
        Self(id: "mug", name: "セラミックマグ", description: "250 mL。黒釉のサンプルです。", symbol: "cup.and.saucer", yen: 1_900, available: 0)
    ]
}

private struct FixtureOrder: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let units: Int
    let totalYen: Int
}

private struct ShoppingState: Codable, Sendable {
    var favorites: Set<String> = []
    var quantities: [String: Int] = [:]
    var orders: [FixtureOrder] = []
}

struct ShoppingSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = ShoppingState()
    @State private var selected: FixtureProduct?
    @State private var showFavorites = false
    @State private var simulateDecline = false
    @State private var confirming = false
    @State private var checkingOut = false
    @State private var loaded = false
    @State private var status: String?
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    private static let disk = FixtureDisk("shopping.json", initial: ShoppingState(), byteLimit: 32_000)
    private let products = FixtureProduct.catalog

    private var cart: [FixtureProduct] { products.filter { state.quantities[$0.id, default: 0] > 0 } }
    private var total: Int { cart.reduce(0) { $0 + $1.yen * state.quantities[$1.id, default: 0] } }

    var body: some View {
        List {
            Section {
                FixtureModeNote(detail: "買い物の再現です。注文、決済、請求は発生しません。")
                Toggle("決済エラーを再現", isOn: $simulateDecline).disabled(checkingOut)
            }
            Section("商品") {
                Toggle("お気に入りだけ表示", isOn: $showFavorites)
                let visible = showFavorites ? products.filter { state.favorites.contains($0.id) } : products
                if visible.isEmpty {
                    ContentUnavailableView("お気に入りの商品がありません", systemImage: "heart")
                }
                ForEach(visible) { product in
                    Button { selected = product } label: {
                        HStack {
                            Label(product.name, systemImage: product.symbol)
                            Spacer()
                            Text(product.yen, format: .currency(code: "JPY")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("カート") {
                if !loaded {
                    if work != nil { ProgressView("カートを読み込み中") }
                    else { Button("読み込みを再試行") { load() } }
                } else if cart.isEmpty {
                    Text("商品がありません。商品詳細から追加できます。").foregroundStyle(.secondary)
                }
                ForEach(cart) { product in
                    let quantity = state.quantities[product.id, default: 0]
                    Stepper {
                        Text("\(product.name)　\(quantity)点")
                    } onIncrement: {
                        updateQuantity(quantity + 1, for: product)
                    } onDecrement: {
                        updateQuantity(quantity - 1, for: product)
                    }
                    .disabled(work != nil)
                }
                LabeledContent("合計") { Text(total, format: .currency(code: "JPY")) }
                Button("購入を試す") { confirming = true }
                    .disabled(!loaded || cart.isEmpty || work != nil)
                if checkingOut {
                    ProgressView("購入を再現中")
                    Button("中断する") { work?.cancel() }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            Section("購入の再現履歴") {
                if state.orders.isEmpty { Text("履歴がありません").foregroundStyle(.secondary) }
                ForEach(state.orders.reversed()) { order in
                    VStack(alignment: .leading) {
                        Text("再現完了　\(order.units)点")
                        Text(order.totalYen, format: .currency(code: "JPY")).foregroundStyle(.secondary)
                        Text(order.timestamp, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("買い物")
        .sheet(item: $selected) { product in
            NavigationStack {
                productDetail(product)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { selected = nil } }
                    }
            }
        }
        .confirmationDialog("カート\(cart.reduce(0) { $0 + state.quantities[$1.id, default: 0] })点の購入を再現しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("購入を再現する") { checkout() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("決済サービスへの接続や請求は発生しません。")
        }
        .task { load() }
        .onDisappear { work?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { work?.cancel() }
        }
    }

    private func productDetail(_ product: FixtureProduct) -> some View {
        List {
            Section {
                Text(product.description)
                LabeledContent("価格") { Text(product.yen, format: .currency(code: "JPY")) }
                LabeledContent("再現用在庫", value: "\(product.available)点")
            }
            Section {
                let favorite = state.favorites.contains(product.id)
                Button(favorite ? "お気に入りから外す" : "お気に入りに追加") { toggleFavorite(product.id) }
                    .disabled(!loaded || work != nil)
                let quantity = state.quantities[product.id, default: 0]
                Button("カートに追加") { updateQuantity(quantity + 1, for: product) }
                    .disabled(!loaded || work != nil || quantity >= product.available)
                if quantity > 0 { Text("カートに\(quantity)点") }
                if let error { Text(error).foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(product.name)
    }

    private func load() {
        guard !loaded, work == nil else { return }
        error = nil
        work = Task {
            defer { work = nil }
            do {
                state = try await Self.disk.read()
                loaded = true
            } catch {
                error = "カートを読み込めませんでした。端末の空き容量を確認してください。"
            }
        }
    }

    private func toggleFavorite(_ id: String) {
        change { value in
            if value.favorites.remove(id) == nil { value.favorites.insert(id) }
        }
    }

    private func updateQuantity(_ quantity: Int, for product: FixtureProduct) {
        guard quantity >= 0, quantity <= product.available else { return }
        let id = product.id
        change { value in
            if quantity == 0 { value.quantities.removeValue(forKey: id) }
            else { value.quantities[id] = quantity }
        }
    }

    private func checkout() {
        guard loaded, !cart.isEmpty, work == nil else { return }
        let snapshot = state.quantities
        let order = FixtureOrder(id: UUID(), timestamp: .now, units: snapshot.values.reduce(0, +), totalYen: total)
        let decline = simulateDecline
        status = nil
        error = nil
        checkingOut = true
        work = Task {
            let start = ContinuousClock.now
            defer { work = nil; checkingOut = false }
            do {
                try await Task.sleep(for: .milliseconds(800))
                if decline {
                    error = "決済エラーを再現しました。設定を解除すると再試行できます。"
                    await diagnostics?.record(sample: .shopping, action: .process, outcome: .failure)
                    return
                }
                state = try await Self.disk.update { value in
                    if value.orders.contains(where: { $0.id == order.id }) { return }
                    guard value.quantities == snapshot else { throw CheckoutConflict() }
                    value.orders.append(order)
                    value.orders = Array(value.orders.suffix(12))
                    value.quantities.removeAll()
                }
                status = "購入の再現が完了しました"
                await diagnostics?.record(sample: .shopping, action: .process, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                status = "購入の再現を中断しました"
                await diagnostics?.record(sample: .shopping, action: .process, outcome: .cancelled)
            } catch is CheckoutConflict {
                if let refreshed = try? await Self.disk.read() { state = refreshed }
                error = "カートの内容が変わりました。確認してから再試行してください。"
                await diagnostics?.record(sample: .shopping, action: .process, outcome: .failure)
            } catch {
                error = "購入履歴を保存できませんでした。空き容量を確認して再試行してください。"
                await diagnostics?.record(sample: .shopping, action: .save, outcome: .failure)
            }
        }
    }

    private struct CheckoutConflict: Error {}

    private func change(_ edit: @escaping @Sendable (inout ShoppingState) -> Void) {
        guard loaded, work == nil else { return }
        error = nil
        status = nil
        work = Task {
            let start = ContinuousClock.now
            defer { work = nil }
            do {
                try Task.checkCancellation()
                state = try await Self.disk.update(edit)
                await diagnostics?.record(sample: .shopping, action: .save, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                await diagnostics?.record(sample: .shopping, action: .save, outcome: .cancelled)
            } catch {
                error = "変更を保存できませんでした。空き容量を確認して再試行してください。"
                await diagnostics?.record(sample: .shopping, action: .save, outcome: .failure)
            }
        }
    }
}

#Preview { NavigationStack { ShoppingSampleView() } }
