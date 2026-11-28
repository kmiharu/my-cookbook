import CatalogCore
import Charts
import Combine
import SwiftUI
import UserNotifications

private struct HabitHistory: Codable, Sendable {
    var title = "水を飲む"
    var completedDays: Set<String> = []
}

private struct HabitDay: Identifiable {
    var id: String { key }
    let date: Date
    let key: String
    let complete: Bool
}

struct HabitSampleView: View {
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: LocalRecords<HabitHistory>
    @State private var goal = ""
    @State private var today = Date()
    @State private var editDate = Date()
    @State private var reminderScheduled = false
    @State private var requesting = false
    @State private var feedback: String?

    private static let reminderID = LocalFixtureMode.performance ? "catalog.habits.stress-daily" : "catalog.habits.daily"

    init(preview: Bool = false) {
        var initial = HabitHistory()
        if LocalFixtureMode.performance || preview {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let today = calendar.startOfDay(for: .now)
            let days = LocalFixtureMode.performance ? 1...729 : 1...3
            initial.completedDays = Set(days.compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: today).map {
                    Self.key(for: $0, calendar: calendar)
                }
            })
        }
        _history = State(initialValue: LocalRecords(initial: initial, fileName: preview ? nil : "habits-v1.json"))
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = environmentCalendar.timeZone
        return result
    }

    private var week: [HabitDay] {
        let today = calendar.startOfDay(for: today)
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = key(for: date)
            return HabitDay(date: date, key: key, complete: history.value.completedDays.contains(key))
        }
    }

    private var streak: Int {
        let completed = history.value.completedDays
        var date = calendar.startOfDay(for: today)
        if !completed.contains(key(for: date)) {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        var count = 0
        while completed.contains(key(for: date)), count < completed.count {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    var body: some View {
        let complete = history.value.completedDays.contains(key(for: editDate))
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let days = week
        Form {
            Section("目標") {
                Text(history.value.title).font(.headline)
                TextField("新しい目標", text: $goal).disabled(history.busy)
                if cleanGoal.count > 40 {
                    Text("目標を40文字以内にしてください。").foregroundStyle(.red)
                }
                Button("目標を保存") {
                    var next = history.value
                    next.title = cleanGoal
                    Task { if await save(next) { goal = "" } }
                }
                .disabled(!(1...40).contains(cleanGoal.count) || !history.canSave)
                LocalRecordStatus(store: history)
            }
            Section("記録") {
                DatePicker("記録する日", selection: $editDate, in: ...Date.now, displayedComponents: .date)
                Button(complete ? "達成を取り消す" : "達成を記録") { toggleDay() }
                    .disabled(!history.canSave || (!complete && history.value.completedDays.count >= 730))
                if history.value.completedDays.count >= 730 {
                    Text("達成記録は730件までです。")
                }
            }
            Section("継続状況") {
                LabeledContent("連続", value: "\(streak)日")
                Text("直近7日間に\(days.filter(\.complete).count)日達成")
                if days.contains(where: \.complete) {
                    Chart(days) { day in
                        BarMark(x: .value("日", day.date, unit: .day), y: .value("達成", day.complete ? 1 : 0))
                    }
                    .chartYScale(domain: 0...1)
                    .chartYAxis(.hidden)
                    .frame(height: 110)
                    .accessibilityHidden(true)
                    ForEach(days) { day in
                        LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted),
                                       value: day.complete ? "達成" : "記録なし")
                    }
                } else {
                    Text("達成を記録すると、直近の状況を表示します。")
                }
            }
            Section("毎日20時のリマインダー") {
                if reminderScheduled {
                    Button("リマインダーを取り消す") {
                        LocalReminder.remove(id: Self.reminderID)
                        reminderScheduled = false
                        feedback = "リマインダーを取り消しました。"
                    }
                } else {
                    Button("リマインダーを設定", action: setReminder)
                        .disabled(requesting)
                }
                if requesting { ProgressView("通知を設定中") }
                if let feedback { Text(feedback) }
            }
        }
        .navigationTitle("習慣の達成を記録")
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = .now }
        .onChange(of: scenePhase) {
            if scenePhase == .active { today = .now }
        }
        .task {
            await history.load()
            reminderScheduled = await UNUserNotificationCenter.current().pendingNotificationRequests()
                .contains { $0.identifier == Self.reminderID }
            await diagnostics?.record(sample: .habits, action: .load, outcome: history.ready ? .success : .failure)
        }
    }

    private func key(for date: Date) -> String {
        Self.key(for: date, calendar: calendar)
    }

    private static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func toggleDay() {
        var next = history.value
        let key = key(for: editDate)
        if next.completedDays.contains(key) {
            next.completedDays.remove(key)
        } else if next.completedDays.count < 730 {
            next.completedDays.insert(key)
        }
        Task { await save(next) }
    }

    @discardableResult
    private func save(_ next: HabitHistory) async -> Bool {
        let success = await history.save(next)
        await diagnostics?.record(sample: .habits, action: .save, outcome: success ? .success : .failure)
        return success
    }

    private func setReminder() {
        guard !requesting else { return }
        requesting = true
        feedback = nil
        Task {
            defer { requesting = false }
            let result = await LocalReminder.add(id: Self.reminderID, title: "今日の習慣を記録する",
                                                components: DateComponents(hour: 20, minute: 0), repeats: true)
            switch result {
            case .scheduled:
                reminderScheduled = true
                feedback = "毎日20時のリマインダーを登録しました。"
            case .denied:
                feedback = "通知が許可されていません。端末の設定から許可できます。"
            case .failed:
                feedback = "通知を登録できませんでした。もう一度お試しください。"
            }
            await diagnostics?.record(sample: .habits, action: .save, outcome: result == .scheduled ? .success : .failure)
        }
    }
}

#Preview {
    NavigationStack { HabitSampleView(preview: true) }
}
