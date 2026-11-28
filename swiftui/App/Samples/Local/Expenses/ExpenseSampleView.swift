import CatalogCore
import Charts
import SwiftUI

private enum ExpenseCategory: String, CaseIterable, Codable, Sendable {
    case food = "食費"
    case transport = "交通"
    case living = "日用品"
    case other = "その他"
}

private struct Expense: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let category: ExpenseCategory
    let yen: Int
}

private struct Expenses: Codable, Sendable {
    var entries: [Expense] = []
    var budgetYen = 25_000
}

private let expenseLocale = Locale(identifier: "ja_JP")

private func yenLabel(_ amount: Int) -> String {
    amount.formatted(.currency(code: "JPY").locale(expenseLocale))
}

struct ExpenseSampleView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.diagnostics) private var diagnostics
    @State private var ledger: LocalRecords<Expenses>
    @State private var date = Date()
    @State private var selectedMonth = Date()
    @State private var category = ExpenseCategory.food
    @State private var amount = ""
    @State private var budget = ""
    @State private var pendingDeletion: Expense?
    @State private var feedback: String?
    @State private var visibleCount = 30

    init(preview: Bool = false) {
        var initial = Expenses()
        if LocalFixtureMode.performance {
            let categories = ExpenseCategory.allCases
            let today = Date.now
            initial.entries = (1...999).map { number in
                Expense(date: today, category: categories[number % categories.count], yen: 100 + number * 11)
            }
        } else if preview {
            initial.entries = [
                Expense(date: .now, category: .food, yen: 1_240),
                Expense(date: .now, category: .transport, yen: 560)
            ]
        }
        _ledger = State(initialValue: LocalRecords(initial: initial, fileName: preview ? nil : "expenses-v1.json"))
    }

    private var monthlyEntries: [Expense] {
        ledger.value.entries.filter { calendar.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
    }

    var body: some View {
        let entries = monthlyEntries
        let total = entries.reduce(0) { $0 + $1.yen }
        let totals = Dictionary(grouping: entries, by: \.category).mapValues { expenses in
            expenses.reduce(0) { $0 + $1.yen }
        }
        Form {
            Section("支出を追加") {
                DatePicker("支出日", selection: $date, displayedComponents: .date)
                Picker("分類", selection: $category) {
                    ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("金額（円）", text: $amount).keyboardType(.numberPad).disabled(ledger.busy)
                if !amount.isEmpty && YenAmount.parse(amount) == nil {
                    Text("1〜1,000,000の整数を入力してください。").foregroundStyle(.red)
                }
                Button("支出を保存", action: addExpense)
                    .disabled(YenAmount.parse(amount) == nil || !ledger.canSave || ledger.value.entries.count >= 1_000)
                if ledger.value.entries.count >= 1_000 {
                    Text("記録は1,000件までです。不要な記録を削除してから追加してください。")
                }
                LocalRecordStatus(store: ledger)
                if let feedback { Text(feedback) }
            }
            Section("月の集計") {
                HStack {
                    Button("前月") { moveMonth(-1) }
                    Spacer()
                    Text(selectedMonth.formatted(.dateTime.year().month(.twoDigits).locale(expenseLocale)))
                    Spacer()
                    Button("翌月") { moveMonth(1) }
                }
                .buttonStyle(.borderless)
                LabeledContent("合計", value: yenLabel(total))
                LabeledContent("毎月の予算", value: yenLabel(ledger.value.budgetYen))
                LabeledContent(
                    total > ledger.value.budgetYen ? "予算超過" : "残りの予算",
                    value: yenLabel(abs(ledger.value.budgetYen - total))
                )
                TextField("新しい毎月の予算（円）", text: $budget).keyboardType(.numberPad).disabled(ledger.busy)
                if !budget.isEmpty && YenAmount.parse(budget) == nil {
                    Text("1〜1,000,000の整数を入力してください。").foregroundStyle(.red)
                }
                Button("毎月の予算を保存", action: saveBudget)
                    .disabled(YenAmount.parse(budget) == nil || !ledger.canSave)
                if !entries.isEmpty {
                    Chart(ExpenseCategory.allCases, id: \.self) { item in
                        BarMark(x: .value("支出（円）", totals[item, default: 0]),
                                y: .value("分類", item.rawValue))
                    }
                    .frame(height: 160)
                    ForEach(ExpenseCategory.allCases, id: \.self) { item in
                        LabeledContent(item.rawValue, value: yenLabel(totals[item, default: 0]))
                    }
                }
            }
            Section("支出の履歴") {
                if entries.isEmpty {
                    Text("この月の支出はありません。上のフォームから追加できます。")
                }
                ForEach(entries.prefix(visibleCount)) { entry in
                    LabeledContent {
                        Text(yenLabel(entry.yen))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.category.rawValue)
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("削除", role: .destructive) { pendingDeletion = entry }
                            .disabled(!ledger.canSave)
                    }
                    .accessibilityAction(named: Text("削除")) { if ledger.canSave { pendingDeletion = entry } }
                }
                if visibleCount < entries.count {
                    Button("次の30件を表示") { visibleCount += 30 }
                }
            }
        }
        .navigationTitle("支出と予算を記録")
        .alert("支出を削除しますか？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { entry in
            Button("削除", role: .destructive) { delete(entry) }
            Button("キャンセル", role: .cancel) {}
        } message: { entry in
            Text("\(entry.category.rawValue)の\(yenLabel(entry.yen))を端末の記録から削除します。")
        }
        .task {
            await ledger.load()
            await diagnostics?.record(sample: .expenses, action: .load, outcome: ledger.ready ? .success : .failure)
        }
    }

    private func moveMonth(_ offset: Int) {
        selectedMonth = calendar.date(byAdding: .month, value: offset, to: selectedMonth) ?? selectedMonth
        visibleCount = 30
    }

    private func addExpense() {
        guard let yen = YenAmount.parse(amount), ledger.value.entries.count < 1_000 else { return }
        let entry = Expense(date: calendar.startOfDay(for: date), category: category, yen: yen)
        var next = ledger.value
        next.entries.insert(entry, at: 0)
        next.entries.sort { $0.date > $1.date }
        Task {
            if await save(next) {
                amount = ""
                selectedMonth = entry.date
                visibleCount = 30
                feedback = "支出を保存しました。"
            }
        }
    }

    private func saveBudget() {
        guard let yen = YenAmount.parse(budget) else { return }
        var next = ledger.value
        next.budgetYen = yen
        Task {
            if await save(next) {
                budget = ""
                feedback = "毎月の予算を保存しました。"
            }
        }
    }

    private func delete(_ entry: Expense) {
        var next = ledger.value
        next.entries.removeAll { $0.id == entry.id }
        Task { if await save(next) { feedback = "支出を削除しました。" } }
    }

    private func save(_ next: Expenses) async -> Bool {
        feedback = nil
        let start = ContinuousClock.now
        let success = await ledger.save(next)
        await diagnostics?.record(sample: .expenses, action: .save, outcome: success ? .success : .failure,
                                  milliseconds: start.duration(to: .now).localMilliseconds)
        return success
    }
}

#Preview {
    NavigationStack { ExpenseSampleView(preview: true) }
}
