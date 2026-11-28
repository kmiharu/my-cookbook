import CatalogCore
import Foundation
import SwiftUI

private struct AITurn: Codable, Identifiable, Sendable {
    enum Delivery: String, Codable, Sendable {
        case streaming, complete, stopped, failed

        var title: String {
            switch self {
            case .streaming: "応答を表示中"
            case .complete: "再現応答を表示しました"
            case .stopped: "応答を中断しました"
            case .failed: "応答を取得できませんでした"
            }
        }
    }

    let id: UUID
    let prompt: String
    var answer: String
    var delivery: Delivery
}

private struct FixtureAIStream: AsyncSequence, Sendable {
    struct StreamFailure: Error {}

    let chunks: [String]
    let fails: Bool

    init(prompt: String, fails: Bool) {
        self.fails = fails
        if prompt.contains("勉強") || prompt.contains("学習") {
            chunks = ["今日は20分の学習を試してみましょう。\n", "1. 最初の5分で前回の内容を思い出します。\n", "2. 10分だけ新しい問題を解きます。\n", "3. 残りの5分で、次に復習したい点を1つメモします。"]
        } else if prompt.contains("買い物") {
            chunks = ["買い物メモを3つに分けます。\n", "冷蔵品、常温品、日用品の順に見直します。\n", "すでに家にあるものを外します。\n", "最後に、持ち帰れる重さか確認します。"]
        } else {
            chunks = ["予定を立てるための再現回答です。\n", "まず済ませたい用事を1つ決めます。\n", "所要時間を見積もり、その前後に移動時間を足します。\n", "最後に、変更できる時間を1か所残します。"]
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [String]
        let fails: Bool
        var index = 0

        mutating func next() async throws -> String? {
            guard index < chunks.count else { return nil }
            try await Task.sleep(for: .milliseconds(300))
            if fails && index == 2 { throw StreamFailure() }
            defer { index += 1 }
            return chunks[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks, fails: fails) }
}

struct AISampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = ""
    @State private var turns: [AITurn] = []
    @State private var loaded = false
    @State private var simulateFailure = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var work: Task<Void, Never>?
    @State private var responding = false

    private static let disk = FixtureDisk("ai.json", initial: [AITurn](), byteLimit: 128_000)

    var body: some View {
        List {
            Section {
                FixtureModeNote(detail: "端末内の定型文を順に表示します。モデルやAPIへの接続はありません。")
                Toggle("応答エラーを再現", isOn: $simulateFailure).disabled(responding)
            }
            Section("質問する") {
                TextField("質問（300文字まで）", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .disabled(responding)
                Button("例を入力") { prompt = "今日の勉強の進め方を考えてください。" }
                    .disabled(responding)
                Button("応答を表示") { startPrompt() }
                    .disabled(!loaded || work != nil || prompt.trimmedForFixture.isEmpty)
                if responding {
                    ProgressView("再現応答を表示中")
                    Button("中断する") { work?.cancel() }
                }
                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            Section("会話の履歴") {
                if !loaded {
                    if work != nil { ProgressView("履歴を読み込み中") }
                    else { Button("読み込みを再試行") { load() } }
                } else if turns.isEmpty {
                    ContentUnavailableView("履歴がありません", systemImage: "text.bubble")
                } else {
                    ForEach(turns.reversed()) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.prompt).font(.headline)
                            if !turn.answer.isEmpty { Text(turn.answer) }
                            Text(turn.delivery.title).font(.caption).foregroundStyle(.secondary)
                            if turn.delivery == .stopped || turn.delivery == .failed {
                                Button("応答を再試行") { generate(prompt: turn.prompt, id: turn.id) }
                                    .buttonStyle(.borderless).disabled(work != nil)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("AIに相談する")
        .task { load() }
        .onDisappear { work?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { work?.cancel() }
        }
    }

    private func load() {
        guard !loaded, work == nil else { return }
        errorMessage = nil
        work = Task {
            defer { work = nil }
            do {
                let saved = try await Self.disk.read()
                try Task.checkCancellation()
                turns = saved.map { turn in
                    var recovered = turn
                    if turn.delivery == .streaming { recovered.delivery = .stopped }
                    return recovered
                }
                loaded = true
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "履歴を読み込めませんでした。端末の空き容量を確認してください。"
            }
        }
    }

    private func startPrompt() {
        let question = prompt.trimmedForFixture
        guard !question.isEmpty, question.fitsFixtureLimit(300) else {
            errorMessage = "質問を300文字以内で入力してください。"
            return
        }
        generate(prompt: question, id: UUID(), clearsDraft: true)
    }

    private func generate(prompt: String, id: UUID, clearsDraft: Bool = false) {
        guard loaded, work == nil else { return }
        let fails = simulateFailure
        status = nil
        errorMessage = nil
        responding = true
        work = Task {
            let start = ContinuousClock.now
            let initial = AITurn(id: id, prompt: prompt, answer: "", delivery: .streaming)
            var turn = initial
            defer { work = nil; responding = false }
            do {
                try Task.checkCancellation()
                turns = try await save(initial)
                if clearsDraft { self.prompt = "" }
                let outcome: DiagnosticOutcome
                do {
                    for try await chunk in FixtureAIStream(prompt: prompt, fails: fails) {
                        let isFirst = turn.answer.isEmpty
                        turn.answer += chunk
                        show(turn)
                        if isFirst {
                            await diagnostics?.record(sample: .ai, action: .load, outcome: .success, milliseconds: fixtureElapsedMilliseconds(since: start))
                        }
                    }
                    turn.delivery = .complete
                    outcome = .success
                } catch is CancellationError {
                    turn.delivery = .stopped
                    outcome = .cancelled
                } catch {
                    turn.delivery = .failed
                    outcome = .failure
                }
                show(turn)
                turns = try await save(turn)
                status = turn.delivery.title
                await diagnostics?.record(sample: .ai, action: .process, outcome: outcome, milliseconds: fixtureElapsedMilliseconds(since: start))
            } catch is CancellationError {
                await diagnostics?.record(sample: .ai, action: .process, outcome: .cancelled)
            } catch {
                errorMessage = "履歴を保存できませんでした。空き容量を確認して再試行してください。"
                await diagnostics?.record(sample: .ai, action: .save, outcome: .failure)
            }
        }
    }

    private func show(_ turn: AITurn) {
        if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
    }

    private func save(_ turn: AITurn) async throws -> [AITurn] {
        try await Self.disk.update { turns in
            if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
            else { turns.append(turn) }
            turns = Array(turns.suffix(12))
        }
    }
}

#Preview { NavigationStack { AISampleView() } }
