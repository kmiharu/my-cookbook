import CatalogCore
import Foundation
import SwiftUI

struct BookingSampleView: View {
    private enum Failure: String, CaseIterable, Identifiable {
        case none = "指定しない"
        case beforeSaving = "保存前の通信エラー"
        case afterSaving = "保存後に応答が途切れる"

        var id: Self { self }
    }

    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = BookingState()
    @State private var day = BookingSchedule.calendar.startOfDay(for: .now)
    @State private var selected: BookingSlot?
    @State private var pending: BookingCommand?
    @State private var fail: Failure = .none
    @State private var loaded = false
    @State private var submitting = false
    @State private var confirmingCancel = false
    @State private var status: String?
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    private static let disk = FixtureDisk("booking.json", initial: BookingState(), byteLimit: 32_000)
    private let calendar = BookingSchedule.calendar

    var body: some View {
        List {
            Section {
                FixtureModeNote(detail: "端末内で予約と取消を再現します。施設への予約や通知は発生しません。")
                Picker("失敗の再現", selection: $fail) {
                    ForEach(Failure.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .disabled(submitting || pending != nil)
            }
            Section("予約内容") {
                if !loaded {
                    if work != nil { ProgressView("予約を読み込み中") }
                    else { Button("読み込みを再試行") { load() } }
                } else if let booking = state.booking {
                    LabeledContent("予約日時", value: format(booking.slot.start, includesDate: true))
                    LabeledContent("所要時間", value: "30分")
                    Button("予約を取り消す", role: .destructive) { confirmingCancel = true }
                        .disabled(work != nil || pending != nil)
                } else {
                    Text("予約はありません").foregroundStyle(.secondary)
                }
            }
            Section("空き枠を選ぶ（日本時間）") {
                DatePicker("希望日", selection: $day, in: BookingSchedule.days(from: .now), displayedComponents: .date)
                    .disabled(!loaded || submitting || pending != nil)
                    .onChange(of: day) { _, _ in selected = nil }
                let slots = BookingSchedule.slots(on: day, now: .now)
                if slots.isEmpty {
                    ContentUnavailableView("空き枠がありません", systemImage: "calendar", description: Text("ほかの日を選んでください。"))
                }
                ForEach(slots) { slot in
                    Button { selected = slot } label: {
                        let isSelected = selected == slot
                        Label(format(slot.start), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    .disabled(!loaded || submitting || pending != nil || state.booking?.slot == slot)
                }
                Button(state.booking == nil ? "予約を試す" : "予約日時を変更する") { submitSelected() }
                    .disabled(!loaded || work != nil || pending != nil || selected == nil)
            }
            Section {
                if submitting {
                    ProgressView("処理中")
                    Button("中断する") { work?.cancel() }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
                if let pending, !submitting {
                    Button("同じ操作を再試行") { send(pending, failure: .none) }
                        .disabled(work != nil)
                    Button("保存された予約を確認") { reconcile(pending) }
                        .disabled(work != nil)
                }
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .navigationTitle("予約")
        .task { load() }
        .onDisappear { work?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { work?.cancel() }
            if phase == .active && !BookingSchedule.days(from: .now).contains(day) {
                day = calendar.startOfDay(for: .now)
                selected = nil
            }
        }
        .confirmationDialog("予約を取り消しますか？", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("予約を取り消す", role: .destructive) {
                guard let booking = state.booking else { return }
                send(BookingCommand(id: UUID(), operation: .cancel(expectedRevision: booking.revision)), failure: fail)
            }
            Button("予約を残す", role: .cancel) {}
        }
    }

    private func format(_ date: Date, includesDate: Bool = false) -> String {
        date.formatted(Date.FormatStyle(
            date: includesDate ? .abbreviated : .omitted,
            time: .shortened,
            locale: Locale(identifier: "ja_JP"),
            calendar: calendar,
            timeZone: calendar.timeZone
        ))
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
                error = "予約を読み込めませんでした。端末の空き容量を確認してください。"
            }
        }
    }

    private func reconcile(_ command: BookingCommand) {
        guard work == nil else { return }
        work = Task {
            defer { work = nil }
            do {
                let refreshed = try await Self.disk.read()
                applyRefreshedState(refreshed)
                status = refreshed.receipts.contains(command) ? "操作が保存されています（再現）" : "操作は保存されていません"
                error = nil
            } catch {
                error = "予約状態を確認できません。端末の空き容量を確認して再試行してください。"
            }
        }
    }

    private func applyRefreshedState(_ refreshed: BookingState) {
        state = refreshed
        pending = nil
        selected = nil
    }

    private func submitSelected() {
        guard let selected else { return }
        let operation: BookingCommand.Operation
        if let booking = state.booking { operation = .move(selected, expectedRevision: booking.revision) }
        else { operation = .reserve(selected) }
        send(BookingCommand(id: UUID(), operation: operation), failure: fail)
    }

    private func send(_ command: BookingCommand, failure: Failure) {
        guard loaded, work == nil else { return }
        pending = command
        error = nil
        status = nil
        submitting = true
        work = Task {
            let start = ContinuousClock.now
            defer { work = nil; submitting = false }
            do {
                try await Task.sleep(for: .milliseconds(650))
                if failure == .beforeSaving { throw SimulatedFailure.beforeSaving }
                try Task.checkCancellation()
                let result = try await Self.disk.update { state in try state.apply(command, now: .now) }
                if failure == .afterSaving { throw SimulatedFailure.afterSaving }
                applyRefreshedState(result)
                switch command.operation {
                case .reserve: status = "予約の再現が完了しました"
                case .move: status = "予約日時を変更しました（再現）"
                case .cancel: status = "予約を取り消しました（再現）"
                }
                await diagnostics?.record(sample: .booking, action: .process, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                // A retry whose earlier response was lost may already be committed.
                if let refreshed = try? await Self.disk.read() {
                    applyRefreshedState(refreshed)
                    status = refreshed.receipts.contains(command) ? "中断前に操作が保存されました（再現）" : "処理を中断しました"
                } else {
                    error = "予約状態を確認できません。同じ操作を再試行してください。"
                }
                await diagnostics?.record(sample: .booking, action: .process, outcome: .cancelled)
            } catch let failure as SimulatedFailure {
                switch failure {
                case .beforeSaving: error = "保存前のエラーです。同じ操作を再試行できます。"
                case .afterSaving: error = "応答が途切れました。同じ操作を再試行して結果を確認できます。"
                }
                await diagnostics?.record(sample: .booking, action: .process, outcome: .failure, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch let rejection as BookingState.Rejection {
                if let refreshed = try? await Self.disk.read() { state = refreshed }
                pending = nil
                selected = nil
                switch rejection {
                case .invalidSlot: error = "この枠は選べません。日時を選び直してください。"
                case .conflict, .conflictingRetry: error = "予約内容が変わりました。確認してから操作してください。"
                }
                await diagnostics?.record(sample: .booking, action: .process, outcome: .failure)
            } catch {
                error = "予約を保存できませんでした。空き容量を確認してから同じ操作を再試行してください。"
                await diagnostics?.record(sample: .booking, action: .save, outcome: .failure)
            }
        }
    }

    private enum SimulatedFailure: Error { case beforeSaving, afterSaving }
}

#Preview { NavigationStack { BookingSampleView() } }
