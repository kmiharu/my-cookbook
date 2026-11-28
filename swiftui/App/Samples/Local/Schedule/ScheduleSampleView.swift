import CatalogCore
import SwiftUI
import UserNotifications

private struct ScheduledTask: Codable, Identifiable, Sendable {
    var id = UUID()
    let title: String
    let due: Date
    var completed = false

    var notificationID: String { "catalog.schedule.\(id.uuidString)" }
}

struct ScheduleSampleView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.diagnostics) private var diagnostics
    @State private var tasks: LocalRecords<[ScheduledTask]>
    @State private var title = ""
    @State private var due = Date.now.addingTimeInterval(3_600)
    @State private var selectedDay = Date()
    @State private var scheduledIDs: Set<String> = []
    @State private var requesting = false
    @State private var feedback: String?
    @State private var pendingDeletion: ScheduledTask?

    init(preview: Bool = false) {
        let initial: [ScheduledTask]
        if LocalFixtureMode.performance {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            initial = (0..<200).compactMap { index in
                guard let day = calendar.date(byAdding: .day, value: index / 50, to: today),
                      let due = calendar.date(byAdding: .minute, value: (index % 50) * 20, to: day) else { return nil }
                return ScheduledTask(title: "性能測定用の予定 \(index + 1)", due: due)
            }
        } else if preview {
            initial = [ScheduledTask(title: "会議資料を確認する", due: Date.now.addingTimeInterval(3_600))]
        } else {
            initial = []
        }
        _tasks = State(initialValue: LocalRecords(initial: initial, fileName: preview ? nil : "schedule-v1.json"))
    }

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("予定を追加") {
                TextField("予定・タスク名", text: $title).disabled(tasks.busy)
                DatePicker("日時", selection: $due).disabled(tasks.busy)
                Button("予定を保存", action: addTask)
                    .disabled(!(1...80).contains(cleanTitle.count) || !tasks.canSave || tasks.value.count >= 200)
                if cleanTitle.count > 80 {
                    Text("予定名を80文字以内にしてください。").foregroundStyle(.red)
                }
                if tasks.value.count >= 200 { Text("予定は200件まで保存できます。") }
                LocalRecordStatus(store: tasks)
            }
            Section("カレンダー") {
                DatePicker("表示する日", selection: $selectedDay, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                let entries = tasks.value.filter { calendar.isDate($0.due, inSameDayAs: selectedDay) }
                if entries.isEmpty {
                    Text("この日には予定がありません。").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            toggle(entry)
                        } label: {
                            Label(entry.title, systemImage: entry.completed ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityValue(entry.completed ? "完了" : "未完了")
                        .disabled(!tasks.canSave || requesting)
                        Text(entry.due.formatted(date: .omitted, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary)
                        if !entry.completed && entry.due > .now {
                            if scheduledIDs.contains(entry.notificationID) {
                                Button("リマインダーを取り消す") {
                                    LocalReminder.remove(id: entry.notificationID)
                                    scheduledIDs.remove(entry.notificationID)
                                    feedback = "リマインダーを取り消しました。"
                                }
                                .disabled(requesting)
                            } else {
                                Button("リマインダーを設定") { setReminder(entry) }
                                    .disabled(requesting || !tasks.canSave)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("削除", role: .destructive) { pendingDeletion = entry }
                            .disabled(!tasks.canSave || requesting)
                    }
                    .accessibilityAction(named: Text("削除")) {
                        if tasks.canSave && !requesting { pendingDeletion = entry }
                    }
                }
                if requesting { ProgressView("通知を設定中") }
                if let feedback { Text(feedback) }
            }
            Section("共有リスト") {
                if !tasks.value.isEmpty {
                    ShareLink(item: tasks.value.map { task in
                        "\(task.completed ? "✓" : "○") \(task.due.formatted(date: .abbreviated, time: .shortened)) \(task.title)"
                    }.joined(separator: "\n")) {
                        Label("予定の一覧を共有", systemImage: "square.and.arrow.up")
                    }
                }
                NavigationLink("共有リストの競合を試す") { ListConflictDemo() }
            }
        }
        .navigationTitle("予定とタスクを管理")
        .alert("予定を削除しますか？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { entry in
            Button("削除", role: .destructive) { delete(entry) }
            Button("キャンセル", role: .cancel) {}
        } message: { entry in
            Text("「\(entry.title)」とそのリマインダーを取り消します。")
        }
        .task {
            await tasks.load()
            scheduledIDs = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
            await diagnostics?.record(sample: .schedule, action: .load, outcome: tasks.ready ? .success : .failure)
        }
    }

    private func delete(_ entry: ScheduledTask) {
        let next = tasks.value.filter { $0.id != entry.id }
        Task {
            if await save(next) {
                LocalReminder.remove(id: entry.notificationID)
                scheduledIDs.remove(entry.notificationID)
                feedback = "予定を削除しました。"
            }
        }
    }

    private func addTask() {
        guard (1...80).contains(cleanTitle.count), tasks.value.count < 200 else { return }
        let entry = ScheduledTask(title: cleanTitle, due: due)
        let next = (tasks.value + [entry]).sorted { $0.due < $1.due }
        Task {
            if await save(next) {
                selectedDay = entry.due
                title = ""
                feedback = "予定を保存しました。"
            }
        }
    }

    private func toggle(_ entry: ScheduledTask) {
        guard !requesting, let index = tasks.value.firstIndex(where: { $0.id == entry.id }) else { return }
        var next = tasks.value
        next[index].completed.toggle()
        let completed = next[index].completed
        Task {
            if await save(next) {
                if completed {
                    LocalReminder.remove(id: entry.notificationID)
                    scheduledIDs.remove(entry.notificationID)
                }
                feedback = completed ? "タスクを完了しました。" : "タスクを未完了に戻しました。"
            }
        }
    }

    private func save(_ next: [ScheduledTask]) async -> Bool {
        feedback = nil
        let success = await tasks.save(next)
        await diagnostics?.record(sample: .schedule, action: .save, outcome: success ? .success : .failure)
        return success
    }

    private func setReminder(_ entry: ScheduledTask) {
        guard !requesting, entry.due > .now else {
            feedback = "予定の時刻が過ぎました。未来の予定を選んでください。"
            return
        }
        requesting = true
        feedback = nil
        Task {
            defer { requesting = false }
            let date = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: entry.due)
            let result = await LocalReminder.add(id: entry.notificationID, title: "予定の時刻です", components: date)
            switch result {
            case .scheduled:
                scheduledIDs.insert(entry.notificationID)
                feedback = "リマインダーを登録しました。"
            case .denied:
                feedback = "通知が許可されていません。端末の設定から許可できます。"
            case .failed:
                feedback = "通知を登録できませんでした。時刻を確認してもう一度お試しください。"
            }
            await diagnostics?.record(sample: .schedule, action: .save, outcome: result == .scheduled ? .success : .failure)
        }
    }
}

private struct ListConflictDemo: View {
    @State private var committed = ["配布資料を用意する"]
    @State private var revision = 1
    @State private var baseRevision = 1
    @State private var draft = ""
    @State private var feedback: String?
    @State private var simulatedEditCount = 0

    var body: some View {
        Form {
            Section("再現用データ") {
                Text("この端末内で、同じリストを2台から編集する状況を再現します。")
                ForEach(committed.indices, id: \.self) { Text(committed[$0]) }
                Button("別端末が項目を追加した状況を再現") {
                    simulatedEditCount += 1
                    committed.append("別端末の項目 \(simulatedEditCount)")
                    revision += 1
                }
                .disabled(committed.count >= 20)
            }
            Section("手元の編集") {
                TextField("追加する項目", text: $draft)
                Button("リストに反映") {
                    if baseRevision != revision {
                        feedback = "別端末の変更が先に反映されました。内容を確認してから再試行してください。"
                    } else {
                        committed.append(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                        revision += 1
                        baseRevision = revision
                        draft = ""
                        feedback = "この端末内の再現用リストに項目を追加しました。"
                    }
                }
                .disabled(!(1...80).contains(draft.trimmingCharacters(in: .whitespacesAndNewlines).count) || committed.count >= 20)
                if baseRevision != revision {
                    Button("別端末の更新を確認") {
                        baseRevision = revision
                        feedback = "最新版を確認しました。手元の項目を反映できます。"
                    }
                }
                if let feedback { Text(feedback) }
            }
        }
        .navigationTitle("共有リストの競合")
    }
}

#Preview {
    NavigationStack { ScheduleSampleView(preview: true) }
}
